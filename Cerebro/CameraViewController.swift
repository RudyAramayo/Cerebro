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
import CoreImage.CIFilterBuiltins

final class CameraViewController: NSViewController {
    private var cameraManager: CameraManagerProtocol!
    //public var robMainViewController: ROBMainViewController
    @IBOutlet weak var skeletonView: SCNView!
    @IBOutlet weak var personMaskImageView: NSImageView!
    @IBOutlet weak var personMaskImageView_maskImage: NSImageView!
    @IBOutlet weak var poseView: PoseDrawingView!
    
    var sceneCreated = false
    let renderer = HumanBodySkeletonRenderer()
    var viewModel: HumanBodyPose3DDetector = HumanBodyPose3DDetector()
    let context = CIContext()
    
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
    
    func applySourceOverCompositing(inputImage: CIImage, backgroundImage: CIImage) -> CIImage? {
        // 1. Create a CISourceOverCompositing filter instance.
        let filter = CIFilter.sourceOverCompositing()

        // 2. Set the input images for the filter.
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(backgroundImage, forKey: kCIInputBackgroundImageKey)

        // 3. Retrieve the output image.
        guard let outputImage = filter.outputImage else {
            print("Failed to get output image from filter.")
            return nil
        }

        return outputImage
    }
    
    func cameraManager(_ output: CameraCaptureOutput, didOutput sampleBuffer: CameraSampleBuffer, from connection: CameraCaptureConnection) {
        
        //process samplebuffer here
        let humanRectanglesRequest = VNDetectHumanRectanglesRequest { request, error in
            if let humanRectanglesObservations = request.results as? [VNHumanObservation] {
                DispatchQueue.main.async {
                    self.poseView.humanRect_observations = humanRectanglesObservations
                    self.poseView.setNeedsDisplay(self.poseView.bounds)
                }
            }
        }
        let humanBodyPoseRequest = VNDetectHumanBodyPoseRequest { request, error in
            if let bodyPoseObservations = request.results as? [VNHumanBodyPoseObservation] {
                DispatchQueue.main.async {
                    self.poseView.bodyPose_observations = bodyPoseObservations
                    self.poseView.setNeedsDisplay(self.poseView.bounds)
                }
            }
        }
        let humanHandPoseRequest = VNDetectHumanHandPoseRequest { request, error in
            if let handObservations = request.results as? [VNHumanHandPoseObservation] {
                DispatchQueue.main.async {
                    self.poseView.humanHandPose_observations = handObservations
                    self.poseView.setNeedsDisplay(self.poseView.bounds)
                }
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
            for observation in request.results as! [VNFaceObservation] {
                print("detectFaceRequest = \(observation)")
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
                    
                    // 6. Scale the mask to match the size of the original image.
                    let scaleX = ciImage.extent.width / maskImage.extent.width
                    let scaleY = ciImage.extent.height / maskImage.extent.height
                    maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                    
                    //------ Working draw mask after transform
                    let rep: NSCIImageRep = NSCIImageRep(ciImage: maskImage) //Render the mask image which looks good...
                    //let rep: NSCIImageRep = NSCIImageRep(ciImage: ciImage) //Render the sampleBuffer image which looks good...
                    let mask_nsImage: NSImage = NSImage(size: rep.size)
                    mask_nsImage.addRepresentation(rep)

                    DispatchQueue.main.async {
                        self.personMaskImageView_maskImage.image = mask_nsImage
                    }
                    //------
                    //------ FAILED TO RENDER THE COLORED MASK and Composite Image!!!
                    // 7. Create a color for the overlay.
//                    let solidColor = CIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5) // Red with 50% opacity
//                    let coloredMask = maskImage.applyingFilter("CIConstantColorGenerator", parameters: [kCIInputColorKey: solidColor])
//
//                    let rep: NSCIImageRep = NSCIImageRep(ciImage: coloredMask) //Render the mask image which looks good...
//                    //let rep: NSCIImageRep = NSCIImageRep(ciImage: ciImage) //Render the sampleBuffer image which looks good...
//                    let mask_nsImage: NSImage = NSImage(size: rep.size)
//                    mask_nsImage.addRepresentation(rep)
//
//                    DispatchQueue.main.async {
//                        self.personMaskImageView_maskImage.image = mask_nsImage
//                    }
//                    // 8. Composite the colored mask onto the original image.
//                    let compositedImage = coloredMask.applyingFilter("CISourceOverCompositing", parameters: [kCIInputImageKey: ciImage])
//                    
//                    // 9. Render the final image from the CIImage.
//                    let context = CIContext(options: nil)
//                    guard let finalImage = context.createCGImage(compositedImage, from: compositedImage.extent) else {
//                        return
//                    }
//                    
//                    let nsImage = NSImage(cgImage: finalImage, size: NSSize(width: finalImage.width, height: finalImage.height))
//
//                    DispatchQueue.main.async {
//                        self.personMaskImageView.image = nsImage
//                    }
//                    //----
                    
                    
                    //This block also fails to render properly
                    // 3. Create the CISourceOverCompositing filter
//                    let filter = CIFilter.sourceOverCompositing()
//                    
//                    // 4. Set the input parameters
//                    // The logo is the 'inputImage' (the source)
//                    filter.inputImage = ciImage
//                    // The background is the 'backgroundImage' (the destination)
//                    filter.backgroundImage = maskImage
//                    
//                    // 5. Get the output image from the filter
//                    guard let outputCIImage = filter.outputImage else {
//                        print("Error: Filter did not produce an output image.")
//                        return
//                    }
//                    
//                    let rep_output: NSCIImageRep = NSCIImageRep(ciImage: outputCIImage) //Render the mask image which looks good...
//                    //let rep: NSCIImageRep = NSCIImageRep(ciImage: ciImage) //Render the sampleBuffer image which looks good...
//                    let nsImage_output: NSImage = NSImage(size: rep_output.size)
//                    nsImage_output.addRepresentation(rep_output)
//
//                    DispatchQueue.main.async {
//                        self.personMaskImageView.image = nsImage_output
//                    }
                    
                    //Compositing test
//                    let foregroundColor = CIColor.init(red: 0.0, green: 0.0, blue: 1.0, alpha: 0.7)
//                    let foregroundImage = CIImage(color: foregroundColor).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
//
//                    let backgroundColor = CIColor.red
//                    let backgroundImage = CIImage(color: backgroundColor).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
//
//                    if let resultImage = self.applySourceOverCompositing(inputImage: foregroundImage, backgroundImage: backgroundImage) {
//                        // 4. Handle the output image.
//                        // In a macOS app, you might draw this image in a view.
//                        // For this console example, we'll print its details.
//                        print("Successfully created a composite image with extent: \(resultImage.extent)")
//
//                        // To display the image in a real application, you would render it.
//                        // For example, in a NSView's `draw` method:
//                        // let context = CIContext()
//                        // let cgImage = context.createCGImage(resultImage, from: resultImage.extent)
//                        // NSGraphicsContext.current?.cgContext.draw(cgImage, in: resultImage.extent)
//                        guard let cgImage = self.context.createCGImage(resultImage, from: resultImage.extent) else {
//                            print("Error: Could not create CGImage from final CIImage.")
//                            return
//                        }
//
//                        let final_nsImage = NSImage(cgImage: cgImage, size: resultImage.extent.size)
//                        DispatchQueue.main.async {
//                            self.personMaskImageView.image = final_nsImage
//                        }
//                    }
                    
                } catch {
                    print("Failed to perform Vision request: \(error.localizedDescription)")
                    return
                }
            }
        }
        let segmentationRequest = VNGeneratePersonSegmentationRequest { request, error in
            for observation in request.results as! [VNPixelBufferObservation] {
                print("segmentationRequest = \(observation)")
                DispatchQueue.main.async {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        return
                    }
                    let ciImage = CIImage(cvImageBuffer: imageBuffer)
                    
                    self.processAndDrawMask(observation: observation, on: ciImage)
                }
            }
        }
        
