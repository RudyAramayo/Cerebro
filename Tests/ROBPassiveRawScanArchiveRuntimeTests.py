#!/usr/bin/env python3
"""Run actual Search RawScanCapture with inert normalized pixels/telemetry."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBArmRoutineVision.swift').read_text()
actual=braced_declaration(source,'    @MainActor private final class RawScanCapture {').replace('@MainActor private final class','@MainActor final class',1)
sweep=braced_declaration(source,'    @MainActor @nonobjc func scanCollisionScene(')
registered=braced_declaration(source,'    @MainActor @nonobjc func captureRegisteredCurrentScene(')
for body in [sweep,registered]:
 assert body.index('await rawCapture.append(')>body.index('try next.append(')
 assert body.index('await rawCapture.finish(snapshot)')>body.index('collisionSnapshotValue = snapshot')
 assert 'archiveReport["raw_archive"]=rawCapture.report' in body
fixture=r'''
import AppKit
import CoreImage
import simd
extension Notification.Name {static let ROBAmberGatewayTelemetryDidUpdate=Notification.Name("fixture-telemetry")}
struct ROBGhostRobotModel {
 let directory:URL;var modelID="model",referenceID="ref",geometryID="geometry",selectedMappingID="mapping"
 init(directory:URL,physicalSide:String="right")throws {self.directory=directory;selectedMappingID=physicalSide+"-mapping"}
}
final class ROBAmberGatewayTelemetry:NSObject {
 let arm:String,sequence:UInt64,receivedAt:Date,sampleAgeAtReceiptMilliseconds=0.0,effectiveSampleAgeMilliseconds=1.0,effectiveGripperFeedbackAgeMilliseconds=1.0
 let positionsRadians=[0,0.01,0.02,0.03,0.04,0.05,0.06].map{NSNumber(value:$0)},statuses=Array(repeating:NSNumber(value:2),count:7)
 init(_ arm:String,_ sequence:UInt64){self.arm=arm;self.sequence=sequence;receivedAt=Date()}
}
final class ROBAmberGatewayClient:NSObject {
 static let shared=ROBAmberGatewayClient();var samples:[String:ROBAmberGatewayTelemetry]=[:]
 func connectionSnapshot()->[String:Any]{["sessionGeneration":NSNumber(value:42)]}
 func telemetry(forArm:String)->ROBAmberGatewayTelemetry?{samples[forArm]}
 func modes(forArm:String)->[NSNumber]{Array(repeating:2,count:7).map{NSNumber(value:$0)}}
}
enum ROBFixedHeadBodyMotionIdentity {static let currentIdentity="inert-stationary-body"}
struct ROBFixedHeadRegistrationScope:Codable {let panTarget=4000,lowerTarget=6011,upperTarget=5450}
struct ROBFixedHeadRegistration {struct Volume:Codable {let lowMeters=[-1.0,-1,0],highMeters=[1.0,1,2]};let id="inert-registration",validRobotVolume=Volume()}
struct ROBWorkspaceCollisionSnapshot:Codable {
 struct Observation:Codable {let sequence:UInt64,capturedAtMilliseconds:Double}
 let sceneID:UUID,cameraGeneration:UUID,observations:[Observation]
 let fingerprint=String(repeating:"a",count:64)
}
enum ROBArmRoutineVision {
 struct Runtime:Codable {let identity="inert-runtime"}
 struct Match {let status="matched"}
 struct K {
  let runtimeCalibration:Runtime?=Runtime(),rgbOutputUndistorted:Bool?=true,depthRGBGeometryCorrespondence:Match?=Match()
  let cameraServiceSourceSHA256:String?=String(repeating:"b",count:64)
  let fx=30.0,fy=30.0,cx=8.0,cy=8.0
  let sourceSize:[Int]?=[16,16],depthSourceSize:[Int]?=[16,16]
  let sourceIntrinsics:[Double]?=[30,0,8,0,30,8,0,0,1],depthSourceIntrinsics:[Double]?=[30,0,8,0,30,8,0,0,1]
  let imageTransform:[Double]?=[1,0,0,0,1,0,0,0,1],depthImageTransform:[Double]?=[1,0,0,0,1,0,0,0,1]
  let rgbSourceDistortionCoefficients:[Double]?=[0,0,0,0,0],depthSourceDistortionCoefficients:[Double]?=[0,0,0,0,0]
  let inertial:String?=nil
 }
 struct Depth {let width=16,height=16;let millimetersLittleEndian=Data((0..<256).flatMap{[UInt8($0),UInt8(3)]})}
 struct Frame {
  var image:CIImage {
   var values:[UInt8]=[]
   for i in 0..<256 {values.append(UInt8((i%16)*12));values.append(UInt8((i/16)*12));values.append(30);values.append(255)}
   let bytes=Data(values)
   let provider=CGDataProvider(data:bytes as CFData)!
   return CIImage(cgImage:CGImage(width:16,height:16,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:64,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!)
  }
  let depth:Depth?=Depth(),intrinsics:K?=K();let sequence:UInt64,capturedAt:Double,cameraGeneration:UUID
 }
}
/* ACTUAL */
@main enum Test {
 @MainActor static func main()async throws {
  let model=try ROBGhostRobotModel(directory:URL(fileURLWithPath:"/private/tmp")),camera=UUID(),scene=UUID()
  let parent=FileManager.default.temporaryDirectory.appendingPathComponent("rob-passive-source-test-\(UUID().uuidString)")
  defer {try?FileManager.default.removeItem(at:parent)}
  let noFeedback=RawScanCapture(model:model,generation:42,parentDirectory:parent)
  let frame=ROBArmRoutineVision.Frame(sequence:1,capturedAt:Date().timeIntervalSince1970*1000,cameraGeneration:camera)
  await noFeedback.append(frame,sceneID:scene,scope:.init(),transform:matrix_identity_double4x4,selfBounds:[],registration:nil,projectionIdentity:"inert-estimate")
  precondition(noFeedback.failure==nil && noFeedback.records.count==1,"Missing feedback must not block passive pixel archive")
  let firstDir=noFeedback.writer!.directory
  defer {try?FileManager.default.removeItem(at:firstDir)}
  let record=noFeedback.records[0],metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:firstDir.appendingPathComponent(record.relativeDirectory+"/frame.json")))as![String:Any]
  precondition((metadata["physicalLeftFeedback"]as![String:Any])["unavailableReason"]as?String != nil)
  let archivedDepth=try Data(contentsOf:firstDir.appendingPathComponent(record.relativeDirectory+"/depth-u16le.raw"))
  precondition(archivedDepth==frame.depth!.millimetersLittleEndian)
  let rgb=try Data(contentsOf:firstDir.appendingPathComponent(record.relativeDirectory+"/rgb888.raw"))
  precondition(rgb[1]<rgb[(15*16)*3+1] && rgb[0]<rgb[15*3],"Original normalized pixel row/column orientation must match depth, never flip")
  for y in 0..<16 {for x in 0..<16 {
   let offset=(y*16+x)*3
   precondition(rgb[offset]==UInt8(x*12) && rgb[offset+1]==UInt8(y*12) && rgb[offset+2]==30,
    "Every rendered archive RGB triple must match known original CGImage row-major source bytes at the same depth pixel")
  }}
  var observations=[ROBWorkspaceCollisionSnapshot.Observation(sequence:1,capturedAtMilliseconds:frame.capturedAt)]
  for sequence in 2...14 {
   let next=ROBArmRoutineVision.Frame(sequence:UInt64(sequence),capturedAt:Date().timeIntervalSince1970*1000,cameraGeneration:camera)
   await noFeedback.append(next,sceneID:scene,scope:.init(),transform:matrix_identity_double4x4,selfBounds:[],registration:nil,projectionIdentity:"inert-estimate")
   observations.append(.init(sequence:next.sequence,capturedAtMilliseconds:next.capturedAt))
  }
  precondition(noFeedback.records.count==14)
  await noFeedback.finish(.init(sceneID:scene,cameraGeneration:camera,observations:observations))
  precondition(noFeedback.report["status"]as?String=="complete")
  let manifest=try JSONDecoder().decode(ROBWorkspaceRawScanArchive.Manifest.self,from:Data(contentsOf:firstDir.appendingPathComponent("manifest.json")))
  precondition(manifest.sourceMapBinding?.observations.count==14 && manifest.sourceMapBinding?.mapFingerprint==String(repeating:"a",count:64))
  let g=ROBAmberGatewayClient.shared
  for arm in ["left","right"]{let sample=ROBAmberGatewayTelemetry(arm,2);g.samples[arm]=sample}
  let withFeedback=RawScanCapture(model:model,generation:42,parentDirectory:parent),frame2=ROBArmRoutineVision.Frame(sequence:2,capturedAt:Date().timeIntervalSince1970*1000,cameraGeneration:camera)
  await withFeedback.append(frame2,sceneID:scene,scope:.init(),transform:matrix_identity_double4x4,selfBounds:[],registration:nil,projectionIdentity:"inert-estimate")
  precondition(withFeedback.failure==nil)
  let dir2=withFeedback.writer!.directory;defer {try?FileManager.default.removeItem(at:dir2)}
  let m2=try JSONSerialization.jsonObject(with:Data(contentsOf:dir2.appendingPathComponent(withFeedback.records[0].relativeDirectory+"/frame.json")))as![String:Any]
  let left=(m2["physicalLeftFeedback"]as![String:Any])["value"]as![String:Any]
  precondition(left["physicalSide"]as?String=="left" && left["gatewayArm"]as?String=="right")
  // Extra/missing map observation cannot claim a complete pixel archive.
  await withFeedback.finish(.init(sceneID:scene,cameraGeneration:camera,observations:[]))
  precondition(withFeedback.report["status"]as?String=="incomplete")
  precondition(manifest.motionAuthority==false && manifest.classificationAuthority==false)
  print("PASS actual passive Search archive: original normalized RGB/depth, source/K/matrix/sampling, missingBOTHq stays explicit+nonblocking, available history uses actual physical/gateway q, exact final-map observation/hash binding, incomplete map link reported; no robot IO")
 }
}
'''.replace('/* ACTUAL */',actual)
with tempfile.TemporaryDirectory(prefix='rob-passive-archive-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-whole-module-optimization','-swift-version','5','-parse-as-library',str(root/'Cerebro/ROBWorkspaceRawScanArchive.swift'),str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True)
