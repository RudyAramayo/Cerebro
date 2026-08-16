//
//  ROBWakeUpCalibrationWindowController.swift
//  Cerebro
//
//  A non-actuating, operator-supervised startup checklist. This window only
//  reads existing state snapshots and records local review acknowledgements.
//  No actuator command API is referenced from this file.
//

import AppKit
import Foundation

enum ROBWakeUpCalibrationStepID: String, CaseIterable {
    case operatorSafety
    case amberGateway
    case leftAmberArm
    case rightAmberArm
    case visualArmRegistration
    case leftAmberGripper
    case rightAmberGripper
    case headAndNeck
    case waistRotation
    case driveTreads
    case flippersBrakesAndLean
    case legacyMaestroArmBank
}

enum ROBWakeUpCalibrationAdapterClass {
    case localOperatorReview
    case authenticatedReadOnlySnapshot
    case dispatchAcknowledgementOnly
    case missingBoundedSafetyContract
}

struct ROBWakeUpCalibrationStep {
    let id: ROBWakeUpCalibrationStepID
    let title: String
    let preview: String
    let adapterClass: ROBWakeUpCalibrationAdapterClass
    let adapterDetail: String
}

/// Immutable for the life of one window-controller instance. In particular,
/// the plan contains no model-generated joint, force, speed, or timing values.
struct ROBWakeUpCalibrationPlan {
    let id: UUID
    let createdAt: Date
    let steps: [ROBWakeUpCalibrationStep]

    static func makeDefault() -> ROBWakeUpCalibrationPlan {
        ROBWakeUpCalibrationPlan(
            id: UUID(),
            createdAt: Date(),
            steps: [
                .init(
                    id: .operatorSafety,
                    title: "Operator, E-stop, and workspace",
                    preview: "Locally confirm that the physical E-stop is reachable, ROB is supported, and people and obstacles are clear.",
                    adapterClass: .localOperatorReview,
                    adapterDetail: "Human safety gate; Cerebro cannot verify the physical environment."
                ),
                .init(
                    id: .amberGateway,
                    title: "Authenticated Amber controller session",
                    preview: "Inspect the existing authenticated, exclusive gateway-session snapshot. No connection or query is started here.",
                    adapterClass: .authenticatedReadOnlySnapshot,
                    adapterDetail: "Queue-consistent gateway state snapshot; read-only in this workflow."
                ),
                .init(
                    id: .leftAmberArm,
                    title: "Left Amber B1 arm",
                    preview: "Verify a fresh, finite seven-joint measured sample before any future activation or position procedure is considered.",
                    adapterClass: .authenticatedReadOnlySnapshot,
                    adapterDetail: "Authenticated measured telemetry exists; a wake-up executor with bounded stop and measured outcome has not been approved."
                ),
                .init(
                    id: .rightAmberArm,
                    title: "Right Amber B1 arm",
                    preview: "Verify a fresh, finite seven-joint measured sample before any future activation or position procedure is considered.",
                    adapterClass: .authenticatedReadOnlySnapshot,
                    adapterDetail: "Authenticated measured telemetry exists; a wake-up executor with bounded stop and measured outcome has not been approved."
                ),
                .init(
                    id: .visualArmRegistration,
                    title: "Visual arm registration (OAK-D + QR)",
                    preview: "Inspect the latest aligned OAK-D depth state, deterministic QR-anchor camera pose, and confident joint-marker observations for both arms.",
                    adapterClass: .authenticatedReadOnlySnapshot,
                    adapterDetail: "Deterministic QR/depth geometry owns calibration facts; Gemini narration and visual description are non-metrology."
                ),
                .init(
                    id: .leftAmberGripper,
                    title: "Left Amber gripper calibration",
                    preview: "Preview the per-session calibration requirement and dispatch state. Calibration is not submitted from this window.",
                    adapterClass: .dispatchAcknowledgementOnly,
                    adapterDetail: "Amber reports dispatch acceptance only; jaw position, force, completion, and a stop primitive are unavailable."
                ),
                .init(
                    id: .rightAmberGripper,
                    title: "Right Amber gripper calibration",
                    preview: "Preview the per-session calibration requirement and dispatch state. Calibration is not submitted from this window.",
                    adapterClass: .dispatchAcknowledgementOnly,
                    adapterDetail: "Amber reports dispatch acceptance only; jaw position, force, completion, and a stop primitive are unavailable."
                ),
                .init(
                    id: .headAndNeck,
                    title: "Head pan, head tilt, and upper neck",
                    preview: "List the legacy Maestro head/neck calibration surface without energizing or positioning it.",
                    adapterClass: .missingBoundedSafetyContract,
                    adapterDetail: "Legacy direct-servo path has no verified bounded stop, feedback, or outcome contract."
                ),
                .init(
                    id: .waistRotation,
                    title: "Waist rotation",
                    preview: "List safe-start, energize, and center checks without invoking the legacy serial actions.",
                    adapterClass: .missingBoundedSafetyContract,
                    adapterDetail: "Legacy serial path has no verified bounded stop and measured-outcome adapter."
                ),
                .init(
                    id: .driveTreads,
                    title: "Drive treads and tread brake",
                    preview: "List locomotion neutral/brake checks without releasing a brake or sending motion.",
                    adapterClass: .missingBoundedSafetyContract,
                    adapterDetail: "No supervised startup adapter can prove neutral, stop, and bounded measured outcome."
                ),
                .init(
                    id: .flippersBrakesAndLean,
                    title: "Flippers, flipper brake, and lean actuators",
                    preview: "List neutral/brake/support checks without moving a flipper, relaxing a brake, or changing lean.",
                    adapterClass: .missingBoundedSafetyContract,
                    adapterDetail: "Legacy serial actions do not expose the required bounded stop and measured-outcome contract."
                ),
                .init(
                    id: .legacyMaestroArmBank,
                    title: "Legacy Maestro arm/gripper channels",
                    preview: "Keep the older shoulder/elbow/wrist/gripper servo bank excluded while Amber B1 is the measured arm path.",
                    adapterClass: .missingBoundedSafetyContract,
                    adapterDetail: "Superseded legacy path has no authenticated feedback or approved wake-up safety adapter."
                ),
            ]
        )
    }
}

