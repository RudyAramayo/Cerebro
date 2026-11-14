import Foundation
import simd
@main struct TeleoperationFixture {
 static func rejects(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch {} }
 static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  _ = try ROBGhostRobotModel(directory: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
  let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  rejects { _ = try ROBArmTeleoperationPlanner(directory: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"), calibrationURL: missing) }
  let identity = matrix_identity_double4x4
  var sample = ROBShadowTrackingSample(trackingID: UUID(), sampleID: 1, ageMilliseconds: 10, quality: "tracked", pose: ROBShadowPose(position: [0,0,0], quaternion: [0,0,0,1]))
  let command = ROBArmTeleoperationCommand(action: .clutch, arm: "left", clutchID: UUID(), authorityID: UUID(), tracking: sample)
  let request = ROBArmTeleoperationRequest(controllerID: UUID(), sessionID: UUID(), sequence: 1, command: command, issuedAt: 100)
  let data = try ROBArmTeleoperationProtocol.encode(request)
  let decoded = try ROBArmTeleoperationProtocol.request(data, now: 100.01)
  precondition(decoded == request)
  rejects { _ = try ROBArmTeleoperationProtocol.request(data, now: 100.2) }
  rejects { _ = try ROBArmTeleoperationProtocol.request(data, now: 99.8) }
  var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  object["extra"] = true
  let extra = try JSONSerialization.data(withJSONObject: object)
  rejects { _ = try ROBArmTeleoperationProtocol.request(extra, now: 100) }
  var clutch = try ROBArmTeleoperationClutch(sample: sample, tool: identity, scale: 0.2)
  let stationary = try clutch.target(from: identity, seconds: 0.7)
  precondition(simd_length(ROBSerialChain.translation(stationary)) < 1e-10)
  sample.sampleID = 2; sample.pose.position = [0,0,-0.1]
  try clutch.update(sample)
  let target = try clutch.target(from: identity, seconds: 0.7)
  precondition(abs(target[3].x - 0.02) < 1e-8 && abs(target[3].y) < 1e-8)
  rejects { try clutch.update(sample) }
  sample.sampleID = 3; sample.pose.position = [1,0,0]
  rejects { try clutch.update(sample) }
  sample.pose.position = [0,0,0]; sample.trackingID = UUID()
  rejects { try clutch.update(sample) }
  sample.ageMilliseconds = 151
  rejects { _ = try ROBArmTeleoperationClutch(sample: sample, tool: identity, scale: 0.2) }
  print("Teleoperation fixtures passed: protocol freshness, unknown fields, relative axes, scale, replay, jumps and tracking loss.")
 }
}
