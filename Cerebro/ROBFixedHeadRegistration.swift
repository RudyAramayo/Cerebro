import Foundation
import CryptoKit
import simd

/// Body motion changes a fixed-head camera-to-base transform even when neck
/// servo targets remain identical. Invalidate synchronously before a physical
/// nonzero body command; publish UI/map cancellation on the main thread.
@objcMembers final class ROBFixedHeadBodyMotionIdentity: NSObject {
    static let changed = Notification.Name("ROBFixedHeadBodyDidMove")
    private static let lock = NSLock()
    private static var identity = UUID().uuidString
    static var currentIdentity: String {
        lock.lock();defer {lock.unlock()};return identity
    }
    /// Base firmware packet: tilde, seven signed four-digit decimal fields,
    /// comma separated. Indices 0/2/4 are brakes; 1/3/5/6 may drive the body.
    /// A malformed packet beginning with the motion prefix is uncertain and
    /// conservatively invalidates registration instead of parsing as zero.
    @objc(baseCommandMayMove:) static func baseCommandMayMove(_ command:String)->Bool {
        let bytes=Array(command.utf8)
        guard bytes.first==0x7e else {return false}
        guard bytes.count==42 else {return true}
        var mayMove=false
        for index in 0..<7 {
            let start=1+index*6
            guard bytes[start]==0x2b || bytes[start]==0x2d else {return true}
            let digits=bytes[(start+1)...(start+4)]
            guard digits.allSatisfy({(0x30...0x39).contains($0)}) else {return true}
            if index<6,bytes[start+5] != 0x2c {return true}
            if [1,3,5,6].contains(index),digits.contains(where:{$0 != 0x30}) {mayMove=true}
        }
        return mayMove
    }

    @discardableResult static func invalidate() -> String {
        lock.lock();identity=UUID().uuidString;let current=identity;lock.unlock()
        let publish = { NotificationCenter.default.post(name:changed,object:nil) }
        if Thread.isMainThread {publish()} else {DispatchQueue.main.async(execute:publish)}
        return current
    }
}

/// Exact acquisition state for a local optical-to-robot measurement. Raw neck
/// targets identify one held view; they are not claimed to be measured angles.
struct ROBFixedHeadRegistrationScope: Codable, Equatable {
    let modelID: String
    let geometryID: String
    let mappingID: String
    let cameraGeneration: UUID
    let gatewaySessionGeneration: UInt64
    let displayCorrectionIdentity: String
    let panTarget: Int
    let lowerTarget: Int
    let upperTarget: Int
    let intrinsicsIdentity: String

    func validate() throws {
        let strings = [modelID,geometryID,mappingID,displayCorrectionIdentity,intrinsicsIdentity]
        guard strings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }), gatewaySessionGeneration > 0,
              [panTarget,lowerTarget,upperTarget].allSatisfy({ (3000...10000).contains($0) }) else {
            throw ROBFixedHeadRegistrationError.invalid("Registration scope needs current model, camera, connection, intrinsics and exact active neck targets.")
        }
    }
}

struct ROBFixedHeadRegistrationVolume: Codable, Equatable {
    let lowMeters: [Double]
    let highMeters: [Double]
    func validate() throws {
        guard lowMeters.count == 3, highMeters.count == 3,
              (0..<3).allSatisfy({ lowMeters[$0].isFinite && highMeters[$0].isFinite &&
                  abs(lowMeters[$0]) <= 4 && abs(highMeters[$0]) <= 4 &&
                  (0.02...2).contains(highMeters[$0]-lowMeters[$0]) }) else {
            throw ROBFixedHeadRegistrationError.invalid("Specify a finite local validation volume, 2 cm to 2 m on each axis.")
        }
    }
    func contains(_ point: SIMD3<Double>) -> Bool {
        lowMeters.count == 3 && highMeters.count == 3 && (0..<3).allSatisfy {
            point[$0].isFinite && point[$0] >= lowMeters[$0] && point[$0] <= highMeters[$0]
        }
    }
    var corners: [SIMD3<Double>] {
        (0..<8).map { mask in SIMD3((mask&1) == 0 ? lowMeters[0] : highMeters[0],
            (mask&2) == 0 ? lowMeters[1] : highMeters[1], (mask&4) == 0 ? lowMeters[2] : highMeters[2]) }
    }
}

