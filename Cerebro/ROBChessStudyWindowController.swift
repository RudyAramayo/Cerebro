import AppKit
import UniformTypeIdentifiers

private final class ROBChessCameraView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var corners: [ROBChessPoint] = [] { didSet { needsDisplay = true } }
    var map: ROBChessBoardMap? { didSet { needsDisplay = true } }
    var highlighted: Set<Int> = [] { didSet { needsDisplay = true } }
    var onPoint: ((ROBChessPoint) -> Void)?
    override var isFlipped: Bool { true }
    private var imageRect: CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width/image.size.width,bounds.height/image.size.height)
        let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
        return CGRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0.08,alpha:1).setFill(); bounds.fill()
        guard let image else {
            ("Open an image or start the main camera." as NSString).draw(at:CGPoint(x:24,y:32),
                withAttributes:[.foregroundColor:NSColor.secondaryLabelColor,.font:NSFont.systemFont(ofSize:17)])
            return
        }
        let rect = imageRect
        image.draw(in:rect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        func point(_ p: ROBChessPoint) -> CGPoint { CGPoint(x:rect.minX+p.x*rect.width,y:rect.minY+p.y*rect.height) }
        if let map {
            let grid = NSBezierPath()
            for i in 0...8 {
                let u = Double(i)/8
                grid.move(to:point(map.imagePoint(u:u,v:0))); grid.line(to:point(map.imagePoint(u:u,v:1)))
                grid.move(to:point(map.imagePoint(u:0,v:u))); grid.line(to:point(map.imagePoint(u:1,v:u)))
            }
            NSColor.systemMint.withAlphaComponent(0.7).setStroke(); grid.lineWidth = 1; grid.stroke()
            for square in highlighted {
                let polygon = NSBezierPath()
                let p = map.polygon(square:square).map(point)
                polygon.move(to:p[0]); p.dropFirst().forEach { polygon.line(to:$0) }; polygon.close()
                NSColor.systemOrange.withAlphaComponent(0.35).setFill(); polygon.fill()
            }
        }
        for (i,p) in corners.enumerated() {
            let at = point(p)
            NSColor.systemMint.setFill()
            NSBezierPath(ovalIn:CGRect(x:at.x-5,y:at.y-5,width:10,height:10)).fill()
            (["a8","h8","h1","a1"][i] as NSString).draw(at:CGPoint(x:at.x+7,y:at.y+5),
                withAttributes:[.foregroundColor:NSColor.white,.backgroundColor:NSColor.black.withAlphaComponent(0.7),
                                .font:NSFont.monospacedSystemFont(ofSize:14,weight:.bold)])
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil), rect = imageRect
        guard image != nil, rect.contains(p) else { return }
        onPoint?(ROBChessPoint(x:(p.x-rect.minX)/rect.width,y:(p.y-rect.minY)/rect.height))
    }
}

private final class ROBChessDiagramView: NSView {
    var position = ROBChessPosition.start { didSet { needsDisplay = true } }
    var highlighted: Set<Int> = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width,bounds.height)/8
        let symbols: [Character:String] = ["K":"♔","Q":"♕","R":"♖","B":"♗","N":"♘","P":"♙",
                                           "k":"♚","q":"♛","r":"♜","b":"♝","n":"♞","p":"♟"]
        for square in 0..<64 {
            let x = CGFloat(square%8)*side, y = CGFloat(7-square/8)*side
            let rect = CGRect(x:x,y:y,width:side,height:side)
            ((square/8+square%8)%2 == 1 ? NSColor(calibratedRed:0.87,green:0.89,blue:0.82,alpha:1)
                : NSColor(calibratedRed:0.31,green:0.44,blue:0.39,alpha:1)).setFill(); rect.fill()
            if highlighted.contains(square) { NSColor.systemOrange.withAlphaComponent(0.45).setFill(); rect.fill() }
            if let symbol = symbols[position.board[square]] {
                let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:side*0.72),
                                                                .foregroundColor:NSColor.black]
                let size = (symbol as NSString).size(withAttributes:attributes)
                (symbol as NSString).draw(at:CGPoint(x:x+(side-size.width)/2,y:y+(side-size.height)/2),withAttributes:attributes)
            }
            (ROBChessPosition.squareName(square) as NSString).draw(at:CGPoint(x:x+2,y:y+1),
                withAttributes:[.font:NSFont.systemFont(ofSize:8),.foregroundColor:NSColor.black.withAlphaComponent(0.7)])
        }
    }
}

