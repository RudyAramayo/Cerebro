import Foundation

extension Notification.Name {
    static let ROBAmberStackMaintenanceDidChange = Notification.Name(
        "ROBAmberStackMaintenanceDidChange"
    )
}

/// Runs one fixed, root-owned recovery helper over SSH. Cerebro never sends an
/// arbitrary shell fragment and never supplies an administrator password; the
/// Ubuntu installation grants `amber` passwordless access to this exact helper
/// path with no arguments.
@objcMembers public final class ROBAmberStackMaintenanceController: NSObject {
    public static let shared = ROBAmberStackMaintenanceController()

    public private(set) var state: ROBAmberStackMaintenanceState = .idle
    public private(set) var detail = "Controller stack recovery is idle"
    public var isRunning: Bool { state == .running }

    private static let remoteHelper = "/usr/local/sbin/rob-amber-recover"
    private static let clientTimeout: TimeInterval = 75
    private var task: Process?
    private var timeoutWorkItem: DispatchWorkItem?
    private var operationID: UUID?
    private var timedOut = false

    @discardableResult
    @nonobjc public func restart(
        host rawHost: String,
        completion: @escaping (ROBAmberStackMaintenanceResult) -> Void
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return false }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHost(host) else {
            failBeforeLaunch("Enter a valid Amber hostname such as amber-master.local.")
            return false
        }
        guard let password = ROBAmberGatewayConfiguration.shared.sshPassword(),
              !password.isEmpty else {
            failBeforeLaunch("Save the Amber SSH password in Keychain before recovery.")
            return false
        }

        let sshArguments = [
            "-T",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=accept-new",
            "amber@\(host)",
            "sudo -n -- \(Self.remoteHelper)",
        ]
        let process: Process
        do {
            process = try ROBSystemDependencyManager.shared
                .newSSHpassTask(withSSHArguments: sshArguments)
        } catch {
            failBeforeLaunch(error.localizedDescription)
            return false
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let identifier = UUID()
        operationID = identifier
        task = process
        timedOut = false
        update(.running, detail: "Connecting to amber@\(host) for guarded stack recovery…")

        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let status = process.terminationStatus
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process,
                      self.operationID == identifier,
                      process === self.task else { return }
                let result = ROBAmberStackMaintenanceOutputParser.parse(
                    standardOutput: output,
                    standardError: errorOutput,
                    terminationStatus: status,
                    timedOut: self.timedOut
                )
                self.finish(result, completion: completion)
            }
        }

        do {
            try ROBSystemDependencyManager.shared.launchSSHpassTask(
                process,
                password: password
            )
        } catch {
            process.terminationHandler = nil
            task = nil
            operationID = nil
            let result = ROBAmberStackMaintenanceResult(
                success: false,
                detail: error.localizedDescription,
                events: []
            )
            update(.failed, detail: result.detail)
            return false
        }

        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process,
                  self.operationID == identifier,
                  process === self.task,
                  process.isRunning else { return }
            self.timedOut = true
            self.update(.running, detail: "Recovery timed out; closing its SSH session…")
            process.terminate()
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clientTimeout, execute: timeout)
        return true
    }

    private func finish(
        _ result: ROBAmberStackMaintenanceResult,
        completion: @escaping (ROBAmberStackMaintenanceResult) -> Void
    ) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        task?.terminationHandler = nil
        task = nil
        operationID = nil
        timedOut = false
        update(result.success ? .succeeded : .failed, detail: result.detail)
        completion(result)
    }

    /// A `false` return means no asynchronous operation was accepted, so its
    /// completion must not run. Callers handle this synchronous failure from
    /// `detail`; invoking both paths can otherwise reconnect or update the GUI
    /// twice after a launch failure.
    private func failBeforeLaunch(_ detail: String) {
        update(.failed, detail: detail)
    }

    private func update(_ state: ROBAmberStackMaintenanceState, detail: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.state = state
        self.detail = detail
        NotificationCenter.default.post(
            name: .ROBAmberStackMaintenanceDidChange,
            object: self,
            userInfo: ["state": state.rawValue, "detail": detail]
        )
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.hasPrefix("-"), !host.hasSuffix("-"),
              !host.contains("..") else { return false }
        return host.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
        }
    }
}
