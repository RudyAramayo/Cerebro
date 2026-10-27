import Foundation

/// Pure image evidence only. The executor must additionally bind the live
/// attachment, release, ownership and observation phase before using support.
typealias ROBVisualDropVerifier = ROBVisualGraspVerifier.DropVerifier

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
        var cameraCollisionAdvisory=false
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
        var cameraCollisionAdvisory=false
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
        evidence.cameraCollisionAdvisory=baseline.cameraCollisionAdvisory
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
              reference.targetIdentity==current.targetIdentity,reference.synchronizedRGBDepth,(reference.handsClear || reference.cameraCollisionAdvisory),
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
              seed.gray.count==current.gray.count,seed.canBox.valid,(seed.handsClear || seed.cameraCollisionAdvisory),seed.synchronizedRGBDepth else{return nil}
        let pixels=Sample(sequence:seed.sequence,capturedAtMilliseconds:seed.capturedAtMilliseconds,synchronizedRGBDepth:seed.synchronizedRGBDepth,
            cameraGeneration:seed.cameraGeneration,fixedViewIdentity:seed.fixedViewIdentity,targetIdentity:seed.targetIdentity,
            width:seed.width,height:seed.height,gray:seed.gray,depthMeters:[],measuredToolCenter:.init(x:.nan,y:.nan),
            measuredToolDepthMeters:.nan,toolFeedbackCapturedAtMilliseconds:.nan,handsClear:seed.handsClear,cameraCollisionAdvisory:seed.cameraCollisionAdvisory)
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
              (0...800).contains(now-s.capturedAtMilliseconds),s.synchronizedRGBDepth,(s.handsClear || s.cameraCollisionAdvisory),
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
        var cameraCollisionAdvisory=false
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
        var cameraCollisionAdvisory=false
    }
    /// Minted only by the actual observed-jaw verifier reaching support.
    /// This object cannot be decoded, copied from an archive or claimed twice.
    final class ObservedSupport {
        let evidence:Evidence
        let sourceIdentity:String
        private let lock=NSLock()
        private var claimed=false
        fileprivate init(evidence:Evidence,sourceIdentity:String) {
            self.evidence=evidence;self.sourceIdentity=sourceIdentity
        }
        func claimForNativeAttachment()->Bool {
            lock.lock();defer{lock.unlock()}
            guard !claimed else{return false};claimed=true;return true
        }
    }
    struct ObservedJawVerifier {
        private var verifier:ROBVisualGraspVerifier
        private let sourceIdentity:String
        private var nativeSupport:ObservedSupport? = nil
        init(baseline:ObservedJawInput,appearance:AppearanceSeed,nowMilliseconds:Double)throws {
            sourceIdentity=baseline.sourceIdentity
            guard appearance.sourceIdentity==baseline.sourceIdentity else{throw Unavailable.evidence("Pre-approach can appearance belongs to another RGB-D source.")}
            guard (0...12_000).contains(nowMilliseconds-baseline.capturedAtMilliseconds) else {throw Unavailable.evidence("The pre-lift appearance baseline expired.")}
            // A retained pre-lift frame is an appearance baseline, not a claim
            // of current feedback. All subsequent frames still need freshness.
            verifier=try ROBVisualGraspVerifier(baseline:Self.sample(baseline,now:baseline.capturedAtMilliseconds),targetBox:baseline.canBox,nowMilliseconds:baseline.capturedAtMilliseconds,independentAppearance:appearance)
        }
        var evidence:Evidence {verifier.evidence}
        var nativeSupportedObservation:ObservedSupport? {nativeSupport}
        mutating func observe(_ value:ObservedJawInput,nowMilliseconds:Double)throws->Evidence {
            guard value.sourceIdentity==sourceIdentity else {throw Unavailable.evidence("The synchronized RGB-D source changed.")}
            let result=verifier.observe(try Self.sample(value,now:nowMilliseconds),nowMilliseconds:nowMilliseconds)
            if result.verdict == .supported,nativeSupport==nil {
                nativeSupport=ObservedSupport(evidence:result,sourceIdentity:sourceIdentity)
            }
            return result
        }
        mutating func finish()->Evidence {verifier.finish()}
        private static func sample(_ v:ObservedJawInput,now:Double)throws->Sample {
            guard !v.sourceIdentity.isEmpty,!v.fixedViewIdentity.isEmpty,v.canBox.valid,
                  (80...640).contains(v.width),(60...480).contains(v.height),v.gray.count==v.width*v.height,
                  v.depthMeters.count==v.gray.count,v.synchronizedRGBDepth,(v.handsClear || v.cameraCollisionAdvisory),
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
                measuredToolDepthMeters:(depths[0]+depths[1])/2,toolFeedbackCapturedAtMilliseconds:v.jawCapturedAtMilliseconds,handsClear:v.handsClear,cameraCollisionAdvisory:v.cameraCollisionAdvisory)
            sample.toolEvidenceSource="independent_observed_fingers";sample.observedFingerRegions=regions
            guard valid(sample,now:now) else {throw Unavailable.evidence("Observed jaw capture is stale or invalid.")}
            return sample
        }
    }
}

