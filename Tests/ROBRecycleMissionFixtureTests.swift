import Foundation

@main struct ROBRecycleMissionFixtureTests {
    static func main() throws {
        func check(_ condition: @autoclosure () throws -> Bool,_ detail: String) throws {
            if try !condition() { throw NSError(domain:"RecycleMissionFixture",code:1,userInfo:[NSLocalizedDescriptionKey:detail]) }
        }
        var request=ROBRecycleMissionMessage(kind:.start,missionID:UUID(),sequence:1,
            sentAtMilliseconds:1_000_000,configuration:.init())
        try check(ROBRecycleMissionMessage.decode(request.encoded()!)==request,"mission wire round trip")
        request.configuration.destination="trash_can"
        try check(request.encoded()==nil,"unsupported destination accepted")
        request.configuration = .init();request.configuration.radiusMeters = .infinity
        try check(request.encoded()==nil,"nonfinite room radius")
        request.configuration = .init();request.configuration.maximumTreadDemand=0.9
        try check(request.encoded()==nil,"unbounded tread demand")
        try check(ROBRecycleMissionMessage.decode(Data("ROBRecycleMission.v2\n{}".utf8))==nil,"future protocol decoded")

        let epoch=UUID(),device=UUID(),now=1_000_000.0
        var cells=Data(repeating:127,count:40_000)
        cells[2_000]=128 // signed negative occupied cell
        func fragment(_ offset:Int,revision:UInt64=1,origin:Double=0,time:Double=now)->ROBRoomMapFragment {
            .init(epoch:epoch,revision:revision,capturedAtMilliseconds:time,width:200,height:200,
                  resolutionX:0.05,resolutionY:0.05,originX:origin,originY:0,offset:offset,
                  cells:cells.subdata(in:offset..<min(cells.count,offset+20_000)))
        }
        var assembler=ROBRoomMapAssembler()
        try check(assembler.consume(fragment(20_000),device:device,now:now)==nil,"partial map exposed")
        let complete=assembler.consume(fragment(0),device:device,now:now)
        try check(complete?.cells==cells,"out-of-order grid fragments not reassembled")
        assembler=ROBRoomMapAssembler()
        _=assembler.consume(fragment(0),device:device,now:now)
        try check(assembler.consume(fragment(20_000,revision:2),device:device,now:now)==nil,"mixed revisions")
        try check(assembler.consume(fragment(0,revision:2,origin:1),device:device,now:now)==nil,"mixed map geometry")
        assembler=ROBRoomMapAssembler()
        _=assembler.consume(fragment(0),device:device,now:now)
        try check(assembler.consume(fragment(20_000),device:UUID(),now:now)==nil,"mixed publishers")
        try check(assembler.consume(fragment(0,time:now-16_000),device:device,now:now)==nil,"stale map accepted")
        let f=fragment(0)
        try check(try ROBRoomMapFragment.decode(f.encoded())==f,"map fragment round trip")

        // A solid wall splits the room. A too-narrow door must remain blocked
        // after full-envelope inflation; unknown cells cannot bridge the wall.
        var grid=Data(repeating:127,count:100*100)
        for y in 0..<100 { grid[y*100+50]=128 }
        for y in 48...52 { grid[y*100+50]=0 }
        func map(_ bytes:Data)->ROBRoomMissionMap {
            .init(epoch:epoch,revision:1,capturedAtMilliseconds:now,width:100,height:100,
                  resolutionX:0.1,resolutionY:0.1,originX:-5,originY:-5,cells:bytes)
        }
        let start=ROBRoomMissionPoint(x:-2,y:0),goal=ROBRoomMissionPoint(x:2,y:0)
        var planner=ROBRoomMissionPlanner(map:map(grid),clearanceMeters:0.3,origin:start,radius:8)!
        try check(planner.path(from:start,to:goal)==nil,"route crossed occupied/unknown wall")
        for y in 48...52 { grid[y*100+50]=127 }
        planner=ROBRoomMissionPlanner(map:map(grid),clearanceMeters:0.3,origin:start,radius:8)!
        try check(planner.path(from:start,to:goal)==nil,"robot fitted through undersized door")
        for y in 42...58 { grid[y*100+50]=127 }
        planner=ROBRoomMissionPlanner(map:map(grid),clearanceMeters:0.3,origin:start,radius:8)!
        let route=planner.path(from:start,to:goal)!
        try check(route.allSatisfy(planner.isFree),"route included blocked inflated cell")
        try check(route.last!.distance(to:goal)<0.1,"route ended at wrong metric location")
        let exploration=planner.path(from:start,excluding:[start])!
        try check(exploration.last!.distance(to:start)>=0.8,"search repeated visited station")
        let confined=ROBRoomMissionPlanner(map:map(grid),clearanceMeters:0.3,origin:start,radius:1)!
        try check(confined.path(from:start,to:goal)==nil,"route escaped authorized radius")

        // The selected can drives the next stop, with a final base heading
        // that places it at the taught right-gripper offset. Unknown remains
        // blocked, even if a candidate itself would be kinematically suitable.
        let open = ROBRoomMissionPlanner(map:map(Data(repeating:127,count:10_000)),clearanceMeters:0.3,origin:start,radius:8)!
        let offset=ROBRoomMissionPoint(x:0.5,y:-0.25)
        let approach=open.canApproach(from:start,yaw:0,can:goal,preferredOffset:offset)!
        try check(approach.route.first==start && approach.route.allSatisfy(open.isFree),"can approach lost its measured start or floor corridor")
        let dx=goal.x-approach.goal.x,dy=goal.y-approach.goal.y,c=cos(approach.baseYaw),s=sin(approach.baseYaw)
        try check(hypot(c*dx+s*dy-offset.x,-s*dx+c*dy-offset.y)<0.08,"final yaw did not put the can beside the ready gripper")
        try check(approach.distance>2 && approach.distance<4.5,"can approach wandered to an unrelated survey stop")
        try check(confined.canApproach(from:start,yaw:0,can:goal,preferredOffset:offset)==nil,"approach escaped the mission radius")
        try check(open.canApproach(from:start,yaw:.nan,can:goal,preferredOffset:offset)==nil,"invalid alignment produced a base route")

        try check(ROBRecycleMissionOutcome.classify(["status":"accepted_unverified","motion_completed":true,
            "batch_completed":8]) == .hold(possiblePayload:true),"legacy path count credited as recycling")
        try check(ROBRecycleMissionOutcome.classify(["placement_verified":true,"transfer_completed":true]) != .verifiedTransfer,
            "placement without empty-jaw evidence credited")
        try check(ROBRecycleMissionOutcome.classify(["placement_verified":true,"transfer_completed":true,"empty_verified":true,"possible_payload_held":true]) != .verifiedTransfer,
            "contradictory payload evidence credited")
        try check(ROBRecycleMissionOutcome.classify(["placement_verified":true,"transfer_completed":true,"empty_verified":true]) == .verifiedTransfer,
            "verified transfer not accepted")
        try check(ROBRecycleMissionOutcome.classify(["status":"not_reachable","arm_motion_sent":false,"jaw_command_sent":false]) == .emptyPerceptionMiss,
            "safe perception miss did not permit another observation stop")
        try check(ROBRecycleMissionOutcome.classify(["status":"not_reachable","arm_motion_sent":false,"jaw_command_sent":NSNull()]) == .hold(possiblePayload:true),
            "uncertain jaw dispatch permitted base search")

        // Actual scan codec with an embedded SDK map fragment. V1 remains
        // byte-compatible; V2 still obeys the local IPC 64 KiB payload ceiling.
        let points=(0..<16).map { ROBLidarWirePoint(distanceMeters:1,angleRadians:Float($0)*0.3) }
        var scan=ROBLidarScanFrame(deviceID:device,sequence:1,sentAtMilliseconds:1_000_000,
            x:1,y:2,z:0,yaw:0,pitch:0,roll:0,points:points)
        let v1=try scan.encoded()
        try check(v1[4]==1 && (try ROBLidarScanFrame.decode(v1)).mapFragment==nil,"v1 scan changed")
        scan.mapFragment=f
        let v2=try scan.encoded(),decoded=try ROBLidarScanFrame.decode(v2)
        try check(v2[4]==2 && decoded.mapFragment==f && v2.count<65_536,"map scan codec")
        var damaged=v2;damaged.removeLast()
        do { _=try ROBLidarScanFrame.decode(damaged);throw NSError(domain:"Fixture",code:2) }
        catch is ROBLidarTelemetryEncodingError {} catch is DecodingError {} catch is ROBRoomMapError {}
        try check(decoded.validationError(authenticatedDeviceID:device,lastAcceptedSequence:1,nowMilliseconds:1_000_000) != nil,"map scan replay accepted")
        print("Recycle mission fixtures passed: wire, map assembly, routes, unknown space, verified outcomes and replay")
    }
}
