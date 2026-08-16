//
//  ROBAmberDiagnosticsWindowController.swift
//  Cerebro
//
//  Bounded Amber telemetry and supervised mode diagnostics. Manual mode
//  commands require explicit operator actions (and warnings for torque-changing
//  transitions); authority controls grant separately validated Gemini motion
//  or controller target-preview paths.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

private enum ROBAmberDiagnosticsArm: String, CaseIterable {
    case left
    case right

    var title: String { rawValue.capitalized }
}

private struct ROBAmberDiagnosticsSample {
    let receivedAt: Date
    let sequence: UInt64
    let sampleAgeMilliseconds: Double
    let positionsRadians: [Double]
    let velocitiesRadiansPerSecond: [Double]
    let currents: [Double]
    let statuses: [Double]
    let targetPositionsRadians: [Double]?
}

private struct ROBAmberDiagnosticsConnectionSnapshot {
    let state: ROBAmberGatewayState
    let detail: String
    let exclusiveControllerSession: Bool
}

/// A deliberately conservative presentation model. The current Amber vendor
/// protocol acknowledges that a command reached the arm core, but does not
/// report jaw position, force, or completion. In particular, an accepted
/// calibration is not presented as physically verified/ready.
private struct ROBAmberDiagnosticsGripperSnapshot {
    var calibrationState = "unknown"
    var calibrationVerified = false
    var feedbackAvailable = false
    var measuredOpening: Double?
    var measuredForce: Double?
    var commandInFlight = false
    var lastAction: String?
    var lastForce: Int?
    var forceMinimum = 1
    var forceMaximum = 300
    var forceUnit = "raw"
    var detail = "State has not been queried"
}

private struct ROBAmberDiagnosticsGripperControls {
    let stateLabel: NSTextField
    let feedbackLabel: NSTextField
    let forceSlider: NSSlider
    let forceLabel: NSTextField
    let queryButton: NSButton
    let calibrateButton: NSButton
    let releaseButton: NSButton
    let gripButton: NSButton
    let stopButton: NSButton

    var commandButtons: [NSButton] {
        [queryButton, calibrateButton, releaseButton, gripButton, stopButton]
    }
}

private final class ROBAmberDiagnosticsHistory {
    static let maximumSamples = 2_400
    var samples: [ROBAmberDiagnosticsSample] = []
    var currentTarget: [Double]?
    var currentTargetCommandID: UInt64?

    var latest: ROBAmberDiagnosticsSample? { samples.last }

    func append(_ sample: ROBAmberDiagnosticsSample) {
        samples.append(sample)
        let overflow = samples.count - Self.maximumSamples
        if overflow > 0 { samples.removeFirst(overflow) }
    }

    func clear() {
        samples.removeAll(keepingCapacity: true)
    }

    func recent(seconds: TimeInterval, now: Date = Date()) -> [ROBAmberDiagnosticsSample] {
        let cutoff = now.addingTimeInterval(-seconds)
        guard let first = samples.firstIndex(where: { $0.receivedAt >= cutoff }) else { return [] }
        return Array(samples[first...])
    }

    func updateRate(now: Date = Date()) -> Double {
        let recentSamples = recent(seconds: 2, now: now)
        guard recentSamples.count > 1,
              let first = recentSamples.first,
              let last = recentSamples.last else { return 0 }
        let elapsed = last.receivedAt.timeIntervalSince(first.receivedAt)
        return elapsed > 0 ? Double(recentSamples.count - 1) / elapsed : 0
    }
}

private final class ROBAmberTelemetryPlotView: NSView {
    enum Metric {
        case position
        case velocity
        case current
        case sampleAge

        var title: String {
            switch self {
            case .position: return "Position — actual solid / last target dashed"
            case .velocity: return "Velocity"
            case .current: return "Motor current"
            case .sampleAge: return "Gateway sample age"
            }
        }

        var unit: String {
            switch self {
            case .position: return "rad"
            case .velocity: return "rad/s"
            case .current: return "raw"
            case .sampleAge: return "ms"
            }
        }
    }

    private static let seriesColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple,
    ]

    let metric: Metric
    var samples: [ROBAmberDiagnosticsSample] = [] {
        didSet { needsDisplay = true }
    }

    init(metric: Metric) {
        self.metric = metric
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel(metric.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        ("\(metric.title) (\(metric.unit))" as NSString).draw(
            at: NSPoint(x: 10, y: bounds.maxY - 20), withAttributes: titleAttributes
        )

        let chart = NSRect(x: 48, y: 22, width: max(1, bounds.width - 58), height: max(1, bounds.height - 50))
        guard chart.width > 20, chart.height > 20 else { return }
        drawGrid(in: chart)
        guard samples.count > 1 else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            ("Waiting for telemetry" as NSString).draw(
                at: NSPoint(x: chart.midX - 55, y: chart.midY - 6), withAttributes: attributes
            )
            return
        }

        let range = valueRange()
        drawScaleLabels(range: range, in: chart)
        let firstTime = samples.first?.receivedAt.timeIntervalSinceReferenceDate ?? 0
        let lastTime = samples.last?.receivedAt.timeIntervalSinceReferenceDate ?? firstTime + 1
        let timeSpan = max(0.001, lastTime - firstTime)

        let seriesCount = metric == .sampleAge ? 1 : 7
        for series in 0..<seriesCount {
            let color = metric == .sampleAge ? NSColor.systemMint : Self.seriesColors[series]
            drawSeries(series, target: false, color: color, range: range,
                       chart: chart, firstTime: firstTime, timeSpan: timeSpan)
            if metric == .position {
                drawSeries(series, target: true, color: color.withAlphaComponent(0.68), range: range,
                           chart: chart, firstTime: firstTime, timeSpan: timeSpan)
            }
        }
        drawLegend()
    }

    private func drawGrid(in chart: NSRect) {
        NSColor.gridColor.withAlphaComponent(0.38).setStroke()
        for index in 0...4 {
            let fraction = CGFloat(index) / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chart.minX, y: chart.minY + chart.height * fraction))
            path.line(to: NSPoint(x: chart.maxX, y: chart.minY + chart.height * fraction))
            path.lineWidth = index == 2 ? 0.8 : 0.4
            path.stroke()
        }
        for index in 0...4 {
            let fraction = CGFloat(index) / 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chart.minX + chart.width * fraction, y: chart.minY))
            path.line(to: NSPoint(x: chart.minX + chart.width * fraction, y: chart.maxY))
            path.lineWidth = 0.35
            path.stroke()
        }
    }

    private func valueRange() -> ClosedRange<Double> {
        var values: [Double] = []
        for sample in samples {
            switch metric {
            case .position:
                values.append(contentsOf: sample.positionsRadians.filter(\.isFinite))
                if let target = sample.targetPositionsRadians {
                    values.append(contentsOf: target.filter(\.isFinite))
                }
            case .velocity:
                values.append(contentsOf: sample.velocitiesRadiansPerSecond.filter(\.isFinite))
            case .current:
                values.append(contentsOf: sample.currents.filter(\.isFinite))
            case .sampleAge:
                if sample.sampleAgeMilliseconds.isFinite { values.append(sample.sampleAgeMilliseconds) }
            }
        }
        guard let rawMin = values.min(), let rawMax = values.max() else { return -1...1 }
        if metric == .velocity || metric == .current {
            let extent = max(0.01, max(abs(rawMin), abs(rawMax)) * 1.08)
            return -extent...extent
        }
        if metric == .sampleAge {
            return 0...max(1, rawMax * 1.12)
        }
        let span = max(0.02, rawMax - rawMin)
        return (rawMin - span * 0.08)...(rawMax + span * 0.08)
    }

    private func drawScaleLabels(range: ClosedRange<Double>, in chart: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for index in 0...4 {
            let fraction = Double(index) / 4
            let value = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
            let text = String(format: "% .2f", value) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: chart.minX - size.width - 4,
                                  y: chart.minY + chart.height * CGFloat(fraction) - size.height / 2),
                      withAttributes: attributes)
        }
    }

    private func drawSeries(_ series: Int, target: Bool, color: NSColor,
                            range: ClosedRange<Double>, chart: NSRect,
                            firstTime: TimeInterval, timeSpan: TimeInterval) {
        let span = max(0.000_001, range.upperBound - range.lowerBound)
        let path = NSBezierPath()
        var hasPoint = false
        for sample in samples {
            let value: Double?
            switch metric {
            case .position:
                let source = target ? sample.targetPositionsRadians : sample.positionsRadians
                value = source.flatMap { $0.indices.contains(series) ? $0[series] : nil }
            case .velocity:
                value = sample.velocitiesRadiansPerSecond.indices.contains(series)
                    ? sample.velocitiesRadiansPerSecond[series] : nil
            case .current:
                value = sample.currents.indices.contains(series) ? sample.currents[series] : nil
            case .sampleAge:
                value = sample.sampleAgeMilliseconds
            }
            guard let value, value.isFinite else {
                hasPoint = false
                continue
            }
            let seconds = sample.receivedAt.timeIntervalSinceReferenceDate - firstTime
            let x = chart.minX + chart.width * CGFloat(seconds / timeSpan)
            let normalized = (value - range.lowerBound) / span
            let y = chart.minY + chart.height * CGFloat(min(1, max(0, normalized)))
            let point = NSPoint(x: x, y: y)
            if hasPoint { path.line(to: point) } else { path.move(to: point) }
            hasPoint = true
        }
        color.setStroke()
        path.lineWidth = target ? 1.0 : 1.35
        if target {
            var dash: [CGFloat] = [4, 3]
            path.setLineDash(&dash, count: dash.count, phase: 0)
        }
        path.stroke()
    }

    private func drawLegend() {
        guard metric != .sampleAge else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var x = max(180, bounds.maxX - 210)
        for index in 0..<7 {
            Self.seriesColors[index].setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.maxY - 17, width: 5, height: 5)).fill()
            ("J\(index + 1)" as NSString).draw(at: NSPoint(x: x + 7, y: bounds.maxY - 20), withAttributes: attributes)
            x += 29
        }
    }
}

/// A pure 2D drawing reference traced from the relaxed arm silhouette in
/// ORobotics/assets/images/pages/ROB_2026_lightsabers.webp. It contains no
/// kinematic angles and can never be reused as an actuator target.
enum ROBAmberPhotoReferenceSilhouette {
    static let label = "photo reference silhouette • not measured • not a target"
    private static let rightPoints: [CGPoint] = [
        CGPoint(x: 0.34, y: 0.92),
        CGPoint(x: 0.38, y: 0.83),
        CGPoint(x: 0.55, y: 0.72),
        CGPoint(x: 0.67, y: 0.58),
        CGPoint(x: 0.65, y: 0.43),
        CGPoint(x: 0.70, y: 0.27),
        CGPoint(x: 0.69, y: 0.10),
    ]

    static func normalizedPoints(forArm arm: String) -> [CGPoint] {
        switch arm.lowercased() {
        case "right": return rightPoints
        case "left": return rightPoints.map { CGPoint(x: 1 - $0.x, y: $0.y) }
        default: return []
        }
    }
}

private final class ROBAmberArmSchematicView: NSView {
    var leftSample: ROBAmberDiagnosticsSample? { didSet { needsDisplay = true } }
    var rightSample: ROBAmberDiagnosticsSample? { didSet { needsDisplay = true } }
    var leftTarget: [Double]? { didSet { needsDisplay = true } }
    var rightTarget: [Double]? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityLabel("Amber arm pose schematic; reference silhouettes are not measured telemetry")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        ("Arm pose — measured telemetry when available" as NSString).draw(
            at: NSPoint(x: 10, y: bounds.maxY - 20), withAttributes: attributes
        )

