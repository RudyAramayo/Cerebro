#include "SocketCanTransport.hpp"
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <linux/can.h>
#include <linux/can/error.h>
#include <linux/can/raw.h>
#include <net/if.h>
#include <sys/socket.h>
#include <unistd.h>
using namespace rob::amber;
namespace {
int groups=0;
void require(bool value,const char* why){if(!value)throw std::runtime_error(why);}
void passed(const char* name){++groups;std::cout<<"{\"test\":\""<<name<<"\",\"passed\":true}\n";}
void waitMs(int count){std::this_thread::sleep_for(std::chrono::milliseconds(count));}
struct Actuator {
    int fd{-1};
    explicit Actuator(const std::string& interface){
        fd=socket(PF_CAN,SOCK_RAW|SOCK_NONBLOCK|SOCK_CLOEXEC,CAN_RAW);require(fd>=0,"fixture CAN socket");
        can_filter filter{0x10,0x7f0|CAN_EFF_FLAG|CAN_RTR_FLAG};
        require(setsockopt(fd,SOL_CAN_RAW,CAN_RAW_FILTER,&filter,sizeof(filter))==0,"fixture filter");
        sockaddr_can address{};address.can_family=AF_CAN;address.can_ifindex=static_cast<int>(if_nametoindex(interface.c_str()));
        require(address.can_ifindex>0&&bind(fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0,"fixture bound");
    }
    ~Actuator(){if(fd>=0)::close(fd);}
    void feedback(canid_t id=0x91,int length=8){
        can_frame f{};f.can_id=id;f.len=static_cast<__u8>(length);f.data[0]=1;f.data[2]=128;f.data[7]=2;
        require(send(fd,&f,sizeof(f),MSG_DONTWAIT)==static_cast<ssize_t>(CAN_MTU),"fixture feedback send");
    }
    int positions(){
        int count=0;can_frame f{};
        while(recv(fd,&f,sizeof(f),MSG_DONTWAIT)==static_cast<ssize_t>(CAN_MTU)){require(f.can_id>=0x11&&f.can_id<=0x17&&f.len==3&&f.data[0]==0x40,"recorded position bytes");++count;}
        require(errno==EAGAIN||errno==EWOULDBLOCK,"fixture queue drained");return count;
    }
};
Frame target(){return {0x11,3,{0x40,0,128}};}
SocketCanOptions options(const std::string& name,bool transmit=false){
    SocketCanOptions o;o.interface=name;o.allow_transmit=transmit;o.receive_budget=10000000;return o;
}
void virtualTests(const std::string& name){
    auto opt=options(name,true);SocketCanTransport transport(opt);
    require(transport.open(1),"verified virtual CAN open");
    require(transport.status().interface_kind=="vcan","kernel confirms virtual interface BEFORE fixture sends");
    Actuator actuator(name);waitMs(5);
    for(int j=0;j<7;++j)actuator.feedback(0x91+j);
    waitMs(1);
    const auto feedback=transport.receive();require(feedback.size()==7,"seven real-kernel timestamped frames");
    for(const auto& f:feedback)require(f.epoch==1&&f.received_at>0&&f.received_at<=SocketCanTransport::monotonicNanoseconds(),"native timestamp epoch and age");
    for(int j=0;j<7;++j){auto f=target();f.identifier+=j;require(transport.writePosition(*route(PhysicalArm::Right),f,SocketCanTransport::monotonicSeconds()+.1)==WriteResult::Accepted,"nonblocking position accepted");}
    require(actuator.positions()==7&&transport.status().accepted==7,"exact seven frame trace");
    passed("virtual_CAN_real_receive_timestamps_and_seven_position_frames");
    SocketCanTransport passive(options(name));require(passive.open(1),"passive open");
    require(passive.writePosition(*route(PhysicalArm::Right),target(),SocketCanTransport::monotonicSeconds()+1)==WriteResult::Rejected,"default output disabled");
    require(passive.status().attempted==0&&actuator.positions()==0,"passive mode never calls send");
    passed("passive_default_opens_receiver_without_transmitting");
    SocketCanTransport stale(options(name,true));require(stale.open(1),"stale fixture open");waitMs(5);
    actuator.feedback();waitMs(120);
    require(stale.receive().empty()&&stale.status().fault==SocketCanFault::Timestamp,"queued feedback preserves stale kernel age");
    require(stale.writePosition(*route(PhysicalArm::Right),target(),SocketCanTransport::monotonicSeconds()+1)==WriteResult::Rejected,"stale channel silent");
    require(!stale.open(2),"no implicit reconnect while open");stale.close();
    require(!stale.open(1)&&stale.open(2),"explicit reopen requires a new source epoch");
    passed("kernel_queue_age_latches_and_reopen_requires_explicit_new_epoch");
    SocketCanTransport late(options(name,true));require(late.open(1),"deadline fixture");
    require(late.writePosition(*route(PhysicalArm::Right),target(),SocketCanTransport::monotonicSeconds()-1)==WriteResult::Rejected,"expired deadline rejects before syscall");
    require(late.status().attempted==0&&late.status().fault==SocketCanFault::Deadline,"deadline diagnostic");
    SocketCanTransport foreign(options(name,true));require(foreign.open(1),"foreign fixture");
    require(foreign.writePosition(*route(PhysicalArm::Left),target(),SocketCanTransport::monotonicSeconds()+1)==WriteResult::Rejected,"wrong physical arm rejected");
    require(foreign.status().attempted==0,"foreign route emitted nothing");
    passed("deadline_and_wrong_arm_reject_before_send");
    SocketCanTransport malformed(options(name));require(malformed.open(1),"malformed fixture");waitMs(5);
    actuator.feedback(0x91,7);require(malformed.receive().empty()&&malformed.status().fault==SocketCanFault::ForeignFrame,"wrong DLC latches");
    auto shortBatch=options(name);shortBatch.maximum_receive_batch=4;
    SocketCanTransport backlog(shortBatch);require(backlog.open(1),"backlog fixture");waitMs(5);
    for(int j=0;j<7;++j)actuator.feedback(0x91+j);
    require(backlog.receive().empty()&&backlog.status().fault==SocketCanFault::Backlog,"bounded batch rejects remaining queued backlog");
    passed("malformed_feedback_and_bounded_receive_backlog_latch");
    SocketCanTransport error(options(name));require(error.open(1),"error fixture");waitMs(5);
    actuator.feedback(CAN_ERR_FLAG|CAN_ERR_BUSOFF);
    require(error.receive().empty()&&error.status().fault==SocketCanFault::BusError,"virtual CAN error frame latches");
    passed("virtual_bus_error_frame_latches_without_claiming_slcan_error_support");
    SocketCanTransport overflow(options(name,true));require(overflow.open(1),"drop-counter fixture");waitMs(5);
    for(int j=0;j<2048;++j)actuator.feedback();
    // Existing queued skbs can carry pre-overflow ancillary snapshots. Query
    // the current socket drop counter BEFORE sending, without draining first.
    require(overflow.writePosition(*route(PhysicalArm::Right),target(),SocketCanTransport::monotonicSeconds()+1)==WriteResult::Rejected,"current receive drop blocks TX before stale queued metadata is read");
    require(overflow.status().attempted==0&&overflow.status().fault==SocketCanFault::Overflow,"current drop counter fault");
    passed("current_socket_drop_counter_blocks_TX_before_old_ancillary_is_dequeued");
}
}
int main(int argc,char** argv){try{
    bool rejected=false;
    try{SocketCanOptions bad;bad.interface="can10";bad.require_virtual=false;bad.arm=PhysicalArm::Left;SocketCanTransport t(bad);}catch(const std::invalid_argument&){rejected=true;}
    require(rejected,"explicit physical side binding");
    passed("physical_route_mismatch_rejected_without_socket");
    if(argc==2){
        const auto* isolated=std::getenv("ROB_ISOLATED_VCAN_TEST");
        require(isolated&&std::string(isolated)=="1","virtual tests require isolated fixture launcher");
        virtualTests(argv[1]);
    }else require(argc==1,"usage: optional verified virtual interface");
    std::cout<<"{\"passed\":"<<groups<<",\"failed\":0,\"robot_io\":false,\"virtual_CAN_io\":"<<(argc==2?"true":"false")<<"}\n";
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
