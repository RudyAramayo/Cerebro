#!/usr/bin/env python3
"""Run production calibration decoding, canonical identity, scopes and generation gates."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
manager = (ROOT / 'Cerebro/CameraManager.swift').read_text()
vision = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
registration = (ROOT / 'Cerebro/ROBFixedHeadRegistration.swift').read_text()
runtime = dict(schemaVersion=1, actualDeviceMXID='19443010016BEE1200', cameraRole='face', sdkVersion='3.8.0',
               factoryEEPROMSHA256='a'*64, effectiveRuntimeCalibrationSHA256='b'*64,
               stereoPolicySHA256='c'*64, candidateSHA256=None, profileSHA256=None)
fields = ['actualDeviceMXID','cameraRole','sdkVersion','factoryEEPROMSHA256',
          'effectiveRuntimeCalibrationSHA256','stereoPolicySHA256','candidateSHA256','profileSHA256']
identity = hashlib.sha256('\n'.join(['runtime-camera-calibration-v1']+[runtime[k] or '-' for k in fields]).encode()).hexdigest()
applied={**runtime,'candidateSHA256':'e'*64,'profileSHA256':'f'*64}
applied_identity=hashlib.sha256('\n'.join(['runtime-camera-calibration-v1']+[applied[k] or '-' for k in fields]).encode()).hexdigest()
fixture = r'''
import Foundation
import CryptoKit
struct CameraInertialObservation:Decodable,Sendable {}
struct ROBChessPieceDetection:Decodable {}
enum ROBFixedHeadRegistrationError:Error {case invalid(String)}
/* TYPES */
struct Registration {
    let scope:ROBFixedHeadRegistrationScope
    /* MATCHES */
}
@main enum Test {
    static func main()throws {
        let payload=Data(#"RUNTIME_JSON"#.utf8)
        let original=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:payload)
        precondition(original.identity=="EXPECTED_ID", "Wire identity differs from independent Python SHA256")
        let encoded=try JSONEncoder().encode(original)
        let roundtrip=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:encoded)
        precondition(roundtrip==original)
        var header:[String:Any] = ["protocol_version":2,"sequence":1,"timestamp_ns":100,
            "rgb_width":4,"rgb_height":2,"rgb_format":"RGB888","rgb_length":24,
            "depth_width":4,"depth_height":2,"depth_format":"DEPTH16LE","depth_unit":"millimeter","depth_length":16,
            "stereo_width":2,"stereo_height":1,"stereo_format":"GRAY8","left_length":2,"right_length":2]
        func decode(_ values:[String:Any])throws->DepthCameraPacketHeader {
            try JSONDecoder().decode(DepthCameraPacketHeader.self,from:JSONSerialization.data(withJSONObject:values))
        }
        let legacyHeader=try decode(header);precondition(legacyHeader.runtimeCalibration == nil)
        let object=try JSONSerialization.jsonObject(with:payload) as! [String:Any]
        header["runtime_calibration"]=object;header["runtime_calibration_identity"]=original.identity
        let runtimeHeader=try decode(header);precondition(runtimeHeader.runtimeCalibration==original)
        func rejects(_ values:[String:Any]) {
            do {_=try decode(values);preconditionFailure("Malformed provided runtime group accepted")}
            catch {}
        }
        var bad=header;bad.removeValue(forKey:"runtime_calibration_identity");rejects(bad)
        bad=header;bad.removeValue(forKey:"runtime_calibration");rejects(bad)
        bad=header;bad["runtime_calibration"]=NSNull();rejects(bad)
        bad=header;bad["runtime_calibration_identity"]=NSNull();rejects(bad)
        bad=header;bad["runtime_calibration_identity"]=String(repeating:"0",count:64);rejects(bad)
        for field in ["schemaVersion","actualDeviceMXID","cameraRole","sdkVersion","factoryEEPROMSHA256",
                      "effectiveRuntimeCalibrationSHA256","stereoPolicySHA256","candidateSHA256","profileSHA256"] {
            var incomplete=object;incomplete.removeValue(forKey:field)
            bad=header;bad["runtime_calibration"]=incomplete;rejects(bad)
        }
        for (field,value) in [("actualDeviceMXID","bad\nidentifier"),("sdkVersion",""),("cameraRole","left"),
                              ("candidateSHA256","garbage"),("stereoPolicySHA256",String(repeating:"g",count:64))] {
            var invalid=object;invalid[field]=value;bad=header;bad["runtime_calibration"]=invalid;rejects(bad)
        }
        for field in ["candidateSHA256","profileSHA256"] {
            var partial=object;partial[field]=String(repeating:"e",count:64)
            do {
                _=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:JSONSerialization.data(withJSONObject:partial))
                preconditionFailure("Partially bound profile/candidate accepted")
            } catch {}
        }
        var appliedObject=object
        appliedObject["candidateSHA256"]=String(repeating:"e",count:64)
        appliedObject["profileSHA256"]=String(repeating:"f",count:64)
        let applied=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:JSONSerialization.data(withJSONObject:appliedObject))
        precondition(applied.identity=="APPLIED_EXPECTED_ID" && applied.identity != original.identity)
        var appliedHeader=header;appliedHeader["runtime_calibration"]=appliedObject
        appliedHeader["runtime_calibration_identity"]=applied.identity
        let parsedApplied=try decode(appliedHeader);precondition(parsedApplied.runtimeCalibration==applied)
        var policy=object;policy["stereoPolicySHA256"]=String(repeating:"d",count:64)
        let changed=try JSONDecoder().decode(CameraRuntimeCalibration.self,from:JSONSerialization.data(withJSONObject:policy))
        precondition(original.identity != changed.identity)
        var stream=CameraRuntimeCalibrationStreamIdentity()
        precondition(!stream.observe(nil) && !stream.observe(nil))
        precondition(stream.observe(original.identity) && !stream.observe(original.identity))
        precondition(stream.observe(changed.identity) && stream.observe(nil))
        var capture=ROBVisionCaptureIdentity()
        func observe(_ identity:String?,_ n:UInt64)->ROBVisionCaptureIdentity.Update {
            capture.observe(streamID:"same-stream",source:"depthAIService",width:640,height:400,
                intrinsics:[488,488,320,200],sequence:n,timestampNanoseconds:n,
                capturedAtMilliseconds:1000+Double(n),runtimeCalibrationIdentity:identity)
        }
        precondition(observe(original.identity,1) == .unchanged)
        let old=capture.generation
        precondition(observe(original.identity,2) == .unchanged && capture.generation==old)
        var anchored=ROBWorkspaceCaptureAnchor()
        precondition(anchored.accept(frameGeneration:old,currentGeneration:old))
        precondition(observe(changed.identity,3) == .changed && capture.generation != old)
        precondition(!anchored.permitsCurrent(capture.generation), "Old collision-map anchor survived policy-only change")
        let k=[488.0,488,320,200]
        func scope(_ id:String?)throws->ROBFixedHeadRegistrationScope {
            .init(modelID:"model",geometryID:"geometry",mappingID:"mapping",cameraGeneration:old,
                gatewaySessionGeneration:1,displayCorrectionIdentity:"body",panTarget:6015,lowerTarget:6011,upperTarget:6160,
                intrinsicsIdentity:try ROBFixedHeadRegistrationScope.cameraIntrinsicsIdentity(width:640,height:400,intrinsics:k,
                    stereoMode:"standard",stereoModeSource:"sdk_initial_config_readback",extendedDisparity:false,subpixel:true,
                    runtimeCalibrationIdentity:id))
        }
        let prior=try scope(original.identity),current=try scope(changed.identity)
        precondition(!Registration(scope:prior).matches(current), "Fixed-head registration survived same-K runtime change")
        let identical=try scope(original.identity);precondition(Registration(scope:prior).matches(identical))
        let legacy=try ROBFixedHeadRegistrationScope.cameraIntrinsicsIdentity(width:640,height:400,intrinsics:k)
        let legacyData=try JSONSerialization.data(withJSONObject:[640.0,400.0]+k)
        precondition(legacy==SHA256.hash(data:legacyData).map{String(format:"%02x",$0)}.joined())
        print("PASS runtime calibration: canonical cross-language SHA, strict provided-group decoding, legacy compatibility, nil transitions, same-K policy generation/map/registration invalidation and immutable identity stability")
    }
}
'''
types = '\n'.join(braced_declaration(manager,s) for s in (
    'struct CameraRuntimeCalibration:', 'struct CameraRuntimeCalibrationStreamIdentity',
    'struct CameraDepthRGBGeometryCorrespondence:', 'struct CameraStereoSourceExtrinsics:',
    'struct CameraStereoPairExtrinsics:', 'struct CameraStereoGeometry:', 'private struct DepthCameraPacketHeader:'))
types += '\n' + vision[vision.index('struct ROBVisionCaptureIdentity {'):vision.index('/// A separate camera consumer')]
types += '\n' + braced_declaration(registration,'struct ROBFixedHeadRegistrationScope:')
fixture=fixture.replace('/* TYPES */',types).replace('/* MATCHES */',braced_declaration(registration,'    func matches(_ candidate:'))
fixture=fixture.replace('RUNTIME_JSON',json.dumps(runtime,separators=(',',':'))).replace('APPLIED_EXPECTED_ID',applied_identity).replace('EXPECTED_ID',identity)
assert 'updateRuntimeCalibrationContext(runtimeIdentity)' in manager
assert 'runtimeCalibration: header.runtimeCalibration' in manager
assert 'runtimeIdentity == expectedRuntimeCalibrationIdentity' in vision
with tempfile.TemporaryDirectory(prefix='rob-runtime-calibration-',dir='/private/tmp') as folder:
    path=Path(folder);(path/'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(path/'Fixture.swift'),'-o',str(path/'fixture')],check=True,timeout=45)
    subprocess.run([str(path/'fixture')],check=True,timeout=10)
