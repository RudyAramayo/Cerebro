import Foundation

private enum FixtureFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let detail): return detail }
    }
}

@main
struct ROBAmberStackMaintenanceProtocolFixtureTests {
    static func main() throws {
        try successRequiresFinalResultAndZeroExit()
        try helperFailureStaysFailed()
        try missingOrForeignResultFailsClosed()
        try operationIdentityAndSingleResultAreRequired()
        try timeoutOverridesSuccess()
        try outputIsBounded()
        print("Amber stack maintenance protocol fixtures passed")
    }

    private static func successRequiresFinalResultAndZeroExit() throws {
        let result = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-1","type":"progress","stage":"stopping","message":"Gateway stopped"}
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-1","type":"result","success":true,"detail":"All recovery checks passed"}
        """)
        try expect(result.success, "Valid recovery result was rejected")
        try expect(result.detail == "All recovery checks passed", "Final detail changed")
        try expect(result.events == ["[stopping] Gateway stopped"], "Progress event changed")

        let nonzero = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-2","type":"result","success":true,"detail":"claimed success"}
        """, status: 7)
        try expect(!nonzero.success, "Nonzero SSH exit promoted a helper claim to success")
    }

    private static func helperFailureStaysFailed() throws {
        let result = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-3","type":"progress","stage":"can","message":"can11 counters did not advance"}
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-3","type":"result","success":false,"detail":"CAN verification failed"}
        """, status: 1)
        try expect(!result.success, "Explicit helper failure was accepted")
        try expect(result.detail == "CAN verification failed", "Helper failure detail was lost")
    }

    private static func missingOrForeignResultFailsClosed() throws {
        let missing = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-4","type":"progress","stage":"start","message":"Started"}
        """)
        try expect(!missing.success, "Missing final result was accepted")

        let foreign = parse("""
        {"protocol":"another-protocol/1","type":"result","success":true,"detail":"wrong helper"}
        """)
        try expect(!foreign.success, "Foreign protocol result was accepted")
    }

    private static func operationIdentityAndSingleResultAreRequired() throws {
        let wrongOperation = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"unrelated","operation_id":"fixture-5","type":"result","success":true,"detail":"wrong operation"}
        """)
        try expect(!wrongOperation.success, "Wrong recovery operation was accepted")

        let changedIdentity = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-6","type":"progress","stage":"start","message":"Started"}
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-7","type":"result","success":true,"detail":"identity changed"}
        """)
        try expect(!changedIdentity.success, "Changed operation identity was accepted")

        let duplicateResult = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-8","type":"result","success":false,"detail":"failed first"}
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-8","type":"result","success":true,"detail":"claimed success later"}
        """)
        try expect(!duplicateResult.success, "Duplicate final results were accepted")
    }

    private static func timeoutOverridesSuccess() throws {
        let result = parse("""
        {"protocol":"rob-amber-recovery/1","operation":"restart_can_core_gateway","operation_id":"fixture-9","type":"result","success":true,"detail":"late result"}
        """, timedOut: true)
        try expect(!result.success, "Timed-out recovery was accepted")
        try expect(result.detail.contains("75-second"), "Timeout detail was not actionable")
    }

    private static func outputIsBounded() throws {
        let noisy = String(repeating: "x", count: 70_000)
        let result = ROBAmberStackMaintenanceOutputParser.parse(
            standardOutput: Data(noisy.utf8),
            standardError: Data(),
            terminationStatus: 0,
            timedOut: false
        )
        try expect(!result.success, "Oversized noise was accepted")
        try expect(result.events.count <= 80, "Event limit was exceeded")
        try expect(result.events.contains(where: { $0.contains("truncated") }), "Truncation was hidden")
    }

    private static func parse(
        _ text: String,
        status: Int32 = 0,
        timedOut: Bool = false
    ) -> ROBAmberStackMaintenanceResult {
        ROBAmberStackMaintenanceOutputParser.parse(
            standardOutput: Data((text + "\n").utf8),
            standardError: Data(),
            terminationStatus: status,
            timedOut: timedOut
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FixtureFailure.failed(message) }
    }
}
