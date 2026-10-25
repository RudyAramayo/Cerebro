#!/usr/bin/env python3
"""Compile production per-can source report metadata without app/device access."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
STUBS=r'''
import Foundation
struct Runtime {let identity:String}
struct Intrinsics {let runtimeCalibration:Runtime?;let cameraServiceSourceSHA256:String?;let rgbOutputUndistorted:Bool?}
struct Frame {let sequence:UInt64;let capturedAt:Double;let cameraGeneration:UUID}
struct Depth {let width:Int;let height:Int}
struct Model {let modelID:String;let geometryID:String;let selectedMappingID:String;let physicalSide:String}
struct Map {let bodyMotionIdentity:String}
struct Estimated {let identity:String?}
struct Registration {let id:String}
struct Measured {let registration:Registration}
struct Scope {let panTarget:Int;let lowerTarget:Int;let upperTarget:Int}
final class ROBFixedHeadCalibrationWindowController {
    static let shared=ROBFixedHeadCalibrationWindowController()
    var shouldFail=false
    var observedSequence:UInt64?
    func scope(model:Model,frame:Frame)throws->Scope {
        observedSequence=frame.sequence
        if shouldFail {throw NSError(domain:"explicit source-scope evidence unavailable",code:1)}
        return .init(panTarget:6015,lowerTarget:6011,upperTarget:6306)
    }
}
func productionSource(frame:Frame,k:Intrinsics,collisionMap:Map?,estimatedCamera:Estimated?,measuredCamera:Measured?)->[String:Any] {
    let model=Model(modelID:"source-model",geometryID:"source-hulls",selectedMappingID:"right-mapping",physicalSide:"right")
    let depth=Depth(width:640,height:480),sceneBodyIdentity="run-body"
    var entry:[String:Any]=[:]
    __ACTUAL_SOURCE_BLOCK__
    return entry["can_section_source"] as! [String:Any]
}
@main struct SourceReportFixtures {
    static func main() throws {
        let generation=UUID(),sequence:UInt64=4_000_000_123,captured=1792918737758.9211
        let frame=Frame(sequence:sequence,capturedAt:captured,cameraGeneration:generation)
        let k=Intrinsics(runtimeCalibration:.init(identity:"actual-worker-runtime-SHA"),cameraServiceSourceSHA256:"actual-worker-source-SHA",rgbOutputUndistorted:true)
        let source=productionSource(frame:frame,k:k,collisionMap:.init(bodyMotionIdentity:"captured-map-body"),
            estimatedCamera:.init(identity:"selected-estimated-projection"),measuredCamera:nil)
        precondition(JSONSerialization.isValidJSONObject(source))
        let encoded=try JSONSerialization.data(withJSONObject:source,options:.sortedKeys)
        let decoded=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        precondition((decoded["sequence"] as! NSNumber).uint64Value==sequence)
        precondition((decoded["captured_at_ms"] as! NSNumber).doubleValue==captured)
        precondition(decoded["camera_generation"] as! String==generation.uuidString)
        precondition(decoded["runtime_calibration_identity"] as! String=="actual-worker-runtime-SHA")
        precondition(decoded["camera_service_source_sha256"] as! String=="actual-worker-source-SHA")
        precondition(decoded["body_motion_identity"] as! String=="captured-map-body")
        precondition(decoded["raw_neck_pan_target"] as! Int==6015 && decoded["raw_neck_lower_target"] as! Int==6011 && decoded["raw_neck_upper_target"] as! Int==6306)
        precondition(decoded["registration_id"] is NSNull && decoded["capture_time_refreshed"] as! Bool==false)
        precondition(ROBFixedHeadCalibrationWindowController.shared.observedSequence==sequence)
        ROBFixedHeadCalibrationWindowController.shared.shouldFail=true
        let missing=productionSource(frame:frame,k:.init(runtimeCalibration:nil,cameraServiceSourceSHA256:nil,rgbOutputUndistorted:nil),
            collisionMap:nil,estimatedCamera:nil,measuredCamera:.init(registration:.init(id:"measured-source-id")))
        precondition(JSONSerialization.isValidJSONObject(missing))
        precondition(missing["runtime_calibration_identity"] is NSNull && missing["camera_service_source_sha256"] is NSNull && missing["rgb_output_undistorted_contract"] is NSNull)
        precondition(missing["raw_neck_pan_target"]==nil && missing["source_scope_error"] != nil)
        precondition(missing["registration_id"] as! String=="measured-source-id" && missing["body_motion_identity"] as! String=="run-body")
        print("PASS actual can-section source report: same64bit sequence/exact capture time/runtime/source/body/raw held-neck, JSON serialization, measured vsestimated labels, and explicitmissingmetadata/scopefailure without invented values")
    }
}
'''

def main():
    vision=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text()
    start=vision.index('                        var sectionSource: [String:Any] =')
    stop=vision.index('                        var rejected = 0',start)
    block=vision[start:stop]
    assert 'Date(' not in block and 'frame.capturedAt' in block and 'frame.sequence' in block
    wrapper=vision[stop:vision.index('                        let candidateContext =',stop)]
    for expected in ['measureWithDiagnostics(', 'diagnostic["source"]=sectionSource',
                     'entry["can_section_diagnostics"]=sectionDiagnostics',
                     '"tabletop_base_height_disagreement"','"outside_fixed_head_registration_volume"',
                     '"reach_calibration_configuration_invalid"']:
        assert expected in wrapper,expected
    with tempfile.TemporaryDirectory(prefix='rob-can-section-source-report-') as folder:
        path=Path(folder);source=path/'Fixture.swift';binary=path/'fixture'
        source.write_text(STUBS.replace('__ACTUAL_SOURCE_BLOCK__',block))
        subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',
            '/private/tmp/cerebro-swift-module-cache',str(source),'-o',str(binary)],check=True,timeout=45)
        subprocess.run([str(binary)],check=True,timeout=10)

if __name__=='__main__':main()
