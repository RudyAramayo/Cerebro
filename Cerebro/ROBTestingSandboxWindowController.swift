import AppKit
import UniformTypeIdentifiers

/// A catalog of changing commissioning trials, separate from robot preferences.
/// Every physical action still enters the runtime approval path.
@objcMembers public final class ROBTestingSandboxWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public static let shared = ROBTestingSandboxWindowController()

    private enum ParameterSet: Equatable { case recycling, depthAlignment, current, none }
    private struct Action {
        let title: String
        let command: String
    }
    private struct Trial {
        let id: String
        let title: String
        let detail: String
        let parameters: ParameterSet
        let actions: [Action]
    }
    private static let trials: [Trial] = [
        Trial(id: "right-recycling", title: "Recycle can · right arm", detail: "Use ROB's physical right arm (Amber L10). Find an empty upright can, grasp its middle, verify a small lift with fixed-head visual evidence, then carry and gravity-drop above the bucket. Right-arm calibration is separate from left-arm reach tuning. One task approval covers both arms holding at their measured positions and only the right arm travelling.", parameters: .current,
              actions: [Action(title: "Run standing can campaign", command: "local-recycling:standing-run"), Action(title: "Import standing campaign…", command: "local-recycling:standing-import"), Action(title: "Export empty-hand observation template…", command: "local-recycling:empty-observation-export"), Action(title: "Import empty-hand observation…", command: "local-recycling:empty-observation-import"), Action(title: "Recycle selected cans", command: "right_recycle_cans"), Action(title: "Search only", command: "right_search_workspace"), Action(title: "Scan workspace geometry", command: "right_scan_clearance"), Action(title: "Inspect depth map / planned route…", command: "ghost:collision"), Action(title: "Prepare approved session job", command: "local-recycling:prepare"), Action(title: "Export approval template…", command: "local-recycling:export"), Action(title: "Import session approval…", command: "local-recycling:import")]),
        Trial(id: "fixed-head-registration", title: "Camera-to-arm registration", detail: "Measure a local camera-to-robot transform from current RGB-D robot surfaces. Hold the exact head pose; fit and held-out validation use separate surface patches and later frames. A validated fit records its uncertainty and bounded volume. This test never moves an arm and does not manufacture a motion approval.", parameters: .none,
              actions: [Action(title: "Open fixed-head calibration…", command: "registration:open")]),
        Trial(id: "right-estimated-calibration", title: "Right-arm calibration step", detail: "Review one empty-right-arm two-joint retreat away from the table, then hold. The four-second step is capped at 3 cm of full-model travel. It is an estimated commissioning test, with existing modeled self-proxy overlaps required to improve. It does not close the jaws, recycle a can or claim a general arm calibration. Inspect the physical local clearance and ghost before one spoken or controller approval.", parameters: .none,
              actions: [Action(title: "Capture / preview right calibration step", command: "right_estimated_preview"), Action(title: "Inspect estimated ghost…", command: "ghost:collision"), Action(title: "Run reviewed right calibration step", command: "right_estimated_trial")]),
        Trial(id: "recycling", title: "Recycle can", detail: "Find an upright empty can and an open orange bucket using the neck camera. Grasp the can at its middle, lift, carry and release above the opening. Search and preview do not move the arms. A run uses one complete-task authorization or an active supervised session.", parameters: .recycling,
              actions: [Action(title: "Run standing can campaign", command: "local-recycling:standing-run"), Action(title: "Import standing campaign…", command: "local-recycling:standing-import"), Action(title: "Export empty-hand observation template…", command: "local-recycling:empty-observation-export"), Action(title: "Import empty-hand observation…", command: "local-recycling:empty-observation-import"), Action(title: "Recycle selected cans", command: "left_recycle_cans"), Action(title: "Search only", command: "left_search_workspace"), Action(title: "Scan workspace geometry", command: "left_scan_clearance"), Action(title: "Preview grasp…", command: "ghost:can"), Action(title: "Inspect depth map / planned route…", command: "ghost:collision"), Action(title: "Prepare approved session job", command: "local-recycling:prepare"), Action(title: "Export approval template…", command: "local-recycling:export"), Action(title: "Import session approval…", command: "local-recycling:import")]),
        Trial(id: "depth-alignment", title: "Depth alignment", detail: "Adjust the face camera's modeled downward mounting angle and move head-camera depth points horizontally toward ROB. The camera model, live depth view, new workspace scans and object measurements share the pitch correction. Previous scans and previews are cleared when the values change.", parameters: .depthAlignment,
              actions: [Action(title: "Show corrected live depth…", command: "ghost:collision"), Action(title: "Capture corrected workspace", command: "left_scan_clearance")]),
        Trial(id: "neck-qr-calibration", title: "Neck / QR calibration", detail: "Select a fixed 120 mm table, floor or wall target. Upper-neck checks start from the current view with lower target 6011 and hold pan fixed. Each selected upper target is checked against the QR, including reverse visits. Protractor mode holds each position until you advance. Posture sweeps repeat pan/upper checks at upright, back and forward lower-neck targets. Keep ROB's base and the target fixed. Results remain unverified until independent measurements validate them.", parameters: .none,
              actions: [Action(title: "Capture current QR view", command: "qr:capture"), Action(title: "Run neck-only calibration sweep", command: "qr:sweep"), Action(title: "Fit recorded views", command: "qr:fit"), Action(title: "Show calibration folder", command: "qr:folder"), Action(title: "Stop calibration", command: "qr:stop"), Action(title: "Check upper neck forward / reverse", command: "qr:upper"), Action(title: "Start protractor measurements", command: "qr:protractor"), Action(title: "Record angle / next position", command: "qr:next"), Action(title: "Sweep upright / back / forward postures", command: "qr:postures"), Action(title: "Refine QR / fit neck mapping", command: "qr:joint-fit"), Action(title: "Calibrate all four targets", command: "qr:all-targets"), Action(title: "Measure selected target", command: "qr:selected-target")]),
        Trial(id: "belly-qr-calibration", title: "Belly camera calibration", detail: "Capture five passive belly RGB-D frames of the 120 mm B01 and B02 targets with centers 400 mm apart and TOP arrows parallel. The offline report checks the printed geometry, camera pose relative to the sheets and raw depth. It never moves the neck or arms, changes a camera profile or grants motion authority. Keep Belly Camera Diagnostics open for the stream.", parameters: .none,
              actions: [Action(title: "Open belly QR calibration…", command: "belly-qr:open")]),
        Trial(id: "estimated-calibration", title: "Estimated calibration trial", detail: "Review one estimated EMPTY-left-arm retreat away from the table, then hold for observation. Registration remains unmeasured. One fresh approval covers one slow, 4-second retreat with about 3 cm maximum modeled arm travel. Existing nearby depth-margin overlaps may only improve; new intrusions block motion. Confirm the complete arm's local working space is clear and report the actual direction. No jaw commands, grasp, recycling or automatic return. Open the ghost view before building if needed; restarting the camera requires a new preview.", parameters: .none,
              actions: [Action(title: "Scan / build estimated ghost", command: "estimate:preview"), Action(title: "Inspect estimated ghost / depth map…", command: "ghost:collision"), Action(title: "Run reviewed empty-arm trial", command: "estimate:run")]),
        Trial(id: "object-cycle", title: "Grip and return", detail: "Present the left arm, grip a supported object gently, release into a supporting hand, then return the empty arm. Readiness confirmations remain within the same task authorization. Keep fingers clear of the jaws.", parameters: .current,
              actions: [Action(title: "Run grip and return", command: "left_object_cycle")]),
        Trial(id: "stationary-grippers", title: "Stationary gripper setup", detail: "Calibrate empty grippers while both arms are hanging and inactive. This does not lift or activate the arms. Keep both jaws clear; Amber acknowledges commands but jaw completion is not measured.", parameters: .none,
              actions: [Action(title: "Set up stationary empty grippers", command: "gripper-setup")]),
        Trial(id: "preparation", title: "Arm preparation and return", detail: "Exercise individual registered routes and stationary jaw commands. These are optional commissioning checks; recycling does not require a separate preparation test. Support any held object before preparation or return.", parameters: .current,
              actions: [Action(title: "Present / open left", command: "left_prepare"), Action(title: "Grip object", command: "left_grip"), Action(title: "Release to hand", command: "left_release"), Action(title: "Lower empty left arm", command: "left_relax"), Action(title: "Check hanging", command: "left_check_hanging"), Action(title: "Scan workspace geometry", command: "left_scan_clearance"), Action(title: "Run both-arm startup route", command: "startup"), Action(title: "Relax empty arms", command: "relax")]),
        Trial(id: "ghost", title: "Ghost motion rehearsal", detail: "Inspect and review a simulated arm path before requesting its execution. Open the controller input scene to edit a gesture or inspect the wave preset.", parameters: .none,
              actions: [Action(title: "Inspect depth map / planned route…", command: "ghost:collision"), Action(title: "Open ghost editor…", command: "ghost:center"), Action(title: "Preview left wave…", command: "ghost:wave"), Action(title: "Motion rehearsal…", command: "show-rehearsal")]),
        Trial(id: "demonstration", title: "Body demonstration", detail: "Record a short camera demonstration, then replay the taught arm route or test the front-arm greeting.", parameters: .none,
              actions: [Action(title: "Record body demonstration", command: "teach"), Action(title: "Replay last", command: "replay"), Action(title: "Front-arm greeting", command: "wave")]),
        Trial(id: "feedback", title: "Spoken feedback", detail: "Check the spoken arm warning without starting an arm movement.", parameters: .none,
              actions: [Action(title: "Test spoken arm warning", command: "speech-test")])
    ]

    private static let recyclingCountKey = "ROBTestingSandboxRecyclingCanCount"
    private static let recyclingArmKey = "ROBTestingSandboxRecyclingPhysicalArm"
    private static var recyclingCount: Int {
        let count = UserDefaults.standard.integer(forKey: recyclingCountKey)
        return (1...ROBRecyclingBatchRequest.maximumCount).contains(count) ? count : 1
    }
    /// The final local-microphone delegate binds this saved bounded task count.
    public var localRecyclingCampaignTargetCount: Int { Self.recyclingCount }
    private let table = NSTableView()
    private let detailStack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let session = NSTextField(wrappingLabelWithString: "")
    private let collisionInfo = NSTextField(wrappingLabelWithString: "")
    private let localApprovalInfo = NSTextField(wrappingLabelWithString: "")
    private let standingCampaignInfo = NSTextField(wrappingLabelWithString: "")
    private let sourcePixelSelfReview = NSButton(checkboxWithTitle:"LLM-reviewed self pixels, freshly matched (experimental)",target:nil,action:nil)
    private let importSourcePixelReview = NSButton(title:"Import experimental pixel template…",target:nil,action:nil)
    private let nominalModelAssumedSelf = NSButton(checkboxWithTitle: "MODEL-ASSUMED self groups + 14 keyframes (one nominal step)", target:nil, action:nil)
    private let nominalEmptyCommissioningStep = NSButton(checkboxWithTitle: "One slow empty-arm commissioning step", target: nil, action: nil)
    private let oneDegreeEmptyCalibrationStep = NSButton(checkboxWithTitle: "One-degree empty-arm calibration step", target: nil, action: nil)
    private let approachUnknownAdvisory = NSButton(checkboxWithTitle:"UNKNOWN advisory for open-jaw approach (experimental)",target:nil,action:nil)
    private let approachCanThenHold = NSButton(checkboxWithTitle:"Approach can then hold (open jaws)",target:nil,action:nil)
    private let holdAfterInitialEmptyLift = NSButton(checkboxWithTitle: "Hold after initial empty lift", target: nil, action: nil)
    private var collisionRefreshTimer: Timer?
    private let continueCycle = NSButton(title: "Continue", target: nil, action: nil)
    private let save = NSButton(title: "Save test parameters", target: nil, action: nil)
    private var fields: [String: NSTextField] = [:]
    private var actionButtons: [NSButton] = []
    private var displayedCycleStage = ""
    private var parameterMessage = ""
    private var observingLeftOperation = false
    private var hasCalibrationFields = false
    private var startSessionButton: NSButton!
    private var endSessionButton: NSButton!
    private let qrTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    private let protractorPitch = NSTextField(string: "")
    private var selectedTrial: Trial { Self.trials[max(0, min(table.selectedRow, Self.trials.count - 1))] }
    private var canEdit: Bool {
        !ROBLeftArmTrial.shared.isRunning && !ROBArmRoutineCoordinator.shared.isRunning &&
            !ROBArmRoutineCoordinator.shared.ownsPhysicalMotion && !ROBControllerArmApproval.shared.isPending &&
            !ROBGripperStartupCalibration.shared.isRunning && !ROBShowMotionCoordinator.shared.isRunning &&
            !ROBAmberGestureExecutor.shared.isExecuting && !ROBNeckQRCalibration.shared.isRunning &&
            !ROBFixedHeadCalibrationWindowController.shared.isRunning && !ROBBellyQRCalibrationWindowController.shared.isRunning
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Testing Sandbox"
        window.identifier = NSUserInterfaceItemIdentifier("rob-testing-sandbox")
        window.minSize = NSSize(width: 870, height: 760)
        super.init(window: window)
        buildInterface()
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBArmRoutineDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBControllerArmApprovalDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .ROBGripperStartupCalibrationDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("ROBNeckQRCalibrationDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: ROBBellyQRCalibrationWindowController.changed, object: nil)
        let initialTrial = ROBLocalRecyclingSandboxRouting.resumeTrialID(selectedTrialID: "",
            persistedArm: UserDefaults.standard.string(forKey: Self.recyclingArmKey))
        table.selectRowIndexes(IndexSet(integer: Self.trials.firstIndex(where: { $0.id == initialTrial }) ?? 0), byExtendingSelection: false)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            if ROBLeftArmTrial.shared.isRunning || ROBControllerArmApproval.shared.isPending { self.refresh() }
            else { self.refreshCollisionInfo() }
        }
        collisionRefreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Use shared") }
    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        let heading = NSTextField(labelWithString: "Testing Sandbox"); heading.font = .boldSystemFont(ofSize: 22)
        root.addArrangedSubview(heading)
        let sessionRow = NSStackView(); sessionRow.spacing = 8
        startSessionButton = NSButton(title: "Start 15-minute left-arm session", target: self, action: #selector(startSession))
        startSessionButton.identifier = NSUserInterfaceItemIdentifier("sandbox-start-arm-session")
        endSessionButton = NSButton(title: "End session", target: self, action: #selector(endSession))
        let stop = NSButton(title: "Stop + hold", target: self, action: #selector(stop)); stop.bezelColor = .systemRed
        stop.identifier = NSUserInterfaceItemIdentifier("sandbox-stop")
        for item in [startSessionButton!, endSessionButton!, stop] { sessionRow.addArrangedSubview(item) }
        root.addArrangedSubview(sessionRow); root.addArrangedSubview(session)
        let split = NSStackView(); split.orientation = .horizontal; split.alignment = .top; split.spacing = 18
        let listScroll = NSScrollView(); listScroll.borderType = .bezelBorder; listScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test")); column.title = "Tests"; column.width = 240
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 40
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Sandbox tests")
        table.identifier = NSUserInterfaceItemIdentifier("sandbox-test-list")
        listScroll.documentView = table
        listScroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        split.addArrangedSubview(listScroll)
        let detailScroll = NSScrollView(); detailScroll.hasVerticalScroller = true; detailScroll.autohidesScrollers = true
        let document = ROBTestingSandboxDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = document
        detailStack.orientation = .vertical; detailStack.alignment = .leading; detailStack.spacing = 12
        detailStack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(detailStack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
                                     detailStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
                                     detailStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
                                     detailStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
                                     detailStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)])
        split.addArrangedSubview(detailScroll)
        root.addArrangedSubview(split)
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        listScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        detailScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        continueCycle.target = self; continueCycle.action = #selector(continueObjectCycle)
        continueCycle.identifier = NSUserInterfaceItemIdentifier("left-cycle-continue")
        root.addArrangedSubview(continueCycle)
        status.isSelectable = true; status.font = .systemFont(ofSize: 12)
        status.identifier = NSUserInterfaceItemIdentifier("sandbox-test-status")
        let statusScroll = NSScrollView(); statusScroll.hasVerticalScroller = true; statusScroll.autohidesScrollers = true
        statusScroll.borderType = .bezelBorder
        let statusDocument = ROBTestingSandboxDocumentView(); statusDocument.translatesAutoresizingMaskIntoConstraints = false
        statusScroll.documentView = statusDocument
        status.translatesAutoresizingMaskIntoConstraints = false; statusDocument.addSubview(status)
        NSLayoutConstraint.activate([statusDocument.widthAnchor.constraint(equalTo: statusScroll.contentView.widthAnchor),
                                     status.leadingAnchor.constraint(equalTo: statusDocument.leadingAnchor, constant: 8),
                                     status.trailingAnchor.constraint(equalTo: statusDocument.trailingAnchor, constant: -8),
                                     status.topAnchor.constraint(equalTo: statusDocument.topAnchor, constant: 8),
                                     status.bottomAnchor.constraint(equalTo: statusDocument.bottomAnchor, constant: -8),
                                     statusScroll.heightAnchor.constraint(equalToConstant: 120)])
        root.addArrangedSubview(statusScroll)
        statusScroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        session.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { Self.trials.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: Self.trials[row].title)
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                                     label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    public func tableViewSelectionDidChange(_ notification: Notification) {
        if let arm = ROBLocalRecyclingSandboxRouting.physicalArm(trialID: selectedTrial.id) {
            UserDefaults.standard.set(arm, forKey: Self.recyclingArmKey)
        }
        buildDetail(); refresh()
    }

    private func buildDetail() {
        detailStack.arrangedSubviews.forEach { detailStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        fields.removeAll(); actionButtons.removeAll(); parameterMessage = ""; hasCalibrationFields = false
        let trial = selectedTrial
        let title = NSTextField(labelWithString: trial.title); title.font = .boldSystemFont(ofSize: 18)
        detailStack.addArrangedSubview(title)
        addHelp(trial.detail)
        if trial.id == "neck-qr-calibration" {
            qrTarget.removeAllItems()
            qrTarget.addItems(withTitles: ROBNeckQRMeasurement.supportedTargetIDs)
            qrTarget.selectItem(withTitle: ROBNeckQRCalibration.shared.selectedTargetID)
            qrTarget.target = self; qrTarget.action = #selector(changeQRTarget)
            qrTarget.setAccessibilityLabel("Calibration QR target")
            detailStack.addArrangedSubview(qrTarget)
            protractorPitch.placeholderString = "Optional pitch degrees; positive nose-up"
            protractorPitch.setAccessibilityLabel("Measured camera pitch degrees")
            protractorPitch.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            detailStack.addArrangedSubview(protractorPitch)
        }
        if ["recycling", "right-recycling", "depth-alignment", "estimated-calibration", "preparation", "ghost"].contains(trial.id) {
            collisionInfo.identifier = NSUserInterfaceItemIdentifier("sandbox-collision-status")
            collisionInfo.isSelectable = true
            collisionInfo.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            detailStack.addArrangedSubview(collisionInfo)
            collisionInfo.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            refreshCollisionInfo()
        }
        if ["recycling", "right-recycling"].contains(trial.id) {
            standingCampaignInfo.identifier = NSUserInterfaceItemIdentifier("sandbox-standing-can-campaign-status")
            standingCampaignInfo.isSelectable = true
            detailStack.addArrangedSubview(standingCampaignInfo)
            standingCampaignInfo.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            addHelp("Import this campaign's standing authorization once, then Run. New plans bind fresh robot context without another approval. After Stop, ‘proceed with protections’ starts a new authorization through the local microphone. Connection recovery retries a new plan at most three times. Stop holds the arms; no lowering or old waypoint resumes automatically.")
            addHelp("Record an actual observation that both grippers are empty; this does not approve or start motion.")
            addField("recyclingCount", "Number of cans", Double(Self.recyclingCount),
                note: "1–\(ROBRecyclingBatchRequest.maximumCount) · each can is checked again")
            addField("localVisualAllowanceMillimeters", "Assumed visual error (mm)",
                ROBLeftArmTrial.shared.localVisualTrialAssumedSpatialErrorMeters * 1000,
                note: "25–150 · local session trial only; not measured")
            fields["localVisualAllowanceMillimeters"]?.delegate = self
            nominalEmptyCommissioningStep.identifier = NSUserInterfaceItemIdentifier("sandbox-nominal-empty-commissioning-step")
            nominalEmptyCommissioningStep.target = self
            nominalEmptyCommissioningStep.action = #selector(changeNominalEmptyCommissioningStep)
            nominalEmptyCommissioningStep.state = ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled ? .on : .off
            detailStack.addArrangedSubview(nominalEmptyCommissioningStep)
            nominalModelAssumedSelf.identifier=NSUserInterfaceItemIdentifier("sandbox-nominal-model-assumed-self")
            nominalModelAssumedSelf.target=self;nominalModelAssumedSelf.action=#selector(changeNominalModelAssumedSelf)
            nominalModelAssumedSelf.state=ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled ? .on:.off
            detailStack.addArrangedSubview(nominalModelAssumedSelf)
            addHelp("Commissioning only: one slow outward empty-arm step, then hold. Current robot occupancy is assumed from the model; calibration error and nearby unobserved space remain unverified. No grip, carry, release or automatic return. Zero cans are transferred.")
            oneDegreeEmptyCalibrationStep.identifier = NSUserInterfaceItemIdentifier("sandbox-one-degree-empty-calibration-step")
            oneDegreeEmptyCalibrationStep.target = self
            oneDegreeEmptyCalibrationStep.action = #selector(changeOneDegreeEmptyCalibrationStep)
            oneDegreeEmptyCalibrationStep.state = ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled ? .on : .off
            detailStack.addArrangedSubview(oneDegreeEmptyCalibrationStep)
            addHelp("Actuator/model calibration only: RIGHT J2 −0.02 rad over 4 seconds, at most 2 cm modeled travel, then hold. Collision clearance is unverified; contact predictions are diagnostic only. Contact could push the table or lift ROB. No payload, jaw command, grasp, carry, release, return or chained motion. Zero transfers. Stop and fresh feedback remain required.")
            #if DEBUG
            if trial.id == "right-recycling" {
                sourcePixelSelfReview.identifier=NSUserInterfaceItemIdentifier("sandbox-source-pixel-self-review")
                sourcePixelSelfReview.target=self;sourcePixelSelfReview.action=#selector(changeSourcePixelSelfReview)
                sourcePixelSelfReview.state=ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled ? .on:.off
                detailStack.addArrangedSubview(sourcePixelSelfReview)
                importSourcePixelReview.identifier=NSUserInterfaceItemIdentifier("sandbox-import-source-pixel-template")
                importSourcePixelReview.target=self;importSourcePixelReview.action=#selector(importSourcePixelSelfTemplate)
                detailStack.addArrangedSubview(importSourcePixelReview)
                addHelp("DEBUG perception assumption only: import a private historical LLM pixel review once; Prepare matches actual next fresh native RAW scan. Table/person/unmasked/mixed groups stay external. Separate exact native receipt required for ONE J2-only empty step +14keyframes; no MODEL-hull fallback, jaws or chaining.")
                approachCanThenHold.identifier=NSUserInterfaceItemIdentifier("sandbox-approach-can-then-hold")
                approachCanThenHold.target=self;approachCanThenHold.action=#selector(changeApproachCanThenHold)
                approachCanThenHold.state=ROBLeftArmTrial.shared.approachCanThenHoldEnabled ? .on:.off
                detailStack.addArrangedSubview(approachCanThenHold)
                approachUnknownAdvisory.identifier=NSUserInterfaceItemIdentifier("sandbox-approach-unknown-advisory")
                approachUnknownAdvisory.target=self;approachUnknownAdvisory.action=#selector(changeApproachUnknownAdvisory)
                approachUnknownAdvisory.state=ROBLeftArmTrial.shared.approachUnknownAdvisoryEnabled ? .on:.off
                detailStack.addArrangedSubview(approachUnknownAdvisory)
                addHelp("DEBUG, exact standing open-jaw approach only: unobserved cells stay UNKNOWN and are reported as advisory, never relabeled free or observed. Occupied returns, self-collision, person/Stop, joint/rate/current and fresh-feedback checks remain. Explicit uncertainty acceptance is not measured registration or certified clearance. No grip, payload or carry.")
                addHelp("DEBUG: find the can, perform ordinary fully checked initial lift and complete approach with open jaws, then hold at observed ready-to-grip alignment. No closing, verification lift, payload, carry, release, automatic recovery or next attempt. ZERO transfers. All occupied/self-collision, person/Stop/joint/rate/current/feedback checks remain; UNKNOWN advisory needs its separate explicit option.")
                holdAfterInitialEmptyLift.identifier = NSUserInterfaceItemIdentifier("sandbox-hold-after-initial-empty-lift")
                holdAfterInitialEmptyLift.target = self; holdAfterInitialEmptyLift.action = #selector(changeHoldAfterInitialEmptyLift)
                holdAfterInitialEmptyLift.state = ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled ? .on : .off
                detailStack.addArrangedSubview(holdAfterInitialEmptyLift)
                addHelp("DEBUG: use the ordinary complete occupied/unknown/self-clearance checks for one initial EMPTY lift, then hold at the measured endpoint. No jaw, grasp, carry, release, return, rescan after lifting or chained step. ZERO can transfers. If no initial lift is needed, remain unchanged.")
            }
            #endif
            localApprovalInfo.identifier = NSUserInterfaceItemIdentifier("sandbox-local-recycling-approval-scope")
            localApprovalInfo.isSelectable = true
            detailStack.addArrangedSubview(localApprovalInfo)
            localApprovalInfo.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            addHelp("The local session job covers the saved count of 1–8 empty Coke cans and the orange bucket. Prepare freezes the selected arm and count; export a template, then import its private user-approval receipt. A retained identical job can continue without another prompt. Stop revokes it. The receipt does not verify camera alignment or remove motion checks.")
        }
        if trial.parameters == .depthAlignment {
            let current = ROBWorkspaceDepthAlignment.snapshot()
            addField("depthTowardRobotInches", "Depth points toward ROB (in)", (current?.towardRobotMeters ?? 0) / 0.0254,
                note: "0–11.8 · horizontal only")
            addField("cameraDownwardPitchDegrees", "Camera downward angle (°)", current?.downwardPitchDegrees ?? 0,
                note: "0–30 · extra mounting pitch")
            addHelp("The values above are the current manual estimate. The angle tilts the camera model and depth rays without commanding the neck. Horizontal reach correction is rebased separately; pitch changes require fresh object measurements and reach calibration against the reference scan.")
        }
        if trial.parameters == .recycling {
            do {
                let parameters = try ROBRecyclingTestParameters.load()
                addField("motionPace", "Motion pace", parameters.motionPace, note: "1.0–1.25 · keeps existing motion limits")
                addField("jawSettleSeconds", "Jaw settling time (s)", parameters.jawSettleSeconds, note: "1.0–2.0")
                addField("pathAdjustment", "Maximum path adjustment (mm)", parameters.maximumPathDeviationMeters * 1000, note: "0–5")
                let calibration = try readCalibration()
                let translation = calibration["translationMeters"] as? [Double] ?? []
                guard translation.count == 3 else { throw ROBGhostMotionError.blocked("The reach calibration needs three translation values.") }
                hasCalibrationFields = true
                let typed = try JSONDecoder().decode(ROBLeftCanReachCalibration.self,
                    from: JSONSerialization.data(withJSONObject: calibration))
                let effectiveTranslation = try typed.effectiveTranslation()
                for (index, axis) in ["X", "Y", "Z"].enumerated() {
                    addField("translation\(index)", "Reach \(axis) correction (cm)", effectiveTranslation[index] * 100, note: "−15–15")
                }
                addField("canOutwardMeters", "Additional reach toward can (cm)", (calibration["canOutwardMeters"] as? Double ?? 0) * 100, note: "0–3")
                if let base = calibration["tabletopCanBaseHeightMeters"] as? Double {
                    addField("tabletopCanBaseHeightMeters", "Calibrated can-base height (cm)", base * 100, note: "30–140")
                    addHelp("The detected can height sets the middle grasp above this calibrated base. Reach Z correction is used only when no calibrated base height is present.")
                }
                addField("bucketYawDegrees", "Bucket release rotation (°)", calibration["bucketYawDegrees"] as? Double ?? 0, note: "−30–30")
                addField("bucketInwardMeters", "Release toward robot (cm)", (calibration["bucketInwardMeters"] as? Double ?? 0) * 100, note: "0–8")
            } catch { parameterMessage = error.localizedDescription; addHelp("Parameters unavailable: \(error.localizedDescription)") }
        }
        if trial.parameters != .none {
            if trial.parameters != .depthAlignment {
                addField("currentLimit", "Current jump stop (raw units)", UserDefaults.standard.double(forKey: ROBLeftArmTrial.currentLimitKey), note: "0 = record only")
                addHelp("Current is recorded automatically. This sample-to-sample threshold is not a measured force limit.")
            }
            save.target = self; save.action = #selector(saveParameters)
            save.title = trial.parameters == .depthAlignment ? "Apply depth alignment" : "Save test parameters"
            save.identifier = NSUserInterfaceItemIdentifier("sandbox-save-parameters")
            detailStack.addArrangedSubview(save)
        }
        let actionTitle = NSTextField(labelWithString: "Actions"); actionTitle.font = .boldSystemFont(ofSize: 13)
        detailStack.addArrangedSubview(actionTitle)
        for (index, action) in trial.actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(performTrialAction(_:)))
            button.tag = index; button.identifier = NSUserInterfaceItemIdentifier("sandbox-\(trial.id)-\(index)")
            if action.command.hasPrefix("local-recycling:") {
                button.identifier = NSUserInterfaceItemIdentifier("sandbox-\(trial.id)-session-\(action.command.dropFirst("local-recycling:".count))")
            }
            detailStack.addArrangedSubview(button); actionButtons.append(button)
        }
        detailStack.addArrangedSubview(NSButton(title: "Show latest recording", target: self, action: #selector(showRecording)))
    }
    private func addHelp(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
    }
    private func addField(_ key: String, _ title: String, _ value: Double, note: String) {
        let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 245).isActive = true
        let field = NSTextField(string: String(format: "%.10g", value))
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.setAccessibilityLabel(title); field.identifier = NSUserInterfaceItemIdentifier("sandbox-parameter-\(key)")
        fields[key] = field
        let hint = NSTextField(labelWithString: note); hint.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, field, hint]); row.spacing = 8; detailStack.addArrangedSubview(row)
    }

    private func readCalibration() throws -> [String: Any] {
        let data = try Data(contentsOf: ROBLeftCanReachCalibration.file)
        guard data.count <= 16_384, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let directory = Bundle.main.url(forResource: "ShadowPlanner", withExtension: nil) else {
            throw ROBGhostMotionError.blocked("A valid local reach calibration is required before editing it.")
        }
        let model = try ROBGhostRobotModel(directory: directory)
        _ = try ROBLeftCanReachCalibration.loadBucketYaw(model: model)
        guard value["modelID"] as? String == model.modelID, value["referenceID"] as? String == model.referenceID,
              value["mappingID"] as? String == ROBGhostRobotModel.mappingID else {
            throw ROBGhostMotionError.blocked("The reach calibration belongs to a different robot model.")
        }
        return value
    }
    private func value(_ key: String, within range: ClosedRange<Double>) throws -> Double {
        guard let field = fields[key], let number = Double(field.stringValue), number.isFinite, range.contains(number) else {
            throw ROBGhostMotionError.blocked("Enter a value from \(range.lowerBound) to \(range.upperBound) for \(fields[key]?.accessibilityLabel() ?? key).")
        }
        return number
    }
    @discardableResult private func storeParameters() -> Bool {
        guard canEdit else { parameterMessage = "Finish or stop the active operation before changing test parameters."; refresh(); return false }
        window?.makeFirstResponder(nil)
        guard selectedTrial.parameters != .none else { return true }
        do {
            if selectedTrial.parameters == .depthAlignment {
                let meters = try value("depthTowardRobotInches", within: 0...(0.30 / 0.0254)) * 0.0254
                let pitch = try value("cameraDownwardPitchDegrees", within: 0...30)
                _ = try ROBWorkspaceDepthAlignment.setAlignment(towardRobotMeters: meters, downwardPitchDegrees: pitch)
                ROBLeftArmTrial.shared.depthAlignmentDidChange()
                ROBArmRoutineVision.shared.depthAlignmentDidChange()
                ROBWorkspaceSearch.shared.depthAlignmentDidChange()
                NotificationCenter.default.post(name: Notification.Name("ROBWorkspaceDepthAlignmentDidChange"), object: self)
                parameterMessage = String(format: "Head depth: %.2f inches toward ROB; face camera %.1f° lower. Capture a fresh scene.", meters / 0.0254, pitch)
                refresh(); return true
            }
            let current = try value("currentLimit", within: 0...Double.greatestFiniteMagnitude)
            let recyclingCount: Int?
            if ["recycling", "right-recycling"].contains(selectedTrial.id) {
                let count = try value("recyclingCount", within: 1...Double(ROBRecyclingBatchRequest.maximumCount))
                guard count.rounded() == count else {
                    throw ROBGhostMotionError.blocked("Enter a whole number of cans.")
                }
                recyclingCount = Int(count)
            } else { recyclingCount = nil }
            if selectedTrial.parameters == .recycling {
                let parameters = ROBRecyclingTestParameters(motionPace: try value("motionPace", within: 1...1.25),
                    jawSettleSeconds: try value("jawSettleSeconds", within: 1...2),
                    maximumPathDeviationMeters: try value("pathAdjustment", within: 0...5) / 1000)
                var calibrationData: Data?
                if hasCalibrationFields {
                    var calibration = try readCalibration()
                    calibration["translationMeters"] = try (0..<3).map { try value("translation\($0)", within: -15...15) / 100 }
                    guard let alignment = ROBWorkspaceDepthAlignment.snapshot() else {
                        throw ROBGhostMotionError.blocked("The head-depth alignment is invalid.")
                    }
                    calibration["depthTowardRobotMetersAtCalibration"] = alignment.towardRobotMeters
                    calibration["canOutwardMeters"] = try value("canOutwardMeters", within: 0...3) / 100
                    calibration["bucketYawDegrees"] = try value("bucketYawDegrees", within: -30...30)
                    calibration["bucketInwardMeters"] = try value("bucketInwardMeters", within: 0...8) / 100
                    if fields["tabletopCanBaseHeightMeters"] != nil {
                        calibration["tabletopCanBaseHeightMeters"] = try value("tabletopCanBaseHeightMeters", within: 30...140) / 100
                    }
                    let data = try JSONSerialization.data(withJSONObject: calibration, options: [.prettyPrinted, .sortedKeys])
                    guard data.count <= 16_384 else { throw ROBGhostMotionError.blocked("The reach calibration is too large.") }
                    calibrationData = data
                }
                try parameters.save()
                // Preserve model identity, source and every unknown optional field.
                if let calibrationData { try calibrationData.write(to: ROBLeftCanReachCalibration.file, options: .atomic) }
            }
            if let recyclingCount { UserDefaults.standard.set(recyclingCount, forKey: Self.recyclingCountKey) }
            UserDefaults.standard.set(current, forKey: ROBLeftArmTrial.currentLimitKey)
            parameterMessage = "Parameters saved for the next test."
            refresh(); return true
        } catch { parameterMessage = error.localizedDescription; refresh(); return false }
    }
    @objc private func saveParameters() { _ = storeParameters() }
    @objc private func changeQRTarget() {
        guard canEdit, let identifier = qrTarget.titleOfSelectedItem else { return }
        ROBNeckQRCalibration.shared.selectTarget(identifier); refresh()
    }
    @objc private func performTrialAction(_ sender: NSButton) {
        guard selectedTrial.actions.indices.contains(sender.tag) else { return }
        let command = selectedTrial.actions[sender.tag].command
        // File controls must remain reachable while the receipt-only request
        // deliberately disables ordinary edits and other trial actions.
        if command == "local-recycling:export" { exportLocalRecyclingApprovalTemplate(); return }
        if command == "local-recycling:import" { importLocalRecyclingApprovalReceipt(); return }
        if command == "local-recycling:prepare" { prepareLocalRecyclingSessionJob(); return }
        if command == "local-recycling:standing-import" { importStandingCanCampaign(); return }
        if command == "local-recycling:standing-run" { runStandingCanCampaign(); return }
        if command == "local-recycling:empty-observation-export" { exportEmptyHandObservationTemplate(); return }
        if command == "local-recycling:empty-observation-import" { importEmptyHandObservation(); return }
        if command == "belly-qr:open" {
            ROBBellyQRCalibrationWindowController.shared.showWindow(self); return
        }
        // Stop remains available while the calibration owns the neck/camera.
        if command == "qr:stop" { ROBNeckQRCalibration.shared.stop(); refresh(); return }
        if command == "qr:next" {
            let text = protractorPitch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty || Double(text)?.isFinite == true else {
                status.stringValue = "Enter an angle in degrees or leave the reading blank."; return
            }
            ROBNeckQRCalibration.shared.advanceProtractor(Double(text).map { NSNumber(value: $0) })
            protractorPitch.stringValue = ""; refresh(); return
        }
        guard canEdit else { return }
        if selectedTrial.parameters != .none && selectedTrial.parameters != .depthAlignment && !["left_search_workspace", "left_scan_clearance", "right_search_workspace", "right_scan_clearance"].contains(command) && !storeParameters() { return }
        if command == "registration:open" {
            ROBFixedHeadCalibrationWindowController.shared.showWindow(self); return
        }
        if command.hasPrefix("qr:") {
            observingLeftOperation = false; parameterMessage = ""
            switch command {
            case "qr:capture": ROBNeckQRCalibration.shared.captureCurrentView()
            case "qr:sweep": ROBNeckQRCalibration.shared.runSweep()
            case "qr:fit": ROBNeckQRCalibration.shared.fitLastCapture()
            case "qr:folder": ROBNeckQRCalibration.shared.openLastCapture()
            case "qr:upper": ROBNeckQRCalibration.shared.runUpperNeckCheck()
            case "qr:protractor": ROBNeckQRCalibration.shared.startProtractorCheck()
            case "qr:postures": ROBNeckQRCalibration.shared.runPostureSweep()
            case "qr:joint-fit": ROBNeckQRCalibration.shared.fitNeckMapping()
            case "qr:all-targets": ROBNeckQRCalibration.shared.calibrateAllFourTargets()
            case "qr:selected-target": ROBNeckQRCalibration.shared.measureSelectedTarget()
            default: break
            }
            refresh()
        } else if command.hasPrefix("ghost:") {
            NotificationCenter.default.post(name: Notification.Name("ROBShowControllerInputDiagnostics"), object: self,
                                            userInfo: ["ghostPreset": String(command.dropFirst(6))])
        } else if command == "estimate:preview" {
            observingLeftOperation = true; parameterMessage = ""
            ROBLeftArmTrial.shared.prepareEstimatedCalibration { [weak self] _ in self?.refresh() }
            refresh()
        } else if command == "estimate:run" {
            observingLeftOperation = true; parameterMessage = ""
            ROBLeftArmTrial.shared.performEstimatedCalibration { [weak self] _ in self?.refresh() }
            refresh()
        } else if command == "gripper-setup" {
            observingLeftOperation = false; parameterMessage = ""
            Task { @MainActor [weak self] in
                do { try await ROBGripperStartupCalibration.shared.prepareStationaryEmptyGrippers() }
                catch { self?.parameterMessage = error.localizedDescription }
                self?.refresh()
            }
        } else if command == "show-rehearsal" { ROBShowMotionCoordinator.shared.showControls(self) }
        else if command == "speech-test" { ROBArmFeedbackAlerts.shared.testSpeech() }
        else { run(command) }
    }
    private var localReceiptFilesEnabled: Bool {
        ROBLocalRecyclingSandboxRouting.receiptFilesEnabled(trialID: selectedTrial.id,
            pendingScope: ROBControllerArmApproval.shared.pendingLocalRecyclingApprovalScope,
            operationRunning: ROBLeftArmTrial.shared.isRunning)
    }
    private func importStandingCanCampaign() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Import the private standing authorization for this can campaign."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ROBControllerArmApproval.shared.importLocalCanCampaignAuthorization(fromReceiptURL: url)
            parameterMessage = "Standing authorization imported. Run starts a fresh can plan; import sends no motion."
        } catch { parameterMessage = error.localizedDescription }
        refresh()
    }
    private var emptyHandObservationFilesEnabled: Bool {
        canEdit && ["recycling", "right-recycling"].contains(selectedTrial.id)
            && ROBControllerArmApproval.shared.canImportLocalCanCampaignEmptyObservation
    }
    private func exportEmptyHandObservationTemplate() {
        guard emptyHandObservationFilesEnabled else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "rob-empty-hand-observation-template.json"
        panel.title = "Export empty-hand observation template"
        panel.message = "Record an actual observation that both grippers are empty; this does not approve or start motion."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard emptyHandObservationFilesEnabled else {
            parameterMessage = "The campaign or active operation changed while choosing the file. No observation was exported."; refresh(); return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try ROBControllerArmApproval.shared.exportLocalCanCampaignEmptyObservationTemplate(to: url)
            parameterMessage = "Exported the private empty-hand observation template. Record the actual observation, then import it. No motion was approved or started."
        } catch { parameterMessage = error.localizedDescription }
        refresh()
    }
    private func importEmptyHandObservation() {
        guard emptyHandObservationFilesEnabled else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Import empty-hand observation"
        panel.message = "Record an actual observation that both grippers are empty; this does not approve or start motion."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard emptyHandObservationFilesEnabled else {
            parameterMessage = "The campaign or active operation changed while choosing the file. No observation was imported."; refresh(); return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try ROBControllerArmApproval.shared.importLocalCanCampaignEmptyObservation(fromReceiptURL: url)
            parameterMessage = "Recorded the actual empty-gripper observation. This did not approve, resume or start arm motion."
        } catch { parameterMessage = error.localizedDescription }
        refresh()
    }
    private func runStandingCanCampaign() {
        guard canEdit else { return }
        guard ROBControllerArmApproval.shared.standingLocalCanCampaignActive else {
            parameterMessage = "No active standing authorization. After Stop, say ‘proceed with protections’ or import a fresh authorization."; refresh(); return
        }
        guard !ROBControllerArmApproval.shared.standingCanCampaignMayHoldPayload else {
            parameterMessage = "A possible held object is still recorded. Holding; a new empty-can grasp cannot start."; refresh(); return
        }
        nominalEmptyCommissioningStep.state = .off; oneDegreeEmptyCalibrationStep.state = .off
        ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled = false
        nominalModelAssumedSelf.state = .off;ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=false
        sourcePixelSelfReview.state = .off;ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=false
        ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled = false
        prepareLocalRecyclingSessionJob()
    }
    /// Called only after a new authorization is accepted; performs fresh task
    /// camera enrollment through the ordinary native standing-run entry.
    @objc(resumeAuthorizedStandingCanCampaignWithTargetCanCount:)
    public func resumeAuthorizedStandingCanCampaign(targetCanCount: Int) {
        guard canEdit, (1...ROBRecyclingBatchRequest.maximumCount).contains(targetCanCount),
              ROBControllerArmApproval.shared.standingLocalCanCampaignActive,
              (ROBControllerArmApproval.shared.standingLocalCanCampaignState?["targetCanCount"] as? NSNumber)?.intValue == targetCanCount else {
            parameterMessage = "The new campaign or its remaining can count changed; no old plan was resumed."; refresh(); return
        }
        let trialID = ROBLocalRecyclingSandboxRouting.resumeTrialID(selectedTrialID: selectedTrial.id,
            persistedArm: UserDefaults.standard.string(forKey: Self.recyclingArmKey))
        if trialID != selectedTrial.id, let row = Self.trials.firstIndex(where: { $0.id == trialID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Explicitly rebuild before assigning the remaining count; selection
            // notifications must not leave a QR/ghost panel's missing fields.
            buildDetail()
        }
        UserDefaults.standard.set(targetCanCount, forKey: Self.recyclingCountKey)
        fields["recyclingCount"]?.stringValue = String(targetCanCount)
        runStandingCanCampaign()
    }
    public func showStandingCanCampaignResumeStatus(_ detail: String) {
        parameterMessage = detail; refresh()
    }
    private func prepareLocalRecyclingSessionJob() {
        guard canEdit else { return }
        let entered = fields["recyclingCount"].flatMap { Double($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let command = ROBLocalRecyclingSandboxRouting.preparationCommand(trialID: selectedTrial.id,
            savedCount: Self.recyclingCount, enteredCount: entered) else {
            parameterMessage = "Choose a whole number of cans from 1 to 8 and save matching test parameters before preparing the exact job."
            refresh(); return
        }
        guard let spatial = ROBLocalRecyclingSandboxRouting.spatialAllowanceMeters(
            fields["localVisualAllowanceMillimeters"].flatMap { Double($0.stringValue) }) else {
            parameterMessage = "Enter an assumed visual error from 25 to 150 mm. This is an experimental allowance, not measured calibration."
            refresh(); return
        }
        // The exact summary/context freezes this assumption before any receipt.
        guard nominalEmptyCommissioningStep.state != .on || oneDegreeEmptyCalibrationStep.state != .on else {
            parameterMessage = "Choose only one empty-arm calibration experiment before preparing its exact receipt."
            refresh(); return
        }
        let approachHold=selectedTrial.id=="right-recycling" && approachCanThenHold.state == .on
        guard !approachHold || (holdAfterInitialEmptyLift.state != .on && nominalEmptyCommissioningStep.state != .on && oneDegreeEmptyCalibrationStep.state != .on) else {
            parameterMessage="Choose approach-and-hold separately from lift-only and calibration options.";refresh();return
        }
        ROBLeftArmTrial.shared.approachUnknownAdvisoryEnabled=approachHold && approachUnknownAdvisory.state == .on
        ROBLeftArmTrial.shared.approachCanThenHoldEnabled=approachHold
        let liftHold = selectedTrial.id == "right-recycling" && holdAfterInitialEmptyLift.state == .on
        guard !liftHold || (nominalEmptyCommissioningStep.state != .on && oneDegreeEmptyCalibrationStep.state != .on) else {
            parameterMessage = "Choose only one empty-arm test; the fully checked lift-and-hold option excludes both calibration experiments."; refresh(); return
        }
        ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled = liftHold
        ROBLeftArmTrial.shared.localVisualTrialAssumedSpatialErrorMeters = spatial
        ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled = nominalEmptyCommissioningStep.state == .on
        ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled = nominalModelAssumedSelf.state == .on && nominalEmptyCommissioningStep.state == .on
        ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled = sourcePixelSelfReview.state == .on && nominalEmptyCommissioningStep.state == .on
        ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled = oneDegreeEmptyCalibrationStep.state == .on
        parameterMessage = ""; observingLeftOperation = true
        ROBLeftArmTrial.shared.performUsingLocalRecyclingReceipt(command, target: String(Self.recyclingCount)) { [weak self] result in
            guard let self else { return }
            if !ROBLeftArmTrial.shared.isRunning, !ROBControllerArmApproval.shared.isPending,
               ["blocked", "rejected", "busy", "failed"].contains(result["status"] as? String ?? ""),
               let detail = result["detail"] as? String, !detail.isEmpty {
                self.parameterMessage = detail
                self.observingLeftOperation = false
            }
            self.refresh()
        }
        refresh()
    }
    @objc private func importSourcePixelSelfTemplate() {
        guard canEdit else{return}
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.allowedFileTypes=["json"];panel.message="Import private experimental LLM source-pixel template (perception only; no movement approval)."
        guard panel.runModal() == .OK,let url=panel.url else{return}
        ROBLeftArmTrial.shared.importSourcePixelSelfReview(from:url){[weak self] result in
            self?.parameterMessage=result["detail"]as?String ?? "Pixel template import ended; no movement authority imported."
            self?.refresh()
        }
    }
    @objc private func changeSourcePixelSelfReview() {
        guard canEdit else{return}
        ROBControllerArmApproval.shared.cancel(reason:"Experimental source-pixel option changed; prepare a new exact job.")
        if sourcePixelSelfReview.state == .on {
            nominalEmptyCommissioningStep.state = .on;nominalModelAssumedSelf.state = .off;oneDegreeEmptyCalibrationStep.state = .off;holdAfterInitialEmptyLift.state = .off
            ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled=true;ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=false
            ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled=false;ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled=false
        }
        ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=sourcePixelSelfReview.state == .on
        parameterMessage="Experimental reviewed pixels are NOT registration or movement authority. Prepare freshly matches current source; all external/table/mixed points remain checked."
        ROBControllerArmApproval.shared.tick();refresh()
    }
    @objc private func changeNominalModelAssumedSelf() {
        guard canEdit else{return}
        let approval=ROBControllerArmApproval.shared
        if approval.localRecyclingApprovalState != nil || approval.pendingLocalRecyclingApprovalScope != nil {
            approval.cancel(reason:"MODEL-ASSUMED self commissioning scope changed; prepare its exact receipt.")
        }
        if nominalModelAssumedSelf.state == .on {
            sourcePixelSelfReview.state = .off;ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=false
            nominalEmptyCommissioningStep.state = .on;oneDegreeEmptyCalibrationStep.state = .off;holdAfterInitialEmptyLift.state = .off
            ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled=true
            ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled=false;ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled=false
        }
        ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=nominalModelAssumedSelf.state == .on
        parameterMessage="MODEL-ASSUMED self is an explicit property-risk hypothesis, not observed recognition. One RIGHT J2 step +14 keyframes; no jaws or chaining."
        approval.tick();refresh()
    }
    @objc private func changeNominalEmptyCommissioningStep() {
        guard canEdit else { return }
        let approval = ROBControllerArmApproval.shared
        if approval.localRecyclingApprovalState != nil || approval.pendingLocalRecyclingApprovalScope != nil {
            approval.cancel(reason: "The one-step commissioning option changed; review a new exact job receipt.")
        }
        ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled = nominalEmptyCommissioningStep.state == .on
        ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled = nominalModelAssumedSelf.state == .on && nominalEmptyCommissioningStep.state == .on
        ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled = sourcePixelSelfReview.state == .on && nominalEmptyCommissioningStep.state == .on
        if nominalEmptyCommissioningStep.state == .on {
            holdAfterInitialEmptyLift.state = .off;ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled = false
            oneDegreeEmptyCalibrationStep.state = .off
            ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled = false
        }
        parameterMessage = nominalEmptyCommissioningStep.state == .on
            ? "Next local receipt: one slow empty-arm outward step, then hold; zero transfers."
            : "One-step commissioning is off; ordinary recycling admission applies."
        approval.tick(); refresh()
    }
    @objc private func changeOneDegreeEmptyCalibrationStep() {
        guard canEdit else { return }
        let approval = ROBControllerArmApproval.shared
        if approval.localRecyclingApprovalState != nil || approval.pendingLocalRecyclingApprovalScope != nil {
            approval.cancel(reason: "The one-degree actuator calibration option changed; review a new exact job receipt.")
        }
        ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled = oneDegreeEmptyCalibrationStep.state == .on
        if oneDegreeEmptyCalibrationStep.state == .on {
            holdAfterInitialEmptyLift.state = .off;ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled = false
            nominalEmptyCommissioningStep.state = .off
            ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled = false
        nominalModelAssumedSelf.state = .off;ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=false
        sourcePixelSelfReview.state = .off;ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=false
        }
        parameterMessage = oneDegreeEmptyCalibrationStep.state == .on
            ? "Next local receipt: one four-second RIGHT J2 −0.02 rad calibration step, then hold; contact clearance is unverified; zero transfers."
            : "One-degree calibration is off; ordinary recycling admission applies."
        approval.tick(); refresh()
    }
    @objc private func changeApproachUnknownAdvisory() {
        guard canEdit else{return}
        ROBLeftArmTrial.shared.approachUnknownAdvisoryEnabled=selectedTrial.id=="right-recycling" && approachCanThenHold.state == .on && approachUnknownAdvisory.state == .on
        parameterMessage=ROBLeftArmTrial.shared.approachUnknownAdvisoryEnabled
            ? "Next exact standing open-jaw approach: UNKNOWN cells advisory only; occupied/self/person/Stop checks remain. Not certified clearance. ZERO transfers."
            : "UNKNOWN advisory is off; ordinary unobserved-space checks apply."
        ROBControllerArmApproval.shared.tick();refresh()
    }
    @objc private func changeApproachCanThenHold() {
        guard canEdit else{return}
        let enabled=selectedTrial.id=="right-recycling" && approachCanThenHold.state == .on
        ROBLeftArmTrial.shared.approachCanThenHoldEnabled=enabled
        if !enabled {approachUnknownAdvisory.state = .off;ROBLeftArmTrial.shared.approachUnknownAdvisoryEnabled=false}
        if enabled {
            holdAfterInitialEmptyLift.state = .off;ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled=false
            nominalEmptyCommissioningStep.state = .off;ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled=false
            nominalModelAssumedSelf.state = .off;ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=false
            sourcePixelSelfReview.state = .off;ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=false
            oneDegreeEmptyCalibrationStep.state = .off;ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled=false
        }
        parameterMessage=enabled ? "Next exact DEBUG job: complete checked approach, then observed open-jaw hold BEFORE close. ZERO transfers; no automatic next attempt.":"Approach-only hold is off; ordinary recycling behavior applies."
        ROBControllerArmApproval.shared.tick();refresh()
    }
    @objc private func changeHoldAfterInitialEmptyLift() {
        guard canEdit else { return }
        ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled = selectedTrial.id == "right-recycling" && holdAfterInitialEmptyLift.state == .on
        if ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled {
            nominalEmptyCommissioningStep.state = .off;oneDegreeEmptyCalibrationStep.state = .off
            ROBLeftArmTrial.shared.nominalEmptyCommissioningStepEnabled = false
        nominalModelAssumedSelf.state = .off;ROBLeftArmTrial.shared.nominalModelAssumedSelfEnabled=false
        sourcePixelSelfReview.state = .off;ROBLeftArmTrial.shared.sourcePixelSelfReviewEnabled=false
            ROBLeftArmTrial.shared.oneDegreeEmptyCalibrationStepEnabled = false
        }
        parameterMessage = ROBLeftArmTrial.shared.holdAfterInitialEmptyLiftEnabled
            ? "Next exact DEBUG job: one fully checked empty lift, then hold; no jaws or can operations, ZERO transfers."
            : "Initial-lift hold is off; ordinary recycling continues after its checked initial lift."
        // Changing the exact context invalidates only its old job. A standing
        // campaign may pause for a fresh plan without revoking its approval.
        ROBControllerArmApproval.shared.tick();refresh()
    }
    public func controlTextDidChange(_ notification: Notification) {
        guard canEdit, let field = fields["localVisualAllowanceMillimeters"],
              notification.object as? NSTextField === field else { return }
        let approval = ROBControllerArmApproval.shared
        if approval.localRecyclingApprovalState != nil {
            approval.cancel(reason: "The local visual-error assumption changed; review a new exact job receipt.")
        }
        if let spatial = ROBLocalRecyclingSandboxRouting.spatialAllowanceMeters(Double(field.stringValue)) {
            ROBLeftArmTrial.shared.localVisualTrialAssumedSpatialErrorMeters = spatial
            parameterMessage = "Local visual-error assumption updated for the next session job; this is not a measured transform."
        } else {
            parameterMessage = "Enter an assumed visual error from 25 to 150 mm before preparing the session job."
        }
        approval.tick(); refresh()
    }
    private func exportLocalRecyclingApprovalTemplate() {
        guard localReceiptFilesEnabled, let template = ROBControllerArmApproval.shared.localRecyclingReceiptTemplate else {
            parameterMessage = "Prepare the exact saved-count can job before exporting its approval template."; refresh(); return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "rob-can-session-approval-template.json"
        panel.title = "Export the pending job's approval template"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The exported source text is blank: this template cannot grant.
            let data = try JSONSerialization.data(withJSONObject: template, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            parameterMessage = "Exported a private, invalid-by-default approval template. Its actual user instructions and SHA-256 values belong only in the private receipt. Import through this sandbox when ready."
        } catch { parameterMessage = error.localizedDescription }
        refresh()
    }
    private func importLocalRecyclingApprovalReceipt() {
        guard localReceiptFilesEnabled else {
            parameterMessage = "Prepare the matching saved-count can job before importing its local approval."; refresh(); return
        }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Import the exact pending job's local user approval"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try ROBControllerArmApproval.shared.importLocalRecyclingSessionApproval(fromReceiptURL: url)
            parameterMessage = "Imported the local job-specific receipt. Motion still requires current feedback, ownership and the selected measured or explicitly unmeasured trial admission. Stop revokes this job approval."
        } catch { parameterMessage = error.localizedDescription }
        refresh()
    }
    @objc private func startSession() { run("arm_session") }
    @objc private func endSession() { run("end_arm_session") }
    private func run(_ command: String) {
        parameterMessage = ""
        observingLeftOperation = ROBLeftArmTrial.commands.contains(command)
        let target = ROBRecyclingBatchRequest.configuredCommands.contains(command) ? String(Self.recyclingCount) : ""
        ROBArmRoutineCoordinator.shared.performCommand(command, target: target) { [weak self] _ in self?.refresh() }
        refresh()
    }
    @objc private func continueObjectCycle() {
        _ = ROBLeftArmTrial.shared.continueOperation(stage: displayedCycleStage); refresh()
    }
    @objc private func showRecording() {
        if selectedTrial.id == "belly-qr-calibration" {
            ROBBellyQRCalibrationWindowController.shared.showEvidence(); return
        }
        if selectedTrial.id == "neck-qr-calibration" {
            ROBNeckQRCalibration.shared.openLastCapture(); return
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let url = ROBLocalRecyclingSandboxRouting.latestRecordingURL(trialID: selectedTrial.id,
                lastRecordingPath: ROBLeftArmTrial.shared.lastRecordingPath, applicationSupport: support) else {
            parameterMessage = "No recording is available for this selected arm test."; refresh(); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func stop() {
        ROBBellyQRCalibrationWindowController.shared.stop()
        ROBFixedHeadCalibrationWindowController.shared.stop()
        ROBNeckQRCalibration.shared.stop()
        // Includes an idle exact-job receipt retained after a perception miss.
        ROBControllerArmApproval.shared.cancel(reason: "Stop requested in Testing Sandbox")
        ROBArmRoutineCoordinator.shared.cancel(reason: "Stop requested in Testing Sandbox")
        _ = ROBAmberGestureExecutor.shared.cancelCurrentGesture(reason: "Stop requested in Testing Sandbox")
        _ = ROBAmberGestureExecutor.shared.requestPriorityHold()
        refresh()
    }
    private func refreshCollisionInfo() {
        let search = ROBWorkspaceSearch.shared, snapshot = search.collisionPreviewSnapshot
        let admissionCurrent = snapshot != nil && snapshot?.fingerprint == search.collisionSnapshot?.fingerprint
        collisionInfo.stringValue = ROBWorkspaceCollisionPresentation.summary(
            snapshot: snapshot,
            review: ROBLeftArmTrial.shared.collisionReviewStatus,
            proposal: ROBLeftArmTrial.shared.collisionReviewProposal,
            admissionCurrent: admissionCurrent)
    }
    @objc private func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }; return
        }
        refreshCollisionInfo()
        let left = ROBLeftArmTrial.shared
        let approval = ROBControllerArmApproval.shared
        if let activity = ROBLocalRecyclingSandboxRouting.activityStatus(trialRunning: left.isRunning,
            trialStatus: left.status, approvalPending: approval.isPending, approvalStatus: approval.status,
            localReceiptState: approval.localRecyclingApprovalState) {
            status.stringValue = activity
        } else if ROBBellyQRCalibrationWindowController.shared.isRunning || selectedTrial.id == "belly-qr-calibration" {
            status.stringValue = ROBBellyQRCalibrationWindowController.shared.status
        } else if ROBNeckQRCalibration.shared.isRunning || selectedTrial.id == "neck-qr-calibration" {
            status.stringValue = ROBNeckQRCalibration.shared.status
        } else if left.isRunning || observingLeftOperation {
            status.stringValue = left.status
        } else if ROBGripperStartupCalibration.shared.isRunning {
            status.stringValue = ROBGripperStartupCalibration.shared.status
        } else {
            status.stringValue = ROBArmRoutineCoordinator.shared.status
        }
        if !parameterMessage.isEmpty {
            status.stringValue = left.isRunning ? status.stringValue + "\n" + parameterMessage : parameterMessage + "\n" + status.stringValue
        }
        status.stringValue = ROBLocalRecyclingSandboxRouting.displayStatus(status.stringValue)
        session.stringValue = ROBControllerArmApproval.shared.armSessionDetail
        localApprovalInfo.stringValue = ROBLocalRecyclingSandboxRouting.scopeDescription(
            pending: ROBControllerArmApproval.shared.pendingLocalRecyclingApprovalScope,
            imported: ROBControllerArmApproval.shared.localRecyclingApprovalState)
        standingCampaignInfo.stringValue = ROBLocalRecyclingSandboxRouting.standingDescription(
            ROBControllerArmApproval.shared.standingLocalCanCampaignState)
        displayedCycleStage = left.interactionStage
        switch displayedCycleStage {
        case "object_placed": continueCycle.title = "Object placed; fingers clear → Grip"
        case "receiver_supporting": continueCycle.title = "Hand supporting object → Release"
        case "object_clear": continueCycle.title = "Object clear of jaws → Lower empty arm"
        default: continueCycle.title = "Continue object cycle"
        }
        continueCycle.isHidden = displayedCycleStage.isEmpty
        continueCycle.isEnabled = left.isRunning && !displayedCycleStage.isEmpty
        for field in fields.values { field.isEnabled = canEdit }
        nominalEmptyCommissioningStep.isEnabled = canEdit
        nominalEmptyCommissioningStep.state = left.nominalEmptyCommissioningStepEnabled ? .on : .off
        nominalModelAssumedSelf.state = left.nominalModelAssumedSelfEnabled ? .on:.off
        nominalModelAssumedSelf.isEnabled = canEdit && selectedTrial.id=="right-recycling"
        sourcePixelSelfReview.state=left.sourcePixelSelfReviewEnabled ? .on:.off
        sourcePixelSelfReview.isEnabled=canEdit && selectedTrial.id=="right-recycling"
        importSourcePixelReview.isEnabled=canEdit && selectedTrial.id=="right-recycling"
        oneDegreeEmptyCalibrationStep.isEnabled = canEdit
        oneDegreeEmptyCalibrationStep.state = left.oneDegreeEmptyCalibrationStepEnabled ? .on : .off
        approachUnknownAdvisory.isEnabled=canEdit && selectedTrial.id=="right-recycling" && left.approachCanThenHoldEnabled
        approachUnknownAdvisory.state=left.approachUnknownAdvisoryEnabled ? .on:.off
        approachCanThenHold.isEnabled=canEdit && selectedTrial.id=="right-recycling"
        approachCanThenHold.state=left.approachCanThenHoldEnabled ? .on:.off
        holdAfterInitialEmptyLift.isEnabled = canEdit && selectedTrial.id == "right-recycling"
        holdAfterInitialEmptyLift.state = left.holdAfterInitialEmptyLiftEnabled ? .on : .off
        save.isEnabled = canEdit
        for button in actionButtons {
            let command = selectedTrial.actions.indices.contains(button.tag) ? selectedTrial.actions[button.tag].command : ""
            let isQRStop = selectedTrial.actions.indices.contains(button.tag)
                && selectedTrial.actions[button.tag].command == "qr:stop"
            let isQRNext = selectedTrial.actions.indices.contains(button.tag)
                && selectedTrial.actions[button.tag].command == "qr:next"
            button.isEnabled = ["local-recycling:export", "local-recycling:import"].contains(command)
                ? localReceiptFilesEnabled
                : ["local-recycling:empty-observation-export", "local-recycling:empty-observation-import"].contains(command)
                    ? emptyHandObservationFilesEnabled
                : command == "local-recycling:standing-run" ? canEdit && ROBControllerArmApproval.shared.standingLocalCanCampaignActive
                : isQRStop || (isQRNext ? ROBNeckQRCalibration.shared.awaitingProtractor : canEdit)
        }
        qrTarget.isEnabled = canEdit
        protractorPitch.isEnabled = ROBNeckQRCalibration.shared.awaitingProtractor
        startSessionButton.isEnabled = canEdit && !ROBControllerArmApproval.shared.armSessionActive
        endSessionButton.isEnabled = ROBControllerArmApproval.shared.armSessionActive
    }
}

private final class ROBTestingSandboxDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Local UI routing only. No text or template produced here authorizes motion.
enum ROBLocalRecyclingSandboxRouting {
    static func displayStatus(_ text:String)->String {
        guard text.contains("Stationary arm guard failed:"),
              text.contains("Pausing nonactuating search for fresh unchanged feedback; no command admitted.") else {return text}
        return "Arm feedback was delayed during the stationary scan (limit 0.35 seconds). No arm motion was sent. Details are saved with the trial recording."
    }
    static func standingDescription(_ value: NSDictionary?) -> String {
        guard let value else { return "Standing can campaign: no active authorization. Import once, or after Stop say ‘proceed with protections’." }
        let state = value["state"] as? String ?? "unavailable"
        let transfers = (value["completedTransfers"] as? NSNumber)?.intValue ?? 0
        let landings = (value["verifiedLandings"] as? NSNumber)?.intValue ?? 0
        let count = (value["targetCanCount"] as? NSNumber)?.intValue ?? (value["canCount"] as? NSNumber)?.intValue ?? 4
        return "Standing can campaign: \(state). Transfers reported \(transfers)/\(count); bucket landings camera-verified \(landings).\n"
            + displayStatus(value["detail"] as? String ?? "") + " Stop revokes this authorization."
    }
    static func activityStatus(trialRunning: Bool, trialStatus: String, approvalPending: Bool,
        approvalStatus: String, localReceiptState: NSDictionary?) -> String? {
        if trialRunning {
            return (localReceiptState?["state"] as? String == "executing" ? "Local session receipt executing.\n" : "") + trialStatus
        }
        return approvalPending ? approvalStatus : nil
    }
    static func latestRecordingURL(trialID: String, lastRecordingPath: String,
        applicationSupport: URL, fileManager: FileManager = .default) -> URL? {
        let arm = trialID.hasPrefix("right-") ? "right" : physicalArm(trialID: trialID)
        guard let arm else { return lastRecordingPath.isEmpty ? nil : URL(fileURLWithPath: lastRecordingPath) }
        let directory = applicationSupport.appendingPathComponent("Cerebro/\(arm == "right" ? "Right" : "Left")ArmTrials")
        var files = (try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        if !lastRecordingPath.isEmpty { files.append(URL(fileURLWithPath: lastRecordingPath)) }
        return files.filter { url in
            url.pathExtension == "csv" && url.lastPathComponent.hasPrefix(arm + "_") &&
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.max { a, b in
            let first = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
    }
    static func spatialAllowanceMeters(_ millimeters: Double?) -> Double? {
        guard let millimeters, millimeters.isFinite, (25...150).contains(millimeters) else { return nil }
        return millimeters / 1000
    }
    static func physicalArm(trialID: String) -> String? {
        switch trialID {
        case "right-recycling": return "right"
        case "recycling": return "left"
        default: return nil
        }
    }
    static func resumeTrialID(selectedTrialID: String, persistedArm: String?) -> String {
        if physicalArm(trialID: selectedTrialID) != nil { return selectedTrialID }
        return persistedArm == "left" ? "recycling" : "right-recycling"
    }
    static func preparationCommand(trialID: String, savedCount: Int, enteredCount: Double?) -> String? {
        guard let arm = physicalArm(trialID: trialID), (1...ROBRecyclingBatchRequest.maximumCount).contains(savedCount),
              let enteredCount, enteredCount.isFinite, enteredCount == Double(savedCount) else { return nil }
        return arm + "_recycle_cans"
    }
    static func receiptFilesEnabled(trialID: String, pendingScope: NSDictionary?, operationRunning: Bool) -> Bool {
        guard !operationRunning, let arm = physicalArm(trialID: trialID), let scope = pendingScope,
              scope["arm"] as? String == arm, scope["command"] as? String == arm + "_recycle_cans",
              let count = (scope["canCount"] as? NSNumber)?.doubleValue, count.isFinite,
              (1...Double(ROBRecyclingBatchRequest.maximumCount)).contains(count), count.rounded()==count else { return false }
        return true
    }
    static func scopeDescription(pending: NSDictionary?, imported: NSDictionary?) -> String {
        guard let scope = imported ?? pending else { return "Local session approval: no imported job is available or executing. Prepare a saved-count can job to review its exact scope." }
        let state = imported?["state"] as? String ?? "waiting for private receipt; no grant"
        let arm = scope["arm"] as? String ?? "unknown"
        let command = scope["command"] as? String ?? "unknown"
        let source = imported?["source"] as? String ?? "no local receipt imported"
        let count = (scope["canCount"] as? NSNumber)?.intValue ?? 0
        var lines = ["Local session approval: " + state, "Source: " + source,
            "Job: \(count) empty Coke cans → orange bucket · physical " + arm.uppercased() + " arm",
            "Command: " + command,
            "Scope: " + (scope["summary"] as? String ?? "missing"),
            "Summary SHA-256: " + (scope["summarySHA256"] as? String ?? "missing"),
            "Context: " + (scope["contextIdentity"] as? String ?? "missing")]
        if let receipt = imported?["receiptID"] as? String { lines.append("Receipt: " + receipt) }
        if let milliseconds = imported?["beginBeforeMilliseconds"] as? Double, milliseconds.isFinite {
            lines.append("Begin before: " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: milliseconds / 1000), dateStyle: .short, timeStyle: .short))
        }
        if scope["permitsUnmeasuredVisualCalibrationTrial"] as? Bool == true {
            lines.append(imported == nil ? "Unmeasured visual trial: requested, not yet approved." : "Unmeasured visual trial: explicitly permitted; planner admission is separate.")
        }
        if let hash=scope["sourcePixelSelfReviewSHA256"]as?String {
            lines.append("DEBUG LLM-reviewed source pixels, matched to current RAW scene. Evidence SHA256 "+hash+". Experimental/not registration; no MODEL-hull fallback. Table/person/uncertain/unmasked/mixed groups remain external. One J2-only empty step +14keyframes; exact receipt still required.")
        }
        if scope["nominalModelAssumedSelfEnabled"]as?Bool==true {
            lines.append("MODEL-ASSUMED alignment, NOT observed self. Whole original groups inside noninflated baseline moving-link hulls only; all raw data retained. One J2-only step, 14 timed keyframes, hold. Contact/property risk accepted for this experiment; no normal clearance or transfer credit.")
        }
        if scope["nominalEmptyCommissioningStepEnabled"] as? Bool == true {
            lines.append("Commissioning only: one slow empty-arm outward step, then hold. Current robot occupancy is assumed from the model; calibration and local unknown space unverified. No grip, carry, release or automatic return. Zero transfers.")
        }
        if scope["oneDegreeEmptyCalibrationStepEnabled"] as? Bool == true {
            lines.append("Actuator/model calibration only: RIGHT J2 −0.02 rad, 4 seconds, at most 2 cm modeled travel, then hold. Collision clearance unverified; contact predictions diagnostic only. Contact may push the table or lift ROB. No payload, jaws, grasp, carry, release, return or chaining. Zero transfers; Stop and fresh feedback required.")
        }
        lines.append("Both arms may hold stationary; only the selected arm travels. Treads, torso and manual gestures are excluded. Stop revokes this approval.")
        return lines.joined(separator: "\n")
    }
}

/// Read-only presentation shared by the sandbox and SceneKit preview. A model
/// prior is never promoted to measured registration by a status label.
enum ROBWorkspaceCollisionPresentation {
    static func summary(snapshot: ROBWorkspaceCollisionSnapshot?, review: NSDictionary,
                        proposal: ROBLeftGestureProposal?, admissionCurrent: Bool = true,
                        nowMilliseconds: Double = Date().timeIntervalSince1970 * 1000) -> String {
        var lines: [String] = []
        if let snapshot {
            let age = nowMilliseconds - snapshot.lastCapturedAtMilliseconds
            let ageText = age.isFinite && age >= 0 ? String(format: "%.1f s old", age / 1000) : "capture time invalid"
            lines.append("Depth map: \(snapshot.occupiedVoxelCount) occupied cells · \(snapshot.observedFrameCount) frames · " + ageText)
            if !admissionCurrent { lines.append("Stored scan preview; rescan before motion.") }
            if snapshot.isTruncated { lines.append("Coverage incomplete: map capacity reached; free space remains unverified.") }
        } else { lines.append("Depth map: no current captured scene") }
        let registrationVerified = admissionCurrent && review["registration_verified"] as? Bool == true
            && snapshot?.registrationID?.isEmpty == false
            && snapshot?.registrationUncertaintyMeters.map({ $0.isFinite && $0 >= 0 }) == true
        lines.append(registrationVerified ? "Registration: measured for this scene" : "Registration: unverified · visualization only")
        if let clearance = review["minimum_clearance_m"] as? Double, clearance.isFinite {
            lines.append(String(format: "Last reviewed model clearance: %.1f cm", clearance * 100))
        } else { lines.append("Path clearance: not evaluated") }
        if let proposal { lines.append("Path preview: \(proposal.steps.count) steps · \(Int(ceil(proposal.seconds))) s scheduled") }
        else { lines.append("Path preview: no validated route available") }
        if let blocked = review["blocked_reason"] as? String, !blocked.isEmpty { lines.append("Blocked: " + blocked) }
        else if let detail = review["detail"] as? String, !detail.isEmpty { lines.append(detail) }
        lines.append("Observed surfaces only; unseen space remains unknown.")
        return lines.joined(separator: "\n")
    }
}
