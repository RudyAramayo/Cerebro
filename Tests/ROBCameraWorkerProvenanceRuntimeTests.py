#!/usr/bin/env python3
"""Decode real producer headers through the actual Swift header/K mapping."""
from pathlib import Path
import json
import subprocess
import tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
from DepthCameraIPCFixtureTests import load_service, FakeRGBFrame, FakeDepthFrame, FakeMonoFrame

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Cerebro/CameraManager.swift').read_text()
structure=braced_declaration(source,'struct CameraIntrinsics:')
header=braced_declaration(source,'private struct DepthCameraPacketHeader:')
start=source.index('header.rgbIntrinsics.flatMap { values in')
opening=source.index('{',start);depth,end=1,opening+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
mapping=source[start:end]
service=load_service()
packet,*_=service.frame_payload(FakeRGBFrame(),FakeDepthFrame(),FakeMonoFrame((7,8)),FakeMonoFrame((9,10)),
                               [100.,0.,1.,0.,101.,0.5,0.,0.,1.])
actual=json.loads(packet)
legacy={k:v for k,v in actual.items()if k not in ('running_service_source_sha256','rgb_output_undistorted')}
replacement={**actual,'running_service_source_sha256':'d'*64,'rgb_output_undistorted':False}
fixture=r'''
import Foundation
struct CameraInertialObservation:Decodable,Sendable {var isValid:Bool {true}}
struct ROBChessPieceDetection:Decodable {}
/* INTRINSICS */
/* HEADER */
private func mapped(_ header:DepthCameraPacketHeader)->CameraIntrinsics? {return /* MAPPING */}
@main enum Fixtures {
    static func main()throws {
        let decoder=JSONDecoder()
        let packets=try CommandLine.arguments.dropFirst().map{try decoder.decode(DepthCameraPacketHeader.self,from:Data(contentsOf:URL(fileURLWithPath:$0)))}
        let current=mapped(packets[0])!,old=mapped(packets[1])!,replacement=mapped(packets[2])!
        precondition(current.cameraServiceSourceSHA256=="/* EXPECTED_SHA */" && current.rgbOutputUndistorted==true)
        precondition(current.fx==100 && current.fy==101 && current.cx==1 && current.cy==0.5)
        precondition(old.cameraServiceSourceSHA256==nil && old.rgbOutputUndistorted==nil && old.isValid(forWidth:2,height:1),"Legacy viewing invented provenance or lost valid K")
        precondition(replacement.cameraServiceSourceSHA256==String(repeating:"d",count:64) && replacement.rgbOutputUndistorted==false,"Frame provenance was replaced by an app/source assumption")
        print("Camera worker provenance runtime passed: actual header-to-intrinsics mapping preserves source SHA/flag, legacy nil and explicit false")
    }
}
'''.replace('/* INTRINSICS */',structure).replace('/* HEADER */',header).replace('/* MAPPING */',mapping).replace('/* EXPECTED_SHA */',actual['running_service_source_sha256'])
with tempfile.TemporaryDirectory(prefix='rob-camera-worker-provenance-',dir='/private/tmp')as directory:
    root=Path(directory);paths=[]
    for name,value in [('current',actual),('legacy',legacy),('replacement',replacement)]:
        path=root/(name+'.json');path.write_text(json.dumps(value));paths.append(str(path))
    swift=root/'Fixture.swift';swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(swift),'-o',str(root/'fixture')],check=True)
    subprocess.run([str(root/'fixture'),*paths],check=True)
