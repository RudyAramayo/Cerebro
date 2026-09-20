import Foundation

@main struct ROBShadowPlannerBridgeFixtureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ShadowFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let controller = UUID(), session = UUID(), shadow = UUID()
        var responses: [ROBShadowResponse] = [], sequence: UInt64 = 0
        let bridge = ROBShadowPlannerBridge(resources: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"), python: python) { data, device, boundSession in
            guard device == controller, boundSession == session,
                  let value = try? ROBShadowProtocol.response(data) else { return false }
            responses.append(value); return true
        }
        func exchange(_ command: ROBShadowCommand) throws -> ROBShadowResponse {
            sequence += 1
            let request = ROBShadowRequest(controllerID: controller, sessionID: session, sequence: sequence, command: command)
            bridge.consume(try ROBShadowProtocol.encode(request), controllerID: controller, sessionID: session)
            let deadline = Date().addingTimeInterval(10)
            while !responses.contains(where: { $0.requestID == command.requestID }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let response = responses.first(where: { $0.requestID == command.requestID }) else {
                throw NSError(domain: "ShadowFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "No Mac worker response"])
            }
            try expect(!response.hardwareOutputEnabled && ["clear_model", "blocked"].contains(response.collisionStatus), "Preview was promoted to execution or clearance")
            return response
        }
        let start = try exchange(.init(.start, shadowID: shadow, visionRequired: false))
        try expect(start.status == "ready" && start.referenceFrames.count == 45, "Approved model did not load")
        let result = try exchange(.init(.nudge, shadowID: shadow, modelID: start.modelID, delta: [0.005, 0, 0]))
        try expect(result.status == "blocked" && result.collisionStatus == "blocked" && result.collisionPair != nil, "Known scan overlap did not block the nudge")
        let reference = Dictionary(uniqueKeysWithValues: start.referenceFrames.map { ($0.name, $0.pose) })
        for name in ["torso_link", "base_link", "left_tool", "right_tool", "insta360_link"] {
            try expect(result.ghostFrames.first(where: { $0.name == name })?.pose == reference[name], "Fixed body or other arm moved")
        }
        let count = responses.count
        let wrong = ROBShadowRequest(controllerID: controller, sessionID: UUID(), sequence: 99,
                                     command: .init(.start, shadowID: UUID()))
        bridge.consume(try ROBShadowProtocol.encode(wrong), controllerID: controller, sessionID: session)
        let stale = ROBShadowRequest(controllerID: controller, sessionID: session, sequence: 100,
                                     command: .init(.start, shadowID: UUID()), sentAtMilliseconds: ROBShadowProtocol.now() - 2000)
        bridge.consume(try ROBShadowProtocol.encode(stale), controllerID: controller, sessionID: session)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(responses.count == count, "Wrong-session or expired request reached worker")
        _ = try exchange(.init(.end, shadowID: shadow))
        bridge.stop()

        // A process failure is an explicit preview error, never a fallback into
        // an arm transport. Inject a malformed worker without a robot connection.
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-failure-\(UUID())")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bad) }
        try Data("import sys\nfor line in sys.stdin: print('{}', flush=True)\n".utf8).write(to: bad.appendingPathComponent("worker.py"))
        var failed = false
        let broken = ROBShadowPlannerBridge(resources: bad, python: python) { data, _, _ in
            failed = (try? ROBShadowProtocol.response(data).status) == "unavailable"; return true
        }
        let failureRequest = ROBShadowRequest(controllerID: controller, sessionID: session, sequence: 1,
                                               command: .init(.start, shadowID: UUID()))
        broken.consume(try ROBShadowProtocol.encode(failureRequest), controllerID: controller, sessionID: session)
        let deadline = Date().addingTimeInterval(3)
        while !failed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(failed, "Malformed worker did not report unavailable")
        broken.stop()
        print("Shadow bridge passed: real Drake round trip, scan overlap held, fixed body, session/freshness rejection, malformed worker, no actuator endpoint")
    }
}
