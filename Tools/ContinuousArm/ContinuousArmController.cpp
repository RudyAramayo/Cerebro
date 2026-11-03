#include "ContinuousArmController.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace rob::arm {
namespace {
constexpr double tolerance = 1e-8;
bool finite(const Vector& x) {
    return std::all_of(x.begin(), x.end(), [](double v) { return std::isfinite(v); });
}
}

Envelope envelope(const Trajectory& trajectory) {
    Envelope e{};
    e.lower.fill(std::numeric_limits<double>::infinity());
    e.upper.fill(-std::numeric_limits<double>::infinity());
    if (!std::isfinite(trajectory.get_duration()) || trajectory.get_duration()<0) return e;
    const auto profiles=trajectory.get_profiles();
    if (profiles.size()!=1) return e; // this owner never accepts waypoint/cloud paths
    for(size_t joint=0;joint<joints;++joint) {
        const auto& p=profiles[0][joint];
        auto segment=[&](double t,double q,double v,double a,double j) {
            if (!std::isfinite(t) || t<0 || !std::isfinite(q) || !std::isfinite(v) ||
                !std::isfinite(a) || !std::isfinite(j)) return false;
            auto sample=[&](double at) {
                const double position=q+at*(v+at*(a/2+at*j/6));
                const double velocity=v+at*(a+at*j/2);
                const double acceleration=a+at*j;
                e.lower[joint]=std::min(e.lower[joint],position);
                e.upper[joint]=std::max(e.upper[joint],position);
                e.velocity[joint]=std::max(e.velocity[joint],std::abs(velocity));
                e.acceleration[joint]=std::max(e.acceleration[joint],std::abs(acceleration));
                return std::isfinite(position) && std::isfinite(velocity) && std::isfinite(acceleration);
            };
            if (!sample(0) || !sample(t)) return false;
            if (t>0) e.jerk[joint]=std::max(e.jerk[joint],std::abs(j));
            auto root=[&](double at) { return at<=0 || at>=t || sample(at); };
            if (j==0) { if(a!=0 && !root(-v/a)) return false; }
            else {
                // Velocity extrema: a(t)=0. Position extrema: v(t)=0.
                if(!root(-a/j)) return false;
                const double d=a*a-2*j*v;
                if(!std::isfinite(d)) return false;
                if(d>=0) {
                    const double sqrt_d=std::sqrt(d);
                    // Stable quadratic roots avoid cancellation near v=0.
                    const double numerator=-a-std::copysign(sqrt_d,a);
                    if(numerator!=0) {
                        if(!root(numerator/j) || !root(2*v/numerator)) return false;
                    } else if(!root(-a/j)) return false;
                }
            }
            return true;
        };
        if(p.brake.duration>0) {
            for(size_t i=0;i<2;++i)
                if(p.brake.t[i]>0 && !segment(p.brake.t[i],p.brake.p[i],p.brake.v[i],p.brake.a[i],p.brake.j[i])) return e;
        }
        for(size_t i=0;i<7;++i)
            if(!segment(p.t[i],p.p[i],p.v[i],p.a[i],p.j[i])) return e;
        // p.back() is integrated by both interfaces; pf is undefined in the
        // velocity interface of pinned Ruckig 0.9.2, so never read it.
        const double remaining=trajectory.get_duration()-p.brake.duration-p.t_sum.back();
        if(!std::isfinite(remaining) || !segment(std::max(0.0,remaining),p.p.back(),p.v.back(),p.a.back(),0)) return e;
    }
    e.valid=true;
    return e;
}
namespace {
bool positive(double x) { return std::isfinite(x) && x > 0; }
bool fresh(double captured, double now, double age) {
    return std::isfinite(now) && std::isfinite(captured) && captured <= now && now-captured <= age;
}
}

