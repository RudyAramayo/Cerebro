import AppKit
import SceneKit
import simd

/// Bounded, nonactuating layered view. Geometry is robot-centred, with the
/// accumulated room transformed by measured SLAM, never integrated demand.
@objcMembers final class ROBRoomDiagnosticsLayer: NSObject {
    private weak var view: SCNView?
    private weak var referenceGround: SCNNode?
    private let depthRoot: SCNNode
    private let mapNode = SCNNode()
    private let laserNode = SCNNode()
    private let mapToggle = NSButton(checkboxWithTitle: "Floor map", target: nil, action: nil)
    private let laserToggle = NSButton(checkboxWithTitle: "Laser hits", target: nil, action: nil)
    private let depthToggle = NSButton(checkboxWithTitle: "Depth scan", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Waiting for authenticated RPLidar data")
    private let poseLabel = NSTextField(wrappingLabelWithString: "")
    private var renderedMapKey: String?
    private var pendingMap = false
    private var closed = false
    private var scanSequence: UInt64 = 0
    private var scanDevice: UUID?
    private var depthGeneration: UInt64?
    private var wasFresh = false
    private var alignmentAvailable = false
    private var roomCorners = [SCNVector3]()
    private let queue = DispatchQueue(label: "com.orbitusrobotics.Cerebro.room-map-display", qos: .utility)

    init(sceneView: SCNView, depthRoot: SCNNode) {
        view = sceneView; self.depthRoot = depthRoot
        referenceGround = sceneView.scene?.rootNode.childNode(withName: "Diagnostic reference ground", recursively: false)
        super.init()
        mapNode.name = "Accumulated lidar occupancy · ground plane only"
        laserNode.name = "Live RPLidar returns · model-assumed scanner mount"
        sceneView.scene?.rootNode.addChildNode(mapNode)
        sceneView.scene?.rootNode.addChildNode(laserNode)
        for toggle in [mapToggle, laserToggle, depthToggle] {
            toggle.state = .on; toggle.target = self; toggle.action = #selector(layersChanged)
            toggle.font = .systemFont(ofSize: 11)
        }
        let room = NSButton(title: "Room view", target: self, action: #selector(showRoom))
        let robot = NSButton(title: "Robot view", target: self, action: #selector(showRobot))
        let title = NSTextField(labelWithString: "Room + depth")
        title.font = .boldSystemFont(ofSize: 13)
        let controls = NSStackView(views: [mapToggle, laserToggle, depthToggle, room, robot])
        controls.spacing = 7
        let legend = NSTextField(wrappingLabelWithString: "Amber: occupied  ·  blue: free at laser height  ·  gray: unknown\nCyan: live laser returns  ·  RGB: depth surfaces")
        let alignment = NSTextField(wrappingLabelWithString: "Estimated sensor alignment · depth is needed above the laser plane")
        alignment.textColor = .systemYellow
        for label in [status, poseLabel, legend, alignment] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.maximumNumberOfLines = 2
        }
        status.setAccessibilityIdentifier("ROB.Diagnostics.RoomSensors.Status")
        let stack = NSStackView(views: [title, controls, status, poseLabel, legend, alignment])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        let panel = NSVisualEffectView()
        panel.material = .hudWindow; panel.blendingMode = .withinWindow; panel.state = .active
        panel.wantsLayer = true; panel.layer?.cornerRadius = 8
        panel.addSubview(stack); sceneView.addSubview(panel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: sceneView.topAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: sceneView.trailingAnchor, constant: -12),
            panel.widthAnchor.constraint(equalToConstant: 490),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10)
        ])
        layersChanged()
    }

    func invalidate() { closed = true; mapNode.removeFromParentNode(); laserNode.removeFromParentNode() }

    /// Returns true when depth history/in-flight projection must be discarded.
    /// Display-only affine matrices come from the SAME model basis as RGB-D.
    func refresh(baseToScene rows: [NSNumber], lidarToBase lidarRows: [NSNumber]) -> Bool {
        guard !closed else { return false }
        let store = ROBRoomSpatialStore.shared, now = ProcessInfo.processInfo.systemUptime
        let fresh = store.poseIsFresh(at: now)
        let clearDepth = depthGeneration != store.depthGeneration || (wasFresh && !fresh)
        depthGeneration = store.depthGeneration; wasFresh = fresh
        defer { layersChanged() }
        guard let scan = store.scan else {
            status.stringValue = "RPLidar: waiting for scan + SLAM pose · room map unavailable"
            poseLabel.stringValue = "Robot-centred view · no motion inferred from tread commands"
            return clearDepth
        }
        let scanAge = store.poseAge(at: now), mapAge = store.mapAge(at: now)
        let scanText = fresh ? String(format: "%d hits · %.0f ms", scan.points.count, scanAge*1000) : String(format: "stale %.1f s · hidden", scanAge)
        let mapText = store.map.map { String(format: "%d × %d · %.1f s%@", $0.width, $0.height, mapAge,
            store.mapIsFresh(at: now) ? "" : " · stale / hidden") } ?? "waiting for complete map"
        status.stringValue = "LASER: \(scanText)\nMAP: \(mapText)"
        status.textColor = fresh && store.mapIsFresh(at: now) ? .systemGreen : .systemYellow
        poseLabel.stringValue = String(format: "SLAM x %.2f m · y %.2f m · yaw %+.1f°", scan.x, scan.y, scan.yaw*180 / .pi)
        guard let baseToScene = Self.affine(rows), let lidarToBase = Self.affine(lidarRows) else {
            alignmentAvailable = false; roomCorners = []
            mapNode.geometry = nil; laserNode.geometry = nil; renderedMapKey = nil; scanSequence = 0
            poseLabel.stringValue += " · model alignment unavailable"
            return clearDepth
        }
        alignmentAvailable = true
        poseLabel.stringValue += String(format: "\nLaser height %.2f m · model estimate", lidarToBase.columns.3.z)
        laserNode.simdTransform = Self.floatMatrix(baseToScene * lidarToBase)
        if fresh, scanSequence != scan.sequence || scanDevice != scan.deviceID {
            let points = scan.points.map { p in
                let point = ROBRoomSpatialGeometry.laserPoint(p, lidarToBase: matrix_identity_double4x4)
                return SCNVector3(point.x, point.y, point.z)
            }
            let element = SCNGeometryElement(indices: Array(0..<UInt32(points.count)), primitiveType: .point)
            element.pointSize = 7; element.minimumPointScreenSpaceRadius = 2; element.maximumPointScreenSpaceRadius = 5
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)], elements: [element])
            let material = SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents = NSColor.cyan
            geometry.materials = [material]; laserNode.geometry = geometry
            scanSequence = scan.sequence; scanDevice = scan.deviceID
        }
        guard let map = store.map else {
            mapNode.geometry = nil; renderedMapKey = nil; roomCorners = []
            return clearDepth
        }
        mapNode.simdTransform = Self.floatMatrix(baseToScene * ROBRoomSpatialGeometry.mapToBase(scan: scan, lidarToBase: lidarToBase))
        let corners = Self.corners(map)
        roomCorners = corners.map { mapNode.convertPosition($0, to: nil) }
        let key = "\(scan.deviceID)/\(map.epoch)/\(map.revision)"
        // A resized/rebased raster must not momentarily inherit the previous
        // revision's geometry while its new texture is being constructed.
        if renderedMapKey != key { mapNode.geometry = nil }
        if renderedMapKey != key, !pendingMap {
            pendingMap = true
            // Texture construction is bounded to the one-million-cell wire cap
            // and runs off the control thread. There is only one pending job.
            queue.async { [weak self] in
                let image = Self.texture(map)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.pendingMap = false
                    let current = ROBRoomSpatialStore.shared
                    guard !self.closed, current.scan?.deviceID == scan.deviceID,
                          current.map?.epoch == map.epoch, current.map?.revision == map.revision else { return }
                    guard let image else { return }
                    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners),
                        SCNGeometrySource(textureCoordinates: [CGPoint(x:0,y:1), CGPoint(x:1,y:1), CGPoint(x:1,y:0), CGPoint(x:0,y:0)])],
                        elements: [SCNGeometryElement(indices: [UInt16(0),1,2,0,2,3], primitiveType: .triangles)])
                    let material = SCNMaterial(); material.lightingModel = .constant; material.isDoubleSided = true
                    material.diffuse.contents = image; material.diffuse.magnificationFilter = .nearest
                    material.diffuse.minificationFilter = .nearest
                    geometry.materials = [material]; self.mapNode.geometry = geometry; self.renderedMapKey = key
                    self.layersChanged()
                }
            }
        }
        return clearDepth
    }

    @objc private func layersChanged() {
        let store = ROBRoomSpatialStore.shared, now = ProcessInfo.processInfo.systemUptime
        mapNode.isHidden = mapToggle.state != .on || !alignmentAvailable || !store.poseIsFresh(at: now) || !store.mapIsFresh(at: now)
        laserNode.isHidden = laserToggle.state != .on || !alignmentAvailable || !store.poseIsFresh(at: now)
        // The provisional display gauge may tilt the ground relative to the
        // original decorative y=0 plane. Never let that plane cut through or
        // reflect the actual occupancy layer and its sensor observations.
        referenceGround?.isHidden = !mapNode.isHidden && mapNode.geometry != nil
        depthRoot.isHidden = depthToggle.state != .on
    }

    @objc private func showRobot() {
        guard let view, let camera = view.pointOfView else { return }
        camera.position = SCNVector3(1.6,1.45,-3.1)
        camera.look(at: SCNVector3(0,0.85,0)); view.defaultCameraController.target = SCNVector3(0,0.78,0)
    }

    @objc private func showRoom() {
        guard !mapNode.isHidden, !roomCorners.isEmpty, let view, let camera = view.pointOfView else { return }
        let xs = roomCorners.map(\.x), zs = roomCorners.map(\.z)
        let center = SCNVector3((xs.min()!+xs.max()!)/2,0,(zs.min()!+zs.max()!)/2)
        let extent = max(3, xs.max()!-xs.min()!, zs.max()!-zs.min()!)
        camera.position = SCNVector3(center.x+extent*0.25, extent*1.1, center.z-extent*0.8)
        camera.look(at: center); view.defaultCameraController.target = center
    }

    @nonobjc private static func affine(_ rows: [NSNumber]) -> simd_double4x4? {
        guard rows.count == 12, rows.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
        var m = matrix_identity_double4x4
        for row in 0..<3 { for column in 0..<4 { m[column][row] = rows[row*4+column].doubleValue } }
        guard abs(simd_determinant(m)) > 1e-9 else { return nil }; return m
    }
    @nonobjc private static func floatMatrix(_ m: simd_double4x4) -> simd_float4x4 {
        .init(columns:(SIMD4<Float>(m.columns.0),SIMD4<Float>(m.columns.1),SIMD4<Float>(m.columns.2),SIMD4<Float>(m.columns.3)))
    }
    @nonobjc private static func corners(_ map: ROBRoomMissionMap) -> [SCNVector3] {
        let x = map.originX, y = map.originY, w = Double(map.width)*map.resolutionX, h = Double(map.height)*map.resolutionY
        return [SCNVector3(x,y,0),SCNVector3(x+w,y,0),SCNVector3(x+w,y+h,0),SCNVector3(x,y+h,0)]
    }
    @nonobjc private static func texture(_ map: ROBRoomMissionMap) -> CGImage? {
        guard let rgba = ROBRoomSpatialGeometry.rasterRGBA(map), let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: map.width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
