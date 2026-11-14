#!/usr/bin/env python3
"""Actual private archive loader, synthetic bytes only; no robot services."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
import subprocess,tempfile
from ROBMainCameraHeadlessStaticTests import braced_declaration
root=Path(__file__).resolve().parents[1]
trial=(root/'Cerebro/ROBLeftArmTrial.swift').read_text()
loader=braced_declaration(trial,'private struct ROBSourcePixelArchiveInputs {').replace('private struct','struct',1)
replay=braced_declaration((root/'Cerebro/ROBWorkspaceCollisionPlan.swift').read_text(),'    struct ReplayFrame {')
hash_method=braced_declaration((root/'Cerebro/ROBGhostMotionPlan.swift').read_text(),'    static func hash(_ data: Data) -> String {')
prepare=braced_declaration(trial,'    private func prepareSourcePixelSelfReview(')
proof=braced_declaration(trial,'    @MainActor private func reviewCurrentSourcePixelStep(')
assert 'Task.detached' not in prepare+proof and 'sourcePixelQueue.async' in prepare and 'sourcePixelQueue.async' in proof
assert 'scanCollisionScene(' not in prepare and 'prepareView?' not in prepare
assert 'current.fingerprint==fingerprint' in prepare and 'current.cameraGeneration==camera' in prepare
fixture=r'''
import Foundation
import CryptoKit
import Darwin
enum ROBGhostMotionError:Error {case blocked(String)}
enum ROBGhostRobotModel { /* HASH */ }
enum ROBWorkspaceSourcePixelSelf { /* REPLAY */ }
/* LOADER */
@main enum Fixture {
 static func rejected(_ operation:()throws->Void){do{try operation();preconditionFailure("Unsafe private file accepted")}catch{}}
 static func main()async throws {
  typealias A=ROBWorkspaceRawScanArchive
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("rob-pixel-loader-\(UUID().uuidString)")
  defer{try?FileManager.default.removeItem(at:root)}
  let scene=A.Scene(archiveID:UUID(),workspaceSceneID:UUID(),bodyMotionIdentity:"inert-body",gatewayGeneration:42,
   modelID:"inert-model",referenceID:"inert-reference",geometryID:"inert-geometry",mappingID:"inert-mapping")
  let writer=try await A.create(parentDirectory:root,scene:scene),camera=UUID(),json=Data("{\"fixture\":true}".utf8)
  let frame=A.Frame(frameID:UUID(),sequence:1,capturedAtHostMilliseconds:1001,
   rgbCapturedAtHostMilliseconds:.unavailable("inert no sensor"),depthCapturedAtHostMilliseconds:.unavailable("inert no sensor"),
   sourceTimestampJSON:.unavailable("inert no device clock"),cameraGeneration:camera,width:16,height:16,
   rgb888:Data(repeating:33,count:768),depthU16LittleEndian:Data(repeating:3,count:512),infrared:.unavailable("none"),infraredContractJSON:.unavailable("none"),
   intrinsics:[30,30,8,8],sourceContractsJSON:json,runtimeCalibrationJSON:json,imuJSON:.unavailable("none"),actualAppliedNeck:.unavailable("none"),
   physicalLeftFeedback:.unavailable("none"),physicalRightFeedback:.unavailable("none"),cameraToRobotColumnMajor:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
   projectionMethod:"inert",projectionScopeJSON:json,returnSamplingContractJSON:json)
  let record=try await writer.append(frame),fingerprint=String(repeating:"a",count:64)
  let source=try JSONSerialization.data(withJSONObject:["sceneID":scene.workspaceSceneID.uuidString,"cameraGeneration":camera.uuidString,
   "fingerprint":fingerprint,"observations":[["sequence":1,"capturedAtMilliseconds":1001]]],options:.sortedKeys)
  _ = try await writer.finish(sourceMap:.init(workspaceSceneID:scene.workspaceSceneID,mapFingerprint:fingerprint,serializedJSON:source,
   observations:[.init(sequence:1,capturedAtHostMilliseconds:1001,cameraGeneration:camera)]))
  let loaded=try ROBSourcePixelArchiveInputs.load(directory:writer.directory)
  precondition(loaded.frames.count==1 && loaded.frames[0].rgb888==frame.rgb888 && loaded.frames[0].depthU16LittleEndian==frame.depthU16LittleEndian)
  let link=root.appendingPathComponent("symbolic-archive");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:writer.directory)
  rejected{_ = try ROBSourcePixelArchiveInputs.load(directory:link)}
  let rgbPath=writer.directory.appendingPathComponent(record.relativeDirectory+"/rgb888.raw")
  try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:rgbPath.path)
  rejected{_ = try ROBSourcePixelArchiveInputs.load(directory:writer.directory)}
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:rgbPath.path)
  try Data(repeating:34,count:768).write(to:rgbPath)
  rejected{_ = try ROBSourcePixelArchiveInputs.load(directory:writer.directory)}
  try frame.rgb888.write(to:rgbPath)
  let manifestPath=writer.directory.appendingPathComponent("manifest.json"),manifest=try Data(contentsOf:manifestPath)
  var changed=try JSONSerialization.jsonObject(with:manifest)as![String:Any]
  var frames=changed["frames"]as![[String:Any]];frames[0]["relativeDirectory"]="../escape";changed["frames"]=frames
  try JSONSerialization.data(withJSONObject:changed).write(to:manifestPath)
  rejected{_ = try ROBSourcePixelArchiveInputs.load(directory:writer.directory)}
  try manifest.write(to:manifestPath)
  let depthPath=writer.directory.appendingPathComponent(record.relativeDirectory+"/depth-u16le.raw")
  try FileManager.default.removeItem(at:depthPath)
  rejected{_ = try ROBSourcePixelArchiveInputs.load(directory:writer.directory)}
  print("PASS actual source-pixel private loader: original hashes/byte lineage, user-only regular files, source-map binding; rejects world-readable/tampered/missing/traversal/symlink files; serial value-only current factory preparation has no scan/head/Task.detached; no grant/robot IO")
 }
}
'''.replace('/* HASH */',hash_method).replace('/* REPLAY */',replay).replace('/* LOADER */',loader)
with tempfile.TemporaryDirectory(prefix='rob-source-pixel-loader-',dir='/private/tmp')as folder:
 p=Path(folder);(p/'Fixture.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-whole-module-optimization','-swift-version','5','-parse-as-library',str(root/'Cerebro/ROBWorkspaceRawScanArchive.swift'),str(p/'Fixture.swift'),'-o',str(p/'fixture')],check=True)
 subprocess.run([str(p/'fixture')],check=True)
