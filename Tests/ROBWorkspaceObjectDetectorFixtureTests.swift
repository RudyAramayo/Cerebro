import Foundation

@main struct ROBWorkspaceObjectDetectorFixtures {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rob-object-detector-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("venv/bin/python3").path, withDestinationPath: "/usr/bin/python3")
        try Data("fixture, not model weights".utf8).write(to: root.appendingPathComponent("model/model.safetensors"))
        let script = root.appendingPathComponent("fixture.py")
        try """
        import base64, json, sys, time
        print(json.dumps({'ready':True,'provider':'owlv2'}),flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            mode=base64.b64decode(request['jpeg']).decode()
            if mode=='hang': time.sleep(60)
            box=[0.66,0.26,0.76,0.51] if mode!='invalid' else [0.66,0.26,0.76,1.5]
            print(json.dumps({'id':request['id'] if mode!='mismatch' else 'old-frame',
                'provider':'owlv2','model':'google/owlv2-base-patch16-ensemble','device':'cpu',
                'width':640,'height':400,'inference_ms':1,
                'candidates':[{'target':'can','query':'fixture','score':0.576,'box':box}]}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ROBWorkspaceObjectDetector(directory: root, script: script)
        try await detector.warmUp()
        let first = try await detector.detect(jpeg: Data("valid".utf8))
        precondition(first.candidates.count == 1 && first.candidates[0].score == 0.576)
        for mode in ["mismatch", "invalid"] {
            var rejected = false
            do { _ = try await detector.detect(jpeg: Data(mode.utf8)) } catch { rejected = true }
            precondition(rejected, "Invalid or stale detector output was accepted")
            _ = try await detector.detect(jpeg: Data("valid".utf8))
        }
        let hanging = Task { try await detector.detect(jpeg: Data("hang".utf8)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        hanging.cancel()
        var cancelled = false
        do { _ = try await hanging.value } catch { cancelled = true }
        precondition(cancelled, "Cancelled camera inference supplied a result")
        _ = try await detector.detect(jpeg: Data("valid".utf8))
        print("Object detector transport: persistent worker, matching frame IDs, invalid boxes rejected, cancellation terminates inference, fresh request after failure. No robot transport linked.")
    }
}
