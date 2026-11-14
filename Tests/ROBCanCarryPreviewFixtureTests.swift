import Foundation
import simd

@main enum CanCarryFixtures {
    static func blocked(_ label:String,_ operation:()throws->Void) {
        do {try operation();preconditionFailure("Unsafe carry proposal admitted: \(label)")}catch{}
    }
    static func main()throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),now=10_000.0
        let payload=ROBWorkspaceCarriedObject(measurementID:"isolated independently observed can",
            centerInToolMeters:[0.015,0,0.01],halfExtentsMeters:[0.063,0.036,0.036])
        for side in ["right","left"] {
            let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:side)
            let start=model.positions(vendorLeft:model.recyclingFrontTarget),front=model.toolPosition(start)!
            let sign=side=="left" ? 1.0:-1.0
            var chosen:(ROBWorkspaceLocatedObject,[String:Double],ROBWorkspaceLocatedObject,ROBCanCarryPreview)?
            for target in [SIMD3(0.45,sign*0.18,0.82),front,front+SIMD3(-0.04,0,0),front+SIMD3(0,0,0.10)] where chosen==nil {
                var can=ROBWorkspaceLocatedObject(target:.can,position:[target.x,target.y,target.z],confidence:0.95,
                    capturedAt:now,sequence:10,view:.init(panDegrees:0,upperTarget:6306),registrationID:"isolated measured camera")
                can.sections = .init(top:[target.x,target.y,target.z+0.06],middle:[target.x,target.y,target.z],
                    bottom:[target.x,target.y,target.z-0.06],heightMeters:0.12,diameterMeters:0.066)
                guard let grab=try?ROBCanGrabPreview.make(can:can,model:model,baseline:start,side:side,now:now),grab.reachesCan,
                      let held=grab.steps.last?.pose else {continue}
                let frame=model.frames(held)[model.toolLink]!,c=frame*SIMD4<Double>(0.015,0,0.01,1)
                for offset in [0.04,0.0,-0.04] where chosen==nil {
                    let bucket=ROBWorkspaceLocatedObject(target:.orangeBucket,position:[c.x,c.y+sign*offset,c.z-0.2],confidence:0.95,
                        capturedAt:now,sequence:11,view:can.view,openingRadius:0.14,registrationID:"isolated measured camera")
                    if let plan=try?ROBCanCarryPreview.make(from:held,can:can,attachedPayload:payload,destination:bucket,
                        model:model,side:side,now:now,dropUncertaintyMeters:0.035) {chosen=(can,held,bucket,plan)}
                }
            }
            guard let (can,held,bucket,plan)=chosen else {preconditionFailure("No actual \(side) held-can fixture was reachable")}
            func make(_ destination:ROBWorkspaceLocatedObject?=nil,_ object:ROBWorkspaceLocatedObject?=nil,
                      _ box:ROBWorkspaceCarriedObject?=nil,_ baseline:[String:Double]?=nil,_ arm:String?=nil,
                      _ time:Double?=nil,_ uncertainty:Double=0.035)throws->ROBCanCarryPreview {
                try .make(from:baseline ?? held,can:object ?? can,attachedPayload:box ?? payload,destination:destination ?? bucket,
                          model:model,side:arm ?? side,now:time ?? now,dropUncertaintyMeters:uncertainty)
            }
            precondition(plan.baseline==held && plan.steps.first!.pose==held)
            precondition(plan.releaseIndex>0 && plan.releaseIndex<plan.steps.count-1)
            precondition(plan.steps.filter{$0.jawAction == .release}.count==1 && plan.steps[plan.releaseIndex].jawAction == .release)
            precondition(plan.steps.allSatisfy{$0.jawAction==nil || $0.jawAction == .release})
            precondition(plan.steps.allSatisfy{!$0.stage.contains("Corkscrew") && !$0.stage.contains("approach")})
            let other=side=="right" ? "left":"right",center=SIMD4<Double>(0.015,0,0.01,1)
            func payloadCenter(_ pose:[String:Double])->SIMD3<Double> {
                let p=model.frames(pose)[model.toolLink]!*center;return SIMD3(p.x,p.y,p.z)
            }
            var previous=payloadCenter(held)
            for step in plan.steps {
                let f=model.frames(step.pose)[model.toolLink]!,p=payloadCenter(step.pose)
                let tilt=asin(min(1,max(abs(f.columns.1.z),abs(f.columns.2.z))))*180/Double.pi
                precondition(tilt<=5+1e-8 && simd_distance(p,previous)<=0.030+1e-8)
                for i in 1...7 {precondition(step.pose[other+"_joint\(i)"]==held[other+"_joint\(i)"])}
                for (key,value) in held where !key.hasPrefix(side+"_joint") {precondition(step.pose[key]==value)}
                precondition(zip(model.vendorLeft(step.pose),ROBWorkspaceCollisionPlan.jointBounds(model:model)).allSatisfy{$1.contains($0)})
                previous=p
            }
            let releaseFrame=model.frames(plan.steps[plan.releaseIndex].pose)[model.toolLink]!
            let releaseCenter=payloadCenter(plan.steps[plan.releaseIndex].pose),e=plan.dropContainmentEvidence
            var footprint=0.0,bottom=Double.infinity
            for x in [-1.0,1] {for y in [-1.0,1] {for z in [-1.0,1] {
                let p=releaseFrame*SIMD4(0.015+x*0.063,y*0.036,0.01+z*0.036,1)
                footprint=max(footprint,hypot(p.x-releaseCenter.x,p.y-releaseCenter.y));bottom=min(bottom,p.z)
                precondition(hypot(p.x-bucket.point.x,p.y-bucket.point.y)+0.035+0.010<=bucket.openingRadius!+1e-9)
            }}}
            precondition(abs(footprint-e.payloadProjectedRadiusMeters)<1e-9 && e.payloadMeasurementID==payload.measurementID)
            precondition(e.remainingOpeningMarginMeters>=0 && e.releaseTargetErrorMeters<=0.012 && e.toolTiltDegrees<=5)
            precondition(bottom-bucket.point.z>=0.035+0.020-1e-9)
            let retreat=payloadCenter(plan.steps.last!.pose)
            precondition(abs(retreat.z-releaseCenter.z-0.08)<=0.012+1e-9 && hypot(retreat.x-releaseCenter.x,retreat.y-releaseCenter.y)<=0.012+1e-9)
            blocked("stale can/bucket"){_=try make(nil,nil,nil,nil,nil,now+60_001)}
            var bad=bucket;bad.openingRadius=0.06;blocked("opening smaller than projected payload+uncertainty"){_=try make(bad)}
            bad = .init(target:.orangeBucket,position:[5,5,0.3],confidence:0.95,capturedAt:now,sequence:12,view:can.view,openingRadius:0.14);blocked("unreachable bucket"){_=try make(bad)}
            bad = .init(target:.orangeBucket,position:[.nan,0,0],confidence:0.95,capturedAt:now,sequence:12,view:can.view,openingRadius:0.14);blocked("nonfinite destination"){_=try make(bad)}
            var missing=can;missing.sections=nil;blocked("missing can geometry"){_=try make(nil,missing)}
            let small=ROBWorkspaceCarriedObject(measurementID:"too small",centerInToolMeters:[0,0,0],halfExtentsMeters:[0.01,0.01,0.01])
            blocked("undersized payload"){_=try make(nil,nil,small)}
            blocked("wrong physical side"){_=try make(nil,nil,nil,nil,other)}
            var invalid=held;invalid[side+"_joint1"] = .nan;blocked("nonfinite held pose"){_=try make(nil,nil,nil,invalid)}
            invalid=held;invalid.removeValue(forKey:side+"_joint2");blocked("incomplete held pose"){_=try make(nil,nil,nil,invalid)}
            blocked("unbounded uncertainty"){_=try make(nil,nil,nil,nil,nil,nil,.nan)}
            // A declared common opening is used without spending its radius
            // through handward placement offsets or calibration corrections.
            var common=bucket;common.registrationID=nil
            common.bucketShapePrior = .init(kind:"local_visual_trial_RGB_opening_floor_shape_prior",
                source:"fresh_orange_upper_contour_surrounding_depth_floor_and_declared_tapered_bucket_family",
                assumedHeightToOpeningDiameterRange:[0.8,1.2],assumedBottomToOpeningRadiusRange:[0.6,1.0],
                contourRMSEPixels:1,contourPointCount:40,floorRMSEMeters:0.005,floorPointCount:100,floorSupportFraction:0.8,
                commonOpeningRadiusMeters:0.14,shapeInsetMeters:0.01,maximumVariantCenterXYSpreadMeters:0.01,
                maximumRimHeightMeters:bucket.point.z,maximumBottomProjectionErrorPixels:1)
            let commonPlan=try make(common)
            precondition(commonPlan.dropContainmentEvidence.usedCommonOpeningPrior)
            precondition(commonPlan.dropContainmentEvidence.payloadCenterOffsetMeters<=0.012)
            common.openingRadius=0.15;blocked("changed common opening radius"){_=try make(common)}
            print("PASS \(side) pure held-can carry: actual attached-box containment,30mm spacing,1release/80mmretreat, unchanged opposite arm; no pickup/open/grip or motion authority")
        }
    }
}
