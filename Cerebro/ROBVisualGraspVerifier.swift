import Foundation

/// Image evidence supports a grasp; it is not a force, jaw-position or payload
/// sensor. The executor owns all movement and must hold on unknown/failed.
struct ROBVisualGraspVerifier {
    enum Verdict: String, Codable { case collecting, supported, failed, unknown }
    struct Point: Codable, Equatable {
        let x: Double
        let y: Double
    }
    struct Box: Codable, Equatable {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
        var center: Point { Point(x:(left+right)/2,y:(top+bottom)/2) }
        var valid: Bool { [left,top,right,bottom].allSatisfy { $0.isFinite && (0...1).contains($0) } && right>left && bottom>top }
    }
    struct Sample {
        let sequence: UInt64
        let capturedAtMilliseconds: Double
        /// Aligned RGB and depth must originate in the same capture frame set.
        let synchronizedRGBDepth: Bool
        let cameraGeneration: UUID
        /// Exact accepted raw neck pose plus registration/calibration identity.
        let fixedViewIdentity: String
        let targetIdentity: String
        let width: Int
        let height: Int
        /// Top-left origin, one grayscale byte and one aligned optical-Z value
        /// per pixel. Nonpositive/nonfinite depth means missing, never zero range.
        let gray: [UInt8]
        let depthMeters: [Float]
        /// Projected from measured arm feedback in this sample's registered
        /// camera frame, not the commanded endpoint or a model-predicted pose.
        let measuredToolCenter: Point
        let measuredToolDepthMeters: Double
        let toolFeedbackCapturedAtMilliseconds: Double
        let handsClear: Bool
        var toolEvidenceSource: String = "registered_measured_feedback"
        var observedFingerRegions: [Box] = []
    }
    struct Evidence: Encodable {
        var verdict: Verdict
        var reason: String
        var samples: Int
        var firstSequence: UInt64
        var lastSequence: UInt64
        let cameraGeneration: UUID
        let fixedViewIdentity: String
        let targetIdentity: String
        let targetBox: Box
        let baselineCapturedAtMilliseconds: Double
        var lastCapturedAtMilliseconds: Double
        var correlation: Double?
        var uniquenessMargin: Double?
        var targetMotionPixels: Double?
        var toolMotionPixels: Double?
        var targetDepthChangeMeters: Double?
        var toolDepthChangeMeters: Double?
        var targetToolMotionErrorPixels: Double?
        var depthMotionErrorMeters: Double?
        var toolEvidenceSource: String = "registered_measured_feedback"
        var appearanceReferenceSequence:UInt64? = nil
        var appearanceReferenceCapturedAtMilliseconds:Double? = nil
        let possessionMeasured = false
    }
    enum Unavailable: LocalizedError {
        case evidence(String)
        var errorDescription: String? { if case .evidence(let text)=self { return text }; return nil }
    }
    private struct Patch {
        let x: Int, y: Int, width: Int, height: Int
        let values: [Double]
        let mean: Double, norm: Double
        var center: Point { Point(x:Double(x)+Double(width)/2,y:Double(y)+Double(height)/2) }
    }
    private struct Match {
        let x: Int, y: Int
        let correlation: Double
        let margin: Double
    }
    private let baseline: Sample
    private let target: Patch
    private let baselineTargetDepth: Double
    private let backgrounds: [Patch]
    private var lastSequence: UInt64
    private var lastCapture: Double
    private var coherentSamples = 0
    private var stationarySamples = 0
    private var divergentSamples = 0
    private(set) var evidence: Evidence

