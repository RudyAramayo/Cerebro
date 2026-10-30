import Cocoa
import CoreFoundation

/// Local commands enter the same native executors as the access panel. Camera
/// pixels and telemetry never pass through accessibility or a cloud service.
@objc(ROBLocalControlService) final class ROBLocalControlService: NSObject {
    @objc static let shared = ROBLocalControlService()
    private let socket = ROBLocalControlSocket()
    private var admission = ROBLocalControlAdmission()
    private weak var serial: ROBSerialBox?
    private var cameraDemand: ((Bool) -> Void)?
    private var stopBase: (() -> Void)?
    private var demandTimer: Timer?
    private var running = false
    private var motionID: String?
    private var timings: [String: [Double]] = [:]
    private var sleepObserver: NSObjectProtocol?
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cerebro/LocalControl")

    @objc(configureWithSerial:cameraDemand:stopBase:)
    func configure(serial: ROBSerialBox, cameraDemand: @escaping (Bool) -> Void, stopBase: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard !running else { return }
        self.serial=serial; self.cameraDemand=cameraDemand; self.stopBase=stopBase
        do {
            try socket.start(directory: Self.directory) { [weak self] data, reply in
                DispatchQueue.main.async { self?.handle(data, reply: reply) }
            }
            running=true
            sleepObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,
                object:nil,queue:.main) { _ in
                ROBRecycleMissionCoordinator.shared.stop(reason:"System sleep ended the local mission")
            }
            NSLog("Local Cerebro control ready at %@", Self.directory.appendingPathComponent("control.sock").path)
        } catch { NSLog("Local Cerebro control unavailable: %@", error.localizedDescription) }
    }
    @objc func shutdown() {
        running=false; socket.stop(); demandTimer?.invalidate(); demandTimer=nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) };sleepObserver=nil
        cameraDemand?(false); ROBInsta360CameraService.shared.setLocalControlDemandActive(false)
    }
    private func handle(_ data: Data, reply: @escaping (Data) -> Void) {
        let began=ProcessInfo.processInfo.systemUptime
        var requestID: String?; var operation="invalid"
        let finish: (Result<[String: Any], Error>) -> Void = { result in
            DispatchQueue.main.async {
                let milliseconds=(ProcessInfo.processInfo.systemUptime-began)*1000
                var values=self.timings[operation,default:[]]; values.append(milliseconds)
                self.timings[operation]=Array(values.suffix(120))
                var envelope: [String: Any] = ["version":1,"session":self.admission.session,
                    "id":requestID as Any? ?? NSNull(),"service_ms":milliseconds]
                switch result {
                case .success(let value): envelope["ok"]=true; envelope["result"]=value
                case .failure(let error): envelope["ok"]=false; envelope["error"]=error.localizedDescription
                }
                reply((try? JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys]))
                    ?? Data("{\"ok\":false,\"error\":\"Non-finite response rejected\"}".utf8))
            }
        }
        do {
            guard running else { throw ROBLocalControlError("Cerebro runtime is stopping") }
            let request=try ROBLocalControlRequest(data:data)
            requestID=request.id.uuidString; operation=request.operation
            try admission.admit(request)
            switch operation {
            case "status": try request.only([]); finish(.success(status()))
            case "mission.status": try request.only([]); finish(.success(ROBRecycleMissionCoordinator.shared.localStatus()))
            case "mission.confirm_empty":
                try request.only(["mission_id"])
                guard let id=request.parameters["mission_id"] as? String else { throw ROBLocalControlError("Supply the mission ID after inspecting the empty grippers") }
                try ROBRecycleMissionCoordinator.shared.confirmEmptyLocal(missionID:id)
                finish(.success(ROBRecycleMissionCoordinator.shared.localStatus()))
            case "runtime.profile":
                try request.only(["quiet_diagnostics","passive_startup"])
                guard !request.parameters.isEmpty,request.parameters.values.allSatisfy({ value in
                    guard let number=value as? NSNumber else {return false}
                    return CFGetTypeID(number)==CFBooleanGetTypeID()
                }) else { throw ROBLocalControlError("Specify boolean quiet_diagnostics and/or passive_startup") }
                if let quiet=request.parameters["quiet_diagnostics"] as? Bool {
                    UserDefaults.standard.set(quiet,forKey:"ROBLowOverheadDiagnostics")
                }
                if let passive=request.parameters["passive_startup"] as? Bool {
                    UserDefaults.standard.set(passive,forKey:"ROBPassiveHardwareStartup")
                }
                if request.parameters["quiet_diagnostics"] as? Bool == true {
                    let names:Set<String>=["Amber Arm Diagnostics","Torso Servo Controls","Camera Capture",
                        "Insta360 Stream Diagnostics","ROB Received VR Controller Diagnostics","Navigation"]
                    for window in NSApp.windows where names.contains(window.title) { window.close() }
                }
                finish(.success(["quiet_diagnostics":UserDefaults.standard.bool(forKey:"ROBLowOverheadDiagnostics"),
                    "passive_startup":UserDefaults.standard.bool(forKey:"ROBPassiveHardwareStartup"),
                    "camera_demand_unchanged":true,"motor_output":false]))
            case "camera.frame":
                try request.only(["camera","depth","maximum_age_ms"])
                guard let camera=request.parameters["camera"] as? String,["front","belly","panorama"].contains(camera),
                      request.parameters["depth"] == nil || request.parameters["depth"] is Bool else { throw ROBLocalControlError("Invalid camera or depth flag") }
                let age=try request.number("maximum_age_ms",default:1200,range:50...2000)
                ROBLocalObservationStore.shared.snapshot(camera:camera,includeDepth:request.parameters["depth"] as? Bool ?? false,
                    maximumAge:age,completion:finish)
            case "camera.demand":
                try request.only(["front","panorama","seconds"])
                guard let front=request.parameters["front"] as? Bool,let panorama=request.parameters["panorama"] as? Bool else {
                    throw ROBLocalControlError("Specify front and panorama booleans")
                }
                let seconds=try request.number("seconds",default:60,range:1...120)
                demandTimer?.invalidate(); cameraDemand?(front)
                ROBInsta360CameraService.shared.setLocalControlDemandActive(panorama)
                demandTimer=Timer.scheduledTimer(withTimeInterval:seconds,repeats:false) { [weak self] _ in
                    self?.cameraDemand?(false); ROBInsta360CameraService.shared.setLocalControlDemandActive(false)
                }
                finish(.success(["front":front,"panorama":panorama,"expires_after_seconds":seconds,"motor_output":false]))
            case "animation.list":
                try request.only([])
                let doc=try library()
                finish(.success(["revision":doc.revision,"sequences":doc.sequences.map {
                    ["id":$0.id.uuidString,"name":$0.name,"duration_seconds":$0.duration,"arm_speed_multiplier":$0.armSpeed]
                }]))
            case "animation.play":
                try request.only(["sequence_id","revision"])
                let doc=try library(), revision=try request.number("revision",range:0...Double(Int32.max))
                guard revision == Double(doc.revision),let id=request.parameters["sequence_id"] as? String,
                      let sequence=doc.sequences.first(where:{$0.id.uuidString.lowercased()==id.lowercased()}) else {
                    throw ROBLocalControlError("Sequence ID or library revision changed; inspect animation.list")
                }
                finish(.success(try play(sequence,id:request.id)))
            case "motion.move":
                try request.only(["values","seconds"])
                guard let numbers=request.parameters["values"] as? [String: NSNumber],!numbers.isEmpty,
                      numbers.values.allSatisfy({CFGetTypeID($0) != CFBooleanGetTypeID()}) else { throw ROBLocalControlError("Supply sparse numeric channel values in native units") }
                let values=numbers.mapValues(\.doubleValue)
                let seconds=try request.number("seconds",range:0.65...600)
                var clip=ROBAnimationClip(pose:.init(name:"Local coordinated target",values:values),transition:seconds)
                clip.easing = .linear
                finish(.success(try play(.init(name:"Local command \(request.id.uuidString)",clips:[clip]),id:request.id)))
            case "arm.mode", "gripper.command":
                try request.only(operation == "gripper.command" ? ["arm","action","intensity"] : ["arm","action"])
                guard let arm=request.parameters["arm"] as? String,["left","right"].contains(arm),
                      let action=request.parameters["action"] as? String else { throw ROBLocalControlError("Specify a physical arm and action") }
                let gripper=operation == "gripper.command"
                guard (gripper ? ["hold","release"] : ["position","deactivate"]).contains(action) else { throw ROBLocalControlError("Unsupported action") }
                let intensity = gripper && action == "hold" ? try request.number("intensity",default:1,range:1...2) : 10
                guard intensity.rounded()==intensity,
                      request.parameters["intensity"] == nil || (gripper && action == "hold") else {
                    throw ROBLocalControlError("Hold intensity must be 1 or 2; release remains 10")
                }
                let wire=arm == "right" ? "left" : "right", gateway=ROBAmberGatewayClient.shared
                if !gripper,action == "deactivate" {
                    guard let feedback=gateway.telemetry(forArm:wire),feedback.effectiveSampleAgeMilliseconds<=ROBArmFeedbackTiming.maximumAgeMilliseconds,
                          feedback.positionsRadians.count==7,feedback.positionsRadians.allSatisfy({abs($0.doubleValue)<=ROBArmRoutinePlan.tolerance}) else {
                        throw ROBLocalControlError("Return the empty arm to measured hanging before CLI deactivation")
                    }
                }
                let nativeOperation=gripper ? (action == "hold" ? "close_gripper" : "open_gripper") : action
                ROBControllerArmApproval.shared.performLocalPanelGatewayCommand(operation:nativeOperation,arm:arm,
                    summary:"Explicit local CLI \(arm) \(action)",command:{
                        if gripper {return gateway.controlGripperUsingExistingDeviceState(forArm:wire,action:action,holdIntensity:action == "hold" ? Int(intensity) : 1)}
                        return action == "position" ? gateway.enterPositionMode(forArm:wire) : gateway.deactivateArm(wire)
                    },completion:{ result in
                        let status=result["status"] as? String ?? "failed"
                        if ["completed","accepted_unverified"].contains(status) {
                            finish(.success(result as? [String:Any] ?? ["status":status]))
                        } else {finish(.failure(ROBLocalControlError(result["detail"] as? String ?? status)))}
                    })
            case "neck.pose":
                try request.only(["pan","lower","upper"])
                guard let serial,!ROBRecycleMissionCoordinator.shared.active,!ROBAnimationPlayback.shared.isRunning else { throw ROBLocalControlError("Neck runtime unavailable or native motion busy") }
                let pan=try request.number("pan",range:4000...8000),lower=try request.number("lower",range:4000...8000),upper=try request.number("upper",range:4000...8000)
                guard [pan,lower,upper].allSatisfy({$0.rounded()==$0}) else { throw ROBLocalControlError("Neck targets must be whole quarter-microseconds") }
                let result=serial.requestOperatorNeckPosePanTarget(Int(pan),lowerTarget:Int(lower),upperTarget:Int(upper))
                guard result != .rejected else { throw ROBLocalControlError(serial.neckCommandSafetyStatus) }
                finish(.success(["status":"submitted","measured_arrival":false,"detail":serial.neckCommandSafetyStatus]))
            case "torso.configure":
                try request.only(["source"])
                guard request.parameters["source"] as? String == "tic_counts",
                      !ROBRecycleMissionCoordinator.shared.active,!ROBAnimationPlayback.shared.isRunning else { throw ROBLocalControlError("Use tic_counts while native motion is idle") }
                ROBTorsoControlCenter.shared.setCountEstimate()
                finish(.success(["status":"reading_controller","motor_energized":false,"counter_reset":false]))
            case "torso.reference":
                try request.only(["observed_degrees"])
                let torso=ROBTorsoControlCenter.shared,observed=try request.number("observed_degrees",range:-180...180)
                guard torso.canSetSoftwareReference,!ROBRecycleMissionCoordinator.shared.active,!ROBAnimationPlayback.shared.isRunning else { throw ROBLocalControlError("Software alignment requires fresh stopped TIC feedback and idle motion") }
                torso.setSoftwareReference(observed)
                finish(.success(["software_reference_degrees":observed,"motor_output":false,"counter_reset":false]))
            case "torso.turn":
                try request.only(["heading_degrees"])
                let heading=try request.number("heading_degrees",range:-3600...3600)
                guard !ROBRecycleMissionCoordinator.shared.active,!ROBAnimationPlayback.shared.isRunning,
                      ROBTorsoControlCenter.shared.usesHardware else { throw ROBLocalControlError("Torso hardware is not selected or another native operation owns motion") }
                ROBTorsoControlCenter.shared.takeLocalControlAndTurn(to:heading)
                finish(.success(["status":"submitted","measured_arrival":false,"detail":ROBTorsoControlCenter.shared.status]))
            case "mission.start":
                try request.only(["maximum_cans","duration_seconds","radius_meters","maximum_tread_demand"])
                var config=ROBRecycleMissionMessage.Configuration()
                let cans=try request.number("maximum_cans",default:8,range:1...8)
                let duration=try request.number("duration_seconds",default:1800,range:60...3600)
                guard cans.rounded()==cans,duration.rounded()==duration else { throw ROBLocalControlError("Can count and duration must be whole numbers") }
                config.maximumCans=Int(cans); config.durationSeconds=Int(duration)
                config.radiusMeters=try request.number("radius_meters",default:5,range:1...10)
                config.maximumTreadDemand=try request.number("maximum_tread_demand",default:0.40,range:0.30...0.50)
                try ROBRecycleMissionCoordinator.shared.startLocal(configuration:config)
                finish(.success(ROBRecycleMissionCoordinator.shared.localStatus()))
            case "mission.plan":
                try request.only(["table_x","table_y","bucket_x","bucket_y","heading_degrees"])
                let table=ROBRecycleShuttlePlan.Point(x:try request.number("table_x",range:-10...10),y:try request.number("table_y",range:-10...10))
                let bucket=ROBRecycleShuttlePlan.Point(x:try request.number("bucket_x",range:-10...10),y:try request.number("bucket_y",range:-10...10))
                finish(.success(try ROBRecycleShuttlePlan.propose(table:table,bucket:bucket,
                    currentHeading:request.number("heading_degrees",default:0,range:-3600...3600),debugCable:ROBTorsoControlCenter.shared.debugCableMode)))
            case "stop":
                try request.only([])
                ROBRecycleMissionCoordinator.shared.stop(reason:"Local CLI Stop")
                ROBAnimationPlayback.shared.stop(reason:"Local CLI Stop")
                ROBArmRoutineCoordinator.shared.cancel(reason:"Local CLI Stop")
                ROBControllerArmApproval.shared.cancel(reason:"Local CLI Stop")
                ROBTorsoControlCenter.shared.stop(); stopBase?()
                for arm in ["left","right"] {
                    if ROBAmberGatewayClient.shared.telemetry(forArm:arm)?.statuses.contains(where:{$0.intValue==2}) == true {
                        ROBAmberGatewayClient.shared.priorityHold(forArm:arm)
                    }
                }
                finish(.success(["status":"stop_requested","measured_stopped":false]))
            default: throw ROBLocalControlError("Unsupported command")
            }
        } catch { finish(.failure(error)) }
    }
    private func library() throws -> ROBAnimationDocument {
        try ROBAnimationStore.decode(Data(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ROB Animations/library.json")))
    }
    private func play(_ sequence: ROBAnimationSequence,id:UUID) throws -> [String:Any] {
        guard let serial,!ROBRecycleMissionCoordinator.shared.active,!ROBAnimationPlayback.shared.isRunning else { throw ROBLocalControlError("Native motion is busy; query status or Stop") }
        var doc=ROBAnimationDocument(); doc.sequences=[sequence]; try doc.validate()
        ROBAnimationPlayback.shared.start(sequence:sequence,serial:serial)
        guard ROBAnimationPlayback.shared.isRunning else { throw ROBLocalControlError(ROBAnimationPlayback.shared.status) }
        motionID=id.uuidString
        return ["operation_id":id.uuidString,"status":"running","measured_arrival":false,"detail":ROBAnimationPlayback.shared.status]
    }
    private func status() -> [String:Any] {
        func finite(_ value:Double)->Any { value.isFinite ? value : NSNull() }
        let gateway=ROBAmberGatewayClient.shared, torso=ROBTorsoControlCenter.shared
        let room=ROBRoomSpatialStore.shared,scan=ROBRoomSpatialStore.shared.scan
        var arms:[String:Any]=[:]
        for (physical,wire) in [("right","left"),("left","right")] {
            guard let sample=gateway.telemetry(forArm:wire) else { arms[physical]=["available":false]; continue }
            arms[physical]=["available":true,"sequence":sample.sequence,"age_ms":finite(sample.effectiveSampleAgeMilliseconds),
                "q_radians":sample.positionsRadians,"currents_raw":sample.currents,"statuses":sample.statuses,
                "modes":gateway.modes(forArm:wire),"target_radians":gateway.targetPositions(forArm:wire)]
        }
        let pano=ROBInsta360CameraService.shared.statusSnapshot()
        let stats=timings.mapValues { values -> [String:Any] in
            let ordered=values.sorted();return ["samples":values.count,"median_ms":ordered[ordered.count/2],
                "p95_ms":ordered[min(ordered.count-1,Int(Double(ordered.count)*0.95))]]
        }
        return ["app_pid":ProcessInfo.processInfo.processIdentifier,"uptime_seconds":ProcessInfo.processInfo.systemUptime,
            "operations":ROBLocalControlRequest.operations.sorted(),"gateway":gateway.connectionSnapshot(),"arms":arms,
            "motion":["id":motionID as Any? ?? NSNull(),"running":ROBAnimationPlayback.shared.isRunning,"detail":ROBAnimationPlayback.shared.status],
            "mission":ROBRecycleMissionCoordinator.shared.localStatus(),
            "torso":["count":finite(torso.currentCount),"heading_degrees":finite(torso.observedHeading),
                "hardware_selected":torso.usesHardware,"has_software_reference":torso.hasSoftwareBaseReference,
                "front_count":torso.countReference,"detail":torso.status,"pulse_ceiling":torso.maximumPulseRate],
            "neck":["known":serial?.isNeckCommandStateKnown ?? false,"pan":serial?.commandedNeckPanTarget ?? 0,
                "lower":serial?.commandedLowerNeckTiltTarget ?? 0,"upper":serial?.commandedUpperNeckTiltTarget ?? 0,
                "detail":serial?.neckCommandSafetyStatus ?? "Unavailable"],
            "navigation":["pose_fresh":room.poseIsFresh(at:ProcessInfo.processInfo.systemUptime),
                "map_fresh":room.mapIsFresh(at:ProcessInfo.processInfo.systemUptime),
                "x_m":finite(Double(scan?.x ?? .nan)),"y_m":finite(Double(scan?.y ?? .nan)),
                "yaw_radians":finite(Double(scan?.yaw ?? .nan)),"map_revision":room.map?.revision ?? 0,
                "can_approach_detail":room.canApproachDetail],
            "cameras":ROBLocalObservationStore.shared.statistics(),
            "panorama":["enabled":pano.desiredRunning,"decoder_active":pano.decoderActive,"fps":pano.framesPerSecond,
                "frames_received":pano.framesReceived,"state":pano.state],
            "visible_windows":NSApp.windows.filter(\.isVisible).map(\.title),"rpc_timings":stats,
            "passive_hardware_startup":UserDefaults.standard.bool(forKey:"ROBPassiveHardwareStartup"),
            "quiet_diagnostics":UserDefaults.standard.bool(forKey:"ROBLowOverheadDiagnostics"),
            "camera_budget_profile":"front_rgbd_plus_insta360_panorama","runtime_network":"local_robot_LAN_only; CLI and mission do not require cloud inference"]
    }
}
