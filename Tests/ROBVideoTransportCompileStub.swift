// Minimal declarations needed when compiling AutoNetDataTransferProtocol.swift
// as a standalone fixture. The production definitions live in ROBVideoServer.
import Network

enum ROBVideoTransport {
    static let applicationProtocol = "robvideo/fixture"
}

@available(macOS 12.0, *)
final class ROBVideoFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: ROBVideoFramer.self)
    static var label: String { "ROBVideoFixture" }

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
    func handleInput(framer: NWProtocolFramer.Instance) -> Int { 0 }
    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {}
}
