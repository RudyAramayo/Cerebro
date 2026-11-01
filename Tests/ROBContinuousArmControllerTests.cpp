// No sockets, CAN, LCM, mode changes or hardware access. Simulated feedback
// follows the last published setpoint exactly unless a test injects a fault.
#include "ContinuousArmController.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using namespace rob::arm;
namespace {
int cases = 0;
void require(bool ok, const std::string& why) { if (!ok) throw std::runtime_error(why); }
void passed(const char* label) {
    ++cases; std::cout << "{\"test\":\"" << label << "\",\"passed\":true}\n";
}
Limits limits() {
    Limits l;
    l.lower.fill(-2.09); l.upper.fill(2.09);
    // Illustrative offline settings, not established hardware capabilities.
    l.velocity.fill(.3); l.acceleration.fill(.6); l.jerk.fill(2);
    return l;
}
Policy policy() { return {.005, .015, .15, .1, .05}; }
PathGuard emptySimulatedWorld() { return [](const Trajectory&, double, bool) { return true; }; }
struct Rig {
    ContinuousArmController controller;
    State state{};
    double time{};
    uint64_t sequence{};
    uint64_t generation{1};
    std::vector<Sample> outputs;
    explicit Rig(PathGuard guard = emptySimulatedWorld()) : controller(limits(), policy(), guard) {
        require(controller.start(generation, state, feedback(), time), "stationary fixture start");
    }
    Feedback feedback() const { return {state.position, time, true, true}; }
    bool step(double dt=.005) {
        time += dt;
        return controller.tick(time, feedback(), [&](const Sample& s) {
            state=s.state; outputs.push_back(s); return true;
        });
    }
    Reason target(const Vector& q) { return controller.submit({generation, ++sequence, time, q}, time); }
    Reason target(double q, size_t j=5) { Vector goal{}; goal[j]=q; return target(goal); }
    void moving(int ticks=150) {
        for (int i=0; i<ticks; ++i) {
            if (i%10==0) require(target(1.0)==Reason::None, "motion target");
            require(step(), "motion step");
        }
        require(std::abs(state.velocity[5])>.01, "fixture moving");
    }
    void held() {
        for (int i=0; i<400 && controller.status().mode!=Mode::Held; ++i) require(step(), "brake step");
        require(controller.status().mode==Mode::Held, "stopped within two seconds");
        for (size_t j=0; j<joints; ++j)
            require(std::abs(state.velocity[j])<1e-9 && std::abs(state.acceleration[j])<1e-9, "zero stopped derivatives");
    }
};
struct Metrics {
    double velocity{}, acceleration{}, jerk{}, step{};
    void check(const State& before, const State& after, double dt) {
        const auto l=limits();
        for (size_t j=0; j<joints; ++j) {
            velocity=std::max(velocity,std::abs(after.velocity[j]));
            acceleration=std::max(acceleration,std::abs(after.acceleration[j]));
            jerk=std::max(jerk,std::abs(after.acceleration[j]-before.acceleration[j])/dt);
            step=std::max(step,std::abs(after.position[j]-before.position[j]));
            require(after.position[j]>=l.lower[j]-1e-8 && after.position[j]<=l.upper[j]+1e-8, "position bound");
            require(std::abs(after.velocity[j])<=l.velocity[j]+1e-8, "velocity bound");
            require(std::abs(after.acceleration[j])<=l.acceleration[j]+1e-8, "acceleration bound");
            require(std::abs(after.acceleration[j]-before.acceleration[j])<=l.jerk[j]*dt+1e-8, "jerk continuity");
            require(std::abs(after.position[j]-before.position[j])<=l.velocity[j]*dt+1e-8, "position continuity");
        }
    }
};

void initialization() {
    bool threw=false; auto bad=limits(); bad.velocity[1]=std::numeric_limits<double>::quiet_NaN();
    try { ContinuousArmController c(bad,policy(),emptySimulatedWorld()); } catch(const std::invalid_argument&) { threw=true; }
    require(threw,"invalid limits rejected");
    threw=false;
    try { ContinuousArmController c(limits(),policy(),{}); } catch(const std::invalid_argument&) { threw=true; }
    require(threw,"missing path guard rejected");
    ContinuousArmController c(limits(),policy(),emptySimulatedWorld());
    State s; Feedback f{s.position,0,true,true};
    require(!c.tick(.005,f,[](const Sample&) { throw std::runtime_error("unarmed emitted"); return true; }),"unarmed silent");
    s.velocity[0]=.01;
    require(!c.start(1,s,f,0),"cannot invent a moving initial state");
    s.velocity[0]=0; f.captured_at=-1;
    require(!c.start(1,s,f,0),"stale start rejected");
    f.captured_at=0;
    require(c.start(1,s,f,0),"fresh stationary start");
    require(!c.start(2,s,f,0),"no active takeover");
    passed("explicit_limits_guard_stationary_start_no_takeover");
}

void streaming(const char* output) {
    Rig rig; Metrics metrics; int retargetedMoving=0;
    std::ofstream trace;
    if (output) { trace.open(output); require(bool(trace),"open trace"); trace << "time,target_j6,q_j6,v_j6,a_j6,sequence,braking\n"; }
    Vector goal{}; std::mt19937 rng(73031);
    std::uniform_real_distribution<double> noise(-.08,.08);
    for(int i=0;i<14000;++i) {
        if(i<12000 && i%3==0) {
            for(size_t j=0;j<joints;++j) goal[j]=.75*std::sin(rig.time*(.3+.08*j))+noise(rng);
            if(std::abs(rig.state.velocity[5])>.01) ++retargetedMoving;
            require(rig.target(goal)==Reason::None,"stream target");
        } else if(i>=12000 && i%10==0) {
            goal.fill(.1); require(rig.target(goal)==Reason::None,"final target heartbeat");
        }
        State before=rig.state;
        require(rig.step(),std::string("stream sample ")+name(rig.controller.status().reason));
        metrics.check(before,rig.state,.005);
        if(trace) trace << std::setprecision(12) << rig.time << ',' << goal[5] << ',' << rig.state.position[5]
                        << ',' << rig.state.velocity[5] << ',' << rig.state.acceleration[5] << ','
                        << rig.controller.status().applied_sequence << ",0\n";
    }
    for(double q:rig.state.position) require(std::abs(q-.1)<1e-7,"last target reached");
    require(retargetedMoving>2000,"retargeted in motion");
    auto st=rig.controller.status();
    std::cout << "{\"metrics\":\"seven_joint_stream\",\"samples\":" << st.published
              << ",\"targets\":" << st.accepted << ",\"moving_retargets\":" << retargetedMoving
              << ",\"max_velocity_rad_s\":" << metrics.velocity << ",\"max_acceleration_rad_s2\":" << metrics.acceleration
              << ",\"max_discrete_jerk_rad_s3\":" << metrics.jerk << ",\"max_step_rad\":" << metrics.step << "}\n";
    passed("seven_joint_noisy_66hz_stream_200hz_owner_and_final_convergence");
}

void bursts() {
    Rig rig;
    for(int i=0;i<1000;++i) require(rig.target(i*.001)==Reason::None,"burst accepted");
    require(rig.controller.status().replaced_pending==999,"only newest slot retained");
    require(rig.step(),"consume burst");
    auto s=rig.controller.status();
    require(s.applied_sequence==1000 && s.replans==1 && !s.pending,"one latest target plan, no backlog");
    passed("thousand_command_burst_one_latest_target");
}

void ingress() {
    Rig r; Vector q{}; q[5]=.5;
    require(r.target(q)==Reason::None,"first target");
    require(r.controller.submit({1,1,0,q},0)==Reason::OldSequence,"duplicate blocked");
    require(r.controller.submit({2,2,0,q},0)==Reason::WrongGeneration,"foreign generation blocked");
    auto bad=q; bad[2]=std::numeric_limits<double>::quiet_NaN();
    require(r.controller.submit({1,2,0,bad},0)==Reason::InvalidTarget,"NaN blocked");
    bad=q; bad[4]=3;
    require(r.controller.submit({1,2,0,bad},0)==Reason::InvalidTarget,"out of bound target blocked");
    require(r.controller.submit({1,2,.001,q},0)==Reason::InvalidTarget,"future pose blocked");
    require(r.controller.submit({1,2,-1,q},0)==Reason::InvalidTarget,"stale pose blocked");
    require(r.step(),"valid pending survives invalid packets");
    require(r.controller.status().applied_sequence==1,"bad packets did not replace target");
    require(r.controller.submit({1,2,0,q},-.1)==Reason::InvalidTarget,"clock reversal blocked");
    passed("replay_reordering_foreign_generation_nan_bounds_and_time_rejected");
}

void releaseAndResume() {
    Rig r; r.moving(); auto before=r.state;
    require(r.controller.stop(1),"stop accepted");
    require(r.target(-1)==Reason::NotFollowing,"target cannot race after Stop barrier");
    require(r.step(),"first braking sample");
    Metrics m; m.check(before,r.state,.005);
    require(r.controller.status().mode==Mode::Braking && r.outputs.back().braking,"controlled brake");
    require(r.controller.status().applied_sequence==0,"old target invalidated");
    r.held();
    require(r.target(-1)==Reason::NotFollowing,"held requires new clutch");
    require(!r.controller.start(1,r.state,r.feedback(),r.time),"same generation cannot restart");
    require(r.controller.start(2,r.state,r.feedback(),r.time),"fresh explicit new stationary generation");
    require(r.target(-1)==Reason::WrongGeneration,"old clutch rejected after restart");
    passed("release_jerk_limited_stop_latched_reclutch_no_replay");
}

void timeout() {
    Rig r; r.moving(); const double last=r.time;
    for(int i=0;i<32;++i) require(r.step(),"timeout progresses to stop");
    require(r.controller.status().reason==Reason::Expired,"deadman expires capture time");
    require(r.time-last<=.161,"timeout bound");
    r.held();
    passed("lost_tracking_stream_stops_and_does_not_auto_resume");
}

void faultCases() {
    for(int type=0;type<7;++type) {
        Rig r; r.moving(); auto f=r.feedback(); double next=r.time+.005;
        if(type==0) f.captured_at-=1;
        if(type==1) f.position[0]+=.1;
        if(type==2) f.position_mode=false;
        if(type==3) f.authority_valid=false;
        if(type==4) next+=.1;
        if(type==5) next=r.time;
        if(type==6) f.position[0]=std::numeric_limits<double>::infinity();
        size_t emitted=0;
        require(!r.controller.tick(next,f,[&](const Sample&) {++emitted; return true;}),"fault rejects output");
        require(emitted==0 && r.controller.status().mode==Mode::Fault,"fault latched before sink");
        require(!r.step(),"fresh next feedback cannot auto-resume");
    }
    passed("stale_feedback_tracking_error_mode_lease_stall_duplicate_tick_infinity_fault");
    Rig r; r.moving();
    require(!r.controller.tick(r.time+.005,r.feedback(),[](const Sample&){return false;}),"sink failure");
    require(r.controller.status().reason==Reason::OutputFailure && !r.step(),"uncertain output never replayed");
    passed("uncertain_transport_result_latches_no_retry");
}

void collisionAndBounds() {
    bool normalAllowed=true, stopAllowed=true;
    Rig r([&](const Trajectory&,double,bool braking) {return braking?stopAllowed:normalAllowed;});
    r.moving(); normalAllowed=false;
    require(r.target(-1)==Reason::None && r.step(),"changed scene requests braking");
    require(r.controller.status().mode==Mode::Braking && r.outputs.back().braking,"full path rejection brakes");
    r.held();
    passed("changed_scene_rechecks_current_path_and_brakes");
    Rig noStop([&](const Trajectory&,double,bool braking) {return !braking || stopAllowed;});
    noStop.moving(); stopAllowed=false;
    require(!noStop.step() && noStop.controller.status().mode==Mode::Fault,"unsafe stop cannot emit unchecked output");
    passed("blocked_stopping_envelope_faults_before_output");
    Rig inspect; Trajectory t; State s;
    s.position[5]=2.089; s.velocity[5]=.3;
    require(!inspect.controller.stopEnvelope(s,t),"in-bounds position insufficient when stop crosses bound");
    s.position[5]=1.8;
    require(inspect.controller.stopEnvelope(s,t),"interior state has bounded stop");
    const auto e=envelope(t);
    require(e.valid && e.upper[5]>s.position[5] && e.upper[5]<=2.09,"analytical stop extrema inspected");
    passed("analytical_braking_extrema_reject_near_limit_overshoot");
    Rig edge;
    for(int i=0;i<2200;++i) {
        if(i%10==0) require(edge.target(2.09)==Reason::None,"edge target");
        require(edge.step(),"edge path bounded");
    }
    require(std::abs(edge.state.position[5]-2.09)<1e-7,"exact edge converged");
    require(edge.target(-2.09)==Reason::None && edge.step(),"edge reversal");
    passed("joint_limit_endpoint_and_reversal_without_wrapping");
}

void jitterAndConcurrency() {
    Rig r; Metrics m;
    for(int i=0;i<1000;++i) {
        if(i%5==0) require(r.target(.5)==Reason::None,"jitter target");
        double dt=i%2==0?.003:.007; auto previous=r.state;
        require(r.step(dt),"jitter integrates elapsed time"); m.check(previous,r.state,dt);
    }
    passed("3ms_7ms_jitter_integrates_time_without_burst_or_derivative_reseed");
    Rig mailbox;
    std::atomic<bool> begin{false}, done{false};
    std::thread producer([&] {
        while(!begin.load()) std::this_thread::yield();
        Vector q{};
        for(uint64_t sequence=1;sequence<=100000;++sequence) {
            q[5]=.25 + double(sequence%100)*.001;
            // Synthetic fixed timestamp: concurrent ticks deliberately share
            // no test clock variable; rejected stale packets are expected.
            mailbox.controller.submit({1,sequence,0,q},0);
        }
        done=true;
    });
    begin=true;
    while(!done.load()) { mailbox.controller.status(); std::this_thread::yield(); }
    producer.join();
    require(mailbox.step(),"one owner consumes concurrent mailbox");
    require(mailbox.controller.status().applied_sequence==100000,"last concurrent packet wins");
    require(mailbox.controller.status().replaced_pending==99999,"constant capacity under load");
    passed("concurrent_100000_packet_mailbox_latest_wins");

    Rig wrongOwner;
    bool output=true;
    std::thread other([&]{output=wrongOwner.controller.tick(.005,wrongOwner.feedback(),[](const Sample&){return true;});});
    other.join();
    require(!output && wrongOwner.controller.status().reason==Reason::WrongThread,"second tick worker rejected");
    passed("second_trajectory_worker_cannot_publish");
}

void stopPublicationBarrier() {
    Rig r; r.moving(); std::mutex m; std::condition_variable cv;
    bool sinkEntered=false, allowSink=false;
    std::atomic<bool> stopReturned{false};
    std::thread stopper([&] {
        {std::unique_lock<std::mutex> lock(m); cv.wait(lock,[&]{return sinkEntered;});}
        r.controller.stop(1); stopReturned=true;
    });
    std::thread unblock([&] {
        {std::unique_lock<std::mutex> lock(m); cv.wait(lock,[&]{return sinkEntered;});}
        // The test deliberately blocks a sink to verify linearization, not
        // to recommend a blocking actuator callback in production.
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        require(!stopReturned.load(),"Stop cannot return while old output is in flight");
        {std::lock_guard<std::mutex> lock(m); allowSink=true;} cv.notify_all();
    });
    require(r.controller.tick(r.time+.005,r.feedback(),[&](const Sample& s) {
        std::unique_lock<std::mutex> lock(m); sinkEntered=true; cv.notify_all();
        cv.wait(lock,[&]{return allowSink;}); r.state=s.state; return true;
    }),"in-flight output precedes Stop");
    stopper.join(); unblock.join(); r.time+=.005;
    require(stopReturned && r.target(-1)==Reason::NotFollowing,"nothing supersedes Stop");
    require(r.step() && r.outputs.back().braking,"only braking samples after Stop");
    passed("stop_and_publication_share_one_generation_barrier");
}

void analyticalEnvelope() {
    std::mt19937 rng(81427);
    std::uniform_real_distribution<double> q(-1,1), v(-.2,.2), a(-.4,.4);
    for(int trial=0;trial<250;++trial) {
        ruckig::InputParameter<joints> in;
        for(size_t j=0;j<joints;++j) {
            in.current_position[j]=q(rng); in.current_velocity[j]=v(rng); in.current_acceleration[j]=a(rng);
            in.target_position[j]=q(rng); in.target_velocity[j]=in.target_acceleration[j]=0;
        }
        in.max_velocity.fill(.3); in.max_acceleration.fill(.6); in.max_jerk.fill(2);
        // Alternate normal motion and velocity stops. No analytical result is
        // inferred from the controller's own safety acceptance.
        if(trial%2) {
            in.control_interface=ruckig::ControlInterface::Velocity;
            in.synchronization=ruckig::Synchronization::None;
            // Exercise unequal-duration profiles with a moving tail too;
            // the production stop path always uses zero terminal velocity.
            for(auto& targetVelocity:in.target_velocity) targetVelocity=v(rng);
        }
        ruckig::Ruckig<joints> planner(.005); Trajectory t;
        require(planner.calculate(in,t)>=0,"random trajectory calculated");
        const auto e=envelope(t); require(e.valid,"finite analytical envelope");
        State s;
        for(int i=0;i<=300;++i) {
            t.at_time(t.get_duration()*i/300.0,s.position,s.velocity,s.acceleration);
            for(size_t j=0;j<joints;++j) {
                require(s.position[j]>=e.lower[j]-1e-8 && s.position[j]<=e.upper[j]+1e-8,"dense q enclosed by extrema");
                require(std::abs(s.velocity[j])<=e.velocity[j]+1e-8,"dense velocity enclosed");
                require(std::abs(s.acceleration[j])<=e.acceleration[j]+1e-8,"dense acceleration enclosed");
            }
        }
    }
    passed("250_random_trajectories_526750_joint_samples_inside_analytic_envelopes");
    // A velocity reversal in a constant-acceleration phase: extrema are
    // strictly between its endpoints. The old helper ignores j==0 roots.
    ruckig::InputParameter<joints> in;
    in.current_position.fill(0); in.target_position.fill(0);
    in.current_velocity.fill(.15); in.current_acceleration.fill(-.6);
    in.target_velocity.fill(-.15); in.target_acceleration.fill(0);
    in.max_velocity.fill(.3); in.max_acceleration.fill(.6); in.max_jerk.fill(2);
    in.control_interface=ruckig::ControlInterface::Velocity;
    in.synchronization=ruckig::Synchronization::None;
    ruckig::Ruckig<joints> planner(.005); Trajectory t;
    require(planner.calculate(in,t)>=0,"constant acceleration reversal");
    auto e=envelope(t);
    require(e.valid && std::abs(e.upper[0]-.01875)<1e-9,"interior maximum v^2/(2a) included");
    passed("constant_acceleration_zero_velocity_root_is_checked");
}

void targetRates() {
    for(double hz:{20.,60.,90.,120.}) {
        Rig r; double nextTarget=0; Metrics metrics;
        for(int tick=0;tick<2000;++tick) {
            if(r.time+1e-9>=nextTarget) {
                Vector goal;
                for(size_t j=0;j<joints;++j) goal[j]=.3*std::sin(r.time*1.3+j*.2);
                require(r.target(goal)==Reason::None,"pose stream rate accepted");
                nextTarget+=1/hz;
            }
            State before=r.state; require(r.step(),"pose rate sample"); metrics.check(before,r.state,.005);
        }
        require(r.controller.status().mode==Mode::Following,"continuous stream never needs settle gate");
    }
    passed("20_60_90_120hz_pose_streams_share_200hz_owner");
}
}
int main(int argc,char** argv) {
    try {
        std::cout<<std::setprecision(12);
        initialization(); streaming(argc>1?argv[1]:nullptr); bursts(); ingress(); releaseAndResume();
        timeout(); faultCases(); collisionAndBounds(); jitterAndConcurrency(); stopPublicationBarrier();
        analyticalEnvelope(); targetRates();
        std::cout<<"{\"result\":\"pass\",\"groups\":"<<cases<<",\"hardware_io\":false,\"ruckig\":\"0.9.2\"}\n";
    } catch(const std::exception& e) {
        std::cerr<<"FAIL: "<<e.what()<<'\n'; return 1;
    }
}