    /// Bounded to a 12-second inspection, 150 ms RGB/tool skew and three
    /// independent advancing observations. No arbitrary retry or actuation.
    init(baseline: Sample, targetBox: Box, nowMilliseconds: Double, independentAppearance:AppearanceSeed? = nil) throws {
        guard Self.valid(baseline,now:nowMilliseconds), targetBox.valid,
              !baseline.targetIdentity.isEmpty, !baseline.fixedViewIdentity.isEmpty else {
            throw Unavailable.evidence("Fresh synchronized RGB-D, measured tool feedback and a fixed calibrated view are required.")
        }
        // Prefer the central can wall. Lateral jaws must not become the target
        // template merely because they surround the original detector box.
        let w=targetBox.right-targetBox.left, h=targetBox.bottom-targetBox.top
        let core=Box(left:targetBox.left+w*0.2,top:targetBox.top+h*0.15,
            right:targetBox.right-w*0.2,bottom:targetBox.bottom-h*0.15)
        let candidate:Patch?
        if let independentAppearance {candidate=Self.seedPatch(independentAppearance,current:baseline,box:core)}
        else {candidate=Self.patch(baseline,box:core)}
        guard let patch=candidate, patch.width>=6,patch.height>=8,
              let depth=Self.depth(baseline,x:patch.x,y:patch.y,width:patch.width,height:patch.height) else {
            throw Unavailable.evidence("The can wall lacks a distinctive visible texture or valid aligned depth.")
        }
        var anchors:[Patch]=[]
        // Spatially distributed static anchors guard against head movement and
        // background/lighting changes. Moving arm pixels are not positive proof.
        for y in [0.12,0.36,0.64,0.88] {
            for x in [0.12,0.36,0.64,0.88] {
                let half=0.035
                let box=Box(left:x-half,top:y-half,right:x+half,bottom:y+half)
                let expanded=Box(left:max(0,targetBox.left-0.08),top:max(0,targetBox.top-0.08),
                    right:min(1,targetBox.right+0.08),bottom:min(1,targetBox.bottom+0.08))
                guard box.right<expanded.left || box.left>expanded.right || box.bottom<expanded.top || box.top>expanded.bottom,
                      let candidate=Self.patch(baseline,box:box),
                      Self.depth(baseline,x:candidate.x,y:candidate.y,width:candidate.width,height:candidate.height) != nil else { continue }
                anchors.append(candidate)
            }
        }
        guard anchors.count>=4 else { throw Unavailable.evidence("Insufficient textured stationary background around the grasp view.") }
        guard baseline.toolEvidenceSource != "independent_observed_fingers" ||
              (baseline.observedFingerRegions.count==2 && !Self.overlaps(patch,regions:baseline.observedFingerRegions,sample:baseline)) else {
            throw Unavailable.evidence("The independent can-wall template overlaps observed fingers; hold for a visible identity patch.")
        }
        self.baseline=baseline; target=patch; backgrounds=anchors; baselineTargetDepth=depth
        lastSequence=baseline.sequence;lastCapture=baseline.capturedAtMilliseconds
        evidence=Evidence(verdict:.collecting,reason:"Waiting for a bounded measured lift and fresh can observations.",samples:0,
            firstSequence:baseline.sequence,lastSequence:baseline.sequence,cameraGeneration:baseline.cameraGeneration,
            fixedViewIdentity:baseline.fixedViewIdentity,targetIdentity:baseline.targetIdentity,targetBox:targetBox,
            baselineCapturedAtMilliseconds:baseline.capturedAtMilliseconds,lastCapturedAtMilliseconds:baseline.capturedAtMilliseconds)
        evidence.toolEvidenceSource=baseline.toolEvidenceSource
        evidence.appearanceReferenceSequence=independentAppearance?.sequence
        evidence.appearanceReferenceCapturedAtMilliseconds=independentAppearance?.capturedAtMilliseconds
    }

