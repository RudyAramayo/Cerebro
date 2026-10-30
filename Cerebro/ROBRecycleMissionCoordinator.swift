import Foundation
import simd

/// The authenticated controller owns this mission. Perception and the existing
/// arm executor are phase adapters; neither may extend its scope or drive treads.
@objcMembers final class ROBRecycleMissionCoordinator: NSObject {
    static let shared = ROBRecycleMissionCoordinator()
    var sendStatus: ((Data, UUID, UUID) -> Void)?
    var driveTreads: ((Int, Int) -> Void)?
    var stopBase: (() -> Void)?
    var takeControl: (() -> Void)?
    var setCameraDemand: ((Bool) -> Void)?
    private(set) var active = false
    private var message: ROBRecycleMissionMessage?
    private var controller: UUID?
    private var networkSession: UUID?
    private var localOwner = false
    private var phaseStarted = ProcessInfo.processInfo.systemUptime
    private var phaseSeconds: [String: Double] = [:]
    private var startDeadline = 0.0
    private var lastCommandSequence: UInt64 = 0
    private var usedMissions = Set<UUID>()
    private var timer: Timer?
    private var task: Task<Void,Never>?
    private var map: ROBRoomMissionMap?
    private var mapDevice: UUID?
    private var pose: ROBRoomMissionPoint?
    private var yaw = 0.0
    private var poseAt = 0.0
    private var scan: ROBLidarScanFrame?
    private var origin: ROBRoomMissionPoint?
    private var searched: [ROBRoomMissionPoint] = []
    private var goal: ROBRoomMissionPoint?
    private var route: [ROBRoomMissionPoint] = []
    private var routeRevision: UInt64 = 0
    private var routeEpoch: UUID?
    private var planner: ROBRoomMissionPlanner?
    private var envelopeRadius = 0.0
    private var armModels: [String: ROBGhostRobotModel] = [:]
    private var armBaseline: [String:[Double]] = [:]
    private let ramp = ROBTreadMotionRamp()
    private var arriving = false
    private var canApproach: ROBRoomCanApproach?
    private var progressPoint: ROBRoomMissionPoint?
    private var progressYaw = 0.0
    private var progressAt = 0.0
    private var lastStatus = 0.0
    private var waitingSince = 0.0
    private let ledgerKey = "ROB.RecycleCans.LastMission.v1"
    private let usedKey = "ROB.RecycleCans.UsedMissionIDs.v1"
    override private init() {
        super.init()
        ROBRoomSpatialStore.shared.requestCanApproachPreview = { [weak self] in self?.previewCanReposition() }
        usedMissions=Set((UserDefaults.standard.stringArray(forKey:usedKey) ?? []).compactMap(UUID.init(uuidString:)))
        if let data=UserDefaults.standard.data(forKey:ledgerKey),
           let saved=try? JSONDecoder().decode(ROBRecycleMissionMessage.self,from:data),saved.valid {
            message=saved
            controller=UserDefaults.standard.string(forKey:ledgerKey+".controller").flatMap(UUID.init(uuidString:))
            if saved.active {
                message?.possiblePayloadHeld=saved.possiblePayloadHeld || saved.phase == .recycling
                message?.active=false;message?.phase = .paused
                message?.detail="Cerebro restarted. The old route and authorization ended; inspect any possible payload before a fresh mission."
            }
        }
    }