ContinuousArmController::ContinuousArmController(Limits limits, Policy policy, PathGuard guard)
    : limits_(limits), policy_(policy), guard_(std::move(guard)) {
    if (!guard_ || !positive(policy.period) || !positive(policy.maximum_tick_gap) ||
        policy.maximum_tick_gap < policy.period || !positive(policy.target_maximum_age) ||
        !positive(policy.feedback_maximum_age) || !positive(policy.tracking_error))
        throw std::invalid_argument("Explicit finite timing, feedback policy and path guard required");
    for (size_t j=0; j<joints; ++j) {
        if (!std::isfinite(limits.lower[j]) || !std::isfinite(limits.upper[j]) ||
            limits.lower[j] >= limits.upper[j] || !positive(limits.velocity[j]) ||
            !positive(limits.acceleration[j]) || !positive(limits.jerk[j]))
            throw std::invalid_argument("Explicit finite SI joint/dynamic limits required");
    }
}

bool ContinuousArmController::stateValid(const State& s) const {
    if (!finite(s.position) || !finite(s.velocity) || !finite(s.acceleration)) return false;
    for (size_t j=0; j<joints; ++j) {
        if (s.position[j] < limits_.lower[j]-tolerance || s.position[j] > limits_.upper[j]+tolerance ||
            std::abs(s.velocity[j]) > limits_.velocity[j]+tolerance ||
            std::abs(s.acceleration[j]) > limits_.acceleration[j]+tolerance) return false;
    }
    return true;
}

bool ContinuousArmController::feedbackValid(const Feedback& f, double now) const {
    if (!f.position_mode || !f.authority_valid || !finite(f.position) ||
        !fresh(f.captured_at, now, policy_.feedback_maximum_age)) return false;
    for (size_t j=0; j<joints; ++j)
        if (f.position[j] < limits_.lower[j] || f.position[j] > limits_.upper[j]) return false;
    return true;
}

bool ContinuousArmController::bounded(Trajectory& t) const {
    if (!std::isfinite(t.get_duration()) || t.get_duration() < 0) return false;
    const auto extrema = envelope(t);
    if (!extrema.valid) return false;
    for (size_t j=0; j<joints; ++j)
        if (extrema.lower[j] < limits_.lower[j]-tolerance || extrema.upper[j] > limits_.upper[j]+tolerance ||
            extrema.velocity[j] > limits_.velocity[j]+tolerance ||
            extrema.acceleration[j] > limits_.acceleration[j]+tolerance || extrema.jerk[j] > limits_.jerk[j]+tolerance)
            return false;
    return true;
}

bool ContinuousArmController::plan(const State& from, const Vector& target, bool stop, Trajectory& t) const {
    ruckig::InputParameter<joints> in;
    in.current_position = from.position;
    in.current_velocity = from.velocity;
    in.current_acceleration = from.acceleration;
    in.target_position = target;
    in.target_velocity.fill(0);
    in.target_acceleration.fill(0);
    in.max_velocity = limits_.velocity;
    in.max_acceleration = limits_.acceleration;
    in.max_jerk = limits_.jerk;
    if (stop) {
        in.control_interface = ruckig::ControlInterface::Velocity;
        in.synchronization = ruckig::Synchronization::None;
    }
    ruckig::Ruckig<joints> planner(policy_.period);
    return stateValid(from) && planner.calculate(in, t) >= 0 && bounded(t);
}

bool ContinuousArmController::stopEnvelope(const State& s, Trajectory& t) const {
    return plan(s, s.position, true, t);
}

bool ContinuousArmController::guard(const Trajectory& t, double from, bool stop) const noexcept {
    try { return guard_(t, from, stop); } catch (...) { return false; }
}

