import Foundation
import simd

// Socket-free adapters. The production coordinator, wire codec, planner and
// ramp are compiled unchanged. These types have no actuator or network access.
enum ROBControlLiveSessionRegistry {
    static var connected=true
    static func isActiveOperator(controllerID:UUID,sessionID:UUID)->Bool { connected }
}
enum ROBWorkspaceTarget: Hashable { case can,orangeBucket }
struct ROBWorkspaceLocatedObject {}
final class ROBWorkspaceSearch {
    static let shared=ROBWorkspaceSearch()
    @MainActor func run(targets:[ROBWorkspaceTarget],model:ROBGhostRobotModel,requireDepth:Bool=true,
        surveyFrontTable:Bool=false,armAlreadyAtGraspReady:Bool=false,
        check:()throws->Void,progress:(String)->Void) async throws ->[ROBWorkspaceTarget:ROBWorkspaceLocatedObject] { [:] }
}
struct ROBGhostRobotModel {
    init(directory:URL,physicalSide:String) throws {}
    func positions(vendorLeft:[Double])->[String:Double] { [:] }
    func worldCollisionBounds(positions:[String:Double])->[String:(low:SIMD3<Double>,high:SIMD3<Double>)] { [:] }
    func frames(_ positions:[String:Double])->[String:simd_double4x4] { [:] }
}
final class ROBLeftArmTrial {
    static let shared=ROBLeftArmTrial();var isRunning=false
    func cancel(reason:String) {}
    func performRecycleMission(authorization:@escaping()->Bool,completion:@escaping(NSDictionary)->Void) {
        completion(["status":"not_found","arm_motion_sent":false,"jaw_command_sent":false])
    }
}
final class ROBControllerArmApproval { static let shared=ROBControllerArmApproval();let standingCanCampaignMayHoldPayload=false;func cancel(reason:String) {} }
final class ROBArmRoutineCoordinator { static let shared=ROBArmRoutineCoordinator();var ownsPhysicalMotion=false }
final class ROBShowMotionCoordinator { static let shared=ROBShowMotionCoordinator();var isRunning=false }
final class ROBAmberGestureExecutor { static let shared=ROBAmberGestureExecutor();var isExecuting=false }
struct FakeTelemetry {
    let sequence=1,effectiveSampleAgeMilliseconds=0.0
    let positionsRadians=[NSNumber](repeating:0,count:7),statuses=[NSNumber](repeating:2,count:7)
}
final class ROBAmberGatewayClient {
    static let shared=ROBAmberGatewayClient()
    func telemetry(forArm:String)->FakeTelemetry? { FakeTelemetry() }
}
enum ROBArmFeedbackTiming { static let maximumAgeMilliseconds=500.0 }
enum ROBCanRecyclingReadyPose { static func matches(_ q:[Double],physicalSide:String)->Bool { true } }
enum ROBArmRoutinePlan { static func near(_ q:[Double],_ r:[Double],tolerance:Double)->Bool { q==r } }
struct FakeDepthDirection { let geometryConfidence=1.0,depthClearanceMeters=2.0,headingOffset=0.0 }
final class ROBTorsoControlCenter { static let shared=ROBTorsoControlCenter();let observedHeading=0.0,usesLiveCamera=true }
struct FakeDepth { let receivedAtUptime=0.0,directions=[FakeDepthDirection()] }
final class ROBTraversabilityRuntime {
    static let shared=ROBTraversabilityRuntime()
    func snapshot()->FakeDepth? { nil }
    func setAutonomousMotionActive(_ active:Bool) {}
}

@main struct ROBRecycleMissionRuntimeFixtures {
    static func main() throws {
        let device=UUID(),session=UUID()
        var held=ROBRecycleMissionMessage(kind:.status,missionID:UUID(),sequence:1,
            sentAtMilliseconds:ROBRecycleMissionMessage.now,configuration:.init())
        held.phase = .paused;held.possiblePayloadHeld=true
        UserDefaults.standard.set(try JSONEncoder().encode(held),forKey:"ROB.RecycleCans.LastMission.v1")
        UserDefaults.standard.set(device.uuidString,forKey:"ROB.RecycleCans.LastMission.v1.controller")
        let coordinator=ROBRecycleMissionCoordinator.shared
        var statuses=[ROBRecycleMissionMessage](),stops=0,drives=0,takeovers=0
        coordinator.sendStatus={data,_,_ in statuses.append(ROBRecycleMissionMessage.decode(data)!)}
        coordinator.stopBase={stops += 1};coordinator.driveTreads={_,_ in drives += 1};coordinator.takeControl={takeovers += 1}
        func request(_ kind:ROBRecycleMissionMessage.Kind,id:UUID=UUID(),sequence:UInt64=1)->ROBRecycleMissionMessage {
            .init(kind:kind,missionID:id,sequence:sequence,sentAtMilliseconds:ROBRecycleMissionMessage.now,configuration:.init())
        }
        func deliver(_ m:ROBRecycleMissionMessage,_ sender:UUID?=nil,_ link:UUID?=nil) {
            coordinator.consume(m.encoded()!,controller:sender ?? device,networkSession:link ?? session)
        }
        func check(_ value:@autoclosure()->Bool,_ message:String) { precondition(value(),message) }
        deliver(request(.query,id:held.missionID))
        deliver(request(.confirmEmpty,id:held.missionID,sequence:2),UUID())
        check(statuses.last?.possiblePayloadHeld==true,"Other peer cleared possible payload")
        deliver(request(.confirmEmpty,id:held.missionID,sequence:2))
        check(statuses.last?.possiblePayloadHeld==false && drives==0,"Operator empty observation moved or failed to clear uncertainty")
        ROBControlLiveSessionRegistry.connected=false
        deliver(request(.start));check(!coordinator.active && takeovers==0,"Unauthenticated mission started")
        ROBControlLiveSessionRegistry.connected=true
        var stale=request(.start);stale.sentAtMilliseconds-=11_000
        deliver(stale);check(!coordinator.active,"Expired Start accepted")
        let first=request(.start);deliver(first)
        check(coordinator.active && takeovers==1,"Mission Start did not activate once")
        check(drives==0,"Mission drove without map and live pose")
        deliver(first);check(takeovers==1,"Duplicate Start executed again")
        deliver(request(.stop,id:first.missionID,sequence:2),UUID())
        check(coordinator.active,"Another controller stopped this mission")
        deliver(request(.stop,id:first.missionID,sequence:1))
        check(coordinator.active,"Stale Stop sequence changed mission")
        deliver(request(.stop,id:first.missionID,sequence:2))
        check(!coordinator.active && statuses.last?.phase == .stopped && stops>0,"Stop failed")
        deliver(first);check(!coordinator.active && takeovers==1,"Stopped Start replayed")
        let second=request(.start);deliver(second)
        check(coordinator.active && takeovers==2,"Fresh mission could not start")
        let freshSession=UUID()
        deliver(request(.query,id:second.missionID),nil,freshSession)
        check(!coordinator.active && statuses.last?.phase == .paused,"Reconnect inherited old authorization")
        let third=request(.start);deliver(third,nil,freshSession)
        ROBControlLiveSessionRegistry.connected=false
        RunLoop.main.run(until:Date().addingTimeInterval(0.12))
        check(!coordinator.active && statuses.last?.phase == .paused,"Disconnected controller kept mission running")
        check(drives==0,"Lifecycle tests emitted tread motion")
        print("Recycle mission runtime passed: authenticated Start, duplicates, owner/sequence Stop, replay, reconnect and disconnect; no hardware")
    }
}
