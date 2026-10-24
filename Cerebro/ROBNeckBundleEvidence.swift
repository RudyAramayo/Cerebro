import Foundation
import CryptoKit
import simd

/// RGB-only articulated-camera evidence. These types never construct a depth
/// registration or grant arm authority. The separately measured depth model
/// must cover the actual view/range before a consumer can project depth.
struct ROBNeckBundleParameters: Codable {
    let panScale: Double
    let lowerScale: Double
    let upperScale: Double
    let lowerOffsetRadians: Double
    let cameraDeltaRotationVector: [Double]
    let cameraTranslationMeters: [Double]
}

struct ROBNeckBundleObservation: Codable {
    let targetID: String
    let training: Bool
    let scope: ROBFixedHeadRegistrationScope
    let width: Int
    let height: Int
    let intrinsics: [Double] // fx,fy,cx,cy of the actual source image
    let distortion: [Double]
    let outputPixelModel: String // undistorted or native_distorted
    let pixelModelProvenanceSHA256: String
    let cornersPixels: [[Double]] // canonical printed TL,TR,BR,BL
    let targetToCameraCandidatesRowMajor: [[Double]]
    let imageSHA256: String
    let metadataSHA256: String
    let frameSequence: UInt64
    let capturedAtMilliseconds: Double
}

struct ROBNeckBundleRGBInput: Codable {
    let schemaVersion: Int
    let kind: String
    let scope: ROBFixedHeadRegistrationScope
    let parameterFitEvidenceSHA256: String
    let symbolSideMeters: Double
    let parameters: ROBNeckBundleParameters
    let observations: [ROBNeckBundleObservation]
    /// Explicit allowance from the offline parameter-sensitivity report. It is
    /// an assumption in this local proof, not a physical confidence interval.
    let parameterPositionAllowanceMeters: Double
}

enum ROBNeckBundleError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(text)=self { return text }; return nil }
}

struct ROBNeckBundleRGBEvidence {
    let id: String
    let scope: ROBFixedHeadRegistrationScope
    let cameraToTorso: simd_double4x4
    let trainingCornerRMSEPixels: Double
    let heldOutCornerRMSEPixels: Double
    let heldOutMarkerDriftMaximumMeters: Double
    let rgbGeometryAllowanceMeters: Double
    let targetToTorso: [String:simd_double4x4]
    let input: ROBNeckBundleRGBInput
    var hasDepthProjectionAuthority: Bool { false }

    private init(id:String,input:ROBNeckBundleRGBInput,camera:simd_double4x4,
                 train:Double,held:Double,drift:Double,markers:[String:simd_double4x4]) {
        self.id=id;self.input=input;scope=input.scope;cameraToTorso=camera
        trainingCornerRMSEPixels=train;heldOutCornerRMSEPixels=held
        heldOutMarkerDriftMaximumMeters=drift;targetToTorso=markers
        rgbGeometryAllowanceMeters=0.020+drift+input.parameterPositionAllowanceMeters
    }

