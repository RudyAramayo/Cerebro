import Foundation
import simd

@main struct FixedHeadRegistrationFixtures {
    static func rejected(_ detail:String,_ block:()throws->Void) {
        do {try block();fatalError(detail)} catch {}
    }
    static func scope(pan:Int=6000,camera:UUID=UUID(),session:UInt64=7,display:String="display",mapping:String="mapping")->ROBFixedHeadRegistrationScope {
        .init(modelID:"model",geometryID:"geometry",mappingID:mapping,cameraGeneration:camera,
            gatewaySessionGeneration:session,displayCorrectionIdentity:display,panTarget:pan,
            lowerTarget:6011,upperTarget:6906,intrinsicsIdentity:"intrinsics-32x24")
    }
    static func input(scope:ROBFixedHeadRegistrationScope, transform:simd_double4x4=matrix_identity_double4x4,
                      validationOffset:SIMD3<Double> = .zero, cameraUncertainty:Double=0.002,
                      referenceUncertainty:Double=0.002)->ROBFixedHeadRegistrationInput {
        let fit:[SIMD3<Double>]=[-0.2,0.2].flatMap {x in [-0.2,0.2].flatMap {y in [0.8,1.2].map {z in SIMD3(x,y,z)}}}
        let validation:[SIMD3<Double>]=[SIMD3(-0.3,-0.1,1.0),SIMD3(0.3,-0.1,1.0),SIMD3(0.0,0.3,1.1)]
        let samples=(fit+validation).enumerated().map {index,p ->ROBFixedHeadRegistrationSample in
            let isValidation=index>=fit.count, transformed=transform*SIMD4(p,1)
            let robot=SIMD3(transformed.x,transformed.y,transformed.z)+(isValidation ? validationOffset:.zero)
            return .init(landmarkID:"landmark-\(index)",captureID:isValidation ? "validation-\(index%2)":"training",frameSequence:UInt64(isValidation ? 2+index%2:1),capturedAtMilliseconds:isValidation ? 10002+Double(index%2):10000,
                evidenceSHA256:String(repeating:isValidation ? "b":"a",count:64),referenceSource:"measured_robot_landmark",cameraMeters:[p.x,p.y,p.z],robotMeters:[robot.x,robot.y,robot.z],
                cameraUncertaintyMeters:cameraUncertainty,referenceUncertaintyMeters:referenceUncertainty,validationOnly:isValidation)
        }
        let center=transform*SIMD4<Double>(0,0,0.75,1)
        return .init(schemaVersion:1,scope:scope,validRobotVolume:.init(lowMeters:[center.x-0.5,center.y-0.5,center.z-0.7],highMeters:[center.x+0.5,center.y+0.5,center.z+0.7]),samples:samples)
    }
    static func changed(_ input:ROBFixedHeadRegistrationInput, _ edit:([String:Any])->[String:Any])throws->ROBFixedHeadRegistrationInput {
        let value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(input)) as! [String:Any]
        return try JSONDecoder().decode(ROBFixedHeadRegistrationInput.self,from:JSONSerialization.data(withJSONObject:edit(value)))
    }
    static func main() throws {
        if CommandLine.arguments.count == 2 {
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
            let fit=try ROBFixedHeadRegistration.fit(JSONDecoder().decode(ROBFixedHeadRegistrationInput.self,from:data))
            print(String(format:"Measured correspondence interchange passed: fit %.3f mm, heldout %.3f mm, allowance %.3f mm",fit.fitRMSEMeters*1000,fit.validationRMSEMeters*1000,fit.uncertaintyMeters*1000))
            return
        }
        func basePacket(_ fields:[String])->String {"~"+fields.joined(separator:",")}
        let zeroFields=Array(repeating:"+0000",count:7)
        precondition(!ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(basePacket(zeroFields)))
        precondition(!ROBFixedHeadBodyMotionIdentity.baseCommandMayMove("~+0001,+0000,+0001,+0000,+0001,+0000,+0000"))
        precondition(!ROBFixedHeadBodyMotionIdentity.baseCommandMayMove("~-0001,-0000,+0001,-0000,+0001,-0000,-0000"))
        for field in [1,3,5,6] {
            for value in [-9999,-3200,-255,-100,-1,0,1,100,255,3200,9999] {
                var fields=zeroFields;fields[field]=String(format:"%+05d",value)
                precondition(ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(basePacket(fields)) == (value != 0))
            }
        }
        for field in [0,2,4] {
            var fields=zeroFields;fields[field]="-0001"
            precondition(!ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(basePacket(fields)))
        }
        for text in ["", "ping", "status?", " +0000", "debug ~+0000", "~".replacingOccurrences(of:"~",with:"～")] {
            precondition(!ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(text))
        }
        let neutral=basePacket(zeroFields)
        let malformed=["~",neutral+"\n",neutral+"\0",neutral+",+0000",String(neutral.dropLast()),
            neutral.replacingOccurrences(of:"+0000",with:"0000"),
            neutral.replacingOccurrences(of:"+0000",with:"+00000"),
            neutral.replacingOccurrences(of:"+0000",with:"+00x0"),
            neutral.replacingOccurrences(of:"+0000",with:"+٠٠٠٠"),
            neutral.replacingOccurrences(of:",",with:";"),
            neutral.replacingOccurrences(of:"+0000",with:" 0000"),
            "~+0000,+0000,+0000,+0000,+0000,+0000,nan"]
        for text in malformed {precondition(ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(text))}
        let identityBeforeParsing=ROBFixedHeadBodyMotionIdentity.currentIdentity
        for text in [neutral]+malformed {_=ROBFixedHeadBodyMotionIdentity.baseCommandMayMove(text)}
        precondition(ROBFixedHeadBodyMotionIdentity.currentIdentity==identityBeforeParsing,"Read-only command classification changed the body epoch")
        let current=scope(),raw=input(scope:current),fit=try ROBFixedHeadRegistration.fit(raw)
        precondition(fit.trainingCount==8 && fit.validationCount==3)
        precondition(fit.validationRMSEMeters<1e-9 && fit.uncertaintyMeters>=0.004 && fit.uncertaintyMeters<0.00401)
        let repeatFit=try ROBFixedHeadRegistration.fit(raw)
        precondition(fit.id == repeatFit.id)
        precondition(fit.matches(current) && !fit.matches(scope(pan:6001,camera:current.cameraGeneration)))
        precondition(!fit.matches(scope(camera:UUID())))
        precondition(!fit.matches(scope(camera:current.cameraGeneration,session:8)))
        precondition(!fit.matches(scope(camera:current.cameraGeneration,display:"changed")))
        precondition(!fit.matches(scope(camera:current.cameraGeneration,mapping:"other-arm")))
        for angle in [Double.pi/2,Double.pi] {
            var transform=simd_matrix4x4(simd_quatd(angle:angle,axis:SIMD3<Double>(0,0,1)))
            transform.columns.3=SIMD4(0.3,-0.2,0.1,1)
            let rotated=try ROBFixedHeadRegistration.fit(input(scope:current,transform:transform))
            for c in 0..<4 {for r in 0..<4 {precondition(abs(rotated.cameraToRobot[c][r]-transform[c][r])<1e-8)}}
        }
        _=try fit.project(SIMD3(0,0,1),scope:current)
        rejected("Scope drift projected") {_=try fit.project(SIMD3(0,0,1),scope:scope(pan:6001,camera:current.cameraGeneration))}
        rejected("Unvalidated extrapolation projected") {_=try fit.project(SIMD3(3,0,1),scope:current)}
        rejected("Heldout residuals participated in training") {_=try ROBFixedHeadRegistration.fit(input(scope:current,validationOffset:SIMD3(0.08,0,0)))}
        rejected("Declared systematic reference error disappeared") {_=try ROBFixedHeadRegistration.fit(input(scope:current,referenceUncertainty:0.049))}
        let reflection=try changed(raw) {value in
            var value=value;var samples=value["samples"] as! [[String:Any]]
            for i in samples.indices {var p=samples[i]["robotMeters"] as! [Double];p[0] = -p[0];samples[i]["robotMeters"]=p}
            value["samples"]=samples;return value
        }
        rejected("Improper reflection accepted") {_=try ROBFixedHeadRegistration.fit(reflection)}
        let planar=try changed(raw) {value in
            var value=value;var samples=value["samples"] as! [[String:Any]]
            for i in samples.indices {for name in ["cameraMeters","robotMeters"] {var p=samples[i][name] as! [Double];p[2]=1;samples[i][name]=p}}
            value["samples"]=samples;return value
        }
        rejected("Flat-plane-only frame was promoted") {_=try ROBFixedHeadRegistration.fit(planar)}
        let leakage=try changed(raw) {value in
            var value=value;var samples=value["samples"] as! [[String:Any]]
            samples[8]["captureID"]="training";value["samples"]=samples;return value
        }
        rejected("Heldout capture reused training capture") {_=try ROBFixedHeadRegistration.fit(leakage)}
        let duplicate=try changed(raw) {value in
            var value=value;var samples=value["samples"] as! [[String:Any]]
            samples[8]["cameraMeters"]=samples[0]["cameraMeters"];samples[8]["robotMeters"]=samples[0]["robotMeters"]
            value["samples"]=samples;return value
        }
        rejected("Spatial duplicate renamed as validation") {_=try ROBFixedHeadRegistration.fit(duplicate)}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("fixed-head-fixture-\(UUID())")
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=ROBFixedHeadRegistrationStore(directory:directory)
        try store.install(raw)
        precondition(store.resolve(scope:current)?.id==fit.id)
        let url=directory.appendingPathComponent(fit.id+".json")
        rejected("Stored fit silently rebound to new head pose") {_=try store.load(url,scope:scope(pan:6001,camera:current.cameraGeneration))}
        store.invalidate();precondition(store.resolve(scope:current)==nil)
        _=try store.load(url,scope:current)
        precondition(store.resolve(scope:current)?.id==fit.id)
        print("Fixed-head registration fixtures passed: strict base motion/brake/malformed packet classification; exact/180-degree rigid transforms, independent heldout captures/points, uncertainty, reflection/plane rejection, local volume and exact pose/model/camera/session invalidation.")
    }
}
