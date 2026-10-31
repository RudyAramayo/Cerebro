import Foundation
import simd

@main struct PourPreviewFixtures {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let model=try ROBGhostRobotModel(directory:root.appendingPathComponent("Cerebro/Resources/ShadowPlanner"),physicalSide:"right")
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
        let full=try ROBCanPourRehearsal(data:data,model:model,timed:false)
        let timed=try ROBCanPourRehearsal(data:data,model:model,timed:true)
        precondition(full.frames.count>50 && timed.frames.count>100)
        precondition(timed.duration>4 && timed.duration<10)
        precondition(simd_distance(timed.frames.first!.canPose.columns.3,timed.frames.last!.canPose.columns.3)<1e-8)
        let original=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        func rejected(_ change:(inout [String:Any])->Void,timed:Bool=false) throws {
            var value=original;change(&value)
            let edited=try JSONSerialization.data(withJSONObject:value)
            do { _=try ROBCanPourRehearsal(data:edited,model:model,timed:timed);fatalError("Invalid rehearsal admitted") }
            catch is ROBGhostMotionError {}
        }
        try rejected {$0["executable"]=true}
        try rejected {$0["hardwareOutputEnabled"]=true}
        try rejected {$0["modelID"]="wrong model"}
        try rejected {$0.removeValue(forKey:"tableAlignment")}
        try rejected {$0.removeValue(forKey:"bodyPreparation")}
        try rejected { root in
            var rows=root["steps"] as! [[String:Any]]
            rows[0].removeValue(forKey:"worldFromRobot");root["steps"]=rows
        }
        try rejected { root in
            var prep=root["bodyPreparation"] as! [String:Any]
            prep["torsoTargetYawRadians"]=0;root["bodyPreparation"]=prep
        }
        try rejected { root in
            var rows=root["steps"] as! [[String:Any]]
            rows.removeAll {($0["phase"] as? String)=="torso"};root["steps"]=rows
        }
        try rejected { root in
            var rows=root["steps"] as! [[String:Any]]
            let arm=rows.firstIndex {($0["phase"] as? String)=="arm"}!
            rows[arm]["worldFromRobot"]=[[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]];root["steps"]=rows
        }
        try rejected { root in
            var geometry=root["sceneGeometry"] as! [String:Any]
            var matrix=geometry["modelFromScene"] as! [[Double]];matrix[2][3] += 0.24
            geometry["modelFromScene"]=matrix;root["sceneGeometry"]=geometry
        }
        try rejected { root in
            var alignment=root["tableAlignment"] as! [String:Any]
            alignment["tableHeightAboveFloorMeters"]=0.96;root["tableAlignment"]=alignment
        }
        try rejected { root in
            var rows=root["steps"] as! [[String:Any]]
            rows[0]["ik"]=["solved":false];root["steps"]=rows
        }
        try rejected { root in
            var geometry=root["sceneGeometry"] as! [String:Any]
            geometry["modelFromScene"]=[[1.0,0,0,0],[0,0.866025403784,-0.5,0],[0,0.5,0.866025403784,0],[0,0,0,1]]
            root["sceneGeometry"]=geometry
        }
        try rejected { root in
            var poses=root["steps"] as! [[String:Any]],q=poses[0]["positions"] as! [String:Double]
            q["right_joint7"]=3;poses[0]["positions"]=q;root["steps"]=poses
        }
        try rejected({ root in
            var poses=root["nativeTimedPreview"] as! [[String:Any]]
            poses[1]["timeSeconds"] = -1;root["nativeTimedPreview"]=poses
        },timed:true)
        try rejected { root in
            var poses=root["steps"] as! [[String:Any]],m=poses[0]["desiredCanPose"] as! [[Double]]
            m[0][0]=7;poses[0]["desiredCanPose"]=m;root["steps"]=poses
        }
        precondition(abs(full.sceneTransform.columns.3.z+full.tableZ-full.tableHeightAboveFloor)<1e-6)
        precondition(full.frames.first!.worldFromRobot.columns.3.x==0)
        precondition(abs(full.frames.last!.worldFromRobot.columns.3.x-0.25)<1e-8)
        for frame in full.frames where frame.stage.hasPrefix("Drive") || frame.stage.hasPrefix("Turn torso") {
            precondition(simd_length(frame.canPose.columns.3-full.frames.first!.canPose.columns.3)<1e-8)
        }
        print("Native pour preview: measured height, fixed world, staged drive/torso and sixteen invalid-input cases passed")
    }
}
