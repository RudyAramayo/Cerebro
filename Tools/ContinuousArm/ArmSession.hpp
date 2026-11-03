#pragma once
#include "ArmDriverBoundary.hpp"

namespace rob::amber {
struct SessionPolicy {
    double writer_lease{},renewal_margin{},maximum_grant{},client_timeout{},shutdown_timeout{};
};
enum class SessionMode { Observing, Following, Braking, Held, Fault };
enum class SessionReason {
    None, Stop, ClientDisconnected, ClientExpired, TargetExpired, GrantEnding,
    GrantExpired, Shutdown, ShutdownTimeout, Clock, Feedback, Output, Transport,
    SourceChanged, WrongThread, UnsafeStop, PathRejected
};
struct SessionStatus {
    SessionMode mode{SessionMode::Observing};
    SessionReason reason{SessionReason::None};
    std::uint64_t generation{},client{},source_epoch{};
    double grant_expires{},writer_expires{};
    bool shutting_down{},shutdown_complete{};
    arm::Status owner;
    BoundaryStatus boundary;
};
// This is trusted host-side lifecycle logic, not wire authentication. Client
// IDs, grants and creation timestamps come from an authenticated ingress bound
// to this boot/session. No client-supplied "authorized" field may call start.
// A real whole-trajectory + braking guard is mandatory. Simulation guards are
// confined to fixtures; profile JSON cannot replace this callback on hardware.
class ArmSession {
public:
    ArmSession(PhysicalArm,Directions,arm::Limits,arm::Policy,BoundaryPolicy,SessionPolicy,
               std::uint64_t writer_id,MonotonicClock,arm::PathGuard,FrameWriter);
    bool resetSource(std::uint64_t new_epoch);
    bool observe(std::uint64_t epoch,const Frame&,double captured_at);
    // Owner thread only. This function does not create or obtain authorization.
    bool start(std::uint64_t authenticated_client,double grant_expires,bool stationary_start_authorized);
    arm::Reason submit(std::uint64_t authenticated_client,std::uint64_t expected_generation,std::uint64_t sequence,
                       double created_at,const arm::Vector&);
    bool heartbeat(std::uint64_t authenticated_client,std::uint64_t expected_generation,double created_at);
    bool stop(std::uint64_t authenticated_client,std::uint64_t expected_generation);
    bool disconnect(std::uint64_t authenticated_client,std::uint64_t expected_generation);
    void shutdown();
    void transportFault();
    bool tick(); // only constructor/start thread; no threads created internally
    SessionStatus status() const;
private:
    bool now(double&);
    bool client(std::uint64_t,std::uint64_t) const;
    bool guard(const arm::Trajectory&,double,bool);
    void brake(SessionReason);
    void fault(SessionReason);
    PhysicalArm arm_;
    arm::Policy owner_policy_;
    BoundaryPolicy boundary_policy_;
    SessionPolicy policy_;
    std::uint64_t writer_;
    MonotonicClock clock_;
    FrameWriter sink_;
    arm::PathGuard guard_;
    std::optional<double> grant_deadline_;
    ArmDriverBoundary boundary_;
    arm::ContinuousArmController owner_;
    std::thread::id thread_;
    mutable std::mutex mutex_;
    SessionStatus status_;
    double last_event_{},last_client_{},shutdown_deadline_{};
    bool clock_seen_{};
};
} // namespace rob::amber
