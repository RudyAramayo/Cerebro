#!/usr/bin/env python3
"""Exercise actual bounded conversation grounding with inert native statuses."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


SUPPORT = r'''
import Foundation
@MainActor final class ROBArmRoutineVision {
 static let shared=ROBArmRoutineVision();var health:[String:Any]=[:];var reads=0
 func healthSnapshot()->NSDictionary {reads+=1;return health as NSDictionary}
}
@MainActor final class ROBLeftArmTrial {
 static let shared=ROBLeftArmTrial();var isRunning=false,status="idle"
}
@MainActor final class ROBArmRoutineCoordinator {
 static let shared=ROBArmRoutineCoordinator();var isRunning=false,status="idle"
}
struct Item {let label:String}
struct Piece {let type:String}
struct Quality {var state="stopped"}
struct InstructionContextFixture {
 let systemInstruction:String,usesEmbodiedCameraContext:Bool,exposesRobotActionTool:Bool
 static let embodiedMotionContract="EXISTING_NATIVE_TOOL_POLICY"
 __SYSTEM_INSTRUCTION__
}
struct SceneSnapshot {
 var mlxIdentifiedPeople:[String]=[],people:[Int]=[],objects:[Item]=[],chessPieces:[Piece]=[]
 var sidewalkConfidence=0.0,sidewalkCenterDeviation=0.0,cameraQuality=Quality()
 func JSONString()throws->String {"{}"}
 __CONTEXT__
 __SUMMARY__
}
'''

FIXTURE = r'''
@main enum GroundingFixtures {
 static var checks=0
 static func expect(_ value:Bool,_ detail:String) {checks+=1;precondition(value,detail)}
 static func decode(_ text:String)throws->[String:Any] {
  let start=text.range(of:"<native_status>")!.upperBound,end=text.range(of:"</native_status>")!.lowerBound
  return try JSONSerialization.jsonObject(with:Data(text[start..<end].utf8))as![String:Any]
 }
 @MainActor static func main()async throws {
  let candidates=(0..<5).map{i->[String:Any] in
   ["target":"can","score":0.7,"box":[0.1+Double(i)*0.1,0.1,0.15+Double(i)*0.1,0.3]]
  }
  func health(captured:Double=1000,sequence:UInt64=42,active:Bool=true,
              rows:[[String:Any]]?=nil)->[String:Any] {
   ["active":active,"input_sequence":9999,"input_age_ms":1,"analysis_age_ms":1,
    "private_receipt":"DO_NOT_COPY_RECEIPT","transcript":"DO_NOT_COPY_TRANSCRIPT",
    "inspection":["assessment":"workspace_object_detector","provider":"owlv2",
     "input_sequence":sequence,"input_captured_at_ms":captured,"candidates":rows ?? candidates,
     "latest_input_file":"DO_NOT_COPY_PATH","image":"DO_NOT_COPY_IMAGE"]]
  }
  func context(_ h:[String:Any],now:Double=1500,running:Bool=true,status:String="Searching cans DO_NOT_COPY_STATUS")throws->(String,[String:Any],[String:Any]) {
   let text=ROBConversationGrounding.nativeStatusContext(health:h,armTaskRunning:running,armTaskStatus:status,nowMilliseconds:now)
   let value=try decode(text);return(text,value,value["workspace_detector"]as![String:Any])
  }
  let missing=try context([:])
  expect(missing.2["observation_status"]as?String=="unavailable_or_invalid_source","Missing report became a negative observation")
  expect(missing.2["recorded_can_candidate_boxes"]is NSNull,"Missing detection became zero cans")
  let seen=try context(health())
  expect(seen.2["recorded_can_candidate_boxes"]as?Int==5,"Native five-can observation was lost")
  expect(seen.2["original_capture_time_ms"]as?Double==1000 && seen.2["source_age_ms"]as?Double==500,"Observation restamped")
  expect(seen.2["source_sequence"]as?Int==42,"Latest input packet substituted for detector source")
  expect(seen.2["current_view_confirmed"]as?Bool==false && seen.2["object_absence_confirmed"]as?Bool==false,"Unbound view/absence became confirmed")
  expect(seen.1["authorizes_actions"]as?Bool==false && seen.1["verified_task_completion"]as?Bool==false,"Read-only context created authority/completion")
  expect(!seen.0.contains("DO_NOT_COPY"),"Private fields, image, path or raw task text leaked")
  let stale=try context(health(),now:9000)
  expect(stale.2["observation_status"]as?String=="stale_recorded_observation" && stale.2["source_age_ms"]as?Double==8000,"New camera callbacks refreshed stale detection")
  expect(stale.2["recorded_can_candidate_boxes"]as?Int==5,"Historical positive silently became zero")
  let zero=try context(health(rows:[]))
  expect(zero.2["recorded_can_candidate_boxes"]as?Int==0 && zero.2["object_absence_confirmed"]as?Bool==false,"Zero boxes proved whole-workspace absence")
  let inactive=try context(health(active:false),running:false)
  expect(inactive.2["feed_active"]as?Bool==false && (inactive.1["arm_task"]as?[String:Any])?["phase"]as?String=="not_running","Inactive or stopped task was presented as healthy idle")
  expect((inactive.1["arm_task"]as?[String:Any])?["scope"]as?String=="native_arm_trial_and_routine","Arm status implied coverage of unqueried motion owners")
  for h in [health(captured:2000),health(captured:.nan),health(sequence:0)] {
   let bad=try context(h)
   expect(bad.2["observation_status"]as?String=="unavailable_or_invalid_source" && bad.2["recorded_can_candidate_boxes"]is NSNull,"Invalid/future source became current evidence")
  }
  let low:[[String:Any]]=[["target":"can","score":0.34,"box":[0.1,0.1,0.2,0.2]],
      ["target":"can","score":0.8,"box":[0.2,0.2,0.1,0.1]],
      ["target":"DO_NOT_COPY","score":0.8,"box":[0.1,0.1,0.2,0.2]]]
  expect(try context(health(rows:low)).2["recorded_can_candidate_boxes"]as?Int==0,"Invalid or unsupported candidates counted")
  let bounded=try context(health(rows:Array(repeating:candidates[0],count:100)))
  expect(bounded.2["recorded_can_candidate_boxes"]as?Int==32 && bounded.0.utf8.count<2500,"Unbounded detector context")
  let emptyScene=SceneSnapshot().formattedNaturalLanguageContext()
  expect(emptyScene.contains("person presence is unconfirmed") && emptyScene.contains("not a negative detection"),"Empty natural context asserted absence")
  expect(!emptyScene.contains("No people are currently visible") && !emptyScene.contains("No sidewalk or pavement"),"Old false negative wording survived")
  let recorded=SceneSnapshot(objects:[Item(label:"soda can")]).formattedNaturalLanguageContext()
  expect(recorded.contains("Recorded generic scene labels") && recorded.contains("current forward view are unconfirmed"),"Generic panorama labels became current forward evidence")
  let cloud=try SceneSnapshot().languageModelContext()
  expect(cloud.contains("ROB is a physical robot") && cloud.contains("not confirmed absence") && cloud.contains("context assembly time"),"Cloud context omitted embodied/unknown/freshness contract")
  expect(cloud.contains("Actual fresh supplied camera images or video may support current visual observations") && cloud.contains("Declared tools may request actions"),"Grounding denied actual fresh vision or existing native tools")
  let isolated=InstructionContextFixture(systemInstruction:"ISOLATED_MESSAGES_ORIGINAL",usesEmbodiedCameraContext:false,exposesRobotActionTool:false)
  expect(isolated.motionSystemInstruction==isolated.systemInstruction,"Nonembodied tool-free Messages system instruction changed")
  for flags in [(true,false),(false,true),(true,true)] {
   let configuration=InstructionContextFixture(systemInstruction:"ORIGINAL",usesEmbodiedCameraContext:flags.0,exposesRobotActionTool:flags.1)
   expect(configuration.motionSystemInstruction.contains(ROBConversationGrounding.contract),"Embodied/tool session missed grounding")
   expect(configuration.motionSystemInstruction.contains("EXISTING_NATIVE_TOOL_POLICY")==flags.1,"Existing native-tool exposure changed")
  }
  ROBArmRoutineVision.shared.health=health();ROBLeftArmTrial.shared.isRunning=true;ROBLeftArmTrial.shared.status="Planning DO_NOT_COPY_STATUS"
  let adapter=try decode(ROBConversationNativeStatus.context())
  expect((adapter["arm_task"]as?[String:Any])?["phase"]as?String=="planning_or_reviewing","Native task status was ignored")
  let before=ROBArmRoutineVision.shared.reads
  let offMain=await Task.detached {ROBConversationNativeStatus.synchronousContext()}.value
  expect(offMain.contains("unavailable") && ROBArmRoutineVision.shared.reads==before,"Off-main conversation read UI-owned status or invented freshness")
  print("PASS \(checks) actual conversation-grounding checks: missing versus zero/stale/native5boxes, original times/current-view uncertainty, bounded private-field-free status, truthful non-dispatching embodiment, actor read-only adapter; no model, hardware or authority")
 }
}
'''


def main():
    scene = (ROOT / 'Cerebro/ROBSceneSnapshot.swift').read_text()
    ai = (ROOT / 'Cerebro/ROBAI.swift').read_text()
    protocol = (ROOT / 'Cerebro/GeminiRoboticsProtocol.swift').read_text()
    helper = block(protocol, 'enum ROBConversationGrounding {')
    adapter = block(ai, 'private enum ROBConversationNativeStatus {')
    # The adapter reads bounded native facts only, never command/approval paths.
    assert all(word not in adapter for word in ['sendApproved', 'requestLocal', 'controlGripper', 'captureBlocker', 'appendConversation'])
    for marker in ['public func sendText(_ text: String, speechWordiness:', 'public func sendRecognizedSpeechText(']:
        assert 'ROBConversationNativeStatus.synchronousContext()' in block(ai, marker)
    fallback = block(ai, 'private func generateReply(to rawPrompt: String)')
    assert 'await MainActor.run {ROBConversationNativeStatus.context()}' in fallback
    local_actor = ai[ai.index('private actor ROBLocalConversationFallback {'):]
    for marker in ['private static func generateWithAppleFoundationModels(', 'private static func mlxPrompt(']:
        actual = block(local_actor, marker)
        assert 'ROBConversationGrounding.contract' in actual
        assert 'no tools' in actual or 'cannot browse, call tools' in actual
    assert 'ROBConversationGrounding.contract' in block(protocol, 'var motionSystemInstruction: String')
    source = SUPPORT.replace('__CONTEXT__', block(scene, 'public func languageModelContext() throws -> String'))
    source = source.replace('__SUMMARY__', block(scene, 'func formattedNaturalLanguageContext() -> String'))
    source = source.replace('__SYSTEM_INSTRUCTION__', block(protocol, 'var motionSystemInstruction: String'))
    with tempfile.TemporaryDirectory(prefix='rob-conversation-grounding-') as folder:
        path = Path(folder)
        swift, binary = path / 'fixture.swift', path / 'fixture'
        swift.write_text(source + '\n' + helper + '\n' + adapter + '\n' + FIXTURE)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                        '-module-cache-path', '/private/tmp/cerebro-swift-module-cache', str(swift), '-o', str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()
