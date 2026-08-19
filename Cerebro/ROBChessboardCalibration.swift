import Foundation
import CoreMedia
import AppKit

final class ROBChessboardCalibration {
    struct ChessboardResponse: Codable {
        let success: Bool
        let corners: [Point]?
        let error: String?
        
        struct Point: Codable {
            let x: Double
            let y: Double
        }
    }
    
    static func performCalibration(
        role: CameraRole,
        rgbSampleBuffer: CMSampleBuffer,
        depth: CameraDepthFrame,
        intrinsics: CameraIntrinsics,
        cols: Int = 9,
        rows: Int = 6,
        squareSizeMeters: Double = 0.025
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(rgbSampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(using: .jpeg, properties: [:]) else { return }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("chessboard_calibration_\(UUID().uuidString).jpg")
        
        do {
            try jpegData.write(to: tempFile)
            
            guard let scriptPath = Bundle.main.path(forResource: "FindChessboardCorners", ofType: "py") else {
                print("FindChessboardCorners.py not found in bundle")
                return
            }
            
            let args = [
                scriptPath,
                "--image", tempFile.path,
                "--cols", "\(cols)",
                "--rows", "\(rows)"
            ]
            
            let output: String
            do {
                output = try ROBPythonRuntime.shared.runPython(withArguments: args)
            } catch {
                print("Failed to run chessboard python script: \(error.localizedDescription)")
                return
            }
            
            guard let data = output.data(using: .utf8),
                  let response = try? JSONDecoder().decode(ChessboardResponse.self, from: data) else {
                print("Failed to parse chessboard python output")
                return
            }
            
            guard response.success, let corners = response.corners else {
                print("Chessboard not found: \(response.error ?? "")")
                return
            }
            
            var correspondences: [ROBRigidCorrespondence] = []
            
            // OpenCV returns corners row by row, left to right
            for row in 0..<rows {
                for col in 0..<cols {
                    let index = row * cols + col
                    let corner = corners[index]
                    
                    let pixelX = Int(corner.x)
                    let pixelY = Int(corner.y)
                    
                    // Median filter depth
                    var samples: [UInt16] = []
                    for y in max(0, pixelY - 3)...min(depth.height - 1, pixelY + 3) {
                        for x in max(0, pixelX - 3)...min(depth.width - 1, pixelX + 3) {
                            if let value = depth.distanceMillimeters(x: x, y: y), (150...10_000).contains(value) {
                                samples.append(value)
                            }
                        }
                    }
                    guard samples.count >= 8 else { continue }
                    samples.sort()
                    let z = Double(samples[samples.count / 2]) / 1_000
                    
                    let cameraPoint = SIMD3<Double>(
                        (Double(corner.x) - intrinsics.cx) * z / intrinsics.fx,
                        (Double(corner.y) - intrinsics.cy) * z / intrinsics.fy,
                        z
                    )
                    
                    // Assume the board is placed such that top-left corner is origin
                    let robotPoint = SIMD3<Double>(
                        Double(col) * squareSizeMeters,
                        Double(row) * squareSizeMeters,
                        0
                    )
                    
                    correspondences.append(ROBRigidCorrespondence(camera: cameraPoint, robot: robotPoint))
                }
            }
            
            if let transform = ROBRigidPoseSolver.solve(correspondences) {
                let vector = transform.rotation.vector
                let pose = ROBCameraPose(
                    translationMeters: [transform.translation.x, transform.translation.y, transform.translation.z],
                    rotationQuaternion: [vector.x, vector.y, vector.z, vector.w],
                    residualRMSEMeters: transform.rms,
                    anchorCount: correspondences.count,
                    confidence: max(0, 1 - transform.rms / 0.05)
                )
                
                let key = role == .face ? "ROBCameraPoseFace" : "ROBCameraPoseBelly"
                if let encoded = try? JSONEncoder().encode(pose) {
                    UserDefaults.standard.set(encoded, forKey: key)
                    print("Successfully calibrated \(role) camera! RMS error: \(transform.rms)")
                }
            } else {
                print("Failed to solve rigid pose from chessboard points")
            }
            
        } catch {
            print("Failed to save temporary calibration image")
        }
        
        try? FileManager.default.removeItem(at: tempFile)
    }
}