/// Camera points are measured in the RAW aligned depth optical frame. Robot
/// references must be physical survey/CAD-surface correspondences, with their
/// own declared error. No neck prior or corrected can location is a reference.
struct ROBFixedHeadRegistrationSample: Codable {
    let landmarkID: String
    let captureID: String
    let frameSequence: UInt64
    let capturedAtMilliseconds: Double
    let evidenceSHA256: String
    let referenceSource: String
    let cameraMeters: [Double]
    let robotMeters: [Double]
    let cameraUncertaintyMeters: Double
    let referenceUncertaintyMeters: Double
    let validationOnly: Bool
    var camera: SIMD3<Double> { SIMD3(cameraMeters[0],cameraMeters[1],cameraMeters[2]) }
    var robot: SIMD3<Double> { SIMD3(robotMeters[0],robotMeters[1],robotMeters[2]) }
}

struct ROBFixedHeadRegistrationInput: Codable {
    let schemaVersion: Int
    let scope: ROBFixedHeadRegistrationScope
    let validRobotVolume: ROBFixedHeadRegistrationVolume
    let samples: [ROBFixedHeadRegistrationSample]
}

enum ROBFixedHeadRegistrationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(detail) = self { return detail }; return nil }
}

/// Recomputed from raw correspondences. This is a local, conditional measured
/// fit with an explicit error allowance, never a global neck/URDF calibration.
/// Only fit() constructs the proof; a JSON field named "verified" has no effect.
struct ROBFixedHeadRegistration {
    let id: String
    let scope: ROBFixedHeadRegistrationScope
    let validRobotVolume: ROBFixedHeadRegistrationVolume
    let cameraToRobot: simd_double4x4
    let fitRMSEMeters: Double
    let validationRMSEMeters: Double
    let validationMaximumMeters: Double
    let uncertaintyMeters: Double
    let trainingCount: Int
    let validationCount: Int
    let input: ROBFixedHeadRegistrationInput

    private init(id:String, input:ROBFixedHeadRegistrationInput, matrix:simd_double4x4,
                 fitRMS:Double, validationRMS:Double, validationMaximum:Double, uncertainty:Double,
                 trainingCount:Int, validationCount:Int) {
        self.id=id; self.input=input; self.scope=input.scope; self.validRobotVolume=input.validRobotVolume
        self.cameraToRobot=matrix; self.fitRMSEMeters=fitRMS; self.validationRMSEMeters=validationRMS
        self.validationMaximumMeters=validationMaximum; self.uncertaintyMeters=uncertainty
        self.trainingCount=trainingCount; self.validationCount=validationCount
    }
    func matches(_ candidate: ROBFixedHeadRegistrationScope) -> Bool { scope == candidate }
    func project(_ rawOpticalPoint: SIMD3<Double>, scope candidate: ROBFixedHeadRegistrationScope) throws -> SIMD3<Double> {
        guard matches(candidate), rawOpticalPoint.z > 0,
              [rawOpticalPoint.x,rawOpticalPoint.y,rawOpticalPoint.z].allSatisfy(\.isFinite) else {
            throw ROBFixedHeadRegistrationError.invalid("Camera registration does not cover the current fixed head/camera state.")
        }
        let result = Self.point(cameraToRobot,rawOpticalPoint)
        guard validRobotVolume.contains(result) else {
            throw ROBFixedHeadRegistrationError.invalid("Point lies outside this registration's measured local volume.")
        }
        return result
    }
    func acceptsTransform(_ matrix: simd_double4x4, scope candidate:ROBFixedHeadRegistrationScope) -> Bool {
        matches(candidate) && (0..<4).allSatisfy { c in (0..<4).allSatisfy { r in
            matrix[c][r].isFinite && abs(matrix[c][r]-cameraToRobot[c][r]) <= 1e-9
        } }
    }

