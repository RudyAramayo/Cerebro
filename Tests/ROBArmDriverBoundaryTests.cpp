// Fake clock, frame sink and synthetic receiver timestamps only. No hardware I/O.
#include "ArmDriverBoundary.hpp"
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <thread>
#include <vector>
namespace wire=rob::amber;
namespace motion=rob::arm;
namespace {
int cases=0;
void require(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
void passed(const char* label){++cases;std::cout<<"{\"test\":\""<<label<<"\",\"passed\":true}\n";}
wire::PositionBounds bounds(){wire::PositionBounds b;b.lower.fill(-2.09);b.upper.fill(2.09);return b;}
wire::Directions signs(){return {1,1,1,1,1,1,1};}
wire::BoundaryPolicy policy(){return {.1,.06,.2,.0004,5,64,0x01,2,.004,.01,10};}
wire::Frame reply(std::size_t j,std::uint16_t word=0,std::uint8_t mode=2,std::uint8_t tag=1){
    return {static_cast<std::uint32_t>(0x91+j),8,{tag,static_cast<std::uint8_t>(word>>8),static_cast<std::uint8_t>(word),0,0,0,0,mode}};
}
struct Rig {
    double time{};
    bool clockThrows{};
    wire::ArmDriverBoundary boundary{wire::PhysicalArm::Right,signs(),bounds(),policy(),[this]{
        if(clockThrows)throw std::runtime_error("injected clock failure");return time;
    }};
    std::uint64_t epoch{1},generation{1},owner{101};
    std::vector<wire::Frame> frames;
    explicit Rig(bool ready=true){require(boundary.resetSource(epoch),"source start");if(ready)warm();}
    bool observe(wire::PhysicalArm arm,std::uint64_t source,const wire::Frame& frame,double received,double now){
        time=now;return boundary.observe(arm,source,frame,received);
    }
    void feed(double now,int omit=-1,std::uint16_t word=0,std::uint8_t mode=2){
        time=now;
        for(std::size_t j=0;j<7;++j)if(static_cast<int>(j)!=omit)
            require(boundary.observe(wire::PhysicalArm::Right,epoch,reply(j,word,mode),time),"synthetic feedback accepted");
    }
    void warm(){const double start=time;for(int i=1;i<=6;++i)feed(start+i*.05);}
    std::optional<wire::StationaryStart> begin(double seconds=5){
        return boundary.begin({owner,generation,epoch,time+seconds,true});
    }
    motion::Sample sample(){motion::Sample s;s.generation=generation;s.sequence=1;s.time=time;s.state.position.fill(.1);return s;}
    bool publish(motion::Sample sample,const wire::FrameWriter& writer={}){
        auto sink=writer?writer:wire::FrameWriter([&](const wire::Route& route,const wire::Frame& frame,double deadline){
            require(route.can_interface=="can10" && time<deadline,"correct route and pre-write deadline");
            frames.push_back(frame);time+=.00002;return wire::WriteResult::Accepted;
        });
        return boundary.publish(owner,sample,sink);
    }
};
void startupAndStationarity(){
    Rig r(false);require(!r.begin(),"cold source cannot start");
    for(int i=1;i<=6;++i)r.feed(i*.05,6);
    require(!r.begin(),"one missing joint prevents start");
    r.warm();auto c=wire::WriterClaim{r.owner,1,1,r.time+5,false};
    require(!r.boundary.begin(c),"fresh samples do not manufacture authorization");
    c.stationary_start_authorized=true;c.source_epoch=2;
    require(!r.boundary.begin(c),"wrong source cannot start");
    c.source_epoch=1;c.expires_at=r.time+11;
    require(!r.boundary.begin(c),"bounded writer lease");
    const auto start=r.begin();require(bool(start),"explicit authorized stationary observation starts");
    require(start->feedback.authority_valid&&start->feedback.position_mode,"simulated admitted snapshot");
    require(r.frames.empty(),"begin never emits");
    c={202,2,1,r.time+5,true};require(!r.boundary.begin(c),"second logical writer rejected");
    require(r.boundary.status().owner==101,"first writer retained");
    passed("fresh_all_joint_stationary_observations_explicit_grant_and_single_claim");

    Rig drift(false);
    for(int i=1;i<=6;++i)drift.feed(i*.05,-1,static_cast<std::uint16_t>(i));
    require(!drift.begin(),"moving position history cannot claim zero derivatives");
    drift.warm();require(bool(drift.begin()),"new quiet window qualifies only after observations");
    Rig gap(false);gap.feed(.05);gap.feed(.10);gap.feed(.30);gap.feed(.35);gap.feed(.40);
    require(!gap.begin(),"gap breaks stationary window");gap.feed(.45);gap.feed(.50);require(bool(gap.begin()),"complete new window");
    passed("stationary_range_and_sample_gap_admission");
}
void inputAndWatermark(){
    Rig r;const auto t=r.time;
    require(!r.observe(wire::PhysicalArm::Left,1,reply(0),t+.01,t+.01),"wrong physical arm rejected");
    require(!r.observe(wire::PhysicalArm::Right,2,reply(0),t+.02,t+.02),"foreign source epoch rejected");
    require(!r.observe(wire::PhysicalArm::Right,1,reply(0),t+.04,t+.03),"future arrival rejected");
    require(!r.observe(wire::PhysicalArm::Right,1,reply(0),t,t+.03),"duplicate arrival rejected");
    require(!r.observe(wire::PhysicalArm::Right,1,reply(0),t-.2,t+.03),"stale arrival rejected");
    require(!r.observe(wire::PhysicalArm::Right,1,reply(0,0,2,99),t+.04,t+.04),"unknown reply tag invalidates joint");
    require(!r.observe(wire::PhysicalArm::Right,1,reply(0),t+.035,t+.05),"invalidation preserves timestamp watermark");
    r.time=t+.05;require(!r.begin(),"invalidated feedback cannot initialize");
    r.warm();require(bool(r.begin()),"new observations can initialize");
    passed("foreign_source_future_stale_duplicate_and_invalidated_feedback_replay");
}
void staleAndMode(){
    for(int scenario=0;scenario<3;++scenario){
        Rig r;require(bool(r.begin()),"claim");const auto t=r.time;
        if(scenario==0){r.feed(t+.05,6);r.feed(t+.10,6);r.feed(t+.15,6);}
        if(scenario==1){r.feed(t+.01,-1,0,3);}
        if(scenario==2){r.time=t+.01;require(!r.boundary.observe(wire::PhysicalArm::Right,1,reply(6,0,2,44),r.time),"tag rejected");}
        require(!r.boundary.feedback(r.owner,r.generation).authority_valid,"feedback fails closed");
        require(r.boundary.status().fault==wire::BoundaryFault::Feedback,"feedback fault latched");
        require(!r.publish(r.sample())&&r.frames.empty(),"no output after feedback loss");
    }
    passed("one_stale_joint_fresh_other_joints_mode_change_unknown_tag_latch");
}
void sourceRestartAndRearm(){
    Rig r;require(bool(r.begin()),"claim");r.time+=.005;const auto old=r.sample();require(r.publish(old),"first batch");
    r.time+=.005;require(r.boundary.resetSource(2),"receiver source reset");r.epoch=2;
    require(r.boundary.status().fault==wire::BoundaryFault::SourceChanged,"source reset revokes claim");
    require(!r.publish(old),"old writer cannot continue");
    require(!r.boundary.observe(wire::PhysicalArm::Right,1,reply(0),r.time),"old-source feedback rejected");
    require(!r.begin(),"source reset requires fresh history");
    r.warm();require(!r.begin(),"generation cannot be reused");++r.generation;
    require(bool(r.begin()),"fresh explicit new source generation");
    const auto before=r.frames.size();require(!r.boundary.publish(r.owner,old,[&](const wire::Route&,const wire::Frame&,double){return wire::WriteResult::Accepted;}),"old sample generation rejected");
    require(r.boundary.status().mode==wire::BoundaryMode::Claimed&&r.frames.size()==before,"foreign sample cannot revoke current owner");
    passed("source_restart_flushes_samples_and_requires_new_generation_and_history");
}
void transientFeedbackLoss(){
    for(int scenario=0;scenario<5;++scenario){
        Rig r;require(bool(r.begin(scenario==4?.08:5)),"claim before transient loss");
        const auto t=r.time;
        if(scenario<3){
            r.time=t+.01;
            const auto bad=reply(3,scenario==2?20000:0,scenario==0?3:2,scenario==1?99:1);
            const bool accepted=r.boundary.observe(wire::PhysicalArm::Right,1,bad,r.time);
            require(accepted==(scenario==0),"raw mode accepted separately from admission");
        }
        // No publish/feedback call intervenes: receive alone must latch the
        // fault, including a complete recovery burst after a silent outage.
        r.feed(t+(scenario==3?.11:scenario==4?.09:.02));
        const auto expected=scenario==4?wire::BoundaryFault::LeaseExpired:wire::BoundaryFault::Feedback;
        require(r.boundary.status().fault==expected,"transient loss cannot be hidden before next owner tick");
        require(!r.publish(r.sample())&&r.frames.empty(),"old writer remains silent after receive recovery");
        ++r.generation;require(!r.begin(),"recovery burst is not a new stationary window");
        r.warm();require(bool(r.begin()),"new stationary window and explicit new grant can rearm");
    }
    Rig primary;require(bool(primary.begin()),"claim for fault diagnostic");
    require(primary.boundary.revoke(101,1),"revoke first");
    primary.time=std::numeric_limits<double>::quiet_NaN();
    require(!primary.boundary.feedback(101,1).authority_valid,"later clock invalid");
    require(primary.boundary.status().fault==wire::BoundaryFault::Revoked,"first failure retained");
    passed("receive_recovery_cannot_mask_mode_tag_range_outage_or_expired_lease");
}
void partialWrites(){
    for(int kind=0;kind<5;++kind)for(int fail=0;fail<7;++fail){
        Rig r;require(bool(r.begin()),"claim");r.time+=.005;const auto sample=r.sample();int call=0;
        auto writer=[&](const wire::Route&,const wire::Frame&,double deadline){
            const int index=call++;
            if(index==fail){
                if(kind==0)return wire::WriteResult::Rejected;
                if(kind==1)return wire::WriteResult::Uncertain;
                if(kind==2)throw std::runtime_error("injected write exception");
                if(kind==3)r.time=deadline+.00001;
                if(kind==4)r.time-=.002;
            }else r.time+=.00001;
            return wire::WriteResult::Accepted;
        };
        require(!r.publish(sample,writer),"injected output fault");const auto st=r.boundary.status();
        require(st.last_batch_attempts==static_cast<std::size_t>(fail+1),"attempted prefix exact");
        require(st.last_batch_accepted==static_cast<std::size_t>(fail+(kind>=3?1:0)),"accepted prefix exact");
        const auto expected=kind==0?wire::BoundaryFault::WriteRejected:kind<=2?wire::BoundaryFault::WriteUncertain:
                            kind==3?wire::BoundaryFault::Deadline:wire::BoundaryFault::Clock;
        require(st.mode==wire::BoundaryMode::Fault&&st.fault==expected,"precise fault reason");
        require(st.published_batches==0&&st.last_write_result.has_value(),"uncertain batch not counted completed");
        const int attempts=call;require(!r.publish(sample,writer)&&call==attempts,"no automatic retry");
        r.time+=.02;++r.generation;require(!r.begin(),"pre-fault stationary history cannot rearm");
    }
    passed("35_partial_rejected_uncertain_exception_late_and_clock_faults_no_retry");
}
void metadataAndLease(){
    for(int kind=0;kind<6;++kind){
        Rig r;require(bool(r.begin()),"claim");r.time+=.005;auto s=r.sample();
        if(kind==0)s.time=r.time+.01;
        if(kind==1)s.time=r.time-.02;
        if(kind==2)s.state.velocity[3]=std::numeric_limits<double>::quiet_NaN();
        if(kind==3)s.state.position[6]=3;
        if(kind==4){s.braking=true;s.sequence=1;}
        if(kind==5)s.time=std::numeric_limits<double>::infinity();
        require(!r.publish(s)&&r.frames.empty(),"bad owner sample cannot reach sink");
    }
    Rig replay;require(bool(replay.begin()),"claim");replay.time+=.005;auto s=replay.sample();s.sequence=2;
    require(replay.publish(s),"first sample");replay.time+=.005;require(!replay.publish(s),"same sample timestamp cannot replay");
    require(replay.frames.size()==7,"no replay output");
    Rig expiry;require(bool(expiry.begin(.1)),"short claim");expiry.time+=.11;
    require(!expiry.publish(expiry.sample())&&expiry.boundary.status().fault==wire::BoundaryFault::LeaseExpired,"writer lease expiry faults");
    expiry.warm();require(!expiry.boundary.renew(101,1,expiry.time+2),"expired lease never revived by renewal");
    Rig renew;require(bool(renew.begin(.5)),"renewable claim");renew.time+=.01;
    require(renew.boundary.renew(101,1,renew.time+1),"same fresh writer can extend bounded lease");
    require(!renew.boundary.renew(202,1,renew.time+2),"foreign owner cannot renew");
    require(!renew.boundary.renew(101,1,renew.time+11),"overlong renewal rejected");
    for(int kind=0;kind<3;++kind){
        Rig clock;require(bool(clock.begin()),"claim before clock loss");auto s=clock.sample();
        if(kind==0)clock.clockThrows=true;
        if(kind==1)clock.time=std::numeric_limits<double>::infinity();
        if(kind==2)clock.time=std::numeric_limits<double>::quiet_NaN();
        require(!clock.publish(s)&&clock.frames.empty()&&clock.boundary.status().fault==wire::BoundaryFault::Clock,"failed clock cannot publish");
    }
    passed("sample_time_replay_nan_bounds_and_bounded_nonreviving_writer_leases");
}
void stopAndThread(){
    Rig r;require(bool(r.begin()),"claim");r.time+=.005;auto s=r.sample();require(r.publish(s),"normal sample");
    r.time+=.005;s.time=r.time;s.braking=true;s.sequence=0;require(r.publish(s),"controlled brake frame allowed");
    r.time+=.005;s.time=r.time;s.braking=false;s.sequence=2;require(!r.publish(s),"old following state cannot return after brake latch");
    Rig revoke;require(bool(revoke.begin()),"claim");require(!revoke.boundary.revoke(202,1),"foreign revoke rejected");
    require(revoke.boundary.revoke(101,1),"writer revoke latches");require(!revoke.publish(revoke.sample()),"revoked writer silent");
    Rig wrong;require(bool(wrong.begin()),"claim");wrong.time+=.005;const auto sample=wrong.sample();bool emitted=true;
    std::thread worker([&]{emitted=wrong.publish(sample);});worker.join();
    require(!emitted&&wrong.frames.empty()&&wrong.boundary.status().fault==wire::BoundaryFault::WrongThread,"wrong publication thread faults");
    passed("brake_latch_explicit_revoke_and_publication_thread_ownership");
}
void publicationBarrier(){
    Rig r;require(bool(r.begin()),"claim for concurrent revoke");r.time+=.005;
    std::mutex mutex;std::condition_variable changed;
    bool entered=false,release=false;
    std::atomic<bool> revokeReturned{false},observeReturned{false};
    bool revokeAccepted=false,observeAccepted=false,blocked=false;
    auto waitForSink=[&]{std::unique_lock<std::mutex> lock(mutex);changed.wait(lock,[&]{return entered;});};
    std::thread revoker([&]{waitForSink();revokeAccepted=r.boundary.revoke(101,1);revokeReturned=true;});
    const double receivedBeforePublication=r.time;
    std::thread observer([&]{waitForSink();observeAccepted=r.boundary.observe(wire::PhysicalArm::Right,1,reply(0),receivedBeforePublication);observeReturned=true;});
    std::thread unblock([&]{
        waitForSink();
        // Deliberately blocked fake I/O tests ordering, not real deadline
        // preemption or a recommendation for blocking actuator callbacks.
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        blocked=!revokeReturned.load()&&!observeReturned.load();
        {std::lock_guard<std::mutex> lock(mutex);release=true;}changed.notify_all();
    });
    int writes=0;
    const bool complete=r.publish(r.sample(),[&](const wire::Route&,const wire::Frame&,double){
        if(writes++==0){
            std::unique_lock<std::mutex> lock(mutex);entered=true;changed.notify_all();
            changed.wait(lock,[&]{return release;});
        }
        r.time+=.00002;return wire::WriteResult::Accepted;
    });
    revoker.join();observer.join();unblock.join();
    require(complete&&writes==7&&blocked,"in-flight seven-frame transaction precedes revoke acknowledgement");
    require(revokeAccepted&&observeAccepted&&r.boundary.status().fault==wire::BoundaryFault::Revoked,"queued receive samples current clock after the lock without a false reversal");
    r.time=.31;
    require(!r.publish(r.sample(),[&](const wire::Route&,const wire::Frame&,double){++writes;return wire::WriteResult::Accepted;})&&writes==7,"no output after revoke returns");
    passed("concurrent_receive_and_revoke_serialize_with_seven_frame_publication");
}
void ownerIntegration(){
    Rig r;auto start=r.begin();require(bool(start),"boundary claim");
    motion::Limits l;l.lower.fill(-2.09);l.upper.fill(2.09);l.velocity.fill(.3);l.acceleration.fill(.6);l.jerk.fill(2);
    motion::ContinuousArmController owner(l,{.005,.015,.15,.1,.05},[](const motion::Trajectory&,double,bool){return true;});
    require(owner.start(1,start->state,start->feedback,r.time),"controller starts from admitted simulated snapshot");
    std::array<std::uint16_t,7> actual{};std::uint64_t sequence=0;double nominal=r.time;std::size_t ticks=0;
    auto tick=[&](bool target){
        nominal+=.005;r.time=nominal;++ticks;
        if(ticks%10==1)for(std::size_t j=0;j<7;++j)
            require(r.boundary.observe(wire::PhysicalArm::Right,1,reply(j,actual[j]),nominal),"20 Hz ideal receive");
        if(ticks%100==0)require(r.boundary.renew(101,1,nominal+5),"bounded heartbeat renewal");
        if(target&&ticks%10==1){motion::Vector q{};q.fill(.65*std::sin(nominal));require(owner.submit({1,++sequence,nominal,q},nominal)==motion::Reason::None,"latest target");}
        return owner.tick(nominal,r.boundary.feedback(101,1),[&](const motion::Sample& sample){
            return r.publish(sample,[&](const wire::Route&,const wire::Frame& f,double deadline){
                require(r.time<deadline,"fake write before deadline");r.frames.push_back(f);
                actual[f.identifier-0x11]=std::uint16_t((std::uint16_t(f.data[1])<<8)|f.data[2]);
                r.time+=.00002;return wire::WriteResult::Accepted;
            });
        });
    };
    for(int i=0;i<1000;++i)require(tick(true),"continuous owner/boundary replay");
    require(owner.stop(1),"owner Stop");
    for(int i=0;i<400&&owner.status().mode!=motion::Mode::Held;++i)require(tick(false),"reviewed simulated brake");
    require(owner.status().mode==motion::Mode::Held,"owner held after controlled brake");
    require(r.frames.size()==ticks*7 && r.boundary.status().published_batches==ticks,"complete seven-frame batches");
    require(owner.submit({1,++sequence,nominal,{}},nominal)==motion::Reason::NotFollowing,"stopped session cannot resume target");
    std::cout<<"{\"metrics\":\"owner_fake_driver_stop\",\"ticks\":"<<ticks<<",\"frames\":"<<r.frames.size()<<",\"targets\":"<<sequence-1<<",\"hardware_io\":false}\n";
    passed("owner_to_fake_driver_20hz_feedback_lease_renewal_and_controlled_stop");
}
} // namespace
int main(){try{startupAndStationarity();inputAndWatermark();staleAndMode();sourceRestartAndRearm();transientFeedbackLoss();partialWrites();metadataAndLease();stopAndThread();publicationBarrier();ownerIntegration();
    std::cout<<"{\"passed\":"<<cases<<",\"failed\":0,\"hardware_io\":false}\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