bool ContinuousArmController::start(uint64_t generation, const State& initial, const Feedback& f, double now) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation == 0 || generation <= status_.generation || status_.mode == Mode::Following ||
        status_.mode == Mode::Braking || !stateValid(initial) || !feedbackValid(f, now)) return false;
    for (size_t j=0; j<joints; ++j)
        if (std::abs(initial.velocity[j]) > tolerance || std::abs(initial.acceleration[j]) > tolerance ||
            std::abs(initial.position[j]-f.position[j]) > tolerance) return false;
    Trajectory stationary;
    if (!stopEnvelope(initial, stationary) || !guard(stationary, 0, true)) return false;
    status_.mode = Mode::Following;
    status_.reason = Reason::None;
    status_.generation = generation;
    status_.received_sequence = status_.applied_sequence = 0;
    status_.commanded = initial;
    status_.pending = false;
    pending_.reset();
    trajectory_ = stationary;
    trajectory_time_ = 0;
    last_tick_ = target_time_ = now;
    stop_requested_ = false;
    owner_ = std::this_thread::get_id();
    return true;
}

Reason ContinuousArmController::submit(const Target& target, double now) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto reject = [&](Reason why) { ++status_.rejected; return why; };
    if (target.generation != status_.generation) return reject(Reason::WrongGeneration);
    if (status_.mode != Mode::Following || stop_requested_) return reject(Reason::NotFollowing);
    if (target.sequence == 0 || target.sequence <= status_.received_sequence) return reject(Reason::OldSequence);
    if (!fresh(target.captured_at, now, policy_.target_maximum_age) || now < last_tick_ ||
        target.captured_at < target_time_ || !finite(target.position)) return reject(Reason::InvalidTarget);
    for (size_t j=0; j<joints; ++j)
        if (target.position[j] < limits_.lower[j] || target.position[j] > limits_.upper[j])
            return reject(Reason::InvalidTarget);
    if (pending_) ++status_.replaced_pending;
    pending_ = target;
    status_.pending = true;
    status_.received_sequence = target.sequence;
    target_time_ = target.captured_at; // receipt time cannot rejuvenate an old pose
    ++status_.accepted;
    return Reason::None;
}

bool ContinuousArmController::stop(uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (generation != status_.generation || status_.mode != Mode::Following) return false;
    stop_requested_ = true;
    pending_.reset();
    status_.pending = false;
    return true;
}

void ContinuousArmController::fault(Reason reason) {
    status_.mode = Mode::Fault;
    status_.reason = reason;
    pending_.reset();
    trajectory_.reset();
    status_.pending = false;
}

void ContinuousArmController::revoke() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_.mode != Mode::Fault) fault(Reason::AuthorityLost);
}

bool ContinuousArmController::brake(Reason why) {
    Trajectory stop;
    pending_.reset();
    status_.pending = false;
    stop_requested_ = true;
    if (!stopEnvelope(status_.commanded, stop) || !guard(stop, 0, true)) {
        fault(Reason::UnsafeStop);
        return false;
    }
    trajectory_ = stop;
    trajectory_time_ = 0;
    status_.mode = Mode::Braking;
    status_.reason = why;
    status_.applied_sequence = 0; // no obsolete target remains an active command
    ++status_.replans;
    return true;
}

