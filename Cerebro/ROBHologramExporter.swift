import AppKit
import AVFoundation
import Darwin

/// Captures the newest synchronized RGB-D frame and exports a GitHub Pages-ready
/// Three.js "hologram message". The binary point format is intentionally tiny:
/// UInt32 count followed by count × (Float32 x/y/z + UInt8 r/g/b/a).
@objcMembers public final class ROBHologramExporter: NSObject {
    public static let shared = ROBHologramExporter()
    private static let detailDefaultsKey = "ROBHologramVoxelDetail"
    private let lock = NSLock()
    private var latestFrame: ROBDepthCloudFrame?
    private var movieFrames: [MovieFrame] = []
    private var movieStartedAt: CFTimeInterval = 0
    private var lastMovieFrameAt: CFTimeInterval = 0
    private var movieAudioRecorder: AVAudioRecorder?
    private var movieAudioURL: URL?
    private var movieDetailScale = 1
    private var latestExportedUSDZ: URL?
    private var airDropServer: Process?
    private var airDropStopTimer: Timer?
    @objc public private(set) var isMovieRecording = false
    public var voxelDetail: Int {
        get { max(1, min(UserDefaults.standard.integer(forKey: Self.detailDefaultsKey), 3)) }
        set { UserDefaults.standard.set(max(1, min(newValue, 3)), forKey: Self.detailDefaultsKey) }
    }

    private func stillARPointBudget(for detail: Int) -> Int {
        [1: 15_000, 2: 45_000, 3: 90_000][detail] ?? 15_000
    }

    private func movieARPointBudget(for detail: Int) -> Int {
        [1: 2_000, 2: 4_000, 3: 7_000][detail] ?? 2_000
    }

    private func arVoxelHalfSize(for detail: Int, movie: Bool) -> Float {
        if movie {
            return [1: 0.008, 2: 0.005, 3: 0.0035][detail] ?? 0.008
        }
        return [1: 0.005, 2: 0.00325, 3: 0.00225][detail] ?? 0.005
    }

    public func showCaptureSettings() {
        let alert = NSAlert()
        alert.messageText = "Hologram Voxel Detail"
        alert.informativeText = "This controls browser capture and Apple AR Quick Look resolution. High exports up to 45,000 still-image AR voxels; Ultra exports up to 90,000 with smaller voxel faces. Movie limits are lower to keep animation practical on iPhone."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        let slider = NSSlider(value: Double(voxelDetail), minValue: 1, maxValue: 3, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 26, width: 340, height: 24)
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = true
        let labels = NSTextField(labelWithString: "Standard                         High                         Ultra")
        labels.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        labels.font = .systemFont(ofSize: 11)
        labels.textColor = .secondaryLabelColor
        container.addSubview(slider)
        container.addSubview(labels)
        alert.accessoryView = container
        if alert.runModal() == .alertFirstButtonReturn {
            voxelDetail = Int(slider.integerValue)
        }
    }

    public func capture(_ frame: ROBDepthCloudFrame) {
        let now = CACurrentMediaTime()
        lock.lock()
        latestFrame = frame
        let shouldCaptureMovieFrame = isMovieRecording &&
            now - lastMovieFrameAt >= 0.125 && now - movieStartedAt <= 15
        if shouldCaptureMovieFrame { lastMovieFrameAt = now }
        lock.unlock()
        guard shouldCaptureMovieFrame else { return }
        let points = makePoints(frame: frame, stride: max(2, 6 / movieDetailScale))
        guard !points.isEmpty else { return }
        lock.lock()
        if isMovieRecording {
            movieFrames.append(MovieFrame(timestamp: Float(now - movieStartedAt), points: points))
        }
        lock.unlock()
    }

