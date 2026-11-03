#pragma once
#include "ArmDriverBoundary.hpp"
#include "ReceiveClock.hpp"
#include <memory>
#include <string>
#include <vector>

namespace rob::amber {
// Linux only. Construction does not open a socket; open() is explicit. No
// activation, gripper, calibration, socket-reconnect or command retries.
// A caller permitting hardware TX must already own the isolated device and
// a commissioned session. This low-level backend cannot manufacture authority.
struct SocketCanOptions {
    PhysicalArm arm{PhysicalArm::Right};
    std::string interface;
    bool require_virtual{true};
    bool allow_transmit{false};
    std::size_t maximum_receive_batch{64};
    Nanoseconds receive_budget{1000000};
    int queue_high_water_bytes{4096};
    ReceiveClockPolicy clock{1000000,2000000,100000000};
};
enum class SocketCanFault {
    None, Open, Configuration, Interface, Timestamp, Overflow, BusError,
    Receive, Backlog, Deadline, Queue, Send, Closed, ForeignFrame
};
struct SocketCanStatus {
    bool opened{},transmit_allowed{};
    SocketCanFault fault{SocketCanFault::None};
    int system_error{},interface_index{};
    std::uint64_t epoch{},received{},discarded_old{},attempted{},accepted{};
    std::string interface_kind;
};
struct KernelFeedback { Frame frame; Nanoseconds received_at; std::uint64_t epoch; };
class SocketCanTransport {
public:
    explicit SocketCanTransport(SocketCanOptions);
    ~SocketCanTransport();
    SocketCanTransport(const SocketCanTransport&)=delete;
    SocketCanTransport& operator=(const SocketCanTransport&)=delete;
    bool open(std::uint64_t new_source_epoch);
    void close();
    std::vector<KernelFeedback> receive();
    WriteResult writePosition(const Route&,const Frame&,double monotonic_deadline);
    SocketCanStatus status() const;
    static Nanoseconds monotonicNanoseconds();
    static double monotonicSeconds();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace rob::amber
