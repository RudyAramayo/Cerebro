#include "ReceiveClock.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>
using namespace rob::amber;
namespace {
constexpr Nanoseconds second=1000000000,ms=1000000,epoch=1800000000LL*second;
void check(bool value,const char* why){if(!value)throw std::runtime_error(why);}
ClockCorrelation sample(Nanoseconds mono,Nanoseconds offset=epoch,Nanoseconds width=10000){return {mono,mono+offset,mono+width};}
ReceiveClock makeClock(){ReceiveClock c({ms,2*ms,100*ms});check(c.reset(1,sample(10*second)),"clock start");return c;}
}
int main(){try{
    auto c=makeClock();auto stamp=c.map(1,epoch+10*second+40*ms,sample(10*second+50*ms));
    check(stamp.monotonic&&*stamp.monotonic==10*second+38*ms,"integer age includes bounded variation, not dequeue time");
    check(c.map(1,epoch+10*second-10*ms,sample(10*second+60*ms)).error==ReceiveClockError::OldPacket,"old epoch queue rejected");
    check(c.map(1,epoch+10*second+250*ms,sample(10*second+70*ms)).error==ReceiveClockError::FuturePacket,"future kernel stamp rejected");
    check(c.map(1,epoch+10*second+20*ms,sample(10*second+150*ms)).error==ReceiveClockError::StalePacket,"stale queue rejected");
    check(c.map(2,epoch+10*second+160*ms,sample(10*second+170*ms)).error==ReceiveClockError::WrongEpoch,"source epoch bound");
    check(bool(c.map(1,epoch+10*second+170*ms,sample(10*second+180*ms)).monotonic),"valid receipt after discarded packets");
    std::cout<<"{\"test\":\"kernel_receive_age_epoch_future_stale_and_conservative_bracket\",\"passed\":true}\n";
    for(int direction:{-1,1}){
        auto jump=makeClock();check(jump.map(1,epoch+10*second+40*ms,sample(10*second+50*ms,epoch+direction*second)).error==ReceiveClockError::ClockChanged,"wall clock jump detected");
        check(!jump.map(1,epoch+10*second+70*ms,sample(10*second+80*ms)).monotonic,"clock recovery cannot rearm old source");
        check(!jump.reset(1,sample(10*second+90*ms)),"same epoch cannot clear fault");
        check(jump.reset(2,sample(10*second+100*ms)),"new epoch can correlate");
        check(bool(jump.map(2,epoch+10*second+120*ms,sample(10*second+130*ms)).monotonic),"new source receipt");
    }
    auto reverse=makeClock();check(reverse.map(1,epoch+9*second,sample(9*second)).error==ReceiveClockError::ClockReversed,"monotonic reversal");
    auto wide=makeClock();check(wide.map(1,epoch+10*second+20*ms,sample(10*second+30*ms,epoch,2*ms)).error==ReceiveClockError::InvalidClock,"uncertain correlation rejected");
    auto invalid=makeClock();check(!invalid.map(1,-1,sample(10*second+30*ms)).monotonic,"negative timestamp rejected");
    auto overflow=makeClock();check(!overflow.reset(2,{std::numeric_limits<Nanoseconds>::max(),0,std::numeric_limits<Nanoseconds>::max()}),"expanded interval overflow rejected");
    std::cout<<"{\"test\":\"clock_step_reversal_uncertainty_overflow_and_new_epoch_recovery\",\"passed\":true}\n";
    for(int direction:{-1,1}){
        auto drift=makeClock();
        check(drift.map(1,epoch+10*second+10*ms,sample(10*second+111*ms,epoch+direction*1900000)).error==ReceiveClockError::StalePacket,"subthreshold step cannot make old feedback young");
        check(bool(drift.map(1,epoch+10*second+30*ms,sample(10*second+120*ms,epoch+direction*1900000)).monotonic),"conservative fresh packet remains usable");
        auto edge=makeClock();
        check(edge.map(1,epoch+10*second+900000,sample(10*second+50*ms,epoch+direction*1900000)).error==ReceiveClockError::OldPacket,"bounded offset cannot move pre-epoch feedback past start");
    }
    auto rollback=makeClock();check(!rollback.reset(2,sample(9*second)),"new epoch cannot erase monotonic reversal");
    std::cout<<"{\"test\":\"allowed_positive_negative_clock_drift_preserves_age_and_epoch_lower_bound\",\"passed\":true}\n";
    for(Nanoseconds error:{-1LL,0LL,1LL}){
        auto exact=makeClock();
        const Nanoseconds now=11*second;
        const auto result=exact.map(1,epoch+now-100*ms+2*ms-error,sample(now,epoch,0));
        check(bool(result.monotonic)==(error<=0),"modern epoch preserves exact one-nanosecond age boundary");
    }
    std::cout<<"{\"test\":\"modern_realtime_epoch_preserves_one_nanosecond_age_boundary\",\"passed\":true}\n";
    std::cout<<"{\"passed\":4,\"failed\":0,\"hardware_io\":false}\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
