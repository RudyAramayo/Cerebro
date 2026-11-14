import AppKit
import AVFoundation

/// Latest-only references to the running streams. No window, detector, camera
/// reconfiguration, disk capture or extra JPEG encoder runs on frame arrival.
final class ROBLocalObservationStore {
    static let shared = ROBLocalObservationStore()
    private let lock = NSLock()
    private let encoder = DispatchQueue(label: "rob.local-control.frame-encoding", qos: .userInitiated)
    private let depthEncoder = DispatchQueue(label: "rob.local-control.depth-copy", qos: .userInitiated)
    private let context = CIContext()
    private var frames: [String: CameraFrameSet] = [:]
    private var panorama: (jpeg: Data, received: Double, sequence: UInt64, generation: UInt64)?
    private var received: [String: UInt64] = [:]
    private var started: [String: Double] = [:]
    private var arrivals: [String: [Double]] = [:]
    private var encodeBusy = false
    private var depthBusy = false

    func offer(_ frame: CameraFrameSet, role: CameraRole) {
        let key = role == .face ? "front" : "belly"
        lock.lock(); defer { lock.unlock() }
        frames[key] = frame; count(key)
    }
    func offerPanorama(jpeg: Data, receivedAt: Date, sequence: UInt64, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        panorama = (jpeg, receivedAt.timeIntervalSince1970*1000, sequence, generation); count("panorama")
    }
    private func count(_ key: String) {
        received[key, default: 0] += 1
        let now=ProcessInfo.processInfo.systemUptime
        if started[key] == nil { started[key] = now }
        var recent=arrivals[key,default:[]];recent.append(now)
        arrivals[key]=Array(recent.suffix(150))
    }
    func statistics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Any] = [:]
        for key in ["front", "belly", "panorama"] {
            let captured = key == "panorama" ? panorama?.received : frames[key]?.capturedAtMilliseconds
            let elapsed = ProcessInfo.processInfo.systemUptime-(started[key] ?? ProcessInfo.processInfo.systemUptime)
            let recent=arrivals[key,default:[]].filter {ProcessInfo.processInfo.systemUptime-$0<=5}
            let span=(recent.last ?? 0)-(recent.first ?? 0)
            result[key] = ["frames_received": received[key] ?? 0,
                "mean_ingress_fps": elapsed > 0 ? Double(received[key] ?? 0)/elapsed : 0,
                "recent_ingress_fps": span>0 && ProcessInfo.processInfo.systemUptime-(recent.last ?? 0)<2 ? Double(recent.count-1)/span : 0,
                "age_ms": captured.map { Date().timeIntervalSince1970*1000-$0 } as Any? ?? NSNull(),
                "timestamp_kind": key == "panorama" ? "decoder_receipt_not_sensor_exposure" : "sensor_capture"]
        }
        return result
    }
    func snapshot(camera: String, includeDepth: Bool, maximumAge: Double, includeRGB: Bool = true,
                  completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard includeRGB || (includeDepth && camera != "panorama") else {
            completion(.failure(ROBLocalControlError("Depth-only snapshots require a depth camera"))); return
        }
        lock.lock()
        guard !(includeRGB ? encodeBusy : depthBusy) else { lock.unlock(); completion(.failure(ROBLocalControlError(includeRGB ? "Snapshot encoder busy; no camera frame queued" : "Depth snapshot busy; no camera frame queued"))); return }
        let frame = frames[camera], pano = panorama
        if includeRGB { encodeBusy = true } else { depthBusy = true }; lock.unlock()
        (includeRGB ? encoder : depthEncoder).async {
            let start = ProcessInfo.processInfo.systemUptime
            func finish(_ result: Result<[String: Any], Error>) {
                self.lock.lock()
                if includeRGB { self.encodeBusy = false } else { self.depthBusy = false }
                self.lock.unlock()
                completion(result)
            }
            do {
                var result: [String: Any]
                let timestamp: Double
                if camera == "panorama", let pano {
                    timestamp = pano.received
                    result = ["camera": camera, "sequence": pano.sequence, "stream_id": "insta360-\(pano.generation)",
                        "timestamp_kind": "decoder_receipt_not_sensor_exposure", "jpeg_base64": pano.jpeg.base64EncodedString(),
                        "depth_available": false, "robot_relative_yaw_calibrated": false]
                } else if ["front", "belly"].contains(camera), let frame,
                          let captured = frame.capturedAtMilliseconds, captured.isFinite,
                          let pixels = CMSampleBufferGetImageBuffer(frame.rgbSampleBuffer) {
                    timestamp = captured
                    guard (0...maximumAge).contains(Date().timeIntervalSince1970*1000-captured) else { throw ROBLocalControlError("Camera frame is stale; timestamps are never refreshed") }
                    result = ["camera": camera, "source": frame.source.rawValue, "sequence": frame.sequence,
                        "stream_id": frame.captureStreamID as Any? ?? NSNull(), "timestamp_kind": "sensor_capture",
                        "width": CVPixelBufferGetWidth(pixels), "height": CVPixelBufferGetHeight(pixels),
                        "depth_available": frame.alignedDepth != nil, "coordinate_frame": "camera_optical",
                        "rgb_included": includeRGB, "robot_registration_verified": false]
                    if includeRGB {
                        let input = CIImage(cvPixelBuffer: pixels)
                        guard let image = self.context.createCGImage(input, from: input.extent),
                              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                            throw ROBLocalControlError("Unable to encode camera pixels")
                        }
                        result["jpeg_base64"] = jpeg.base64EncodedString()
                    } else if frame.alignedDepth == nil {
                        throw ROBLocalControlError("Aligned depth unavailable; no inferred depth supplied")
                    }
                    if let k = frame.intrinsics {
                        result["intrinsics"] = ["fx": k.fx, "fy": k.fy, "cx": k.cx, "cy": k.cy]
                        if let imu = k.inertial { result["imu"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imu)) }
                    }
                    if includeDepth, let depth = frame.alignedDepth {
                        result["depth"] = ["width": depth.width, "height": depth.height,
                            "format": "uint16_little_endian_millimeters", "invalid_value": 0,
                            "base64": depth.millimetersLittleEndian.base64EncodedString()]
                    }
                } else { throw ROBLocalControlError("No frame for \(camera); request camera.demand and wait for a live sample") }
                let age = Date().timeIntervalSince1970*1000-timestamp
                guard (0...maximumAge).contains(age) else { throw ROBLocalControlError("Frame expired during encoding; request a fresh frame") }
                result["captured_at_ms"] = timestamp; result["age_ms"] = age
                result["encoding_ms"] = (ProcessInfo.processInfo.systemUptime-start)*1000
                result["motion_authority"] = false
                finish(.success(result))
            } catch { finish(.failure(error)) }
        }
    }
}