    public func startMovieRecording() {
        guard !isMovieRecording else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async { self?.beginMovieRecording(recordAudio: granted) }
        }
    }

    private func beginMovieRecording(recordAudio: Bool) {
        lock.lock()
        let canBegin = !isMovieRecording
        lock.unlock()
        guard canBegin else { return }
        if recordAudio {
            NotificationCenter.default.post(name: .ROBHologramWillBeginAudioRecording, object: self)
        }
        var preparedRecorder: AVAudioRecorder?
        var preparedAudioURL: URL?
        if recordAudio {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rob-hologram-\(UUID().uuidString).wav")
                let recorder = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false
                ])
                guard recorder.prepareToRecord() else {
                    throw ExportError.audio("The selected microphone could not prepare for recording.")
                }
                preparedRecorder = recorder
                preparedAudioURL = url
            } catch {
                presentError("Voxel recording will continue without audio: \(error.localizedDescription)")
            }
        }
        lock.lock()
        guard !isMovieRecording else { lock.unlock(); return }
        movieFrames.removeAll(keepingCapacity: true)
        movieStartedAt = CACurrentMediaTime()
        lastMovieFrameAt = 0
        movieDetailScale = voxelDetail
        isMovieRecording = true
        lock.unlock()
        movieAudioRecorder = preparedRecorder
        movieAudioURL = preparedAudioURL
        if let preparedRecorder, !preparedRecorder.record(forDuration: 15) {
            movieAudioRecorder = nil
            movieAudioURL = nil
            if let preparedAudioURL { try? FileManager.default.removeItem(at: preparedAudioURL) }
            presentError("Voxel recording started, but the microphone could not begin recording. The export will contain moving voxels without audio.")
        }
        if preparedRecorder == nil {
            NotificationCenter.default.post(name: .ROBHologramDidEndAudioRecording, object: self)
        }
        NotificationCenter.default.post(name: .ROBHologramMovieRecordingStateDidChange, object: self)
        NSSound.beep()
    }

    public func stopMovieRecordingInteractively() {
        lock.lock()
        guard isMovieRecording else { lock.unlock(); return }
        isMovieRecording = false
        let frames = movieFrames
        let detail = movieDetailScale
        movieFrames.removeAll()
        lock.unlock()
        NotificationCenter.default.post(name: .ROBHologramMovieRecordingStateDidChange, object: self)
        movieAudioRecorder?.stop()
        movieAudioRecorder = nil
        NotificationCenter.default.post(name: .ROBHologramDidEndAudioRecording, object: self)
        let audioURL = movieAudioURL
        movieAudioURL = nil
        guard !frames.isEmpty else {
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            presentError("No RGB-depth movie frames were received. Confirm the OAK-D stream is active and try again.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export AR Voxel Hologram Recording"
        panel.nameFieldStringValue = "rob-hologram-movie"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.begin { [weak self] response in
            defer { if let audioURL { try? FileManager.default.removeItem(at: audioURL) } }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try self?.exportMovie(frames: frames, audioURL: audioURL, detail: detail, to: destination)
                self?.latestExportedUSDZ = destination.appendingPathComponent("hologram.usdz")
                NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("index.html")])
            } catch {
                self?.presentError(error.localizedDescription)
            }
        }
    }

    public func exportInteractively() {
        lock.lock(); let frame = latestFrame; lock.unlock()
        guard let frame else {
            presentError("No synchronized RGB-depth frame is available yet.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export ROB Hologram Message"
        panel.nameFieldStringValue = "rob-hologram-message"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try self?.export(frame: frame, to: destination)
                self?.latestExportedUSDZ = destination.appendingPathComponent("hologram.usdz")
                NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("index.html")])
            } catch {
                self?.presentError(error.localizedDescription)
            }
        }
    }

    public func shareLatestHologramViaAirDrop() {
        guard let usdz = latestExportedUSDZ,
              FileManager.default.fileExists(atPath: usdz.path) else {
            presentError("Export a still or moving hologram before starting an AirDrop session.")
            return
        }
        stopAirDropSession()
        let port = 8_765
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.currentDirectoryURL = usdz.deletingLastPathComponent()
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "0.0.0.0"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        do {
            try server.run()
            airDropServer = server
        } catch {
            presentError("The temporary hologram server could not start: \(error.localizedDescription)")
            return
        }
        airDropStopTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            self?.stopAirDropSession()
        }
        let hostedURL = Self.localIPv4Address().flatMap {
            URL(string: "http://\($0):\(port)/hologram.usdz")
        }
        let alert = NSAlert()
        alert.messageText = "AirDrop Hologram for 10 Minutes"
        alert.informativeText = "Cerebro will now open AirDrop with the USDZ file and its temporary URL. In Control Center → AirDrop, choose Everyone for 10 Minutes if the recipient cannot see this Mac. The recipient must remain on the same Wi-Fi network to use the temporary URL."
        alert.addButton(withTitle: "Open AirDrop")
        alert.addButton(withTitle: "Cancel Session")
        if alert.runModal() != .alertFirstButtonReturn {
            stopAirDropSession()
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            stopAirDropSession()
            presentError("AirDrop sharing is unavailable on this Mac.")
            return
        }
        var items: [Any] = [usdz]
        if let hostedURL { items.append(hostedURL) }
        service.perform(withItems: items)
    }

    public func stopAirDropSession() {
        airDropStopTimer?.invalidate()
        airDropStopTimer = nil
        if let airDropServer, airDropServer.isRunning { airDropServer.terminate() }
        airDropServer = nil
    }

    private static func localIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var address = interface.ifa_addr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            if result == 0 { return String(cString: host) }
        }
        return nil
    }

    private func export(frame: ROBDepthCloudFrame, to folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let detail = voxelDetail
        let points = makePoints(frame: frame, stride: max(1, 4 - detail))
        guard !points.isEmpty else { throw ExportError.noDepth }
        try binary(points).write(to: folder.appendingPathComponent("hologram.bin"), options: .atomic)
        try metadata(pointCount: points.count, detail: detail).write(to: folder.appendingPathComponent("hologram.json"), atomically: true, encoding: .utf8)
        try Self.indexHTML.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Self.viewerJavaScript.write(to: folder.appendingPathComponent("viewer.js"), atomically: true, encoding: .utf8)
        try Self.styles.write(to: folder.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        try Self.localServer.write(to: folder.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        try Self.readme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let usda = folder.appendingPathComponent("hologram.usda")
        try usd(points, detail: detail).write(to: usda, atomically: true, encoding: .utf8)
        try createUSDZ(from: usda, at: folder.appendingPathComponent("hologram.usdz"))
        try? fileManager.removeItem(at: usda)
    }

    private func exportMovie(frames: [MovieFrame], audioURL: URL?, detail: Int, to folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try movieBinary(frames).write(to: folder.appendingPathComponent("hologram-movie.bin"), options: .atomic)
        let duration = frames.last?.timestamp ?? 0
        let audioSize = audioURL.flatMap {
            try? fileManager.attributesOfItem(atPath: $0.path)[.size] as? NSNumber
        }??.intValue ?? 0
        let hasAudio = audioURL != nil && audioSize > 1_024
        let audioName = "message.wav"
        let packagedAudioURL = folder.appendingPathComponent(audioName)
        if hasAudio, let audioURL {
            if fileManager.fileExists(atPath: packagedAudioURL.path) { try fileManager.removeItem(at: packagedAudioURL) }
            try fileManager.copyItem(at: audioURL, to: packagedAudioURL)
        }
        let metadata = """
        {"format":"ROB-HOLOGRAM-MOVIE-1","frameCount":\(frames.count),"duration":\(duration),"hasAudio":\(hasAudio),"voxelDetail":\(detail),"units":"meters","capturedAt":"\(ISO8601DateFormatter().string(from: Date()))"}
        """
        try metadata.write(to: folder.appendingPathComponent("hologram-movie.json"), atomically: true, encoding: .utf8)
        try Self.movieIndexHTML.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Self.movieViewerJavaScript.write(to: folder.appendingPathComponent("viewer.js"), atomically: true, encoding: .utf8)
        try Self.styles.write(to: folder.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        try Self.localServer.write(to: folder.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        try Self.movieReadme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let usda = folder.appendingPathComponent("hologram.usda")
        try animatedUSD(frames: frames, audioName: hasAudio ? audioName : nil, detail: detail)
            .write(to: usda, atomically: true, encoding: .utf8)
        try createUSDZ(
            from: usda,
            at: folder.appendingPathComponent("hologram.usdz"),
            additionalFiles: hasAudio ? [packagedAudioURL] : []
        )
        try? fileManager.removeItem(at: usda)
    }

    private struct Point { let x, y, z: Float; let r, g, b: UInt8 }
    private struct MovieFrame { let timestamp: Float; let points: [Point] }
    private struct ARMovieFrame { let timestamp: Float; let points: [Point] }

    private func makePoints(frame: ROBDepthCloudFrame, stride sampleStride: Int = 3) -> [Point] {
        let width = frame.width, height = frame.height
        guard width > 0, height > 0,
              frame.millimetersLittleEndian.length == width * height * 2 else { return [] }
        let depth = frame.millimetersLittleEndian.bytes.assumingMemoryBound(to: UInt8.self)
        let rgb = frame.rgbPixelBuffer
        if let rgb { CVPixelBufferLockBaseAddress(rgb, .readOnly) }
        defer { if let rgb { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) } }
        let rgbBase = rgb.flatMap(CVPixelBufferGetBaseAddress)?.assumingMemoryBound(to: UInt8.self)
        let rgbRow = rgb.map(CVPixelBufferGetBytesPerRow) ?? 0
        let rgbWidth = rgb.map(CVPixelBufferGetWidth) ?? 0
        let rgbHeight = rgb.map(CVPixelBufferGetHeight) ?? 0
        let focal = Float(width) / (2 * tan(69 * .pi / 360))
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        var output: [Point] = []
        output.reserveCapacity((width / sampleStride) * (height / sampleStride))
        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                let offset = (y * width + x) * 2
                let mm = UInt16(depth[offset]) | (UInt16(depth[offset + 1]) << 8)
                guard mm >= 200, mm <= 8_000 else { continue }
                let meters = Float(mm) / 1000
                var r: UInt8 = 90, g: UInt8 = 220, b: UInt8 = 255
                if let rgbBase, x < rgbWidth, y < rgbHeight {
                    let pixel = rgbBase.advanced(by: y * rgbRow + x * 4)
                    b = pixel[0]; g = pixel[1]; r = pixel[2]
                }
                output.append(Point(
                    x: (Float(x) - cx) * meters / focal,
                    y: -(Float(y) - cy) * meters / focal,
                    z: -meters, r: r, g: g, b: b
                ))
            }
        }
        return output
    }

    private func binary(_ points: [Point]) -> Data {
        var data = Data(capacity: 4 + points.count * 16)
        var count = UInt32(points.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for point in points {
            for component in [point.x, point.y, point.z] {
                var bits = component.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: [point.r, point.g, point.b, 255])
        }
        return data
    }

    private func movieBinary(_ frames: [MovieFrame]) -> Data {
        var data = Data()
        data.append(contentsOf: [0x52, 0x4f, 0x42, 0x4d]) // ROBM
        var version = UInt32(1).littleEndian
        var frameCount = UInt32(frames.count).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &frameCount) { data.append(contentsOf: $0) }
        for frame in frames {
            var timestamp = frame.timestamp.bitPattern.littleEndian
            var pointCount = UInt32(frame.points.count).littleEndian
            withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &pointCount) { data.append(contentsOf: $0) }
            for point in frame.points {
                for component in [point.x, point.y, point.z] {
                    var bits = component.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                }
                data.append(contentsOf: [point.r, point.g, point.b, 255])
            }
        }
        return data
    }

    private func metadata(pointCount: Int, detail: Int) -> String {
        """
        {"format":"ROB-HOLOGRAM-1","pointCount":\(pointCount),"voxelDetail":\(detail),"units":"meters","coordinateSystem":"camera-right-up-back","capturedAt":"\(ISO8601DateFormatter().string(from: Date()))"}
        """
    }

    private func usd(_ points: [Point], detail: Int) -> String {
        // AR Quick Look does not consistently draw UsdGeomPoints. Export a
        // real, double-sided quad mesh instead. Limit the AR copy so iPhone
        // and Vision Pro can place it quickly while the web viewer retains all
        // points from hologram.bin.
        let maximumARPoints = stillARPointBudget(for: detail)
        let arStep = max(1, Int(ceil(Double(points.count) / Double(maximumARPoints))))
        let arPoints = Array(points.enumerated().compactMap {
            $0.offset.isMultiple(of: arStep) ? $0.element : nil
        }.prefix(maximumARPoints))
        func percentile(_ values: [Float], _ fraction: Double) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }
        let xs = arPoints.map(\.x), ys = arPoints.map(\.y), zs = arPoints.map(\.z)
        let minimumY = percentile(ys, 0.01)
        let minimumX = percentile(xs, 0.02)
        let maximumX = percentile(xs, 0.98)
        let minimumZ = percentile(zs, 0.02)
        let maximumZ = percentile(zs, 0.98)
        let centerX = (minimumX + maximumX) / 2
        let centerZ = (minimumZ + maximumZ) / 2
        let halfSize = arVoxelHalfSize(for: detail, movie: false)
        // RealityKit/Quick Look commonly falls back to beige when a mesh uses
        // a displayColor primvar. Quantize the RGB samples into 64 small mesh
        // batches and bind a concrete PreviewSurface material to each batch.
        // This preserves a useful RGB image while remaining lightweight.
        let buckets = Dictionary(grouping: arPoints) { point in
            (Int(point.r >> 6) << 4) | (Int(point.g >> 6) << 2) | Int(point.b >> 6)
        }
        var children: [String] = []
        children.reserveCapacity(buckets.count * 2)
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key], !bucket.isEmpty else { continue }
            let red = bucket.reduce(0) { $0 + Int($1.r) } / bucket.count
            let green = bucket.reduce(0) { $0 + Int($1.g) } / bucket.count
            let blue = bucket.reduce(0) { $0 + Int($1.b) } / bucket.count
            let color = "(\(Float(red) / 255), \(Float(green) / 255), \(Float(blue) / 255))"
            let glow = "(\(Float(red) / 2040), \(Float(green) / 2040), \(Float(blue) / 2040))"
            var positions: [String] = []
            var counts: [String] = []
            var indices: [String] = []
            positions.reserveCapacity(bucket.count * 4)
            counts.reserveCapacity(bucket.count)
            indices.reserveCapacity(bucket.count * 4)
            for (pointIndex, point) in bucket.enumerated() {
                let x = point.x - centerX
                let y = max(point.y - minimumY, 0) + 0.03
                let z = point.z - centerZ
                positions.append("(\(x - halfSize), \(y - halfSize), \(z))")
                positions.append("(\(x + halfSize), \(y - halfSize), \(z))")
                positions.append("(\(x + halfSize), \(y + halfSize), \(z))")
                positions.append("(\(x - halfSize), \(y + halfSize), \(z))")
                counts.append("4")
                let base = pointIndex * 4
                indices.append(contentsOf: ["\(base)", "\(base + 1)", "\(base + 2)", "\(base + 3)"])
            }
            children.append("""
                def Material "RGBMaterial_\(key)" {
                    token outputs:surface.connect = </Hologram/RGBMaterial_\(key)/PreviewSurface.outputs:surface>
                    def Shader "PreviewSurface" {
                        uniform token info:id = "UsdPreviewSurface"
                        color3f inputs:diffuseColor = \(color)
                        color3f inputs:emissiveColor = \(glow)
                        float inputs:metallic = 0
                        float inputs:roughness = 1
                        token outputs:surface
                    }
                }
                def Mesh "RGBPoints_\(key)" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                ) {
                    uniform token subdivisionScheme = "none"
                    bool doubleSided = true
                    rel material:binding = </Hologram/RGBMaterial_\(key)>
                    int[] faceVertexCounts = [\(counts.joined(separator: ","))]
                    int[] faceVertexIndices = [\(indices.joined(separator: ","))]
                    point3f[] points = [\(positions.joined(separator: ",\n"))]
                }
            """)
        }
        return """
        #usda 1.0
        (
            defaultPrim = "Hologram"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "Hologram" {
            # Preserve the approximate three-foot camera height instead of
            # pinning the captured scene to the detected floor plane.
            double3 xformOp:translate = (0, 0.9144, 0)
            float3 xformOp:scale = (0.45, 0.45, 0.45)
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:scale"]
        \(children.joined(separator: "\n"))
        }
        """
    }

    private func animatedUSD(frames: [MovieFrame], audioName: String?, detail: Int) -> String {
        let maximumPointsPerFrame = movieARPointBudget(for: detail)
        let arFrames = frames.map { frame -> ARMovieFrame in
            let step = max(1, Int(ceil(Double(frame.points.count) / Double(maximumPointsPerFrame))))
            let points = frame.points.enumerated().compactMap { index, point in
                index.isMultiple(of: step) ? point : nil
            }
            return ARMovieFrame(timestamp: frame.timestamp, points: Array(points.prefix(maximumPointsPerFrame)))
        }
        let allPoints = arFrames.flatMap(\.points)
        func percentile(_ values: [Float], _ fraction: Double) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }
        let minimumY = percentile(allPoints.map(\.y), 0.01)
        let minimumX = percentile(allPoints.map(\.x), 0.02)
        let maximumX = percentile(allPoints.map(\.x), 0.98)
        let minimumZ = percentile(allPoints.map(\.z), 0.02)
        let maximumZ = percentile(allPoints.map(\.z), 0.98)
        let centerX = (minimumX + maximumX) / 2
        let centerZ = (minimumZ + maximumZ) / 2
        let halfSize = arVoxelHalfSize(for: detail, movie: true)
        func paletteKey(_ point: Point) -> Int {
            min(Int(point.r) * 3 / 256, 2) * 9 +
            min(Int(point.g) * 3 / 256, 2) * 3 +
            min(Int(point.b) * 3 / 256, 2)
        }
        let usedKeys = Set(allPoints.map(paletteKey)).sorted()
        let levels: [Float] = [42 / 255, 128 / 255, 213 / 255]
        let materials = usedKeys.map { key -> String in
            let r = levels[key / 9], g = levels[(key / 3) % 3], b = levels[key % 3]
            return """
                def Material "RGBMaterial_\(key)" {
                    token outputs:surface.connect = </Hologram/RGBMaterial_\(key)/PreviewSurface.outputs:surface>
                    def Shader "PreviewSurface" {
                        uniform token info:id = "UsdPreviewSurface"
                        color3f inputs:diffuseColor = (\(r), \(g), \(b))
                        color3f inputs:emissiveColor = (\(r / 8), \(g / 8), \(b / 8))
                        float inputs:metallic = 0
                        float inputs:roughness = 1
                        token outputs:surface
                    }
                }
            """
        }
        // Quick Look can drop or flash prims when thousands of per-frame
        // meshes toggle visibility. Keep one fixed-topology mesh per palette
        // color and animate only its vertex positions instead.
        let groupedFrames = arFrames.map { Dictionary(grouping: $0.points, by: paletteKey) }
        var meshes: [String] = []
        for key in usedKeys {
            let slotCount = groupedFrames.map { $0[key]?.count ?? 0 }.max() ?? 0
            guard slotCount > 0 else { continue }
            let counts = Array(repeating: "4", count: slotCount).joined(separator: ",")
            var indices: [String] = []
            indices.reserveCapacity(slotCount * 4)
            for slot in 0..<slotCount {
                let base = slot * 4
                indices.append(contentsOf: ["\(base)", "\(base + 1)", "\(base + 2)", "\(base + 3)"])
            }
            var samples: [String] = []
            var defaultPositions = ""
            for (frameIndex, frame) in arFrames.enumerated() {
                let time = max(0, Int((frame.timestamp * 1_000).rounded()))
                let points = groupedFrames[frameIndex][key] ?? []
                var positions: [String] = []
                positions.reserveCapacity(slotCount * 4)
                for slot in 0..<slotCount {
                    if slot < points.count {
                        let point = points[slot]
                        let x = point.x - centerX
                        let y = max(point.y - minimumY, 0) + 0.03
                        let z = point.z - centerZ
                        positions.append("(\(x - halfSize), \(y - halfSize), \(z))")
                        positions.append("(\(x + halfSize), \(y - halfSize), \(z))")
                        positions.append("(\(x + halfSize), \(y + halfSize), \(z))")
                        positions.append("(\(x - halfSize), \(y + halfSize), \(z))")
                    } else {
                        // Degenerate unused slots at the placement origin so
                        // every animation sample retains identical topology.
                        positions.append(contentsOf: repeatElement("(0, 0, 0)", count: 4))
                    }
                }
                if frameIndex == 0 { defaultPositions = positions.joined(separator: ",\n") }
                samples.append("\(time): [\(positions.joined(separator: ",\n"))]")
            }
            meshes.append("""
                def Mesh "RGBVoxels_\(key)" (
                    prepend apiSchemas = ["MaterialBindingAPI"]
                ) {
                    uniform token subdivisionScheme = "none"
                    bool doubleSided = true
                    rel material:binding = </Hologram/RGBMaterial_\(key)>
                    int[] faceVertexCounts = [\(counts)]
                    int[] faceVertexIndices = [\(indices.joined(separator: ","))]
                    point3f[] points = [\(defaultPositions)]
                    point3f[] points.timeSamples = {
                        \(samples.joined(separator: ",\n"))
                    }
                }
            """)
        }
        let endTime = max(1, Int(((arFrames.last?.timestamp ?? 0) * 1_000).rounded()) + 125)
        let audio = audioName.map { name in
            """
                def SpatialAudio "MessageAudio" {
                    uniform asset filePath = @\(name)@
                    uniform token auralMode = "nonSpatial"
                    uniform token playbackMode = "onceFromStartToEnd"
                    uniform timecode startTime = 0
                    uniform timecode endTime = \(endTime)
                }
            """
        } ?? ""
        return """
        #usda 1.0
        (
            defaultPrim = "Hologram"
            startTimeCode = 0
            endTimeCode = \(endTime)
            timeCodesPerSecond = 1000
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "Hologram" {
            double3 xformOp:translate = (0, 0.9144, 0)
            float3 xformOp:scale = (0.45, 0.45, 0.45)
            uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:scale"]
        \(materials.joined(separator: "\n"))
        \(meshes.joined(separator: "\n"))
        \(audio)
        }
        """
    }

    private func createUSDZ(from usda: URL, at destination: URL, additionalFiles: [URL] = []) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/usdzip")
        process.currentDirectoryURL = usda.deletingLastPathComponent()
        process.arguments = [destination.path, usda.lastPathComponent] + additionalFiles.map(\.lastPathComponent)
        let errorPipe = Pipe(); process.standardError = errorPipe
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown usdzip error"
            throw ExportError.usdz(detail)
        }
    }

    private func presentError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = "ROB Hologram Export Failed"; alert.informativeText = message; alert.runModal()
        }
    }

    private enum ExportError: LocalizedError {
        case noDepth, usdz(String), audio(String)
        var errorDescription: String? {
            switch self { case .noDepth: return "The current depth image contains no usable points."
            case .usdz(let detail): return "Could not create the Apple AR asset: \(detail)"
            case .audio(let detail): return detail }
        }
    }
}