    /// `verifySource` must hash the immutable source image and metadata on disk
    /// and bind their original sequence/time/scope. A JSON verified flag is not
    /// accepted. The caller supplies the nominal mount from the pinned URDF.
    static func validateRGB(_ input:ROBNeckBundleRGBInput,
        expectedScope:ROBFixedHeadRegistrationScope,nominalUpperToOptical:simd_double4x4,
        verifiedNativeDistortedImageModelSHA256:Set<String> = [],
        verifySource:(ROBNeckBundleObservation)throws->Bool) throws -> Self {
        func reject(_ message:String) throws ->Never {throw ROBNeckBundleError.invalid(message)}
        try expectedScope.validate();try input.scope.validate()
        guard input.schemaVersion==1,input.kind=="neck_bundle",input.scope==expectedScope,
              input.symbolSideMeters==0.12,hex(input.parameterFitEvidenceSHA256),
              (0...0.025).contains(input.parameterPositionAllowanceMeters),
              (24...512).contains(input.observations.count),rigid(nominalUpperToOptical) else {
            try reject("Neck-bundle evidence needs an exact live scope, measured120mm symbol and pinned proper camera mount.")
        }
        _ = try camera(input.parameters,scope:input.scope,nominal:nominalUpperToOptical)
        var seen=Set<String>(),poses:[String:Bool]=[:],trainPoses=Set<String>(),heldPoses=Set<String>()
        var validated:[ValidatedObservation]=[]
        let supported=Set(["ROB:TABLE:001","ROB:FLOOR:L01","ROB:FLOOR:R01","ROB:WALL:R01"])
        for observation in input.observations {
            try observation.scope.validate()
            let pose=poseID(observation.scope)
            guard sameEnvironment(observation.scope,input.scope),supported.contains(observation.targetID),
                  (16...4000).contains(observation.width),(16...4000).contains(observation.height),
                  observation.intrinsics.count==4,observation.intrinsics.allSatisfy(\.isFinite),
                  observation.intrinsics[0]>0,observation.intrinsics[1]>0,
                  (0..<Double(observation.width)).contains(observation.intrinsics[2]),
                  (0..<Double(observation.height)).contains(observation.intrinsics[3]),
                  observation.cornersPixels.count==4,
                  observation.cornersPixels.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite) &&
                      (0..<Double(observation.width)).contains($0[0]) && (0..<Double(observation.height)).contains($0[1])}),
                  validQuad(observation.cornersPixels),
                  [0,4,5,8,12,14].contains(observation.distortion.count),observation.distortion.allSatisfy(\.isFinite),
                  observation.distortion.dropFirst(8).allSatisfy({abs($0)<1e-15}),
                  hex(observation.pixelModelProvenanceSHA256),
                  observation.outputPixelModel=="undistorted" || observation.outputPixelModel=="native_distorted",
                  observation.outputPixelModel != "undistorted" || observation.distortion.allSatisfy({abs($0)<1e-15}),
                  observation.outputPixelModel != "native_distorted" ||
                      verifiedNativeDistortedImageModelSHA256.contains(observation.pixelModelProvenanceSHA256),
                  hex(observation.imageSHA256),hex(observation.metadataSHA256),observation.frameSequence>0,
                  observation.capturedAtMilliseconds.isFinite,observation.capturedAtMilliseconds>0,
                  seen.insert(observation.imageSHA256+":"+observation.targetID).inserted,
                  poses[pose].map({$0==observation.training}) ?? true,
                  try verifySource(observation) else {
                try reject("QR observation changed scope, image provenance, intrinsics, pixel geometry or training split.")
            }
            let intrinsicsData=try JSONSerialization.data(withJSONObject:[Double(observation.width),Double(observation.height)]+observation.intrinsics)
            guard digest(intrinsicsData)==observation.scope.intrinsicsIdentity else {
                try reject("QR intrinsics do not match the exact captured camera scope.")
            }
            poses[pose]=observation.training
            if observation.training {trainPoses.insert(pose)} else {heldPoses.insert(pose)}
            let C=try camera(input.parameters,scope:observation.scope,nominal:nominalUpperToOptical)
            guard (1...2).contains(observation.targetToCameraCandidatesRowMajor.count) else {
                try reject("Supply the checked finite PnP candidates for every QR observation.")
            }
            var candidates:[(matrix:simd_double4x4,error:Double)]=[]
            for values in observation.targetToCameraCandidatesRowMajor {
                guard let matrix=matrix(values),rigid(matrix),matrix.columns.3.z>0,
                      simd_dot(SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z),
                               SIMD3(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z))<0 else {
                    try reject("QR PnP candidate is reflected, behind the image or back-facing.")
                }
                let error=try cornerError(matrix,observation:observation)
                candidates.append((matrix,error))
            }
            candidates.sort{$0.error<$1.error}
            guard candidates[0].error<=1.5 else {try reject("QR pose does not independently reproject its source pixels.")}
            if candidates.count==2,candidates[1].error-candidates[0].error<=max(0.05,0.1*candidates[0].error),
               (simd_distance(translation(candidates[0].matrix),translation(candidates[1].matrix))>0.001 ||
                 rotationDistance(candidates[0].matrix,candidates[1].matrix)>0.1 * .pi/180) {
                try reject("QR planar pose is ambiguous at this source view.")
            }
            validated.append(.init(observation:observation,camera:C,pnp:candidates[0].matrix))
        }
        guard trainPoses.count>=4,heldPoses.count>=3,trainPoses.isDisjoint(with:heldPoses),
              poses[poseID(input.scope)] != nil else {
            try reject("Use four training and three separate held-out neck poses; the exact requested view must be observed.")
        }
        let groups=Dictionary(grouping:validated,by:{$0.observation.targetID})
        guard groups.count>=2 else {try reject("Validate at least two distinct fixed QR targets.")}
        var markers:[String:simd_double4x4]=[:]
        for (identifier,observations) in groups {
            let training=observations.filter{$0.observation.training}
            guard Set(training.map{poseID($0.observation.scope)}).count>=3 else {
                try reject("Each fixed marker needs at least three distinct training views.")
            }
            var seeded=Set<String>()
            let seeds=training.filter{seeded.insert(poseID($0.observation.scope)).inserted}.prefix(3).map{$0.camera*$0.pnp}
            let fits=try seeds.map{try fitMarker(seed:$0,observations:training)}.sorted{$0.cost<$1.cost}
            for alternative in fits.dropFirst() where alternative.cost<=fits[0].cost+max(0.01,0.01*fits[0].cost) {
                guard simd_distance(translation(alternative.matrix),translation(fits[0].matrix))<=0.01,
                      rotationDistance(alternative.matrix,fits[0].matrix)<=2 * .pi/180 else {
                    try reject("Training QR views admit materially different fixed marker poses.")
                }
            }
            markers[identifier]=fits[0].matrix
        }
        var trainErrors:[Double]=[],heldErrors:[Double]=[],drift=0.0
        for row in validated {
            let M=markers[row.observation.targetID]!
            let error=try cornerError(simd_inverse(row.camera)*M,observation:row.observation)
            guard error<=8 else {try reject("A QR view disagrees with the shared neck chain by more than8pixels.")}
            if row.observation.training {trainErrors.append(error*error)}
            else {
                heldErrors.append(error*error)
                drift=max(drift,simd_distance(translation(row.camera*row.pnp),translation(M)))
            }
        }
        let train=sqrt(trainErrors.reduce(0,+)/Double(trainErrors.count)),held=sqrt(heldErrors.reduce(0,+)/Double(heldErrors.count))
        guard train<=4,held<=4,drift<=0.030 else {try reject("Shared QR geometry failed independent held-out image or marker-drift limits.")}
        if let left=markers["ROB:FLOOR:L01"],let right=markers["ROB:FLOOR:R01"] {
            let a=SIMD3(left.columns.2.x,left.columns.2.y,left.columns.2.z),b=SIMD3(right.columns.2.x,right.columns.2.y,right.columns.2.z)
            guard acos(min(1,max(-1,abs(simd_dot(a,b)))))<=3 * .pi/180,
                  abs(simd_dot(a,translation(left)-translation(right)))<=0.030,
                  abs(simd_dot(b,translation(left)-translation(right)))<=0.030 else {
                try reject("The independently fitted floor targets disagree beyond the local flat-floor allowance.")
            }
        }
        if let table=markers["ROB:TABLE:001"],let floor=markers["ROB:FLOOR:R01"] ?? markers["ROB:FLOOR:L01"] {
            let a=SIMD3(table.columns.2.x,table.columns.2.y,table.columns.2.z),b=SIMD3(floor.columns.2.x,floor.columns.2.y,floor.columns.2.z)
            guard acos(min(1,max(-1,abs(simd_dot(a,b)))))<=3 * .pi/180 else {
                try reject("The table and floor QR normals disagree beyond the local parallel-surface allowance.")
            }
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let id="neck-bundle-rgb-"+digest(try encoder.encode(input))
        return .init(id:id,input:input,camera:try camera(input.parameters,scope:input.scope,nominal:nominalUpperToOptical),
                     train:train,held:held,drift:drift,markers:markers)
    }

    static func camera(_ parameters:ROBNeckBundleParameters,scope:ROBFixedHeadRegistrationScope,
                       nominal:simd_double4x4)throws->simd_double4x4 {
        guard [parameters.panScale,parameters.lowerScale,parameters.upperScale].allSatisfy({$0.isFinite && (0.4...2.6).contains($0)}),
              parameters.lowerOffsetRadians.isFinite,abs(parameters.lowerOffsetRadians)<=Double.pi/2,
              parameters.cameraDeltaRotationVector.count==3,parameters.cameraTranslationMeters.count==3,
              (parameters.cameraDeltaRotationVector+parameters.cameraTranslationMeters).allSatisfy(\.isFinite),
              simd_length(SIMD3(parameters.cameraTranslationMeters[0],parameters.cameraTranslationMeters[1],parameters.cameraTranslationMeters[2]))<=0.5,
              rigid(nominal) else {throw ROBNeckBundleError.invalid("Invalid bounded articulated-camera parameters.")}
        let c=Double.pi/6000
        let pan=Double(scope.panTarget-6000)*c*parameters.panScale
        let lower=Double(scope.lowerTarget-6011)*c*parameters.lowerScale+parameters.lowerOffsetRadians
        let upper = -Double(scope.upperTarget-6906)*c*parameters.upperScale
        var mount=nominal;mount.columns.3=SIMD4(parameters.cameraTranslationMeters[0],parameters.cameraTranslationMeters[1],parameters.cameraTranslationMeters[2],1)
        mount=mount*rotation(SIMD3(parameters.cameraDeltaRotationVector[0],parameters.cameraDeltaRotationVector[1],parameters.cameraDeltaRotationVector[2]))
        return translated(SIMD3(-0.0207044288303,0,0.355408962871))*rotation(SIMD3(0,0,pan))*rotation(SIMD3(0,lower,0))*translated(SIMD3(0,0,0.15579))*rotation(SIMD3(0,upper,0))*mount
    }

    private struct ValidatedObservation {let observation:ROBNeckBundleObservation;let camera:simd_double4x4;let pnp:simd_double4x4}
    private static func fitMarker(seed:simd_double4x4,observations:[ValidatedObservation])throws->(matrix:simd_double4x4,cost:Double) {
        let counts=Dictionary(grouping:observations,by:{poseID($0.observation.scope)}).mapValues(\.count)
        func residual(_ M:simd_double4x4)throws->[Double] {
            var result:[Double]=[]
            for row in observations {
                let transform=simd_inverse(row.camera)*M,weight=1/sqrt(Double(counts[poseID(row.observation.scope)]!))
                let points=try projected(transform,observation:row.observation)
                for i in 0..<4 {for j in 0..<2 {
                    let e=(points[i][j]-row.observation.cornersPixels[i][j])*weight,a=abs(e)
                    result.append(a<=2 ? e : (e<0 ? -1:1)*sqrt(4*a-4))
                }}
            }
            return result
        }
        func advance(_ M:simd_double4x4,_ delta:[Double])->simd_double4x4 {
            var result=M*rotation(SIMD3(delta[0],delta[1],delta[2]))
            result.columns.3+=SIMD4(delta[3],delta[4],delta[5],0);return result
        }
        var M=seed,lambda=0.001,r=try residual(seed),cost=0.0
        cost=r.reduce(0){$0+$1*$1}
        for _ in 0..<50 {
            var J=Array(repeating:Array(repeating:0.0,count:6),count:r.count)
            for column in 0..<6 {
                var step=Array(repeating:0.0,count:6);step[column]=1e-5
                let moved=try residual(advance(M,step))
                for i in r.indices {J[i][column]=(moved[i]-r[i])/1e-5}
            }
            var A=Array(repeating:Array(repeating:0.0,count:6),count:6),b=Array(repeating:0.0,count:6)
            for i in r.indices {for a in 0..<6 {b[a]-=J[i][a]*r[i];for c in 0..<6 {A[a][c]+=J[i][a]*J[i][c]}}}
            for i in 0..<6 {A[i][i]+=lambda*max(1,A[i][i])}
            guard let delta=solve(A,b) else {throw ROBNeckBundleError.invalid("Training marker pose is geometrically degenerate.")}
            guard delta.allSatisfy(\.isFinite),delta.reduce(0,{$0+$1*$1})<1 else {lambda*=10;continue}
            let proposed=advance(M,delta),next=try residual(proposed),nextCost=next.reduce(0){$0+$1*$1}
            if nextCost<cost {
                let improvement=cost-nextCost;M=proposed;r=next;cost=nextCost;lambda=max(1e-9,lambda/3)
                if improvement<1e-9 {break}
            } else {lambda*=10;if lambda>1e9 {break}}
        }
        return(M,cost)
    }

    private static func cornerError(_ matrix:simd_double4x4,observation:ROBNeckBundleObservation)throws->Double {
        let points=try projected(matrix,observation:observation)
        return sqrt((0..<4).reduce(0){sum,i in sum+(0..<2).reduce(0){$0+pow(points[i][$1]-observation.cornersPixels[i][$1],2)}}/4)
    }
    private static func projected(_ matrix:simd_double4x4,observation:ROBNeckBundleObservation)throws->[[Double]] {
        let corners=[SIMD4(-0.06,0.06,0.0,1.0),SIMD4(0.06,0.06,0,1),SIMD4(0.06,-0.06,0,1),SIMD4(-0.06,-0.06,0,1)]
        let d=observation.distortion+Array(repeating:0,count:max(0,8-observation.distortion.count)),k=observation.intrinsics
        return try corners.map { corner in
            let p=matrix*corner
            guard p.z>0.05,p.z<10 else {throw ROBNeckBundleError.invalid("QR corner lies behind or outside the bounded camera range.")}
            let x=p.x/p.z,y=p.y/p.z,r=x*x+y*y
            let denominator=1+d[5]*r+d[6]*r*r+d[7]*r*r*r
            guard abs(denominator)>1e-8 else {throw ROBNeckBundleError.invalid("Invalid radial projection denominator.")}
            let radial=(1+d[0]*r+d[1]*r*r+d[4]*r*r*r)/denominator
            return [(x*radial+2*d[2]*x*y+d[3]*(r+2*x*x))*k[0]+k[2],
                    (y*radial+d[2]*(r+2*y*y)+2*d[3]*x*y)*k[1]+k[3]]
        }
    }
    private static func solve(_ matrix:[[Double]],_ rhs:[Double])->[Double]? {
        let n=rhs.count;var a=zip(matrix,rhs).map{$0+[$1]}
        for column in 0..<n {
            let pivot=(column..<n).max{abs(a[$0][column])<abs(a[$1][column])}!
            guard abs(a[pivot][column])>1e-12 else {return nil}
            a.swapAt(column,pivot);let divisor=a[column][column]
            for j in column...n {a[column][j]/=divisor}
            for i in 0..<n where i != column {let amount=a[i][column];for j in column...n {a[i][j]-=amount*a[column][j]}}
        }
        return a.map{$0[n]}
    }
    private static func rotation(_ vector:SIMD3<Double>)->simd_double4x4 {
        let angle=simd_length(vector);guard angle>1e-14 else {return matrix_identity_double4x4}
        let v=vector/angle,c=cos(angle),s=sin(angle),t=1-c,x=v.x,y=v.y,z=v.z
        return simd_double4x4(SIMD4(t*x*x+c,t*x*y+s*z,t*x*z-s*y,0),SIMD4(t*x*y-s*z,t*y*y+c,t*y*z+s*x,0),SIMD4(t*x*z+s*y,t*y*z-s*x,t*z*z+c,0),SIMD4(0,0,0,1))
    }
    private static func translated(_ v:SIMD3<Double>)->simd_double4x4 {var T=matrix_identity_double4x4;T.columns.3=SIMD4(v,1);return T}
    private static func translation(_ T:simd_double4x4)->SIMD3<Double> {SIMD3(T.columns.3.x,T.columns.3.y,T.columns.3.z)}
    private static func matrix(_ values:[Double])->simd_double4x4? {
        guard values.count==16,values.allSatisfy(\.isFinite) else {return nil}
        return simd_double4x4((0..<4).map{c in SIMD4(values[c],values[c+4],values[c+8],values[c+12])})
    }
    private static func rigid(_ T:simd_double4x4)->Bool {
        let R=simd_double3x3(SIMD3(T.columns.0.x,T.columns.0.y,T.columns.0.z),SIMD3(T.columns.1.x,T.columns.1.y,T.columns.1.z),SIMD3(T.columns.2.x,T.columns.2.y,T.columns.2.z))
        return (0..<4).allSatisfy{c in (0..<4).allSatisfy{T[c][$0].isFinite}} &&
            abs(simd_determinant(R)-1)<1e-7 && (0..<3).allSatisfy{abs(simd_length(R[$0])-1)<1e-7} &&
            abs(simd_dot(R[0],R[1]))+abs(simd_dot(R[0],R[2]))+abs(simd_dot(R[1],R[2]))<1e-7 &&
            abs(T.columns.0.w)+abs(T.columns.1.w)+abs(T.columns.2.w)+abs(T.columns.3.w-1)<1e-9
    }
    private static func rotationDistance(_ A:simd_double4x4,_ B:simd_double4x4)->Double {
        let R=simd_inverse(A)*B;return acos(min(1,max(-1,(R.columns.0.x+R.columns.1.y+R.columns.2.z-1)/2)))
    }
    private static func poseID(_ s:ROBFixedHeadRegistrationScope)->String {"\(s.panTarget)/\(s.lowerTarget)/\(s.upperTarget)"}
    private static func sameEnvironment(_ a:ROBFixedHeadRegistrationScope,_ b:ROBFixedHeadRegistrationScope)->Bool {
        a.modelID==b.modelID && a.geometryID==b.geometryID && a.mappingID==b.mappingID && a.cameraGeneration==b.cameraGeneration &&
            a.gatewaySessionGeneration==b.gatewaySessionGeneration && a.displayCorrectionIdentity==b.displayCorrectionIdentity && a.intrinsicsIdentity==b.intrinsicsIdentity
    }
    private static func hex(_ string:String)->Bool {string.utf8.count==64 && string.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func validQuad(_ p:[[Double]])->Bool {
        guard p.count==4,p.allSatisfy({$0.count==2}) else {return false}
        var area=0.0
        for i in 0..<4 {
            let a=p[i],b=p[(i+1)%4],c=p[(i+2)%4],x=b[0]-a[0],y=b[1]-a[1]
            guard hypot(x,y)>3,x*(c[1]-b[1])-y*(c[0]-b[0])>1e-6 else {return false}
            area+=a[0]*b[1]-a[1]*b[0]
        }
        return area>50
    }
}
