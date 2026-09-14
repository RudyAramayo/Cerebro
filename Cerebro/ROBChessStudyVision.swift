import AppKit
import CoreImage
import CoreMedia
import ImageIO
import Vision

struct ROBChessRaster {
    let image: CGImage
    let width: Int
    let height: Int
    let rgba: [UInt8] // top-left row first, R/G/B/A
    init(image: CGImage) throws {
        guard image.width >= 64, image.height >= 64, image.width <= 4096, image.height <= 4096 else {
            throw ROBChessStudyError.invalid("Use an image between 64 and 4096 pixels on each side.")
        }
        let width = image.width, height = image.height
        self.width = width; self.height = height; self.image = image
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let rendered = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard rendered else { throw ROBChessStudyError.invalid("Could not read the image pixels.") }
        rgba = bytes
    }
    static func load(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 40_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:2048
              ] as CFDictionary) else { throw ROBChessStudyError.invalid("Could not open that image.") }
        return try Self(image: image)
    }
    func encoded(_ type: CFString = "public.jpeg" as CFString) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data,type,1,nil) else {
            throw ROBChessStudyError.invalid("Could not create an image encoder.")
        }
        CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:0.94] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ROBChessStudyError.invalid("Image encoding failed.") }
        return data as Data
    }
    func rectified(map: ROBChessBoardMap, size: Int = 512) throws -> Self {
        guard size >= 64, size <= 1024 else { throw ROBChessStudyError.invalid("Invalid board output size.") }
        let minEdge = (0..<4).map { i -> Double in
            let a = map.corners[i], b = map.corners[(i+1)%4]
            return hypot((a.x-b.x)*Double(width),(a.y-b.y)*Double(height))
        }.min() ?? 0
        guard minEdge >= 160 else { throw ROBChessStudyError.invalid("Move the view closer: the shortest board edge needs at least 160 pixels.") }
        var output = [UInt8](repeating:255,count:size*size*4)
        for y in 0..<size { for x in 0..<size {
            let p = map.imagePoint(u:(Double(x)+0.5)/Double(size),v:(Double(y)+0.5)/Double(size))
            let sx = max(0,min(Double(width-1),p.x*Double(width)-0.5))
            let sy = max(0,min(Double(height-1),p.y*Double(height)-0.5))
            let x0 = Int(sx), y0 = Int(sy), x1 = min(width-1,x0+1), y1 = min(height-1,y0+1)
            let fx = sx-Double(x0), fy = sy-Double(y0)
            for c in 0..<3 {
                let top = Double(rgba[(y0*width+x0)*4+c])*(1-fx)+Double(rgba[(y0*width+x1)*4+c])*fx
                let bottom = Double(rgba[(y1*width+x0)*4+c])*(1-fx)+Double(rgba[(y1*width+x1)*4+c])*fx
                output[(y*size+x)*4+c] = UInt8(clamping:Int((top*(1-fy)+bottom*fy).rounded()))
            }
        }}
        let data = Data(output) as CFData
        guard let provider = CGDataProvider(data:data),
              let image = CGImage(width:size,height:size,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:size*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw ROBChessStudyError.invalid("Could not rectify the board.")
        }
        return try Self(image:image)
    }
    func evidence() -> ROBChessEvidence {
        var descriptors = [[Float]]()
        for square in 0..<64 {
            let file = square%8, row = 7-square/8
            var values = [Float]()
            // Low-resolution spatial color appearance; avoid the outer 12% of each square.
            for y in 0..<10 { for x in 0..<10 {
                let u = (Double(file)+0.12+0.76*(Double(x)+0.5)/10)/8
                let v = (Double(row)+0.12+0.76*(Double(y)+0.5)/10)/8
                let px = min(width-1,Int(u*Double(width))), py = min(height-1,Int(v*Double(height)))
                let i = (py*width+px)*4
                values += [Float(rgba[i])/255,Float(rgba[i+1])/255,Float(rgba[i+2])/255]
            }}
            descriptors.append(values)
        }
        return ROBChessEvidence(descriptors:descriptors)
    }
    func hasVisibleHand() -> Bool {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        do {
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
            return (request.results ?? []).contains { observation in
                guard let points = try? observation.recognizedPoints(.all) else { return false }
                return points.values.filter { $0.confidence > 0.35 }.count >= 3
            }
        } catch {
            // This is only an additional review cue, never an execution safety gate.
            return false
        }
    }
}

