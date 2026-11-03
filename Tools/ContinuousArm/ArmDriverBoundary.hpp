#pragma once
#include "AmberWireCodec.hpp"
#include "ContinuousArmController.hpp"
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace rob::amber {
// Offline-tested boundary only. There is no transport backend, service, motor
// activation or hardware watchdog. All authority/source/timestamp assertions
// must come from a trusted host adapter, not an unauthenticated wire client.
struct BoundaryPolicy {
    double feedback_maximum_age, feedback_maximum_gap;
    double stationary_span, stationary_range;
    std::size_t stationary_samples, history_capacity;
    std::uint8_t expected_reply_tag; // fixture value; firmware meaning unverified
    std::uint8_t expected_position_status; // explicit simulated admission, not raw decoding
    double publication_budget, sample_maximum_age, maximum_lease;
};
struct WriterClaim {
    std::uint64_t owner{}, generation{}, source_epoch{};
    double expires_at{};
    bool stationary_start_authorized{}; // external authorization, never inferred
};
enum class BoundaryMode { Unclaimed, Claimed, Fault };
enum class BoundaryFault {
    None, SourceChanged, Revoked, Clock, LeaseExpired, Feedback, Replay,
    InvalidSample, Encoding, Deadline, WriteRejected, WriteUncertain, WrongThread
};
enum class WriteResult { Accepted, Rejected, Uncertain };
// Accepted means the fake/backend transport accepted this frame, NOT a motor
// acknowledgement. Rejected must mean definitely not queued; otherwise Uncertain.
using FrameWriter = std::function<WriteResult(const Route&, const Frame&, double deadline)>;
using MonotonicClock = std::function<double()>;
struct StationaryStart { arm::State state; arm::Feedback feedback; };
struct BoundaryStatus {
    BoundaryMode mode{BoundaryMode::Unclaimed};
    BoundaryFault fault{BoundaryFault::None};
    std::uint64_t owner{}, generation{}, source_epoch{}, rejected_inputs{};
    std::size_t attempted_frames{}, accepted_frames{}, published_batches{};
    std::size_t last_batch_attempts{}, last_batch_accepted{};
    std::optional<WriteResult> last_write_result;
};

// One shared boundary instance per physical arm. The mutex gives logical writer
// exclusion within this instance; it does NOT exclude another process or object
// opening CAN. A future service must enforce OS-level sole-writer ownership.
// Callbacks run under the publication transaction and must be bounded and
// nonreentrant. Post-return deadline checks cannot preempt a hung callback.
class ArmDriverBoundary {
public:
    ArmDriverBoundary(PhysicalArm, Directions, PositionBounds, BoundaryPolicy, MonotonicClock);
    bool resetSource(std::uint64_t epoch); // clears all feedback/claims
    bool observe(PhysicalArm, std::uint64_t epoch, const Frame&, double received_at);
    std::optional<StationaryStart> begin(const WriterClaim&);
    bool renew(std::uint64_t owner, std::uint64_t generation, double expires_at);
    bool revoke(std::uint64_t owner, std::uint64_t generation);
    arm::Feedback feedback(std::uint64_t owner, std::uint64_t generation);
    bool publish(std::uint64_t owner, const arm::Sample&, const FrameWriter&);
    BoundaryStatus status() const;
private:
    struct Observation { double time, position; };
    struct Joint {
        bool present{}, timestamp_seen{};
        double time{}, position{};
        std::uint8_t mode{};
        std::deque<Observation> history;
    };
    bool clockValid(double now);
    bool readClock(double& now);
    bool identity(std::uint64_t owner, std::uint64_t generation) const;
    bool authority(double now);
    bool fresh(double now) const;
    bool stationary() const;
    arm::Feedback snapshot(double now) const;
    void fault(BoundaryFault);
    PhysicalArm arm_;
    Directions signs_;
    PositionBounds bounds_;
    BoundaryPolicy policy_;
    // Sample after acquiring mutex_, so time spent waiting behind publication
    // cannot appear as a clock reversal from a pre-lock caller snapshot.
    MonotonicClock clock_;
    mutable std::mutex mutex_;
    std::array<Joint, joint_count> feedback_;
    BoundaryStatus status_;
    WriterClaim claim_;
    double source_started_{}, last_event_{}, last_sample_{}, last_deadline_{};
    std::uint64_t last_sequence_{};
    bool clock_seen_{}, sample_seen_{}, braking_{};
    std::thread::id writer_thread_;
};
} // namespace rob::amber
