#include "ReceiveClock.hpp"
#include <limits>
#include <stdexcept>

namespace rob::amber {
namespace {
std::optional<Nanoseconds> add(Nanoseconds a,Nanoseconds b) {
    if((b>0&&a>std::numeric_limits<Nanoseconds>::max()-b)||
       (b<0&&a<std::numeric_limits<Nanoseconds>::min()-b))return {};
    return a+b;
}
}
ReceiveClock::ReceiveClock(ReceiveClockPolicy policy):policy_(policy) {
    if(policy.maximum_bracket<=0||policy.maximum_offset_change<=0||policy.maximum_age<=0||
       policy.maximum_bracket>=policy.maximum_age)throw std::invalid_argument("invalid receive clock policy");
}
bool ReceiveClock::valid(const ClockCorrelation& c) const {
    return c.monotonic_before>=0&&c.realtime>=0&&c.monotonic_after>=c.monotonic_before&&
        c.monotonic_after-c.monotonic_before<=policy_.maximum_bracket;
}
bool ReceiveClock::reset(std::uint64_t epoch,const ClockCorrelation& c) {
    if(epoch==0||epoch<=epoch_)return false;
    if(!valid(c)){fault_=ReceiveClockError::InvalidClock;return false;}
    if(epoch_!=0&&c.monotonic_before<last_time_){fault_=ReceiveClockError::ClockReversed;return false;}
    // Subtraction of nonnegative int64 clocks is representable. Expanding the
    // offset interval still needs overflow checks at synthetic endpoints.
    const auto low=add(c.monotonic_before-c.realtime,-policy_.maximum_offset_change);
    const auto high=add(c.monotonic_after-c.realtime,policy_.maximum_offset_change);
    if(!low||!high){fault_=ReceiveClockError::InvalidClock;return false;}
    epoch_=epoch;offset_low_=*low;offset_high_=*high;
    anchor_mono_=c.monotonic_before;anchor_realtime_=c.realtime;
    started_=last_time_=c.monotonic_after;fault_=ReceiveClockError::None;return true;
}
ReceivedTime ReceiveClock::map(std::uint64_t epoch,Nanoseconds received,const ClockCorrelation& c) {
    if(fault_!=ReceiveClockError::None)return {{},fault_};
    if(epoch!=epoch_)return {{},ReceiveClockError::WrongEpoch};
    if(!valid(c)||received<0){fault_=ReceiveClockError::InvalidClock;return {{},fault_};}
    if(c.monotonic_before<last_time_){fault_=ReceiveClockError::ClockReversed;return {{},fault_};}
    const auto low=c.monotonic_before-c.realtime,high=c.monotonic_after-c.realtime;
    // Require the entire observed bracket to fit in the allowed epoch bounds.
    if(low<offset_low_||high>offset_high_){fault_=ReceiveClockError::ClockChanged;return {{},fault_};}
    last_time_=c.monotonic_after;
    if(received>c.realtime)return {{},ReceiveClockError::FuturePacket};
    // Earliest offset across the whole epoch, including allowed unseen drift.
    // Current-offset-only mapping can make an old packet appear younger.
    // Integer ns preserve modern realtime epoch precision without float loss.
    auto mapped=add(anchor_mono_,received-anchor_realtime_);
    if(mapped)mapped=add(*mapped,-policy_.maximum_offset_change);
    if(!mapped){fault_=ReceiveClockError::InvalidClock;return {{},fault_};}
    if(*mapped<started_)return {{},ReceiveClockError::OldPacket};
    if(*mapped>c.monotonic_after)return {{},ReceiveClockError::FuturePacket};
    if(c.monotonic_after-*mapped>policy_.maximum_age)return {{},ReceiveClockError::StalePacket};
    return {mapped,ReceiveClockError::None};
}
} // namespace rob::amber
