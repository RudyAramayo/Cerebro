import Foundation
import simd

/// No gateway, camera, UI or actuator implementation is linked to this fixture.
final class ROBGhostRobotModel {
    struct Description:Codable {
        let physicalSide:String
        let modelID:String
        let geometryID:String
        let mappingID:String
        let referenceID:String
        let torsoToModelRowMajor:[Double]
        let nominalUpperToOpticalRowMajor:[Double]
    }
    let description:Description
    var torsoShift=0.0
    init(_ value:Description) {description=value}
    var physicalSide:String {description.physicalSide}
    var modelID:String {description.modelID}
    var geometryID:String {description.geometryID}
    var selectedMappingID:String {description.mappingID}
    var referenceID:String {description.referenceID}
    var reference:[String:Double] {[:]}
    func frames(_ positions:[String:Double])->[String:simd_double4x4] {
        var torso=Self.matrix(description.torsoToModelRowMajor);torso.columns.3.x+=torsoShift
        return ["torso_link":torso,"upper_neck_link":torso,
                "oak_optical_frame":torso*Self.matrix(description.nominalUpperToOpticalRowMajor)]
    }
    static func matrix(_ v:[Double])->simd_double4x4 {simd_double4x4((0..<4).map{c in SIMD4(v[c],v[c+4],v[c+8],v[c+12])})}
}

@main enum ROBEstimatedFixedHeadCaptureFixture {
    struct Configuration:Codable {
        let model:ROBGhostRobotModel.Description
        let scope:ROBFixedHeadRegistrationScope
        let expectedCameraToModelRowMajor:[Double]
        let assertSyntheticPatch:Bool
        let verifiedCameraServiceSourceSHA256:[String]
    }
    static func main() throws {
        let arguments=CommandLine.arguments
        let package=URL(fileURLWithPath:arguments[1]),root=URL(fileURLWithPath:arguments[2])
        let config=try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:URL(fileURLWithPath:arguments[3])))
        let model=ROBGhostRobotModel(config.model),reject=arguments.contains("reject")
        do {
            let context:ROBEstimatedFixedHeadCapture.Context=try ROBEstimatedFixedHeadCapture.load(
                packageURL:package,model:model,expectedScope:config.scope,evidenceRoot:root,
                verifiedCameraServiceSourceSHA256:Set(config.verifiedCameraServiceSourceSHA256))
            precondition(!reject,"Invalid estimated package was accepted")
            precondition(!context.measuredRegistrationVerified && !context.authorizesGrasp)
            precondition(context.rgbOutputUndistorted && config.verifiedCameraServiceSourceSHA256.contains(context.cameraServiceSourceSHA256))
            precondition(context.depthHypothesisID.count==64 && context.depthHypothesisID.allSatisfy{$0.isHexDigit})
            precondition(context.matches(currentScope:config.scope,model:model))
            for changes:[String:Any] in [["panTarget":config.scope.panTarget+1],
                ["lowerTarget":config.scope.lowerTarget+1],["upperTarget":config.scope.upperTarget+1],
                ["cameraGeneration":UUID().uuidString],["gatewaySessionGeneration":99],
                ["displayCorrectionIdentity":"changed:body:different"],["mappingID":"other-arm"],
                ["intrinsicsIdentity":"other-intrinsics"],["modelID":"other-model"]] {
                var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(config.scope)) as! [String:Any]
                for (key,value) in changes {json[key]=value}
                let changed=try JSONDecoder().decode(ROBFixedHeadRegistrationScope.self,from:JSONSerialization.data(withJSONObject:json))
                precondition(!context.matches(currentScope:changed,model:model),"Stale context was rebound")
            }
            model.torsoShift=0.001;precondition(!context.matches(currentScope:config.scope,model:model));model.torsoShift=0
            let actual=(0..<4).flatMap{r in (0..<4).map{c in context.cameraToModel[c][r]}}
            precondition(zip(actual,config.expectedCameraToModelRowMajor).allSatisfy{abs($0-$1)<1e-9})
            for raw:UInt16 in [1,330,500,1000,1301,65000] {
                let pixels=context.hypotheses(x:150,y:150,rawMillimeters:raw)
                precondition(pixels.unionMillimeters.first==raw,"Raw occupied return was erased")
            }
            precondition(context.hypotheses(x:150,y:150,rawMillimeters:0).unionMillimeters.isEmpty)
            precondition(context.correctedMillimeters(raw:330)==nil)
            let corrected=context.correctedMillimeters(raw:1000)!
            precondition(corrected==UInt16((1000/(context.inverseScale+context.inverseBiasPerMeter)).rounded()))
            let points=context.opticalPoints(x:150,y:150,rawMillimeters:1000)
            precondition(points.count==2 && points[0].z==1 && abs(points[1].z-Double(corrected)/1000)<1e-12)
            if config.assertSyntheticPatch {
                precondition(context.hypotheses(x:150,y:150,rawMillimeters:1000).withinObservedPatch)
                precondition(!context.hypotheses(x:20,y:20,rawMillimeters:1000).withinObservedPatch)
            }
            print(String(data:try JSONSerialization.data(withJSONObject:context.metadata,options:[.sortedKeys]),encoding:.utf8)!)
        } catch {
            guard reject else {throw error}
            print("Rejected: \(error.localizedDescription)")
        }
    }
}
