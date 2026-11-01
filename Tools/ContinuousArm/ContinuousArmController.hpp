#pragma once

// Offline-tested trajectory owner. No motor/network implementation is provided.
// A commissioned adapter must provide bounded callbacks, measured feedback,
// exclusive actuator ownership and an independent hardware watchdog. Never run
// this beside Amber's detached Ruckig workers or feed its samples to UDP cmd 4.
#include <ruckig/ruckig.hpp>
#include <array>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <thread>

namespace rob::arm {
constexpr size_t joints = 7;
using Vector = std::array<double, joints>;
using Trajectory = ruckig::Trajectory<joints>;

struct State { Vector position{}, velocity{}, acceleration{}; };
struct Limits { Vector lower, upper, velocity, acceleration, jerk; };
struct Envelope { Vector lower, upper, velocity, acceleration, jerk; bool valid{}; };
// Analytical segment extrema, including zero-jerk acceleration phases. Does
// not use Ruckig 0.9.2's uninitialized velocity-profile final-position field.
Envelope envelope(const Trajectory&);
struct Policy {
    double period;                  // seconds, e.g. 0.005; not a motor rating
    double maximum_tick_gap;
    double target_maximum_age;
    double feedback_maximum_age;
    double tracking_error;          // radians; must be commissioned
};
struct Feedback {
    Vector position{};
    double captured_at{};           // host monotonic time, not client wall time
    bool position_mode{};
    bool authority_valid{};
};
struct Target {
    uint64_t generation{}, sequence{};
    double captured_at{};           // validated/mapped by ingress adapter
    Vector position{};              // SI radians in the native joint reference
};
enum class Mode { Unarmed, Following, Braking, Held, Fault };
enum class Reason {
    None, Released, Expired, InvalidTarget, OldSequence, WrongGeneration,
    NotFollowing, BadStart, Timing, Feedback, TrackingError, Planning,
    JointBounds, PathRejected, UnsafeStop, OutputFailure, WrongThread
};
struct Sample {
    State state;
    double time{};
    uint64_t generation{}, sequence{};
    bool braking{};
};
struct Status {
    Mode mode{Mode::Unarmed};
    Reason reason{Reason::None};
    State commanded;
    uint64_t generation{}, applied_sequence{}, received_sequence{};
    uint64_t accepted{}, replaced_pending{}, rejected{}, replans{}, published{};
    bool pending{};
};

// guard examines the entire remaining trajectory [from_time, duration], not
// just endpoints. It must bind current model/world/other-arm context. A missing
// guard is rejected. Tests explicitly supply simulated worlds.
using PathGuard = std::function<bool(const Trajectory&, double from_time, bool braking)>;
// Called inside the ownership transaction. false/exception means uncertain
// output, latches Fault and MUST NOT be retried. Never reenter the controller.
using Sink = std::function<bool(const Sample&)>;

class ContinuousArmController {
public:
    ContinuousArmController(Limits limits, Policy policy, PathGuard guard);
    // Host authorization chooses a strictly increasing generation. Only a
    // fresh, proven stationary coherent state may initialize/reinitialize it.
    // No active takeover, inferred zero velocity or automatic fault recovery.
    bool start(uint64_t generation, const State& stationary, const Feedback&, double now);
    Reason submit(const Target&, double now); // one slot; never a waypoint FIFO
    bool stop(uint64_t generation);          // latches; invalidates pending target
    bool tick(double now, const Feedback&, const Sink&); // one owner thread only
    Status status() const;

    // Pure inspection, including the analytical extrema of the stop trajectory.
    bool stopEnvelope(const State&, Trajectory& stop) const;
private:
    bool stateValid(const State&) const;
    bool feedbackValid(const Feedback&, double now) const;
    bool bounded(Trajectory&) const;
    bool plan(const State&, const Vector&, bool brake, Trajectory&) const;
    bool guard(const Trajectory&, double from, bool brake) const noexcept;
    void fault(Reason);
    bool brake(Reason);
    Limits limits_;
    Policy policy_;
    PathGuard guard_;
    mutable std::mutex mutex_;
    Status status_;
    std::optional<Target> pending_;
    std::optional<Trajectory> trajectory_;
    std::thread::id owner_;
    double last_tick_{}, target_time_{}, trajectory_time_{};
    bool stop_requested_{};
};
const char* name(Mode);
const char* name(Reason);
} // namespace rob::arm