        let imageRequestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        try? imageRequestHandler.perform([
            humanRectanglesRequest,
            humanBodyPoseRequest,       // √
            humanHandPoseRequest,
            //humanBodyPose3DRequest,
            //trajectoriesRequest,
            //animalBodyPoseRequest,
            detectFaceRequest,
            //personInstanceRequest     // √
            //segmentationRequest       // √
        ])
    }
    
    func processAndDrawMask(observation: VNPixelBufferObservation, on originalCIImage: CIImage) {
            //let originalCIImage = CIImage(cgImage: sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            let maskPixelBuffer = observation.pixelBuffer

            // Create a CIImage from the segmentation mask.
            let maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)

            // The mask is the same size as the observation, not necessarily the original image.
            // Scale the mask to match the original image size.
            let scaleX = originalCIImage.extent.width / maskImage.extent.width
            let scaleY = originalCIImage.extent.height / maskImage.extent.height
            let scaledMaskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            // Create a Core Image filter to blend the mask with the original image.
            let filter = CIFilter(name: "CISourceOverCompositing")
            filter?.setValue(scaledMaskImage, forKey: kCIInputImageKey)
            filter?.setValue(originalCIImage, forKey: kCIInputBackgroundImageKey)
            
            // You can use a different filter, for example, to replace the background:
            /*
            let backgroundCIImage = CIImage(color: CIColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0)).cropped(to: originalCIImage.extent)
            let blendFilter = CIFilter(name: "CIBlendWithMask")
            blendFilter?.setValue(originalCIImage, forKey: kCIInputImageKey)
            blendFilter?.setValue(backgroundCIImage, forKey: kCIInputBackgroundImageKey)
            blendFilter?.setValue(scaledMaskImage, forKey: kCIInputMaskImageKey)
            */
            
            // Get the final output image.
            guard let outputCIImage = filter?.outputImage else {
                print("Error: Could not get output CIImage.")
                return
            }

            // 5. Convert CIImage to NSImage and display it.
            let context = CIContext(options: nil)
            if let cgImageResult = context.createCGImage(outputCIImage, from: outputCIImage.extent) {
                let finalImage = NSImage(cgImage: cgImageResult, size: CGSizeMake(originalCIImage.extent.width, originalCIImage.extent.height))
                self.personMaskImageView.image = finalImage
            }
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

