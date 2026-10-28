import Foundation
import simd
import AppKit
import SceneKit

@main struct ROBRoomSpatialFixtureTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) {
            precondition(value(), reason); checks += 1
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 1e-5 }
        let device = UUID(), epoch = UUID(), wall = 1_800_000_000_000.0
        func frame(_ sequence: UInt64, x: Float = 0, y: Float = 0, yaw: Float = 0,
                   deviceID: UUID? = nil, sent: Double? = nil, fragment: ROBRoomMapFragment? = nil) -> ROBLidarScanFrame {
            .init(deviceID: deviceID ?? device, sequence: sequence, sentAtMilliseconds: UInt64(sent ?? wall),
                  x:x, y:y, z:0, yaw:yaw, pitch:0, roll:0,
                  points:(0..<16).map { .init(distanceMeters:2, angleRadians:Float($0)*2 * .pi/16) }, mapFragment:fragment)
        }
        func fragment(_ revision: UInt64 = 1, epochID: UUID? = nil, captured: Double? = nil) -> ROBRoomMapFragment {
            .init(epoch:epochID ?? epoch, revision:revision, capturedAtMilliseconds:captured ?? wall,
                  width:2,height:2,resolutionX:0.1,resolutionY:0.2,originX:-0.1,originY:-0.2,offset:0,
                  cells:Data([127,0,255,127]))
        }
        let store = ROBRoomSpatialStore()
        check(store.consume(frame(1,fragment:fragment()),now:10,wallMilliseconds:wall), "accept sensor evidence")
        check(store.map != nil && store.poseIsFresh(at:10), "complete map + fresh pose")
        check(!store.consume(frame(1),now:10.1,wallMilliseconds:wall), "duplicate scan cannot refresh age")
        check(!store.poseIsFresh(at:10.751), "pose expires without a renderer renewal")
        check(store.mapIsFresh(at:25) && !store.mapIsFresh(at:25.01), "map independently expires")
        let firstGeneration = store.depthGeneration
        check(store.consume(frame(2,x:0.01),now:10.1,wallMilliseconds:wall), "small pose step")
        check(store.depthGeneration == firstGeneration, "subthreshold step does not repeatedly reset history")
        check(store.consume(frame(3,x:0.02),now:10.2,wallMilliseconds:wall), "second small step")
        check(store.consume(frame(4,x:0.03),now:10.3,wallMilliseconds:wall), "third small step")
        check(store.depthGeneration > firstGeneration, "cumulative manual displacement invalidates depth")
        let movedGeneration = store.depthGeneration
        check(store.consume(frame(5,x:0.03,yaw:0.04),now:10.4,wallMilliseconds:wall), "manual yaw update")
        check(store.depthGeneration > movedGeneration, "manual yaw invalidates depth")
        let yawGeneration = store.depthGeneration
        check(store.consume(frame(6,x:0.03,yaw:0.04),now:12,wallMilliseconds:wall), "reconnect same pose")
        check(store.depthGeneration > yawGeneration, "telemetry gap invalidates old depth even at same coordinates")
        check(!store.consume(frame(7,sent:wall-2001),now:12.1,wallMilliseconds:wall), "old source timestamp rejected")
        check(!store.consume(frame(7,sent:wall+501),now:12.1,wallMilliseconds:wall), "future source timestamp rejected")
        check(store.consume(frame(7,fragment:fragment(2)),now:12.2,wallMilliseconds:wall), "new raster revision")
        check(store.consume(frame(8,fragment:fragment(1)),now:12.3,wallMilliseconds:wall), "scan with old fragment")
        check(store.map?.revision == 2, "old fragment cannot roll back complete map")
        check(store.consume(frame(9,fragment:fragment(1,epochID:UUID())),now:12.4,wallMilliseconds:wall), "map reset")
        check(store.map?.epoch != epoch, "reset replaces frame identity")
        check(store.consume(frame(1,sent:wall+1),now:12.45,wallMilliseconds:wall+1), "same-device publisher restarts its sequence in a new authenticated session")
        check(store.map == nil, "publisher restart cannot retain its previous map before a new epoch arrives")
        check(store.consume(frame(1,deviceID:UUID()),now:12.5,wallMilliseconds:wall), "authenticated source replacement")
        check(store.map == nil, "never attach old publisher map to new pose")

        let map = ROBRoomMissionMap(epoch:epoch,revision:1,capturedAtMilliseconds:wall,width:2,height:2,
            resolutionX:0.1,resolutionY:0.2,originX:-0.1,originY:-0.2,cells:Data([127,0,255,127]))
        let rgba = [UInt8](ROBRoomSpatialGeometry.rasterRGBA(map)!)
        check(Array(rgba[0..<3]) == [245,158,65], "occupied top-left uses SDK negative sign + row flip")
        check(Array(rgba[12..<15]) == [65,65,76], "zero unknown remains visibly different from free")
        check(map.cells == Data([127,0,255,127]), "display does not edit mission evidence")
        var mount = matrix_identity_double4x4
        mount.columns.3 = SIMD4(-0.05,-0.013,0.185,1)
        let scan = frame(1,x:3,y:4,yaw:.pi/2)
        let transform = ROBRoomSpatialGeometry.mapToBase(scan:scan,lidarToBase:mount)
        let ahead = transform * SIMD4<Double>(3,6,0,1)
        check(near(ahead.x,1.95) && near(ahead.y,-0.013), "map +Y at yaw90 is two metres in front, including mount offset")
        check(near(ahead.z,0.008), "map remains on floor rather than scanner height")
        let hit = ROBRoomSpatialGeometry.laserPoint(.init(distanceMeters:2,angleRadians:0),lidarToBase:mount)
        check(near(hit.x,ahead.x) && near(hit.y,ahead.y) && near(hit.z,0.185), "scan hits align in XY but preserve physical laser plane")

        // Exercise production SceneKit layers without network, robot gateways,
        // controller grants or actuator adapters. A tabletop over free floor
        // must remain a separate elevated obstacle after room-map publication.
        _ = NSApplication.shared
        let view = SCNView(frame:NSRect(x:0,y:0,width:1100,height:800))
        view.scene = SCNScene(); view.scene!.background.contents = NSColor.black
        let referenceGround = SCNNode(geometry:SCNFloor()); referenceGround.name="Diagnostic reference ground"
        view.scene!.rootNode.addChildNode(referenceGround)
        let depth = SCNNode(); view.scene!.rootNode.addChildNode(depth)
        let tabletop = SCNNode(geometry:SCNBox(width:1.2,height:0.04,length:0.7,chamferRadius:0))
        tabletop.position = SCNVector3(0,0.8,-1.4); depth.addChildNode(tabletop)
        let layer = ROBRoomDiagnosticsLayer(sceneView:view,depthRoot:depth)
        let basis = simd_double4x4(columns:(SIMD4(0,0,-1,0),SIMD4(-1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,0,1)))
        func rows(_ m:simd_double4x4)->[NSNumber] {(0..<3).flatMap {r in (0..<4).map {NSNumber(value:m[$0][r])}}}
        var live = frame(1,sent:Date().timeIntervalSince1970*1000)
        live.mapFragment = .init(epoch:epoch,revision:1,capturedAtMilliseconds:Double(live.sentAtMilliseconds),
            width:24,height:24,resolutionX:0.25,resolutionY:0.25,originX:-3,originY:-3,offset:0,
            cells:Data((0..<576).map {i in
                let x=i%24, y=i/24
                if x<8 && y>=16 { return UInt8(255) }
                if x>=16 && y<8 { return UInt8(0) }
                return UInt8(127)
            }))
        check(ROBRoomSpatialStore.shared.consume(live), "production store accepts synthetic fixture")
        check(layer.refresh(baseToScene:rows(basis),lidarToBase:rows(mount)), "new pose requests old-depth invalidation")
        check(!layer.refresh(baseToScene:rows(basis),lidarToBase:rows(mount)), "stable pose retains current depth")
        let mapNode = view.scene!.rootNode.childNode(withName:"Accumulated lidar occupancy · ground plane only",recursively:true)!
        let laserNode = view.scene!.rootNode.childNode(withName:"Live RPLidar returns · model-assumed scanner mount",recursively:true)!
        let until = Date().addingTimeInterval(3)
        while mapNode.geometry == nil && Date() < until { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        check(mapNode.geometry != nil, "background raster is published")
        check(laserNode.geometry?.elements.first?.primitiveCount == 16, "all live hits rendered")
        check(tabletop.parent === depth && near(Double(tabletop.position.y),0.8) && !depth.isHidden, "free floor never removes tabletop depth")
        check(!mapNode.isHidden && !laserNode.isHidden, "fresh aligned layers visible")
        check(referenceGround.isHidden, "decorative floor cannot intersect or reflect the measured map")
        // Render the actual textured geometry from above. An asymmetric map
        // detects an upside-down texture that a symmetric room would conceal.
        let rasterScene = SCNScene()
        rasterScene.background.contents = NSColor.black
        let rasterNode = SCNNode(geometry:mapNode.geometry)
        rasterScene.rootNode.addChildNode(rasterNode)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection=true; camera.camera!.orthographicScale=3
        camera.position=SCNVector3(0,0,5); rasterScene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device:nil,options:nil)
        renderer.scene=rasterScene; renderer.pointOfView=camera
        let rasterImage = renderer.snapshot(atTime:0,with:CGSize(width:240,height:240),antialiasingMode:.none)
        let bitmap = NSBitmapImageRep(data:rasterImage.tiffRepresentation!)!
        let topLeft = bitmap.colorAt(x:40,y:40)!.usingColorSpace(.deviceRGB)!
        let bottomRight = bitmap.colorAt(x:200,y:200)!.usingColorSpace(.deviceRGB)!
        check(topLeft.redComponent > topLeft.blueComponent*1.5, "rendered top-left is occupied: UV orientation matches native map Y")
        check(abs(bottomRight.redComponent-bottomRight.blueComponent)<0.12, "rendered bottom-right is unknown, never free")
        if let path=ProcessInfo.processInfo.environment["ROB_ROOM_FIXTURE_RENDER_PATH"],
           let png=bitmap.representation(using:.png,properties:[:]) { try png.write(to:URL(fileURLWithPath:path)) }
        _ = layer.refresh(baseToScene:[],lidarToBase:[])
        check(mapNode.isHidden && laserNode.isHidden, "missing alignment never draws a fabricated sensor overlay")
        check(!referenceGround.isHidden, "reference grid returns when the room map is unavailable")
        layer.invalidate()
        print("Room spatial fixtures passed: \(checks) checks; metric alignment, occupancy signs, stale/reset/source handling, cumulative realignment and layered tabletop rendering; no hardware")
    }
}
