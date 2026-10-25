#!/usr/bin/env python3
"""Typecheck/run actual search bucket-prior hook with native software RGB pixels."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]

def block(source,marker):
 start=source.index(marker);i=source.index('{',start)+1;depth=1
 while depth:
  depth+=(source[i]=='{')-(source[i]=='}');i+=1
 return source[start:i]

FIXTURE=r'''
import AppKit
import CoreImage
import simd
struct Depth {let width:Int,height:Int;func distanceMillimeters(x:Int,y:Int)->UInt16? {800}}
struct Runtime {let identity:String}
struct Intrinsics {let fx=490.0,fy=490.0,cx=320.0,cy=240.0;let runtimeCalibration:Runtime? = .init(identity:"actual-runtime");let cameraServiceSourceSHA256:String?="source-SHA"}
struct Frame {let image:CIImage;let depth:Depth?;let intrinsics:Intrinsics?;let sequence:UInt64;let capturedAt:Double;let cameraGeneration:UUID}
struct Estimated {let identity:String?}
struct Map {let estimatedCameraProjectionIdentity:String?;let bodyMotionIdentity:String}
struct Enrollment {let sequence:UInt64;let capturedAtMilliseconds:Double}
enum ROBFixedHeadBodyMotionIdentity {static var currentIdentity="body"}
final class Vision {var cameraGeneration=UUID()}
struct Detection {let box:[Double];let confidence:Double}
struct View {}
struct Diagnostics {var report:[String:Any] { ["reason":"rim_fit_failed"] }}
struct Bucket {let diagnostics=Diagnostics()}
struct ROBWorkspaceBucketOpeningPrior {
 struct Evidence:Codable {let kind="fixture_estimated_prior"}
 struct Estimate {let center:SIMD3<Double>;let radius:Double;let evidence=Evidence()}
 static var calls=0;static var afterEstimate:(()->Void)?
 static func estimate(box:[Double],width:Int,height:Int,fx:Double,fy:Double,cx:Double,cy:Double,cameraToRobot:simd_double4x4,
    depth:(Int,Int)->UInt16?,color:(Int,Int)->SIMD3<Double>?)->Estimate? {
  calls+=1
  let rgb=color(320,240)!;precondition(rgb.x>0.9 && rgb.y>0.15 && rgb.y<0.35 && rgb.z<0.05)
  precondition(depth(320,240)==800);afterEstimate?()
  return .init(center:SIMD3(-0.2,0.5,0.3),radius:0.08)
 }
}
struct ROBWorkspaceLocatedObject {
 enum Target {case orangeBucket}
 let target:Target;let position:[Double];let confidence:Double;let capturedAt:Double;let sequence:UInt64;let view:View
 let openingRadius:Double;let bucketShapePrior:ROBWorkspaceBucketOpeningPrior.Evidence;let registrationID:String?
}
@MainActor func exercise(permit:Bool=true,registered:Bool=false,sourceMatches:Bool=true,revokedAfterCompute:Bool=false,changedDuringCompute:Bool=false) async throws -> (ROBWorkspaceLocatedObject?,[String:Any]) {
 let generation=UUID(),now=Date().timeIntervalSince1970*1000
 let image=CIImage(color:CIColor(red:1,green:0.25,blue:0)).cropped(to:CGRect(x:0,y:0,width:640,height:480))
 let frame=Frame(image:image,depth:.init(width:640,height:480),intrinsics:.init(),sequence:456,capturedAt:now-300,cameraGeneration:generation)
 let measuredCamera:Int?=registered ? 1:nil,cameraTransform:simd_double4x4?=matrix_identity_double4x4
 let estimatedCamera:Estimated? = .init(identity:"projection")
 let collisionMap:Map? = .init(estimatedCameraProjectionIdentity:"projection",bodyMotionIdentity:"body")
 let collisionEnrollment=Enrollment(sequence:sourceMatches ? 456:455,capturedAtMilliseconds:frame.capturedAt)
 let vision=Vision();vision.cameraGeneration=generation
 let detection=Detection(box:[0.3,0.3,0.6,0.7],confidence:0.7),view=View(),bucket=Bucket()
 var measurement:ROBWorkspaceLocatedObject?,entry:[String:Any]=[:],checks=0
 func permitsLocalCanShapePrior()throws->Bool {checks+=1;return permit && !(revokedAfterCompute && checks>1)}
 func check()throws {}
 func requireSceneProjectionIdentity()throws {}
 func isViewReady(_ v:View)->Bool {true}
 ROBWorkspaceBucketOpeningPrior.calls=0
 ROBWorkspaceBucketOpeningPrior.afterEstimate=changedDuringCompute ? {vision.cameraGeneration=UUID()}:nil
 __ACTUAL_HOOK__
 return (measurement,entry)
}
@main struct BucketPriorHookFixtures {
 @MainActor static func main() async throws {
  let accepted=try await exercise()
  precondition(accepted.0?.sequence==456 && accepted.0?.registrationID==nil && accepted.0?.position==[-0.2,0.5,0.3])
  let report=accepted.1["bucket_shape_prior"] as! [String:Any]
  precondition(JSONSerialization.isValidJSONObject(report) && report["evidence"] != nil)
  precondition(report["registration_verified"] as! Bool==false && report["measured_rim_rejected_reason"] as! String=="rim_fit_failed")
  for mode in 0..<3 {
   let result=try await exercise(permit:mode != 0,registered:mode==1,sourceMatches:mode != 2)
   precondition(result.0==nil && ROBWorkspaceBucketOpeningPrior.calls==0)
  }
  for mode in [0,1] {
   do {_=try await exercise(revokedAfterCompute:mode==0,changedDuringCompute:mode==1);preconditionFailure("Stale/revoked bucket prior published")}
   catch is CancellationError {}
  }
  print("PASS actual bucket-prior search hook: software-native deviceRGB, explicit default-closed trial/registration/source gates, same sequence/time/source evidence, revocation and sourcechange aftercompute cancel, estimated evidence JSON; no hardware")
 }
}
'''

def main():
 source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text();hook=block(source,'                        if measurement==nil,try permitsLocalCanShapePrior()')
 with tempfile.TemporaryDirectory(prefix='rob-bucket-prior-hook-') as folder:
  path=Path(folder);swift=path/'Fixture.swift';binary=path/'fixture';swift.write_text(FIXTURE.replace('__ACTUAL_HOOK__',hook))
  subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
  subprocess.run([str(binary)],check=True,timeout=20)
if __name__=='__main__':main()