    @nonobjc func consume(_ data: Data, controller: UUID, networkSession: UUID) {
        precondition(Thread.isMainThread)
        guard let incoming=ROBRecycleMissionMessage.decode(data),
              ROBControlLiveSessionRegistry.isActiveOperator(controllerID:controller,sessionID:networkSession) else { return }
        if incoming.kind == .query {
            if self.controller == controller {
                if active,self.networkSession != networkSession { pause("Controller reconnected; the previous mission route ended.") }
                self.networkSession=networkSession;publish()
            } else {
                var reply=incoming;reply.kind = .status;reply.phase = .idle;reply.active=false
                reply.detail=active ? "Another controller owns the active mission":"No mission is active for this controller"
                reply.sentAtMilliseconds=ROBRecycleMissionMessage.now
                if let bytes=reply.encoded() { sendStatus?(bytes,controller,networkSession) }
            };return
        }
        guard abs(ROBRecycleMissionMessage.now-incoming.sentAtMilliseconds) <= 10_000 else { return }
        if incoming.kind == .confirmEmpty {
            guard !active,!ROBLeftArmTrial.shared.isRunning,!ROBArmRoutineCoordinator.shared.ownsPhysicalMotion,
                  self.controller==controller,message?.missionID==incoming.missionID,
                  message?.possiblePayloadHeld==true,incoming.sequence>lastCommandSequence else { publish();return }
            lastCommandSequence=incoming.sequence;self.networkSession=networkSession
            message?.possiblePayloadHeld=false
            setPhase(.paused,"Operator inspected the gripper and confirmed it empty. Ready for a fresh mission plan.")
            return // Observation only; no motion, jaw command or transfer credit.
        }
        if incoming.kind == .stop {
            guard self.controller == controller, incoming.missionID == message?.missionID,
                  incoming.sequence > lastCommandSequence else { publish();return }
            lastCommandSequence=incoming.sequence;stop(reason:"Stopped from ROBController");publish();return
        }
        guard incoming.kind == .start else { return }
        if incoming.missionID == message?.missionID { publish();return }
        guard !usedMissions.contains(incoming.missionID), usedMissions.count < 1024 else { return }
        // A running/uncertain task cannot be silently replaced by another Start.
        guard !active, message?.possiblePayloadHeld != true else {
            if self.controller == controller { publish() }
            else {
                var reply=incoming;reply.kind = .status;reply.phase = .paused;reply.active=false
                reply.detail="The current mission must finish or resolve its possible held payload before another mission starts."
                reply.sentAtMilliseconds=ROBRecycleMissionMessage.now
                if let bytes=reply.encoded() { sendStatus?(bytes,controller,networkSession) }
            }
            return
        }
        usedMissions.insert(incoming.missionID)
        UserDefaults.standard.set(usedMissions.map(\.uuidString),forKey:usedKey)
        self.controller=controller;self.networkSession=networkSession
        localOwner=false
        begin(incoming)
    }

    /// Explicit same-user CLI Start, distinct from an authenticated remote
    /// controller and from model text. Authority lives only for this bounded
    /// in-process mission; a CLI disconnect is not an internet dependency.
    @nonobjc func startLocal(configuration: ROBRecycleMissionMessage.Configuration) throws {
        precondition(Thread.isMainThread)
        guard configuration.valid, !active, message?.possiblePayloadHeld != true,
              !ROBLeftArmTrial.shared.isRunning, !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion,
              !ROBAnimationPlayback.shared.isRunning,
              takeControl != nil, stopBase != nil, driveTreads != nil else {
            throw ROBLocalControlError("Mission busy, possible payload unresolved, invalid configuration or runtime unavailable")
        }
        controller=nil; networkSession=nil; localOwner=true
        begin(ROBRecycleMissionMessage(kind: .start, missionID: UUID(), sequence: 1,
            sentAtMilliseconds: ROBRecycleMissionMessage.now, configuration: configuration))
    }

    @nonobjc func localStatus() -> [String: Any] {
        var result = message.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["active": false, "phase": "idle"]
        var timings=phaseSeconds
        if active, let phase=message?.phase { timings[phase.rawValue,default:0] += ProcessInfo.processInfo.systemUptime-phaseStarted }
        result["authority_source"] = localOwner ? "explicit_local_user_command" : "authenticated_controller"
        result["phase_seconds"] = timings
        result["internet_required"] = false
        result["remote_bucket_transport_commissioned"] = false
        return result
    }

    @nonobjc func confirmEmptyLocal(missionID: String) throws {
        guard !active,!ROBLeftArmTrial.shared.isRunning,!ROBArmRoutineCoordinator.shared.ownsPhysicalMotion,
              !ROBAnimationPlayback.shared.isRunning,message?.missionID.uuidString.lowercased()==missionID.lowercased(),
              message?.possiblePayloadHeld==true else { throw ROBLocalControlError("No matching inactive mission awaiting an empty-gripper observation") }
        message?.possiblePayloadHeld=false
        setPhase(.paused,"Local operator inspected both grippers and confirmed them empty. No jaw command or transfer credit.")
    }

