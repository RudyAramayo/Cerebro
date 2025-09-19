//
//  KeyframeAnimationManager.swift
//  Cerebro
//
//  Created by Rob Makina on 9/16/25.
//  Copyright © 2025 Rob Makina. All rights reserved.
//

import AppKit

@objcMembers public class KeyframeAnimationManager: NSObject {
    public static var shared: KeyframeAnimationManager = KeyframeAnimationManager()
    
    //Animations are stored in the UserData Directory as codable model files
    @objc public var animations: [KeyframeAnimation] = []
    
    @objc public var currentAnimation: KeyframeAnimation?
    
    public override init() {
        super.init()
        loadAnimations()
    }
    
    public func saveCurrentKeyframeAnimation() {
        guard let currentAnimation = self.currentAnimation else {
            return
        }
        
        let userDataDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let keyframeAnimationsDirectory = userDataDirectoryURL.appendingPathComponent("ROB KeyframeAnimations")
        let newKeyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(currentAnimation.name + ".keyAnim")
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(currentAnimation)
            try data.write(to: newKeyframeAnimationURL)
            //Successfully written to file
        } catch {
            print("error saving KeyframeAnimation")
        }
    }
    
    @objc public func loadAnimations() {
        let userDataDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        var isDirectory:ObjCBool = true
        let keyframeAnimationsDirectory = userDataDirectoryURL.appendingPathComponent("ROB KeyframeAnimations")
        
        if !FileManager.default.fileExists(atPath: keyframeAnimationsDirectory.path) && isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(at: keyframeAnimationsDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("failed to write to documents directory")
            }
        }
        
        do {
            var keyframeAnimations = try FileManager.default.contentsOfDirectory(atPath: keyframeAnimationsDirectory.path)
            
            //create default animation if it doesn't exist
            if keyframeAnimations.isEmpty || (keyframeAnimations.count == 1 && keyframeAnimations.first == ".DS_Store") {
                //create our first animation here
                let newKeyframeAnimation = KeyframeAnimation(name:"StarWars Droid Battle")
                self.currentAnimation = newKeyframeAnimation
                let newKeyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(newKeyframeAnimation.name + ".keyAnim")
                let encoder = JSONEncoder()
                do {
                    let data = try encoder.encode(newKeyframeAnimation)
                    try data.write(to: newKeyframeAnimationURL)
                    keyframeAnimations = try FileManager.default.contentsOfDirectory(atPath: keyframeAnimationsDirectory.path)
                    //Successfully written to file
                }
            }
            
            for keyframeAnimation in keyframeAnimations {
                guard keyframeAnimation != ".DS_Store" else { continue }
                print("keyframeAnimation \(keyframeAnimation)")
                
                let keyframeAnimationURL = keyframeAnimationsDirectory.appendingPathComponent(keyframeAnimation)
                
                if currentAnimation == nil {
                    //Read it back
                    let savedData = try Data(contentsOf: keyframeAnimationURL)
                    let decoder = JSONDecoder()
                    let decodedInstance = try decoder.decode(KeyframeAnimation.self, from: savedData)
                    print("decodedInstance = \(decodedInstance.name) keyframes = \(decodedInstance.keyframeSequence) keyframeA: \(decodedInstance.keyframeSequence.first?.name ?? "noname")")
                    self.currentAnimation = decodedInstance
                }
                
            }
            
        } catch {
            print("Failed to decode keyframes \(error)")
        }
    }
    
    public func addNewNamedKeyframe(name:String) {
        currentAnimation?.addNewNamedKeyframe()
        saveCurrentKeyframeAnimation()
    }
    
}


@objcMembers public class KeyframeAnimation: NSObject, Codable {
    public var name: String = "Keyframe Animation"
    public var keyframeSequence: [Keyframe] = []
    public var namedKeyframes: [Keyframe] = []
    public var keyframeDict: [String: Keyframe] = [:]
    public var currentKeyframe: Keyframe = Keyframe(name: UUID().uuidString)
    
    init(name: String, keyframeSequence: [Keyframe]) {
        self.name = name
        self.keyframeSequence = keyframeSequence
    }
    
    convenience init(name: String) {
        self.init()
        self.name = name
        self.keyframeSequence = []
    }
    
    public override init() {}
    
    public func addNewNamedKeyframe() {
        keyframeDict[currentKeyframe.name] = currentKeyframe
        namedKeyframes.append(currentKeyframe)
        currentKeyframe = Keyframe(name: UUID().uuidString)
    }
    
    public func appendCurrentKeyframeToSequence() {
        keyframeSequence.append(currentKeyframe)
    }
}

@objcMembers public class Keyframe: NSObject, Codable {
    @objc public var name: String = "keyframe"
    
    @objc public var arm_R11_keyframe: Bool = false
    @objc public var arm_R11_cmd_sleep: Double = 0
    @objc public var arm_R11_cmd_time: Double = 2
    @objc public var arm_R11_servo1: Double = 0
    @objc public var arm_R11_servo2: Double = 0
    @objc public var arm_R11_servo3: Double = 0
    @objc public var arm_R11_servo4: Double = 0
    @objc public var arm_R11_servo5: Double = 0
    @objc public var arm_R11_servo6: Double = 0
    @objc public var arm_R11_servo7: Double = 0
    
    @objc public var arm_L10_keyframe: Bool = false
    @objc public var arm_L10_cmd_sleep: Double = 0
    @objc public var arm_L10_cmd_time: Double = 2
    @objc public var arm_L10_servo1: Double = 0
    @objc public var arm_L10_servo2: Double = 0
    @objc public var arm_L10_servo3: Double = 0
    @objc public var arm_L10_servo4: Double = 0
    @objc public var arm_L10_servo5: Double = 0
    @objc public var arm_L10_servo6: Double = 0
    @objc public var arm_L10_servo7: Double = 0
    
    @objc public var head_keyframe: Bool = false
    @objc public var head_upperNeck: Double = 0
    @objc public var head_lowerNeck: Double = 0
    @objc public var head_neckRotation: Double = 0
    
    @objc public var tread_movement_keyframe: Bool = false
    @objc public var tread_movement_cmd_time: Double = 0
    @objc public var treadR: Double = 0
    @objc public var treadL: Double = 0
    
    @objc public var flipper_keyframe: Bool = false
    @objc public var flipper: Double = 0
    
    @objc public var LACT_keyframe: Bool = false
    @objc public var LACT_cmd_time: Double = 0
    @objc public var LACT: Double = 0
    
    @objc public var torsoRotation_keyframe: Bool = false
    @objc public var torsoRotation_speed: Double = 0
    @objc public var torsoRotation_finalPosition: Double = 0
    
    @objc public var speechDialog_keyframe: Bool = false
    @objc public var speech_dialog: String = ""
    @objc public var speech_language: String = ""
    @objc public var speech_volume: Double = 0
    @objc public var speech_rate: Double = 0
    @objc public var speech_pitchMultiplier: Double = 0
    
    init(name: String) {
        self.name = name
    }
    
    public override init() {}
}
