// Inert lifecycle integration: synthetic quantized feedback, fake clock/sink.
#include "ArmSession.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <thread>
namespace wire=rob::amber;
namespace motion=rob::arm;
namespace {
int cases=0;
void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
void passed(const char* name){++cases;std::cout<<"{\"test\":\""<<name<<"\",\"passed\":true}\n";}
motion::Limits limits(){motion::Limits l;l.lower.fill(-2.09);l.upper.fill(2.09);l.velocity.fill(.3);l.acceleration.fill(.6);l.jerk.fill(2);return l;}
wire::SessionPolicy policy(){return {.12,.06,30,.08,2};}
struct Rig {
    double time{};std::uint64_t epoch{1},sequence{},peer{21};
    std::array<std::uint16_t,7> actual{};
    std::size_t writes{},ticks{};int fail_at{-1};bool guard_ok{true},route_ok{true};double guard_delay{};
    wire::ArmSession session;
    explicit Rig(wire::SessionPolicy p=policy()):session(wire::PhysicalArm::Right,{1,1,1,1,1,1,1},limits(),
       {.005,.015,.15,.1,.05},{.1,.06,.2,.0004,5,64,1,2,.004,.01,10},p,101,
       [this]{return time;},[this](const motion::Trajectory&,double,bool braking){if(braking){time+=guard_delay;guard_delay=0;}return guard_ok&&(braking||route_ok);},
       [this](const wire::Route&,const wire::Frame& f,double deadline){
           require(time<deadline,"write before deadline");
           const auto attempt=writes++;
           if(static_cast<int>(attempt)==fail_at)return wire::WriteResult::Uncertain;
           actual.at(f.identifier-0x11)=std::uint16_t((std::uint16_t(f.data[1])<<8)|f.data[2]);
           return wire::WriteResult::Accepted;
       }){require(session.resetSource(epoch),"new source");warm();}
    void feed(){for(std::size_t j=0;j<7;++j){wire::Frame f{static_cast<std::uint32_t>(0x91+j),8,
       {1,static_cast<std::uint8_t>(actual[j]>>8),static_cast<std::uint8_t>(actual[j]),0,0,0,0,2}};
       require(session.observe(epoch,f,time),"feedback accepted");}}
    void warm(){for(int i=0;i<6;++i){time+=.05;feed();}}
    void start(double grant=20){require(session.start(peer,time+grant,true),"authorized start");}
    bool tick(bool target=true,bool heartbeat=false){time+=.005;++ticks;if(ticks%10==1)feed();
       if(target&&session.status().mode==wire::SessionMode::Following){motion::Vector q{};q.fill(.65*std::sin(time));
           require(session.submit(peer,session.status().generation,++sequence,time,q)==motion::Reason::None,"target accepted");}
       if(heartbeat&&session.status().mode==wire::SessionMode::Following)require(session.heartbeat(peer,session.status().generation,time),"fresh heartbeat");
       return session.tick();}
    void moving(){start();for(int i=0;i<80;++i)require(tick(),"moving samples");
       require(std::abs(session.status().owner.commanded.velocity[0])>.01,"fixture moving");}
    void finish(){for(int i=0;i<500&&session.status().mode!=wire::SessionMode::Held;++i)require(tick(false),"controlled braking samples");
       require(session.status().mode==wire::SessionMode::Held,"held");}
};
void startup(){Rig r;require(r.session.status().mode==wire::SessionMode::Observing,"passive startup");
    require(!r.session.start(21,r.time+10,false),"quiet feedback cannot grant authority");
    require(!r.session.start(21,r.time+31,true),"bounded grant");
    require(r.tick(false)&&r.writes==0,"passive tick no output");r.start();
    require(!r.session.start(22,r.time+10,true),"no takeover");
    require(r.session.submit(22,r.session.status().generation,1,r.time,{})==motion::Reason::NotFollowing,"wrong client rejected");
    require(!r.session.stop(22,r.session.status().generation)&&!r.session.disconnect(22,r.session.status().generation),"foreign client cannot change session");
    passed("passive_start_explicit_bounded_grant_and_client_identity");}
void disconnect(){Rig r;r.moving();const auto before=r.writes;const double lease=r.session.status().writer_expires;
    require(r.session.disconnect(21,r.session.status().generation),"disconnect");
    require(r.session.submit(21,r.session.status().generation,++r.sequence,r.time,{})==motion::Reason::NotFollowing,"old client target rejected");
    require(!r.session.heartbeat(21,r.session.status().generation,r.time),"old heartbeat rejected");r.finish();
    require(r.writes>before&&r.time>lease,"controlled stop outlives client and original internal lease");
    require(r.session.status().reason==wire::SessionReason::ClientDisconnected,"reason retained");
    const auto held=r.writes;require(r.tick(false)&&r.writes==held,"no further output or implicit restart");
    require(!r.session.start(22,r.time+10,true),"old quiet history cannot restart");r.warm();r.peer=22;r.start();
    require(r.session.status().generation==2&&r.session.submit(21,r.session.status().generation,999,r.time,{})==motion::Reason::NotFollowing,"new generation/new client");
    passed("disconnect_brakes_with_internal_lease_then_requires_new_history_and_grant");}
void expiry(){Rig r;r.moving();for(int i=0;i<18;++i)require(r.tick(false),"client timeout braking");
    require(r.session.status().reason==wire::SessionReason::ClientExpired,"heartbeat timeout");r.finish();
    Rig h;h.moving();for(int i=0;i<32;++i)require(h.tick(false,true),"heartbeat cannot rejuvenate target");
    require(h.session.status().mode==wire::SessionMode::Braking&&h.session.status().reason==wire::SessionReason::TargetExpired,"target separately expires");h.finish();
    passed("client_liveness_and_target_freshness_expire_independently");}
void grant(){Rig r;r.start(1.5);for(int i=0;i<400&&r.session.status().mode!=wire::SessionMode::Held;++i)require(r.tick(),"grant controlled stop");
    require(r.session.status().mode==wire::SessionMode::Held&&r.session.status().reason==wire::SessionReason::GrantEnding,"brakes before grant deadline");
    require(r.time<r.session.status().grant_expires,"held before expiry");
    Rig hard;hard.start(.5);hard.time+=.51;require(!hard.session.tick()&&hard.writes==0,"no write after hard expiry");
    require(hard.session.status().reason==wire::SessionReason::GrantExpired,"hard deadline reason");
    passed("grant_ending_reserves_brake_time_and_hard_expiry_has_no_output");}
void shutdown(){Rig r;r.moving();r.session.shutdown();require(!r.session.heartbeat(21,r.session.status().generation,r.time),"shutdown rejects ingress");r.finish();
    require(r.session.status().shutdown_complete,"controlled shutdown complete");r.warm();require(!r.session.start(22,r.time+5,true),"shutdown irreversible for process");
    auto p=policy();p.shutdown_timeout=.01;Rig shortStop(p);shortStop.moving();shortStop.session.shutdown();
    require(shortStop.tick(false),"first stop sample");shortStop.time+=.02;const auto n=shortStop.writes;
    require(!shortStop.session.tick()&&shortStop.writes==n,"shutdown deadline no later write");
    require(shortStop.session.status().reason==wire::SessionReason::ShutdownTimeout&&!shortStop.session.status().shutdown_complete,"timeout not misreported as stopped");
    Rig idle;idle.session.shutdown();require(idle.session.status().shutdown_complete&&idle.writes==0,"passive shutdown immediate");
    passed("controlled_shutdown_and_explicit_incomplete_timeout");}
void faults(){for(int i=0;i<7;++i){Rig r;r.start();r.fail_at=i;require(!r.tick(),"partial failure");
       const auto s=r.session.status();require(s.mode==wire::SessionMode::Fault&&s.boundary.last_batch_attempts==std::size_t(i+1)&&s.boundary.last_batch_accepted==std::size_t(i),"exact partial diagnostics");
       const auto n=r.writes;require(!r.tick(false)&&r.writes==n,"no retry");}
    Rig transport;transport.moving();transport.session.transportFault();const auto n=transport.writes;
    require(!transport.tick(false)&&transport.writes==n&&transport.session.status().reason==wire::SessionReason::Transport,"transport loss latches");
    passed("seven_partial_output_faults_and_transport_loss_latch_without_retries");}
void sourceAndTime(){Rig r;r.moving();require(r.session.resetSource(++r.epoch),"new receiver source");
    require(r.session.status().reason==wire::SessionReason::SourceChanged&&!r.tick(false),"source loss stops writes");
    r.warm();r.peer=22;r.start();require(r.session.status().generation==2,"explicit new source restart");
    require(r.session.submit(22,r.session.status().generation,100,r.time-.2,{})==motion::Reason::InvalidTarget,"buffered target remains stale");
    require(!r.session.heartbeat(22,r.session.status().generation,r.time-.2)&&!r.session.heartbeat(22,r.session.status().generation,r.time+.01),"old and future heartbeats rejected");
    r.time+=.005;require(r.session.submit(22,r.session.status().generation,100,r.time,{})==motion::Reason::None,"fresh sequence");
    require(r.session.submit(22,r.session.status().generation,100,r.time,{})==motion::Reason::OldSequence,"sequence replay rejected");
    r.time-=.01;require(!r.session.tick()&&r.session.status().reason==wire::SessionReason::Clock,"clock reversal latches");
    passed("source_restart_timestamp_watermarks_replay_and_clock_reversal");}
void threadAndGuard(){Rig r;r.start();bool result=true;std::thread t([&]{result=r.session.tick();});t.join();
    require(!result&&r.writes==0&&r.session.status().reason==wire::SessionReason::WrongThread,"wrong owner thread");
    Rig g;g.moving();g.guard_ok=false;const auto n=g.writes;require(!g.tick()&&g.writes==n,"revoked world guard blocks proposed and brake path");
    passed("owner_thread_and_missing_valid_world_guard_fail_closed");}
void candidateDeadline(){Rig r;r.start(.05);r.time+=.015;motion::Vector q{};q.fill(1);
    require(r.session.submit(21,1,1,r.time,q)==motion::Reason::None,"short-grant target admitted for planning");
    require(r.session.tick(),"unsafe candidate replaced by stationary stop");
    const auto s=r.session.status();
    require(s.mode==wire::SessionMode::Held&&s.reason==wire::SessionReason::UnsafeStop,"candidate reserve rejects acceleration that exceeds grant");
    require(s.owner.commanded.position[0]==0&&s.owner.commanded.velocity[0]==0,"rejected acceleration never published");
    passed("every_candidate_brake_reserve_checked_against_short_grant_deadline");}
void stationaryReasonsAndGeneration(){Rig r;r.start();r.route_ok=false;require(r.tick(),"rejected path brakes from rest");
    require(r.session.status().mode==wire::SessionMode::Held&&r.session.status().reason==wire::SessionReason::PathRejected,"zero-duration path rejection reason retained");
    r.route_ok=true;r.warm();r.start();
    require(r.session.submit(21,1,999,r.time,{})==motion::Reason::WrongGeneration,"same-client old-grant packet cannot acquire new generation");
    require(!r.session.heartbeat(21,1,r.time)&&!r.session.stop(21,1)&&!r.session.disconnect(21,1),"all prior-generation ingress rejected");
    for(int i=0;i<32;++i)require(r.tick(false,true),"stationary heartbeat without target");
    require(r.session.status().mode==wire::SessionMode::Held&&r.session.status().reason==wire::SessionReason::TargetExpired,"zero-duration target expiry reason retained");
    passed("zero_duration_stop_reasons_and_same_client_previous_grant_replay");}
void guardLatency(){for(double grant:{.09,10.0}){Rig r;r.start(grant);r.guard_delay=.02;r.time+=.015;
    motion::Vector q{};q.fill(1);require(r.session.submit(21,1,1,r.time,q)==motion::Reason::None,"target before delayed guard");
    require(!r.session.tick()&&r.writes==0,"guard latency cannot publish a sample that cannot meet next tick");
    require(r.session.status().mode==wire::SessionMode::Fault,"delayed guard latches fault");}
    passed("post_guard_deadline_and_total_planning_age_reject_delayed_candidate");}
}
int main(){try{startup();disconnect();expiry();grant();shutdown();faults();sourceAndTime();threadAndGuard();candidateDeadline();stationaryReasonsAndGeneration();guardLatency();
    std::cout<<"{\"passed\":"<<cases<<",\"failed\":0,\"hardware_io\":false}\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