        let content = NSRect(x: 12, y: 15, width: max(1, bounds.width - 24), height: max(1, bounds.height - 44))
        let halfWidth = max(1, (content.width - 12) / 2)
        drawArm(.left, sample: leftSample, target: leftTarget,
                in: NSRect(x: content.minX, y: content.minY, width: halfWidth, height: content.height))
        drawArm(.right, sample: rightSample, target: rightTarget,
                in: NSRect(x: content.minX + halfWidth + 12, y: content.minY,
                           width: halfWidth, height: content.height))
    }

    private func drawArm(_ arm: ROBAmberDiagnosticsArm, sample: ROBAmberDiagnosticsSample?,
                         target: [Double]?, in rect: NSRect) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        (arm.title as NSString).draw(at: NSPoint(x: rect.minX + 2, y: rect.maxY - 12), withAttributes: labelAttributes)
        guard let sample else {
            drawPhotoReferenceSilhouette(arm, in: rect)
            return
        }

        let mount = ROBAmberMountConfiguration.shared.mount(for: arm.rawValue)
            ?? ROBAmberArmMount(translationMeters: [0, 0, 0], rotationRPYRadians: [0, 0, 0])
        guard let actual3D = ROBAmberB1Kinematics.jointOriginsInRobot(
            angles: sample.positionsRadians, mount: mount
        ) else { return }
        let actual = projected(actual3D)
        let targetPoints = target.flatMap {
            ROBAmberB1Kinematics.jointOriginsInRobot(angles: $0, mount: mount)
        }.map(projected)
        let all = actual + (targetPoints ?? [])
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
        let sourceWidth = max(0.04, maxX - minX)
        let sourceHeight = max(0.04, maxY - minY)
        let drawRect = rect.insetBy(dx: 10, dy: 16)
        let scale = min(drawRect.width / sourceWidth, drawRect.height / sourceHeight) * 0.86
        func mapped(_ point: CGPoint) -> NSPoint {
            let centeredX = point.x - (minX + maxX) / 2
            let centeredY = point.y - (minY + maxY) / 2
            return NSPoint(x: drawRect.midX + centeredX * scale,
                           y: drawRect.midY + centeredY * scale)
        }

        if let targetPoints {
            drawChain(targetPoints.map(mapped), color: NSColor.systemOrange.withAlphaComponent(0.58), dashed: true)
        }
        let stale = Date().timeIntervalSince(sample.receivedAt) > 0.5
        let outsideJointLimits = Swift.zip(sample.positionsRadians, ROBAmberB1Kinematics.joints)
            .contains { angle, joint in !(joint.lowerLimit ... joint.upperLimit).contains(angle) }
        drawChain(
            actual.map(mapped),
            color: stale || outsideJointLimits
                ? .systemRed : (arm == .left ? .systemTeal : .systemBlue),
            dashed: false
        )
    }

    private func drawPhotoReferenceSilhouette(
        _ arm: ROBAmberDiagnosticsArm,
        in rect: NSRect
    ) {
        let points = ROBAmberPhotoReferenceSilhouette.normalizedPoints(forArm: arm.rawValue)
        let drawRect = rect.insetBy(dx: 14, dy: 20)
        let mapped = points.map { point in
            NSPoint(
                x: drawRect.minX + point.x * drawRect.width,
                y: drawRect.minY + point.y * drawRect.height + 4
            )
        }
        drawChain(
            mapped,
            color: NSColor.tertiaryLabelColor.withAlphaComponent(0.32),
            dashed: true
        )
        let referenceAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (ROBAmberPhotoReferenceSilhouette.label as NSString).draw(
            in: NSRect(x: rect.minX + 2, y: rect.minY, width: rect.width - 4, height: 12),
            withAttributes: referenceAttributes
        )
    }

    private func projected(_ points: [SIMD3<Double>]) -> [CGPoint] {
        points.map { point in
            CGPoint(x: point.x - point.y * 0.58, y: point.z + point.y * 0.24)
        }
    }

    private func drawChain(_ points: [NSPoint], color: NSColor, dashed: Bool) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        points.dropFirst().forEach(path.line)
        path.lineWidth = dashed ? 1.25 : 2.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if dashed {
            var dash: [CGFloat] = [4, 3]
            path.setLineDash(&dash, count: dash.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
        if !dashed {
            color.setFill()
            for point in points {
                NSBezierPath(ovalIn: NSRect(x: point.x - 2.8, y: point.y - 2.8, width: 5.6, height: 5.6)).fill()
            }
        }
    }
}