struct ROBChessStudyFrame {
    let id: UUID
    let capturedAt: Date
    let receivedUptime: TimeInterval
    let source: String
    let raster: ROBChessRaster
    let handVisible: Bool
    let depth: ROBChessStudyDepth?
    init(raster: ROBChessRaster, source: String, depth: ROBChessStudyDepth? = nil) {
        id = UUID(); capturedAt = Date(); receivedUptime = ProcessInfo.processInfo.systemUptime
        self.raster = raster; self.source = source; handVisible = raster.hasVisibleHand()
        self.depth = depth
    }
}

struct ROBChessStudyDepth: Codable {
    let width: Int
    let height: Int
    let millimetersLittleEndian: Data
    let fx: Double?
    let fy: Double?
    let cx: Double?
    let cy: Double?
    let cameraSequence: UInt64
    let cameraTimestampNanoseconds: UInt64
    var valid: Bool {
        (1...4096).contains(width) && (1...4096).contains(height) &&
            millimetersLittleEndian.count == width*height*2
    }
    func point(x:Int,y:Int) -> SIMD3<Double>? {
        guard valid, (0..<width).contains(x), (0..<height).contains(y),
              let fx,let fy,let cx,let cy,fx.isFinite,fy.isFinite,cx.isFinite,cy.isFinite,fx>0,fy>0 else { return nil }
        let i = (y*width+x)*2
        let z = Double(UInt16(millimetersLittleEndian[i]) | UInt16(millimetersLittleEndian[i+1])<<8)/1000
        guard (0.15...5).contains(z) else { return nil }
        return SIMD3((Double(x)-cx)*z/fx,(Double(y)-cy)*z/fy,z)
    }
    /// Robust camera-frame board plane from known empty-square centers. This
    /// is an appearance cue, not robot extrinsics or a certified grasp surface.
    func heights(map:ROBChessBoardMap,position:ROBChessPosition) -> [Double?]? {
        var points = [SIMD3<Double>]()
        for square in 0..<64 where position.board[square] == "." {
            let p = map.imagePoint(u:(Double(square%8)+0.5)/8,v:(Double(7-square/8)+0.5)/8)
            if let p = point(x:Int(p.x*Double(width)),y:Int(p.y*Double(height))) { points.append(p) }
        }
        guard points.count >= 12 else { return nil }
        func fit(_ points:[SIMD3<Double>]) -> [Double]? {
            var m = [[Double]](repeating:[Double](repeating:0,count:4),count:3)
            for p in points {
                let a = [p.x,p.y,1.0]
                for i in 0..<3 {
                    for j in 0..<3 { m[i][j] += a[i]*a[j] }
                    m[i][3] += a[i]*p.z
                }
            }
            for k in 0..<3 {
                let pivot = (k..<3).max { abs(m[$0][k]) < abs(m[$1][k]) }!
                guard abs(m[pivot][k]) > 1e-8 else { return nil }
                m.swapAt(k,pivot); let scale = m[k][k]
                for j in k...3 { m[k][j] /= scale }
                for i in 0..<3 where i != k { let factor = m[i][k]; for j in k...3 { m[i][j] -= factor*m[k][j] } }
            }
            return m.map { $0[3] }
        }
        guard let first = fit(points) else { return nil }
        points = points.filter { abs($0.z-first[0]*$0.x-first[1]*$0.y-first[2]) < 0.012 }
        guard points.count >= 12, let plane = fit(points) else { return nil }
        let normal = sqrt(plane[0]*plane[0]+plane[1]*plane[1]+1)
        let residual = points.reduce(0.0) { $0 + abs($1.z-plane[0]*$1.x-plane[1]*$1.y-plane[2])/normal }/Double(points.count)
        guard residual < 0.006 else { return nil }
        return (0..<64).map { square in
            var heights = [Double]()
            for y in 0..<9 { for x in 0..<9 {
                let p = map.imagePoint(u:(Double(square%8)+0.1+Double(x)*0.1)/8,
                                      v:(Double(7-square/8)+0.1+Double(y)*0.1)/8)
                if let p = point(x:Int(p.x*Double(width)),y:Int(p.y*Double(height))) {
                    let h = (plane[0]*p.x+plane[1]*p.y+plane[2]-p.z)/normal*1000
                    if h >= -15 && h <= 200 { heights.append(max(0,h)) }
                }
            }}
            guard heights.count >= 20 else { return nil }
            heights.sort()
            return heights[Int(Double(heights.count-1)*0.90)]
        }
    }
}

