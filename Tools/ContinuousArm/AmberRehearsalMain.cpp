// Deterministic commissioning rehearsal. Linked to the real owner, session and
// wire codec, but NOT SocketCanTransport. No sockets, devices, activation or
// external inputs. All positions and feedback below are explicitly synthetic.
#include "ArmSession.hpp"
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>

namespace a = rob::arm;
namespace w = rob::amber;
namespace {
constexpr double degree = 1.0 / w::radians_to_degrees;
constexpr double period = .005;
constexpr std::size_t active_joint = 1; // simulated native J2, NOT a verified lift axis
void check(bool value, const char *why) {
    if (!value) throw std::runtime_error(why);
}
a::Limits limits() {
    a::Limits l;
    l.lower.fill(-.5 * degree); l.upper.fill(.5 * degree);
    l.lower[active_joint] = -degree; l.upper[active_joint] = 6 * degree;
    l.velocity.fill(.08); l.acceleration.fill(.16); l.jerk.fill(.5);
    return l;
}
struct Rig {
    double now{}, peak_velocity{}, peak_acceleration{}, peak_wire_step{};
    double previous_velocity{};
    int last_direction{}, reversals{};
    std::uint64_t sequence{};
    std::size_t frames{}, target_changes{}, moving_changes{};
    a::Vector actual{}, last_target{};
    std::array<std::uint16_t, 7> words{};
    bool feedback_enabled{true};
    w::ArmSession session;
    Rig() : session(w::PhysicalArm::Right, {1,1,1,1,1,1,1}, limits(),
        {period,.015,.15,.1,.02}, {.1,.06,.2,.0004,5,64,1,2,.004,.01,1},
        {.15,.08,30,.1,3}, 1, [this]{return now;},
        [](const a::Trajectory &path, double, bool) {
            const auto e = a::envelope(path);
            const auto l = limits();
            if (!e.valid) return false;
            for (std::size_t j=0;j<7;++j)
                if (e.lower[j] < l.lower[j] || e.upper[j] > l.upper[j]) return false;
            return true; // synthetic joint corridor, NOT physical collision clearance
        }, [this](const w::Route &route, const w::Frame &f, double deadline) {
            check(route.can_interface == "can10" && now < deadline, "route/deadline");
            check(f.identifier == 0x11 + frames % 7 && f.length == 3 && f.data[0] == 0x40,
                  "one ordered seven-joint batch");
            const auto j = f.identifier - 0x11;
            words[j] = (static_cast<std::uint16_t>(f.data[1]) << 8) | f.data[2];
            const w::Frame reply{static_cast<std::uint32_t>(0x91+j),8,
                {1,f.data[1],f.data[2],0,0,0,0,2}};
            const auto d = w::decodeJointDiagnostic(reply,1);
            check(d.has_value(), "wire decode");
            peak_wire_step = std::max(peak_wire_step, std::abs(d->position_radians-actual[j]));
            actual[j] = d->position_radians;
            if(j != active_joint) check(actual[j] == 0, "inactive joints unchanged");
            ++frames;
            return w::WriteResult::Accepted;
        }) {
        check(session.resetSource(1), "new source");
        for(int i=0;i<6;++i) { now+=.05; feed(); }
        check(frames==0 && session.start(1,now+25,true), "explicit simulated start");
    }
    void feed() {
        for(std::size_t j=0;j<7;++j) {
            w::Frame f{static_cast<std::uint32_t>(0x91+j),8,
                {1,static_cast<std::uint8_t>(words[j]>>8),static_cast<std::uint8_t>(words[j]),0,0,0,0,2}};
            check(session.observe(1,f,now), "synthetic feedback");
        }
    }
    void target(double angle) {
        a::Vector q{}; q[active_joint]=angle;
        if(q!=last_target) {
            ++target_changes;
            if(std::abs(session.status().owner.commanded.velocity[active_joint])>.001) ++moving_changes;
            last_target=q;
        }
        check(session.submit(1,1,++sequence,now,q)==a::Reason::None, "fresh target admitted");
    }
    bool tick(bool refresh=true) {
        now+=period;
        if(feedback_enabled) feed();
        if(refresh && session.status().mode==w::SessionMode::Following) target(last_target[active_joint]);
        const bool ok=session.tick();
        const auto s=session.status().owner.commanded;
        const double velocity=s.velocity[active_joint];
        peak_velocity=std::max(peak_velocity,std::abs(velocity));
        peak_acceleration=std::max(peak_acceleration,std::abs(s.acceleration[active_joint]));
        check(std::abs(velocity-previous_velocity)<=.16*period+1e-8, "coherent velocity step");
        previous_velocity=velocity;
        const int direction=velocity>.001?1:velocity<-.001?-1:0;
        if(direction && last_direction && direction!=last_direction) ++reversals;
        if(direction) last_direction=direction;
        return ok;
    }
    void raise() {
        target(5*degree);
        int settled=0;
        for(int i=0;i<1200 && settled<20;++i) {
            check(tick(), "small move tick");
            const auto s=session.status().owner.commanded;
            settled=(std::abs(actual[active_joint]-5*degree)<.0002 &&
                     std::abs(s.velocity[active_joint])<1e-8)?settled+1:0;
        }
        check(settled==20, "small move reached and settled in simulated feedback");
    }
    void switchTargets() {
        for(int leg=0;leg<12;++leg) {
            target((leg%2?5:2)*degree);
            for(int i=0;i<200;++i) check(tick(), "mid-motion retarget tick");
        }
        check(moving_changes>=10 && reversals>=8, "actual moving reversals exercised");
    }
    void finish() {
        for(int i=0;i<600 && session.status().mode!=w::SessionMode::Held;++i)
            check(tick(false), "controlled brake");
        check(session.status().mode==w::SessionMode::Held, "held after brake");
        check(std::abs(session.status().owner.commanded.velocity[active_joint])<1e-9, "zero commanded velocity");
        const auto n=frames;
        for(int i=0;i<40;++i) check(tick(false), "held tick");
        check(frames==n, "no publication or replay after held");
        check(session.submit(1,1,++sequence,now,{})==a::Reason::NotFollowing, "old client cannot resume");
    }
};
void run(const std::string &trigger) {
    Rig r; r.raise(); r.switchTargets();
    check(std::abs(r.session.status().owner.commanded.velocity[active_joint])>.001, "trigger while moving");
    if(trigger=="stop") check(r.session.stop(1,1), "stop");
    else if(trigger=="disconnect") check(r.session.disconnect(1,1), "disconnect");
    else if(trigger=="shutdown") r.session.shutdown();
    else if(trigger=="stale_target") {
        for(int i=0;i<31;++i) {
            r.now+=period; r.feed();
            if(r.session.status().mode==w::SessionMode::Following)
                check(r.session.heartbeat(1,1,r.now), "heartbeat cannot renew target");
            check(r.session.tick(), "target expires with live client");
        }
        // Update metric baseline after the direct ticks above.
        r.previous_velocity=r.session.status().owner.commanded.velocity[active_joint];
    } else if(trigger=="feedback_loss") {
        r.feedback_enabled=false;
        for(int i=0;i<25 && r.session.status().mode!=w::SessionMode::Fault;++i) r.tick();
        check(r.session.status().mode==w::SessionMode::Fault &&
              r.session.status().reason==w::SessionReason::Feedback, "feedback fault latched");
        const auto n=r.frames;
        for(int i=0;i<20;++i) r.tick(false);
        check(r.frames==n, "no output after feedback fault");
    } else throw std::runtime_error("unknown scenario");
    if(trigger!="feedback_loss") r.finish();
    const auto s=r.session.status();
    const auto expected=trigger=="stop"?w::SessionReason::Stop:
        trigger=="disconnect"?w::SessionReason::ClientDisconnected:
        trigger=="shutdown"?w::SessionReason::Shutdown:
        trigger=="stale_target"?w::SessionReason::TargetExpired:w::SessionReason::Feedback;
    check(s.reason==expected, "correct termination cause");
    check(r.peak_velocity<=.08+1e-8 && r.peak_acceleration<=.16+1e-8, "simulated rate limits");
    check(r.peak_wire_step<=.08*period+2*degree/128, "quantized position step bound");
    check(s.owner.generation==1 && s.boundary.published_batches*7==r.frames, "one owner generation and full batches");
    std::cout<<std::setprecision(10)<<"{\"test\":\"small_move_retargets_"<<trigger<<"\",\"passed\":true,"
        <<"\"hardware_io\":false,\"simulated_seconds\":"<<r.now<<",\"target_changes\":"<<r.target_changes
        <<",\"mid_motion_changes\":"<<r.moving_changes<<",\"velocity_reversals\":"<<r.reversals
        <<",\"recorded_frames\":"<<r.frames<<",\"owner_generations\":1,\"peak_velocity_rad_s\":"<<r.peak_velocity
        <<",\"peak_acceleration_rad_s2\":"<<r.peak_acceleration<<",\"peak_wire_step_rad\":"<<r.peak_wire_step<<"}\n";
}
}
int main(int argc,char **argv) {
    if(argc!=2 || std::string(argv[1])!="--run") {
        std::cout<<"rob-amber-rehearse --run\nSynthetic 5-degree native J2 move, 12 retargets, then stop/fault cases.\n"
            <<"No hardware I/O. Does not establish anatomical raise direction, physical limits or collision clearance.\n";
        return argc==1?0:2;
    }
    try {
        for(const char *trigger:{"stop","disconnect","shutdown","stale_target","feedback_loss"}) run(trigger);
        std::cout<<"{\"passed\":5,\"failed\":0,\"hardware_io\":false,\"feedback\":\"synthetic ideal quantized plant\"}\n";
        return 0;
    } catch(const std::exception &e) { std::cerr<<e.what()<<'\n';return 1; }
}