@objcMembers public final class ROBAmberDiagnosticsWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    public static let shared = ROBAmberDiagnosticsWindowController()

    private let gateway = ROBAmberGatewayClient.shared
    private let tunnel = ROBAmberGatewayTunnel.shared
    private let configuration = ROBAmberGatewayConfiguration.shared
    private let authority = ROBAmberDebugAuthority.shared
    private let gestureCatalog = ROBAmberGestureCatalog.shared
    private let stackMaintenance = ROBAmberStackMaintenanceController.shared
    private var histories: [ROBAmberDiagnosticsArm: ROBAmberDiagnosticsHistory] = [
        .left: ROBAmberDiagnosticsHistory(),
        .right: ROBAmberDiagnosticsHistory(),
    ]
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var displayPaused = false
    private var modeSnapshots: [ROBAmberDiagnosticsArm: [Int]] = [.left: [], .right: []]
    private var credentialStatusNeedsRefresh = true
    private var pendingManualCommandIDs: Set<UInt64> = []
    private var pendingGripperCommands: [UInt64: (arm: ROBAmberDiagnosticsArm, operation: String)] = [:]
    private var gripperSnapshots: [ROBAmberDiagnosticsArm: ROBAmberDiagnosticsGripperSnapshot] = [
        .left: ROBAmberDiagnosticsGripperSnapshot(),
        .right: ROBAmberDiagnosticsGripperSnapshot(),
    ]
    private var gripperControls: [ROBAmberDiagnosticsArm: ROBAmberDiagnosticsGripperControls] = [:]
    private var logLines: [String] = []
    private let maximumLogLines = 300

    private let gatewayStateLabel = NSTextField(labelWithString: "Gateway disconnected")
    private let tunnelStateLabel = NSTextField(labelWithString: "Tunnel disconnected")
    private let credentialStatusLabel = NSTextField(labelWithString: "")
    private let authorityStatusLabel = NSTextField(labelWithString: "Debug authority is off")
    private let tokenField = NSSecureTextField()
    private let passwordField = NSSecureTextField()
    private let hostField = NSTextField(string: "amber-master.local")
    private let restartStackButton = NSButton(
        title: "Restart CAN/Core Stack…",
        target: nil,
        action: nil
    )
    private let stackMaintenanceStatusLabel = NSTextField(labelWithString: "Controller stack idle")
    private var stackRecoveryInProgress = false
    private var stackMaintenanceStatusOverride: (text: String, color: NSColor)?
    private let geminiAuthorityButton = NSButton(checkboxWithTitle: "Gemini hand-movement tools", target: nil, action: nil)
    private let controllerAuthorityButton = NSButton(checkboxWithTitle: "Vision Pro gripper commands", target: nil, action: nil)
    private let gestureNameField = NSTextField()
    private let approvedGesturePopup = NSPopUpButton()
    private let runSelectedGestureButton = NSButton(
        title: "Run Selected Gesture…",
        target: nil,
        action: nil
    )
    private let gestureStatusLabel = NSTextField(labelWithString: "No approved Gemini gestures")
    private let keyframeCaptureStatusLabel = NSTextField(
        labelWithString: "Copies fresh measured telemetry; does not move either arm"
    )
    private let commandArmSelector = NSSegmentedControl(
        labels: ["Left arm", "Right arm"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var armCommandButtons: [NSButton] = []
    private let pauseButton = NSButton(checkboxWithTitle: "Pause display", target: nil, action: nil)
    private let graphArmSelector = NSSegmentedControl(labels: ["Left arm", "Right arm"], trackingMode: .selectOne,
                                                       target: nil, action: nil)
    private let leftTable = NSTableView()
    private let rightTable = NSTableView()
    private let leftSummary = NSTextField(labelWithString: "Waiting for left-arm telemetry")
    private let rightSummary = NSTextField(labelWithString: "Waiting for right-arm telemetry")
    private let positionPlot = ROBAmberTelemetryPlotView(metric: .position)
    private let velocityPlot = ROBAmberTelemetryPlotView(metric: .velocity)
    private let currentPlot = ROBAmberTelemetryPlotView(metric: .current)
    private let sampleAgePlot = ROBAmberTelemetryPlotView(metric: .sampleAge)
    private let schematicView = ROBAmberArmSchematicView()
    private let eventLogView = NSTextView()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_380, height: 980),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Amber Arm Diagnostics"
        window.minSize = NSSize(width: 1_200, height: 930)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildInterface()
        installObservers()
        ingestExistingTelemetry()
        appendEvent("Diagnostics initialized; gripper actions and torque-changing arm modes require local confirmation")
        refreshGestureCatalog()
        refreshDisplay()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        refreshTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        credentialStatusNeedsRefresh = true
        startRefreshTimer()
        refreshDisplay()
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Lets command producers mirror a requested target in the diagnostics UI.
    /// Recording a target is display-only and does not send anything to Amber.
    @objc(recordTargetForArm:positionsRadians:commandID:)
    public func recordTarget(forArm armName: String, positionsRadians: [NSNumber], commandID: UInt64) {
        let values = positionsRadians.map(\.doubleValue)
        guard let arm = ROBAmberDiagnosticsArm(rawValue: armName.lowercased()),
              values.count == 7, values.allSatisfy(\.isFinite) else { return }
        DispatchQueue.main.async {
            self.histories[arm]?.currentTarget = values
            self.histories[arm]?.currentTargetCommandID = commandID
            self.appendEvent("\(arm.title) target recorded for command \(commandID)")
            self.refreshDisplay()
        }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        gatewayStateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        gatewayStateLabel.lineBreakMode = .byTruncatingMiddle
        tunnelStateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tunnelStateLabel.textColor = .secondaryLabelColor
        tunnelStateLabel.lineBreakMode = .byTruncatingMiddle
        let stateStack = NSStackView(views: [gatewayStateLabel, tunnelStateLabel])
        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = 2

        let safetyLabel = NSTextField(labelWithString: "SUPERVISED ROBOT DEBUG — gripper and torque-changing actions require confirmation")
        safetyLabel.font = .systemFont(ofSize: 11, weight: .bold)
        safetyLabel.textColor = .systemOrange
        let stateRow = NSStackView(views: [stateStack, NSView(), safetyLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 10

        tokenField.placeholderString = "Gateway token (stored value is never shown)"
        passwordField.placeholderString = "SSH password"
        hostField.placeholderString = "amber-master.local"
        for field in [tokenField, passwordField, hostField] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        tokenField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        hostField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let saveCredentialsButton = makeButton("Save in Keychain", action: #selector(saveCredentials(_:)))
        let removeCredentialsButton = makeButton("Remove Credentials…", action: #selector(removeCredentials(_:)))
        let connectButton = makeButton("Connect Tunnel", action: #selector(connectTunnel(_:)))
        let disconnectButton = makeButton("Disconnect", action: #selector(disconnectTunnel(_:)))
        credentialStatusLabel.font = .systemFont(ofSize: 10)
        credentialStatusLabel.textColor = .secondaryLabelColor
        credentialStatusLabel.lineBreakMode = .byTruncatingTail
        credentialStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let credentialRow = NSStackView(views: [
            NSTextField(labelWithString: "Host"), hostField,
            NSTextField(labelWithString: "Token"), tokenField,
            NSTextField(labelWithString: "SSH"), passwordField,
            saveCredentialsButton, removeCredentialsButton, connectButton, disconnectButton,
        ])
        credentialRow.orientation = .horizontal
        credentialRow.alignment = .centerY
        credentialRow.spacing = 7
        let credentialStack = NSStackView(views: [credentialRow, credentialStatusLabel])
        credentialStack.orientation = .vertical
        credentialStack.alignment = .leading
        credentialStack.spacing = 4

        restartStackButton.target = self
        restartStackButton.action = #selector(restartCANCoreStack(_:))
        restartStackButton.bezelStyle = .rounded
        restartStackButton.contentTintColor = .systemOrange
        restartStackButton.toolTip = "Stops and restarts the Amber gateway, CAN setup, and both vendor cores after an explicit typed confirmation."
        let wakeUpCalibrationButton = makeButton(
            "Wake-Up Calibration (Dry Run)…",
            action: #selector(showWakeUpCalibration(_:))
        )
        wakeUpCalibrationButton.toolTip = "Opens the non-actuating ordered startup checklist. It reads snapshots and records local review only."
        stackMaintenanceStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stackMaintenanceStatusLabel.textColor = .secondaryLabelColor
        stackMaintenanceStatusLabel.lineBreakMode = .byTruncatingTail
        stackMaintenanceStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stackMaintenanceWarning = NSTextField(
            labelWithString: "Both arms can lose torque and feedback during recovery; physically support them."
        )
        stackMaintenanceWarning.font = .systemFont(ofSize: 10, weight: .semibold)
        stackMaintenanceWarning.textColor = .systemOrange
        stackMaintenanceWarning.lineBreakMode = .byTruncatingTail
        stackMaintenanceWarning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stackMaintenanceRow = NSStackView(views: [
            NSTextField(labelWithString: "Controller Stack"), restartStackButton,
            wakeUpCalibrationButton, stackMaintenanceStatusLabel, NSView(), stackMaintenanceWarning,
        ])
        stackMaintenanceRow.orientation = .horizontal
        stackMaintenanceRow.alignment = .centerY
        stackMaintenanceRow.spacing = 8

        geminiAuthorityButton.toolTip = "Temporarily permits Gemini-originated arm requests after all command validation passes."
        controllerAuthorityButton.toolTip = "Temporarily permits bounded authenticated Vision Pro gripper hold/release commands after local calibration. Joint-arm motion uses separate per-arm rob-arm-control/2 authority bound to the current authenticated session."
        let grantButton = makeButton("Enable selected for 15 minutes", action: #selector(grantAuthority(_:)))
        let revokeButton = makeButton("Revoke now", action: #selector(revokeAuthority(_:)))
        revokeButton.contentTintColor = .systemRed
        authorityStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        authorityStatusLabel.textColor = .secondaryLabelColor
        authorityStatusLabel.lineBreakMode = .byTruncatingTail
        authorityStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let authorityRow = NSStackView(views: [
            geminiAuthorityButton, controllerAuthorityButton, grantButton, revokeButton,
            NSView(), authorityStatusLabel,
        ])
        authorityRow.orientation = .horizontal
        authorityRow.alignment = .centerY
        authorityRow.spacing = 10

        gestureNameField.placeholderString = "Gesture name"
        gestureNameField.font = .systemFont(ofSize: 11)
        gestureNameField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        gestureNameField.toolTip = "Name the immutable copy of the current keyframe that Gemini may request while debug authority is active."
        approvedGesturePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        approvedGesturePopup.target = self
        approvedGesturePopup.action = #selector(approvedGestureChanged(_:))
        let approveGestureButton = makeButton("Approve Current Keyframe", action: #selector(approveGesture(_:)))
        let revokeGestureButton = makeButton("Revoke Gesture…", action: #selector(revokeGesture(_:)))
        runSelectedGestureButton.target = self
        runSelectedGestureButton.action = #selector(runSelectedGesture(_:))
        runSelectedGestureButton.bezelStyle = .rounded
        runSelectedGestureButton.contentTintColor = .systemOrange
        runSelectedGestureButton.toolTip = "Runs the selected immutable gesture on the physical Amber arms after a critical confirmation. All executor authority, mode, freshness, step, speed, and measured-completion checks still apply."
        gestureStatusLabel.font = .systemFont(ofSize: 10)
        gestureStatusLabel.textColor = .secondaryLabelColor
        gestureStatusLabel.lineBreakMode = .byTruncatingTail
        gestureStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let gestureRow = NSStackView(views: [
            NSTextField(labelWithString: "Gemini Gesture"), gestureNameField,
            approveGestureButton, NSTextField(labelWithString: "Approved"), approvedGesturePopup,
            runSelectedGestureButton, revokeGestureButton, NSView(), gestureStatusLabel,
        ])
        gestureRow.orientation = .horizontal
        gestureRow.alignment = .centerY
        gestureRow.spacing = 8

        let captureLeftButton = makeButton(
            "Capture Left Measured → Keyframe",
            action: #selector(captureLeftMeasuredPose(_:))
        )
        let captureRightButton = makeButton(
            "Capture Right Measured → Keyframe",
            action: #selector(captureRightMeasuredPose(_:))
        )
        keyframeCaptureStatusLabel.font = .systemFont(ofSize: 10)
        keyframeCaptureStatusLabel.textColor = .secondaryLabelColor
        keyframeCaptureStatusLabel.lineBreakMode = .byTruncatingTail
        keyframeCaptureStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let keyframeCaptureRow = NSStackView(views: [
            NSTextField(labelWithString: "Measured Keyframe"), captureLeftButton,
            captureRightButton, NSView(), keyframeCaptureStatusLabel,
        ])
        keyframeCaptureRow.orientation = .horizontal
        keyframeCaptureRow.alignment = .centerY
        keyframeCaptureRow.spacing = 8

        commandArmSelector.selectedSegment = 0
        commandArmSelector.toolTip = "Select the arm for the manual mode command."
        let queryModeButton = makeButton("Query Mode", action: #selector(querySelectedArmMode(_:)))
        let activateButton = makeButton("Activate…", action: #selector(activateSelectedArm(_:)))
        let positionButton = makeButton("Position + Hold…", action: #selector(positionSelectedArm(_:)))
        let holdButton = makeButton("Hold Measured Pose", action: #selector(holdSelectedArm(_:)))
        let deactivateButton = makeButton("Deactivate…", action: #selector(deactivateSelectedArm(_:)))
        deactivateButton.contentTintColor = .systemRed
        armCommandButtons = [queryModeButton, activateButton, positionButton,
                             holdButton, deactivateButton]
        let commandWarning = NSTextField(
            labelWithString: "Mode switching momentarily cuts power; support the arm and keep the physical E-stop ready."
        )
        commandWarning.font = .systemFont(ofSize: 10, weight: .semibold)
        commandWarning.textColor = .systemOrange
        commandWarning.lineBreakMode = .byTruncatingTail
        commandWarning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let commandRow = NSStackView(views: [
            NSTextField(labelWithString: "Manual Mode"), commandArmSelector,
            queryModeButton, activateButton, positionButton, holdButton,
            deactivateButton, NSView(), commandWarning,
        ])
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 8

        let gripperRow = NSStackView(views: ROBAmberDiagnosticsArm.allCases.map(makeGripperPanel))
        gripperRow.orientation = .horizontal
        gripperRow.distribution = .fillEqually
        gripperRow.spacing = 10

        configureTable(leftTable, arm: .left)
        configureTable(rightTable, arm: .right)
        let leftPanel = makeArmTablePanel(.left, table: leftTable, summary: leftSummary)
        let rightPanel = makeArmTablePanel(.right, table: rightTable, summary: rightSummary)
        let tableRow = NSStackView(views: [leftPanel, rightPanel])
        tableRow.orientation = .horizontal
        tableRow.distribution = .fillEqually
        tableRow.spacing = 10

        graphArmSelector.selectedSegment = 0
        graphArmSelector.target = self
        graphArmSelector.action = #selector(graphArmChanged(_:))
        pauseButton.target = self
        pauseButton.action = #selector(pauseDisplayChanged(_:))
        pauseButton.toolTip = "Freezes tables and plots while Cerebro continues buffering gateway telemetry."
        let clearButton = makeButton("Clear history", action: #selector(clearHistory(_:)))
        let exportButton = makeButton("Export CSV…", action: #selector(exportCSV(_:)))
        let graphControls = NSStackView(views: [
            NSTextField(labelWithString: "Graphs"), graphArmSelector, pauseButton,
            clearButton, exportButton, NSView(),
            NSTextField(labelWithString: "60-second display • bounded to 2,400 samples per arm"),
        ])
        graphControls.orientation = .horizontal
        graphControls.alignment = .centerY
        graphControls.spacing = 8
        if let note = graphControls.arrangedSubviews.last as? NSTextField {
            note.font = .systemFont(ofSize: 10)
            note.textColor = .secondaryLabelColor
        }

        let plotTopRow = NSStackView(views: [positionPlot, velocityPlot])
        plotTopRow.orientation = .horizontal
        plotTopRow.distribution = .fillEqually
        plotTopRow.spacing = 10
        let plotBottomRow = NSStackView(views: [currentPlot, sampleAgePlot])
        plotBottomRow.orientation = .horizontal
        plotBottomRow.distribution = .fillEqually
        plotBottomRow.spacing = 10
        let plots = NSStackView(views: [plotTopRow, plotBottomRow])
        plots.orientation = .vertical
        plots.distribution = .fillEqually
        plots.spacing = 10

        eventLogView.isEditable = false
        eventLogView.isSelectable = true
        eventLogView.isRichText = false
        eventLogView.frame = NSRect(x: 0, y: 0, width: 700, height: 120)
        eventLogView.autoresizingMask = [.width]
        eventLogView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        eventLogView.textColor = .secondaryLabelColor
        eventLogView.textContainerInset = NSSize(width: 7, height: 6)
        let eventScroll = NSScrollView()
        eventScroll.hasVerticalScroller = true
        eventScroll.autohidesScrollers = true
        eventScroll.borderType = .bezelBorder
        eventScroll.documentView = eventLogView
        let eventStack = NSStackView(views: [NSTextField(labelWithString: "Connection and command events"), eventScroll])
        eventStack.orientation = .vertical
        eventStack.alignment = .leading
        eventStack.spacing = 4
        eventScroll.widthAnchor.constraint(equalTo: eventStack.widthAnchor).isActive = true
        let bottomRow = NSStackView(views: [schematicView, eventStack])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fillProportionally
        bottomRow.spacing = 10
        schematicView.widthAnchor.constraint(equalTo: bottomRow.widthAnchor, multiplier: 0.42).isActive = true

        for view in [stateRow, credentialStack, stackMaintenanceRow, authorityRow,
                     keyframeCaptureRow, gestureRow,
                     commandRow, gripperRow, tableRow, graphControls, plots, bottomRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stateRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stateRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stateRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            credentialStack.topAnchor.constraint(equalTo: stateRow.bottomAnchor, constant: 9),
            credentialStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            credentialStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            stackMaintenanceRow.topAnchor.constraint(equalTo: credentialStack.bottomAnchor, constant: 9),
            stackMaintenanceRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stackMaintenanceRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            authorityRow.topAnchor.constraint(equalTo: stackMaintenanceRow.bottomAnchor, constant: 9),
            authorityRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            authorityRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            keyframeCaptureRow.topAnchor.constraint(equalTo: authorityRow.bottomAnchor, constant: 8),
            keyframeCaptureRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            keyframeCaptureRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            gestureRow.topAnchor.constraint(equalTo: keyframeCaptureRow.bottomAnchor, constant: 8),
            gestureRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            gestureRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            commandRow.topAnchor.constraint(equalTo: gestureRow.bottomAnchor, constant: 8),
            commandRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            commandRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            gripperRow.topAnchor.constraint(equalTo: commandRow.bottomAnchor, constant: 8),
            gripperRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            gripperRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            gripperRow.heightAnchor.constraint(equalToConstant: 72),

            tableRow.topAnchor.constraint(equalTo: gripperRow.bottomAnchor, constant: 9),
            tableRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tableRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tableRow.heightAnchor.constraint(equalToConstant: 195),

            graphControls.topAnchor.constraint(equalTo: tableRow.bottomAnchor, constant: 9),
            graphControls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            graphControls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            plots.topAnchor.constraint(equalTo: graphControls.bottomAnchor, constant: 7),
            plots.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            plots.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            plots.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),
            positionPlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            currentPlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),

            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            bottomRow.heightAnchor.constraint(equalToConstant: 130),
        ])
    }

    private func configureTable(_ table: NSTableView, arm: ROBAmberDiagnosticsArm) {
        let definitions: [(String, String, CGFloat)] = [
            ("joint", "Joint", 52),
            ("positionRad", "Position rad", 88),
            ("positionDeg", "Position °", 82),
            ("targetDeg", "Last target °", 90),
            ("errorDeg", "Error °", 74),
            ("velocity", "Velocity rad/s", 105),
            ("current", "Current", 76),
            ("mode", "Mode", 84),
            ("status", "Status raw", 78),
        ]
        for definition in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.0))
            column.title = definition.1
            column.width = definition.2
            column.minWidth = max(45, definition.2 - 20)
            table.addTableColumn(column)
        }
        table.identifier = NSUserInterfaceItemIdentifier("\(arm.rawValue)-telemetry")
        table.frame = NSRect(x: 0, y: 0, width: 640, height: 142)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("\(arm.title) Amber joint telemetry")
    }

    private func makeArmTablePanel(_ arm: ROBAmberDiagnosticsArm, table: NSTableView,
                                   summary: NSTextField) -> NSView {
        let heading = NSTextField(labelWithString: "\(arm.title) arm — measured state")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        summary.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        let header = NSStackView(views: [heading, NSView(), summary])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let panel = NSStackView(views: [header, scroll])
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 5
        scroll.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        return panel
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func makeGripperPanel(_ arm: ROBAmberDiagnosticsArm) -> NSView {
        let stateLabel = NSTextField(labelWithString: "State unknown")
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let feedbackLabel = NSTextField(
            labelWithString: "Opening — • Force — • feedback not reported"
        )
        feedbackLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.lineBreakMode = .byTruncatingTail
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let forceLabel = NSTextField(labelWithString: "Cmd force 10")
        forceLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        forceLabel.alignment = .right
        forceLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let forceSlider = NSSlider(value: 10, minValue: 2, maxValue: 20,
                                   target: self, action: #selector(gripperForceChanged(_:)))
        forceSlider.isContinuous = true
        forceSlider.tag = arm == .left ? 0 : 1
        forceSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        forceSlider.toolTip = "Raw Amber grip intensity. Diagnostics intentionally limits the vendor's 1–300 range to 2–20."

        func actionButton(_ title: String, action: Selector) -> NSButton {
            let button = makeButton(title, action: action)
            button.tag = arm == .left ? 0 : 1
            return button
        }
        let queryButton = actionButton("Refresh", action: #selector(queryGripperState(_:)))
        queryButton.toolTip = "Queries the authenticated gateway's per-session calibration state. This does not move the gripper."
        let calibrateButton = actionButton("Calibrate…", action: #selector(calibrateGripper(_:)))
        calibrateButton.contentTintColor = .systemOrange
        calibrateButton.toolTip = "Calibration can move this gripper through its travel and requires a critical confirmation."
        let releaseButton = actionButton("Release…", action: #selector(releaseGripper(_:)))
        releaseButton.contentTintColor = .systemOrange
        releaseButton.toolTip = "Commands this gripper to open at the bounded raw intensity after confirmation."
        let gripButton = actionButton("Grip…", action: #selector(gripGripper(_:)))
        gripButton.contentTintColor = .systemOrange
        gripButton.toolTip = "Commands this gripper to close at the bounded raw intensity after confirmation."
        let stopButton = actionButton("Stop N/A", action: #selector(stopGripperUnavailable(_:)))
        stopButton.isEnabled = false
        stopButton.toolTip = "Amber exposes release, hold, and calibration only. It has no verified stop primitive; release would itself cause motion and may drop an object."

        let statusRow = NSStackView(views: [stateLabel, NSView(), feedbackLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        let commandRow = NSStackView(views: [
            forceLabel, forceSlider, queryButton, calibrateButton,
            releaseButton, gripButton, stopButton,
        ])
        commandRow.orientation = .horizontal
        commandRow.alignment = .centerY
        commandRow.spacing = 6
        let contentStack = NSStackView(views: [statusRow, commandRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 3
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.title = "\(arm.title) gripper"
        box.titlePosition = .atTop
        box.boxType = .primary
        guard let contentView = box.contentView else { return box }
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -7),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -3),
            statusRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        gripperControls[arm] = ROBAmberDiagnosticsGripperControls(
            stateLabel: stateLabel,
            feedbackLabel: feedbackLabel,
            forceSlider: forceSlider,
            forceLabel: forceLabel,
            queryButton: queryButton,
            calibrateButton: calibrateButton,
            releaseButton: releaseButton,
            gripButton: gripButton,
            stopButton: stopButton
        )
        return box
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ROBAmberGatewayTelemetryDidUpdate,
                                            object: gateway, queue: nil) { [weak self] notification in
            guard let telemetry = notification.userInfo?["telemetry"] as? ROBAmberGatewayTelemetry else { return }
            DispatchQueue.main.async { self?.ingest(telemetry) }
        })
        observers.append(center.addObserver(forName: .ROBAmberGatewayGripperDidUpdate,
                                            object: gateway, queue: nil) { [weak self] notification in
            let flattened = notification.userInfo ?? [:]
            let snapshot = (flattened["snapshot"] as? NSDictionary)
                .flatMap { $0 as? [AnyHashable: Any] } ?? flattened
            DispatchQueue.main.async {
                self?.ingestGripperSnapshot(snapshot)
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberGatewayStateDidChange,
                                            object: gateway, queue: nil) { [weak self] notification in
            let detail = notification.userInfo?["detail"] as? String ?? "Gateway state changed"
            DispatchQueue.main.async {
                let state = (notification.userInfo?["state"] as? NSNumber)?.intValue
                    ?? (notification.userInfo?["state"] as? Int)
                if let state,
                   state != ROBAmberGatewayState.ready.rawValue {
                    self?.pendingManualCommandIDs.removeAll()
                    self?.pendingGripperCommands.removeAll()
                    for arm in ROBAmberDiagnosticsArm.allCases {
                        self?.gripperSnapshots[arm] = ROBAmberDiagnosticsGripperSnapshot(
                            calibrationState: "required",
                            calibrationVerified: false,
                            feedbackAvailable: false,
                            measuredOpening: nil,
                            measuredForce: nil,
                            commandInFlight: false,
                            detail: "Gateway session ended; calibration authorization reset"
                        )
                    }
                    self?.histories.values.forEach {
                        $0.currentTarget = nil
                        $0.currentTargetCommandID = nil
                    }
                }
                self?.appendEvent(detail)
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberGatewayCommandDidComplete,
                                            object: gateway, queue: nil) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            let command = (info["commandID"] as? NSNumber)?.uint64Value
                ?? (info["commandID"] as? UInt64) ?? 0
            let accepted = (info["accepted"] as? NSNumber)?.boolValue
                ?? (info["accepted"] as? Bool) ?? false
            let operation = info["operation"] as? String ?? "command"
            let arm = info["arm"] as? String ?? "arm"
            let response = (info["amberResponse"] as? NSNumber)?.intValue
                ?? (info["amberResponse"] as? Int) ?? -1
            let latency = (info["latencyMilliseconds"] as? NSNumber)?.doubleValue
                ?? (info["latencyMilliseconds"] as? Double) ?? .infinity
            let error = info["error"] as? String ?? ""
            let captured = (info["capturedPositionsRadians"] as? [Double])
                ?? (info["capturedPositionsRadians"] as? [NSNumber])?.map(\.doubleValue)
            DispatchQueue.main.async {
                self?.pendingManualCommandIDs.remove(command)
                self?.handleGripperCommandCompletion(
                    commandID: command,
                    operation: operation,
                    armName: arm,
                    accepted: accepted,
                    error: error,
                    info: info
                )
                if let captured, captured.count == 7,
                   let diagnosticsArm = ROBAmberDiagnosticsArm(rawValue: arm) {
                    self?.histories[diagnosticsArm]?.currentTarget = captured
                    self?.histories[diagnosticsArm]?.currentTargetCommandID = command
                }
                let suffix = error.isEmpty ? "" : " • \(error)"
                if operation.hasPrefix("gripper_") {
                    let physical = ["gripper_calibrate", "gripper_control"].contains(operation)
                    var parts = [
                        "\(arm) \(operation)",
                        "command \(command) \(accepted ? "accepted" : "rejected")",
                    ]
                    if response >= 0 { parts.append("vendor response \(response)") }
                    if latency.isFinite { parts.append(String(format: "%.2f ms", latency)) }
                    if physical && accepted {
                        let verified = (info["completionVerified"] as? NSNumber)?.boolValue
                            ?? (info["completionVerified"] as? Bool) ?? false
                        parts.append(verified ? "completion verified" : "physical completion unverified")
                    }
                    if !error.isEmpty { parts.append(error) }
                    self?.appendEvent(parts.joined(separator: " • "))
                } else {
                    self?.appendEvent(String(format: "%@ %@ • command %llu %@ • Amber %d • %.2f ms%@",
                                             arm, operation, command, accepted ? "accepted" : "rejected",
                                             response, latency, suffix))
                }
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberGatewayTunnelDidChange,
                                            object: tunnel, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                self?.appendEvent(self?.tunnel.detail ?? "Tunnel state changed")
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberStackMaintenanceDidChange,
                                            object: stackMaintenance, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                if self?.stackMaintenance.isRunning == true {
                    self?.stackMaintenanceStatusOverride = nil
                }
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberDebugAuthorityDidChange,
                                            object: authority, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                self?.appendEvent(self?.authority.isEnabled == true
                    ? "Temporary debug authority enabled" : "Debug authority revoked")
                self?.refreshDisplay()
            }
        })
        observers.append(center.addObserver(forName: .ROBAmberGestureCatalogDidChange,
                                            object: gestureCatalog, queue: nil) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshGestureCatalog()
                self?.appendEvent("Approved Gemini gesture catalog changed")
            }
        })
        observers.append(center.addObserver(forName: Notification.Name("ROBAmberGatewayTargetDidChange"),
                                            object: nil, queue: nil) { [weak self] notification in
            guard let arm = notification.userInfo?["arm"] as? String,
                  let positions = notification.userInfo?["positionsRadians"] as? [NSNumber] else { return }
            let command = (notification.userInfo?["commandID"] as? NSNumber)?.uint64Value ?? 0
            self?.recordTarget(forArm: arm, positionsRadians: positions, commandID: command)
        })
    }

    private func ingestExistingTelemetry() {
        if let left = gateway.telemetry(forArm: "left") { ingest(left) }
        if let right = gateway.telemetry(forArm: "right") { ingest(right) }
        for arm in ROBAmberDiagnosticsArm.allCases {
            if let snapshot = gateway.gripperSnapshot(forArm: arm.rawValue) as? [AnyHashable: Any] {
                ingestGripperSnapshot(snapshot, fallbackArm: arm)
            }
        }
    }

    private func ingestGripperSnapshot(
        _ dictionary: [AnyHashable: Any],
        fallbackArm: ROBAmberDiagnosticsArm? = nil
    ) {
        guard let arm = stringValue(in: dictionary, keys: ["arm"])
            .flatMap({ ROBAmberDiagnosticsArm(rawValue: $0.lowercased()) }) ?? fallbackArm else { return }
        var snapshot = gripperSnapshots[arm] ?? ROBAmberDiagnosticsGripperSnapshot()
        if let value = stringValue(in: dictionary, keys: ["calibrationState"]) {
            snapshot.calibrationState = value
        }
        if let value = boolValue(in: dictionary, keys: ["calibrationVerified"]) {
            snapshot.calibrationVerified = value
        }
        if let value = boolValue(in: dictionary, keys: ["feedbackAvailable"]) {
            snapshot.feedbackAvailable = value
        }
        if let value = boolValue(in: dictionary, keys: ["commandInFlight"]) {
            snapshot.commandInFlight = value
        }
        if dictionary["lastAction"] != nil {
            let value = stringValue(in: dictionary, keys: ["lastAction"])
            snapshot.lastAction = value?.isEmpty == false ? value : nil
        }
        if dictionary["lastForce"] != nil {
            snapshot.lastForce = integerValue(in: dictionary, keys: ["lastForce"])
        }
        if let value = integerValue(in: dictionary, keys: ["forceMin"]) {
            snapshot.forceMinimum = value
        }
        if let value = integerValue(in: dictionary, keys: ["forceMax"]) {
            snapshot.forceMaximum = value
        }
        if let value = stringValue(in: dictionary, keys: ["forceUnit"]), !value.isEmpty {
            snapshot.forceUnit = value
        }
        if let value = stringValue(in: dictionary, keys: ["detail"]), !value.isEmpty {
            snapshot.detail = value
        }
        // The current schema intentionally has no measuredOpening/measuredForce.
        // If a future gateway publishes them, render only finite explicit values.
        snapshot.measuredOpening = doubleValue(in: dictionary, keys: ["measuredOpening"])
        snapshot.measuredForce = doubleValue(in: dictionary, keys: ["measuredForce"])
        gripperSnapshots[arm] = snapshot

        if let controls = gripperControls[arm] {
            let safeMinimum = max(2, snapshot.forceMinimum)
            let safeMaximum = min(20, snapshot.forceMaximum)
            if safeMinimum <= safeMaximum {
                controls.forceSlider.minValue = Double(safeMinimum)
                controls.forceSlider.maxValue = Double(safeMaximum)
                let bounded = min(safeMaximum, max(safeMinimum, controls.forceSlider.integerValue))
                controls.forceSlider.integerValue = bounded
                controls.forceLabel.stringValue = "Cmd force \(bounded)"
            }
        }
    }

    private func ingest(_ telemetry: ROBAmberGatewayTelemetry) {
        guard let arm = ROBAmberDiagnosticsArm(rawValue: telemetry.arm.lowercased()),
              telemetry.sampleAgeMilliseconds.isFinite,
              telemetry.sampleAgeMilliseconds >= 0,
              telemetry.positionsRadians.count == 7,
              telemetry.velocitiesRadiansPerSecond.count == 7,
              telemetry.currents.count == 7,
              telemetry.statuses.count == 7,
              let history = histories[arm] else { return }
        let positions = telemetry.positionsRadians.map(\.doubleValue)
        let velocities = telemetry.velocitiesRadiansPerSecond.map(\.doubleValue)
        let currents = telemetry.currents.map(\.doubleValue)
        let statuses = telemetry.statuses.map(\.doubleValue)
        guard positions.allSatisfy(\.isFinite),
              velocities.allSatisfy(\.isFinite),
              currents.allSatisfy(\.isFinite),
              statuses.allSatisfy(\.isFinite) else { return }
        let sample = ROBAmberDiagnosticsSample(
            receivedAt: Date(),
            sequence: telemetry.sequence,
            sampleAgeMilliseconds: telemetry.sampleAgeMilliseconds,
            positionsRadians: positions,
            velocitiesRadiansPerSecond: velocities,
            currents: currents,
            statuses: statuses,
            targetPositionsRadians: history.currentTarget
        )
        history.append(sample)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshDisplay() {
        let connection = connectionSnapshot()
        synchronizeGatewayTargets()
        gatewayStateLabel.stringValue = gatewayStateText(connection)
        gatewayStateLabel.textColor = connection.state == .ready ? .systemGreen
            : (connection.state == .failed ? .systemRed : .labelColor)
        tunnelStateLabel.stringValue = tunnel.detail
        refreshCredentialStatusIfNeeded()
        let gestureIsExecuting = ROBAmberGestureExecutor.shared.isExecuting
        let gripperCommandIsActive = hasActiveGripperCommand()
        armCommandButtons.forEach {
            $0.isEnabled = connection.state == .ready
                && connection.exclusiveControllerSession
                && pendingManualCommandIDs.isEmpty
                && !gripperCommandIsActive
                && !gestureIsExecuting
                && !stackMaintenance.isRunning
                && !stackRecoveryInProgress
        }
        restartStackButton.isEnabled = !stackMaintenance.isRunning
            && !stackRecoveryInProgress
            && pendingManualCommandIDs.isEmpty
            && !gripperCommandIsActive
            && !gestureIsExecuting
        runSelectedGestureButton.isEnabled = approvedGesturePopup.isEnabled
            && !gestureIsExecuting
            && pendingManualCommandIDs.isEmpty
            && !gripperCommandIsActive
            && !stackMaintenance.isRunning
            && !stackRecoveryInProgress
        refreshGripperPanels(connection: connection, gestureIsExecuting: gestureIsExecuting)
        refreshStackMaintenanceStatus()
        refreshAuthorityStatus()
        guard !displayPaused else { return }

        for arm in ROBAmberDiagnosticsArm.allCases {
            modeSnapshots[arm] = gateway.modes(forArm: arm.rawValue).map(\.intValue)
        }
        leftTable.reloadData()
        rightTable.reloadData()
        refreshSummary(.left, label: leftSummary)
        refreshSummary(.right, label: rightSummary)
        let selected: ROBAmberDiagnosticsArm = graphArmSelector.selectedSegment == 1 ? .right : .left
        let samples = histories[selected]?.recent(seconds: 60) ?? []
        positionPlot.samples = samples
        velocityPlot.samples = samples
        currentPlot.samples = samples
        sampleAgePlot.samples = samples
        schematicView.leftSample = histories[.left]?.latest
        schematicView.rightSample = histories[.right]?.latest
        schematicView.leftTarget = histories[.left]?.currentTarget
        schematicView.rightTarget = histories[.right]?.currentTarget
    }

    private func synchronizeGatewayTargets() {
        for arm in ROBAmberDiagnosticsArm.allCases {
            let bridged = gateway.targetPositions(forArm: arm.rawValue)
            guard bridged.count == 7 else { continue }
            let values = bridged.map(\.doubleValue)
            guard values.allSatisfy(\.isFinite) else { continue }
            histories[arm]?.currentTarget = values
        }
    }

    private func connectionSnapshot() -> ROBAmberDiagnosticsConnectionSnapshot {
        let dictionary = gateway.connectionSnapshot()
        let rawState = (dictionary["state"] as? NSNumber)?.intValue
            ?? ROBAmberGatewayState.disconnected.rawValue
        let state = ROBAmberGatewayState(rawValue: rawState) ?? .disconnected
        return ROBAmberDiagnosticsConnectionSnapshot(
            state: state,
            detail: dictionary["detail"] as? String ?? "Disconnected",
            exclusiveControllerSession: (dictionary["exclusiveControllerSession"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func gatewayStateText(_ snapshot: ROBAmberDiagnosticsConnectionSnapshot) -> String {
        let name: String
        switch snapshot.state {
        case .disconnected: name = "disconnected"
        case .connecting: name = "connecting"
        case .authenticating: name = "authenticating"
        case .ready: name = "ready"
        case .failed: name = "failed"
        @unknown default: name = "unknown"
        }
        let ownership = snapshot.state == .ready && snapshot.exclusiveControllerSession
            ? " • exclusive controller" : ""
        return "Gateway \(name) — \(snapshot.detail)\(ownership)"
    }

    private func refreshCredentialStatusIfNeeded() {
        guard credentialStatusNeedsRefresh else { return }
        credentialStatusNeedsRefresh = false
        credentialStatusLabel.stringValue = "Keychain: gateway token \(configuration.hasGatewayToken ? "saved" : "missing") • SSH password \(configuration.hasSSHPassword ? "saved" : "missing") — stored values are never displayed"
    }

    private func refreshStackMaintenanceStatus() {
        if let status = stackMaintenanceStatusOverride {
            stackMaintenanceStatusLabel.stringValue = status.text
            stackMaintenanceStatusLabel.textColor = status.color
            return
        }
        stackMaintenanceStatusLabel.stringValue = stackMaintenance.detail
        switch stackMaintenance.state {
        case .idle:
            stackMaintenanceStatusLabel.textColor = .secondaryLabelColor
        case .running:
            stackMaintenanceStatusLabel.textColor = .systemOrange
        case .succeeded:
            stackMaintenanceStatusLabel.textColor = .systemGreen
        case .failed:
            stackMaintenanceStatusLabel.textColor = .systemRed
        @unknown default:
            stackMaintenanceStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private func refreshGripperPanels(
        connection: ROBAmberDiagnosticsConnectionSnapshot,
        gestureIsExecuting: Bool
    ) {
        let sharedInterlocksPass = connection.state == .ready
            && connection.exclusiveControllerSession
            && pendingManualCommandIDs.isEmpty
            && !hasActiveGripperCommand()
            && !gestureIsExecuting
            && !stackMaintenance.isRunning
            && !stackRecoveryInProgress

        for arm in ROBAmberDiagnosticsArm.allCases {
            guard let controls = gripperControls[arm] else { continue }
            let snapshot = gripperSnapshots[arm] ?? ROBAmberDiagnosticsGripperSnapshot()
            let pending = pendingGripperCommands.values.first { $0.arm == arm }
            let stateText: String
            let stateColor: NSColor
            if pending?.operation == "gripper_calibrate" {
                stateText = "Calibrating — awaiting dispatch acknowledgement"
                stateColor = .systemOrange
            } else if let operation = pending?.operation {
                let name: String
                switch operation {
                case "gripper_state": name = "Refreshing state"
                case "gripper_release": name = "Release command pending"
                case "gripper_hold": name = "Grip command pending"
                default: name = "Gripper command pending"
                }
                stateText = name
                stateColor = .systemOrange
            } else if snapshot.commandInFlight {
                stateText = snapshot.detail.localizedCaseInsensitiveContains("calibration")
                    ? "Calibrating — awaiting dispatch acknowledgement"
                    : "Gripper command in flight"
                stateColor = .systemOrange
            } else if snapshot.calibrationState == "fault" {
                stateText = "Fault"
                stateColor = .systemRed
            } else if snapshot.calibrationVerified {
                stateText = "Ready — calibration verified"
                stateColor = .systemGreen
            } else if snapshot.calibrationState == "command_accepted_unverified" {
                stateText = "Calibration accepted — physical state unverified"
                stateColor = .systemOrange
            } else if snapshot.calibrationState == "required" {
                stateText = "Uncalibrated for this gateway session"
                stateColor = .systemOrange
            } else {
                stateText = connection.state == .ready ? "State unknown — refresh required" : "Gateway unavailable"
                stateColor = .secondaryLabelColor
            }
            controls.stateLabel.stringValue = stateText
            controls.stateLabel.textColor = stateColor
            controls.stateLabel.toolTip = snapshot.detail

            if snapshot.feedbackAvailable {
                let opening = snapshot.measuredOpening.map {
                    String(format: "%.3f", $0)
                } ?? "—"
                let force = snapshot.measuredForce.map {
                    String(format: "%.3f", $0)
                } ?? "—"
                controls.feedbackLabel.stringValue = "Measured opening \(opening) • force \(force)"
            } else {
                var text = "Opening — • Force — • not reported by Amber"
                if let action = snapshot.lastAction {
                    let forceUnit = snapshot.forceUnit.replacingOccurrences(of: "_", with: " ")
                    let force = snapshot.lastForce.map {
                        " @ \($0) \(forceUnit)"
                    } ?? ""
                    text += " • last request \(action)\(force)"
                }
                controls.feedbackLabel.stringValue = text
            }
            controls.feedbackLabel.toolTip = snapshot.feedbackAvailable
                ? "The gateway advertises measured gripper feedback."
                : "Current Amber telemetry reports seven arm joints only; it has no measured gripper opening or force fields."

            let calibrationAccepted = snapshot.calibrationVerified
                || snapshot.calibrationState == "command_accepted_unverified"
            controls.queryButton.isEnabled = sharedInterlocksPass
            controls.calibrateButton.isEnabled = sharedInterlocksPass
                && !snapshot.commandInFlight
            controls.releaseButton.isEnabled = sharedInterlocksPass
                && !snapshot.commandInFlight
                && calibrationAccepted
            controls.gripButton.isEnabled = sharedInterlocksPass
                && !snapshot.commandInFlight
                && calibrationAccepted
            controls.forceSlider.isEnabled = controls.gripButton.isEnabled
            controls.stopButton.isEnabled = false
        }
    }

    private func refreshSummary(_ arm: ROBAmberDiagnosticsArm, label: NSTextField) {
        guard let history = histories[arm], let sample = history.latest else {
            label.stringValue = "Waiting for \(arm.rawValue)-arm telemetry"
            label.textColor = .secondaryLabelColor
            return
        }
        let localAge = Date().timeIntervalSince(sample.receivedAt)
        label.stringValue = String(format: "seq %llu • %.1f Hz • %.2f ms • received %.2f s ago",
                                   sample.sequence, history.updateRate(), sample.sampleAgeMilliseconds, localAge)
        label.textColor = localAge > 0.5 || sample.sampleAgeMilliseconds > 250
            ? .systemRed : .secondaryLabelColor
    }

    private func refreshAuthorityStatus() {
        guard authority.isEnabled else {
            authorityStatusLabel.stringValue = "Debug authority is off"
            authorityStatusLabel.textColor = .secondaryLabelColor
            return
        }
        let total = max(0, Int(authority.remainingSeconds.rounded(.up)))
        let sources = [authority.authorizesGemini() ? "Gemini" : nil,
                       authority.authorizesController() ? "Vision Pro grippers" : nil]
            .compactMap { $0 }.joined(separator: " + ")
        authorityStatusLabel.stringValue = String(format: "%@ authorized • %02d:%02d remaining",
                                                   sources.isEmpty ? "No sources" : sources,
                                                   total / 60, total % 60)
        authorityStatusLabel.textColor = total < 60 ? .systemOrange : .systemGreen
    }

    private func refreshGestureCatalog(selecting preferredName: String? = nil) {
        let existingSelection = preferredName ?? approvedGesturePopup.selectedItem?.title
        let names = gestureCatalog.approvedGestureNames
        gestureStatusLabel.textColor = .secondaryLabelColor
        approvedGesturePopup.removeAllItems()
        if names.isEmpty {
            approvedGesturePopup.addItem(withTitle: "None")
            approvedGesturePopup.isEnabled = false
            approvedGesturePopup.toolTip = nil
            runSelectedGestureButton.isEnabled = false
            gestureStatusLabel.stringValue = "No approved Gemini gestures"
            return
        }
        approvedGesturePopup.addItems(withTitles: names)
        approvedGesturePopup.isEnabled = true
        if let existingSelection, names.contains(existingSelection) {
            approvedGesturePopup.selectItem(withTitle: existingSelection)
        }
        runSelectedGestureButton.isEnabled = !ROBAmberGestureExecutor.shared.isExecuting
            && pendingManualCommandIDs.isEmpty
            && !hasActiveGripperCommand()
        gestureStatusLabel.stringValue = "\(names.count) approved • copied values remain fixed if the source keyframe changes"
        approvedGesturePopup.toolTip = names.joined(separator: "\n")
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { 7 }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, (0..<7).contains(row) else { return nil }
        let arm: ROBAmberDiagnosticsArm = tableView === rightTable ? .right : .left
        let sample = histories[arm]?.latest
        let target = histories[arm]?.currentTarget
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.alignment = identifier.rawValue == "joint" ? .left : .right
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let position = sample?.positionsRadians[safe: row]
        let targetValue = target?[safe: row]
        switch identifier.rawValue {
        case "joint": label.stringValue = "J\(row + 1)"
        case "positionRad": label.stringValue = format(position, digits: 5)
        case "positionDeg": label.stringValue = format(position.map { $0 * 180 / .pi }, digits: 2)
        case "targetDeg": label.stringValue = format(targetValue.map { $0 * 180 / .pi }, digits: 2)
        case "errorDeg":
            label.stringValue = format(zip(position, targetValue).map { ($1 - $0) * 180 / .pi }, digits: 2)
        case "velocity": label.stringValue = format(sample?.velocitiesRadiansPerSecond[safe: row], digits: 4)
        case "current": label.stringValue = format(sample?.currents[safe: row], digits: 4)
        case "mode": label.stringValue = formatMode(modeSnapshots[arm]?[safe: row])
        case "status": label.stringValue = formatStatus(sample?.statuses[safe: row])
        default: label.stringValue = "—"
        }
        if let sample, Date().timeIntervalSince(sample.receivedAt) > 0.5 {
            label.textColor = .systemRed
        } else if identifier.rawValue == "errorDeg", let position, let targetValue,
                  abs(targetValue - position) > 0.0873 {
            label.textColor = .systemOrange
        } else {
            label.textColor = .labelColor
        }
        label.toolTip = label.stringValue
        return cell
    }

    private func format(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "% .\(digits)f", value)
    }

    private func formatStatus(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.3f", value)
    }

    private func formatMode(_ mode: Int?) -> String {
        guard let mode else { return "—" }
        switch mode {
        case 0: return "inactive"
        case 1: return "active"
        case 2: return "position"
        case 3: return "speed"
        case 4: return "current"
        default: return "unknown(\(mode))"
        }
    }

    private func appendEvent(_ message: String) {
        let line = "\(dateFormatter.string(from: Date()))  \(message)"
        logLines.append(line)
        if logLines.count > maximumLogLines { logLines.removeFirst(logLines.count - maximumLogLines) }
        eventLogView.string = logLines.joined(separator: "\n")
        eventLogView.scrollToEndOfDocument(nil)
    }

    @objc private func saveCredentials(_ sender: Any?) {
        do {
            var saved: [String] = []
            if !tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try configuration.saveGatewayToken(tokenField.stringValue)
                saved.append("gateway token")
            }
            if !passwordField.stringValue.isEmpty {
                try configuration.saveSSHPassword(passwordField.stringValue)
                saved.append("SSH password")
            }
            tokenField.stringValue = ""
            passwordField.stringValue = ""
            if saved.isEmpty {
                appendEvent("No credential changes entered")
            } else {
                appendEvent("Saved \(saved.joined(separator: " and ")) in Keychain")
            }
        } catch {
            presentError(error)
            appendEvent("Credential save failed: \(error.localizedDescription)")
        }
        credentialStatusNeedsRefresh = true
        refreshDisplay()
    }

    @objc private func removeCredentials(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove Amber credentials from this Mac?"
        alert.informativeText = "The current tunnel will disconnect, and the gateway token and SSH password will both be removed from Keychain. The Amber box is not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Credentials")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            tunnel.disconnect()
            try configuration.removeCredentials()
            tokenField.stringValue = ""
            passwordField.stringValue = ""
            appendEvent("Removed Amber credentials from Keychain")
        } catch {
            presentError(error)
            appendEvent("Credential removal failed: \(error.localizedDescription)")
        }
        credentialStatusNeedsRefresh = true
        refreshDisplay()
    }

    @objc private func connectTunnel(_ sender: Any?) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tunnel.connect(host: host.isEmpty ? "amber-master.local" : host)
        appendEvent("Requested secure gateway tunnel")
    }

    @objc private func disconnectTunnel(_ sender: Any?) {
        tunnel.disconnect()
        appendEvent("Requested gateway tunnel disconnect")
    }

    @objc private func showWakeUpCalibration(_ sender: Any?) {
        ROBWakeUpCalibrationWindowController.shared.showWindow(sender)
        appendEvent("Opened ROB Wake-Up Calibration in dry-run mode; no actuator command sent")
    }

    @objc private func restartCANCoreStack(_ sender: Any?) {
        stackMaintenanceStatusOverride = nil
        let gestureExecutor = ROBAmberGestureExecutor.shared
        guard !gestureExecutor.isExecuting else {
            rejectStackRestart("Finish or stop the active gesture before restarting the controller stack")
            return
        }
        guard pendingManualCommandIDs.isEmpty else {
            rejectStackRestart("Wait for the pending manual arm command before restarting the controller stack")
            return
        }
        guard !hasActiveGripperCommand(refreshFromGateway: true) else {
            rejectStackRestart("Wait for the pending gripper command before restarting the controller stack")
            return
        }
        guard !stackMaintenance.isRunning, !stackRecoveryInProgress else {
            rejectStackRestart("A controller-stack recovery is already in progress")
            return
        }
        guard configuration.hasSSHPassword else {
            rejectStackRestart("Save the Amber SSH password in Keychain before restarting the controller stack")
            return
        }

        let hostInput = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostInput.isEmpty ? "amber-master.local" : hostInput
        let confirmationField = NSTextField(string: "")
        confirmationField.placeholderString = "RESTART"
        confirmationField.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        confirmationField.setAccessibilityLabel("Type RESTART to confirm controller stack restart")
        confirmationField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let confirmationPrompt = NSTextField(
            wrappingLabelWithString: "Type RESTART to confirm that both arms are physically supported."
        )
        confirmationPrompt.font = .systemFont(ofSize: 11, weight: .semibold)
        let accessory = NSStackView(views: [confirmationPrompt, confirmationField])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        accessory.frame = NSRect(x: 0, y: 0, width: 390, height: 54)

        let alert = NSAlert()
        alert.messageText = "Restart the Amber CAN/core stack?"
        alert.informativeText = "This interrupts the gateway, both vendor cores, and the can10/can11 connections. Powered arms may lose holding torque or feedback. Physically support both arms, clear their workspace, and keep the physical E-stop ready. No arm command may be active."
        alert.alertStyle = .critical
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Restart Controller Stack")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = confirmationField
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendEvent("Cancelled controller-stack restart before submission")
            return
        }
        guard confirmationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == "RESTART" else {
            rejectStackRestart("Controller-stack restart cancelled because the typed confirmation did not match RESTART")
            return
        }

        // The alert runs a nested event loop. Revalidate every motion/recovery
        // interlock after it closes so a command that began while the operator
        // was reading the warning cannot be interrupted by maintenance.
        guard !gestureExecutor.isExecuting,
              pendingManualCommandIDs.isEmpty,
              !hasActiveGripperCommand(refreshFromGateway: true),
              !stackMaintenance.isRunning,
              !stackRecoveryInProgress else {
            rejectStackRestart(
                "Controller-stack restart was not submitted because arm-control state changed during confirmation"
            )
            return
        }

        // Remove every temporary motion grant before intentionally interrupting
        // feedback, then close the existing control session. Maintenance uses a
        // separate, fixed SSH operation and reconnects this tunnel only on success.
        authority.revoke()
        geminiAuthorityButton.state = .off
        controllerAuthorityButton.state = .off
        guard !gestureExecutor.isExecuting,
              pendingManualCommandIDs.isEmpty,
              !hasActiveGripperCommand(refreshFromGateway: true) else {
            rejectStackRestart(
                "Debug authority was revoked, but an arm command is still active; stop it before retrying recovery"
            )
            return
        }
        stackRecoveryInProgress = true
        appendEvent("Confirmed controller-stack restart on amber@\(host); debug authority revoked")
        tunnel.disconnect()
        appendEvent("Disconnected the gateway tunnel before controller-stack recovery")
        refreshDisplay()

        let accepted = stackMaintenance.restart(host: host) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleStackMaintenanceResult(result, host: host)
            }
        }
        guard accepted else {
            stackRecoveryInProgress = false
            rejectStackRestart("Controller-stack recovery was not accepted: \(stackMaintenance.detail)")
            return
        }
        appendEvent("Submitted guarded controller-stack recovery")
        refreshDisplay()
    }

    private func handleStackMaintenanceResult(
        _ result: ROBAmberStackMaintenanceResult,
        host: String
    ) {
        for event in result.events {
            appendEvent("Controller stack • \(boundedMaintenanceText(event))")
        }
        let detail = boundedMaintenanceText(result.detail)
        if result.success {
            appendEvent("Controller-stack recovery succeeded • \(detail)")
            stackMaintenanceStatusOverride = (detail, .systemGreen)
            tunnel.connect(host: host)
            appendEvent("Requested secure gateway tunnel reconnect after successful recovery")
        } else {
            NSSound.beep()
            appendEvent("Controller-stack recovery failed • \(detail)")
            stackMaintenanceStatusOverride = (detail, .systemRed)
        }
        stackRecoveryInProgress = false
        refreshDisplay()
    }

    private func rejectStackRestart(_ detail: String) {
        NSSound.beep()
        stackMaintenanceStatusOverride = (detail, .systemRed)
        appendEvent(detail)
        refreshDisplay()
    }

    private func boundedMaintenanceText(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " • ")
        guard singleLine.count > 600 else { return singleLine }
        return String(singleLine.prefix(600)) + "…"
    }

    private var selectedCommandArm: String {
        commandArmSelector.selectedSegment == 1 ? "right" : "left"
    }

    @objc private func gripperForceChanged(_ sender: NSSlider) {
        guard let arm = diagnosticsArm(forTag: sender.tag),
              let controls = gripperControls[arm] else { return }
        let force = min(20, max(2, Int(sender.doubleValue.rounded())))
        sender.integerValue = force
        controls.forceLabel.stringValue = "Cmd force \(force)"
    }

    @objc private func queryGripperState(_ sender: NSControl) {
        guard let arm = diagnosticsArm(forTag: sender.tag),
              validateGripperInterlocks(for: arm, requiresCalibration: false) else { return }
        recordSubmittedGripperCommand(
            gateway.queryGripperState(forArm: arm.rawValue),
            operation: "gripper_state",
            arm: arm
        )
    }

    @objc private func calibrateGripper(_ sender: NSControl) {
        guard let arm = diagnosticsArm(forTag: sender.tag),
              validateGripperInterlocks(for: arm, requiresCalibration: false) else { return }
        let alert = NSAlert()
        alert.messageText = "Calibrate the \(arm.rawValue) gripper?"
        alert.informativeText = "Calibration may move this gripper through its full travel. Remove every object and keep fingers, clothing, and cables clear of the jaws. Keep the physical E-stop ready. A successful Amber response confirms command dispatch only; Cerebro cannot verify mechanical completion with the telemetry currently available."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Calibrate \(arm.title) Gripper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendEvent("Cancelled \(arm.rawValue) gripper calibration before submission")
            return
        }
        // The modal alert runs a nested event loop, so revalidate all shared
        // motion/recovery state immediately before sending the physical action.
        guard validateGripperInterlocks(for: arm, requiresCalibration: false) else { return }
        recordSubmittedGripperCommand(
            gateway.calibrateGripper(forArm: arm.rawValue),
            operation: "gripper_calibrate",
            arm: arm
        )
    }

    @objc private func releaseGripper(_ sender: NSControl) {
        submitGripperControl(sender, action: "release", displayName: "release")
    }

    @objc private func gripGripper(_ sender: NSControl) {
        submitGripperControl(sender, action: "hold", displayName: "grip")
    }

    @objc private func stopGripperUnavailable(_ sender: NSControl) {
        guard let arm = diagnosticsArm(forTag: sender.tag) else { return }
        NSSound.beep()
        appendEvent("\(arm.title) gripper stop unavailable: Amber defines release, hold, and calibration only")
    }

    private func submitGripperControl(
        _ sender: NSControl,
        action: String,
        displayName: String
    ) {
        guard let arm = diagnosticsArm(forTag: sender.tag),
              let controls = gripperControls[arm],
              validateGripperInterlocks(for: arm, requiresCalibration: true) else { return }
        let force = min(20, max(2, Int(controls.forceSlider.doubleValue.rounded())))
        controls.forceSlider.integerValue = force
        controls.forceLabel.stringValue = "Cmd force \(force)"

        let alert = NSAlert()
        alert.messageText = "\(displayName.capitalized) with the \(arm.rawValue) gripper?"
        if action == "hold" {
            alert.informativeText = "This closes the physical gripper at bounded raw intensity \(force) (GUI limit 2–20). Clear the pinch/crush zone, verify the intended object can tolerate the grip, and keep the physical E-stop ready. Amber does not report measured jaw opening, force, or completion."
        } else {
            alert.informativeText = "This opens the physical gripper at bounded raw intensity \(force) (GUI limit 2–20). Support anything being held because it may drop, clear the gripper travel, and keep the physical E-stop ready. Amber does not report measured jaw opening, force, or completion."
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "\(displayName.capitalized) \(arm.title) Gripper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendEvent("Cancelled \(arm.rawValue) gripper \(displayName) before submission")
            return
        }
        guard validateGripperInterlocks(for: arm, requiresCalibration: true) else { return }
        recordSubmittedGripperCommand(
            gateway.controlGripper(forArm: arm.rawValue, action: action, force: force),
            operation: "gripper_\(action)",
            arm: arm
        )
    }

    private func validateGripperInterlocks(
        for arm: ROBAmberDiagnosticsArm,
        requiresCalibration: Bool
    ) -> Bool {
        let connection = connectionSnapshot()
        _ = hasActiveGripperCommand(refreshFromGateway: true)
        let snapshot = gripperSnapshots[arm] ?? ROBAmberDiagnosticsGripperSnapshot()
        let reason: String?
        if connection.state != .ready || !connection.exclusiveControllerSession {
            reason = "the authenticated exclusive Amber gateway is not ready"
        } else if ROBAmberGestureExecutor.shared.isExecuting {
            reason = "an approved arm gesture is executing"
        } else if !pendingManualCommandIDs.isEmpty {
            reason = "a manual arm command is pending"
        } else if hasActiveGripperCommand() {
            reason = "another gripper command is pending"
        } else if stackMaintenance.isRunning || stackRecoveryInProgress {
            reason = "controller-stack recovery is active"
        } else if requiresCalibration
                    && !snapshot.calibrationVerified
                    && snapshot.calibrationState != "command_accepted_unverified" {
            reason = "this gripper has no calibration acceptance in the current gateway session"
        } else {
            reason = nil
        }
        guard let reason else { return true }
        NSSound.beep()
        gripperSnapshots[arm]?.detail = "Command blocked: \(reason)"
        appendEvent("Blocked \(arm.rawValue) gripper command: \(reason)")
        refreshDisplay()
        return false
    }

    private func hasActiveGripperCommand(refreshFromGateway: Bool = false) -> Bool {
        if refreshFromGateway {
            for arm in ROBAmberDiagnosticsArm.allCases {
                if let dictionary = gateway.gripperSnapshot(forArm: arm.rawValue)
                    as? [AnyHashable: Any] {
                    ingestGripperSnapshot(dictionary, fallbackArm: arm)
                }
            }
        }
        return !pendingGripperCommands.isEmpty
            || gripperSnapshots.values.contains { $0.commandInFlight }
    }

    private func recordSubmittedGripperCommand(
        _ commandID: UInt64,
        operation: String,
        arm: ROBAmberDiagnosticsArm
    ) {
        guard commandID != 0 else {
            NSSound.beep()
            gripperSnapshots[arm]?.detail = "Gateway rejected \(operation) before submission"
            appendEvent("\(arm.rawValue) \(operation) was not sent: gateway validation failed")
            refreshDisplay()
            return
        }
        pendingGripperCommands[commandID] = (arm, operation)
        gripperSnapshots[arm]?.commandInFlight = true
        if operation == "gripper_calibrate" {
            gripperSnapshots[arm]?.calibrationState = "calibrating"
            gripperSnapshots[arm]?.calibrationVerified = false
        }
        gripperSnapshots[arm]?.detail = "Awaiting gateway acknowledgement for command \(commandID)"
        appendEvent("Submitted \(arm.rawValue) \(operation) command \(commandID)")
        refreshDisplay()
    }

    private func diagnosticsArm(forTag tag: Int) -> ROBAmberDiagnosticsArm? {
        switch tag {
        case 0: return .left
        case 1: return .right
        default: return nil
        }
    }

    @objc private func querySelectedArmMode(_ sender: Any?) {
        recordSubmittedCommand(
            gateway.queryMode(forArm: selectedCommandArm),
            operation: "mode query",
            arm: selectedCommandArm
        )
    }

    @objc private func activateSelectedArm(_ sender: Any?) {
        let arm = selectedCommandArm
        guard confirmArmCommand(
            title: "Activate the \(arm) Amber arm?",
            detail: "The vendor warns that switching modes momentarily cuts actuator power. Support the arm at a safe initial pose, clear its workspace, and keep the physical E-stop ready. This command requests Active mode and verifies all seven joints.",
            confirmation: "Activate \(arm.capitalized) Arm"
        ) else { return }
        recordSubmittedCommand(
            gateway.activateArm(arm),
            operation: "activate",
            arm: arm
        )
    }

    @objc private func positionSelectedArm(_ sender: Any?) {
        let arm = selectedCommandArm
        guard confirmArmCommand(
            title: "Enter position mode for the \(arm) arm?",
            detail: "Cerebro will request Active mode, verify all seven joints, capture a new telemetry pose, request Position mode, verify it, then hold that captured pose. Mode switching can briefly remove actuator power; physically support the arm and keep the E-stop ready.",
            confirmation: "Position + Hold"
        ) else { return }
        recordSubmittedCommand(
            gateway.enterPositionMode(forArm: arm),
            operation: "position + measured hold",
            arm: arm
        )
    }

    @objc private func holdSelectedArm(_ sender: Any?) {
        let arm = selectedCommandArm
        recordSubmittedCommand(
            gateway.holdCurrentPosition(forArm: arm),
            operation: "hold measured pose",
            arm: arm
        )
    }

    @objc private func deactivateSelectedArm(_ sender: Any?) {
        let arm = selectedCommandArm
        guard confirmArmCommand(
            title: "Deactivate the \(arm) Amber arm?",
            detail: "Inactive mode removes holding torque and the arm may fall or collapse. Physically support it and keep the E-stop ready before continuing.",
            confirmation: "Deactivate \(arm.capitalized) Arm"
        ) else { return }
        recordSubmittedCommand(
            gateway.deactivateArm(arm),
            operation: "deactivate",
            arm: arm
        )
    }

    private func confirmArmCommand(
        title: String,
        detail: String,
        confirmation: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .critical
        alert.addButton(withTitle: confirmation)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func recordSubmittedCommand(
        _ commandID: UInt64,
        operation: String,
        arm: String
    ) {
        guard commandID != 0 else {
            NSSound.beep()
            appendEvent("\(arm) \(operation) was not sent: gateway is not ready or validation failed")
            return
        }
        pendingManualCommandIDs.insert(commandID)
        appendEvent("Submitted \(arm) \(operation) command \(commandID)")
        refreshDisplay()
    }

    private func handleGripperCommandCompletion(
        commandID: UInt64,
        operation: String,
        armName: String,
        accepted: Bool,
        error: String,
        info: [AnyHashable: Any]
    ) {
        let pending = pendingGripperCommands.removeValue(forKey: commandID)
        guard operation.hasPrefix("gripper_") || pending != nil,
              let arm = ROBAmberDiagnosticsArm(rawValue: armName.lowercased())
                ?? pending?.arm else { return }
        ingestGripperSnapshot(info, fallbackArm: arm)
        var snapshot = gripperSnapshots[arm] ?? ROBAmberDiagnosticsGripperSnapshot()
        snapshot.commandInFlight = boolValue(
            in: info, keys: ["commandInFlight", "command_in_flight"]
        ) ?? false
        if let calibrationState = stringValue(
            in: info, keys: ["calibrationState", "calibration_state"]
        ) {
            snapshot.calibrationState = calibrationState
        }
        if let verified = boolValue(
            in: info, keys: ["calibrationVerified", "calibration_verified"]
        ) {
            snapshot.calibrationVerified = verified
        }
        if let feedback = boolValue(
            in: info, keys: ["feedbackAvailable", "feedback_available"]
        ) {
            snapshot.feedbackAvailable = feedback
        }
        snapshot.measuredOpening = doubleValue(
            in: info, keys: ["measuredOpening", "measured_opening"]
        )
        snapshot.measuredForce = doubleValue(
            in: info, keys: ["measuredForce", "measured_force"]
        )

        let submittedOperation = pending?.operation ?? operation
        if accepted {
            switch operation {
            case "gripper_calibrate":
                // The UDP acknowledgement proves vendor-core dispatch only.
                // Do not upgrade this state to Ready without real feedback.
                snapshot.calibrationState = "command_accepted_unverified"
                snapshot.calibrationVerified = false
                snapshot.detail = "Calibration dispatch accepted; physical completion is not reported"
            case "gripper_control":
                let acknowledgedAction = stringValue(in: info, keys: ["action"])
                let action: String
                if submittedOperation == "gripper_release" || acknowledgedAction == "release" {
                    action = "Release"
                } else if submittedOperation == "gripper_hold" || acknowledgedAction == "hold" {
                    action = "Grip"
                } else {
                    action = "Gripper command"
                }
                snapshot.detail = "\(action) dispatch accepted; physical completion is not reported"
            case "gripper_state":
                snapshot.detail = snapshot.calibrationVerified
                    ? "Gateway reports verified calibration"
                    : (snapshot.calibrationState == "command_accepted_unverified"
                        ? "Calibration dispatch was accepted in this session; physical completion is unverified"
                        : "Calibration is required in this gateway session")
            default:
                snapshot.detail = "Gateway accepted \(submittedOperation)"
            }
        } else {
            snapshot.calibrationState = "fault"
            snapshot.calibrationVerified = false
            snapshot.detail = error.isEmpty
                ? "Gateway rejected \(submittedOperation)"
                : "Gateway rejected \(submittedOperation): \(error)"
        }
        gripperSnapshots[arm] = snapshot
    }

    private func stringValue(in dictionary: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private func boolValue(in dictionary: [AnyHashable: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
            if let value = dictionary[key] as? Bool { return value }
        }
        return nil
    }

    private func doubleValue(in dictionary: [AnyHashable: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber, value.doubleValue.isFinite {
                return value.doubleValue
            }
            if let value = dictionary[key] as? Double, value.isFinite { return value }
        }
        return nil
    }

    private func integerValue(in dictionary: [AnyHashable: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.intValue }
            if let value = dictionary[key] as? Int { return value }
        }
        return nil
    }

    @objc private func grantAuthority(_ sender: Any?) {
        let gemini = geminiAuthorityButton.state == .on
        let controller = controllerAuthorityButton.state == .on
        guard gemini || controller else {
            NSSound.beep()
            appendEvent("Debug authority not enabled: select at least one request source")
            return
        }
        authority.enable(gemini: gemini, controller: controller, durationMinutes: 15)
    }

    @objc private func revokeAuthority(_ sender: Any?) {
        authority.revoke()
        geminiAuthorityButton.state = .off
        controllerAuthorityButton.state = .off
    }

    @objc private func approvedGestureChanged(_ sender: NSPopUpButton) {
        guard sender.isEnabled, let name = sender.selectedItem?.title else { return }
        gestureNameField.stringValue = name
    }

    @objc private func runSelectedGesture(_ sender: Any?) {
        guard pendingManualCommandIDs.isEmpty, !hasActiveGripperCommand(refreshFromGateway: true),
              !stackMaintenance.isRunning, !stackRecoveryInProgress else {
            NSSound.beep()
            gestureStatusLabel.textColor = .systemRed
            gestureStatusLabel.stringValue = "Wait for active manual, gripper, or recovery work to finish"
            return
        }
        guard approvedGesturePopup.isEnabled,
              let name = approvedGesturePopup.selectedItem?.title,
              gestureCatalog.approvedGestureNames.contains(name) else {
            NSSound.beep()
            gestureStatusLabel.textColor = .systemRed
            gestureStatusLabel.stringValue = "Select an approved gesture first"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Run “\(name)” on the physical Amber arms?"
        alert.informativeText = "This can move one or both powered arms. Confirm that the workspace is clear, the physical E-stop is ready, and this is the intended gesture. Cerebro will still enforce Gemini debug authority, gateway readiness, verified position mode, fresh measured telemetry, step and speed bounds, and measured completion."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Run Physical Gesture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendEvent("Cancelled GUI run of approved gesture “\(name)” before submission")
            return
        }
        guard pendingManualCommandIDs.isEmpty, !hasActiveGripperCommand(refreshFromGateway: true),
              !stackMaintenance.isRunning, !stackRecoveryInProgress,
              !ROBAmberGestureExecutor.shared.isExecuting else {
            NSSound.beep()
            appendEvent("Gesture “\(name)” was not submitted because control state changed during confirmation")
            return
        }

        runSelectedGestureButton.isEnabled = false
        gestureStatusLabel.textColor = .systemOrange
        gestureStatusLabel.stringValue = "Running “\(name)” • awaiting measured completion"
        appendEvent("Requested GUI run of approved gesture “\(name)”; executor safety checks remain active")
        ROBAmberGestureExecutor.shared.executeApprovedGesture(name) { [weak self] result in
            DispatchQueue.main.async {
                self?.displayGestureExecutionResult(result, gestureName: name)
            }
        }
        refreshDisplay()
    }

    private func displayGestureExecutionResult(
        _ result: NSDictionary,
        gestureName: String
    ) {
        let status = (result["status"] as? String ?? "unknown").lowercased()
        let detail = result["detail"] as? String
        let measured = (result["measured"] as? NSNumber)?.boolValue
            ?? (result["measured"] as? Bool) ?? false
        let maximumError = (result["maximum_tracking_error_rad"] as? NSNumber)?.doubleValue
            ?? (result["maximum_tracking_error_rad"] as? Double)
        let elapsed = (result["elapsed_seconds"] as? NSNumber)?.doubleValue
            ?? (result["elapsed_seconds"] as? Double)

        var resultParts: [String] = [status]
        if measured { resultParts.append("measured completion verified") }
        if let maximumError, maximumError.isFinite {
            resultParts.append(String(format: "max error %.4f rad", maximumError))
        }
        if let elapsed, elapsed.isFinite {
            resultParts.append(String(format: "%.2f s", elapsed))
        }
        if let detail, !detail.isEmpty { resultParts.append(detail) }
        let summary = resultParts.joined(separator: " • ")

        gestureStatusLabel.stringValue = "“\(gestureName)” • \(summary)"
        switch status {
        case "completed": gestureStatusLabel.textColor = .systemGreen
        case "rejected", "failed", "cancelled":
            gestureStatusLabel.textColor = .systemRed
            NSSound.beep()
        default: gestureStatusLabel.textColor = .systemOrange
        }
        appendEvent("GUI gesture “\(gestureName)” result: \(summary)")
        refreshDisplay()
    }

    @objc private func captureLeftMeasuredPose(_ sender: Any?) {
        captureMeasuredPose(forArm: "left")
    }

    @objc private func captureRightMeasuredPose(_ sender: Any?) {
        captureMeasuredPose(forArm: "right")
    }

    private func captureMeasuredPose(forArm arm: String) {
        let captured = KeyframeAnimationManager.shared.captureCurrentAmberPose(forArm: arm)
        if captured {
            KeyframeAnimationManager.shared.saveCurrentKeyframeAnimation()
            keyframeCaptureStatusLabel.textColor = .systemGreen
            keyframeCaptureStatusLabel.stringValue = "Captured fresh \(arm)-arm telemetry into the current keyframe"
            appendEvent("Captured fresh \(arm)-arm measured pose into the current keyframe")
        } else {
            NSSound.beep()
            keyframeCaptureStatusLabel.textColor = .systemRed
            keyframeCaptureStatusLabel.stringValue = "Capture failed: select an editable keyframe and require fresh seven-joint telemetry"
            appendEvent("Could not capture \(arm)-arm pose: no editable keyframe or telemetry was stale/invalid")
        }
    }

    @objc private func approveGesture(_ sender: Any?) {
        let name = gestureNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = gestureCatalog.approvedGestureNames.first(where: {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            let alert = NSAlert()
            alert.messageText = "Replace the approved gesture “\(existing)”?"
            alert.informativeText = "This replaces Gemini’s immutable approved copy with the arm values in the currently edited keyframe. It does not move either arm."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace Approved Gesture")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try gestureCatalog.approveCurrentKeyframe(as: name)
            gestureNameField.stringValue = name
            refreshGestureCatalog(selecting: name)
            appendEvent("Approved current keyframe as Gemini gesture “\(name)”")
        } catch {
            presentError(error)
            appendEvent("Gesture approval failed: \(error.localizedDescription)")
        }
    }

    @objc private func revokeGesture(_ sender: Any?) {
        guard approvedGesturePopup.isEnabled,
              let name = approvedGesturePopup.selectedItem?.title,
              gestureCatalog.approvedGestureNames.contains(name) else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Revoke “\(name)” from Gemini?"
        alert.informativeText = "This removes the approved immutable gesture. It does not alter the source keyframe or move either arm."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revoke Gesture")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        gestureCatalog.revokeGesture(named: name)
        if gestureNameField.stringValue == name { gestureNameField.stringValue = "" }
        refreshGestureCatalog()
        appendEvent("Revoked Gemini gesture “\(name)”")
    }

    @objc private func graphArmChanged(_ sender: Any?) {
        refreshDisplay()
    }

    @objc private func pauseDisplayChanged(_ sender: NSButton) {
        displayPaused = sender.state == .on
        appendEvent(displayPaused
            ? "Display paused; telemetry buffering continues"
            : "Display resumed")
        if !displayPaused { refreshDisplay() }
    }

    @objc private func clearHistory(_ sender: Any?) {
        histories.values.forEach { $0.clear() }
        logLines.removeAll(keepingCapacity: true)
        eventLogView.string = ""
        appendEvent("Telemetry history and event display cleared")
        refreshDisplay()
    }

    @objc private func exportCSV(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Export Amber Telemetry"
        panel.nameFieldStringValue = "AmberTelemetry-\(Self.fileTimestamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.csvData().write(to: url, options: .atomic)
                self.appendEvent("Exported bounded telemetry to \(url.lastPathComponent)")
            } catch {
                self.presentError(error)
                self.appendEvent("Telemetry export failed: \(error.localizedDescription)")
            }
        }
    }

    private func csvData() -> Data {
        var lines = ["arm,received_at,sequence,sample_age_ms,joint,position_rad,target_rad,error_rad,velocity_rad_s,current,status"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for arm in ROBAmberDiagnosticsArm.allCases {
            for sample in histories[arm]?.samples ?? [] {
                for joint in 0..<7 {
                    let target = sample.targetPositionsRadians?[safe: joint]
                    let error = target.map { $0 - sample.positionsRadians[joint] }
                    let fields = [
                        arm.rawValue,
                        formatter.string(from: sample.receivedAt),
                        String(sample.sequence),
                        csvNumber(sample.sampleAgeMilliseconds),
                        String(joint + 1),
                        csvNumber(sample.positionsRadians[joint]),
                        csvNumber(target),
                        csvNumber(error),
                        csvNumber(sample.velocitiesRadiansPerSecond[joint]),
                        csvNumber(sample.currents[joint]),
                        csvNumber(sample.statuses[joint]),
                    ]
                    lines.append(fields.joined(separator: ","))
                }
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func csvNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func zip<T, U>(_ lhs: T?, _ rhs: U?) -> (T, U)? {
    guard let lhs, let rhs else { return nil }
    return (lhs, rhs)
}