    static func fit(_ input: ROBFixedHeadRegistrationInput) throws -> Self {
        try input.scope.validate(); try input.validRobotVolume.validate()
        guard input.schemaVersion == 1, (7...256).contains(input.samples.count) else {
            throw ROBFixedHeadRegistrationError.invalid("A local registration needs 4 or more fit landmarks and 3 or more independent validation landmarks.")
        }
        let supportedSources = ["surveyed_robot_landmark","measured_robot_landmark","measured_arm_fk","cad_surface_rgbd"]
        for sample in input.samples {
            guard !sample.landmarkID.isEmpty, sample.landmarkID.utf8.count <= 256,
                  !sample.captureID.isEmpty, sample.captureID.utf8.count <= 256,
                  sample.frameSequence > 0, sample.capturedAtMilliseconds.isFinite, sample.capturedAtMilliseconds > 0,
                  sample.evidenceSHA256.count == 64, sample.evidenceSHA256.allSatisfy({ $0.isHexDigit }),
                  supportedSources.contains(sample.referenceSource),
                  sample.cameraMeters.count == 3, sample.robotMeters.count == 3,
                  (sample.cameraMeters+sample.robotMeters).allSatisfy({ $0.isFinite && abs($0) <= 5 }),
                  (0.1...3).contains(sample.cameraMeters[2]),
                  (0.001...0.10).contains(sample.cameraUncertaintyMeters),
                  (0.001...0.10).contains(sample.referenceUncertaintyMeters) else {
                throw ROBFixedHeadRegistrationError.invalid("Every landmark needs finite measured XYZ, source, capture evidence and explicit camera/reference uncertainty.")
            }
        }
        let training = input.samples.filter { !$0.validationOnly }, validation = input.samples.filter(\.validationOnly)
        guard training.count >= 4, validation.count >= 3,
              Set(input.samples.map(\.landmarkID)).count == input.samples.count,
              Set(training.map(\.captureID)).isDisjoint(with:Set(validation.map(\.captureID))),
              Set(validation.map(\.captureID)).count >= 2 else {
            throw ROBFixedHeadRegistrationError.invalid("Fit and validation must use distinct landmarks and capture frames; validate on at least two later independent captures.")
        }
        let newestTraining = training.map(\.capturedAtMilliseconds).max()!
        guard validation.allSatisfy({ $0.capturedAtMilliseconds > newestTraining }) else {
            throw ROBFixedHeadRegistrationError.invalid("Validation frames must be captured after the fit frames at the same held pose.")
        }
        for sample in validation {
            guard training.allSatisfy({ simd_distance(sample.robot,$0.robot) >= 0.015 &&
                simd_distance(sample.camera,$0.camera) >= 0.015 }) else {
                throw ROBFixedHeadRegistrationError.invalid("Validation repeats a fitted point; withhold separate physical landmarks or surface patches.")
            }
        }
        let source = training.map(\.camera), target = training.map(\.robot)
        try checkSpatialGeometry(source:source,target:target)
        guard noncollinear(validation.map(\.robot)) else {
            throw ROBFixedHeadRegistrationError.invalid("Independent validation points are collinear or cover too little of the robot.")
        }
        let matrix = try rigidFit(source:source,target:target)
        let fitErrors = training.map { simd_distance(point(matrix,$0.camera),$0.robot) }
        let validationErrors = validation.map { simd_distance(point(matrix,$0.camera),$0.robot) }
        let fitRMS = rms(fitErrors), validationRMS = rms(validationErrors), validationMaximum = validationErrors.max()!
        let referenceAllowance = input.samples.map { $0.cameraUncertaintyMeters+$0.referenceUncertaintyMeters }.max()!
        // Delete-one sensitivity is evaluated over the actual requested local
        // volume. It grows when angular fit uncertainty is extrapolated away
        // from the observed robot; it is not an iid-pixel confidence interval.
        var sensitivity = 0.0
        for excluded in training.indices {
            let remaining = training.indices.filter { $0 != excluded }
            guard let jackknife = try? rigidFit(source:remaining.map { source[$0] },target:remaining.map { target[$0] }) else {
                throw ROBFixedHeadRegistrationError.invalid("Registration is unstable when one fitted landmark is withheld.")
            }
            for corner in input.validRobotVolume.corners {
                let raw = simd_inverse(matrix)*SIMD4(corner,1)
                sensitivity=max(sensitivity,simd_distance(point(jackknife,SIMD3(raw.x,raw.y,raw.z)),corner))
            }
        }
        let uncertainty = referenceAllowance + max(validationMaximum,fitErrors.max()!) + sensitivity
        guard fitRMS <= 0.02, validationRMS <= 0.025, validationMaximum <= 0.04,
              uncertainty.isFinite, uncertainty <= 0.05 else {
            throw ROBFixedHeadRegistrationError.invalid(String(format:
                "Local registration failed validation: fit %.1f mm, held-out %.1f mm RMS / %.1f mm max, error allowance %.1f mm (limit 50 mm).",fitRMS*1000,validationRMS*1000,validationMaximum*1000,uncertainty*1000))
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let digest=SHA256.hash(data:try encoder.encode(input)).map { String(format:"%02x",$0) }.joined()
        return .init(id:"fixed-head-"+digest,input:input,matrix:matrix,fitRMS:fitRMS,validationRMS:validationRMS,
            validationMaximum:validationMaximum,uncertainty:uncertainty,trainingCount:training.count,validationCount:validation.count)
    }

    private static func point(_ matrix:simd_double4x4,_ p:SIMD3<Double>)->SIMD3<Double> {
        let value=matrix*SIMD4(p,1);return SIMD3(value.x,value.y,value.z)
    }
    private static func rms(_ values:[Double])->Double { sqrt(values.reduce(0) { $0+$1*$1 }/Double(values.count)) }
    private static func noncollinear(_ points:[SIMD3<Double>])->Bool {
        guard let a=points.first,let b=points.max(by:{simd_distance(a,$0)<simd_distance(a,$1)}),simd_distance(a,b)>=0.10 else {return false}
        return points.contains { simd_length(simd_cross(b-a,$0-a))/simd_distance(a,b)>=0.03 }
    }
    private static func checkSpatialGeometry(source:[SIMD3<Double>],target:[SIMD3<Double>]) throws {
        guard noncollinear(source),noncollinear(target) else {
            throw ROBFixedHeadRegistrationError.invalid("Spread measured fit landmarks across at least 10 cm in two directions.")
        }
        let a=0,b=source.indices.max(by:{simd_distance(source[a],source[$0])<simd_distance(source[a],source[$1])})!
        let c=source.indices.max(by:{simd_length(simd_cross(source[b]-source[a],source[$0]-source[a]))<simd_length(simd_cross(source[b]-source[a],source[$1]-source[a]))})!
        let normal=simd_cross(source[b]-source[a],source[c]-source[a])
        let d=source.indices.max(by:{abs(simd_dot(normal,source[$0]-source[a]))<abs(simd_dot(normal,source[$1]-source[a]))})!
        let sourceVolume=simd_dot(normal,source[d]-source[a])
        let robotNormal=simd_cross(target[b]-target[a],target[c]-target[a])
        let targetVolume=simd_dot(robotNormal,target[d]-target[a])
        guard abs(sourceVolume)/simd_length(normal)>=0.01, simd_length(robotNormal)>1e-8,
              abs(targetVolume)/simd_length(robotNormal)>=0.01 else {
            throw ROBFixedHeadRegistrationError.invalid("A single flat plane cannot independently check the camera-to-arm frame. Include a measured landmark at another depth.")
        }
        guard sourceVolume*targetVolume>0 else {
            throw ROBFixedHeadRegistrationError.invalid("Camera and robot correspondences have opposite handedness; a reflection is not a physical camera transform.")
        }
    }
    /// Horn absolute orientation with Jacobi diagonalization (including exact
    /// half turns). Its quaternion always represents a proper rigid rotation.
    private static func rigidFit(source:[SIMD3<Double>],target:[SIMD3<Double>]) throws -> simd_double4x4 {
        guard source.count==target.count,source.count>=3,noncollinear(source),noncollinear(target) else {
            throw ROBFixedHeadRegistrationError.invalid("Rigid fit is geometrically degenerate.")
        }
        let sc=source.reduce(.zero,+)/Double(source.count),tc=target.reduce(.zero,+)/Double(target.count)
        var h=Array(repeating:Array(repeating:0.0,count:3),count:3)
        for (x,y) in zip(source,target) {let a=x-sc,b=y-tc;for r in 0..<3 {for c in 0..<3 {h[r][c]+=a[r]*b[c]}}}
        let trace=h[0][0]+h[1][1]+h[2][2]
        var n=[
            [trace,h[1][2]-h[2][1],h[2][0]-h[0][2],h[0][1]-h[1][0]],
            [h[1][2]-h[2][1],h[0][0]-h[1][1]-h[2][2],h[0][1]+h[1][0],h[0][2]+h[2][0]],
            [h[2][0]-h[0][2],h[0][1]+h[1][0],-h[0][0]+h[1][1]-h[2][2],h[1][2]+h[2][1]],
            [h[0][1]-h[1][0],h[0][2]+h[2][0],h[1][2]+h[2][1],-h[0][0]-h[1][1]+h[2][2]]]
        var vectors=(0..<4).map {r in (0..<4).map {c in r==c ? 1.0:0.0}}
        for _ in 0..<100 {
            var p=0,q=1
            for i in 0..<4 {for j in (i+1)..<4 where abs(n[i][j])>abs(n[p][q]) {p=i;q=j}}
            if abs(n[p][q])<1e-14 {break}
            let angle=0.5*atan2(2*n[p][q],n[q][q]-n[p][p]),c=cos(angle),s=sin(angle)
            let pp=n[p][p],qq=n[q][q],pq=n[p][q]
            for k in 0..<4 where k != p && k != q {
                let kp=n[k][p],kq=n[k][q]
                n[k][p]=c*kp-s*kq;n[p][k]=n[k][p]
                n[k][q]=s*kp+c*kq;n[q][k]=n[k][q]
            }
            n[p][p]=c*c*pp-2*s*c*pq+s*s*qq;n[q][q]=s*s*pp+2*s*c*pq+c*c*qq;n[p][q]=0;n[q][p]=0
            for k in 0..<4 {let kp=vectors[k][p],kq=vectors[k][q];vectors[k][p]=c*kp-s*kq;vectors[k][q]=s*kp+c*kq}
        }
        let i=(0..<4).max(by:{n[$0][$0]<n[$1][$1]})!
        let rotation=simd_normalize(simd_quatd(ix:vectors[1][i],iy:vectors[2][i],iz:vectors[3][i],r:vectors[0][i]))
        var matrix=simd_matrix4x4(rotation);matrix.columns.3=SIMD4(tc-rotation.act(sc),1)
        guard abs(simd_determinant(simd_double3x3(rotation))-1)<1e-8 else {throw ROBFixedHeadRegistrationError.invalid("Rigid fit rotation is invalid.")}
        return matrix
    }
}

/// Session-scoped data only. Saving inputs preserves measurement provenance;
/// loading always recomputes validation, and a camera/session/pose change never
/// rebinds an old fit. This store neither owns nor commands an actuator.
final class ROBFixedHeadRegistrationStore {
    static let shared=ROBFixedHeadRegistrationStore()
    private let lock=NSLock()
    private var registrations:[ROBFixedHeadRegistration]=[]
    private let directory:URL
    init(directory:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cerebro/FixedHeadRegistration/registrations",isDirectory:true)) {self.directory=directory}
    @discardableResult func install(_ input:ROBFixedHeadRegistrationInput) throws -> ROBFixedHeadRegistration {
        let fit=try ROBFixedHeadRegistration.fit(input)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path=directory.appendingPathComponent(fit.id+".json")
        try encoder.encode(input).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        lock.lock();registrations.removeAll {$0.scope==fit.scope};registrations.append(fit);lock.unlock()
        return fit
    }
    @discardableResult func load(_ url:URL, scope:ROBFixedHeadRegistrationScope) throws -> ROBFixedHeadRegistration {
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count<=2_000_000 else {throw ROBFixedHeadRegistrationError.invalid("Registration input exceeds 2 MB.")}
        let input=try JSONDecoder().decode(ROBFixedHeadRegistrationInput.self,from:data)
        guard input.scope==scope else {throw ROBFixedHeadRegistrationError.invalid("Imported registration belongs to another pose, camera or arm connection.")}
        return try install(input)
    }
    func resolve(scope:ROBFixedHeadRegistrationScope)->ROBFixedHeadRegistration? {
        lock.lock();defer {lock.unlock()};return registrations.last {$0.matches(scope)}
    }
    func invalidate() {lock.lock();registrations.removeAll();lock.unlock()}
}
