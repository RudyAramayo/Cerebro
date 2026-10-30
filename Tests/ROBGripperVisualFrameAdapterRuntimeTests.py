#!/usr/bin/env python3
"""Exercise the production native RGB-D adapter; no camera or robot linked."""
from pathlib import Path
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Cerebro/ROBArmRoutineVision.swift').read_text()
start = source.index('    func makeGripperVisualServoFrame(')
brace = source.index('{', start)
level = 1
end = brace + 1
while level:
    level += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
enroll_start = source.index('    func ensureActiveForTaskObservation(')
enroll_brace = source.index('{', enroll_start)
level = 1
enroll_end = enroll_brace + 1
while level:
    level += (source[enroll_end] == '{') - (source[enroll_end] == '}')
    enroll_end += 1
enrollment = source[enroll_start:enroll_end]
support = r'''
import AppKit
import Foundation

enum ROBVisualGraspVerifier {
 enum Unavailable:LocalizedError {case evidence(String)
  var errorDescription:String? {if case .evidence(let s)=self{return s};return nil}}
}
enum ROBGripperVisualServo {
 struct Frame {
  let width:Int,height:Int,rgb:Data,depthMillimeters:[UInt16]
  let fx:Double,fy:Double,cx:Double,cy:Double
  let sequence:UInt64,capturedAtMilliseconds:Double,scopeIdentity:String
  let jointPositions:[Double],jointCapturedAtMilliseconds:Double,poseHeldDuringCapture:Bool
  var openingCommandAtMilliseconds:Double?=nil
 }
}
struct Match {var status="matched"}
struct ROBWorkspaceVisualCalibrationTrial {
 var usesOperatorClearedCameraCollisionAdvisory=false
 var cameraGeneration=UUID()
}
struct K {
 var stereoMode:String?,stereoModeSource:String?
 var fx=600.0,fy=610.0,cx=319.5,cy=239.5
 var rgbOutputUndistorted:Bool?=true
 var depthRGBGeometryCorrespondence:Match?=Match()
 func isValid(forWidth:Int,height:Int)->Bool{forWidth==640 && height==480}
}
struct Depth {
 let width=640,height=480
 func distanceMillimeters(x:Int,y:Int)->UInt16? {
  if x<10 && y<10{return nil};return y<240 ? 800:1400
 }
}
final class Adapter {
 let context=CIContext(options:[.useSoftwareRenderer:true])
 var cameraGeneration=UUID()
 let lock=NSLock()
 var active=false,teaching=false,epoch=UUID()
 var observedJawFullHeightDemand=false
 var observedJawTaskStereoMode:String?
 var frames:[String:Frame]=[:],busy=Set<String>(),lastOffer:[String:Double]=[:],inputNotes:[String:String]=[:]
 var lastIncomingCapture:Double?=nil,lastIncomingSequence:UInt64=0,processingMilliseconds=0.0
 var lastInspection:[String:Any]=[:],lastSettlingDiagnostics:[String:Any]=[:]
 struct Frame {
  var image:CIImage,capturedAt:Double,sequence:UInt64=10,cameraGeneration:UUID
  var handsClear=true,depth:Depth?=Depth(),intrinsics:K?=K()
 }
 // This fixture exercises the unchanged default adapter path. The actual
 // native token/factory and its source/route binding have a separate fixture.
 struct HumanClearance {func matches(frame:Frame,scopeIdentity:String)->Bool {false}}
 /* ACTUAL METHOD */
 /* ACTUAL ENROLLMENT */
 /* ACTUAL SOURCE REQUEST */
}
@main enum Test {
 static func main()throws {
  let now=Date().timeIntervalSince1970*1000,adapter=Adapter()
  var pixels=[UInt8](repeating:0,count:640*480*4)
  for y in 0..<480 {for x in 0..<640 {
   let i=(y*640+x)*4
   pixels[i]=y<240 ? 230:5;pixels[i+1]=100;pixels[i+2]=y<240 ? 5:230;pixels[i+3]=255
  }}
  let provider=CGDataProvider(data:Data(pixels) as CFData)!
  let image=CGImage(width:640,height:480,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:640*4,
   space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
   provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  let input=Adapter.Frame(image:CIImage(cgImage:image),capturedAt:now-20,cameraGeneration:adapter.cameraGeneration)
  adapter.active=true;adapter.teaching=true;adapter.frames=["face":input];adapter.busy=["face"]
  let enrolledEpoch=adapter.epoch,enrolledGeneration=adapter.cameraGeneration
  adapter.ensureActiveForTaskObservation()
  precondition(adapter.observedJawFullHeightDemand,"Standing jaw observation requests full camera height")
  precondition(adapter.epoch==enrolledEpoch && adapter.frames["face"]?.sequence==10 && adapter.busy.contains("face") && adapter.teaching,
   "An already-active camera must retain its frames and ongoing consumer state")
  adapter.ensureActiveForTaskObservation(stereoMode:"near_field")
  precondition(!adapter.taskObservationFrameMatchesRequest(input),"Old camera frames satisfied a new mode request")
  var requested=input;requested.intrinsics!.stereoMode="near_field";requested.intrinsics!.stereoModeSource="cli_request"
  precondition(!adapter.taskObservationFrameMatchesRequest(requested),"CLI intent treated as actual readback")
  requested.intrinsics!.stereoModeSource="sdk_initial_config_readback"
  precondition(adapter.taskObservationFrameMatchesRequest(requested))
  requested.intrinsics!.stereoMode="standard";precondition(!adapter.taskObservationFrameMatchesRequest(requested))
  precondition(adapter.epoch==enrolledEpoch && adapter.frames["face"]?.sequence==10)
  adapter.active=false;adapter.ensureActiveForTaskObservation()
  precondition(adapter.active && !adapter.teaching && adapter.epoch != enrolledEpoch && adapter.frames.isEmpty && adapter.busy.isEmpty)
  precondition(adapter.cameraGeneration==enrolledGeneration,"Consumer enrollment must not invent a physical camera restart")
  func convert(_ frame:Adapter.Frame=input,_ q:[Double]=Array(repeating:0,count:7),_ time:Double?=nil,_ held:Bool=true,_ scope:String="exact-held-scope",opening:Double?=nil)throws->ROBGripperVisualServo.Frame {
   try adapter.makeGripperVisualServoFrame(frame:frame,scopeIdentity:scope,jointPositions:q,
    jointCapturedAtMilliseconds:time ?? now-10,poseHeldDuringCapture:held,openingCommandAtMilliseconds:opening,nowMilliseconds:now)
  }
  func rejects(_ body:()throws->Void) {do{try body();fatalError("Invalid native jaw frame admitted")}catch{}}
  let output=try convert()
  precondition(output.width==320 && output.height==240 && output.rgb.count==320*240*3 && output.depthMillimeters.count==320*240)
  precondition(output.fx==300 && output.fy==305 && output.cx==159.5 && output.cy==119.5)
  precondition(output.sequence==10 && output.scopeIdentity=="exact-held-scope" && output.poseHeldDuringCapture)
  func color(_ x:Int,_ y:Int)->[UInt8]{Array(output.rgb[((y*320+x)*3)..<((y*320+x)*3+3)])}
  let top=color(20,20),bottom=color(20,220)
  precondition(top[0]>200 && top[2]<20 && bottom[0]<20 && bottom[2]>200,"RGB orientation/channel mismatch")
  precondition(output.depthMillimeters[20*320+20]==800 && output.depthMillimeters[220*320+20]==1400,"RGB/depth row mismatch")
  precondition(output.depthMillimeters[0]==0,"Missing depth must stay missing")
  let recent=try convert(opening:now-30_000)
  precondition(recent.openingCommandAtMilliseconds==now-30_000)
  let expired=try convert(opening:now-30_001)
  precondition(expired.openingCommandAtMilliseconds==nil && expired.capturedAtMilliseconds==input.capturedAt,
   "An expired opening event must not invalidate or retimestamp a fresh observation")
  rejects{_=try convert(opening:now+1)}
  rejects{_=try convert(opening:.nan)}
  var historical=input;historical.capturedAt=now-260
  let synchronized=try convert(historical,Array(repeating:0,count:7),now-265)
  precondition(synchronized.jointCapturedAtMilliseconds==now-265,"Historical feedback must retain its real exposure-matched time")
  var bad=input;bad.capturedAt=now-701;rejects{_=try convert(bad)}
  bad=input;bad.capturedAt=now+1;rejects{_=try convert(bad)}
  bad=input;bad.handsClear=false;rejects{_=try convert(bad)}
  bad=input;bad.cameraGeneration=UUID();rejects{_=try convert(bad)}
  bad=input;bad.intrinsics?.rgbOutputUndistorted=false;rejects{_=try convert(bad)}
  bad=input;bad.intrinsics?.depthRGBGeometryCorrespondence?.status="unmatched";rejects{_=try convert(bad)}
  bad=input;bad.depth=nil;rejects{_=try convert(bad)}
  rejects{_=try convert(input,[0,0])};rejects{_=try convert(input,[.nan,0,0,0,0,0,0])}
  rejects{_=try convert(input,Array(repeating:0,count:7),now-200)}
  rejects{_=try convert(input,Array(repeating:0,count:7),now+1)}
  rejects{_=try convert(input,Array(repeating:0,count:7),nil,false)}
  rejects{_=try convert(input,Array(repeating:0,count:7),nil,true,"")}
  print("PASS actual observed-jaw native adapter: RGB channels/orientation align with raw depth; rescaled K; missing depth retained; fresh held scope/CAN/source/hands guards; no hardware")
 }
}
'''.replace('/* ACTUAL METHOD */', method).replace('/* ACTUAL ENROLLMENT */', enrollment).replace('/* ACTUAL SOURCE REQUEST */',braced_declaration(source,'    func taskObservationFrameMatchesRequest('))
with tempfile.TemporaryDirectory(prefix='rob-jaw-frame-') as tmp:
    folder = Path(tmp)
    swift = folder / 'Fixture.swift'
    swift.write_text(support)
    binary = folder / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(ROOT / 'Cerebro/ROBArmJointLimits.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