    /// Call only at already-reviewed, measured holds. A small lift must be in
    /// the collision-reviewed proposal; this function never creates one.
    mutating func observe(_ sample:Sample,nowMilliseconds:Double) -> Evidence {
        guard evidence.verdict == .collecting else { return evidence }
        func unknown(_ reason:String) -> Evidence {
            var value=evidence;value.verdict = .unknown;value.reason=reason;return value
        }
        guard Self.valid(sample,now:nowMilliseconds),sample.cameraGeneration==baseline.cameraGeneration,
              sample.fixedViewIdentity==baseline.fixedViewIdentity,sample.targetIdentity==baseline.targetIdentity,
              sample.width==baseline.width,sample.height==baseline.height,
              sample.toolEvidenceSource==baseline.toolEvidenceSource else {
            evidence=unknown("Camera, fixed neck/calibration identity, target identity or synchronized measured feedback changed.");return evidence
        }
        guard sample.sequence>lastSequence,sample.capturedAtMilliseconds>lastCapture,
              (evidence.samples==0 || sample.capturedAtMilliseconds-lastCapture<=1500),
              sample.capturedAtMilliseconds-baseline.capturedAtMilliseconds<=12_000 else {
            evidence=unknown("The bounded observation expired or camera frames stopped advancing.");return evidence
        }
        lastSequence=sample.sequence;lastCapture=sample.capturedAtMilliseconds
        evidence.samples+=1;evidence.lastSequence=sample.sequence;evidence.lastCapturedAtMilliseconds=sample.capturedAtMilliseconds
        var stationaryAnchors=0, shiftedAnchors=0
        var anchorCenters:[Point]=[]
        for patch in backgrounds {
            guard let match=Self.match(patch,in:sample,centerX:patch.x,centerY:patch.y,radius:3),match.correlation>=0.85,
                  let before=Self.depth(baseline,x:patch.x,y:patch.y,width:patch.width,height:patch.height),
                  let after=Self.depth(sample,x:match.x,y:match.y,width:patch.width,height:patch.height),abs(after-before)<=0.015 else { continue }
            let mean=Self.mean(sample,x:match.x,y:match.y,width:patch.width,height:patch.height)
            guard abs(mean-patch.mean)<=35 else { continue }
            if hypot(Double(match.x-patch.x),Double(match.y-patch.y))<=1.0 {
                stationaryAnchors+=1;anchorCenters.append(patch.center)
            } else { shiftedAnchors+=1 }
        }
        let spread=anchorCenters.map { a in anchorCenters.map { b in hypot(a.x-b.x,a.y-b.y) }.max() ?? 0 }.max() ?? 0
        guard shiftedAnchors<3,stationaryAnchors>=3,spread>=Double(min(sample.width,sample.height))*0.3 else {
            evidence=unknown("Static background did not confirm an unchanged camera view and exposure.");return evidence
        }
        let toolX=(sample.measuredToolCenter.x-baseline.measuredToolCenter.x)*Double(sample.width)
        let toolY=(sample.measuredToolCenter.y-baseline.measuredToolCenter.y)*Double(sample.height)
        let toolMotion=hypot(toolX,toolY)
        let toolDepth=sample.measuredToolDepthMeters-baseline.measuredToolDepthMeters
        evidence.toolMotionPixels=toolMotion;evidence.toolDepthChangeMeters=toolDepth
        // Search both original and projected locations so a can left on the
        // table is recorded as failure rather than disappearing off the search.
        let radius=min(48,max(8,Int(ceil(toolMotion))+6))
        let observedFingers=sample.toolEvidenceSource=="independent_observed_fingers"
        let trackedCandidate=observedFingers ? Self.observedMatch(target,in:sample,dx:toolX,dy:toolY) :
            Self.match(target,in:sample,centerX:target.x,centerY:target.y,radius:radius)
        guard toolMotion <= (observedFingers ? 128:42),abs(toolDepth)<=0.12,
              let tracked=trackedCandidate,
              tracked.correlation>=0.82,tracked.margin>=0.06,
              let currentDepth=Self.depth(sample,x:tracked.x,y:tracked.y,width:target.width,height:target.height) else {
            evidence=unknown("Can texture was occluded, ambiguous, outside the bounded view or lacked aligned depth.");return evidence
        }
        if sample.toolEvidenceSource=="independent_observed_fingers" {
            let region=Patch(x:tracked.x,y:tracked.y,width:target.width,height:target.height,values:target.values,mean:target.mean,norm:target.norm)
            guard sample.observedFingerRegions.count==2,!Self.overlaps(region,regions:sample.observedFingerRegions,sample:sample) else {
                evidence=unknown("Observed fingers occlude the independent can-wall identity; jaw texture cannot establish possession.");return evidence
            }
        }
        evidence.correlation=tracked.correlation;evidence.uniquenessMargin=tracked.margin
        let targetX=Double(tracked.x-target.x),targetY=Double(tracked.y-target.y)
        let targetMotion=hypot(targetX,targetY), targetDepth=currentDepth-baselineTargetDepth
        let pixelError=hypot(targetX-toolX,targetY-toolY),depthError=abs(targetDepth-toolDepth)
        evidence.targetMotionPixels=targetMotion;evidence.targetDepthChangeMeters=targetDepth
        evidence.targetToolMotionErrorPixels=pixelError;evidence.depthMotionErrorMeters=depthError
        guard toolMotion>=6 || abs(toolDepth)>=0.02 else {
            evidence.reason="Measured lift is too small to distinguish possession from stationary contact."
            return evidence
        }
        let moved=targetMotion>=4 || abs(targetDepth)>=0.015
        if moved,pixelError<=max(3,toolMotion*0.25),depthError<=0.015 {
            coherentSamples+=1;stationarySamples=0;divergentSamples=0
        } else if targetMotion<=2,abs(targetDepth)<=0.008 {
            stationarySamples+=1;coherentSamples=0;divergentSamples=0
        } else {
            divergentSamples+=1;coherentSamples=0;stationarySamples=0
        }
        if coherentSamples>=3 {
            evidence.verdict = .supported
            evidence.reason=observedFingers
                ? "Three advancing synchronized RGB-D views preserve independent can-wall texture moving with image-observed fingers and independently sampled finger depth against a static background. Possession remains visual support, not measured retention."
                : "Three advancing RGB-D views show the same can moving coherently with the measured tool against a static background. Possession remains visual evidence, not measured force or jaw retention."
        } else if stationarySamples>=3 || divergentSamples>=3 {
            evidence.verdict = .failed
            evidence.reason=stationarySamples>=3 ? "The tool moved but the visible can remained on the table." : "The visible can moved independently of the measured tool."
        } else { evidence.reason="Collecting repeated can/tool motion agreement after the measured lift." }
        return evidence
    }