extension ROBVisualGraspVerifier {
    /// Independent observed opening entry. No common bucket shape prior, FK
    /// tool projection or disappearance can supply a positive entry event.
    struct DropVerifier {
        struct Scope: Codable,Equatable {
            let phaseID:UUID,attachmentID:UUID,cameraGeneration:UUID
            let bodyMotionIdentity:String,sourceIdentity:String,runtimeCalibrationIdentity:String
            let estimatedCameraProjectionIdentity:String,fixedViewIdentity:String,targetIdentity:String
        }
        struct Frame {
            let scope:Scope,sequence:UInt64,capturedAtMilliseconds:Double
            let width:Int,height:Int,rgb:[UInt8],depthMeters:[Float]
            let fx:Double,fy:Double,cx:Double,cy:Double
            let synchronizedRGBDepth:Bool
            /// From the image-observed finger detector for THIS exact frame,
            /// never projected commanded fingers or a previous tracker box.
            let fingerRegions:[Box],fingerSequence:UInt64,fingerConfidence:Double
            let fingerEvidenceKind:String
            var valid:Bool {
                (80...640).contains(width) && (60...480).contains(height) &&
                    rgb.count==width*height*3 && depthMeters.count==width*height && sequence>0 &&
                    capturedAtMilliseconds.isFinite && synchronizedRGBDepth &&
                    [fx,fy,cx,cy].allSatisfy(\.isFinite) && fx>0 && fy>0 &&
                    !scope.sourceIdentity.isEmpty && !scope.runtimeCalibrationIdentity.isEmpty &&
                    !scope.estimatedCameraProjectionIdentity.isEmpty &&
                    !scope.bodyMotionIdentity.isEmpty && !scope.fixedViewIdentity.isEmpty && !scope.targetIdentity.isEmpty
            }
            fileprivate var sample:Sample {
                var gray=[UInt8]();gray.reserveCapacity(width*height)
                for i in stride(from:0,to:rgb.count,by:3) {
                    let red=Int(rgb[i])*299,green=Int(rgb[i+1])*587,blue=Int(rgb[i+2])*114
                    gray.append(UInt8((red+green+blue)/1000))
                }
                // Pixels only: deliberately invalid tool values cannot become
                // registered feedback or pass the grasp sample validator.
                return Sample(sequence:sequence,capturedAtMilliseconds:capturedAtMilliseconds,synchronizedRGBDepth:synchronizedRGBDepth,
                    cameraGeneration:scope.cameraGeneration,fixedViewIdentity:scope.fixedViewIdentity,targetIdentity:scope.targetIdentity,
                    width:width,height:height,gray:gray,depthMeters:depthMeters,measuredToolCenter:.init(x:.nan,y:.nan),
                    measuredToolDepthMeters:.nan,toolFeedbackCapturedAtMilliseconds:.nan,handsClear:false)
            }
            fileprivate func point(_ x:Double,_ y:Double,_ z:Double)->SIMD3<Double> {SIMD3((x-cx)*z/fx,(y-cy)*z/fy,z)}
            fileprivate func orange(_ x:Int,_ y:Int)->Bool {
                let i=(y*width+x)*3,r=Double(rgb[i]),g=Double(rgb[i+1]),b=Double(rgb[i+2])
                return r>=90 && g>=35 && r>g*1.12 && g>b*1.2 && r-b>=55
            }
        }
        /// A bounded immutable raw-frame store. The CameraFrameSet hook must
        /// offer frames before the perception consumer's 5Hz/busy throttle.
        /// This type never invents frames, restamps captures or grants motion.
        final class RawRing {
            private let lock=NSLock(),scope:Scope
            private var values:[Frame]=[]
            private var isInvalidated=false
            var invalidated:Bool {lock.lock();defer{lock.unlock()};return isInvalidated}
            init(scope:Scope) {self.scope=scope}
            @discardableResult func append(_ frame:Frame,nowMilliseconds:Double)->Bool {
                lock.lock();defer{lock.unlock()}
                guard !isInvalidated,frame.valid,frame.scope==scope,nowMilliseconds.isFinite,
                      (0...800).contains(nowMilliseconds-frame.capturedAtMilliseconds),
                      values.last.map({frame.sequence>$0.sequence && frame.capturedAtMilliseconds>$0.capturedAtMilliseconds &&
                          frame.width==$0.width && frame.height==$0.height && [frame.fx,frame.fy,frame.cx,frame.cy]==[$0.fx,$0.fy,$0.cx,$0.cy]}) ?? true else {
                    isInvalidated=true;values=[];return false
                }
                values.append(frame)
                // 96 native frames and at most 3 seconds; bound resident
                // storage as well for full-resolution RGB/depth captures.
                while values.count>96 || (values.first.map{frame.capturedAtMilliseconds-$0.capturedAtMilliseconds>3000} ?? false) ||
                        values.reduce(0,{$0+$1.rgb.count+$1.depthMeters.count*MemoryLayout<Float>.stride})>220_000_000 {values.removeFirst()}
                return true
            }
            func snapshot()->[Frame] {lock.lock();defer{lock.unlock()};return isInvalidated ? []:values}
            func invalidate() {lock.lock();defer{lock.unlock()};isInvalidated=true;values=[]}
        }
        enum Verdict:String,Codable {case collecting,supported,stillHeld,outsideOpening,unknown}
        struct Evidence:Encodable {
            var verdict:Verdict,reason:String,samples:Int
            let scope:Scope,canDiameterMeters:Double,canHeightMeters:Double,uncertaintyMeters:Double
            let releaseAcceptedAtMilliseconds:Double,gravityOptical:[Double]
            let scopePhaseID:UUID,attachmentID:UUID,firstSequence:UInt64,baselineCapturedAtMilliseconds:Double
            var lastSequence:UInt64,lastCapturedAtMilliseconds:Double
            let observedRimPointCount:Int,observedRimRMSEMeters:Double
            var entrySequence:UInt64?,minimumWholeCanBelowRimMeters:Double?
            var correlation:Double? = nil
            var uniquenessMargin:Double? = nil
            var clearFingerSamples:Int,noBounceObservedMilliseconds:Double
            let observedRestingCan=false
            let source="raw_RGBD_identity_whole_can_opening_crossing_observed_empty_fingers_visible_mouth_no_outbound"
        }
        final class NativePlacementSupport {
            let evidence:Evidence,scope:Scope
            private let lock=NSLock()
            private var consumed=false
            fileprivate init(_ evidence:Evidence,scope:Scope) {self.evidence=evidence;self.scope=scope}
            func claimForNativeCompletion(currentScope:Scope,nowMilliseconds:Double)->Bool {
                lock.lock();defer{lock.unlock()};guard !consumed else{return false};consumed=true
                return currentScope==scope && nowMilliseconds.isFinite &&
                    (0...800).contains(nowMilliseconds-evidence.lastCapturedAtMilliseconds)
            }
        }
        private struct Opening {
            let roi:Box,hole:Set<Int>,boundary:[Int],normal:SIMD3<Double>,offset:Double,rmse:Double,rimCount:Int
        }
        private struct TrackedCan {let match:Match,scale:Double}
        private let baseline:Frame,opening:Opening,target:Patch,canBox:Box,diameter:Double,heightMeters:Double
        private let gravity:SIMD3<Double>,uncertainty:Double,releaseAt:Double
        private var lastX:Int,lastY:Int,lastSequence:UInt64,lastTime:Double,previousCenter:SIMD3<Double>?
        private var lastScale=1.0
        private var seenAbove=false,entryAt:Double?,emptyCount=0,postEntryFrames=0
        private(set) var evidence:Evidence
        private(set) var nativeSupport:NativePlacementSupport?
        private static func dot(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
        private static func length(_ a:SIMD3<Double>)->Double {sqrt(dot(a,a))}
        private static func cross(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->SIMD3<Double> {SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)}
        private static func normalized(_ a:SIMD3<Double>)->SIMD3<Double>? {let n=length(a);return n.isFinite && n>1e-10 ? a/n:nil}
        private static func rectangle(_ b:Box,_ f:Frame)->(Int,Int,Int,Int)? {
            guard b.valid else{return nil};let x=Int((b.left*Double(f.width)).rounded()),y=Int((b.top*Double(f.height)).rounded())
            let w=Int(((b.right-b.left)*Double(f.width)).rounded()),h=Int(((b.bottom-b.top)*Double(f.height)).rounded())
            return x>=0 && y>=0 && w>=4 && h>=4 && x+w<=f.width && y+h<=f.height ? (x,y,w,h):nil
        }
        private static func solve(_ rows:[SIMD3<Double>],_ z:[Double])->SIMD3<Double>? {
            guard rows.count==z.count,rows.count>=3 else{return nil}
            var a=Array(repeating:Array(repeating:0.0,count:4),count:3)
            for (p,v) in zip(rows,z) {for i in 0..<3 {for j in 0..<3 {a[i][j]+=p[i]*p[j]};a[i][3]+=p[i]*v}}
            for i in 0..<3 {guard let p=(i..<3).max(by:{abs(a[$0][i])<abs(a[$1][i])}),abs(a[p][i])>1e-10 else{return nil};a.swapAt(i,p)
                let d=a[i][i];for j in i..<4 {a[i][j]/=d};for k in 0..<3 where k != i {let m=a[k][i];for j in i..<4 {a[k][j]-=m*a[i][j]}}}
            let result=SIMD3(a[0][3],a[1][3],a[2][3]);return [result.x,result.y,result.z].allSatisfy(\.isFinite) ? result:nil
        }
        private static func observedOpening(_ f:Frame,roi:Box)->Opening? {
            guard let(x0,y0,w,h)=rectangle(roi,f),w>=24,h>=24 else{return nil}
            // The actual dark/nonorange interior must be enclosed by visible
            // orange pixels. No inferred ellipse closes a missing/occluded rim.
            let sx=x0+w/2,sy=y0+h/2
            guard !f.orange(sx,sy) else{return nil}
            var seen=Set<Int>(),queue=[sy*f.width+sx],cursor=0
            seen.insert(queue[0])
            while cursor<queue.count {
                let p=queue[cursor];cursor+=1;let x=p%f.width,y=p/f.width
                guard x>x0,y>y0,x<x0+w-1,y<y0+h-1 else{return nil}
                for q in [p-1,p+1,p-f.width,p+f.width] where !seen.contains(q) && !f.orange(q%f.width,q/f.width) {seen.insert(q);queue.append(q)}
            }
            guard seen.count>=80,Double(seen.count)<Double(w*h)*0.9 else{return nil}
            let boundary=seen.filter{p in [p-1,p+1,p-f.width,p+f.width].contains{!seen.contains($0)}}.sorted()
            guard boundary.count>=32 else{return nil}
            var rim:[SIMD3<Double>]=[]
            for i in stride(from:0,to:boundary.count,by:max(1,boundary.count/160)) {
                let p=boundary[i]
                for q in [p-1,p+1,p-f.width,p+f.width] where f.orange(q%f.width,q/f.width) {
                    let z=Double(f.depthMeters[q]);if z.isFinite,(0.15...3).contains(z) {rim.append(f.point(Double(q%f.width),Double(q/f.width),z));break}
                }
            }
            guard rim.count>=30,let fit=solve(rim.map{SIMD3($0.x,$0.y,1)},rim.map(\.z)),
                  let normal=normalized(SIMD3(fit.x,fit.y,-1)) else{return nil}
            let sampledBoundaryCount=(boundary.count+max(1,boundary.count/160)-1)/max(1,boundary.count/160)
            guard Double(rim.count)/Double(sampledBoundaryCount)>=0.75 else{return nil}
            let offset=fit.z/sqrt(1+fit.x*fit.x+fit.y*fit.y)
            let errors=rim.map{abs(dot(normal,$0)+offset)},rmse=sqrt(errors.reduce(0){$0+$1*$1}/Double(errors.count))
            guard rmse<=0.010,errors.filter({$0<=0.015}).count>=rim.count*9/10 else{return nil}
            var recessed=0,valid=0
            for p in queue where p%5==0 {
                let z=Double(f.depthMeters[p]);guard z.isFinite,(0.15...3).contains(z) else{continue};valid+=1
                if dot(normal,f.point(Double(p%f.width),Double(p/f.width),z))+offset < -0.04 {recessed+=1}
            }
            guard valid>=25,Double(recessed)/Double(valid)>=0.65 else{return nil}
            return Opening(roi:roi,hole:seen,boundary:boundary,normal:normal,offset:offset,rmse:rmse,rimCount:rim.count)
        }
        /// `gravityOptical` is the unit direction of physical DOWN in the
        /// current RGB optical frame. Stationary BNO086 acceleration metadata
        /// supplies support/UP: the native adapter must use
        /// -normalize(R_imuToRGB * meanAcceleration), despite a field named
        /// gravity_mps2. Passing UP is rejected against the observed rim.
        init(baseline:Frame,canBox:Box,bucketROI:Box,canDiameterMeters:Double,canHeightMeters:Double,
             gravityOptical:SIMD3<Double>,uncertaintyMeters:Double,releaseAcceptedAtMilliseconds:Double,nowMilliseconds:Double)throws {
            guard baseline.valid,nowMilliseconds.isFinite,(0...800).contains(nowMilliseconds-baseline.capturedAtMilliseconds),
                  canDiameterMeters.isFinite,(0.04...0.10).contains(canDiameterMeters),canHeightMeters.isFinite,(0.07...0.20).contains(canHeightMeters),
                  uncertaintyMeters.isFinite,(0.005...0.05).contains(uncertaintyMeters),
                  releaseAcceptedAtMilliseconds.isFinite,(0...500).contains(releaseAcceptedAtMilliseconds-baseline.capturedAtMilliseconds),
                  let g=Self.normalized(gravityOptical),abs(Self.length(gravityOptical)-1)<0.01,
                  let opening=Self.observedOpening(baseline,roi:bucketROI),Self.dot(g,opening.normal) < -0.3 else {
                throw Unavailable.evidence("A fresh actual closed orange rim with measured planar depth/recessed interior and independent gravity is required; a bucket prior is insufficient.")
            }
            let w=canBox.right-canBox.left,h=canBox.bottom-canBox.top
            let core=Box(left:canBox.left+w*0.2,top:canBox.top+h*0.15,right:canBox.right-w*0.2,bottom:canBox.bottom-h*0.15)
            guard canBox.valid,let patch=ROBVisualGraspVerifier.patch(baseline.sample,box:core),patch.width>=6,patch.height>=8,
                  ROBVisualGraspVerifier.depth(baseline.sample,x:patch.x,y:patch.y,width:patch.width,height:patch.height) != nil else {
                throw Unavailable.evidence("The actual pre-release held-can wall is not distinctive or lacks valid synchronized depth.")
            }
            self.baseline=baseline;self.opening=opening;target=patch;self.canBox=canBox;diameter=canDiameterMeters;heightMeters=canHeightMeters
            gravity=g;uncertainty=uncertaintyMeters;releaseAt=releaseAcceptedAtMilliseconds
            lastX=patch.x;lastY=patch.y;lastSequence=baseline.sequence;lastTime=baseline.capturedAtMilliseconds
            evidence=Evidence(verdict:.collecting,reason:"Collecting actual whole-can entry and clear-finger evidence.",samples:0,
                scope:baseline.scope,canDiameterMeters:canDiameterMeters,canHeightMeters:canHeightMeters,uncertaintyMeters:uncertaintyMeters,
                releaseAcceptedAtMilliseconds:releaseAcceptedAtMilliseconds,gravityOptical:[g.x,g.y,g.z],
                scopePhaseID:baseline.scope.phaseID,attachmentID:baseline.scope.attachmentID,firstSequence:baseline.sequence,
                baselineCapturedAtMilliseconds:baseline.capturedAtMilliseconds,lastSequence:baseline.sequence,lastCapturedAtMilliseconds:baseline.capturedAtMilliseconds,
                observedRimPointCount:opening.rimCount,observedRimRMSEMeters:opening.rmse,clearFingerSamples:0,noBounceObservedMilliseconds:0)
        }
        private func stableOpening(_ f:Frame)->Bool {
            var attempted=0,valid=0,matching=0
            for i in stride(from:0,to:opening.boundary.count,by:max(1,opening.boundary.count/100)) {
                attempted+=1
                let p=opening.boundary[i];var found=false
                for q in [p-1,p+1,p-f.width,p+f.width] where f.orange(q%f.width,q/f.width) {
                    let z=Double(f.depthMeters[q]);guard z.isFinite,(0.15...3).contains(z) else{continue};valid+=1
                    if abs(Self.dot(opening.normal,f.point(Double(q%f.width),Double(q/f.width),z))+opening.offset)<=0.015 {found=true};break
                }
                if found {matching+=1}
            }
            return valid>=30 && Double(matching)/Double(max(1,attempted))>=0.9
        }
        private func clearObservedFingers(_ f:Frame)->Bool {
            guard f.fingerSequence==f.sequence,f.fingerConfidence.isFinite,f.fingerConfidence>=0.65,
                  f.fingerEvidenceKind=="image_observed_opening_after_release_command_then_temporal_edges",f.fingerRegions.count==2,
                  f.fingerRegions.allSatisfy(\.valid) else{return false}
            let regions=f.fingerRegions.sorted{$0.center.x<$1.center.x},a=regions[0],b=regions[1]
            let gap=Box(left:a.right,top:max(a.top,b.top),right:b.left,bottom:min(a.bottom,b.bottom))
            guard let(x,y,w,h)=Self.rectangle(gap,f),w>=8,h>=8 else{return false}
            let s=f.sample
            var fingerDepths:[Double]=[]
            for r in regions {guard let(x,y,w,h)=Self.rectangle(r,f),let d=ROBVisualGraspVerifier.depth(s,x:x,y:y,width:w,height:h) else{return false};fingerDepths.append(d)}
            var valid=0,farther=0
            for yy in stride(from:y,to:y+h,by:max(1,h/8)) {for xx in stride(from:x,to:x+w,by:max(1,w/8)) {
                let z=Double(f.depthMeters[yy*f.width+xx]);if z.isFinite,(0.15...5).contains(z) {valid+=1;if z>fingerDepths.max()!+max(0.025,diameter/2) {farther+=1}}
            }}
            return valid>=24 && Double(farther)/Double(valid)>=0.9
        }
        private func volume(_ f:Frame,tracked:TrackedCan,sample:Sample)->[SIMD3<Double>]? {
            let match=tracked.match,scale=tracked.scale
            let left=Double(match.x)-(Double(target.x)-canBox.left*Double(f.width))*scale
            let top=Double(match.y)-(Double(target.y)-canBox.top*Double(f.height))*scale
            let box=Box(left:left/Double(f.width),top:top/Double(f.height),
                right:left/Double(f.width)+(canBox.right-canBox.left)*scale,
                bottom:top/Double(f.height)+(canBox.bottom-canBox.top)*scale)
            guard let(x,y,w,h)=Self.rectangle(box,f),!f.fingerRegions.contains(where:{r in !(r.right<box.left || r.left>box.right || r.bottom<box.top || r.top>box.bottom)}),
                  let z=ROBVisualGraspVerifier.depth(sample,x:match.x,y:match.y,width:max(6,Int((Double(target.width)*scale).rounded())),
                    height:max(8,Int((Double(target.height)*scale).rounded()))) else{return nil}
            // Independently support the full translated silhouette with raw
            // depth at every edge; the central NCC patch cannot stand in for
            // an unseen can top, bottom or rear surface.
            for edge in 0..<4 {
                var valid=0,edgeValid=0,foreground=0,outsideValid=0,outsideClear=0
                for i in 1...12 {
                    let xx=edge<2 ? x+i*(w-1)/13:(edge==2 ? x:x+w-1)
                    let yy=edge>=2 ? y+i*(h-1)/13:(edge==0 ? y:y+h-1)
                    let edgeDepth=Double(f.depthMeters[yy*f.width+xx])
                    if edgeDepth.isFinite,(0.15...5).contains(edgeDepth) {edgeValid+=1}
                    let inwardX=edge==2 ? 1:(edge==3 ? -1:0),inwardY=edge==0 ? 1:(edge==1 ? -1:0)
                    var supported=false
                    for k in 0...max(2,min(w,h)/10) {
                        let px=xx+inwardX*k,py=yy+inwardY*k,d=Double(f.depthMeters[py*f.width+px])
                        if d.isFinite,(0.15...5).contains(d) {valid+=1
                            if abs(d-z)<=diameter/2+uncertainty,!f.orange(px,py) {supported=true}}
                    }
                    if supported {foreground+=1}
                    let ox=xx-inwardX*2,oy=yy-inwardY*2
                    guard ox>=0,oy>=0,ox<f.width,oy<f.height else{return nil}
                    let outside=Double(f.depthMeters[oy*f.width+ox])
                    if outside.isFinite,(0.15...5).contains(outside) {outsideValid+=1
                        if outside>z+diameter/2+uncertainty {outsideClear+=1}}
                }
                guard valid>=9,edgeValid>=9,foreground>=6,outsideValid>=9,outsideClear>=9 else{return nil}
            }
            var visibleDepths:[Double]=[]
            for yy in y..<y+h {for xx in x..<x+w {
                let d=Double(f.depthMeters[yy*f.width+xx])
                if d.isFinite,(0.15...5).contains(d),abs(d-z)<=diameter/2+uncertainty,!f.orange(xx,yy) {visibleDepths.append(d)}
            }}
            guard visibleDepths.count>=w*h/2,let nearest=visibleDepths.min(),let farthest=visibleDepths.max() else{return nil}
            // The visible silhouette is closed by observed exterior depth;
            // include the entire measured can diagonal behind its first raw
            // returns, rather than pretending its center patch is its depth.
            let diagonal=hypot(heightMeters,diameter)
            let pad=2+Int(ceil(uncertainty*max(f.fx,f.fy)/z)),near=max(0.15,nearest-uncertainty),far=farthest+diagonal+uncertainty
            guard x-pad>=0,y-pad>=0,x+w+pad<f.width,y+h+pad<f.height else{return nil}
            var points:[SIMD3<Double>]=[]
            for xx in [x-pad,x+w+pad] {for yy in [y-pad,y+h+pad] {for zz in [near,far] {points.append(f.point(Double(xx),Double(yy),zz))}}}
            return points
        }
        private func scaledTarget(_ scale:Double)->Patch? {
            if abs(scale-1)<1e-6 {return target}
            let w=Int((Double(target.width)*scale).rounded()),h=Int((Double(target.height)*scale).rounded())
            guard w>=6,h>=8 else{return nil}
            var values:[Double]=[]
            for y in 0..<h {for x in 0..<w {
                let xx=Double(x)*Double(target.width-1)/Double(w-1),yy=Double(y)*Double(target.height-1)/Double(h-1)
                let x0=Int(xx),y0=Int(yy),x1=min(target.width-1,x0+1),y1=min(target.height-1,y0+1),dx=xx-Double(x0),dy=yy-Double(y0)
                let a=target.values[y0*target.width+x0]*(1-dx)+target.values[y0*target.width+x1]*dx
                let b=target.values[y1*target.width+x0]*(1-dx)+target.values[y1*target.width+x1]*dx
                values.append(a*(1-dy)+b*dy)
            }}
            let mean=values.reduce(0,+)/Double(values.count),centered=values.map{$0-mean},norm=sqrt(centered.reduce(0){$0+$1*$1})
            return norm>1 ? Patch(x:target.x,y:target.y,width:w,height:h,values:centered,mean:target.mean+mean,norm:norm):nil
        }
        private func rawMatch(_ patch:Patch,in sample:Sample,frame:Frame)->Match? {
            let loX=max(0,lastX-24),hiX=min(frame.width-patch.width,lastX+24)
            let loY=max(0,lastY-24),hiY=min(frame.height-patch.height,lastY+24)
            guard loX<=hiX,loY<=hiY else{return nil}
            // Direct NCC on a distributed, bounded subset of actual patch
            // pixels. Evaluate every candidate displacement, rather than
            // skipping image positions or following a tracker prediction.
            let step=max(1,max(patch.width,patch.height)/16)
            var offsets:[(Int,Int,Double)]=[]
            for dy in stride(from:0,to:patch.height,by:step) {for dx in stride(from:0,to:patch.width,by:step) {
                offsets.append((dx,dy,patch.values[dy*patch.width+dx]))
            }}
            guard offsets.count>=24 else{return nil}
            let mean=offsets.reduce(0){$0+$1.2}/Double(offsets.count)
            let norm=sqrt(offsets.reduce(0){$0+pow($1.2-mean,2)})
            guard norm>1 else{return nil}
            var matches:[(Int,Int,Double)]=[]
            for y in loY...hiY {for x in loX...hiX {
                let xx=x+patch.width/2,yy=y+patch.height/2,i=yy*frame.width+xx
                let z=Double(frame.depthMeters[i]),before=Double(baseline.depthMeters[i])
                // A pre-existing can inside the bucket has unchanged raw
                // depth here. Its identical logo cannot start a new event.
                if z.isFinite,before.isFinite,(0.15...3).contains(before),abs(z-before)<=0.015,
                   Self.dot(opening.normal,baseline.point(Double(xx),Double(yy),before))+opening.offset < -0.04 {continue}
                var sum=0.0,squared=0.0,dot=0.0
                for (dx,dy,p) in offsets {let v=Double(sample.gray[(y+dy)*frame.width+x+dx]);sum+=v;squared+=v*v;dot+=(p-mean)*v}
                let variance=squared-sum*sum/Double(offsets.count)
                if variance>1 {matches.append((x,y,dot/(norm*sqrt(variance))))}
            }}
            guard let best=matches.max(by:{$0.2<$1.2}) else{return nil}
            let exclusion=max(2,min(patch.width,patch.height)/3)
            let second=matches.filter{abs($0.0-best.0)>exclusion || abs($0.1-best.1)>exclusion}.map{$0.2}.max() ?? -1
            return Match(x:best.0,y:best.1,correlation:best.2,margin:best.2-second)
        }
        private func track(_ f:Frame,sample:Sample)->TrackedCan? {
            let original=baseline
            let centerX=min(f.width-1,max(0,lastX+Int(Double(target.width)*lastScale/2)))
            let centerY=min(f.height-1,max(0,lastY+Int(Double(target.height)*lastScale/2)))
            let current=Double(f.depthMeters[centerY*f.width+centerX])
            let oldDepth=ROBVisualGraspVerifier.depth(original.sample,x:target.x,y:target.y,width:target.width,height:target.height)
            var scales=[1.0,lastScale,max(0.6,lastScale-0.1),min(1.3,lastScale+0.1)]
            if let oldDepth,current.isFinite,(0.15...3).contains(current) {scales.append(min(1.3,max(0.6,oldDepth/current)))}
            var candidates:[TrackedCan]=[],used=Set<Int>()
            for scale in scales where used.insert(Int((scale*100).rounded())).inserted {
                guard let patch=scaledTarget(scale) else{continue}
                let found=rawMatch(patch,in:sample,frame:f)
                if let found {candidates.append(TrackedCan(match:found,scale:scale))}
            }
            guard let best=candidates.max(by:{$0.match.correlation<$1.match.correlation}) else{return nil}
            let exclusion=max(2,min(target.width,target.height)/3)
            let other=candidates.filter{abs($0.match.x-best.match.x)>exclusion || abs($0.match.y-best.match.y)>exclusion}.map{$0.match.correlation}.max()
            let m=best.match
            return TrackedCan(match:Match(x:m.x,y:m.y,correlation:m.correlation,margin:min(m.margin,other.map{m.correlation-$0} ?? m.margin)),scale:best.scale)
        }
        private func contained(_ points:[SIMD3<Double>],frame:Frame)->Bool {
            let denominator=Self.dot(opening.normal,gravity)
            for p in points {
                let atRim=p-gravity*((Self.dot(opening.normal,p)+opening.offset)/denominator)
                guard atRim.z>0 else{return false}
                let x=Int((frame.fx*atRim.x/atRim.z+frame.cx).rounded()),y=Int((frame.fy*atRim.y/atRim.z+frame.cy).rounded())
                guard x>=1,y>=1,x<frame.width-1,y<frame.height-1,
                      [-1,0,1].allSatisfy({dy in [-1,0,1].allSatisfy{dx in opening.hole.contains((y+dy)*frame.width+x+dx)}}) else{return false}
            }
            return true
        }
        private func visibleMouthWithoutOutbound(_ f:Frame)->Bool {
            var attempted=0,valid=0,foreground=0
            for p in opening.hole.sorted() where p%5==0 {
                let x=p%f.width,y=p/f.width,u=Double(x)/Double(f.width),v=Double(y)/Double(f.height)
                if f.fingerRegions.contains(where:{$0.left<=u && u<=$0.right && $0.top<=v && v<=$0.bottom}) {continue}
                attempted+=1
                let z=Double(f.depthMeters[p]);guard z.isFinite,(0.15...3).contains(z) else{continue};valid+=1
                if Self.dot(opening.normal,f.point(Double(x),Double(y),z))+opening.offset>uncertainty {foreground+=1}
            }
            // Monitor the entire observed mouth, not only a tracker search
            // box. Unobserved/foreground pixels cannot prove no outbound can.
            return attempted>=30 && Double(valid)/Double(attempted)>=0.75 && foreground<=max(2,attempted/100)
        }
        mutating func observe(_ f:Frame,nowMilliseconds:Double)->Evidence {
            guard evidence.verdict == .collecting else{return evidence}
            func finish(_ verdict:Verdict,_ text:String)->Evidence {var e=evidence;e.verdict=verdict;e.reason=text;return e}
            guard f.valid,f.scope==baseline.scope,f.width==baseline.width,f.height==baseline.height,
                  [f.fx,f.fy,f.cx,f.cy]==[baseline.fx,baseline.fy,baseline.cx,baseline.cy],
                  nowMilliseconds.isFinite,(0...800).contains(nowMilliseconds-f.capturedAtMilliseconds),
                  f.sequence>lastSequence,f.capturedAtMilliseconds>lastTime,f.capturedAtMilliseconds-lastTime<=120,
                  (0...4000).contains(f.capturedAtMilliseconds-releaseAt),stableOpening(f) else {
                evidence=finish(.unknown,"Raw capture/view/source changed, frames were missing/stale, or the actual mouth/rim was no longer visible and stationary.");return evidence
            }
            lastSequence=f.sequence;lastTime=f.capturedAtMilliseconds;evidence.samples+=1
            evidence.lastSequence=f.sequence;evidence.lastCapturedAtMilliseconds=f.capturedAtMilliseconds
            let empty=clearObservedFingers(f);emptyCount=empty ? emptyCount+1:0;evidence.clearFingerSamples=emptyCount
            let sample=f.sample
            let tracked=track(f,sample:sample)
            if let tracked,tracked.match.correlation>=0.85,tracked.match.margin>=0.08 {
                let found=tracked.match
                evidence.correlation=found.correlation;evidence.uniquenessMargin=found.margin
                lastX=found.x;lastY=found.y;lastScale=tracked.scale
                if let points=volume(f,tracked:tracked,sample:sample) {
                    let heights=points.map{Self.dot(opening.normal,$0)+opening.offset}
                    let center=points.reduce(SIMD3<Double>.zero,+)/Double(points.count)
                    if let previous=previousCenter {
                        let delta=center-previous,down=Self.dot(delta,gravity),lateral=Self.length(delta-gravity*down)
                        guard down >= -0.015,lateral<=max(0.025,down*0.6) else {
                            evidence=finish(entryAt == nil ? .unknown:.outsideOpening,"The identified can moved laterally/upward rather than completing a contained gravity entry.");return evidence
                        }
                    }
                    previousCenter=center
                    if heights.min()!>uncertainty {seenAbove=true}
                    if heights.max()! < -uncertainty {
                        guard seenAbove,contained(points,frame:f),empty else {
                            evidence=finish(.outsideOpening,"The whole identified can was not observed entering inside the actual opening with independently clear fingers.");return evidence
                        }
                        if entryAt==nil {entryAt=f.capturedAtMilliseconds;evidence.entrySequence=f.sequence;evidence.minimumWholeCanBelowRimMeters = -heights.max()!}
                    } else if entryAt != nil {
                        evidence=finish(.outsideOpening,"The identified can reappeared above the observed rim after entry.");return evidence
                    }
                } else if entryAt==nil {
                    evidence.reason="Whole-can edges/depth are occluded; no complete crossing is inferred from its central texture."
                }
            } else if entryAt==nil {
                evidence=finish(.unknown,"Can identity rotated, disappeared or became ambiguous before a positively observed whole-can crossing.");return evidence
            }
            if let entryAt {
                guard empty,visibleMouthWithoutOutbound(f) else {
                    evidence=finish(.unknown,"The entire mouth and independently clear fingers did not remain positively observed without foreground/outbound material.");return evidence
                }
                postEntryFrames+=1;evidence.noBounceObservedMilliseconds=f.capturedAtMilliseconds-entryAt
                // Opaque interiors may hide the resting can AFTER complete
                // positive entry. Continue watching the actual rim/mouth and
                // fingers; this records entry/no-outbound, not visible rest.
                if evidence.noBounceObservedMilliseconds>=1000,postEntryFrames>=12,emptyCount>=3 {
                    evidence=finish(.supported,"The whole same textured can crossed below the observed rim inside its eroded opening; actual fingers stayed clear and the visible stationary mouth showed no outbound can for at least one second. Resting pose is not observed.")
                    nativeSupport=NativePlacementSupport(evidence,scope:baseline.scope)
                }
            } else if f.capturedAtMilliseconds-releaseAt>=1500 {
                evidence=finish(.stillHeld,"No independently observed complete entry followed release; preserve possible payload and do not credit a transfer.")
            }
            return evidence
        }
        mutating func finish()->Evidence {
            if evidence.verdict == .collecting {evidence.verdict = .unknown;evidence.reason="The bounded raw observation ended without complete supported entry/clear-finger/no-outbound evidence."}
            return evidence
        }
    }
}