extension VNHumanBodyPoseObservation {
    func getJointPoints(for size: NSSize) -> [CGPoint] {
        var points: [CGPoint] = []
        let joints = availableJointNames
        
        for jointName in joints {
            if let recognizedPoint = try? recognizedPoint(jointName), recognizedPoint.confidence > 0.1 {
                // Convert normalized point to image coordinates
                let visionPoint = recognizedPoint.location
                var cgPoint = VNImagePointForNormalizedPoint(visionPoint, Int(size.width), Int(size.height))
                
                // Adjust for different coordinate systems (Vision's bottom-left vs AppKit's top-left)
                cgPoint.y = size.height - cgPoint.y
                points.append(cgPoint)
            }
        }
        return points
    }
}

struct BodyJoints {
    static let links: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.neck, .rightShoulder),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.neck, .leftShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightHip),
        (.leftShoulder, .leftHip),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .leftHip)
    ]
}

class PoseDrawingView: NSView {
    var humanHandPose_observations: [VNHumanHandPoseObservation] = []
    var humanRect_observations: [VNHumanObservation] = []
    var bodyPose_observations: [VNHumanBodyPoseObservation] = []
    var clearScreenTimer: Timer = Timer()
    var kClearScreenTimeInterval = 1.0
    
    @objc func clearScreen() {
        print("clearing screen")
        self.humanRect_observations = []
        self.bodyPose_observations = []
        self.setNeedsDisplay(self.bounds)
    }
    
