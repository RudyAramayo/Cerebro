#include "SocketCanTransport.hpp"
#ifdef __linux__
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <linux/can.h>
#include <linux/can/error.h>
#include <linux/can/raw.h>
#include <linux/if_link.h>
#include <linux/rtnetlink.h>
#include <linux/sockios.h>
#include <linux/sock_diag.h>
#include <linux/time_types.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

namespace rob::amber {
namespace {
constexpr Nanoseconds billion=1000000000;
struct Fd { int value{-1};~Fd(){if(value>=0)::close(value);} };
Nanoseconds ns(std::int64_t seconds,std::int64_t nanos) {
    if(seconds<0||nanos<0||nanos>=billion||seconds>(std::numeric_limits<Nanoseconds>::max()-nanos)/billion)
        throw std::runtime_error("invalid kernel clock");
    return seconds*billion+nanos;
}
Nanoseconds clockValue(clockid_t clock) {
    timespec t{};
    if(clock_gettime(clock,&t)!=0)throw std::runtime_error("clock_gettime failed");
    return ns(t.tv_sec,t.tv_nsec);
}
ClockCorrelation correlation() {
    ClockCorrelation c;
    c.monotonic_before=clockValue(CLOCK_MONOTONIC);
    c.realtime=clockValue(CLOCK_REALTIME);
    c.monotonic_after=clockValue(CLOCK_MONOTONIC);
    return c;
}
template<class T> bool option(int fd,int level,int name,const T& value) {
    return setsockopt(fd,level,name,&value,sizeof(value))==0;
}
struct SocketMemory {std::uint32_t receive_drops,write_allocated;};
std::optional<SocketMemory> socketMemory(int fd) {
    std::array<std::uint32_t,SK_MEMINFO_VARS> memory{};
    socklen_t length=sizeof(memory);
    if(getsockopt(fd,SOL_SOCKET,SO_MEMINFO,memory.data(),&length)!=0||
       length<(SK_MEMINFO_DROPS+1)*sizeof(std::uint32_t))return {};
    return SocketMemory{memory[SK_MEMINFO_DROPS],memory[SK_MEMINFO_WMEM_ALLOC]};
}
std::string interfaceKind(int index) {
    // Read-only, bounded rtnetlink query. Interface names alone cannot prove
    // that a test is attached to virtual CAN rather than physical hardware.
    Fd fd{socket(AF_NETLINK,SOCK_RAW|SOCK_NONBLOCK|SOCK_CLOEXEC,NETLINK_ROUTE)};
    if(fd.value<0)return {};
    struct Request {nlmsghdr header;ifinfomsg info;} request{};
    request.header.nlmsg_len=NLMSG_LENGTH(sizeof(ifinfomsg));
    request.header.nlmsg_type=RTM_GETLINK;request.header.nlmsg_flags=NLM_F_REQUEST;
    request.header.nlmsg_seq=1;request.info.ifi_family=AF_UNSPEC;request.info.ifi_index=index;
    sockaddr_nl destination{};destination.nl_family=AF_NETLINK;
    if(sendto(fd.value,&request,request.header.nlmsg_len,MSG_DONTWAIT,reinterpret_cast<sockaddr*>(&destination),sizeof(destination))!=static_cast<ssize_t>(request.header.nlmsg_len))return {};
    pollfd poller{fd.value,POLLIN,0};
    if(poll(&poller,1,100)!=1||!(poller.revents&POLLIN))return {};
    alignas(nlmsghdr) char data[8192];
    sockaddr_nl peer{};iovec payload{data,sizeof(data)};msghdr reply{};
    reply.msg_name=&peer;reply.msg_namelen=sizeof(peer);reply.msg_iov=&payload;reply.msg_iovlen=1;
    const auto size=recvmsg(fd.value,&reply,MSG_DONTWAIT);
    if(size<=0||(reply.msg_flags&(MSG_TRUNC|MSG_CTRUNC))||reply.msg_namelen<sizeof(peer)||
       peer.nl_family!=AF_NETLINK||peer.nl_pid!=0)return {};
    int remaining=static_cast<int>(size);
    for(auto* h=reinterpret_cast<nlmsghdr*>(data);NLMSG_OK(h,remaining);h=NLMSG_NEXT(h,remaining)) {
        if(h->nlmsg_type!=RTM_NEWLINK||h->nlmsg_seq!=1||h->nlmsg_len<NLMSG_LENGTH(sizeof(ifinfomsg)))continue;
        const auto* info=reinterpret_cast<const ifinfomsg*>(NLMSG_DATA(h));
        if(info->ifi_index!=index)continue;
        int length=IFLA_PAYLOAD(h);
        for(auto* a=IFLA_RTA(info);RTA_OK(a,length);a=RTA_NEXT(a,length))if(a->rta_type==IFLA_LINKINFO) {
            int nested=RTA_PAYLOAD(a);
            for(auto* n=reinterpret_cast<rtattr*>(RTA_DATA(a));RTA_OK(n,nested);n=RTA_NEXT(n,nested))if(n->rta_type==IFLA_INFO_KIND) {
                const auto* value=static_cast<const char*>(RTA_DATA(n));
                const auto available=static_cast<std::size_t>(RTA_PAYLOAD(n));
                const auto count=strnlen(value,available);
                if(count==available)return {};
                return std::string(value,count);
            }
        }
    }
    return {};
}
}
struct SocketCanTransport::Impl {
    explicit Impl(SocketCanOptions value):options(std::move(value)),clock(options.clock) {}
    SocketCanOptions options;
    ReceiveClock clock;
    mutable std::mutex mutex;
    Fd fd;
    SocketCanStatus state;
    void fail(SocketCanFault reason,int error=0) {
        if(state.fault==SocketCanFault::None){state.fault=reason;state.system_error=error;}
    }
    bool receiveHealthy() {
        const auto memory=socketMemory(fd.value);
        if(!memory){fail(SocketCanFault::Configuration,errno);return false;}
        if(memory->receive_drops!=0){fail(SocketCanFault::Overflow);return false;}
        return true;
    }
};
SocketCanTransport::SocketCanTransport(SocketCanOptions options):impl_(std::make_unique<Impl>(std::move(options))) {
    const auto& o=impl_->options;
    if(!route(o.arm)||o.interface.empty()||o.interface.size()>=IFNAMSIZ||o.interface.find('/')!=std::string::npos||
       o.maximum_receive_batch==0||o.maximum_receive_batch>256||o.receive_budget<=0||o.receive_budget>billion||
       o.queue_high_water_bytes<static_cast<int>(CAN_MTU)||o.queue_high_water_bytes>1048576)
        throw std::invalid_argument("invalid explicit SocketCAN policy");
    if(!o.require_virtual&&o.interface!=route(o.arm)->can_interface)
        throw std::invalid_argument("physical arm/interface route mismatch");
}
SocketCanTransport::~SocketCanTransport()=default;
Nanoseconds SocketCanTransport::monotonicNanoseconds(){return clockValue(CLOCK_MONOTONIC);}
double SocketCanTransport::monotonicSeconds(){return static_cast<double>(monotonicNanoseconds())/billion;}
bool SocketCanTransport::open(std::uint64_t epoch) {
    auto& s=*impl_;std::lock_guard<std::mutex> lock(s.mutex);
    if(s.fd.value>=0||epoch==0||epoch<=s.state.epoch)return false;
    s.state={};s.state.epoch=epoch;
    Fd pending{socket(PF_CAN,SOCK_RAW|SOCK_NONBLOCK|SOCK_CLOEXEC,CAN_RAW)};
    if(pending.value<0){s.fail(SocketCanFault::Open,errno);return false;}
    const auto index=if_nametoindex(s.options.interface.c_str());
    if(index==0){s.fail(SocketCanFault::Interface,errno);return false;}
    ifreq info{};std::memcpy(info.ifr_name,s.options.interface.c_str(),s.options.interface.size()+1);
    if(ioctl(pending.value,SIOCGIFHWADDR,&info)!=0||info.ifr_hwaddr.sa_family!=ARPHRD_CAN){s.fail(SocketCanFault::Interface,errno);return false;}
    s.state.interface_index=static_cast<int>(index);s.state.interface_kind=interfaceKind(static_cast<int>(index));
    if(s.options.require_virtual&&s.state.interface_kind!="vcan"){s.fail(SocketCanFault::Interface);return false;}
    if(s.state.interface_kind.empty())s.state.interface_kind="unspecified-can";
    std::array<can_filter,joint_count> filters{};
    for(std::size_t j=0;j<joint_count;++j)filters[j]={static_cast<canid_t>(0x91+j),CAN_SFF_MASK|CAN_EFF_FLAG|CAN_RTR_FLAG};
    const int enabled=1,disabled=0,receiveBuffer=65536;
    const can_err_mask_t errors=CAN_ERR_MASK;
    if(setsockopt(pending.value,SOL_CAN_RAW,CAN_RAW_FILTER,filters.data(),sizeof(filters))!=0||
       !option(pending.value,SOL_CAN_RAW,CAN_RAW_ERR_FILTER,errors)||
       !option(pending.value,SOL_CAN_RAW,CAN_RAW_RECV_OWN_MSGS,disabled)||
       !option(pending.value,SOL_SOCKET,SO_TIMESTAMPNS_NEW,enabled)||
       !option(pending.value,SOL_SOCKET,SO_RXQ_OVFL,enabled)||
       !option(pending.value,SOL_SOCKET,SO_RCVBUF,receiveBuffer)||
       !option(pending.value,SOL_SOCKET,SO_SNDBUF,s.options.queue_high_water_bytes)) {
        s.fail(SocketCanFault::Configuration,errno);return false;
    }
    sockaddr_can address{};address.can_family=AF_CAN;address.can_ifindex=static_cast<int>(index);
    if(bind(pending.value,reinterpret_cast<sockaddr*>(&address),sizeof(address))!=0){s.fail(SocketCanFault::Open,errno);return false;}
    const auto memory=socketMemory(pending.value);
    if(!memory||memory->receive_drops!=0){s.fail(SocketCanFault::Configuration,errno);return false;}
    try {
        if(!s.clock.reset(epoch,correlation())){s.fail(SocketCanFault::Timestamp);return false;}
    }catch(...){s.fail(SocketCanFault::Timestamp);return false;}
    // No receive timestamp captured before this anchor can initialize a writer.
    s.fd.value=pending.value;pending.value=-1;s.state.opened=true;
    s.state.transmit_allowed=s.options.allow_transmit;return true;
}
void SocketCanTransport::close() {
    auto& s=*impl_;std::lock_guard<std::mutex> lock(s.mutex);
    if(s.fd.value>=0){::close(s.fd.value);s.fd.value=-1;}
    s.state.opened=false;s.state.transmit_allowed=false;s.fail(SocketCanFault::Closed);
}
std::vector<KernelFeedback> SocketCanTransport::receive() {
    auto& s=*impl_;std::lock_guard<std::mutex> lock(s.mutex);
    std::vector<KernelFeedback> result;
    if(!s.state.opened||s.state.fault!=SocketCanFault::None)return result;
    if(!s.receiveHealthy())return result;
    result.reserve(s.options.maximum_receive_batch);
    try {
        const auto started=monotonicNanoseconds();
        std::size_t processed=0;
        for(;processed<s.options.maximum_receive_batch;++processed) {
            if(monotonicNanoseconds()-started>s.options.receive_budget){s.fail(SocketCanFault::Backlog);break;}
            can_frame frame{};sockaddr_can address{};
            alignas(cmsghdr) char control[CMSG_SPACE(sizeof(__kernel_timespec))+CMSG_SPACE(sizeof(std::uint32_t))]{};
            iovec payload{&frame,sizeof(frame)};msghdr msg{};
            msg.msg_name=&address;msg.msg_namelen=sizeof(address);msg.msg_iov=&payload;msg.msg_iovlen=1;
            msg.msg_control=control;msg.msg_controllen=sizeof(control);
            const auto bytes=recvmsg(s.fd.value,&msg,MSG_DONTWAIT);
            if(bytes<0) {
                if(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR)break;
                s.fail(SocketCanFault::Receive,errno);break;
            }
            constexpr auto minimumAddress=offsetof(sockaddr_can,can_ifindex)+sizeof(address.can_ifindex);
            if(bytes!=static_cast<ssize_t>(CAN_MTU)||(msg.msg_flags&(MSG_TRUNC|MSG_CTRUNC))||msg.msg_namelen<minimumAddress||
               address.can_family!=AF_CAN||address.can_ifindex!=s.state.interface_index){s.fail(SocketCanFault::Receive);break;}
            if(frame.can_id&CAN_ERR_FLAG){s.fail(SocketCanFault::BusError);break;}
            if((!s.options.require_virtual&&(msg.msg_flags&MSG_DONTROUTE))||frame.can_id<0x91||frame.can_id>0x97||frame.len!=8){
                s.fail(SocketCanFault::ForeignFrame);break;
            }
            std::optional<Nanoseconds> received;
            for(auto* c=CMSG_FIRSTHDR(&msg);c;c=CMSG_NXTHDR(&msg,c)) {
                if(c->cmsg_level!=SOL_SOCKET)continue;
                if(c->cmsg_type==SO_TIMESTAMPNS_NEW) {
                    if(received||c->cmsg_len!=CMSG_LEN(sizeof(__kernel_timespec))){s.fail(SocketCanFault::Timestamp);break;}
                    __kernel_timespec time{};std::memcpy(&time,CMSG_DATA(c),sizeof(time));received=ns(time.tv_sec,time.tv_nsec);
                }else if(c->cmsg_type==SO_RXQ_OVFL) {
                    if(c->cmsg_len!=CMSG_LEN(sizeof(std::uint32_t))){s.fail(SocketCanFault::Overflow);break;}
                    std::uint32_t dropped{};std::memcpy(&dropped,CMSG_DATA(c),sizeof(dropped));
                    if(dropped!=0){s.fail(SocketCanFault::Overflow);break;}
                }
            }
            if(s.state.fault!=SocketCanFault::None)break;
            if(!received){s.fail(SocketCanFault::Timestamp);break;}
            const auto mapped=s.clock.map(s.state.epoch,*received,correlation());
            if(mapped.error==ReceiveClockError::OldPacket){++s.state.discarded_old;continue;}
            if(!mapped.monotonic){s.fail(SocketCanFault::Timestamp);break;}
            Frame decoded{frame.can_id,frame.len,{}};std::copy_n(frame.data,8,decoded.data.begin());
            result.push_back({decoded,*mapped.monotonic,s.state.epoch});++s.state.received;
        }
        // Hitting the bounded batch with more queued data is a fault, not an
        // unbounded drain that starves the owner or freshens an old backlog.
        if(processed==s.options.maximum_receive_batch&&s.state.fault==SocketCanFault::None) {
            char next;const auto bytes=recv(s.fd.value,&next,1,MSG_PEEK|MSG_DONTWAIT);
            if(bytes>=0)s.fail(SocketCanFault::Backlog);
            else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)s.fail(SocketCanFault::Receive,errno);
        }
    }catch(...){s.fail(SocketCanFault::Timestamp);}
    if(!s.receiveHealthy()||s.state.fault!=SocketCanFault::None)result.clear();
    return result;
}
WriteResult SocketCanTransport::writePosition(const Route& destination,const Frame& frame,double deadline) {
    auto& s=*impl_;std::lock_guard<std::mutex> lock(s.mutex);
    if(!s.state.opened||s.state.fault!=SocketCanFault::None||!s.state.transmit_allowed)return WriteResult::Rejected;
    const auto memory=socketMemory(s.fd.value);
    if(!memory){s.fail(SocketCanFault::Configuration,errno);return WriteResult::Rejected;}
    if(memory->receive_drops!=0){s.fail(SocketCanFault::Overflow);return WriteResult::Rejected;}
    const auto expected=route(s.options.arm);
    if(destination.physical_arm!=s.options.arm||destination.can_interface!=expected->can_interface||
       frame.identifier<0x11||frame.identifier>0x17||frame.length!=3||frame.data[0]!=0x40) {
        s.fail(SocketCanFault::ForeignFrame);return WriteResult::Rejected;
    }
    try {
        if(!std::isfinite(deadline)||monotonicSeconds()>=deadline){s.fail(SocketCanFault::Deadline);return WriteResult::Rejected;}
        // CAN_RAW does not implement SIOCOUTQ in the target 5.15 baseline.
        // This is socket-memory backpressure, not a device FIFO/ACK counter.
        if(memory->write_allocated>=static_cast<std::uint32_t>(s.options.queue_high_water_bytes)){
            s.fail(SocketCanFault::Queue);return WriteResult::Rejected;
        }
        can_frame packet{};packet.can_id=frame.identifier;packet.len=frame.length;
        std::copy_n(frame.data.begin(),frame.length,packet.data);
        ++s.state.attempted;
        const auto written=send(s.fd.value,&packet,sizeof(packet),MSG_DONTWAIT|MSG_NOSIGNAL);
        const int error=errno;
        if(written==static_cast<ssize_t>(CAN_MTU)) {
            ++s.state.accepted;
            // Accepted means kernel queue acceptance only. The boundary also
            // checks its clock after return; no packet is retried or recalled.
            if(monotonicSeconds()>=deadline)s.fail(SocketCanFault::Deadline);
            return WriteResult::Accepted;
        }
        s.fail(SocketCanFault::Send,written<0?error:0);
        if(written<0&&(error==EAGAIN||error==EWOULDBLOCK||error==EMSGSIZE||error==EINTR))return WriteResult::Rejected;
        return WriteResult::Uncertain;
    }catch(...){s.fail(SocketCanFault::Timestamp);return WriteResult::Uncertain;}
}
SocketCanStatus SocketCanTransport::status() const {
    const auto& s=*impl_;std::lock_guard<std::mutex> lock(s.mutex);return s.state;
}
} // namespace rob::amber
#endif