    mutating func finish() -> Evidence {
        if evidence.verdict == .collecting {
            evidence.verdict = .unknown;evidence.reason="The bounded observation ended without repeated grasp support. Hold for review."
        }
        return evidence
    }

    /// Transfer a detector ROI to a current image only when the same textured
    /// wall and distributed background stayed still. The old image supplies
    /// appearance, never current tool or payload evidence.
    static func confirmTargetContinuity(reference:Sample,targetBox:Box,current:Sample,nowMilliseconds:Double) -> Box? {
        guard valid(current,now:nowMilliseconds),targetBox.valid,
              reference.width==current.width,reference.height==current.height,
              reference.gray.count==current.gray.count,reference.depthMeters.count==current.depthMeters.count,
              reference.cameraGeneration==current.cameraGeneration,reference.fixedViewIdentity==current.fixedViewIdentity,
              reference.targetIdentity==current.targetIdentity,reference.synchronizedRGBDepth,reference.handsClear,
              current.sequence>=reference.sequence,(0...30_000).contains(current.capturedAtMilliseconds-reference.capturedAtMilliseconds) else {return nil}
        let w=targetBox.right-targetBox.left,h=targetBox.bottom-targetBox.top
        let core=Box(left:targetBox.left+w*0.2,top:targetBox.top+h*0.15,right:targetBox.right-w*0.2,bottom:targetBox.bottom-h*0.15)
        guard let source=patch(reference,box:core),
              let tracked=match(source,in:current,centerX:source.x,centerY:source.y,radius:6),
              tracked.correlation>=0.9,tracked.margin>=0.08,
              hypot(Double(tracked.x-source.x),Double(tracked.y-source.y))<=3 else {return nil}
        var anchors:[Point]=[]
        for y in [0.12,0.36,0.64,0.88] {for x in [0.12,0.36,0.64,0.88] {
            let box=Box(left:x-0.035,top:y-0.035,right:x+0.035,bottom:y+0.035)
            guard box.right<targetBox.left-0.08 || box.left>targetBox.right+0.08 || box.bottom<targetBox.top-0.08 || box.top>targetBox.bottom+0.08,
                  let p=patch(reference,box:box),let m=match(p,in:current,centerX:p.x,centerY:p.y,radius:3),
                  m.correlation>=0.85,hypot(Double(m.x-p.x),Double(m.y-p.y))<=1,
                  abs(mean(current,x:m.x,y:m.y,width:p.width,height:p.height)-p.mean)<=35 else {continue}
            anchors.append(p.center)
        }}
        let spread=anchors.map {a in anchors.map{b in hypot(a.x-b.x,a.y-b.y)}.max() ?? 0}.max() ?? 0
        guard anchors.count>=3,spread>=Double(min(current.width,current.height))*0.3 else {return nil}
        let dx=Double(tracked.x-source.x)/Double(current.width),dy=Double(tracked.y-source.y)/Double(current.height)
        let box=Box(left:targetBox.left+dx,top:targetBox.top+dy,right:targetBox.right+dx,bottom:targetBox.bottom+dy)
        return box.valid ? box : nil
    }

