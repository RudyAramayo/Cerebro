import Foundation

/// Image observations and a task-local image-response controller. This helper
/// never sends motion, grants permission, certifies clearance, or substitutes
/// an FK projection for observed fingers. All output targets need independent
/// full-arm/table/body review by the owning trial.
enum ROBGripperVisualServo {
    struct Frame: Sendable {
        let width:Int,height:Int
        let rgb:Data
        let depthMillimeters:[UInt16]
        let fx:Double,fy:Double,cx:Double,cy:Double
        let sequence:UInt64
        let capturedAtMilliseconds:Double
        let scopeIdentity:String
        let jointPositions:[Double]
        let jointCapturedAtMilliseconds:Double
        let poseHeldDuringCapture:Bool
        var openingCommandAtMilliseconds:Double? = nil
        /// Optional 2x7 FK image-response prior, NEVER an observed Jacobian.
        var estimatedImageJacobian:[[Double]]? = nil
        var gripperPosition:Double? = nil
        var gripperCapturedAtMilliseconds:Double? = nil
    }
    struct ROI:Sendable {let xMin:Double,yMin:Double,xMax:Double,yMax:Double}
    struct Target:Sendable {
        let id:String
        let boxNormalized:[Double]
        var geometryAssumed=false
        var assumedDepthMeters:Double? = nil
        var assumedDiameterMeters:Double? = nil
        var measuredDepthMeters:Double? = nil
    }
    struct Configuration:Sendable {
        let jointBounds:[ClosedRange<Double>]
        let correctingJointIndices:[Int]
        var maximumCorrectionRadians=0.010
        var maximumImageCorrectionPixels=6.0
        var alignmentTolerancePixels=3.0
        var maximumIterations=6
        var minimumFingerLengthPixels=8
        var maximumFrameAgeMilliseconds=750.0
    }
    struct JawObservation:Codable,Equatable,Sendable {
        let centerPixels:[Double]
        let tipsPixels:[[Double]]
        let openingPixels:Double
        let openingMeters:Double?
        let confidence:Double
        let evidenceKind:String
        let sequence:UInt64
        let capturedAtMilliseconds:Double
        let scopeIdentity:String
    }
    struct Decision:Sendable {
        let status:String,reason:String
        let observation:JawObservation?
        let canMiddlePixels:[Double]
        let pixelError:[Double]?
        let jointTarget:[Double]?
        /// Image/aperture alignment only; NEVER physical motion authority.
        let readyToGrip:Bool
        let diagnostics:[String:Double]
    }
    private struct V:Sendable {
        var x:Double,y:Double
        static func +(_ a:V,_ b:V)->V{.init(x:a.x+b.x,y:a.y+b.y)}
        static func -(_ a:V,_ b:V)->V{.init(x:a.x-b.x,y:a.y-b.y)}
        static func *(_ a:V,_ b:Double)->V{.init(x:a.x*b,y:a.y*b)}
        var length:Double{hypot(x,y)}
        func dot(_ b:V)->Double{x*b.x+y*b.y}
        var array:[Double]{[x,y]}
    }
    private struct Line:Sendable {let angle:Double,rho:Double,lo:Double,hi:Double,sign:Double,strength:Double
        var n:V{.init(x:cos(angle),y:sin(angle))};var t:V{.init(x:-sin(angle),y:cos(angle))}
        var center:V{n*rho+t*((lo+hi)/2)};var length:Double{hi-lo}
    }
    private struct Pair:Sendable {
        let left:Line,right:Line,outerLeft:Line,outerRight:Line,lo:Double,hi:Double,score:Double
        var n:V{left.n};var t:V{left.t};var gap:Double{right.rho-left.rho}
        var center:V{n*((left.rho+right.rho)/2)+t*((lo+hi)/2)}
        var tips:[V]{[n*left.rho+t*hi,n*right.rho+t*hi]}
    }
    private struct Seen:Sendable {let frame:Frame,gray:[Double],lines:[Line],pairs:[Pair]}
    private struct Response:Sendable {let q:[Double],pixels:V,atQ:[Double],capturedAt:Double}
    struct Controller:Sendable {
        let configuration:Configuration
        private var previous:Seen?
        private var identified:Pair?
        private var identifiedFrame:Frame?
        private var identifiedGray:[Double]?
        private var responses:[Response]=[]
        private var scope:String?,targetID:String?
        private var initialCan:V?
        private var alignedCount=0,iterations=0,bootstrapCount=0
        private var pendingBootstrap:(q:[Double],error:V,predicted:V)?
        private var terminalFailure:String?
        init(configuration:Configuration){self.configuration=configuration}
        mutating func reset(){previous=nil;identified=nil;identifiedFrame=nil;identifiedGray=nil;responses=[];scope=nil;targetID=nil;initialCan=nil;alignedCount=0;iterations=0;bootstrapCount=0;pendingBootstrap=nil;terminalFailure=nil}
        mutating func update(frame:Frame,target:Target,searchROI:ROI,nowMilliseconds:Double,observationOnly:Bool=false)->Decision {
            var d:[String:Double]=["fk_pixels_used_as_observed":0,"full_6d_calibration_established":0,"independent_collision_review_required":1,
                "geometry_assumed":target.geometryAssumed ? 1:0,"range_verified":0]
            var middle:[Double]=[]
            func answer(_ status:String,_ reason:String,_ observation:JawObservation?=nil,_ error:[Double]?=nil,_ q:[Double]?=nil,_ ready:Bool=false)->Decision {
                .init(status:status,reason:reason,observation:observation,canMiddlePixels:middle,pixelError:error,jointTarget:q,readyToGrip:ready,diagnostics:d)
            }
            if let terminalFailure {return answer("blocked",terminalFailure)}
            guard frame.width>=24,frame.height>=24,frame.width<=4096,frame.height<=4096,
                  frame.rgb.count==frame.width*frame.height*3,frame.depthMillimeters.count==frame.width*frame.height,
                  [frame.fx,frame.fy,frame.cx,frame.cy,frame.capturedAtMilliseconds,frame.jointCapturedAtMilliseconds,nowMilliseconds].allSatisfy(\.isFinite),
                  frame.fx>0,frame.fy>0,!frame.scopeIdentity.isEmpty,frame.sequence>0,frame.poseHeldDuringCapture,
                  (0...configuration.maximumFrameAgeMilliseconds).contains(nowMilliseconds-frame.capturedAtMilliseconds),
                  (0...700).contains(nowMilliseconds-frame.jointCapturedAtMilliseconds),
                  abs(frame.capturedAtMilliseconds-frame.jointCapturedAtMilliseconds)<=150,frame.jointPositions.count==7,
                  configuration.jointBounds.count==7,zip(frame.jointPositions,configuration.jointBounds).allSatisfy({$0.isFinite && $1.contains($0)}),
                  !configuration.correctingJointIndices.isEmpty,Set(configuration.correctingJointIndices).count==configuration.correctingJointIndices.count,
                  configuration.correctingJointIndices.allSatisfy({(0..<7).contains($0)}),
                  configuration.maximumCorrectionRadians.isFinite,configuration.maximumCorrectionRadians>0,configuration.maximumCorrectionRadians<=0.010,
                  configuration.maximumImageCorrectionPixels.isFinite,(0.1...6).contains(configuration.maximumImageCorrectionPixels),
                  configuration.alignmentTolerancePixels.isFinite,(0.1...6).contains(configuration.alignmentTolerancePixels),
                  (1...6).contains(configuration.maximumIterations), (4...100).contains(configuration.minimumFingerLengthPixels),
                  configuration.maximumFrameAgeMilliseconds.isFinite,(1...750).contains(configuration.maximumFrameAgeMilliseconds),
                  target.boxNormalized.count==4,target.boxNormalized.allSatisfy({$0.isFinite && (0...1).contains($0)}),
                  target.boxNormalized[2]>target.boxNormalized[0],target.boxNormalized[3]>target.boxNormalized[1],!target.id.isEmpty else {
                return answer("unavailable","Fresh matched image/depth, actual held joint feedback, valid target and bounded configuration are required.")
            }
            let can=V(x:(target.boxNormalized[0]+target.boxNormalized[2])*Double(frame.width-1)/2,
                      y:(target.boxNormalized[1]+target.boxNormalized[3])*Double(frame.height-1)/2);middle=can.array
            if let scope,scope != frame.scopeIdentity {reset();return answer("scopeChanged","Camera/head/body/source scope changed; discard image identity and measured response history.")}
            if let targetID,targetID != target.id {reset();return answer("targetChanged","The selected can identity changed; reacquire this task's can before any correction.")}
            scope=frame.scopeIdentity;targetID=target.id
            if !observationOnly,let initialCan,(can-initialCan).length>6 {alignedCount=0;return answer("targetMoved","Observed can middle moved beyond the bounded image corridor; hold and reobserve/replan.")}
            if initialCan==nil {initialCan=can}
            if let p=previous,frame.sequence<=p.frame.sequence || frame.capturedAtMilliseconds<=p.frame.capturedAtMilliseconds {
                return answer("unavailable","An advancing original image is required; repeated pixels cannot identify or control jaws.")
            }
            let gray:[Double]=ROBGripperVisualServo.grayscale(frame.rgb)
            let detected=ROBGripperVisualServo.detect(gray:gray,width:frame.width,height:frame.height,roi:searchROI,minLength:configuration.minimumFingerLengthPixels)
            if let prior=previous {
                let bg=ROBGripperVisualServo.background(prior.gray,gray,width:frame.width,height:frame.height,excluding:[searchROI,.init(xMin:target.boxNormalized[0],yMin:target.boxNormalized[1],xMax:target.boxNormalized[2],yMax:target.boxNormalized[3])])
                d["static_background_patch_count"]=Double(bg.patchCount);d["background_motion_pixels"]=bg.medianMotionPixels;d["background_stable"]=bg.stable ? 1:0
            }
            d["edge_line_count"]=Double(detected.lines.count);d["finger_pair_hypotheses"]=Double(detected.pairs.count)
            let current=Seen(frame:frame,gray:gray,lines:detected.lines,pairs:detected.pairs)
            defer {previous=current}
            guard !detected.pairs.isEmpty else {alignedCount=0;return answer("needsJawIdentification","No two finite opposing finger strips were observed. The FK ROI is only a search prior; make the actual fingers visible or add a visual marker.")}
            var selected:Pair?
            if let old=identified,let oldFrame=identifiedFrame,let oldGray=identifiedGray {
                let scored=detected.pairs.compactMap{p->(Pair,Double)? in
                    guard (p.center-old.center).length<=35,abs(ROBGripperVisualServo.angleDistance(p.left.angle,old.left.angle))<0.30,
                          p.gap/max(0.1,old.gap)>0.55,p.gap/max(0.1,old.gap)<1.8 else{return nil}
                    let match=ROBGripperVisualServo.pairPatchSimilarity(oldGray,gray,width:frame.width,height:frame.height,old:old,new:p)
                    guard match>0.72 else{return nil};return(p,match*0.75+p.score*0.25)
                }.sorted{$0.1>$1.1}
                d["temporal_pair_matches"]=Double(scored.count)
                guard let best=scored.first else {alignedCount=0;return answer("unavailable","The previously image-identified fingers could not be reacquired; hold instead of using predicted jaw pixels.")}
                if scored.count>1,best.1-scored[1].1<0.08,(best.0.center-scored[1].0.center).length>3 {return answer("ambiguous","Multiple actual edge pairs match the gripper appearance; no correction is selected.")}
                selected=best.0
                let change=best.0.center-old.center,dq=zip(frame.jointPositions,oldFrame.jointPositions).map(-),length=sqrt(dq.reduce(0){$0+$1*$1})
                if length>=0.001,length<=0.20,change.length>=0.75,change.length<=35 {
                    let outside=(0..<7).filter{!configuration.correctingJointIndices.contains($0)}.reduce(0.0){$0+abs(dq[$1])}
                    if outside<=0.001 && !observationOnly && d["background_stable"]==1 {
                        let unit=dq.map{$0/length},pixels=change*(1/length)
                        for oldResponse in responses {
                            let cosine=zip(unit,oldResponse.q).reduce(0.0){$0+$1.0*$1.1}
                            if abs(cosine)>0.95 {
                                let expected=oldResponse.pixels*(cosine>0 ? 1:-1),ratio=pixels.length/max(0.001,expected.length)
                                guard ratio>=0.5,ratio<=2,pixels.dot(expected)>0.70*pixels.length*expected.length else {
                                    terminalFailure="Repeated actual joint directions produced inconsistent jaw-image response; hold and reidentify instead of using a false measured Jacobian."
                                    return answer("blocked",terminalFailure!)
                                }
                            }
                        }
                        responses.append(.init(q:unit,pixels:pixels,atQ:frame.jointPositions,capturedAt:frame.capturedAtMilliseconds));if responses.count>10 {responses.removeFirst(responses.count-10)}
                    }
                }
            } else {
                guard let before=previous else {return answer("needsJawIdentification","Record the held before-image and the actual PREPARE/open request, then observe symmetric finger opening.")}
                let qMotion=zip(frame.jointPositions,before.frame.jointPositions).reduce(0.0){$0+abs($1.0-$1.1)}
                guard qMotion<=0.002,let command=frame.openingCommandAtMilliseconds,command.isFinite,
                      command>=before.frame.capturedAtMilliseconds-30,command<=frame.capturedAtMilliseconds+30,
                      frame.capturedAtMilliseconds-before.frame.capturedAtMilliseconds<=6000 else {
                    return answer("needsJawIdentification","A real opening image response after PREPARE, with the arm held, must identify fingers before joint visual servoing. Command acceptance is not opening feedback.")
                }
                let background=ROBGripperVisualServo.backgroundStable(before.gray,gray,width:frame.width,height:frame.height,roi:searchROI,target:target.boxNormalized)
                d["static_background_patch_count"]=Double(background.count);d["background_motion_pixels"]=background.motion
                guard background.count>=4,background.motion<=0.75 else {return answer("unavailable","The held background did not remain visually stable during jaw identification.")}
                let matches=detected.pairs.compactMap{p->(Pair,Double)? in
                    guard let score=ROBGripperVisualServo.openingSupport(before:before,current:current,pair:p) else{return nil};return(p,score)
                }.sorted{$0.1>$1.1}
                d["opening_supported_pairs"]=Double(matches.count)
                guard let first=matches.first else {return answer("needsJawIdentification","No unique symmetric opening of actual finger edges was seen after the open request. Already-open, occluded or ambiguous fingers remain unavailable.")}
                if matches.count>1,first.1-matches[1].1<0.10,(first.0.center-matches[1].0.center).length>3 {return answer("ambiguous","More than one image pair opened symmetrically; do not label either as jaws.")}
                selected=first.0;d["image_opening_response_verified"]=1
            }
            guard let pair=selected else{return answer("unavailable","No observed jaw pair.")}
            guard pair.score>=0.65 else {return answer("unavailable","Actual finger strip edge support is below the confidence gate; no observed jaw output is promoted.")}
            identified=pair;identifiedFrame=frame;identifiedGray=gray
            let openingDepth=ROBGripperVisualServo.jawDepth(frame,pair:pair)
            let observation=JawObservation(centerPixels:pair.center.array,tipsPixels:pair.tips.map(\.array),openingPixels:pair.gap,
                openingMeters:openingDepth.map{pair.gap*$0/((frame.fx+frame.fy)/2)},confidence:min(0.99,max(0,pair.score)),
                evidenceKind:"image_observed_opening_after_release_command_then_temporal_edges",sequence:frame.sequence,
                capturedAtMilliseconds:frame.capturedAtMilliseconds,scopeIdentity:frame.scopeIdentity)
            let error=can-pair.center
            if observationOnly {return answer("observedOnly","Actual image fingers reacquired for verification; no correction or grip authority is emitted.",observation,error.array)}
            if let pending=pendingBootstrap {
                let moved=sqrt(zip(frame.jointPositions,pending.q).reduce(0.0){$0+pow($1.0-$1.1,2)})
                guard moved>=0.0005 else {return answer("observing","Wait for the checked bootstrap endpoint before evaluating actual image response.",observation,error.array)}
                let actual=pending.error-error, progress=pending.error.length-error.length
                d["bootstrap_observed_progress_pixels"]=progress
                guard actual.length>=0.25,progress>=0.20,actual.dot(pending.predicted)>0.25*actual.length*pending.predicted.length else {
                    pendingBootstrap=nil;terminalFailure="The explicitly estimated direction did not produce the required actual jaw-image progress; hold and reacquire instead of repeating it."
                    return answer("blocked",terminalFailure!,observation,error.array)
                }
                pendingBootstrap=nil
            }
            d["actual_opening_pixels"]=pair.gap;d["measured_response_count"]=Double(responses.count)
            let canWidth=(target.boxNormalized[2]-target.boxNormalized[0])*Double(frame.width-1)
            let apertureFits=pair.gap>=canWidth*1.08
            d["image_aperture_fits"]=apertureFits ? 1:0
            var rangeReady=false
            if let jaw=openingDepth,let measured=target.measuredDepthMeters,measured.isFinite,measured>0,abs(jaw-measured)<=0.025 {d["range_verified"]=1;rangeReady=true}
            if target.geometryAssumed,let z=target.assumedDepthMeters,z.isFinite,z>0 {rangeReady=true;d["assumed_target_depth_m"]=z}
            if error.length<=configuration.alignmentTolerancePixels,apertureFits {alignedCount+=1}else{alignedCount=0}
            if alignedCount>=2,rangeReady {return answer("aligned","Actual image fingers align with observed can middle/aperture. Independent 3D contact/table/body review is still required; assumed geometry is not measured range.",observation,error.array,nil,true)}
            if error.length<=configuration.alignmentTolerancePixels {return answer("observing",apertureFits ? "Image alignment is close; require an advancing confirmation and explicit measured/assumed target range." : "Actual observed jaw aperture is too narrow for the current can image.",observation,error.array)}
            guard d["background_stable"]==1 else {return answer("unavailable","Actual static background could not be confirmed; no image-response correction is emitted.",observation,error.array)}
            guard iterations<configuration.maximumIterations else{return answer("blocked","Bounded visual correction count reached; hold and reobserve instead of chasing.",observation,error.array)}
            let local=responses.filter{frame.capturedAtMilliseconds-$0.capturedAt<=20000 && sqrt(zip(frame.jointPositions,$0.atQ).reduce(0.0){$0+pow($1.0-$1.1,2)})<=0.25}
            // Independent image changes from the SAME joint direction are not
            // a rank-two measured control basis. Require joint AND image rank.
            var basis:[Response]=[]
            var bestCondition=0.0
            for i in local.indices {for j in local.indices where j>i {
                let qi=local[i].q,qj=local[j].q,cosine=zip(qi,qj).reduce(0.0){$0+$1.0*$1.1}
                let pi=local[i].pixels,pj=local[j].pixels,cross=abs(pi.x*pj.y-pi.y*pj.x)/max(1e-9,pi.length*pj.length)
                let condition=(1-abs(cosine))*cross
                if abs(cosine)<=0.90,cross>=0.20,condition>bestCondition {basis=[local[i],local[j]];bestCondition=condition}
            }}
            var a=0.0,b=0.0,c=0.0,estimated=false
            var control:[Response]=basis
            d["measured_joint_image_basis_rank"]=basis.count==2 ? 2:(local.isEmpty ? 0:1)
            if control.isEmpty,bootstrapCount<2,let jac=frame.estimatedImageJacobian,
               jac.count==2,jac.allSatisfy({$0.count==7 && $0.allSatisfy({$0.isFinite && abs($0)<100000})}) {
                for i in configuration.correctingJointIndices {
                    var q=Array(repeating:0.0,count:7);q[i]=1
                    control.append(.init(q:q,pixels:.init(x:jac[0][i],y:jac[1][i]),atQ:frame.jointPositions,capturedAt:frame.capturedAtMilliseconds))
                }
                estimated=true
            }
            for r in control {a+=r.pixels.x*r.pixels.x;b+=r.pixels.x*r.pixels.y;c+=r.pixels.y*r.pixels.y}
            let determinant=a*c-b*b
            d["measured_jacobian_rank"]=basis.count==2 ? 2:(local.isEmpty ? 0:1)
            guard control.count>=2,determinant>max(1,pow(a+c,2))*0.015 else {return answer("needsMeasuredResponse","No independent well-conditioned actual joint/image basis exists, and no bounded usable estimated FK direction prior remains.",observation,error.array)}
            let gain=min(0.5,configuration.maximumImageCorrectionPixels/max(0.001,error.length)),wanted=error*gain
            let dual=V(x:(c*wanted.x-b*wanted.y)/determinant,y:(a*wanted.y-b*wanted.x)/determinant)
            var delta=Array(repeating:0.0,count:7)
            for r in control {let coefficient=r.pixels.dot(dual);for i in 0..<7 {delta[i]+=r.q[i]*coefficient}}
            let maximum=delta.map(abs).max() ?? 0,scale=min(1,configuration.maximumCorrectionRadians/max(1e-10,maximum));delta=delta.map{$0*scale}
            let proposed=zip(frame.jointPositions,delta).map(+)
            guard delta.contains(where:{abs($0)>0.00005}),zip(proposed,configuration.jointBounds).allSatisfy({$0.isFinite && $1.contains($0)}) else {return answer("blocked","The image correction has no bounded in-range joint target.",observation,error.array)}
            if estimated {
                bootstrapCount+=1
                pendingBootstrap=(frame.jointPositions,error,wanted*scale)
                d["estimated_fk_direction_prior_used"]=1;d["estimated_bootstrap_count"]=Double(bootstrapCount)
            } else {d["estimated_fk_direction_prior_used"]=0}
            iterations+=1;d["correction_iteration"]=Double(iterations);d["maximum_joint_delta_rad"]=delta.map(abs).max() ?? 0
            return answer("correction",estimated ? "Bounded bootstrap from an explicitly ESTIMATED FK direction prior; actual observed jaw response must confirm progress after independent collision review." : "Bounded target from independent actual task-local joint/image response; owning trial must independently collision-review and dispatch it.",observation,error.array,proposed)
        }
    }
    struct BackgroundObservation:Codable,Equatable,Sendable {
        let patchCount:Int,medianMotionPixels:Double,maximumResidualPixels:Double,stable:Bool
    }
    static func backgroundStability(previous:Frame,current:Frame,excluding:[ROI])->BackgroundObservation {
        guard previous.scopeIdentity==current.scopeIdentity,previous.width==current.width,previous.height==current.height,
              current.sequence>previous.sequence,current.capturedAtMilliseconds>previous.capturedAtMilliseconds,
              previous.rgb.count==previous.width*previous.height*3,current.rgb.count==current.width*current.height*3 else {
            return .init(patchCount:0,medianMotionPixels:.infinity,maximumResidualPixels:.infinity,stable:false)
        }
        let priorGray:[Double]=grayscale(previous.rgb)
        let currentGray:[Double]=grayscale(current.rgb)
        return background(priorGray,currentGray,width:current.width,height:current.height,excluding:excluding)
    }
    private static func grayscale(_ data:Data)->[Double] {
        let bytes:[UInt8]=Array(data)
        var result:[Double]=[]
        result.reserveCapacity(bytes.count/3)
        var index:Int=0
        while index<bytes.count {
            let red:Double=0.299*Double(bytes[index])
            let green:Double=0.587*Double(bytes[index+1])
            let blue:Double=0.114*Double(bytes[index+2])
            let redGreen:Double=red+green
            let value:Double=redGreen+blue
            result.append(value)
            index+=3
        }
        return result
    }
    private static func angleDistance(_ a:Double,_ b:Double)->Double {let d=abs(a-b).truncatingRemainder(dividingBy:.pi);return min(d,.pi-d)}
    private static func detect(gray:[Double],width:Int,height:Int,roi:ROI,minLength:Int)->(lines:[Line],pairs:[Pair]) {
        guard [roi.xMin,roi.yMin,roi.xMax,roi.yMax].allSatisfy({$0.isFinite && (0...1).contains($0)}),roi.xMax>roi.xMin,roi.yMax>roi.yMin else{return([],[])}
        let x0=max(2,Int(roi.xMin*Double(width-1))),x1=min(width-3,Int(roi.xMax*Double(width-1))),y0=max(2,Int(roi.yMin*Double(height-1))),y1=min(height-3,Int(roi.yMax*Double(height-1)))
        guard x1-x0>=12,y1-y0>=12,(x1-x0)*(y1-y0)<=100_000 else{return([],[])}
        var edges:[(p:V,g:V,m:Double)]=[]
        for y in y0...y1 {for x in x0...x1 {
            let gx=(gray[y*width+x+1]-gray[y*width+x-1])/2,gy=(gray[(y+1)*width+x]-gray[(y-1)*width+x])/2,m=hypot(gx,gy)
            if m>=22 {edges.append((.init(x:Double(x),y:Double(y)),.init(x:gx,y:gy),m))}
        }}
        guard edges.count>=minLength*4 else{return([],[])}
        let shift=width+height,bins=2*shift+1
        var lines:[Line]=[]
        for k in 0..<36 {
            let angle=Double(k)*Double.pi/36,n=V(x:cos(angle),y:sin(angle)),t=V(x:-sin(angle),y:cos(angle))
            var histogram=Array(repeating:0,count:bins)
            for edge in edges where abs(edge.g.dot(n))/edge.m>0.94 {let i=Int(edge.p.dot(n).rounded())+shift;if (0..<bins).contains(i){histogram[i]+=1}}
            var peaks:[Int]=[]
            for i in 1..<bins-1 where histogram[i]>=minLength && histogram[i]>=histogram[i-1] && histogram[i]>histogram[i+1] {peaks.append(i)}
            peaks.sort{histogram[$0]>histogram[$1]}
            for peak in peaks.prefix(10) {
                let rho=Double(peak-shift),support=edges.filter{abs($0.p.dot(n)-rho)<=0.85 && abs($0.g.dot(n))/$0.m>0.94}
                guard support.count>=minLength else{continue}
                let samples=support.map{$0.p.dot(t)}.sorted(),lo=samples[samples.count/20],hi=samples[samples.count*19/20],length=hi-lo
                guard length>=Double(minLength),Double(support.count)/max(1,length)>=0.65 else{continue}
                let weighted=support.reduce(0.0){$0+$1.p.dot(n)*$1.m}/support.reduce(0){$0+$1.m}
                let sign=support.reduce(0.0){$0+$1.g.dot(n)},strength=min(1,Double(support.count)/max(1,length))*min(1,support.reduce(0){$0+$1.m}/Double(support.count)/55)
                let line=Line(angle:angle,rho:weighted,lo:lo,hi:hi,sign:sign,strength:strength)
                if !lines.contains(where:{angleDistance($0.angle,line.angle)<0.04 && ($0.center-line.center).length<3 && min($0.length,line.length)/max($0.length,line.length)>0.7}) {lines.append(line)}
            }
        }
        lines.sort{$0.strength*$0.length>$1.strength*$1.length};if lines.count>100{lines=Array(lines.prefix(100))}
        var pairs:[Pair]=[]
        for i in lines.indices {for j in lines.indices where j>i {
            var left=lines[i],right=lines[j]
            guard angleDistance(left.angle,right.angle)<0.025,left.sign*right.sign<0 else{continue}
            if left.rho>right.rho{swap(&left,&right)}
            let gap=right.rho-left.rho,lo=max(left.lo,right.lo),hi=min(left.hi,right.hi)
            guard gap>=4,gap<=min(90,Double(max(x1-x0,y1-y0))*0.8),hi-lo>=Double(minLength),
                  (hi-lo)/min(left.length,right.length)>=0.65 else{continue}
            func outer(_ inner:Line,_ side:Double)->Line? {
                lines.filter{angleDistance($0.angle,inner.angle)<0.025 && $0.sign*inner.sign<0 &&
                    ($0.rho-inner.rho)*side>=1.5 && ($0.rho-inner.rho)*side<=12 && min($0.hi,hi)-max($0.lo,lo)>=(hi-lo)*0.7}
                    .max{$0.strength<$1.strength}
            }
            guard let outerLeft=outer(left,-1),let outerRight=outer(right,1) else{continue}
            let score=(left.strength+right.strength+outerLeft.strength+outerRight.strength)/4
            let pair=Pair(left:left,right:right,outerLeft:outerLeft,outerRight:outerRight,lo:lo,hi:hi,score:score)
            if !pairs.contains(where:{($0.center-pair.center).length<3 && abs($0.gap-pair.gap)<3 && angleDistance($0.left.angle,pair.left.angle)<0.10}){pairs.append(pair)}
        }}
        pairs.sort{$0.score>$1.score};return(lines,Array(pairs.prefix(30)))
    }
    private static func openingSupport(before:Seen,current:Seen,pair:Pair)->Double? {
        let width=current.frame.width,height=current.frame.height
        let candidatesLeft=before.lines.filter{angleDistance($0.angle,pair.outerLeft.angle)<0.04 && $0.sign*pair.outerLeft.sign>0 && $0.rho-pair.outerLeft.rho>=0.8 && $0.rho-pair.outerLeft.rho<=40 && min($0.hi,pair.hi)-max($0.lo,pair.lo)>=(pair.hi-pair.lo)*0.6}
        let candidatesRight=before.lines.filter{angleDistance($0.angle,pair.outerRight.angle)<0.04 && $0.sign*pair.outerRight.sign>0 && pair.outerRight.rho-$0.rho>=0.8 && pair.outerRight.rho-$0.rho<=40 && min($0.hi,pair.hi)-max($0.lo,pair.lo)>=(pair.hi-pair.lo)*0.6}
        var best:Double?
        for left in candidatesLeft {for right in candidatesRight {
            let dl=left.rho-pair.outerLeft.rho,dr=pair.outerRight.rho-right.rho
            guard right.rho>left.rho,dl+dr>=3,abs(dl-dr)<=max(2,(dl+dr)*0.35),
                  abs((left.rho+right.rho-pair.outerLeft.rho-pair.outerRight.rho)/2)<=2 else{continue}
            func changed(_ rho0:Double,_ rho1:Double)->Double {
                let samples=12,total=Double(samples*3);var difference=0.0
                for i in 0..<samples {let t=pair.lo+(pair.hi-pair.lo)*Double(i+1)/Double(samples+1)
                    for f in [0.25,0.5,0.75] {let p=pair.n*(rho0+(rho1-rho0)*f)+pair.t*t,x=Int(p.x.rounded()),y=Int(p.y.rounded())
                        guard (0..<width).contains(x),(0..<height).contains(y) else{continue}
                        if abs(before.gray[y*width+x]-current.gray[y*width+x])>=18{difference+=1}
                    }
                };return difference/total
            }
            let movement=min(changed(left.rho,pair.outerLeft.rho),changed(right.rho,pair.outerRight.rho))
            guard movement>=0.45 else{continue}
            let score=0.65*movement+0.35*pair.score;if score>(best ?? -1){best=score}
        }};return best
    }
    private static func patch(_ image:[Double],width:Int,height:Int,at point:V)->[Double]? {
        let x=Int(point.x.rounded()),y=Int(point.y.rounded());guard x>=3,y>=3,x+3<width,y+3<height else{return nil}
        var out:[Double]=[];for dy in -3...3 {for dx in -3...3 {out.append(image[(y+dy)*width+x+dx])}};return out
    }
    private static func correlation(_ a:[Double],_ b:[Double])->Double {
        let ma=a.reduce(0,+)/Double(a.count),mb=b.reduce(0,+)/Double(b.count)
        var aa=0.0,bb=0.0,ab=0.0
        for (x,y) in zip(a,b){aa+=(x-ma)*(x-ma);bb+=(y-mb)*(y-mb);ab+=(x-ma)*(y-mb)}
        guard aa>80,bb>80 else{return -1};return ab/sqrt(aa*bb)
    }
    private static func pairPatchSimilarity(_ a:[Double],_ b:[Double],width:Int,height:Int,old:Pair,new:Pair)->Double {
        func points(_ pair:Pair)->[V] {
            [pair.outerLeft.center,pair.outerRight.center,
             pair.n*pair.outerLeft.rho+pair.t*pair.lo,pair.n*pair.outerLeft.rho+pair.t*pair.hi,
             pair.n*pair.outerRight.rho+pair.t*pair.lo,pair.n*pair.outerRight.rho+pair.t*pair.hi]
        }
        let oldPoints=points(old),newPoints=points(new)
        var scores:[Double]=[]
        for (x,y) in zip(oldPoints,newPoints){if let p=patch(a,width:width,height:height,at:x),let q=patch(b,width:width,height:height,at:y){scores.append(correlation(p,q))}}
        return scores.count==6 ? scores.min()!:-1
    }
    private static func background(_ a:[Double],_ b:[Double],width:Int,height:Int,excluding:[ROI])->BackgroundObservation {
        guard a.count==width*height,b.count==a.count else{return .init(patchCount:0,medianMotionPixels:.infinity,maximumResidualPixels:.infinity,stable:false)}
        var flows:[V]=[]
        for y in stride(from:10,to:height-10,by:max(12,height/8)){for x in stride(from:10,to:width-10,by:max(12,width/10)) {
            let u=Double(x)/Double(width-1),v=Double(y)/Double(height-1)
            if excluding.contains(where:{u >= $0.xMin-0.03 && u <= $0.xMax+0.03 && v >= $0.yMin-0.03 && v <= $0.yMax+0.03}){continue}
            guard let source=patch(a,width:width,height:height,at:.init(x:Double(x),y:Double(y))) else{continue}
            var matches:[(Double,V)]=[]
            for dy in -3...3{for dx in -3...3{if let p=patch(b,width:width,height:height,at:.init(x:Double(x+dx),y:Double(y+dy))){matches.append((correlation(source,p),.init(x:Double(dx),y:Double(dy))))}}}
            matches.sort{$0.0>$1.0};guard let best=matches.first,best.0>=0.90 else{continue}
            if let alternate=matches.dropFirst().first(where:{($0.1-best.1).length>1.5}),best.0-alternate.0<0.02{continue}
            flows.append(best.1)
        }}
        guard !flows.isEmpty else{return .init(patchCount:0,medianMotionPixels:.infinity,maximumResidualPixels:.infinity,stable:false)}
        let xs=flows.map(\.x).sorted(),ys=flows.map(\.y).sorted(),median=V(x:xs[xs.count/2],y:ys[ys.count/2])
        let residuals=flows.map{($0-median).length}.sorted(),p90=residuals[residuals.count*9/10]
        return .init(patchCount:flows.count,medianMotionPixels:median.length,maximumResidualPixels:p90,stable:flows.count>=4 && median.length<=0.75 && p90<=1)
    }
    private static func backgroundStable(_ a:[Double],_ b:[Double],width:Int,height:Int,roi:ROI,target:[Double])->(count:Int,motion:Double) {
        let value=background(a,b,width:width,height:height,excluding:[roi,.init(xMin:target[0],yMin:target[1],xMax:target[2],yMax:target[3])])
        return(value.stable ? value.patchCount:0,value.medianMotionPixels)
    }
    private static func jawDepth(_ frame:Frame,pair:Pair)->Double? {
        var values:[Double]=[]
        for point in [pair.n*((pair.left.rho+pair.outerLeft.rho)/2)+pair.t*((pair.lo+pair.hi)/2),pair.n*((pair.right.rho+pair.outerRight.rho)/2)+pair.t*((pair.lo+pair.hi)/2)] {
            var part:[Double]=[];let x=Int(point.x.rounded()),y=Int(point.y.rounded())
            for dy in -1...1{for dx in -1...1{guard (0..<frame.width).contains(x+dx),(0..<frame.height).contains(y+dy) else{continue};let z=frame.depthMillimeters[(y+dy)*frame.width+x+dx];if (100...3000).contains(z){part.append(Double(z)/1000)}}}
            guard part.count>=5 else{return nil};part.sort();guard part[part.count*9/10]-part[part.count/10]<=0.025 else{return nil};values.append(part[part.count/2])
        }
        guard values.count==2,abs(values[0]-values[1])<=0.040 else{return nil};return(values[0]+values[1])/2
    }
}
