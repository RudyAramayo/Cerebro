import Foundation
import CoreMedia
import AppKit

enum ROBChessboardCalibrationError: LocalizedError {
    case invalidRGBBuffer
    case invalidImageRepresentation
    case missingCornersScript
    case pythonScriptFailed(String)
    case parseResponseFailed(String)
    case cornersNotFound(String)
    case insufficientDepthPoints
    case solverFailed
    case encoderFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidRGBBuffer: return "Failed to retrieve the RGB pixel buffer."
        case .invalidImageRepresentation: return "Failed to encode the RGB image to JPEG."
        case .missingCornersScript: return "FindChessboardCorners.py script is missing from the bundle."
        case .pythonScriptFailed(let msg): return "Python script execution failed: \(msg)"
        case .parseResponseFailed(let raw): return "Failed to parse the Python script response. Raw output:\n\(raw)"
        case .cornersNotFound(let msg): return "Chessboard corners not found: \(msg)"
        case .insufficientDepthPoints: return "Insufficient depth points found around chessboard corners."
        case .solverFailed: return "Rigid pose solver failed to find a valid transform."
        case .encoderFailed: return "Failed to encode or persist the calibrated pose."
        }
    }
}

final class ROBChessboardCalibration {
    struct ChessboardResponse: Codable {
        let success: Bool
        let corners: [Point]?
        let error: String?
        let cols: Int?
        let rows: Int?
        
        struct Point: Codable {
            let x: Double
            let y: Double
        }
    }
    
    @discardableResult
    static func performCalibration(
        role: CameraRole,
        rgbSampleBuffer: CMSampleBuffer,
        depth: CameraDepthFrame,
        intrinsics: CameraIntrinsics,
        cols: Int = 9,
        rows: Int = 6,
        squareSizeMeters: Double = 0.025
    ) throws -> Double {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(rgbSampleBuffer) else {
            throw ROBChessboardCalibrationError.invalidRGBBuffer
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ROBChessboardCalibrationError.invalidRGBBuffer
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapImage.representation(using: .jpeg, properties: [:]) else {
            throw ROBChessboardCalibrationError.invalidImageRepresentation
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("chessboard_calibration_\(UUID().uuidString).jpg")
        
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        do {
            try jpegData.write(to: tempFile)
        } catch {
            throw ROBChessboardCalibrationError.invalidImageRepresentation
        }
        
        guard let scriptPath = Bundle.main.path(forResource: "FindChessboardCorners", ofType: "py") else {
            throw ROBChessboardCalibrationError.missingCornersScript
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
            throw ROBChessboardCalibrationError.pythonScriptFailed(error.localizedDescription)
        }
        
        var parsedResponse: ChessboardResponse? = nil
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { continue }
            if let data = trimmed.data(using: .utf8),
               let response = try? JSONDecoder().decode(ChessboardResponse.self, from: data) {
                parsedResponse = response
                break
            }
        }
        
        guard let response = parsedResponse else {
            throw ROBChessboardCalibrationError.parseResponseFailed(output)
        }
        
        guard response.success, let corners = response.corners else {
            throw ROBChessboardCalibrationError.cornersNotFound(response.error ?? "No corners returned.")
        }
        
        var correspondences: [ROBRigidCorrespondence] = []
        let detectedCols = response.cols ?? cols
        let detectedRows = response.rows ?? rows
        
        // OpenCV returns corners row by row, left to right
        for row in 0..<detectedRows {
            for col in 0..<detectedCols {
                let index = row * detectedCols + col
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
        
        guard correspondences.count >= 8 else {
            throw ROBChessboardCalibrationError.insufficientDepthPoints
        }
        
        guard let transform = ROBRigidPoseSolver.solve(correspondences) else {
            throw ROBChessboardCalibrationError.solverFailed
        }
        
        let vector = transform.rotation.vector
        let pose = ROBCameraPose(
            translationMeters: [transform.translation.x, transform.translation.y, transform.translation.z],
            rotationQuaternion: [vector.x, vector.y, vector.z, vector.w],
            residualRMSEMeters: transform.rms,
            anchorCount: correspondences.count,
            confidence: max(0, 1 - transform.rms / 0.05)
        )
        
        let key = role == .face ? "ROBCameraPoseFace" : "ROBCameraPoseBelly"
        guard let encoded = try? JSONEncoder().encode(pose) else {
            throw ROBChessboardCalibrationError.encoderFailed
        }
        
        UserDefaults.standard.set(encoded, forKey: key)
        print("Successfully calibrated \(role) camera! RMS error: \(transform.rms)")
        return transform.rms
    }
}
