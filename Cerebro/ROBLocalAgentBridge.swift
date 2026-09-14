// Local same-user command inbox. No network listener, shell execution, selectors,
// raw serial bytes, arbitrary paths, or general actuator commands.
import Foundation
import Darwin

@objc protocol ROBLocalAgentDelegate: AnyObject {
    func localAgentStatus() -> [String:Any]
    @objc(localAgentNudgeAxis:delta:expected:)
    func localAgentNudge(axis:String,delta:Int,expected:[String:NSNumber]) -> [String:Any]
    func localAgentStop()
}

struct ROBLocalAgentRequest: Codable {
    let version: Int
    let id: UUID
    let expiresAt: Double
    let command: String
    let arguments: [String:String]
    static func decode(_ data:Data,now:Double = Date().timeIntervalSince1970) throws -> Self {
        guard data.count <= 8192,
              let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(object.keys) == ["version","id","expiresAt","command","arguments"] else {
            throw ROBChessStudyError.invalid("Invalid command envelope.")
        }
        let request = try JSONDecoder().decode(Self.self,from:data)
        guard request.version == 1, request.expiresAt.isFinite,
              request.expiresAt >= now, request.expiresAt <= now+10 else {
            throw ROBChessStudyError.invalid("Command expired or its deadline is invalid.")
        }
        let keys: Set<String>
        switch request.command {
        case "status","capture","stop": keys = []
        case "observe","camera-hold": keys = ["active"]
        case "camera-nudge": keys = ["axis","delta","pan","lower","upper"]
        default: throw ROBChessStudyError.invalid("Unknown command. Use the documented bounded operations.")
        }
        guard Set(request.arguments.keys) == keys else { throw ROBChessStudyError.invalid("Unexpected command arguments.") }
        if keys.contains("active"), !["true","false"].contains(request.arguments["active"] ?? "") {
            throw ROBChessStudyError.invalid("active must be true or false.")
        }
        if request.command == "camera-nudge" {
            guard ["pan","upper"].contains(request.arguments["axis"] ?? ""),
                  let delta = Int(request.arguments["delta"] ?? ""), delta != 0, (-100...100).contains(delta),
                  ["pan","lower","upper"].allSatisfy({ key in
                    guard let n = Int(request.arguments[key] ?? "") else { return false }
                    return (1...16383).contains(n)
                  }) else { throw ROBChessStudyError.invalid("Nudges require known targets and a nonzero delta of at most 100 Maestro units.") }
        }
        return request
    }
}