    private func begin(_ incoming: ROBRecycleMissionMessage) {
        message=incoming;message?.kind = .status;message?.verifiedTransfers=0
        message?.searchedStops=0;message?.possiblePayloadHeld=false
        lastCommandSequence=incoming.sequence
        phaseSeconds=[:];phaseStarted=ProcessInfo.processInfo.systemUptime
        startDeadline=ROBRecycleMissionMessage.now+Double(incoming.configuration.durationSeconds)*1000
        origin=nil;searched=[];goal=nil;route=[];planner=nil;routeEpoch=nil;armBaseline=[:];canApproach=nil
        takeControl?();active=true;setCameraDemand?(true)
        ROBTraversabilityRuntime.shared.setAutonomousMotionActive(true)
        haltBase()
        waitingSince=ProcessInfo.processInfo.systemUptime
        setPhase(.acquiringMap,"Waiting for the live room map and local pose")
        timer?.invalidate()
        let clock=Timer(timeInterval:0.05,repeats:true) { [weak self] _ in self?.tick() }
        timer=clock;RunLoop.main.add(clock,forMode:.common)
        tick()
    }

    func updateLidarScanData(_ data: Data) {
        precondition(Thread.isMainThread)
        guard let frame=try? ROBLidarScanFrame.decode(data) else { return }
        guard ROBRoomSpatialStore.shared.consume(frame) else { return }
        if map != nil, ROBRoomSpatialStore.shared.map == nil {
            map=nil;planner=nil
            if active { pause("The lidar publisher or map frame changed; waiting for a new complete room map.") }
        }
        let now=ProcessInfo.processInfo.systemUptime, next=ROBRoomMissionPoint(x:Double(frame.x),y:Double(frame.y))
        let sourceChanged=mapDevice != nil && mapDevice != frame.deviceID
        if sourceChanged { map=nil;if active { pause("The authenticated lidar publisher changed; replan in its own map frame.") } }
        mapDevice=frame.deviceID
        if active, let previous=pose, now-poseAt < 1,
           sourceChanged || previous.distance(to:next)>0.35 || abs(Self.angle(Double(frame.yaw)-yaw))>0.4 {
            haltBase();goal=nil;route=[];planner=nil
            if task != nil {
                pause("Localization changed during an arm observation or transfer; hold and reacquire before continuing.")
            } else {
                searched=[]
                setPhase(.acquiringMap,"SLAM realigned; rebuilding the route from the new measured pose")
                waitingSince=now
            }
        }
        pose=next;yaw=Double(frame.yaw);poseAt=now-max(0,ROBRecycleMissionMessage.now-Double(frame.sentAtMilliseconds))/1000;scan=frame
        if let fragment=frame.mapFragment,let old=map,old.epoch != fragment.epoch {
            if active { pause("The room map was replaced. Replan within the new map frame.") }
            map=nil;planner=nil
        }
        if let complete=ROBRoomSpatialStore.shared.map {
            if active,let old=map,old.epoch != complete.epoch {
                pause("The room map was replaced. The prior search area is no longer in this coordinate frame.")
            }
            map=complete
        }
    }

