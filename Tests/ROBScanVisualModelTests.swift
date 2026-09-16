import AppKit
import SceneKit
import Metal

@main struct ROBScanVisualModelTests {
    @MainActor static func main() throws {
        let start = Date()
        let robot = ROBScanVisualModel.makeRobot()
        let firstLoad = Date().timeIntervalSince(start)
        let repeatStart = Date()
        _ = ROBScanVisualModel.makeRobot()
        print(String(format: "Captured model load: first %.3fs, cached %.3fs", firstLoad, Date().timeIntervalSince(repeatStart)))
        func node(_ name: String) -> SCNNode {
            guard let result = robot.childNode(withName: name, recursively: true) else { fatalError("Missing \(name)") }
            return result
        }
        let flipper = node("Base Lift Flipper Assembly")
        precondition(flipper.parent?.name == "Drive Base Assembly")
        precondition(flipper.childNodes.count == 2)
        for side in ["Left", "Right"] {
            let axle = node("\(side) Tri-Wheel 3").worldPosition
            let pivot = flipper.worldPosition
            precondition(abs(axle.y - pivot.y) < 0.00001 && abs(axle.z - pivot.z) < 0.00001)
            let roller = node("\(side) Flipper End Roller")
            precondition(abs(roller.position.z + 0.33655 * 1.2) < 0.00001)
            precondition(node("\(side) Perforated UHMW Flipper").geometry != nil)
            _ = node("\(side) Camera Eye"); _ = node("\(side) ROB Speaker Cone")
            for index in 1...7 { _ = node("\(side) AMBER Joint \(index)") }
        }
        precondition(robot.childNode(withName: "Base Lift Flipper Blade", recursively: true) == nil)
        // Head pan rotates the entire head, including the optics and antennas.
        let head = node("Camera Head Pivot"), lens = node("Left Camera Eye")
        let capturedHead = node("Camera Head")
        precondition(capturedHead.geometry!.sources(for: .texcoord).first!.vectorCount > 1000)
        precondition(capturedHead.geometry!.firstMaterial!.diffuse.contents is NSImage)
        precondition(capturedHead.geometry!.firstMaterial!.lightingModel == .constant)
        var capturedTriangles = 0
        robot.enumerateChildNodes { child, _ in
            if child.geometry?.firstMaterial?.diffuse.contents is NSImage {
                capturedTriangles += child.geometry!.elements.reduce(0) { $0 + $1.primitiveCount }
            }
        }
        precondition(capturedTriangles > 100_000 && capturedTriangles < 150_000)
        let point = SCNVector3(0.06, 0, 0)
        let capturedBefore = capturedHead.convertPosition(point, to: nil)
        let baseBefore = node("Tri-Wheel Chassis").worldTransform
        let before = lens.worldPosition
        node("Neck Pan").eulerAngles.y = 0.6
        precondition(abs(lens.worldPosition.x - before.x) > 0.001)
        precondition(abs(capturedHead.convertPosition(point, to: nil).x - capturedBefore.x) > 0.001)
        precondition(SCNMatrix4EqualToMatrix4(node("Tri-Wheel Chassis").worldTransform, baseBefore))
        precondition(head.parent?.name == "Neck Pan")
        node("Neck Pan").eulerAngles.y = 0
        print("ROB shared mesh, flipper pivots, rollers, optics and articulated hierarchy passed")

        if CommandLine.arguments.count > 1 {
            let scene = SCNScene(); scene.rootNode.addChildNode(robot)
            scene.background.contents = NSColor(srgbRed: 0.035, green: 0.060, blue: 0.09, alpha: 1)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 38; camera.camera?.wantsHDR = true; camera.camera?.exposureOffset = -1
            camera.position = SCNVector3(1.5, 1.13, -2.7); camera.look(at: SCNVector3(0, 0.80, 0)); scene.rootNode.addChildNode(camera)
            for (position, intensity) in [(SCNVector3(1, 3, -3), 650.0), (SCNVector3(-2, 2, 1), 450.0)] {
                let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = intensity; light.position = position; scene.rootNode.addChildNode(light)
            }
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 120; scene.rootNode.addChildNode(ambient)
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); renderer.scene = scene; renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 1000), antialiasingMode: .multisampling4X)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
