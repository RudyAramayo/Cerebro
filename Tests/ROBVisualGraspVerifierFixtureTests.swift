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
        print("Visual grasp fixtures passed: coherent lift, static/independent can, RGB-D/tool timing, identity, camera/background/exposure, occlusion, ambiguity, bounded hold")
    }
}
