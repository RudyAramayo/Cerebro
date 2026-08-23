//
//  ROBSystemStatusWindowController.swift
//  Cerebro
//
//  A read-only, cached view of Cerebro's runtime services and controller sessions.
//

import AppKit
import Foundation

/// The operator-facing condition of a service. The text is always rendered with
/// the color indicator so status never depends on color alone.
public enum ROBSystemServiceState: Int, CaseIterable, Sendable {
    case healthy
    case working
    case idle
    case disabled
    case degraded
    case unavailable
    case unknown

    public var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .working: return "Working"
        case .idle: return "Idle"
        case .disabled: return "Disabled"
        case .degraded: return "Degraded"
        case .unavailable: return "Unavailable"
        case .unknown: return "Unknown"
        }
    }
}

/// Stable groupings for Cerebro's fixed services. Controller sessions are
/// rendered in their own dynamic section.
public enum ROBSystemServiceCategory: String, CaseIterable, Sendable {
    case languageModels
    case perception
    case connectivity
    case other

    public var displayName: String {
        switch self {
        case .languageModels: return "AI and Language Models"
        case .perception: return "Perception"
        case .connectivity: return "Connections"
        case .other: return "Other Services"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .languageModels: return 0
        case .perception: return 1
        case .connectivity: return 2
        case .other: return 3
        }
    }
}

/// A short, already-redacted metric suitable for display on a status card.
public struct ROBSystemStatusMetric: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A snapshot for one fixed Cerebro service. `id` must remain stable between
/// refreshes (for example, `gemini-live` or `insta360`).
public struct ROBSystemServiceCardSnapshot: Sendable {
    public let id: String
    public let displayName: String
    public let category: ROBSystemServiceCategory
    public let state: ROBSystemServiceState
    public let detail: String
    /// Age, in seconds, of the service data or last meaningful event.
    public let age: TimeInterval?
    public let metrics: [ROBSystemStatusMetric]

    public init(
        id: String,
        displayName: String,
        category: ROBSystemServiceCategory,
        state: ROBSystemServiceState,
        detail: String,
        age: TimeInterval? = nil,
        metrics: [ROBSystemStatusMetric] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.state = state
        self.detail = detail
        self.age = age
        self.metrics = metrics
    }
}

/// A live controller connection. One card is displayed per session and cards
/// are sorted deterministically by device name and stable connection ID.
public struct ROBControllerSessionCardSnapshot: Sendable {
    public let stableID: String
    public let displayName: String
    public let state: ROBSystemServiceState
    public let detail: String
    public let role: String?
    public let deviceIdentifier: String?
    public let sessionIdentifier: String?
    /// Age, in seconds, of the connection data or last meaningful event.
    public let age: TimeInterval?
    public let metrics: [ROBSystemStatusMetric]

    public init(
        stableID: String,
        displayName: String,
        state: ROBSystemServiceState,
        detail: String,
        role: String? = nil,
        deviceIdentifier: String? = nil,
        sessionIdentifier: String? = nil,
        age: TimeInterval? = nil,
        metrics: [ROBSystemStatusMetric] = []
    ) {
        self.stableID = stableID
        self.displayName = displayName
        self.state = state
        self.detail = detail
        self.role = role
        self.deviceIdentifier = deviceIdentifier
        self.sessionIdentifier = sessionIdentifier
        self.age = age
        self.metrics = metrics
    }
}

/// One atomic capture of all cached service state displayed by the panel.
public struct ROBSystemStatusSnapshot: Sendable {
    public let capturedAt: Date
    public let services: [ROBSystemServiceCardSnapshot]
    public let controllers: [ROBControllerSessionCardSnapshot]

    public init(
        capturedAt: Date = Date(),
        services: [ROBSystemServiceCardSnapshot],
        controllers: [ROBControllerSessionCardSnapshot]
    ) {
        self.capturedAt = capturedAt
        self.services = services
        self.controllers = controllers
    }
}

