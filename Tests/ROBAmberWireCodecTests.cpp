// Entirely inert: no CAN/LCM/UDP sockets, mode commands or vendor code execution.
#include "AmberWireCodec.hpp"
#include "ContinuousArmController.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
namespace wire = rob::amber;
namespace motion = rob::arm;
namespace {
int cases = 0;
constexpr double quantum = 1.0 / (wire::position_counts_per_degree * wire::radians_to_degrees);
void require(bool test, const char* message) { if (!test) throw std::runtime_error(message); }
void passed(const char* message) {
    ++cases; std::cout << "{\"test\":\"" << message << "\",\"passed\":true}\n";
}
wire::Directions signs() { return {1,1,1,1,1,1,1}; }
wire::PositionBounds bounds() {
    wire::PositionBounds value;
    value.lower.fill(-2.09); value.upper.fill(2.09);
    return value; // illustrative offline profile, not commissioning
}
wire::Frame reply(std::uint16_t position, std::uint16_t velocity=0, std::uint16_t current=0) {
    return {0x91,8,{0x01,static_cast<std::uint8_t>(position>>8),static_cast<std::uint8_t>(position),
                  static_cast<std::uint8_t>(velocity>>8),static_cast<std::uint8_t>(velocity),
                  static_cast<std::uint8_t>(current>>8),static_cast<std::uint8_t>(current),2}};
}
wire::JointVector decodeRecorded(const wire::PositionBatch& batch, const wire::Directions& direction) {
    wire::JointVector result{};
    for (std::size_t j=0; j<wire::joint_count; ++j) {
        // An ideal simulated drive echoes the recorded position word. This is
        // not a vendor firmware reply, measured motion or a verified reply tag.
        const auto& f=batch.frames[j];
        auto response=reply((std::uint16_t(f.data[1])<<8)|f.data[2]);
        response.identifier=0x91+static_cast<std::uint32_t>(j);
        auto decoded=wire::decodeJointDiagnostic(response,direction[j]);
        require(bool(decoded),"simulated reply decodes");
        result[j]=decoded->position_radians;
    }
    return result;
}
void routingAndGoldenFrames() {
    require(wire::route(wire::PhysicalArm::Right)->can_interface=="can10","physical RIGHT CAN10");
    require(wire::route(wire::PhysicalArm::Right)->vendor_directory=="L-10","RIGHT vendor L");
    require(wire::route(wire::PhysicalArm::Right)->vendor_lcm_prefix=="Left_","RIGHT LCM prefix");
    require(wire::route(wire::PhysicalArm::Left)->can_interface=="can11","physical LEFT CAN11");
    require(wire::route(wire::PhysicalArm::Left)->vendor_directory=="R-11","LEFT vendor R");
    require(wire::route(wire::PhysicalArm::Left)->vendor_lcm_prefix=="Right_","LEFT LCM prefix");
    require(!wire::route(static_cast<wire::PhysicalArm>(99)),"invalid arm rejected");
    // Independent hand-derived words from observed 128 counts/degree and
    // negative+65535 convention; angles are radians, not already degrees.
    const wire::JointVector q{0,1,-1,.5,-.5,2,-2};
    const std::array<std::uint16_t,7> expected{0x0000,0x1ca5,0xe35a,0x0e52,0xf1ad,0x394b,0xc6b4};
    for (auto arm : {wire::PhysicalArm::Right,wire::PhysicalArm::Left}) {
        const auto batch=wire::encodePositions(arm,q,signs(),bounds());
        require(bool(batch),"golden batch accepted");
        require(batch->destination.physical_arm==arm,"side retained");
        for (std::size_t j=0;j<7;++j) {
            const auto& f=batch->frames[j];
            require(f.identifier==0x11+j && f.length==3,"joint ID and length");
            require(f.data[0]==0x40 && f.data[1]==(expected[j]>>8) && f.data[2]==(expected[j]&255),"golden bytes");
            for(std::size_t k=3;k<8;++k) require(f.data[k]==0,"unused bytes initialized");
        }
    }
    passed("physical_arm_routes_and_fourteen_exact_golden_position_frames");
}
void signedBoundaries() {
    const std::array<std::uint16_t,8> words{0,1,32767,32768,32769,65533,65534,65535};
    const std::array<std::int32_t,8> expected{0,1,32767,32768,-32766,-2,-1,0};
    for (std::size_t i=0;i<words.size();++i) {
        const auto d=wire::decodeJointDiagnostic(reply(words[i],words[i],words[i]),1);
        require(bool(d),"boundary decodes");
        require(d->position_native_counts==expected[i] && d->velocity_native_counts==expected[i] &&
                d->current_native_counts==expected[i],"legacy signed convention exact");
        require(d->current_vendor_scaled==expected[i]/256.0,"vendor scaling retained without amperes claim");
        require(std::abs(d->position_radians-expected[i]*quantum)<1e-14,"one position SI conversion");
    }
    passed("legacy_0_32768_32769_65535_signed_boundaries_all_three_fields");
}
void diagnosticRejection() {
    auto f=reply(128,65534,256);
    for (std::uint32_t id : {0u,0x11u,0x90u,0x98u,0x191u,0x80000091u,0x40000091u,0x20000091u}) {
        f.identifier=id; require(!wire::decodeJointDiagnostic(f,1),"wrong ID, gripper or CAN flags rejected");
    }
    f.identifier=0x91;
    for (std::uint8_t len : {0,3,7,9,255}) {
        f.length=len; require(!wire::decodeJointDiagnostic(f,1),"wrong DLC rejected");
    }
    f.length=8;
    for(int sign : {0,2,-2}) require(!wire::decodeJointDiagnostic(f,sign),"invalid sign rejected");
    for(std::uint32_t id=0x91;id<=0x97;++id) {
        f.identifier=id; f.data[0]=0xab;f.data[7]=10;
        const auto d=wire::decodeJointDiagnostic(f,-1);
        require(d && d->joint_index==id-0x91,"all seven replies routed");
        require(d->reply_tag==0xab && d->status==10,"unknown tag/status retained, no authority inference");
        require(d->position_radians<0 && d->velocity_native_counts==-1 && d->current_native_counts==256,"direction only changes position");
    }
    passed("reject_wrong_id_dlc_can_flags_and_direction_preserve_raw_diagnostics");
}
void inputRejection() {
    wire::JointVector q{};auto b=bounds();auto s=signs();
    require(!wire::encodePositions(static_cast<wire::PhysicalArm>(99),q,s,b),"invalid arm no batch");
    for(double value : {std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::infinity(),
                       -std::numeric_limits<double>::infinity(),2.1,-2.1}) {
        q[6]=value;require(!wire::encodePositions(wire::PhysicalArm::Right,q,s,b),"invalid seventh joint rejects whole batch");
    }
    q.fill(0);
    for(int sign : {0,2,-2}) { s[6]=sign;require(!wire::encodePositions(wire::PhysicalArm::Right,q,s,b),"invalid explicit sign"); }
    s=signs();
    for(int kind=0;kind<4;++kind) {
        auto bad=b;
        if(kind==0)bad.lower[0]=std::numeric_limits<double>::quiet_NaN();
        if(kind==1)bad.upper[0]=std::numeric_limits<double>::infinity();
        if(kind==2)bad.lower[0]=bad.upper[0];
        if(kind==3)bad.lower[0]=3;
        require(!wire::encodePositions(wire::PhysicalArm::Right,q,s,bad),"invalid profile rejected");
    }
    b.lower.fill(-1e300);b.upper.fill(1e300);
    for(double value : {1e299,-1e299,32768*quantum,-32768*quantum,32767.5*quantum,-32767.5*quantum}) {
        q[0]=value;require(!wire::encodePositions(wire::PhysicalArm::Right,q,s,b),"overflow and ambiguous range rejected before cast");
    }
    passed("finite_profile_range_sign_and_atomic_seven_joint_rejection");
}
void quantization() {
    auto b=bounds();auto s=signs();wire::JointVector q{};
    for(int sign : {-1,1}) {
        s.fill(sign);
        for(int i=-15000;i<=15000;++i) {
            const double requested=(i+(i<0?-.25:.25))*quantum;
            q.fill(requested);
            const auto batch=wire::encodePositions(wire::PhysicalArm::Right,q,s,b);
            require(bool(batch),"quantization sweep accepted");
            const auto decoded=decodeRecorded(*batch,s);
            for(double actual:decoded) {
                require(std::abs(actual-requested)<quantum,"less than one count quantization error");
                require(std::abs(actual)<=std::abs(requested)+1e-15,"truncation toward zero");
            }
        }
    }
    q.fill(-0.0);const auto zero=wire::encodePositions(wire::PhysicalArm::Right,q,s,b);
    require(zero && zero->frames[0].data[1]==0 && zero->frames[0].data[2]==0,"negative zero encoded zero");
    for(int direction : {-1,1}) for(double fraction : {-.75,-.25,.25,.75}) {
        q.fill(fraction*quantum);s.fill(direction);
        const auto tiny=wire::encodePositions(wire::PhysicalArm::Right,q,s,b);
        require(tiny && tiny->frames[0].data[1]==0 && tiny->frames[0].data[2]==0,
                "sign branch follows integer truncation; sub-count negative encodes 0000, not ffff");
    }
    b=bounds();q.fill(0);q[0]=.25*quantum;b.lower[0]=q[0];
    require(!wire::encodePositions(wire::PhysicalArm::Right,q,signs(),b),"quantization may not escape a positive lower bound");
    b=bounds();q[0]=-.25*quantum;b.upper[0]=q[0];
    require(!wire::encodePositions(wire::PhysicalArm::Right,q,signs(),b),"quantization may not escape a negative upper bound");
    passed("420014_quantized_joint_roundtrips_both_signs_and_tight_bound_rejection");
}
void ownerIntegration() {
    motion::Limits l;l.lower.fill(-2.09);l.upper.fill(2.09);l.velocity.fill(.3);l.acceleration.fill(.6);l.jerk.fill(2);
    motion::ContinuousArmController owner(l,{.005,.015,.15,.1,.05},[](const motion::Trajectory&,double,bool){return true;});
    motion::State initial{};motion::Feedback feedback{initial.position,0,true,true};
    require(owner.start(1,initial,feedback,0),"known stationary simulation starts");
    wire::JointVector lastRecorded{};auto before=initial;std::uint64_t seq=0;std::size_t records=0,movingRetargets=0;
    double maxError=0,maxStep=0;
    for(int i=1;i<=6000;++i) {
        const double now=i*.005;
        if(i%10==1) { feedback.position=lastRecorded;feedback.captured_at=now; } // ideal 20 Hz measurements
        if((i<4000 && i%3==1) || (i>=4000 && i%10==1)) {
            wire::JointVector goal{};
            for(std::size_t j=0;j<7;++j)goal[j]=i<4000 ? .7*std::sin(now*(.3+j*.07)) : .1;
            if(std::abs(before.velocity[5])>.01)++movingRetargets;
            require(owner.submit({1,++seq,now,goal},now)==motion::Reason::None,"continuous target accepted");
        }
        require(owner.tick(now,feedback,[&](const motion::Sample& sample) {
            const auto batch=wire::encodePositions(wire::PhysicalArm::Right,sample.state.position,signs(),bounds());
            require(bool(batch),"owner sample encodes");
            const auto decoded=decodeRecorded(*batch,signs());
            for(std::size_t j=0;j<7;++j) {
                maxError=std::max(maxError,std::abs(decoded[j]-sample.state.position[j]));
                maxStep=std::max(maxStep,std::abs(decoded[j]-lastRecorded[j]));
                require(std::abs(sample.state.position[j]-before.position[j])<=.3*.005+1e-10,"owner position continuity");
                require(std::abs(sample.state.acceleration[j]-before.acceleration[j])<=2*.005+1e-10,"owner jerk continuity");
                require(std::abs(decoded[j]-lastRecorded[j])<=.3*.005+quantum+1e-10,"wire step includes one-count quantization");
            }
            lastRecorded=decoded;before=sample.state;++records;return true;
        }),"owner tick with quantized delayed feedback");
    }
    require(records==6000 && movingRetargets>500 && maxError<quantum,"recorded integration metrics");
    for(double q:lastRecorded)require(std::abs(q-.1)<quantum,"quantized final target reached in ideal simulation");
    std::cout << "{\"metrics\":\"owner_to_recorded_CAN\",\"samples\":" << records << ",\"frames\":" << records*7
              << ",\"moving_retargets\":" << movingRetargets << ",\"maximum_quantization_error_rad\":" << maxError
              << ",\"maximum_wire_step_rad\":" << maxStep << ",\"hardware_io\":false}\n";
    passed("200hz_owner_to_recorded_frames_with_20hz_ideal_quantized_feedback");
}
void uncertainOutput() {
    motion::Limits l;l.lower.fill(-2.09);l.upper.fill(2.09);l.velocity.fill(.3);l.acceleration.fill(.6);l.jerk.fill(2);
    motion::ContinuousArmController owner(l,{.005,.015,.15,.1,.05},[](const motion::Trajectory&,double,bool){return true;});
    motion::State state{};motion::Feedback f{state.position,0,true,true};
    require(owner.start(1,state,f,0),"stationary fixture");
    auto invalid=signs();invalid[6]=0;std::size_t records=0;
    auto sink=[&](const motion::Sample& sample) {
        const auto batch=wire::encodePositions(wire::PhysicalArm::Right,sample.state.position,invalid,bounds());
        if(!batch)return false;
        records+=batch->frames.size();return true;
    };
    require(!owner.tick(.005,f,sink),"codec rejection propagates output failure");
    require(owner.status().reason==motion::Reason::OutputFailure && records==0,"whole batch rejected and fault latched");
    invalid=signs();require(!owner.tick(.01,f,sink) && records==0,"fixed encoding cannot auto-retry fault");
    passed("invalid_driver_boundary_emits_zero_frames_and_owner_latches_fault");
}
} // namespace
int main() {
    try {
        routingAndGoldenFrames();signedBoundaries();diagnosticRejection();inputRejection();quantization();ownerIntegration();uncertainOutput();
        std::cout << "{\"passed\":" << cases << ",\"failed\":0,\"hardware_io\":false}\n";return 0;
    } catch(const std::exception& e) { std::cerr << e.what() << '\n';return 1; }
}
