#!/usr/bin/env python3
"""Run actual belly demand methods with a fake camera; no devices or services."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'Cerebro/ROBBellyCameraWindowController.swift').read_text()
def method(signature):
 start=source.index(signature);depth=0;quoted=False;escaped=False
 for i in range(source.index('{',start),len(source)):
  c=source[i]
  if quoted:
   if escaped:escaped=False
   elif c=='\\':escaped=True
   elif c=='"':quoted=False
  elif c=='"':quoted=True
  elif c=='{':depth+=1
  elif c=='}':
   depth-=1
   if depth==0:return source[start:i+1]
 raise AssertionError(signature)
methods='\n'.join(method(s) for s in ['    @objc private func qrCalibrationDemandDidChange(', '    private func applyRecordingDemand()', '    private func reconcileCameraSession()'])
fixture='''import AppKit
@MainActor enum ROBBellyQRCalibrationWindowController {
 static let captureResolution="1280x800"
}
enum Role {case belly}
struct Demand {var active=false;var resolutionOverride:String?=nil}
@MainActor final class ROBRecordingCoordinator {
 static let shared=ROBRecordingCoordinator();var demand=Demand()
 func cameraCaptureDemand(for role:Role)->Demand {demand}
}
@MainActor final class ROBTorsoControlCenter {static let shared=ROBTorsoControlCenter();var cameraDemandActive=false}
@MainActor final class FakeManager {
 var resolutions:[String?]=[];var starts=0;var stops=0
 func setCaptureResolutionOverride(_ value:String?) {resolutions.append(value)}
 func startSession()throws {starts+=1}
 func stopSession()throws {stops+=1}
}
@MainActor final class Form:NSObject {
 let manager=FakeManager()
 var bellyCameraManager:FakeManager?;var qrCalibrationCaptureID:String?
 var recordingDemandActive=false,armRoutineDemand=false,navigationDemandActive=false,cameraViewIsVisible=false,remoteVideoDemandActive=false,cameraSessionIsRequested=false
 override init(){super.init();bellyCameraManager=manager}
 func update(){applyRecordingDemand();reconcileCameraSession()}
 func deliver(active:Bool,id:String,resolution:String?=nil){
 var info:[String:Any]=["active":active,"captureID":id]
 if let resolution {info["resolution"]=resolution}
 qrCalibrationDemandDidChange(Notification(name:Notification.Name("test"),userInfo:info))
 }
/*METHODS*/
}
@main struct Test {
 @MainActor static func main(){
 let form=Form();form.navigationDemandActive=true;form.update()
 precondition(form.manager.resolutions.last!=="640x400")
 precondition(form.manager.starts==1)
 form.deliver(active:true,id:"A",resolution:"1280x800")
 precondition(form.manager.resolutions.last!=="1280x800")
 form.deliver(active:true,id:"B",resolution:"1280x800")
 let calls=form.manager.resolutions.count
 form.deliver(active:false,id:"A")
 precondition(form.manager.resolutions.count==calls && form.qrCalibrationCaptureID=="B")
 ROBRecordingCoordinator.shared.demand=Demand(active:true,resolutionOverride:"1920x1080")
 form.deliver(active:false,id:"B")
 precondition(form.manager.resolutions.last!=="1920x1080" && form.qrCalibrationCaptureID==nil)
 form.deliver(active:true,id:"C",resolution:"640x400")
 precondition(form.qrCalibrationCaptureID==nil,"Unapproved resolution was accepted")
 form.navigationDemandActive=false;ROBRecordingCoordinator.shared.demand=Demand();form.update()
 precondition(form.manager.resolutions.last! == nil && form.manager.stops==1)
 let captureOnly=Form();captureOnly.deliver(active:true,id:"alone",resolution:"1280x800")
 precondition(captureOnly.manager.starts==1 && captureOnly.cameraSessionIsRequested)
 captureOnly.deliver(active:false,id:"alone")
 precondition(captureOnly.manager.stops==1 && !captureOnly.cameraSessionIsRequested)
 print("PASS belly HD demand: scoped begin/end, stale release rejected, prior recording/navigation resolution restored, capture-only streaming stops; no camera/robot linked")
 }
}
'''.replace('/*METHODS*/',methods)
# Space the optional force unwrap and equality; avoids a !== identity operator.
fixture=fixture.replace('last!==','last! == ')
with tempfile.TemporaryDirectory(prefix='rob-belly-demand-',dir='/private/tmp') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-framework','AppKit',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 r=subprocess.run([str(p/'test')],capture_output=True,text=True,timeout=10)
 if r.returncode:raise AssertionError(r.stdout+r.stderr)
 print(r.stdout.strip())