    /// Every external Stop, manual takeover, sleep and disconnect invalidates
    /// the mission and in-flight callbacks. Never reopen a possibly occupied jaw.
    func stop(reason: String) { end(.stopped,reason:reason) }
    private func pause(_ detail: String) { end(.paused,reason:detail) }
    private func end(_ phase: ROBRecycleMissionMessage.Phase, reason: String) {
        guard active else { return }
        active=false;timer?.invalidate();timer=nil;task?.cancel();task=nil
        setCameraDemand?(false);ROBTraversabilityRuntime.shared.setAutonomousMotionActive(false)
        haltBase()
        if ROBLeftArmTrial.shared.isRunning {
            // Keep possible payload conservative until the executor's result.
            if message?.phase == .recycling { message?.possiblePayloadHeld=true }
            ROBLeftArmTrial.shared.cancel(reason:reason)
            ROBControllerArmApproval.shared.cancel(reason:reason)
        }
        setPhase(phase,reason)
    }
    private func haltBase() { ramp.reset();stopBase?();progressPoint=nil;progressAt=0 }
    private var grantIsLive: Bool {
        guard active,ROBRecycleMissionMessage.now<startDeadline else { return false }
        if localOwner { return true }
        guard let controller,let networkSession else { return false }
        return ROBControlLiveSessionRegistry.isActiveOperator(controllerID:controller,sessionID:networkSession)
    }
    /// The initial stationary survey precedes the arm trial. It still owns
    /// the native neck adapter, only while this mission's search is live.
    var ownsWorkspaceSearchView: Bool { grantIsLive && message?.phase == .searching }
    private func tick() {
        guard active else { return }
        guard grantIsLive else { pause("Mission ended: controller connection or duration expired. Holding the current arm pose.");return }
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastStatus>=1 { publish() }
        guard let pose,now-poseAt<=0.75,let map,
              (0...15_000).contains(ROBRecycleMissionMessage.now-map.capturedAtMilliseconds) else {
            haltBase()
            if task != nil { pause("Lidar pose or room map became stale during the task.");return }
            if now-waitingSince>30 { pause("No fresh accumulated room map. Keep RPLidar connected and mapping, then resume.") }
            return
        }
        if origin==nil { origin=pose }
        if task != nil { return }
        if message?.phase == .acquiringMap { beginSurvey();return }
        if message?.phase == .navigating { navigate(now:now,pose:pose,map:map) }
    }