/// The provider must only return state that is already cached in memory. It
/// must not start, restart, probe, connect, load a model, or perform I/O.
public typealias ROBSystemStatusSnapshotProvider = @MainActor () -> ROBSystemStatusSnapshot

/// Read-only service overview for operators. It intentionally exposes no
/// service lifecycle controls; the Refresh button only captures cached state.
@MainActor
@objc(ROBSystemStatusWindowController)
public final class ROBSystemStatusWindowController: NSWindowController, NSWindowDelegate {
    private let snapshotProvider: ROBSystemStatusSnapshotProvider
    private let timestampLabel = NSTextField(labelWithString: "Not yet refreshed")
    private let contentStack = NSStackView()
    private var cardViews: [String: ROBSystemStatusCardView] = [:]
    private var renderedStructure: String?
    private var refreshTimer: Timer?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// Swift integration point. Keep the closure fast and observational: it is
    /// called on the main actor about once per second while the window is open.
    @nonobjc public init(snapshotProvider: @escaping ROBSystemStatusSnapshotProvider) {
        self.snapshotProvider = snapshotProvider
        super.init(window: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cerebro Service Status"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 440)
        window.delegate = self
        window.center()
        self.window = window
        configureContent(of: window)
    }

    public override func showWindow(_ sender: Any?) {
        // This controller is entirely programmatic and has no window nib.
        // NSWindowController reports isWindowLoaded == true after
        // init(window: nil), even though the actual window is still nil. Test
        // the object itself and create it explicitly before presentation.
        if window == nil {
            loadWindow()
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refreshFromCachedState()
        startRefreshTimer()
    }

    public func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    /// Objective-C-compatible action for toolbar/menu wiring. This performs no
    /// health check; it only asks the provider for another cached snapshot.
    @objc(refreshNow:)
    public func refreshNow(_ sender: Any?) {
        guard isWindowLoaded else { return }
        refreshFromCachedState()
    }

    private func configureContent(of window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let titleLabel = NSTextField(labelWithString: "System Services")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.setAccessibilityLabel("System Services")

        let explanationLabel = NSTextField(wrappingLabelWithString:
            "Live, read-only health from Cerebro’s cached runtime state. This panel never starts or probes a service."
        )
        explanationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 0
        explanationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timestampLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.alignment = .right
        timestampLabel.setAccessibilityLabel("Status snapshot timestamp")

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshNow(_:)))
        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = "Refresh from cached service state"
        refreshButton.setAccessibilityHelp("Reads cached service state without probing or restarting services.")

        let titleStack = NSStackView(views: [titleLabel, explanationLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let trailingStack = NSStackView(views: [timestampLabel, refreshButton])
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 10

        let header = NSStackView(views: [titleStack, NSView(), trailingStack])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12

        let documentView = ROBSystemStatusFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            titleStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            explanationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 500),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(refreshTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refreshFromCachedState()
    }

    private func refreshFromCachedState() {
        let snapshot = snapshotProvider()
        let services = sortedServices(snapshot.services)
        let controllers = sortedControllers(snapshot.controllers)
        let structure = structureSignature(services: services, controllers: controllers)

        if structure != renderedStructure {
            rebuildCards(services: services, controllers: controllers)
            renderedStructure = structure
        }

        for service in services {
            cardViews["service:\(service.id)"]?.update(
                name: service.displayName,
                state: service.state,
                detail: service.detail,
                metadata: [],
                age: service.age,
                metrics: service.metrics
            )
        }

        for controller in controllers {
            var metadata: [ROBSystemStatusMetric] = []
            if let role = nonempty(controller.role) {
                metadata.append(ROBSystemStatusMetric(label: "Role", value: role))
            }
            if let deviceID = nonempty(controller.deviceIdentifier) {
                metadata.append(ROBSystemStatusMetric(label: "Device", value: deviceID))
            }
            if let sessionID = nonempty(controller.sessionIdentifier) {
                metadata.append(ROBSystemStatusMetric(label: "Session", value: sessionID))
            }
            cardViews["controller:\(controller.stableID)"]?.update(
                name: controller.displayName,
                state: controller.state,
                detail: controller.detail,
                metadata: metadata,
                age: controller.age,
                metrics: controller.metrics
            )
        }

        timestampLabel.stringValue = "Updated \(timeFormatter.string(from: snapshot.capturedAt)) · \(relativeAge(from: snapshot.capturedAt))"
        timestampLabel.toolTip = snapshot.capturedAt.formatted(date: .abbreviated, time: .standard)
        timestampLabel.setAccessibilityValue(timestampLabel.stringValue)
    }

    private func rebuildCards(
        services: [ROBSystemServiceCardSnapshot],
        controllers: [ROBControllerSessionCardSnapshot]
    ) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardViews.removeAll(keepingCapacity: true)

        for category in ROBSystemServiceCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let categoryServices = services.filter { $0.category == category }
            guard !categoryServices.isEmpty else { continue }

            let cards = categoryServices.map { service -> ROBSystemStatusCardView in
                let card = ROBSystemStatusCardView()
                cardViews["service:\(service.id)"] = card
                return card
            }
            addSection(title: category.displayName, count: cards.count, cards: cards)
        }

        if controllers.isEmpty {
            let heading = sectionHeading(title: "Controllers", count: 0)
            let emptyState = ROBSystemStatusEmptyControllersView()
            contentStack.addArrangedSubview(heading)
            contentStack.addArrangedSubview(emptyState)
            contentStack.setCustomSpacing(8, after: heading)
            heading.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            emptyState.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        } else {
            let cards = controllers.map { controller -> ROBSystemStatusCardView in
                let card = ROBSystemStatusCardView()
                cardViews["controller:\(controller.stableID)"] = card
                return card
            }
            addSection(title: "Controllers", count: cards.count, cards: cards)
        }
    }

