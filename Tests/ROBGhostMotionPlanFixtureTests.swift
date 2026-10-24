import Foundation
import simd

private extension ROBLeftCanReachCalibration {
    func saveFixture(to file:URL) throws { try JSONEncoder().encode(self).write(to:file) }
}

@main struct GhostMotionFixtures {
    static func expectBlocked(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Unsafe or changed proposal was admitted") }
        catch { }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = try ROBGhostRobotModel(directory: root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"))
        precondition(model.modelID.count == 64 && model.joints.count == 44 && model.hulls.count >= 40)
        if CommandLine.arguments.last == "photo-origin-residual-scope" {
            let suite="ROBPhotoResidualScope."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("rob-photo-residual-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:folder);defaults.removePersistentDomain(forName:suite)}
            let alignment=ROBWorkspaceDepthAlignment.snapshot(defaults:defaults)!,pid=String(repeating:"a",count:64)
            for side in ["left","right"] {
                let testModel=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:side)
                let file=folder.appendingPathComponent(side+"-reach.json")
                var calibration=ROBLeftCanReachCalibration(modelID:testModel.modelID,referenceID:testModel.referenceID,
                    mappingID:testModel.selectedMappingID,translationMeters:[0.02,-0.01,-0.03],source:"Legacy camera-only tuning fixture",
                    bucketYawDegrees:18,bucketInwardMeters:0.035,recoveryGraspClearanceMeters:0.037,canOutwardMeters:0.01,
                    tabletopCanBaseHeightMeters:0.80)
                try calibration.saveFixture(to:file)
                let sections=ROBWorkspaceCanSections(top:[0.5,0.1,0.98],middle:[0.5,0.1,0.92],bottom:[0.5,0.1,0.86],heightMeters:0.12,diameterMeters:0.066)
                let can=ROBWorkspaceLocatedObject(target:.can,position:sections.middle,confidence:0.9,capturedAt:1000,sequence:1,
                    view:.init(panDegrees:0,upperTarget:6160),sections:sections)
                let legacy=try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:alignment)
                precondition(legacy.x>0.02 && legacy.y != 0 && abs(legacy.z+0.06)<1e-10)
                let yaw=try ROBLeftCanReachCalibration.loadBucketYaw(model:testModel,file:file)
                let inward=try ROBLeftCanReachCalibration.loadBucketInward(model:testModel,file:file)
                let base=try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:testModel,file:file)
                let clearance=try ROBLeftCanReachCalibration.loadRecoveryGraspClearance(model:testModel,file:file)
                precondition(yaw==18 && inward==0.035 && base==0.80 && clearance==0.037)
                let fresh=try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:alignment,estimatedCameraProjectionIdentity:pid)
                let freshYaw=try ROBLeftCanReachCalibration.loadBucketYaw(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                let freshInward=try ROBLeftCanReachCalibration.loadBucketInward(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                let freshBase=try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                precondition(fresh == .zero && freshYaw==0 && freshInward==0 && freshBase==nil,"Legacy camera tuning leaked into photo-origin coordinates")
                calibration.tabletopCanBaseHeightMeters=nil;calibration.tabletopGraspHeightMeters=0.85;try calibration.saveFixture(to:file)
                let oldHeight=try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:alignment)
                let newHeight=try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:alignment,estimatedCameraProjectionIdentity:pid)
                precondition(abs(oldHeight.z+0.07)<1e-10 && newHeight == .zero)
                // Even a corrupt old camera file must not be opened/decoded
                // merely to discover that its coordinate frame is obsolete.
                try Data("Invalid legacy file, deliberately isolated fixture".utf8).write(to:file)
                let noLegacyRead=try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:nil,estimatedCameraProjectionIdentity:pid)
                let noYawRead=try ROBLeftCanReachCalibration.loadBucketYaw(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                let noInwardRead=try ROBLeftCanReachCalibration.loadBucketInward(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                let noBaseRead=try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:testModel,file:file,estimatedCameraProjectionIdentity:pid)
                precondition(noLegacyRead == .zero && noYawRead==0 && noInwardRead==0 && noBaseRead==nil)
                expectBlocked {_ = try ROBLeftCanReachCalibration.load(model:testModel,can:can,file:file,depthAlignment:alignment)}
                let registration="measured-local-"+side
                let scoped=try ROBLeftCanReachCalibration.saveRegisteredResidual(model:testModel,registrationID:registration,
                    regionLowMeters:[0.2,-0.5,0.6],regionHighMeters:[0.8,0.5,1.2],translationMeters:[0.01,0.02,0.03],
                    source:"Independently registered residual fixture",baseFile:file)
                var registered=try JSONDecoder().decode(ROBLeftCanReachCalibration.self,from:Data(contentsOf:scoped))
                registered.bucketYawDegrees = -12;registered.bucketInwardMeters=0.02;registered.tabletopCanBaseHeightMeters=0.78
                try registered.saveFixture(to:scoped)
                var registeredCan=can;registeredCan.registrationID=registration
                let residual=try ROBLeftCanReachCalibration.load(model:testModel,can:registeredCan,file:file,depthAlignment:nil,estimatedCameraProjectionIdentity:pid)
                let measuredYaw=try ROBLeftCanReachCalibration.loadBucketYaw(model:testModel,file:file,registrationID:registration,estimatedCameraProjectionIdentity:pid)
                let measuredInward=try ROBLeftCanReachCalibration.loadBucketInward(model:testModel,file:file,registrationID:registration,estimatedCameraProjectionIdentity:pid)
                let measuredBase=try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:testModel,file:file,registrationID:registration,estimatedCameraProjectionIdentity:pid)
                precondition(residual==SIMD3(0.01,0.02,0.03) && measuredYaw == -12 && measuredInward==0.02 && measuredBase==0.78,
                    "Photo-origin policy suppressed an independently matched measured-frame residual")
                registeredCan.registrationID="unmatched-registration"
                let unmatched=try ROBLeftCanReachCalibration.load(model:testModel,can:registeredCan,file:file,depthAlignment:nil,estimatedCameraProjectionIdentity:pid)
                precondition(unmatched == .zero,"An unmatched registration inherited legacy tuning")
            }
            print("Photo-origin residual scope: both arms drop legacy translation/outward/table heights/bucket offsets before file read; nil identity preserves legacy behavior; matched registered residuals and physical recovery clearance remain independent")
            return
        }
        if CommandLine.arguments.last == "depth-reach-rebase" {
            let suite = "ROBDepthReachFixture."+UUID().uuidString
            let defaults = UserDefaults(suiteName:suite)!
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rob-depth-reach-"+UUID().uuidString+".json")
            defer {
                defaults.removePersistentDomain(forName:suite)
                try? FileManager.default.removeItem(at:file)
            }
            let rawAlignment = ROBWorkspaceDepthAlignment.snapshot(defaults:defaults)!
            let shiftedAlignment = try ROBWorkspaceDepthAlignment.setTowardRobotMeters(0.1778,defaults:defaults)
            var calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,
                mappingID:ROBGhostRobotModel.mappingID,translationMeters:[-0.127,0,-0.0508],
                source:"Legacy successful reach fixture")
            try calibration.saveFixture(to:file)
            let legacy = try JSONDecoder().decode(ROBLeftCanReachCalibration.self,from:Data(contentsOf:file))
            precondition(legacy.depthTowardRobotMetersAtCalibration == nil,"Legacy files must retain their raw-frame baseline")
            let before = try ROBLeftCanReachCalibration.load(model:model,file:file,depthAlignment:rawAlignment)
            let after = try ROBLeftCanReachCalibration.load(model:model,file:file,depthAlignment:shiftedAlignment)
            precondition(abs(before.x + 0.127) < 1e-12 && abs(after.x - 0.0508) < 1e-12)
            precondition(before.y == after.y && before.z == after.z,"Horizontal rebasing cannot alter grasp height")
            let oldPoint = SIMD3<Double>(0.55,-0.06,0.87), shiftedPoint = oldPoint-SIMD3(0.1778,0,0)
            precondition(simd_distance(oldPoint+before,shiftedPoint+after) < 1e-12,
                "Moving the cloud must not apply the existing can reach offset twice")
            calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,
                mappingID:ROBGhostRobotModel.mappingID,translationMeters:[after.x,after.y,after.z],
                source:"Resaved residual fixture",depthTowardRobotMetersAtCalibration:0.1778)
            try calibration.saveFixture(to:file)
            let resaved = try ROBLeftCanReachCalibration.load(model:model,file:file,depthAlignment:shiftedAlignment)
            let restoredRaw = try ROBLeftCanReachCalibration.load(model:model,file:file,depthAlignment:rawAlignment)
            precondition(simd_distance(resaved,after) < 1e-12 && simd_distance(restoredRaw,before) < 1e-12,
                "Saving the current residual and its baseline must remain reversible")
            let view = ROBWorkspaceView(panDegrees:0,upperTarget:6306)
            let oldCan = ROBWorkspaceLocatedObject(target:.can,position:[oldPoint.x,oldPoint.y,oldPoint.z],
                confidence:0.9,capturedAt:1_000,sequence:1,view:view)
            let shiftedCan = ROBWorkspaceLocatedObject(target:.can,position:[shiftedPoint.x,shiftedPoint.y,shiftedPoint.z],
                confidence:0.9,capturedAt:1_000,sequence:2,view:view)
            calibration.canOutwardMeters = 0.01
            try calibration.saveFixture(to:file)
            let shiftedNudge = try ROBLeftCanReachCalibration.load(model:model,can:shiftedCan,file:file,depthAlignment:shiftedAlignment)
            let rawNudge = try ROBLeftCanReachCalibration.load(model:model,can:oldCan,file:file,depthAlignment:rawAlignment)
            precondition(simd_distance(oldPoint+rawNudge,shiftedPoint+shiftedNudge) < 1e-12,
                "Rebasing and resaving cannot rotate the legacy radial outward nudge")
            for invalid in [-0.001,0.301] {
                calibration.depthTowardRobotMetersAtCalibration = invalid
                try calibration.saveFixture(to:file)
                expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,file:file,depthAlignment:shiftedAlignment) }
            }
            calibration.depthTowardRobotMetersAtCalibration = .nan
            expectBlocked { _ = try calibration.effectiveTranslation(depthAlignment:shiftedAlignment) }
            calibration.depthTowardRobotMetersAtCalibration = 0.1778
            expectBlocked { _ = try calibration.effectiveTranslation(depthAlignment:nil) }
            print("Depth reach rebase: legacy -127mm becomes +50.8mm at a 177.8mm cloud shift; final target and height preserved, save/reverse stable, invalid baselines and missing alignment rejected")
            return
        }
        if CommandLine.arguments.last == "recycling-pace" {
            let evidence = root.appendingPathComponent("docs/calibration/evidence/2026-10-22-recycling/first-confirmed-recycle.proposal.json")
            let legacy = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:Data(contentsOf:evidence))
            precondition(legacy.recyclingParameters == nil)
            for q in [legacy.baseline,legacy.steps[16].positions,legacy.steps[44].positions] {
                let positions = model.positions(vendorLeft:q), current = model.frames(positions)
                var complete = ["base_link":matrix_identity_double4x4]
                for _ in 0..<model.joints.count {
                    for joint in model.joints where complete[joint.child] == nil {
                        guard let parent = complete[joint.parent] else { continue }
                        let value = positions[joint.name] ?? model.reference[joint.name] ?? 0
                        var motion = matrix_identity_double4x4
                        if joint.kind == "revolute" || joint.kind == "continuous" { motion = simd_double4x4(simd_quatd(angle:value,axis:joint.axis)) }
                        else if joint.kind == "prismatic" { motion.columns.3 = SIMD4(joint.axis*value,1) }
                        complete[joint.child] = parent*joint.origin*motion
                    }
                }
                precondition(current.count == complete.count)
                for (link,frame) in complete { for column in 0..<4 {
                    precondition(current[link]![column] == frame[column],"Completed-tree early exit changed a forward-kinematics transform")
                } }
            }
            try ROBLeftGestureCompiler.validate(legacy,model:model)
            let parameters = ROBRecyclingTestParameters()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rob-recycling-pace-"+UUID().uuidString+".json")
            defer { try? FileManager.default.removeItem(at:file) }
            let defaults = try ROBRecyclingTestParameters.load(file:file)
            precondition(defaults == parameters)
            try parameters.save(file:file)
            let loaded = try ROBRecyclingTestParameters.load(file:file)
            precondition(loaded == parameters)
            func compile(_ parameters:ROBRecyclingTestParameters) throws -> ROBLeftGestureProposal {
                try ROBLeftGestureCompiler.compile(kind:legacy.kind,name:legacy.name,poses:legacy.poses,model:model,
                    baseline:legacy.baseline,generation:legacy.sessionGeneration,id:legacy.id,
                    recyclingActions:legacy.recyclingActions,recyclingParameters:parameters)
            }
            let started = ProcessInfo.processInfo.systemUptime
            let revised = try compile(parameters)
            let compileSeconds = ProcessInfo.processInfo.systemUptime-started
            try ROBLeftGestureCompiler.validate(revised,model:model)
            precondition(revised.steps.count < legacy.steps.count && revised.seconds < legacy.seconds*0.9,
                "Dense waypoint removal must produce a meaningful measured schedule improvement")
            precondition(revised.steps.compactMap(\.jawAction) == [.prepare,.grip,.release])
            var sourceIndex = 0
            for step in revised.steps {
                guard let index = legacy.steps.indices.dropFirst(sourceIndex).first(where:{ legacy.steps[$0].positions == step.positions }) else {
                    preconditionFailure("Compaction invented a waypoint or reordered the original path")
                }
                sourceIndex = index+1
            }
            for action in [ROBLeftGestureProposal.JawAction.prepare,.grip,.release] {
                let a = legacy.steps.firstIndex { $0.jawAction == action }!, b = revised.steps.firstIndex { $0.jawAction == action }!
                precondition(legacy.steps[a].positions == revised.steps[b].positions,"Jaw boundaries moved")
                if a > 0 { precondition(legacy.steps[a-1].positions == revised.steps[b-1].positions,"The stationary jaw approach stop was removed") }
                precondition(legacy.steps[a+1].positions == revised.steps[b+1].positions,"The immediate jaw retreat or lift was removed")
            }
            var previous = revised.baseline
            for step in revised.steps {
                let minimum = ROBLeftArmInteractionPlan.duration(from:previous,to:step.positions)!
                precondition(step.seconds+1e-10 >= minimum && (0.7...5).contains(step.seconds),"Pace bypassed the unchanged gateway duration minimum")
                if step.stage != "Present empty left arm" {
                    precondition((zip(previous,step.positions).map { abs($0-$1) }.max() ?? 0) <= 0.30+1e-9)
                }
                previous = step.positions
            }
            let unchanged = try compile(.init(motionPace:1,jawSettleSeconds:1.5,maximumPathDeviationMeters:0))
            precondition(unchanged.steps == legacy.steps,"Zero adjustment at original pace must preserve the entire old path and timing")
            let decoded = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:revised.encoded())
            precondition(decoded == revised && revised.fingerprint != legacy.fingerprint)
            var invalid = parameters
            for value in [0.99,1.251,Double.nan] {
                invalid.motionPace = value
                expectBlocked { _ = try compile(invalid) }
                expectBlocked { try invalid.save(file:file) }
            }
            invalid = parameters; invalid.maximumPathDeviationMeters = 0.0051
            expectBlocked { _ = try compile(invalid) }
            invalid = parameters; invalid.jawSettleSeconds = 0.99
            expectBlocked { _ = try compile(invalid) }
            try Data("{\"motionPace\":20}".utf8).write(to:file)
            expectBlocked { _ = try ROBRecyclingTestParameters.load(file:file) }
            print("Recycling pace: archived successful path \(legacy.steps.count) -> \(revised.steps.count) steps, \(legacy.seconds) -> \(revised.seconds)s scheduled, \(compileSeconds)s compile; 3mm tool/0.01rad joint chord bounds and lower-envelope clearance checked, jaw transitions and existing gateway timing unchanged; completed-tree FK matches the full dependency pass exactly")
            return
        }
        if CommandLine.arguments.last == "can-sections" {
            let view = ROBWorkspaceView(panDegrees:0,upperTarget:6306)
            let frame = view.cameraFrame(model:model)!, inverse = simd_inverse(frame)
            let width = 640, height = 480, fx = 500.0, fy = 500.0, cx = 319.5, cy = 239.5
            let base = 0.7980352035511078, canHeight = 0.12, canDiameter = 0.066, planeX = 0.6
            func pixel(_ point:SIMD3<Double>) -> SIMD2<Double> {
                let p = inverse*SIMD4(point.x,point.y,point.z,1)
                precondition(p.z > 0)
                return SIMD2(fx*p.x/p.z+cx,fy*p.y/p.z+cy)
            }
            let corners = [base,base+canHeight].flatMap { z in
                [-canDiameter/2,canDiameter/2].map { y in pixel(SIMD3(planeX,y,z)) }
            }
            let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
            let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
            let box = [minX/Double(width-1),minY/Double(height-1),maxX/Double(width-1),maxY/Double(height-1)]
            let center = [(box[0]+box[2])/2,(box[1]+box[3])/2]
            let detection = ROBWorkspaceDetection(visible:true,confidence:0.9,box:box,aim:center,depthPoint:center)
            func depth(_ x:Int,_ y:Int) -> UInt16? {
                guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
                let direction = frame*SIMD4((Double(x)-cx)/fx,(Double(y)-cy)/fy,1,0)
                let z = (planeX-frame.columns.3.x)/direction.x
                guard z.isFinite, (0.15...3).contains(z) else { return nil }
                return UInt16((z*1000).rounded())
            }
            func sections(_ candidate:ROBWorkspaceDetection, _ source:(Int,Int)->UInt16?) -> ROBWorkspaceCanSections? {
                ROBWorkspaceCanSections.measure(detection:candidate,width:width,height:height,fx:fx,fy:fy,cx:cx,cy:cy,
                    depth:source,view:view,model:model)
            }
            let measured = sections(detection,depth)!
            precondition(measured.valid && abs(measured.heightMeters-canHeight) < 0.006)
            precondition(abs(measured.diameterMeters-canDiameter) < 0.008)
            precondition(measured.top[2] > measured.middle[2] && measured.middle[2] > measured.bottom[2])
            precondition(abs(measured.middle[2]-(measured.top[2]+measured.bottom[2])/2) < 1e-12)
            func observation(_ sections:ROBWorkspaceCanSections?,_ sequence:UInt64) -> ROBWorkspaceLocatedObject {
                .init(target:.can,position:measured.middle,confidence:0.8,capturedAt:1000+Double(sequence)*100,
                    sequence:sequence,view:view,sections:sections)
            }
            let middlePoint = SIMD3(measured.middle[0],measured.middle[1],measured.middle[2])
            func body(_ height:Double,_ diameter:Double) -> ROBWorkspaceCanSections {
                ROBWorkspaceCanSections.fit(topBand:middlePoint+SIMD3(0,0,height*0.32),middleBand:middlePoint,
                    bottomBand:middlePoint-SIMD3(0,0,height*0.32),diameterMeters:diameter)!
            }
            var confirmation = ROBWorkspaceLocationConfirmation()
            precondition(confirmation.observe(observation(measured,1)) == nil)
            precondition(confirmation.observe(observation(body(measured.heightMeters+0.001,measured.diameterMeters),2)) != nil,
                "Consistent advancing can section measurements must confirm")
            precondition(confirmation.observe(observation(body(0.17,measured.diameterMeters),3)) == nil,
                "Agreeing midpoints cannot confirm a can height jump")
            var diameterConfirmation = ROBWorkspaceLocationConfirmation()
            precondition(diameterConfirmation.observe(observation(body(0.12,0.05),1)) == nil)
            precondition(diameterConfirmation.observe(observation(body(0.12,0.08),2)) == nil,
                "Agreeing midpoints cannot confirm a can diameter jump")
            var missingSections = ROBWorkspaceLocationConfirmation()
            precondition(missingSections.observe(observation(measured,1)) == nil)
            precondition(missingSections.observe(observation(nil,2)) == nil,
                "Section-aware confirmation needs valid geometry in both frames")
            precondition(sections(detection,{ x,y in (x+y)%47 == 0 ? 2500 : depth(x,y) }) != nil,
                "Sparse reflective-depth outliers must not replace the body-band median")
            precondition(sections(detection,{ _,_ in nil }) == nil)
            precondition(sections(detection,{ x,y in abs(Double(y)-(minY+maxY)/2) < 10 ? nil : depth(x,y) }) == nil,
                "A missing middle depth band must block section geometry")
            let clipped = ROBWorkspaceDetection(visible:true,confidence:0.9,box:[0.01,box[1],box[2],box[3]],
                aim:center,depthPoint:center)
            precondition(sections(clipped,depth) == nil,"Clipped boxes cannot supply a measured full can height")
            precondition(ROBWorkspaceCanSections.fit(topBand:SIMD3(0.6,0.04,0.86),middleBand:SIMD3(0.6,0,0.86),
                bottomBand:SIMD3(0.6,-0.04,0.86),diameterMeters:canDiameter) == nil,
                "A fallen can cannot be treated as upright")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rob-can-sections-"+UUID().uuidString+".json")
            defer { try? FileManager.default.removeItem(at:file) }
            var calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,
                mappingID:ROBGhostRobotModel.mappingID,translationMeters:[-0.127,0,-0.0508],
                source:"Isolated conservative same-table base datum fixture",canOutwardMeters:0.01,
                tabletopCanBaseHeightMeters:base)
            try calibration.saveFixture(to:file)
            let loadedBase = try ROBLeftCanReachCalibration.loadTabletopCanBaseHeight(model:model,file:file)
            precondition(loadedBase == base)
            let raw = [0.56,-0.067,0.9243580983385508]
            var can = ROBWorkspaceLocatedObject(target:.can,position:raw,confidence:0.8,capturedAt:1000,sequence:1,
                view:view,sections:measured)
            let offset = try ROBLeftCanReachCalibration.load(model:model,can:can,file:file)
            precondition(abs(can.point.z+offset.z-(base+measured.heightMeters/2)) < 1e-12)
            precondition(can.point.z+offset.z > base+0.05,"The middle-body grasp must clear the conservative tabletop datum")
            precondition(can.position == raw && can.sections?.top == measured.top,"Calibration mutated raw section observations")
            let decoded = try JSONDecoder().decode(ROBWorkspaceLocatedObject.self,from:JSONEncoder().encode(can))
            precondition(decoded.sections?.valid == true && decoded.sections?.middle == measured.middle)
            can.sections = nil
            expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,can:can,file:file) }
            expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,file:file) }
            calibration.tabletopGraspHeightMeters = base
            try calibration.saveFixture(to:file)
            expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,can:can,file:file) }
            print("Can sections: synthetic 12cm upright RGB-D body, independent top/middle/base bands, unclipped height and diameter, robust median; missing/clipped/fallen geometry rejected, calibrated middle clears conservative same-table datum")
            return
        }
        if CommandLine.arguments.last == "search-schedule" {
            let now = Date().timeIntervalSince1970 * 1000
            let canHint = ROBWorkspaceRecall.Sighting(target:.can,view:.init(panDegrees:-30,upperTarget:6306),
                box:[0.0008170492947101593,0.6563320922851562,0.08337186574935913,0.9749293518066406],
                confidence:0.6290956735610962,capturedAt:now-1000)
            let bucketHint = ROBWorkspaceRecall.Sighting(target:.orangeBucket,view:.init(panDegrees:15,upperTarget:5650),
                box:[0.16691629886627196,0.3721091842651367,0.382261323928833,0.7084024810791015],
                confidence:0.5621610879898071,capturedAt:now-1000)
            let recall = ROBWorkspaceRecall(modelID:model.modelID,geometryID:model.geometryID,sightings:[canHint,bucketHint])
            var search = ROBWorkspaceSearchSchedule(targets:[.can,.orangeBucket],recall:recall,now:now)
            precondition(search.next(confirmed:[]) == canHint.centeredView,
                "A clipped historical can must be centered before repeating its clipped view")
            precondition(search.next(confirmed:[.can]) == bucketHint.view,
                "The missing bucket must be checked before more views of the already confirmed can")
            let completedViews = search.attempted.count
            precondition(search.next(confirmed:[.can,.orangeBucket]) == nil && search.attempted.count == completedViews,
                "Both fresh confirmations must stop the search before another neck move")
            precondition(completedViews == 2)
            precondition(ROBWorkspaceSearchSchedule.recallQuality([0.4,0.4,0.6,0.7]) >
                ROBWorkspaceSearchSchedule.recallQuality(canHint.box),"A clipped glimpse must not replace a better current-search recall view")

            let emptyRecall = ROBWorkspaceRecall(modelID:model.modelID,geometryID:model.geometryID)
            var fallback = ROBWorkspaceSearchSchedule(targets:[.can,.orangeBucket],recall:emptyRecall,now:now)
            var raster: [ROBWorkspaceView] = []
            while let view = fallback.next(confirmed:[]) { raster.append(view) }
            precondition(ROBWorkspaceView.sweep.allSatisfy { original in
                raster.contains { abs($0.panDegrees-original.panDegrees) < 3 && abs($0.upperTarget-original.upperTarget) < 100 }
            },"Every original raster interval must remain available when recall fails")
            precondition(raster.count < ROBWorkspaceView.sweep.count,
                "A raster view already inspected must not incur another move and inference pair")
            let coarse = [ROBWorkspaceView(panDegrees:0,upperTarget:6306),.init(panDegrees:-30,upperTarget:6306),
                .init(panDegrees:30,upperTarget:6306),.init(panDegrees:0,upperTarget:5650),
                .init(panDegrees:30,upperTarget:5650),.init(panDegrees:-30,upperTarget:5650)]
            precondition(Array(raster.prefix(6)) == coarse,
                "A rotated scene without recall must check broad front/left/right views before the detailed raster")
            func canBox(_ box: [Double], _ confidence: Double) -> ROBWorkspaceDetection {
                let center = [(box[0]+box[2])/2,(box[1]+box[3])/2]
                return .init(visible:true,confidence:confidence,box:box,aim:center,depthPoint:center,confidenceThreshold:0.35)
            }
            let firstCan = canBox([0.2,0.2,0.3,0.6],0.8), repeatedCan = canBox([0.205,0.205,0.305,0.605],0.7)
            let secondCan = canBox([0.6,0.2,0.7,0.6],0.6)
            let distinctCans = ROBWorkspaceSearchSchedule.distinctCans([repeatedCan,secondCan,firstCan])
            precondition(distinctCans.count == 2 && distinctCans[0].box == firstCan.box && distinctCans[1].box == secondCan.box,
                "Repeated prompts for one can must merge while two separate physical cans remain distinct")
            let manyCans = (0..<10).map { index in canBox([Double(index)/10,0.2,Double(index)/10+0.04,0.5],0.9) }
            precondition(ROBWorkspaceSearchSchedule.distinctCans(manyCans).count == 8)

            var nearby = ROBWorkspaceSearchSchedule(targets:[.can,.orangeBucket],recall:recall,now:now,
                boundedPan:{ max(-35,min(35,$0)) })
            var missingBucket: [ROBWorkspaceView] = []
            while let view = nearby.next(confirmed:[.can]) { missingBucket.append(view) }
            precondition(missingBucket.first == bucketHint.view)
            precondition([0.0,30].allSatisfy { pan in missingBucket.prefix(6).contains {
                abs($0.panDegrees-pan) < 3 && abs($0.upperTarget-5650) < 100
            } },
                "Look 15 degrees around the missing bucket hint before the full raster")
            precondition(missingBucket.allSatisfy { (5300...7500).contains($0.upperTarget) && abs($0.panDegrees) <= 45 })
            for index in missingBucket.indices {
                precondition(!missingBucket.prefix(index).contains {
                    abs($0.panDegrees-missingBucket[index].panDegrees) < 3 && abs($0.upperTarget-missingBucket[index].upperTarget) < 100
                },"Recall, recentering and fallback must not repeat the same inspected view")
            }
            var hanging = ROBWorkspaceSearchSchedule(targets:[],recall:emptyRecall,now:now)
            var hangingViews = 0
            while hanging.next(confirmed:[]) != nil { hangingViews += 1 }
            precondition(hangingViews == 3,"An empty object target list must retain the hanging inspection scan")
            print("Search schedule: clipped can centered, missing bucket reached in2views, confirmed pair stops; fresh rotated scene gets6broadviews, all\(ROBWorkspaceView.sweep.count) fallback intervals retained, distinctcanNMS preserves2instances/max8, hanging scan retained")
            return
        }
        if CommandLine.arguments.last == "can-vector" {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rob-can-vector-"+UUID().uuidString+".json")
            defer { try? FileManager.default.removeItem(at:file) }
            var calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,
                mappingID:ROBGhostRobotModel.mappingID,translationMeters:[-0.127,0,-0.0508],
                source:"Isolated one-centimeter deeper grasp fixture",canOutwardMeters:0.01)
            try calibration.saveFixture(to:file)
            let base = SIMD3<Double>(-0.127,0,-0.0508)
            for xy in [SIMD2<Double>(0.56,-0.067),SIMD2<Double>(0.2,0.6)] {
                let can = ROBWorkspaceLocatedObject(target:.can,position:[xy.x,xy.y,0.85],confidence:0.8,
                    capturedAt:1000,sequence:1,view:.init(panDegrees:0,upperTarget:6306))
                let offset = try ROBLeftCanReachCalibration.load(model:model,can:can,file:file)
                let delta = SIMD2(offset.x-base.x,offset.y-base.y)
                precondition(simd_length(delta-simd_normalize(xy)*0.01) < 1e-12 && offset.z == base.z)
                precondition(can.position == [xy.x,xy.y,0.85],"Calibration mutated a raw sighting")
            }
            expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,file:file) }
            for invalid in [-0.001,0.031] {
                calibration.canOutwardMeters = invalid
                try calibration.saveFixture(to:file)
                expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,file:file) }
            }
            calibration.canOutwardMeters = 0.01
            calibration.tabletopGraspHeightMeters = 0.7980352035511078
            try calibration.saveFixture(to:file)
            for rawZ in [0.8488352035511078,0.9243580983385508] {
                let can = ROBWorkspaceLocatedObject(target:.can,position:[0.56,-0.067,rawZ],confidence:0.8,
                    capturedAt:1000,sequence:1,view:.init(panDegrees:0,upperTarget:6306))
                let offset = try ROBLeftCanReachCalibration.load(model:model,can:can,file:file)
                let xy = SIMD2<Double>(0.56,-0.067), delta = SIMD2(offset.x-base.x,offset.y-base.y)
                precondition(abs(can.point.z+offset.z-calibration.tabletopGraspHeightMeters!) < 1e-12)
                precondition(simd_length(delta-simd_normalize(xy)*0.01) < 1e-12)
                precondition(can.position == [0.56,-0.067,rawZ],"Tabletop calibration mutated the fresh sighting")
            }
            let highCan = ROBWorkspaceLocatedObject(target:.can,position:[0.56,-0.067,1.2],confidence:0.8,
                capturedAt:1000,sequence:1,view:.init(panDegrees:0,upperTarget:6306))
            expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,can:highCan,file:file) }
            print("Can-vector calibration: exactly1cm along each fresh horizontal can vector, fixed proven tabletop height across camera views, raw sightings unchanged; missing direction and out-of-range corrections rejected")
            return
        }
        if CommandLine.arguments.last == "raised-recovery" {
            let evidence = root.appendingPathComponent("docs/calibration/evidence/2026-10-22-recycling/height-yaw-live-missed-grasp.proposal.json")
            let previous = try JSONDecoder().decode(ROBLeftGestureProposal.self,from:Data(contentsOf:evidence))
            precondition(previous.kind == "recycling" && previous.steps.count == 48)
            try ROBLeftGestureCompiler.validate(previous,model:model)
            // Isolated samples prove all 48 frozen waypoints were visited. The
            // archived CSV remains the physical record; this fixture sends nothing.
            let samples = previous.steps.enumerated().map { index,step in
                ROBGhostRecordingSample(time:Double(index),positions:step.positions,currents:[Double](repeating:0.2,count:7),
                    deltas:[Double](repeating:0,count:7),step:index)
            }
            let measured = previous.steps.last!.positions
            let gripIndex = previous.steps.firstIndex { $0.jawAction == .grip }!
            let frontIndex = previous.steps.firstIndex { $0.jawAction == .prepare }!
            let clearance = 0.0889
            let floor = model.toolPosition(model.positions(vendorLeft:previous.steps[gripIndex].positions))!.z + clearance
            let original = try ROBRecordedLeftRecovery.make(previous:previous,samples:samples,measured:measured,model:model,generation:78)
            let raised = try ROBRecordedLeftRecovery.make(previous:previous,samples:samples,measured:measured,model:model,
                generation:78,graspClearanceMeters:clearance)
            precondition(original.steps.contains { $0.positions == previous.steps[gripIndex].positions },
                "Default recorded recovery must retain its existing route behavior")
            precondition(!raised.steps.contains { $0.positions == previous.steps[gripIndex].positions },
                "Raised recovery must skip the grasp that contacted the table")
            precondition(raised.steps.count < original.steps.count && raised.steps.count <= 80 && raised.seconds <= 100)
            precondition(raised.kind == "recover" && raised.sessionGeneration == 78 && raised.baseline == measured && raised.id != previous.id)
            precondition(raised.validForReplay(model:model) && raised.steps.allSatisfy { $0.jawAction == nil })
            precondition(raised.steps.last!.positions == previous.steps[frontIndex].positions,
                "Raised recovery must finish at the previously visited front pose")
            for invalidClearance in [-0.001,0.151,Double.nan] {
                expectBlocked {
                    _ = try ROBRecordedLeftRecovery.make(previous:previous,samples:samples,measured:measured,model:model,
                        generation:78,graspClearanceMeters:invalidClearance)
                }
            }
            expectBlocked {
                _ = try ROBRecordedLeftRecovery.make(previous:previous,samples:samples,
                    measured:previous.steps[gripIndex].positions,model:model,generation:78,graspClearanceMeters:clearance)
            }
            var lastVisited = previous.steps.count, previousQ = measured, minimumHeight = Double.infinity
            for step in raised.steps {
                let matching = stride(from:lastVisited-1,through:frontIndex,by:-1).first { previous.steps[$0].positions == step.positions }
                precondition(matching != nil,"Recovery invented or reordered a previously unvisited target")
                lastVisited = matching!
                let duration = ROBLeftArmInteractionPlan.duration(from:previousQ,to:step.positions,padding:ROBArmRoutinePlan.tolerance)!
                precondition(abs(step.seconds-duration) < 1e-9 && step.seconds <= 5)
                let checks = max(1,Int(ceil(1.5*zip(previousQ,step.positions).reduce(0.0) { $0+abs($1.0-$1.1) }/0.01)))
                for sample in 0...checks {
                    let t = Double(sample)/Double(checks), q = zip(previousQ,step.positions).map { $0+($1-$0)*t }
                    let positions = model.positions(vendorLeft:q), z = model.toolPosition(positions)!.z
                    minimumHeight = min(minimumHeight,z)
                    precondition(q.allSatisfy { $0.isFinite && abs($0) <= 3.1 })
                    precondition(model.treadSeparation(vendorLeft:q) >= 0.030)
                    precondition(model.joints.filter { $0.name.hasPrefix("left_joint") }.allSatisfy {
                        ($0.lower...$0.upper).contains(positions[$0.name]!)
                    })
                    precondition(z >= floor-1e-9,"A return bridge descended into the table-contact clearance zone")
                }
                previousQ = step.positions
            }
            print("Raised recorded recovery: \(raised.steps.count) visited targets in reverse order, \(raised.seconds)s, minimum height above prior grasp \(minimumHeight-(floor-clearance))m; no jaw replay, front pose reached")
            return
        }
        if ["operator-alignment","measured-hanging"].contains(CommandLine.arguments.last ?? "") {
            let measuredHanging = CommandLine.arguments.last == "measured-hanging"
            let baselineQ: [Double] = measuredHanging ? [0,0,0,0,0,0,0.00272707695624114] : Array(repeating:0,count:7)
            let now = Date().timeIntervalSince1970 * 1000, baseline = model.positions(vendorLeft:baselineQ)
            let view = ROBWorkspaceView(panDegrees:0,upperTarget:6306)
            let can = ROBWorkspaceLocatedObject(target:.can,position:measuredHanging ? [0.5692687658021478,-0.08326221606964468,0.9243580983385508] : [0.5324488846561272,-0.06700092572478558,0.8835158279604254],
                confidence:0.8,capturedAt:now,sequence:10,view:view)
            let bucket = ROBWorkspaceLocatedObject(target:.orangeBucket,position:measuredHanging ? [0.32242477494949906,0.4546627224299035,0.2752971437682622] : [0.3386968846760923,0.46298106639441516,0.27549540863399613],
                confidence:0.6,capturedAt:now,sequence:11,view:view,openingRadius:0.10133714336237384)
            let rawCan = can.position, rawBucket = bucket.position, rawRadius = bucket.openingRadius
            let previousOffset = SIMD3<Double>(-0.127,0,-0.1143), offset = SIMD3<Double>(-0.127,0,-0.0508)
            let inward = 0.0381
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("rob-alignment-"+UUID().uuidString+".json")
            defer { try? FileManager.default.removeItem(at:file) }
            let calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,mappingID:ROBGhostRobotModel.mappingID,
                translationMeters:[offset.x,offset.y,offset.z],source:"Isolated operator alignment fixture",
                bucketYawDegrees:20,bucketInwardMeters:inward)
            try calibration.saveFixture(to:file)
            let loadedOffset = try ROBLeftCanReachCalibration.load(model:model,file:file)
            let loadedYaw = try ROBLeftCanReachCalibration.loadBucketYaw(model:model,file:file)
            let loadedInward = try ROBLeftCanReachCalibration.loadBucketInward(model:model,file:file)
            precondition(loadedOffset == offset && loadedYaw == 20 && loadedInward == inward)
            let previousGrasp = try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,now:now,reachOffset:previousOffset)
            let noInward = try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,now:now,bucket:bucket,
                reachOffset:offset,bucketYawDegrees:20)
            let corrected = try ROBCanGrabPreview.make(can:can,model:model,baseline:baseline,now:now,bucket:bucket,
                reachOffset:loadedOffset,bucketYawDegrees:loadedYaw,bucketInwardMeters:loadedInward)
            precondition(corrected.reachesCan && corrected.can.position == rawCan)
            precondition(can.position == rawCan && bucket.position == rawBucket && bucket.openingRadius == rawRadius)
            precondition(abs(corrected.calibratedGraspPoint.z-(can.point.z-0.0508)) < 0.000001)
            precondition(ROBArmRoutinePlan.near(model.vendorLeft(corrected.steps[0].pose),ROBLeftArmInteractionPlan.target(index:ROBLeftArmInteractionPlan.frontIndex)!,tolerance:0.001),"Hanging wrist residual leaked into the registered front target")
            precondition(abs(corrected.calibratedGraspPoint.z-previousGrasp.calibratedGraspPoint.z-0.0635) < 0.000001,
                "The table-contact correction must raise the grasp by 2.5 inches")
            precondition(corrected.calibratedGraspPoint.x == previousGrasp.calibratedGraspPoint.x &&
                corrected.calibratedGraspPoint.y == previousGrasp.calibratedGraspPoint.y)
            let actions = Dictionary(uniqueKeysWithValues:corrected.steps.enumerated().compactMap { i,s in s.jawAction.map { (i,$0) } })
            let frozen = try ROBLeftGestureCompiler.compile(kind:"recycling",name:"Operator alignment regression",poses:corrected.steps.map(\.pose),
                model:model,baseline:baselineQ,generation:77,recyclingActions:actions)
            try ROBLeftGestureCompiler.validate(frozen,model:model)
            func release(_ plan:ROBCanGrabPreview) -> SIMD3<Double> { model.toolPosition(plan.steps.first { $0.jawAction == .release }!.pose)! }
            let pivot = model.frames(baseline)["left_one_Link"]!.columns.3
            let a = release(noInward), b = release(corrected)
            let radialChange = hypot(a.x-pivot.x,a.y-pivot.y)-hypot(b.x-pivot.x,b.y-pivot.y)
            precondition(abs(radialChange-inward) < 0.006,
                "Bucket release must move 1.5 inches toward the left shoulder")
            precondition(abs(a.z-b.z) < 0.003,"The inward release correction must preserve drop height")
            print("Operator alignment: grasp raised6.35cm, raw sightings unchanged, yaw remains20 degrees LEFT, release moves\(radialChange)m inward; \(frozen.steps.count) validated physical steps, grasp error\(corrected.graspError)m")
            return
        }
        func head(_ pan: Double, _ lower: Double, _ upper: Double) -> [String: simd_double4x4] {
            var positions = model.reference
            positions.merge(model.headPositions(pan: pan, lowerPitch: lower, upperPitch: upper)!) { _, command in command }
            return model.frames(positions)
        }
        let upright = model.headPositions(pan: 0, lowerPitch: 0, upperPitch: 0)!
        precondition(upright["lower_neck"] == 0 && upright["upper_neck"] == 0 && upright["neck_pan"] == 0)
        let acceptedUpright = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(acceptedUpright.lowerPitch == 0 && acceptedUpright.upperPitch == 0)
        let acceptedSocial = ROBHeadCameraPoseEstimator.estimate(panRadians: .pi / 6, lowerTarget: 6011,
            upperTarget: 6306, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(abs(acceptedSocial.upperPitch + .pi / 10) < 1e-9 && acceptedSocial.lowerPitch == 0)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: false) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 0,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimate(panRadians: .nan, lowerTarget: 6011,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true) == nil)
        // A captured lean-back pose must not survive an upright command.
        var zeroNeck = model.reference
        zeroNeck.merge(upright) { _, command in command }
        let lowerOnly = model.headPositions(pan: 0, lowerPitch: 0.1, upperPitch: 0)!
        precondition(lowerOnly["lower_neck"] == 0.1 && lowerOnly["upper_neck"] == 0)
        func opticalPitch(_ frames: [String: simd_double4x4]) -> Double {
            let direction = frames["oak_optical_frame"]!.columns.2
            return atan2(direction.z, hypot(direction.x, direction.y))
        }
        let displayNeutral = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6906, known: true)!
        let displayFrames = head(0, displayNeutral.lowerPitch, displayNeutral.upperPitch)
        precondition(displayNeutral.lowerPitch == 0 && displayNeutral.upperPitch == 0)
        precondition(abs(opticalPitch(displayFrames)) < 1e-8,
            "Observed upright posture must place the front camera parallel to the floor")
        let neckUp = displayFrames["lower_neck_link"]!.columns.2
        precondition(simd_distance(SIMD3(neckUp.x, neckUp.y, neckUp.z), SIMD3<Double>(0, 0, 1)) < 1e-8)
        let displayLowerMoved = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6411, upperTarget: 6906, known: true)!
        let displayUpperMoved = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6506, known: true)!
        for changed in [displayLowerMoved, displayUpperMoved] {
            precondition(abs(opticalPitch(head(0, changed.lowerPitch, changed.upperPitch)) + 12 * .pi / 180) < 1e-8,
                "Observed neutral must remain articulated by each accepted neck command")
        }
        let inferredCandidate = ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 7014, upperTarget: 7790, known: true)!
        precondition(abs(inferredCandidate.lowerPitch) > 0.5 && abs(inferredCandidate.upperPitch) > 0.4,
            "A later live target pair must not silently replace the operator-confirmed display zero")
        precondition(ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 6011, upperTarget: 6906, known: false) == nil)
        precondition(ROBHeadCameraPoseEstimator.estimateDisplay(panRadians: 0,
            lowerTarget: 0, upperTarget: 6906, known: true) == nil)
        let acceptedForward = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 7014,
            upperTarget: 7790, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        let forwardHead = head(acceptedForward.panRadians, acceptedForward.lowerPitch, acceptedForward.upperPitch)
        precondition(abs(opticalPitch(forwardHead) + 3.57 * .pi / 180) < 1e-8,
            "Accepted lower/upper commands must counter-rotate, not point the cloud at the ceiling")
        let acceptedLowerOnly = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6411,
            upperTarget: 6906, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        precondition(abs(opticalPitch(head(0, acceptedLowerOnly.lowerPitch, acceptedLowerOnly.upperPitch)) + 12 * .pi / 180) < 1e-8,
            "Increasing the accepted lower target must pitch the optical direction downward")
        let acceptedCompensated = ROBHeadCameraPoseEstimator.estimate(panRadians: 0, lowerTarget: 6411,
            upperTarget: 7306, uprightLowerTarget: 6011, levelUpperTarget: 6906, known: true)!
        let compensated = head(0, acceptedCompensated.lowerPitch, acceptedCompensated.upperPitch)
        precondition(abs(opticalPitch(compensated)) < 1e-8,
            "Equal positive lower/upper command deltas must preserve the level optical direction")
        let level = head(0, 0, 0), down = head(0, 0, -.pi / 10), turned = head(.pi / 6, 0, -.pi / 10)
        let forward = level["oak_optical_frame"]!.columns.2
        let downForward = down["oak_optical_frame"]!.columns.2
        precondition(abs(forward.z) < 1e-8 && forward.x > 0.99)
        precondition(abs(atan2(downForward.z, hypot(downForward.x, downForward.y)) + .pi / 10) < 1e-8)
        precondition(turned["oak_optical_frame"]!.columns.2.y > 0.4)
        precondition(simd_distance(level["oak_optical_frame"]!.columns.3, down["oak_optical_frame"]!.columns.3) > 0.02)
        precondition(level["belly_oak_optical_frame"]! == turned["belly_oak_optical_frame"]!)
        precondition(level["lower_neck_link"]! == model.frames(zeroNeck)["lower_neck_link"]!)
        let lowerBent = head(0, 0.1, 0)
        let lowerAxis = lowerBent["lower_neck_link"]!.columns.2
        precondition(lowerAxis.x > 0.09 && lowerAxis.z > 0.99)
        precondition(simd_distance(lowerBent["neck_pan_link"]!.columns.3, level["neck_pan_link"]!.columns.3) > 0.01)
        precondition(head(0, -0.1, 0.1)["lower_neck_link"]! != level["lower_neck_link"]!)
        precondition(model.headPositions(pan: .nan, lowerPitch: 0, upperPitch: 0) == nil)
        precondition(compensated["lower_neck_link"]! != level["lower_neck_link"]!,
            "Level camera compensation must not freeze the lower-neck joint")
        print("Head FK: upright/upper-only preserved; lower rotates down, paired commands counter-rotate, 7014/7790 predicts -3.57 degrees; belly remains fixed")
        let oldFront = ROBLeftArmInteractionPlan.target(index: 18)!
        let center = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.frontIndex)!
        let wave = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveRestIndex)!
        let oldXYZ = model.toolPosition(model.positions(vendorLeft: oldFront))!
        let centerXYZ = model.toolPosition(model.positions(vendorLeft: center))!
        let waveFrames = model.frames(model.positions(vendorLeft: wave))
        let waveXYZ = model.toolPosition(model.positions(vendorLeft: wave))!
        let shoulderZ = waveFrames["left_one_Link"]!.columns.3.z
        let j6CenterXYZ = model.toolPosition(model.positions(vendorLeft: ROBLeftArmInteractionPlan.target(index: 24)!))!
        precondition(abs(j6CenterXYZ.y) < 0.05 && j6CenterXYZ.y < oldXYZ.y - 0.1)
        precondition(centerXYZ.z > j6CenterXYZ.z + 0.18)
        precondition(waveXYZ.z > shoulderZ + 0.15)
        precondition(wave[4] == -1.4 && ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)![5] == -0.9)
        print("URDF: negative J6 centers the hand; larger J2 and negative J4 put the wave above shoulder height")

        let proposal = try ROBLeftGestureCompiler.compile(kind: "wave", name: "High wave", model: model,
            baseline: Array(repeating: 0, count: 7), generation: 42)
        try ROBLeftGestureCompiler.validate(proposal, model: model)
        precondition(proposal.steps.last!.positions == wave)
        precondition(proposal.steps.allSatisfy { (0.7...5).contains($0.seconds) })
        precondition(proposal.seconds < 20 && proposal.steps.count == 11)
        let approachFrom = ROBLeftArmInteractionPlan.target(index: 5)!, approachTo = ROBLeftArmInteractionPlan.target(index: 6)!
        precondition(abs(ROBLeftArmInteractionPlan.duration(from: approachFrom, to: approachTo)! * 4 -
            ROBArmRoutinePlan.duration(from: approachFrom, to: approachTo)!) < 1e-8)
        let crest = ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)!
        precondition((0.7...0.75).contains(ROBLeftArmInteractionPlan.duration(from: wave, to: crest)!))
        let route = Array(ROBLeftArmInteractionPlan.waypoints[1...ROBLeftArmInteractionPlan.waveRestIndex])
        let compact = ROBLeftGestureCompiler.compactRoute(baseline: Array(repeating: 0, count: 7), targets: route)
        precondition(compact == [1,4,6,9,12,15,18,24,28,34,42].map { ROBLeftArmInteractionPlan.waypoints[$0] })
        let zero = Array(repeating: 0.0, count: 7)
        let centerRoute = ROBLeftArmInteractionPlan.executionRoute(from: zero, hanging: false)!
        let centerStops = ROBLeftArmInteractionPlan.compactRoute(from: zero, indices: centerRoute)!
        precondition(ROBLeftArmInteractionPlan.route(from: zero, hanging: false)!.count == 28)
        precondition(centerStops == [1,4,6,18,28])
        let returnStops = ROBLeftArmInteractionPlan.compactRoute(from: center,
            indices: ROBLeftArmInteractionPlan.executionRoute(from: center, hanging: true)!)!
        precondition(returnStops == [18,6,4,1,0])
        let centerProposal = try ROBLeftGestureCompiler.compile(kind: "center", name: "Smooth handoff", model: model,
            baseline: zero, generation: 42)
        precondition(centerProposal.steps.map(\.positions) == centerStops.map { ROBLeftArmInteractionPlan.waypoints[$0] },
            "Normal controls and ghost preview must traverse the same retained corners")
        for start in 0...ROBLeftArmInteractionPlan.waveRestIndex {
            for hanging in [false, true] {
                var previous = ROBLeftArmInteractionPlan.waypoints[start]
                let original = ROBLeftArmInteractionPlan.executionRoute(from: previous, hanging: hanging)!
                let reduced = ROBLeftArmInteractionPlan.compactRoute(from: previous, indices: original)!
                for index in reduced {
                    precondition(ROBLeftArmInteractionPlan.allowsDirectMove(from: previous, to: index))
                    previous = ROBLeftArmInteractionPlan.waypoints[index]
                }
                precondition(original.last == reduced.last)
            }
        }
        print(String(format: "Normal handoff: 28 stops reduced to 5, %.1f seconds scheduled; ghost path and reverse corners agree", centerProposal.seconds))
        // Changing a joint at a corner must not turn into a diagonal shortcut.
        let corner = [[0.1,0,0,0,0,0,0],[0.1,0.1,0,0,0,0,0],[0.2,0.1,0,0,0,0,0]]
        precondition(ROBLeftGestureCompiler.compactRoute(baseline: Array(repeating: 0, count: 7), targets: corner) == corner)
        precondition(proposal.steps.suffix(4).map(\.positions) == [crest,wave,crest,wave])
        print(String(format: "Reviewed pace: collinear increments joined with corners/reversals intact; full wave %.1f seconds scheduled", proposal.seconds))
        let encoded = try proposal.encoded()
        precondition(proposal.fingerprint == ROBGhostRobotModel.hash(encoded))
        let historical = try JSONDecoder().decode(ROBLeftGestureProposal.self, from: encoded)
        precondition(historical.steps.contains { $0.seconds >= 0.7 && $0.seconds < 0.8 })
        precondition(historical.validForReplay(model: model), "Fast recorded steps must replay without reauthorizing execution")
        let invalidReplay = ROBLeftGestureProposal(id: proposal.id, name: proposal.name, kind: proposal.kind, modelID: proposal.modelID,
            referenceID: proposal.referenceID, geometryID: proposal.geometryID, mappingID: proposal.mappingID,
            sessionGeneration: proposal.sessionGeneration, baseline: proposal.baseline, poses: proposal.poses,
            steps: [.init(positions: wave, seconds: 0.3)])
        precondition(!invalidReplay.validForReplay(model: model))
        let changed = ROBLeftGestureProposal(id: proposal.id, name: proposal.name, kind: proposal.kind, modelID: proposal.modelID,
            referenceID: proposal.referenceID, geometryID: proposal.geometryID, mappingID: proposal.mappingID,
            sessionGeneration: proposal.sessionGeneration, baseline: proposal.baseline,
            poses: proposal.poses, steps: Array(proposal.steps.dropLast()))
        expectBlocked { try ROBLeftGestureCompiler.validate(changed, model: model) }
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "wave", name: "Bad", model: model, baseline: center, generation: 0) }
        print("Frozen review: model/session identity, complete targets, timings and SHA256 are bound; tampering rejected")

        let returnIndices = ROBLeftArmInteractionPlan.route(from: ROBLeftArmInteractionPlan.target(index: ROBLeftArmInteractionPlan.waveIndex)!, hanging: false)!
        precondition(returnIndices == Array(stride(from: ROBLeftArmInteractionPlan.waveRestIndex, through: ROBLeftArmInteractionPlan.frontIndex, by: -1)))
        let lowering = ROBLeftArmInteractionPlan.route(from: wave, hanging: true)!
        precondition(lowering == Array(stride(from: ROBLeftArmInteractionPlan.waveRestIndex - 1, through: 0, by: -1)))
        precondition(ROBLeftArmInteractionPlan.stationaryFrontTarget(wave) == nil)
        print("Return: high wave reverses through every raised waypoint before centering/lowering; jaw-only wave-pose action rejected")

        var custom = model.positions(vendorLeft: center)
        custom["left_joint1"] = -0.95
        let gesture = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Small hello", poses: [custom], model: model,
            baseline: center, generation: 42)
        precondition(gesture.steps.last!.positions == center)
        precondition(gesture.steps.contains { abs($0.positions[0] + 0.95) < 0.00001 })
        var otherServo = custom; otherServo["neck_pan"] = 0.1
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Unmapped", poses: [otherServo], model: model, baseline: center, generation: 42) }
        var outside = custom; outside["left_joint2"] = 0
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Near treads", poses: [outside], model: model, baseline: center, generation: 42) }
        var nan = custom; nan["left_joint1"] = .nan
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "Invalid", poses: [nan], model: model, baseline: center, generation: 42) }
        print("Custom gestures: bounded front workspace, interpolated steps, reverse return, unmapped axes and non-finite values blocked")

        let start = model.positions(vendorLeft: center)
        let target = model.toolPosition(start)! + SIMD3(0.015, 0, 0.01)
        let solution = model.solveLeft(target: target, from: start, frontWorkspace: true)
        precondition(solution != nil && simd_distance(model.toolPosition(solution!)!, target) < 0.012)
        _ = try ROBLeftGestureCompiler.compile(kind: "custom", name: "XYZ goal", poses: [solution!], model: model,
            baseline: center, generation: 42)
        print("XYZ ghost target: numerical IK reaches the requested nearby model position without hardware transport")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-currents-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = "elapsed_s,sequence,robot_arm,gateway_arm,joint,position_rad,current_raw,current_delta_raw,feedback_age_ms,phase\n"
        var rows = (1...7).map { "1,10,left,right,\($0),0,0.2,\($0 == 3 ? 9 : 0),1,gesture step 0\n" }.joined()
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
        let recording = try ROBGhostRecordingSample.load(url)
        precondition(recording.count == 1 && recording[0].deltas[2] == 9 && recording[0].step == 0)
        rows += "2,11,left,right,1,0,0.2,0,1,gesture step 1\n"
        try (header + rows).write(to: url, atomically: true, encoding: .utf8)
        expectBlocked { _ = try ROBGhostRecordingSample.load(url) }
        try (header + rows.replacingOccurrences(of: ",0.2,", with: ",nan,")).write(to: url, atomically: true, encoding: .utf8)
        expectBlocked { _ = try ROBGhostRecordingSample.load(url) }
        print("Current replay: per-joint spike retained; incomplete and non-finite samples rejected instead of hidden")
        let object = ROBWorkspaceDetection(visible: true, confidence: 0.85, box: [0.3,0.3,0.7,0.7],
            aim: [0.5,0.5], depthPoint: [0.5,0.35])
        let absent = ROBWorkspaceDetection(visible: false, confidence: 0, box: [], aim: [], depthPoint: [])
        let observation = ROBWorkspaceObservation(can: object, orangeBucket: absent,
            leftArmHanging: true, rightArmHanging: false, hangingConfidence: 0.8)
        let observationJSON = String(data: try JSONEncoder().encode(observation), encoding: .utf8)!
        let decodedObservation = try ROBWorkspaceObservation.decode(observationJSON)
        precondition(decodedObservation.can.usable)
        let detectorCan = ROBWorkspaceDetection(visible: true, confidence: 0.576, box: [0.66,0.26,0.76,0.51],
            aim: [0.71,0.385], depthPoint: [0.71,0.385], confidenceThreshold: 0.35)
        precondition(detectorCan.usable, "A raw OWLv2 score must use the detector's threshold without inflating confidence")
        let redecodedCan = try JSONDecoder().decode(ROBWorkspaceDetection.self, from: JSONEncoder().encode(detectorCan))
        precondition(!redecodedCan.usable, "JSON must never set a lower native acceptance threshold")
        let bucketBoxOnly = ROBWorkspaceDetection(visible: true, confidence: 0.6, box: [0.1,0.2,0.6,0.8],
            aim: [], depthPoint: [], confidenceThreshold: 0.35)
        precondition(bucketBoxOnly.visuallyUsable && !bucketBoxOnly.usable, "A bucket rectangle cannot invent a rim/release position")
        var speech = ROBWorkspaceSearchSpeech()
        precondition(speech.confirmed([], targets: ROBWorkspaceTarget.allCases) == nil)
        precondition(speech.confirmed([.can], targets: ROBWorkspaceTarget.allCases) == "I see the can. I'm still looking for the bucket.")
        precondition(speech.confirmed([.can], targets: ROBWorkspaceTarget.allCases) == nil,
            "Repeated observations must not repeat a discovery announcement")
        precondition(speech.confirmed([.can, .orangeBucket], targets: ROBWorkspaceTarget.allCases) == "I see the bucket.")
        precondition(speech.confirmed([.orangeBucket], targets: ROBWorkspaceTarget.allCases) == nil)
        precondition(speech.confirmed([.can, .orangeBucket], targets: ROBWorkspaceTarget.allCases) == nil,
            "Refreshing an older target must not announce it again")
        var bucketFirst = ROBWorkspaceSearchSpeech()
        precondition(bucketFirst.confirmed([.orangeBucket], targets: ROBWorkspaceTarget.allCases) == "I see the bucket. I'm still looking for the can.")
        var together = ROBWorkspaceSearchSpeech()
        precondition(together.confirmed([.can, .orangeBucket], targets: ROBWorkspaceTarget.allCases) == "I see the can and bucket.")
        var canOnly = ROBWorkspaceSearchSpeech()
        precondition(canOnly.confirmed([.can, .orangeBucket], targets: [.can]) == "I see the can.")
        print("Search speech: can-first/bucket-first/simultaneous discoveries, requested targets only, no repeated prompts on later observations")
        let wrappedObservation = try ROBWorkspaceObservation.decode("Here is the observation:\n```JSON\n" + observationJSON + "\n```")
        precondition(wrappedObservation.can.usable)
        let bareFence = try ROBWorkspaceObservation.decode("```\n" + observationJSON + "\n```")
        precondition(bareFence.can.usable)
        expectBlocked { _ = try ROBWorkspaceObservation.decode(observationJSON + " move the motors") }
        expectBlocked { _ = try ROBWorkspaceObservation.decode(observationJSON + observationJSON) }
        expectBlocked { _ = try ROBWorkspaceObservation.decode(String(observationJSON.dropLast())) }
        expectBlocked { _ = try ROBWorkspaceObservation.decode(observationJSON.replacingOccurrences(of: "0.85", with: "1.85")) }
        let view = ROBWorkspaceView(panDegrees: 0, upperTarget: 6906)
        let recallDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("rob-recall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recallDirectory) }
        var recall = ROBWorkspaceRecall(modelID: model.modelID, geometryID: model.geometryID)
        let recallNow = Date().timeIntervalSince1970 * 1000
        recall.remember(target: .orangeBucket, detection: .init(visible: true, confidence: 0.6,
            box: [0.02,0.4,0.26,0.77], aim: [], depthPoint: [], confidenceThreshold: 0.35),
            view: .init(panDegrees: 15, upperTarget: 5650), capturedAt: recallNow)
        try recall.save(to: recallDirectory.appendingPathComponent("recall-v1.json"))
        let restarted = ROBWorkspaceRecall.load(model: model, directory: recallDirectory, now: recallNow)
        let recalledBucketViews = restarted.views(targets: [.orangeBucket], now: recallNow)
        precondition(restarted.sightings.count == 1 && recalledBucketViews.first!.panDegrees == 15 && recalledBucketViews.first!.upperTarget == 5650)
        precondition(recalledBucketViews.dropFirst().contains { $0.panDegrees > 35 })
        precondition(restarted.views(targets: [.can], now: recallNow).isEmpty)
        precondition(restarted.views(targets: [.orangeBucket], now: recallNow + 86_400_001).isEmpty)
        let mismatched = ROBWorkspaceRecall(modelID: "old-model", geometryID: model.geometryID, sightings: recall.sightings)
        try mismatched.save(to: recallDirectory.appendingPathComponent("recall-v1.json"))
        precondition(ROBWorkspaceRecall.load(model: model, directory: recallDirectory, now: recallNow).sightings.isEmpty)
        let ring = (0..<180).map { i -> SIMD3<Double> in
            let angle = Double(i)*2 * .pi/180
            return SIMD3(0.45+0.14*cos(angle),0.2+0.14*sin(angle),0.55)
        }
        let interior = (0..<50).map { i -> SIMD3<Double> in
            let angle = Double(i)*2 * .pi/50
            return SIMD3(0.45+0.03*cos(angle),0.2+0.03*sin(angle),0.30)
        }
        let fitted = ROBWorkspaceBucketRim.fit(orange: ring, scene: ring+interior)
        precondition(fitted != nil && simd_distance(fitted!.center, SIMD3(0.45,0.2,0.55)) < 0.005)
        precondition(ROBWorkspaceBucketRim.fit(orange: ring, scene: ring+interior.map { SIMD3($0.x,$0.y,0.55) }) == nil,
            "A solid orange lid was mistaken for an opening")
        precondition(ROBWorkspaceBucketRim.fit(orange: Array(ring.prefix(70)), scene: interior) == nil,
            "A partially observed rim was treated as a full release opening")
        let floorNormal = simd_normalize(SIMD3<Double>(-0.42,-0.09,0.90))
        let floorRotation = simd_quatd(from: SIMD3<Double>(0,0,1),to: floorNormal)
        let floorPoints = (0..<30).flatMap { x in (0..<30).map { y in
            floorRotation.act(SIMD3(Double(x)*0.03,Double(y)*0.03,-0.25))
        } }
        var camera = matrix_identity_double4x4; camera.columns.3 = SIMD4(0,0,1.07,1)
        let floorAlignment = ROBWorkspaceFloorAlignment.fit(points: floorPoints,cameraFrame: camera)
        precondition(floorAlignment != nil && (25...27).contains(floorAlignment!.correctionDegrees))
        precondition(floorAlignment!.supportFraction > 0.99)
        precondition(ROBWorkspaceFloorAlignment.fit(points: floorPoints.map { $0+SIMD3(0,0,0.8) },cameraFrame: camera) == nil,
            "A tabletop was accepted as the floor")
        print("Recall: durable per-model sighting hints, original successful camera view first then recentered view, expiry and no object-position reuse. Rim: measured circle plus recessed interior; lids and partial arcs rejected")
        var crossView = ROBWorkspaceLocationConfirmation()
        let measuredBucketA = ROBWorkspaceLocatedObject(target:.orangeBucket,
            position:[0.3164549455,0.4341462099,0.2781495990],confidence:0.526,
            capturedAt:1_792_716_357_126,sequence:3876,view:.init(panDegrees:31.8814,upperTarget:5557),openingRadius:0.09775845)
        let measuredBucketB = ROBWorkspaceLocatedObject(target:.orangeBucket,
            position:[0.3465006004,0.4511758391,0.2855762468],confidence:0.639,
            capturedAt:1_792_716_364_893,sequence:4109,view:.init(panDegrees:30,upperTarget:5650),openingRadius:0.09969289)
        precondition(crossView.observe(measuredBucketA) == nil)
        precondition(crossView.observe(measuredBucketB)?.sequence == 4109,
            "Live agreeing bucket measurements were lost when the neck changed views")
        crossView.invalidate(.orangeBucket)
        precondition(crossView.observe(measuredBucketB) == nil,"A refresh reused a previous confirmation")
        var inconsistentRadius = measuredBucketB
        inconsistentRadius = .init(target:.orangeBucket,position:measuredBucketB.position,confidence:0.8,
            capturedAt:measuredBucketB.capturedAt+1000,sequence:4110,view:measuredBucketB.view,openingRadius:0.2)
        precondition(crossView.observe(inconsistentRadius) == nil)
        var expired = ROBWorkspaceLocationConfirmation()
        precondition(expired.observe(measuredBucketA) == nil)
        let tooLate = ROBWorkspaceLocatedObject(target:.orangeBucket,position:measuredBucketB.position,confidence:0.8,
            capturedAt:measuredBucketA.capturedAt+30_001,sequence:5000,view:measuredBucketB.view,openingRadius:0.1)
        precondition(expired.observe(tooLate) == nil,"Historical measurements supplied a live pair")
        print("Cross-view bucket regression: actual fresh 3.53 cm agreement retained across neck views; refresh, radius mismatch and expired pairs rejected")
        precondition(ROBWorkspaceView.sweep.count == 32 && ROBWorkspaceView.sweep.contains { $0.upperTarget == 5300 })
        precondition(zip(ROBWorkspaceView.sweep, ROBWorkspaceView.sweep.dropFirst()).allSatisfy { abs($0.panDegrees - $1.panDegrees) <= 15 },
            "Search must inspect intermediate views rather than jumping between distant sides")
        func ground(_ depth: @escaping (Int,Int) -> UInt16?) -> ROBWorkspaceLocatedObject? {
            ROBWorkspaceGrounding.locate(target: .can, detection: object, width: 640, height: 480,
                fx: 500, fy: 500, cx: 319.5, cy: 239.5, depth: depth,
                view: view, model: model, capturedAt: 1000, sequence: 1)
        }
        let located = ground { _,_ in 700 }!
        let frame = view.cameraFrame(model: model)!
        let expected = frame * SIMD4<Double>(0,0,0.7,1)
        precondition(simd_distance(located.point, SIMD3(expected.x,expected.y,expected.z)) < 1e-8)
        precondition(ground { _,_ in nil } == nil)
        precondition(ground { x,_ in x % 2 == 0 ? 700 : 1800 } == nil,
            "Mixed foreground/background depth was accepted")
        let confirmed = ROBWorkspaceLocatedObject(target: .can, position: located.position, confidence: 0.8,
            capturedAt: 1500, sequence: 2, view: view)
        precondition(located.agrees(with: confirmed) && !located.agrees(with: located))
        let changedObject = ROBWorkspaceLocatedObject(target: .can, position: [10,10,10], confidence: 0.8,
            capturedAt: 1500, sequence: 2, view: view)
        precondition(!located.agrees(with: changedObject))
        let hint = ROBWorkspacePointingHint(x: 0.65, y: 0.5, dx: 0.15, dy: 0, distanceMeters: 1)
        precondition(hint.agrees(with: hint) && hint.guidedView(from: view).panDegrees < 0)
        let guidedViews = hint.searchViews(from: view, boundedPan: { max(-40, min(40, $0)) })
        precondition(guidedViews.count >= 6 && guidedViews.allSatisfy { (-40...40).contains($0.panDegrees) && (5300...7500).contains($0.upperTarget) })
        precondition(Set(guidedViews.map(\.upperTarget)).count >= 3, "Pointing must search a neighborhood of heights")
        precondition(!hint.agrees(with: .init(x: 0.65, y: 0.5, dx: -0.15, dy: 0, distanceMeters: 1)))
        let previewNow = Date().timeIntervalSince1970 * 1000
        let previewHand = model.toolPosition(model.positions(vendorLeft: center))!
        let previewCan = ROBWorkspaceLocatedObject(target: .can, position: [previewHand.x, previewHand.y, previewHand.z], confidence: 0.8,
            capturedAt: previewNow, sequence: 71, view: view)
        let grabPreview = try ROBCanGrabPreview.make(can: previewCan, model: model, baseline: model.reference, now: previewNow)
        let recycleBucket = ROBWorkspaceLocatedObject(target: .orangeBucket,
            position: [previewHand.x,previewHand.y+0.08,previewHand.z-0.10], confidence: 0.8,
            capturedAt: previewNow, sequence: 74, view: view, openingRadius: 0.14)
        let recycling = try ROBCanGrabPreview.make(can: previewCan, model: model, baseline: model.positions(vendorLeft: zero),
            now: previewNow, bucket: recycleBucket)
        let recyclingActions = Dictionary(uniqueKeysWithValues: recycling.steps.enumerated().compactMap { index, step in step.jawAction.map { (index,$0) } })
        let physicalRecycle = try ROBLeftGestureCompiler.compile(kind: "recycling", name: "Horizontal recycling", poses: recycling.steps.map(\.pose),
            model: model, baseline: zero, generation: 42, recyclingActions: recyclingActions)
        try ROBLeftGestureCompiler.validate(physicalRecycle, model: model)
        precondition(physicalRecycle.steps.compactMap(\.jawAction) == [.prepare,.grip,.release])
        precondition(physicalRecycle.steps.contains { abs($0.positions[6]) > 0.2 }, "Horizontal jaws require the reviewed wrist roll")
        var altered = physicalRecycle; altered.recyclingActions = [:]
        expectBlocked { try ROBLeftGestureCompiler.validate(altered, model: model) }
        precondition(physicalRecycle.steps.count <= 80 && physicalRecycle.seconds <= 135)
        let stopIndex = physicalRecycle.steps.firstIndex { $0.jawAction == .grip }! + 3
        let recorded = physicalRecycle.steps.enumerated().prefix(stopIndex+1).map { index, step in
            ROBGhostRecordingSample(time:Double(index),positions:step.positions,currents:[Double](repeating:0.2,count:7),
                deltas:[Double](repeating:0,count:7),step:index)
        }
        let stoppedQ = zip(physicalRecycle.steps[stopIndex-1].positions,physicalRecycle.steps[stopIndex].positions).map { ($0+$1)/2 }
        let recovery = try ROBRecordedLeftRecovery.make(previous:physicalRecycle,samples:recorded,measured:stoppedQ,model:model,generation:43)
        precondition(recovery.kind == "recover" && recovery.sessionGeneration == 43 && recovery.baseline == stoppedQ)
        precondition(recovery.steps.first!.positions == physicalRecycle.steps[stopIndex-1].positions && recovery.steps.last!.positions == center)
        precondition(recovery.steps.allSatisfy { $0.jawAction == nil }, "A recorded empty return must never replay gripper actions")
        expectBlocked { _ = try ROBRecordedLeftRecovery.make(previous:physicalRecycle,samples:recorded,measured:[Double](repeating:2.8,count:7),model:model,generation:43) }
        expectBlocked { _ = try ROBRecordedLeftRecovery.make(previous:physicalRecycle,samples:[],measured:stoppedQ,model:model,generation:43) }
        let calibrationURL = recallDirectory.appendingPathComponent("can-calibration.json")
        let missingCorrection = try ROBLeftCanReachCalibration.load(model:model,file:calibrationURL)
        precondition(missingCorrection == .zero)
        let calibration = ROBLeftCanReachCalibration(modelID:model.modelID,referenceID:model.referenceID,mappingID:ROBGhostRobotModel.mappingID,
            translationMeters:[-0.127,0,0],source:"Isolated operator-measurement fixture")
        try calibration.saveFixture(to:calibrationURL)
        let correction = try ROBLeftCanReachCalibration.load(model:model,file:calibrationURL)
        precondition(correction == SIMD3<Double>(-0.127,0,0))
        let observedCan = ROBWorkspaceLocatedObject(target:.can,position:[0.5476,-0.0659,0.8759],confidence:0.7,
            capturedAt:previewNow,sequence:81,view:view)
        let correctedReach = try ROBCanGrabPreview.make(can:observedCan,model:model,baseline:model.positions(vendorLeft:zero),
            now:previewNow,reachOffset:correction)
        precondition(correctedReach.can.position == observedCan.position && correctedReach.reachesCan)
        precondition(abs(correctedReach.calibratedGraspPoint.x-0.4206) < 0.00001)
        let wrongCalibration = ROBLeftCanReachCalibration(modelID:"wrong",referenceID:model.referenceID,mappingID:ROBGhostRobotModel.mappingID,
            translationMeters:[-0.127,0,0],source:"Invalid fixture")
        try wrongCalibration.saveFixture(to:calibrationURL)
        expectBlocked { _ = try ROBLeftCanReachCalibration.load(model:model,file:calibrationURL) }
        print("Recorded recovery: exact executed prefix only, fresh baseline/new session, reverse to front with no jaw replay; operator reach correction leaves raw sightings intact and rejects mismatched models")
        let dropIndex = recycling.steps.firstIndex { $0.jawAction == .release }!
        let dropPoint = model.toolPosition(recycling.steps[dropIndex].pose)!
        precondition(dropPoint.z >= previewCan.point.z + 0.08 && dropPoint.z > recycleBucket.point.z + 0.12,
            "A floor bucket must use a high gravity drop instead of requiring a low hand pose")
        precondition(hypot(dropPoint.x-recycleBucket.point.x,dropPoint.y-recycleBucket.point.y) < recycleBucket.openingRadius!-0.05)
        print("Physical horizontal recycling: same seven-joint ghost approach, grip/lift/carry/release/retreat, bounded wrist mapping and exact immutable jaw transitions")
        precondition(grabPreview.side == "left" && grabPreview.reachesCan && grabPreview.graspError <= 0.012)
        precondition(grabPreview.gripperTiltDegrees <= 5, "A successful grasp requires horizontal approach and jaw axes")
        precondition(grabPreview.helpRequest == nil, "A reachable can must not trigger a move-closer request")
        precondition(grabPreview.steps.contains { $0.stage == "Close jaws (simulation)" })
        precondition(grabPreview.steps.allSatisfy { step in
            model.joints.filter { !$0.name.hasPrefix("left_joint") }.allSatisfy { step.pose[$0.name] == model.reference[$0.name] }
        }, "Can rehearsal must keep the other arm and body at their starting pose")
        expectBlocked { _ = try ROBCanGrabPreview.make(can: previewCan, model: model, baseline: model.reference, now: previewNow + 60_001) }
        expectBlocked { _ = try ROBCanGrabPreview.make(can: .init(target: .can, position: [.nan,0,0], confidence: 0.8,
            capturedAt: previewNow, sequence: 72, view: view), model: model, baseline: model.reference, now: previewNow) }
        let rightCan = ROBWorkspaceLocatedObject(target: .can, position: [0.589,-0.300,0.873], confidence: 0.6,
            capturedAt: previewNow, sequence: 73, view: view)
        let rightPreview = try ROBCanGrabPreview.make(can: rightCan, model: model, baseline: model.reference, side: "right", now: previewNow)
        precondition(rightPreview.side == "right")
        precondition(rightPreview.reachesCan || !rightPreview.steps.contains { $0.stage.contains("simulation") }, "An unreachable can must not appear gripped or lifted")
        let crossBody = try ROBCanGrabPreview.make(can: rightCan, model: model, baseline: model.reference, now: previewNow)
        precondition(crossBody.graspError > 0.012 && crossBody.helpRequest == "Please bring the can closer.")
        let tiltOnly = ROBCanGrabPreview(can: previewCan, side: "left", baseline: model.reference,
            steps: [], graspError: 0.001, gripperTiltDegrees: 15, reachesCan: false)
        precondition(tiltOnly.helpRequest == nil, "A wrist orientation problem must not be described as a distant can")
        precondition(crossBody.side == "left" && crossBody.steps.allSatisfy { step in
            model.joints.filter { $0.name.hasPrefix("right_joint") }.allSatisfy { step.pose[$0.name] == model.reference[$0.name] }
        }, "A can on the right must still use the operator-selected left arm when the table blocks the right")
        print(String(format: "Can ghost: selected left cross-body reach, unchanged right arm, explicit clearance uncertainty; grasp gap %.1f mm; stale/invalid targets and false grip/lift rejected", crossBody.graspError * 1000))
        print("Local search: typed observations, calibrated depth projection, distinct-frame confirmation and pointing direction; missing/mixed depth and invalid facts rejected")

        let hand = model.toolPosition(model.positions(vendorLeft: center))!
        let can = ROBWorkspaceLocatedObject(target: .can, position: [hand.x,hand.y,hand.z], confidence: 0.9,
            capturedAt: 1000, sequence: 1, view: view)
        let bucket = ROBWorkspaceLocatedObject(target: .orangeBucket, position: [hand.x,hand.y + 0.08,hand.z - 0.10],
            confidence: 0.9, capturedAt: 1500, sequence: 2, view: view)
        let task = try ROBWorkspaceGrounding.task(can: can, bucket: bucket, model: model)
        let farCan = ROBWorkspaceLocatedObject(target: .can, position: [10,0,1], confidence: 0.9,
            capturedAt: 1000, sequence: 1, view: view)
        let farBucket = ROBWorkspaceLocatedObject(target: .orangeBucket, position: [10,0,1], confidence: 0.9,
            capturedAt: 1500, sequence: 2, view: view)
        do {
            _ = try ROBWorkspaceGrounding.task(can: farCan, bucket: bucket, model: model)
            preconditionFailure("Unreachable pickup was accepted")
        } catch let error as ROBWorkspaceReachError {
            precondition(error.helpRequest == "Please bring the can closer.")
        }
        do {
            _ = try ROBWorkspaceGrounding.task(can: can, bucket: farBucket, model: model)
            preconditionFailure("Unreachable bucket was accepted")
        } catch let error as ROBWorkspaceReachError {
            precondition(error.helpRequest == "Please bring the bucket closer.",
                "An unreachable bucket must not ask the human to move the can")
        }
        let tabletop = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: task.name, poses: task.poses,
            model: model, baseline: zero, generation: 42)
        try ROBLeftGestureCompiler.validate(tabletop, model: model)
        precondition(tabletop.steps.compactMap(\.jawAction) == [.prepare,.grip,.release])
        precondition(tabletop.steps.prefix(5).map(\.positions) == centerStops.map { ROBLeftArmInteractionPlan.waypoints[$0] })
        precondition(tabletop.steps.last!.stage == "Retreat")
        var tamperedSteps = tabletop.steps; tamperedSteps[0].jawAction = .grip
        let tampered = ROBLeftGestureProposal(id: tabletop.id, name: tabletop.name, kind: tabletop.kind,
            modelID: tabletop.modelID, referenceID: tabletop.referenceID, geometryID: tabletop.geometryID,
            mappingID: tabletop.mappingID, sessionGeneration: 42, baseline: zero, poses: tabletop.poses, steps: tamperedSteps)
        expectBlocked { try ROBLeftGestureCompiler.validate(tampered, model: model) }
        expectBlocked { _ = try ROBLeftGestureCompiler.compile(kind: "tabletop", name: "Incomplete", poses: Array(task.poses.prefix(4)),
            model: model, baseline: zero, generation: 42) }
        print("Recycling plan: observed can/bucket → local IK → five-anchor route, five-segment presentation, exact prepare/grip/release boundaries and tamper rejection")
        print("Ghost motion plan fixtures passed; model preview assumptions are not physical calibration")
    }
}
