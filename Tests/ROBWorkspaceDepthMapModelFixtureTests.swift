import Foundation
import simd

@main struct ROBWorkspaceDepthMapModelFixtures {
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        let camera = UUID()
        var checked = 0
        for upper in [5650,6306] {
            for pan in [-45.0,-30,-15,0,15,30,45] {
                let view = ROBWorkspaceView(panDegrees:pan,upperTarget:upper)
                guard let transform = view.cameraFrame(model:model) else { fatalError("Bundled neck view has no camera frame: \(view)") }
                var map = ROBWorkspaceDepthMap(modelID:model.modelID,geometryID:model.geometryID,
                    mappingID:ROBGhostRobotModel.mappingID,sessionGeneration:1,cameraGeneration:camera,nowMilliseconds:1000)
                for sequence:UInt64 in 1...2 {
                    // Existing face OAK intrinsics, uniformly downsampled20x.
                    try map.append(width:32,height:20,fx:573.69189453125/20,fy:573.69189453125/20,
                        cx:319.5987243652344/20,cy:205.55215454101562/20,depth:{_,_ in 1000},cameraToRobot:transform,
                        capturedAtMilliseconds:1000+Double(sequence),sequence:sequence,cameraGeneration:camera,
                        nowMilliseconds:1001+Double(sequence),recordedPanDegrees:pan,recordedUpperTarget:upper)
                }
                let snapshot = map.snapshot(nowMilliseconds:1004)!
                precondition(snapshot.observedFrameCount == 2 && snapshot.observations.count == 2)
                precondition(snapshot.observations.allSatisfy {
                    $0.recordedPanDegrees == pan && $0.recordedUpperTarget == upper && $0.cameraToRobotColumnMajor.count == 16
                })
                precondition(snapshot.registrationID == nil && snapshot.registrationUncertaintyMeters == nil)
                checked += 1
            }
        }
        print("Actual camera-frame fixtures passed: \(checked) bundled pan/tilt views, real model FK, aligned face intrinsics, frame provenance and unchanged unverified registration")
    }
}
