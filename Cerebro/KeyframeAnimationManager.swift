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
                    print("decodedInstance = \(decodedInstance.name) keyframes = \(decodedInstance.namedSequences) keyframeA: \(decodedInstance.namedSequences.first?.name ?? "noname")")
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
    
    public var namedKeyframes: [Keyframe] = []
    public var namedSequences: [KeyframeSequence] = []
    public var keyframeDict: [String: Keyframe] = [:]
    public var currentKeyframe: Keyframe = Keyframe(name: UUID().uuidString)
    public var currentSequence: KeyframeSequence = KeyframeSequence()
    
    init(name: String, namedKeyframes: [Keyframe]) {
        self.name = name
        self.namedKeyframes = namedKeyframes
    }
    
    convenience init(name: String) {
        self.init()
        self.name = name
        self.namedSequences = []
    }
    
    public override init() {}
    
    public func addNewNamedKeyframe() {
        keyframeDict[currentKeyframe.name] = currentKeyframe
        namedKeyframes.append(currentKeyframe)
        currentKeyframe = Keyframe(name: UUID().uuidString)
    }
    
    public func addNewNamedSequence() {
        let newSequence = KeyframeSequence()
        namedSequences.append(newSequence)
        currentSequence = newSequence
    }
    
    public func removeNamedKeyframe(name: String) {
        keyframeDict[name] = nil
        namedKeyframes.removeAll { $0.name == name }
        if currentKeyframe.name == name {
            currentKeyframe = namedKeyframes.last ?? Keyframe(name: UUID().uuidString)
        }
    }
    
    public func appendCurrentKeyframeToSequence() {
        currentSequence.appendKeyframe(currentKeyframe)
    }
    
    public func addKeyframeToCurrentSequence(_ keyframe: Keyframe) {
        currentSequence.appendKeyframe(keyframe)
    }
    
    public func removeSequenceKeyframe(index: Int) {
        currentSequence.keyframes.remove(at: index)
    }
    
    public func removeSequence(index: Int) {
        namedSequences.remove(at: index)
    }
}

@objcMembers public class KeyframeSequence: NSObject, Codable {
    public var name: String = "sequence"
    public var uuid: UUID = UUID()
    public var keyframes: [Keyframe] = []
    
    func appendKeyframe(_ keyframe: Keyframe) {
        keyframes.append(keyframe)
    }
}

@objcMembers public class Keyframe: NSObject, Codable {
    public var name: String = "keyframe"
    public var uuid: UUID = UUID()
    public var arm_R11_keyframe: Bool = false
    public var arm_R11_cmd_sleep: Double = 0
    public var arm_R11_cmd_time: Double = 2
    public var arm_R11_servo1: Double = 0
    public var arm_R11_servo2: Double = 0
    public var arm_R11_servo3: Double = 0
    public var arm_R11_servo4: Double = 0
    public var arm_R11_servo5: Double = 0
    public var arm_R11_servo6: Double = 0
    public var arm_R11_servo7: Double = 0
    
    public var arm_L10_keyframe: Bool = false
    public var arm_L10_cmd_sleep: Double = 0
    public var arm_L10_cmd_time: Double = 2
    public var arm_L10_servo1: Double = 0
    public var arm_L10_servo2: Double = 0
    public var arm_L10_servo3: Double = 0
    public var arm_L10_servo4: Double = 0
    public var arm_L10_servo5: Double = 0
    public var arm_L10_servo6: Double = 0
    public var arm_L10_servo7: Double = 0
    
    public var head_keyframe: Bool = false
    public var head_upperNeck: Double = 0
    public var head_lowerNeck: Double = 0
    public var head_neckRotation: Double = 0
    
    public var tread_movement_keyframe: Bool = false
    public var tread_movement_cmd_time: Double = 0
    public var treadR: Double = 0
    public var treadL: Double = 0
    
    public var flipper_keyframe: Bool = false
    public var flipper: Double = 0
    
    public var LACT_keyframe: Bool = false
    public var LACT_cmd_time: Double = 0
    public var LACT: Double = 0
    
    public var torsoRotation_keyframe: Bool = false
    public var torsoRotation_speed: Double = 0
    public var torsoRotation_finalPosition: Double = 0
    
    public var speechDialog_keyframe: Bool = false
    public var speech_dialog: String = ""
    public var speech_language: String = ""
    public var speech_volume: Double = 0
    public var speech_rate: Double = 0
    public var speech_pitchMultiplier: Double = 0
    
    init(name: String) {
        self.name = name
    }
    
    public override init() {}
}