    /// The reference contributes appearance only. Its deliberately invalid
    /// tool fields can never pass measurement validation or become motion data.
    private static func seedPatch(_ seed:AppearanceSeed,current:Sample,box:Box)->Patch? {
        guard seed.sequence>0,seed.sequence<current.sequence,seed.capturedAtMilliseconds<current.capturedAtMilliseconds,
              (0...30_000).contains(current.capturedAtMilliseconds-seed.capturedAtMilliseconds),
              seed.cameraGeneration==current.cameraGeneration,seed.fixedViewIdentity==current.fixedViewIdentity,
              seed.targetIdentity==current.targetIdentity,seed.width==current.width,seed.height==current.height,
              seed.gray.count==current.gray.count,seed.canBox.valid,seed.handsClear,seed.synchronizedRGBDepth else{return nil}
        let pixels=Sample(sequence:seed.sequence,capturedAtMilliseconds:seed.capturedAtMilliseconds,synchronizedRGBDepth:seed.synchronizedRGBDepth,
            cameraGeneration:seed.cameraGeneration,fixedViewIdentity:seed.fixedViewIdentity,targetIdentity:seed.targetIdentity,
            width:seed.width,height:seed.height,gray:seed.gray,depthMeters:[],measuredToolCenter:.init(x:.nan,y:.nan),
            measuredToolDepthMeters:.nan,toolFeedbackCapturedAtMilliseconds:.nan,handsClear:seed.handsClear)
        let w=seed.canBox.right-seed.canBox.left,h=seed.canBox.bottom-seed.canBox.top
        let core=Box(left:seed.canBox.left+w*0.2,top:seed.canBox.top+h*0.15,right:seed.canBox.right-w*0.2,bottom:seed.canBox.bottom-h*0.15)
        guard let patch=Self.patch(pixels,box:core) else{return nil}
        let x=Int((box.left*Double(current.width)).rounded()),y=Int((box.top*Double(current.height)).rounded())
        guard abs(Double(patch.width)-(box.right-box.left)*Double(current.width))<=3,
              abs(Double(patch.height)-(box.bottom-box.top)*Double(current.height))<=3,
              let found=match(patch,in:current,centerX:x,centerY:y,radius:6),found.correlation>=0.90,found.margin>=0.08,
              hypot(Double(found.x-x),Double(found.y-y))<=3 else{return nil}
        return Patch(x:found.x,y:found.y,width:patch.width,height:patch.height,values:patch.values,mean:patch.mean,norm:patch.norm)
    }

    private static func overlaps(_ patch:Patch,regions:[Box],sample:Sample)->Bool {
        let b=Box(left:Double(patch.x)/Double(sample.width),top:Double(patch.y)/Double(sample.height),
                  right:Double(patch.x+patch.width)/Double(sample.width),bottom:Double(patch.y+patch.height)/Double(sample.height))
        return regions.contains{!$0.valid || !(b.right<$0.left || b.left>$0.right || b.bottom<$0.top || b.top>$0.bottom)}
    }

