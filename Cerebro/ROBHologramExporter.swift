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
        try Self.localServer.write(to: folder.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
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
        // AR Quick Look does not consistently draw UsdGeomPoints. Export a
        // real, double-sided quad mesh instead. Limit the AR copy so iPhone
        // and Vision Pro can place it quickly while the web viewer retains all
        // points from hologram.bin.
        let arPoints = points.count > 10_000
            ? points.enumerated().compactMap { $0.offset.isMultiple(of: 3) ? $0.element : nil }
            : points
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
        let halfSize: Float = 0.006
        var positions: [String] = []
        var colors: [String] = []
        var counts: [String] = []
        var indices: [String] = []
        positions.reserveCapacity(arPoints.count * 4)
        colors.reserveCapacity(arPoints.count * 4)
        counts.reserveCapacity(arPoints.count)
        indices.reserveCapacity(arPoints.count * 4)
        for (pointIndex, point) in arPoints.enumerated() {
            // Quick Look places the asset origin on a detected surface. Put
            // the lowest observed point just above y=0 and center horizontal
            // and depth extents around the placement origin.
            let x = point.x - centerX
            let y = max(point.y - minimumY, 0) + 0.03
            let z = point.z - centerZ
            positions.append("(\(x - halfSize), \(y - halfSize), \(z))")
            positions.append("(\(x + halfSize), \(y - halfSize), \(z))")
            positions.append("(\(x + halfSize), \(y + halfSize), \(z))")
            positions.append("(\(x - halfSize), \(y + halfSize), \(z))")
            let color = "(\(Float(point.r)/255), \(Float(point.g)/255), \(Float(point.b)/255))"
            colors.append(contentsOf: repeatElement(color, count: 4))
            counts.append("4")
            let base = pointIndex * 4
            indices.append(contentsOf: ["\(base)", "\(base + 1)", "\(base + 2)", "\(base + 3)"])
        }
        return """
        #usda 1.0
        (
            defaultPrim = "Hologram"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "Hologram" {
            # Keep the first AR placement comfortably inspectable on a phone.
            # Quick Look still allows the viewer to pinch the message larger.
            float3 xformOp:scale = (0.45, 0.45, 0.45)
            uniform token[] xformOpOrder = ["xformOp:scale"]

            def Material "RGBPointMaterial" {
                token outputs:surface.connect = </Hologram/RGBPointMaterial/PreviewSurface.outputs:surface>

                def Shader "DisplayColor" {
                    uniform token info:id = "UsdPrimvarReader_float3"
                    token inputs:varname = "displayColor"
                    float3 outputs:result
                }

                def Shader "PreviewSurface" {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </Hologram/RGBPointMaterial/DisplayColor.outputs:result>
                    color3f inputs:emissiveColor.connect = </Hologram/RGBPointMaterial/DisplayColor.outputs:result>
                    float inputs:metallic = 0
                    float inputs:roughness = 1
                    token outputs:surface
                }
            }

            def Mesh "Message" {
                uniform token subdivisionScheme = "none"
                bool doubleSided = true
                rel material:binding = </Hologram/RGBPointMaterial>
                int[] faceVertexCounts = [\(counts.joined(separator: ","))]
                int[] faceVertexIndices = [\(indices.joined(separator: ","))]
                point3f[] points = [\(positions.joined(separator: ",\n"))]
                color3f[] primvars:displayColor = [\(colors.joined(separator: ",\n"))]
                uniform token primvars:displayColor:interpolation = "vertex"
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
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover,user-scalable=no"><meta name="theme-color" content="#020811"><title>Message from ROB</title><link rel="stylesheet" href="styles.css"><script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.180.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.180.0/examples/jsm/"}}</script></head>
    <body><main><div id="stage" aria-label="Interactive RGB point cloud"></div><header><div><h1>Message from ROB</h1><p id="status" role="status">Loading hologram…</p></div><button id="fullscreen" aria-label="Enter full screen">⛶</button></header><nav aria-label="Hologram controls"><a class="apple-ar" rel="ar" href="hologram.usdz"><img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='44' height='44' viewBox='0 0 44 44'%3E%3Cpath fill='none' stroke='%2343dcff' stroke-width='2' d='m22 4 16 9v18l-16 9-16-9V13zM6 13l16 9 16-9M22 22v18'/%3E%3C/svg%3E" alt=""><span>View in Apple AR</span></a><button id="reset">Reset view</button><button id="replay">Replay</button></nav><aside id="hint">Drag to orbit · Pinch to zoom · Two fingers to pan</aside></main><script type="module" src="viewer.js"></script></body></html>
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

    static let styles = #"""
    :root{color-scheme:dark;font-family:ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif;background:#020811;color:#eaffff}*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}html,body,main{width:100%;height:100%;height:100svh;margin:0;overflow:hidden}body{background:radial-gradient(circle at 50% 42%,#0a3449,#020811 68%);overscroll-behavior:none}#stage{position:absolute;inset:0;touch-action:none}#stage canvas{display:block;width:100%;height:100%}header{position:fixed;z-index:5;top:0;left:0;right:0;display:flex;justify-content:space-between;align-items:flex-start;padding:max(.75rem,env(safe-area-inset-top)) max(.85rem,env(safe-area-inset-right)) .5rem max(.85rem,env(safe-area-inset-left));pointer-events:none;background:linear-gradient(#020811cc,transparent)}h1{margin:0;font-size:clamp(1.05rem,4.5vw,1.65rem);text-shadow:0 0 14px #34d9ff}p{margin:.2rem 0;color:#9ed5df;font-size:.78rem}button,.apple-ar{min-height:48px;border:1px solid #43dcff;border-radius:14px;background:#06273aeF;color:white;text-decoration:none;font:600 .9rem/1 system-ui;display:inline-flex;align-items:center;justify-content:center;gap:.35rem;padding:.7rem .9rem;box-shadow:0 3px 18px #0008;cursor:pointer;pointer-events:auto}.apple-ar{background:#075270}.apple-ar img{width:25px;height:25px}#fullscreen{min-width:48px;padding:0;font-size:1.4rem}nav{position:fixed;z-index:10;left:0;right:0;bottom:0;display:flex;justify-content:center;gap:.45rem;padding:.55rem max(.65rem,env(safe-area-inset-right)) max(.65rem,env(safe-area-inset-bottom)) max(.65rem,env(safe-area-inset-left));background:linear-gradient(transparent,#020811 30%)}nav>*{flex:0 1 auto}#hint{position:fixed;z-index:4;left:50%;bottom:5.3rem;transform:translateX(-50%);white-space:nowrap;padding:.45rem .7rem;border-radius:999px;background:#0009;color:#bdebf2;font-size:.72rem;transition:opacity .5s;pointer-events:none}.hidden{opacity:0}.webxr-ar{position:static!important;margin:0!important;width:auto!important}@media(max-width:520px){nav{display:grid;grid-template-columns:1.6fr 1fr 1fr}.apple-ar,button{padding:.65rem .55rem;font-size:.78rem}}@media(orientation:landscape) and (max-height:520px){header{right:auto;max-width:45%}nav{left:auto;top:0;bottom:0;width:min(220px,34vw);padding:max(.65rem,env(safe-area-inset-top)) max(.65rem,env(safe-area-inset-right)) max(.65rem,env(safe-area-inset-bottom)) .4rem;display:flex;flex-direction:column;justify-content:center;background:linear-gradient(90deg,transparent,#020811 35%)}nav>*{width:100%}#hint{bottom:1rem}}
    """#

    static let readme = #"""
    # ROB Hologram Message

    A static Three.js RGB point-cloud transmission exported by Cerebro.

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
