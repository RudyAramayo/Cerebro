import Foundation

private func expect(_ condition:@autoclosure () -> Bool,_ message:String) {
    if !condition() { fatalError(message) }
}

private struct Scene {
    let width=160,height=120
    let camera=UUID()
    let box=ROBVisualGraspVerifier.Box(left:0.4,top:0.4,right:0.6,bottom:0.7)
    let background:[UInt8]
    let can:[UInt8]
    init() {
        var seed:UInt64=18397
        func noise(_ count:Int) -> [UInt8] {
            (0..<count).map { _ in
                seed=seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(40+Int((seed>>32)%160))
            }
        }
        background=noise(width*height);can=noise(32*36)
    }
    func sample(sequence:UInt64=1,time:Double=10_000,canDX:Int=0,canDY:Int=0,
        toolDX:Int=0,toolDY:Int=0,canDepthDelta:Double=0,toolDepthDelta:Double=0,
        camera:UUID?=nil,view:String="P6000-L6011-U6500|registration-test",identity:String="can-A",
        brightness:Int=0,sceneShift:Int=0,occluded:Bool=false,duplicate:Bool=false,
        missingDepth:Bool=false,feedbackSkew:Double=0,handsClear:Bool=true,synchronized:Bool=true) -> ROBVisualGraspVerifier.Sample {
        var gray=background,depth=[Float](repeating:1.5,count:width*height)
        func paste(_ dx:Int,_ dy:Int) {
            for y in 0..<36 { for x in 0..<32 {
                let i=(48+dy+y)*width+64+dx+x
                gray[i]=occluded ? 90 : can[y*32+x]
                depth[i]=missingDepth ? 0 : Float(0.75+canDepthDelta)
            } }
        }
        paste(canDX,canDY)
        if duplicate { paste(canDX+32,canDY) }
        gray=gray.map { UInt8(max(0,min(255,Int($0)+brightness))) }
        if sceneShift != 0 {
            let before=gray
            for y in 0..<height { for x in 0..<width {
                let source=max(0,min(width-1,x-sceneShift));gray[y*width+x]=before[y*width+source]
            } }
        }
        return .init(sequence:sequence,capturedAtMilliseconds:time,synchronizedRGBDepth:synchronized,
            cameraGeneration:camera ?? self.camera,fixedViewIdentity:view,targetIdentity:identity,width:width,height:height,
            gray:gray,depthMeters:depth,
            measuredToolCenter:.init(x:0.5+Double(toolDX)/Double(width),y:0.6+Double(toolDY)/Double(height)),
            measuredToolDepthMeters:0.7+toolDepthDelta,toolFeedbackCapturedAtMilliseconds:time+feedbackSkew,handsClear:handsClear)
    }
    func verifier() throws -> ROBVisualGraspVerifier {
        try .init(baseline:sample(),targetBox:box,nowMilliseconds:10_000)
    }
}

