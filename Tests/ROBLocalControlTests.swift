import Foundation

@main enum LocalControlTests {
    static func main() throws {
        var admission=ROBLocalControlAdmission()
        let now=Date().timeIntervalSince1970*1000
        func request(_ operation:String,_ session:String?=nil,_ sent:Double?=nil,_ id:UUID=UUID()) throws ->ROBLocalControlRequest {
            var value:[String:Any] = ["version":1,"id":id.uuidString,"operation":operation,"parameters":[:],"sent_at_ms":sent ?? now]
            if let session {value["session"]=session}
            return try ROBLocalControlRequest(data:JSONSerialization.data(withJSONObject:value),now:now)
        }
        func rejected(_ run:()throws->Void) { do {try run();fatalError("Expected rejection")} catch {} }
        try admission.admit(request("status"),now:now)
        rejected {try admission.admit(request("motion.move"),now:now)}
        rejected {try admission.admit(request("mission.start","old-launch"),now:now)}
        let command=try request("mission.start",admission.session)
        try admission.admit(command,now:now)
        rejected {try admission.admit(command,now:now)}
        rejected {_=try request("stop",admission.session,now-11_000)}
        rejected {_=try request("eval",admission.session)}
        try admission.admit(request("stop","old-launch"),now:now)
        for bad:Any in [true,"3",NSNull()] {
            let encoded=try JSONSerialization.data(withJSONObject:["version":1,"id":UUID().uuidString,
                "operation":"motion.move","parameters":["seconds":bad],"sent_at_ms":now])
            let invalid=try ROBLocalControlRequest(data:encoded,now:now)
            rejected {_=try invalid.number("seconds",default:1,range:0.65...600)}
        }
        var settle=ROBPassiveViewSettling()
        func frame(_ seq:UInt64,_ time:Double,_ stationary:Bool=true,_ generation:String="a")->ROBPassiveViewSettling.Exposure {
            .init(generation:generation,sequence:seq,capturedAt:time,stationary:stationary,validIMU:true,imuWindowMilliseconds:300,imuSamples:20)
        }
        func observe(_ frame:ROBPassiveViewSettling.Exposure?,_ uptime:Double,_ ready:Bool=true)->Bool {
            settle.observe(ready:ready,exposure:frame,nowUptime:uptime,nowMilliseconds:10_000+uptime*1000,maximumAgeMilliseconds:1200)
        }
        precondition(!observe(frame(1,10_000),0))
        precondition(!observe(frame(1,10_000),0.4),"Duplicate exposure completed settling")
        precondition(observe(frame(2,10_400),0.4),"Advancing stationary frames did not take the fast path")
        precondition(settle.method=="advancing_stationary_imu_exposures")
        settle=ROBPassiveViewSettling()
        precondition(!observe(frame(1,9_000),0))
        precondition(!observe(frame(2,10_400,false),0.4))
        precondition(!observe(frame(3,10_700),0.7))
        precondition(!observe(frame(4,11_000,true,"new-stream"),1.0))
        precondition(!observe(frame(5,11_300),1.3,false),"Lost neck readiness accepted frames")
        precondition(!observe(nil,1.4))
        precondition(!observe(nil,2.8))
        precondition(observe(nil,3.0),"Missing IMU did not retain 1.5 s fallback")
        let nearby=try ROBRecycleShuttlePlan.propose(table:.init(x:0.5,y:0.1),bucket:.init(x:-0.5,y:0.1),currentHeading:0,debugCable:true)
        precondition(nearby["strategy"] as? String=="torso_first_same_base_anchor")
        precondition((nearby["outbound_turn_degrees"] as! Double)+(nearby["return_turn_degrees"] as! Double)==0)
        precondition(nearby["executable"] as? Bool==false && nearby["collision_checked"] as? Bool==false)
        let far=try ROBRecycleShuttlePlan.propose(table:.init(x:1.5,y:0),bucket:.init(x:0,y:0.5),currentHeading:0,debugCable:true)
        precondition(far["strategy"] as? String=="checked_base_reposition_needed")
        print("PASS local session/expiry/replay gates, advancing-IMU settling/fallback/reset, torso-first proposal/unwind; no robot transport")
    }
}