@objcMembers final class ROBLocalAgentBridge: NSObject {
    static let shared = ROBLocalAgentBridge()
    weak var delegate: ROBLocalAgentDelegate?
    private(set) var cameraHoldActive = false
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cerebro/AgentBridge",isDirectory:true)
    private let io = DispatchQueue(label:"com.orbitusrobotics.local-agent-io",qos:.utility)
    private var timer: Timer?
    private var seen: [UUID:Double] = [:]
    private var capturePending: ROBLocalAgentRequest?
    private var captureBusy = false
    private(set) var lastError: String?

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        do {
            for path in [root,root.appendingPathComponent("inbox"),root.appendingPathComponent("outbox"),root.appendingPathComponent("captures")] {
                try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let attrs = try FileManager.default.attributesOfItem(atPath:path.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory,
                      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw ROBChessStudyError.invalid("AgentBridge must be a directory owned by this user.")
                }
                try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
                guard path.resolvingSymlinksInPath().standardizedFileURL == path.standardizedFileURL else {
                    throw ROBChessStudyError.invalid("AgentBridge refuses symlinked paths.")
                }
            }
            ROBChessStudyLiveSource.shared.onAgentFrame = { [weak self] frame in self?.completeCapture(frame) }
            timer = Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] _ in self?.poll() }
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
    func shutdown() { timer?.invalidate(); timer = nil; cameraHoldActive = false; ROBChessStudyLiveSource.shared.setAgentActive(false) }
    static func publishPrivateResponse(_ data:Data,to path:URL) throws {
        // Foundation forbids combining atomic and withoutOverwriting. Publish a
        // fully written private file with link(2), which fails if the name exists.
        let temporary = path.deletingLastPathComponent().appendingPathComponent("."+UUID().uuidString+".tmp")
        try data.write(to:temporary,options:.withoutOverwriting)
        defer { try? FileManager.default.removeItem(at:temporary) }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
        guard Darwin.link(temporary.path,path.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
    }
    private func reply(id:UUID,ok:Bool,result:[String:Any]) {
        let payload: [String:Any] = ["version":1,"id":id.uuidString,"ok":ok,"result":result,"repliedAt":Date().timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys]) else { return }
        let path = root.appendingPathComponent("outbox").appendingPathComponent(id.uuidString+".json")
        io.async { [weak self] in
            do {
                try Self.publishPrivateResponse(data,to:path)
                // Append only bounded command-result metadata, never image pixels or credentials.
                let audit = self?.root.appendingPathComponent("audit.jsonl")
                if let audit {
                    if !FileManager.default.fileExists(atPath:audit.path) {
                        FileManager.default.createFile(atPath:audit.path,contents:nil,attributes:[.posixPermissions:0o600])
                    }
                    if let file = try? FileHandle(forWritingTo:audit) {
                        try file.seekToEnd(); try file.write(contentsOf:data+Data([10])); try file.close()
                    }
                }
            } catch { DispatchQueue.main.async { self?.lastError = error.localizedDescription } }
        }
    }
    private func poll() {
        let now = Date().timeIntervalSince1970
        seen = seen.filter { now-$0.value < 60 }
        if let pending = capturePending, now > pending.expiresAt {
            capturePending = nil; reply(id:pending.id,ok:false,result:["error":"No fresh camera frame arrived before the deadline."])
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("inbox"),includingPropertiesForKeys:nil) else { return }
        // Only 8 small envelopes per tick; requests expire instead of building a motion queue.
        let fresh = urls.filter { url in
            guard url.pathExtension == "json", let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent) else { return false }
            return seen[id] == nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("outbox").appendingPathComponent(id.uuidString+".json").path)
        }
        for url in fresh.sorted(by:{$0.lastPathComponent < $1.lastPathComponent}).prefix(8) {
            guard let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      ((attrs[.size] as? NSNumber)?.intValue ?? 9000) <= 8192,
                      ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
                    throw ROBChessStudyError.invalid("Command file must be a small private regular file owned by this user.")
                }
                let data = try Data(contentsOf:url)
                try FileManager.default.removeItem(at:url)
                guard seen[id] == nil else { continue }
                seen[id] = now
                let request = try ROBLocalAgentRequest.decode(data,now:now)
                guard request.id == id else { throw ROBChessStudyError.invalid("Request ID does not match its filename.") }
                dispatch(request)
            } catch {
                // Never remove links or malformed files whose ownership was not established.
                if seen[id] == nil { seen[id] = now; reply(id:id,ok:false,result:["error":error.localizedDescription]) }
                else { reply(id:id,ok:false,result:["error":error.localizedDescription]) }
            }
        }
    }
    private func dispatch(_ request:ROBLocalAgentRequest) {
        guard let delegate else { reply(id:request.id,ok:false,result:["error":"Robot runtime is not available."]); return }
        var result: [String:Any]
        switch request.command {
        case "status":
            result = delegate.localAgentStatus()
            result["cameraHoldActive"] = cameraHoldActive
            result["cameraConsumerActive"] = ROBChessStudyLiveSource.shared.isActive
            result["frameAgeSeconds"] = ROBChessStudyLiveSource.shared.latestFrame.map { ProcessInfo.processInfo.systemUptime-$0.receivedUptime } ?? NSNull()
            result["availableCommands"] = ["status","observe","capture","camera-hold","camera-nudge","stop"]
        case "observe":
            let active = request.arguments["active"] == "true"
            ROBChessStudyLiveSource.shared.setAgentActive(active)
            result = ["observing":active]
        case "camera-hold":
            let active = request.arguments["active"] == "true"
            // Holding stops new automatic tracking requests without moving a
            // servo. Requiring a settled neck here would starve the hold while
            // tracking continuously renews its target. Nudges still wait for
            // the existing transition to finish and the neck to settle.
            if active, delegate.localAgentStatus()["cameraHoldAvailable"] as? Bool != true {
                reply(id:request.id,ok:false,result:["error":"Finish Follow, autonomy, shows and pending robot actions before acquiring camera-hold."]); return
            }
            cameraHoldActive = active
            if active { ROBChessStudyLiveSource.shared.setAgentActive(true) }
            result = ["cameraHoldActive":active,"detail":"Pauses automatic person-camera tracking; does not command a servo. Release explicitly when finished."]
        case "camera-nudge":
            guard cameraHoldActive else { reply(id:request.id,ok:false,result:["error":"Acquire camera-hold before adjusting the camera."]); return }
            let expected = Dictionary(uniqueKeysWithValues:["pan","lower","upper"].map { ($0,NSNumber(value:Int(request.arguments[$0]!)!)) })
            result = delegate.localAgentNudge(axis:request.arguments["axis"]!,delta:Int(request.arguments["delta"]!)!,expected:expected)
            reply(id:request.id,ok:result["accepted"] as? Bool == true,result:result); return
        case "stop":
            // Remain held after stopping; never resume automatic camera motion as a side effect.
            cameraHoldActive = true; delegate.localAgentStop()
            result = ["stopped":true,"cameraHoldActive":true,"detail":"Existing priority software stop invoked; this is not a physical power cutoff."]
        case "capture":
            guard !captureBusy, capturePending == nil else { reply(id:request.id,ok:false,result:["error":"A capture is already pending."]); return }
            capturePending = request
            ROBChessStudyLiveSource.shared.setAgentActive(true)
            if let frame = ROBChessStudyLiveSource.shared.latestFrame, ProcessInfo.processInfo.systemUptime-frame.receivedUptime <= 1 { completeCapture(frame) }
            return
        default: return
        }
        reply(id:request.id,ok:true,result:result)
    }
    private func completeCapture(_ frame:ROBChessStudyFrame) {
        guard let request = capturePending, !captureBusy, Date().timeIntervalSince1970 <= request.expiresAt,
              ProcessInfo.processInfo.systemUptime-frame.receivedUptime <= 1 else { return }
        capturePending = nil; captureBusy = true
        let folder = root.appendingPathComponent("captures").appendingPathComponent(request.id.uuidString)
        let neck = delegate?.localAgentStatus() ?? [:]
        io.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                try frame.raster.encoded().write(to:folder.appendingPathComponent("rgb.jpg"),options:.atomic)
                var metadata: [String:Any] = [
                    "schemaVersion":1,"frameID":frame.id.uuidString,"capturedAt":frame.capturedAt.timeIntervalSince1970,
                    "source":frame.source,"width":frame.raster.width,"height":frame.raster.height,
                    "labelStatus":"unreviewed","robotStatusAtExport":neck,
                    "hasAlignedDepth":frame.depth != nil,"robotExtrinsicsCalibrated":false
                ]
                if let depth = frame.depth {
                    try depth.millimetersLittleEndian.write(to:folder.appendingPathComponent("depth-u16le-mm.raw"),options:.atomic)
                    var depthInfo: [String:Any] = ["width":depth.width,"height":depth.height,"units":"millimeters","invalidValue":0,
                        "cameraSequence":depth.cameraSequence,"cameraTimestampNanoseconds":depth.cameraTimestampNanoseconds]
                    depthInfo["fx"] = depth.fx.map { $0 as Any } ?? NSNull()
                    depthInfo["fy"] = depth.fy.map { $0 as Any } ?? NSNull()
                    depthInfo["cx"] = depth.cx.map { $0 as Any } ?? NSNull()
                    depthInfo["cy"] = depth.cy.map { $0 as Any } ?? NSNull()
                    metadata["depth"] = depthInfo
                }
                try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])
                    .write(to:folder.appendingPathComponent("frame.json"),options:.atomic)
                DispatchQueue.main.async {
                    self?.captureBusy = false
                    self?.reply(id:request.id,ok:true,result:["captureDirectory":folder.path,"frameID":frame.id.uuidString,
                        "rgb":folder.appendingPathComponent("rgb.jpg").path,"hasAlignedDepth":frame.depth != nil])
                }
            } catch {
                DispatchQueue.main.async { self?.captureBusy = false; self?.reply(id:request.id,ok:false,result:["error":error.localizedDescription]) }
            }
        }
    }
}
