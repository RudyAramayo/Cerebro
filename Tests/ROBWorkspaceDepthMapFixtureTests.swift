import Foundation
import simd

@main struct ROBWorkspaceDepthMapFixtures {
    static func expect(_ value: @autoclosure () -> Bool, _ detail: String) {
        precondition(value(),detail)
    }
    static func rejected(_ detail: String, _ block: () throws -> Void) {
        do { try block(); fatalError(detail) } catch {}
    }
    static func main() throws {
        let camera = UUID(), now = 10_000.0
        func make() -> ROBWorkspaceDepthMap {
            .init(modelID:"model",geometryID:"geometry",mappingID:"mapping",sessionGeneration:7,
                cameraGeneration:camera,nowMilliseconds:now)
        }
        func append(_ map: inout ROBWorkspaceDepthMap, sequence:UInt64, millimeters:UInt16 = 1000,
                    transform:simd_double4x4 = matrix_identity_double4x4,
                    hole:Bool = false, selfBounds:[(low:SIMD3<Double>,high:SIMD3<Double>)] = [], verified:Bool = false) throws {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,
                depth:{ x,y in hole && (10...22).contains(x) && (6...18).contains(y) ? nil : millimeters },
                cameraToRobot:transform,capturedAtMilliseconds:now+Double(sequence),sequence:sequence,
                cameraGeneration:camera,nowMilliseconds:now+Double(sequence)+1,
                measuredSelfBounds:selfBounds,cameraRegistrationVerified:verified)
        }
        var map = make()
        try append(&map,sequence:1)
        expect(map.snapshot(nowMilliseconds:now+2) == nil,"One frame became a confirmed map")
        try append(&map,sequence:2)
        let snapshot = map.snapshot(nowMilliseconds:now+3)!
        expect(snapshot.observedFrameCount == 2,"Distinct frame count was lost")
        expect(snapshot.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Depth surface was not occupied")
        expect(snapshot.state(at:SIMD3(0.01,0.01,0.5)) == .free,"Observed space before a stable surface was not free")
        expect(snapshot.state(at:SIMD3(0.01,0.01,1.3)) == .unknown,"Space behind a return became free")
        expect(snapshot.state(at:SIMD3(1.8,1.8,0.5)) == .unknown,"Unobserved space became free")
        expect(snapshot.registrationID == nil && snapshot.registrationUncertaintyMeters == nil,"A neck-command prior became calibrated hand-eye evidence")
        expect(snapshot.fingerprint.count == 64 && snapshot.fingerprint == map.snapshot(nowMilliseconds:now+3)!.fingerprint,"Immutable map fingerprint was not deterministic")
        try append(&map,sequence:3,millimeters:2000)
        expect(map.snapshot(nowMilliseconds:now+4)!.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Later rays cleared a previously occupied obstacle")
        expect(map.snapshot(nowMilliseconds:now+4)!.fingerprint != snapshot.fingerprint,"Map content change retained its fingerprint")
        rejected("Reordered camera frame was accepted") { try append(&map,sequence:2) }
        rejected("Camera generation change retained transformed evidence") {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+4,sequence:4,
                cameraGeneration:UUID(),nowMilliseconds:now+5)
        }
        rejected("Stale camera frame was accepted") {
            try map.append(width:32,height:24,fx:30,fy:30,cx:16,cy:12,depth:{_,_ in 1000},
                cameraToRobot:matrix_identity_double4x4,capturedAtMilliseconds:now+4,sequence:4,
                cameraGeneration:camera,nowMilliseconds:now+1000)
        }
        var holes = make()
        try append(&holes,sequence:1,hole:true); try append(&holes,sequence:2,hole:true)
        expect(holes.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,0.5)) == .unknown,"Missing depth carved free space")
        var moved = make(), transform = matrix_identity_double4x4
        transform.columns.3.x = 0.5
        try append(&moved,sequence:1,transform:transform); try append(&moved,sequence:2,transform:transform)
        expect(moved.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.51,0.01,1)) == .occupied,"Recorded camera transform was ignored")
        let hulls = [(low:SIMD3<Double>(-0.3,-0.3,0.8),high:SIMD3<Double>(0.3,0.3,1.2))]
        var priorSelf = make()
        try append(&priorSelf,sequence:1,selfBounds:hulls); try append(&priorSelf,sequence:2,selfBounds:hulls)
        expect(priorSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1)) == .occupied,"Unregistered self mask erased a possible table")
        var measuredSelf = make()
        try append(&measuredSelf,sequence:1,selfBounds:hulls,verified:true)
        try append(&measuredSelf,sequence:2,selfBounds:hulls,verified:true)
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1)) == .unknown,"Measured self depth was treated as free space")
        expect(measuredSelf.snapshot(nowMilliseconds:now+3)!.state(at:SIMD3(0.01,0.01,1.3)) == .unknown,"Self occlusion cleared space behind the arm")
        print("Depth-map fixtures passed: fresh identities and frames, occupied/free/unknown ray semantics, holes/occlusion, transform provenance, immutable fingerprint and no provisional hand-eye promotion")
    }
}
