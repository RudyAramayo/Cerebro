#pragma once
#include <cstdint>
#include <optional>

namespace rob::amber {
// SO_TIMESTAMPNS_NEW is realtime, not monotonic. Capture CLOCK_MONOTONIC on
// both sides of CLOCK_REALTIME. All values are integer nanoseconds; the bracket bounds
// uncertainty rather than silently relabelling a dequeue time as receive time.
using Nanoseconds = std::int64_t;
struct ClockCorrelation { Nanoseconds monotonic_before{}, realtime{}, monotonic_after{}; };
// Assumption: throughout this source epoch, the realtime-to-monotonic offset
// stays within the initial bracket expanded by maximum_offset_change. Each
// observed bracket must fit entirely in that interval. Unobserved excursions
// between correlation samples cannot be proved absent by this mapper.
struct ReceiveClockPolicy { Nanoseconds maximum_bracket{}, maximum_offset_change{}, maximum_age{}; };
enum class ReceiveClockError { None, InvalidClock, ClockReversed, ClockChanged, WrongEpoch, OldPacket, FuturePacket, StalePacket, NotStarted };
struct ReceivedTime { std::optional<Nanoseconds> monotonic; ReceiveClockError error{ReceiveClockError::None}; };
// Single receiver owner; the transport serializes access. No system calls.
class ReceiveClock {
public:
    explicit ReceiveClock(ReceiveClockPolicy);
    bool reset(std::uint64_t source_epoch, const ClockCorrelation&);
    ReceivedTime map(std::uint64_t source_epoch, Nanoseconds kernel_realtime, const ClockCorrelation& now);
    ReceiveClockError fault() const { return fault_; }
private:
    bool valid(const ClockCorrelation&) const;
    ReceiveClockPolicy policy_;
    std::uint64_t epoch_{};
    Nanoseconds offset_low_{},offset_high_{},anchor_mono_{},anchor_realtime_{},started_{},last_time_{};
    ReceiveClockError fault_{ReceiveClockError::NotStarted};
};
} // namespace rob::amber
