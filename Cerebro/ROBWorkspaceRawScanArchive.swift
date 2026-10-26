import Foundation
import CryptoKit
import Darwin

/// Private, bounded pixel provenance only. Decoding this archive cannot create
/// robot-self classification, workspace free space or motion authority.
final class ROBWorkspaceRawScanArchive: @unchecked Sendable {
    struct Availability<Value:Codable & Sendable>:Codable,Sendable {
        let value:Value?
        let unavailableReason:String?
        static func available(_ value:Value)->Self {.init(value:value,unavailableReason:nil)}
        static func unavailable(_ reason:String)->Self {.init(value:nil,unavailableReason:reason)}
        fileprivate var valid:Bool {(value != nil && unavailableReason == nil) || (value == nil && unavailableReason.map{!$0.isEmpty && $0.utf8.count<=512}==true)}
    }
    struct ArmFeedback:Codable,Sendable {
        let physicalSide:String
        let gatewayArm:String
        let telemetrySequence:UInt64
        let receivedAtHostMilliseconds:Double
        let effectiveSampleAgeMilliseconds:Double
        let effectiveGripperAgeMilliseconds:Double
        /// Original feedback observation, never substituted with planned q.
        let positionsRadians:[Double]
        let reportedModes:[Int]
        let gatewayModes:[Int]
        let exposureOffsetMilliseconds:Availability<Double>
        let referenceIdentity:Availability<String>
        let modelID:String,geometryID:String,mappingID:String
    }
    struct Neck:Codable,Sendable {
        let appliedPanTarget:Int,appliedLowerTarget:Int,appliedUpperTarget:Int
        let observedAtHostMilliseconds:Double
        let stationary:Bool
        let source:String
    }
    struct Scene:Codable {
        let archiveID:UUID
        let workspaceSceneID:UUID
        let bodyMotionIdentity:String
        let gatewayGeneration:UInt64
        let modelID:String,referenceID:String,geometryID:String,mappingID:String
    }
    /// Values must be copied from the same retained capture before dispatching
    /// to this writer. The writer never accesses camera/telemetry singletons.
    struct Frame:Sendable {
        let frameID:UUID
        let sequence:UInt64
        let capturedAtHostMilliseconds:Double
        let rgbCapturedAtHostMilliseconds:Availability<Double>
        let depthCapturedAtHostMilliseconds:Availability<Double>
        let sourceTimestampJSON:Availability<Data>
        let cameraGeneration:UUID
        let width:Int,height:Int
        let rgb888:Data
        let depthU16LittleEndian:Data
        let infrared:Availability<Data>
        let infraredContractJSON:Availability<Data>
        /// fx,fy,cx,cy for these exact normalized pixels.
        let intrinsics:[Double]
        let sourceContractsJSON:Data
        let runtimeCalibrationJSON:Data
        let imuJSON:Availability<Data>
        let actualAppliedNeck:Availability<Neck>
        let physicalLeftFeedback:Availability<ArmFeedback>
        let physicalRightFeedback:Availability<ArmFeedback>
        let cameraToRobotColumnMajor:[Double]
        let projectionMethod:String
        let projectionScopeJSON:Data
        /// Original pixel sampling contract used by map.append. This does not
        /// label any return self; (frameID,x,y) preserves its original source.
        let returnSamplingContractJSON:Data
    }
    struct Record:Codable {
        let frameID:UUID,sequence:UInt64
        let capturedAtHostMilliseconds:Double
        let cameraGeneration:UUID
        let relativeDirectory:String
        let rgbSHA256:String,depthSHA256:String
        let metadataSHA256:String
        let byteCount:Int
    }
    struct Manifest:Codable {
        let schemaVersion:Int
        let kind:String
        let scene:Scene
        let maximumFrames:Int,maximumBytes:Int
        let status:String
        let frames:[Record]
        let failure:String?
        let classificationAuthority:Bool
        let motionAuthority:Bool
    }
    private struct Metadata:Codable {
        let schemaVersion:Int
        let frameID:UUID,sequence:UInt64
        let capturedAtHostMilliseconds:Double
        let rgbCapturedAtHostMilliseconds:Availability<Double>,depthCapturedAtHostMilliseconds:Availability<Double>
        let sourceTimestampJSON:Availability<Data>
        let cameraGeneration:UUID
        let width:Int,height:Int
        let rgbPath:String,rgbSHA256:String,depthPath:String,depthSHA256:String
        let infraredPath:Availability<String>,infraredSHA256:Availability<String>,infraredContractJSON:Availability<Data>
        let intrinsics:[Double]
        let sourceContractsJSON:Data,runtimeCalibrationJSON:Data,imuJSON:Availability<Data>
        let actualAppliedNeck:Availability<Neck>
        let physicalLeftFeedback:Availability<ArmFeedback>,physicalRightFeedback:Availability<ArmFeedback>
        let cameraToRobotColumnMajor:[Double]
        let projectionMethod:String,projectionScopeJSON:Data,returnSamplingContractJSON:Data
        let classificationAuthority:Bool,motionAuthority:Bool
    }
    enum ArchiveError:LocalizedError {
        case rejected(String)
        var errorDescription:String? {if case .rejected(let value)=self{return value};return nil}
    }
    let directory:URL
    private let scene:Scene
    private let queue=DispatchQueue(label:"com.orbitusrobotics.raw-workspace-archive",qos:.utility)
    private let maximumFrames:Int,maximumBytes:Int
    private var frames:[Record]=[]
    private var byteCount=0
    private var closed=false
    private init(directory:URL,scene:Scene,maximumFrames:Int,maximumBytes:Int) {
        self.directory=directory;self.scene=scene;self.maximumFrames=maximumFrames;self.maximumBytes=maximumBytes
    }
    static func create(parentDirectory:URL,scene:Scene,maximumFrames:Int=14,maximumBytes:Int=64_000_000) async throws->ROBWorkspaceRawScanArchive {
        guard parentDirectory.isFileURL,(1...14).contains(maximumFrames),(1...64_000_000).contains(maximumBytes),
              scene.gatewayGeneration>0,!scene.bodyMotionIdentity.isEmpty,
              [scene.modelID,scene.referenceID,scene.geometryID,scene.mappingID].allSatisfy({!$0.isEmpty && $0.utf8.count<=512}) else {
            throw ArchiveError.rejected("Invalid bounded raw archive scene.")
        }
        let parent=parentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let value=ROBWorkspaceRawScanArchive(directory:parent.appendingPathComponent(scene.archiveID.uuidString,isDirectory:true),
            scene:scene,maximumFrames:maximumFrames,maximumBytes:maximumBytes)
        return try await withCheckedThrowingContinuation {continuation in
            value.queue.async {
                do {
                    try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                    guard !FileManager.default.fileExists(atPath:value.directory.path) else {throw ArchiveError.rejected("Raw archive already exists; no overwrite.")}
                    try FileManager.default.createDirectory(at:value.directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    try value.writeManifest(status:"open",failure:nil)
                    continuation.resume(returning:value)
                }catch {value.closed=true;continuation.resume(throwing:error)}
            }
        }
    }
    func append(_ frame:Frame) async throws->Record {
        try await withCheckedThrowingContinuation {continuation in
            queue.async {
                guard !self.closed else {continuation.resume(throwing:ArchiveError.rejected("Raw archive is closed; no frame accepted."));return}
                do {
                    let result=try self.appendOnQueue(frame)
                    continuation.resume(returning:result)
                }catch {
                    self.closed=true
                    _ = try?self.writeManifest(status:"failed",failure:error.localizedDescription)
                    continuation.resume(throwing:error)
                }
            }
        }
    }
    func finish() async throws->Manifest {
        try await withCheckedThrowingContinuation {continuation in
            queue.async {
                guard !self.closed else {continuation.resume(throwing:ArchiveError.rejected("Raw archive is closed."));return}
                do {
                    guard !self.frames.isEmpty else {throw ArchiveError.rejected("Raw archive cannot finish empty.")}
                    let manifest=try self.writeManifest(status:"complete",failure:nil)
                    self.closed=true;continuation.resume(returning:manifest)
                }catch {self.closed=true;_ = try?self.writeManifest(status:"failed",failure:error.localizedDescription);continuation.resume(throwing:error)}
            }
        }
    }
    private func appendOnQueue(_ f:Frame)throws->Record {
        func require(_ condition:Bool,_ reason:String)throws {if !condition {throw ArchiveError.rejected(reason)}}
        func json(_ data:Data)throws {try require(data.count<=1_000_000,"Raw JSON metadata exceeds bound.");let v=try JSONSerialization.jsonObject(with:data);try require(v is [String:Any] || v is [Any],"Raw JSON metadata must be object/array.")}
        func optionalJSON(_ value:Availability<Data>)throws {try require(value.valid,"Missing metadata needs explicit unavailable reason.");if let data=value.value {try json(data)}}
        try require(frames.count<maximumFrames,"Raw archive frame limit reached.")
        try require(f.sequence>0 && f.capturedAtHostMilliseconds.isFinite && f.capturedAtHostMilliseconds>0,"Invalid original frame time/sequence.")
        try require(!frames.contains{$0.frameID==f.frameID},"Duplicate original frame ID.")
        if let previous=frames.last {try require(previous.cameraGeneration==f.cameraGeneration && f.sequence>previous.sequence && f.capturedAtHostMilliseconds>previous.capturedAtHostMilliseconds,"Raw source generation or advancing sequence/time changed.")}
        try require((16...1920).contains(f.width) && (16...1200).contains(f.height),"Invalid raw dimensions.")
        try require(f.rgb888.count==f.width*f.height*3 && f.depthU16LittleEndian.count==f.width*f.height*2,"Raw byte count differs from actual dimensions.")
        try require(f.intrinsics.count==4 && f.intrinsics.allSatisfy(\.isFinite) && f.intrinsics[0]>0 && f.intrinsics[1]>0 && (0..<Double(f.width)).contains(f.intrinsics[2]) && (0..<Double(f.height)).contains(f.intrinsics[3]),"Invalid exact pixel intrinsics.")
        try require(f.cameraToRobotColumnMajor.count==16 && f.cameraToRobotColumnMajor.allSatisfy(\.isFinite) && !f.projectionMethod.isEmpty && f.projectionMethod.utf8.count<=512,"Missing original projection scope.")
        for timing in [f.rgbCapturedAtHostMilliseconds,f.depthCapturedAtHostMilliseconds] {try require(timing.valid && (timing.value.map{$0.isFinite && $0>0} ?? true),"Timing must be original finite or explicitly unavailable.")}
        for data in [f.sourceContractsJSON,f.runtimeCalibrationJSON,f.projectionScopeJSON,f.returnSamplingContractJSON] {try json(data)}
        for value in [f.sourceTimestampJSON,f.imuJSON,f.infraredContractJSON] {try optionalJSON(value)}
        try require(f.infrared.valid,"Missing IR must be explicit.")
        try require((f.infrared.value != nil)==(f.infraredContractJSON.value != nil),"IR bytes and actual source contract must be available together.")
        try require(f.actualAppliedNeck.valid,"Missing applied neck feedback must be explicit.")
        if let n=f.actualAppliedNeck.value {try require([n.appliedPanTarget,n.appliedLowerTarget,n.appliedUpperTarget].allSatisfy{(3000...10000).contains($0)} && n.observedAtHostMilliseconds.isFinite && n.observedAtHostMilliseconds>0 && !n.source.isEmpty,"Invalid actual applied neck provenance.")}
        for (value,side,gateway) in [(f.physicalLeftFeedback,"left","right"),(f.physicalRightFeedback,"right","left")] {
            try require(value.valid,"Missing physical arm feedback must be explicit.")
            if let a=value.value {
                try require(a.physicalSide==side && a.gatewayArm==gateway && a.telemetrySequence>0 && a.receivedAtHostMilliseconds.isFinite && a.receivedAtHostMilliseconds>0 && a.effectiveSampleAgeMilliseconds.isFinite && a.effectiveSampleAgeMilliseconds>=0 && a.effectiveGripperAgeMilliseconds.isFinite && a.effectiveGripperAgeMilliseconds>=0,"Invalid original physical/gateway arm feedback identity.")
                try require(a.positionsRadians.count==7 && a.positionsRadians.allSatisfy(\.isFinite) && a.reportedModes.count==7 && a.gatewayModes.count==7 && (a.reportedModes+a.gatewayModes).allSatisfy{(0...255).contains($0)},"Invalid measured q/modes.")
                try require(a.exposureOffsetMilliseconds.valid && (a.exposureOffsetMilliseconds.value.map{$0.isFinite} ?? true) && a.referenceIdentity.valid && [a.modelID,a.geometryID,a.mappingID].allSatisfy{!$0.isEmpty},"Missing measured feedback source/exposure provenance.")
            }
        }
        let folder=f.frameID.uuidString,frameDirectory=directory.appendingPathComponent(folder,isDirectory:true)
        let rgbHash=Self.hash(f.rgb888),depthHash=Self.hash(f.depthU16LittleEndian)
        let infraredPath=f.infrared.value.map{_ in Availability<String>.available("infrared.raw")} ?? .unavailable(f.infrared.unavailableReason!)
        let infraredHash=f.infrared.value.map{Availability<String>.available(Self.hash($0))} ?? .unavailable(f.infrared.unavailableReason!)
        let metadata=Metadata(schemaVersion:1,frameID:f.frameID,sequence:f.sequence,capturedAtHostMilliseconds:f.capturedAtHostMilliseconds,
            rgbCapturedAtHostMilliseconds:f.rgbCapturedAtHostMilliseconds,depthCapturedAtHostMilliseconds:f.depthCapturedAtHostMilliseconds,
            sourceTimestampJSON:f.sourceTimestampJSON,cameraGeneration:f.cameraGeneration,width:f.width,height:f.height,
            rgbPath:"rgb888.raw",rgbSHA256:rgbHash,depthPath:"depth-u16le.raw",depthSHA256:depthHash,
            infraredPath:infraredPath,infraredSHA256:infraredHash,infraredContractJSON:f.infraredContractJSON,intrinsics:f.intrinsics,
            sourceContractsJSON:f.sourceContractsJSON,runtimeCalibrationJSON:f.runtimeCalibrationJSON,imuJSON:f.imuJSON,
            actualAppliedNeck:f.actualAppliedNeck,physicalLeftFeedback:f.physicalLeftFeedback,physicalRightFeedback:f.physicalRightFeedback,
            cameraToRobotColumnMajor:f.cameraToRobotColumnMajor,projectionMethod:f.projectionMethod,projectionScopeJSON:f.projectionScopeJSON,
            returnSamplingContractJSON:f.returnSamplingContractJSON,classificationAuthority:false,motionAuthority:false)
        let data=try Self.encode(metadata),size=f.rgb888.count+f.depthU16LittleEndian.count+(f.infrared.value?.count ?? 0)+data.count
        try require(size<=maximumBytes-byteCount,"Raw archive scene byte limit reached.")
        try FileManager.default.createDirectory(at:frameDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Self.writeNew(f.rgb888,to:frameDirectory.appendingPathComponent("rgb888.raw"))
        try Self.writeNew(f.depthU16LittleEndian,to:frameDirectory.appendingPathComponent("depth-u16le.raw"))
        if let infrared=f.infrared.value {try Self.writeNew(infrared,to:frameDirectory.appendingPathComponent("infrared.raw"))}
        try Self.writeNew(data,to:frameDirectory.appendingPathComponent("frame.json"))
        let record=Record(frameID:f.frameID,sequence:f.sequence,capturedAtHostMilliseconds:f.capturedAtHostMilliseconds,cameraGeneration:f.cameraGeneration,
            relativeDirectory:folder,rgbSHA256:rgbHash,depthSHA256:depthHash,metadataSHA256:Self.hash(data),byteCount:size)
        frames.append(record);byteCount+=size
        _ = try writeManifest(status:"open",failure:nil)
        return record
    }
    @discardableResult private func writeManifest(status:String,failure:String?)throws->Manifest {
        let manifest=Manifest(schemaVersion:1,kind:"raw_workspace_pixel_provenance_only",scene:scene,maximumFrames:maximumFrames,maximumBytes:maximumBytes,
            status:status,frames:frames,failure:failure,classificationAuthority:false,motionAuthority:false)
        let data=try Self.encode(manifest),temporary=directory.appendingPathComponent("manifest-\(UUID().uuidString).tmp")
        try Self.writeNew(data,to:temporary)
        guard rename(temporary.path,directory.appendingPathComponent("manifest.json").path)==0 else {try?FileManager.default.removeItem(at:temporary);throw ArchiveError.rejected("Atomic raw manifest publication failed.")}
        return manifest
    }
    private static func encode<T:Encodable>(_ value:T)throws->Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(value)}
    private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func writeNew(_ data:Data,to url:URL)throws {
        let fd=open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600))
        guard fd>=0 else {throw ArchiveError.rejected("Cannot exclusively create private raw archive file.")}
        defer {close(fd)}
        try data.withUnsafeBytes {buffer in
            var offset=0
            while offset<buffer.count {
                let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count<0 && errno==EINTR {continue}
                guard count>0 else {throw ArchiveError.rejected("Raw archive write failed.")}
                offset+=count
            }
        }
        guard fsync(fd)==0 else {throw ArchiveError.rejected("Raw archive flush failed.")}
    }
}
