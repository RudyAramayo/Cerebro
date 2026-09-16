import Foundation

@main struct BubbleConsoleTests {
    @MainActor static func main() {
        var now = 100.0
        let model = ROBBubbleConsoleModel(uptime: { now })
        var sent: [ROBBubbleCommand] = []
        model.send = { sent.append($0) }
        precondition(!model.fresh && !model.canAuthorize && !model.canEnableMount)
        precondition(model.cameraPlaceholder == "Waiting for Cerebro connection")
        var state = ROBBubbleStatus(detail: "Ready", armed: false, dryRun: true,
            spin: false, blower: false, spinReady: false, mode: "manual", remainingSeconds: 119.4,
            cooldownSeconds: 0, pan: 4000, tilt: 8000, targetDescription: "Select RGB target",
            mountLive: false, motorsLive: false, depthReady: false, mountAuthorized: false)
        model.consume(state)
        precondition(model.canAuthorize && model.canEnableMount, "Camera absence cannot block authorization")
        precondition(model.cameraPlaceholder == "Waiting for face-camera RGB")
        model.enableMount()
        precondition(sent.last?.operation == .authorizeMount && !model.canMove, "Wait for server permission before moving")
        model.authorize()
        precondition(sent.last?.operation == .authorizeMotors, "No hidden Cerebro switch is required to exit dry run")
        state.mountAuthorized = true; state.mountLive = true; state.dryRun = false
        state.cooldownSeconds = 40
        model.consume(state)
        precondition(model.canMove && !model.canAuthorize && !model.canRunMotors)
        model.applyManual()
        precondition(sent.last?.operation == .manual, "Motor cooldown must not disable Tilt/Pan")
        now += 2
        precondition(!model.canMove && !model.canAuthorize)
        model.setVisible(true)
        model.send = { _ in model.error = "Connect to an authenticated Cerebro session" }
        model.poll()
        precondition(model.error == "Connect to an authenticated Cerebro session")
        model.disconnected()
        precondition(model.status == nil && model.frameID == nil && !model.canAuthorize)
        model.allowsAuthorization = false
        state.mountAuthorized = false; state.cooldownSeconds = 0
        model.consume(state)
        precondition(model.canMove && model.canRunMotors && !model.armed, "Local controls do not require a remote grant")
        print("Bubble console fixtures passed: no-camera authorization, explicit live enable, independent movement, stale status, local control")
    }
}
