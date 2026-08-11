import AppKit
import AVFoundation

/// Captures the newest synchronized RGB-D frame and exports a GitHub Pages-ready
/// Three.js "hologram message". The binary point format is intentionally tiny:
/// UInt32 count followed by count × (Float32 x/y/z + UInt8 r/g/b/a).
@objcMembers public final class ROBHologramExporter: NSObject {
    public static let shared = ROBHologramExporter()
    private let lock = NSLock()
    private var latestFrame: ROBDepthCloudFrame?

    public func capture(_ frame: ROBDepthCloudFrame) {
        lock.lock(); latestFrame = frame; lock.unlock()
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
                NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("index.html")])
            } catch {
                self?.presentError(error.localizedDescription)
            }
        }
    }

    private func export(frame: ROBDepthCloudFrame, to folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let points = makePoints(frame: frame)
        guard !points.isEmpty else { throw ExportError.noDepth }
        try binary(points).write(to: folder.appendingPathComponent("hologram.bin"), options: .atomic)
        try metadata(pointCount: points.count).write(to: folder.appendingPathComponent("hologram.json"), atomically: true, encoding: .utf8)
        try Self.indexHTML.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Self.viewerJavaScript.write(to: folder.appendingPathComponent("viewer.js"), atomically: true, encoding: .utf8)
        try Self.styles.write(to: folder.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
        try Self.readme.write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let usda = folder.appendingPathComponent("hologram.usda")
        try usd(points).write(to: usda, atomically: true, encoding: .utf8)
        try createUSDZ(from: usda, at: folder.appendingPathComponent("hologram.usdz"))
        try? fileManager.removeItem(at: usda)
    }

    private struct Point { let x, y, z: Float; let r, g, b: UInt8 }

    private func makePoints(frame: ROBDepthCloudFrame) -> [Point] {
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
        output.reserveCapacity((width / 3) * (height / 3))
        for y in Swift.stride(from: 0, to: height, by: 3) {
            for x in Swift.stride(from: 0, to: width, by: 3) {
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

    private func metadata(pointCount: Int) -> String {
        """
        {"format":"ROB-HOLOGRAM-1","pointCount":\(pointCount),"units":"meters","coordinateSystem":"camera-right-up-back","capturedAt":"\(ISO8601DateFormatter().string(from: Date()))"}
        """
    }

    private func usd(_ points: [Point]) -> String {
        let positions = points.map { "(\($0.x), \($0.y), \($0.z))" }.joined(separator: ",\n")
        let colors = points.map { "(\(Float($0.r)/255), \(Float($0.g)/255), \(Float($0.b)/255))" }.joined(separator: ",\n")
        return """
        #usda 1.0
        (
            defaultPrim = "Hologram"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "Hologram" {
            def Points "Message" {
                point3f[] points = [\(positions)]
                color3f[] primvars:displayColor = [\(colors)]
                uniform token primvars:displayColor:interpolation = "vertex"
                float[] widths = [0.012]
                uniform token widths:interpolation = "constant"
            }
        }
        """
    }

    private func createUSDZ(from usda: URL, at destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/usdzip")
        process.currentDirectoryURL = usda.deletingLastPathComponent()
        process.arguments = [destination.path, usda.lastPathComponent]
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
        case noDepth, usdz(String)
        var errorDescription: String? {
            switch self { case .noDepth: return "The current depth image contains no usable points."
            case .usdz(let detail): return "Could not create the Apple AR asset: \(detail)" }
        }
    }
}

private extension ROBHologramExporter {
    static let indexHTML = #"""
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Message from ROB</title><link rel="stylesheet" href="styles.css"><script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.180.0/examples/jsm/"}}</script></head><body><main><div id="stage"></div><section><h1>Message from ROB</h1><p>A captured moment carried by a droid.</p><a class="apple-ar" rel="ar" href="hologram.usdz"><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/%3E" alt=""><span>Place hologram in AR</span></a><button id="replay">Replay transmission</button><p id="status" role="status">Loading hologram…</p></section></main><script type="module" src="viewer.js"></script></body></html>
    """#

    static let viewerJavaScript = #"""
    import * as THREE from 'three';
    import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
    import { ARButton } from 'three/addons/webxr/ARButton.js';
    const stage=document.querySelector('#stage'), status=document.querySelector('#status');
    const renderer=new THREE.WebGLRenderer({antialias:true,alpha:true}); renderer.setPixelRatio(Math.min(devicePixelRatio,2)); renderer.xr.enabled=true; stage.append(renderer.domElement);
    const scene=new THREE.Scene(), camera=new THREE.PerspectiveCamera(55,1,.01,20); camera.position.set(0,0.1,2);
    const controls=new OrbitControls(camera,renderer.domElement); controls.enableDamping=true; controls.target.set(0,0,-1.5);
    const root=new THREE.Group(); scene.add(root);
    const pulse=new THREE.PointLight(0x45e8ff,3,5); pulse.position.set(0,1,1); scene.add(pulse);
    const response=await fetch('hologram.bin'), buffer=await response.arrayBuffer(), view=new DataView(buffer), count=view.getUint32(0,true);
    const positions=new Float32Array(count*3), colors=new Uint8Array(count*4); let o=4;
    for(let i=0;i<count;i++){positions[i*3]=view.getFloat32(o,true);positions[i*3+1]=view.getFloat32(o+4,true);positions[i*3+2]=view.getFloat32(o+8,true);colors.set(new Uint8Array(buffer,o+12,4),i*4);o+=16;}
    const geometry=new THREE.BufferGeometry(); geometry.setAttribute('position',new THREE.BufferAttribute(positions,3)); geometry.setAttribute('color',new THREE.BufferAttribute(colors,4,true)); geometry.computeBoundingSphere();
    const cloud=new THREE.Points(geometry,new THREE.PointsMaterial({size:.014,vertexColors:true,transparent:true,opacity:.94,sizeAttenuation:true,depthWrite:false,blending:THREE.AdditiveBlending})); root.add(cloud);
    const center=geometry.boundingSphere.center; root.position.sub(center); root.position.z=-1.4; status.textContent=`Transmission ready • ${count.toLocaleString()} points`;
    function replay(){cloud.material.opacity=0; const start=performance.now(); function step(t){cloud.material.opacity=Math.min(.94,(t-start)/1400); if(cloud.material.opacity<.94)requestAnimationFrame(step)} requestAnimationFrame(step)} document.querySelector('#replay').onclick=replay; replay();
    if(navigator.xr){document.body.append(ARButton.createButton(renderer,{optionalFeatures:['dom-overlay'],domOverlay:{root:document.body}}));}
    function resize(){const w=stage.clientWidth,h=stage.clientHeight;renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix()} addEventListener('resize',resize);resize();
    renderer.setAnimationLoop((time)=>{controls.update();pulse.intensity=2.5+Math.sin(time*.004);renderer.render(scene,camera)});
    """#

    static let styles = #"""
    :root{color-scheme:dark;font-family:ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif;background:#020811;color:#dffcff}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 50% 30%,#08324b,#020811 65%)}main{min-height:100svh;display:grid;grid-template-rows:minmax(55svh,1fr) auto}#stage{min-height:55svh;touch-action:none}section{padding:1rem 1.25rem 2rem;text-align:center}h1{margin:.2rem;font-size:clamp(1.8rem,5vw,3.2rem);text-shadow:0 0 18px #34d9ff}p{color:#9ed5df}.apple-ar,button{display:inline-flex;align-items:center;margin:.4rem;padding:.8rem 1.1rem;border:1px solid #43dcff;border-radius:999px;background:#06273a;color:white;text-decoration:none;font:inherit}.apple-ar img{width:1px;height:1px}button{cursor:pointer}@media(orientation:landscape){main{grid-template-columns:2fr 1fr;grid-template-rows:100svh}section{align-self:center}}
    """#

    static let readme = #"""
    # ROB Hologram Message

    A static Three.js RGB point-cloud transmission exported by Cerebro.

    Preview locally (module loading requires HTTP):

    ```sh
    python3 -m http.server 8080
    ```

    Publish by copying this entire folder into a GitHub repository and enabling GitHub Pages. Do not open `index.html` directly from Finder.

    - Desktop/mobile browsers: interactive Three.js point cloud.
    - WebXR browsers supporting `immersive-ar`: the generated AR button starts passthrough AR.
    - iPhone, iPad, and Apple Vision Pro: **Place hologram in AR** opens the bundled USDZ using Apple AR Quick Look.

    The CDN dependency is pinned to Three.js 0.180.0. Vendor it locally before long-term archival if the page must work offline.
    """#
}
