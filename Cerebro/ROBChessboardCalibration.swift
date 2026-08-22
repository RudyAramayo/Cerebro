import Foundation
import CoreMedia
import AppKit

enum ROBChessboardCalibrationError: LocalizedError {
    case invalidRGBBuffer
    case invalidImageRepresentation
    case invalidBoardDimensions(cols: Int, rows: Int)
    case invalidSquareSize
    case invalidIntrinsics
    case invalidDepthFrameDimensions
    case missingBoardPlacement
    case invalidBoardPlacement
    case missingCornersScript
    case pythonScriptFailed(String)
    case parseResponseFailed(String)
    case cornersNotFound(String)
    case unexpectedCornerPattern(expectedCols: Int, expectedRows: Int, actualCols: Int?, actualRows: Int?)
    case invalidCornerCount(expected: Int, actual: Int)
    case invalidCornerCoordinate(index: Int)
    case insufficientDepthPoints
    case solverFailed
    case unacceptableSolverResidual(Double)
    case encoderFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidRGBBuffer: return "Failed to retrieve the RGB pixel buffer."
        case .invalidImageRepresentation: return "Failed to encode the RGB image to JPEG."
        case .invalidBoardDimensions(let cols, let rows):
            return "Chessboard dimensions must both be greater than one; received \(cols)x\(rows)."
        case .invalidSquareSize:
            return "Chessboard square size must be finite and greater than zero."
        case .invalidIntrinsics:
            return "Camera intrinsics must contain finite, positive focal lengths and principal-point coordinates."
        case .invalidDepthFrameDimensions:
            return "The aligned depth frame has invalid dimensions."
        case .missingBoardPlacement:
            return "Calibration requires an explicit board-to-robot placement. Refusing to persist a board-relative pose as robot-relative."
        case .invalidBoardPlacement:
            return "The board-to-robot placement must be a finite, right-handed rigid transform."
        case .missingCornersScript: return "FindChessboardCorners.py script is missing from the bundle."
        case .pythonScriptFailed(let msg): return "Python script execution failed: \(msg)"
        case .parseResponseFailed(let raw): return "Failed to parse the Python script response. Raw output:\n\(raw)"
        case .cornersNotFound(let msg): return "Chessboard corners not found: \(msg)"
        case .unexpectedCornerPattern(let expectedCols, let expectedRows, let actualCols, let actualRows):
            let actual = "\(actualCols.map { String($0) } ?? "missing")x\(actualRows.map { String($0) } ?? "missing")"
            return "Corner detector returned pattern \(actual); expected exactly \(expectedCols)x\(expectedRows)."
        case .invalidCornerCount(let expected, let actual):
            return "Corner detector returned \(actual) points; expected exactly \(expected)."
        case .invalidCornerCoordinate(let index):
            return "Corner \(index) has a non-finite or out-of-bounds RGB coordinate."
        case .insufficientDepthPoints: return "Insufficient depth points found around chessboard corners."
        case .solverFailed: return "Rigid pose solver failed to find a valid transform."
        case .unacceptableSolverResidual(let residual):
            return "Calibration residual \(residual) m is non-finite or exceeds the 0.05 m safety limit."
        case .encoderFailed: return "Failed to encode or persist the calibrated pose."
        }
    }
}

final class ROBChessboardCalibration {
    /// A rigid placement of the calibration board in robot coordinates.
    /// Axis vectors are the board's unit X/Y/Z axes expressed in the robot frame.
    struct BoardToRobotTransform {
        let translationMeters: SIMD3<Double>
        let xAxis: SIMD3<Double>
        let yAxis: SIMD3<Double>
        let zAxis: SIMD3<Double>

        init(
            translationMeters: SIMD3<Double>,
            xAxis: SIMD3<Double>,
            yAxis: SIMD3<Double>,
            zAxis: SIMD3<Double>
        ) {
            self.translationMeters = translationMeters
            self.xAxis = xAxis
            self.yAxis = yAxis
            self.zAxis = zAxis
        }

        fileprivate func applying(to boardPoint: SIMD3<Double>) -> SIMD3<Double> {
            translationMeters
                + xAxis * boardPoint.x
                + yAxis * boardPoint.y
                + zAxis * boardPoint.z
        }
    }

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

    private static let maximumAcceptableResidualMeters = 0.05

