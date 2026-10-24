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
    init(baseline: Sample, targetBox: Box, nowMilliseconds: Double) throws {
        guard Self.valid(baseline,now:nowMilliseconds), targetBox.valid,
              !baseline.targetIdentity.isEmpty, !baseline.fixedViewIdentity.isEmpty else {
            throw Unavailable.evidence("Fresh synchronized RGB-D, measured tool feedback and a fixed calibrated view are required.")
        }
        // Prefer the central can wall. Lateral jaws must not become the target
        // template merely because they surround the original detector box.
        let w=targetBox.right-targetBox.left, h=targetBox.bottom-targetBox.top
        let core=Box(left:targetBox.left+w*0.2,top:targetBox.top+h*0.15,
            right:targetBox.right-w*0.2,bottom:targetBox.bottom-h*0.15)
        guard let patch=Self.patch(baseline,box:core), patch.width>=6,patch.height>=8,
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
        self.baseline=baseline; target=patch; backgrounds=anchors; baselineTargetDepth=depth
        lastSequence=baseline.sequence;lastCapture=baseline.capturedAtMilliseconds
        evidence=Evidence(verdict:.collecting,reason:"Waiting for a bounded measured lift and fresh can observations.",samples:0,
            firstSequence:baseline.sequence,lastSequence:baseline.sequence,cameraGeneration:baseline.cameraGeneration,
            fixedViewIdentity:baseline.fixedViewIdentity,targetIdentity:baseline.targetIdentity,targetBox:targetBox,
            baselineCapturedAtMilliseconds:baseline.capturedAtMilliseconds,lastCapturedAtMilliseconds:baseline.capturedAtMilliseconds)
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
              sample.width==baseline.width,sample.height==baseline.height else {
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
        guard toolMotion<=42,abs(toolDepth)<=0.12,
              let tracked=Self.match(target,in:sample,centerX:target.x,centerY:target.y,radius:radius),
              tracked.correlation>=0.82,tracked.margin>=0.06,
              let currentDepth=Self.depth(sample,x:tracked.x,y:tracked.y,width:target.width,height:target.height) else {
            evidence=unknown("Can texture was occluded, ambiguous, outside the bounded view or lacked aligned depth.");return evidence
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
            evidence.reason="Three advancing RGB-D views show the same can moving coherently with the measured tool against a static background. Possession remains visual evidence, not measured force or jaw retention."
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
