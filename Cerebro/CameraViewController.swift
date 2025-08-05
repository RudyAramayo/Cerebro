//
//  ViewController.swift
//  macOS Camera
//
//  Created by Mihail Șalari. on 4/24/17.
//  Copyright © 2017 Mihail Șalari. All rights reserved.
//

import Cocoa
import Vision

final class CameraViewController: NSViewController {
    private var cameraManager: CameraManagerProtocol!
    //public var robMainViewController: ROBMainViewController
    
    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            cameraManager = try CameraManager(containerView: view)
            cameraManager.delegate = self
        } catch {
            // Cath the error here
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
    func cameraManager(_ output: CameraCaptureOutput, didOutput sampleBuffer: CameraSampleBuffer, from connection: CameraCaptureConnection) {
        
        //process samplebuffer here
        let detectFaceRequest = VNDetectFaceRectanglesRequest { request, error in
            if let results = request.results {
                for observation in results {
                    print("observation = \(observation)")
                }
            }
        }
        
        let imageRequestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        try? imageRequestHandler.perform([detectFaceRequest])
        
    }
}
