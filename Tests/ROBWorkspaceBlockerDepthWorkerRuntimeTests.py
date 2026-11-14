#!/usr/bin/env python3
"""Exercise the production GCD workers with the real byte reader and ray map.

No camera, actuator, app, socket, or authorization service is opened. Optional
historical maps are read unchanged. Their clock/body context is mocked only in
temporary fixture source; appended images are explicitly synthetic test data.
"""
from pathlib import Path
import argparse
import contextlib
import hashlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


FIXTURE = r'''
import Foundation
import simd
enum FixtureClock {
    private static let lock=NSLock()
    private static var timestamp=Date().timeIntervalSince1970*1000
    private static var body=UUID().uuidString
    static var nowMilliseconds:Double {lock.lock();defer {lock.unlock()};return timestamp}
    static var bodyIdentity:String {lock.lock();defer {lock.unlock()};return body}
    static func set(_ value:Double,bodyIdentity:String) {lock.lock();timestamp=value;body=bodyIdentity;lock.unlock()}
}
struct CameraIntrinsics {let fx:Double,fy:Double,cx:Double,cy:Double}
__ACTUAL_DEPTH_READER__
final class Harness:NSObject {
__ACTUAL_QUEUE__
__ACTUAL_APPEND__
__ACTUAL_FREEZE__
    static func append(_ map:ROBWorkspaceDepthMap,pixels:CameraDepthFrame,k:CameraIntrinsics,
        matrix:simd_double4x4,captured:Double,sequence:UInt64,camera:UUID,view:ROBWorkspaceView,projection:String)
        async throws->ROBWorkspaceDepthMap {
        try await appendBlockerDepth(map:map,pixels:pixels,intrinsics:k,matrix:matrix,capturedAtMilliseconds:captured,
            sequence:sequence,cameraGeneration:camera,view:view,projection:projection)
    }
    static func freeze(_ map:ROBWorkspaceDepthMap)async->ROBWorkspaceCollisionSnapshot? {await freezeBlockerDepth(map:map)}
}
@main struct WorkerFixtures {
    static func pixels(_ mm:UInt16)->CameraDepthFrame {
        var bytes=Data(count:640*480*2)
        bytes.withUnsafeMutableBytes { raw in
            let values=raw.bindMemory(to:UInt8.self)
            for index in stride(from:0,to:values.count,by:2) {values[index]=UInt8(mm&255);values[index+1]=UInt8(mm>>8)}
        }
        return .init(width:640,height:480,millimetersLittleEndian:bytes)
    }
    static func matrix(_ values:[Double])->simd_double4x4 {
        precondition(values.count==16)
        return .init(columns:(SIMD4(values[0],values[1],values[2],values[3]),SIMD4(values[4],values[5],values[6],values[7]),
            SIMD4(values[8],values[9],values[10],values[11]),SIMD4(values[12],values[13],values[14],values[15])))
    }
    static func continued(_ seed:ROBWorkspaceCollisionSnapshot)throws->ROBWorkspaceDepthMap {
        try .init(continuing:seed,modelID:seed.modelID,geometryID:seed.geometryID,mappingID:seed.mappingID,
            sessionGeneration:seed.sessionGeneration,cameraGeneration:seed.cameraGeneration,
            estimatedCameraProjectionIdentity:seed.estimatedCameraProjectionIdentity!,nowMilliseconds:FixtureClock.nowMilliseconds)
    }
    static func assertOriginalEvidence(_ before:ROBWorkspaceCollisionSnapshot,_ after:ROBWorkspaceCollisionSnapshot) {
        precondition(after.sceneID==before.sceneID && after.registrationID==nil)
        precondition(after.observations.prefix(before.observations.count).map(\.sequence)==before.observations.map(\.sequence))
        precondition(after.observations.prefix(before.observations.count).map(\.capturedAtMilliseconds)==before.observations.map(\.capturedAtMilliseconds))
        for cell in before.occupiedVoxels {
            let point=cell.center(voxelSizeMeters:before.voxelSizeMeters),old=before.occupiedSampleBounds(at:point)!,new=after.occupiedSampleBounds(at:point)!
            precondition(after.state(at:point) == .occupied)
            precondition((0..<3).allSatisfy {new.low[$0]<=old.low[$0] && new.high[$0]>=old.high[$0]})
        }
    }
    static func exercise(_ original:ROBWorkspaceCollisionSnapshot,cycles:Int,label:String)async throws {
        var seed=original
        let k=CameraIntrinsics(fx:500,fy:500,cx:320,cy:240),image=pixels(1500),hole=pixels(0)
        let transform=matrix(seed.observations.last!.cameraToRobotColumnMajor)
        let view=ROBWorkspaceView(panDegrees:seed.observations.last!.recordedPanDegrees!,upperTarget:seed.observations.last!.recordedUpperTarget!)
        for index in 0..<cycles {
            let time=original.createdAtMilliseconds+Double(index+1)*100
            FixtureClock.set(time,bodyIdentity:original.bodyMotionIdentity)
            let map=try continued(seed)
            precondition(map.snapshot(nowMilliseconds:seed.createdAtMilliseconds)!.fingerprint==seed.fingerprint)
            let before=seed,sequence=seed.observations.last!.sequence+1
            let next=try await Harness.append(map,pixels:image,k:k,matrix:transform,captured:time-1,sequence:sequence,
                camera:seed.cameraGeneration,view:view,projection:seed.estimatedCameraProjectionIdentity!)
            guard let frozen=await Harness.freeze(next) else {preconditionFailure("Worker did not freeze")}
            precondition(frozen.observedFrameCount==before.observedFrameCount+1 && frozen.observations.last!.capturedAtMilliseconds==time-1)
            assertOriginalEvidence(before,frozen);seed=frozen
        }
        // A hole changes observation metadata only, never the measured sets.
        let time=FixtureClock.nowMilliseconds+100
        FixtureClock.set(time,bodyIdentity:original.bodyMotionIdentity)
        let map=try continued(seed),sequence=seed.observations.last!.sequence+1
        let holeMap=try await Harness.append(map,pixels:hole,k:k,matrix:transform,captured:time-1,sequence:sequence,
            camera:seed.cameraGeneration,view:view,projection:seed.estimatedCameraProjectionIdentity!)
        let frozenHole=(await Harness.freeze(holeMap))!
        precondition(Set(frozenHole.occupiedVoxels)==Set(seed.occupiedVoxels) && Set(frozenHole.freeVoxels)==Set(seed.freeVoxels))
        assertOriginalEvidence(seed,frozenHole)
        // Keep the new source capture advancing; only its delivery clock is
        // late. An earlier capture correctly rejects as reorder before expiry.
        FixtureClock.set(time+1000,bodyIdentity:original.bodyMotionIdentity)
        do {
            _=try await Harness.append(map,pixels:image,k:k,matrix:transform,captured:time-1,sequence:sequence,
                camera:seed.cameraGeneration,view:view,projection:seed.estimatedCameraProjectionIdentity!)
            preconditionFailure("Expired source entered GCD worker")
        } catch let error as ROBWorkspaceDepthMapError {
            guard case .expiredAtProjection=error else {preconditionFailure("Worker lost actual mapper error")}
        }
        precondition(map.snapshot(nowMilliseconds:seed.createdAtMilliseconds)!.fingerprint==seed.fingerprint)
        // A rejected input resumes exactly once and does not poison the queue.
        let recoveryTime=time+1100
        FixtureClock.set(recoveryTime,bodyIdentity:original.bodyMotionIdentity)
        let afterError=try await Harness.append(map,pixels:hole,k:k,matrix:transform,captured:recoveryTime-1,sequence:sequence,
            camera:seed.cameraGeneration,view:view,projection:seed.estimatedCameraProjectionIdentity!)
        let recovered=(await Harness.freeze(afterError))!
        precondition(recovered.observedFrameCount==seed.observedFrameCount+1)
        print("PASS \(label): \(cycles) repeated actual serial-worker continuation/append/freeze cycles; preserved raw unions and all original timestamps; missing depth unchanged; expiry error and following task delivered once; SYNTHETIC new images only")
    }
    static func main()async throws {
        let now=Date().timeIntervalSince1970*1000,body=UUID().uuidString,camera=UUID(),projection=String(repeating:"a",count:64)
        FixtureClock.set(now,bodyIdentity:body)
        var map=ROBWorkspaceDepthMap(modelID:"synthetic-worker-model",geometryID:"synthetic-worker-geometry",mappingID:"synthetic-worker-mapping",
            sessionGeneration:1,cameraGeneration:camera,nowMilliseconds:now-1000,estimatedCameraProjectionIdentity:projection)
        let image=pixels(1500)
        for sequence:UInt64 in 1...2 {
            try map.append(width:image.width,height:image.height,fx:500,fy:500,cx:320,cy:240,
                depth:{image.distanceMillimeters(x:$0,y:$1)},cameraToRobot:matrix_identity_double4x4,
                capturedAtMilliseconds:now-300+Double(sequence)*100,sequence:sequence,cameraGeneration:camera,
                recordedPanDegrees:0,recordedUpperTarget:5300,recordedLowerTarget:6011,estimatedCameraProjectionIdentity:projection)
        }
        try await exercise(map.snapshot(nowMilliseconds:now)!,cycles:24,label:"full640x480 synthetic source")
        for path in CommandLine.arguments.dropFirst() {
            let bytes=try Data(contentsOf:URL(fileURLWithPath:path)),seed=try JSONDecoder().decode(ROBWorkspaceCollisionSnapshot.self,from:bytes)
            print("READONLY historical map \(bytes.count)bytes, \(seed.occupiedVoxelCount)occupied/\(seed.freeVoxelCount)free, fingerprint \(seed.fingerprint); historical clock/body replay seam only")
            try await exercise(seed,cycles:6,label:"actual retained historical map")
        }
        print("No camera/actuator/app IO, no installed map, no motion or registration authority; historical inputs unchanged")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--historical-map", type=Path, action="append", default=[])
    parser.add_argument("--output-directory", type=Path)
    args = parser.parse_args()
    vision = (ROOT / "Cerebro/ROBArmRoutineVision.swift").read_text()
    queue = next(line for line in vision.splitlines() if "@nonobjc private static let blockerDepthQueue = DispatchQueue(" in line)
    append = declaration(vision, "    @nonobjc private static func appendBlockerDepth(")
    freeze = declaration(vision, "    @nonobjc private static func freezeBlockerDepth(")
    assert "Task.detached" not in append + freeze
    assert "measuredSelfBounds:[],cameraRegistrationVerified:false" in append
    reader = declaration((ROOT / "Cerebro/CameraManager.swift").read_text(), "struct CameraDepthFrame {")
    fixture = FIXTURE.replace("__ACTUAL_QUEUE__", queue).replace("__ACTUAL_APPEND__", append).replace("__ACTUAL_FREEZE__", freeze).replace("__ACTUAL_DEPTH_READER__", reader)
    source = (ROOT / "Cerebro/ROBWorkspaceCollisionPlan.swift").read_text()
    search = (ROOT / "Cerebro/ROBWorkspaceSearchPlan.swift").read_text()
    view = search[search.index("struct ROBWorkspaceView:"):search.index("    static let sweep:")] + "}\n"
    protocol = "import Foundation\nimport simd\n" + view + source[source.index("struct ROBWorkspaceOccupiedReturnBounds"):source.index("/// A measured object envelope")]
    depth_map = (ROOT / "Cerebro/ROBWorkspaceDepthMap.swift").read_text().replace("Date().timeIntervalSince1970 * 1000", "FixtureClock.nowMilliseconds")
    registration = (ROOT / "Cerebro/ROBFixedHeadRegistration.swift").read_text().replace("lock.lock();defer {lock.unlock()};return identity", "return FixtureClock.bodyIdentity", 1)
    hashes = {path.resolve(): hashlib.sha256(path.read_bytes()).hexdigest() for path in args.historical_map}
    if args.output_directory:
        args.output_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    manager = contextlib.nullcontext(args.output_directory.resolve()) if args.output_directory else tempfile.TemporaryDirectory(prefix="rob-blocker-real-depth-workers-")
    with manager as directory:
        directory = Path(directory)
        for name, text in [("Fixture.swift", fixture), ("Protocol.swift", protocol), ("DepthMap.swift", depth_map), ("Registration.swift", registration)]:
            (directory / name).write_text(text)
        executable = directory / "fixture"
        subprocess.run(["xcrun", "swiftc", "-O", "-g", "-swift-version", "5", "-parse-as-library", "-module-cache-path", "/private/tmp/cerebro-swift-module-cache",
                        str(ROOT / "Cerebro/ROBArmJointLimits.swift"), str(directory / "Protocol.swift"), str(directory / "Registration.swift"),
                        str(directory / "DepthMap.swift"), str(directory / "Fixture.swift"), "-o", str(executable)], check=True, timeout=90)
        subprocess.run([str(executable), *map(str, hashes)], check=True, timeout=90)
    assert all(hashlib.sha256(path.read_bytes()).hexdigest() == digest for path, digest in hashes.items()), "Historical input changed"


if __name__ == "__main__":
    main()