    private static func valid(_ s:Sample,now:Double) -> Bool {
        guard (80...640).contains(s.width),(60...480).contains(s.height),s.gray.count==s.width*s.height,
              s.depthMeters.count==s.gray.count,s.sequence>0,s.capturedAtMilliseconds.isFinite,now.isFinite,
              (0...800).contains(now-s.capturedAtMilliseconds),s.synchronizedRGBDepth,s.handsClear,
              s.measuredToolCenter.x.isFinite,s.measuredToolCenter.y.isFinite,
              (0...1).contains(s.measuredToolCenter.x),(0...1).contains(s.measuredToolCenter.y),
              s.measuredToolDepthMeters.isFinite,(0.15...5).contains(s.measuredToolDepthMeters),
              s.toolFeedbackCapturedAtMilliseconds.isFinite,
              abs(s.toolFeedbackCapturedAtMilliseconds-s.capturedAtMilliseconds)<=150 else { return false }
        return true
    }
    private static func patch(_ s:Sample,box:Box) -> Patch? {
        let x=Int((box.left*Double(s.width)).rounded()),y=Int((box.top*Double(s.height)).rounded())
        let w=Int(((box.right-box.left)*Double(s.width)).rounded()),h=Int(((box.bottom-box.top)*Double(s.height)).rounded())
        guard w>=4,h>=4,x>=0,y>=0,x+w<=s.width,y+h<=s.height else { return nil }
        var values:[Double]=[];values.reserveCapacity(w*h)
        for dy in 0..<h { for dx in 0..<w { values.append(Double(s.gray[(y+dy)*s.width+x+dx])) } }
        let mean=values.reduce(0,+)/Double(values.count),centered=values.map { $0-mean }
        let norm=sqrt(centered.reduce(0) { $0+$1*$1 })
        guard norm/sqrt(Double(values.count))>=10 else { return nil }
        return Patch(x:x,y:y,width:w,height:h,values:centered,mean:mean,norm:norm)
    }
    private static func mean(_ s:Sample,x:Int,y:Int,width:Int,height:Int) -> Double {
        var sum=0.0
        for dy in 0..<height { for dx in 0..<width { sum+=Double(s.gray[(y+dy)*s.width+x+dx]) } }
        return sum/Double(width*height)
    }
    /// Two small windows preserve a stationary-can alternative without a
    /// quadratic search over the entire observed lift displacement.
    private static func observedMatch(_ patch:Patch,in sample:Sample,dx:Double,dy:Double)->Match? {
        guard dx.isFinite,dy.isFinite,hypot(dx,dy)<=128 else{return nil}
        let matches=[match(patch,in:sample,centerX:patch.x,centerY:patch.y,radius:8),
                     match(patch,in:sample,centerX:patch.x+Int(dx.rounded()),centerY:patch.y+Int(dy.rounded()),radius:8)].compactMap{$0}
        guard let best=matches.max(by:{$0.correlation<$1.correlation}) else{return nil}
        let exclusion=max(2,min(patch.width,patch.height)/3)
        let competing=matches.filter{abs($0.x-best.x)>exclusion || abs($0.y-best.y)>exclusion}.map(\.correlation).max()
        return Match(x:best.x,y:best.y,correlation:best.correlation,margin:min(best.margin,competing.map{best.correlation-$0} ?? best.margin))
    }

    private static func match(_ patch:Patch,in sample:Sample,centerX:Int,centerY:Int,radius:Int) -> Match? {
        let loX=max(0,centerX-radius),hiX=min(sample.width-patch.width,centerX+radius)
        let loY=max(0,centerY-radius),hiY=min(sample.height-patch.height,centerY+radius)
        guard loX<=hiX,loY<=hiY else { return nil }
        var candidates:[(x:Int,y:Int,score:Double)]=[]
        for y in loY...hiY { for x in loX...hiX {
            let m=mean(sample,x:x,y:y,width:patch.width,height:patch.height)
            var norm=0.0,dot=0.0,index=0
            for dy in 0..<patch.height { for dx in 0..<patch.width {
                let p=Double(sample.gray[(y+dy)*sample.width+x+dx])-m
                dot+=patch.values[index]*p;norm+=p*p;index+=1
            } }
            if norm>1 { candidates.append((x,y,dot/(patch.norm*sqrt(norm)))) }
        } }
        guard let best=candidates.max(by:{ $0.score<$1.score }) else { return nil }
        // Adjacent positions of one image patch are not independent identities.
        let exclusion=max(2,min(patch.width,patch.height)/3)
        let second=candidates.filter { abs($0.x-best.x)>exclusion || abs($0.y-best.y)>exclusion }.map(\.score).max() ?? -1
        return Match(x:best.x,y:best.y,correlation:best.score,margin:best.score-second)
    }
    private static func depth(_ sample:Sample,x:Int,y:Int,width:Int,height:Int) -> Double? {
        var values:[Double]=[]
        var attempted=0
        for dy in stride(from:0,to:height,by:max(1,height/8)) {
            for dx in stride(from:0,to:width,by:max(1,width/8)) {
                attempted+=1
                let z=Double(sample.depthMeters[(y+dy)*sample.width+x+dx])
                if z.isFinite,(0.15...5).contains(z) { values.append(z) }
            }
        }
        guard values.count>=12,Double(values.count)/Double(attempted)>=0.6 else { return nil }
        values.sort();let median=values[values.count/2]
        let deviations=values.map { abs($0-median) }.sorted()
        guard deviations[deviations.count/2]<=0.012 else { return nil }
        return median
    }
}