    let fingerJoints: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
            [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
        ]
        
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        clearScreenTimer.invalidate()
        clearScreenTimer = Timer.scheduledTimer(timeInterval: kClearScreenTimeInterval, target: self, selector: #selector(clearScreen), userInfo: nil, repeats: false)
         
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        context.setLineWidth(4.0)
        
        //VNHumanHandPoseObservation
        for observation in humanHandPose_observations {
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else { continue }
            
            let pointMap = recognizedPoints.filter { $0.value.confidence > 0.1 }.mapValues {
                // Convert normalized Vision coordinates to image-sized coordinates
                let cgPoint = VNImagePointForNormalizedPoint($0.location, Int(bounds.width), Int(bounds.height))
                return cgPoint
            }
            
            // Draw the connecting lines
            for finger in fingerJoints {
                let path = CGMutablePath()
                var firstPoint = true
                for jointName in finger {
                    if let point = pointMap[jointName] {
                        if firstPoint {
                            path.move(to: point)
                            firstPoint = false
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                context.addPath(path)
            }
            
            // Draw the points (circles)
            for point in pointMap.values {
                context.addEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            }
            
            context.setStrokeColor(CGColor(red: 1.0, green: 0, blue: 0, alpha: 1.0))
            context.setFillColor(CGColor(red: 1.0, green: 0, blue: 0, alpha: 1.0))
            context.setLineWidth(3.0)
            context.strokePath()
            context.fillPath()
        }
        
        // VNHumanObservation
        for observation in humanRect_observations {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            
            // Set up the drawing attributes.
            context.setStrokeColor(NSColor.red.cgColor)
            context.setLineWidth(2.0)
            
            // The image's coordinate system has (0,0) at the bottom-left.
            // AppKit's coordinate system has (0,0) at the bottom-left by default,
            // so we just need to handle the scaling and position.
            
//            let viewBounds = self.bounds
//            let scaleX = viewBounds.width / imageSize.width
//            let scaleY = viewBounds.height / imageSize.height
//            let scale = min(scaleX, scaleY)
//            
//            let offsetX = (viewBounds.width - imageSize.width * scale) / 2.0
//            let offsetY = (viewBounds.height - imageSize.height * scale) / 2.0
//            
            //for observation in observations {
                let boundingBox = observation.boundingBox
                
                // Convert normalized coordinates to the view's coordinates.
                let rectInViewSpace = CGRect(
                    x: /*offsetX +*/ boundingBox.origin.x,// * imageSize.width * scale,
                    y: /*offsetY +*/ boundingBox.origin.y,// * imageSize.height * scale,
                    width: boundingBox.size.width,// * imageSize.width * scale,
                    height: boundingBox.size.height// * imageSize.height * scale
                )
                
                // Draw the bounding box.
                context.stroke(rectInViewSpace)
            //}
        }
        
        // VNHumanBodyPose 2D
        context.setStrokeColor(NSColor.green.cgColor)
        
        for observation in bodyPose_observations {
            let bodyPoints = observation.getJointPoints(for: bounds.size)
            
            // Draw connections (lines)
            for (joint1Name, joint2Name) in BodyJoints.links {
                if let point1 = try? observation.recognizedPoint(joint1Name),
                   let point2 = try? observation.recognizedPoint(joint2Name),
                   point1.confidence > 0.1, point2.confidence > 0.1 {
                    
                    var cgPoint1 = VNImagePointForNormalizedPoint(point1.location, Int(bounds.width), Int(bounds.height))
                    cgPoint1.y = bounds.height - cgPoint1.y
                    
                    var cgPoint2 = VNImagePointForNormalizedPoint(point2.location, Int(bounds.width), Int(bounds.height))
                    cgPoint2.y = bounds.height - cgPoint2.y
                    
                    let fixed_cgPoint1 = cgPoint1.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                    let fixed_cgPoint2 = cgPoint2.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                    
                    context.move(to: fixed_cgPoint1)
                    context.addLine(to: fixed_cgPoint2)
                    context.strokePath()
                }
            }
            
            // Draw joints (circles)
            context.setFillColor(NSColor.red.cgColor)
            for point in bodyPoints {
                let fixed_point = point.translateFromCoreImageToUIKitCoordinateSpace(using: bounds.height)
                let rect = NSRect(x: fixed_point.x - 5, y: fixed_point.y - 5, width: 10, height: 10)
                context.fillEllipse(in: rect)
            }
        }
    }
}

extension CGPoint {
    func translateFromCoreImageToUIKitCoordinateSpace(using height: CGFloat) -> CGPoint {
        let transform = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -height);
        
        return self.applying(transform)
    }
}