bool ContinuousArmController::tick(double now, const Feedback& f, const Sink& sink) {
    // All target replacement, cancellation and sample publication share this
    // transaction. There are no detached trajectory workers or stale writers.
    std::lock_guard<std::mutex> lock(mutex_);
    if (status_.mode == Mode::Unarmed || status_.mode == Mode::Fault) return false;
    if (std::this_thread::get_id() != owner_) { fault(Reason::WrongThread); return false; }
    const double dt = now-last_tick_;
    if (!std::isfinite(now) || dt <= 0 || dt > policy_.maximum_tick_gap+tolerance) {
        fault(Reason::Timing); return false; // do not burst delayed samples
    }
    if (!feedbackValid(f, now)) { fault(Reason::Feedback); return false; }
    for (size_t j=0; j<joints; ++j) {
        if (std::abs(f.position[j]-status_.commanded.position[j]) > policy_.tracking_error) {
            fault(Reason::TrackingError); return false;
        }
    }
    if (status_.mode == Mode::Following) {
        if (stop_requested_ || !fresh(target_time_, now, policy_.target_maximum_age)) {
            if (!brake(stop_requested_ ? Reason::Released : Reason::Expired)) return false;
        } else if (pending_) {
            Trajectory next;
            const auto target = *pending_;
            pending_.reset(); status_.pending = false;
            if (!plan(status_.commanded, target.position, false, next) || !guard(next, 0, false)) {
                if (!brake(Reason::PathRejected)) return false;
            } else {
                trajectory_ = next;
                trajectory_time_ = 0;
                status_.applied_sequence = target.sequence;
                ++status_.replans;
            }
        }
    }
    const bool stopping = status_.mode == Mode::Braking || status_.mode == Mode::Held;
    if (!trajectory_ || !guard(*trajectory_, trajectory_time_, stopping)) {
        if (stopping || !brake(Reason::PathRejected)) { fault(Reason::UnsafeStop); return false; }
    }
    double next_time = std::min(trajectory_time_+dt, trajectory_->get_duration());
    State next;
    trajectory_->at_time(next_time, next.position, next.velocity, next.acceleration);
    auto continuousSample = [&](const State& sample) {
        if (!stateValid(sample)) return false;
        for (size_t j=0; j<joints; ++j) {
            if (std::abs(sample.position[j]-status_.commanded.position[j]) > limits_.velocity[j]*dt+tolerance ||
                std::abs(sample.acceleration[j]-status_.commanded.acceleration[j]) > limits_.jerk[j]*dt+tolerance)
                return false;
        }
        return true;
    };
    if (!continuousSample(next)) { fault(Reason::Planning); return false; }
    // Verify a feasible, collision-reviewed stop from every proposed sample.
    // Reject before publishing, never clip q after planning (which breaks PVA).
    Trajectory reserve;
    if (!stopEnvelope(next, reserve) || !guard(reserve, 0, true)) {
        if (status_.mode != Mode::Following || !brake(Reason::UnsafeStop)) {
            fault(Reason::UnsafeStop); return false;
        }
        // Replace the rejected candidate within this same tick. Do not leave
        // a gap, reset velocity, clamp q or send the unsafe candidate first.
        next_time = std::min(dt, trajectory_->get_duration());
        trajectory_->at_time(next_time, next.position, next.velocity, next.acceleration);
        if (!continuousSample(next) || !stopEnvelope(next, reserve) || !guard(reserve, 0, true)) {
            fault(Reason::UnsafeStop); return false;
        }
    }
    Sample sample{next, now, status_.generation, status_.applied_sequence,
                  status_.mode == Mode::Braking || status_.mode == Mode::Held};
    bool sent = false;
    try { sent = sink && sink(sample); } catch (...) { sent = false; }
    if (!sent) { fault(Reason::OutputFailure); return false; }
    status_.commanded = next; // one coherent, immutable-in-flight PVA snapshot
    trajectory_time_ = next_time;
    last_tick_ = now;
    ++status_.published;
    if (status_.mode == Mode::Braking && next_time >= trajectory_->get_duration()) status_.mode = Mode::Held;
    return true;
}

Status ContinuousArmController::status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return status_;
}
const char* name(Mode x) {
    switch (x) {
        case Mode::Unarmed: return "unarmed"; case Mode::Following: return "following";
        case Mode::Braking: return "braking"; case Mode::Held: return "held"; case Mode::Fault: return "fault";
    } return "unknown";
}
const char* name(Reason x) {
    switch (x) {
#define ROB_REASON(x) case Reason::x: return #x
        ROB_REASON(None); ROB_REASON(Released); ROB_REASON(Expired); ROB_REASON(InvalidTarget);
        ROB_REASON(OldSequence); ROB_REASON(WrongGeneration); ROB_REASON(NotFollowing);
        ROB_REASON(BadStart); ROB_REASON(Timing); ROB_REASON(Feedback); ROB_REASON(TrackingError);
        ROB_REASON(Planning); ROB_REASON(JointBounds); ROB_REASON(PathRejected);
        ROB_REASON(UnsafeStop); ROB_REASON(OutputFailure); ROB_REASON(WrongThread);
        ROB_REASON(AuthorityLost);
#undef ROB_REASON
    } return "unknown";
}
} // namespace rob::arm
