import AppKit
import CoreImage
import Darwin
import simd

/// Ephemeral admission evidence for one already-authorized waypoint. It is
/// never encoded or retained across steps/sessions. Account for start drift
/// inside the swept check's existing 5mm inflation: at most 2.5mm lies between
/// its samples, leaving this conservative 2mm budget without spending the
/// mechanical-clearance or registration margins.
struct ROBReviewedArmDispatchStart {
    let proposalID: UUID
    let index: Int
    let generation: UInt64
    let mapFingerprint: String
    let positions: [Double]
    let sequence: UInt64
    let reviewCompletedAtUptime: Double
    static let maximumStartPointDriftMeters = 0.002
    static let maximumAdmissionDelaySeconds = 0.250
    func matches(proposalID: UUID, index: Int, generation: UInt64, mapFingerprint: String,
                 positions actual: [Double], sequence: UInt64, nowUptime: Double) -> Bool {
        guard self.proposalID == proposalID, self.index == index, self.generation == generation, generation > 0,
              self.mapFingerprint == mapFingerprint, !mapFingerprint.isEmpty,
              self.positions.count == 7, actual.count == 7, (self.positions+actual).allSatisfy(\.isFinite),
              self.sequence > 0, sequence >= self.sequence, nowUptime.isFinite, reviewCompletedAtUptime.isFinite,
              (0...Self.maximumAdmissionDelaySeconds).contains(nowUptime-reviewCompletedAtUptime) else { return false }
        let pointDriftBound = 1.5*zip(self.positions,actual).reduce(0.0) { $0+abs($1.0-$1.1) }
        return pointDriftBound <= Self.maximumStartPointDriftMeters
    }
}

/// Historical failure evidence only. No image, private instruction text or
/// restored authority is encoded; the exact map is never altered for export.
enum ROBInitialRetreatFailureExport {
    static func write(recording:URL,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        baseline:[Double],goal:[Double],trial:ROBWorkspaceVisualCalibrationTrial,stage:String,
        reviewTimeMilliseconds:Double,measuredAtMilliseconds:Double,sequence:UInt64,detail:String)throws->URL {
        let directory=recording.deletingPathExtension().appendingPathExtension("initial-retreat-rejection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        func save(_ data:Data,_ name:String)throws {
            let path=directory.appendingPathComponent(name)
            // Atomic temporary files remain inside the private0700 directory.
            try data.write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        let bytes=try encoder.encode(map)
        try save(bytes,"collision-map.json")
        let report:[String:Any]=["schemaVersion":1,"kind":"initial_empty_visual_retreat_rejection_diagnostic",
            "stage":stage,"detail":detail,"motionAuthority":false,"registrationVerified":false,
            "sourceFramesNotRetained":true,"privateInstructionTextRetained":false,
            "recordingFile":recording.lastPathComponent,"physicalArm":model.physicalSide,
            "modelID":model.modelID,"referenceID":model.referenceID,"geometryID":model.geometryID,
            "mappingID":model.selectedMappingID,"resourceDirectory":model.directory.path,
            "measuredBaseline":baseline,"goal":goal,"telemetrySequence":NSNumber(value:sequence),
            "reviewTimeMilliseconds":reviewTimeMilliseconds,"measuredAtMilliseconds":measuredAtMilliseconds,
            "mapFile":"collision-map.json","mapSHA256":ROBGhostRobotModel.hash(bytes),
            "mapFingerprint":map.fingerprint,"mapByteCount":bytes.count,
            "trial":try JSONSerialization.jsonObject(with:encoder.encode(trial))]
        try save(JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),"rejection.json")
        return directory.appendingPathComponent("rejection.json")
    }
}

/// Passive scan evidence only. Encode the immutable snapshot away from the
/// main actor; no frames, instruction text or motion authority are added.
enum ROBPassiveWorkspaceMapExport {
    private static let queue = DispatchQueue(label:"com.cerebro.passive-workspace-map-export",qos:.utility)
    static func write(map:ROBWorkspaceCollisionSnapshot,recording:URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let destination=recording.deletingPathExtension().appendingPathExtension("workspace-map.json")
                    let temporary=destination.deletingLastPathComponent().appendingPathComponent(".workspace-map-export-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,
                        attributes:[.posixPermissions:0o700])
                    defer {try? FileManager.default.removeItem(at:temporary)}
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                    let file=temporary.appendingPathComponent("workspace-map.json")
                    try encoder.encode(map).write(to:file,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                    // Each recording has its own UUID; never replace another
                    // scan's archived evidence or alter its capture timestamps.
                    try FileManager.default.moveItem(at:file,to:destination)
                    continuation.resume(returning:destination)
                } catch {continuation.resume(throwing:error)}
            }
        }
    }
}

/// Raw electrical observations only: no calibrated force or contact claim.
/// A latched event cannot authorize a waypoint, reverse, restart or release.
enum ROBArmCurrentSpikeRecording {
    struct Sample:Codable {
        let sequence:UInt64,gatewaySessionGeneration:UInt64,arm:String,receivedAtMilliseconds:Double,receivedAtUptime:Double
        let positionsRadians:[Double],currentsRaw:[Double],statuses:[Int]
        let sampleAgeAtReceiptMilliseconds:Double?,effectiveSampleAgeMilliseconds:Double?
        let controllerSampleAgeMilliseconds:Double?,jointFeedbackAgeMilliseconds:[Double?]
        let gripperFeedbackAgeMilliseconds:Double?,effectiveGripperFeedbackAgeMilliseconds:Double?
        init(_ sample:ROBAmberGatewayTelemetry,sessionGeneration:UInt64) {
            func finite(_ value:Double)->Double? {value.isFinite ? value:nil}
            sequence=sample.sequence;gatewaySessionGeneration=sessionGeneration;arm=sample.arm
            receivedAtMilliseconds=sample.receivedAt.timeIntervalSince1970*1000;receivedAtUptime=sample.receivedAtUptime
            positionsRadians=sample.positionsRadians.map(\.doubleValue);currentsRaw=sample.currents.map(\.doubleValue)
            statuses=sample.statuses.map(\.intValue)
            sampleAgeAtReceiptMilliseconds=finite(sample.sampleAgeAtReceiptMilliseconds)
            effectiveSampleAgeMilliseconds=finite(sample.effectiveSampleAgeMilliseconds)
            controllerSampleAgeMilliseconds=finite(sample.controllerSampleAgeMilliseconds)
            jointFeedbackAgeMilliseconds=sample.jointFeedbackAgeMilliseconds.map{finite($0.doubleValue)}
            gripperFeedbackAgeMilliseconds=finite(sample.gripperFeedbackAgeMilliseconds)
            effectiveGripperFeedbackAgeMilliseconds=finite(sample.effectiveGripperFeedbackAgeMilliseconds)
        }
    }
    struct Hold:Codable {
        let commandID:UInt64,requestedAtMilliseconds:Double,requestedAtUptime:Double
        var acknowledgementAtMilliseconds:Double?=nil,accepted:Bool?=nil,holdConfirmed:Bool?=nil
    }
    struct Event:Codable {
        let schemaVersion=1,kind="latched_raw_current_jump_stop",currentUnits="unchanged_vendor_jointCurrent_raw"
        let calibratedForceProtection=false,motionAuthority=false,automaticReversePermitted=false
        let configuredJumpLimitRaw:Double,currentDeltaRaw:[Double],peakJumpRaw:Double,triggerJointIndices:[Int]
        let before:Sample?,trigger:Sample,detectedAtMilliseconds:Double,detectedAtUptime:Double
        let physicalArm:String,gatewayArm:String,phase:String,sessionGeneration:UInt64
        let summarySHA256:String,proposalID:String?,proposalSHA256:String?,proposalKind:String?,stepIndex:Int
        let proposedStepPositionsRadians:[Double]?,proposedStepSeconds:Double?,mapFingerprint:String?
        let modelID:String?,referenceID:String?,geometryID:String?,mappingID:String?
        let cameraGeneration:String,cameraFrameGeneration:String?,cameraFrameSequence:UInt64?,cameraFrameCapturedAtMilliseconds:Double?
        let runtimeCalibrationIdentity:String?,bodyMotionIdentity:String,estimatedCameraProjectionIdentity:String?
        let possiblePayloadHeldAtTrigger:Bool
        var holds:[Hold]=[],postStopSamples:[Sample]=[]
        var postStopWindowSeconds=1.0,postStopCollectionCompleted=false,postStopCollectionCompletedAtMilliseconds:Double?=nil
    }
    static func write(_ event:Event,recordingPath:String,proposal:ROBLeftGestureProposal?)throws->URL {
        let directory=URL(fileURLWithPath:recordingPath).deletingPathExtension().appendingPathExtension("current-spike")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        func save(_ bytes:Data,_ name:String)throws {
            let path=directory.appendingPathComponent(name);try bytes.write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        if let proposal,event.proposalSHA256==proposal.fingerprint {try save(proposal.encoded(),"proposal.json")}
        try save(encoder.encode(event),"event.json")
        return directory.appendingPathComponent("event.json")
    }
}

/// Operator-supervised trials with fresh scene evidence and a complete
/// dynamically checked arm sweep. Physical geometry still needs commissioning.
/// Physical sides are explicit: LEFT=R11/gateway right, RIGHT=L10/gateway left.
/// Existing left gesture commands retain their original scope; right recycling
/// has an independent model mapping and one-shot approval.
/// Private perception files only. This loader never imports an arm grant.
private struct ROBSourcePixelArchiveInputs {
    let manifestJSON:Data,sourceMapJSON:Data,frames:[ROBWorkspaceSourcePixelSelf.ReplayFrame]
    static func privateFile(_ url:URL,limit:Int)throws->Data {
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard url.isFileURL,attributes[.type]as?FileAttributeType == .typeRegular,
              (attributes[.posixPermissions]as?NSNumber).map({$0.intValue & 0o077 == 0})==true,
              (attributes[.ownerAccountID]as?NSNumber)?.uint32Value==getuid(),
              let size=(attributes[.size]as?NSNumber)?.intValue,size>=0,size<=limit else {
            throw ROBGhostMotionError.blocked("Experimental pixel review requires bounded private regular files owned by the current user.")
        }
        let bytes=try Data(contentsOf:url)
        guard bytes.count==size else {throw ROBGhostMotionError.blocked("A pixel evidence file changed during reading.")}
        return bytes
    }
    static func load(directory:URL)throws->Self {
        let root=directory.standardizedFileURL
        let attributes=try FileManager.default.attributesOfItem(atPath:root.path)
        guard root.isFileURL,root.path==root.resolvingSymlinksInPath().path,
              attributes[.type]as?FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions]as?NSNumber).map({$0.intValue & 0o077 == 0})==true else {
            throw ROBGhostMotionError.blocked("The reviewed raw archive must be a private original directory, not a symlink.")
        }
        let manifestData=try privateFile(root.appendingPathComponent("manifest.json"),limit:1_000_000)
        let manifest=try JSONDecoder().decode(ROBWorkspaceRawScanArchive.Manifest.self,from:manifestData)
        guard manifest.schemaVersion==1,manifest.kind=="raw_workspace_pixel_provenance_only",manifest.status=="complete",
              !manifest.motionAuthority,!manifest.classificationAuthority,(1...14).contains(manifest.frames.count),
              let binding=manifest.sourceMapBinding,binding.relativePath=="source-map.json",
              binding.workspaceSceneID==manifest.scene.workspaceSceneID else {
            throw ROBGhostMotionError.blocked("Experimental review requires a complete native raw archive and final source-map binding.")
        }
        let mapData=try privateFile(root.appendingPathComponent(binding.relativePath),limit:64_000_000)
        guard ROBGhostRobotModel.hash(mapData)==binding.serializedSHA256 else {throw ROBGhostMotionError.blocked("Raw source-map bytes changed.")}
        var total=manifestData.count+mapData.count,frames:[ROBWorkspaceSourcePixelSelf.ReplayFrame]=[]
        for record in manifest.frames {
            guard record.relativeDirectory==record.frameID.uuidString else {throw ROBGhostMotionError.blocked("A source frame path is not its exact native UUID directory.")}
            let folder=root.appendingPathComponent(record.relativeDirectory,isDirectory:true)
            guard folder.path==folder.resolvingSymlinksInPath().path else {throw ROBGhostMotionError.blocked("A source frame directory is a symlink.")}
            let metadata=try privateFile(folder.appendingPathComponent("frame.json"),limit:1_000_000)
            guard ROBGhostRobotModel.hash(metadata)==record.metadataSHA256,
                  let object=try JSONSerialization.jsonObject(with:metadata)as?[String:Any],
                  object["rgbPath"]as?String=="rgb888.raw",object["depthPath"]as?String=="depth-u16le.raw" else {
                throw ROBGhostMotionError.blocked("Raw frame metadata/hash/path changed.")
            }
            let rgb=try privateFile(folder.appendingPathComponent("rgb888.raw"),limit:8_000_000)
            let depth=try privateFile(folder.appendingPathComponent("depth-u16le.raw"),limit:5_000_000)
            guard ROBGhostRobotModel.hash(rgb)==record.rgbSHA256,ROBGhostRobotModel.hash(depth)==record.depthSHA256 else {
                throw ROBGhostMotionError.blocked("Original RGB/depth evidence bytes changed.")
            }
            total+=metadata.count+rgb.count+depth.count
            guard total<=64_000_000 else {throw ROBGhostMotionError.blocked("Pixel evidence exceeds the private64MB source budget.")}
            frames.append(.init(metadataJSON:metadata,rgb888:rgb,depthU16LittleEndian:depth))
        }
        return .init(manifestJSON:manifestData,sourceMapJSON:mapData,frames:frames)
    }
}

/// Value-only diagnostics for the unchanged250ms/3mm stationary hold guard.
private enum ROBHeldArmFeedbackGuard {
    static func failures(present:Bool,motorAge:Double,gripperAge:Double,q:[Double],expectedQ:[Double],
        gatewayModes:[Int],reportedModes:[Int],expectedModes:[Int])->[String] {
        var fields:[String]=[]
        if !present {fields.append("telemetry_missing")}
        if !(motorAge<=250) {fields.append("motor_age_ms")}
        if !(gripperAge<=250) {fields.append("gripper_age_ms")}
        if q.count != 7 || expectedQ.count != 7 || !q.allSatisfy(\.isFinite) {fields.append("joint_positions")}
        if gatewayModes != expectedModes {fields.append("gateway_modes")}
        if reportedModes != expectedModes {fields.append("reported_modes")}
        if q.count==7,expectedQ.count==7,
           !(1.5*zip(q,expectedQ).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003) {fields.append("position_drift_m")}
        return fields
    }
    static func agesOnly(_ fields:[String])->Bool {!fields.isEmpty && fields.allSatisfy{["motor_age_ms","gripper_age_ms"].contains($0)}}
}
private struct ROBPassiveFeedbackPause:LocalizedError {
    let detail:String
    var errorDescription:String? {detail}
}

@objcMembers final class ROBLeftArmTrial: NSObject {
    static let shared = ROBLeftArmTrial()
    static let commands = ["left_wave", "left_prepare", "left_grip", "left_release", "left_relax", "left_object_cycle",
        "left_pick_place", "left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance",
        "left_estimated_preview", "left_estimated_calibration",
        "right_estimated_preview", "right_estimated_trial", "right_recycle_can", "right_recycle_two_cans", "right_recycle_three_cans", "left_recycle_two_cans", "right_search_workspace", "right_scan_clearance"] + ROBRecyclingBatchRequest.configuredCommands
    private static let neckOnlyCommands = ["left_search_workspace", "left_check_hanging", "left_scan_clearance", "left_estimated_preview"]
    @nonobjc private var workspaceSearchTargets = ROBWorkspaceTarget.allCases
    static let currentLimitKey = "ROBLeftArmCurrentJumpLimitRaw"
    private(set) var isRunning = false
    var isNeckOnlyInspection: Bool { isRunning && Self.neckOnlyCommands.contains(activeCommand) }
    var preservesRegisteredHeadView: Bool { isRunning && (activeCommand == "left_recycle_can" || physicalSide == "right" && activeCommand == "left_estimated_calibration") }
    private(set) var status = "Left arm ready for a supervised trial"
    private(set) var lastRecordingPath = ""
    /// Local readiness within the one controller-approved object cycle.
    /// Empty outside a wait; callers must echo the displayed expected stage.
    private(set) var interactionStage = ""
    var statusChanged: ((String) -> Void)?
    @nonobjc var recordingDirectory: URL?
    @nonobjc var canReachCalibrationFile = ROBLeftCanReachCalibration.file
    @nonobjc var recyclingTestParametersFile = ROBRecyclingTestParameters.file
    @nonobjc private(set) var collisionReviewStatus: NSDictionary = ["status":"not_scanned", "detail":"Scan current depth before planning arm travel."]
    @nonobjc private(set) var collisionReviewProposal: ROBLeftGestureProposal?
    @nonobjc private var collisionMap: ROBWorkspaceCollisionSnapshot?
    @nonobjc private var collisionModel: ROBGhostRobotModel?
    private var sceneCapturedForThisTask = false
    private var armTravelDispatched = false
    private var jawCommandDispatched = false
    private var jawSetupDispatchUncertain = false
    private var servoPossiblePayloadUncertain = false
    private var recyclingReachDispatched = false
    private var localReceiptCommand: String?
    private var localReceiptContextIdentity: String?
    private var localReceiptEvidence: NSDictionary?
    private var localReceiptHeldNeckIdentity: String?
    private var localReceiptPerceptionFailure = false
    private var passiveFeedbackPauseStarted:Double?
    private var lastHeldFeedbackDiagnostic:String?
    private var localCameraPreparationTask:Task<Void,Never>?
    @nonobjc private var localReceiptContextComponents: [String:String]?
    @nonobjc private(set) var localRecyclingContextDiagnostics: NSDictionary = [:]
    @nonobjc private var localReceiptModel: ROBGhostRobotModel?
    private var localReceiptCameraTimer: Timer?
    @nonobjc private var activeLocalRetreat: ROBWorkspaceInitialEmptyRetreat?
    @nonobjc private var activeNominalRetreat: ROBWorkspaceNominalEmptyCommissioningRetreat?
    @nonobjc var nominalEmptyCommissioningStepEnabled = false
    @nonobjc var nominalModelAssumedSelfEnabled = false
    @nonobjc var sourcePixelSelfReviewEnabled=false
    @nonobjc private var sourcePixelTemplate:ROBWorkspaceSourcePixelSelf.Template?
    private var sourcePixelTemplateSHA256:String?,sourcePixelTemplatePath:String?
    @nonobjc private var sourcePixelCurrentView:ROBWorkspaceSourcePixelSelf.View?
    private var sourcePixelCurrentMapFingerprint:String?
    private var sourcePixelCurrentSourceMapJSON:Data?,sourcePixelCurrentEvidenceSHA256:String?
    private var sourcePixelPreparationTask:Task<Void,Never>?
    private var sourcePixelPreparationID:UUID?
    private static let sourcePixelQueue=DispatchQueue(label:"com.orbitusrobotics.source-pixel-review",qos:.userInitiated)
    private var usesFixedCommissioningKeyframes:Bool {nominalModelAssumedSelfEnabled || sourcePixelSelfReviewEnabled}
    private var currentSourcePixelEvidenceSHA256:String? {sourcePixelSelfReviewEnabled ? sourcePixelCurrentEvidenceSHA256:nil}
    @nonobjc private var activeOneDegreeCalibration: ROBWorkspaceOneDegreeEmptyCalibrationStep?
    @nonobjc var oneDegreeEmptyCalibrationStepEnabled = false
    /// DEBUG-only early stop on the ordinary, fully checked empty entry path.
    @nonobjc var approachUnknownAdvisoryEnabled = false
    private var activeApproachUnknownAdvisory = false
    @nonobjc var approachCanThenHoldEnabled = false
    private var activeApproachCanThenHold = false
    @nonobjc var holdAfterInitialEmptyLiftEnabled = false
    private var activeHoldAfterInitialEmptyLift = false
    private var initialEmptyLiftHeldEvidence: NSDictionary?
    var localVisualTrialAssumedSpatialErrorMeters = 0.05
    @nonobjc private var sceneHold: [String:(positions:[Double],modes:[Int])] = [:]
    @nonobjc private var reviewedDispatchStart: ROBReviewedArmDispatchStart?

    private(set) var physicalSide = "left"
    @nonobjc var executionGatewayArm: String { physicalSide == "left" ? "right" : "left" }
    private var arm: String { executionGatewayArm }
    @nonobjc var rightCanReachCalibrationFile = ROBLeftCanReachCalibration.file(forPhysicalSide:"right")
    @nonobjc private var selectedCanReachCalibrationFile: URL {
        physicalSide == "left" ? canReachCalibrationFile : rightCanReachCalibrationFile
    }
    private func selectPhysicalSide(_ side: String) {
        guard physicalSide != side else { return }
        physicalSide = side; referencedGeneration = 0; recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        collisionMap = nil; collisionModel = nil; collisionReviewProposal = nil
        collisionReviewStatus = ["status":"not_scanned","detail":"Physical arm changed; scan its current scene before planning."]
    }
    private let gateway = ROBAmberGatewayClient.shared
    private let vision = ROBArmRoutineVision.shared
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var ackObserver: NSObjectProtocol?
    private var sampleObserver: NSObjectProtocol?
    private var acks: [UInt64: Bool] = [:]
    private var holdConfirmations: [UInt64: Bool] = [:]
    private var waiting: Set<UInt64> = []
    private var leaseRenewals: [UInt64: Double] = [:]
    private var owner: UUID?
    private var generation: UInt64 = 0
    private var referencedGeneration: UInt64 = 0
    private var deadline = 0.0
    private var summary = ""
    private var failure: String?
    private var cameraReady = false
    private var positionReady = false
    private var allowsArmTravel = false
    private var leased = false
    private var lastRenewal = 0.0
    private var log: FileHandle?
    private var logStarted = 0.0
    private var lastSequence: UInt64 = 0
    private var previousCurrents: [Double]?
    private var currentLimit = 0.0
    @nonobjc private var previousCurrentEvidence:ROBArmCurrentSpikeRecording.Sample?
    @nonobjc private var currentSpikeEvidence:ROBArmCurrentSpikeRecording.Event?
    private var currentSpikeEvidencePath="",currentSpikeEvidenceWriteError:String?
    private var currentSpikePostStopDeadline:Double?
    private var currentSpikeCollectionFinished=false
    private var currentSpikeCompletionTask:Task<Void,Never>?
    private var peakJump = 0.0
    private var sampleCount = 0
    private var delayedSampleCount = 0
    private var maxDelayedSampleAge = 0.0
    private var phase = "preflight"
    private var activeCommand = ""
    private var requestedCanCount = 1
    @nonobjc private var recyclingCan: ROBWorkspaceLocatedObject?
    @nonobjc private var recyclingDestination:ROBWorkspaceLocatedObject?
    @nonobjc private var nativeCanAttachment:ROBNativeCanAttachment?
    @nonobjc private var nativeCarryServoContext:ROBRecyclingVisualInspection.ServoContext?
    @nonobjc private var nativeCarryDispatchTicket:ROBNativeCanAttachment.DispatchTicket?
    @nonobjc private var lastVisualGraspEvidence: ROBVisualGraspVerifier.Evidence?
    private var movingTargetReplansRemaining = 1
    private var localCampaignRecoveryReason: ROBStandingCanCampaignRecoveryReason?
    private var localCampaignRecoveryTask: Task<Void,Never>?
    private var standingPreparationTask:Task<Void,Never>?
    @nonobjc private var nominalBothArmHistory:[String:[(generation:UInt64,sample:ROBAmberGatewayTelemetry)]] = [:]
    private var nominalArchiveLastSequence:UInt64=0
    private var nominalArchiveTimes:[(stage:String,time:Double)]=[]
    private var servoTelemetryHistory:[(generation:UInt64,sample:ROBAmberGatewayTelemetry)]=[]


    private var recyclingGripDispatched = false
    private var inactiveWorkspaceSearch = false
    private var readinessConfirmed = false
    private var jawIntensity = 10
    @nonobjc private var taskJawTarget: [Double]?
    private var taskOpeningCommandAtMilliseconds:Double?
    private var servoEvidenceWriteError:String?
    @nonobjc private var proposal: ROBLeftGestureProposal?
    private var proposalStep = -1
    @nonobjc private var sentPath: [[Double]] = []
    @nonobjc private var recoveryPath: [[Double]] = []
    private var recoveryGeneration: UInt64 = 0
    @nonobjc private var offeredRecovery: ROBLeftGestureProposal?

    // These are session-local review evidence, never an actuator grant. The
    // dedicated approval consumes the pending proof exactly once.
    private struct EstimatedPreview {
        let proof: ROBEstimatedArmCalibrationPlan
        let map: ROBWorkspaceCollisionSnapshot
        let model: ROBGhostRobotModel
        let proposal: ROBLeftGestureProposal
        let otherArmHold: (positions: [Double], modes: [Int])
        let geometryValidationFingerprint:String
        let resourceFingerprint:String
    }
    @nonobjc private var pendingEstimated: EstimatedPreview?
    @nonobjc private var activeEstimated: EstimatedPreview?
    private var estimatedPreviewTimer: Timer?
    private var estimatedCameraRetained = false
    private var estimatedApprovalPending = false

    @nonobjc func prepareEstimatedCalibration(completion: @escaping (NSDictionary) -> Void) {
        perform("left_estimated_preview", completion: completion)
    }

    /// Deliberately uses the one-shot manual lane, never a remembered rehearsal
    /// session. The operator confirms EMPTY jaws and visually clear local space.
    @nonobjc func performEstimatedCalibration(completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                  !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
                  !ROBControllerArmApproval.shared.isPending, let pending = pendingEstimated, pending.model.physicalSide==physicalSide else {
                throw ROBArmRoutineError.blocked("Prepare and review a fresh estimated single-step preview first; finish other operations.")
            }
            try validateEstimatedContext(pending, generation: pending.proof.sessionGeneration)
            guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue), baseline: pending.proof.baseline) else {
                throw ROBArmRoutineError.blocked("The arm moved from its frozen estimated start; prepare a new preview.")
            }
            let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
            guard limit.isFinite, limit >= 0 else { throw ROBArmRoutineError.blocked("Invalid current jump threshold.") }
            let changes = zip(pending.proof.baseline,pending.proof.target).enumerated().map {
                String(format:"J%d %+.4f rad",$0.offset+1,$0.element.1-$0.element.0)
            }.joined(separator:"; ")
            let text = "ONE estimated EMPTY physical \(physicalSide.uppercased())-arm retreat away from the table over 4 seconds: \(changes), modeled vertex travel \(Int(ceil(pending.proof.maximumVertexDisplacementMeters*1000))) mm. Confirm empty jaws and visually clear the complete arm and its surrounding local working space. Camera registration remains UNVERIFIED. This supervised EMPTY retreat may start inside the estimated 150 mm depth margin: recorded existing nearby cells must have at least 100 mm plus jaw allowance of modeled starting separation and move farther from the arm at every checked pose, with strict final improvement. New margin intrusions still block. These are estimated geometry checks, not measured collision protection. No grasp, jaw command, encoder reset, torque-off, return or repeat. Hold at the measured finish and report physical direction. Proof \(pending.proof.id.uuidString); scene \(pending.map.sceneID.uuidString); map SHA256 \(pending.map.fingerprint). Keep Stop + hold ready."
            estimatedApprovalPending = true
            update("Awaiting approval for one estimated empty-arm calibration step")
            ROBControllerArmApproval.shared.request(operation: "manual", arm: physicalSide, summary: text,
                execute: { [weak self] done in
                    guard let self else { return }
                    self.estimatedApprovalPending = false
                    do {
                        guard self.pendingEstimated?.proof == pending.proof else {
                            throw ROBArmRoutineError.blocked("The estimated preview expired or was consumed; no motion sent.")
                        }
                        try self.validateEstimatedContext(pending, generation: pending.proof.sessionGeneration)
                        guard self.estimatedStartMatches(try self.measured().positionsRadians.map(\.doubleValue),baseline:pending.proof.baseline) else {
                            throw ROBArmRoutineError.blocked("The measured arm changed while awaiting approval; no motion sent.")
                        }
                        self.estimatedPreviewTimer?.invalidate(); self.estimatedPreviewTimer = nil
                        self.pendingEstimated = nil
                        self.activeEstimated = pending; self.proposal = pending.proposal
                        self.start("left_estimated_calibration",summary:text,limit:limit,completion:done)
                        if !self.isRunning { self.activeEstimated = nil; self.releaseEstimatedCamera() }
                    } catch {
                        self.invalidateEstimatedPreview(reason:error.localizedDescription)
                        done(["status":"blocked","arm_motion_sent":false,"detail":error.localizedDescription])
                    }
                }, cancel: { [weak self] in self?.abort("Estimated calibration declined or stopped; no further motion authorized.") },
                completion: { [weak self] result in
                    self?.estimatedApprovalPending = false
                    if self?.isRunning != true { self?.invalidateEstimatedPreview(reason:"Estimated calibration approval ended") }
                    completion(result)
                })
        } catch {
            invalidateEstimatedPreview(reason:error.localizedDescription)
            completion(["status":"blocked","arm_motion_sent":false,"detail":error.localizedDescription])
        }
    }

    private func estimatedGeometryFingerprint(proof:ROBEstimatedArmCalibrationPlan,map:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,proposal:ROBLeftGestureProposal) throws ->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var bytes=try encoder.encode(proof)
        bytes.append(Data("|\(proposal.fingerprint)|\(map.fingerprint)|\(model.modelID)|\(model.referenceID)|\(model.geometryID)|\(model.selectedMappingID)|\(model.physicalSide)".utf8))
        return ROBGhostRobotModel.hash(bytes)
    }
    private func estimatedResourceFingerprint(model:ROBGhostRobotModel) throws ->String {
        let paths=["model.urdf","reference.json","surfaces.json"]+Array(Set(model.hulls.values)).sorted()
        var bytes=Data()
        for path in paths {
            bytes.append(Data(path.utf8));bytes.append(0)
            bytes.append(Data(ROBGhostRobotModel.hash(try Data(contentsOf:model.directory.appendingPathComponent(path))).utf8))
        }
        return ROBGhostRobotModel.hash(bytes)
    }

    private func estimatedStartMatches(_ actual: [Double], baseline: [Double]) -> Bool {
        actual.count == 7 && baseline.count == 7 && actual.allSatisfy(\.isFinite) &&
            1.5*zip(actual,baseline).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= ROBReviewedArmDispatchStart.maximumStartPointDriftMeters
    }

    private func estimatedCorridorMatches(_ actual: [Double], proof: ROBEstimatedArmCalibrationPlan) -> Bool {
        guard actual.count == 7, proof.baseline.count == 7, proof.target.count == 7,
              (actual+proof.baseline+proof.target).allSatisfy(\.isFinite) else { return false }
        let delta = zip(proof.baseline,proof.target).map { $1-$0 }
        let squaredLength = delta.reduce(0.0) { $0+$1*$1 }
        guard squaredLength.isFinite, squaredLength > 0 else { return false }
        let projection = zip(zip(actual,proof.baseline),delta).reduce(0.0) { $0+($1.0.0-$1.0.1)*$1.1 } / squaredLength
        let fraction = min(1,max(0,projection))
        let nearest = zip(proof.baseline,delta).map { $0+fraction*$1 }
        return 1.5*zip(actual,nearest).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003
    }

    private func validateEstimatedContext(_ value: EstimatedPreview, generation: UInt64) throws {
        let proof = value.proof, path = value.proposal
        guard Thread.isMainThread else {throw ROBArmRoutineError.blocked("Estimated arm context must be reviewed on the control thread.")}
        if physicalSide == "left", value.map.registrationID == nil {
            guard MainActor.assumeIsolated({
                ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:value.model,map:value.map)
            }) else {
                throw ROBArmRoutineError.blocked("The estimated camera mount changed after the LEFT preview; capture a fresh scene before moving.")
            }
        }
        if physicalSide == "right" {
            guard MainActor.assumeIsolated({
                ROBRecyclingVisualInspection.fixedHeadContextIsCurrent(model:value.model,map:value.map) ||
                ROBWorkspaceSearch.shared.estimatedContextIsCurrent(model:value.model,map:value.map)
            }) else {
                throw ROBArmRoutineError.blocked("The fixed estimated or registered head/body/camera context changed after the RIGHT preview; no probe admitted.")
            }
        }
        guard value.geometryValidationFingerprint == (try estimatedGeometryFingerprint(proof:proof,map:value.map,model:value.model,proposal:path)),
              value.model.physicalSide==physicalSide, gateway.isReady(),
              (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation,
              let current = ROBWorkspaceSearch.shared.collisionSnapshot,
              current.sceneID == value.map.sceneID, current.fingerprint == value.map.fingerprint,
              path.kind == "estimated_calibration", path.id == proof.id,
              path.modelID == proof.modelID, path.referenceID == proof.referenceID,
              path.geometryID == proof.geometryID, path.mappingID == proof.mappingID,
              path.sessionGeneration == proof.sessionGeneration, path.baseline == proof.baseline, path.steps == proof.steps,
              path.poses.isEmpty, path.workspaceCollisionPlan == nil, path.workspaceApproachPlan == nil,
              path.recyclingActions == nil, path.recyclingParameters == nil,
              zip(proof.target,ROBArmJointLimits.radians).allSatisfy({ $1.contains($0) }) else {
            throw ROBArmRoutineError.blocked("The single-step estimated proof, scene or arm connection changed; no motion admitted.")
        }
        try proof.validateContext(map:value.map,model:value.model,generation:generation,
            cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
        if activeCommand == "left_estimated_calibration",
           !estimatedCorridorMatches(try measured().positionsRadians.map(\.doubleValue),proof:proof) {
            throw ROBArmRoutineError.blocked("Measured LEFT joints left the approved estimated retreat corridor; hold requested.")
        }
        let held = value.otherArmHold, otherGatewayArm = arm == "right" ? "left" : "right"
        guard let sample = gateway.telemetry(forArm:otherGatewayArm), sample.effectiveSampleAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7, sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              gateway.modes(forArm:otherGatewayArm).map(\.intValue) == held.modes,
              sample.statuses.map(\.intValue) == held.modes,
              1.5*zip(sample.positionsRadians.map(\.doubleValue),held.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003 else {
            throw ROBArmRoutineError.blocked("The other arm moved, changed mode or lost fresh feedback; hold the estimated trial.")
        }
    }

    private func releaseEstimatedCamera() {
        if estimatedCameraRetained {
            estimatedCameraRetained = false
            // A different operation may already have acquired camera demand.
            // Relinquish this preview without switching that owner's view off.
            if !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning,
               !ROBAmberGestureExecutor.shared.isExecuting {
                vision.setActive(false); ROBArmRoutineCoordinator.shared.cameraDemand?(false)
            }
        }
    }

    private func invalidateEstimatedPreview(reason: String, stopCamera: Bool = true) {
        estimatedPreviewTimer?.invalidate(); estimatedPreviewTimer = nil
        pendingEstimated = nil
        if collisionReviewProposal?.kind == "estimated_calibration" { collisionReviewProposal = nil }
        let cancelApproval = estimatedApprovalPending; estimatedApprovalPending = false
        if stopCamera, !isRunning { releaseEstimatedCamera() }
        if cancelApproval { ROBControllerArmApproval.shared.cancel(reason:reason) }
    }

    private func retainEstimatedPreviewCamera() {
        estimatedCameraRetained = true
        estimatedPreviewTimer?.invalidate()
        let timer = Timer(timeInterval:0.25,repeats:true) { [weak self] _ in
            guard let self, let pending = self.pendingEstimated else { return }
            do {
                guard !self.isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                      !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting else {
                    throw ROBArmRoutineError.blocked("Another operation replaced the estimated preview.")
                }
                try self.validateEstimatedContext(pending,generation:pending.proof.sessionGeneration)
                guard self.estimatedStartMatches(try self.measured().positionsRadians.map(\.doubleValue),baseline:pending.proof.baseline) else {
                    throw ROBArmRoutineError.blocked("The estimated preview start changed; capture a new preview.")
                }
            } catch { self.invalidateEstimatedPreview(reason:error.localizedDescription); self.update(error.localizedDescription) }
        }
        estimatedPreviewTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }

    /// Local review is not actuator permission: execution still starts only
    /// after the authenticated phone/Vision controller accepts this exact hash.
    @nonobjc func perform(proposal: ROBLeftGestureProposal, model: ROBGhostRobotModel,
                          completion: @escaping (NSDictionary) -> Void) {
        precondition(Thread.isMainThread)
        do {
            guard !["estimated_calibration","incremental_visual_servo_grasp_hold"].contains(proposal.kind) else {
                throw ROBArmRoutineError.blocked("Estimated calibration cannot execute through the generic gesture lane. Use its fresh single-step approval.")
            }
            if !isRunning { invalidateEstimatedPreview(reason:"Another gesture replaced the estimated preview") }
            guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
                  !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
                  !ROBControllerArmApproval.shared.isPending else { throw ROBGhostMotionError.blocked("Finish the active operation first.") }
            guard !proposal.steps.contains(where:{ $0.jawAction == .grip || $0.jawAction == .release }) ||
                  proposal.workspaceCollisionPlan?.payload?.valid == true else {
                throw ROBGhostMotionError.blocked("Measure the carried object and review its complete sweep before requesting a grasp-and-carry motion.")
            }
            if proposal.kind == "recover" {
                guard offeredRecovery == proposal, recoveryGeneration == proposal.sessionGeneration else {
                    throw ROBGhostMotionError.blocked("The recovery path changed; review it again.")
                }
            } else {
                let map = ROBWorkspaceSearch.shared.collisionSnapshot
                try ROBLeftGestureCompiler.validate(proposal,model:model,collisionMap:map,
                    collisionSceneID:map?.sceneID,collisionCameraGeneration:map?.cameraGeneration)
            }
            let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
            guard limit.isFinite, limit >= 0 else { throw ROBGhostMotionError.blocked("Invalid current jump threshold.") }
            selectPhysicalSide(model.physicalSide)
            let range = (0..<7).map { index in
                let values = [proposal.baseline[index]] + proposal.steps.map { $0.positions[index] }
                return String(format: "J%d %.2f…%.2f", index + 1, values.min()!, values.max()!)
            }.joined(separator: "; ")
            let current = limit == 0 ? "Record currents only; automatic cutoff is not configured."
                : "Hold on a sample-to-sample current jump above \(limit) raw units; not a calibrated force limit."
            let scope = ["tabletop", "recycling"].contains(proposal.kind)
                ? "Complete a fixed-station can-to-bucket attempt using startup gripper readiness and a fresh full-arm collision review. Open before approach, grip, lift, carry, release above the bucket and retreat held. One approval covers the path. Supervise actual jaw opening and pickup; retention and placement remain unmeasured."
                : "Move only the empty physical LEFT arm; jaws unchanged."
            let text = "Reviewed ghost gesture ‘\(proposal.name)’: \(proposal.steps.count) steps, \(Int(ceil(proposal.seconds))) seconds scheduled, maximum 180 seconds including settling. \(range). Proposal \(proposal.id.uuidString), SHA256 \(proposal.fingerprint). \(scope) Camera centers at upright lower 6011 / upper 6306. Confirm physically hanging at encoder zero for the first movement of this session. Model/encoder mapping uses the recorded upright prior; watch actual arm, tread and cable clearance. This is a supervised trial, not certified collision or force protection. Keep Stop + hold ready; keep the controller open when using controller approval. \(current)"
            update("Awaiting controller approval for reviewed ghost: \(proposal.name)")
            let execute: (@escaping (NSDictionary) -> Void) -> Void = { [weak self] done in
                guard let self else { return }
                self.proposal = proposal
                self.start("left_ghost", summary:text, limit:limit, completion:done)
            }
            let cancelled = { [weak self] in self?.abort("Controller cancelled the ghost gesture; hold requested."); return }
            let finished: (NSDictionary) -> Void = { [weak self] result in self?.update(result["detail"] as? String ?? "Ghost gesture ended"); completion(result) }
            if model.physicalSide == "right" {
                ROBControllerArmApproval.shared.requestRightWorkspaceTask(summary:text,execute:execute,cancel:cancelled,completion:finished)
            } else {
                ROBControllerArmApproval.shared.requestLeftGesture(summary:text,execute:execute,cancel:cancelled,completion:finished)
            }
        } catch { completion(["status": "blocked", "detail": error.localizedDescription]) }
    }

    /// Only the single currently dispatched step of the frozen accepted path
    /// is admitted. No caller supplies raw targets to the gateway.
    @nonobjc func approvedGestureTarget(id: UUID, index: Int, seconds: Double, generation: UInt64) -> [Double]? {
        guard let proposal, proposal.id == id, proposal.sessionGeneration == generation,
              proposalStep == index, proposal.steps.indices.contains(index),
              abs(proposal.steps[index].seconds - seconds) < 0.000001,
              authorizesTaughtWaypoint(arm: arm, expectedSessionGeneration: generation),
              let review = reviewedDispatchStart, let map = collisionMap,
              let sample = try? measured(),
              review.matches(proposalID:id,index:index,generation:generation,mapFingerprint:map.fingerprint,
                positions:sample.positionsRadians.map(\.doubleValue),sequence:sample.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else { return nil }
        if proposal.kind=="recycling_carry_release" {
            guard Thread.isMainThread,MainActor.assumeIsolated({
                guard let attachment=nativeCanAttachment,let ticket=nativeCarryDispatchTicket,let model=collisionModel,
                      let context=try?nativeAttachmentContext(attachment.context),let feedback=try?nativeAttachmentFeedback() else{return false}
                return attachment.matchesAndConsumeDispatch(ticket,proposalID:id,proposalSHA256:proposal.fingerprint,index:index,seconds:seconds,
                    currentContext:context,map:map,model:model,feedback:feedback,nowMilliseconds:Date().timeIntervalSince1970*1000,
                    nowUptime:ProcessInfo.processInfo.systemUptime)
            }) else{return nil}
            nativeCarryDispatchTicket=nil
        }
        reviewedDispatchStart = nil
        return proposal.steps[index].positions
    }

    @nonobjc func recoveryProposal(model: ROBGhostRobotModel) throws -> ROBLeftGestureProposal {
        guard !isRunning, recoveryGeneration > 0,
              (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == recoveryGeneration,
              recoveryPath.count > 1 else { throw ROBGhostMotionError.blocked("No stopped custom path in this gateway session.") }
        let q = try measured().positionsRadians.map(\.doubleValue)
        var segment: Int?
        for index in stride(from: recoveryPath.count - 1, through: 1, by: -1) {
            let a = recoveryPath[index - 1], b = recoveryPath[index]
            let d = zip(a, b).map { $1 - $0 }; let square = d.reduce(0) { $0 + $1 * $1 }
            let t = square > 0 ? max(0, min(1, zip(zip(q, a), d).reduce(0) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / square)) : 0
            if ROBArmRoutinePlan.near(q, zip(a, d).map { $0 + t * $1 }) { segment = index; break }
        }
        guard let segment else { throw ROBGhostMotionError.blocked("Measured arm is outside the interrupted path; no recovery motion proposed.") }
        var previous = q; var steps: [ROBLeftGestureProposal.Step] = []
        for target in recoveryPath.prefix(segment).reversed() {
            let seconds = ROBLeftArmInteractionPlan.duration(from: previous, to: target,
                padding: ROBArmRoutinePlan.tolerance)!
            guard seconds <= 5 else { throw ROBGhostMotionError.blocked("Recovery segment exceeds the motion bound.") }
            steps.append(.init(positions: target, seconds: seconds)); previous = target
        }
        guard steps.reduce(0, { $0 + $1.seconds }) <= 135 else { throw ROBGhostMotionError.blocked("Recovery path exceeds one approval window.") }
        let value = ROBLeftGestureProposal(id: UUID(), name: "Return interrupted gesture", kind: "recover", modelID: model.modelID,
            referenceID: model.referenceID, geometryID: model.geometryID, mappingID: model.selectedMappingID,
            sessionGeneration: recoveryGeneration, baseline: q, poses: [], steps: steps)
        offeredRecovery = value; return value
    }

    override init() {
        super.init()
        ackObserver = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
            object: gateway, queue: .main) { [weak self] note in
                guard let self, self.isRunning,
                      let id = (note.userInfo?["commandID"] as? NSNumber)?.uint64Value else { return }
                let accepted = note.userInfo?["accepted"] as? Bool == true
                if note.userInfo?["operation"] as? String=="priority_hold",
                   let index=self.currentSpikeEvidence?.holds.firstIndex(where:{$0.commandID==id}) {
                    self.currentSpikeEvidence?.holds[index].acknowledgementAtMilliseconds=Date().timeIntervalSince1970*1000
                    self.currentSpikeEvidence?.holds[index].accepted=accepted
                    self.currentSpikeEvidence?.holds[index].holdConfirmed=note.userInfo?["holdConfirmed"] as? Bool
                }
                if ["gripper_control","gripper_calibrate"].contains(note.userInfo?["operation"] as? String ?? "") {
                    self.jawCommandDispatched=true
                }
                let renewal = self.leaseRenewals.removeValue(forKey: id) != nil
                if self.waiting.contains(id) {
                    self.acks[id] = accepted
                    if note.userInfo?["operation"] as? String == "priority_hold" {
                        self.holdConfirmations[id] = note.userInfo?["holdConfirmed"] as? Bool == true
                    }
                }
                if (renewal || self.waiting.contains(id)) && !accepted {
                    self.abort(note.userInfo?["error"] as? String ?? "Left-arm command rejected; hold requested.")
                }
            }
        sampleObserver = NotificationCenter.default.addObserver(forName: .ROBAmberGatewayTelemetryDidUpdate,
            object: gateway, queue: .main) { [weak self] note in
                guard let self,let sample=note.userInfo?["telemetry"] as? ROBAmberGatewayTelemetry else{return}
                if self.isRunning,sample.arm==self.arm,sample.sequence>0,sample.sampleAgeAtReceiptMilliseconds<=250 {
                    let current=(self.gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
                    if self.servoTelemetryHistory.last?.generation != current {self.servoTelemetryHistory=[]}
                    if self.servoTelemetryHistory.last?.sample.sequence != sample.sequence {
                        self.servoTelemetryHistory.append((current,sample))
                        if self.servoTelemetryHistory.count>80 {self.servoTelemetryHistory.removeFirst(self.servoTelemetryHistory.count-80)}
                    }
                }
                if self.isRunning,self.usesFixedCommissioningKeyframes,sample.sequence>0,sample.sampleAgeAtReceiptMilliseconds<=250 {
                    let current=(self.gateway.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value ?? 0
                    var history=self.nominalBothArmHistory[sample.arm] ?? []
                    if history.last?.generation != current {history=[]}
                    if history.last?.sample.sequence != sample.sequence {history.append((current,sample));if history.count>240 {history.removeFirst(history.count-240)}}
                    self.nominalBothArmHistory[sample.arm]=history
                }
                self.recordCurrentSpikePostStop(sample)
                guard self.isRunning,self.failure==nil,!Self.neckOnlyCommands.contains(self.activeCommand),
                      !self.inactiveWorkspaceSearch,sample.arm==self.arm else{return}
                do { try self.record(sample) } catch { self.abort(error.localizedDescription) }
            }
    }

    func perform(_ requestedCommand: String, completion: @escaping (NSDictionary) -> Void) {
        perform(requestedCommand, target: "", completion: completion)
    }

    func perform(_ requestedCommand: String, target: String, completion: @escaping (NSDictionary) -> Void) {
        performImpl(requestedCommand,target:target,localReceiptOnly:false,completion:completion)
    }

    /// Dedicated local Sandbox action; ordinary model/controller commands do
    /// not enter this lane by naming a task or by decoding a saved proposal.
    @nonobjc var sourcePixelSelfReviewStatus:NSDictionary {
        ["enabled":sourcePixelSelfReviewEnabled,"templateSHA256":sourcePixelTemplateSHA256 as Any? ?? NSNull(),
         "templatePath":sourcePixelTemplatePath as Any? ?? NSNull(),"currentEvidenceSHA256":sourcePixelCurrentEvidenceSHA256 as Any? ?? NSNull(),
         "currentMapFingerprint":sourcePixelCurrentMapFingerprint as Any? ?? NSNull(),
         "classificationBasis":"llm_visual_review_experimental","motionAuthority":false]
    }
    @nonobjc func importSourcePixelSelfReview(from url:URL,completion:@escaping(NSDictionary)->Void) {
        #if !DEBUG
        completion(["status":"rejected","detail":"Experimental source-pixel commissioning is DEBUG-only."]);return
        #else
        guard Thread.isMainThread,!isRunning,sourcePixelPreparationTask==nil else {completion(["status":"busy","detail":"Finish the active operation before importing perception evidence."]);return}
        ROBControllerArmApproval.shared.cancel(reason:"Experimental source-pixel template changed; old job scope is invalid.")
        sourcePixelCurrentView=nil;sourcePixelCurrentMapFingerprint=nil;sourcePixelCurrentSourceMapJSON=nil;sourcePixelCurrentEvidenceSHA256=nil
        let preparationID=UUID();sourcePixelPreparationID=preparationID
        sourcePixelPreparationTask=Task { @MainActor [weak self] in
            guard let self else{return};defer {if self.sourcePixelPreparationID==preparationID {self.sourcePixelPreparationTask=nil;self.sourcePixelPreparationID=nil}}
            do {
                let result:(ROBWorkspaceSourcePixelSelf.Template,String)=try await withCheckedThrowingContinuation{continuation in
                    Self.sourcePixelQueue.async {
                        do {
                            let bytes=try ROBSourcePixelArchiveInputs.privateFile(url,limit:8_000_000)
                            guard let review=try JSONSerialization.jsonObject(with:bytes)as?[String:Any],
                                  let path=review["archiveDirectory"]as?String,path.hasPrefix("/"),
                                  let directory=Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil) else {
                                throw ROBGhostMotionError.blocked("Experimental review lacks its original native archive directory or bundled model.")
                            }
                            let inputs=try ROBSourcePixelArchiveInputs.load(directory:URL(fileURLWithPath:path))
                            let model=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
                            let template=try ROBWorkspaceSourcePixelSelf.loadTemplate(reviewJSON:bytes,manifestJSON:inputs.manifestJSON,
                                sourceMapJSON:inputs.sourceMapJSON,frames:inputs.frames,model:model)
                            continuation.resume(returning:(template,ROBGhostRobotModel.hash(bytes)))
                        }catch {continuation.resume(throwing:error)}
                    }
                }
                try Task.checkCancellation();guard !self.isRunning,self.sourcePixelPreparationID==preparationID else {throw ROBGhostMotionError.blocked("The arm task changed while loading perception evidence.")}
                self.sourcePixelTemplate=result.0;self.sourcePixelTemplateSHA256=result.1;self.sourcePixelTemplatePath=url.path
                completion(["status":"perception_template_imported","motionAuthority":false,"detail":"Historical LLM visual pixel template loaded. Prepare will match actual NEXT fresh scan; no motion permission imported."])
            }catch {completion(["status":"blocked","motionAuthority":false,"detail":error.localizedDescription])}
        }
        #endif
    }
    private func prepareSourcePixelSelfReview(command:String,target:String,completion:@escaping(NSDictionary)->Void) {
        #if !DEBUG
        completion(["status":"rejected","detail":"Experimental source-pixel commissioning is DEBUG-only."]);return
        #else
        guard !isRunning,sourcePixelPreparationTask==nil,!ROBControllerArmApproval.shared.isPending,
              nominalEmptyCommissioningStepEnabled,!nominalModelAssumedSelfEnabled,!oneDegreeEmptyCalibrationStepEnabled,
              let template=sourcePixelTemplate,let templateHash=sourcePixelTemplateSHA256,
              let map=ROBWorkspaceSearch.shared.collisionSnapshot,
              let report=ROBWorkspaceSearch.shared.lastReport["raw_archive"]as?[String:Any],report["status"]as?String=="complete",
              let path=report["directory"]as?String,
              let directory=Bundle.main.url(forResource:"ShadowPlanner",withExtension:nil) else {
            completion(["status":"blocked","detail":"Select only the DEBUG source-pixel nominal variant, import its historical template once, and capture a fresh complete native RAW scan."]);return
        }
        let fingerprint=map.fingerprint,scene=map.sceneID,body=map.bodyMotionIdentity,camera=map.cameraGeneration,session=map.sessionGeneration
        sourcePixelCurrentView=nil;sourcePixelCurrentMapFingerprint=nil;sourcePixelCurrentSourceMapJSON=nil;sourcePixelCurrentEvidenceSHA256=nil
        let preparationID=UUID();sourcePixelPreparationID=preparationID
        sourcePixelPreparationTask=Task { @MainActor [weak self] in
            guard let self else{return};defer {if self.sourcePixelPreparationID==preparationID {self.sourcePixelPreparationTask=nil;self.sourcePixelPreparationID=nil}}
            do {
                let classified:(ROBWorkspaceSourcePixelSelf.View,String,Data)=try await withCheckedThrowingContinuation{continuation in
                    // Decode/model/replay/NCC stay on one serial value-only
                    // worker. No camera buffers or live map actor cross it.
                    Self.sourcePixelQueue.async {
                        do {
                            let inputs=try ROBSourcePixelArchiveInputs.load(directory:URL(fileURLWithPath:path))
                            let source=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:inputs.sourceMapJSON)
                            guard source.fingerprint==fingerprint,source.sceneID==scene,source.bodyMotionIdentity==body,
                                  source.cameraGeneration==camera,source.sessionGeneration==session else {
                                throw ROBGhostMotionError.blocked("Current raw archive differs from the actual native scan; no historical relabeling accepted.")
                            }
                            let model=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
                            let view=try ROBWorkspaceSourcePixelSelf.classify(template:template,currentManifestJSON:inputs.manifestJSON,
                                currentSourceMapJSON:inputs.sourceMapJSON,currentFrames:inputs.frames,map:source,model:model,
                                nowMilliseconds:Date().timeIntervalSince1970*1000)
                            continuation.resume(returning:(view,view.fingerprint,inputs.sourceMapJSON))
                        }catch {continuation.resume(throwing:error)}
                    }
                }
                try Task.checkCancellation()
                guard self.sourcePixelSelfReviewEnabled,self.sourcePixelTemplateSHA256==templateHash,self.sourcePixelPreparationID==preparationID,!self.isRunning,
                      !ROBControllerArmApproval.shared.isPending,let current=ROBWorkspaceSearch.shared.collisionSnapshot,
                      current.fingerprint==fingerprint,current.sceneID==scene,current.bodyMotionIdentity==body,
                      current.cameraGeneration==camera,current.sessionGeneration==session else {
                    throw ROBGhostMotionError.blocked("Source-pixel preparation lost the current60s scene, source, template or idle scope.")
                }
                self.sourcePixelCurrentView=classified.0;self.sourcePixelCurrentMapFingerprint=fingerprint
                self.sourcePixelCurrentEvidenceSHA256=classified.1;self.sourcePixelCurrentSourceMapJSON=classified.2
                self.performImpl(command,target:target,localReceiptOnly:true,completion:completion)
            }catch {self.sourcePixelCurrentView=nil;self.sourcePixelCurrentMapFingerprint=nil;self.sourcePixelCurrentSourceMapJSON=nil;self.sourcePixelCurrentEvidenceSHA256=nil
                completion(["status":"blocked","arm_motion_sent":false,"jaw_command_sent":false,"detail":error.localizedDescription])}
        }
        #endif
    }

    @nonobjc func performUsingLocalRecyclingReceipt(_ command:String,target:String,completion:@escaping(NSDictionary)->Void) {
        guard ["left_recycle_cans","right_recycle_cans"].contains(command),
              let canCount=try? ROBRecyclingBatchRequest.requestedCount(command:command,target:target) else {
            completion(["status":"rejected","detail":"Choose an exact local recycling count from1 through8."]);return
        }
        if sourcePixelSelfReviewEnabled {
            guard command=="right_recycle_cans" else {completion(["status":"rejected","detail":"Source-pixel commissioning is physical RIGHT only."]);return}
            prepareSourcePixelSelfReview(command:command,target:target,completion:completion);return
        }
        let broker=ROBControllerArmApproval.shared
        if broker.standingLocalCanCampaignActive,!nominalEmptyCommissioningStepEnabled,!nominalModelAssumedSelfEnabled,!oneDegreeEmptyCalibrationStepEnabled {
            let state=broker.standingLocalCanCampaignState
            let targetCount=(state?["targetCanCount"]as?NSNumber)?.intValue ?? (state?["canCount"]as?NSNumber)?.intValue ?? 4
            guard canCount==targetCount else {
                completion(["status":"rejected","detail":"The requested can count differs from this standing campaign's exact target."]);return
            }
            guard standingPreparationTask==nil,!isRunning,!broker.isPending,
                  let campaign=broker.standingLocalCanCampaignState?["campaignID"] as? String else {
                completion(["status":"busy","detail":"The standing can task is already preparing or running."]);return
            }
            localReceiptCameraTimer?.invalidate();localReceiptCameraTimer=nil
            let before=vision.snapshot()["face"]?.sequence ?? 0
            vision.ensureActiveForTaskObservation();ROBArmRoutineCoordinator.shared.cameraDemand?(true)
            update("Starting the live task camera before freezing a fresh can-task plan")
            standingPreparationTask=Task { @MainActor [weak self] in
                guard let self else{return}
                defer {self.standingPreparationTask=nil}
                let end=ProcessInfo.processInfo.systemUptime+12
                while !Task.isCancelled,broker.standingLocalCanCampaignActive,
                      broker.standingLocalCanCampaignState?["campaignID"] as? String==campaign,
                      ProcessInfo.processInfo.systemUptime<end {
                    if self.vision.fresh,let frame=self.vision.snapshot()["face"],frame.sequence>before,
                       frame.depth?.width==640,frame.depth?.height==480 {
                        self.performImpl(command,target:target,localReceiptOnly:true,completion:completion);return
                    }
                    try?await Task.sleep(nanoseconds:100_000_000)
                }
                if !Task.isCancelled {completion(["status":"blocked","arm_motion_sent":false,"jaw_command_sent":false,
                    "detail":"The standing task camera did not provide a fresh frame before preparation expired; no arm command sent."])}
            }
            return
        }
        guard localCameraPreparationTask==nil,!isRunning,!broker.isPending else {completion(["status":"busy","detail":"A task is already preparing or running."]);return}
        localReceiptCameraTimer?.invalidate();localReceiptCameraTimer=nil
        let previous=vision.snapshot()["face"]?.sequence ?? 0
        vision.ensureActiveForTaskObservation();ROBArmRoutineCoordinator.shared.cameraDemand?(true)
        if vision.fresh {performImpl(command,target:target,localReceiptOnly:true,completion:completion);return}
        localCameraPreparationTask=Task { @MainActor [weak self] in
            guard let self else{return};defer {self.localCameraPreparationTask=nil}
            let end=ProcessInfo.processInfo.systemUptime+12
            while !Task.isCancelled,!self.isRunning,!broker.isPending,ProcessInfo.processInfo.systemUptime<end {
                if self.vision.fresh,let frame=self.vision.snapshot()["face"],frame.sequence>previous,frame.depth != nil {
                    self.performImpl(command,target:target,localReceiptOnly:true,completion:completion);return
                }
                try?await Task.sleep(nanoseconds:50_000_000)
            }
            if !Task.isCancelled {completion(["status":"blocked","arm_motion_sent":false,"jaw_command_sent":false,
                "detail":"The task camera did not provide a newly enrolled fresh RGB-D frame within12seconds; no arm command sent."])}
        }
    }

    private func performImpl(_ requestedCommand:String,target:String,localReceiptOnly:Bool,completion:@escaping(NSDictionary)->Void) {
        precondition(Thread.isMainThread)
        guard Self.commands.contains(requestedCommand) else { completion(["status": "rejected"]); return }
        // Normalize shared task semantics only after preserving physical identity.
        // Busy callers cannot change the side of an already-running operation.
        guard !isRunning else { completion(["status":"busy","detail":"An arm operation is already running."]); return }
        guard !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning,
              !ROBAmberGestureExecutor.shared.isExecuting,
              !ROBControllerArmApproval.shared.isPending || requestedCommand == "left_relax" else {
            completion(["status":"busy","detail":"Finish the current operation or use Stop + hold."]);return
        }
        let canCount: Int
        do { canCount = try ROBRecyclingBatchRequest.requestedCount(command: requestedCommand, target: target) ?? 1 }
        catch { completion(["status":"rejected", "detail":error.localizedDescription]); return }
        selectPhysicalSide(requestedCommand.hasPrefix("right_") ? "right" : "left")
        requestedCanCount = canCount
        let canonical = requestedCommand.hasPrefix("right_") ? "left_" + requestedCommand.dropFirst(6) : requestedCommand
        let command = ["left_recycle_two_cans","left_recycle_three_cans","left_recycle_cans"].contains(canonical) ? "left_recycle_can" : canonical == "left_estimated_trial" ? "left_estimated_calibration" : canonical
        workspaceSearchTargets = command == "left_search_workspace"
            && target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "can"
            ? [.can] : ROBWorkspaceTarget.allCases
        if command == "left_estimated_calibration" { performEstimatedCalibration(completion:completion); return }
        if !isRunning { invalidateEstimatedPreview(reason:"Another operation replaced the estimated preview") }
        if command == "left_pick_place" {
            do {
                let model = try workspaceModel()
                guard let saved = ROBTabletopPickPlace.saved(), saved.modelID == model.modelID,
                      saved.referenceID == model.referenceID, saved.geometryID == model.geometryID,
                      let sample = gateway.telemetry(forArm: arm), sample.effectiveSampleAgeMilliseconds <= 250,
                      let session = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value else {
                    throw ROBGhostMotionError.blocked("Save a five-position tabletop task in Ghost gestures and connect fresh arm feedback first.")
                }
                let path = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: saved.name, poses: saved.poses,
                    model: model, baseline: sample.positionsRadians.map(\.doubleValue), generation: session)
                perform(proposal: path, model: model, completion: completion)
            } catch { completion(["status": "blocked", "detail": error.localizedDescription]) }
            return
        }
        // Non-editor operations never inherit an old reviewed proposal.
        if !isRunning { proposal = nil }
        if command == "left_relax", !isRunning,
           !ROBArmRoutineCoordinator.shared.isRunning, !ROBShowMotionCoordinator.shared.isRunning {
            if ROBControllerArmApproval.shared.isPending {
                ROBControllerArmApproval.shared.cancel(reason: "Empty-arm return requested")
            }
        }
        guard !isRunning, !ROBArmRoutineCoordinator.shared.isRunning,
              !ROBShowMotionCoordinator.shared.isRunning, !ROBAmberGestureExecutor.shared.isExecuting,
              !ROBControllerArmApproval.shared.isPending else {
            completion(["status": "busy", "detail": "Finish the current operation or use Stop + hold."]); return
        }
        let limit = UserDefaults.standard.double(forKey: Self.currentLimitKey)
        guard limit.isFinite, limit >= 0 else {
            completion(["status": "blocked", "detail": "Current jump limit must be zero or a positive number."]); return
        }
        let action: String
        let intensity = ROBControllerArmApproval.shared.armSessionActive ? 2 : 10
        switch command {
        case "left_estimated_preview": action = "Capture fresh neck-only depth while both arms remain still, then review one estimated EMPTY-left-arm retreat away from the table over 4 seconds. No arm motion or gripper command."
        case "left_scan_clearance": action = "Scan the current workspace with the neck RGB-D camera while both arms remain still. Retain occupied surfaces and observed free space for a full-arm collision review. A provisional camera transform does not authorize movement."
        case "left_search_workspace": action = "Search locally for \(workspaceSearchTargets == [.can] ? "a Coke can" : "a Coke can and an orange bucket") by panning/tilting the neck camera. Confirm detections in two fresh RGB-D observations using the offline object detector. If missing, ask the nearest visible person to point and search in the estimated pointing direction. Report found/not found. No arm activation, gripper commands or arm travel."
        case "left_check_hanging": action = "Inspect both robot arms by panning/tilting the neck camera using on-device MLX; report whether each is visibly hanging. This observation never resets encoders or activates/moves either arm."
        case "left_recycle_can": action = "One experimental recycling test: hold the current arm pose while the neck camera finds the empty can, bucket opening and workspace depth. Check measured camera/arm registration and the complete arm, open jaws and payload sweep. Dynamically plan the entire approach, middle grasp, carry, gravity release and retreat before moving; no blind parking or taught-route exemption. Reuse stationary startup gripper setup. Open at intensity 10 before approaching, grip at intensity 2, and release above the opening at intensity 10. Deferred empty-jaw setup may happen only after a collision-checked empty return to hanging/inactive. One authorization covers all waypoints. No force escalation, driving, blind retries or torque-off with a payload. Pickup and placement remain unmeasured."
        case "left_wave": action = "Scan current geometry, dynamically connect the empty LEFT arm to the wave targets, check each complete arm sweep, wave and leave raised. Jaws unchanged."
        case "left_prepare": action = "Present the confirmed-EMPTY physical LEFT arm using a fresh full-arm collision-checked connector. Reuse startup gripper readiness; explicit jaw setup is stationary. Confirm no object is held and supervise actual jaw opening. No encoder reset or unreviewed return path."
        case "left_grip": action = "Keep the LEFT arm stationary in front and close its already-calibrated gripper at intensity \(intensity) around the presented OBJECT. Confirm the object is between the open jaws and all fingers are clear. Never grip a person's hand. No reopening, calibration or arm travel."
        case "left_release": action = "Keep the LEFT arm stationary in front and open its already-calibrated gripper to return the object. Confirm the receiver supports the object before approving. No calibration or arm travel."
        case "left_object_cycle": action = "Complete one LEFT object handoff using fresh depth and dynamically checked full-arm connectors. Reuse startup gripper setup, open and wait for Object placed / fingers clear before gripping at intensity 2. Wait for Receiver supporting before release, then Object clear / jaws empty before a checked empty return to hanging and deactivation. Readiness signals continue the same approval. Opening, retention and force remain unmeasured."
        default: action = "Return the empty LEFT arm to hanging through a fresh dynamically calculated full-arm collision-checked route, then deactivate only at measured hanging. Remove any object first. No extra approval is needed for this empty return."
        }
        let notice = " Physical \(physicalSide.uppercased()) arm only. Arm travel requires measured camera/robot registration, fresh observed space and complete arm clearance. Unknown space blocks the path. Confirm the joint reference for the first motion of a session. The other arm stays still. Watch actual clearance; Stop + hold remains available."
        let current = limit == 0 ? " Current recording only; automatic current cutoff is not configured."
            : " Request hold if any joint's current changes by more than \(limit) raw units between samples; this is not a calibrated force limit."
        let travel = ["left_wave", "left_prepare", "left_relax", "left_object_cycle"].contains(command)
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance"].contains(command)
        let bothHolds = physicalSide == "right" && command == "left_recycle_can"
            ? " Both arms may enter a measured stationary position hold without travel; only the physical RIGHT arm may execute the planned path. If both are already measured hanging and empty, stationary startup jaw initialization may finish there without raising them. The physical LEFT arm otherwise stays at its measured pose." : ""
        let batch = requestedCanCount > 1 && command == "left_recycle_can"
            ? " \(requestedCanCount) empty cans, sequentially: fresh perception, collision review and visual grasp check for each. A failed or uncertain grasp stops the batch in a hold; no blind next-can retry. One approval covers all \(requestedCanCount) complete transfers." : ""
        let recyclingSummary = localReceiptOnly
            ? "Tonight's \(requestedCanCount) empty Coke cans to the orange bucket, physical \(physicalSide.uppercased()) arm. Use best-available unmeasured alignment as an operator visual-calibration trial, with assumed spatial allowance \(localVisualTrialAssumedSpatialErrorMeters*1000) mm. Find the nearest reachable confirmed can first; open before approach, close gently and validate the short lift in fresh camera frames before carrying or gravity release. Check the entire arm, open jaws and payload against observed obstacles/free space; unknown space and initial model overlaps may still block. Both arms may hold their current positions. No blind parking, treads, torso, encoder reset, force escalation or blind retries. One exact local user-session receipt covers \(requestedCanCount) transfers within600seconds. Stop/fresh feedback/ownership/limits remain active. No measured registration, grasp or landing success is implied."
            : action + batch + notice + bothHolds + current + (workspace ? " Maximum 600 seconds including search, planning and movement." : travel ? " Maximum 180 seconds including preparation and settling." : "")
        let nominalSummary=localReceiptOnly && nominalEmptyCommissioningStepEnabled
            ? "ONE NOMINAL EMPTY physical RIGHT-arm commissioning experiment only: fresh measured q0 to J2 minus0.075rad over4seconds, at most6cm full-hull travel and0.20rad per joint. No jaw command, grasp, payload, carry, release, automatic return or chained can attempt. Both arms may hold their measured positions. Watch the arm in the actual recorded RIGHT camera view. Exact raw-return bounds are checked for nominal no-contact; unknown space is admitted ONLY in the recorded local swept regions. Current robot occupancy is assumed from the model; this is a geometric assumption, not sensor classification or removal of raw returns. Modeled millimeter-scale gaps are much smaller than the explicitly ASSUMED35mm camera uncertainty: this is NOT certified collision protection and physical contact remains possible. Stop, ownership, current limits, fresh motor/gripper feedback, source/body/profile identity and exact receipt remain required. After this ONE step, measure the endpoint and hold, report partial with ZERO recycled cans; the \(requestedCanCount)-can job remains unfinished. Empty state is assumed from startup/task history, not sensed possession."
            : recyclingSummary
        let assumedSummary=localReceiptOnly && nominalModelAssumedSelfEnabled
            ? "ONE MODEL-ASSUMED EMPTY RIGHT-arm commissioning step: exact fresh q0 to J2 minus0.075rad only,4seconds,at most60mm full-hull travel. Assumed alignment is NOT observed self recognition. Only COMPLETE original source groups entirely inside NONinflated baseline moving-link model hulls are treated as assumed robot material for this one nominal proof; an external object inside that assumed volume could be misclassified and contact/property damage is possible. All other raw groups retain existing nominal external-contact checks. Raw occupied data and unknown space remain unchanged; no normal clearance certificate. Fixed head/body and BOTH measured arm holds; only RIGHT J2 moves. Collect14 explicit RGB-D keyframes (3before,8during,3after) with actual timestamps/cadence and BOTH measured q. No jaws, payload, grip,carry,release,return,retry or automatic chaining. Preserve Stop/person/current/fresh feedback/ownership/joint/self-nonworsening/endclearance checks. Hold after one step; ZERO transfers; camera35mm error and empty startup/history remain assumptions. Requires current prepared P4000 L6011 U5450; no head change by this variant."
            : nominalSummary
        let experimentSummary=localReceiptOnly && oneDegreeEmptyCalibrationStepEnabled
            ? "ONE EMPTY physical RIGHT-arm actuator/geometry calibration experiment only: fresh measured q0 to J2 minus0.02rad (about one degree) over4seconds, at most2cm modeled full-hull travel. No jaw command, payload, grasp, carry, release, automatic return or chained can attempt. Both arms remain stationary except this ONE selected-joint step. Watch the actual RIGHT arm in the recorded camera view. Best-available camera/model alignment has explicitly ASSUMED35mm error; raw contact predictions and unknown regions are recorded as diagnostics and are NOT verified motion clearance or a collision certificate. Physical contact and calibration mistakes are accepted for this bounded experiment. Stop, ownership, current limits, fresh motor/gripper feedback, source/body/profile identity, q0, joint bounds and a tight measured motion corridor remain required. After the ONE step, measure the endpoint and hold, report partial with ZERO recycled cans. Empty state is assumed from startup/task history, not sensed possession."
            : assumedSummary
        let pixelSummary=localReceiptOnly && sourcePixelSelfReviewEnabled
            ? "ONE DEBUG EXPERIMENTAL LLM-VISUAL-REVIEWED SOURCE-PIXEL EMPTY RIGHT-arm step, J2 minus0.075rad ONLY over4seconds,≤60mm full-hull travel, then hold. Fresh RGB/depth+exactneck/BOTHq/device/runtime/source checks matched an historical reviewed template to THIS current raw map; current evidence SHA256 \(currentSourcePixelEvidenceSHA256 ?? "unavailable"). Original template SHA256 \(sourcePixelTemplateSHA256 ?? "unavailable"). Current raw map SHA256 \(sourcePixelCurrentMapFingerprint ?? "unavailable"). This is experimental perception, NOT measured self/registration or motion authority. Only original source groups whose EVERY accepted contributor is positively matched experimental robot may be excluded; table/person/hand/uncertain/unmasked/mixed groups remain external. No MODEL-hull fallback or normal-route exemption; all raw data retained. Prepared fixed P4000L6011U5450, both arms held, only RIGHT J2 travels. Record14 actual RGB-D/BOTHq keyframes3before/8during/3after, no30fps claim. Preserve actual external-contact/joint/fullarm/self-nonworsening/endclearance/person/current/feedback/ownership/Stop checks. No jaw,payload,grip,carry,release,return,retry,automatic chaining or transfer. Empty state and35mm camera error remain assumptions; contact/property risk possible. A fresh exact native private receipt is still required."
            : experimentSummary
        let liftSummary=localReceiptOnly && holdAfterInitialEmptyLiftEnabled
            ? "DEBUG initial EMPTY lift and hold only, physical RIGHT arm: search fresh can/workspace observations, select one initial empty lift using the ordinary complete occupied/unknown/full-arm/self-clearance review, recheck its exact measured start before dispatch, then measure the endpoint and hold. No jaw commands or startup jaw calibration, grasp, payload, carry, release, return, rescan after lifting, next can or chained motion. If no initial lift is required, remain unchanged and report that. ZERO transfers; the \(requestedCanCount)-can campaign remains unfinished. Both arms may hold their current measured positions. The same explicit visual trial uses assumed spatial error \(localVisualTrialAssumedSpatialErrorMeters*1000) mm; no calibration or collision exemption is added. Preserve joint bounds, fresh motor/gripper feedback, source/body/context identity, exclusive ownership, current-spike hold and immediate Stop."
            : pixelSummary
        let approachSummary=localReceiptOnly && approachCanThenHoldEnabled
            ? "DEBUG approach can then hold with OPEN jaws: search the can and workspace, perform any ordinary fully checked initial empty lift, reobserve and execute the complete checked dynamic entry and bounded observed-jaw alignment. Stop at actual ready-to-grip alignment BEFORE close, verification lift, payload, carry or release. Opening/startup jaw readiness is permitted; closing is prohibited. Hold the measured endpoint, ZERO transfers, no automatic recovery or next attempt. Preserve ordinary occupied/unknown/full-arm/self-clearance, joint/current/person/Stop, fresh feedback and exact camera/body/receipt protections. Assumed visual uncertainty remains \(localVisualTrialAssumedSpatialErrorMeters*1000)mm; no commissioning collision exemption."
            : liftSummary
        let approvedSummary=localReceiptOnly && approachUnknownAdvisoryEnabled
            ? "DEBUG operator-cleared UNKNOWN-advisory EMPTY physical RIGHT open-jaw approach: search the can and workspace, perform any needed occupied/full-arm/self-checked initial empty lift, reobserve, then execute the complete checked dynamic entry and bounded observed-jaw alignment. Unobserved cells remain UNKNOWN and are recorded as advisory; they do not veto this approach and are never relabeled free or observed. ALL occupied returns, self-collision, person/Stop, joints/rates/current/fresh feedback and exact camera/body/standing-receipt checks remain enforced. Stop at actual ready-to-grip alignment BEFORE closing. Opening/startup empty-jaw readiness is permitted; no close, verification lift, payload, carry, release, automatic recovery or next attempt. Hold the measured endpoint, ZERO transfers. Assumed visual uncertainty remains \(localVisualTrialAssumedSpatialErrorMeters*1000)mm. This accepted uncertainty is NOT certified collision clearance or measured registration. No other route receives this UNKNOWN policy."
            : approachSummary
        if Self.neckOnlyCommands.contains(command) || command == "left_relax" {
            update(command == "left_relax" ? "Returning the empty left arm to hanging" : "Starting local neck-camera inspection")
            start(command, summary: action, limit: limit, completion: completion)
            return
        }
        update(localReceiptOnly ? "Awaiting the exact local \(canCount)-can session receipt" : "Awaiting spoken or controller authorization: \(action)")
        let execute: (@escaping (NSDictionary) -> Void) -> Void = { [weak self] done in
            self?.localReceiptCommand = localReceiptOnly ? requestedCommand : nil
            self?.localReceiptEvidence = localReceiptOnly ? ROBControllerArmApproval.shared.activeLocalRecyclingApprovalEvidence : nil
            self?.localReceiptContextIdentity = localReceiptOnly ? self?.currentLocalRecyclingContextIdentity() : nil
            self?.jawIntensity = intensity
            self?.start(command, summary: approvedSummary, limit: limit, completion: done)
        }
        let cancel = { [weak self] in
            self?.captureActualCampaignInterruption()
            self?.abort("Controller cancelled or disconnected; left-arm hold requested.");return
        }
        let finished: (NSDictionary) -> Void = { [weak self] result in
            self?.update(result["detail"] as? String ?? "Left-arm operation ended"); completion(result)
        }
        if localReceiptOnly {
            #if !DEBUG
            guard !holdAfterInitialEmptyLiftEnabled,!sourcePixelSelfReviewEnabled,!approachCanThenHoldEnabled,!approachUnknownAdvisoryEnabled else {
                completion(["status":"rejected","detail":"Initial empty lift-and-hold is available only in DEBUG commissioning builds."]);return
            }
            #endif
            guard !approachUnknownAdvisoryEnabled || (approachCanThenHoldEnabled && ROBControllerArmApproval.shared.standingLocalCanCampaignActive) else {
                completion(["status":"rejected","detail":"UNKNOWN advisory needs the separate exact open-jaw approach option and current standing typed authorization."]);return
            }
            guard !approachCanThenHoldEnabled || (physicalSide=="right" && !holdAfterInitialEmptyLiftEnabled && !nominalEmptyCommissioningStepEnabled && !oneDegreeEmptyCalibrationStepEnabled && !sourcePixelSelfReviewEnabled) else {
                completion(["status":"rejected","detail":"Approach-and-hold requires physical RIGHT and excludes the separate lift-only and calibration options."]);return
            }
            guard !holdAfterInitialEmptyLiftEnabled || (physicalSide=="right" && !nominalEmptyCommissioningStepEnabled && !oneDegreeEmptyCalibrationStepEnabled) else {
                completion(["status":"rejected","detail":"The fully checked empty lift-and-hold option requires physical RIGHT and excludes both separate calibration experiments."]);return
            }
            guard !(nominalEmptyCommissioningStepEnabled && oneDegreeEmptyCalibrationStepEnabled),
                  !nominalModelAssumedSelfEnabled || nominalEmptyCommissioningStepEnabled && physicalSide=="right",
                  !sourcePixelSelfReviewEnabled || (nominalEmptyCommissioningStepEnabled && !nominalModelAssumedSelfEnabled && !oneDegreeEmptyCalibrationStepEnabled && physicalSide=="right" && currentSourcePixelEvidenceSHA256 != nil),
                  !(nominalEmptyCommissioningStepEnabled || oneDegreeEmptyCalibrationStepEnabled) || physicalSide=="right" && localVisualTrialAssumedSpatialErrorMeters==0.035 else {
                completion(["status":"rejected","detail":"The separate empty calibration experiments are mutually exclusive and require physical RIGHT and an explicit35mm assumed camera uncertainty."]);return
            }
            guard vision.fresh else {
                completion(["status":"blocked","arm_motion_sent":false,"reach_sent":false,"jaw_command_sent":false,
                    "detail":"A fresh enrolled RGB-D frame is required to prepare this local recycling job."]);return
            }
            // The new pending operation owns this already-enrolled camera.
            // An old idle-receipt timer must not turn it off while the new
            // private receipt is being prepared/imported.
            localReceiptCameraTimer?.invalidate();localReceiptCameraTimer=nil
            localReceiptContextComponents=nil
            ROBControllerArmApproval.shared.requestRecyclingWorkspaceTask(command:requestedCommand,arm:physicalSide,canCount:canCount,
                summary:approvedSummary,contextIdentity:{[weak self] in self?.currentLocalRecyclingContextIdentity()},receiptOnly:true,
                permitsUnmeasuredVisualCalibrationTrial:true,nominalEmptyCommissioningStepEnabled:nominalEmptyCommissioningStepEnabled,
                nominalModelAssumedSelfEnabled:nominalModelAssumedSelfEnabled,approachCanThenHoldEnabled:approachCanThenHoldEnabled,approachUnknownAdvisoryEnabled:approachUnknownAdvisoryEnabled,
                sourcePixelSelfReviewSHA256:currentSourcePixelEvidenceSHA256,
                oneDegreeEmptyCalibrationStepEnabled:oneDegreeEmptyCalibrationStepEnabled,
                execute:execute,cancel:cancel,completion:finished)
        } else if workspace && physicalSide == "right" {
            ROBControllerArmApproval.shared.requestRightWorkspaceTask(summary: approvedSummary, execute:execute, cancel:cancel, completion:finished)
        } else if workspace {
            ROBControllerArmApproval.shared.requestLeftWorkspaceTask(summary: approvedSummary, execute: execute,
                cancel: cancel, completion: finished)
        } else if travel {
            ROBControllerArmApproval.shared.requestLeftGesture(summary: approvedSummary, execute: execute,
                cancel: cancel, completion: finished)
        } else {
            ROBControllerArmApproval.shared.requestLeftStationary(summary: approvedSummary,
                execute: execute, cancel: cancel, completion: finished)
        }
    }

    func cancel(reason: String) {
        sourcePixelCurrentView=nil;sourcePixelCurrentEvidenceSHA256=nil;sourcePixelCurrentMapFingerprint=nil;sourcePixelCurrentSourceMapJSON=nil
        localCameraPreparationTask?.cancel();localCameraPreparationTask=nil;sourcePixelPreparationTask?.cancel();sourcePixelPreparationTask=nil;sourcePixelPreparationID=nil;localCampaignRecoveryTask?.cancel();localCampaignRecoveryTask=nil;standingPreparationTask?.cancel();standingPreparationTask=nil;localCampaignRecoveryReason=nil
        abort(reason)
    }

    func depthAlignmentDidChange() {
        precondition(Thread.isMainThread)
        abort("Head depth alignment changed; review a fresh scene.")
        collisionMap = nil; collisionModel = nil; collisionReviewProposal = nil
        collisionReviewStatus = ["status":"not_scanned", "detail":"Head depth alignment changed; capture a fresh scene."]
        recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
    }

    /// Readiness is not fresh motion authority: the original authenticated
    /// controller approval, session and every live guard must remain valid.
    @discardableResult func continueOperation(stage: String) -> Bool {
        precondition(Thread.isMainThread)
        guard isRunning, activeCommand == "left_object_cycle", !readinessConfirmed,
              !interactionStage.isEmpty, interactionStage == stage else { return false }
        do { try verifyFront() }
        catch { abort(error.localizedDescription); return false }
        readinessConfirmed = true; interactionStage = ""
        update("Object-cycle readiness confirmed; continuing the approved operation")
        return true
    }

    /// Gateway admission is scoped to this accepted operation, physical side
    /// and session. Stationary grip/release approvals never permit arm travel.
    @nonobjc func authorizesTaughtWaypoint(arm: String, expectedSessionGeneration: UInt64) -> Bool {
        guard Thread.isMainThread, isRunning, owner != nil, allowsArmTravel,
              cameraReady, positionReady, arm == self.arm, generation > 0,
              generation == expectedSessionGeneration else { return false }
        do { try check(); try checkCollisionContext(); return true } catch { return false }
    }

    private func update(_ message: String) {
        status = message; statusChanged?(message)
        NotificationCenter.default.post(name: Notification.Name("ROBArmRoutineDidChange"), object: self)
    }

    /// Stable job identity deliberately excludes neck targets and arm q: both
    /// may legitimately change during the authorized search/planned motion.
    private func currentLocalRecyclingContextIdentity() -> String? {
        func unavailable(_ reason:String)->String? {
            localRecyclingContextDiagnostics=["status":"unavailable","reason":reason,"camera_frame_fresh":vision.fresh]
            return nil
        }
        guard Thread.isMainThread,gateway.isReady() else {return unavailable("gateway_unavailable")}
        if localReceiptModel?.physicalSide != physicalSide {localReceiptModel=try?workspaceModel()}
        guard let model=localReceiptModel else {return unavailable("model_unavailable")}
        guard let session=(gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value,session>0 else {return unavailable("gateway_generation_unavailable")}
        guard let frame=vision.snapshot()["face"] else {return unavailable("enrolled_face_snapshot_unavailable")}
        guard frame.cameraGeneration==vision.cameraGeneration else {return unavailable("face_capture_generation_changed")}
        guard let calibration=frame.intrinsics?.runtimeCalibration,calibration.identity.count==64,
              calibration.stereoPolicySHA256.count==64 else {return unavailable("actual_runtime_or_mode_identity_unavailable")}
        guard let projection=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model),projection.count==64 else {return unavailable("physical_projection_identity_unavailable")}
        guard localVisualTrialAssumedSpatialErrorMeters.isFinite,(0.025...0.15).contains(localVisualTrialAssumedSpatialErrorMeters) else {return unavailable("assumed_spatial_allowance_invalid")}
        // Vision's generation enrolls the actual source, stream, dimensions
        // and K; the runtime policy binds actual HOST stereo mode/normalization.
        // A transient age/depth-coverage lapse is readiness, not a new identity.
        guard (1...ROBRecyclingBatchRequest.maximumCount).contains(requestedCanCount) else{return unavailable("job_can_count_invalid")}
        var value:[String:Any] = ["kind":"local_can_visual_trial_context_v2","physicalSide":physicalSide,"canCount":requestedCanCount,
            "cameraGeneration":vision.cameraGeneration.uuidString,"runtimeCalibrationIdentity":calibration.identity,
            "stereoPolicySHA256":calibration.stereoPolicySHA256,
            "gatewayGeneration":NSNumber(value:session),"bodyMotionIdentity":ROBFixedHeadBodyMotionIdentity.currentIdentity,
            "modelID":model.modelID,"referenceID":model.referenceID,"geometryID":model.geometryID,
            "mappingID":model.selectedMappingID,"physicalProjectionIdentity":projection,
            "nominalEmptyCommissioningStepEnabled":nominalEmptyCommissioningStepEnabled,
            "oneDegreeEmptyCalibrationStepEnabled":oneDegreeEmptyCalibrationStepEnabled,
            "assumedSpatialErrorMeters":localVisualTrialAssumedSpatialErrorMeters]
        if approachUnknownAdvisoryEnabled {value["approachUnknownAdvisoryEnabled"]=true}
        if approachCanThenHoldEnabled {value["approachCanThenHoldEnabled"]=true}
        if holdAfterInitialEmptyLiftEnabled {value["holdAfterInitialEmptyLiftEnabled"]=true}
        if nominalModelAssumedSelfEnabled {value["nominalModelAssumedSelfEnabled"]=true}
        if sourcePixelSelfReviewEnabled {
            guard sourcePixelCurrentView != nil,let evidence=sourcePixelCurrentEvidenceSHA256,let current=ROBWorkspaceSearch.shared.collisionSnapshot,
                  current.fingerprint==sourcePixelCurrentMapFingerprint else{return nil}
            value["sourcePixelSelfReviewSHA256"]=evidence
            value["sourcePixelSelfMapFingerprint"]=current.fingerprint
        }
        let components=value.mapValues{String(describing:$0)}
        let changed=localReceiptContextComponents.map { prior in components.keys.filter{prior[$0] != components[$0]}.sorted() } ?? []
        if localReceiptContextComponents==nil {localReceiptContextComponents=components}
        localRecyclingContextDiagnostics=["status":changed.isEmpty ? "current":"changed","changed_components":changed,
            "camera_frame_fresh":vision.fresh,"source_mode_binding":"actual Vision capture generation and runtime stereo policy"]
        return (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)).map(ROBGhostRobotModel.hash)
    }

    private func localNeckIdentity() -> String? {
        MainActor.assumeIsolated {
            guard let neck = ROBFixedHeadCalibrationWindowController.shared.readNeck?(),
                  neck["known"] as? Bool == true, neck["stationary"] as? Bool == true,
                  let pan=neck["pan"] as? Int,let lower=neck["lower"] as? Int,let upper=neck["upper"] as? Int,
                  let ready=neck["ready_at"] as? Double,ready.isFinite,ready<=ProcessInfo.processInfo.systemUptime else {return nil}
            return (try? JSONSerialization.data(withJSONObject:["pan":pan,"lower":lower,"upper":upper],options:.sortedKeys)).map(ROBGhostRobotModel.hash)
        }
    }

    private func requireLocalReceipt() throws -> NSDictionary {
        guard let command=localReceiptCommand,command==physicalSide+"_recycle_cans",(1...ROBRecyclingBatchRequest.maximumCount).contains(requestedCanCount),
              ROBControllerArmApproval.shared.authorizesLocalRecyclingVisualCalibrationTrial(summary:summary,arm:physicalSide),
              let frozen=localReceiptEvidence,let current=ROBControllerArmApproval.shared.activeLocalRecyclingApprovalEvidence,
              let identity=localReceiptContextIdentity,identity==currentLocalRecyclingContextIdentity(),
              current["command"] as? String==command,current["arm"] as? String==physicalSide,
              (current["canCount"] as? NSNumber)?.intValue==requestedCanCount,current["summary"] as? String==summary,
              current["summarySHA256"] as? String==ROBGhostRobotModel.hash(Data(summary.utf8)),
              current["contextIdentity"] as? String==identity,
              current["permitsUnmeasuredVisualCalibrationTrial"] as? Bool==true,
              (current["approachUnknownAdvisoryEnabled"] as? Bool ?? false)==approachUnknownAdvisoryEnabled,
              (current["approachCanThenHoldEnabled"] as? Bool ?? false)==approachCanThenHoldEnabled,
              (current["nominalEmptyCommissioningStepEnabled"] as? Bool ?? false)==nominalEmptyCommissioningStepEnabled,
              (current["nominalModelAssumedSelfEnabled"] as? Bool ?? false)==nominalModelAssumedSelfEnabled,
              current["sourcePixelSelfReviewSHA256"]as?String==currentSourcePixelEvidenceSHA256,
              (current["oneDegreeEmptyCalibrationStepEnabled"] as? Bool ?? false)==oneDegreeEmptyCalibrationStepEnabled,
              let until=(current["executingUntilMilliseconds"] as? NSNumber)?.doubleValue,
              until>Date().timeIntervalSince1970*1000 else {
            throw ROBArmRoutineError.blocked("The exact local recycling-count receipt, current camera/body/profile context or expiry changed; hold requested.")
        }
        guard (frozen["approachUnknownAdvisoryEnabled"] as? Bool ?? false)==approachUnknownAdvisoryEnabled,
              (frozen["approachCanThenHoldEnabled"] as? Bool ?? false)==approachCanThenHoldEnabled,
              (frozen["nominalEmptyCommissioningStepEnabled"] as? Bool ?? false)==nominalEmptyCommissioningStepEnabled,
              (frozen["nominalModelAssumedSelfEnabled"] as? Bool ?? false)==nominalModelAssumedSelfEnabled,
              frozen["sourcePixelSelfReviewSHA256"]as?String==currentSourcePixelEvidenceSHA256,
              (frozen["oneDegreeEmptyCalibrationStepEnabled"] as? Bool ?? false)==oneDegreeEmptyCalibrationStepEnabled else {
            throw ROBArmRoutineError.blocked("The receipt's nominal-empty experiment flag changed.")
        }
        if approachUnknownAdvisoryEnabled {
            guard activeApproachUnknownAdvisory,activeApproachCanThenHold,physicalSide=="right",!recyclingGripDispatched,!servoPossiblePayloadUncertain,
                  let campaign=current["standingCampaignID"]as?String,campaign==frozen["standingCampaignID"]as?String,
                  ROBControllerArmApproval.shared.standingLocalCanCampaignActive,!ROBControllerArmApproval.shared.standingCanCampaignMayHoldPayload,
                  campaign==ROBControllerArmApproval.shared.standingLocalCanCampaignState?["campaignID"]as?String else {
                throw ROBArmRoutineError.blocked("UNKNOWN advisory lost its exact standing EMPTY open-jaw approach scope.")
            }
        }
        for key in ["receiptID","receiptSHA256","appSessionID","pendingID","command","arm","canCount","summarySHA256","contextIdentity","executingUntilMilliseconds"] {
            guard let a=frozen[key] as? NSObject,let b=current[key] as? NSObject,a.isEqual(b) else {
                throw ROBArmRoutineError.blocked("The active local recycling receipt changed its frozen job identity.")
            }
        }
        guard isRunning,let owner,ROBAmberArmMotionArbiter.shared.isReserved(.left,owner:owner),
              ROBAmberArmMotionArbiter.shared.isReserved(.right,owner:owner) else {
            throw ROBArmRoutineError.blocked("The local recycling task lost physical arm ownership.")
        }
        return current
    }

    private func visualTrial(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,baseline:[Double]) throws -> ROBWorkspaceVisualCalibrationTrial? {
        guard localReceiptCommand != nil else {return nil}
        let receipt=try requireLocalReceipt()
        guard let neck=localNeckIdentity(),
              ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:model,map:map) else {
            throw ROBArmRoutineError.blocked("The current raw estimated map lacks its recorded neck/projection/body scope; no visual-calibration path admitted.")
        }
        if let held=localReceiptHeldNeckIdentity,held != neck {throw ROBArmRoutineError.blocked("The held neck changed after visual-trial planning; rescan before motion.")}
        localReceiptHeldNeckIdentity=neck
        guard map.registrationID == nil else {return nil}
        guard let scope=map.visualCalibrationScope else {throw ROBArmRoutineError.blocked("The raw estimated map is incomplete or lacks its frozen projection/pose evidence.")}
        let poseData=try JSONSerialization.data(withJSONObject:["heldNeck":neck,"baseline":baseline],options:.sortedKeys)
        let now=Date().timeIntervalSince1970*1000
        let value=ROBWorkspaceVisualCalibrationTrial(receiptID:receipt["receiptID"] as? String ?? "",
            receiptSHA256:receipt["receiptSHA256"] as? String ?? "",appSessionID:receipt["appSessionID"] as? String ?? "",
            command:receipt["command"] as? String ?? "",canCount:requestedCanCount,summarySHA256:receipt["summarySHA256"] as? String ?? "",
            authorizationContextIdentity:receipt["contextIdentity"] as? String ?? "",sessionGeneration:generation,
            sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,modelID:model.modelID,geometryID:model.geometryID,
            mappingID:model.selectedMappingID,mapFingerprint:map.fingerprint,bodyMotionIdentity:scope.bodyMotionIdentity,
            estimatedCameraProjectionIdentity:scope.estimatedCameraProjectionIdentity,observationPoseIdentity:scope.observationPoseIdentity,
            currentPoseIdentity:ROBGhostRobotModel.hash(poseData),baseline:baseline,issuedAtMilliseconds:now,
            expiresAtMilliseconds:min(now+600_000,(receipt["executingUntilMilliseconds"] as? NSNumber)?.doubleValue ?? now),
            assumedSpatialErrorMeters:localVisualTrialAssumedSpatialErrorMeters,
            operatorClearedUnknownApproach:activeApproachUnknownAdvisory ? true:nil)
        _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(map,model:model,generation:generation,
            sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:now,trial:value)
        return value
    }

    private static func rebasedVisualTrial(_ value:ROBWorkspaceVisualCalibrationTrial,baseline:[Double]) -> ROBWorkspaceVisualCalibrationTrial {
        .init(receiptID:value.receiptID,receiptSHA256:value.receiptSHA256,appSessionID:value.appSessionID,command:value.command,
            canCount:value.canCount,summarySHA256:value.summarySHA256,authorizationContextIdentity:value.authorizationContextIdentity,
            sessionGeneration:value.sessionGeneration,sceneID:value.sceneID,cameraGeneration:value.cameraGeneration,
            modelID:value.modelID,geometryID:value.geometryID,mappingID:value.mappingID,mapFingerprint:value.mapFingerprint,
            bodyMotionIdentity:value.bodyMotionIdentity,estimatedCameraProjectionIdentity:value.estimatedCameraProjectionIdentity,
            observationPoseIdentity:value.observationPoseIdentity,
            currentPoseIdentity:ROBGhostRobotModel.hash(Data((value.currentPoseIdentity+baseline.map(String.init(describing:)).joined(separator:",")).utf8)),
            baseline:baseline,issuedAtMilliseconds:value.issuedAtMilliseconds,expiresAtMilliseconds:value.expiresAtMilliseconds,
            assumedSpatialErrorMeters:value.assumedSpatialErrorMeters,operatorClearedUnknownApproach:value.operatorClearedUnknownApproach)
    }

    private func requireLiveVisualTrial(_ trial:ROBWorkspaceVisualCalibrationTrial,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel) throws {
        let e=try requireLocalReceipt()
        guard vision.fresh else {throw ROBArmRoutineError.blocked("The visual-calibration motion needs a fresh camera frame; the unchanged job receipt does not permit stale-image travel.")}
        guard trial.receiptID==e["receiptID"] as? String,trial.receiptSHA256==e["receiptSHA256"] as? String,
              trial.appSessionID==e["appSessionID"] as? String,trial.command==e["command"] as? String,
              trial.summarySHA256==e["summarySHA256"] as? String,trial.authorizationContextIdentity==e["contextIdentity"] as? String,
              (trial.operatorClearedUnknownApproach ?? false)==activeApproachUnknownAdvisory,
              !activeApproachUnknownAdvisory || (activeApproachCanThenHold && physicalSide=="right" && !recyclingGripDispatched && !servoPossiblePayloadUncertain && !jawSetupDispatchUncertain),
              trial.assumedSpatialErrorMeters==localVisualTrialAssumedSpatialErrorMeters,
              localReceiptHeldNeckIdentity != nil,localReceiptHeldNeckIdentity==localNeckIdentity(),
              ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:model,map:map) else {
            throw ROBArmRoutineError.blocked("The live receipt, held neck or current projection no longer matches this visual-trial proof.")
        }
        _ = try ROBWorkspaceCollisionPlan.validateVisualCalibrationTrialMap(map,model:model,generation:generation,
            sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000,trial:trial)
    }

    private func accountedJawCommand(_ dispatch:()->UInt64) -> UInt64 {
        let id=dispatch();if id != 0 {jawCommandDispatched=true};return id
    }

    private func retainLocalReceiptCamera() {
        localReceiptCameraTimer?.invalidate()
        // setActive(true) clears real Vision frames/epoch even when already
        // active. Keep the existing fresh stream which the receipt binds.
        ROBArmRoutineCoordinator.shared.cameraDemand?(true)
        let timer=Timer(timeInterval:0.25,repeats:true){[weak self] timer in
            guard let self else {timer.invalidate();return}
            guard !self.isRunning else {return}
            if ROBControllerArmApproval.shared.localRecyclingApprovalState == nil {
                timer.invalidate();self.localReceiptCameraTimer=nil
                self.localReceiptModel=nil
                self.vision.setActive(false);ROBArmRoutineCoordinator.shared.cameraDemand?(false)
            }
        }
        localReceiptCameraTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }

    @MainActor private func prepareLocalCanObservationView(_ can:ROBWorkspaceLocatedObject,map:ROBWorkspaceCollisionSnapshot) async throws {
        guard localReceiptCommand != nil else {return}
        guard !leased,leaseRenewals.isEmpty,!recyclingGripDispatched,
              let observation=map.observations.first(where:{$0.sequence==can.sequence && abs($0.capturedAtMilliseconds-can.capturedAt)<=1}),
              let lower=observation.recordedLowerTarget,let upper=observation.recordedUpperTarget,
              let pan=observation.recordedPanDegrees else {
            throw ROBArmRoutineError.blocked("The selected can has no exact recorded observation view; no blind grasp-view change admitted.")
        }
        cameraReady=false;localReceiptHeldNeckIdentity=nil
        phase="settling selected-can observation view"
        try await wait(12){ROBWorkspaceSearch.shared.prepareView?(pan,upper)==true}
        try await wait(10){ROBWorkspaceSearch.shared.viewReady?(pan,upper)==true && self.vision.fresh && ROBArmRoutineCoordinator.shared.viewIsStationary?()==true}
        let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
        let expectedPan=ROBWorkspaceSearch.shared.panTargetForView?(pan)?.intValue
        let held=localNeckIdentity(),projectionCurrent=ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:try workspaceModel(),map:map)
        var fields:[String]=[]
        if expectedPan==nil {fields.append("pan_target_unavailable")}
        if expectedPan==nil || neck["pan"]as?Int != expectedPan {fields.append("raw_pan_target")}
        if neck["lower"]as?Int != lower {fields.append("raw_lower_target")}
        if neck["upper"]as?Int != upper {fields.append("raw_upper_target")}
        if vision.cameraGeneration != map.cameraGeneration {fields.append("camera_generation")}
        if held==nil {fields.append("stationary_neck_identity")}
        if !projectionCurrent {fields.append("physical_projection")}
        guard fields.isEmpty,let held else {
            let facts:[String:Any]=["reason":"selected_can_view_mismatch","failed_fields":fields,
                "requested_pan_degrees":pan,"expected_raw_pan":expectedPan as Any? ?? NSNull(),
                "actual_raw_pan":neck["pan"] ?? NSNull(),"actual_pan_degrees":neck["pan_degrees"] ?? NSNull(),
                "expected_lower":lower,"actual_lower":neck["lower"] ?? NSNull(),"expected_upper":upper,"actual_upper":neck["upper"] ?? NSNull(),
                "expected_camera_generation":map.cameraGeneration.uuidString,"actual_camera_generation":vision.cameraGeneration.uuidString,
                "stationary_neck_identity_available":held != nil,"physical_projection_current":projectionCurrent]
            var report=collisionReviewStatus as? [String:Any] ?? [:];report["selected_can_view_diagnostic"]=facts
            collisionReviewStatus=report as NSDictionary
            throw ROBArmRoutineError.blocked("The settled can-source view changed: "+fields.joined(separator:", ")+". Requested pan \(pan)°, expected raw \(expectedPan.map(String.init) ?? "unavailable"), actual raw \(neck["pan"] ?? NSNull()); no reach sent.")
        }
        localReceiptHeldNeckIdentity=held
    }

    @MainActor private func publishCollisionReview(map: ROBWorkspaceCollisionSnapshot, detail: String,
                                                  blocked: Bool = false) {
        collisionReviewStatus = ["status":blocked ? "blocked" : "captured", "detail":detail,
            "blocked_reason":blocked ? detail : "", "scene_id":map.sceneID.uuidString,
            "map_fingerprint":map.fingerprint, "occupied_voxels":map.occupiedVoxelCount,
            "free_voxels":map.freeVoxelCount, "registration_verified":map.registrationID != nil,
            "observed_frames":map.observedFrameCount]
        update(detail)
    }

    /// No arm travel, including a taught empty return, precedes this scan.
    /// Existing object-search frames may supply the same fresh scene evidence.
    @MainActor private func ensureCollisionScene(model: ROBGhostRobotModel) async throws {
        let prior = inactiveWorkspaceSearch
        try await beginHeldSceneObservation()
        defer { inactiveWorkspaceSearch = prior }
        guard !leased else { throw ROBArmRoutineError.blocked("Hold the arm before scanning its environment.") }
        if localReceiptCommand != nil,!recyclingGripDispatched {localReceiptHeldNeckIdentity=nil}
        let now = Date().timeIntervalSince1970*1000
        let map: ROBWorkspaceCollisionSnapshot
        if sceneCapturedForThisTask, let observed = ROBWorkspaceSearch.shared.collisionSnapshot,
           observed.sessionGeneration == generation, observed.cameraGeneration == vision.cameraGeneration,
           observed.modelID == model.modelID, observed.geometryID == model.geometryID,
           (0...ROBWorkspaceCollisionPlan.maximumMapAgeMilliseconds).contains(now-observed.oldestCapturedAtMilliseconds) {
            map = observed
        } else {
            map = try await ROBWorkspaceSearch.shared.scanCollisionScene(model:model,generation:generation,
                check:{ try self.check() },progress:{ self.update($0) })
        }
        collisionMap = map; collisionModel = model; collisionReviewProposal = nil
        sceneCapturedForThisTask = true
        do {
            if let trial=try visualTrial(map:map,model:model,baseline:try measured().positionsRadians.map(\.doubleValue)) {
                publishCollisionReview(map:map,detail:trial.detail)
            } else {
                _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,
                    sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
                publishCollisionReview(map:map,detail:"Fresh workspace map ready for complete arm-path collision review.")
            }
        } catch {
            publishCollisionReview(map:map,detail:error.localizedDescription,blocked:true)
            throw error
        }
    }

    @MainActor private func beginHeldSceneObservation(allowActiveForPassiveCapture:Bool = false) async throws {
        guard !leased, leaseRenewals.isEmpty else {
            throw ROBArmRoutineError.blocked("Finish the measured arm hold before moving the neck to scan.")
        }
        var baseline: [String:(positions:[Double],modes:[Int])] = [:]
        var sequences: [String:UInt64] = [:]
        for side in ["left","right"] {
            let modes = gateway.modes(forArm:side).map(\.intValue)
            guard let sample = gateway.telemetry(forArm:side), sample.effectiveSampleAgeMilliseconds <= 250,
                  sample.positionsRadians.count == 7, sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                  modes.count == 7, ([0,2].contains(modes[0]) || allowActiveForPassiveCapture && modes[0]==1), modes.allSatisfy({ $0 == modes[0] }),
                  sample.statuses.map(\.intValue) == modes else {
                throw ROBArmRoutineError.blocked("Fresh unchanged holding or inactive feedback is required for the neck-only scene scan.")
            }
            baseline[side] = (sample.positionsRadians.map(\.doubleValue),modes)
            sequences[side] = sample.sequence
        }
        sceneHold = baseline; inactiveWorkspaceSearch = true; cameraReady = false; positionReady = false
        // Distinct fresh packets over a measured interval establish that both
        // arms have actually settled before any neck/depth capture begins.
        // Position mode alone is not proof that an earlier move has stopped.
        let started = ProcessInfo.processInfo.systemUptime
        var distinctSamples = ["left":0,"right":0]
        while ProcessInfo.processInfo.systemUptime-started < 0.25 || distinctSamples.values.contains(where: { $0 < 3 }) {
            try check()
            guard ProcessInfo.processInfo.systemUptime-started < 2 else {
                throw ROBArmRoutineError.blocked("Both arms must settle with advancing feedback before scanning workspace geometry.")
            }
            try await Task.sleep(nanoseconds:50_000_000)
            for side in ["left","right"] {
                guard let sample = gateway.telemetry(forArm:side), let held = baseline[side],
                      sample.effectiveSampleAgeMilliseconds <= 250,
                      sample.positionsRadians.count == 7,
                      sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                      gateway.modes(forArm:side).map(\.intValue) == held.modes,
                      sample.statuses.map(\.intValue) == held.modes,
                      1.5*zip(sample.positionsRadians.map(\.doubleValue),held.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003 else {
                    throw ROBArmRoutineError.blocked("An arm is still moving; no workspace capture or arm command was sent.")
                }
                if sample.sequence > (sequences[side] ?? 0) {
                    sequences[side] = sample.sequence; distinctSamples[side,default:0] += 1
                }
            }
        }
    }

    private func checkCollisionContext() throws {
        if let calibration=activeOneDegreeCalibration {
            guard oneDegreeEmptyCalibrationStepEnabled,!nominalEmptyCommissioningStepEnabled,localReceiptCommand=="right_recycle_cans",physicalSide=="right",
                  ROBControllerArmApproval.shared.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:summary,arm:physicalSide),
                  let map=collisionMap,let model=collisionModel,let trial=calibration.context.visualTrial,
                  map.fingerprint==calibration.context.mapFingerprint,let path=proposal,path.kind=="one_degree_empty_calibration",
                  path.baseline==calibration.baseline,path.steps==[calibration.step],path.steps[0].jawAction==nil,
                  !jawCommandDispatched,!jawSetupDispatchUncertain,!recyclingGripDispatched else {
                throw ROBArmRoutineError.blocked("The separate one-degree EMPTY calibration permission, source or no-jaw scope changed.")
            }
            try requireLiveVisualTrial(trial,map:map,model:model)
            let q=try measured().positionsRadians.map(\.doubleValue),delta=zip(calibration.baseline,calibration.goal).map{$1-$0}
            let length=delta.reduce(0.0){$0+$1*$1}
            let fraction=length>0 ? min(1,max(0,zip(zip(q,calibration.baseline),delta).reduce(0.0){$0+($1.0.0-$1.0.1)*$1.1}/length)):0
            let nearest=zip(calibration.baseline,delta).map{$0+fraction*$1}
            let drift=1.5*zip(q,nearest).reduce(0.0,{$0+abs($1.0-$1.1)})
            guard drift<=0.003,calibration.maximumHullTravelMeters+drift<=0.020 else {
                throw ROBArmRoutineError.blocked("Measured joints left the one-degree EMPTY calibration corridor or2cm modeled travel bound; hold requested.")
            }
            return
        }
        if let nominal=activeNominalRetreat {
            guard nominalEmptyCommissioningStepEnabled,localReceiptCommand=="right_recycle_cans",physicalSide=="right",
                  ROBControllerArmApproval.shared.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:physicalSide,modelAssumedSelfEnabled:nominalModelAssumedSelfEnabled,sourcePixelSelfReviewSHA256:currentSourcePixelEvidenceSHA256),
                  let map=collisionMap,let model=collisionModel,let trial=nominal.context.visualTrial,
                  (nominal.modelAssumedSelfAudit != nil)==nominalModelAssumedSelfEnabled,
                  (nominal.sourcePixelSelfAudit != nil)==sourcePixelSelfReviewEnabled,
                  map.fingerprint==nominal.context.mapFingerprint,let path=proposal,path.kind=="nominal_empty_commissioning",
                  path.baseline==nominal.baseline,path.steps==[nominal.step],path.steps[0].jawAction==nil,
                  !jawCommandDispatched,!jawSetupDispatchUncertain,!recyclingGripDispatched else {
                throw ROBArmRoutineError.blocked("The separate nominal-empty proof, receipt flag or no-jaw scope changed.")
            }
            try requireLiveVisualTrial(trial,map:map,model:model)
            let q=try measured().positionsRadians.map(\.doubleValue),delta=zip(nominal.baseline,nominal.goal).map{$1-$0}
            let length=delta.reduce(0.0){$0+$1*$1}
            let fraction=length>0 ? min(1,max(0,zip(zip(q,nominal.baseline),delta).reduce(0.0){$0+($1.0.0-$1.0.1)*$1.1}/length)):0
            let nearest=zip(nominal.baseline,delta).map{$0+fraction*$1}
            guard 1.5*zip(q,nearest).reduce(0.0,{$0+abs($1.0-$1.1)})<=min(0.003,nominal.minimumSweptNominalClearanceMeters/2) else {
                throw ROBArmRoutineError.blocked("Measured joints left the bounded nominal-empty corridor; hold requested.")
            }
            return
        }
        if let retreat=activeLocalRetreat {
            guard activeCommand=="left_recycle_can",localReceiptCommand != nil,
                  let map=collisionMap,let model=collisionModel,let trial=retreat.context.visualTrial,
                  let current=ROBWorkspaceSearch.shared.collisionSnapshot,current.fingerprint==map.fingerprint,
                  let path=proposal,path.kind=="initial_empty_visual_retreat",path.baseline==retreat.baseline,
                  path.steps==[retreat.step],path.steps[0].jawAction==nil,!recyclingGripDispatched else {
                throw ROBArmRoutineError.blocked("The distinct initial empty-retreat proof or current scene changed.")
            }
            try requireLiveVisualTrial(trial,map:map,model:model)
            let q=try measured().positionsRadians.map(\.doubleValue),delta=zip(retreat.baseline,retreat.goal).map{$1-$0}
            let length=delta.reduce(0.0){$0+$1*$1}
            let fraction=length>0 ? min(1,max(0,zip(zip(q,retreat.baseline),delta).reduce(0.0){$0+($1.0.0-$1.0.1)*$1.1}/length)) : 0
            let nearest=zip(retreat.baseline,delta).map{$0+fraction*$1}
            guard 1.5*zip(q,nearest).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
                throw ROBArmRoutineError.blocked("The actual arm left the initial empty-retreat corridor.")
            }
            return
        }
        if activeCommand == "left_estimated_calibration" {
            guard let active = activeEstimated, proposal == active.proposal,
                  collisionMap?.fingerprint == active.map.fingerprint,
                  collisionMap?.sceneID == active.map.sceneID else {
                throw ROBArmRoutineError.blocked("Missing frozen estimated single-step proof; hold requested.")
            }
            try validateEstimatedContext(active,generation:generation)
            return
        }
        guard let map = collisionMap, let model = collisionModel,
              let current = ROBWorkspaceSearch.shared.collisionSnapshot,
              current.sceneID == map.sceneID, current.fingerprint == map.fingerprint else {
            throw ROBArmRoutineError.blocked("Scan current workspace geometry before arm travel.")
        }
        if localReceiptCommand != nil {
            _ = try requireLocalReceipt()
            guard localReceiptHeldNeckIdentity == nil || localReceiptHeldNeckIdentity == localNeckIdentity(),
                  ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:model,map:map) else {
                throw ROBArmRoutineError.blocked("The held neck or physical camera projection changed after the local trial review.")
            }
        }
        if localReceiptCommand != nil, map.registrationID == nil {
            _ = try visualTrial(map:map,model:model,baseline:try measured().positionsRadians.map(\.doubleValue))
        } else {
            _ = try ROBWorkspaceCollisionPlan.validateMap(map,model:model,generation:generation,
                sceneID:map.sceneID,cameraGeneration:vision.cameraGeneration,nowMilliseconds:Date().timeIntervalSince1970*1000)
        }
    }

    @MainActor private func workspaceConnector(to goal: [Double], name: String) async throws -> ROBLeftGestureProposal {
        try checkCollisionContext()
        guard let map = collisionMap, let model = collisionModel else {
            throw ROBArmRoutineError.blocked("No current workspace geometry is available.")
        }
        let baseline = try measured().positionsRadians.map(\.doubleValue), session = generation
        let camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
        let visual=try visualTrial(map:map,model:model,baseline:baseline)
        let result = try await Task.detached(priority:.userInitiated) {
            let path:ROBWorkspaceCollisionPlan
            if let visual {
                path=try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:baseline,to:goal,map:map,model:model,generation:session,
                    sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:visual)
            }else{
                path=try ROBWorkspaceCollisionPlan.make(from:baseline,to:goal,map:map,model:model,generation:session,
                    sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now)
            }
            return try ROBLeftGestureCompiler.compile(kind:"workspace_collision",name:name,model:model,baseline:baseline,
                generation:session,workspaceCollisionPlan:path,collisionMap:map,collisionSceneID:map.sceneID,
                collisionCameraGeneration:camera,visualCalibrationTrial:visual,nowMilliseconds:now)
        }.value
        try check(); try checkCollisionContext()
        guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue),baseline,tolerance:0.015) else {
            throw ROBArmRoutineError.blocked("The arm moved while its dynamic route was being calculated.")
        }
        collisionReviewProposal = result
        collisionReviewStatus = ["status":"reviewed","detail":"Complete arm connector checked against current scene geometry.",
            "registration_verified":map.registrationID != nil,"visual_calibration_trial":visual != nil,"checked_poses":result.workspaceCollisionPlan?.checkedPoseCount ?? 0,
            "required_clearance_m":ROBWorkspaceCollisionPlan.mechanicalClearanceMeters]
        return result
    }

    private func start(_ command: String, summary: String, limit: Double,
                       completion: @escaping (NSDictionary) -> Void) {
        let id = UUID()
        // Reserve both physical arms so another controller cannot move the
        // other arm into this trial. Only the selected arm receives waypoints;
        // the right-task scope separately covers current-pose holds on both.
        guard ROBAmberArmMotionArbiter.shared.reserve(.left, owner: id) else {
            completion(["status": "blocked", "detail": "Another controller owns the left arm."]); return
        }
        guard ROBAmberArmMotionArbiter.shared.reserve(.right, owner: id) else {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: id)
            completion(["status": "blocked", "detail": "Another controller owns the right arm."]); return
        }
        if command != "left_estimated_calibration" {
            invalidateEstimatedPreview(reason:"Another operation replaced the estimated preview",stopCamera:false)
            activeEstimated = nil
        }
        owner = id; isRunning = true; self.summary = summary; currentLimit = limit
        activeApproachUnknownAdvisory = localReceiptCommand != nil && approachUnknownAdvisoryEnabled
        activeApproachCanThenHold = localReceiptCommand != nil && approachCanThenHoldEnabled
        activeHoldAfterInitialEmptyLift = localReceiptCommand != nil && holdAfterInitialEmptyLiftEnabled
        initialEmptyLiftHeldEvidence = nil
        collisionMap = command == "left_estimated_calibration" ? activeEstimated?.map : nil
        collisionModel = command == "left_estimated_calibration" ? activeEstimated?.model : nil
        sceneCapturedForThisTask = command == "left_estimated_calibration"; reviewedDispatchStart = nil
        armTravelDispatched = false; jawCommandDispatched=false;jawSetupDispatchUncertain=false;servoPossiblePayloadUncertain=false;recyclingReachDispatched=false
        localReceiptHeldNeckIdentity=nil;localReceiptPerceptionFailure=false;sceneHold = [:];localCampaignRecoveryReason=nil
        passiveFeedbackPauseStarted=nil;lastHeldFeedbackDiagnostic=nil
        activeCommand = command;activeNominalRetreat=nil;activeOneDegreeCalibration=nil; recyclingCan=nil; lastVisualGraspEvidence=nil; movingTargetReplansRemaining=activeApproachCanThenHold ? 0:1; recyclingGripDispatched=false; inactiveWorkspaceSearch = false; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        lastRecordingPath = ""; sampleCount = 0; peakJump = 0;servoTelemetryHistory=[];servoEvidenceWriteError=nil;taskOpeningCommandAtMilliseconds=nil
        currentSpikeCompletionTask?.cancel();currentSpikeCompletionTask=nil
        currentSpikeEvidence=nil;previousCurrentEvidence=nil;currentSpikeEvidencePath="";currentSpikeEvidenceWriteError=nil
        currentSpikePostStopDeadline=nil;currentSpikeCollectionFinished=false
        failure = nil; generation = 0; cameraReady = false; positionReady = false; leased = false
        allowsArmTravel = ["left_wave", "left_prepare", "left_relax", "left_ghost", "left_object_cycle", "left_recycle_can", "left_estimated_calibration"].contains(command)
        proposalStep = -1; sentPath = []
        waiting = []; acks = [:]; holdConfirmations = [:]; leaseRenewals = [:]; phase = "preflight"
        let workspace = ["left_recycle_can", "left_search_workspace", "left_check_hanging", "left_scan_clearance", "left_estimated_preview"].contains(command)
        deadline = ProcessInfo.processInfo.systemUptime + (workspace ? 590 : allowsArmTravel ? 170 : 115)
        if !estimatedCameraRetained {
            if localReceiptCommand == nil {vision.setActive(true)}
            ROBArmRoutineCoordinator.shared.cameraDemand?(true)
        }
        if !Self.neckOnlyCommands.contains(command), !gateway.isReady() { ROBAmberGatewayTunnel.shared.connect() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.monitor() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.beginRecording(command)
                let result = try await self.execute(command)
                self.finish(result, completion: completion)
            } catch {
                self.finish(["status": "blocked", "detail": self.failure ?? error.localizedDescription], completion: completion)
            }
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw ROBArmRoutineError.blocked(failure) }
        if localReceiptCommand != nil {
            guard activeApproachUnknownAdvisory==approachUnknownAdvisoryEnabled else {throw ROBArmRoutineError.blocked("The frozen UNKNOWN advisory option changed.")}
            guard activeApproachCanThenHold==approachCanThenHoldEnabled,!activeApproachCanThenHold || !recyclingGripDispatched else {throw ROBArmRoutineError.blocked("The frozen open-jaw approach option changed or a grip was observed; no further travel is permitted.")}
            guard activeHoldAfterInitialEmptyLift==holdAfterInitialEmptyLiftEnabled else {
                throw ROBArmRoutineError.blocked("The frozen initial-lift hold option changed; no further motion is permitted.")
            }
            if activeHoldAfterInitialEmptyLift && (jawCommandDispatched || jawSetupDispatchUncertain || recyclingGripDispatched) {
                throw ROBArmRoutineError.blocked("The empty lift-only test observed a jaw command; holding without any further step.")
            }
            captureActualCampaignInterruption()
            do {_ = try requireLocalReceipt()} catch {captureActualCampaignInterruption();throw error}
        }
        let passive=inactiveWorkspaceSearch && sceneHold.count==2 && sceneHold.values.allSatisfy{$0.modes==Array(repeating:0,count:7)} &&
            !leased && !positionReady && !armTravelDispatched && !jawCommandDispatched && !jawSetupDispatchUncertain && !recyclingGripDispatched
        if localReceiptCommand != nil {
            let sides=passive ? ["left","right"]:[arm == "left" ? "right":"left"]
            var ageFailures:[String]=[]
            for side in sides {if let held=sceneHold[side] {
                let sample=gateway.telemetry(forArm:side),q=sample?.positionsRadians.map(\.doubleValue) ?? []
                let motor=sample?.effectiveSampleAgeMilliseconds ?? .infinity,gripper=sample?.effectiveGripperFeedbackAgeMilliseconds ?? .infinity
                let modes=gateway.modes(forArm:side).map(\.intValue),reported=sample?.statuses.map(\.intValue) ?? []
                let fields=ROBHeldArmFeedbackGuard.failures(present:sample != nil,motorAge:motor,gripperAge:gripper,q:q,expectedQ:held.positions,
                    gatewayModes:modes,reportedModes:reported,expectedModes:held.modes)
                if !fields.isEmpty {
                    let delivery=sample.map{max(0,ProcessInfo.processInfo.systemUptime-$0.receivedAtUptime)*1000} ?? .infinity
                    let drift=q.count==7 ? 1.5*zip(q,held.positions).reduce(0.0,{$0+abs($1.0-$1.1)}):Double.infinity
                    let detail="Stationary arm guard failed: gateway=\(side), physical=\(side=="left" ? "right":"left"), fields=\(fields), motor_age_ms=\(motor), gripper_age_ms=\(gripper), delivery_elapsed_ms=\(delivery), drift_m=\(drift), sequence=\(sample?.sequence ?? 0), expected_modes=\(held.modes), gateway_modes=\(modes), reported_modes=\(reported), expected_q=\(held.positions), current_q=\(q)."
                    if lastHeldFeedbackDiagnostic==nil {
                        lastHeldFeedbackDiagnostic=detail
                        if !lastRecordingPath.isEmpty {
                            let url=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("held-feedback-diagnostic.json")
                            if let bytes=try?JSONSerialization.data(withJSONObject:["kind":"stationary_arm_guard_diagnostic","detail":detail,"phase":phase,
                                "checkedAtMilliseconds":Date().timeIntervalSince1970*1000,"motionAuthority":false],options:.sortedKeys) {
                                try?bytes.write(to:url,options:.atomic);try?FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                            }
                        }
                    }
                    if passive,ROBHeldArmFeedbackGuard.agesOnly(fields) {ageFailures.append(detail)}
                    else {throw ROBArmRoutineError.blocked(detail)}
                }
            }}
            if !ageFailures.isEmpty {
                let now=ProcessInfo.processInfo.systemUptime,detail=ageFailures.joined(separator:" ")
                if passiveFeedbackPauseStarted==nil {passiveFeedbackPauseStarted=now}
                guard now-passiveFeedbackPauseStarted!<=2 else {throw ROBArmRoutineError.blocked(detail+" Passive same-pose feedback did not recover within2seconds.")}
                throw ROBPassiveFeedbackPause(detail:detail+" Pausing nonactuating search for fresh unchanged feedback; no command admitted.")
            }
            passiveFeedbackPauseStarted=nil
        }
        if localReceiptCommand != nil,sourcePixelSelfReviewEnabled {
            guard let view=sourcePixelCurrentView,let sample=gateway.telemetry(forArm:"right"),sample.effectiveSampleAgeMilliseconds<=150,
                  sample.positionsRadians.count==7,view.physicalLeftBaseline.count==7,
                  1.5*zip(sample.positionsRadians.map(\.doubleValue),view.physicalLeftBaseline).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.002 else {
                throw ROBArmRoutineError.blocked("The observed source-pixel scene's physical LEFT held pose changed.")
            }
        }
        guard Self.neckOnlyCommands.contains(activeCommand) || activeCommand == "left_relax" || (physicalSide == "left" ? ROBControllerArmApproval.shared.authorizesLeftArmTrial(summary) : ROBControllerArmApproval.shared.authorizesRightArmTrial(summary)) else {
            throw ROBArmRoutineError.blocked("Left-arm authorization ended; hold requested.")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ROBArmRoutineError.blocked("Left-arm trial timed out.") }
        if generation > 0 {
            guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == generation else {
                throw ROBArmRoutineError.blocked("Arm gateway session changed.")
            }
            if !inactiveWorkspaceSearch { _ = try measured() }
            else {
                guard !leased, !positionReady, leaseRenewals.isEmpty, sceneHold.count == 2 else {
                    throw ROBArmRoutineError.blocked("The stationary scene-scan hold is unavailable.")
                }
                for (side,baseline) in sceneHold where localReceiptCommand == nil || !passive {
                    guard let sample = gateway.telemetry(forArm:side), sample.effectiveSampleAgeMilliseconds <= 250,
                          gateway.modes(forArm:side).map(\.intValue) == baseline.modes,
                          sample.statuses.map(\.intValue) == baseline.modes,
                          sample.positionsRadians.count == 7,
                          sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
                          1.5*zip(sample.positionsRadians.map(\.doubleValue),baseline.positions).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= ROBWorkspaceCollisionPlan.sweptPointTravelMeters else {
                        throw ROBArmRoutineError.blocked("An arm changed pose, mode or feedback freshness during the stationary neck scan.")
                    }
                }
            }
        }
        if activeCommand == "left_estimated_calibration", generation > 0 { try checkCollisionContext() }
        if cameraReady {
            guard vision.fresh, ROBArmRoutineCoordinator.shared.viewIsStationary?() == true else {
                throw ROBArmRoutineError.blocked("Live camera or stationary body view lost; left-arm hold requested.")
            }
            guard vision.handsClear else {
                throw ROBArmRoutineError.blocked("Person or hand clearance was lost; an arm hold was requested.")
            }
        }
        if positionReady {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            let statuses = gateway.telemetry(forArm: arm)?.statuses.map(\.intValue) ?? []
            guard modes.count == 7, statuses.count == 7, modes.allSatisfy({ $0 == 2 }), statuses.allSatisfy({ $0 == 2 }) else {
                throw ROBArmRoutineError.blocked("Left arm left position mode or reported a motor fault.")
            }
            if !interactionStage.isEmpty,
               ROBLeftArmInteractionPlan.stationaryFrontTarget(try measured().positionsRadians.map(\.doubleValue)) == nil {
                throw ROBArmRoutineError.blocked("Left arm moved from its held front pose while awaiting object readiness.")
            }
            if let target = taskJawTarget,
               !ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), target) {
                throw ROBArmRoutineError.blocked("Left arm drifted from the task's stationary jaw position; hold requested.")
            }
        }
    }

    private func captureActualCampaignInterruption() {
        guard localReceiptCommand != nil,!recyclingGripDispatched,!jawSetupDispatchUncertain,
              !nominalEmptyCommissioningStepEnabled,!oneDegreeEmptyCalibrationStepEnabled,!activeHoldAfterInitialEmptyLift else{return}
        if !gateway.isReady() || (generation>0 && (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value != generation) {
            localCampaignRecoveryReason = .transportLost;return
        }
        let changed=localRecyclingContextDiagnostics["changed_components"] as? [String] ?? []
        if !changed.isEmpty,Set(changed).isSubset(of:["cameraGeneration","runtimeCalibrationIdentity","stereoPolicySHA256"]) {
            localCampaignRecoveryReason = .cameraSourceChanged
        }
    }

    @MainActor private func restartCampaignAfterFreshObservation(command:String,campaignID:String) {
        localCampaignRecoveryTask?.cancel()
        localCampaignRecoveryTask=Task { @MainActor [weak self] in
            guard let self else{return}
            let broker=ROBControllerArmApproval.shared
            func current()->Bool {
                !Task.isCancelled && !self.isRunning && !broker.isPending && broker.standingLocalCanCampaignActive &&
                    broker.standingLocalCanCampaignState?["campaignID"] as? String==campaignID
            }
            guard current() else{return}
            // Existing recovery is telemetry-only: no activation, target,
            // encoder reset, CAN/core restart or replayed waypoint.
            ROBAmberGatewayTunnel.shared.connect()
            self.vision.ensureActiveForTaskObservation();ROBArmRoutineCoordinator.shared.cameraDemand?(true)
            defer {self.localCampaignRecoveryTask=nil}
            let end=ProcessInfo.processInfo.systemUptime+20
            var previous:[String:[Double]]=[:],last:[String:UInt64]=[:],stableSince:TimeInterval?,advances=0
            while current(),ProcessInfo.processInfo.systemUptime<end {
                if self.gateway.isReady(),self.vision.fresh,ROBArmRoutineCoordinator.shared.viewIsStationary?()==true {
                    var next:[String:[Double]]=[:],seq:[String:UInt64]=[:],healthy=true
                    for side in ["left","right"] {
                        guard let sample=self.gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                              sample.effectiveGripperFeedbackAgeMilliseconds<=250,sample.positionsRadians.count==7,
                              sample.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),sample.sequence>(last[side] ?? 0),
                              sample.statuses.count==7,sample.statuses.allSatisfy({[0,2].contains($0.intValue)}) else {healthy=false;break}
                        let q=sample.positionsRadians.map(\.doubleValue)
                        if let p=previous[side],1.5*zip(q,p).reduce(0.0,{$0+abs($1.0-$1.1)})>0.003 {healthy=false;break}
                        next[side]=q;seq[side]=sample.sequence
                    }
                    if healthy,next.count==2 {
                        if stableSince==nil {stableSince=ProcessInfo.processInfo.systemUptime};advances+=1;previous=next;last=seq
                        if advances>=3,ProcessInfo.processInfo.systemUptime-(stableSince ?? .infinity)>=0.15 {
                            guard current() else{return}
                            self.localReceiptModel=nil;self.localReceiptContextComponents=nil
                            self.update("Connection recovered with fresh stationary feedback; rebuilding the can task from a NEW scene and measured pose")
                            let state=broker.standingLocalCanCampaignState
                            let count=(state?["targetCanCount"]as?NSNumber)?.intValue ?? (state?["canCount"]as?NSNumber)?.intValue ?? 4
                            guard (1...ROBRecyclingBatchRequest.maximumCount).contains(count) else{return}
                            self.performUsingLocalRecyclingReceipt(command,target:String(count)) { _ in }
                            return
                        }
                    }else{stableSince=nil;advances=0;previous=[:];last=[:]}
                }else{stableSince=nil;advances=0;previous=[:];last=[:]}
                try?await Task.sleep(nanoseconds:100_000_000)
            }
            if current() {broker.pauseStandingLocalCanCampaign(reason:"Fresh advancing stationary feedback and camera were not restored within20seconds. No arm command was retried.")}
            if !self.isRunning {self.vision.setActive(false);ROBArmRoutineCoordinator.shared.cameraDemand?(false)}
        }
    }

    private func measured() throws -> ROBAmberGatewayTelemetry {
        let current = gateway.telemetry(forArm: arm)
        guard let sample = current, sample.sequence > 0,
              sample.effectiveSampleAgeMilliseconds <= 250, sample.effectiveGripperFeedbackAgeMilliseconds <= 250,
              sample.positionsRadians.count == 7, sample.currents.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }), sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            if localReceiptCommand != nil,!recyclingGripDispatched,!jawSetupDispatchUncertain,
               current==nil || current.map({$0.effectiveSampleAgeMilliseconds>250 || $0.effectiveGripperFeedbackAgeMilliseconds>250})==true {
                localCampaignRecoveryReason = .feedbackLost
            }
            let detail = current.map {
                String(format: " Motor age %.0f ms, gripper age %.0f ms, sequence %llu.",
                    $0.effectiveSampleAgeMilliseconds, $0.effectiveGripperFeedbackAgeMilliseconds, $0.sequence)
            } ?? " No telemetry sample is available."
            throw ROBArmRoutineError.blocked("Fresh left-arm motor and gripper feedback is required." + detail)
        }
        if localCampaignRecoveryReason == .feedbackLost {localCampaignRecoveryReason=nil}
        return sample
    }

    @MainActor private func passiveFeedbackCheckpoint() async throws {
        while true {
            do {try check();return}
            catch is ROBPassiveFeedbackPause {try Task.checkCancellation();try await Task.sleep(nanoseconds:20_000_000)}
        }
    }

    @MainActor private func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try await passiveFeedbackCheckpoint()
            guard ProcessInfo.processInfo.systemUptime < end else { throw ROBArmRoutineError.blocked("Timed out during \(phase).") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await passiveFeedbackCheckpoint()
    }

    @MainActor private func accepted(requiresConfirmedHold: Bool = false, _ dispatch: () -> UInt64) async throws {
        try await passiveFeedbackCheckpoint()
        try check() // Never dispatch on a stale/passively paused packet.
        let id = dispatch()
        guard id != 0 else { throw ROBArmRoutineError.blocked("Gateway refused left-arm command during \(phase), before submission.") }
        waiting.insert(id)
        defer { waiting.remove(id); acks.removeValue(forKey: id); holdConfirmations.removeValue(forKey: id) }
        try await wait(3) { self.acks[id] == true }
        if requiresConfirmedHold, holdConfirmations[id] != true {
            throw ROBArmRoutineError.blocked("Left-arm position hold was not confirmed; no gripper command sent.")
        }
    }

    @MainActor private func execute(_ command: String) async throws -> NSDictionary {
        if localReceiptCommand != nil,activeHoldAfterInitialEmptyLift || activeApproachCanThenHold {
            let result=try await executeSingle(command)
            var output=result as! [String:Any]
            output["batch_requested"]=requestedCanCount;output["batch_completed"]=0;output["transfer_completed"]=false
            output["motion_completed"]=false;output["grasp_visually_supported"]=false
            return output as NSDictionary
        }
        if localReceiptCommand != nil,oneDegreeEmptyCalibrationStepEnabled {
            let result=try await executeOneDegreeEmptyCalibration()
            var output=result as! [String:Any]
            output["batch_requested"]=requestedCanCount;output["batch_completed"]=0;output["transfer_completed"]=false
            return output as NSDictionary
        }
        if localReceiptCommand != nil,nominalEmptyCommissioningStepEnabled {
            let result=try await executeNominalEmptyCommissioning()
            var output=result as! [String:Any]
            output["batch_requested"]=requestedCanCount;output["batch_completed"]=0;output["transfer_completed"]=false
            return output as NSDictionary
        }
        guard command == "left_recycle_can",requestedCanCount>1 || localReceiptCommand != nil else {return try await executeSingle(command)}
        let remaining=(localReceiptEvidence?["standingRemainingTransfers"]as?NSNumber)?.intValue
        guard let count=ROBRecyclingBatchRequest.executionCount(requestedCount:requestedCanCount,standingRemainingTransfers:remaining) else {
            throw ROBArmRoutineError.blocked("The exact recycling target or remaining-transfer count is invalid.")
        }
        var results:[[String:Any]]=[]
        for index in 0..<count {
            try check()
            update("Recycling can \(index+1) of \(count); freshly checking this can and the bucket")
            localReceiptHeldNeckIdentity=nil
            recyclingCan=nil; lastVisualGraspEvidence=nil; movingTargetReplansRemaining=1; recyclingGripDispatched=false; sceneCapturedForThisTask=false;collisionMap=nil;collisionModel=nil;collisionReviewProposal=nil
            let result=try await executeSingle(command)
            results.append(result as! [String:Any])
            guard result["motion_completed"] as? Bool == true,
                  result["grasp_visually_supported"] as? Bool == true else {
                var stopped=result as! [String:Any]
                stopped["batch_requested"]=count;stopped["batch_completed"]=index;stopped["batch_results"]=results
                stopped["detail"]="Recycling test stopped at can \(index+1) of \(count): " + (result["detail"] as? String ?? "Unconfirmed result; held for observation.")
                return stopped as NSDictionary
            }
        }
        return ["status":"accepted_unverified","motion_completed":true,"grasp_visually_supported":true,
            "placement_verified":false,"batch_requested":count,"batch_completed":count,"batch_results":results,
            "physical_arm":physicalSide,"detail":"All \(count) can-transfer paths completed with visual support for each grasp. Gravity releases were commanded over the measured opening; landing inside the bucket remains unmeasured."]
    }

    @MainActor private func captureRightArmCalibrationView(model:ROBGhostRobotModel) async throws ->ROBWorkspaceCollisionSnapshot {
        let search=ROBWorkspaceSearch.shared
        let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
        let pan:Double,upper:Int
        if usesFixedCommissioningKeyframes {
            guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,neck["pan"]as?Int==4000,
                  neck["lower"]as?Int==6011,neck["upper"]as?Int==5450,let actual=neck["pan_degrees"]as?Double else {
                throw ROBArmRoutineError.blocked(sourcePixelSelfReviewEnabled ? "Source-pixel commissioning needs already prepared fixed P4000 L6011 U5450; no head movement sent.":"MODEL-ASSUMED commissioning needs already prepared fixed P4000 L6011 U5450; no head movement sent.")
            }
            pan=actual;upper=5450
        }else {pan = -55.0;upper=5650}
        phase="settling RIGHT arm commissioning view";cameraReady=false;localReceiptHeldNeckIdentity=nil
        if !usesFixedCommissioningKeyframes {try await wait(12){search.prepareView?(pan,upper)==true}}
        let settledSince=ProcessInfo.processInfo.systemUptime
        try await wait(8){search.viewReady?(pan,upper)==true && self.vision.fresh &&
            ROBArmRoutineCoordinator.shared.viewIsStationary?()==true && ProcessInfo.processInfo.systemUptime-settledSince>=1.5}
        guard let pid=ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model) else {throw ROBArmRoutineError.blocked("No current physical camera projection for this empty calibration experiment.")}
        let camera=vision.cameraGeneration,body=ROBFixedHeadBodyMotionIdentity.currentIdentity,session=generation
        if usesFixedCommissioningKeyframes {
            guard let prior=search.collisionSnapshot,prior.registrationID==nil,prior.bodyMotionIdentity==body,
                  prior.sessionGeneration==session,prior.cameraGeneration==camera,prior.modelID==model.modelID,
                  prior.geometryID==model.geometryID,prior.mappingID==model.selectedMappingID,
                  prior.estimatedCameraProjectionIdentity==pid,prior.originalOccupiedSourceGroups != nil,
                  let held=localNeckIdentity() else {
                throw ROBArmRoutineError.blocked(sourcePixelSelfReviewEnabled ? "Source-pixel commissioning needs its exact fresh native complete RAW scan; no object search or replacement scene.":"MODEL-ASSUMED step needs the fresh native full workspace scan with complete original groups; no object search or replacement single-view map.")
            }
            // Preserve the exact full native raw map/fingerprint. The three
            // independent before-keyframes below record the current view;
            // they do not restamp or replace the workspace observations.
            localReceiptHeldNeckIdentity=held;collisionMap=prior;collisionModel=model;sceneCapturedForThisTask=true
            return prior
        }
        var map=ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:session,cameraGeneration:camera,estimatedCameraProjectionIdentity:pid)
        let deadline=ProcessInfo.processInfo.systemUptime+12
        var previous:UInt64=0,frames=0,expired=0,expectedScope:ROBFixedHeadRegistrationScope?
        while frames<3 {
            try check()
            guard ProcessInfo.processInfo.systemUptime<deadline,search.viewReady?(pan,upper)==true,
                  vision.cameraGeneration==camera,body==ROBFixedHeadBodyMotionIdentity.currentIdentity,
                  ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==pid else {throw ROBArmRoutineError.blocked("The empty calibration capture lost its settled source/body/projection context.")}
            let frame=try await vision.settledDepthFrame(deadlineUptime:deadline)
            try check()
            guard frame.sequence>previous,let depth=frame.depth,let k=frame.intrinsics,
                  k.isValid(forWidth:depth.width,height:depth.height),k.rgbOutputUndistorted==true,
                  k.depthRGBGeometryCorrespondence?.status=="matched",frame.cameraGeneration==camera else {
                throw ROBArmRoutineError.blocked("Empty calibration needs advancing actual normalized synchronized RGB-D frames.")
            }
            let controller=ROBFixedHeadCalibrationWindowController.shared,scope=try controller.scope(model:model,frame:frame)
            let neck=controller.readNeck?() ?? [:]
            guard scope.lowerTarget==6011,scope.upperTarget==upper,scope.gatewaySessionGeneration==session,
                  ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:frame.cameraGeneration,
                actualDeviceMXID:frame.intrinsics?.runtimeCalibration?.actualDeviceMXID,
                runtimeCalibrationIdentity:frame.intrinsics?.runtimeCalibration?.identity,
                cameraServiceSourceSHA256:frame.intrinsics?.cameraServiceSourceSHA256,scope:scope,
                inertialJSON:(frame.intrinsics?.inertial).flatMap{try?JSONEncoder().encode($0)})),
                  let actualPan=neck["pan_degrees"] as? Double,abs(actualPan-pan)<=0.05,
                  expectedScope.map({$0==scope}) ?? true,
                  let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,panTarget:scope.panTarget,
                    lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget) else {
                throw ROBArmRoutineError.blocked("The actual RIGHT arm capture does not match its recorded raw neck hold.")
            }
            expectedScope=scope;previous=frame.sequence
            let input=map
            do {map=try await Task.detached(priority:.userInitiated){
                var next=input
                try next.append(width:depth.width,height:depth.height,fx:k.fx,fy:k.fy,cx:k.cx,cy:k.cy,
                    depth:{depth.distanceMillimeters(x:$0,y:$1)},cameraToRobot:matrix,capturedAtMilliseconds:frame.capturedAt,
                    sequence:frame.sequence,cameraGeneration:camera,measuredSelfBounds:[],cameraRegistrationVerified:false,
                    recordedPanDegrees:actualPan,recordedUpperTarget:upper,recordedLowerTarget:scope.lowerTarget,
                    registration:nil,registrationScope:scope,estimatedCameraProjectionIdentity:pid)
                return next
            }.value} catch {
                guard let e=error as?ROBWorkspaceDepthMapError,case .expiredAtProjection=e,expired<3 else {throw error}
                expired+=1;continue
            }
            frames+=1;update("Empty calibration: recorded RIGHT arm depth view \(frames)/3; no arm or jaw movement")
        }
        try check()
        let input=map
        guard let snapshot=await Task.detached(priority:.userInitiated,operation:{input.snapshot()}).value,
              snapshot.registrationID==nil,snapshot.bodyMotionIdentity==body,
              snapshot.observations.last?.recordedUpperTarget==upper,
              snapshot.observations.last?.recordedPanDegrees.map({abs($0-pan)<=0.05})==true,
              search.viewReady?(pan,upper)==true,let held=localNeckIdentity() else {throw ROBArmRoutineError.blocked("The fresh recorded RIGHT arm view was lost before proof freezing.")}
        localReceiptHeldNeckIdentity=held;collisionMap=snapshot;collisionModel=model;sceneCapturedForThisTask=true
        return snapshot
    }

    @MainActor private func archiveNominalKeyframe(_ frame:ROBArmRoutineVision.Frame,stage:String,map:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,writer:ROBWorkspaceRawScanArchive) async throws->ROBWorkspaceRawScanArchive.Record {
        try check();try checkCollisionContext()
        guard usesFixedCommissioningKeyframes,let depth=frame.depth,let k=frame.intrinsics,let runtime=k.runtimeCalibration,
              k.isValid(forWidth:depth.width,height:depth.height),k.rgbOutputUndistorted==true,k.depthRGBGeometryCorrespondence?.status=="matched",
              frame.cameraGeneration==map.cameraGeneration,frame.handsClear,
              (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
              let image=CIContext(options:[.useSoftwareRenderer:true]).createCGImage(frame.image,from:frame.image.extent),
              image.width==depth.width,image.height==depth.height else {throw ROBArmRoutineError.blocked("Commissioning keyframe lost actual paired RGB-D/source pixels.")}
        let controller=ROBFixedHeadCalibrationWindowController.shared,scope=try controller.scope(model:model,frame:frame),neck=controller.readNeck?() ?? [:]
        guard scope.panTarget==4000,scope.lowerTarget==6011,scope.upperTarget==5450,scope.gatewaySessionGeneration==generation,
              neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,let matrix=ROBNeckRGBPoseDisplay.provisionalCameraToModel(model:model,
                panTarget:scope.panTarget,lowerTarget:scope.lowerTarget,upperTarget:scope.upperTarget) else {
            throw ROBArmRoutineError.blocked("Commissioning keyframe lost its exact already-prepared fixed head.")
        }
        var rgba=[UInt8](repeating:0,count:depth.width*depth.height*4)
        let rendered=rgba.withUnsafeMutableBytes{bytes->Bool in
            guard let drawing=CGContext(data:bytes.baseAddress,width:depth.width,height:depth.height,bitsPerComponent:8,
                bytesPerRow:depth.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            drawing.draw(image,in:CGRect(x:0,y:0,width:depth.width,height:depth.height));return true
        }
        guard rendered else {throw ROBArmRoutineError.blocked("Commissioning RGB888 copy failed; no learning success claimed.")}
        var rgb=Data(count:depth.width*depth.height*3)
        rgb.withUnsafeMutableBytes{buffer in let bytes=buffer.bindMemory(to:UInt8.self)
            for i in 0..<(depth.width*depth.height) {bytes[i*3]=rgba[i*4];bytes[i*3+1]=rgba[i*4+1];bytes[i*3+2]=rgba[i*4+2]}}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        func json(_ object:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)}
        func measuredArm(_ side:String,_ gatewayArm:String)throws->ROBWorkspaceRawScanArchive.ArmFeedback {
            let candidates=nominalBothArmHistory[gatewayArm] ?? []
            let sample=candidates.filter{$0.generation==generation}.map(\.sample).min{a,b in
                abs(a.receivedAt.timeIntervalSince1970*1000-a.sampleAgeAtReceiptMilliseconds-frame.capturedAt)<abs(b.receivedAt.timeIntervalSince1970*1000-b.sampleAgeAtReceiptMilliseconds-frame.capturedAt)
            }
            guard let sample,sample.sampleAgeAtReceiptMilliseconds.isFinite,
                  abs(sample.receivedAt.timeIntervalSince1970*1000-sample.sampleAgeAtReceiptMilliseconds-frame.capturedAt)<=150 else {
                throw ROBArmRoutineError.blocked("Commissioning keyframe lacks actual exposure-matched BOTH-arm measured q; no substitute planned pose.")
            }
            let sourceModel=try ROBGhostRobotModel(directory:model.directory,physicalSide:side)
            let feedbackTime=sample.receivedAt.timeIntervalSince1970*1000-sample.sampleAgeAtReceiptMilliseconds
            return .init(physicalSide:side,gatewayArm:gatewayArm,telemetrySequence:sample.sequence,
                receivedAtHostMilliseconds:sample.receivedAt.timeIntervalSince1970*1000,effectiveSampleAgeMilliseconds:sample.effectiveSampleAgeMilliseconds,
                effectiveGripperAgeMilliseconds:sample.effectiveGripperFeedbackAgeMilliseconds,positionsRadians:sample.positionsRadians.map(\.doubleValue),
                reportedModes:sample.statuses.map(\.intValue),gatewayModes:gateway.modes(forArm:gatewayArm).map(\.intValue),
                exposureOffsetMilliseconds:.available(frame.capturedAt-feedbackTime),referenceIdentity:.unavailable("Raw vendor encoders; native reference token has no archive export identity"),
                modelID:sourceModel.modelID,geometryID:sourceModel.geometryID,mappingID:sourceModel.selectedMappingID)
        }
        let left=try measuredArm("left","right"),right=try measuredArm("right","left")
        let contracts:[String:Any]=["stage":stage,"pixelSource":"retained normalized CIImage rendered RGB888 at original paired depth dimensions",
            "rgbOutputUndistorted":k.rgbOutputUndistorted as Any? ?? NSNull(),"depthRGBGeometryCorrespondence":k.depthRGBGeometryCorrespondence?.status as Any? ?? NSNull(),
            "cameraServiceSourceSHA256":k.cameraServiceSourceSHA256 as Any? ?? NSNull(),"runtimeCalibrationIdentity":runtime.identity,
            "sourceSize":k.sourceSize as Any? ?? NSNull(),"sourceIntrinsics":k.sourceIntrinsics as Any? ?? NSNull(),"imageTransform":k.imageTransform as Any? ?? NSNull(),
            "depthSourceSize":k.depthSourceSize as Any? ?? NSNull(),"depthSourceIntrinsics":k.depthSourceIntrinsics as Any? ?? NSNull(),"depthImageTransform":k.depthImageTransform as Any? ?? NSNull(),
            "rgbSourceDistortionCoefficients":k.rgbSourceDistortionCoefficients as Any? ?? NSNull(),"depthSourceDistortionCoefficients":k.depthSourceDistortionCoefficients as Any? ?? NSNull()]
        let input=ROBWorkspaceRawScanArchive.Frame(frameID:UUID(),sequence:frame.sequence,capturedAtHostMilliseconds:frame.capturedAt,
            rgbCapturedAtHostMilliseconds:.unavailable("Independent RGB exposure host timestamp not exported by retained Vision frame"),
            depthCapturedAtHostMilliseconds:.unavailable("Independent depth exposure host timestamp not exported by retained Vision frame"),
            sourceTimestampJSON:.unavailable("Device RGB/depth clock timestamps not exported by retained Vision frame"),cameraGeneration:frame.cameraGeneration,
            width:depth.width,height:depth.height,rgb888:rgb,depthU16LittleEndian:Data(depth.millimetersLittleEndian),
            infrared:.unavailable("IR not exported by retained frame"),infraredContractJSON:.unavailable("IR not exported by retained frame"),
            intrinsics:[k.fx,k.fy,k.cx,k.cy],sourceContractsJSON:try json(contracts),runtimeCalibrationJSON:try encoder.encode(runtime),
            imuJSON:try k.inertial.map{.available(try encoder.encode($0))} ?? .unavailable("No actual synchronized IMU packet in retained frame"),
            actualAppliedNeck:.available(.init(appliedPanTarget:scope.panTarget,appliedLowerTarget:scope.lowerTarget,appliedUpperTarget:scope.upperTarget,
                observedAtHostMilliseconds:Date().timeIntervalSince1970*1000,stationary:true,source:"native current applied neck feedback at archive copy; original frame scope separately frozen")),
            physicalLeftFeedback:.available(left),physicalRightFeedback:.available(right),cameraToRobotColumnMajor:(0..<4).flatMap{c in(0..<4).map{r in matrix[c][r]}},
            projectionMethod:sourcePixelSelfReviewEnabled ? "llm_visual_review_experimental_not_registration":"assumed_alignment_not_observed_self",projectionScopeJSON:try encoder.encode(scope),
            returnSamplingContractJSON:try json(["pixelCoordinates":"original normalized top-left RGB-D raster","depthUnits":"u16le_mm",
                "sourceMapFingerprint":map.fingerprint,"firstPixel":[1,1],"stride":max(2,Int(ceil(sqrt(Double(depth.width*depth.height)/12000)))),
                "observedSelf":false,"stage":stage]))
        return try await writer.append(input)
    }
    @MainActor private func collectNominalKeyframes(count:Int,stage:String,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        writer:ROBWorkspaceRawScanArchive,startUptime:Double?=nil,startHostMilliseconds:Double?=nil) async throws {
        let began=startUptime ?? ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            let target=began+(stage=="during" ? 0.2+Double(index)*0.5:Double(index)*0.15)
            let deadline=stage=="during" ? began+5:target+3
            while true {
                try check();try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw ROBArmRoutineError.blocked("Missing \(stage) commissioning keyframe; stopped held with incomplete learning archive.")}
                if ProcessInfo.processInfo.systemUptime>=target,let frame=vision.snapshot()["face"],frame.sequence>nominalArchiveLastSequence,
                   startHostMilliseconds.map({frame.capturedAt >= $0 && (stage != "during" || frame.capturedAt <= $0+4000)}) ?? true {
                    _ = try await archiveNominalKeyframe(frame,stage:stage,map:map,model:model,writer:writer)
                    nominalArchiveLastSequence=frame.sequence;nominalArchiveTimes.append((stage,frame.capturedAt));break
                }
                try await Task.sleep(nanoseconds:20_000_000)
            }
        }
    }

    @MainActor private func reviewCurrentSourcePixelStep(from q:[Double],map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        trial:ROBWorkspaceVisualCalibrationTrial,now:Double,measuredAt:Double,emptySource:String,
        view:ROBWorkspaceSourcePixelSelf.View) async throws->ROBWorkspaceNominalEmptyCommissioningRetreat {
        guard let bytes=sourcePixelCurrentSourceMapJSON,sourcePixelCurrentMapFingerprint==map.fingerprint else {
            throw ROBArmRoutineError.blocked("No current native pixel classification/source map for this exact scene.")
        }
        let fingerprint=map.fingerprint,scene=map.sceneID,camera=map.cameraGeneration,session=map.sessionGeneration,directory=model.directory
        return try await withCheckedThrowingContinuation{continuation in
            Self.sourcePixelQueue.async {
                do {
                    let source=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:bytes)
                    guard source.fingerprint==fingerprint,source.sceneID==scene,source.cameraGeneration==camera,source.sessionGeneration==session else {
                        throw ROBGhostMotionError.blocked("Source-pixel proof source differs from the native current scan.")
                    }
                    let workerModel=try ROBGhostRobotModel(directory:directory,physicalSide:"right")
                    let proof=try ROBWorkspaceCollisionPlan.reviewSourcePixelNominalEmptyCommissioningRetreat(from:q,map:source,model:workerModel,
                        generation:session,sceneID:scene,cameraGeneration:camera,nowMilliseconds:now,trial:trial,
                        measuredAtMilliseconds:measuredAt,nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:emptySource,
                        sourcePixelSelfView:view)
                    continuation.resume(returning:proof)
                }catch {continuation.resume(throwing:error)}
            }
        }
    }

    @MainActor private func executeNominalEmptyCommissioning() async throws ->NSDictionary {
        guard nominalEmptyCommissioningStepEnabled,physicalSide=="right",(1...ROBRecyclingBatchRequest.maximumCount).contains(requestedCanCount),
              ROBControllerArmApproval.shared.authorizesLocalRecyclingNominalEmptyCommissioningStep(summary:summary,arm:physicalSide,modelAssumedSelfEnabled:nominalModelAssumedSelfEnabled,sourcePixelSelfReviewSHA256:currentSourcePixelEvidenceSHA256),
              !armTravelDispatched,!jawCommandDispatched,!jawSetupDispatchUncertain,!recyclingGripDispatched else {
            throw ROBArmRoutineError.blocked("No exact separate nominal EMPTY commissioning permission is active.")
        }
        _ = try requireLocalReceipt()
        phase="nominal EMPTY preflight"
        try await wait(12){self.gateway.isReady()}
        try await accepted{gateway.queryMode(forArm:arm)}
        try await wait(3){(try?self.measured()) != nil}
        generation=(gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        guard generation>0 else {throw ROBArmRoutineError.blocked("No authenticated nominal experiment gateway generation.")}
        try await prepareRightRecyclingSceneHolds(allowDeferredJawSetup:false)
        try await beginHeldSceneObservation()
        let model=try workspaceModel(),map=try await captureRightArmCalibrationView(model:model)
        // Stationary mode preparation holds the existing measured position;
        // it never initializes jaws, zeros encoders or restores another view.
        inactiveWorkspaceSearch=false
        try await prepareCameraAndMode(stationaryJaw:false)
        var archive:ROBWorkspaceRawScanArchive?
        defer {if let writer=archive {Task {await writer.closeIncomplete(reason:"Commissioning phase ended before a complete14-keyframe archive; no learning success claimed.")}}}
        if usesFixedCommissioningKeyframes {
            nominalArchiveLastSequence=0;nominalArchiveTimes=[]
            let parent=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension(sourcePixelSelfReviewEnabled ? "source-pixel-self-keyframes":"model-assumed-self-keyframes")
            let writer=try await ROBWorkspaceRawScanArchive.create(parentDirectory:parent,scene:.init(archiveID:UUID(),workspaceSceneID:map.sceneID,
                bodyMotionIdentity:map.bodyMotionIdentity,gatewayGeneration:generation,modelID:model.modelID,referenceID:model.referenceID,
                geometryID:model.geometryID,mappingID:model.selectedMappingID))
            archive=writer
            try await collectNominalKeyframes(count:3,stage:"before",map:map,model:model,writer:writer)
        }
        let sample=try measured(),q=sample.positionsRadians.map(\.doubleValue),session=generation,camera=vision.cameraGeneration
        guard !jawCommandDispatched,!armTravelDispatched,let trial=try visualTrial(map:map,model:model,baseline:q) else {
            throw ROBArmRoutineError.blocked("Nominal experiment lost its fresh q0, no-jaw state or explicit trial scope.")
        }
        let now=Date().timeIntervalSince1970*1000,measuredAt=now-sample.effectiveSampleAgeMilliseconds
        let emptySource="local_first_attempt_no_arm_travel_or_task_grip",assumedSelf=nominalModelAssumedSelfEnabled
        let proof:ROBWorkspaceNominalEmptyCommissioningRetreat
        do {
            if sourcePixelSelfReviewEnabled {
                guard let view=sourcePixelCurrentView else {throw ROBArmRoutineError.blocked("No current native source-pixel view; historical template is not movement authority.")}
                proof=try await reviewCurrentSourcePixelStep(from:q,map:map,model:model,trial:trial,now:now,measuredAt:measuredAt,emptySource:emptySource,view:view)
            }else {proof=try await Task.detached(priority:.userInitiated){
            try ROBWorkspaceCollisionPlan.reviewNominalEmptyCommissioningRetreat(from:q,map:map,model:model,generation:session,
                sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:trial,measuredAtMilliseconds:measuredAt,
                nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:emptySource,modelAssumedSelfEnabled:assumedSelf)
        }.value}
        } catch {
            let original=error,recording=lastRecordingPath,detail=error.localizedDescription
            if !recording.isEmpty { _ = try?await Task.detached(priority:.utility){
                try ROBInitialRetreatFailureExport.write(recording:URL(fileURLWithPath:recording),map:map,model:model,
                    baseline:q,goal:zip(q,[0.0,-0.075,0,0,0,0,0]).map(+),trial:trial,stage:"nominal_empty_review",
                    reviewTimeMilliseconds:now,measuredAtMilliseconds:measuredAt,sequence:sample.sequence,detail:detail)
            }.value }
            throw original
        }
        let reviewedAt=ProcessInfo.processInfo.systemUptime
        let path=ROBLeftGestureProposal(id:proof.id,name:"ONE unverified nominal EMPTY commissioning step",kind:"nominal_empty_commissioning",
            modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:session,baseline:q,poses:[],steps:[proof.step])
        activeNominalRetreat=proof;proposal=path;collisionReviewProposal=path
        collisionReviewStatus=["status":"nominal_experiment_reviewed","registration_verified":false,"collision_protection_certified":false,
            "assumed_camera_uncertainty_m":proof.assumedCalibrationUncertaintyMeters,
            "minimum_swept_nominal_clearance_m":proof.minimumSweptNominalClearanceMeters,
            "unknown_local_regions":proof.unknownLocalRegions.count,"maximum_hull_travel_m":proof.maximumHullTravelMeters,
            "detail":"ONE nominal EMPTY experiment; modeled gaps are smaller than35mm camera uncertainty. No collision certificate, jaw command or automatic chaining."]
        let dispatch=ROBReviewedArmDispatchStart(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:q,sequence:sample.sequence,reviewCompletedAtUptime:reviewedAt)
        try check();try checkCollisionContext();try requireLiveVisualTrial(trial,map:map,model:model)
        let current=try measured(),admissionTime=Date().timeIntervalSince1970*1000
        if sourcePixelSelfReviewEnabled {
            guard let view=sourcePixelCurrentView else {throw ROBArmRoutineError.blocked("Native current pixel classification was lost before dispatch.")}
            try proof.validateSourcePixelContext(map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
                nowMilliseconds:admissionTime,trial:trial,measuredAtMilliseconds:admissionTime-current.effectiveSampleAgeMilliseconds,
                measuredBaseline:current.positionsRadians.map(\.doubleValue),nominalEmptyCommissioningEnabled:true,
                emptyStateEvidenceSource:emptySource,sourcePixelSelfView:view)
        }else {
        try proof.validateContext(map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
            nowMilliseconds:admissionTime,trial:trial,measuredAtMilliseconds:admissionTime-current.effectiveSampleAgeMilliseconds,
            measuredBaseline:current.positionsRadians.map(\.doubleValue),nominalEmptyCommissioningEnabled:true,emptyStateEvidenceSource:emptySource,modelAssumedSelfEnabled:assumedSelf)
        }
        guard dispatch.matches(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:current.positionsRadians.map(\.doubleValue),sequence:current.sequence,nowUptime:ProcessInfo.processInfo.systemUptime) else {
            throw ROBArmRoutineError.blocked("The fresh nominal commissioning start changed after proof review; no step sent.")
        }
        proposalStep=0;phase="ONE nominal EMPTY commissioning step";sentPath=[q,proof.goal]
        update("One four-second nominal EMPTY step; watching the RIGHT arm, then holding. Collision uncertainty remains unverified.")
        reviewedDispatchStart=dispatch;armTravelDispatched=true
        let dispatchedUptime=ProcessInfo.processInfo.systemUptime,dispatchedHost=Date().timeIntervalSince1970*1000
        let duringTask:Task<Void,Error>?=archive.map{writer in Task { @MainActor in
            do {try await self.collectNominalKeyframes(count:8,stage:"during",map:map,model:model,writer:writer,
                startUptime:dispatchedUptime,startHostMilliseconds:dispatchedHost)}
            catch {self.abort("Commissioning pixel/q recording failed; immediate hold: "+error.localizedDescription)
                await writer.closeIncomplete(reason:error.localizedDescription);throw error}
        }}
        defer {duringTask?.cancel()}
        if usesFixedCommissioningKeyframes {ROBWorkspaceSearch.shared.announce?("Moving my right arm a little.")}
        try await accepted{gateway.sendApprovedLeftGestureStep(proposalID:path.id,index:0,duration:4,expectedSessionGeneration:session)}
        reviewedDispatchStart=nil;leased=true;lastRenewal=ProcessInfo.processInfo.systemUptime
        let began=ProcessInfo.processInfo.systemUptime;var settler=ROBArmRoutineSettler()
        try await wait(7){
            guard let feedback=try?self.measured() else{return false}
            return settler.observe(sequence:feedback.sequence,positions:feedback.positionsRadians.map(\.doubleValue),target:proof.goal,
                now:ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime-began>=4
        }
        try await holdTaskPosition(proof.goal);taskJawTarget=nil
        try await duringTask?.value
        if let archive {
            try await collectNominalKeyframes(count:3,stage:"after",map:map,model:model,writer:archive,
                startHostMilliseconds:Date().timeIntervalSince1970*1000)
            _ = try await archive.finish()
        }
        let endpoint=try measured().positionsRadians.map(\.doubleValue)
        guard 1.5*zip(endpoint,proof.goal).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {throw ROBArmRoutineError.blocked("The nominal endpoint is held but did not reach its reviewed goal; no further step admitted.")}
        if usesFixedCommissioningKeyframes {ROBWorkspaceSearch.shared.announce?("Arm movement complete. Holding here.")}
        let recording=lastRecordingPath,keyframeTimes=nominalArchiveTimes,archivePath=archive?.directory.path
        try await Task.detached(priority:.utility){
            let directory=URL(fileURLWithPath:recording).deletingPathExtension().appendingPathExtension("nominal-empty-evidence")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            if let archivePath {
                let times=keyframeTimes.map(\.time),gaps=zip(times.dropFirst(),times).map{$0-$1}
                let data=try JSONSerialization.data(withJSONObject:["kind":"fourteen_explicit_commissioning_keyframes_not_30fps",
                    "archivePath":archivePath,"learningCaptureComplete":keyframeTimes.count==14,"observedSelf":false,
                    "frames":keyframeTimes.map{["stage":$0.stage,"capturedAtHostMilliseconds":$0.time]},
                    "maximumInterframeGapMilliseconds":gaps.max() ?? 0,"achievedFramesPerSecond":times.count>1 ? Double(times.count-1)*1000/(times.last!-times.first!):0],options:.sortedKeys)
                let file=directory.appendingPathComponent("keyframe-cadence.json");try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
            for (name,data) in [("proof.json",try encoder.encode(proof)),("collision-map.json",try encoder.encode(map))] {
                let file=directory.appendingPathComponent(name);try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
        }.value
        var result:[String:Any] = ["status":"partial_empty_step_held","measured":false,"joint_motion_measured":true,"motion_completed":false,
            "transfer_completed":false,"nominal_empty_commissioning_step":true,"collision_protection_certified":false,
            "baseline_positions":q,"goal_positions":proof.goal,"measured_positions":endpoint,"endpoint_stopped_and_held":true,
            "assumed_camera_uncertainty_m":0.035,"minimum_swept_nominal_clearance_m":proof.minimumSweptNominalClearanceMeters,
            "unknown_local_regions":proof.unknownLocalRegions.count,"jaw_command_sent":false,
            "detail":"ONE four-second nominal EMPTY commissioning step reached its measured endpoint and is held. Camera uncertainty remains unverified; no jaw, grasp, carry, release, return or chained can attempt. ZERO transfers completed."]
        if assumedSelf {
            result["model_assumed_self_enabled"]=true;result["self_identity_label"]="assumed_alignment_not_observed_self"
            result["observed_self"]=false;result["learning_keyframes_complete"]=nominalArchiveTimes.count==14
            result["keyframe_archive_path"]=archivePath as Any? ?? NSNull()
            result["assumed_source_groups"]=proof.modelAssumedSelfAudit?.groups.count ?? 0
            result["detail"]="ONE MODEL-ASSUMED J2-only EMPTY step is measured held.14 explicit timestamped pixel/BOTH-q keyframes retained, NOT30fps or observed-self recognition. Raw map/unknown unchanged; no jaws, carry, release, return, retry or chaining. ZERO transfers."
        }
        if sourcePixelSelfReviewEnabled {
            result["source_pixel_self_review"]=true;result["source_basis"]="llm_visual_review_experimental_current_rgb_depth_match"
            result["source_pixel_evidence_sha256"]=currentSourcePixelEvidenceSHA256 as Any? ?? NSNull()
            result["observed_self"]=false;result["learning_keyframes_complete"]=nominalArchiveTimes.count==14
            result["keyframe_archive_path"]=archivePath as Any? ?? NSNull()
            result["detail"]="ONE experimental source-pixel J2-only EMPTY step is measured held;14 timed actual pixel/BOTHq keyframes retained. LLM-reviewed masks were freshly matched, not registration or measured self recognition. Table/unmasked/uncertain/mixed returns retained. No jaw,carry,release,return,retry or chaining; ZERO transfers."
        }
        return result as NSDictionary
    }

    @MainActor private func executeOneDegreeEmptyCalibration() async throws ->NSDictionary {
        guard oneDegreeEmptyCalibrationStepEnabled,physicalSide=="right",(1...ROBRecyclingBatchRequest.maximumCount).contains(requestedCanCount),
              ROBControllerArmApproval.shared.authorizesLocalRecyclingOneDegreeEmptyCalibrationStep(summary:summary,arm:physicalSide),
              !armTravelDispatched,!jawCommandDispatched,!jawSetupDispatchUncertain,!recyclingGripDispatched else {
            throw ROBArmRoutineError.blocked("No exact separate one-degree EMPTY commissioning permission is active.")
        }
        _ = try requireLocalReceipt()
        phase="one-degree EMPTY preflight"
        try await wait(12){self.gateway.isReady()}
        try await accepted{gateway.queryMode(forArm:arm)}
        try await wait(3){(try?self.measured()) != nil}
        generation=(gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        guard generation>0 else {throw ROBArmRoutineError.blocked("No authenticated one-degree experiment gateway generation.")}
        try await prepareRightRecyclingSceneHolds(allowDeferredJawSetup:false)
        try await beginHeldSceneObservation()
        let model=try workspaceModel(),map=try await captureRightArmCalibrationView(model:model)
        // Stationary mode preparation holds the existing measured position;
        // it never initializes jaws, zeros encoders or restores another view.
        inactiveWorkspaceSearch=false
        try await prepareCameraAndMode(stationaryJaw:false)
        let sample=try measured(),q=sample.positionsRadians.map(\.doubleValue),session=generation,camera=vision.cameraGeneration
        guard !jawCommandDispatched,!armTravelDispatched,let trial=try visualTrial(map:map,model:model,baseline:q) else {
            throw ROBArmRoutineError.blocked("One-degree experiment lost its fresh q0, no-jaw state or explicit trial scope.")
        }
        let now=Date().timeIntervalSince1970*1000,measuredAt=now-sample.effectiveSampleAgeMilliseconds
        let emptySource="local_first_attempt_no_arm_travel_or_task_grip"
        let proof:ROBWorkspaceOneDegreeEmptyCalibrationStep
        do {proof=try await Task.detached(priority:.userInitiated){
            try ROBWorkspaceCollisionPlan.reviewOneDegreeEmptyCalibrationStep(from:q,map:map,model:model,generation:session,
                sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:trial,measuredAtMilliseconds:measuredAt,
                oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:emptySource)
        }.value} catch {
            let original=error,recording=lastRecordingPath,detail=error.localizedDescription
            if !recording.isEmpty { _ = try?await Task.detached(priority:.utility){
                try ROBInitialRetreatFailureExport.write(recording:URL(fileURLWithPath:recording),map:map,model:model,
                    baseline:q,goal:zip(q,[0.0,-0.02,0,0,0,0,0]).map(+),trial:trial,stage:"one_degree_empty_calibration_review",
                    reviewTimeMilliseconds:now,measuredAtMilliseconds:measuredAt,sequence:sample.sequence,detail:detail)
            }.value }
            throw original
        }
        let path=ROBLeftGestureProposal(id:proof.id,name:"ONE unverified one-degree EMPTY commissioning step",kind:"one_degree_empty_calibration",
            modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:session,baseline:q,poses:[],steps:[proof.step])
        activeOneDegreeCalibration=proof;proposal=path;collisionReviewProposal=path
        collisionReviewStatus=["status":"actuator_calibration_reviewed","registration_verified":false,"collision_protection_certified":false,
            "assumed_camera_uncertainty_m":0.035,
            "contact_predictions_are_diagnostics_only":true,
            "maximum_hull_travel_m":proof.maximumHullTravelMeters,
            "detail":"ONE one-degree EMPTY actuator/geometry experiment. Raw contacts/unknown space are diagnostics only under the explicit receipt;35mm camera uncertainty remains unverified. No collision certificate, jaw command or chaining."]
        let recording=lastRecordingPath
        try await Task.detached(priority:.utility){
            let directory=URL(fileURLWithPath:recording).deletingPathExtension().appendingPathExtension("one-degree-empty-evidence")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            for (name,data) in [("proof.json",try encoder.encode(proof)),("collision-map.json",try encoder.encode(map))] {
                let file=directory.appendingPathComponent(name);try data.write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            }
        }.value
        try check();try checkCollisionContext();try requireLiveVisualTrial(trial,map:map,model:model)
        let current=try measured(),admissionTime=Date().timeIntervalSince1970*1000
        try proof.validateContext(map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
            nowMilliseconds:admissionTime,trial:trial,measuredAtMilliseconds:admissionTime-current.effectiveSampleAgeMilliseconds,
            measuredBaseline:current.positionsRadians.map(\.doubleValue),oneDegreeEmptyCalibrationStepEnabled:true,emptyStateEvidenceSource:emptySource)
        let dispatch=ROBReviewedArmDispatchStart(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:current.positionsRadians.map(\.doubleValue),sequence:current.sequence,reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
        guard dispatch.matches(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:current.positionsRadians.map(\.doubleValue),sequence:current.sequence,nowUptime:ProcessInfo.processInfo.systemUptime) else {
            throw ROBArmRoutineError.blocked("The fresh one-degree calibration start changed after proof review; no step sent.")
        }
        proposalStep=0;phase="ONE one-degree EMPTY commissioning step";sentPath=[q,proof.goal]
        update("One four-second one-degree EMPTY step; watching the RIGHT arm, then holding. Collision uncertainty remains unverified.")
        reviewedDispatchStart=dispatch;armTravelDispatched=true
        try await accepted{gateway.sendApprovedLeftGestureStep(proposalID:path.id,index:0,duration:4,expectedSessionGeneration:session)}
        reviewedDispatchStart=nil;leased=true;lastRenewal=ProcessInfo.processInfo.systemUptime
        let began=ProcessInfo.processInfo.systemUptime;var settler=ROBArmRoutineSettler()
        try await wait(7){
            guard let feedback=try?self.measured() else{return false}
            let positions=feedback.positionsRadians.map(\.doubleValue)
            // A4s command is not proof that the motor has arrived. The
            // generic25mrad settler can accept this entire20mrad move;
            // priorityHold would then replace the goal with an early pose.
            // Require the SAME final3mm aggregate endpoint bound throughout
            // distinct stable samples before requesting a measured-pose hold.
            guard 1.5*zip(positions,proof.goal).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
                settler=ROBArmRoutineSettler();return false
            }
            return settler.observe(sequence:feedback.sequence,positions:positions,target:proof.goal,
                now:ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime-began>=4
        }
        try await holdTaskPosition(proof.goal);taskJawTarget=nil
        let endpoint=try measured().positionsRadians.map(\.doubleValue)
        guard 1.5*zip(endpoint,proof.goal).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {throw ROBArmRoutineError.blocked("The calibration endpoint is held but did not reach its reviewed goal; no further step admitted.")}
        return ["status":"partial_empty_calibration_step_held","measured":false,"joint_motion_measured":true,"motion_completed":false,
            "transfer_completed":false,"one_degree_empty_calibration_step":true,"collision_protection_certified":false,
            "baseline_positions":q,"goal_positions":proof.goal,"measured_positions":endpoint,"endpoint_stopped_and_held":true,
            "assumed_camera_uncertainty_m":0.035,"contact_predictions_are_diagnostics_only":true,
            "jaw_command_sent":false,"evidence_directory":URL(fileURLWithPath:recording).deletingPathExtension().appendingPathExtension("one-degree-empty-evidence").path,
            "detail":"ONE four-second one-degree EMPTY actuator calibration step reached its measured endpoint and is held. Camera uncertainty remains unverified; no jaw, grasp, carry, release, return or chained can attempt. ZERO transfers completed."]
    }

    @MainActor private func executeSingle(_ command: String) async throws -> NSDictionary {
        if command == "left_scan_clearance" || command == "left_estimated_preview" {
            let model = try workspaceModel()
            let current = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
            guard current > 0, gateway.isReady() else { throw ROBArmRoutineError.blocked("Connect Amber before scanning arm-clearance geometry.") }
            generation = current
            let passiveRightProbe = physicalSide == "right" && command == "left_estimated_preview"
            try await beginHeldSceneObservation(allowActiveForPassiveCapture:passiveRightProbe)
            let map:ROBWorkspaceCollisionSnapshot
            if passiveRightProbe {
                map = try await ROBWorkspaceSearch.shared.captureEstimatedOrRegisteredCurrentScene(model:model,generation:current,
                    check:{try self.check()},progress:{self.update($0)})
            } else {
                map = try await ROBWorkspaceSearch.shared.scanCollisionScene(model:model,generation:current,
                    check:{ try self.check() },progress:{ self.update($0) })
            }
            collisionMap = map; collisionReviewProposal = nil
            collisionModel = model; sceneCapturedForThisTask = true
            publishCollisionReview(map:map,detail:map.registrationDetail)
            if command == "left_estimated_preview" {
                let baseline = try measured().positionsRadians.map(\.doubleValue)
                let camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
                let proof:ROBEstimatedArmCalibrationPlan
                do {
                    proof = try await Task.detached(priority:.userInitiated) {
                        try ROBEstimatedArmCalibrationPlan.make(from:baseline,map:map,model:model,generation:current,
                            cameraGeneration:camera,nowMilliseconds:now)
                    }.value
                } catch let rejection as ROBEstimatedArmCollisionRejection {
                    let rejectionOwner=owner
                    let exportResult:Result<URL,Error>
                    do {
                        guard !lastRecordingPath.isEmpty else {throw ROBArmRoutineError.blocked("No collision recording destination is available.")}
                        let directory=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("collision-evidence")
                        let path=try await Task.detached(priority:.utility) {try rejection.export(map:map,to:directory)}.value
                        exportResult = .success(path)
                    } catch {exportResult = .failure(error)}
                    let mayPublish:Bool
                    do {
                        try check()
                        mayPublish=owner==rejectionOwner && activeCommand=="left_estimated_preview" && generation==current &&
                            vision.cameraGeneration==map.cameraGeneration && map.bodyMotionIdentity==ROBFixedHeadBodyMotionIdentity.currentIdentity &&
                            ROBWorkspaceSearch.shared.estimatedCameraProjectionIsCurrent(model:model,map:map)
                    }catch{mayPublish=false}
                    if mayPublish {
                        switch exportResult {
                        case .success(let path):
                            publishCollisionReview(map:map,detail:rejection.localizedDescription+"\nCollision evidence: "+path.path,blocked:true)
                            var status=collisionReviewStatus as? [String:Any] ?? [:]
                            status["rejection_evidence_path"]=path.path;collisionReviewStatus=status as NSDictionary
                        case .failure(let error):
                            publishCollisionReview(map:map,detail:rejection.localizedDescription+"\nSaving collision evidence failed: "+error.localizedDescription,blocked:true)
                        }
                    }
                    throw rejection
                }
                try check()
                guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue),baseline:baseline),
                      let held = sceneHold[arm == "right" ? "left" : "right"] else {
                    throw ROBArmRoutineError.blocked("The arms changed during estimated calibration review; capture again.")
                }
                let path = ROBLeftGestureProposal(id:proof.id,name:"Estimated EMPTY-arm retreat away from the table",
                    kind:"estimated_calibration",modelID:proof.modelID,referenceID:proof.referenceID,
                    geometryID:proof.geometryID,mappingID:proof.mappingID,sessionGeneration:proof.sessionGeneration,
                    baseline:proof.baseline,poses:[],steps:proof.steps)
                let pending = EstimatedPreview(proof:proof,map:map,model:model,proposal:path,otherArmHold:held,
                    geometryValidationFingerprint:try estimatedGeometryFingerprint(proof:proof,map:map,model:model,proposal:path),
                    resourceFingerprint:try estimatedResourceFingerprint(model:model))
                try validateEstimatedContext(pending,generation:current)
                pendingEstimated = pending; collisionReviewProposal = path
                try writeEstimatedRecording(proof:proof,proposal:path)
                publishCollisionReview(map:map,detail:"Estimated single-step preview ready. Registration UNVERIFIED; visually confirm empty jaws and local clearance before one separate approval.")
                return ["status":"accepted_unverified","arm_motion_sent":false,"measured":false,
                    "estimated_calibration_preview":true,"estimated_proof_id":proof.id.uuidString,
                    "map_fingerprint":map.fingerprint,"unknown_voxels":proof.unknownVoxelCount,
                    "modeled_max_vertex_travel_m":proof.maximumVertexDisplacementMeters,
                    "detail":"One estimated EMPTY-arm retreat away from the table over 4 seconds is ready. No motion sent. Confirm local clearance and approve separately; review expires with the fresh map."]
            }
            var result:[String:Any] = ["status":"accepted_unverified","arm_motion_sent":false,"measured":false,
                    "detail":map.registrationDetail,"workspace_search":ROBWorkspaceSearch.shared.lastReport]
            if !lastRecordingPath.isEmpty {
                let path=try await ROBPassiveWorkspaceMapExport.write(map:map,recording:URL(fileURLWithPath:lastRecordingPath))
                try check()
                var status=collisionReviewStatus as? [String:Any] ?? [:]
                status["workspace_map_path"]=path.path;collisionReviewStatus=status as NSDictionary
                result["workspace_map_path"]=path.path
            }
            return result as NSDictionary
        }
        if command == "left_search_workspace" || command == "left_check_hanging" {
            let model = try workspaceModel()
            _ = try await ROBWorkspaceSearch.shared.run(targets: command == "left_check_hanging" ? [] : workspaceSearchTargets,
                model: model, requireDepth: false, check: { try self.check() }, progress: { self.update($0) })
            return ["status": "accepted_unverified", "measured": false, "arm_motion_sent": false,
                "detail": ROBWorkspaceSearch.shared.lastReport["detail"] ?? "Local workspace search ended.",
                "workspace_search": ROBWorkspaceSearch.shared.lastReport]
        }
        try await wait(12) { self.gateway.isReady() }
        let connectedGeneration = (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value ?? 0
        guard connectedGeneration > 0 else { throw ROBArmRoutineError.blocked("No authenticated gateway session.") }
        try await accepted { gateway.queryMode(forArm: arm) }
        try await wait(3) { (try? self.measured()) != nil }
        guard gateway.isReady(), (gateway.connectionSnapshot()["sessionGeneration"] as? NSNumber)?.uint64Value == connectedGeneration else {
            throw ROBArmRoutineError.blocked("Gateway session changed during left-arm preflight.")
        }
        generation = connectedGeneration
        var q = try measured().positionsRadians.map(\.doubleValue)
        if command == "left_estimated_calibration" { return try await executeEstimatedCalibration() }
        var entryRecovery: ROBLeftGestureProposal?
        if command == "left_relax", ROBArmRoutinePlan.near(q, Array(repeating: 0, count: 7)),
           gateway.modes(forArm: arm).count == 7, gateway.modes(forArm: arm).allSatisfy({ $0.intValue == 0 }),
           try measured().statuses.count == 7, try measured().statuses.allSatisfy({ $0.intValue == 0 }) {
            return ["status": "completed", "measured": true, "detail": "Left arm is already hanging and inactive."]
        }
        if allowsArmTravel, command != "left_recycle_can",
           !(command == "left_prepare" && ROBLeftArmInteractionPlan.stationaryFrontTarget(q) != nil) {
            do { try await ensureCollisionScene(model:workspaceModel()) }
            catch {
                return ["status":"not_localized","arm_motion_sent":false,"reach_sent":false,
                        "detail":error.localizedDescription,"collision_review":collisionReviewStatus]
            }
        }
        if command == "left_prepare", ROBLeftArmInteractionPlan.executionRoute(from:q,hanging:false) == nil {
            guard referencedGeneration == generation else {
                throw ROBArmRoutineError.blocked("The held arm needs a verified joint reference before a new dynamic return can be planned.")
            }
            entryRecovery = try await workspaceConnector(to:ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!,
                name:"Collision-checked empty return to front")
            proposal = entryRecovery
        }
        if command == "left_recycle_can" {
            let recyclingParameters = try ROBRecyclingTestParameters.load(file: recyclingTestParametersFile)
            // Search while holding the measured pose. Parking is itself a
            // motion and may collide with a newly positioned table.
            if physicalSide == "right" { try await prepareRightRecyclingSceneHolds() }
            q = try measured().positionsRadians.map(\.doubleValue)
            let searchBaseline = q
            try await beginHeldSceneObservation(); phase = "stationary neck-only scene search"
            update("Holding the arms still while searching and mapping the current workspace")
            let model = try workspaceModel()
            let calibrationFile = selectedCanReachCalibrationFile
            var objects = try await ROBWorkspaceSearch.shared.run(targets: (activeHoldAfterInitialEmptyLift || activeApproachCanThenHold) ? [.can]:ROBWorkspaceTarget.allCases,
                model: model, requireDepth: true,permitsLocalCanShapePrior:{
                    guard self.localReceiptCommand != nil else {return false}
                    _ = try self.requireLocalReceipt()
                    return true
                },canReachBaseline:localReceiptCommand != nil ? model.positions(vendorLeft:searchBaseline):nil,
                passiveFeedbackCheckpoint:{try await self.passiveFeedbackCheckpoint()},
                check: { try self.check() }, progress: { self.update($0) })
            sceneCapturedForThisTask = true
            if let map = ROBWorkspaceSearch.shared.collisionSnapshot {
                collisionMap = map; collisionModel = model
                publishCollisionReview(map:map,detail:map.registrationDetail,blocked:map.registrationID == nil && localReceiptCommand == nil)
                if localReceiptCommand != nil {
                    let selected=await ROBWorkspaceSearch.shared.nearestReachableCan(model:model,baseline:model.positions(vendorLeft:q),
                        map:map,calibrationFile:calibrationFile)
                    objects[.can]=selected.object
                    var report=collisionReviewStatus as? [String:Any] ?? [:]
                    report["nearest_reachable_candidates"]=selected.diagnostics;report["path_admitted"]=false
                    collisionReviewStatus=report as NSDictionary
                }
            }
            try check()
            try await wait(3) { (try? self.measured()) != nil }
            try await accepted { gateway.queryMode(forArm:arm) }
            q = try measured().positionsRadians.map(\.doubleValue)
            guard ROBArmRoutinePlan.near(q,searchBaseline,tolerance:0.015) else {
                throw ROBArmRoutineError.blocked("The arm changed pose during the stationary search.")
            }
            // Ask for a reachable can even when bucket release geometry is
            // still unavailable. This is a model check, never a motion path.
            if let can = objects[.can] {
                let baseline = model.positions(vendorLeft: q)
                let projectionIdentity=collisionMap?.estimatedCameraProjectionIdentity ?? ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)
                let reach = try await Task.detached(priority: .userInitiated) {
                    try ROBCanGrabPreview.make(can: can, model: model, baseline: baseline, side: model.physicalSide,
                        reachOffset:ROBLeftCanReachCalibration.load(model:model,can:can,file:calibrationFile,
                            estimatedCameraProjectionIdentity:projectionIdentity))
                }.value
                try check()
                if let message = reach.helpRequest {
                    ROBWorkspaceSearch.shared.announce?(message)
                    return ["status": "needs_help", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                        "detail": message + " I'll check its new position before reaching.",
                        "workspace_search": ROBWorkspaceSearch.shared.lastReport]
                }
            }
            guard let can = objects[.can],objects[.orangeBucket] != nil || localReceiptCommand != nil else {
                let report = ROBWorkspaceSearch.shared.lastReport
                let visible = report["visually_confirmed"] as? [String] ?? []
                let detail = objects[.orangeBucket] == nil && visible.contains("orangeBucket")
                    ? "I see the bucket, but I can't measure its opening yet."
                    : report["detail"] as? String ?? "Can or orange bucket was not confirmed."
                if visible.contains("orangeBucket") { ROBWorkspaceSearch.shared.announce?(detail) }
                return ["status": ["depth_unconfirmed", "vision_unavailable", "visually_found"].contains(report["status"] as? String ?? "") ? "not_localized" : "not_found", "measured": false, "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false,
                    "detail": detail,
                    "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            }
            let bucket=objects[.orangeBucket]
            let observedObjects=[can]+(bucket.map{[$0]} ?? [])
            recyclingCan=can;recyclingDestination=bucket
            guard observedObjects.allSatisfy({ Date().timeIntervalSince1970 * 1000 - $0.capturedAt < 60_000 }) else {
                throw ROBGhostMotionError.blocked("Object observations expired during search; no reach was sent.")
            }
            guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), q, tolerance: 0.015) else {
                throw ROBGhostMotionError.blocked("Arm start position changed during the scan; no reach was sent.")
            }
            do {
                try await ensureCollisionScene(model:model)
                guard collisionMap != nil, let owner else {
                    throw ROBArmRoutineError.blocked("The workspace map or arm ownership changed before planning.")
                }
                if !activeHoldAfterInitialEmptyLift,!ROBGripperStartupCalibration.shared.calibrationReady(forArm:arm) {
                    _ = try await parkEmptyArmForSearch(q)
                    try await beginHeldSceneObservation()
                    if localReceiptCommand != nil {jawSetupDispatchUncertain=true}
                    try await ROBGripperStartupCalibration.shared.ensureReady(whileParkedBy:owner)
                    jawSetupDispatchUncertain=false // sequence dispatch finished; physical opening remains unmeasured
                    try check()
                    q = try measured().positionsRadians.map(\.doubleValue)
                    try await ensureCollisionScene(model:model)
                }
                guard let map = collisionMap, let sections = can.sections, sections.valid else {
                    throw ROBArmRoutineError.blocked("Measure the complete can and current environment before planning a payload sweep.")
                }
                try await prepareLocalCanObservationView(can,map:map)
                if try await performInitialLocalRetreatIfNeeded(map:map,model:model) {
                    if activeHoldAfterInitialEmptyLift {return try initialEmptyLiftHoldResult(performed:true)}
                    // One declared-empty corrective step, then fresh targets
                    // and raw geometry. Never chain blind grasp retries.
                    return try await executeSingle(command)
                }
                if activeHoldAfterInitialEmptyLift {return try initialEmptyLiftHoldResult(performed:false)}
                guard referencedGeneration == generation || ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)) else {
                    throw ROBArmRoutineError.blocked("The arm joint reference must be verified before a dynamic approach from this held pose.")
                }
                let planningStart = q, session = generation, camera = vision.cameraGeneration
                let baseline = model.positions(vendorLeft:planningStart), now = Date().timeIntervalSince1970*1000
                let visual=try visualTrial(map:map,model:model,baseline:planningStart)
                guard !activeApproachCanThenHold || visual != nil else {throw ROBArmRoutineError.blocked("Open-jaw approach requires the native observed-jaw servo path; no alternate grasp route is permitted.")}
                var destinationAdmissionFailure:String?
                if let bucketPrior=bucket?.bucketShapePrior {
                    let contained=visual.map { trial in
                        map.registrationID==nil && bucket?.registrationID==nil && bucketPrior.valid &&
                            bucket?.openingRadius.map{$0.isFinite && $0>=0.033+trial.assumedSpatialErrorMeters && abs($0-bucketPrior.commonOpeningRadiusMeters)<=0.000001}==true &&
                            bucketPrior.commonOpeningRadiusMeters>=0.033+trial.assumedSpatialErrorMeters
                    } ?? false
                    if !contained {
                        guard visual != nil else {throw ROBArmRoutineError.blocked("An assumed bucket opening needs its explicit local visual-trial containment proof.")}
                        destinationAdmissionFailure="The assumed opening does not contain the can plus the trial allowance."
                    }
                }
                if bucket==nil {
                    guard visual != nil else {throw ROBArmRoutineError.blocked("A complete transfer needs a freshly confirmed bucket opening.")}
                    destinationAdmissionFailure="The bucket opening is not admitted."
                }
                let destinationFailure=destinationAdmissionFailure
                phase="complete recycling collision planning"
                let compiled = try await Task.detached(priority:.userInitiated) {
                    func candidate(_ rearward:Double,forceGraspHold:Bool=false) throws -> ROBLeftGestureProposal {
                    func preview(_ destination:ROBWorkspaceLocatedObject?) throws -> ROBCanGrabPreview {
                        try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,side:model.physicalSide,bucket:destination,
                        reachOffset:ROBLeftCanReachCalibration.load(model:model,can:can,file:calibrationFile,
                            estimatedCameraProjectionIdentity:map.estimatedCameraProjectionIdentity),
                        bucketYawDegrees:ROBLeftCanReachCalibration.loadBucketYaw(model:model,file:calibrationFile,registrationID:can.registrationID,
                            estimatedCameraProjectionIdentity:map.estimatedCameraProjectionIdentity),
                        bucketInwardMeters:ROBLeftCanReachCalibration.loadBucketInward(model:model,file:calibrationFile,registrationID:can.registrationID,
                            estimatedCameraProjectionIdentity:map.estimatedCameraProjectionIdentity),rearwardJoint1Radians:rearward)
                    }
                    let plan:ROBCanGrabPreview
                    var graspHold=visual != nil || forceGraspHold || destinationFailure != nil
                    var holdReason=destinationFailure ?? "The complete transfer route was not admitted."
                    if graspHold {guard visual != nil else {throw ROBArmRoutineError.blocked("A partial grasp-and-hold needs the exact active local visual trial.")};plan=try preview(nil)}
                    else {do {plan=try preview(bucket)}catch {
                        guard visual != nil else {throw error}
                        graspHold=true;holdReason=error.localizedDescription;plan=try preview(nil)
                    }}
                    let kind=graspHold ? "recycling_grasp_hold":"recycling"
                    let operationName=graspHold ? "Grasp and hold: "+String(holdReason.prefix(80)):"Recycle with complete arm clearance"
                    let entry:ROBWorkspaceCollisionPlan
                    if let visual {
                        var previous=planningStart,segments:[ROBLeftGestureProposal.Step]=[]
                        guard !plan.dynamicEntryWaypoints.isEmpty else {throw ROBGhostMotionError.blocked("The can-derived visual-trial entry is incomplete.")}
                        for pose in plan.dynamicEntryWaypoints {
                            let goal=model.vendorLeft(pose)
                            let connector=try ROBWorkspaceCollisionPlan.makeVisualCalibrationTrial(from:previous,to:goal,map:map,model:model,
                                generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,
                                trial:Self.rebasedVisualTrial(visual,baseline:previous))
                            segments += connector.steps.map{.init(positions:$0.positions,seconds:$0.seconds,stage:"Can-derived visual calibration trial entry")}
                            previous=goal
                        }
                        entry=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:planningStart,steps:segments,map:map,model:model,
                            generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:visual)
                    } else {
                        entry=try plan.plannedDynamicEntry(map:map,model:model,generation:session,
                            sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now)
                    }
                    let body=Array(plan.recyclingBodySteps)
                    if let visual {
                        // Future image corrections/grip/lift are NOT admitted
                        // by this entry proof. The same task receipt permits
                        // planning each from fresh measured/observed state.
                        return ROBLeftGestureProposal(id:UUID(),name:"One can: checked empty entry, then observed-jaw visual servo and hold",
                            kind:"incremental_visual_servo_grasp_hold",modelID:model.modelID,referenceID:model.referenceID,
                            geometryID:model.geometryID,mappingID:model.selectedMappingID,sessionGeneration:session,
                            baseline:planningStart,poses:body.map(\.pose),steps:entry.steps,
                            recyclingActions:Dictionary(uniqueKeysWithValues:body.enumerated().compactMap{i,s in s.jawAction.map{(i,$0)}}),
                            recyclingParameters:recyclingParameters,workspaceCollisionPlan:entry)
                    }
                    let actions = Dictionary(uniqueKeysWithValues:body.enumerated().compactMap { index,step in
                        step.jawAction.map { (index,$0) }
                    })
                    let raw = try ROBLeftGestureCompiler.compile(kind:kind,name:operationName,
                        poses:body.map(\.pose),model:model,baseline:planningStart,generation:session,recyclingActions:actions,
                        recyclingParameters:recyclingParameters,workspaceApproachPlan:entry,collisionMap:map,
                        collisionSceneID:map.sceneID,collisionCameraGeneration:camera,visualCalibrationTrial:visual,nowMilliseconds:now)
                    guard sections.surfaceToAxisOffsetMeters != nil || (visual != nil && sections.shapePriorEvidence?.valid==true),
                          let grip=raw.steps.firstIndex(where:{$0.jawAction == .grip}),
                          let prepared=raw.steps.firstIndex(where:{$0.jawAction == .prepare}),
                          let tool=model.frames(model.positions(vendorLeft:raw.steps[grip].positions))[model.toolLink] else {
                        throw ROBArmRoutineError.blocked("A fresh can cylinder with measured or explicitly authorized assumed geometry and frozen jaw stages is required for intentional grasp contact.")
                    }
                    let inverseTool=simd_inverse(tool)
                    func local(_ values:[Double])->SIMD3<Double> {
                        let p=inverseTool*SIMD4(values[0],values[1],values[2],1)
                        return SIMD3(p.x,p.y,p.z)
                    }
                    let top=local(sections.top),bottom=local(sections.bottom),axis=simd_normalize(top-bottom)
                    let radius=sections.diameterMeters/2
                    let radial=SIMD3((0..<3).map { radius*sqrt(max(0,1-axis[$0]*axis[$0])) })
                    let low=simd_min(top,bottom)-radial,high=simd_max(top,bottom)+radial
                    let center=(low+high)/2,half=(high-low)/2+SIMD3<Double>(repeating:0.003)
                    let measurementID=(sections.shapePriorEvidence==nil ? "can-depth-bands-frame-":"assumed-can-shape-prior-frame-")+String(can.sequence)
                    let payload=ROBWorkspaceCarriedObject(measurementID:measurementID,
                        centerInToolMeters:[center.x,center.y,center.z],halfExtentsMeters:[half.x,half.y,half.z])
                    let contact=ROBWorkspaceIntentionalContact(measurementID:measurementID,observationSequence:can.sequence,
                        capturedAtMilliseconds:can.capturedAt,sceneID:map.sceneID,cameraGeneration:camera,
                        mapFingerprint:map.fingerprint,modelID:model.modelID,geometryID:model.geometryID,
                        mappingID:model.selectedMappingID,toolLink:model.toolLink,topCenterMeters:sections.top,
                        bottomCenterMeters:sections.bottom,diameterMeters:sections.diameterMeters,
                        firstContactStepIndex:min(grip,prepared+1),gripStepIndex:grip,
                        releaseStepIndex:raw.steps.firstIndex(where:{$0.jawAction == .release}),stepCount:raw.steps.count,
                        terminalGraspHold:graspHold ? true:nil)
                    let review:ROBWorkspaceCollisionPlan
                    if let visual {
                        review=try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:raw.baseline,steps:raw.steps,map:map,model:model,
                            generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:visual,payload:payload,intentionalContact:contact)
                    } else {
                        review=try ROBWorkspaceCollisionPlan.review(baseline:raw.baseline,steps:raw.steps,map:map,model:model,
                            generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,payload:payload,intentionalContact:contact)
                    }
                    return try ROBLeftGestureCompiler.compile(kind:kind,name:raw.name,poses:raw.poses,model:model,
                        baseline:planningStart,generation:session,id:raw.id,recyclingActions:actions,
                        recyclingParameters:recyclingParameters,workspaceCollisionPlan:review,workspaceApproachPlan:entry,
                        collisionMap:map,collisionSceneID:map.sceneID,collisionCameraGeneration:camera,visualCalibrationTrial:visual,nowMilliseconds:now)
                    }
                    var lastFailure:Error=ROBGhostMotionError.blocked("No collision-free corkscrew entry was found.")
                    for rearward in [0.24,0.16,0.32] {
                        do {return try candidate(rearward)} catch {lastFailure=error}
                    }
                    if visual != nil {
                        // Review the complete standalone grasp/lift route;
                        // a failed destination never supplies an exemption
                        // for its approach, payload or observed environment.
                        for rearward in [0.24,0.16,0.32] {
                            do {return try candidate(rearward,forceGraspHold:true)}catch{lastFailure=error}
                        }
                    }
                    throw lastFailure
                }.value
                try check(); try checkCollisionContext()
                guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue),planningStart,tolerance:0.015),
                      observedObjects.allSatisfy({ Date().timeIntervalSince1970*1000-$0.capturedAt < 60_000 }) else {
                    throw ROBArmRoutineError.blocked("The arm or objects changed while the complete route was being checked.")
                }
                proposal = compiled; collisionReviewProposal = compiled
                collisionReviewStatus = ["status":"reviewed","registration_verified":map.registrationID != nil,
                    "visual_calibration_trial":visual != nil,"assumed_spatial_error_m":visual?.assumedSpatialErrorMeters as Any? ?? NSNull(),
                    "can_geometry_assumed":sections.shapePriorEvidence != nil,
                    "can_geometry_source":sections.shapePriorEvidence?.source ?? "RGB_D_depth_body_bands",
                    "payload_geometry_measured":sections.shapePriorEvidence == nil,
                    "intentional_contact_geometry_assumed":sections.shapePriorEvidence != nil,
                    "terminal_grasp_hold":["recycling_grasp_hold","incremental_visual_servo_grasp_hold"].contains(compiled.kind),
                    "entry_only_admitted":compiled.kind=="incremental_visual_servo_grasp_hold",
                    "checked_poses":compiled.workspaceCollisionPlan?.checkedPoseCount ?? 0,
                    "detail":compiled.kind=="incremental_visual_servo_grasp_hold" ? "Only the empty entry is checked. Observed jaws/can and each fresh corrected segment must be admitted before a gentle grip and verification lift.":compiled.kind=="recycling_grasp_hold" ? compiled.name+". Complete approach/grasp/6cm lift checked; no carry, release or return admitted.":"Can-derived corkscrew entry from the measured start, grasp, payload transfer and retreat checked together before travel."]
            } catch let error as ROBWorkspaceReachError {
                localReceiptPerceptionFailure=true
                ROBWorkspaceSearch.shared.announce?(error.helpRequest)
                return ["status": "needs_help", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                    "detail": error.localizedDescription, "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            } catch {
                localReceiptPerceptionFailure=true
                return ["status": "not_reachable", "arm_motion_sent": armTravelDispatched, "reach_sent": false, "empty_arm_parked": false, "measured": false,
                    "detail": error.localizedDescription, "workspace_search": ROBWorkspaceSearch.shared.lastReport]
            }
            try proposal!.encoded().write(to: URL(fileURLWithPath: lastRecordingPath).deletingPathExtension()
                .appendingPathExtension("proposal.json"), options: .atomic)
            update(proposal?.kind=="recycling_grasp_hold" ? "Can confirmed; the destination route is not admitted. Trying one checked grasp and short lift, then holding.":"Can and orange bucket confirmed. Executing the bounded local plan under the original approval.")
        }
        if let proposal {
            guard proposal.sessionGeneration == generation, ROBArmRoutinePlan.near(q, proposal.baseline, tolerance: 0.015) else {
                throw ROBArmRoutineError.blocked("The gateway session or measured start pose changed; rebuild and review the ghost path.")
            }
            sentPath = [q]
        }
        let stationaryJaw = command == "left_grip" || command == "left_release"
        guard let route = ROBLeftArmInteractionPlan.executionRoute(from: q, hanging: command == "left_relax", waving: command == "left_wave")
            ?? (entryRecovery != nil || proposal?.workspaceCollisionPlan != nil || proposal?.kind == "recover" && referencedGeneration == generation ? [] : nil) else {
            throw ROBArmRoutineError.blocked("Left arm is outside the taught route; no movement sent.")
        }
        if stationaryJaw {
            try verifyFront()
        } else if referencedGeneration != generation {
            guard entryRecovery != nil || ROBArmRoutinePlan.near(q, Array(repeating: 0, count: 7)) else {
                throw ROBArmRoutineError.blocked("First left-arm movement in a new session must start physically hanging at encoder zero.")
            }
            referencedGeneration = generation
        }
        if inactiveWorkspaceSearch {
            try await wait(3) { (try? self.measured()) != nil }
            inactiveWorkspaceSearch = false
            try check()
        }
        try await prepareCameraAndMode(stationaryJaw:stationaryJaw)
        if let entryRecovery {
            try await move(entryRecovery)
            proposal = nil; proposalStep = -1; sentPath = []
            try verifyFront()
        }
        if stationaryJaw {
            try await settleFront()
        } else if let proposal {
            do {
                if proposal.kind=="incremental_visual_servo_grasp_hold" {
                    return try await performIncrementalCanGrasp(proposal)
                }
                try await move(proposal)
            }
            catch let moved as ROBRecyclingVisualInspection.TargetMoved {
                guard command == "left_recycle_can", !recyclingGripDispatched,movingTargetReplansRemaining>0 else {throw moved}
                movingTargetReplansRemaining-=1
                try await holdTaskPosition(try measured().positionsRadians.map(\.doubleValue))
                self.proposal=nil;proposalStep = -1;taskJawTarget=nil;recyclingCan=nil;lastVisualGraspEvidence=nil
                collisionMap=nil;collisionModel=nil;collisionReviewProposal=nil;sceneCapturedForThisTask=false
                localReceiptHeldNeckIdentity=nil
                ROBWorkspaceSearch.shared.announce?("The can moved. I am holding and checking its new position.")
                update("Can moved before closing; one bounded fresh search and full replan under the same approval")
                return try await executeSingle(command)
            }
            if proposal.kind=="recycling_grasp_hold" {
                try await holdTaskPosition(proposal.steps.last!.positions)
                return ["status":"partial_held","measured":false,"motion_completed":false,"transfer_completed":false,
                    "grasp_attempted":true,"grasp_visually_supported":lastVisualGraspEvidence?.verdict == .supported,
                    "possible_payload_held":true,"placement_verified":false,"physical_arm":physicalSide,
                    "detail":"One grasp and6cm verification lift completed; holding at the measured endpoint. No carry, release, return or recycled-can count. Destination needs a separately admitted route.",
                    "workspace_search":ROBWorkspaceSearch.shared.lastReport]
            }
            if ["tabletop", "recycling"].contains(proposal.kind) {
                try await holdTaskPosition(proposal.steps.last!.positions)
                return ["status": "accepted_unverified", "measured": false, "motion_completed": true,
                    "gripper_measured": false, "placement_verified": false,
                    "grasp_visually_supported":lastVisualGraspEvidence?.verdict == .supported,
                    "gripper_intensity": ROBTabletopPickPlace.intensity,
                    "gripper_opening_intensity": proposal.kind == "recycling" ? 10 : 2,
                    "workspace_search": command == "left_recycle_can" ? ROBWorkspaceSearch.shared.lastReport : [:],
                    "physical_arm":physicalSide, "detail": "The \(physicalSide) arm reached all recycling-task positions; closing at intensity 2 and opening at intensity \(proposal.kind == "recycling" ? 10 : 2) were accepted. It is holding at the retreat pose. Object retention, jaw opening and placement in the bucket are unverified; inspect the result."]
            }
            return ["status": "completed", "measured": true, "motion_proposal_id": proposal.id.uuidString,
                "motion_proposal_sha256": proposal.fingerprint,
                "detail": "Ghost gesture ‘\(proposal.name)’ completed; left arm held at its final pose. Jaws unchanged."]
        } else { try await move(route) }
        switch command {
        case "left_relax":
            try await deactivateAtHanging()
            return ["status": "completed", "measured": true, "detail": "Left arm reached hanging and is inactive."]
        case "left_wave":
            try await move([ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex,
                ROBLeftArmInteractionPlan.waveIndex, ROBLeftArmInteractionPlan.waveRestIndex],preserveTargets:true)
            return ["status": "completed", "measured": true, "detail": "Left arm waved twice above the shoulder and is holding raised. Gripper unchanged."]
        case "left_object_cycle":
            return try await objectCycleAtFront()
        default:
            try await holdFrontForGripper()
            try await requireGripperCalibration(allowEmptyCalibration: command == "left_prepare")
            try await commandJaw(action: command == "left_grip" ? "hold" : "release", intensity: command == "left_prepare" ? 10 : jawIntensity)
            return ["status": "accepted_unverified", "measured": false, "detail": command == "left_grip"
                ? "Left grip command accepted; arm stays in front. Check object retention before releasing your support."
                : "Left open command accepted; arm stays in front. Check the jaws and object before continuing."]
        }
    }

    @MainActor private func parkEmptyArmForSearch(_ q:[Double]) async throws -> Bool {
        if ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)), gateway.modes(forArm:arm).count == 7, gateway.modes(forArm:arm).allSatisfy({ $0.intValue == 0 }) { return false }
        guard referencedGeneration == generation || ROBArmRoutinePlan.near(q,Array(repeating:0,count:7)) else {
            throw ROBArmRoutineError.blocked("A verified joint reference is needed before calculating an empty-arm return.")
        }
        try checkCollisionContext()
        let connector = try await workspaceConnector(to:Array(repeating:0,count:7),name:"Dynamic empty-arm return for stationary jaw setup")
        let previous = proposal; proposal = connector
        defer { proposal = previous; proposalStep = -1 }
        referencedGeneration = generation
        ROBWorkspaceSearch.shared.announce?("Returning my empty arm along the checked path.")
        inactiveWorkspaceSearch = false
        try await prepareCameraAndMode(stationaryJaw:false)
        try await move(connector)
        try await deactivateAtHanging()
        try await wait(1) { self.leaseRenewals.isEmpty }
        positionReady = false; cameraReady = false
        return true
    }

    /// Private breadcrumbs survive a process abort without serializing a
    /// partially built map. Logging never grants or resumes motion.
    private func recordCoverageStage(_ stage:String) {
        guard !lastRecordingPath.isEmpty,stage.utf8.count<=512 else {return}
        let path=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("coverage-stages.log")
        do {
            if !FileManager.default.fileExists(atPath:path.path) {
                guard FileManager.default.createFile(atPath:path.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
                    throw ROBArmRoutineError.blocked("Could not create the private coverage stage log.")
                }
            }
            let handle=try FileHandle(forWritingTo:path)
            defer {try?handle.close()}
            try handle.seekToEnd()
            let line=String(format:"%.3f",Date().timeIntervalSince1970*1000)+" "+stage+"\n"
            try handle.write(contentsOf:Data(line.utf8))
        } catch {
            var status=collisionReviewStatus as? [String:Any] ?? [:]
            status["coverage_stage_write_error"]=error.localizedDescription;collisionReviewStatus=status as NSDictionary
        }
    }

    /// Only neck observations may mitigate an unknown-cell preflight failure.
    /// Every attempt rebuilds the complete proof from original retained rays;
    /// neither the diagnostic nor a selected view grants arm travel.
    @MainActor private func reviewInitialRetreatWithCoverage(map initialMap:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,initialBaseline:[Double],offset:[Double],emptySource:String)
        async throws ->(map:ROBWorkspaceCollisionSnapshot,trial:ROBWorkspaceVisualCalibrationTrial,proof:ROBWorkspaceInitialEmptyRetreat,reference:InitialEmptyViewReference) {
        var map=initialMap,attempted:[ROBWorkspaceView]=[],evidence:[[String:Any]]=[]
        let began=ProcessInfo.processInfo.systemUptime,recoveryDeadline=began+30
        var outcome="not_attempted"
        defer {
            if !evidence.isEmpty,!lastRecordingPath.isEmpty {
                do {
                    let report:[String:Any]=["kind":"initial_unknown_cell_coverage_recovery","schemaVersion":1,
                        "motionAuthority":false,"freeSpaceInferred":false,"maximumViews":2,"budgetSeconds":30,
                        "elapsedSeconds":ProcessInfo.processInfo.systemUptime-began,"outcome":outcome,
                        "originalMapFingerprint":initialMap.fingerprint,"finalMapFingerprint":map.fingerprint,
                        "sceneID":map.sceneID.uuidString,"attempts":evidence]
                    let path=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("coverage-recovery.json")
                    try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:path,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                } catch {
                    var status=collisionReviewStatus as? [String:Any] ?? [:]
                    status["coverage_evidence_write_error"]=error.localizedDescription;collisionReviewStatus=status as NSDictionary
                }
            }
        }
        while true {
            try check()
            let sample=try measured(),baseline=sample.positionsRadians.map(\.doubleValue)
            guard baseline.count==7,initialBaseline.count==7,offset.count==7,
                  1.5*zip(baseline,initialBaseline).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
                throw ROBArmRoutineError.blocked("The arm changed during automatic coverage; no travel was sent.")
            }
            guard let trial=try visualTrial(map:map,model:model,baseline:baseline) else {
                throw ROBArmRoutineError.blocked("Automatic coverage lost the exact local visual-trial scope.")
            }
            guard let sourceFrame=vision.snapshot()["face"] else {throw ROBArmRoutineError.blocked("The initial preflight source frame is unavailable.")}
            let reference=try initialEmptyViewReference(sourceFrame)
            let now=Date().timeIntervalSince1970*1000
            do {
                let proof=try await reviewInitialLocalRetreat(map:map,model:model,baseline:baseline,
                    goal:zip(baseline,offset).map(+),trial:trial,generation:generation,camera:vision.cameraGeneration,
                    now:now,measuredAt:now-sample.effectiveSampleAgeMilliseconds,sequence:sample.sequence,
                    emptySource:emptySource,stage:"before_stationary_mode_preparation")
                outcome=attempted.isEmpty ? "initial_review_passed":"fresh_complete_review_passed"
                return (map,trial,proof,reference)
            } catch {
                let original=error
                guard localReceiptCommand != nil,inactiveWorkspaceSearch,!leased,!positionReady,
                      leaseRenewals.isEmpty,!armTravelDispatched,!jawCommandDispatched,!jawSetupDispatchUncertain,
                      !recyclingGripDispatched,!servoPossiblePayloadUncertain,
                      attempted.count<2,ProcessInfo.processInfo.systemUptime<recoveryDeadline,
                      let blocker=ROBWorkspaceUnknownCellBlocker(detail:error.localizedDescription,voxelSizeMeters:map.voxelSizeMeters) else {
                    outcome="review_still_blocked";throw original
                }
                try check()
                cameraReady=false;localReceiptHeldNeckIdentity=nil
                phase="automatic unknown-cell coverage"
                update("Checking a new view of the blocked \(blocker.link) region, attempt \(attempted.count+1) of 2")
                let before=map
                guard let capture=try await ROBWorkspaceSearch.shared.captureBlockerCoverage(blocker:blocker,continuing:map,
                    model:model,generation:generation,attempted:attempted,deadlineUptime:recoveryDeadline,
                    recordStage:{self.recordCoverageStage($0)},
                    check:{try self.check()},progress:{self.update($0)}) else {
                    outcome="no_distinct_observable_view"
                    evidence.append(["status":outcome,"blocked_link":blocker.link,
                        "blocked_voxel":[blocker.voxel.x,blocker.voxel.y,blocker.voxel.z],"detail":original.localizedDescription])
                    throw original
                }
                try check()
                guard capture.snapshot.sceneID==before.sceneID,capture.snapshot.cameraGeneration==before.cameraGeneration,
                      capture.snapshot.sessionGeneration==before.sessionGeneration,
                      capture.snapshot.bodyMotionIdentity==before.bodyMotionIdentity,
                      capture.snapshot.estimatedCameraProjectionIdentity==before.estimatedCameraProjectionIdentity,
                      capture.snapshot.observedFrameCount>before.observedFrameCount,
                      capture.snapshot.lastCapturedAtMilliseconds>before.lastCapturedAtMilliseconds else {
                    throw ROBArmRoutineError.blocked("Automatic coverage changed its scene or failed to add original observations.")
                }
                attempted.append(capture.view);map=capture.snapshot
                collisionMap=map;collisionModel=model;collisionReviewProposal=nil
                evidence.append(["status":"captured_rechecking_complete_path","attempt":attempted.count,
                    "blocked_link":blocker.link,"blocked_voxel":[blocker.voxel.x,blocker.voxel.y,blocker.voxel.z],
                    "pan":capture.view.panDegrees,"upper":capture.view.upperTarget,
                    "before_state":Int(before.state(at:blocker.center).rawValue),"after_state":Int(map.state(at:blocker.center).rawValue),
                    "before_map":before.fingerprint,"after_map":map.fingerprint,
                    "before_frames":before.observedFrameCount,"after_frames":map.observedFrameCount,
                    "occupied_returns_preserved":true,"free_space_inferred":false])
                publishCollisionReview(map:map,detail:"New blocker view captured; rechecking the entire initial arm route")
            }
        }
    }

    private struct InitialEmptyViewReference {
        let frame:ROBArmRoutineVision.Frame
        let pan:Int,lower:Int,upper:Int,readyAtUptime:Double,intrinsicsIdentity:String
        let bodyIdentity:String,session:UInt64,neckIdentity:String
    }
    /// The old frame supplies source/K only, NEVER a pose at the new head hold.
    /// Pin actual held targets/readiness independently before geometry work.
    @MainActor private func initialEmptyViewReference(_ frame:ROBArmRoutineVision.Frame) throws ->InitialEmptyViewReference {
        let neck=ROBFixedHeadCalibrationWindowController.shared.readNeck?() ?? [:]
        guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,
              let pan=neck["pan"]as?Int,let lower=neck["lower"]as?Int,let upper=neck["upper"]as?Int,
              let ready=neck["ready_at"]as?Double,ready.isFinite,ready<=ProcessInfo.processInfo.systemUptime,
              let identity=localNeckIdentity(),generation>0,frame.cameraGeneration==vision.cameraGeneration else {
            throw ROBArmRoutineError.blocked("Initial empty view reference needs known stationary raw neck targets, readiness, current camera and gateway session.")
        }
        return .init(frame:frame,pan:pan,lower:lower,upper:upper,readyAtUptime:ready,
            intrinsicsIdentity:try ROBFixedHeadCalibrationWindowController.intrinsicsIdentity(frame),
            bodyIdentity:ROBFixedHeadBodyMotionIdentity.currentIdentity,session:generation,neckIdentity:identity)
    }

    /// Nonactuating initial-retreat preflight only. A slow geometry proof may
    /// outlive a frame; reacquire actual source data rather than restamp it.
    @MainActor private func refreshInitialEmptyDispatchView(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        trial:ROBWorkspaceVisualCalibrationTrial,baseline:[Double],reference:InitialEmptyViewReference) async throws {
        guard localReceiptCommand != nil,!cameraReady,!leased,!armTravelDispatched,!jawCommandDispatched,
              !jawSetupDispatchUncertain,!recyclingGripDispatched,!servoPossiblePayloadUncertain else {
            throw ROBArmRoutineError.blocked("Fresh-view recovery is limited to stationary EMPTY preflight before any travel or jaw command.")
        }
        let controller=ROBFixedHeadCalibrationWindowController.shared
        let oldFrame=reference.frame
        func reject(_ reason:String,_ detail:String)->ROBArmRoutineError {
            var status=collisionReviewStatus as? [String:Any] ?? [:]
            status["initial_empty_view_refresh"]=["reason":reason,"detail":detail,
                "reference_used_for_source_only":true,"reference_sequence":NSNumber(value:oldFrame.sequence),
                "reference_captured_at_ms":oldFrame.capturedAt,"expected_ready_at_uptime":reference.readyAtUptime,
                "expected_raw_neck":[reference.pan,reference.lower,reference.upper],
                "expected_gateway_generation":NSNumber(value:reference.session),"motion_authority":false]
            collisionReviewStatus=status as NSDictionary
            return .blocked("Initial empty view ["+reason+"]: "+detail)
        }
        guard let expected=oldFrame.intrinsics,let runtime=expected.runtimeCalibration?.identity,
              let source=expected.cameraServiceSourceSHA256,oldFrame.cameraGeneration==trial.cameraGeneration,reference.bodyIdentity==trial.bodyMotionIdentity,reference.session==generation else {
            throw reject("reference_source_contract_changed","The initial proof lost its original RGB-D source contract.")
        }
        let began=Date().timeIntervalSince1970*1000,end=min(deadline,ProcessInfo.processInfo.systemUptime+2)
        while ProcessInfo.processInfo.systemUptime<end {
            try check();try Task.checkCancellation()
            guard !armTravelDispatched,!jawCommandDispatched,!leased,!recyclingGripDispatched,
                  localReceiptHeldNeckIdentity==reference.neckIdentity,reference.neckIdentity==localNeckIdentity(),
                  ROBFixedHeadBodyMotionIdentity.currentIdentity==trial.bodyMotionIdentity,
                  ROBNeckRGBPoseDisplay.estimatedCameraProjectionIdentity(model:model)==trial.estimatedCameraProjectionIdentity,
                  vision.cameraGeneration==trial.cameraGeneration else {
                throw reject("held_body_head_or_generation_changed","The stationary empty preflight lost its held head/body/source identity.")
            }
            let neck=controller.readNeck?() ?? [:]
            guard neck["known"]as?Bool==true,neck["stationary"]as?Bool==true,
                  neck["pan"]as?Int==reference.pan,neck["lower"]as?Int==reference.lower,neck["upper"]as?Int==reference.upper,
                  neck["ready_at"]as?Double==reference.readyAtUptime else {
                throw reject("held_neck_changed","The pinned raw neck targets or readiness changed during empty preflight.")
            }
            let actual=try measured().positionsRadians.map(\.doubleValue)
            guard actual.count==7,baseline.count==7,1.5*zip(actual,baseline).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.002 else {
                throw reject("baseline_changed","The measured initial-retreat start changed during fresh-view recovery.")
            }
            if let frame=vision.snapshot()["face"] {
                guard frame.cameraGeneration==oldFrame.cameraGeneration,
                      frame.intrinsics?.runtimeCalibration?.identity==runtime,frame.intrinsics?.cameraServiceSourceSHA256==source else {
                    throw reject("source_contract_changed","The RGB-D source changed while awaiting an actual fresh preflight frame.")
                }
                if frame.sequence>oldFrame.sequence,frame.capturedAt>=began,vision.fresh,
                   (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt),
                   frame.depthCoverage>=0.25,let depth=frame.depth,let k=frame.intrinsics,
                   k.isValid(forWidth:depth.width,height:depth.height),k.rgbOutputUndistorted==true,
                   k.depthRGBGeometryCorrespondence?.status=="matched" {
                    let capturedUptime=ProcessInfo.processInfo.systemUptime-(Date().timeIntervalSince1970*1000-frame.capturedAt)/1000
                    guard capturedUptime>=reference.readyAtUptime else {
                        throw reject("new_frame_before_ready","The new frame exposure preceded the pinned stationary neck readiness.")
                    }
                    // Historical visibility cannot veto a current approach.
                    // Assess people only in this new post-ready exposure;
                    // stale observations wait for reacquisition below.
                    guard frame.handsClear else {
                        throw reject("person_or_hand_visible","A hand or person is visible in the fresh post-ready frame; holding the empty preflight.")
                    }
                    let scope:ROBFixedHeadRegistrationScope
                    do {scope=try controller.scope(model:model,frame:frame)}
                    catch {throw reject("new_frame_scope_rejected",error.localizedDescription)}
                    guard scope.panTarget==reference.pan,scope.lowerTarget==reference.lower,scope.upperTarget==reference.upper,
                          scope.cameraGeneration==oldFrame.cameraGeneration,scope.gatewaySessionGeneration==reference.session,
                          scope.intrinsicsIdentity==reference.intrinsicsIdentity,
                          ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(model:model,actualFrame:.init(cameraGeneration:frame.cameraGeneration,
                            actualDeviceMXID:k.runtimeCalibration?.actualDeviceMXID,runtimeCalibrationIdentity:k.runtimeCalibration?.identity,
                            cameraServiceSourceSHA256:k.cameraServiceSourceSHA256,scope:scope,inertialJSON:k.inertial.flatMap{try?JSONEncoder().encode($0)})) else {
                        throw reject("new_frame_contract_or_geometry_changed","The new preflight frame changed its normalized K/raw head pose or refined source geometry.")
                    }
                    try requireLiveVisualTrial(trial,map:map,model:model)
                    return
                }
            }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw reject("fresh_post_ready_frame_timeout","No NEW actual fresh RGB-D frame reached the unchanged empty preflight within two seconds; no travel sent.")
    }

    @MainActor private func performInitialLocalRetreatIfNeeded(map initialMap:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel) async throws ->Bool {
        var map=initialMap
        guard localReceiptCommand != nil,map.registrationID == nil else {return false}
        let initial=try measured().positionsRadians.map(\.doubleValue)
        let needsRetreat=try await Task.detached(priority:.userInitiated){
            var proxy=ROBWorkspaceSelfProxyClearance(model:model)
            return try proxy.minimum(vendorLeft:initial)<0.030
        }.value
        guard needsRetreat else {return false}
        try check()
        let sample=try measured(),start=sample.positionsRadians.map(\.doubleValue)
        guard 1.5*zip(initial,start).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
            throw ROBArmRoutineError.blocked("The initial arm changed while its proxy geometry was checked.")
        }
        guard physicalSide=="right",!armTravelDispatched,!jawCommandDispatched,!jawSetupDispatchUncertain,
              !recyclingGripDispatched,ROBArmRoutinePlan.near(start,Array(repeating:0,count:7)),
              try visualTrial(map:map,model:model,baseline:start) != nil else {
            throw ROBArmRoutineError.blocked("Initial self-proxy clearance needs a distinct declared-empty first-attempt retreat; no general overlap exemption is available.")
        }
        let emptySource="local_first_attempt_no_arm_travel_or_task_grip"
        let preferredOffset=[0,-0.075,0,0,0,0,0]
        let session=generation
        let coverageReview=try await reviewInitialRetreatWithCoverage(map:map,model:model,initialBaseline:start,offset:preferredOffset,emptySource:emptySource)
        map=coverageReview.map
        let trial=coverageReview.trial,initialProof=coverageReview.proof,camera=vision.cameraGeneration
        // Freeze the selected retreat, rather than silently restoring
        // the old pure-J2 offset when position mode supplies a fresh baseline.
        let offset=zip(initialProof.baseline,initialProof.goal).map{$1-$0}
        try await refreshInitialEmptyDispatchView(map:map,model:model,trial:trial,baseline:initialProof.baseline,reference:coverageReview.reference)
        try requireLiveVisualTrial(trial,map:map,model:model)
        let initialPath=ROBLeftGestureProposal(id:UUID(),name:"Initial declared-empty visual calibration retreat",kind:"initial_empty_visual_retreat",
            modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:session,baseline:initialProof.baseline,poses:[],steps:[initialProof.step])
        activeLocalRetreat=initialProof;proposal=initialPath;collisionReviewProposal=initialPath
        defer {activeLocalRetreat=nil;proposal=nil;proposalStep = -1;reviewedDispatchStart=nil}
        inactiveWorkspaceSearch=false
        try await prepareCameraAndMode(stationaryJaw:false)
        let reviewed=try measured(),q=reviewed.positionsRadians.map(\.doubleValue),reviewTime=Date().timeIntervalSince1970*1000
        // Entering position mode is not permission to spend the proof's start
        // tolerance as extra travel. Rebuild the complete retreat from this
        // exact, fresh measured start immediately before dispatch.
        guard let dispatchTrial=try visualTrial(map:map,model:model,baseline:q) else {
            throw ROBArmRoutineError.blocked("The explicit initial-retreat trial scope disappeared during stationary preparation.")
        }
        let dispatchGoal=zip(q,offset).map(+)
        guard let sourceFrame=vision.snapshot()["face"] else {throw ROBArmRoutineError.blocked("The stationary preflight source frame disappeared.")}
        let reference=try initialEmptyViewReference(sourceFrame)
        cameraReady=false // No travel has been dispatched; restore the strict gate only after actual reacquisition.
        let proof=try await reviewInitialLocalRetreat(map:map,model:model,baseline:q,goal:dispatchGoal,trial:dispatchTrial,
            generation:session,camera:camera,now:reviewTime,measuredAt:reviewTime-reviewed.effectiveSampleAgeMilliseconds,
            sequence:reviewed.sequence,emptySource:emptySource,stage:"fresh_dispatch_start")
        let path=ROBLeftGestureProposal(id:initialPath.id,name:initialPath.name,kind:initialPath.kind,
            modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            sessionGeneration:session,baseline:q,poses:[],steps:[proof.step])
        activeLocalRetreat=proof;proposal=path;collisionReviewProposal=path
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        try encoder.encode(proof).write(to:URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("initial-empty-retreat.json"),options:.atomic)
        collisionReviewStatus=["status":"reviewed_initial_empty_retreat","registration_verified":false,
            "initial_empty_state_assumed":true,"empty_state_evidence_source":emptySource,
            "maximum_hull_travel_m":proof.maximumHullTravelMeters,"checked_poses":proof.checkedPoseCount,
            "detail":"One four-second first-attempt EMPTY-state assumption from task history; no sensor-confirmed jaws, grasp, payload or obstacle exemption."]
        try await refreshInitialEmptyDispatchView(map:map,model:model,trial:dispatchTrial,baseline:q,reference:reference)
        cameraReady=true
        let dispatch=ROBReviewedArmDispatchStart(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:q,sequence:reviewed.sequence,reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
        try check();try checkCollisionContext();try requireLiveVisualTrial(dispatchTrial,map:map,model:model)
        let current=try measured()
        let admissionDrift=1.5*zip(current.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})
        guard dispatch.matches(proposalID:path.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:current.positionsRadians.map(\.doubleValue),sequence:current.sequence,nowUptime:ProcessInfo.processInfo.systemUptime),
              proof.maximumHullTravelMeters+admissionDrift<=0.060 else {
            throw ROBArmRoutineError.blocked("The actual retreat start drifted after review; no step sent.")
        }
        ROBWorkspaceSearch.shared.announce?("Moving my \(physicalSide) arm.")
        proposalStep=0;phase="initial declared-empty retreat";sentPath=[q,dispatchGoal]
        reviewedDispatchStart=dispatch;armTravelDispatched=true
        try await accepted {gateway.sendApprovedLeftGestureStep(proposalID:path.id,index:0,duration:4,expectedSessionGeneration:session)}
        reviewedDispatchStart=nil;leased=true;lastRenewal=ProcessInfo.processInfo.systemUptime
        let began=ProcessInfo.processInfo.systemUptime;var settler=ROBArmRoutineSettler()
        try await wait(7){
            guard let sample=try?self.measured() else{return false}
            return settler.observe(sequence:sample.sequence,positions:sample.positionsRadians.map(\.doubleValue),target:dispatchGoal,
                now:ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime-began>=4
        }
        try await holdTaskPosition(dispatchGoal)
        if activeHoldAfterInitialEmptyLift {
            let endpoint=try measured(),actual=endpoint.positionsRadians.map(\.doubleValue)
            let goalError=1.5*zip(actual,dispatchGoal).reduce(0.0,{$0+abs($1.0-$1.1)})
            let evidence:[String:Any]=["kind":"fully_checked_initial_empty_lift_held","motionAuthority":false,
                "proposalID":path.id.uuidString,"mapFingerprint":map.fingerprint,"modelID":model.modelID,
                "geometryID":model.geometryID,"selectedBaseline":q,"selectedGoal":dispatchGoal,
                "actualMeasuredEndpoint":actual,"endpointGoalPointErrorBoundMeters":goalError,
                "endpointWithin3mmOfGoal":goalError<=0.003,"telemetrySequence":NSNumber(value:endpoint.sequence),
                "gatewaySessionGeneration":NSNumber(value:session),"recordedAtMilliseconds":Date().timeIntervalSince1970*1000,
                "proofFile":URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("initial-empty-retreat.json").path,
                "jawCommandSent":false,"transfersCompleted":0]
            let file=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("initial-empty-lift-held.json")
            try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys,.prettyPrinted]).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            var stored=evidence;stored["recordingPath"]=file.path;initialEmptyLiftHeldEvidence=stored as NSDictionary
        }
        taskJawTarget=nil
        referencedGeneration=session
        activeLocalRetreat=nil;proposal=nil;proposalStep = -1;cameraReady=false;positionReady=false
        collisionMap=nil;collisionModel=nil;collisionReviewProposal=nil;sceneCapturedForThisTask=false;localReceiptHeldNeckIdentity=nil
        update(activeHoldAfterInitialEmptyLift ? "Initial checked empty lift is held; no next step or can operation. ZERO transfers."
            : "Initial empty retreat completed; observing fresh can and workspace geometry before any grasp")
        return true
    }

    @MainActor private func initialEmptyLiftHoldResult(performed:Bool)throws->NSDictionary {
        try check()
        guard activeHoldAfterInitialEmptyLift,localReceiptCommand != nil,physicalSide=="right",
              !jawCommandDispatched,!jawSetupDispatchUncertain,!recyclingGripDispatched,
              !performed || initialEmptyLiftHeldEvidence != nil else {
            throw ROBArmRoutineError.blocked("The empty lift-only result lost its exact scope or endpoint evidence.")
        }
        let sample=try measured()
        var output:[String:Any]=["status":performed ? "partial_empty_lift_held":"partial_empty_lift_not_needed_held",
            "motion_completed":false,"transfer_completed":false,"batch_completed":0,"placement_verified":false,
            "grasp_visually_supported":false,"initial_empty_lift_only":true,"initial_empty_lift_performed":performed,
            "jaw_commands_permitted":false,"grasp_attempted":false,"measured_positions":sample.positionsRadians.map(\.doubleValue),
            "detail":performed ? "Initial fully checked empty lift is held for inspection. No jaw, grasp, carry, release, return or next step. ZERO cans transferred."
                : "No initial empty lift was required by the current model check. The arm remains unchanged; no jaw or can operation. ZERO cans transferred."]
        if let evidence=initialEmptyLiftHeldEvidence {output["initial_empty_lift_evidence"]=evidence}
        return output as NSDictionary
    }

    @MainActor private func reviewInitialLocalRetreat(map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        baseline:[Double],goal:[Double],trial:ROBWorkspaceVisualCalibrationTrial,generation:UInt64,camera:UUID,
        now:Double,measuredAt:Double,sequence:UInt64,emptySource:String,stage:String) async throws ->ROBWorkspaceInitialEmptyRetreat {
        var reviewedGoal=goal
        do {
            if stage=="before_stationary_mode_preparation" {
                let selection=try await Task.detached(priority:.userInitiated){
                    try ROBWorkspaceCollisionPlan.selectInitialEmptyVisualCalibrationRetreat(from:baseline,map:map,model:model,
                        generation:generation,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:trial,
                        measuredAtMilliseconds:measuredAt,emptyTrialEligibility:true,emptyStateEvidenceSource:emptySource)
                }.value
                reviewedGoal=selection.proof?.goal ?? selection.representativeRejectedGoal ?? goal
                if !lastRecordingPath.isEmpty {
                    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
                    let path=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension()
                        .appendingPathExtension("initial-retreat-candidates-"+UUID().uuidString+".json")
                    try encoder.encode(selection).write(to:path,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
                    var status=collisionReviewStatus as? [String:Any] ?? [:]
                    status["initial_retreat_candidates_evidence_path"]=path.path
                    status["initial_retreat_candidate_count"]=selection.attempts.count
                    collisionReviewStatus=status as NSDictionary
                }
                if let selected=selection.proof {return selected}
                throw ROBArmRoutineError.blocked(selection.rejectionDetail)
            }
            // Dispatch rechecks exactly the selected offset. It cannot choose
            // another route after the camera/mode and measured start freeze.
            return try await Task.detached(priority:.userInitiated){
                try ROBWorkspaceCollisionPlan.reviewInitialEmptyVisualCalibrationRetreat(from:baseline,to:goal,map:map,model:model,
                    generation:generation,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:trial,
                    measuredAtMilliseconds:measuredAt,emptyTrialEligibility:true,emptyStateEvidenceSource:emptySource)
            }.value
        } catch {
            let original=error,detail=error.localizedDescription,recording=lastRecordingPath,rejectedGoal=reviewedGoal
            do {
                guard !recording.isEmpty else {throw ROBArmRoutineError.blocked("No task recording path is available for the rejection export.")}
                let evidence=try await Task.detached(priority:.utility){
                    try ROBInitialRetreatFailureExport.write(recording:URL(fileURLWithPath:recording),map:map,model:model,
                        baseline:baseline,goal:rejectedGoal,trial:trial,stage:stage,reviewTimeMilliseconds:now,
                        measuredAtMilliseconds:measuredAt,sequence:sequence,detail:detail)
                }.value
                var status=collisionReviewStatus as? [String:Any] ?? [:]
                status["initial_retreat_rejection_evidence_path"]=evidence.path
                status["status"]="blocked";status["detail"]=detail;collisionReviewStatus=status as NSDictionary
            } catch {
                var status=collisionReviewStatus as? [String:Any] ?? [:]
                status["initial_retreat_rejection_export_error"]=error.localizedDescription;collisionReviewStatus=status as NSDictionary
            }
            // Export failure never replaces or softens the original rejection.
            throw original
        }
    }

    @MainActor private func executeEstimatedCalibration() async throws -> NSDictionary {
        guard activeCommand == "left_estimated_calibration", let active = activeEstimated,
              proposal == active.proposal else { throw ROBArmRoutineError.blocked("No frozen estimated proof is active.") }
        try check(); try checkCollisionContext()
        guard estimatedStartMatches(try measured().positionsRadians.map(\.doubleValue),baseline:active.proof.baseline) else {
            throw ROBArmRoutineError.blocked("Estimated calibration start drift exceeded 2 mm; no step sent.")
        }
        // No encoder zero, jaw initialization or arm return is part of this
        // lane. Enter position mode at the existing measured pose only.
        inactiveWorkspaceSearch = false
        try await prepareCameraAndMode(stationaryJaw:false)
        try checkCollisionContext()
        let sample = try measured(), q = sample.positionsRadians.map(\.doubleValue)
        guard estimatedStartMatches(q,baseline:active.proof.baseline) else {
            throw ROBArmRoutineError.blocked("The measured start changed during mode preparation; no calibration step sent.")
        }
        let session = generation, camera = vision.cameraGeneration, now = Date().timeIntervalSince1970*1000
        if physicalSide == "right" {
            // This value was built internally from the complete geometry review
            // and is held immutably in this one pending/active operation. Reuse
            // only identical inputs; imported decoded proofs still use validate().
            guard active.resourceFingerprint == (try estimatedResourceFingerprint(model:active.model)),
                  active.geometryValidationFingerprint == (try estimatedGeometryFingerprint(proof:active.proof,map:active.map,model:active.model,proposal:active.proposal)) else {
                throw ROBArmRoutineError.blocked("The frozen RIGHT geometry, proposal or resources changed; no cached review is reusable.")
            }
            try active.proof.validateContext(map:active.map,model:active.model,generation:session,
                cameraGeneration:camera,nowMilliseconds:now)
        } else {
            try await Task.detached(priority:.userInitiated) {
                try active.proof.validate(map:active.map,model:active.model,generation:session,
                    cameraGeneration:camera,nowMilliseconds:now)
            }.value
        }
        let review = ROBReviewedArmDispatchStart(proposalID:active.proof.id,index:0,generation:session,
            mapFingerprint:active.map.fingerprint,positions:q,sequence:sample.sequence,
            reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
        try check(); try checkCollisionContext()
        let actual = try measured()
        guard estimatedStartMatches(actual.positionsRadians.map(\.doubleValue),baseline:active.proof.baseline),
              review.matches(proposalID:active.proof.id,index:0,generation:session,mapFingerprint:active.map.fingerprint,
                positions:actual.positionsRadians.map(\.doubleValue),sequence:actual.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else {
            throw ROBArmRoutineError.blocked("Actual-start drift invalidated the estimated review; no calibration step sent.")
        }
        let started = ProcessInfo.processInfo.systemUptime
        proposalStep = 0; phase = "estimated single empty-arm retreat"
        update("Performing one slow estimated empty-arm retreat away from the table")
        do {
            reviewedDispatchStart = review
            defer { reviewedDispatchStart = nil }
            // A missing acknowledgement cannot prove that no motion started.
            armTravelDispatched = true
            try await accepted { gateway.sendApprovedLeftGestureStep(proposalID:active.proof.id,index:0,
                duration:active.proof.seconds,expectedSessionGeneration:session) }
        }
        leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
        var settler = ROBArmRoutineSettler()
        try await wait(active.proof.seconds+3) {
            guard let latest = try? self.measured() else { return false }
            return settler.observe(sequence:latest.sequence,positions:latest.positionsRadians.map(\.doubleValue),
                target:active.proof.target,now:ProcessInfo.processInfo.systemUptime)
                && 1.5*zip(latest.positionsRadians.map(\.doubleValue),active.proof.target).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003
                && ProcessInfo.processInfo.systemUptime-started >= active.proof.seconds
        }
        proposalStep = -1
        try await holdTaskPosition(active.proof.target)
        let end = try measured().positionsRadians.map(\.doubleValue)
        guard 1.5*zip(end,active.proof.target).reduce(0.0,{ $0+abs($1.0-$1.1) }) <= 0.003,
              end.contains(where:{ abs($0) > ROBEstimatedArmCalibrationPlan.hangingToleranceRadians+0.002+1e-6 }) else {
            throw ROBArmRoutineError.blocked("The estimated step did not hold its small measured target; observe the arm before any new action.")
        }
        return ["status":"completed","measured":true,"arm_motion_sent":true,"jaw_command_sent":false,
            "estimated_calibration_unverified":true,"estimated_proof_id":active.proof.id.uuidString,
            "map_fingerprint":active.map.fingerprint,"baseline_positions":active.proof.baseline,
            "target_positions":active.proof.target,"measured_positions":end,
            "measured_joint_delta":zip(active.proof.baseline,end).map { $1-$0 },
            "physical_arm":physicalSide,"detail":"One 4-second estimated EMPTY-\(physicalSide)-arm retreat completed and is held. Joint feedback measured; physical calibration remains unverified. No jaw command or automatic return. Report the observed direction and clearance."]
    }

    /// Rebuild read-only session state before accepting a stationary baseline.
    @MainActor private func synchronizeSceneArmModes() async throws {
        // A new gateway session may have current CAN packets but no cached
        // mode for the opposite arm. Query both; never activate or reset one
        // merely to populate this read-only state.
        for side in ["left","right"] {
            try await accepted {gateway.queryMode(forArm:side)}
        }
        try await wait(2) {
            ["left","right"].allSatisfy {side in
                guard let sample=self.gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                      sample.effectiveGripperFeedbackAgeMilliseconds<=250,sample.positionsRadians.count==7,
                      sample.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),sample.statuses.count==7,
                      let first=sample.statuses.first?.intValue,[0,1,2].contains(first),
                      sample.statuses.allSatisfy({$0.intValue==first}) else {return false}
                return self.gateway.modes(forArm:side).map(\.intValue)==sample.statuses.map(\.intValue)
            }
        }
    }

    /// Part of the explicit one-shot RIGHT recycling scope: both physical
    /// arms remain at measured positions. This is not a parking trajectory.
    /// Inactive arms need no extra torque; active arms enter a measured hold.
    @MainActor private func prepareRightRecyclingSceneHolds(allowDeferredJawSetup:Bool=true) async throws {
        guard physicalSide == "right", activeCommand == "left_recycle_can",
              ROBControllerArmApproval.shared.authorizesRightArmTrial(summary), let owner else {
            throw ROBArmRoutineError.blocked("The complete right recycling approval does not cover stationary preparation.")
        }
        try await synchronizeSceneArmModes()
        var baselines: [String:[Double]] = [:]
        var sequences: [String:UInt64] = [:]
        for side in ["left","right"] {
            guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                  sample.effectiveGripperFeedbackAgeMilliseconds<=250,sample.positionsRadians.count==7,
                  sample.positionsRadians.allSatisfy({$0.doubleValue.isFinite}),
                  sample.statuses.count==7,let first=sample.statuses.first?.intValue,[0,1,2].contains(first),
                  sample.statuses.allSatisfy({$0.intValue==first}),
                  gateway.modes(forArm:side).map(\.intValue)==sample.statuses.map(\.intValue) else {
                throw ROBArmRoutineError.blocked("Both arms need current consistent per-joint feedback before stationary preparation.")
            }
            baselines[side]=sample.positionsRadians.map(\.doubleValue);sequences[side]=sample.sequence
        }
        let heldSince=ProcessInfo.processInfo.systemUptime
        try await wait(2) {
            guard ProcessInfo.processInfo.systemUptime-heldSince>=0.3 else{return false}
            return ["left","right"].allSatisfy { side in
                guard let sample=self.gateway.telemetry(forArm:side),sample.sequence>(sequences[side] ?? 0),
                      sample.effectiveSampleAgeMilliseconds<=250,let q=baselines[side] else{return false}
                return sample.positionsRadians.count==7 && 1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003
            }
        }
        // Finish a deferred startup only at the already-established hanging
        // zero. A raised arm is never lowered blindly to initialize jaws.
        if allowDeferredJawSetup,!ROBGripperStartupCalibration.shared.calibrationReady(forArm:arm),
           baselines.values.allSatisfy({ROBArmRoutinePlan.near($0,Array(repeating:0,count:7))}) {
            for side in ["left","right"] where gateway.modes(forArm:side).contains(where:{$0.intValue != 0}) {
                guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                      sample.effectiveGripperFeedbackAgeMilliseconds<=250,
                      ROBArmRoutinePlan.near(sample.positionsRadians.map(\.doubleValue),Array(repeating:0,count:7)),
                      gateway.modes(forArm:side).map(\.intValue)==sample.statuses.map(\.intValue) else {
                    throw ROBArmRoutineError.blocked("An arm left its measured hanging state before stationary jaw setup; torque remains unchanged.")
                }
                try await accepted { gateway.deactivateArm(side) }
            }
            try await wait(2) { ["left","right"].allSatisfy { side in
                self.gateway.modes(forArm:side).map(\.intValue)==Array(repeating:0,count:7) &&
                self.gateway.telemetry(forArm:side)?.statuses.map(\.intValue)==Array(repeating:0,count:7)
            } }
            if localReceiptCommand != nil {jawSetupDispatchUncertain=true}
            try await ROBGripperStartupCalibration.shared.ensureReady(whileParkedBy:owner)
            jawSetupDispatchUncertain=false // confirmed EMPTY startup dispatch, not possession/opening feedback
            try check()
        }
        for side in ["left","right"] {
            if gateway.modes(forArm:side).map(\.intValue)==Array(repeating:1,count:7) {
                guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                      sample.effectiveGripperFeedbackAgeMilliseconds<=250,let q=baselines[side],
                      sample.statuses.map(\.intValue)==Array(repeating:1,count:7),
                      sample.positionsRadians.count==7,
                      1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {
                    throw ROBArmRoutineError.blocked("An arm changed before entering its measured stationary hold.")
                }
                try await accepted { gateway.enterPositionMode(forArm:side) }
                try await wait(2) {
                    guard let sample=self.gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                          sample.statuses.map(\.intValue)==Array(repeating:2,count:7),let q=baselines[side] else{return false}
                    return self.gateway.modes(forArm:side).map(\.intValue)==Array(repeating:2,count:7) &&
                        1.5*zip(sample.positionsRadians.map(\.doubleValue),q).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003
                }
                try await accepted(requiresConfirmedHold:true) { gateway.priorityHold(forArm:side) }
            }
        }
    }

    @MainActor private func prepareCameraAndMode(stationaryJaw:Bool) async throws {
        phase = "camera preparation"; update("Preparing live view for left-arm trial")
        if localReceiptCommand == nil {
            try await wait(12) { ROBArmRoutineCoordinator.shared.prepareView?() == true }
        } else {
            _ = try requireLocalReceipt()
            guard localReceiptHeldNeckIdentity != nil,localReceiptHeldNeckIdentity==localNeckIdentity() else {
                throw ROBArmRoutineError.blocked("The already-settled visual trial camera view changed before arm preparation.")
            }
        }
        try await wait(10) { self.vision.fresh && ROBArmRoutineCoordinator.shared.viewIsStationary?() == true }
        cameraReady = true
        try record(measured())
        if let owner {
            NotificationCenter.default.post(name: Notification.Name("ROBLeftArmTrialViewPrepared"), object: self,
                userInfo: ["executionID": owner])
        }
        if !stationaryJaw {
            let modes = gateway.modes(forArm: arm).map(\.intValue)
            guard modes.count == 7, [0, 1, 2].contains(modes[0]), modes.allSatisfy({ $0 == modes[0] }) else {
                throw ROBArmRoutineError.blocked("Left-arm modes are mixed or unsupported.")
            }
            if modes[0] != 2 { try await accepted { gateway.enterPositionMode(forArm: arm) } }
            let modeSequence = try measured().sequence
            try await wait(2) {
                guard let sample = try? self.measured(), sample.sequence > modeSequence else { return false }
                return sample.statuses.count == 7 && sample.statuses.allSatisfy({ $0.intValue == 2 })
            }
        }
        positionReady = true
    }

    private func workspaceModel() throws -> ROBGhostRobotModel {
        if localReceiptCommand != nil,let model=localReceiptModel,model.physicalSide==physicalSide {return model}
        guard let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("Bundled workspace model is unavailable.")
        }
        let model=try ROBGhostRobotModel(directory: directory, physicalSide: physicalSide)
        if localReceiptCommand != nil {localReceiptModel=model}
        return model
    }

    @MainActor private func holdTaskPosition(_ target: [Double]) async throws {
        try check()
        taskJawTarget = target
        leased = false
        try await wait(1) { self.leaseRenewals.isEmpty }
        try await accepted(requiresConfirmedHold: true) { gateway.priorityHold(forArm: arm) }
        var settler = ROBArmRoutineSettler()
        try await wait(2) {
            guard let sample = try? self.measured() else { return false }
            return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                target: target, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    @MainActor private func taskJaw(_ action: ROBLeftGestureProposal.JawAction, at target: [Double],beforeDispatch:(() async throws->Void)?=nil) async throws {
        guard !activeApproachCanThenHold || action == .prepare else {throw ROBGhostMotionError.blocked("Open-jaw approach forbids close and release commands.")}
        try await holdTaskPosition(target)
        defer { taskJawTarget = nil }
        if ["recycling","recycling_grasp_hold","incremental_visual_servo_grasp_hold","recycling_carry_release"].contains(proposal?.kind ?? "") {
            guard ROBGripperStartupCalibration.shared.calibrationReady(forArm: arm) else {
                throw ROBArmRoutineError.blocked("Stationary startup gripper setup is unavailable; no grasp was sent.")
            }
            try await requireGripperCalibration(allowEmptyCalibration: false)
        } else { try await requireGripperCalibration(allowEmptyCalibration: action == .prepare) }
        phase = "tabletop \(action.rawValue)"
        update(action == .grip ? "Local task: gripping empty can at intensity 2" : "Local task: opening gripper at the planned position")
        ROBWorkspaceSearch.shared.announce?(action == .prepare ? "Preparing my \(physicalSide) hand." : action == .grip ? "Grabbing the can." : "Releasing over the bucket.")
        let intensity = action != .grip && ["recycling","recycling_grasp_hold","incremental_visual_servo_grasp_hold","recycling_carry_release"].contains(proposal?.kind ?? "") ? 10 : ROBTabletopPickPlace.intensity
        try await beforeDispatch?()
        try await accepted { accountedJawCommand {
            let id=gateway.controlGripper(forArm:arm,action:action == .grip ? "hold":"release",force:intensity)
            if id != 0,action != .grip {taskOpeningCommandAtMilliseconds=Date().timeIntervalSince1970*1000}
            return id
        } }
        let settle = proposal?.recyclingParameters?.jawSettleSeconds ?? 1.5
        let end = ProcessInfo.processInfo.systemUptime + settle
        try await wait(settle + 1.5) { ProcessInfo.processInfo.systemUptime >= end }
    }

    @MainActor private func objectCycleAtFront() async throws -> NSDictionary {
        // No travel authority while the object may be present. Only the final
        // explicit empty-jaw readiness restores the bounded reverse route.
        allowsArmTravel = false
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: true)
        try await commandJaw(action: "release", intensity: 2)
        try await awaitReadiness("object_placed", message: "Check the jaws are OPEN. Place the object between them and clear your fingers, then choose Object placed / fingers clear. No closing until you continue.")
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: false)
        try await commandJaw(action: "hold", intensity: 2)
        try await awaitReadiness("receiver_supporting", message: "Grip intensity 2 was accepted, not measured. Check retention before removing support. Support the object in the receiver's hand, then choose Receiver supporting to open. The arm stays stationary.")
        try await holdFrontForGripper()
        try await requireGripperCalibration(allowEmptyCalibration: false)
        try await commandJaw(action: "release", intensity: 2)
        try await awaitReadiness("object_clear", message: "Check the object has released into the receiver's hand and is completely clear of the EMPTY jaws. Choose Object clear / jaws empty to lower the arm.")
        try await settleFront()
        guard let reverse = ROBLeftArmInteractionPlan.executionRoute(from: try measured().positionsRadians.map(\.doubleValue), hanging: true) else {
            throw ROBArmRoutineError.blocked("Left arm left the registered return corridor; no lowering sent.")
        }
        allowsArmTravel = true
        try await move(reverse)
        try await deactivateAtHanging()
        return ["status": "completed", "measured": true, "gripper_measured": false, "gripper_intensity": 2,
            "detail": "Object cycle completed after all three operator readiness signals. Left arm reached hanging and is inactive. Jaw commands were accepted; jaw position, retention and force remain unmeasured."]
    }

    @MainActor private func awaitReadiness(_ stage: String, message: String) async throws {
        try verifyFront()
        interactionStage = stage; readinessConfirmed = false; phase = "waiting \(stage)"
        update(message + " Keep the approving controller open; Stop + hold remains available. Readiness waits are bounded to 45 seconds and the entire operation to 180 seconds.")
        defer { interactionStage = ""; readinessConfirmed = false }
        try await wait(min(45, max(0, deadline - ProcessInfo.processInfo.systemUptime))) { self.readinessConfirmed }
    }

    @MainActor private func holdFrontForGripper() async throws {
        // Settling alone leaves a renewed gateway lease. Drain its replies,
        // then require a confirmed measured-pose hold without removing torque.
        try verifyFront()
        phase = "holding front for gripper"; update("Holding left arm before gripper setup")
        leased = false
        try await wait(1) { self.leaseRenewals.isEmpty }
        try await accepted(requiresConfirmedHold: true) { gateway.priorityHold(forArm: arm) }
        try await settleFront()
    }

    @MainActor private func requireGripperCalibration(allowEmptyCalibration: Bool) async throws {
        try await accepted { gateway.queryGripperState(forArm: arm) }
        let calibrated = gateway.gripperSnapshot(forArm: arm)["calibrationState"] as? String == "command_accepted_unverified"
        if !calibrated {
            guard allowEmptyCalibration else { throw ROBArmRoutineError.blocked("Use Present / open with empty jaws first. Grip/release never recalibrates.") }
            phase = "empty gripper calibration"; update("Calibrating empty left gripper")
            try await accepted { accountedJawCommand { gateway.calibrateGripper(forArm: arm) } }
            // The controller acknowledges dispatch before the physical empty
            // calibration finishes. On ROB, opening after two seconds left
            // the jaws closed; a separate later opening succeeded. Keep the
            // measured hold/freshness checks throughout this conservative
            // interval. Elapsed time still does not verify jaw opening.
            update("Waiting for empty gripper calibration before opening")
            let end = ProcessInfo.processInfo.systemUptime + 10
            try await wait(11) { ProcessInfo.processInfo.systemUptime >= end }
        }
        if allowEmptyCalibration {
            // Rob commissioned this stationary EMPTY-jaw close/open cycle:
            // opening alone after calibration left the fingers closed. The
            // caller follows this gentle close with its fixed opening command.
            // Never prime while gripping or releasing a potentially held can.
            phase = "initializing empty jaws"
            update("Initializing empty left jaws: gentle close before opening")
            try await accepted { accountedJawCommand { gateway.controlGripper(forArm: arm, action: "hold", force: 2) } }
            let end = ProcessInfo.processInfo.systemUptime + 1.5
            try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
        }
    }

    @MainActor private func commandJaw(action: String, intensity: Int) async throws {
        try verifyFront()
        phase = action == "hold" ? "grip object" : "release object"
        update(action == "hold" ? "Closing left gripper on the presented object" : "Opening left gripper; support the object")
        try await accepted { accountedJawCommand { gateway.controlGripper(forArm: arm, action: action, force: intensity) } }
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        try await wait(3) { ProcessInfo.processInfo.systemUptime >= end }
    }

    @MainActor private func deactivateAtHanging() async throws {
        guard ROBArmRoutinePlan.near(try measured().positionsRadians.map(\.doubleValue), Array(repeating: 0, count: 7)) else {
            throw ROBArmRoutineError.blocked("Hanging arrival not measured; torque remains on.")
        }
        positionReady = false; phase = "deactivating"
        try await accepted { gateway.deactivateArm(arm) }
        leased = false
        try await wait(2) { let modes = self.gateway.modes(forArm: self.arm); return modes.count == 7 && modes.allSatisfy({ $0.intValue == 0 }) }
    }

    private func verifyFront() throws {
        try check()
        let modes = gateway.modes(forArm: arm)
        let sample = try measured()
        guard modes.count == 7, modes.allSatisfy({ $0.intValue == 2 }), sample.statuses.count == 7,
              sample.statuses.allSatisfy({ $0.intValue == 2 }),
              ROBLeftArmInteractionPlan.stationaryFrontTarget(sample.positionsRadians.map(\.doubleValue)) != nil else {
            throw ROBArmRoutineError.blocked("Gripper action requires the left arm stationary at the taught front pose in position mode.")
        }
    }

    @MainActor private func settleFront() async throws {
        // Position mode and a single matching read do not prove settling.
        // Recheck distinct fresh samples after changing the arm to a hold.
        try verifyFront()
        var settler = ROBArmRoutineSettler()
        guard let front = ROBLeftArmInteractionPlan.stationaryFrontTarget(try measured().positionsRadians.map(\.doubleValue)) else {
            throw ROBArmRoutineError.blocked("Left arm drifted from the front pose; no jaw command sent.")
        }
        try await wait(2) {
            guard let sample = try? self.measured() else { return false }
            return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                target: front, now: ProcessInfo.processInfo.systemUptime)
        }
    }

    @MainActor private func move(_ route: [Int], preserveTargets: Bool = false) async throws {
        guard let last = route.last else { return }
        // Named routes supply endpoints, not permission to replay their old
        // sweeps through a newly positioned table.
        for index in preserveTargets ? route : [last] {
            guard let target = ROBLeftArmInteractionPlan.target(index:index) else {
                throw ROBArmRoutineError.blocked("The requested arm endpoint is unavailable.")
            }
            let connector = try await workspaceConnector(to:target,name:"Dynamic collision-checked arm connector")
            let previous = proposal; proposal = connector
            do { try await move(connector) }
            catch { proposal = previous; proposalStep = -1; throw error }
            proposal = previous; proposalStep = -1
        }
    }

    private func exposureMatchedServoFeedback(_ frame:ROBArmRoutineVision.Frame)->ROBAmberGatewayTelemetry? {
        let now=Date().timeIntervalSince1970*1000
        return servoTelemetryHistory.filter{$0.generation==generation && $0.sample.sampleAgeAtReceiptMilliseconds<=250 &&
            $0.sample.effectiveSampleAgeMilliseconds<=700}.min {
                abs(now-$0.sample.effectiveSampleAgeMilliseconds-frame.capturedAt)<abs(now-$1.sample.effectiveSampleAgeMilliseconds-frame.capturedAt)
            }.flatMap { entry in
                abs(now-entry.sample.effectiveSampleAgeMilliseconds-frame.capturedAt)<=150 ? entry.sample:nil
            }
    }

    @MainActor private func servoObservation(_ context:ROBRecyclingVisualInspection.ServoContext,model:ROBGhostRobotModel,
        heldSince:Double,openingAt:Double?,tableSupport:Bool=true) async throws->ROBRecyclingVisualInspection.ServoObservation {
        let end=ProcessInfo.processInfo.systemUptime+2.5
        while ProcessInfo.processInfo.systemUptime<end {
            try check();try checkCollisionContext()
            if let frame=vision.snapshot()["face"],frame.sequence>context.lastSequence,frame.capturedAt>=heldSince,
               let historical=exposureMatchedServoFeedback(frame) {
                let current=try measured()
                return try ROBRecyclingVisualInspection.observeIncrementalVisualServo(context:context,model:model,frame:frame,
                    feedback:historical,currentFeedback:current,heldSinceMilliseconds:heldSince,
                    openingCommandAtMilliseconds:openingAt,requireTableSupport:tableSupport,check:{try self.check()})
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        throw ROBGhostMotionError.blocked("No advancing exposure-matched image at the actual held pose; no servo correction or grip sent.")
    }

    private func servoContact(model:ROBGhostRobotModel,can:ROBWorkspaceLocatedObject,map:ROBWorkspaceCollisionSnapshot,
        graspQ:[Double]) throws->(ROBWorkspaceCarriedObject,ROBWorkspaceIntentionalContact) {
        guard let sections=can.sections,sections.valid,
              let tool=model.frames(model.positions(vendorLeft:graspQ))[model.toolLink] else {throw ROBGhostMotionError.blocked("Missing actual-start can/tool geometry for the local contact review.")}
        let inverse=simd_inverse(tool)
        func local(_ a:[Double])->SIMD3<Double> {let p=inverse*SIMD4(a[0],a[1],a[2],1);return SIMD3(p.x,p.y,p.z)}
        let top=local(sections.top),bottom=local(sections.bottom),axis=simd_normalize(top-bottom),radius=sections.diameterMeters/2
        let radial=SIMD3((0..<3).map{radius*sqrt(max(0,1-axis[$0]*axis[$0]))}),low=simd_min(top,bottom)-radial,high=simd_max(top,bottom)+radial
        let center=(low+high)/2,half=(high-low)/2+SIMD3<Double>(repeating:0.003)
        let id=(sections.shapePriorEvidence == nil ? "can-depth-bands-frame-":"assumed-can-shape-prior-frame-")+String(can.sequence)
        let payload=ROBWorkspaceCarriedObject(measurementID:id,centerInToolMeters:[center.x,center.y,center.z],halfExtentsMeters:[half.x,half.y,half.z])
        let contact=ROBWorkspaceIntentionalContact(measurementID:id,observationSequence:can.sequence,capturedAtMilliseconds:can.capturedAt,
            sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,mapFingerprint:map.fingerprint,modelID:model.modelID,
            geometryID:model.geometryID,mappingID:model.selectedMappingID,toolLink:model.toolLink,topCenterMeters:sections.top,
            bottomCenterMeters:sections.bottom,diameterMeters:sections.diameterMeters,firstContactStepIndex:0,
            gripStepIndex:1,releaseStepIndex:nil,stepCount:3,terminalGraspHold:true)
        return(payload,contact)
    }

    @MainActor private func sendCheckedServoSegment(goal:[Double],stage:String,map:ROBWorkspaceCollisionSnapshot,
        model:ROBGhostRobotModel,trial:ROBWorkspaceVisualCalibrationTrial,payload:ROBWorkspaceCarriedObject?=nil,
        contact:ROBWorkspaceIntentionalContact?=nil,contactIndex:Int?=nil,carrying:Bool=false,shortCorrection:Bool=true) async throws->Double {
        try check();try checkCollisionContext();try requireLiveVisualTrial(trial,map:map,model:model)
        let before=try measured(),q=before.positionsRadians.map(\.doubleValue),session=generation,camera=vision.cameraGeneration
        let travel=1.5*zip(q,goal).reduce(0.0,{$0+abs($1.0-$1.1)})
        guard goal.count==7,travel.isFinite,!shortCorrection || travel<=0.030 else {throw ROBGhostMotionError.blocked("Visual servo correction exceeds its30mm full-arm lever bound.")}
        let duration=max(0.8,ROBLeftArmInteractionPlan.duration(from:q,to:goal,padding:0.002) ?? .infinity)
        guard duration<=5 else {throw ROBGhostMotionError.blocked("Visual servo segment exceeds the bounded motion duration.")}
        let step=ROBLeftGestureProposal.Step(positions:goal,seconds:duration,stage:stage),now=Date().timeIntervalSince1970*1000
        let segmentTrial=Self.rebasedVisualTrial(trial,baseline:q)
        let proof=try await Task.detached(priority:.userInitiated){
            try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:[step],map:map,model:model,generation:session,
                sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:segmentTrial,payload:payload,
                intentionalContact:contact,contactStepIndex:contactIndex,carryingAtStart:carrying)
        }.value
        let previous=proposal
        let segment=ROBLeftGestureProposal(id:UUID(),name:stage,kind:"workspace_collision",modelID:model.modelID,referenceID:model.referenceID,
            geometryID:model.geometryID,mappingID:model.selectedMappingID,sessionGeneration:session,baseline:q,poses:[],steps:[step],workspaceCollisionPlan:proof)
        proposal=segment;proposalStep=0
        defer {proposal=previous;proposalStep = -1;reviewedDispatchStart=nil}
        try check();try checkCollisionContext();try requireLiveVisualTrial(segmentTrial,map:map,model:model)
        let start=try measured(),review=ROBReviewedArmDispatchStart(proposalID:segment.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:q,sequence:before.sequence,reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
        guard review.matches(proposalID:segment.id,index:0,generation:session,mapFingerprint:map.fingerprint,
            positions:start.positionsRadians.map(\.doubleValue),sequence:start.sequence,nowUptime:ProcessInfo.processInfo.systemUptime) else {throw ROBGhostMotionError.blocked("The real servo start changed during swept review; no correction sent.")}
        phase=stage;update(stage);reviewedDispatchStart=review;armTravelDispatched=true;recyclingReachDispatched=true;sentPath.append(goal)
        try await accepted{gateway.sendApprovedLeftGestureStep(proposalID:segment.id,index:0,duration:duration,expectedSessionGeneration:session)}
        reviewedDispatchStart=nil;leased=true;lastRenewal=ProcessInfo.processInfo.systemUptime
        let started=ProcessInfo.processInfo.systemUptime;var settler=ROBArmRoutineSettler()
        try await wait(duration+3){
            guard let sample=try?self.measured() else{return false};let positions=sample.positionsRadians.map(\.doubleValue)
            guard 1.5*zip(positions,goal).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {settler=ROBArmRoutineSettler();return false}
            return settler.observe(sequence:sample.sequence,positions:positions,target:goal,now:ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime-started>=duration
        }
        try await holdTaskPosition(goal);taskJawTarget=nil
        return Date().timeIntervalSince1970*1000
    }

    @MainActor private func approachCanThenHoldResult(readyToGrip:Bool,hasObservation:Bool) async throws -> NSDictionary? {
        guard activeApproachCanThenHold else {return nil}
        guard localReceiptCommand != nil,approachCanThenHoldEnabled,readyToGrip,hasObservation,!recyclingGripDispatched else {
            throw ROBGhostMotionError.blocked("Open-jaw approach needs actual observed alignment and its frozen local scope; no close permitted.")
        }
        try check();try checkCollisionContext()
        let q=try measured().positionsRadians.map(\.doubleValue)
        try await holdTaskPosition(q)
        try check()
        let held=try measured().positionsRadians.map(\.doubleValue)
        guard 1.5*zip(q,held).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.003 else {throw ROBGhostMotionError.blocked("The open-jaw approach endpoint did not remain held.")}
        return ["status":"partial_open_jaw_approach_held","approach_can_then_hold":true,"joint_motion_measured":true,
            "measured_positions":held,"endpoint_stopped_and_held":true,"ready_to_grip_observed":true,
            "grip_sent":false,"transfer_completed":false,"placement_verified":false,"batch_completed":0,
            "automatic_recovery_eligible":false,"old_waypoint_resumption_permitted":false,
            "detail":"The complete checked entry and observed alignment reached a measured hold with jaws commanded open. No close, lift, carry or release; ZERO transfers. Physical jaw opening remains unmeasured."]
    }

    @MainActor private func performIncrementalCanGrasp(_ entry:ROBLeftGestureProposal) async throws->NSDictionary {
        guard localReceiptCommand != nil,!nominalEmptyCommissioningStepEnabled,!oneDegreeEmptyCalibrationStepEnabled,
              let map=collisionMap,let model=collisionModel,let trial=entry.workspaceCollisionPlan?.context.visualTrial,
              let can=recyclingCan,can.sections?.shapePriorEvidence?.valid==true,!recyclingGripDispatched,
              entry.recyclingActions?.values.contains(.grip)==true else {
            throw ROBGhostMotionError.blocked("The incremental grasp needs its exact local receipt, real checked entry and selected can; no imported or calibration-only path is accepted.")
        }
        try requireLiveVisualTrial(trial,map:map,model:model)
        let context=try await ROBRecyclingVisualInspection.beginIncrementalVisualServo(model:model,can:can,map:map,trial:trial,gatewayArm:arm,
            feedbackForFrame:{[weak self] in self?.exposureMatchedServoFeedback($0)},check:{try self.check()})
        defer {do{try writeServoEvidence(context)}catch{servoEvidenceWriteError=error.localizedDescription}}
        var held=Date().timeIntervalSince1970*1000,openingAt:Double?
        var jawIdentificationAttempted=false
        _ = try?await servoObservation(context,model:model,heldSince:held,openingAt:nil)
        try await taskJaw(.prepare,at:try measured().positionsRadians.map(\.doubleValue));openingAt=lastTaskOpeningCommandAtMilliseconds
        _ = try await servoObservation(context,model:model,heldSince:held,openingAt:openingAt)
        // Entry is ordinary full-arm/open-jaw observed-space checked. Each
        // actual segment is independently rechecked; no planned q is replayed.
        for step in entry.steps {
            held=try await sendCheckedServoSegment(goal:step.positions,stage:"Checked empty entry; observing actual jaws",
                map:map,model:model,trial:trial,shortCorrection:false)
            let seen=try await servoObservation(context,model:model,heldSince:held,openingAt:openingAt)
            if seen.decision.status=="needsJawIdentification",!jawIdentificationAttempted,
               try await emptyJawIdentificationIsClear(context:context,model:model,map:map,can:can) {
                jawIdentificationAttempted=true
                try await identifyEmptyJawsByObservedOpening(context:context,model:model,heldSince:held)
                openingAt=lastTaskOpeningCommandAtMilliseconds
            }
        }
        var observation=try await servoObservation(context,model:model,heldSince:held,openingAt:openingAt)
        var corrections=0,confirmations=0
        let deadline=ProcessInfo.processInfo.systemUptime+45
        while !observation.decision.readyToGrip,corrections<6,ProcessInfo.processInfo.systemUptime<deadline {
            try check();try requireLiveVisualTrial(trial,map:map,model:model)
            let q=try measured().positionsRadians.map(\.doubleValue)
            if observation.decision.status=="observing" {
                confirmations+=1
                guard confirmations<=3 else {throw ROBGhostMotionError.blocked("Repeated observed jaw frames did not confirm aperture/range/alignment: "+observation.decision.reason)}
                observation=try await servoObservation(context,model:model,heldSince:held,openingAt:openingAt);continue
            }
            confirmations=0
            let goal:[Double]
            if let corrected=observation.decision.jointTarget {goal=corrected;corrections+=1}
            else{
                throw ROBGhostMotionError.blocked("Observed-jaw grasp held: "+observation.decision.reason+" No blind correction or grip was sent.")
            }
            let(_,contact)=try servoContact(model:model,can:can,map:map,graspQ:goal)
            held=try await sendCheckedServoSegment(goal:goal,stage:"Observed jaw-to-can middle correction",map:map,model:model,trial:trial,
                contact:contact,contactIndex:0)
            observation=try await servoObservation(context,model:model,heldSince:held,openingAt:openingAt)
        }
        guard observation.decision.readyToGrip,observation.decision.observation != nil else {
            throw ROBGhostMotionError.blocked("The bounded image-guided approach ended without observed jaw/can alignment; holding without closing.")
        }
        if let held=try await approachCanThenHoldResult(readyToGrip:observation.decision.readyToGrip,hasObservation:observation.decision.observation != nil) {return held}
        let q=try measured().positionsRadians.map(\.doubleValue),positions=model.positions(vendorLeft:q)
        guard let tool=model.toolPosition(positions),let lift=model.solveLeft(target:tool+SIMD3(0,0,0.06),from:positions),
              let lifted=model.toolPosition(lift),abs(lifted.z-tool.z-0.06)<=0.012,hypot(lifted.x-tool.x,lifted.y-tool.y)<=0.015 else {
            throw ROBGhostMotionError.blocked("Observed alignment found, but a real6cm verification-lift endpoint is not admitted. No grip sent.")
        }
        let liftQ=model.vendorLeft(lift),payloadAndContact=try servoContact(model:model,can:can,map:map,graspQ:q)
        let payload=payloadAndContact.0,contact=payloadAndContact.1,session=generation,camera=vision.cameraGeneration
        let liftDuration=max(0.8,ROBLeftArmInteractionPlan.duration(from:q,to:liftQ,padding:0.002) ?? .infinity)
        let closeAndLift:[ROBLeftGestureProposal.Step]=[.init(positions:q,seconds:0.8,stage:"Observed alignment hold"),
            .init(positions:q,seconds:0.8,jawAction:.grip,stage:"Grip can"),.init(positions:liftQ,seconds:liftDuration,stage:"Verification lift")]
        let now=Date().timeIntervalSince1970*1000,closeTrial=Self.rebasedVisualTrial(trial,baseline:q)
        _ = try await Task.detached(priority:.userInitiated){try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:closeAndLift,
            map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:closeTrial,
            payload:payload,intentionalContact:contact)}.value
        // Do not intentionally acquire a can without a complete destination
        // route. This predicted route is geometry only, never grasp evidence.
        guard let destination=recyclingDestination else {throw ROBGhostMotionError.blocked("No observed reachable bucket; remaining EMPTY before grip. A table relay needs its own checked native phase.")}
        let predictedCarry=try ROBCanCarryPreview.make(from:model.positions(vendorLeft:liftQ),can:can,attachedPayload:payload,
            destination:destination,model:model,side:physicalSide,now:Date().timeIntervalSince1970*1000,
            dropUncertaintyMeters:trial.assumedSpatialErrorMeters)
        let predictedSteps=try nativeCarrySteps(predictedCarry,model:model,baseline:liftQ)
        let feasibilitySteps=closeAndLift+predictedSteps
        let feasibilityContact=ROBWorkspaceIntentionalContact(measurementID:contact.measurementID,observationSequence:contact.observationSequence,
            capturedAtMilliseconds:contact.capturedAtMilliseconds,sceneID:contact.sceneID,cameraGeneration:contact.cameraGeneration,
            mapFingerprint:contact.mapFingerprint,modelID:contact.modelID,geometryID:contact.geometryID,mappingID:contact.mappingID,
            toolLink:contact.toolLink,topCenterMeters:contact.topCenterMeters,bottomCenterMeters:contact.bottomCenterMeters,
            diameterMeters:contact.diameterMeters,firstContactStepIndex:contact.firstContactStepIndex,gripStepIndex:1,
            releaseStepIndex:closeAndLift.count+predictedCarry.releaseIndex,stepCount:feasibilitySteps.count)
        _ = try await Task.detached(priority:.userInitiated){try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:feasibilitySteps,
            map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:Date().timeIntervalSince1970*1000,
            trial:closeTrial,payload:payload,intentionalContact:feasibilityContact)}.value
        try check();try requireLiveVisualTrial(trial,map:map,model:model)
        guard 1.5*zip(q,try measured().positionsRadians.map(\.doubleValue)).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.002 else {throw ROBGhostMotionError.blocked("The actual grasp pose changed during contact/lift review; no close sent.")}
        var beforeClose=observation
        try await taskJaw(.grip,at:q,beforeDispatch:{
            // Observe AFTER lift/contact review, stationary hold and gripper
            // query—not merely a fresh source with an old ready decision.
            beforeClose=try await self.servoObservation(context,model:model,heldSince:Date().timeIntervalSince1970*1000,openingAt:openingAt)
            guard beforeClose.decision.readyToGrip,beforeClose.decision.observation != nil else {
                throw ROBGhostMotionError.blocked("Fresh observed jaws/can were no longer aligned immediately before close. Holding without a grip.")
            }
            try ROBControllerArmApproval.shared.markLocalCanCampaignPossiblePayloadHeld()
            self.recyclingGripDispatched=true
        })
        held=try await sendCheckedServoSegment(goal:liftQ,stage:"Verification lift",map:map,model:model,trial:trial,payload:payload,
            contact:contact,contactIndex:2,carrying:true,shortCorrection:false)
        let evidence=try await ROBRecyclingVisualInspection.verifyIncrementalServoLift(context:context,beforeLift:beforeClose,model:model,
            heldSinceMilliseconds:held,observe:{try await self.servoObservation(context,model:model,heldSince:held,openingAt:openingAt,tableSupport:false)},check:{try self.check()})
        lastVisualGraspEvidence=evidence;try writeVisualGraspEvidence(evidence)
        let appearanceSupported=evidence.verdict == .supported && evidence.toolEvidenceSource=="independent_observed_fingers" &&
            evidence.appearanceReferenceSequence != nil
        if appearanceSupported,let support=context.nativeObservedSupport {
            return try await performNativeSupportedCarry(context:context,support:support,can:can,payload:payload,sourceContact:contact,
                map:map,model:model,trial:trial)
        }
        return ["status":"partial_held","motion_completed":false,"transfer_completed":false,"grasp_attempted":true,
            "possible_payload_held":true,"grasp_visually_supported":appearanceSupported,"appearance_verified":appearanceSupported,"possession_measured":false,
            "provisional_co_motion":context.provisionalCoMotion,"visual_servo_verdict":context.provisionalCoMotion ? "provisional_co_motion":evidence.verdict.rawValue,"placement_verified":false,"requires_intervention":!appearanceSupported,
            "detail":"One observed-jaw can grasp and checked verification lift attempted; holding. "+evidence.reason+" ZERO transfers; no carry, release, return or automatic grasp retry."]
    }

    @MainActor private func nativeAttachmentFeedback()throws->ROBNativeCanAttachment.HeldFeedback {
        let sample=try measured(),now=Date().timeIntervalSince1970*1000,q=sample.positionsRadians.map(\.doubleValue)
        let previous=servoTelemetryHistory.reversed().first{entry in
            entry.generation==generation && entry.sample.sequence<sample.sequence &&
            (100...500).contains(sample.receivedAt.timeIntervalSince1970*1000-entry.sample.receivedAt.timeIntervalSince1970*1000)
        }?.sample
        let stationary=previous.map{1.5*zip(q,$0.positionsRadians.map(\.doubleValue)).reduce(0.0){$0+abs($1.0-$1.1)}<=0.002} ?? false
        return .init(physicalArm:physicalSide,gatewayGeneration:generation,sequence:sample.sequence,
            capturedAtMilliseconds:now-sample.effectiveSampleAgeMilliseconds,positions:q,
            motorAgeMilliseconds:sample.effectiveSampleAgeMilliseconds,gripperAgeMilliseconds:sample.effectiveGripperFeedbackAgeMilliseconds,
            jointModes:sample.statuses.map(\.intValue),gatewayModes:gateway.modes(forArm:arm).map(\.intValue),stationary:stationary)
    }
    @MainActor private func nativeAttachmentContext(_ frozen:ROBNativeCanAttachment.Context)throws->ROBNativeCanAttachment.Context {
        try check();try checkCollisionContext()
        let receipt=try requireLocalReceipt()
        guard let liveServo=nativeCarryServoContext,let liveModel=collisionModel else {throw ROBGhostMotionError.blocked("Native attachment has no live observed source context.")}
        try ROBRecyclingVisualInspection.validateNativeObservedSupportContext(liveServo,model:liveModel)
        guard let owner,let map=collisionMap,let model=collisionModel,let body=map.visualCalibrationScope,
              body.bodyContextIsCurrent,let app=UUID(uuidString:receipt["appSessionID"] as? String ?? ""),
              let task=UUID(uuidString:receipt["pendingID"] as? String ?? ""),
              let frame=vision.snapshot()["face"],frame.cameraGeneration==map.cameraGeneration,
              (0...700).contains(Date().timeIntervalSince1970*1000-frame.capturedAt) else {
            throw ROBGhostMotionError.blocked("Native attachment lost its live task/body/source context.")
        }
        return .init(appSessionID:app,taskID:task,ownershipID:owner,physicalArm:physicalSide,bodyMotionIdentity:body.bodyMotionIdentity,
            gatewayGeneration:generation,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,modelID:model.modelID,
            referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            fixedViewIdentity:frozen.fixedViewIdentity,targetIdentity:frozen.targetIdentity,sourceIdentity:frozen.sourceIdentity)
    }
    @MainActor private func nativeCarrySteps(_ preview:ROBCanCarryPreview,model:ROBGhostRobotModel,baseline:[Double])throws->[ROBLeftGestureProposal.Step] {
        var previous=baseline,result:[ROBLeftGestureProposal.Step]=[]
        for step in preview.steps {
            let goal=model.vendorLeft(step.pose)
            guard let minimum=ROBLeftArmInteractionPlan.duration(from:previous,to:goal,padding:0.002),
                  max(step.seconds,minimum).isFinite,max(step.seconds,minimum)<=5 else {
                throw ROBGhostMotionError.blocked("Carry endpoint exceeds current transport limits.")
            }
            result.append(.init(positions:goal,seconds:max(step.seconds,minimum),jawAction:step.jawAction,stage:step.stage));previous=goal
        }
        return result
    }
    @MainActor private func performNativeSupportedCarry(context:ROBRecyclingVisualInspection.ServoContext,
        support:ROBVisualGraspVerifier.ObservedSupport,can:ROBWorkspaceLocatedObject,payload:ROBWorkspaceCarriedObject,
        sourceContact:ROBWorkspaceIntentionalContact,map:ROBWorkspaceCollisionSnapshot,model:ROBGhostRobotModel,
        trial:ROBWorkspaceVisualCalibrationTrial) async throws->NSDictionary {
        try check();try requireLiveVisualTrial(trial,map:map,model:model)
        guard let destination=recyclingDestination,let owner,let body=map.visualCalibrationScope,
              case .visualTrial(let projection)=context.baseline.projection,
              let app=UUID(uuidString:trial.appSessionID),let receipt=try?requireLocalReceipt(),
              let task=UUID(uuidString:receipt["pendingID"] as? String ?? "") else {
            throw ROBGhostMotionError.blocked("Supported grasp held: destination or live native source lineage unavailable.")
        }
        let binding=ROBNativeCanAttachment.Context(appSessionID:app,taskID:task,ownershipID:owner,physicalArm:physicalSide,
            bodyMotionIdentity:body.bodyMotionIdentity,gatewayGeneration:generation,sceneID:map.sceneID,cameraGeneration:map.cameraGeneration,
            modelID:model.modelID,referenceID:model.referenceID,geometryID:model.geometryID,mappingID:model.selectedMappingID,
            fixedViewIdentity:context.baseline.viewIdentity,targetIdentity:context.baseline.targetIdentity,sourceIdentity:projection.frameContractIdentity)
        let baseline=try nativeAttachmentFeedback(),now=Date().timeIntervalSince1970*1000
        let attachment=try ROBNativeCanAttachment.create(support:support,sourceContact:sourceContact,payload:payload,context:binding,
            map:map,model:model,baseline:baseline,nowMilliseconds:now)
        nativeCanAttachment=attachment;nativeCarryServoContext=context
        defer {nativeCarryServoContext=nil;attachment.invalidate(reason:"Native carry phase ended; no persisted restore authority.");nativeCanAttachment=nil;nativeCarryDispatchTicket=nil;reviewedDispatchStart=nil;proposalStep = -1}
        let preview:ROBCanCarryPreview
        do {preview=try ROBCanCarryPreview.make(from:model.positions(vendorLeft:baseline.positions),can:can,attachedPayload:payload,
            destination:destination,model:model,side:physicalSide,now:now,dropUncertaintyMeters:trial.assumedSpatialErrorMeters)}
        catch {return ["status":"partial_held","transfer_completed":false,"possible_payload_held":true,"grasp_visually_supported":true,
            "requires_intervention":true,"detail":"Actual supported grasp held; bucket carry is unreachable: "+error.localizedDescription]}
        let steps=try nativeCarrySteps(preview,model:model,baseline:baseline.positions)
        let contact=ROBWorkspaceIntentionalContact(measurementID:sourceContact.measurementID,observationSequence:sourceContact.observationSequence,
            capturedAtMilliseconds:sourceContact.capturedAtMilliseconds,sceneID:sourceContact.sceneID,cameraGeneration:sourceContact.cameraGeneration,
            mapFingerprint:sourceContact.mapFingerprint,modelID:sourceContact.modelID,geometryID:sourceContact.geometryID,mappingID:sourceContact.mappingID,
            toolLink:sourceContact.toolLink,topCenterMeters:sourceContact.topCenterMeters,bottomCenterMeters:sourceContact.bottomCenterMeters,
            diameterMeters:sourceContact.diameterMeters,firstContactStepIndex:0,gripStepIndex:nil,releaseStepIndex:preview.releaseIndex,
            stepCount:steps.count,verifiedAttachment:attachment.record)
        let carryTrial=Self.rebasedVisualTrial(trial,baseline:baseline.positions),session=generation,camera=vision.cameraGeneration
        let proof=try await Task.detached(priority:.userInitiated){try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(
            baseline:baseline.positions,steps:steps,map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
            nowMilliseconds:now,trial:carryTrial,payload:payload,intentionalContact:contact,carryingAtStart:true)}.value
        let carry=try ROBLeftGestureCompiler.compile(kind:"recycling_carry_release",name:"Observed supported can to observed bucket",
            poses:[],model:model,baseline:baseline.positions,generation:session,workspaceCollisionPlan:proof,collisionMap:map,
            collisionSceneID:map.sceneID,collisionCameraGeneration:camera,visualCalibrationTrial:carryTrial,
            verifiedAttachment:attachment.record,nowMilliseconds:Date().timeIntervalSince1970*1000)
        try attachment.bind(proposal:carry,currentContext:try nativeAttachmentContext(binding),map:map,model:model,
            feedback:try nativeAttachmentFeedback(),nowMilliseconds:Date().timeIntervalSince1970*1000)
        proposal=carry
        for (index,step) in carry.steps.enumerated() {
            // Post-release travel requires independently verified EMPTY and
            // landing. Command acceptance never admits that retreat.
            guard index<=preview.releaseIndex else{break}
            try check();try requireLiveVisualTrial(carryTrial,map:map,model:model)
            let feedback=try nativeAttachmentFeedback(),checkedAt=Date().timeIntervalSince1970*1000
            let segmentTrial=Self.rebasedVisualTrial(carryTrial,baseline:feedback.positions)
            let segment=try await Task.detached(priority:.userInitiated){try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(
                baseline:feedback.positions,steps:[step],map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
                nowMilliseconds:checkedAt,trial:segmentTrial,payload:payload,intentionalContact:contact,contactStepIndex:index,carryingAtStart:true)}.value
            let fresh=try nativeAttachmentFeedback()
            nativeCarryDispatchTicket=try attachment.prepareDispatch(index:index,segmentProof:segment,currentContext:try nativeAttachmentContext(binding),
                map:map,model:model,feedback:fresh,nowMilliseconds:Date().timeIntervalSince1970*1000,nowUptime:ProcessInfo.processInfo.systemUptime)
            reviewedDispatchStart=ROBReviewedArmDispatchStart(proposalID:carry.id,index:index,generation:session,mapFingerprint:map.fingerprint,
                positions:feedback.positions,sequence:feedback.sequence,reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
            proposalStep=index;phase="native checked carry \(index)";armTravelDispatched=true;recyclingReachDispatched=true;sentPath.append(step.positions)
            let started=ProcessInfo.processInfo.systemUptime
            try await accepted{gateway.sendApprovedLeftGestureStep(proposalID:carry.id,index:index,duration:step.seconds,expectedSessionGeneration:session)}
            nativeCarryDispatchTicket=nil;reviewedDispatchStart=nil;leased=true;lastRenewal=ProcessInfo.processInfo.systemUptime
            var settler=ROBArmRoutineSettler()
            try await wait(step.seconds+3){
                guard let sample=try?self.measured() else{return false}
                return settler.observe(sequence:sample.sequence,positions:sample.positionsRadians.map(\.doubleValue),target:step.positions,
                    now:ProcessInfo.processInfo.systemUptime) && ProcessInfo.processInfo.systemUptime-started>=step.seconds
            }
            try await holdTaskPosition(step.positions)
            if step.jawAction == .release {
                try await taskJaw(.release,at:step.positions,beforeDispatch:{
                    let held=try self.nativeAttachmentFeedback(),releaseNow=Date().timeIntervalSince1970*1000
                    let releaseTrial=Self.rebasedVisualTrial(carryTrial,baseline:held.positions)
                    let releaseProof=try await Task.detached(priority:.userInitiated){try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(
                        baseline:held.positions,steps:[step],map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,
                        nowMilliseconds:releaseNow,trial:releaseTrial,payload:payload,intentionalContact:contact,contactStepIndex:index,carryingAtStart:true)}.value
                    let fresh=try self.nativeAttachmentFeedback(),current=try self.nativeAttachmentContext(binding)
                    let ticket=try attachment.prepareReleaseCommand(segmentProof:releaseProof,currentContext:current,map:map,model:model,feedback:fresh,
                        nowMilliseconds:Date().timeIntervalSince1970*1000,nowUptime:ProcessInfo.processInfo.systemUptime)
                    guard attachment.matchesAndConsumeReleaseCommand(ticket,proposalID:carry.id,proposalSHA256:carry.fingerprint,
                        currentContext:try self.nativeAttachmentContext(binding),map:map,model:model,feedback:try self.nativeAttachmentFeedback(),
                        nowMilliseconds:Date().timeIntervalSince1970*1000,nowUptime:ProcessInfo.processInfo.systemUptime) else {
                        throw ROBGhostMotionError.blocked("Fresh settled native release admission failed; jaws remain unchanged.")
                    }
                })
                let releaseAt=lastTaskOpeningCommandAtMilliseconds ?? Date().timeIntervalSince1970*1000
                // Retain actual advancing raw observations, including failure
                // or occlusion. No tracker disappearance is EMPTY/landing proof.
                for _ in 0..<3 {
                    do {_ = try await servoObservation(context,model:model,heldSince:releaseAt,openingAt:releaseAt,tableSupport:false)}
                    catch {try check();context.observations.append(["stage":"post_release_raw_observation_unavailable","detail":error.localizedDescription,
                        "captured_at_ms":Date().timeIntervalSince1970*1000,"placement_verified":false,"empty_verified":false])}
                    try check()
                }
                return ["status":"released_unverified_held","motion_completed":false,"transfer_completed":false,
                    "possible_payload_held":true,"grasp_visually_supported":true,"release_command_accepted":true,
                    "placement_verified":false,"requires_intervention":true,
                    "detail":"Checked supported-can carry reached the contained bucket opening and a separately admitted jaw release was accepted. Raw post-release observations retained; detachment and landing remain unverified. Holding; ZERO credited transfers and no EMPTY retreat."]
            }
        }
        throw ROBGhostMotionError.blocked("Native carry ended without a verified release phase; holding possible payload.")
    }

    private var lastTaskOpeningCommandAtMilliseconds:Double? {
        get {taskOpeningCommandAtMilliseconds}
    }
    private func writeServoEvidence(_ context:ROBRecyclingVisualInspection.ServoContext)throws {
        guard !lastRecordingPath.isEmpty else{return}
        let directory=URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("visual-servo")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var frames:[[String:Any]]=[]
        for f in context.retainedFrames {
            let rgb="frame-\(f.sequence).rgb888",depth="frame-\(f.sequence).u16le"
            let little=f.depthMillimeters.map{$0.littleEndian}
            let raw=little.withUnsafeBytes{Data($0)}
            for(name,data)in[(rgb,f.rgb),(depth,raw)]{let url=directory.appendingPathComponent(name);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
            frames.append(["sequence":NSNumber(value:f.sequence),"captured_at_ms":f.capturedAtMilliseconds,"width":f.width,"height":f.height,
                "scope_identity":f.scopeIdentity,"K":[f.fx,f.fy,f.cx,f.cy],"joint_positions":f.jointPositions,
                "joint_captured_at_ms":f.jointCapturedAtMilliseconds,"rgbPath":rgb,"rgbSHA256":ROBGhostRobotModel.hash(f.rgb),
                "depthPath":depth,"depthSHA256":ROBGhostRobotModel.hash(raw)])
        }
        let data=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"kind":"observed_jaw_incremental_can_attempt",
            "registrationVerified":false,"possessionMeasured":false,"appearanceVerified":context.nativeObservedSupport != nil,"provisionalCoMotion":context.provisionalCoMotion,"observations":context.observations,"frames":frames],options:[.sortedKeys])
        let path=directory.appendingPathComponent("evidence.json");try data.write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }

    @MainActor private func emptyJawIdentificationIsClear(context:ROBRecyclingVisualInspection.ServoContext,model:ROBGhostRobotModel,
        map:ROBWorkspaceCollisionSnapshot,can:ROBWorkspaceLocatedObject)async throws->Bool {
        guard !recyclingGripDispatched,!jawSetupDispatchUncertain,let frame=vision.snapshot()["face"],frame.handsClear,
              let k=frame.intrinsics,let depth=frame.depth,
              case .visualTrial(let projection)=context.baseline.projection,
              let tip=model.toolPosition(model.positions(vendorLeft:try measured().positionsRadians.map(\.doubleValue))),
              simd_distance(tip,can.point)>=0.20 else{return false}
        let p=simd_inverse(projection.cameraToModel)*SIMD4(tip.x,tip.y,tip.z,1)
        guard p.z>0 else{return false}
        let u=(k.fx*p.x/p.z+k.cx)/Double(depth.width),v=(k.fy*p.y/p.z+k.cy)/Double(depth.height),b=context.targetBox
        // Entire uncertain search region must be separate from the selected
        // object; this is additional to the current full-arm observed-space proof.
        guard u+0.22<b[0]-0.03 || u-0.22>b[2]+0.03 || v+0.22<b[1]-0.03 || v-0.22>b[3]+0.03 else{return false}
        let(observation,observedFrame)=try await vision.observeWorkspace()
        try check()
        guard (0...700).contains(Date().timeIntervalSince1970*1000-observedFrame.capturedAt),observedFrame.handsClear,
              try ROBFixedHeadCalibrationWindowController.shared.scope(model:model,frame:observedFrame)==context.baseline.scope else{return false}
        let boxes=(observation.cans ?? [observation.can]).filter{$0.visuallyUsable}.map(\.box)
        guard !boxes.isEmpty,boxes.allSatisfy({box in u+0.22<box[0]-0.03 || u-0.22>box[2]+0.03 || v+0.22<box[1]-0.03 || v-0.22>box[3]+0.03}) else{return false}
        let q=try measured().positionsRadians.map(\.doubleValue),now=Date().timeIntervalSince1970*1000,session=generation,camera=vision.cameraGeneration
        guard let trial=try visualTrial(map:map,model:model,baseline:q) else{return false}
        _ = try await Task.detached(priority:.userInitiated){
            try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:[.init(positions:q,seconds:0.8,stage:"Empty jaw identity hold")],
                map:map,model:model,generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:trial)
        }.value
        try check();try requireLiveVisualTrial(trial,map:map,model:model)
        return 1.5*zip(q,try measured().positionsRadians.map(\.doubleValue)).reduce(0.0,{$0+abs($1.0-$1.1)})<=0.002
    }

    @MainActor private func identifyEmptyJawsByObservedOpening(context:ROBRecyclingVisualInspection.ServoContext,
        model:ROBGhostRobotModel,heldSince:Double) async throws {
        guard !recyclingGripDispatched,!jawSetupDispatchUncertain,ROBGripperStartupCalibration.shared.calibrationReady(forArm:arm) else {throw ROBGhostMotionError.blocked("Empty jaw identity setup lacks stationary startup readiness.")}
        // ONE gentle empty close/open, no calibration and no arm target. If it
        // cannot be visually resolved, remain stopped rather than infer opening.
        try ROBControllerArmApproval.shared.markLocalCanCampaignPossiblePayloadHeld()
        jawSetupDispatchUncertain=true;servoPossiblePayloadUncertain=true
        try await accepted{accountedJawCommand{gateway.controlGripper(forArm:arm,action:"hold",force:2)}}
        let closed=ProcessInfo.processInfo.systemUptime+1.5
        try await wait(2){ProcessInfo.processInfo.systemUptime>=closed}
        _ = try await servoObservation(context,model:model,heldSince:heldSince,openingAt:nil)
        try await accepted{accountedJawCommand{
            let id=gateway.controlGripper(forArm:arm,action:"release",force:10)
            if id != 0 {taskOpeningCommandAtMilliseconds=Date().timeIntervalSince1970*1000};return id
        }}
        let opened=ProcessInfo.processInfo.systemUptime+1.5
        try await wait(2){ProcessInfo.processInfo.systemUptime>=opened}
        let seen=try await servoObservation(context,model:model,heldSince:heldSince,openingAt:taskOpeningCommandAtMilliseconds)
        guard seen.decision.observation != nil else {throw ROBGhostMotionError.blocked("Empty close/open finished without uniquely observed jaw opening. Holding; no grasp or automatic retry.")}
        try ROBControllerArmApproval.shared.recordLocalCanCampaignSupportedRelease()
        jawSetupDispatchUncertain=false;servoPossiblePayloadUncertain=false
    }

    @MainActor private func move(_ proposal: ROBLeftGestureProposal) async throws {
        try checkCollisionContext()
        guard let map = collisionMap, let model = collisionModel else {
            throw ROBArmRoutineError.blocked("No fresh scene map is available for the complete arm sweep.")
        }
        let session = generation, camera = vision.cameraGeneration
        let payload = proposal.workspaceCollisionPlan?.payload
        let visual=proposal.workspaceCollisionPlan?.context.visualTrial
        let recycling=["recycling","recycling_grasp_hold"].contains(proposal.kind)
        if let visual {try requireLiveVisualTrial(visual,map:map,model:model)}
        let reviewTime = Date().timeIntervalSince1970*1000
        _ = try await Task.detached(priority:.userInitiated) {
            if let frozen = proposal.workspaceCollisionPlan {
                if let visual {
                    try frozen.validateVisualCalibrationTrial(map:map,model:model,generation:session,sceneID:map.sceneID,
                        cameraGeneration:camera,nowMilliseconds:reviewTime,trial:visual)
                }else{
                    try frozen.validate(map:map,model:model,generation:session,sceneID:map.sceneID,
                        cameraGeneration:camera,nowMilliseconds:reviewTime)
                }
            }
            if let visual {
                return try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:proposal.baseline,steps:proposal.steps,map:map,model:model,
                    generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:reviewTime,trial:visual,payload:payload,
                    intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact)
            }
            return try ROBWorkspaceCollisionPlan.review(baseline:proposal.baseline,steps:proposal.steps,map:map,model:model,
                generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:reviewTime,payload:payload,
                intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact)
        }.value
        var carrying = false
        var visualContext: ROBRecyclingVisualInspection.Context?
        var graspSupported = false
        for (index, step) in proposal.steps.enumerated() {
            // A single already-planned vertical lift may gather evidence. No
            // transfer/release continues on command acceptance alone.
            if recycling, carrying, !graspSupported, step.stage != "Verification lift" {
                guard let context=visualContext else {
                    throw ROBArmRoutineError.blocked("No before-close visual grasp baseline; holding the possible payload.")
                }
                let evidence=try await ROBRecyclingVisualInspection.verifyAfterLift(context:context,model:model,gatewayArm:arm,check:{try self.check()})
                lastVisualGraspEvidence=evidence
                try writeVisualGraspEvidence(evidence)
                guard evidence.verdict == .supported else {
                    try await holdTaskPosition(try measured().positionsRadians.map(\.doubleValue))
                    throw ROBArmRoutineError.blocked("Grasp \(evidence.verdict.rawValue): \(evidence.reason) Holding; no carry or automatic reopening.")
                }
                graspSupported=true
                ROBWorkspaceSearch.shared.announce?("I have visual support for the grasp.")
            }
            reviewedDispatchStart = nil
            try check(); try checkCollisionContext()
            let reviewedSample = try measured(), q = reviewedSample.positionsRadians.map(\.doubleValue)
            guard let minimum = ROBLeftArmInteractionPlan.duration(from: q, to: step.positions), step.seconds >= minimum - 0.05 else {
                throw ROBArmRoutineError.blocked("Measured start drift exceeds the reviewed timing; hold requested.")
            }
            let now = Date().timeIntervalSince1970*1000
            if let visual {try requireLiveVisualTrial(visual,map:map,model:model)}
            // Each segment binds its ACTUAL fresh start. Later waypoints are
            // never compared to the initial full-path baseline.
            let segmentVisual=visual.map{Self.rebasedVisualTrial($0,baseline:q)}
            _ = try await Task.detached(priority:.userInitiated) {
                if let segmentVisual {
                    return try ROBWorkspaceCollisionPlan.reviewVisualCalibrationTrial(baseline:q,steps:[step],map:map,model:model,
                        generation:session,sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,trial:segmentVisual,payload:payload,
                        intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact,
                        contactStepIndex:proposal.workspaceCollisionPlan?.intentionalContact == nil ? nil : index,carryingAtStart:carrying)
                }
                return try ROBWorkspaceCollisionPlan.review(baseline:q,steps:[step],map:map,model:model,generation:session,
                    sceneID:map.sceneID,cameraGeneration:camera,nowMilliseconds:now,payload:payload,
                    intentionalContact:proposal.workspaceCollisionPlan?.intentionalContact,
                    contactStepIndex:proposal.workspaceCollisionPlan?.intentionalContact == nil ? nil : index,
                    carryingAtStart:carrying)
            }.value
            let dispatchReview = ROBReviewedArmDispatchStart(proposalID:proposal.id,index:index,generation:session,
                mapFingerprint:map.fingerprint,positions:q,sequence:reviewedSample.sequence,
                reviewCompletedAtUptime:ProcessInfo.processInfo.systemUptime)
            try check(); try checkCollisionContext()
            let admissionSample = try measured()
            if let visual {try requireLiveVisualTrial(visual,map:map,model:model)}
            guard dispatchReview.matches(proposalID:proposal.id,index:index,generation:session,mapFingerprint:map.fingerprint,
                positions:admissionSample.positionsRadians.map(\.doubleValue),sequence:admissionSample.sequence,
                nowUptime:ProcessInfo.processInfo.systemUptime) else {
                throw ROBArmRoutineError.blocked("The arm moved while its actual-start sweep was checked. Hold and review the new start before dispatch.")
            }
            proposalStep = index; phase = "gesture step \(index)"; update("\(proposal.name): step \(index + 1)/\(proposal.steps.count)")
            let started = ProcessInfo.processInfo.systemUptime
            sentPath.append(step.positions)
            armTravelDispatched = true
            if recycling,1.5*zip(q,step.positions).reduce(0.0,{$0+abs($1.0-$1.1)})>0.000001 {recyclingReachDispatched=true}
            do {
                reviewedDispatchStart = dispatchReview
                defer { reviewedDispatchStart = nil }
                try await accepted { gateway.sendApprovedLeftGestureStep(proposalID: proposal.id, index: index,
                    duration: step.seconds, expectedSessionGeneration: generation) }
            }
            leased = true; lastRenewal = ProcessInfo.processInfo.systemUptime
            var settler = ROBArmRoutineSettler()
            try await wait(step.seconds + 3) {
                guard let sample = try? self.measured() else { return false }
                return settler.observe(sequence: sample.sequence, positions: sample.positionsRadians.map(\.doubleValue),
                    target: step.positions, now: ProcessInfo.processInfo.systemUptime)
                    && ProcessInfo.processInfo.systemUptime - started >= step.seconds
            }
            proposalStep = -1
            if step.jawAction == .grip,recycling {
                guard let can=recyclingCan else { throw ROBArmRoutineError.blocked("The fresh can identity was lost before closing.") }
                try await holdTaskPosition(step.positions)
                if let visual {
                    try requireLiveVisualTrial(visual,map:map,model:model)
                    visualContext=try await ROBRecyclingVisualInspection.beginVisualCalibrationTrial(
                        model:model,can:can,map:map,trial:visual,gatewayArm:arm,check:{try self.check()})
                } else {
                    visualContext=try await ROBRecyclingVisualInspection.begin(model:model,can:can,gatewayArm:arm,check:{try self.check()})
                }
            }
            if step.jawAction == .grip,recycling { recyclingGripDispatched=true }
            if let action = step.jawAction { try await taskJaw(action, at: step.positions) }
            if step.jawAction == .grip { carrying = true }
            if step.jawAction == .release { carrying = false }
        }
        if proposal.kind=="recycling_grasp_hold" {
            guard visual != nil,carrying,let context=visualContext,proposal.steps.last?.stage=="Verification lift",
                  !proposal.steps.contains(where:{$0.jawAction == .release}) else {
                throw ROBArmRoutineError.blocked("The partial grasp trial lost its explicit terminal-lift/holding state; hold requested.")
            }
            let evidence=try await ROBRecyclingVisualInspection.verifyAfterLift(context:context,model:model,gatewayArm:arm,check:{try self.check()})
            lastVisualGraspEvidence=evidence;try writeVisualGraspEvidence(evidence)
            try await holdTaskPosition(try measured().positionsRadians.map(\.doubleValue))
            guard evidence.verdict == .supported else {
                throw ROBArmRoutineError.blocked("Grasp \(evidence.verdict.rawValue): \(evidence.reason) Holding the possible payload; no carry, release or automatic reopening.")
            }
        }
    }

    private func monitor() {
        guard isRunning, failure == nil else { return }
        do {
            try check()
            if leased { try checkCollisionContext() }
            if generation > 0, !inactiveWorkspaceSearch { try record(measured()) }
            let now = ProcessInfo.processInfo.systemUptime
            guard !leaseRenewals.values.contains(where: { now - $0 > 1 }) else { throw ROBArmRoutineError.blocked("Left-arm lease acknowledgement timed out.") }
            if leased, now - lastRenewal >= 0.4 {
                lastRenewal = now
                let id = gateway.renewLease(forArm: arm, leaseMilliseconds: 1500)
                guard id != 0 else { throw ROBArmRoutineError.blocked("Left-arm motion lease refused.") }
                leaseRenewals[id] = now
            }
        } catch is ROBPassiveFeedbackPause { return } catch { abort(error.localizedDescription) }
    }

    private func writeVisualGraspEvidence(_ evidence: ROBVisualGraspVerifier.Evidence) throws {
        guard !lastRecordingPath.isEmpty else {throw ROBArmRoutineError.blocked("No recording is available for visual grasp evidence.")}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        try encoder.encode(evidence).write(to:URL(fileURLWithPath:lastRecordingPath).deletingPathExtension().appendingPathExtension("grasp-visual.json"),options:.atomic)
    }

    private func writeEstimatedRecording(proof: ROBEstimatedArmCalibrationPlan, proposal: ROBLeftGestureProposal) throws {
        guard !lastRecordingPath.isEmpty else { throw ROBArmRoutineError.blocked("No local calibration recording is open.") }
        let base = URL(fileURLWithPath:lastRecordingPath).deletingPathExtension()
        try proposal.encoded().write(to:base.appendingPathExtension("proposal.json"),options:.atomic)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(proof).write(to:base.appendingPathExtension("estimated-calibration.json"),options:.atomic)
    }

    private func beginRecording(_ command: String) throws {
        let folder = try recordingDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Cerebro/\(physicalSide == "left" ? "Left" : "Right")ArmTrials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingCommand = physicalSide == "right" && command.hasPrefix("left_") ? "right_" + command.dropFirst(5) : command
        let url = folder.appendingPathComponent("\(recordingCommand)-\(UUID().uuidString).csv")
        try Data("elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n".utf8).write(to: url, options: .atomic)
        log = try FileHandle(forWritingTo: url); try log?.seekToEnd()
        lastRecordingPath = url.path; logStarted = ProcessInfo.processInfo.systemUptime
        if let proposal { try proposal.encoded().write(to: url.deletingPathExtension().appendingPathExtension("proposal.json"), options: .atomic) }
        if let active = activeEstimated { try writeEstimatedRecording(proof:active.proof,proposal:active.proposal) }
        lastSequence = 0; previousCurrents = nil; peakJump = 0; sampleCount = 0
        delayedSampleCount = 0; maxDelayedSampleAge = 0
    }

    private func record(_ sample: ROBAmberGatewayTelemetry) throws {
        guard log != nil, sample.sequence > lastSequence else { return }
        let deliveredAge = sample.effectiveSampleAgeMilliseconds
        guard sample.sampleAgeAtReceiptMilliseconds <= 250, deliveredAge.isFinite, sample.positionsRadians.count == 7,
              sample.positionsRadians.allSatisfy({ $0.doubleValue.isFinite }),
              sample.currents.count == 7, sample.currents.allSatisfy({ $0.doubleValue.isFinite }) else {
            throw ROBArmRoutineError.blocked("Invalid or stale left-arm current recording; hold requested.")
        }
        if deliveredAge > 250 {
            // Notifications carry the packet captured on the gateway queue,
            // not necessarily the latest packet after a busy UI resumes.
            // Retain that historical current sample only if actual live motor
            // AND gripper feedback is fresh and strictly newer. All live
            // admission, session checks and the independent lease stay intact.
            try check()
            let current = try measured()
            guard current.sequence > sample.sequence else {
                throw ROBArmRoutineError.blocked("Left-arm telemetry stopped advancing; hold requested.")
            }
            delayedSampleCount += 1; maxDelayedSampleAge = max(maxDelayedSampleAge, deliveredAge)
        }
        let currents = sample.currents.map(\.doubleValue)
        let changes = zip(currents, previousCurrents ?? currents).map { $0 - $1 }
        let jump = changes.map(abs).max() ?? 0
        let sourceGeneration=(gateway.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value ?? 0
        let before=previousCurrentEvidence,currentEvidence=ROBArmCurrentSpikeRecording.Sample(sample,sessionGeneration:sourceGeneration)
        peakJump = max(peakJump, jump); previousCurrents = currents; lastSequence = sample.sequence; sampleCount += 1
        previousCurrentEvidence=currentEvidence
        let tripped=currentLimit>0 && jump>currentLimit
        let tripMessage="\(physicalSide.uppercased())-arm current jump \(jump) exceeded \(currentLimit) raw units; hold requested. Inspect the recording before retrying."
        if tripped,currentSpikeEvidence==nil {
            let path=proposal,model=collisionModel ?? localReceiptModel,frame=vision.snapshot()["face"]
            let step=path.flatMap{(0..<$0.steps.count).contains(proposalStep) ? $0.steps[proposalStep]:nil}
            currentSpikeEvidence = .init(configuredJumpLimitRaw:currentLimit,currentDeltaRaw:changes,peakJumpRaw:jump,
                triggerJointIndices:changes.indices.filter{abs(changes[$0])>currentLimit}.map{$0+1},before:before,trigger:currentEvidence,
                detectedAtMilliseconds:Date().timeIntervalSince1970*1000,detectedAtUptime:ProcessInfo.processInfo.systemUptime,
                physicalArm:physicalSide,gatewayArm:arm,phase:phase,sessionGeneration:generation,
                summarySHA256:ROBGhostRobotModel.hash(Data(summary.utf8)),proposalID:path?.id.uuidString,proposalSHA256:path?.fingerprint,
                proposalKind:path?.kind,stepIndex:proposalStep,proposedStepPositionsRadians:step?.positions,proposedStepSeconds:step?.seconds,
                mapFingerprint:collisionMap?.fingerprint,modelID:path?.modelID ?? model?.modelID,referenceID:path?.referenceID ?? model?.referenceID,
                geometryID:path?.geometryID ?? model?.geometryID,mappingID:path?.mappingID ?? model?.selectedMappingID,
                cameraGeneration:vision.cameraGeneration.uuidString,cameraFrameGeneration:frame?.cameraGeneration.uuidString,
                cameraFrameSequence:frame?.sequence,cameraFrameCapturedAtMilliseconds:frame?.capturedAt,
                runtimeCalibrationIdentity:frame?.intrinsics?.runtimeCalibration?.identity,
                bodyMotionIdentity:ROBFixedHeadBodyMotionIdentity.currentIdentity,estimatedCameraProjectionIdentity:collisionMap?.estimatedCameraProjectionIdentity,
                possiblePayloadHeldAtTrigger:recyclingGripDispatched || servoPossiblePayloadUncertain)
            // Queue the existing priority hold BEFORE diagnostic disk writes.
            // Remaining targets/lease renewals stop via the existing latch.
            abort(tripMessage)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - logStarted
        let rows = (0..<7).map { "\(elapsed),\(sample.sequence),\(physicalSide),\(arm),\($0 + 1),\(sample.positionsRadians[$0]),\(currents[$0]),\(changes[$0]),\(deliveredAge),\(phase)\n" }.joined()
        try log?.write(contentsOf: Data(rows.utf8))
        if tripped {throw ROBArmRoutineError.blocked(tripMessage)}
    }

    private func abort(_ message: String) {
        invalidateEstimatedPreview(reason:message)
        activeEstimated = nil
        guard isRunning, failure == nil else { return }
        failure = message; task?.cancel(); reviewedDispatchStart = nil
        if Thread.isMainThread {MainActor.assumeIsolated {nativeCanAttachment?.invalidate(reason:message);nativeCarryDispatchTicket=nil}}
        interactionStage = ""; readinessConfirmed = false
        if !Self.neckOnlyCommands.contains(activeCommand) {
            let requested=ProcessInfo.processInfo.systemUptime
            if currentSpikeEvidence != nil {currentSpikePostStopDeadline=requested+1}
            let commandID=gateway.priorityHold(forArm:arm)
            if currentSpikeEvidence != nil {
                currentSpikeEvidence?.holds.append(.init(commandID:commandID,requestedAtMilliseconds:Date().timeIntervalSince1970*1000,requestedAtUptime:requested))
                persistCurrentSpikeEvidence()
            }
        }
        leased = false
        update(message)
    }

    private func persistCurrentSpikeEvidence() {
        guard let event=currentSpikeEvidence,!lastRecordingPath.isEmpty else{return}
        do {currentSpikeEvidencePath=try ROBArmCurrentSpikeRecording.write(event,recordingPath:lastRecordingPath,proposal:proposal).path}
        catch {currentSpikeEvidenceWriteError=error.localizedDescription}
    }

    private func recordCurrentSpikePostStop(_ sample:ROBAmberGatewayTelemetry) {
        guard isRunning,!currentSpikeCollectionFinished,let end=currentSpikePostStopDeadline,
              ProcessInfo.processInfo.systemUptime<=end,sample.arm==arm,let event=currentSpikeEvidence,
              sample.sequence>(event.postStopSamples.last?.sequence ?? event.trigger.sequence),event.postStopSamples.count<64 else{return}
        let sourceGeneration=(gateway.connectionSnapshot()["sessionGeneration"]as?NSNumber)?.uint64Value ?? 0
        currentSpikeEvidence?.postStopSamples.append(.init(sample,sessionGeneration:sourceGeneration))
    }

    private func finish(_ result: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
        if currentSpikeEvidence != nil,!currentSpikeCollectionFinished {
            guard currentSpikeCompletionTask==nil else{return}
            timer?.invalidate();timer=nil
            let end=currentSpikePostStopDeadline ?? ProcessInfo.processInfo.systemUptime
            currentSpikeCompletionTask=Task { @MainActor [weak self] in
                guard let self else{return}
                let remaining=max(0,end-ProcessInfo.processInfo.systemUptime)
                if remaining>0 {try? await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}
                self.currentSpikeCollectionFinished=true
                self.currentSpikeEvidence?.postStopCollectionCompleted=true
                self.currentSpikeEvidence?.postStopCollectionCompletedAtMilliseconds=Date().timeIntervalSince1970*1000
                self.persistCurrentSpikeEvidence()
                self.currentSpikeCompletionTask=nil
                self.finish(result,completion:completion)
            }
            return
        }
        timer?.invalidate(); timer = nil
        let localJob=localReceiptCommand != nil
        let recoveryCommand=localReceiptCommand
        let recoveryCampaignID=localReceiptEvidence?["standingCampaignID"] as? String
        let recoveryReason=localCampaignRecoveryReason
        let canAutoRecover=currentSpikeEvidence==nil && localJob && recoveryReason != nil && recoveryCampaignID != nil &&
            !recyclingGripDispatched && !jawSetupDispatchUncertain && !servoPossiblePayloadUncertain &&
            !nominalEmptyCommissioningStepEnabled && !oneDegreeEmptyCalibrationStepEnabled && !activeHoldAfterInitialEmptyLift && !activeApproachCanThenHold
        var preserveLocalReceipt=false
        if localJob,!armTravelDispatched,!recyclingReachDispatched,!jawCommandDispatched,!jawSetupDispatchUncertain,failure==nil {
            let perception=["not_found","not_localized","not_reachable","needs_help"].contains(result["status"] as? String ?? "") || localReceiptPerceptionFailure
            if perception {
                do {
                    try check();_ = try requireLocalReceipt()
                    for side in ["left","right"] {
                        guard let sample=gateway.telemetry(forArm:side),sample.effectiveSampleAgeMilliseconds<=250,
                              sample.effectiveGripperFeedbackAgeMilliseconds<=250 else {throw ROBArmRoutineError.blocked("Feedback lost before retaining the receipt.")}
                    }
                    preserveLocalReceipt=true
                }catch{}
            }
        }
        if currentSpikeEvidence==nil,!Self.neckOnlyCommands.contains(activeCommand),leased || result["status"] as? String=="blocked" { _ = gateway.priorityHold(forArm:arm) }
        leased = false
        if activeHoldAfterInitialEmptyLift || currentSpikeEvidence != nil || ["tabletop", "recycling", "recycling_grasp_hold", "estimated_calibration", "initial_empty_visual_retreat", "nominal_empty_commissioning", "one_degree_empty_calibration", "incremental_visual_servo_grasp_hold", "recycling_carry_release"].contains(proposal?.kind ?? "") {
            // A failed close/open may leave a payload. Never offer the old
            // empty-arm reverse/recovery automatically for a recycling task.
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        } else if proposal != nil, result["status"] as? String != "completed", sentPath.count > 1 {
            recoveryPath = sentPath; recoveryGeneration = generation
        } else if result["status"] as? String == "completed" {
            recoveryPath = []; recoveryGeneration = 0; offeredRecovery = nil
        }
        var output = result as! [String: Any]
        output["physical_arm"]=physicalSide
        if let refresh=collisionReviewStatus["initial_empty_view_refresh"] {output["initial_empty_view_refresh"]=refresh}
        if let view=collisionReviewStatus["selected_can_view_diagnostic"] {output["selected_can_view_diagnostic"]=view}
        if activeApproachUnknownAdvisory {
            output["approach_unknown_advisory"]=true;output["unknown_space_policy"]="operator_cleared_advisory_only"
            output["unknown_cells_observed"]=false;output["unknown_cells_relabeled_free"]=false
            output["occupied_and_self_checks_retained"]=true;output["collision_protection_certified"]=false
        }
        if let lastHeldFeedbackDiagnostic {output["held_feedback_diagnostic"]=lastHeldFeedbackDiagnostic}
        output["arm_motion_sent"]=armTravelDispatched
        output["reach_sent"]=recyclingReachDispatched
        output["jaw_command_sent"] = jawSetupDispatchUncertain && !jawCommandDispatched ? NSNull() : jawCommandDispatched as Any
        if activeHoldAfterInitialEmptyLift,localJob {
            output["initial_empty_lift_only"]=true;output["transfer_completed"]=false;output["motion_completed"]=false
            output["batch_completed"]=0;output["jaw_commands_permitted"]=false;output["grasp_visually_supported"]=false
            output["automatic_recovery_eligible"]=false;output["old_waypoint_resumption_permitted"]=false
        }
        if nominalEmptyCommissioningStepEnabled,localJob {
            output["nominal_empty_commissioning_step"]=true;output["collision_protection_certified"]=false
            output["assumed_camera_uncertainty_m"]=0.035;output["transfer_completed"]=false;output["motion_completed"]=false
            output["batch_completed"]=0;output["jaw_commands_permitted"]=false
        }
        if oneDegreeEmptyCalibrationStepEnabled,localJob {
            output["one_degree_empty_calibration_step"]=true;output["collision_protection_certified"]=false
            output["assumed_camera_uncertainty_m"]=0.035;output["transfer_completed"]=false;output["motion_completed"]=false
            output["batch_completed"]=0;output["jaw_commands_permitted"]=false;output["contact_predictions_are_diagnostics_only"]=true
        }
        if proposal?.kind=="recycling_grasp_hold" {
            output["transfer_completed"]=false;output["motion_completed"]=false
            output["grasp_attempted"]=recyclingGripDispatched;output["possible_payload_held"]=recyclingGripDispatched
            output["terminal_grasp_hold"]=true;output["placement_verified"]=false
        }
        if localJob {
            output["authorized_can_count"]=requestedCanCount
            output["requires_new_plan"]=canAutoRecover
            output["interruption_reason"]=recoveryReason?.rawValue as Any? ?? NSNull()
            output["automatic_recovery_eligible"]=canAutoRecover
            output["requires_intervention"]=output["requires_intervention"] as? Bool ?? (!canAutoRecover && !preserveLocalReceipt && output["status"] as? String=="blocked")
            output["old_waypoint_resumption_permitted"]=false
            output["possible_payload_held"]=recyclingGripDispatched || servoPossiblePayloadUncertain
            output["local_session_context_diagnostics"]=localRecyclingContextDiagnostics
            output["can_geometry_assumed"]=recyclingCan?.sections?.shapePriorEvidence != nil
            if let prior=recyclingCan?.sections?.shapePriorEvidence,
               let bytes=try?JSONEncoder().encode(prior),let evidence=try?JSONSerialization.jsonObject(with:bytes) {
                output["can_shape_prior_evidence"]=evidence
            }
            output["perception_only_rejection"]=preserveLocalReceipt
            output["local_session_receipt_used"]=true
            output["unmeasured_visual_calibration_trial_authorized"]=true
            output["assumed_spatial_error_m"]=localVisualTrialAssumedSpatialErrorMeters
            output["registration_verified"]=collisionMap?.registrationID != nil
            output["jaw_setup_dispatch_unconfirmed"]=jawSetupDispatchUncertain && !jawCommandDispatched
        }
        if let evidence=lastVisualGraspEvidence {
            output["grasp_visually_supported"]=evidence.verdict == .supported
            if let data=try? JSONEncoder().encode(evidence),let value=try? JSONSerialization.jsonObject(with:data) {output["visual_grasp_evidence"]=value}
        }
        if activeCommand == "left_estimated_calibration" {
            output["arm_motion_sent"] = armTravelDispatched
            output["jaw_command_sent"] = false
            output["estimated_calibration_unverified"] = true
        }
        do { try log?.synchronize(); try log?.close() } catch {
            preserveLocalReceipt=false
            if localJob {output["perception_only_rejection"]=false}
            output["recording_error"] = error.localizedDescription
            output["status"] = "blocked"
            output["detail"] = "Left-arm trial ended, but saving the current recording failed: \(error.localizedDescription)"
        }
        log = nil
        if let servoEvidenceWriteError {output["visual_servo_evidence_write_error"]=servoEvidenceWriteError;output["requires_intervention"]=true}
        output["current_recording"] = lastRecordingPath
        output["current_samples"] = sampleCount
        output["delayed_telemetry_samples"] = delayedSampleCount
        output["max_delayed_telemetry_age_ms"] = maxDelayedSampleAge
        output["peak_current_jump_raw"] = peakJump
        output["current_jump_limit_raw"] = currentLimit
        if let event=currentSpikeEvidence {
            output["current_spike_latched"]=true;output["current_spike_evidence_path"]=currentSpikeEvidencePath
            output["current_spike_post_stop_samples"]=event.postStopSamples.count
            output["current_spike_hold_confirmed"]=event.holds.contains{$0.accepted==true && $0.holdConfirmed==true}
            output["current_force_protection_calibrated"]=false;output["automatic_recovery_eligible"]=false
            output["requires_new_plan"]=true;output["requires_intervention"]=true;output["old_waypoint_resumption_permitted"]=false
            if let error=currentSpikeEvidenceWriteError {output["current_spike_evidence_write_error"]=error}
        }
        if let proposal {
            output["motion_proposal_id"] = proposal.id.uuidString
            output["motion_proposal_sha256"] = proposal.fingerprint
        }
        let keepEstimatedPreview = activeCommand == "left_estimated_preview" &&
            output["status"] as? String == "accepted_unverified" && pendingEstimated != nil
        if !keepEstimatedPreview {
            estimatedCameraRetained = false
            if !preserveLocalReceipt {vision.setActive(false);ROBArmRoutineCoordinator.shared.cameraDemand?(false)}
            invalidateEstimatedPreview(reason:"Estimated trial ended",stopCamera:false)
        }
        activeEstimated = nil
        if let owner {
            ROBAmberArmMotionArbiter.shared.release(.left, owner: owner)
            ROBAmberArmMotionArbiter.shared.release(.right, owner: owner)
        }
        owner = nil; isRunning = false; task = nil; proposal = nil;activeNominalRetreat=nil;activeOneDegreeCalibration=nil; proposalStep = -1; reviewedDispatchStart = nil
        activeApproachUnknownAdvisory=false
        activeApproachCanThenHold=false
        activeHoldAfterInitialEmptyLift=false;initialEmptyLiftHeldEvidence=nil
        activeCommand = ""; recyclingCan=nil; inactiveWorkspaceSearch = false; interactionStage = ""; readinessConfirmed = false; taskJawTarget = nil
        localReceiptCommand=nil;localReceiptEvidence=nil;localReceiptContextIdentity=nil;localReceiptHeldNeckIdentity=nil
        if !preserveLocalReceipt {localReceiptModel=nil}
        localReceiptPerceptionFailure=false
        if keepEstimatedPreview { retainEstimatedPreviewCamera() }
        if preserveLocalReceipt {retainLocalReceiptCamera()}
        update(output["detail"] as? String ?? "Left-arm trial ended")
        completion(output as NSDictionary)
        if canAutoRecover,let recoveryReason,let recoveryCommand,let recoveryCampaignID {
            _ = ROBControllerArmApproval.shared.scheduleStandingLocalCanCampaignRecovery(reason:recoveryReason) { [weak self] in
                Task { @MainActor [weak self] in self?.restartCampaignAfterFreshObservation(command:recoveryCommand,campaignID:recoveryCampaignID) }
            }
        }
    }
}