extension Notification.Name {
    static let robChessStudyDemandDidChange = Notification.Name("ROBChessStudyDemandDidChange")
}

/// Capture-only consumer; one pending frame, maximum 2 FPS. No actuator dependencies.
@objcMembers final class ROBChessStudyLiveSource: NSObject {
    static let shared = ROBChessStudyLiveSource()
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"com.orbitusrobotics.chess-study-frames",qos:.utility)
    private let context = CIContext(options:[.cacheIntermediates:false])
    private var requested = false
    private var agentRequested = false
    private var busy = false
    private var generation: UInt64 = 0
    private var lastAdmission: TimeInterval = 0
    @nonobjc var onFrame: ((ROBChessStudyFrame) -> Void)?
    @nonobjc var onError: ((String) -> Void)?
    @nonobjc var latestFrame: ROBChessStudyFrame?
    @nonobjc var onAgentFrame: ((ROBChessStudyFrame) -> Void)?
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return requested || agentRequested }
    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        lock.lock(); requested = active; generation &+= 1; lock.unlock()
        NotificationCenter.default.post(name:.robChessStudyDemandDidChange,object:self)
    }
    func setAgentActive(_ active:Bool) {
        precondition(Thread.isMainThread)
        lock.lock(); agentRequested = active; generation &+= 1; lock.unlock()
        NotificationCenter.default.post(name:.robChessStudyDemandDidChange,object:self)
    }
    @nonobjc func offer(_ sample: CMSampleBuffer, depth:ROBChessStudyDepth? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard (requested || agentRequested), !busy, now-lastAdmission >= 0.5 else { lock.unlock(); return }
        busy = true; lastAdmission = now; let epoch = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<ROBChessStudyFrame,Error> = Result {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw ROBChessStudyError.invalid("Main-camera frame has no pixels.")
                }
                let input = CIImage(cvPixelBuffer:buffer)
                guard let image = self.context.createCGImage(input,from:input.extent) else {
                    throw ROBChessStudyError.invalid("Could not read the main-camera image.")
                }
                let aligned = depth.flatMap { $0.valid && $0.width == image.width && $0.height == image.height ? $0 : nil }
                return try ROBChessStudyFrame(raster:ROBChessRaster(image:image),source:"Cerebro main camera",depth:aligned)
            }
            DispatchQueue.main.async {
                self.lock.lock()
                self.busy = false
                let current = (self.requested || self.agentRequested) && self.generation == epoch && ProcessInfo.processInfo.systemUptime-now < 2
                let deliverUI = self.requested
                self.lock.unlock()
                guard current else { return }
                switch result {
                case .success(let frame):
                    self.latestFrame = frame; self.onAgentFrame?(frame)
                    if deliverUI { self.onFrame?(frame) }
                case .failure(let error): self.onError?(error.localizedDescription)
                }
            }
        }
    }
}