    private func addSection(title: String, count: Int, cards: [ROBSystemStatusCardView]) {
        let heading = sectionHeading(title: title, count: count)
        let rows = ROBSystemStatusRowListView(rows: cards)
        contentStack.addArrangedSubview(heading)
        contentStack.addArrangedSubview(rows)
        contentStack.setCustomSpacing(5, after: heading)
        heading.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        rows.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func sectionHeading(title: String, count: Int) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.setAccessibilityLabel("\(title) section")

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.setAccessibilityLabel("\(count) \(title.lowercased())")

        let row = NSStackView(views: [label, countLabel, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func sortedServices(_ services: [ROBSystemServiceCardSnapshot]) -> [ROBSystemServiceCardSnapshot] {
        services.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
    }

    private func sortedControllers(
        _ controllers: [ROBControllerSessionCardSnapshot]
    ) -> [ROBControllerSessionCardSnapshot] {
        controllers.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.stableID.localizedCaseInsensitiveCompare($1.stableID) == .orderedAscending
        }
    }

    private func structureSignature(
        services: [ROBSystemServiceCardSnapshot],
        controllers: [ROBControllerSessionCardSnapshot]
    ) -> String {
        let serviceIDs = services.map { "S|\($0.category.rawValue)|\($0.id)" }
        let controllerIDs = controllers.map { "C|\($0.stableID)" }
        return (serviceIDs + controllerIDs).joined(separator: "\u{1f}")
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 1 { return "just now" }
        return "\(ROBSystemStatusFormatting.duration(seconds)) ago"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum ROBSystemStatusFormatting {
    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "unknown" }
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 1 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

private final class ROBSystemStatusFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Full-width rows use the panel's horizontal space and stay compact until the
/// operator asks for detail. This makes live throughput visible without a grid
/// of mostly empty fixed-height cards.
private final class ROBSystemStatusRowListView: NSStackView {
    init(rows: [ROBSystemStatusCardView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        distribution = .fill
        spacing = 6
        for row in rows {
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ROBSystemStatusCardView: NSView {
    private let accent = NSView()
    private let disclosureButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let stateDot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let metadataLabel = NSTextField(wrappingLabelWithString: "")
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let detailStack = NSStackView()
    private var state: ROBSystemServiceState = .unknown
    private var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.wantsLayer = true

        disclosureButton.title = "▸"
        disclosureButton.isBordered = false
        disclosureButton.font = .systemFont(ofSize: 13, weight: .semibold)
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpanded(_:))
        disclosureButton.toolTip = "Show service details"
        disclosureButton.setAccessibilityLabel("Show details")

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.usesSingleLineMode = true
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 4

        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.usesSingleLineMode = true

        summaryLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.usesSingleLineMode = true
        summaryLabel.alignment = .right
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadataLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.maximumNumberOfLines = 2
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        footerLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.maximumNumberOfLines = 0
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stateRow = NSStackView(views: [stateDot, stateLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 5

        let header = NSStackView(views: [disclosureButton, nameLabel, stateRow, summaryLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        detailStack.setViews([detailLabel, metadataLabel, footerLabel], in: .top)
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 4
        detailStack.isHidden = true

        let stack = NSStackView(views: [header, detailStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        addSubview(accent)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            metadataLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            footerLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 18),
            nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            stateRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 78),
            stateDot.widthAnchor.constraint(equalToConstant: 8),
            stateDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func update(
        name: String,
        state: ROBSystemServiceState,
        detail: String,
        metadata: [ROBSystemStatusMetric],
        age: TimeInterval?,
        metrics: [ROBSystemStatusMetric]
    ) {
        self.state = state
        nameLabel.stringValue = name
        stateLabel.stringValue = state.displayName
        detailLabel.stringValue = detail.isEmpty ? "No detail reported." : detail
        metadataLabel.stringValue = formatted(metadata)
        summaryLabel.stringValue = metrics.prefix(3)
            .map { "\($0.label) \($0.value)" }
            .joined(separator: "  •  ")

        var footerParts = metrics.map { "\($0.label) \($0.value)" }
        if let age {
            footerParts.append("Age \(ROBSystemStatusFormatting.duration(age))")
        }
        footerLabel.stringValue = footerParts.joined(separator: "  •  ")

        metadataLabel.isHidden = metadataLabel.stringValue.isEmpty
        footerLabel.isHidden = footerLabel.stringValue.isEmpty
        setAccessibilityLabel("\(name), \(state.displayName)")
        setAccessibilityValue(detailLabel.stringValue)
        setAccessibilityHelp((metadata + metrics).map { "\($0.label): \($0.value)" }.joined(separator: ", "))
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        toggleExpanded(self)
    }

    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        detailStack.isHidden = !isExpanded
        disclosureButton.title = isExpanded ? "▾" : "▸"
        disclosureButton.toolTip = isExpanded ? "Hide service details" : "Show service details"
        disclosureButton.setAccessibilityLabel(isExpanded ? "Hide details" : "Show details")
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func formatted(_ values: [ROBSystemStatusMetric]) -> String {
        values.map { "\($0.label) \($0.value)" }.joined(separator: "  •  ")
    }

    private func updateAppearance() {
        let color = stateColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            accent.layer?.backgroundColor = color.cgColor
            stateDot.layer?.backgroundColor = color.cgColor
        }
        stateLabel.textColor = color
    }

    private var stateColor: NSColor {
        switch state {
        case .healthy: return .systemGreen
        case .working: return .systemBlue
        case .idle: return .secondaryLabelColor
        case .disabled: return .tertiaryLabelColor
        case .degraded: return .systemOrange
        case .unavailable: return .systemRed
        case .unknown: return .systemGray
        }
    }
}

private final class ROBSystemStatusEmptyControllersView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        let title = NSTextField(labelWithString: "No active controller connections")
        title.font = .systemFont(ofSize: 14, weight: .medium)

        let detail = NSTextField(wrappingLabelWithString:
            "Controller listener status is shown above. A card appears here for each authenticated controller session."
        )
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let stack = NSStackView(views: [title, detail])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -13),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("No active controller connections")
        setAccessibilityValue(detail.stringValue)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