/// Image-only adapter. Finger depth is sampled at observed fingertips OUTSIDE
/// the complete can ROI. No FK projection, assumed can depth or detector-box
/// motion supplies tool evidence. The existing registered verifier is reused.
extension ROBVisualGraspVerifier {
    struct AppearanceSeed {
        let sequence:UInt64,capturedAtMilliseconds:Double,cameraGeneration:UUID
        let fixedViewIdentity:String,targetIdentity:String,sourceIdentity:String
        let width:Int,height:Int,gray:[UInt8],canBox:Box
        let synchronizedRGBDepth:Bool,handsClear:Bool
    }
    struct ObservedJawInput {
        let sequence:UInt64,capturedAtMilliseconds:Double,cameraGeneration:UUID
        let fixedViewIdentity:String,targetIdentity:String,sourceIdentity:String
        let width:Int,height:Int,gray:[UInt8],depthMeters:[Float]
        let fx:Double,fy:Double,cx:Double,cy:Double
        let synchronizedRGBDepth:Bool,handsClear:Bool
        let jawCenterPixels:Point,fingerTipsPixels:[Point]
        let jawSequence:UInt64,jawCapturedAtMilliseconds:Double,jawScopeIdentity:String
        let jawConfidence:Double,jawEvidenceKind:String
        let canBox:Box
    }
    struct ObservedJawVerifier {
        private var verifier:ROBVisualGraspVerifier
        private let sourceIdentity:String
        init(baseline:ObservedJawInput,appearance:AppearanceSeed,nowMilliseconds:Double)throws {
            sourceIdentity=baseline.sourceIdentity
            guard appearance.sourceIdentity==baseline.sourceIdentity else{throw Unavailable.evidence("Pre-approach can appearance belongs to another RGB-D source.")}
            guard (0...12_000).contains(nowMilliseconds-baseline.capturedAtMilliseconds) else {throw Unavailable.evidence("The pre-lift appearance baseline expired.")}
            // A retained pre-lift frame is an appearance baseline, not a claim
            // of current feedback. All subsequent frames still need freshness.
            verifier=try ROBVisualGraspVerifier(baseline:Self.sample(baseline,now:baseline.capturedAtMilliseconds),targetBox:baseline.canBox,nowMilliseconds:baseline.capturedAtMilliseconds,independentAppearance:appearance)
        }
        var evidence:Evidence {verifier.evidence}
        mutating func observe(_ value:ObservedJawInput,nowMilliseconds:Double)throws->Evidence {
            guard value.sourceIdentity==sourceIdentity else {throw Unavailable.evidence("The synchronized RGB-D source changed.")}
            return verifier.observe(try Self.sample(value,now:nowMilliseconds),nowMilliseconds:nowMilliseconds)
        }
        mutating func finish()->Evidence {verifier.finish()}
        private static func sample(_ v:ObservedJawInput,now:Double)throws->Sample {
            guard !v.sourceIdentity.isEmpty,!v.fixedViewIdentity.isEmpty,v.canBox.valid,
                  (80...640).contains(v.width),(60...480).contains(v.height),v.gray.count==v.width*v.height,
                  v.depthMeters.count==v.gray.count,v.synchronizedRGBDepth,v.handsClear,
                  [v.fx,v.fy,v.cx,v.cy].allSatisfy(\.isFinite),v.fx>0,v.fy>0,
                  v.fingerTipsPixels.count==2,v.jawSequence==v.sequence,
                  v.jawCapturedAtMilliseconds==v.capturedAtMilliseconds,v.jawScopeIdentity==v.fixedViewIdentity,
                  v.jawConfidence.isFinite,v.jawConfidence>=0.65,
                  v.jawEvidenceKind=="image_observed_opening_after_release_command_then_temporal_edges",
                  [v.jawCenterPixels.x,v.jawCenterPixels.y].allSatisfy(\.isFinite),
                  (0..<Double(v.width)).contains(v.jawCenterPixels.x),(0..<Double(v.height)).contains(v.jawCenterPixels.y) else {
                throw Unavailable.evidence("Independent observed fingers and current synchronized RGB-D source are required.")
            }
            var depths:[Double]=[],regions:[Box]=[]
            let spanX=v.fingerTipsPixels[1].x-v.fingerTipsPixels[0].x,spanY=v.fingerTipsPixels[1].y-v.fingerTipsPixels[0].y
            let span=hypot(spanX,spanY)
            guard span.isFinite,span>=8 else{throw Unavailable.evidence("Observed fingers have no independently resolved span.")}
            for (index,tip) in v.fingerTipsPixels.enumerated() {
                guard tip.x.isFinite,tip.y.isFinite,tip.x>=4,tip.y>=4,tip.x<Double(v.width-4),tip.y<Double(v.height-4) else {throw Unavailable.evidence("Observed fingertip depth is unavailable.")}
                // Inner edges can coincide with the can silhouette. Sample
                // the observed finger FACE outward along the measured span.
                let sign=index==0 ? -1.0:1.0
                let faceX=tip.x+sign*spanX/span*4,faceY=tip.y+sign*spanY/span*4
                let x=Int(faceX.rounded()),y=Int(faceY.rounded())
                guard x>=2,y>=2,x<v.width-2,y<v.height-2 else{throw Unavailable.evidence("Observed finger face lies outside the RGB-D image.")}
                var values:[Double]=[]
                for dy in -2...2 {for dx in -2...2 {
                    let px=x+dx,py=y+dy,u=Double(px)/Double(v.width),w=Double(py)/Double(v.height)
                    // Exclude the entire detector ROI, including its boundary.
                    guard u<v.canBox.left || u>v.canBox.right || w<v.canBox.top || w>v.canBox.bottom else {continue}
                    let z=Double(v.depthMeters[py*v.width+px]);if z.isFinite,(0.15...5).contains(z) {values.append(z)}
                }}
                guard values.count>=15 else {throw Unavailable.evidence("Finger depth outside the can ROI is missing; can depth cannot substitute.")}
                values.sort();let z=values[values.count/2]
                guard values.filter({abs($0-z)<=0.012}).count>=Int(ceil(Double(values.count)*0.8)) else {throw Unavailable.evidence("Observed finger depth is discontinuous.")}
                depths.append(z)
                regions.append(.init(left:max(0,(min(tip.x,faceX)-4)/Double(v.width)),top:max(0,(min(tip.y,faceY,v.jawCenterPixels.y)-4)/Double(v.height)),
                    right:min(1,(max(tip.x,faceX)+4)/Double(v.width)),bottom:min(1,(max(tip.y,faceY,v.jawCenterPixels.y)+4)/Double(v.height))))
            }
            let points=zip(v.fingerTipsPixels,depths).map{point,z in
                [(point.x-v.cx)*z/v.fx,(point.y-v.cy)*z/v.fy,z]
            }
            let separation=sqrt(zip(points[0],points[1]).reduce(0.0){$0+pow($1.0-$1.1,2)})
            // A broad physical finger-span bound allows oblique views. Equal
            // optical depths are not required for horizontally opened jaws.
            guard separation.isFinite,(0.008...0.18).contains(separation) else {throw Unavailable.evidence("Observed finger separation is physically inconsistent.")}
            var sample=Sample(sequence:v.sequence,capturedAtMilliseconds:v.capturedAtMilliseconds,synchronizedRGBDepth:v.synchronizedRGBDepth,
                cameraGeneration:v.cameraGeneration,fixedViewIdentity:v.fixedViewIdentity,targetIdentity:v.targetIdentity,width:v.width,height:v.height,
                gray:v.gray,depthMeters:v.depthMeters,measuredToolCenter:.init(x:v.jawCenterPixels.x/Double(v.width),y:v.jawCenterPixels.y/Double(v.height)),
                measuredToolDepthMeters:(depths[0]+depths[1])/2,toolFeedbackCapturedAtMilliseconds:v.jawCapturedAtMilliseconds,handsClear:v.handsClear)
            sample.toolEvidenceSource="independent_observed_fingers";sample.observedFingerRegions=regions
            guard valid(sample,now:now) else {throw Unavailable.evidence("Observed jaw capture is stale or invalid.")}
            return sample
        }
    }
}
