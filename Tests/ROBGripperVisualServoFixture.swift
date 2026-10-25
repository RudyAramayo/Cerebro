import Foundation
@main enum GripperServoFixture {
 static let width=160,height=120
 static func frame(_ sequence:UInt64,_ time:Double,open:Bool=true,shiftX:Int=0,shiftY:Int=0,q:[Double]=Array(repeating:0,count:7),command:Double?=nil,secondPair:Bool=false)->ROBGripperVisualServo.Frame {
  var bytes=[UInt8](repeating:0,count:width*height*3)
  for y in 0..<height {for x in 0..<width {let v:UInt8=UInt8(65+((x*7919+y*104729+x*y*13)%47));for c in 0..<3 {bytes[(y*width+x)*3+c]=v}}}
  func fingers(_ cx:Int,_ cy:Int) {let centers=open ? [cx-16,cx+16]:[cx-6,cx+6];for center in centers {for y in cy-20...cy+20 {for x in center-3...center+3 {guard x>=0,x<width,y>=0,y<height else{continue};for c in 0..<3 {bytes[(y*width+x)*3+c]=225}}}}}
  fingers(80+shiftX,55+shiftY);if secondPair {fingers(120,55)}
  return .init(width:width,height:height,rgb:Data(bytes),depthMillimeters:Array(repeating:600,count:width*height),fx:120,fy:120,cx:80,cy:60,sequence:sequence,capturedAtMilliseconds:time,scopeIdentity:"actual-camera-context",jointPositions:q,jointCapturedAtMilliseconds:time-20,poseHeldDuringCapture:true,openingCommandAtMilliseconds:command,estimatedImageJacobian:[[200,0,0,0,0,0,0],[0,200,0,0,0,0,0]])
 }
 static func main() {
  setbuf(stdout,nil)
  let cfg=ROBGripperVisualServo.Configuration(jointBounds:Array(repeating:-1.0...1.0,count:7),correctingJointIndices:[0,1])
  let roi=ROBGripperVisualServo.ROI(xMin:0.25,yMin:0.2,xMax:0.70,yMax:0.8)
  let target=ROBGripperVisualServo.Target(id:"unique-can",boxNormalized:[0.60,0.42,0.66,0.51],geometryAssumed:true,assumedDepthMeters:0.60,assumedDiameterMeters:0.066)
  var controller=ROBGripperVisualServo.Controller(configuration:cfg)
  let before=controller.update(frame:frame(1,1000,open:false),target:target,searchROI:roi,nowMilliseconds:1020)
  precondition(before.observation==nil && before.jointTarget==nil)
  let after=controller.update(frame:frame(2,1200,command:1100),target:target,searchROI:roi,nowMilliseconds:1220)
  precondition(after.observation != nil,"True symmetric observed opening should identify actual edge strips")
  precondition(after.observation!.evidenceKind.contains("image_observed"))
  precondition(abs(after.observation!.centerPixels[0]-80)<2)
  precondition(after.diagnostics["estimated_fk_direction_prior_used"]==1 && after.jointTarget != nil)
  precondition(after.jointTarget!.map(abs).max()! <= 0.01000001)
  var q=after.jointTarget!
  let progress=controller.update(frame:frame(3,1400,shiftX:2,q:q),target:target,searchROI:roi,nowMilliseconds:1420)
  precondition(progress.observation != nil && progress.diagnostics["bootstrap_observed_progress_pixels"]! > 0)
  let liftedTarget=ROBGripperVisualServo.Target(id:"unique-can",boxNormalized:[0.60,0.25,0.66,0.34],geometryAssumed:true,assumedDepthMeters:0.60)
  q[1]+=0.01
  let lift=controller.update(frame:frame(4,1600,shiftX:2,shiftY:-4,q:q),target:liftedTarget,searchROI:roi,nowMilliseconds:1620,observationOnly:true)
  precondition(lift.status=="observedOnly" && lift.observation != nil && lift.jointTarget==nil && !lift.readyToGrip)
  var unavailable=ROBGripperVisualServo.Controller(configuration:cfg)
  _=unavailable.update(frame:frame(1,1000),target:target,searchROI:roi,nowMilliseconds:1020)
  let unchanged=unavailable.update(frame:frame(2,1200,command:1100),target:target,searchROI:roi,nowMilliseconds:1220)
  precondition(unchanged.observation==nil && unchanged.jointTarget==nil,"Open ACK/unchanged pixels never identify jaws")
  var bad=frame(5,1800);bad=ROBGripperVisualServo.Frame(width:bad.width,height:bad.height,rgb:bad.rgb,depthMillimeters:bad.depthMillimeters,fx:bad.fx,fy:bad.fy,cx:bad.cx,cy:bad.cy,sequence:bad.sequence,capturedAtMilliseconds:bad.capturedAtMilliseconds,scopeIdentity:"different-runtime",jointPositions:bad.jointPositions,jointCapturedAtMilliseconds:bad.jointCapturedAtMilliseconds,poseHeldDuringCapture:true)
  let changed=controller.update(frame:bad,target:target,searchROI:roi,nowMilliseconds:1820)
  precondition(changed.status=="scopeChanged" && changed.observation==nil)
  let bg=ROBGripperVisualServo.backgroundStability(previous:frame(1,1000),current:frame(2,1200),excluding:[roi])
  precondition(bg.stable && bg.patchCount>=4 && bg.medianMotionPixels==0)
  var wrong=ROBGripperVisualServo.Controller(configuration:cfg)
  _=wrong.update(frame:frame(1,1000,open:false),target:target,searchROI:roi,nowMilliseconds:1020)
  let bootstrap=wrong.update(frame:frame(2,1200,command:1100),target:target,searchROI:roi,nowMilliseconds:1220)
  let failure=wrong.update(frame:frame(3,1400,shiftX:-2,q:bootstrap.jointTarget!),target:target,searchROI:roi,nowMilliseconds:1420)
  precondition(failure.status=="blocked" && failure.jointTarget==nil,"Wrong actual image response must stop estimated bootstrap")
  let latched=wrong.update(frame:frame(4,1600,q:bootstrap.jointTarget!),target:target,searchROI:roi,nowMilliseconds:1620)
  precondition(latched.status=="blocked" && latched.jointTarget==nil)
  var rank=ROBGripperVisualServo.Controller(configuration:cfg)
  _=rank.update(frame:frame(1,1000,open:false),target:target,searchROI:roi,nowMilliseconds:1020)
  var ill=frame(2,1200,command:1100)
  ill.estimatedImageJacobian=[[1000,1000,0,0,0,0,0],[0,1,0,0,0,0,0]]
  let poorlyConditioned=rank.update(frame:ill,target:target,searchROI:roi,nowMilliseconds:1220)
  precondition(poorlyConditioned.observation != nil && poorlyConditioned.status=="needsMeasuredResponse" && poorlyConditioned.jointTarget==nil)
  var sameJoint=Array(repeating:0.0,count:7);sameJoint[0]=0.01
  var moved=frame(3,1400,shiftX:2,q:sameJoint);moved.estimatedImageJacobian=nil
  _=rank.update(frame:moved,target:target,searchROI:roi,nowMilliseconds:1420)
  sameJoint[0]=0.02;moved=frame(4,1600,shiftX:4,shiftY:1,q:sameJoint);moved.estimatedImageJacobian=nil
  let noisyRankOne=rank.update(frame:moved,target:target,searchROI:roi,nowMilliseconds:1620)
  precondition(noisyRankOne.observation != nil && noisyRankOne.diagnostics["measured_joint_image_basis_rank"]==1 && noisyRankOne.jointTarget==nil,"Same joint plus off-axis image noise cannot become a measured 2D basis")
  var repeated=ROBGripperVisualServo.Controller(configuration:cfg)
  _=repeated.update(frame:frame(1,1000,open:false),target:target,searchROI:roi,nowMilliseconds:1020)
  let stale=repeated.update(frame:frame(2,1200,command:1100),target:target,searchROI:roi,nowMilliseconds:2100)
  precondition(stale.status=="unavailable" && stale.observation==nil && stale.jointTarget==nil)
  print("Observed-jaw servo fixture PASS: observed opening/identity, bounded estimated bootstrap and signed progress, failure latch, joint+image rank/conditioning, stale/scope/unchanged-ACK negatives, observation-only lift. Synthetic evidence does not establish real-hardware detector reliability.")
 }
}
