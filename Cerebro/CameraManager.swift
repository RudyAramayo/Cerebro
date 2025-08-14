//
//  CameraManager.swift
//  macOS Camera
//
//  Created by Mihail Șalari. on 16.05.2022.
//  Copyright © 2017 Mihail Șalari. All rights reserved.
//

import AVFoundation
import Cocoa

enum CameraError: LocalizedError {
    case cannotDetectCameraDevice
    case cannotAddInput
    case previewLayerConnectionError
    case cannotAddOutput
    case videoSessionNil
    
    var localizedDescription: String {
        switch self {
        case .cannotDetectCameraDevice: return "Cannot detect camera device"
        case .cannotAddInput: return "Cannot add camera input"
        case .previewLayerConnectionError: return "Preview layer connection error"
        case .cannotAddOutput: return "Cannot add video output"
        case .videoSessionNil: return "Camera video session is nil"
        }
    }
}

typealias CameraCaptureOutput = AVCaptureOutput
typealias CameraSampleBuffer = CMSampleBuffer
typealias CameraCaptureConnection = AVCaptureConnection

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ output: CameraCaptureOutput, didOutput sampleBuffer: CameraSampleBuffer, from connection: CameraCaptureConnection)
}

protocol CameraManagerProtocol: AnyObject {
    var delegate: CameraManagerDelegate? { get set }
    
    func startSession() throws
    func stopSession() throws
}

final class CameraManager: NSObject, CameraManagerProtocol {
    
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var videoSession: AVCaptureSession!
    private var cameraDevice: AVCaptureDevice!
    
    private let cameraQueue: DispatchQueue
    
    private let containerView: NSView
    
    weak var delegate: CameraManagerDelegate?
    
    var deviceDiscoverySession: AVCaptureDevice.DiscoverySession?

    
    init(containerView: NSView) throws {
        self.containerView = containerView
        cameraQueue = DispatchQueue(label: "sample buffer delegate", attributes: [])
        
        super.init()
        
        initializeCameraDiscoverySession()
        
        //initialize existing Luxonis UVC camera...
        if let camera = deviceDiscoverySession?.devices.first ?? AVCaptureDevice.default(for: .video) {
            try prepareCamera(for: camera)
        }
    }
    
    deinit {
        previewLayer = nil
        videoSession = nil
        cameraDevice = nil

        // Remove observers when the object is deallocated
        deviceDiscoverySession?.removeObserver(self, forKeyPath: "devices")
        NotificationCenter.default.removeObserver(self)
    }
    
    func initializeCameraDiscoverySession() {
        // 1. Create an AVCaptureDeviceDiscoverySession
        deviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        // 2. Observe changes to the 'devices' property
        deviceDiscoverySession?.addObserver(
            self,
            forKeyPath: "devices",
            options: .new,
            context: nil
        )

        // 3. Register for device connected/disconnected notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceConnected(_:)),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )

    }
    
    // KVO callback
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey : Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "devices", let newDevices = change?[.newKey] as? [AVCaptureDevice] {
            print("KVO: Available devices changed. New list: \(newDevices.map { $0.localizedName })")
            // Handle the updated list of devices here
        }
    }

    // ---------------
    // Luxonis UVC 3D Color/Depth Camera
    // ---------------
    // NotificationCenter callbacks
    // KVO: Available devices changed. New list: ["Luxonis UVC Camera"]
    // Notification: Device connected: Luxonis UVC Camera
    // device.manufacturer = Luxonis UVC Camera
    // device.manufacturer = UVC Camera VendorID_999 ProductID_63035
    // device.manufacturer = Intel Corporation
    // device.manufacturer = 0x261300003e7f63b
    // ---------------
    // Tonor USB Mic
    // ---------------
    // device.manufacturer = TONOR G11 USB microphone
    // device.manufacturer = TONOR G11 USB microphone :0D8C:0134
    // device.manufacturer = C-Media Electronics Inc.
    // device.manufacturer = AppleUSBAudioEngine:C-Media Electronics Inc.:TONOR G11 USB microphone:20230624:1
    // ---------------
    @objc func deviceConnected(_ notification: Notification) {
        if let device = notification.object as? AVCaptureDevice {
            print("Notification: Device connected: \(device.localizedName)")
            // Handle the new camera connection
            //TODO: Check the parameters of this camera and make sure its the one we want...
            print("device.manufacturer = \(device.localizedName)")
            print("device.manufacturer = \(device.modelID)")
            print("device.manufacturer = \(device.manufacturer)")
            print("device.manufacturer = \(device.uniqueID)")
            
            do {
                try prepareCamera(for: device)
            } catch {
                print("error preparing camera! \(error)")
            }
        }
    }

    @objc func deviceDisconnected(_ notification: Notification) {
        if let device = notification.object as? AVCaptureDevice {
            print("Notification: Device disconnected: \(device.localizedName)")
            // Handle the camera disconnection
        }
    }

    
    private func prepareCamera(for newCameraDevice: AVCaptureDevice?) throws {
        videoSession = AVCaptureSession()
        videoSession.sessionPreset = AVCaptureSession.Preset.photo
        previewLayer = AVCaptureVideoPreviewLayer(session: videoSession)
        previewLayer.videoGravity = .resizeAspectFill
        
        cameraDevice = newCameraDevice
        
        if cameraDevice != nil  {
            do {
                let input = try AVCaptureDeviceInput(device: cameraDevice)
                if videoSession.canAddInput(input) {
                    videoSession.addInput(input)
                } else {
                    throw CameraError.cannotAddInput
                }
                
                if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                } else {
                    throw CameraError.previewLayerConnectionError
                }
                
                previewLayer.frame = containerView.bounds
                containerView.layer = previewLayer
                containerView.wantsLayer = true
                
            } catch {
                throw CameraError.cannotDetectCameraDevice
            }
        }
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        if videoSession.canAddOutput(videoOutput) {
            videoSession.addOutput(videoOutput)
        } else {
            throw CameraError.cannotAddOutput
        }
    }
    
    func startSession() throws {
        if let videoSession = videoSession {
            if !videoSession.isRunning {
                cameraQueue.async {
                    videoSession.startRunning()
                }
            }
        } else {
            throw CameraError.videoSessionNil
        }
    }
    
    func stopSession() throws {
        if let videoSession = videoSession {
            if videoSession.isRunning {
                cameraQueue.async {
                    videoSession.stopRunning()
                }
            }
        } else {
            throw CameraError.videoSessionNil
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.cameraManager(output, didOutput: sampleBuffer, from: connection)
    }
}