    private func beginSurvey() {
        guard active,task==nil,let at=pose,let id=message?.missionID else { return }
        haltBase();goal=nil;route=[];canApproach=nil
        setPhase(.searching,"Scanning the immediate right and left table areas for cans and the orange bucket")
        task=Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let directory=Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil) else { throw ROBRoomMissionFailure("Robot model unavailable") }
                let model=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
                let right=ROBAmberGatewayClient.shared.telemetry(forArm:"left")
                let ready=right.map { $0.effectiveSampleAgeMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds &&
                    ROBCanRecyclingReadyPose.matches($0.positionsRadians.map(\.doubleValue),physicalSide:"right") } ?? false
                let found=try await ROBWorkspaceSearch.shared.run(targets:[.can,.orangeBucket],model:model,
                    surveyFrontTable:true,armAlreadyAtGraspReady:ready,
                    check:{
                        guard self.grantIsLive,self.message?.missionID==id,!Task.isCancelled,
                              self.pose.map({$0.distance(to:at)<0.05})==true else { throw ROBRoomMissionFailure("Mission or stationary survey context changed") }
                    },progress:{ self.setPhase(.searching,$0) })
                guard self.grantIsLive,self.message?.missionID==id,!Task.isCancelled else { return }
                self.searched.append(at);self.message?.searchedStops=self.searched.count
                self.task=nil
                if found[.can] != nil { self.beginRecycling() }
                else { self.planNextStop() }
            } catch {
                if self.active,self.message?.missionID==id { self.task=nil;self.pause(error.localizedDescription) }
            }
        }
    }
    private func beginRecycling() {
        guard active,task==nil,let id=message?.missionID else { return }
        haltBase()
        setPhase(.recycling,"Reobserving a nearby can and orange bucket; checking the complete right-arm transfer")
        task=Task { @MainActor [weak self] in
            guard let self else { return }
            let result: NSDictionary = await withCheckedContinuation { continuation in
                ROBLeftArmTrial.shared.performRecycleMission(authorization:{ [weak self] in
                    self?.grantIsLive==true && self?.message?.missionID==id && self?.message?.phase == .recycling
                }) { continuation.resume(returning:$0) }
            }
            guard self.message?.missionID==id else { return }
            if !self.active || Task.isCancelled {
                if result["arm_motion_sent"] as? Bool == false,result["jaw_command_sent"] as? Bool == false {
                    self.message?.possiblePayloadHeld=false;self.publish()
                }
                return
            }
            self.task=nil
            let disposition=ROBRecycleMissionOutcome.classify(result)
            switch disposition {
            case .verifiedTransfer:
                self.message?.verifiedTransfers += 1;self.message?.possiblePayloadHeld=false
                if self.message!.verifiedTransfers>=self.message!.configuration.maximumCans {
                    self.end(.finished,reason:"Requested cans verified in the orange bucket")
                } else { self.beginSurvey() }
            case .emptyPerceptionMiss:
                self.message?.possiblePayloadHeld=false
                if (try? ROBWorkspaceSearch.shared.canForBasePlanning()) != nil { self.planCanReposition() }
                else { self.planNextStop() }
            case .hold(let possiblePayload):
                self.message?.possiblePayloadHeld=possiblePayload
                self.pause(result["detail"] as? String ?? "The transfer was not verified. Holding for inspection.")
            }
        }
    }

    /// Native diagnostics entry point: plans and displays only, never starts
    /// a mission, arms a motor, or dispatches a tread/torso demand.
    func previewCanReposition() {
        guard !active else { return }
        let store = ROBRoomSpatialStore.shared
        store.canApproachPreview = nil
        do {
            let (_, proposal) = try makeCanReposition()
            store.canApproachPreview = proposal
            store.canApproachClearance = envelopeRadius
            store.canApproachDetail = approachDescription(proposal) + " Preview only; RGB-D travel corridor must be checked."
        } catch { store.canApproachDetail = error.localizedDescription }
    }

    private func approachDescription(_ proposal: ROBRoomCanApproach) -> String {
        let torso = ROBTorsoControlCenter.shared
        let correction = torso.observedHeading.isFinite ? String(format: "%+.1f° → 0°", torso.observedHeading) : "unconfirmed → base front"
        return String(format: "Can approach %.2f m to map (%.2f, %.2f), final base yaw %+.1f°. Torso %@ (front count %.0f).",
            proposal.distance, proposal.goal.x, proposal.goal.y, proposal.baseYaw*180 / .pi, correction, torso.countReference)
    }

    /// The tool offset comes from the taught horizontal ready pose, with a
    /// position-IK check at the observed can height. Full grasp/path admission
    /// still happens from a new observation after the base finishes moving.
    private func makeCanReposition() throws -> (ROBRoomMissionPlanner, ROBRoomCanApproach) {
        let store = ROBRoomSpatialStore.shared, now = ProcessInfo.processInfo.systemUptime
        guard store.poseIsFresh(at: now), store.mapIsFresh(at: now), let map = store.map, let scan = store.scan else {
            throw ROBRoomMissionFailure("Can approach needs a fresh complete RPLidar map and live SLAM pose.")
        }
        let can = try ROBWorkspaceSearch.shared.canForBasePlanning()
        if let failure = store.poseMatchFailure(capturedAtMilliseconds: can.capturedAt) {
            throw ROBRoomMissionFailure(failure)
        }
        envelopeRadius = try measuredEnvelopeRadius()
        guard let model = armModels["right"] else { throw ROBRoomMissionFailure("Right-arm model unavailable") }
        var ready = model.positions(vendorLeft: try ROBCanRecyclingReadyPose.target(physicalSide: "right"))
        ready["torso_yaw"] = 0
        let frames = model.frames(ready)
        guard let lidar = frames["rplidar_link"], let torsoFrame = frames["torso_link"],
              let tool = model.toolPosition(ready) else { throw ROBRoomMissionFailure("Ready gripper/lidar frames unavailable") }
        let torso = ROBTorsoControlCenter.shared
        let heading = torso.navigationHeading
        guard heading.isFinite else {
            throw ROBRoomMissionFailure("Torso alignment is missing. In Torso Rotation, set the software reference from its physical angle to the tread base, or acquire live camera alignment. No homing/index signal is required.")
        }
        var point = can.point
        if can.registrationID == nil {
            // The unregistered source projection uses the zero-torso model.
            // Rotate that model hypothesis about the actual torso pivot once.
            let pivot = torsoFrame.columns.3, c = cos(heading * .pi/180), s = sin(heading * .pi/180)
            let x = point.x-pivot.x, y = point.y-pivot.y
            point.x = pivot.x+c*x-s*y; point.y = pivot.y+s*x+c*y
        }
        let canInLidar = simd_inverse(lidar)*SIMD4(point.x,point.y,point.z,1)
        let c = cos(Double(scan.yaw)), s = sin(Double(scan.yaw))
        let target = ROBRoomMissionPoint(x: Double(scan.x)+c*canInLidar.x-s*canInLidar.y,
                                         y: Double(scan.y)+s*canInLidar.x+c*canInLidar.y)
        let desired = SIMD3(tool.x, tool.y, point.z)
        guard model.solveLeft(target: desired, from: ready, frontWorkspace: true) != nil else {
            throw ROBRoomMissionFailure("The can's height is outside the modeled ready-grasp workspace; horizontal base motion alone cannot fix it.")
        }
        // Planner positions are scanner poses. Remove its fixed XY offset from
        // the desired can location before choosing a final base orientation.
        let offset = ROBRoomMissionPoint(x: desired.x-lidar.columns.3.x, y: desired.y-lidar.columns.3.y)
        let at = ROBRoomMissionPoint(x: Double(scan.x), y: Double(scan.y))
        guard let planner = ROBRoomMissionPlanner(map:map,clearanceMeters:envelopeRadius,
            origin:origin ?? at,radius:message?.configuration.radiusMeters ?? 5),
              let proposal = planner.canApproach(from:at,yaw:Double(scan.yaw),can:target,preferredOffset:offset) else {
            throw ROBRoomMissionFailure("No mapped path brings this can into the ready workspace with both arm/gripper envelopes clear. Scan more floor/depth or select another can.")
        }
        return (planner, proposal)
    }

    private func planCanReposition() {
        do {
            let (planned, proposal) = try makeCanReposition()
            ROBRoomSpatialStore.shared.canApproachPreview = proposal
            ROBRoomSpatialStore.shared.canApproachClearance = envelopeRadius
            ROBRoomSpatialStore.shared.canApproachDetail = approachDescription(proposal)
            guard abs(ROBTorsoControlCenter.shared.navigationHeading) <= 3 else {
                throw ROBRoomMissionFailure(approachDescription(proposal) + " Align torso to the tread-base front with both arms raised, then reacquire the can before travel.")
            }
            planner=planned;canApproach=proposal;goal=proposal.goal;route=proposal.route
            routeRevision=planned.map.revision;routeEpoch=planned.map.epoch;arriving=false
            progressPoint=pose;progressYaw=yaw;progressAt=ProcessInfo.processInfo.systemUptime
            setPhase(.navigating, approachDescription(proposal) + " Checking live lidar + RGB-D before each movement; reacquire the can on arrival.")
        } catch { pause(error.localizedDescription) }
    }

    private func planNextStop() {
        canApproach = nil
        guard let pose,let map,let origin,let config=message?.configuration else { return }
        do {
            envelopeRadius=try measuredEnvelopeRadius()
            guard let planner=ROBRoomMissionPlanner(map:map,clearanceMeters:envelopeRadius,origin:origin,radius:config.radiusMeters) else {
                throw ROBRoomMissionFailure("Room geometry is unavailable")
            }
            guard planner.isFree(pose) else { throw ROBRoomMissionFailure("The current full robot envelope is not clear in the room map; no tread motion sent") }
            guard searched.count<256,let next=planner.path(from:pose,excluding:searched),let goal=next.last else {
                end(.finished,reason:"Search finished in the reachable mapped area. \(message?.verifiedTransfers ?? 0) verified transfers; unknown or blocked areas were not searched.");return
            }
            self.planner=planner;self.goal=goal;arriving=false;route=next;routeRevision=map.revision;routeEpoch=map.epoch
            setPhase(.navigating,"Moving gently to the next reachable observation stop; orange bucket remains the destination")
            progressPoint=pose;progressYaw=yaw;progressAt=ProcessInfo.processInfo.systemUptime
        } catch { pause(error.localizedDescription) }
    }

    private func navigate(now: Double,pose: ROBRoomMissionPoint,map: ROBRoomMissionMap) {
        guard let goal,let origin,let config=message?.configuration else { return }
        do {
            let radius=try measuredEnvelopeRadius(checkUnchanged:true)
            if routeRevision != map.revision || routeEpoch != map.epoch || abs(radius-envelopeRadius)>0.01 {
                guard let updated=ROBRoomMissionPlanner(map:map,clearanceMeters:radius,origin:origin,radius:config.radiusMeters),
                      let next=updated.path(from:pose,to:goal) else { throw ROBRoomMissionFailure("The updated room map blocks this route") }
                planner=updated;route=next;routeRevision=map.revision;routeEpoch=map.epoch;envelopeRadius=radius
            }
            guard let planner,planner.isFree(pose),let scan else { throw ROBRoomMissionFailure("Robot left the checked map corridor") }
            let atGoal = pose.distance(to:goal) < (canApproach == nil ? 0.30 : 0.08)
            let finalTurn = atGoal && canApproach != nil
            let headingError = canApproach.map { Self.angle($0.baseYaw-yaw) } ?? 0
            if atGoal && abs(headingError)<0.08 { arriving=true }
            while route.count>1 && pose.distance(to:route[0])<0.18 { route.removeFirst() }
            guard let next=route.first,planner.segmentIsFree(pose,next) else { throw ROBRoomMissionFailure("Local path is no longer clear") }
            let error=finalTurn ? headingError : Self.angle(atan2(next.y-pose.y,next.x-pose.x)-yaw)
            let turning=abs(error)>(finalTurn ? 0.08 : 0.18)
            // Live scan stops dynamic obstacles even between grid revisions.
            let relevant=scan.points.filter { turning || abs(Self.angle(Double($0.angleRadians)))<0.55 }
            guard relevant.count>=8,relevant.allSatisfy({ Double($0.distanceMeters)>envelopeRadius+0.15 }) else {
                throw ROBRoomMissionFailure("Live lidar reports an obstacle in the next movement envelope")
            }
            // The belly camera turns with the torso. A clear side-looking
            // image is not forward clearance for the tread base.
            let torso=ROBTorsoControlCenter.shared
            let cameraYaw=torso.navigationHeading * .pi / 180
            guard cameraYaw.isFinite,
                  let depth=ROBTraversabilityRuntime.shared.snapshot(),now-depth.receivedAtUptime<=0.75 else {
                throw ROBRoomMissionFailure("Waiting for fresh RGB-D and measured torso-to-base alignment for navigation")
            }
            let relevantDepth=depth.directions.filter { turning || abs(Self.angle($0.headingOffset+cameraYaw))<0.25 }
            guard !relevantDepth.isEmpty,relevantDepth.allSatisfy({$0.geometryConfidence>=0.5 && $0.depthClearanceMeters>=envelopeRadius+0.2}) else {
                throw ROBRoomMissionFailure("RGB-D does not cover a clear base travel direction; keep the camera focused on the approach")
            }
            let demand=arriving ? 0:Int((255*config.maximumTreadDemand).rounded())
            let left=turning ? (error>0 ? -demand:demand) : demand
            let right=turning ? -left:demand
            guard ramp.advance(toLeft:left,right:right,mode:0,now:now) else { throw ROBRoomMissionFailure("Navigation timer stalled; tread output stopped") }
            driveTreads?(ramp.leftCommand,ramp.rightCommand)
            if arriving,ramp.isStopped { haltBase();beginSurvey();return }
            if progressPoint==nil { progressPoint=pose;progressYaw=yaw;progressAt=now }
            let distance=pose.distance(to:progressPoint!),angle=abs(Self.angle(yaw-progressYaw))
            if distance>=0.03 || angle>=0.05 { progressPoint=pose;progressYaw=yaw;progressAt=now }
            else if now-progressAt>6 { throw ROBRoomMissionFailure("Tread demand produced no measured SLAM progress; check traction or obstruction") }
        } catch { pause(error.localizedDescription) }
    }

    /// Model radius includes BOTH measured arm/gripper envelopes, every base
    /// hull and the lidar offset. No torso angle is inferred from stepper counts.
    private func measuredEnvelopeRadius(checkUnchanged: Bool = false) throws -> Double {
        guard !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion,!ROBLeftArmTrial.shared.isRunning,
              !ROBShowMotionCoordinator.shared.isRunning,!ROBAmberGestureExecutor.shared.isExecuting else {
            throw ROBRoomMissionFailure("Finish the active arm operation before mission travel")
        }
        guard !ROBControllerArmApproval.shared.standingCanCampaignMayHoldPayload else {
            message?.possiblePayloadHeld=true
            throw ROBRoomMissionFailure("The previous native can task may hold a payload. Resolve its gripper observation before empty-arm room travel.")
        }
        let gateway=ROBAmberGatewayClient.shared
        var radius=0.0,lidarOffset=0.0
        for side in ["left","right"] {
            let key=side=="right" ? "left":"right"
            guard let sample=gateway.telemetry(forArm:key),sample.sequence>0,
                  sample.effectiveSampleAgeMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,
                  sample.positionsRadians.count==7,sample.statuses.count==7,
                  sample.statuses.allSatisfy({[0,2].contains($0.intValue)}) else { throw ROBRoomMissionFailure("Fresh stationary \(side)-arm feedback is required for base planning") }
            let q=sample.positionsRadians.map(\.doubleValue)
            if checkUnchanged,let before=armBaseline[side],!ROBArmRoutinePlan.near(q,before,tolerance:0.03) {
                throw ROBRoomMissionFailure("An arm moved during base travel; stop and replan its complete envelope")
            }
            if !checkUnchanged { armBaseline[side]=q }
            if armModels[side]==nil,let directory=Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil) {
                armModels[side]=try ROBGhostRobotModel(directory:directory,physicalSide:side)
            }
            guard let model=armModels[side] else { throw ROBRoomMissionFailure("Robot hull model unavailable") }
            let positions=model.positions(vendorLeft:q),bounds=model.worldCollisionBounds(positions:positions)
            let frames=model.frames(positions)
            guard let torso=frames["torso_link"],let lidar=frames["rplidar_link"] else {
                throw ROBRoomMissionFailure("Torso/lidar model frames unavailable")
            }
            let tx=torso.columns.3.x,ty=torso.columns.3.y
            for box in bounds.values {
                // Circumscribe every possible torso yaw about its actual
                // offset axis; a zero-yaw model pose is not the observed yaw.
                let reach=hypot(max(abs(box.low.x-tx),abs(box.high.x-tx)),max(abs(box.low.y-ty),abs(box.high.y-ty)))
                radius=max(radius,reach+hypot(tx,ty))
            }
            lidarOffset=max(lidarOffset,hypot(lidar.columns.3.x,lidar.columns.3.y))
        }
        return radius + lidarOffset + 0.04 + 0.10 // open jaw + map sampling/stop allowance; model assumption
    }
    private static func angle(_ value: Double) -> Double { atan2(sin(value),cos(value)) }
    private func setPhase(_ phase: ROBRecycleMissionMessage.Phase,_ detail: String) {
        guard message != nil else { return }
        if let old=message?.phase,old != phase {
            phaseSeconds[old.rawValue,default:0] += ProcessInfo.processInfo.systemUptime-phaseStarted
            phaseStarted=ProcessInfo.processInfo.systemUptime
        }
        message?.phase=phase;message?.detail=String(detail.prefix(2048));publish()
    }
    private func publish() {
        guard var value=message else { return }
        value.kind = .status;value.active=active;value.sequence=max(value.sequence,lastCommandSequence)
        value.sentAtMilliseconds=ROBRecycleMissionMessage.now;message=value
        if let data=try? JSONEncoder().encode(value) { UserDefaults.standard.set(data,forKey:ledgerKey) }
        UserDefaults.standard.set(controller?.uuidString,forKey:ledgerKey+".controller")
        if let data=value.encoded(),let controller,let networkSession { sendStatus?(data,controller,networkSession) };lastStatus=ProcessInfo.processInfo.systemUptime
    }
}

private struct ROBRoomMissionFailure: LocalizedError {
    let errorDescription: String?
    init(_ detail: String) { errorDescription=detail }
}
