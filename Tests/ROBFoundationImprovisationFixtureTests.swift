import Foundation

@main struct ROBFoundationImprovisationFixtureTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ROBLocalImprovisationError.invalidPlan(message) }
    }
    static func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    static func main() throws {
        let config = try ROBLocalImprovisationConfiguration(isEnabled: true, providerKind: .foundationModels,
            endpointURL: URL(string: "http://127.0.0.1:8080")!, model: "SystemLanguageModel.default", timeout: 0.5)
        let request = ROBLocalImprovisationRequest(showTitle: "fixture", cueID: "cue", sceneGoal: "Joke", authoredFallback: "Ready")
        let plan = ROBLocalImprovisationPlan(beat: .robotJoke, delivery: .deadpan, offlineLine: "My rehearsal has excellent error handling.")
        let success = ROBFoundationImprovisationProvider(configuration: config) { _ in plan }
        var result: Result<ROBLocalImprovisationPlan, Error>?
        success.generatePlan(for: request, requestID: "success", timeout: 0.5) { result = $0 }
        wait(0.15)
        let generated = try result?.get()
        try expect(generated == plan, "Typed local dialogue did not complete")
        let invalid = ROBFoundationImprovisationProvider(configuration: config) { _ in
            ROBLocalImprovisationPlan(beat: .robotJoke, delivery: .warm, offlineLine: "robot_action servo joint")
        }
        result = nil
        invalid.generatePlan(for: request, requestID: "invalid", timeout: 0.5) { result = $0 }
        wait(0.15)
        if case .failure? = result {} else { throw ROBLocalImprovisationError.invalidPlan("Semantic output gate was bypassed") }
        let slow = ROBFoundationImprovisationProvider(configuration: config) { _ in
            try? await Task.sleep(nanoseconds: 250_000_000)
            return plan
        }
        var completions = 0
        slow.generatePlan(for: request, requestID: "timeout", timeout: 0.04) { value in
            completions += 1
            if case .failure(let error) = value { result = .failure(error) }
        }
        wait(0.35)
        try expect(completions == 1, "Timeout and late generation both completed")
        if case .failure(let error)? = result {
            try expect(error as? ROBLocalImprovisationError == .timedOut, "Timeout was not reported")
        } else { throw ROBLocalImprovisationError.invalidPlan("Timeout completion missing") }
        slow.generatePlan(for: request, requestID: "cancel", timeout: 0.5) { _ in completions += 1 }
        slow.cancel(requestID: "cancel")
        wait(0.3)
        try expect(completions == 1, "Cancelled generation spoke a late line")
        print("Foundation stage fixtures passed: typed output, semantic checks, timeout, cancellation and late-result suppression")
    }
}
