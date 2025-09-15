//
//  ViewController.swift
//  macOS Camera
//
//  Created by Mihail Șalari. on 4/24/17.
//  Copyright © 2017 Mihail Șalari. All rights reserved.
//

import Cocoa
import Vision
import CoreImage
import SceneKit

final class CameraViewController: NSViewController {
    private var cameraManager: CameraManagerProtocol!
    //public var robMainViewController: ROBMainViewController
    @IBOutlet weak var skeletonView: SCNView!
    @IBOutlet weak var personMaskImageView: NSImageView!
    var sceneCreated = false
    let renderer = HumanBodySkeletonRenderer()
    var viewModel: HumanBodyPose3DDetector = HumanBodyPose3DDetector()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            cameraManager = try CameraManager(containerView: view)
            cameraManager.delegate = self
        } catch {
            // Cath the error here
            print(error.localizedDescription)
        }
        
        setupSceneKitView()
    }
    
    @IBAction func toggleCamera(_ sender: Any?) {
        do {
            print("ToggleCamera")
            try cameraManager.stopSession()
            try cameraManager.startSession()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    @IBAction func bindCamera(_ sender: Any?) {
        do {
            try cameraManager.bindCamera()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    @IBAction func bindCameaRebootSession(_ sender: Any?) {
        do {
            try cameraManager.bindCameraRebootSession()
        } catch {
            print(error.localizedDescription)
        }
    }
    
    
    override var representedObject: Any? {
        didSet {
            // Update the view, if already loaded.
        }
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        do {
            try cameraManager.startSession()
        } catch {
            // Cath the error here
            print(error.localizedDescription)
        }
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
        do {
            try cameraManager.stopSession()
        } catch {
            // Cath the error here
            print(error.localizedDescription)
        }
    }
}

extension CameraViewController: CameraManagerDelegate {
    
    func process_humanBodyPose3D_Observation(_ observation: VNHumanBodyPose3DObservation) {
        if !sceneCreated {
            self.skeletonView.scene = createScene(observation: observation)
            //sceneCreated = true
        } else {
            //This is not working as expected
            updateScene(observation: observation)
        }
    }
    
    func updateScene(observation: VNHumanBodyPose3DObservation) {
        guard let myScene = self.skeletonView.scene else {
            return
        }
        let nodeDict = renderer.createSkeletonNodes(observation: observation)
        
        
        //let rootNode = SCNNode()
        // Clear any previous skeleton from the scene
        myScene.rootNode.childNodes.forEach {
            if $0 != self.renderer.cameraNode {
                $0.removeFromParentNode()
            }
        }
        //myScene.rootNode.addChildNode(rootNode)

        //myScene.rootNode.addChildNode(renderer.createCameraNode(observation: observation))
        
        // Add skeleton nodes to the scene.
        let bodyAnchorNode = SCNNode()
        bodyAnchorNode.position = SCNVector3(0, 0, 0)
        myScene.rootNode.addChildNode(bodyAnchorNode)
        for jointName in nodeDict.keys {
            if let jointNode = nodeDict[jointName] {
                bodyAnchorNode.addChildNode(jointNode)
            }
        }
        
        // Give the head more spherical geometry.
        if let topHead = nodeDict[.topHead], let centerHeadNode = nodeDict[.centerHead], let centerShoulderNode = nodeDict[.centerShoulder] {
            let headHight = CGFloat(topHead.position.y - centerShoulderNode.position.y)
            centerHeadNode.geometry = SCNBox(width: 0.2,
                                             height: headHight,
                                             length: 0.2,
                                             chamferRadius: 0.4)
            centerHeadNode.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
            topHead.isHidden = true
        }
        
        let jointOrderArray: [VNHumanBodyPose3DObservation.JointName] = [.leftWrist, .leftElbow, .leftShoulder,
                                                                         .rightWrist, .rightElbow, .rightShoulder,
                                                                         .centerShoulder, .spine, .rightAnkle,
                                                                         .rightKnee, .rightHip, .leftAnkle, .leftKnee, .leftHip]
        for jointName in jointOrderArray {
            connectNodeToParent(joint: jointName,
                                observation: observation,
                                nodeJointDict: nodeDict,
                                viewModel)
        }
    }
    
    func createScene(observation: VNHumanBodyPose3DObservation) -> SCNScene {
        let myScene = SCNScene()
        let nodeDict = renderer.createSkeletonNodes(observation: observation)
        myScene.rootNode.addChildNode(renderer.createCameraNode(observation: observation))
        
        // Add skeleton nodes to the scene.
        let bodyAnchorNode = SCNNode()
        bodyAnchorNode.position = SCNVector3(0, 0, 0)
        myScene.rootNode.addChildNode(bodyAnchorNode)
        for jointName in nodeDict.keys {
            if let jointNode = nodeDict[jointName] {
                bodyAnchorNode.addChildNode(jointNode)
            }
        }
        
        // Give the head more spherical geometry.
        if let topHead = nodeDict[.topHead], let centerHeadNode = nodeDict[.centerHead], let centerShoulderNode = nodeDict[.centerShoulder] {
            let headHight = CGFloat(topHead.position.y - centerShoulderNode.position.y)
            centerHeadNode.geometry = SCNBox(width: 0.2,
                                             height: headHight,
                                             length: 0.2,
                                             chamferRadius: 0.4)
            centerHeadNode.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
            topHead.isHidden = true
        }
        
        let jointOrderArray: [VNHumanBodyPose3DObservation.JointName] = [.leftWrist, .leftElbow, .leftShoulder,
                                                                         .rightWrist, .rightElbow, .rightShoulder,
                                                                         .centerShoulder, .spine, .rightAnkle,
                                                                         .rightKnee, .rightHip, .leftAnkle, .leftKnee, .leftHip]
        for jointName in jointOrderArray {
            connectNodeToParent(joint: jointName,
                                observation: observation,
                                nodeJointDict: nodeDict,
                                viewModel)
        }
        return myScene
    }
    
    func setupSceneKitView() {
        self.skeletonView.backgroundColor = .clear
    }

    func cameraManager(_ output: CameraCaptureOutput, didOutput sampleBuffer: CameraSampleBuffer, from connection: CameraCaptureConnection) {
        
        //process samplebuffer here
        let humanRectanglesRequest = VNDetectHumanRectanglesRequest { request, error in
            for observation in request.results as! [VNHumanObservation] {
                print("humanRectanglesRequest = \(observation)")
            }
        }
        let humanBodyPoseRequest = VNDetectHumanBodyPoseRequest { request, error in
            for observation in request.results as! [VNHumanBodyPoseObservation] {
                print("humanBodyPoseRequest = \(observation)")
            }
        }
        let humanHandPoseRequest = VNDetectHumanHandPoseRequest { request, error in
            for observation in request.results as! [VNHumanHandPoseObservation] {
                print("humanHandPoseRequest = \(observation)")
            }
        }
        let humanBodyPose3DRequest = VNDetectHumanBodyPose3DRequest { request, error in
            for observation in request.results as! [VNHumanBodyPose3DObservation] {
                //print("--------------------------------------------------")
                //print("humanBodyPose3DRequest = \(observation)")
                //observation.availableJointNames.forEach { print($0) }
                //observation.availableJointsGroupNames.forEach { print($0) }
                //renderSkeleton(from: observation)
                //if let scene = self.skeletonView.scene {
                self.process_humanBodyPose3D_Observation(observation)
                //}
                
                //print("--------------------------------------------------")
            }
        }
        let trajectoriesRequest = VNDetectTrajectoriesRequest(frameAnalysisSpacing: CMTime(value: 1, timescale: 60), trajectoryLength: 1, completionHandler: { request, error in
            for observation in request.results as! [VNTrajectoryObservation] {
                print("trajectoriesRequest = \(observation)")
            }
        })
        let animalBodyPoseRequest = VNDetectAnimalBodyPoseRequest(completionHandler: { request, error in
            for observation in request.results as! [VNAnimalBodyPoseObservation] {
                print("animalBodyPoseRequest = \(observation)")
            }
        })
        
        let detectFaceRequest = VNDetectFaceRectanglesRequest { request, error in
            if let results = request.results {
                for observation in results {
                    print("detectFaceRequest = \(observation)")
                }
            }
        }
        
        let personInstanceRequest = VNGeneratePersonInstanceMaskRequest { request, error in
            for observation in request.results as! [VNInstanceMaskObservation] {
                print("personInstanceRequest = \(observation)")
                
                do {
                    // 4. Get the first person's mask.
                    // The observations are `VNInstanceMaskObservation` objects.
                    let firstPersonMaskObservation = observation as VNInstanceMaskObservation
                    
                    // 5. Generate a `CIImage` mask for the desired instance.
                    // We'll use the `allInstances` property to get a mask for all detected instances.
                    let maskPixelBuffer = try firstPersonMaskObservation.generateMask(forInstances: observation.allInstances)
                    var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
                    
                    
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }
                    let ciImage = CIImage(cvImageBuffer: imageBuffer)

                    let imageWidth = CVPixelBufferGetWidth(imageBuffer);
                    let imageHeight = CVPixelBufferGetHeight(imageBuffer);
                    
                    // 6. Scale the mask to match the size of the original image.
                    let scaleX = CGFloat(imageWidth) / maskImage.extent.width
                    let scaleY = CGFloat(imageHeight) / maskImage.extent.height
                    maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                    
                    // 7. Create a color for the overlay.
                    let solidColor = CIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5) // Red with 50% opacity
                    let coloredMask = maskImage.applyingFilter("CIConstantColorGenerator", parameters: [kCIInputColorKey: solidColor])
                    
                    // 8. Composite the colored mask onto the original image.
                    let compositedImage = coloredMask.applyingFilter("CISourceOverCompositing", parameters: [kCIInputImageKey: ciImage])
                    
                    // 9. Render the final image from the CIImage.
                    let context = CIContext(options: nil)
                    guard let finalImage = context.createCGImage(compositedImage, from: compositedImage.extent) else {
                        return
                    }
                    
                    let myNSImage = NSImage(cgImage: finalImage, size: NSSize(width: finalImage.width, height: finalImage.height))

                    self.personMaskImageView.image = myNSImage
                    
                } catch {
                    print("Failed to perform Vision request: \(error.localizedDescription)")
                    return
                }
            }
        }
        let segmentationRequest = VNGeneratePersonSegmentationRequest { request, error in
            if let results = request.results {
                for observation in results {
                    print("segmentationRequest = \(observation)")
                }
            }
        }
        
        let imageRequestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        try? imageRequestHandler.perform([
            //humanRectanglesRequest,
            //humanBodyPoseRequest,
            //humanHandPoseRequest,
            //humanBodyPose3DRequest,
            //trajectoriesRequest,
            //animalBodyPoseRequest,
            //detectFaceRequest,
            personInstanceRequest
            
        ])
        
    }
}


// MARK: - Redraws the skeleton upon model change.
func connectNodeToParent(joint: VNHumanBodyPose3DObservation.JointName, observation: VNHumanBodyPose3DObservation,
                         nodeJointDict: [VNHumanBodyPose3DObservation.JointName: SCNNode], _ viewModel: HumanBodyPose3DDetector) {
    if let parentJointName = observation.parentJointName(joint), let node = nodeJointDict[joint] {
        guard let parentNode = nodeJointDict[parentJointName] else {
            return
        }
        updateLineNode(node: node,
                       joint: joint,
                       fromPoint: node.simdPosition,
                       toPoint: parentNode.simdPosition,
                       detector: viewModel,
                       observation: observation)
    }
}

func updateLineNode(node: SCNNode,
                    joint: VNHumanBodyPose3DObservation.JointName,
                    fromPoint: simd_float3,
                    toPoint: simd_float3,
                    originalCubeWidth: Float = 0.05,
                    detector: HumanBodyPose3DDetector,
                    observation: VNHumanBodyPose3DObservation) {
    // Determine the distance between the child and parent nodes.
    let length = max(simd_length(toPoint - fromPoint), 1E-5)
    
    // The distance between the child and parent nodes serves as the length of the limb node geometry.
    let boxGeometry = SCNBox(width: CGFloat(Float(originalCubeWidth)),
                             height: CGFloat(Float(length)),
                             length: CGFloat(originalCubeWidth),
                             chamferRadius: 0.05)
    node.geometry = boxGeometry
    node.geometry?.firstMaterial?.diffuse.contents = NSColor(ciColor: .red)
    
    // The node is positioned between the child and parent nodes.
    node.simdPosition = (toPoint + fromPoint) / 2
    node.simdEulerAngles = detector.calculateLocalAngleToParent(joint: joint, observation: observation)
}
