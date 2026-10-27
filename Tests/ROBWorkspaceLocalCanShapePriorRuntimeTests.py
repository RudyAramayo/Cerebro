#!/usr/bin/env python3
"""Numerical tests of the actual local-only cylinder estimator; no devices."""
from pathlib import Path
import argparse,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]

def block(source,marker):
 start=source.index(marker);brace=source.index('{',start);end=brace+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]

STUBS=r'''
import Foundation
import simd
import CryptoKit
struct ROBWorkspaceDetection {
 let visible:Bool;let confidence:Double;let box:[Double]
 var visuallyUsable:Bool {visible && confidence>=0.35 && box.count==4 && box.allSatisfy{(0...1).contains($0)}}
 var usable:Bool {visuallyUsable && box[2]>box[0] && box[3]>box[1]}
}
struct ROBWorkspaceCanSections {
 let top:[Double],middle:[Double],bottom:[Double];let heightMeters:Double,diameterMeters:Double
 static func localKnownEmptyCokeCylinder(base:SIMD3<Double>,axis:SIMD3<Double>,planeRMSEMeters:Double,planePointCount:Int,
    planeSupportFraction:Double,silhouetteIoU:Double,silhouetteMaximumEdgeErrorPixels:Double)->Self? {
  guard planeRMSEMeters<=0.008,planePointCount>=80,planeSupportFraction>=0.65,silhouetteIoU>=0.50 else{return nil}
  let top=base+axis*0.120,middle=base+axis*0.060
  return .init(top:[top.x,top.y,top.z],middle:[middle.x,middle.y,middle.z],bottom:[base.x,base.y,base.z],heightMeters:0.120,diameterMeters:0.066)
 }
}
'''
FIXTURE=r'''
@main struct LocalPriorFixtures {
 static func main() throws {
  let denied=try PriorPolicy(surveyFrontTable:false,physicalCanShapePrior:{false}).permitsLocalCanShapePrior()
  let permitted=try PriorPolicy(surveyFrontTable:false,physicalCanShapePrior:{true}).permitsLocalCanShapePrior()
  let ghost=try PriorPolicy(surveyFrontTable:true,physicalCanShapePrior:{fatalError("Ghost requested physical-trial policy")}).permitsLocalCanShapePrior()
  precondition(!denied && permitted && ghost)
  if CommandLine.arguments.count>1 {
   let capture=URL(fileURLWithPath:CommandLine.arguments[1]),report=URL(fileURLWithPath:CommandLine.arguments[2]),output=URL(fileURLWithPath:CommandLine.arguments[3])
   let bytes=try Data(contentsOf:capture),m=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
   let frames=m["frames"] as! [[String:Any]],f=frames[0],w=f["width"] as! Int,h=f["height"] as! Int,k=f["intrinsics"] as! [Double]
   let raw=try Data(contentsOf:capture.deletingLastPathComponent().appendingPathComponent(f["depthPath"] as! String))
   let hash=SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined();precondition(hash==f["captureSHA256"] as! String && raw.count==w*h*2)
   let encoded=m["initialCameraToRobotColumnMajor"] as! [Double]
   let c=simd_double4x4(columns:(SIMD4(encoded[0],encoded[1],encoded[2],encoded[3]),SIMD4(encoded[4],encoded[5],encoded[6],encoded[7]),SIMD4(encoded[8],encoded[9],encoded[10],encoded[11]),SIMD4(encoded[12],encoded[13],encoded[14],encoded[15])))
   let search=try JSONSerialization.jsonObject(with:Data(contentsOf:report)) as! [String:Any]
   let views=search["views"] as! [[String:Any]],view=views.first{$0["can_section_diagnostics"] != nil}!
   let boxes=(view["can_section_diagnostics"] as! [[String:Any]]).map{ROBWorkspaceDetection(visible:true,confidence:0.7,box:$0["box"] as! [Double])}
   var results:[[String:Any]]=[]
   for box in boxes {
    let result=ROBWorkspaceLocalCanShapePrior.estimate(detection:box,allCanDetections:boxes,width:w,height:h,fx:k[0],fy:k[1],cx:k[2],cy:k[3],depth:{x,y in
     let index=2*(y*w+x);return UInt16(raw[index]) | UInt16(raw[index+1])<<8
    },cameraToRobot:c)
    var item=result.diagnostics;item["source_capture_path"]=capture.path;item["source_depth_sha256"]=hash
    item["original_detector_report"]=report.path;item["detector_boxes_same_held_pose_not_same_exposure"]=true
    results.append(item)
    print("ACTUAL",box.box,result.sections?.middle as Any,result.diagnostics)
   }
   try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys,.prettyPrinted]).write(to:output)
   print("ACTUAL_REPORT",output.path)
   return
  }
  let s=sqrt(0.5),c=simd_double4x4(columns:(SIMD4(0,-1,0,0),SIMD4(-s,0,-s,0),SIMD4(s,0,-s,0),SIMD4(0,0,1.2,1)))
  let inverse=simd_inverse(c),w=640,h=480,fx=490.0,fy=490.0,cx=320.0,cy=240.0,base=SIMD3<Double>(0.50,0,0.75)
  var pixels:[SIMD2<Double>]=[]
  for z in [0.0,0.120] {for i in 0..<64 {
   let theta=Double(i)*2*Double.pi/64,p=inverse*SIMD4(base.x+0.033*cos(theta),base.y+0.033*sin(theta),base.z+z,1)
   pixels.append(SIMD2(fx*p.x/p.z+cx,fy*p.y/p.z+cy))
  }}
  let low=pixels.reduce(pixels[0]){simd_min($0,$1)},high=pixels.reduce(pixels[0]){simd_max($0,$1)}
  let box=[low.x/Double(w-1),low.y/Double(h-1),high.x/Double(w-1),high.y/Double(h-1)]
  let detection=ROBWorkspaceDetection(visible:true,confidence:0.7,box:box)
  func table(_ x:Int,_ y:Int)->UInt16? {
   let q=c*SIMD4((Double(x)-cx)/fx,(Double(y)-cy)/fy,1,0),t=(0.75-1.2)/q.z
   return (0.15...3).contains(t) ? UInt16((t*1000).rounded()) : nil
  }
  func estimate(_ d:ROBWorkspaceDetection = detection,_ depth:(Int,Int)->UInt16? = table)->(sections:ROBWorkspaceCanSections?,diagnostics:[String:Any]) {
   ROBWorkspaceLocalCanShapePrior.estimate(detection:d,allCanDetections:[d],width:w,height:h,fx:fx,fy:fy,cx:cx,cy:cy,depth:depth,cameraToRobot:c)
  }
  let result=estimate();precondition(result.sections != nil,String(describing:result.diagnostics))
  let actual=result.sections!,middle=SIMD3(actual.middle[0],actual.middle[1],actual.middle[2])
  precondition(simd_distance(middle,base+SIMD3(0,0,0.060))<0.005)
  precondition(actual.heightMeters==0.120 && actual.diameterMeters==0.066)
  precondition(JSONSerialization.isValidJSONObject(result.diagnostics))
  let missing=estimate(detection,{_,_ in nil});precondition(missing.sections==nil && missing.diagnostics["rejection_stage"] as! String=="insufficient_local_table_support")
  let noisy=estimate(detection,{x,y in let mm=table(x,y);return ((x*13+y*7)%5==0) ? mm.map{$0+200}:mm})
  precondition(noisy.sections != nil,String(describing:noisy.diagnostics))
  let clipped=ROBWorkspaceDetection(visible:true,confidence:0.7,box:[0,box[1],box[2],box[3]])
  precondition(estimate(clipped).sections==nil)
  let wrong=ROBWorkspaceDetection(visible:true,confidence:0.7,box:[box[0]-0.12,box[1],box[2]+0.12,box[3]])
  precondition(estimate(wrong).sections==nil,"An unrelated wide silhouette passed")
  print("PASS actual local-only cylinder estimator: fresh localtable ring robust to20% depthoutliers; known120×66upright silhouette recoverscenterwithin5mm; missing/clipped/wrongshape reject; JSON evidence explicit")
 }
}
'''

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--capture');parser.add_argument('--report');parser.add_argument('--output');a=parser.parse_args()
 source=(ROOT/'Cerebro/ROBArmRoutineVision.swift').read_text();helper=block(source,'enum ROBWorkspaceLocalCanShapePrior {')
 run=source[source.index('@MainActor @nonobjc func run(targets:'):]
 assert 'permitsLocalCanShapePrior physicalCanShapePrior: () throws -> Bool = {false}' in run
 assert run.count('try permitsLocalCanShapePrior()')>=2
 assert 'collisionEnrollment.capturedAtMilliseconds==frame.capturedAt' in run and 'measuredCamera==nil' in run
 with tempfile.TemporaryDirectory(prefix='rob-local-can-prior-') as folder:
  policy='struct PriorPolicy { let surveyFrontTable:Bool; let physicalCanShapePrior:()throws->Bool;\n'+block(run,'func permitsLocalCanShapePrior() throws -> Bool {')+'\n}'
  p=Path(folder);swift=p/'Fixture.swift';binary=p/'fixture';swift.write_text(STUBS+'\n'+helper+'\n'+policy+'\n'+FIXTURE)
  subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-parse-as-library','-module-cache-path','/private/tmp/cerebro-swift-module-cache',str(swift),'-o',str(binary)],check=True,timeout=60)
  subprocess.run([str(binary)],check=True,timeout=20)
  if a.capture:subprocess.run([str(binary),a.capture,a.report,a.output],check=True,timeout=30)
if __name__=='__main__':main()
