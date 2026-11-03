#include "ArmDriverBoundary.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace rob::amber {
ArmDriverBoundary::ArmDriverBoundary(PhysicalArm arm, Directions signs, PositionBounds bounds, BoundaryPolicy policy, MonotonicClock clock)
    : arm_(arm), signs_(signs), bounds_(bounds), policy_(policy), clock_(std::move(clock)) {
    auto positive=[](double x){return std::isfinite(x)&&x>0;};
    if (!clock_ || !route(arm) || !positive(policy.feedback_maximum_age) || !positive(policy.feedback_maximum_gap) ||
        policy.feedback_maximum_gap>policy.feedback_maximum_age || !positive(policy.stationary_span) ||
        !positive(policy.stationary_range) || policy.stationary_samples<2 ||
        policy.history_capacity<policy.stationary_samples || policy.history_capacity>4096 ||
        !positive(policy.publication_budget) || !positive(policy.sample_maximum_age) || !positive(policy.maximum_lease))
        throw std::invalid_argument("invalid offline driver policy");
    for(std::size_t j=0;j<joint_count;++j)
        if((signs[j]!=1&&signs[j]!=-1) || !std::isfinite(bounds.lower[j]) || !std::isfinite(bounds.upper[j]) || bounds.lower[j]>=bounds.upper[j])
            throw std::invalid_argument("invalid explicit directions/bounds");
}
void ArmDriverBoundary::fault(BoundaryFault reason) {
    // Preserve the first fault until an explicitly admitted new generation.
    if(status_.mode!=BoundaryMode::Fault)status_.fault=reason;
    status_.mode=BoundaryMode::Fault;
    // A possibly accepted frame may have started motion. Pre-fault stationary
    // history can never authorize a new generation, even with a new grant.
    for(auto& joint:feedback_)joint.history.clear();
}
bool ArmDriverBoundary::clockValid(double now) {
    if(!std::isfinite(now) || (clock_seen_ && now<last_event_)) { fault(BoundaryFault::Clock);return false; }
    last_event_=now;clock_seen_=true;return true;
}
bool ArmDriverBoundary::readClock(double& now) {
    try { now=clock_(); }
    catch(...) { fault(BoundaryFault::Clock);return false; }
    return clockValid(now);
}
bool ArmDriverBoundary::resetSource(std::uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now;
    if(!readClock(now) || epoch==0 || epoch<=status_.source_epoch) return false;
    if(status_.mode==BoundaryMode::Claimed)fault(BoundaryFault::SourceChanged);
    feedback_={};status_.source_epoch=epoch;source_started_=now;return true;
}
bool ArmDriverBoundary::observe(PhysicalArm arm, std::uint64_t epoch, const Frame& frame, double received) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now;
    auto reject=[&](){++status_.rejected_inputs;return false;};
    if(!readClock(now) || arm!=arm_ || epoch==0 || epoch!=status_.source_epoch ||
        !std::isfinite(received) || received<source_started_ || received>now || now-received>policy_.feedback_maximum_age)
        return reject();
    // Check the previous snapshot before replacing a stale observation. A new
    // receive burst must not hide a feedback outage or revive an expired lease
    // between owner ticks. Continue recording for a future explicit rearm.
    if(status_.mode==BoundaryMode::Claimed)authority(now);
    if(frame.identifier<0x91 || frame.identifier>0x97) return reject();
    const auto index=frame.identifier-0x91;
    const auto decoded=decodeJointDiagnostic(frame,signs_[index]);
    if(!decoded) return reject();
    auto& joint=feedback_[index];
    if(joint.timestamp_seen && received<=joint.time) return reject();
    if(decoded->reply_tag!=policy_.expected_reply_tag || decoded->position_radians<bounds_.lower[index] ||
        decoded->position_radians>bounds_.upper[index]) {
        if(status_.mode==BoundaryMode::Claimed)fault(BoundaryFault::Feedback);
        joint.present=false;joint.timestamp_seen=true;joint.time=received;joint.history.clear();return reject();
    }
    // A later good packet must not erase observed loss of the admitted mode.
    if(status_.mode==BoundaryMode::Claimed && decoded->status!=policy_.expected_position_status)
        fault(BoundaryFault::Feedback);
    if(!joint.present || received-joint.time>policy_.feedback_maximum_gap ||
        decoded->status!=policy_.expected_position_status || joint.mode!=policy_.expected_position_status)
        joint.history.clear();
    joint.present=true;joint.timestamp_seen=true;joint.time=received;joint.position=decoded->position_radians;joint.mode=decoded->status;
    if(joint.mode==policy_.expected_position_status) {
        joint.history.push_back({received,joint.position});
        while(joint.history.size()>policy_.history_capacity)joint.history.pop_front();
        while(joint.history.size()>1 && joint.history[1].time<=received-policy_.stationary_span)
            joint.history.pop_front();
    }
    return true;
}
bool ArmDriverBoundary::fresh(double now) const {
    for(const auto& j:feedback_)
        if(!j.present || j.mode!=policy_.expected_position_status || j.time>now || now-j.time>policy_.feedback_maximum_age)return false;
    return true;
}
bool ArmDriverBoundary::stationary() const {
    for(const auto& j:feedback_) {
        if(j.history.size()<policy_.stationary_samples || j.history.back().time-j.history.front().time+1e-12<policy_.stationary_span)
            return false;
        double low=j.position,high=j.position;
        for(const auto& x:j.history){low=std::min(low,x.position);high=std::max(high,x.position);}
        if(high-low>policy_.stationary_range)return false;
    }
    return true;
}
bool ArmDriverBoundary::identity(std::uint64_t owner, std::uint64_t generation) const {
    return status_.mode==BoundaryMode::Claimed && owner==status_.owner && generation==status_.generation;
}
bool ArmDriverBoundary::authority(double now) {
    if(status_.mode!=BoundaryMode::Claimed)return false;
    if(claim_.source_epoch!=status_.source_epoch){fault(BoundaryFault::SourceChanged);return false;}
    if(now>=claim_.expires_at){fault(BoundaryFault::LeaseExpired);return false;}
    if(!fresh(now)){fault(BoundaryFault::Feedback);return false;}
    return true;
}
arm::Feedback ArmDriverBoundary::snapshot(double now) const {
    arm::Feedback result;result.captured_at=now;result.position_mode=fresh(now);
    result.authority_valid=status_.mode==BoundaryMode::Claimed && now<claim_.expires_at && claim_.source_epoch==status_.source_epoch;
    for(std::size_t j=0;j<joint_count;++j) {
        result.position[j]=feedback_[j].position;
        result.captured_at=std::min(result.captured_at,feedback_[j].time);
    }
    return result;
}
std::optional<StationaryStart> ArmDriverBoundary::begin(const WriterClaim& claim) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now;
    if(!readClock(now) || status_.mode==BoundaryMode::Claimed || claim.owner==0 || claim.generation==0 ||
        claim.generation<=status_.generation || claim.source_epoch==0 || claim.source_epoch!=status_.source_epoch ||
        !claim.stationary_start_authorized || !std::isfinite(claim.expires_at) || claim.expires_at<=now ||
        claim.expires_at-now>policy_.maximum_lease || !fresh(now) || !stationary())return std::nullopt;
    claim_=claim;status_.owner=claim.owner;status_.generation=claim.generation;
    status_.mode=BoundaryMode::Claimed;status_.fault=BoundaryFault::None;
    sample_seen_=braking_=false;last_sequence_=0;
    writer_thread_=std::this_thread::get_id();
    status_.last_batch_attempts=status_.last_batch_accepted=0;status_.last_write_result.reset();
    StationaryStart start;start.feedback=snapshot(now);start.state.position=start.feedback.position;
    return start; // zero derivatives are an explicitly authorized stationary start assumption
}
bool ArmDriverBoundary::renew(std::uint64_t owner, std::uint64_t generation, double expires) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now;
    if(!readClock(now) || !identity(owner,generation) || !authority(now) || !std::isfinite(expires) ||
        expires<=claim_.expires_at || expires-now>policy_.maximum_lease)return false;
    claim_.expires_at=expires;return true;
}
bool ArmDriverBoundary::revoke(std::uint64_t owner, std::uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!identity(owner,generation))return false;
    fault(BoundaryFault::Revoked);return true;
}
arm::Feedback ArmDriverBoundary::feedback(std::uint64_t owner, std::uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    double now;
    if(!readClock(now) || !identity(owner,generation) || !authority(now))return {};
    return snapshot(now);
}
bool ArmDriverBoundary::publish(std::uint64_t owner, const arm::Sample& sample, const FrameWriter& writer) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!identity(owner,sample.generation)) { ++status_.rejected_inputs;return false; }
    if(std::this_thread::get_id()!=writer_thread_){fault(BoundaryFault::WrongThread);return false;}
    status_.last_batch_attempts=status_.last_batch_accepted=0;
    status_.last_write_result.reset();
    double now;
    if(!readClock(now) || !authority(now))return false;
    if(!std::isfinite(sample.time) || sample.time>now || now-sample.time>policy_.sample_maximum_age ||
        (sample_seen_ && sample.time<=last_sample_) || (braking_ && !sample.braking) ||
        (sample.braking && sample.sequence!=0) || (!sample.braking && sample.sequence<last_sequence_)) {
        fault(BoundaryFault::Replay);return false;
    }
    for(std::size_t j=0;j<joint_count;++j)
        if(!std::isfinite(sample.state.velocity[j]) || !std::isfinite(sample.state.acceleration[j])) {
            fault(BoundaryFault::InvalidSample);return false;
        }
    const auto batch=encodePositions(arm_,sample.state.position,signs_,bounds_);
    if(!batch) { fault(BoundaryFault::Encoding);return false; }
    if(!writer) { fault(BoundaryFault::WriteRejected);return false; }
    last_deadline_=std::min(now+policy_.publication_budget,claim_.expires_at);
    if(!std::isfinite(last_deadline_)){fault(BoundaryFault::Clock);return false;}
    for(const auto& frame:batch->frames) {
        if(!readClock(now) || !authority(now))return false;
        if(now>=last_deadline_){fault(BoundaryFault::Deadline);return false;}
        ++status_.attempted_frames;++status_.last_batch_attempts;
        WriteResult result=WriteResult::Uncertain;
        try { result=writer(batch->destination,frame,last_deadline_); } catch(...) {}
        status_.last_write_result=result;
        if(result==WriteResult::Accepted){++status_.accepted_frames;++status_.last_batch_accepted;}
        if(!readClock(now))return false;
        if(result==WriteResult::Rejected){fault(BoundaryFault::WriteRejected);return false;}
        if(result!=WriteResult::Accepted){fault(BoundaryFault::WriteUncertain);return false;}
        if(now>=last_deadline_){fault(BoundaryFault::Deadline);return false;}
        if(!authority(now))return false;
    }
    last_sample_=sample.time;last_sequence_=sample.sequence;sample_seen_=true;braking_=sample.braking;
    ++status_.published_batches;return true;
}
BoundaryStatus ArmDriverBoundary::status() const { std::lock_guard<std::mutex> lock(mutex_);return status_; }
} // namespace rob::amber
