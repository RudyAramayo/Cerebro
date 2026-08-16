import Foundation

@objc public enum ROBAmberStackMaintenanceState: Int {
    case idle
    case running
    case succeeded
    case failed
}

@objcMembers public final class ROBAmberStackMaintenanceResult: NSObject {
    public let success: Bool
    public let detail: String
    public let events: [String]

    public init(success: Bool, detail: String, events: [String]) {
        self.success = success
        self.detail = detail
        self.events = events
        super.init()
    }
}

/// Decoder for the bounded JSON-lines contract emitted by the root-owned
/// Ubuntu recovery helper. Ordinary SSH output can never promote a recovery to
/// success: a matching final protocol result and a zero process status are both
/// required.
enum ROBAmberStackMaintenanceOutputParser {
    static let protocolName = "rob-amber-recovery/1"
    static let operationName = "restart_can_core_gateway"
    static let maximumOutputBytes = 64 * 1_024
    static let maximumEvents = 80
    static let maximumEventCharacters = 512

    private struct Envelope: Decodable {
        var protocolName: String
        var type: String
        var operation: String
        var operationID: String
        var stage: String?
        var message: String?
        var success: Bool?
        var detail: String?

        enum CodingKeys: String, CodingKey {
            case type, operation, stage, message, success, detail
            case protocolName = "protocol"
            case operationID = "operation_id"
        }
    }

    static func parse(
        standardOutput: Data,
        standardError: Data,
        terminationStatus: Int32,
        timedOut: Bool
    ) -> ROBAmberStackMaintenanceResult {
        let outputWasTruncated = standardOutput.count > maximumOutputBytes
        let errorWasTruncated = standardError.count > maximumOutputBytes
        let output = boundedString(standardOutput)
        let errorOutput = boundedString(standardError)
        let decoder = JSONDecoder()
        var events: [String] = []
        var finalSuccess: Bool?
        var finalDetail: String?
        var operationID: String?
        var finalResultCount = 0
        var contractWasViolated = false

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            guard events.count < maximumEvents else { break }
            let line = String(rawLine)
            guard let data = line.data(using: .utf8),
                  let envelope = try? decoder.decode(Envelope.self, from: data),
                  envelope.protocolName == protocolName else {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    events.append("Unrecognized helper output: \(boundedLine(line))")
                }
                continue
            }
            guard envelope.operation == operationName,
                  !envelope.operationID.isEmpty,
                  envelope.operationID.utf8.count <= 128 else {
                events.append("Ignored recovery output with an invalid operation identity")
                continue
            }
            if let operationID, operationID != envelope.operationID {
                contractWasViolated = true
                events.append("Recovery helper changed operation identity mid-stream")
                continue
            }
            operationID = envelope.operationID
            switch envelope.type {
            case "progress":
                let stage = envelope.stage?.isEmpty == false ? envelope.stage! : "recovery"
                let message = envelope.message?.isEmpty == false
                    ? envelope.message! : "Stage updated"
                events.append("[\(boundedLine(stage))] \(boundedLine(message))")
            case "result":
                finalResultCount += 1
                if finalResultCount > 1 {
                    contractWasViolated = true
                }
                finalSuccess = envelope.success
                finalDetail = envelope.detail
                if let message = envelope.message, !message.isEmpty {
                    events.append("[result] \(boundedLine(message))")
                }
            default:
                events.append("Ignored unknown helper event type \(boundedLine(envelope.type))")
            }
        }

        for rawLine in errorOutput.split(whereSeparator: \Character.isNewline) {
            guard events.count < maximumEvents else { break }
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { events.append("SSH: \(boundedLine(line))") }
        }
        if outputWasTruncated || errorWasTruncated, events.count < maximumEvents {
            events.append("Recovery output exceeded the 64 KiB display limit and was truncated")
        }

        let detail: String
        let success: Bool
        if timedOut {
            success = false
            detail = "Amber stack recovery exceeded its 75-second client timeout. Debug authority remains revoked."
        } else if terminationStatus != 0 {
            success = false
            detail = finalDetail?.isEmpty == false
                ? boundedLine(finalDetail!)
                : "Amber stack recovery exited with status \(terminationStatus). Debug authority remains revoked."
        } else if !contractWasViolated,
                  finalResultCount == 1,
                  operationID != nil,
                  finalSuccess == true {
            success = true
            detail = finalDetail?.isEmpty == false
                ? boundedLine(finalDetail!)
                : "Amber CAN/core stack and gateway passed recovery verification."
        } else {
            success = false
            detail = finalDetail?.isEmpty == false
                ? boundedLine(finalDetail!)
                : "Amber recovery did not provide a valid successful final result. Debug authority remains revoked."
        }

        return ROBAmberStackMaintenanceResult(
            success: success,
            detail: detail,
            events: Array(events.prefix(maximumEvents))
        )
    }

    private static func boundedString(_ data: Data) -> String {
        let prefix = data.prefix(maximumOutputBytes)
        return String(decoding: prefix, as: UTF8.self)
    }

    private static func boundedLine(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars)).prefix(maximumEventCharacters).description
    }
}