@main enum Fixtures {
    static func main() throws {
        let scene=Scene()
        var verifier=try scene.verifier()
        var last=verifier.evidence
        for index in 1...3 {
            let time=10_000+Double(index)*200
            last=verifier.observe(scene.sample(sequence:UInt64(index+1),time:time,canDX:12,canDY:-8,
                toolDX:12,toolDY:-8,canDepthDelta:-0.025,toolDepthDelta:-0.025),nowMilliseconds:time)
            expect(last.verdict == (index==3 ? .supported : .collecting),"Coherent can/tool lift must require3 distinct samples")
        }
        expect(last.possessionMeasured==false,"Visual agreement cannot invent a payload sensor")
        expect((last.correlation ?? 0)>0.99,"Successful fixture must actually track the original texture")
        expect((last.targetToolMotionErrorPixels ?? 100)<0.01,"Tracked displacement must agree with measured tool projection")

        // Brightness changes alone cannot turn a can left on the table into a
        // supported grasp, even when the tool actually moves.
        verifier=try scene.verifier()
        for index in 1...3 {
            let time=10_000+Double(index)*200
            last=verifier.observe(scene.sample(sequence:UInt64(index+1),time:time,toolDX:12,toolDY:-8,
                toolDepthDelta:-0.025,brightness:12),nowMilliseconds:time)
        }
        expect(last.verdict == .failed,"Visible stationary can must fail possession after tool lift")

        verifier=try scene.verifier()
        for index in 1...3 {
            let time=10_000+Double(index)*200
            last=verifier.observe(scene.sample(sequence:UInt64(index+1),time:time,canDX:10,canDY:7,
                toolDX:12,toolDY:-8,canDepthDelta:0.03,toolDepthDelta:-0.025),nowMilliseconds:time)
        }
        expect(last.verdict == .failed,"Independently moving can cannot support a grasp")

        let unknowns:[(String,ROBVisualGraspVerifier.Sample,Double)]=[
            ("jaw occlusion",scene.sample(sequence:2,time:10_200,toolDX:12,toolDY:-8,occluded:true),10_200),
            ("camera pan",scene.sample(sequence:2,time:10_200,toolDX:12,toolDY:-8,sceneShift:3),10_200),
            ("exposure jump",scene.sample(sequence:2,time:10_200,toolDX:12,toolDY:-8,brightness:50),10_200),
            ("stream generation",scene.sample(sequence:2,time:10_200,camera:UUID()),10_200),
            ("neck or registration change",scene.sample(sequence:2,time:10_200,view:"different pose"),10_200),
            ("target swap",scene.sample(sequence:2,time:10_200,identity:"can-B"),10_200),
            ("missing stereo",scene.sample(sequence:2,time:10_200,missingDepth:true),10_200),
            ("RGB-D synchronization",scene.sample(sequence:2,time:10_200,synchronized:false),10_200),
            ("stale camera",scene.sample(sequence:2,time:10_200),11_001),
            ("old tool feedback",scene.sample(sequence:2,time:10_200,feedbackSkew:151),10_200),
            ("visible human hand",scene.sample(sequence:2,time:10_200,handsClear:false),10_200),
            ("camera replay",scene.sample(sequence:1,time:10_200),10_200),
            ("ambiguous second can",scene.sample(sequence:2,time:10_200,toolDX:37,duplicate:true),10_200)
        ]
        for (name,sample,now) in unknowns {
            verifier=try scene.verifier();last=verifier.observe(sample,nowMilliseconds:now)
            expect(last.verdict == .unknown,"\(name) must remain unknown, got \(last.verdict): \(last.reason)")
            let result=verifier.observe(scene.sample(sequence:3,time:10_400,canDX:12,canDY:-8,toolDX:12,toolDY:-8,
                canDepthDelta:-0.025,toolDepthDelta:-0.025),nowMilliseconds:10_400)
            expect(result.verdict == .unknown,"A lost identity cannot silently reacquire and authorize carrying")
        }

        verifier=try scene.verifier()
        _=verifier.observe(scene.sample(sequence:2,time:10_200),nowMilliseconds:10_200)
        expect(verifier.observe(scene.sample(sequence:3,time:11_701),nowMilliseconds:11_701).verdict == .unknown,"A gap after inspection begins must end observation")
        verifier=try scene.verifier()
        expect(verifier.observe(scene.sample(sequence:2,time:22_001),nowMilliseconds:22_001).verdict == .unknown,"The12second baseline/lift budget is absolute")
        let reference=scene.sample(time:1000,feedbackSkew:5000)
        let current=scene.sample(sequence:2,time:10_000)
        expect(ROBVisualGraspVerifier.confirmTargetContinuity(reference:reference,targetBox:scene.box,current:current,nowMilliseconds:10_000) != nil,"Old detector pixels may transfer appearance to fresh unchanged image, without refreshing their timestamp/tool data")
        expect(ROBVisualGraspVerifier.confirmTargetContinuity(reference:reference,targetBox:scene.box,current:scene.sample(sequence:2,time:10_000,canDX:7),nowMilliseconds:10_000)==nil,"A moved can cannot inherit the old detector ROI")
        verifier=try scene.verifier()
        last=verifier.observe(scene.sample(sequence:2,time:10_200,canDX:2,toolDX:2),nowMilliseconds:10_200)
        expect(last.verdict == .collecting,"Tiny motion is insufficient evidence")
        expect(verifier.finish().verdict == .unknown,"A completed observation without support must hold")
        // A tool-only projection match with incompatible stereo motion fails.
        verifier=try scene.verifier()
        for index in 1...3 {
            let time=10_000+Double(index)*200
            last=verifier.observe(scene.sample(sequence:UInt64(index+1),time:time,canDX:12,canDY:-8,
                toolDX:12,toolDY:-8,canDepthDelta:0.04,toolDepthDelta:-0.025),nowMilliseconds:time)
        }
        expect(last.verdict == .failed,"Matching2D pixels without agreeing depth cannot support possession")
        do {
            _=try ROBVisualGraspVerifier(baseline:scene.sample(feedbackSkew:200),targetBox:scene.box,nowMilliseconds:10_000)
            fatalError("Unsynchronized baseline must reject")
        } catch is ROBVisualGraspVerifier.Unavailable {}
        // Independent observed-finger adapter: the detector box never supplies
        // jaw motion/depth. Finger depth lives outside the entire can ROI.
        func observed(_ sample:ROBVisualGraspVerifier.Sample,dx:Int=0,dy:Int=0,toolDepth:Double=0.7,
                      missingFingerDepth:Bool=false,alias:Bool=false,source:String="actual-rgbd-source",
                      jawKind:String="image_observed_opening_after_release_command_then_temporal_edges",
                      fingersOcclude:Bool=false,oblique:Bool=false,wide:Bool=false)->ROBVisualGraspVerifier.ObservedJawInput {
            let width=wide ? 320:scene.width
            var depth=sample.depthMeters,gray=sample.gray
            if wide {
                depth=[];gray=[]
                for y in 0..<scene.height {
                    gray.append(contentsOf:sample.gray[(y*160)..<(y*160+160)])
                    gray.append(contentsOf:scene.background[(y*160)..<(y*160+160)])
                    depth.append(contentsOf:sample.depthMeters[(y*160)..<(y*160+160)])
                    depth.append(contentsOf:Array(repeating:Float(1.5),count:160))
                }
            }
            let tips=fingersOcclude ? [ROBVisualGraspVerifier.Point(x:80+Double(dx),y:70+Double(dy)),.init(x:120+Double(dx),y:70+Double(dy))] :
                [.init(x:40+Double(dx),y:70+Double(dy)),.init(x:120+Double(dx),y:70+Double(dy))]
            let spanX=tips[1].x-tips[0].x,spanY=tips[1].y-tips[0].y,span=hypot(spanX,spanY)
            for (index,tip) in tips.enumerated() {for y in -2...2 {for x in -2...2 {
                let sign=index==0 ? -1.0:1.0
                let px=Int((tip.x+sign*spanX/span*4).rounded())+x,py=Int((tip.y+sign*spanY/span*4).rounded())+y
                depth[py*width+px]=missingFingerDepth ? 0:Float(toolDepth+(oblique ? sign*0.03:0))
            }}}
            if alias {
                // A jaw/second-object copy of the SAME can-wall texture inside
                // the bounded search must destroy independent uniqueness.
                for y in 0..<25 {for x in 0..<19 {
                    gray[(53-8+y)*width+62+x]=scene.can[(5+y)*32+6+x]
                }}
            }
            return .init(sequence:sample.sequence,capturedAtMilliseconds:sample.capturedAtMilliseconds,
                cameraGeneration:sample.cameraGeneration,fixedViewIdentity:sample.fixedViewIdentity,targetIdentity:sample.targetIdentity,
                sourceIdentity:source,width:width,height:scene.height,gray:gray,depthMeters:depth,fx:500,fy:500,cx:80,cy:60,
                synchronizedRGBDepth:sample.synchronizedRGBDepth,handsClear:sample.handsClear,
                jawCenterPixels:.init(x:80+Double(dx),y:72+Double(dy)),fingerTipsPixels:tips,
                jawSequence:sample.sequence,jawCapturedAtMilliseconds:sample.capturedAtMilliseconds,jawScopeIdentity:sample.fixedViewIdentity,
                jawConfidence:0.9,jawEvidenceKind:jawKind,
                canBox:.init(left:(scene.box.left*160+Double(dx))/Double(width),top:scene.box.top+Double(dy)/120,
                             right:(scene.box.right*160+Double(dx))/Double(width),bottom:scene.box.bottom+Double(dy)/120))
        }
        func seed(_ value:ROBVisualGraspVerifier.ObservedJawInput)->ROBVisualGraspVerifier.AppearanceSeed {
            .init(sequence:1,capturedAtMilliseconds:9900,cameraGeneration:value.cameraGeneration,
                fixedViewIdentity:value.fixedViewIdentity,targetIdentity:value.targetIdentity,sourceIdentity:value.sourceIdentity,
                width:value.width,height:value.height,gray:value.gray,canBox:value.canBox,synchronizedRGBDepth:value.synchronizedRGBDepth,handsClear:value.handsClear)
        }
        let observedBase=observed(scene.sample(sequence:2))
        do {
            _=try ROBVisualGraspVerifier.ObservedJawVerifier(baseline:observed(scene.sample(sequence:2,occluded:true)),
                appearance:seed(observedBase),nowMilliseconds:10_000)
            fatalError("Jaws covering the pre-close can cannot become a new can-appearance template")
        } catch is ROBVisualGraspVerifier.Unavailable {}
        var jawVerifier=try ROBVisualGraspVerifier.ObservedJawVerifier(baseline:observedBase,appearance:seed(observedBase),nowMilliseconds:10_000)
        for index in 1...3 {
            let time=10_000+Double(index)*200
            let frame=scene.sample(sequence:UInt64(index+2),time:time,canDX:12,canDY:-8,canDepthDelta:-0.025)
            last=try jawVerifier.observe(observed(frame,dx:12,dy:-8,toolDepth:0.675),nowMilliseconds:time)
            expect(last.verdict == (index==3 ? .supported:.collecting),"Independent appearance/fingers need3 advancing captures")
        }
        expect(last.toolEvidenceSource=="independent_observed_fingers" && !last.possessionMeasured,"Observed adapter evidence source must be explicit")
        jawVerifier=try .init(baseline:observedBase,appearance:seed(observedBase),nowMilliseconds:10_000)
        for index in 1...3 {
            let time=10_000+Double(index)*200
            last=try jawVerifier.observe(observed(scene.sample(sequence:UInt64(index+2),time:time),dx:12,dy:-8,toolDepth:0.675),nowMilliseconds:time)
        }
        expect(last.verdict == .failed,"Observed fingers moving while original can stays must fail")
        for wide in [false,true] {
            let base=observed(scene.sample(sequence:2),oblique:true,wide:wide)
            jawVerifier=try .init(baseline:base,appearance:seed(base),nowMilliseconds:10_000)
            let motion=wide ? 60:12
            for index in 1...3 {
                let time=10_000+Double(index)*200
                let frame=scene.sample(sequence:UInt64(index+2),time:time,canDX:motion,canDepthDelta:-0.025)
                last=try jawVerifier.observe(observed(frame,dx:motion,toolDepth:0.675,oblique:true,wide:wide),nowMilliseconds:time)
            }
            expect(last.verdict == .supported,"Oblique fingers and60px observed lift must retain independent positive support")
        }
        for mode in ["occlusion","alias","bad_depth","missing_depth","bad_kind","finger_overlap","source_changed","unsynchronized"] {
            jawVerifier=try .init(baseline:observedBase,appearance:seed(observedBase),nowMilliseconds:10_000)
            var rejected=false
            for index in 1...3 {
                let time=10_000+Double(index)*200
                let frame=scene.sample(sequence:UInt64(index+2),time:time,canDX:12,canDY:-8,canDepthDelta:-0.025,
                    occluded:mode=="occlusion",synchronized:mode != "unsynchronized")
                do {
                    last=try jawVerifier.observe(observed(frame,dx:12,dy:-8,toolDepth:mode=="bad_depth" ? 0.78:0.675,
                        missingFingerDepth:mode=="missing_depth",alias:mode=="alias",source:mode=="source_changed" ? "changed":"actual-rgbd-source",
                        jawKind:mode=="bad_kind" ? "FK_projected":"image_observed_opening_after_release_command_then_temporal_edges",
                        fingersOcclude:mode=="finger_overlap"),nowMilliseconds:time)
                    if last.verdict != .collecting {break}
                } catch {rejected=true;break}
            }
            expect(rejected || last.verdict != .supported,"Untrustworthy observed-jaw evidence supported: \(mode)")
        }
        print("Visual grasp fixtures passed: coherent lift, static/independent can, RGB-D/tool timing, identity, camera/background/exposure, occlusion, ambiguity, bounded hold; independent observed fingers, outside-can depth, oblique and60px lift, occlusion/alias/missing-depth rejection")
    }
}
