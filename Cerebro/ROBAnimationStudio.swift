import Cocoa
import UniformTypeIdentifiers

/// Both the original three tables and the expanded editor use this one store
/// and stable selection. Row numbers are never persisted or used after reload.
@objc(ROBAnimationStudio) final class ROBAnimationStudio: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    @objc static let shared = ROBAnimationStudio()
    static let previewChanged = Notification.Name("ROBAnimationPreviewChanged")
    private let store: ROBAnimationStore
    private let previewUptime: () -> Double
    private enum Role { case library, clips, sequences }
    private struct Table { weak var view: NSTableView?; let role: Role }
    private var tables: [Table] = []
    private weak var legacyPoseName: NSTextField?
    private weak var legacySequenceName: NSTextField?
    private var capture: (() -> [String: NSNumber])?
    private var enabled: (() -> [String])?
    private weak var serial: ROBSerialBox?
    private var windowController: NSWindowController?
    private var libraryID: UUID?
    private var sequenceID: UUID?
    private var clipID: UUID?
    private enum Editing { case new, pose(UUID), clip(UUID, UUID) }
    private var editing = Editing.new
    private var draft = ROBAnimationPose(name: "New pose", values: [:])
    private var draftRevision = 0
    private var reloading = false
    private var draftDirty = false
    private var timingDirty = false
    private var inboxTimer: Timer?
    private var previewTimer: Timer?
    private var previewLastTick = 0.0
    private var previewElapsed = 0.0
    private var previewRate = 1.0
    private var previewSequence: ROBAnimationSequence?
    private var previewBaseline: [String: Double] = [:]
    private let previewPlay = NSButton(title: "Play ghost", target: nil, action: nil)
    private let previewSpeed = NSPopUpButton()
    private let previewLoop = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private static let previewRates = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    private var undoHistory: [ROBAnimationDocument] = []
    private var redoHistory: [ROBAnimationDocument] = []
    private let poseName = NSTextField(string: "New pose")
    private let sequenceName = NSTextField(string: "New sequence")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let selectionInfo = NSTextField(wrappingLabelWithString: "Draft · no channels selected")
    private let transition = NSTextField(string: "2.0")
    private let hold = NSTextField(string: "0.0")
    private let easing = NSPopUpButton()
    private let role = NSPopUpButton()
    private let greeting = NSPopUpButton()
    private let armSpeed = NSSlider(value: 100, minValue: 25, maxValue: 200, target: nil, action: nil)
    private let armSpeedPercent = NSTextField(string: "100")
    private let ghostLean = NSTextField(string: "")
    private let timeline = ROBAnimationTimeline()
    private let clock = NSTextField(labelWithString: "0.00 s")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var fields: [String: NSTextField] = [:]
    private var includes: [String: NSButton] = [:]
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    private var lastObservedRevision = 0

    override convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(store: ROBAnimationStore(url: documents.appendingPathComponent("ROB Animations/library.json"),
            legacyDirectory: documents.appendingPathComponent("ROB KeyframeAnimations")))
    }
    init(store: ROBAnimationStore, previewUptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.previewUptime = previewUptime
        super.init()
        sequenceID = store.document.sequences.first?.id
        draftRevision = store.document.revision; lastObservedRevision = draftRevision
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollInbox() }
        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged), name: ROBAnimationPlayback.changed, object: nil)
    }

    @objc func connect(library: NSTableView, clips: NSTableView, sequences: NSTableView,
                       poseName: NSTextField, sequenceName: NSTextField, serial: ROBSerialBox,
                       capture: @escaping () -> [String: NSNumber], enabled: @escaping () -> [String]) {
        self.serial = serial; self.capture = capture; self.enabled = enabled
        legacyPoseName = poseName; legacySequenceName = sequenceName
        register(library, as: .library); register(clips, as: .clips); register(sequences, as: .sequences)
        reload()
    }
    private func register(_ table: NSTableView, as role: Role) {
        tables.append(Table(view: table, role: role)); table.dataSource = self; table.delegate = self
        table.rowHeight = 26; table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.tableColumns.first?.title = role == .library ? "Pose library" : role == .clips ? "Sequence clips" : "Sequences"
    }
    private var selectedSequence: ROBAnimationSequence? { store.document.sequences.first { $0.id == sequenceID } }
    private func role(of table: NSTableView) -> Role? { tables.first { $0.view === table }?.role }
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch role(of: tableView) {
        case .library: return store.document.poses.count
        case .clips: return selectedSequence?.clips.count ?? 0
        case .sequences: return store.document.sequences.count
        case nil: return 0
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
        let text: String
        switch role(of: tableView) {
        case .library:
            let pose = store.document.poses[row]
            text = pose.name + (pose.role == nil ? "" : " ★") + (pose.needsReview ? " · review" : "")
        case .clips:
            guard let clip = selectedSequence?.clips[row] else { return nil }
            text = "\(row + 1). \(clip.pose.name)  ·  \(format(clip.transition))s + \(format(clip.hold))s"
        case .sequences:
            let sequence = store.document.sequences[row]
            text = "\(sequence.name)  ·  \(sequence.clips.count) clips"
        case nil: return nil
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.toolTip = text; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let table = notification.object as? NSTableView,
              table.selectedRow >= 0, table.selectedRow < numberOfRows(in: table) else { return }
        // Preserve an edited draft until the user explicitly saves or discards it.
        if draftDirty || timingDirty { message("Save the draft with Record new / Update selected, or choose Discard draft before selecting another pose."); reload(); return }
        switch role(of: table) {
        case .library:
            let value = store.document.poses[table.selectedRow]; libraryID = value.id
            load(value, editing: .pose(value.id)); clipID = nil
        case .clips:
            guard let sequence = selectedSequence else { return }
            let value = sequence.clips[table.selectedRow]; clipID = value.id
            load(value.pose, editing: .clip(sequence.id, value.id)); loadTiming(value)
        case .sequences:
            sequenceID = store.document.sequences[table.selectedRow].id; clipID = nil
            stopPreview(); scrubber.doubleValue = 0; sequenceName.stringValue = selectedSequence?.name ?? ""
        case nil: return
        }
        reload(); showDraftPreview(open: false)
    }

    @objc func show() {
        if windowController == nil { buildWindow() }
        windowController?.showWindow(nil); windowController?.window?.makeKeyAndOrderFront(nil)
        reload(); message(store.loadError ?? "Select channels, capture controls, then Record new. Scrubbing moves only the ghost.")
    }
    /// Read-only lookup for mission/LLM consumers. Sparse joint masks are
    /// retained; callers must resolve omitted joints from current feedback.
    @objc func graspReadyValues(physicalSide: String, vertical: Bool) -> [String: NSNumber]? {
        guard ["left", "right"].contains(physicalSide),
              let pose = store.document.poses.first(where: { $0.role == "grasp.\(vertical ? "vertical" : "horizontal").\(physicalSide)" }),
              !pose.needsReview else { return nil }
        return pose.values.mapValues(NSNumber.init(value:))
    }

    @objc func recordLegacyControls() {
        draft = ROBAnimationPose(name: legacyPoseName?.stringValue ?? "New pose", values: [:])
        let values = capture?() ?? [:]
        for key in enabled?() ?? [] { if let value = values[key] { draft.values[key] = value.doubleValue } }
        draftRevision = store.document.revision; editing = .new; draftDirty = false
        syncDraft(); recordNew()
    }
    @objc func legacyNameChanged(_ name: String) { draft.name = name; poseName.stringValue = name; draftDirty = true }
    @objc func renameSequence(_ name: String) {
        guard let id = sequenceID else { return }
        commit { document in
            guard let i = document.sequences.firstIndex(where: { $0.id == id }) else { throw ROBAnimationError.invalid("Sequence was deleted.") }
            document.sequences[i].name = name
        }
    }
    @objc func newSequence() {
        let value = ROBAnimationSequence(name: "Sequence \(store.document.sequences.count + 1)")
        if commit({ $0.sequences.append(value) }) { sequenceID = value.id; clipID = nil; reload() }
    }
    @objc func addSelectedPose() {
        guard let id = libraryID, let value = store.document.poses.first(where: { $0.id == id }), let sequenceID else {
            message("Select a library pose and a sequence first."); return
        }
        let clip = ROBAnimationClip(pose: value)
        if commit({ document in
            guard let i = document.sequences.firstIndex(where: { $0.id == sequenceID }) else { throw ROBAnimationError.invalid("Sequence was deleted.") }
            document.sequences[i].clips.append(clip)
        }) { clipID = clip.id; load(clip.pose, editing: .clip(sequenceID, clip.id)); loadTiming(clip); reload() }
    }
    @objc func previewPose() { show(); showDraftPreview(open: true) }
    @objc func previewSelectedSequence() {
        guard let sequence = selectedSequence, !sequence.clips.isEmpty else { message("Add poses to a sequence first."); return }
        if previewTimer != nil {
            advancePreview(at: previewUptime())
            guard previewSequence != nil else { return }
            previewTimer?.invalidate(); previewTimer = nil; previewPlay.title = "Play ghost"
            message("Ghost preview paused. Play ghost resumes from this frame.")
        } else if previewSequence == sequence {
            resumePreview(); message("Ghost preview resumed at \(format(previewRate))×. No robot commands.")
        } else { show(); startPreview(sequence) }
    }

    private func load(_ pose: ROBAnimationPose, editing: Editing) {
        draft = pose; self.editing = editing; draftRevision = store.document.revision; draftDirty = false; timingDirty = false; syncDraft()
    }
    private func syncDraft() {
        poseName.stringValue = draft.name; legacyPoseName?.stringValue = draft.name
        ghostLean.stringValue = draft.previewLeanDegrees.map(format) ?? ""
        role.selectItem(at: draft.role.flatMap { ROBAnimationDocument.roles.firstIndex(of: $0) }.map { $0+1 } ?? 0)
        for channel in ROBAnimationChannel.all {
            includes[channel.id]?.state = draft.values[channel.id] == nil ? .off : .on
            fields[channel.id]?.stringValue = format(draft.values[channel.id] ?? channel.defaultValue)
            fields[channel.id]?.isEnabled = draft.values[channel.id] != nil
        }
        let destination: String
        switch editing { case .new: destination = "New draft"; case .pose: destination = "Editing library pose"; case .clip: destination = "Editing this sequence clip only" }
        selectionInfo.stringValue = "\(destination) · \(draft.values.count) included channels · omitted channels keep their position."
            + (draft.needsReview ? " Imported slider units need review; Update selected confirms these values." : "")
            + (draft.note.isEmpty ? "" : "\n\(draft.note)")
    }
    private func readDraft() throws -> ROBAnimationPose {
        var value = draft; value.name = poseName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.values = [:]
        for channel in ROBAnimationChannel.all where includes[channel.id]?.state == .on {
            guard let number = Double(fields[channel.id]?.stringValue ?? ""), number.isFinite else {
                throw ROBAnimationError.invalid("Enter a finite number for \(channel.name).")
            }
            value.values[channel.id] = number
        }
        // Original compact panel has no inspector yet; use its captured values.
        if fields.isEmpty { value.values = draft.values; value.name = draft.name }
        if !fields.isEmpty {
            let lean = ghostLean.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if lean.isEmpty { value.previewLeanDegrees = nil }
            else {
                guard let degrees = Double(lean), degrees.isFinite, (0...45).contains(degrees) else {
                    throw ROBAnimationError.invalid("Ghost lean must be 0–45 degrees, or blank to retain the previous illustration.")
                }
                value.previewLeanDegrees = degrees
            }
        }
        value.role = role.indexOfSelectedItem > 0 ? ROBAnimationDocument.roles[role.indexOfSelectedItem - 1] : nil
        guard !value.values.isEmpty else { throw ROBAnimationError.invalid("Include at least one channel before recording a pose.") }
        return value
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === transition || field === hold { timingDirty = true }
        else if field === poseName || field === ghostLean || fields.values.contains(where: { $0 === field }) { editDraft(field) }
    }
    @objc private func editDraft(_ sender: Any?) {
        draftDirty = true
        for channel in ROBAnimationChannel.all { fields[channel.id]?.isEnabled = includes[channel.id]?.state == .on }
        if let value = try? readDraft() { draft = value; legacyPoseName?.stringValue = value.name; showDraftPreview(open: false) }
    }
    @objc private func captureControls() {
        let values = capture?() ?? [:]
        for channel in ROBAnimationChannel.all where includes[channel.id]?.state == .on {
            if let value = values[channel.id] { fields[channel.id]?.stringValue = format(value.doubleValue) }
        }
        editDraft(nil); message("Captured selected control targets. Nothing moved; press Record new or Update selected to save.")
    }
    @objc private func newDraft() {
        load(.init(name: "New pose", values: [:]), editing: .new); libraryID = nil; clipID = nil; reload()
    }
    @objc private func discardDraft() {
        switch editing {
        case .pose(let id): if let pose = store.document.poses.first(where: { $0.id == id }) { load(pose, editing: .pose(id)) } else { newDraft() }
        case .clip(let s, let c): if let clip = store.document.sequences.first(where: { $0.id == s })?.clips.first(where: { $0.id == c }) { load(clip.pose, editing: .clip(s,c)); loadTiming(clip) } else { newDraft() }
        case .new: newDraft()
        }
    }
    @objc private func recordNew() {
        do {
            var value = try readDraft(); value.id = UUID(); value.needsReview = false
            if commit({ document in
                if let role = value.role { for i in document.poses.indices where document.poses[i].role == role { document.poses[i].role = nil } }
                document.poses.append(value)
            }) { libraryID = value.id; load(value, editing: .pose(value.id)); reload() }
        } catch { message(error.localizedDescription) }
    }
    @objc private func updateSelected() {
        do {
            var value = try readDraft(); value.needsReview = false
            switch editing {
            case .new: message("Use Record new for a new draft."); return
            case .pose(let id):
                value.id = id
                if commit(expected: draftRevision, { document in
                    guard let i = document.poses.firstIndex(where: { $0.id == id }) else { throw ROBAnimationError.invalid("Pose was deleted.") }
                    if let role = value.role { for j in document.poses.indices where document.poses[j].role == role { document.poses[j].role = nil } }
                    document.poses[i] = value
                }) { load(value, editing: .pose(id)) }
            case .clip(let sequence, let clip):
                let timing = try readTiming()
                if commit(expected: draftRevision, { document in
                    guard let s = document.sequences.firstIndex(where: { $0.id == sequence }), let c = document.sequences[s].clips.firstIndex(where: { $0.id == clip }) else { throw ROBAnimationError.invalid("Clip was deleted.") }
                    value.id = document.sequences[s].clips[c].pose.id; value.role = nil
                    document.sequences[s].clips[c].pose = value
                    document.sequences[s].clips[c].transition = timing.0
                    document.sequences[s].clips[c].hold = timing.1
                    document.sequences[s].clips[c].easing = timing.2
                }) { load(value, editing: .clip(sequence, clip)) }
            }
            reload()
        } catch { message(error.localizedDescription) }
    }
    private func readTiming() throws -> (Double, Double, ROBAnimationEase) {
        guard let t = Double(transition.stringValue), let h = Double(hold.stringValue), t.isFinite, h.isFinite else { throw ROBAnimationError.invalid("Enter finite transition and hold seconds.") }
        return (t, h, easing.indexOfSelectedItem == 0 ? .smooth : .linear)
    }
    private func loadTiming(_ clip: ROBAnimationClip) {
        transition.stringValue = format(clip.transition); hold.stringValue = format(clip.hold); easing.selectItem(at: clip.easing == .smooth ? 0 : 1)
    }
    @objc private func timingChanged() { timingDirty = true }
    @objc private func applyTiming() {
        guard let sequenceID, let clipID else { message("Select a sequence clip to edit its timing."); return }
        do {
            let timing = try readTiming()
            if commit(expected: draftRevision, { document in
                guard let s = document.sequences.firstIndex(where: { $0.id == sequenceID }), let c = document.sequences[s].clips.firstIndex(where: { $0.id == clipID }) else { throw ROBAnimationError.invalid("Clip was deleted.") }
                document.sequences[s].clips[c].transition = timing.0; document.sequences[s].clips[c].hold = timing.1; document.sequences[s].clips[c].easing = timing.2
            }) { timingDirty = false; draftRevision = store.document.revision }

        } catch { message(error.localizedDescription) }
    }
    @objc private func moveUp() { moveClip(-1) }
    @objc private func moveDown() { moveClip(1) }
    private func moveClip(_ delta: Int) {
        guard let sequenceID, let clipID else { return }
        commit { document in
            guard let s = document.sequences.firstIndex(where: { $0.id == sequenceID }), let c = document.sequences[s].clips.firstIndex(where: { $0.id == clipID }), document.sequences[s].clips.indices.contains(c+delta) else { return }
            document.sequences[s].clips.swapAt(c, c+delta)
        }
    }
    @objc private func duplicateClip() {
        guard let sequenceID, let clipID else { return }
        var next: UUID?
        if commit({ document in
            guard let s = document.sequences.firstIndex(where: { $0.id == sequenceID }), let c = document.sequences[s].clips.firstIndex(where: { $0.id == clipID }) else { return }
            var copy = document.sequences[s].clips[c]; copy.id = UUID(); copy.pose.id = UUID(); next = copy.id
            document.sequences[s].clips.insert(copy, at: c+1)
        }) {
            self.clipID = next
            if let value = selectedSequence?.clips.first(where: { $0.id == next }) { load(value.pose, editing: .clip(sequenceID, value.id)); loadTiming(value) }
            reload()
        }
    }
    @objc private func refreshClipFromLibrary() {
        guard let sequenceID, let clipID else { return }
        commit { document in
            guard let s = document.sequences.firstIndex(where: { $0.id == sequenceID }), let c = document.sequences[s].clips.firstIndex(where: { $0.id == clipID }),
                  let id = document.sequences[s].clips[c].sourcePoseID, let pose = document.poses.first(where: { $0.id == id }) else { throw ROBAnimationError.invalid("This clip's source pose is unavailable.") }
            var value = pose; value.id = document.sequences[s].clips[c].pose.id; value.role = nil
            document.sequences[s].clips[c].pose = value
        }
        if !draftDirty && !timingDirty { discardDraft() }
    }
    @objc private func deletePose() {
        guard let libraryID else { return }
        if commit({ $0.poses.removeAll { $0.id == libraryID } }) { self.libraryID = nil; if !draftDirty && !timingDirty { newDraft() }; reload() }
    }
    @objc private func deleteClip() {
        guard let sequenceID, let clipID else { return }
        if commit({ document in
            guard let s = document.sequences.firstIndex(where: { $0.id == sequenceID }) else { return }
            document.sequences[s].clips.removeAll { $0.id == clipID }
        }) { self.clipID = nil; if !draftDirty && !timingDirty { newDraft() }; reload() }
    }
    @objc private func deleteSequence() {
        guard let sequenceID else { return }
        if commit({ $0.sequences.removeAll { $0.id == sequenceID } }) { self.sequenceID = nil; clipID = nil; reload() }
    }
    @objc private func renameSelectedSequence() { renameSequence(sequenceName.stringValue) }
    @objc private func greetingChanged() {
        guard let id = sequenceID else { return }
        let enabled = greeting.indexOfSelectedItem == 1
        commit { document in
            guard let i = document.sequences.firstIndex(where: { $0.id == id }) else { throw ROBAnimationError.invalid("Sequence was deleted.") }
            document.sequences[i].completionGreeting = enabled ? (document.sequences[i].completionGreeting ?? ROBAnimationGreeting()) : nil
        }
    }
    @objc private func armSpeedChanged(_ sender: Any?) {
        guard let id = sequenceID else { return }
        let percent: Double?
        if sender as? NSSlider === armSpeed { percent = armSpeed.doubleValue.rounded() }
        else { percent = Double(armSpeedPercent.stringValue) }
        guard let percent, percent.isFinite, (25...200).contains(percent) else {
            message("Enter arm speed from 25 to 200 percent."); reload(); return
        }
        if commit({ document in
            guard let i = document.sequences.firstIndex(where: { $0.id == id }) else { throw ROBAnimationError.invalid("Sequence was deleted.") }
            document.sequences[i].armSpeedMultiplier = percent == 100 ? nil : percent/100
        }) { message("Arm speed \(format(percent))% saved for the next Run. Motor limits apply; other tracks keep their timing.") }
    }

    @discardableResult private func commit(expected: Int? = nil, _ mutation: (inout ROBAnimationDocument) throws -> Void) -> Bool {
        do {
            let previous = store.document; var next = previous; try mutation(&next)
            guard next != previous else { return true }
            try store.replace(next, expectedRevision: expected ?? previous.revision)
            undoHistory.append(previous); if undoHistory.count > 100 { undoHistory.removeFirst() }; redoHistory = []
            lastObservedRevision = store.document.revision
            if !draftDirty && !timingDirty { draftRevision = store.document.revision }
            stopPreview(); reload(); message("Saved revision \(store.document.revision). Existing clips keep their own pose snapshots.")
            return true
        } catch { message(error.localizedDescription); reload(); return false }
    }
    @objc private func undoEdit() { restoreHistory(undo: true) }
    @objc private func redoEdit() { restoreHistory(undo: false) }
    private func restoreHistory(undo: Bool) {
        guard var previous = undo ? undoHistory.last : redoHistory.last else { return }
        let current = store.document; previous.revision = current.revision
        do {
            try store.replace(previous, expectedRevision: current.revision)
            if undo { undoHistory.removeLast(); redoHistory.append(current) } else { redoHistory.removeLast(); undoHistory.append(current) }
            lastObservedRevision = store.document.revision; stopPreview(); reload()
            if !draftDirty && !timingDirty { discardDraft() }
            message("\(undo ? "Undo" : "Redo") saved as revision \(store.document.revision).")
        } catch { message(error.localizedDescription) }
    }
    private func pollInbox() {
        let reports = store.processInbox()
        if store.document.revision != lastObservedRevision {
            lastObservedRevision = store.document.revision; undoHistory = []; redoHistory = []; stopPreview(); reload()
            if !draftDirty && !timingDirty { discardDraft() }
        }
        if let last = reports.last { message(last) }
    }
    private func reload() {
        reloading = true; defer { reloading = false }
        for entry in tables {
            guard let table = entry.view else { continue }
            table.reloadData()
            let index: Int?
            switch entry.role {
            case .library: index = store.document.poses.firstIndex { $0.id == libraryID }
            case .clips: index = selectedSequence?.clips.firstIndex { $0.id == clipID }
            case .sequences: index = store.document.sequences.firstIndex { $0.id == sequenceID }
            }
            table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? IndexSet(), byExtendingSelection: false)
        }
        sequenceName.stringValue = selectedSequence?.name ?? "New sequence"
        legacySequenceName?.stringValue = sequenceName.stringValue
        greeting.isEnabled = selectedSequence != nil
        greeting.selectItem(at: selectedSequence?.completionGreeting == nil ? 0 : 1)
        let schedule = selectedSequence?.completionGreeting ?? ROBAnimationGreeting()
        greeting.toolTip = "Spoken only after successful robot playback. Local time: morning \(schedule.morningHour):00, daytime \(schedule.daytimeHour):00, evening \(schedule.eveningHour):00. Now: \(schedule.text())"
        armSpeed.isEnabled = selectedSequence != nil; armSpeedPercent.isEnabled = selectedSequence != nil
        armSpeed.doubleValue = (selectedSequence?.armSpeed ?? 1)*100
        armSpeedPercent.stringValue = format(armSpeed.doubleValue)
        timeline.sequence = selectedSequence; timeline.selectedClip = clipID; timeline.needsDisplay = true
        scrubber.maxValue = max(0.01, selectedSequence?.duration ?? 1)
        let time = min(scrubber.doubleValue, selectedSequence?.duration ?? 0)
        timeline.time = time; scrubber.doubleValue = time
        clock.stringValue = String(format: "%.2f / %.2f s", time, selectedSequence?.duration ?? 0)
        undoButton.isEnabled = !undoHistory.isEmpty; redoButton.isEnabled = !redoHistory.isEmpty
    }
    private func message(_ text: String) { status.stringValue = text; legacyPoseName?.toolTip = text }
    private func format(_ value: Double) -> String { String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }

    private func output(_ values: [String: Double], title: String, time: Double, open: Bool, prop: ROBAnimationPreviewProp? = nil) {
        if open { NotificationCenter.default.post(name: Notification.Name("ROBShowControllerInputDiagnostics"), object: self, userInfo: ["animationPreview": true]) }
        var info: [String: Any] = ["values": values, "title": title, "time": time]
        if let prop { info["previewProp"] = ["kind": prop.kind, "arm": prop.arm, "lengthMeters": prop.lengthMeters] }
        NotificationCenter.default.post(name: Self.previewChanged, object: self, userInfo: info)
    }
    private func showDraftPreview(open: Bool) {
        stopPreview()
        var values = (capture?() ?? [:]).mapValues(\.doubleValue)
        if case .clip(let sequenceID, let clipID) = editing,
           var sequence = store.document.sequences.first(where: { $0.id == sequenceID }),
           let index = sequence.clips.firstIndex(where: { $0.id == clipID }) {
            // A sparse body/head clip inherits the preceding arm pose. Use a
            // private prefix so neither later clips nor unsaved draft values
            // can alter the stored sequence or issue hardware commands.
            sequence.clips = Array(sequence.clips.prefix(index + 1))
            sequence.clips[index].pose = draft
            values = ROBAnimationDocument.sample(sequence, at: sequence.duration, baseline: values)
        } else {
            for (key, value) in draft.values { values[key] = value }
            if let lean = draft.previewLeanDegrees { values["preview.bodyLeanDegrees"] = lean }
        }
        output(values, title: draft.name, time: 0, open: open, prop: draft.previewProp)
    }
    private func startPreview(_ sequence: ROBAnimationSequence) {
        stopPreview(); previewSequence = sequence
        previewBaseline = (capture?() ?? [:]).mapValues(\.doubleValue)
        previewElapsed = scrubber.doubleValue < sequence.duration ? max(0, scrubber.doubleValue) : 0
        output(ROBAnimationDocument.sample(sequence, at: previewElapsed, baseline: previewBaseline), title: sequence.name, time: previewElapsed, open: true, prop: ROBAnimationDocument.previewProp(sequence, at: previewElapsed))
        renderTime(previewElapsed, sequence: sequence, baseline: previewBaseline)
        resumePreview()
        message("Ghost preview at \(format(previewRate))×. Change Ghost speed while playing; Loop repeats. No robot commands.")
    }
    private func resumePreview() {
        guard previewSequence != nil else { return }
        previewLastTick = previewUptime()
        let timer = Timer(timeInterval: 1/30, repeats: true) { [weak self] _ in
            self?.previewTick()
        }
        previewTimer = timer; RunLoop.main.add(timer, forMode: .common)
        previewPlay.title = "Pause ghost"
    }
    @objc private func previewTick() { advancePreview(at: previewUptime()) }
    private func advancePreview(at time: Double) {
        guard previewTimer != nil, let sequence = previewSequence else { return }
        // Integrate elapsed time at the current rate so a live speed change
        // does not jump backward or multiply the entire prior playback time.
        previewElapsed += max(0, time-previewLastTick)*previewRate; previewLastTick = time
        let finished = previewElapsed >= sequence.duration
        if finished {
            previewElapsed = previewLoop.state == .on && sequence.duration > 0
                ? previewElapsed.truncatingRemainder(dividingBy: sequence.duration) : sequence.duration
        }
        renderTime(previewElapsed, sequence: sequence, baseline: previewBaseline)
        if finished && previewLoop.state != .on { stopPreview(); message("Ghost preview complete. Play ghost replays; Loop repeats automatically.") }
    }
    @objc private func previewSpeedChanged() {
        guard Self.previewRates.indices.contains(previewSpeed.indexOfSelectedItem) else { return }
        advancePreview(at: previewUptime())
        previewRate = Self.previewRates[previewSpeed.indexOfSelectedItem]
        message("Ghost speed \(format(previewRate))× · visual playback only. Saved timings and robot speed are unchanged.")
    }
    private func stopPreview() {
        previewTimer?.invalidate(); previewTimer = nil; previewSequence = nil; previewPlay.title = "Play ghost"
    }
    @objc private func scrubSlider() { scrub(to: scrubber.doubleValue) }
    private func scrub(to time: Double) {
        stopPreview(); guard let sequence = selectedSequence else { return }
        renderTime(time, sequence: sequence, baseline: (capture?() ?? [:]).mapValues(\.doubleValue))
    }
    private func renderTime(_ time: Double, sequence: ROBAnimationSequence, baseline: [String: Double]) {
        scrubber.doubleValue = time; clock.stringValue = String(format: "%.2f / %.2f s", time, sequence.duration)
        timeline.time = time; timeline.needsDisplay = true
        output(ROBAnimationDocument.sample(sequence, at: time, baseline: baseline), title: sequence.name, time: time, open: false, prop: ROBAnimationDocument.previewProp(sequence, at: time))
    }
    @objc private func runRobot() {
        guard !draftDirty && !timingDirty else { message("Save or discard the draft before running the saved sequence."); return }
        guard let sequence = selectedSequence, let serial else { message("Select a sequence and connect the controls."); return }
        stopPreview(); ROBAnimationPlayback.shared.start(sequence: sequence, serial: serial)
    }
    @objc private func stopAll() {
        stopPreview()
        if ROBAnimationPlayback.shared.isRunning { ROBAnimationPlayback.shared.stop(reason: "Animation stopped; arm holds requested.") }
        else { message("Ghost preview stopped.") }
    }
    @objc private func playbackChanged() { message(ROBAnimationPlayback.shared.status) }
    func windowWillClose(_ notification: Notification) { stopAll() }
    @objc private func exportJSON() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "ROB-animations-r\(store.document.revision).json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try ROBAnimationStore.encode(store.document).write(to: url, options: .atomic); message("Exported revision \(store.document.revision).") }
            catch { message(error.localizedDescription) }
        }
    }
    @objc private func importJSON() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let next = try ROBAnimationStore.decode(Data(contentsOf: url)); let previous = store.document
                try store.replace(next, expectedRevision: next.revision)
                undoHistory.append(previous); redoHistory = []; lastObservedRevision = store.document.revision
                stopPreview(); reload(); if !draftDirty && !timingDirty { discardDraft() }; message("Imported JSON. No robot motion.")
            } catch { message(error.localizedDescription) }
        }
    }
    @objc private func revealLibrary() { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action); button.setAccessibilityIdentifier("animation-" + title.lowercased().replacingOccurrences(of: " ", with: "-")); return button
    }
    private func row(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 8; s.alignment = .centerY; return s }
    private func column(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = 8; s.alignment = .leading; return s }
    private func heading(_ title: String) -> NSTextField { let v = NSTextField(labelWithString: title); v.font = .systemFont(ofSize: 13, weight: .semibold); return v }
    private func tablePane(_ title: String, role: Role, actions: [NSView]) -> NSView {
        let table = NSTableView(); let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title)); c.title = title; c.width = 300; table.addTableColumn(c); table.headerView = nil; table.usesAlternatingRowBackgroundColors = true
        register(table, as: role)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let pane = column([heading(title), scroll, row(actions)])
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: pane.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 180)])
        return pane
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 90, y: 80, width: 1210, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ROB Animation Studio"; window.minSize = NSSize(width: 1040, height: 800); window.delegate = self
        let root = column([]); root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        if let content = window.contentView { NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)]) }
        undoButton.target = self; undoButton.action = #selector(undoEdit); redoButton.target = self; redoButton.action = #selector(redoEdit)
        previewPlay.target = self; previewPlay.action = #selector(previewSelectedSequence)
        previewPlay.setAccessibilityIdentifier("animation-preview-sequence")
        previewPlay.toolTip = "Play or pause the ghost from the playhead. Preview only; no robot motion."
        previewSpeed.addItems(withTitles: Self.previewRates.map { format($0) + "×" }); previewSpeed.selectItem(at: 3)
        previewSpeed.target = self; previewSpeed.action = #selector(previewSpeedChanged)
        previewSpeed.setAccessibilityLabel("Ghost preview speed")
        previewSpeed.toolTip = "0.25×–4× visual playback. Changes immediately without editing the sequence or moving ROB."
        previewLoop.setAccessibilityLabel("Loop ghost preview")
        previewLoop.toolTip = "Repeat only the ghost preview; Run on robot remains one sequence."
        root.addArrangedSubview(row([heading("POSES → CLIPS → SEQUENCES"), button("Ghost output", #selector(previewPose)), previewPlay,
            heading("Ghost speed"), previewSpeed, previewLoop, button("Run on robot", #selector(runRobot)), button("Stop", #selector(stopAll)), undoButton, redoButton]))
        armSpeed.target = self; armSpeed.action = #selector(armSpeedChanged(_:)); armSpeed.isContinuous = false
        armSpeed.widthAnchor.constraint(equalToConstant: 170).isActive = true
        armSpeed.setAccessibilityLabel("Arm playback speed percent")
        armSpeedPercent.target = self; armSpeedPercent.action = #selector(armSpeedChanged(_:))
        armSpeedPercent.widthAnchor.constraint(equalToConstant: 55).isActive = true
        armSpeedPercent.setAccessibilityLabel("Arm speed percent")
        armSpeed.toolTip = "25–200% of saved arm transition speed. Applies on the next Run; maximum 0.20 rad/s (11.5°/s). Other tracks retain their timing."
        armSpeedPercent.toolTip = armSpeed.toolTip
        root.addArrangedSubview(row([heading("Arm speed"), armSpeed, armSpeedPercent, heading("%"), button("Apply speed", #selector(armSpeedChanged(_:))), NSTextField(labelWithString: "Next Run · motor limits apply · other tracks keep their timing")]))
        let a = tablePane("Pose library", role: .library, actions: [button("New draft", #selector(newDraft)), button("Add →", #selector(addSelectedPose)), button("Delete pose", #selector(deletePose))])
        let b = tablePane("Selected sequence · independent clips", role: .clips, actions: [button("↑", #selector(moveUp)), button("↓", #selector(moveDown)), button("Duplicate", #selector(duplicateClip)), button("Remove", #selector(deleteClip))])
        let c = tablePane("Sequences", role: .sequences, actions: [button("New sequence", #selector(newSequence)), button("Delete sequence", #selector(deleteSequence))])
        let panes = row([a,b,c]); panes.distribution = .fillEqually; panes.alignment = .top
        root.addArrangedSubview(panes); panes.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        sequenceName.placeholderString = "Sequence name"; sequenceName.widthAnchor.constraint(equalToConstant: 240).isActive = true
        transition.delegate = self; hold.delegate = self; poseName.delegate = self
        transition.widthAnchor.constraint(equalToConstant: 65).isActive = true; hold.widthAnchor.constraint(equalToConstant: 65).isActive = true
        easing.addItems(withTitles: ["Smooth", "Linear"]); easing.target = self; easing.action = #selector(timingChanged)
        root.addArrangedSubview(row([sequenceName, button("Rename", #selector(renameSelectedSequence)), heading("Transition s"), transition, heading("Hold s"), hold, easing, button("Apply timing", #selector(applyTiming)), button("Refresh from pose", #selector(refreshClipFromLibrary))]))
        root.addArrangedSubview(timeline)
        timeline.heightAnchor.constraint(equalToConstant: 126).isActive = true; timeline.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        timeline.onScrub = { [weak self] in self?.scrub(to: $0) }
        scrubber.target = self; scrubber.action = #selector(scrubSlider); scrubber.isContinuous = true; scrubber.setAccessibilityLabel("Animation playhead seconds")
        let playback = row([scrubber, clock]); root.addArrangedSubview(playback); playback.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        poseName.widthAnchor.constraint(equalToConstant: 220).isActive = true; poseName.target = self; poseName.action = #selector(editDraft(_:))
        role.addItems(withTitles: ["No grasp-ready role"] + ROBAnimationDocument.roles); role.target = self; role.action = #selector(editDraft(_:))
        root.addArrangedSubview(row([heading("Pose / clip"), poseName, role, button("Capture controls", #selector(captureControls)), button("Record new", #selector(recordNew)), button("Update selected", #selector(updateSelected)), button("Discard draft", #selector(discardDraft))]))
        root.addArrangedSubview(selectionInfo); selectionInfo.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let inspector = NSStackView(); inspector.orientation = .horizontal; inspector.alignment = .top; inspector.distribution = .fillEqually; inspector.spacing = 18
        for group in ["Right arm", "Left arm", "Neck", "Maestro", "Body"] {
            let list = column([heading(group)])
            let select = NSButton(checkboxWithTitle: "Include group", target: self, action: #selector(toggleGroup(_:))); select.identifier = NSUserInterfaceItemIdentifier(group); list.addArrangedSubview(select)
            for channel in ROBAnimationChannel.all where channel.group == group {
                let toggle = NSButton(checkboxWithTitle: channel.name, target: self, action: #selector(editDraft(_:))); includes[channel.id] = toggle
                let value = NSTextField(string: format(channel.defaultValue)); value.target = self; value.action = #selector(editDraft(_:)); value.widthAnchor.constraint(equalToConstant: 65).isActive = true
                value.setAccessibilityLabel(channel.name + " " + channel.unit); value.toolTip = "\(channel.minimum)…\(channel.maximum) \(channel.unit)"; fields[channel.id] = value
                let line = row([toggle, value]); list.addArrangedSubview(line)
            }
            list.addArrangedSubview(NSTextField(wrappingLabelWithString: group.contains("arm") ? "Vendor radians" : group == "Body" ? "Torso: ° to base\nLACT: ±% timed\nPositive = forward" : "Maestro targets: ¼ µs"))
            if group == "Body" {
                ghostLean.delegate = self; ghostLean.target = self; ghostLean.action = #selector(editDraft(_:))
                ghostLean.widthAnchor.constraint(equalToConstant: 65).isActive = true
                ghostLean.setAccessibilityLabel("Ghost lean degrees")
                ghostLean.toolTip = "Illustration only; not an actuator angle command. Blank retains the previous ghost lean."
                list.addArrangedSubview(row([NSTextField(labelWithString: "Ghost lean °"), ghostLean]))
                list.addArrangedSubview(NSTextField(labelWithString: "Illustration only"))
            }
            inspector.addArrangedSubview(list)
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = inspector
        inspector.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([inspector.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), inspector.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), inspector.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor)])
        root.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 175).isActive = true
        greeting.addItems(withTitles: ["Finish: no speech", "Finish: Japanese greeting"])
        greeting.target = self; greeting.action = #selector(greetingChanged)
        greeting.setAccessibilityLabel("Sequence completion greeting")
        root.addArrangedSubview(row([button("Export JSON", #selector(exportJSON)), button("Import JSON edit", #selector(importJSON)), button("Show library file", #selector(revealLibrary)), greeting, NSTextField(labelWithString: "Ch 3 unassigned · Ch 6–9: Bubble")] ))
        root.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        windowController = NSWindowController(window: window); syncDraft()
    }
    @objc private func toggleGroup(_ sender: NSButton) {
        for channel in ROBAnimationChannel.all where channel.group == sender.identifier?.rawValue { includes[channel.id]?.state = sender.state }
        editDraft(nil)
    }
}

private final class ROBAnimationTimeline: NSView {
    var sequence: ROBAnimationSequence?
    var selectedClip: UUID?
    var time = 0.0
    var onScrub: ((Double) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        let left = 92.0, width = max(1, bounds.width-left-10)
        let groups = ["Right arm", "Left arm", "Neck", "Maestro", "Body"]
        let colors: [NSColor] = [.systemBlue,.systemPurple,.systemTeal,.systemOrange,.systemGreen]
        let duration = max(0.01, sequence?.duration ?? 1)
        for (index, group) in groups.enumerated() {
            let y = CGFloat(index)*21+20
            (group as NSString).draw(at: NSPoint(x: 5,y: y+2), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            NSColor.separatorColor.setFill(); NSRect(x: left, y: y+19, width: width, height: 1).fill()
            var start = 0.0
            for clip in sequence?.clips ?? [] {
                let clipDuration = sequence?.playbackDuration(for: clip) ?? clip.duration
                let active = clip.pose.values.keys.contains { ROBAnimationChannel.byID[$0]?.group == group }
                if active {
                    let rect = NSRect(x: left+start/duration*width, y: y, width: max(1,clipDuration/duration*width-2), height: 17)
                    colors[index].withAlphaComponent(clip.id == selectedClip ? 0.95 : 0.5).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    let transition = index < 2 ? (sequence?.armTransition(for: clip) ?? clip.transition) : clip.transition
                    if clipDuration > transition { NSColor.white.withAlphaComponent(0.25).setFill(); NSRect(x:left+(start+transition)/duration*width,y:y,width:max(0,(clipDuration-transition)/duration*width-2),height:17).fill() }
                    if rect.width > 60 { (clip.pose.name as NSString).draw(in: rect.insetBy(dx: 4, dy: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white]) }
                }
                start += clipDuration
            }
        }
        for i in 0...4 { (String(format:"%.1fs",duration*Double(i)/4) as NSString).draw(at:NSPoint(x:left+width*Double(i)/4-10,y:2),withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]) }
        NSColor.labelColor.setFill(); NSRect(x: left+min(duration,max(0,time))/duration*width,y:18,width:2,height:108).fill()
    }
    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    private func update(_ event: NSEvent) { let p = convert(event.locationInWindow, from: nil); onScrub?(min(1,max(0,(p.x-92)/max(1,bounds.width-102)))*(sequence?.duration ?? 0)) }
}
