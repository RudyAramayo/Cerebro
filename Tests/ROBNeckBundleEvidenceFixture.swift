import Foundation
import simd
import CryptoKit

@main enum ROBNeckBundleEvidenceFixture {
    struct Fixture:Codable {
        let input:ROBNeckBundleRGBInput
        let nominalRowMajor:[Double]
        let expectedCameraToTorsoRowMajor:[Double]
    }
    static func matrix(_ v:[Double])->simd_double4x4 {
        simd_double4x4((0..<4).map{c in SIMD4(v[c],v[c+4],v[c+8],v[c+12])})
    }
    static func rows(_ T:simd_double4x4)->[Double] {(0..<4).flatMap{r in (0..<4).map{c in T[c][r]}}}
    static func sourceVerifier(_ root:String,outputContract:String?)throws->(ROBNeckBundleObservation)->Bool {
        var trusted=Set<String>()
        let files=FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:nil)!
        func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
        let contract=try outputContract.map{try Data(contentsOf:URL(fileURLWithPath:$0))}
        let contractSHA=contract.map(hash)
        if let contract {
            let source=String(decoding:contract,as:UTF8.self)
            precondition(source.contains("rgb_output = rgb_camera.requestOutput(") && source.contains("enableUndistortion=True,"),"Unverified output image-model contract")
        }
        func key(_ o:ROBNeckBundleObservation)->String {"\(o.metadataSHA256)|\(o.imageSHA256)|\(o.frameSequence)|\(o.capturedAtMilliseconds)|\(o.scope.panTarget)|\(o.scope.lowerTarget)|\(o.scope.upperTarget)|\(o.scope.cameraGeneration)|\(o.scope.displayCorrectionIdentity)|\(o.scope.gatewaySessionGeneration)|\(o.scope.modelID)|\(o.scope.geometryID)|\(o.scope.mappingID)|\(o.scope.intrinsicsIdentity)|\(o.width)|\(o.height)|\(o.intrinsics)|\(o.outputPixelModel)|\(o.pixelModelProvenanceSHA256)"}
        for case let url as URL in files where url.lastPathComponent=="capture-input.json" {
            let bytes=try Data(contentsOf:url),json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            guard let scopeJSON=json["scope"],let frames=json["frames"] as? [[String:Any]] else {continue}
            let scope=try JSONDecoder().decode(ROBFixedHeadRegistrationScope.self,from:JSONSerialization.data(withJSONObject:scopeJSON))
            for frame in frames {
                guard let path=frame["depthPath"] as? String,let width=frame["width"] as? Int,let height=frame["height"] as? Int,
                      let intrinsics=frame["intrinsics"] as? [Double],let sequence=frame["sequence"] as? UInt64,
                      let time=frame["capturedAtMilliseconds"] as? Double else {continue}
                let jpg=url.deletingLastPathComponent().appendingPathComponent(path).deletingPathExtension().appendingPathExtension("jpg")
                guard let image=try? Data(contentsOf:jpg) else {continue}
                let modelHash:String
                if frame["rgbOutputUndistorted"] as? Bool == true {modelHash=hash(bytes)}
                else if let contractSHA {modelHash=contractSHA}
                else {continue}
                let o=ROBNeckBundleObservation(targetID:"",training:false,scope:scope,width:width,height:height,
                    intrinsics:intrinsics,distortion:[],outputPixelModel:"undistorted",pixelModelProvenanceSHA256:modelHash,
                    cornersPixels:[],targetToCameraCandidatesRowMajor:[],
                    imageSHA256:hash(image),metadataSHA256:hash(bytes),frameSequence:sequence,capturedAtMilliseconds:time)
                trusted.insert(key(o))
            }
        }
        return {trusted.contains(key($0))}
    }
    static func main() throws {
        let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let shouldReject=CommandLine.arguments.contains("reject"),rejectSource=CommandLine.arguments.contains("reject-source")
        let sourceRoot=CommandLine.arguments.firstIndex(of:"--evidence-root").map{CommandLine.arguments[$0+1]}
        let contract=CommandLine.arguments.firstIndex(of:"--output-contract").map{CommandLine.arguments[$0+1]}
        let verify=try sourceRoot.map{try sourceVerifier($0,outputContract:contract)}
        do {
            let proof=try ROBNeckBundleRGBEvidence.validateRGB(fixture.input,expectedScope:fixture.input.scope,
                nominalUpperToOptical:matrix(fixture.nominalRowMajor),verifySource:{!rejectSource && (verify?($0) ?? true)})
            precondition(!shouldReject && !rejectSource,"Invalid evidence was admitted")
            precondition(!proof.hasDepthProjectionAuthority,"RGB evidence acquired depth authority")
            let expected=fixture.expectedCameraToTorsoRowMajor,actual=rows(proof.cameraToTorso)
            precondition(zip(expected,actual).allSatisfy{abs($0-$1)<1e-9},"Swift/Python neck kinematics disagree")
            let json:[String:Any]=["id":proof.id,"trainingPixels":proof.trainingCornerRMSEPixels,
                "heldOutPixels":proof.heldOutCornerRMSEPixels,"heldOutMarkerDriftMaximumMeters":proof.heldOutMarkerDriftMaximumMeters,
                "rgbGeometryAllowanceMeters":proof.rgbGeometryAllowanceMeters,"hasDepthAuthority":proof.hasDepthProjectionAuthority,
                "markers":proof.targetToTorso.mapValues(rows)]
            print(String(data:try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]),encoding:.utf8)!)
        } catch {
            guard shouldReject || rejectSource else {throw error}
            print("Rejected: \(error.localizedDescription)")
        }
    }
}
