import Foundation

private typealias Drop=ROBVisualDropVerifier
private typealias Box=ROBVisualGraspVerifier.Box
private var checks=0
private func expect(_ value:@autoclosure()->Bool,_ message:String) {
    checks+=1
    if !value() {FileHandle.standardError.write(Data(("FAIL: "+message+"\n").utf8));fatalError(message)}
}
private struct DropScene {
    let width=160,height=120
    let scope=Drop.Scope(phaseID:UUID(),attachmentID:UUID(),cameraGeneration:UUID(),bodyMotionIdentity:UUID().uuidString,
        sourceIdentity:"actual-source-fixture",runtimeCalibrationIdentity:"actual-runtime-fixture",estimatedCameraProjectionIdentity:"current-estimated-projection",
        fixedViewIdentity:"current-drop-view",targetIdentity:"held-can-A")
    let canBox=Box(left:72.0/160,top:52.0/120,right:88.0/160,bottom:76.0/120)
    let bucket=Box(left:25.0/160,top:15.0/120,right:135.0/160,bottom:118.0/120)
    let fingers=[Box(left:58.0/160,top:40.0/120,right:66.0/160,bottom:82.0/120),Box(left:94.0/160,top:40.0/120,right:102.0/160,bottom:82.0/120)]
    let texture:[UInt8],background:[UInt8]
    init() {
        var seed:UInt64=813876
        func noise(_ n:Int)->[UInt8] {(0..<n).map{_ in seed=seed &* 6364136223846793005 &+ 1;return UInt8(40+(seed>>32)%180)}}
        texture=noise(16*24);background=noise(160*120)
    }
    func frame(_ n:Int,z:Double?=nil,visible:Bool=true,rotated:Bool=false,canDX:Int=0,
        openRim:Bool=true,rimDepth:Bool=true,clearFingerEvidence:Bool=true,partial:Bool=false,
        scopeOverride:Drop.Scope?=nil,timeOverride:Double?=nil,outbound:Bool=false)->Drop.Frame {
        var rgb=[UInt8](repeating:0,count:width*height*3),depth=[Float](repeating:1.7,count:width*height)
        func pixel(_ x:Int,_ y:Int,_ r:UInt8,_ g:UInt8,_ b:UInt8,_ z:Double) {
            let i=y*width+x;rgb[i*3]=r;rgb[i*3+1]=g;rgb[i*3+2]=b;depth[i]=Float(z)
        }
        for y in 0..<height {for x in 0..<width {
            let d=hypot(Double(x-80),Double(y-70)),v=background[y*width+x]
            pixel(x,y,v,v,v,1.7)
            if openRim,d>=40,d<=44 {pixel(x,y,230,110,20,rimDepth ? 1.2:0)}
        }}
        func paste(_ left:Int,_ top:Int,_ z:Double,_ rotate:Bool=false) {
            for y in 0..<24 {for x in 0..<16 {
                let index=rotate ? ((23-y)*16+15-x):(y*16+x),v=texture[index]
                pixel(left+x,top+y,v,v,v,z)
            }}
        }
        // Two already-present cans carry the SAME appearance. Their stable
        // actual baseline depth must not become a new release-entry event.
        paste(45,57,1.65);paste(105,57,1.65)
        for r in fingers {
            let x0=Int((r.left*160).rounded()),x1=Int((r.right*160).rounded()),y0=Int((r.top*120).rounded()),y1=Int((r.bottom*120).rounded())
            for y in y0..<y1 {for x in x0..<x1 {let v=background[y*width+x];pixel(x,y,v,v,v,0.9)}}
        }
        if visible {paste(72+canDX,52,z ?? 0.9,rotated)}
        if partial {for x in 72+canDX..<88+canDX {depth[52*width+x]=0}}
        if outbound {for y in 30..<38 {for x in 78..<88 {pixel(x,y,180,180,180,1.05)}}}
        let seq=UInt64(n+1),time=timeOverride ?? (10_000+Double(n)*33.333333333)
        return .init(scope:scopeOverride ?? scope,sequence:seq,capturedAtMilliseconds:time,width:width,height:height,rgb:rgb,
            depthMeters:depth,fx:150,fy:150,cx:80,cy:60,synchronizedRGBDepth:true,fingerRegions:fingers,
            fingerSequence:clearFingerEvidence ? seq:seq-1,fingerConfidence:0.9,
            fingerEvidenceKind:"image_observed_opening_after_release_command_then_temporal_edges")
    }
    func verifier(openRim:Bool=true,rimDepth:Bool=true)throws->Drop {
        try .init(baseline:frame(0,openRim:openRim,rimDepth:rimDepth),canBox:canBox,bucketROI:bucket,
            canDiameterMeters:0.066,canHeightMeters:0.123,gravityOptical:SIMD3(0,0,1),uncertaintyMeters:0.005,
            releaseAcceptedAtMilliseconds:10_000,nowMilliseconds:10_000)
    }
}
@main private enum DropFixtures {
    static func main()throws {
        let s=DropScene()
        var v=try s.verifier()
        var last=v.evidence
        for n in 1...44 {
            let f=s.frame(n,z:0.9+Double(n)*0.04,visible:n<=12)
            last=v.observe(f,nowMilliseconds:f.capturedAtMilliseconds)
            if last.verdict != .collecting {break}
        }
        expect(last.verdict == .supported,"Actual complete contained crossing, clear fingers and visible-mouth window did not support entry: \(last.reason)")
        expect(last.entrySequence != nil && (last.minimumWholeCanBelowRimMeters ?? 0)>0.005,"No raw whole-can crossing evidence")
        expect(last.noBounceObservedMilliseconds>=1000 && last.clearFingerSamples>=3,"No bounded no-outbound/clear-finger window")
        expect(last.observedRimPointCount>=30 && last.observedRimRMSEMeters<0.001,"Opening was not derived from actual measured rim depth")
        expect(last.observedRestingCan==false,"Opaque bucket must not invent a visible resting pose")
        let positive=v.nativeSupport!
        expect(positive.claimForNativeCompletion(currentScope:s.scope,nowMilliseconds:last.lastCapturedAtMilliseconds),"Native entry support could not be claimed")
        expect(!positive.claimForNativeCompletion(currentScope:s.scope,nowMilliseconds:last.lastCapturedAtMilliseconds),"Native entry support was replayable")
        let encoded=try JSONEncoder().encode(last)
        expect(!encoded.isEmpty,"Actual evidence was not auditable")
        var expired=try s.verifier()
        for n in 1...44 {
            let f=s.frame(n,z:0.9+Double(n)*0.04,visible:n<=12)
            _=expired.observe(f,nowMilliseconds:f.capturedAtMilliseconds)
        }
        let stale=expired.nativeSupport!
        expect(!stale.claimForNativeCompletion(currentScope:s.scope,nowMilliseconds:expired.evidence.lastCapturedAtMilliseconds+801),"Expired native placement support was accepted")
        expect(!stale.claimForNativeCompletion(currentScope:s.scope,nowMilliseconds:expired.evidence.lastCapturedAtMilliseconds),"Failed native completion claim could be retried/replayed")

        for mode in ["stationary held","partly above","rotated","occluded","missing top","unobserved fingers","outside","outbound"] {
            v=try s.verifier()
            for n in 1...50 {
                var z=0.9+Double(n)*0.04
                if mode=="stationary held" {z=0.9}
                if mode=="partly above" {z=min(1.18,z)}
                let f=s.frame(n,z:z,visible:mode=="occluded" ? n<4:(n<=12 || mode=="stationary held" || mode=="partly above"),
                    rotated:mode=="rotated" && n>=4,canDX:mode=="outside" && n>=4 ? 22:0,
                    clearFingerEvidence:mode != "unobserved fingers",partial:mode=="missing top",
                    outbound:mode=="outbound" && n>=13)
                last=v.observe(f,nowMilliseconds:f.capturedAtMilliseconds)
                if last.verdict != .collecting {break}
            }
            if last.verdict == .collecting {last=v.finish()}
            expect(last.verdict != .supported && v.nativeSupport==nil,"Unsupported scene minted placement: \(mode)")
            if mode=="stationary held" || mode=="partly above" {expect(last.entrySequence==nil,"An existing interior can or partial crossing became a new whole-can entry")}
        }
        for (rim,depth) in [(false,true),(true,false)] {
            do {_ = try s.verifier(openRim:rim,rimDepth:depth);preconditionFailure("A prior or missing actual rim depth became an observed opening")}
            catch {expect(true,"No actual opening")}
        }
        // The camera looks down at this actual measured rim. Its physical
        // DOWN is optical +Z; transformed stationary acceleration is UP/-Z.
        // A misleading gravity_mps2 field name must not reverse this sign and
        // allow the raw downward-entry frames above to credit an upward fall.
        do {
            _ = try Drop(baseline:s.frame(0),canBox:s.canBox,bucketROI:s.bucket,
                canDiameterMeters:0.066,canHeightMeters:0.123,gravityOptical:SIMD3(0,0,-1),uncertaintyMeters:0.005,
                releaseAcceptedAtMilliseconds:10_000,nowMilliseconds:10_000)
            preconditionFailure("Stationary support/UP was accepted as physical DOWN")
        } catch {expect(true,"Wrong-sign gravity rejects before any raw entry can be credited")}
        v=try s.verifier()
        var changed=s.scope
        changed = .init(phaseID:changed.phaseID,attachmentID:changed.attachmentID,cameraGeneration:UUID(),bodyMotionIdentity:changed.bodyMotionIdentity,
            sourceIdentity:changed.sourceIdentity,runtimeCalibrationIdentity:changed.runtimeCalibrationIdentity,
            estimatedCameraProjectionIdentity:changed.estimatedCameraProjectionIdentity,fixedViewIdentity:changed.fixedViewIdentity,targetIdentity:changed.targetIdentity)
        let changedFrame=s.frame(1,scopeOverride:changed)
        expect(v.observe(changedFrame,nowMilliseconds:changedFrame.capturedAtMilliseconds).verdict == .unknown,"Source change was accepted")
        v=try s.verifier()
        let gap=s.frame(1,timeOverride:10_200)
        expect(v.observe(gap,nowMilliseconds:gap.capturedAtMilliseconds).verdict == .unknown,"Missing flight frames were accepted")
        v=try s.verifier()
        expect(v.finish().verdict == .unknown && v.nativeSupport==nil,"No frames minted delivery")

        let ring=Drop.RawRing(scope:s.scope)
        for n in 0..<110 {let f=s.frame(n,visible:false);expect(ring.append(f,nowMilliseconds:f.capturedAtMilliseconds),"Actual advancing raw frame was rejected")}
        let saved=ring.snapshot()
        expect(saved.count<=96 && saved.last!.capturedAtMilliseconds-saved.first!.capturedAtMilliseconds<=3000,"Raw ring is unbounded")
        expect(saved.last!.sequence==110 && saved.last!.capturedAtMilliseconds==s.frame(109).capturedAtMilliseconds,"Raw ring restamped evidence")
        expect(!ring.append(saved.last!,nowMilliseconds:saved.last!.capturedAtMilliseconds) && ring.snapshot().isEmpty && ring.invalidated,"Duplicate source was not failed closed")
        let staleRing=Drop.RawRing(scope:s.scope),old=s.frame(0)
        expect(!staleRing.append(old,nowMilliseconds:old.capturedAtMilliseconds+801) && staleRing.snapshot().isEmpty,"Raw ring admitted a stale capture")
        let changedRing=Drop.RawRing(scope:s.scope)
        expect(changedRing.append(old,nowMilliseconds:old.capturedAtMilliseconds),"Raw ring baseline failed")
        expect(!changedRing.append(changedFrame,nowMilliseconds:changedFrame.capturedAtMilliseconds) && changedRing.snapshot().isEmpty,"Raw ring admitted changed source/camera generation")
        print("PASS \(checks) raw RGB-D drop/rim/NCC/whole-entry/empty-finger/no-outbound/multiple-existing-can/ring fixtures; no hardware or authority")
    }
}