@objcMembers final class ROBChessStudyWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = ROBChessStudyWindowController()
    private let cameraView = ROBChessCameraView()
    private let diagram = ROBChessDiagramView()
    private let status = NSTextField(wrappingLabelWithString:"New session → open a board image → mark the four corners.")
    private let detail = NSTextField(wrappingLabelWithString:"Observation and teaching only. No arm or tread commands.")
    private let memoryLabel = NSTextField(wrappingLabelWithString:"No verified examples yet.")
    private let sourceLabel = NSTextField(labelWithString:"No image")
    private let fenLabel = NSTextField(wrappingLabelWithString:ROBChessPosition.startingFEN)
    private let coachLabel = NSTextField(wrappingLabelWithString:"Play one move, clear your hands, then review the next frame.")
    private let liveButton = NSButton(title:"Start main camera",target:nil,action:nil)
    private let freezeButton = NSButton(title:"Freeze for review",target:nil,action:nil)
    private let baselineButton = NSButton(title:"Save shown position",target:nil,action:nil)
    private let moveButton = NSButton(title:"Confirm move + teach",target:nil,action:nil)
    private let review = NSButton(checkboxWithTitle:"I checked all 64 squares against this diagram",target:nil,action:nil)
    private let moveField = NSTextField(string:"")
    private let suggestions = NSPopUpButton()
    private let queue = DispatchQueue(label:"com.orbitusrobotics.chess-study-analysis",qos:.utility)
    private var busy = false
    private var epoch = 0
    private var timer: Timer?
    private var frame: ROBChessStudyFrame?
    private var boardRaster: ROBChessRaster?
    private var evidence: ROBChessEvidence?
    private var baseline: ROBChessEvidence?
    private var previous: ROBChessEvidence?
    private var stableCount = 0
    private var map: ROBChessBoardMap?
    private var cornerPoints: [ROBChessPoint] = []
    private var position = ROBChessPosition.start
    private var memory = ROBChessAppearanceMemory()
    private var session: ROBChessStudySession?
    private var live = false
    private var frozen = true
    private var marking = false
    private var pendingCorrection = false
    private var currentChanges = [Double]()
    private var proposalMoves: [ROBChessProposal] = []

    private init() {
        let window = NSWindow(contentRect:CGRect(x:80,y:70,width:1230,height:840),
            styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "ROB Chess Study"
        window.minSize = CGSize(width:1050,height:780)
        super.init(window:window)
        window.delegate = self
        buildUI()
        ROBChessStudyLiveSource.shared.onFrame = { [weak self] in self?.receive($0) }
        ROBChessStudyLiveSource.shared.onError = { [weak self] in self?.status.stringValue = $0 }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.updateAge() }
        updateControls()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }
    override func showWindow(_ sender:Any?) { super.showWindow(sender); window?.makeKeyAndOrderFront(sender) }
    func windowWillClose(_ notification:Notification) { stopLive(); epoch += 1 }

    private func button(_ title:String,_ action:Selector) -> NSButton {
        let result = NSButton(title:title,target:self,action:action); result.bezelStyle = .rounded; return result
    }
    private func column(_ views:[NSView],spacing:CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = spacing; return stack
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString:"ROB  /  CHESS STUDY")
        title.font = .systemFont(ofSize:24,weight:.bold)
        let subtitle = NSTextField(labelWithString:"Observe a game. Review the evidence. Teach your own pieces.")
        subtitle.textColor = .secondaryLabelColor
        let toolbar = NSStackView(views:[
            button("New session",#selector(newSession)),button("Open session",#selector(openSession)),
            button("Open image…",#selector(openImage)),liveButton,freezeButton,
            button("Show saved data",#selector(showSavedData))
        ])
        toolbar.spacing = 8; toolbar.alignment = .centerY
        liveButton.target = self; liveButton.action = #selector(startLive)
        freezeButton.target = self; freezeButton.action = #selector(freezeReview)
        #if ROB_CHESS_STANDALONE
        liveButton.isHidden = true
        #endif
        sourceLabel.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        cameraView.wantsLayer = true; cameraView.layer?.cornerRadius = 12
        cameraView.onPoint = { [weak self] in self?.mark($0) }
        let mapping = NSStackView(views:[button("Mark board corners",#selector(markCorners)),
            NSTextField(labelWithString:"a8 → h8 → h1 → a1 • outer edges of the playing squares")])
        let left = column([sourceLabel,cameraView,mapping,status,detail])
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.heightAnchor.constraint(greaterThanOrEqualToConstant:440).isActive = true
        cameraView.widthAnchor.constraint(equalTo:left.widthAnchor).isActive = true
        status.font = .systemFont(ofSize:15,weight:.semibold)
        detail.textColor = .secondaryLabelColor
        let boardTitle = NSTextField(labelWithString:"Position to save • a8 at top left")
        boardTitle.font = .systemFont(ofSize:13,weight:.semibold)
        diagram.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([diagram.widthAnchor.constraint(equalToConstant:304),
                                     diagram.heightAnchor.constraint(equalToConstant:304)])
        fenLabel.font = .monospacedSystemFont(ofSize:10,weight:.regular)
        moveField.placeholderString = "Reviewed move, e.g. e2e4"
        moveField.delegate = self; moveField.identifier = NSUserInterfaceItemIdentifier("ROB.Chess.Move")
        moveField.widthAnchor.constraint(equalToConstant:304).isActive = true
        suggestions.target = self; suggestions.action = #selector(chooseSuggestion)
        suggestions.widthAnchor.constraint(equalToConstant:304).isActive = true
        review.target = self; review.action = #selector(reviewChanged)
        review.font = .systemFont(ofSize:11)
        baselineButton.target = self; baselineButton.action = #selector(savePosition)
        moveButton.target = self; moveButton.action = #selector(saveMove)
        let saveRow = NSStackView(views:[baselineButton,moveButton]); saveRow.spacing = 8
        let positionRow = NSStackView(views:[button("Correct position…",#selector(correctPosition)),
                                           button("Suggest ROB move",#selector(suggestMove))])
        memoryLabel.font = .systemFont(ofSize:12); memoryLabel.textColor = .secondaryLabelColor
        coachLabel.font = .systemFont(ofSize:12)
        let right = column([boardTitle,diagram,fenLabel,positionRow,suggestions,moveField,review,saveRow,memoryLabel,coachLabel],spacing:8)
        right.widthAnchor.constraint(equalToConstant:340).isActive = true
        for label in [fenLabel,memoryLabel,coachLabel] { label.widthAnchor.constraint(equalToConstant:332).isActive = true }
        let body = NSStackView(views:[left,right]); body.orientation = .horizontal; body.alignment = .top; body.spacing = 22; body.distribution = .fill
        left.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let root = column([title,subtitle,toolbar,body],spacing:12)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:22),
            root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-22),
            root.topAnchor.constraint(equalTo:content.topAnchor,constant:20),
            root.bottomAnchor.constraint(lessThanOrEqualTo:content.bottomAnchor,constant:-18),
            body.widthAnchor.constraint(equalTo:root.widthAnchor),
            status.widthAnchor.constraint(equalTo:left.widthAnchor),
            detail.widthAnchor.constraint(equalTo:left.widthAnchor)
        ])
    }
    private func showError(_ error:Error) {
        status.stringValue = error.localizedDescription
        updateControls()
    }
    private func resetForSession() {
        stopLive(); epoch += 1
        position = .start; memory = ROBChessAppearanceMemory()
        baseline = nil; previous = nil; map = nil; cornerPoints = []; marking = false
        frame = nil; boardRaster = nil; evidence = nil; pendingCorrection = false
        moveField.stringValue = ""; review.state = .off; cameraView.image = nil
        cameraView.map = nil; cameraView.corners = []; currentChanges = []; proposalMoves = []
        updateDiagram(); updateControls()
    }
    @objc private func newSession() {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Create a chess teaching session"
        panel.nameFieldStringValue = "Chess Study \(ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-"))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let created = try ROBChessStudySession(createAt:url)
            resetForSession(); session = created
            status.stringValue = "Standard starting position selected. Open an image or start the main camera."
            updateControls()
        } catch { showError(error) }
    }
    @objc private func openSession() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Open a saved chess teaching session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stopLive(); status.stringValue = "Checking saved images and rebuilding appearance examples…"
        busy = true; updateControls(); epoch += 1; let ticket = epoch
        queue.async { [weak self] in
            let result = Result { () throws -> (ROBChessStudySession,ROBChessAppearanceMemory) in
                let loaded = try ROBChessStudySession(open:url)
                var memory = ROBChessAppearanceMemory()
                // Bounded example replay; archived labels/images remain intact.
                for record in loaded.manifest.trainingRecords.suffix(80) {
                    let boardURL = url.appendingPathComponent(record.id.uuidString).appendingPathComponent("board.png")
                    var evidence = try ROBChessRaster.load(boardURL).evidence()
                    evidence.heightsMillimeters = record.heightsMillimeters.map { heights in (0..<64).map { heights[ROBChessPosition.squareName($0)] } }
                    memory.learn(position:try ROBChessPosition(fen:record.fen),evidence:evidence)
                }
                return (loaded,memory)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard self.epoch == ticket else { self.updateControls(); return }
                switch result {
                case .success(let (loaded,memory)):
                    self.resetForSession(); self.session = loaded; self.memory = memory
                    if let last = loaded.manifest.records.last { self.position = (try? ROBChessPosition(fen:last.fen)) ?? .start }
                    self.status.stringValue = "Session restored. Mark the board in a fresh frame and verify the current position."
                    self.updateDiagram(); self.updateControls()
                case .failure(let error): self.showError(error)
                }
            }
        }
    }
    @objc private func openImage() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg,.png,.heic,.tiff]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stopLive(); epoch += 1
        do { receive(try ROBChessStudyFrame(raster:ROBChessRaster.load(url),source:"Imported image: \(url.lastPathComponent)")) }
        catch { showError(error) }
    }
    @objc private func startLive() {
        guard !busy else { return }
        #if ROB_CHESS_STANDALONE
        return
        #else
        marking = false; frozen = false; live = true
        previous = nil; stableCount = 0; review.state = .off
        ROBChessStudyLiveSource.shared.setActive(true)
        status.stringValue = "Watching the main camera. Keep the board and camera fixed; clear hands before review."
        updateControls()
        #endif
    }
    private func stopLive() {
        ROBChessStudyLiveSource.shared.setActive(false)
        live = false; frozen = true
    }
    @objc private func freezeReview() {
        // Stop incoming frames even while the current frame is being analyzed.
        // Its completion may finish normally; review stays disabled until then.
        if live, let frame, ProcessInfo.processInfo.systemUptime-frame.receivedUptime > 3 {
            status.stringValue = "The live feed is stale. Wait for a fresh frame before freezing."; return
        }
        stopLive()
        status.stringValue = "Frozen evidence. Review the image and the position diagram before saving."
        updateControls()
    }
    @objc private func markCorners() {
        guard frame != nil, !busy else { status.stringValue = "Load a board image first."; return }
        freezeReview(); guard frozen else { return }
        epoch += 1; map = nil; cornerPoints = []; baseline = nil; previous = nil
        boardRaster = nil; evidence = nil; cameraView.map = nil; cameraView.corners = []
        marking = true; review.state = .off
        status.stringValue = "Click the OUTER a8 corner, then h8, h1, a1. Use the actual board coordinates."
        updateControls()
    }
    private func mark(_ point:ROBChessPoint) {
        guard marking, cornerPoints.count < 4, !busy else { return }
        cornerPoints.append(point); cameraView.corners = cornerPoints
        if cornerPoints.count == 4 {
            do {
                map = try ROBChessBoardMap(corners:cornerPoints); cameraView.map = map; marking = false
                if let frame { analyze(frame) }
            } catch { cornerPoints = []; cameraView.corners = []; showError(error) }
        } else { status.stringValue = "Next outer corner: \(["a8","h8","h1","a1"][cornerPoints.count])." }
    }
    @nonobjc func receive(_ incoming:ROBChessStudyFrame) {
        guard !busy else { return }
        if let old = frame, old.raster.width != incoming.raster.width || old.raster.height != incoming.raster.height {
            map = nil; cornerPoints = []; baseline = nil; cameraView.map = nil; cameraView.corners = []
        }
        frame = incoming; boardRaster = nil; evidence = nil; review.state = .off
        cameraView.image = NSImage(cgImage:incoming.raster.image,size:.zero)
        sourceLabel.stringValue = "\(incoming.source) • \(incoming.raster.width) × \(incoming.raster.height) • \(incoming.capturedAt.formatted(date:.omitted,time:.standard))"
        analyze(incoming)
    }
    private func analyze(_ frame:ROBChessStudyFrame) {
        guard let map else {
            status.stringValue = "Mark the board corners, then verify the starting position."; updateControls(); return
        }
        busy = true; updateControls(); let ticket = epoch
        let base = baseline, prior = previous, currentPosition = position
        queue.async { [weak self] in
            let result = Result { () throws -> (ROBChessRaster,ROBChessEvidence,[Double],[ROBChessProposal],Bool) in
                let board = try frame.raster.rectified(map:map,size:256)
                var evidence = board.evidence()
                evidence.heightsMillimeters = frame.depth?.heights(map:map,position:currentPosition)
                let changes = base.map { evidence.changes(from:$0) } ?? []
                let proposals = frame.handVisible ? [] : ROBChessStudyAnalysis.proposals(position:currentPosition,changes:changes)
                let stability = prior.map { evidence.changes(from:$0).reduce(0,+)/64 < 0.009 } ?? false
                return (board,evidence,changes,proposals,stability)
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard self.epoch == ticket, self.frame?.id == frame.id else { self.updateControls(); return }
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let (board,evidence,changes,proposals,stable)):
                    self.boardRaster = board; self.evidence = evidence; self.previous = evidence
                    self.currentChanges = changes; self.stableCount = stable ? self.stableCount+1 : 0
                    self.proposalMoves = self.live && self.stableCount < 2 ? [] : proposals
                    self.cameraView.highlighted = Set(changes.indices.filter { changes[$0] >= 0.045 })
                    self.suggestions.removeAllItems(); self.suggestions.addItem(withTitle:"Move suggestions — review required")
                    for proposal in self.proposalMoves.prefix(8) {
                        self.suggestions.addItem(withTitle:"\(proposal.move.uci) · image agreement \(Int(proposal.score*100))")
                    }
                    let changed = changes.filter { $0 >= 0.045 }.count
                    if frame.handVisible { self.status.stringValue = "A hand is visible. Clear the view before teaching this frame." }
                    else if base == nil { self.status.stringValue = "Board mapped. Check all 64 squares against the diagram, then save." }
                    else if changed > 6 { self.status.stringValue = "Many squares changed. Check camera alignment, lighting and obstructions; re-mark if needed." }
                    else if self.live && self.stableCount < 2 { self.status.stringValue = "Waiting for three steady observations…" }
                    else if proposals.isEmpty { self.status.stringValue = changed == 0 ? "Board unchanged." : "No clear legal move match. Review manually or correct the position." }
                    else { self.status.stringValue = "\(proposals.count) legal image match\(proposals.count == 1 ? "" : "es"). Freeze, choose a move and check the diagram." }
                    let guesses = (0..<64).compactMap { self.memory.guess(square:$0,descriptor:evidence.descriptors[$0],height:evidence.heightsMillimeters?[$0]) }
                    let heightCount = evidence.heightsMillimeters?.compactMap { $0 }.count ?? 0
                    self.detail.stringValue = "\(guesses.count)/64 distinctive appearance hints • \(heightCount)/64 depth-height estimates. Review ambiguous marble pieces. These are hints, not verified identities or confidence probabilities."
                    self.updateControls()
                }
            }
        }
    }
    @objc private func chooseSuggestion() {
        guard suggestions.indexOfSelectedItem > 0 else { return }
        let index = suggestions.indexOfSelectedItem-1
        guard index < proposalMoves.count else { return }
        moveField.stringValue = proposalMoves[index].move.uci; review.state = .off
        updateDiagram(); updateControls()
    }
    func controlTextDidChange(_ obj:Notification) { review.state = .off; updateDiagram(); updateControls() }
    @objc private func reviewChanged() { updateControls() }
    private var reviewedMove: String { moveField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }
    private func updateDiagram() {
        let next = try? position.applying(uci:reviewedMove)
        diagram.position = next ?? position; fenLabel.stringValue = diagram.position.fen
        diagram.highlighted = next.map { next in Set((0..<64).filter { next.board[$0] != position.board[$0] }) } ?? []
    }
    private func updateControls() {
        let ready = session != nil && map != nil && evidence != nil && boardRaster != nil &&
            frame != nil && frame?.handVisible == false && frozen && !busy && !marking && review.state == .on
        baselineButton.isEnabled = ready && reviewedMove.isEmpty && (baseline == nil || pendingCorrection)
        moveButton.isEnabled = ready && baseline != nil && !pendingCorrection && (try? position.applying(uci:reviewedMove)) != nil
        freezeButton.isEnabled = live
        liveButton.isEnabled = !live && !busy
        review.isEnabled = frozen && !busy && map != nil && frame?.handVisible == false
        memoryLabel.stringValue = "\(session?.manifest.records.count ?? 0) reviewed frames • \(memory.examples.count) saved appearance examples\n\(session?.directory.lastPathComponent ?? "Create a session to save teaching data.")"
    }
    @objc private func savePosition() {
        guard baselineButton.isEnabled else { return }
        let kind = pendingCorrection ? "correction" : ((session?.manifest.records.isEmpty ?? true) ? "baseline" : "rebaseline")
        persist(position:position,kind:kind,move:nil)
    }
    @objc private func saveMove() {
        guard moveButton.isEnabled, let next = try? position.applying(uci:reviewedMove) else { return }
        persist(position:next,kind:"move",move:reviewedMove)
    }
    private func persist(position next:ROBChessPosition,kind:String,move:String?) {
        guard let session, let frame, let boardRaster, let evidence, let map else { return }
        busy = true; updateControls(); let ticket = epoch
        queue.async { [weak self] in
            let result = Result { () throws -> ROBChessAppearanceMemory? in
                try session.append(frame:frame,board:boardRaster,map:map,position:next,kind:kind,move:move)
                guard kind == "correction" else { return nil }
                var rebuilt = ROBChessAppearanceMemory()
                for record in session.manifest.trainingRecords.suffix(80) {
                    let url = session.directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("board.png")
                    var evidence = try ROBChessRaster.load(url).evidence()
                    evidence.heightsMillimeters = record.heightsMillimeters.map { heights in (0..<64).map { heights[ROBChessPosition.squareName($0)] } }
                    rebuilt.learn(position:try ROBChessPosition(fen:record.fen),evidence:evidence)
                }
                return rebuilt
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard self.epoch == ticket else { self.updateControls(); return }
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let rebuilt):
                    self.position = next; self.baseline = evidence; self.pendingCorrection = false
                    if let rebuilt { self.memory = rebuilt }
                    else {
                        var reviewed = evidence
                        reviewed.heightsMillimeters = frame.depth?.heights(map:map,position:next)
                        self.memory.learn(position:next,evidence:reviewed)
                    }
                    self.moveField.stringValue = ""; self.review.state = .off; self.proposalMoves = []
                    self.status.stringValue = "Saved \(move ?? "verified position"). \(next.whiteToMove ? "White" : "Black") to move. Continue observing after the next move."
                    self.updateDiagram(); self.updateControls()
                }
            }
        }
    }
    @objc private func correctPosition() {
        guard !busy, frozen else { status.stringValue = "Freeze a frame before correcting its position."; return }
        let alert = NSAlert(); alert.messageText = "Correct the position using FEN"
        alert.informativeText = "Enter all pieces, side to move, castling and en-passant rights. Review the updated diagram before saving. Existing records remain in the session."
        let input = NSTextField(string:position.fen); input.frame = CGRect(x:0,y:0,width:540,height:28)
        alert.accessoryView = input; alert.addButton(withTitle:"Review correction"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            position = try ROBChessPosition(fen:input.stringValue); pendingCorrection = true
            baseline = nil; moveField.stringValue = ""; review.state = .off
            updateDiagram(); updateControls()
            status.stringValue = "Correction is not saved yet. Check the diagram against the frozen image."
        } catch { showError(error) }
    }
    @objc private func suggestMove() {
        guard !busy, !pendingCorrection, baseline != nil else {
            status.stringValue = "Save a verified position before asking for a move."; return
        }
        let current = position; coachLabel.stringValue = "Checking legal moves with the basic two-ply coach…"
        busy = true; updateControls(); let ticket = epoch
        queue.async { [weak self] in
            let move = ROBChessCoach.suggestion(current)
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                guard self.epoch == ticket, self.position == current else { self.updateControls(); return }
                if let move {
                    self.coachLabel.stringValue = "ROB suggests \(move.uci): \(ROBChessPosition.label(current.board[move.from]).replacingOccurrences(of:"_",with:" ")) \(ROBChessPosition.squareName(move.from)) → \(ROBChessPosition.squareName(move.to)). Move it by hand, then observe and confirm. Basic rules/material coach."
                } else { self.coachLabel.stringValue = current.isInCheck(white:current.whiteToMove) ? "Checkmate: no legal moves." : "Stalemate: no legal moves." }
                self.updateControls()
            }
        }
    }
    @objc private func showSavedData() { if let session { NSWorkspace.shared.open(session.directory) } }
    private func updateAge() {
        guard live else { return }
        if frame == nil || ProcessInfo.processInfo.systemUptime-(frame?.receivedUptime ?? 0) > 3 {
            status.stringValue = "Waiting for a fresh main-camera frame. No new observations are being accepted."
            review.state = .off; updateControls()
        }
    }
    // Deterministic UI/fixture entry point, also useful for replaying an exported image.
    @nonobjc func loadDemo(imageURL:URL,corners:[ROBChessPoint]) throws {
        stopLive(); map = try ROBChessBoardMap(corners:corners); cornerPoints = corners
        cameraView.map = map; cameraView.corners = corners
        receive(try ROBChessStudyFrame(raster:ROBChessRaster.load(imageURL),source:"Illustrative fixture — not ROB's camera"))
    }
}