    private static func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private static func dot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func cross(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private static func isValid(_ placement: BoardToRobotTransform) -> Bool {
        guard isFinite(placement.translationMeters),
              isFinite(placement.xAxis),
              isFinite(placement.yAxis),
              isFinite(placement.zAxis) else { return false }

        let tolerance = 0.01
        let xLength = sqrt(dot(placement.xAxis, placement.xAxis))
        let yLength = sqrt(dot(placement.yAxis, placement.yAxis))
        let zLength = sqrt(dot(placement.zAxis, placement.zAxis))
        guard abs(xLength - 1) <= tolerance,
              abs(yLength - 1) <= tolerance,
              abs(zLength - 1) <= tolerance,
              abs(dot(placement.xAxis, placement.yAxis)) <= tolerance,
              abs(dot(placement.xAxis, placement.zAxis)) <= tolerance,
              abs(dot(placement.yAxis, placement.zAxis)) <= tolerance else { return false }

        return abs(dot(cross(placement.xAxis, placement.yAxis), placement.zAxis) - 1) <= tolerance * 2
    }
    
    @discardableResult
    static func performCalibration(
        role: CameraRole,
        rgbSampleBuffer: CMSampleBuffer,
        depth: CameraDepthFrame,
        intrinsics: CameraIntrinsics,
        cols: Int = 9,
        rows: Int = 6,
        squareSizeMeters: Double = 0.025,
        boardToRobotTransform: BoardToRobotTransform? = nil
    ) throws -> Double {
        guard cols > 1, rows > 1 else {
            throw ROBChessboardCalibrationError.invalidBoardDimensions(cols: cols, rows: rows)
        }
        let (expectedCornerCount, cornerCountOverflow) = cols.multipliedReportingOverflow(by: rows)
        guard !cornerCountOverflow else {
            throw ROBChessboardCalibrationError.invalidBoardDimensions(cols: cols, rows: rows)
        }
        guard squareSizeMeters.isFinite, squareSizeMeters > 0 else {
            throw ROBChessboardCalibrationError.invalidSquareSize
        }
        guard intrinsics.fx.isFinite, intrinsics.fx > 0,
              intrinsics.fy.isFinite, intrinsics.fy > 0,
              intrinsics.cx.isFinite, intrinsics.cx > 0,
              intrinsics.cy.isFinite, intrinsics.cy > 0 else {
            throw ROBChessboardCalibrationError.invalidIntrinsics
        }
        guard depth.width > 0, depth.height > 0 else {
            throw ROBChessboardCalibrationError.invalidDepthFrameDimensions
        }
        guard let boardToRobotTransform else {
            throw ROBChessboardCalibrationError.missingBoardPlacement
        }
        guard isValid(boardToRobotTransform) else {
            throw ROBChessboardCalibrationError.invalidBoardPlacement
        }

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

        guard response.cols == cols, response.rows == rows else {
            throw ROBChessboardCalibrationError.unexpectedCornerPattern(
                expectedCols: cols,
                expectedRows: rows,
                actualCols: response.cols,
                actualRows: response.rows
            )
        }
        guard corners.count == expectedCornerCount else {
            throw ROBChessboardCalibrationError.invalidCornerCount(
                expected: expectedCornerCount,
                actual: corners.count
            )
        }

        let rgbWidth = Double(cgImage.width)
        let rgbHeight = Double(cgImage.height)
        guard rgbWidth > 0, rgbHeight > 0 else {
            throw ROBChessboardCalibrationError.invalidRGBBuffer
        }
        let depthScaleX = Double(depth.width) / rgbWidth
        let depthScaleY = Double(depth.height) / rgbHeight
        
        var correspondences: [ROBRigidCorrespondence] = []
        
        // OpenCV returns corners row by row, left to right
        for row in 0..<rows {
            for col in 0..<cols {
                let index = row * cols + col
                let corner = corners[index]
                guard corner.x.isFinite, corner.y.isFinite,
                      corner.x >= 0, corner.x < rgbWidth,
                      corner.y >= 0, corner.y < rgbHeight else {
                    throw ROBChessboardCalibrationError.invalidCornerCoordinate(index: index)
                }
                
                let scaledDepthX = (corner.x + 0.5) * depthScaleX - 0.5
                let scaledDepthY = (corner.y + 0.5) * depthScaleY - 0.5
                guard scaledDepthX.isFinite, scaledDepthY.isFinite else {
                    throw ROBChessboardCalibrationError.invalidCornerCoordinate(index: index)
                }
                let pixelX = min(depth.width - 1, max(0, Int(scaledDepthX.rounded())))
                let pixelY = min(depth.height - 1, max(0, Int(scaledDepthY.rounded())))
                
                // Median filter depth
                var samples: [UInt16] = []
                let minimumY = max(0, pixelY - 3)
                let maximumY = min(depth.height - 1, pixelY + 3)
                let minimumX = max(0, pixelX - 3)
                let maximumX = min(depth.width - 1, pixelX + 3)
                guard minimumY <= maximumY, minimumX <= maximumX else { continue }
                for y in minimumY...maximumY {
                    for x in minimumX...maximumX {
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
                
                let boardPoint = SIMD3<Double>(
                    Double(col) * squareSizeMeters,
                    Double(row) * squareSizeMeters,
                    0
                )
                guard isFinite(boardPoint) else {
                    throw ROBChessboardCalibrationError.invalidSquareSize
                }
                let robotPoint = boardToRobotTransform.applying(to: boardPoint)
                guard isFinite(cameraPoint), isFinite(robotPoint) else {
                    throw ROBChessboardCalibrationError.invalidBoardPlacement
                }
                
                correspondences.append(ROBRigidCorrespondence(camera: cameraPoint, robot: robotPoint))
            }
        }
        
        guard correspondences.count >= 8 else {
            throw ROBChessboardCalibrationError.insufficientDepthPoints
        }
        
        guard let transform = ROBRigidPoseSolver.solve(correspondences) else {
            throw ROBChessboardCalibrationError.solverFailed
        }
        guard transform.rms.isFinite,
              transform.rms >= 0,
              transform.rms <= maximumAcceptableResidualMeters else {
            throw ROBChessboardCalibrationError.unacceptableSolverResidual(transform.rms)
        }
        
        let vector = transform.rotation.vector
        guard isFinite(transform.translation),
              vector.x.isFinite, vector.y.isFinite,
              vector.z.isFinite, vector.w.isFinite else {
            throw ROBChessboardCalibrationError.solverFailed
        }
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
