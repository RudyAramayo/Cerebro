#include "ArmSession.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace rob::amber {
namespace {
PositionBounds bounds(const arm::Limits& limits){return {limits.lower,limits.upper};}
}
ArmSession::ArmSession(PhysicalArm arm,Directions directions,arm::Limits limits,arm::Policy owner_policy,
                       BoundaryPolicy boundary_policy,SessionPolicy policy,std::uint64_t writer,
                       MonotonicClock clock,arm::PathGuard guard,FrameWriter sink)
    :arm_(arm),owner_policy_(owner_policy),boundary_policy_(boundary_policy),policy_(policy),writer_(writer),
     clock_(std::move(clock)),sink_(std::move(sink)),guard_(std::move(guard)),boundary_(arm,directions,bounds(limits),boundary_policy,clock_),
     owner_(limits,owner_policy,[this](const arm::Trajectory& t,double from,bool brake){return this->guard(t,from,brake);}),thread_(std::this_thread::get_id()) {
    for(double x:{policy.writer_lease,policy.renewal_margin,policy.maximum_grant,policy.client_timeout,policy.shutdown_timeout})
        if(!std::isfinite(x)||x<=0)throw std::invalid_argument("invalid session timing policy");
    if(!clock_||!sink_||!guard_||writer==0||policy.writer_lease>boundary_policy.maximum_lease||
       policy.renewal_margin>=policy.writer_lease||policy.writer_lease>policy.maximum_grant||
       owner_policy.maximum_tick_gap<=owner_policy.period+boundary_policy.publication_budget)
        throw std::invalid_argument("invalid session authority policy");
}
bool ArmSession::guard(const arm::Trajectory& path,double from,bool braking) {
    auto deadlineFits=[&]{
        if(!braking||!grant_deadline_)return true;
        // Check every proposed sample's braking reserve, not only the previous
        // PVA. Brake duration can grow faster than elapsed time while accelerating.
        const double time=clock_();
        if(!std::isfinite(time)||time<last_event_||
           time+std::max(0.0,path.get_duration()-from)+owner_policy_.maximum_tick_gap+
                boundary_policy_.publication_budget>=*grant_deadline_)return false;
        return true;
    };
    // The external world check consumes time. Both its input and result must
    // still fit the grant; an old successful guard result cannot extend it.
    return deadlineFits()&&guard_(path,from,braking)&&deadlineFits();
}
void ArmSession::fault(SessionReason reason) {
    if(status_.mode!=SessionMode::Fault)status_.reason=reason;
    status_.mode=SessionMode::Fault;status_.client=0;
    owner_.revoke();
    boundary_.revoke(writer_,status_.generation);
}
bool ArmSession::now(double& value) {
    try{value=clock_();}catch(...){fault(SessionReason::Clock);return false;}
    if(!std::isfinite(value)||value<0||(clock_seen_&&value<last_event_)){fault(SessionReason::Clock);return false;}
    last_event_=value;clock_seen_=true;return true;
}
bool ArmSession::resetSource(std::uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!boundary_.resetSource(epoch))return false;
    status_.source_epoch=epoch;
    if(status_.mode==SessionMode::Following||status_.mode==SessionMode::Braking)fault(SessionReason::SourceChanged);
    return true;
}
bool ArmSession::observe(std::uint64_t epoch,const Frame& frame,double captured) {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool accepted=boundary_.observe(arm_,epoch,frame,captured);
    if((status_.mode==SessionMode::Following||status_.mode==SessionMode::Braking)&&
       boundary_.status().mode==BoundaryMode::Fault)fault(SessionReason::Feedback);
    return accepted;
}
bool ArmSession::start(std::uint64_t peer,double expires,bool authorized) {
    std::lock_guard<std::mutex> lock(mutex_);double time;
    if(std::this_thread::get_id()!=thread_){fault(SessionReason::WrongThread);return false;}
    if(!now(time)||status_.shutting_down||status_.mode==SessionMode::Following||status_.mode==SessionMode::Braking||
       peer==0||!authorized||!std::isfinite(expires)||expires<=time||expires-time>policy_.maximum_grant||
       status_.generation==std::numeric_limits<std::uint64_t>::max())return false;
    const auto generation=status_.generation+1;
    const auto writer_expiry=std::min(expires,time+policy_.writer_lease);
    const auto admitted=boundary_.begin({writer_,generation,status_.source_epoch,writer_expiry,authorized});
    if(!admitted)return false;
    status_.generation=generation;
    grant_deadline_=expires;
    if(!owner_.start(generation,admitted->state,admitted->feedback,time)){fault(SessionReason::Feedback);return false;}
    status_.client=peer;status_.grant_expires=expires;status_.writer_expires=writer_expiry;
    status_.mode=SessionMode::Following;status_.reason=SessionReason::None;last_client_=time;
    return true;
}
bool ArmSession::client(std::uint64_t peer,std::uint64_t generation) const {
    return peer!=0&&peer==status_.client&&generation==status_.generation&&status_.mode==SessionMode::Following&&!status_.shutting_down;
}
arm::Reason ArmSession::submit(std::uint64_t peer,std::uint64_t generation,std::uint64_t sequence,double created,const arm::Vector& target) {
    std::lock_guard<std::mutex> lock(mutex_);double time;
    if(!now(time))return arm::Reason::NotFollowing;
    if(generation!=status_.generation)return arm::Reason::WrongGeneration;
    if(!client(peer,generation))return arm::Reason::NotFollowing;
    const auto result=owner_.submit({generation,sequence,created,target},time);
    if(result==arm::Reason::None)last_client_=std::max(last_client_,created);
    return result;
}
bool ArmSession::heartbeat(std::uint64_t peer,std::uint64_t generation,double created) {
    std::lock_guard<std::mutex> lock(mutex_);double time;
    if(!now(time)||!client(peer,generation)||!std::isfinite(created)||created>time||
       time-created>owner_policy_.target_maximum_age||created<=last_client_)return false;
    last_client_=created;return true;
}
void ArmSession::brake(SessionReason reason) {
    if(status_.mode==SessionMode::Following) {
        owner_.stop(status_.generation);status_.mode=SessionMode::Braking;status_.reason=reason;
        status_.client=0; // old client/queued targets cannot resume this generation
    }
}
bool ArmSession::stop(std::uint64_t peer,std::uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!client(peer,generation))return false;
    brake(SessionReason::Stop);return true;
}
bool ArmSession::disconnect(std::uint64_t peer,std::uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!client(peer,generation))return false;
    // Retain the internal writer lease for the authorized controlled stop.
    brake(SessionReason::ClientDisconnected);return true;
}
void ArmSession::shutdown() {
    std::lock_guard<std::mutex> lock(mutex_);double time;
    if(status_.shutting_down)return;
    status_.shutting_down=true;
    if(!now(time))return;
    shutdown_deadline_=time+policy_.shutdown_timeout;
    brake(SessionReason::Shutdown);
    if(status_.mode==SessionMode::Observing||status_.mode==SessionMode::Held)status_.shutdown_complete=true;
}
void ArmSession::transportFault(){std::lock_guard<std::mutex> lock(mutex_);fault(SessionReason::Transport);}
bool ArmSession::tick() {
    std::lock_guard<std::mutex> lock(mutex_);double time;
    if(std::this_thread::get_id()!=thread_){fault(SessionReason::WrongThread);return false;}
    if(!now(time)||status_.mode==SessionMode::Fault)return false;
    if(status_.mode!=SessionMode::Following&&status_.mode!=SessionMode::Braking)return true;
    if(status_.shutting_down&&time>=shutdown_deadline_){fault(SessionReason::ShutdownTimeout);return false;}
    if(time>=status_.grant_expires){fault(SessionReason::GrantExpired);return false;}
    if(time+policy_.renewal_margin>=status_.writer_expires) {
        const double expiry=std::min(status_.grant_expires,time+policy_.writer_lease);
        if(expiry>status_.writer_expires) {
            if(!boundary_.renew(writer_,status_.generation,expiry)){fault(SessionReason::Feedback);return false;}
            status_.writer_expires=expiry;
        }
    }
    if(status_.mode==SessionMode::Following) {
        arm::Trajectory stop_path;
        if(!owner_.stopEnvelope(owner_.status().commanded,stop_path)){fault(SessionReason::UnsafeStop);return false;}
        const double reserve=stop_path.get_duration()+2*owner_policy_.maximum_tick_gap+boundary_policy_.publication_budget;
        if(time+reserve>=status_.grant_expires)brake(SessionReason::GrantEnding);
        else if(time-last_client_>policy_.client_timeout)brake(SessionReason::ClientExpired);
    }
    const auto feedback=boundary_.feedback(writer_,status_.generation);
    const bool success=owner_.tick(time,feedback,[&](const arm::Sample& sample){
        const double publication=clock_();
        const double planning_budget=std::min(boundary_policy_.sample_maximum_age,
            owner_policy_.maximum_tick_gap-owner_policy_.period-boundary_policy_.publication_budget);
        if(!std::isfinite(publication)||publication<time||publication-time>planning_budget)return false;
        return boundary_.publish(writer_,sample,sink_);
    });
    const auto owner=owner_.status();
    if(!success) {fault(owner.reason==arm::Reason::Feedback||owner.reason==arm::Reason::TrackingError?SessionReason::Feedback:SessionReason::Output);return false;}
    if((owner.mode==arm::Mode::Braking||owner.mode==arm::Mode::Held)&&status_.mode==SessionMode::Following) {
        status_.mode=SessionMode::Braking;status_.client=0;
        switch(owner.reason) {
            case arm::Reason::Expired:status_.reason=SessionReason::TargetExpired;break;
            case arm::Reason::PathRejected:status_.reason=SessionReason::PathRejected;break;
            case arm::Reason::UnsafeStop:status_.reason=SessionReason::UnsafeStop;break;
            default:status_.reason=SessionReason::Stop;break;
        }
    }
    if(owner.mode==arm::Mode::Held) {
        status_.mode=SessionMode::Held;status_.client=0;
        boundary_.revoke(writer_,status_.generation);
        if(status_.shutting_down)status_.shutdown_complete=true;
    }
    return true;
}
SessionStatus ArmSession::status() const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto status=status_;status.owner=owner_.status();status.boundary=boundary_.status();return status;
}
} // namespace rob::amber