private enum ROBWakeUpReadinessLevel {
    case ready
    case attention
    case unavailable

    var color: NSColor {
        switch self {
        case .ready: return .systemGreen
        case .attention: return .systemOrange
        case .unavailable: return .secondaryLabelColor
        }
    }
}

private struct ROBWakeUpReadiness {
    let level: ROBWakeUpReadinessLevel
    let summary: String
    let detail: String
}

private struct ROBWakeUpStepControls {
    let statusLabel: NSTextField
    let detailLabel: NSTextField
    let adapterLabel: NSTextField
    let confirmationButton: NSButton
    let box: NSBox
}

private final class ROBWakeUpFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@objcMembers public final class ROBWakeUpCalibrationWindowController: NSWindowController,
    NSWindowDelegate {

    public static let shared = ROBWakeUpCalibrationWindowController()

    private let gateway = ROBAmberGatewayClient.shared
    private let plan = ROBWakeUpCalibrationPlan.makeDefault()
    private var confirmedStepIDs: Set<ROBWakeUpCalibrationStepID> = []
    private var evaluations: [ROBWakeUpCalibrationStepID: ROBWakeUpReadiness] = [:]
    private var controls: [ROBWakeUpCalibrationStepID: ROBWakeUpStepControls] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var auditLines: [String] = []
    private let maximumAuditLines = 300

    private let summaryLabel = NSTextField(labelWithString: "")
    private let auditView = NSTextView()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ROB Wake-Up Calibration — Dry Run"
        window.minSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildInterface()
        installObservers()
        appendAudit("Created immutable dry-run plan \(plan.id.uuidString); zero actuator commands sent")
        refreshReadiness(logEvent: true)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        startRefreshTimer()
        refreshReadiness(logEvent: false)
    }

    public func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "ROB Wake-Up Calibration")
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        let dryRunBadge = NSTextField(labelWithString: "DRY RUN ONLY — NO ACTUATOR COMMANDS")
        dryRunBadge.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        dryRunBadge.textColor = .systemOrange
        dryRunBadge.setAccessibilityLabel("Dry run only. No actuator commands.")

        let descriptionLabel = NSTextField(wrappingLabelWithString:
            "This ordered checklist evaluates existing snapshots and records local operator review. "
            + "It never starts automatically, never derives actuator values from a model, and cannot move ROB."
        )
        descriptionLabel.textColor = .secondaryLabelColor

        summaryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingTail

        let refreshButton = makeButton("Refresh Readiness", action: #selector(refreshReadinessAction(_:)))
        refreshButton.toolTip = "Reads in-process gateway and telemetry snapshots. It does not connect, query, or command hardware."
        let copyPlanButton = makeButton("Copy Dry-Run Plan", action: #selector(copyPlan(_:)))
        let resetButton = makeButton("Reset Confirmations…", action: #selector(resetConfirmations(_:)))
        let toolbar = NSStackView(views: [refreshButton, copyPlanButton, resetButton, NSView(), summaryLabel])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8

        let planStack = NSStackView()
        planStack.orientation = .vertical
        planStack.alignment = .leading
        planStack.spacing = 8
        planStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, step) in plan.steps.enumerated() {
            let row = makeStepRow(step, index: index)
            planStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: planStack.widthAnchor).isActive = true
        }

        let planDocument = ROBWakeUpFlippedDocumentView()
        planDocument.translatesAutoresizingMaskIntoConstraints = false
        planDocument.addSubview(planStack)
        NSLayoutConstraint.activate([
            planStack.leadingAnchor.constraint(equalTo: planDocument.leadingAnchor, constant: 8),
            planStack.trailingAnchor.constraint(equalTo: planDocument.trailingAnchor, constant: -8),
            planStack.topAnchor.constraint(equalTo: planDocument.topAnchor, constant: 8),
            planStack.bottomAnchor.constraint(equalTo: planDocument.bottomAnchor, constant: -8),
        ])
        let planScroll = NSScrollView()
        planScroll.hasVerticalScroller = true
        planScroll.autohidesScrollers = true
        planScroll.borderType = .bezelBorder
        planScroll.documentView = planDocument
        NSLayoutConstraint.activate([
            planDocument.leadingAnchor.constraint(equalTo: planScroll.contentView.leadingAnchor),
            planDocument.topAnchor.constraint(equalTo: planScroll.contentView.topAnchor),
            planDocument.widthAnchor.constraint(equalTo: planScroll.contentView.widthAnchor),
        ])

        auditView.isEditable = false
        auditView.isSelectable = true
        auditView.isRichText = false
        auditView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        auditView.textColor = .secondaryLabelColor
        auditView.textContainerInset = NSSize(width: 7, height: 6)
        let auditScroll = NSScrollView()
        auditScroll.hasVerticalScroller = true
        auditScroll.autohidesScrollers = true
        auditScroll.borderType = .bezelBorder
        auditScroll.documentView = auditView
        auditScroll.heightAnchor.constraint(equalToConstant: 145).isActive = true

        let copyAuditButton = makeButton("Copy Audit", action: #selector(copyAudit(_:)))
        let clearAuditButton = makeButton("Clear Audit", action: #selector(clearAudit(_:)))
        let auditHeader = NSStackView(views: [
            NSTextField(labelWithString: "Local dry-run audit"), NSView(), copyAuditButton, clearAuditButton,
        ])
        auditHeader.orientation = .horizontal
        auditHeader.alignment = .centerY
        auditHeader.spacing = 8
        if let heading = auditHeader.arrangedSubviews.first as? NSTextField {
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
        }

        let footer = NSTextField(wrappingLabelWithString:
            "Physical execution is intentionally unavailable until a concrete per-subsystem adapter can enforce "
            + "bounded inputs, a bounded stop, and a measured outcome. A review confirmation never grants motion authority."
        )
        footer.font = .systemFont(ofSize: 10, weight: .semibold)
        footer.textColor = .systemOrange

        let root = NSStackView(views: [
            titleLabel, dryRunBadge, descriptionLabel, toolbar, planScroll,
            auditHeader, auditScroll, footer,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        for view in [descriptionLabel, toolbar, planScroll, auditHeader, auditScroll, footer] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            planScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    private func makeStepRow(_ step: ROBWakeUpCalibrationStep, index: Int) -> NSView {
        let title = NSTextField(labelWithString: "\(index + 1). \(step.title)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .vertical)

        let status = NSTextField(labelWithString: "Not evaluated")
        status.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let preview = NSTextField(wrappingLabelWithString: step.preview)
        preview.font = .systemFont(ofSize: 10)
        preview.textColor = .secondaryLabelColor

        let adapter = NSTextField(wrappingLabelWithString: adapterText(for: step))
        adapter.font = .systemFont(ofSize: 10, weight: .semibold)
        adapter.textColor = adapterColor(step.adapterClass)

        let detail = NSTextField(wrappingLabelWithString: "Readiness has not been evaluated")
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor

        let buttonTitle = step.id == .operatorSafety
            ? "Confirm Safety Review…"
            : step.adapterClass == .missingBoundedSafetyContract
                ? "Acknowledge Exclusion…" : "Confirm Readiness Review…"
        let button = makeButton(buttonTitle, action: #selector(confirmStep(_:)))
        button.tag = index
        button.toolTip = "Records a local checklist acknowledgement only. This button cannot send an actuator command."

        let top = NSStackView(views: [title, NSView(), status])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        let bottom = NSStackView(views: [adapter, NSView(), button])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        let stack = NSStackView(views: [top, preview, detail, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [top, preview, detail, bottom] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        guard let content = box.contentView else { return box }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
        ])
        controls[step.id] = ROBWakeUpStepControls(
            statusLabel: status,
            detailLabel: detail,
            adapterLabel: adapter,
            confirmationButton: button,
            box: box
        )
        return box
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func adapterText(for step: ROBWakeUpCalibrationStep) -> String {
        let prefix: String
        switch step.adapterClass {
        case .localOperatorReview:
            prefix = "LOCAL HUMAN GATE"
        case .authenticatedReadOnlySnapshot:
            prefix = "VERIFIED SNAPSHOT • EXECUTION DISABLED"
        case .dispatchAcknowledgementOnly:
            prefix = "DISPATCH-ONLY • PHYSICAL RESULT UNVERIFIED • EXECUTION DISABLED"
        case .missingBoundedSafetyContract:
            prefix = "EXCLUDED • NO BOUNDED STOP/OUTCOME ADAPTER"
        }
        return "\(prefix) — \(step.adapterDetail)"
    }

    private func adapterColor(_ adapterClass: ROBWakeUpCalibrationAdapterClass) -> NSColor {
        switch adapterClass {
        case .localOperatorReview: return .systemOrange
        case .authenticatedReadOnlySnapshot: return .systemBlue
        case .dispatchAcknowledgementOnly: return .systemOrange
        case .missingBoundedSafetyContract: return .systemRed
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        for name in [
            Notification.Name.ROBAmberGatewayStateDidChange,
            Notification.Name.ROBAmberGatewayTelemetryDidUpdate,
            Notification.Name.ROBAmberGatewayGripperDidUpdate,
        ] {
            observers.append(center.addObserver(forName: name, object: gateway, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshReadiness(logEvent: false) }
            })
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshReadiness(logEvent: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @objc private func refreshReadinessAction(_ sender: Any?) {
        refreshReadiness(logEvent: true)
    }

    private func refreshReadiness(logEvent: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshReadiness(logEvent: logEvent) }
            return
        }
        let connection = connectionSnapshot()
        var next: [ROBWakeUpCalibrationStepID: ROBWakeUpReadiness] = [:]
        for step in plan.steps {
            next[step.id] = evaluate(step, connection: connection)
        }
        evaluations = next
        refreshRows()
        if logEvent {
            let ready = next.values.filter { $0.level == .ready }.count
            let unavailable = next.values.filter { $0.level == .unavailable }.count
            appendAudit("Refreshed in-process readiness: \(ready) ready, \(unavailable) excluded/unavailable; zero commands sent")
        }
    }

    private func evaluate(
        _ step: ROBWakeUpCalibrationStep,
        connection: (state: ROBAmberGatewayState, detail: String, exclusive: Bool)
    ) -> ROBWakeUpReadiness {
        switch step.id {
        case .operatorSafety:
            if confirmedStepIDs.contains(step.id) {
                return .init(
                    level: .ready,
                    summary: "Locally reviewed",
                    detail: "Operator acknowledgement recorded for this dry-run plan; physical conditions remain the operator's responsibility."
                )
            }
            return .init(
                level: .attention,
                summary: "Local confirmation required",
                detail: "Cerebro cannot sense E-stop reachability, arm support, people, or obstacles."
            )

        case .amberGateway:
            guard connection.state == .ready else {
                return .init(
                    level: .attention,
                    summary: "Gateway not ready",
                    detail: connection.detail.isEmpty ? "No authenticated ready session snapshot" : connection.detail
                )
            }
            guard connection.exclusive else {
                return .init(
                    level: .attention,
                    summary: "Session is not exclusive",
                    detail: "The gateway is ready but has not reported an exclusive controller session."
                )
            }
            return .init(
                level: .ready,
                summary: "Authenticated exclusive session ready",
                detail: connection.detail.isEmpty ? "Gateway reports ready" : connection.detail
            )

        case .leftAmberArm:
            return evaluateArm("left", connection: connection)
        case .rightAmberArm:
            return evaluateArm("right", connection: connection)
        case .visualArmRegistration:
            return evaluateVisualArmRegistration()
        case .leftAmberGripper:
            return evaluateGripper("left", connection: connection)
        case .rightAmberGripper:
            return evaluateGripper("right", connection: connection)

        case .headAndNeck, .waistRotation, .driveTreads,
             .flippersBrakesAndLean, .legacyMaestroArmBank:
            return .init(
                level: .unavailable,
                summary: "Physical execution excluded",
                detail: step.adapterDetail
            )
        }
    }

    private func evaluateVisualArmRegistration() -> ROBWakeUpReadiness {
        let calibration = ROBSceneSnapshotStore.shared.visualCalibrationSnapshot()
        let snapshot = calibration.scene
        let freshness = calibration.producerFreshness
        func formattedAge(_ milliseconds: Double) -> String {
            milliseconds.isFinite ? String(format: "%.0f ms", milliseconds) : "missing"
        }
        let ageDetail = "producer ages: frame \(formattedAge(freshness.cameraFrameAgeMilliseconds)), camera pose \(formattedAge(freshness.cameraPoseAgeMilliseconds)), arm pose \(formattedAge(freshness.armPoseAgeMilliseconds))"
        guard snapshot.cameraQuality.state == "streamingRGBD",
              snapshot.cameraQuality.hasAlignedDepth else {
            return .init(
                level: .attention,
                summary: "Aligned OAK-D RGB-D is not ready",
                detail: "Camera state is \(snapshot.cameraQuality.state); deterministic visual registration requires streamingRGBD with aligned depth • \(ageDetail)."
            )
        }
        guard freshness.allRequiredProducersAreFresh() else {
            return .init(
                level: .attention,
                summary: "Visual calibration producers are stale",
                detail: "All camera-frame, camera-pose, and arm-pose producer ages must be ≤ 500 ms • \(ageDetail)."
            )
        }
        guard snapshot.cameraQuality.confidence.isFinite,
              snapshot.cameraQuality.confidence >= 0.5 else {
            return .init(
                level: .attention,
                summary: "OAK-D stream confidence is insufficient",
                detail: String(format: "Camera confidence %.2f; readiness threshold is 0.50 • %@.",
                               snapshot.cameraQuality.confidence, ageDetail)
            )
        }
        guard let pose = snapshot.cameraPose,
              pose.anchorCount >= 4,
              pose.confidence.isFinite, pose.confidence >= 0.5,
              pose.residualRMSEMeters.isFinite, pose.residualRMSEMeters <= 0.05,
              pose.translationMeters.count == 3,
              pose.rotationQuaternion.count == 4,
              (pose.translationMeters + pose.rotationQuaternion).allSatisfy(\.isFinite) else {
            return .init(
                level: .attention,
                summary: "QR camera pose is not adequate",
                detail: "Requires at least four anchors, confidence ≥ 0.50, finite transform values, and residual RMS ≤ 0.05 m • \(ageDetail)."
            )
        }

        func adequateJointCount(for arm: String) -> Int {
            snapshot.armPose.filter { observation in
                guard observation.arm.lowercased() == arm,
                      observation.source == "amber-b1-urdf-oak-d-reverse-pose",
                      observation.confidence.isFinite,
                      observation.confidence >= 0.5,
                      let angle = observation.angleRadians else { return false }
                return angle.isFinite
            }.count
        }
        let leftCount = adequateJointCount(for: "left")
        let rightCount = adequateJointCount(for: "right")
        guard leftCount >= 3, rightCount >= 3 else {
            return .init(
                level: .attention,
                summary: "Both arm-marker fits are required",
                detail: "Deterministic confident joint observations: left \(leftCount), right \(rightCount); at least three per arm are required. Gemini observations do not count • \(ageDetail)."
            )
        }
        return .init(
            level: .ready,
            summary: "Deterministic visual registration ready",
            detail: String(
                format: "%d QR anchors • camera confidence %.2f • RMS %.3f m • left %d/right %d confident joints • %@ • no movement",
                pose.anchorCount, pose.confidence, pose.residualRMSEMeters,
                leftCount, rightCount, ageDetail
            )
        )
    }

    private func evaluateArm(
        _ arm: String,
        connection: (state: ROBAmberGatewayState, detail: String, exclusive: Bool)
    ) -> ROBWakeUpReadiness {
        guard connection.state == .ready, connection.exclusive else {
            return .init(
                level: .attention,
                summary: "Waiting for authenticated exclusive session",
                detail: "No arm command is permitted by this window; readiness needs an existing ready/exclusive gateway snapshot."
            )
        }
        guard let telemetry = gateway.telemetry(forArm: arm) else {
            return .init(
                level: .attention,
                summary: "No measured telemetry",
                detail: "No \(arm)-arm seven-joint sample is cached."
            )
        }
        let positions = telemetry.positionsRadians.map(\.doubleValue)
        let velocities = telemetry.velocitiesRadiansPerSecond.map(\.doubleValue)
        let currents = telemetry.currents.map(\.doubleValue)
        let statuses = telemetry.statuses.map(\.doubleValue)
        guard telemetry.sequence > 0,
              positions.count == 7, velocities.count == 7,
              currents.count == 7, statuses.count == 7,
              (positions + velocities + currents + statuses).allSatisfy(\.isFinite) else {
            return .init(
                level: .attention,
                summary: "Malformed measured telemetry",
                detail: "Expected sequence > 0 and seven finite position, velocity, current, and status values."
            )
        }
        let age = telemetry.effectiveSampleAgeMilliseconds
        guard age.isFinite, age <= 250 else {
            return .init(
                level: .attention,
                summary: "Measured telemetry is stale",
                detail: String(format: "Effective sample age %.1f ms; readiness limit is 250 ms.", age)
            )
        }
        let modes = gateway.modes(forArm: arm).map(\.intValue)
        let modeDetail = modes.count == 7
            ? "mode snapshot [\(modes.map(String.init).joined(separator: ", "))]"
            : "mode snapshot unavailable"
        return .init(
            level: .ready,
            summary: "Fresh seven-joint feedback",
            detail: String(format: "Sequence %llu • effective age %.1f ms • %@ • execution remains disabled.",
                           telemetry.sequence, age, modeDetail)
        )
    }

    private func evaluateGripper(
        _ arm: String,
        connection: (state: ROBAmberGatewayState, detail: String, exclusive: Bool)
    ) -> ROBWakeUpReadiness {
        guard connection.state == .ready, connection.exclusive else {
            return .init(
                level: .attention,
                summary: "Waiting for authenticated exclusive session",
                detail: "Calibration remains preview-only and cannot be submitted from this window."
            )
        }
        let snapshot = gateway.gripperSnapshot(forArm: arm)
        let state = (snapshot["calibrationState"] as? String) ?? "unknown"
        let verified = boolValue(snapshot["calibrationVerified"])
        let feedback = boolValue(snapshot["feedbackAvailable"])
        let inFlight = boolValue(snapshot["commandInFlight"])
        let detail = (snapshot["detail"] as? String) ?? "No gripper state detail"
        if inFlight {
            return .init(
                level: .attention,
                summary: "Gripper command already in flight",
                detail: "This window will not join or replace it. \(detail)"
            )
        }
        if verified && feedback {
            return .init(
                level: .ready,
                summary: "Verified feedback advertised; execution still disabled",
                detail: "A wake-up executor has not been approved for this window. \(detail)"
            )
        }
        if state == "command_accepted_unverified" {
            return .init(
                level: .attention,
                summary: "Calibration dispatch accepted; not physically verified",
                detail: "No measured jaw/force completion and no stop primitive. \(detail)"
            )
        }
        if state == "required" {
            return .init(
                level: .attention,
                summary: "Per-session calibration required",
                detail: "Preview only: no calibration command will be sent. \(detail)"
            )
        }
        return .init(
            level: .attention,
            summary: "Calibration state unknown",
            detail: "Preview only: \(detail)"
        )
    }

    private func connectionSnapshot() -> (
        state: ROBAmberGatewayState, detail: String, exclusive: Bool
    ) {
        let snapshot = gateway.connectionSnapshot()
        let rawState = (snapshot["state"] as? NSNumber)?.intValue
            ?? (snapshot["state"] as? Int)
            ?? ROBAmberGatewayState.disconnected.rawValue
        return (
            ROBAmberGatewayState(rawValue: rawState) ?? .disconnected,
            (snapshot["detail"] as? String) ?? "",
            boolValue(snapshot["exclusiveControllerSession"])
        )
    }

    private func boolValue(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private func refreshRows() {
        let nextUnconfirmed = plan.steps.first { !confirmedStepIDs.contains($0.id) }?.id
        for step in plan.steps {
            guard let row = controls[step.id], let readiness = evaluations[step.id] else { continue }
            let confirmed = confirmedStepIDs.contains(step.id)
            row.statusLabel.stringValue = confirmed
                ? "✓ Reviewed • \(readiness.summary)" : readiness.summary
            row.statusLabel.textColor = readiness.level.color
            row.statusLabel.toolTip = readiness.detail
            row.detailLabel.stringValue = readiness.detail
            row.detailLabel.toolTip = readiness.detail
            row.confirmationButton.isEnabled = !confirmed && nextUnconfirmed == step.id
            row.confirmationButton.title = confirmed
                ? "Reviewed"
                : step.id == .operatorSafety
                    ? "Confirm Safety Review…"
                    : step.adapterClass == .missingBoundedSafetyContract
                        ? "Acknowledge Exclusion…" : "Confirm Readiness Review…"
            row.box.borderColor = confirmed ? NSColor.systemGreen.withAlphaComponent(0.6) : .separatorColor
        }
        let ready = evaluations.values.filter { $0.level == .ready }.count
        let unavailable = evaluations.values.filter { $0.level == .unavailable }.count
        summaryLabel.stringValue = "\(confirmedStepIDs.count)/\(plan.steps.count) reviewed • \(ready) ready • \(unavailable) excluded • commands sent: 0"
        summaryLabel.textColor = .secondaryLabelColor
    }

    @objc private func confirmStep(_ sender: NSButton) {
        guard plan.steps.indices.contains(sender.tag) else { return }
        let step = plan.steps[sender.tag]
        guard plan.steps.first(where: { !confirmedStepIDs.contains($0.id) })?.id == step.id else {
            NSSound.beep()
            return
        }
        let readiness = evaluations[step.id] ?? .init(
            level: .attention, summary: "Not evaluated", detail: "Refresh readiness before review."
        )
        let excluded = step.adapterClass == .missingBoundedSafetyContract
        let alert = NSAlert()
        alert.messageText = step.id == .operatorSafety
            ? "Confirm the physical safety review?"
            : excluded
                ? "Acknowledge that \(step.title) is excluded?"
                : "Record review of \(step.title)?"
        alert.informativeText = step.id == .operatorSafety
            ? "Only confirm after you personally verify the physical E-stop is reachable, both arms are supported as needed, and the workspace is clear. This records an acknowledgement only and sends no command."
            : "Current readiness: \(readiness.summary). \(readiness.detail) This records a local review only; it does not calibrate, energize, release a brake, move, or grant authority."
        alert.alertStyle = step.id == .operatorSafety ? .critical : .warning
        alert.addButton(withTitle: excluded ? "Acknowledge Exclusion" : "Record Review")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            appendAudit("Cancelled review of step \(sender.tag + 1): \(step.title)")
            return
        }
        confirmedStepIDs.insert(step.id)
        appendAudit(
            "Reviewed step \(sender.tag + 1): \(step.title) • \(readiness.summary) • "
            + (excluded ? "physical execution remains excluded" : "no command sent")
        )
        refreshReadiness(logEvent: false)
    }

    @objc private func resetConfirmations(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset this dry-run checklist?"
        alert.informativeText = "This clears only local review acknowledgements. It does not change ROB, gateway state, credentials, or motion authority."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset Confirmations")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        confirmedStepIDs.removeAll()
        appendAudit("Reset all local review acknowledgements; zero commands sent")
        refreshReadiness(logEvent: false)
    }

    @objc private func copyPlan(_ sender: Any?) {
        let header = "ROB Wake-Up Calibration — DRY RUN ONLY\nPlan: \(plan.id.uuidString)\n"
        let body = plan.steps.enumerated().map { index, step in
            "\(index + 1). \(step.title)\n   \(step.preview)\n   \(adapterText(for: step))"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(header + "\n" + body, forType: .string)
        appendAudit("Copied immutable dry-run plan to clipboard; zero commands sent")
    }

    @objc private func copyAudit(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(auditLines.joined(separator: "\n"), forType: .string)
        appendAudit("Copied local dry-run audit to clipboard")
    }

    @objc private func clearAudit(_ sender: Any?) {
        auditLines.removeAll(keepingCapacity: true)
        auditView.string = ""
        appendAudit("Cleared local dry-run audit; checklist confirmations were preserved")
    }

    private func appendAudit(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        auditLines.append(line)
        if auditLines.count > maximumAuditLines {
            auditLines.removeFirst(auditLines.count - maximumAuditLines)
        }
        auditView.string = auditLines.joined(separator: "\n")
        auditView.scrollToEndOfDocument(nil)
    }
}
