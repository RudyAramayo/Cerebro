import Foundation
import simd

/// Pure actual-CAD projection checks. No camera, UI, grants or actuators.
@main enum HumanProximityFixtures {
    static var checks=0
    static func expect(_ condition:Bool,_ message:String) {checks+=1;precondition(condition,message)}
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
        let start=Array(repeating:0.0,count:7),goal=[0.0,-0.075,0,0,0,0,0]
        // Deliberately synthetic camera, three meters in front of the actual
        // CAD arm. This is test geometry, never a measured robot transform.
        let camera=simd_double4x4(columns:(SIMD4(0,1,0,0),SIMD4(0,0,-1,0),SIMD4(-1,0,0,0),SIMD4(3,0,0.7,1)))
        let far=[[0.02,0.02,0.06,0.06]]
        func assess(_ regions:[[Double]]=far,success:Bool=true,baseline:[Double]?=nil,route:[[Double]]?=nil,
            matrix:simd_double4x4?=nil,fx:Double=200,cx:Double=319.5,modelError:Double=0.05,humanBuffer:Double=0.10)->ROBWorkspaceHumanProximity.Assessment {
            ROBWorkspaceHumanProximity.assess(model:model,baseline:baseline ?? start,route:route ?? [goal],cameraToRobot:matrix ?? camera,
                width:640,height:480,fx:fx,fy:200,cx:cx,cy:239.5,humanRegions:regions,localizationSucceeded:success,
                spatialErrorMeters:modelError,humanBufferMeters:humanBuffer)
        }
        let clear=assess()
        expect(clear.clear && clear.fullCorridorVisible,"A visible human separated from the complete padded arm route was vetoed: "+clear.reason)
        expect(clear.checkedPoseCount>2 && clear.projectedLinkCount>=8*clear.checkedPoseCount,"Full-arm sampled route was replaced by tool/endpoints")
        expect(clear.modelAllowanceMeters==0.05 && clear.humanBufferMeters==0.10 && clear.sweptSampleAllowanceMeters==0.005 && clear.openJawAdditionalMarginMeters==0.04,"Physical uncertainty was omitted")
        expect(clear.corridorBoundsNormalized?.count==4,"Missing bounded route diagnostic")
        let noHuman=assess([])
        expect(noHuman.clear && !noHuman.fullCorridorVisible && noHuman.checkedPoseCount==0,"No-detection changed legacy behavior or claimed unseen-space visibility")
        expect(!assess([],success:false).clear,"Failed detector became a clear no-detection frame")
        expect(!assess(success:false).clear,"Unlocalized human was ignored")
        expect(!assess([[0,0,1,1]]).clear,"Overlapping observed human was ignored")
        for bad in [[[Double.nan,0,1,1]],[[0.4,0.4,0.2,0.5]],[[0,0,1.1,1]],[[0,0,0,1]],[[0,0,1]]] {
            expect(!assess(bad).clear,"Malformed human box was accepted")
        }
        let offscreen=assess(fx:4000)
        expect(!offscreen.clear && !offscreen.fullCorridorVisible && !offscreen.rejectedLinks.isEmpty && offscreen.rejectedBoundsNormalized?.count==4,"Offscreen arm was treated as human-clear")
        expect(!assess(cx:0).clear,"Partly cropped envelope was accepted")
        var behind=camera;behind.columns.3.x = -3
        expect(!assess(matrix:behind).clear,"Behind-camera geometry was omitted")
        var malformed=camera;malformed.columns.0.x = .nan
        expect(!assess(matrix:malformed).clear,"Nonfinite projection was accepted")
        malformed=camera;malformed.columns.0 *= 2
        expect(!assess(matrix:malformed).clear,"Nonrigid camera transform was accepted")
        expect(!assess(fx:0).clear,"Invalid intrinsics were accepted")
        expect(!assess(modelError:0.049).clear && !assess(humanBuffer:0.099).clear,"Uncertainty buffers could be silently reduced")
        expect(!assess(route:[]).clear && !assess(route:Array(repeating:goal,count:81)).clear,"Missing/unbounded full route was accepted")
        var invalid=start;invalid[0] = .nan
        expect(!assess(baseline:invalid).clear,"Nonfinite encoder baseline was accepted")
        invalid=start;invalid[0]=10
        expect(!assess(route:[invalid]).clear,"Out-of-limit route was accepted")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        expect(try JSONDecoder().decode(ROBWorkspaceHumanProximity.Assessment.self,from:encoder.encode(clear))==clear,"Assessment audit failed roundtrip")

        // A shoulder/motor can intersect a person while the tool stays clear.
        let inverse=simd_inverse(camera)
        func point(_ world:SIMD3<Double>)->[Double] {
            let p=inverse*SIMD4(world,1)
            return [(200*p.x/p.z+319.5)/639,(200*p.y/p.z+239.5)/479]
        }
        let bounds=model.worldCollisionBounds(positions:model.positions(vendorLeft:start)),tool=bounds[model.toolLink]!
        let padding=0.05+0.10+0.005+0.04
        var toolRect=[Double.infinity,Double.infinity,-Double.infinity,-Double.infinity]
        for x in [tool.low.x-padding,tool.high.x+padding] {for y in [tool.low.y-padding,tool.high.y+padding] {for z in [tool.low.z-padding,tool.high.z+padding] {
            let p=point(SIMD3(x,y,z));toolRect=[min(toolRect[0],p[0]),min(toolRect[1],p[1]),max(toolRect[2],p[0]),max(toolRect[3],p[1])]
        }}}
        var foundUpperArm=false
        for (link,box) in bounds where link.hasPrefix("right_") && link != model.toolLink && link.hasSuffix("_Link") {
            let p=point((box.low+box.high)/2),r=[p[0]-0.002,p[1]-0.002,p[0]+0.002,p[1]+0.002]
            if r[2]<toolRect[0] || r[0]>toolRect[2] || r[3]<toolRect[1] || r[1]>toolRect[3] {
                expect(!assess([r],route:[start]).clear,"A hand at the actual upper-arm/motor envelope was ignored because the tool was clear")
                foundUpperArm=true;break
            }
        }
        expect(foundUpperArm,"Actual CAD fixture did not distinguish an upper arm from its gripper")

        // Return to the same final pose: the intervening path still matters.
        var foundInterior=false
        for angle in [0.6,1.0,1.4,1.8,2.1] {
            var middle=start;middle[0]=angle
            guard let toolPoint=model.toolPosition(model.positions(vendorLeft:middle)) else{continue}
            let p=point(toolPoint),r=[p[0]-0.002,p[1]-0.002,p[0]+0.002,p[1]+0.002]
            guard r.allSatisfy({$0>0 && $0<1}),assess([r],route:[start]).clear else{continue}
            expect(!assess([r],route:[middle,start]).clear,"Only the final endpoint was checked for human proximity")
            foundInterior=true;break
        }
        expect(foundInterior,"Actual CAD fixture did not produce a distinct intervening swept region")
        print("PASS \(checks) actual-CAD human-proximity checks: whole arm/open jaw, sampled complete route, separated human allowed, overlapping/unknown/cropped/behind held, explicit buffers, bounded audit; no authority or actuators")
    }
}