private extension Notification.Name {
    static let ROBHologramMovieRecordingStateDidChange = Notification.Name("ROBHologramMovieRecordingStateDidChange")
    static let ROBHologramWillBeginAudioRecording = Notification.Name("ROBHologramWillBeginAudioRecording")
    static let ROBHologramDidEndAudioRecording = Notification.Name("ROBHologramDidEndAudioRecording")
}

private extension ROBHologramExporter {
    static let indexHTML = #"""
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover,user-scalable=no"><meta name="theme-color" content="#020811"><title>Message from ROB</title><link rel="stylesheet" href="styles.css"><script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.180.0/examples/jsm/"}}</script></head>
    <body><main><div id="stage" aria-label="Interactive RGB point cloud"></div><header><div><h1>Message from ROB</h1><p id="status" role="status">Loading hologram…</p></div><button id="fullscreen" aria-label="Enter full screen">⛶</button></header><nav aria-label="Hologram controls"><a class="apple-ar" rel="ar" href="hologram.usdz"><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='44' height='44' viewBox='0 0 44 44'%3E%3Cpath fill='none' stroke='%2343dcff' stroke-width='2' d='m22 4 16 9v18l-16 9-16-9V13zM6 13l16 9 16-9M22 22v18'/%3E%3C/svg%3E" alt=""><span>View in Apple AR</span></a><button id="reset">Reset view</button><button id="replay">Replay</button></nav><aside id="hint">Drag to orbit · Pinch to zoom · Two fingers to pan</aside></main><script type="module" src="viewer.js"></script></body></html>
    """#

    static let movieIndexHTML = #"""
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover,user-scalable=no"><meta name="theme-color" content="#020811"><title>Moving Message from ROB</title><link rel="stylesheet" href="styles.css"><script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.180.0/examples/jsm/"}}</script></head>
    <body><main><div id="stage" aria-label="Animated RGB voxel hologram"></div><header><div><h1>Moving Message from ROB</h1><p id="status" role="status">Loading recording…</p></div><button id="fullscreen" aria-label="Enter full screen">⛶</button></header><nav aria-label="Hologram controls"><a class="apple-ar" rel="ar" href="hologram.usdz"><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='44' height='44' viewBox='0 0 44 44'%3E%3Cpath fill='none' stroke='%2343dcff' stroke-width='2' d='m22 4 16 9v18l-16 9-16-9V13zM6 13l16 9 16-9M22 22v18'/%3E%3C/svg%3E" alt=""><span>Watch in Apple AR</span></a><button id="replay">▶ Play with sound</button><button id="reset">Reset view</button></nav><aside id="hint">Tap Play with sound first · Drag to orbit · Pinch to zoom</aside><audio id="message-audio" preload="auto" playsinline src="message.wav"></audio></main><script type="module" src="viewer.js"></script></body></html>
    """#

    static let viewerJavaScript = #"""
    import * as THREE from 'three';
    import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
    import { ARButton } from 'three/addons/webxr/ARButton.js';
    const stage=document.querySelector('#stage'), status=document.querySelector('#status');
    const renderer=new THREE.WebGLRenderer({antialias:true,alpha:true,powerPreference:'high-performance'}); renderer.setPixelRatio(Math.min(devicePixelRatio,1.75)); renderer.outputColorSpace=THREE.SRGBColorSpace; renderer.xr.enabled=true; stage.append(renderer.domElement);
    const scene=new THREE.Scene(), camera=new THREE.PerspectiveCamera(52,1,.01,50);
    const controls=new OrbitControls(camera,renderer.domElement); controls.enableDamping=true; controls.dampingFactor=.07; controls.screenSpacePanning=true; controls.minDistance=.15; controls.maxDistance=20;
    const root=new THREE.Group(); scene.add(root); let cloud, radius=1, homeDistance=2;
    function resetView(){root.position.set(0,0,0);root.scale.setScalar(1);const visualCenter=-radius*.1;camera.position.set(0,visualCenter,homeDistance);controls.target.set(0,visualCenter,0);controls.update()}
    try {
      const response=await fetch('hologram.bin'); if(!response.ok)throw new Error(`HTTP ${response.status}`); const buffer=await response.arrayBuffer(), view=new DataView(buffer), count=view.getUint32(0,true); if(buffer.byteLength!==4+count*16)throw new Error('invalid hologram data');
      const positions=new Float32Array(count*3), colors=new Uint8Array(count*4); let o=4;
      for(let i=0;i<count;i++){positions[i*3]=view.getFloat32(o,true);positions[i*3+1]=view.getFloat32(o+4,true);positions[i*3+2]=view.getFloat32(o+8,true);colors.set(new Uint8Array(buffer,o+12,4),i*4);o+=16;}
      const axis=n=>{const a=[];for(let i=n;i<positions.length;i+=3)a.push(positions[i]);return a.sort((a,b)=>a-b)}, xs=axis(0),ys=axis(1),zs=axis(2),q=(a,p)=>a[Math.round((a.length-1)*p)];
      const loX=q(xs,.02),hiX=q(xs,.98),loY=q(ys,.02),hiY=q(ys,.98),loZ=q(zs,.02),hiZ=q(zs,.98),center=new THREE.Vector3((loX+hiX)/2,(loY+hiY)/2,(loZ+hiZ)/2);
      const geometry=new THREE.BufferGeometry(); geometry.setAttribute('position',new THREE.BufferAttribute(positions,3)); geometry.setAttribute('color',new THREE.BufferAttribute(colors,4,true)); geometry.translate(-center.x,-center.y,-center.z); geometry.computeBoundingSphere();
      radius=Math.max((hiX-loX)*.55,(hiY-loY)*.65,(hiZ-loZ)*.18,.1); homeDistance=Math.max(.6,radius/Math.tan(THREE.MathUtils.degToRad(camera.fov*.42)));
      cloud=new THREE.Points(geometry,new THREE.PointsMaterial({size:Math.max(.006,radius/120),vertexColors:true,sizeAttenuation:true,transparent:false,depthWrite:true})); root.add(cloud); resetView(); status.textContent=`Ready · ${count.toLocaleString()} RGB points`; replay();
    } catch(error) { status.textContent=`Could not load transmission: ${error.message}`; console.error(error); }
    function replay(){if(!cloud)return;cloud.material.transparent=true;cloud.material.opacity=0;const start=performance.now();function step(t){cloud.material.opacity=Math.min(1,(t-start)/900);cloud.material.needsUpdate=true;if(cloud.material.opacity<1)requestAnimationFrame(step);else cloud.material.transparent=false}requestAnimationFrame(step)}
    document.querySelector('#reset').onclick=resetView; document.querySelector('#replay').onclick=replay; document.querySelector('#fullscreen').onclick=()=>document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen?.();
    const apple=/AppleWebKit/i.test(navigator.userAgent)&&!/CriOS|FxiOS|EdgiOS/i.test(navigator.userAgent);
    if(!apple&&navigator.xr){const ar=ARButton.createButton(renderer,{optionalFeatures:['dom-overlay'],domOverlay:{root:document.body}});ar.classList.add('webxr-ar');document.querySelector('nav').prepend(ar);}
    renderer.xr.addEventListener('sessionstart',()=>{controls.enabled=false;root.position.set(0,0,-1.4);root.scale.setScalar(Math.min(1,.9/radius))}); renderer.xr.addEventListener('sessionend',()=>{controls.enabled=true;resetView()});
    function resize(){const w=Math.max(stage.clientWidth,1),h=Math.max(stage.clientHeight,1);renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix()} new ResizeObserver(resize).observe(stage);resize();
    renderer.setAnimationLoop(()=>{controls.update();renderer.render(scene,camera)}); setTimeout(()=>document.querySelector('#hint').classList.add('hidden'),5000);
    """#

    static let movieViewerJavaScript = #"""
    import * as THREE from 'three';
    import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
    const stage=document.querySelector('#stage'),status=document.querySelector('#status'),audio=document.querySelector('#message-audio');
    const renderer=new THREE.WebGLRenderer({antialias:true,alpha:true,powerPreference:'high-performance'});renderer.setPixelRatio(Math.min(devicePixelRatio,1.75));renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.xr.enabled=true;stage.append(renderer.domElement);
    const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(52,1,.01,50),controls=new OrbitControls(camera,renderer.domElement);controls.enableDamping=true;controls.screenSpacePanning=true;
    const root=new THREE.Group();scene.add(root);let cloud,frames=[],radius=1,homeDistance=2,playing=false,startedAt=0,animationToken=0,maxPointCount=0,workingPositions,workingColors;
    function resetView(){camera.position.set(0,-radius*.1,homeDistance);controls.target.set(0,-radius*.1,0);controls.update()}
    function showFrame(index){const frame=frames[index];if(!frame||!cloud)return;const count=frame.positions.length/3;for(let i=0;i<count;i++){workingPositions[i*3]=frame.positions[i*3]-frame.center.x;workingPositions[i*3+1]=frame.positions[i*3+1]-frame.center.y;workingPositions[i*3+2]=frame.positions[i*3+2]-frame.center.z;workingColors.set(frame.colors.subarray(i*4,i*4+4),i*4)}cloud.geometry.setDrawRange(0,count);cloud.geometry.attributes.position.needsUpdate=true;cloud.geometry.attributes.color.needsUpdate=true}
    try{const [metaResponse,dataResponse]=await Promise.all([fetch('hologram-movie.json'),fetch('hologram-movie.bin')]);if(!metaResponse.ok||!dataResponse.ok)throw new Error('recording files unavailable');const meta=await metaResponse.json(),buffer=await dataResponse.arrayBuffer(),view=new DataView(buffer);if(view.getUint32(0,false)!==0x524f424d||view.getUint32(4,true)!==1)throw new Error('invalid movie format');const frameCount=view.getUint32(8,true);let offset=12,all=[];for(let f=0;f<frameCount;f++){const time=view.getFloat32(offset,true),count=view.getUint32(offset+4,true);maxPointCount=Math.max(maxPointCount,count);offset+=8;const positions=new Float32Array(count*3),colors=new Uint8Array(count*4);for(let i=0;i<count;i++){positions[i*3]=view.getFloat32(offset,true);positions[i*3+1]=view.getFloat32(offset+4,true);positions[i*3+2]=view.getFloat32(offset+8,true);colors.set(new Uint8Array(buffer,offset+12,4),i*4);all.push(positions[i*3],positions[i*3+1],positions[i*3+2]);offset+=16}frames.push({time,positions,colors})}if(offset!==buffer.byteLength)throw new Error('trailing movie data');const axes=[[],[],[]];for(let i=0;i<all.length;i++)axes[i%3].push(all[i]);axes.forEach(a=>a.sort((a,b)=>a-b));const q=(a,p)=>a[Math.round((a.length-1)*p)],center=new THREE.Vector3((q(axes[0],.02)+q(axes[0],.98))/2,(q(axes[1],.02)+q(axes[1],.98))/2,(q(axes[2],.02)+q(axes[2],.98))/2);frames.forEach(f=>f.center=center);radius=Math.max((q(axes[0],.98)-q(axes[0],.02))*.55,(q(axes[1],.98)-q(axes[1],.02))*.65,.1);homeDistance=Math.max(.6,radius/Math.tan(THREE.MathUtils.degToRad(camera.fov*.42)));workingPositions=new Float32Array(maxPointCount*3);workingColors=new Uint8Array(maxPointCount*4);const geometry=new THREE.BufferGeometry(),positionAttribute=new THREE.BufferAttribute(workingPositions,3),colorAttribute=new THREE.BufferAttribute(workingColors,4,true);positionAttribute.setUsage(THREE.DynamicDrawUsage);colorAttribute.setUsage(THREE.DynamicDrawUsage);geometry.setAttribute('position',positionAttribute);geometry.setAttribute('color',colorAttribute);cloud=new THREE.Points(geometry,new THREE.PointsMaterial({size:Math.max(.009,radius/100),vertexColors:true,sizeAttenuation:true}));root.add(cloud);showFrame(0);resetView();if(!meta.hasAudio){audio.removeAttribute('src');audio.load()}status.textContent=`Ready · ${frameCount} moving RGB frames · ${meta.duration.toFixed(1)} seconds`;}catch(error){status.textContent=`Could not load recording: ${error.message}`;console.error(error)}
    function replay(){if(!frames.length)return;const token=++animationToken;playing=true;let useAudio=Boolean(audio.getAttribute('src'));audio.pause();audio.currentTime=0;const playPromise=useAudio?audio.play():Promise.resolve();playPromise.then(()=>{startedAt=performance.now()-audio.currentTime*1000;run()}).catch(error=>{useAudio=false;startedAt=performance.now();status.textContent='Sound was blocked · tap Play with sound again';console.warn('Audio playback unavailable',error);run()});function run(){function tick(now){if(token!==animationToken)return;const elapsed=useAudio?audio.currentTime:(now-startedAt)/1000;let index=frames.length-1;for(let i=1;i<frames.length;i++){if(frames[i].time>elapsed){index=i-1;break}}showFrame(index);const audioActive=useAudio&&!audio.ended;const visualActive=elapsed<=frames[frames.length-1].time+.15;if(audioActive||visualActive)requestAnimationFrame(tick);else{playing=false;status.textContent='Message complete · tap Play with sound to watch again'}}requestAnimationFrame(tick)}}
    document.querySelector('#replay').onclick=replay;document.querySelector('#reset').onclick=resetView;document.querySelector('#fullscreen').onclick=()=>document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen?.();
    const apple=/AppleWebKit/i.test(navigator.userAgent)&&!/CriOS|FxiOS|EdgiOS/i.test(navigator.userAgent);if(!apple&&navigator.xr){const module=await import('three/addons/webxr/ARButton.js');const ar=module.ARButton.createButton(renderer,{optionalFeatures:['dom-overlay'],domOverlay:{root:document.body}});ar.classList.add('webxr-ar');document.querySelector('nav').prepend(ar)}
    renderer.xr.addEventListener('sessionstart',()=>{controls.enabled=false;root.position.set(0,.9,-1.4);root.scale.setScalar(Math.min(.45,.5/radius));replay()});renderer.xr.addEventListener('sessionend',()=>{controls.enabled=true;root.position.set(0,0,0);root.scale.setScalar(1);resetView()});
    function resize(){const w=Math.max(stage.clientWidth,1),h=Math.max(stage.clientHeight,1);renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix()}new ResizeObserver(resize).observe(stage);resize();renderer.setAnimationLoop(()=>{controls.update();renderer.render(scene,camera)});setTimeout(()=>document.querySelector('#hint').classList.add('hidden'),6000);
    """#

    static let styles = #"""
    :root{color-scheme:dark;font-family:ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif;background:#020811;color:#eaffff}*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}html,body,main{width:100%;height:100%;height:100svh;margin:0;overflow:hidden}body{background:radial-gradient(circle at 50% 42%,#0a3449,#020811 68%);overscroll-behavior:none}#stage{position:absolute;inset:0;touch-action:none}#stage canvas{display:block;width:100%;height:100%}header{position:fixed;z-index:5;top:0;left:0;right:0;display:flex;justify-content:space-between;align-items:flex-start;padding:max(.75rem,env(safe-area-inset-top)) max(.85rem,env(safe-area-inset-right)) .5rem max(.85rem,env(safe-area-inset-left));pointer-events:none;background:linear-gradient(#020811cc,transparent)}h1{margin:0;font-size:clamp(1.05rem,4.5vw,1.65rem);text-shadow:0 0 14px #34d9ff}p{margin:.2rem 0;color:#9ed5df;font-size:.78rem}button,.apple-ar{min-height:48px;border:1px solid #43dcff;border-radius:14px;background:#06273aeF;color:white;text-decoration:none;font:600 .9rem/1 system-ui;display:inline-flex;align-items:center;justify-content:center;gap:.35rem;padding:.7rem .9rem;box-shadow:0 3px 18px #0008;cursor:pointer;pointer-events:auto}.apple-ar{background:#075270}.apple-ar img{width:25px;height:25px}#fullscreen{min-width:48px;padding:0;font-size:1.4rem}nav{position:fixed;z-index:10;left:0;right:0;bottom:0;display:flex;justify-content:center;gap:.45rem;padding:.55rem max(.65rem,env(safe-area-inset-right)) max(.65rem,env(safe-area-inset-bottom)) max(.65rem,env(safe-area-inset-left));background:linear-gradient(transparent,#020811 30%)}nav>*{flex:0 1 auto}#hint{position:fixed;z-index:4;left:50%;bottom:5.3rem;transform:translateX(-50%);white-space:nowrap;padding:.45rem .7rem;border-radius:999px;background:#0009;color:#bdebf2;font-size:.72rem;transition:opacity .5s;pointer-events:none}.hidden{opacity:0}.webxr-ar{position:static!important;margin:0!important;width:auto!important}@media(max-width:520px){nav{display:grid;grid-template-columns:1.6fr 1fr 1fr}.apple-ar,button{padding:.65rem .55rem;font-size:.78rem}}@media(orientation:landscape) and (max-height:520px){header{right:auto;max-width:45%}nav{left:auto;top:0;bottom:0;width:min(220px,34vw);padding:max(.65rem,env(safe-area-inset-top)) max(.65rem,env(safe-area-inset-right)) max(.65rem,env(safe-area-inset-bottom)) .4rem;display:flex;flex-direction:column;justify-content:center;background:linear-gradient(90deg,transparent,#020811 35%)}nav>*{width:100%}#hint{bottom:1rem}}
    """#

    static let readme = #"""
    # ROB Hologram Message

    A static Three.js RGB point-cloud transmission exported by Cerebro.

    Choose **Development → Hologram Voxel Detail…** before capture to select Standard, High, or Ultra resolution. Apple AR exports up to 15,000, 45,000, or 90,000 voxels respectively, with progressively smaller voxel faces. Higher settings create substantially larger USDZ assets.

    Preview locally (module loading requires HTTP):

    ```sh
    python3 serve.py
    ```

    Publish by copying this entire folder into a GitHub repository and enabling GitHub Pages. Do not open `index.html` directly from Finder.

    - Desktop/mobile browsers: interactive Three.js point cloud.
    - WebXR browsers supporting `immersive-ar`: the generated AR button starts passthrough AR.
    - iPhone, iPad, and Apple Vision Pro: **Place hologram in AR** opens the bundled USDZ using Apple AR Quick Look.

    The CDN dependency is pinned to Three.js 0.180.0. Vendor it locally before long-term archival if the page must work offline.
    """#

    static let movieReadme = #"""
    # ROB Moving Voxel Hologram

    A synchronized RGB-D voxel recording with microphone audio, interactive Three.js playback, and an animated USDZ for Apple AR Quick Look.

    Choose **Development → Hologram Voxel Detail…** before recording to select Standard, High, or Ultra resolution. Apple AR movie exports use up to 2,000, 4,000, or 7,000 animated voxels per frame respectively, with progressively smaller voxel faces.

    Preview locally (camera AR and JavaScript modules require HTTP):

    ```sh
    python3 serve.py
    ```

    Then open `http://localhost:8080` on this Mac or the printed Wi-Fi address on an iPhone. Copy the complete folder to a GitHub Pages repository when publishing; the binary, audio, USDZ, JSON, JavaScript, and HTML files must remain together.

    - Tap **Play message** to start synchronized browser animation and audio.
    - Tap **Watch in Apple AR** on iPhone, iPad, or Apple Vision Pro for animated USDZ playback with audio.
    - Non-Apple browsers with immersive WebXR support receive a passthrough AR button.

    The AR copy intentionally uses fewer voxels and a compact 27-color RGB palette to keep mobile playback responsive. The browser copy retains the denser recorded RGB point frames.
    """#

    static let localServer = #"""
    #!/usr/bin/env python3
    """Local ROB hologram server with the MIME type required by AR Quick Look."""
    import http.server
    import socketserver
    import socket

    http.server.SimpleHTTPRequestHandler.extensions_map.update({
        ".usdz": "model/vnd.usdz+zip",
        ".js": "text/javascript; charset=utf-8",
        ".bin": "application/octet-stream",
    })
    with socketserver.TCPServer(("0.0.0.0", 8080), http.server.SimpleHTTPRequestHandler) as server:
        print("This Mac: http://localhost:8080")
        try:
            print("iPhone on the same Wi-Fi: http://%s:8080" % socket.gethostbyname(socket.gethostname()))
        except OSError:
            pass
        server.serve_forever()
    """#
}
