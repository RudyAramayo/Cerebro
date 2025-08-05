//
//  VisionTrackerProcessor.m
//  NiTECamera
//
//  Created by Rob Makina on 8/2/19.
//  Copyright © 2019 Apple. All rights reserved.
//

#import "VisionTrackerProcessor.h"
#import "TrackedPolyRect.h"
//#import "HeatmapPostProcessor-swift.h"

//#import <ROBNiteController/ROBNiteController-Swift.h>
//#import "NiTECamera-Swift.h"
//#import "ROBNiteController-Swift.h"

#import <Vision/Vision.h>


API_AVAILABLE(macos(10.15))
@interface VisionTrackerProcessor ()
//Tracking properties
@property (readwrite, retain) id trackingLevel;
@property (readwrite, retain) NSMutableDictionary *inputObservations;
@property (readwrite, retain) NSMutableDictionary *trackedObjects;
@property (readwrite, assign) BOOL trackingFailedForAtLeastOneObject;
@property (readwrite, retain) VNImageRequestHandler *imageRequestHandler;
@property (readwrite, retain) VNSequenceRequestHandler *sequenceRequestHandler;
@property (readwrite, retain) NSMutableArray *tracking_initialRectObservations;
@property (readwrite, retain) NSMutableArray *trackingRequests;

//ImageRecognition properties
@property (readwrite, retain) NSMutableArray *imageAnalysisRequests;
@property (readwrite, retain) VNDetectRectanglesRequest *rectangleDetectionRequest;

@property (readwrite, retain) VNDetectFaceCaptureQualityRequest *faceQualityDetectionRequest;
@property (readwrite, assign) bool isCapturingFaces;

@property (readwrite, retain) VNDetectFaceRectanglesRequest *faceDetectionRequest;
@property (readwrite, retain) VNDetectFaceLandmarksRequest *faceLandmarkRequest;
@property (readwrite, retain) VNDetectTextRectanglesRequest *textDetectionRequest;
@property (readwrite, retain) VNDetectBarcodesRequest *barcodeDetectionRequest;
@property (readwrite, retain) VNDetectHumanRectanglesRequest *humanDetectionRequest;

@property (readwrite, retain) VNRecognizeAnimalsRequest *animalsRequest;
@property (readwrite, retain) VNDetectHorizonRequest *horizonRequest;
@property (readwrite, retain) VNGenerateImageFeaturePrintRequest *imageFeaturePriuntRequest;
@property (readwrite, retain) VNGenerateAttentionBasedSaliencyImageRequest *imageAttentionSaliency;
@property (readwrite, retain) VNGenerateObjectnessBasedSaliencyImageRequest *imageObjectnessSaliency;
//@property (readwrite, retain) VNDetectHumanBodyPoseRequest *humanBodyPoseDetectionRequest;
@property (readwrite, retain) VNTranslationalImageRegistrationRequest *translationRequest;

//let request = VNDetectHumanBodyPoseRequest(completionHandler: bodyPoseHandler)




//@property (readwrite, retain) VNDetectAnimalRectanglesRequest *animalDetectionRequest;


//CoreMLRecognition properties
@property (readwrite, retain) VNCoreMLRequest *coreml_request;
@property (readwrite, retain) VNCoreMLRequest *pose_coreml_request;
//@property (readwrite, retain) HeatmapPostProcessor *postProcessor;
@property (readwrite, retain) NSMutableArray *mvfilters;

@end

@implementation VisionTrackerProcessor


- (void) initializeVisionProcessor
{
    self.trackingRequests = [NSMutableArray new];
    self.imageAnalysisRequests = [NSMutableArray new];
    
    self.tracking_initialRectObservations = [NSMutableArray new];
    
    self.inputObservations = [NSMutableDictionary new];
    self.trackedObjects = [NSMutableDictionary new];
    
    self.sequenceRequestHandler = [VNSequenceRequestHandler new];
    self.objectsToTrack = [NSMutableArray new];
    
    self.imageAnalysisRequests = [self createVisionRequests];
    
    //self.postProcessor = [HeatmapPostProcessor new];
    self.mvfilters = [NSMutableArray new];
}


- (void) performImageAnalysis:(CGImageRef)frame
{
    
    // Create a request handler.
    self.imageRequestHandler = [[VNImageRequestHandler alloc] initWithCGImage:frame
                                                                  orientation:kCGImagePropertyOrientationUp
                                                                      options:@{}];
    
    // Send the requests to the request handler.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSError *error;
        
        [self.imageRequestHandler performRequests:self.imageAnalysisRequests error:&error];
        
        if (error)
        {
            NSLog(@"error %@", error.localizedDescription);
        }
    });
}


- (void) displayFaceObservations:(NSArray *)faceObservations
{
    
}


- (void) saveFaceObservations:(NSArray *)faceObservations
{
    
}


- (NSMutableArray<VNRequest *> *) createVisionRequests
{
    self.rectangleDetectionRequest = [[VNDetectRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        //handleDetectedRectangles()
        NSArray<VNRectangleObservation *> *observations = [request results];
        
        for (VNRectangleObservation *observation in observations)
        {
            NSLog(@"rectangle = %@", observation);
        }
    }];
    self.rectangleDetectionRequest.maximumObservations = 8;
    self.rectangleDetectionRequest.minimumConfidence = 0.6;
    self.rectangleDetectionRequest.minimumAspectRatio = 0.3;
    
    self.faceQualityDetectionRequest = [[VNDetectFaceCaptureQualityRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        
        NSArray *faceObservations = [request results];
        
        [self displayFaceObservations:faceObservations];
        if (self.isCapturingFaces) {
            [self saveFaceObservations:faceObservations];
        }
    }];
    
    self.faceDetectionRequest = [[VNDetectFaceRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        //handleDetectedFaces()
        NSArray<VNFaceObservation *> *observations = [request results];
        
        for (VNFaceObservation *observation in observations)
        {
            NSLog(@"face = %@", observation);
        }
    }];
    self.faceLandmarkRequest = [[VNDetectFaceLandmarksRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        //handleDetectedFaceLandmarks()
        NSArray<VNFaceObservation *> *observations = [request results];
        
        for (VNFaceObservation *observation in observations)
        {
            NSLog(@"faceLandmark = %@", observation);
        }
    }];
    
    self.textDetectionRequest = [[VNDetectTextRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        //handleDetectedText()
        NSArray<VNTextObservation *> *observations = [request results];
        
        for (VNTextObservation *observation in observations)
        {
            NSLog(@"text = %@", [observation characterBoxes]);
        }
    }];
  
    self.barcodeDetectionRequest = [[VNDetectBarcodesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        //handleDetectedBarcodes()
        NSArray<VNBarcodeObservation *> *observations = [request results];
        
        for (VNBarcodeObservation *observation in observations)
        {
            NSLog(@"barcode = %@", observation.payloadStringValue);
            NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:@"do shell script \"say %@\"", observation.payloadStringValue]];
            [script executeAndReturnError:nil];
        }
    }];
    
    self.humanDetectionRequest = [[VNDetectHumanRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        NSArray<VNDetectedObjectObservation *> *observations = [request results];
        if (!error)
        {
            [self.delegate didTrackHuman:observations];
        }
    }];
    
    
    NSError *vnCoreMLError;
    NSError *mlmodelError;
    /*
    VNCoreMLModel *coreml_model = [VNCoreMLModel modelForMLModel:
      [MLModel modelWithContentsOfURL:
       [[NSBundle mainBundle] URLForResource:@"ObjectDetector" withExtension:@"mlmodelc"] error:&mlmodelError] error:&vnCoreMLError];
    
    self.coreml_request = [[VNCoreMLRequest alloc] initWithModel:coreml_model completionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        
        //handleCoreMLObservations()
        NSArray<VNCoreMLFeatureValueObservation *> *observations = [request results];
        
        for (VNRecognizedObjectObservation *observation in observations)
        {
            for (VNClassificationObservation *classificationObservation in observation.labels)
            {
                NSLog(@"Object = %@", classificationObservation.identifier);
                if ([classificationObservation.identifier isEqualToString:@"Banana"] &&
                    classificationObservation.confidence > 0.8)
                {
                    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:@"do shell script \"say bananna\""];
                    [script executeAndReturnError:nil];
                }
            }
            
        }
        
    }];
    */
    
    /*
    VNCoreMLModel *pose_coreml_model = [VNCoreMLModel modelForMLModel:
                                   [MLModel modelWithContentsOfURL:
                                    [[NSBundle mainBundle] URLForResource:@"model_cpm" withExtension:@"mlmodelc"] error:&mlmodelError] error:&vnCoreMLError];
    
    self.pose_coreml_request = [[VNCoreMLRequest alloc] initWithModel:pose_coreml_model completionHandler:^(VNRequest * _Nonnull request, NSError * _Nullable error) {
        
        //handleCoreMLObservations()
        NSArray<VNCoreMLFeatureValueObservation *> *observations = [request results];
        
        for (VNRecognizedObjectObservation *observation in observations)
        {
            NSLog(@"-------- HUMAN POSE DATA:");
            MLMultiArray *heatmaps = [[(id)observation featureValue] multiArrayValue];
            
            // ===================================================================
            // ========================= post-processing =========================
            
            // ------------------ convert heatmap to point array -----------------
            //var predictedPoints = postProcessor.convertToPredictedPoints(from: heatmaps)
            NSMutableArray *predictedPoints = [[self.postProcessor convertToPredictedPointsFrom:heatmaps isFlipped:false] mutableCopy];
            
            // --------------------- moving average filter -----------------------
            if ([predictedPoints count] != [self.mvfilters count])
            {
                //mvfilters = predictedPoints.map { _ in MovingAverageFilter(limit: 3) }
                
                self.mvfilters = [NSMutableArray new];
                for (int i=0; i < predictedPoints.count; i++)
                {
                    [self.mvfilters addObject:[[MovingAverageFilter alloc] initWithLimit:3]];
                    
                    //id predictedPoint = point;
                    //id filter = [self.mvfilters lastObject];
                    //[filter addObject:predictedPoint];
                }
            }
            //for (predictedPoint, filter) in zip(predictedPoints, mvfilters) {
            //    filter.add(element: predictedPoint)
            //}
            for (int i=0; i < self.mvfilters.count; i++)
            {
                PredictedPoint *predictedPoint = predictedPoints[i];
                id filter = self.mvfilters[i];
                [filter addWithElement:predictedPoint];
            }
            //predictedPoints = mvfilters.map { $0.averagedValue() }
            for (int i =0; i < self.mvfilters.count; i++)
            {
                MovingAverageFilter *filter = self.mvfilters[i];
                predictedPoints[i] = [filter averagedValue];
            }
            // ===================================================================
            
            // ===================================================================
            // ======================= display the results =======================
            
            dispatch_async(dispatch_get_main_queue(), ^{
                //self.jointView.bodyPoints = predictedPoints;
                //NSLog(@"%@", predictedPoints);
                bool maxConfidenceThresholdExceeded = true;
                int invalidatedPointsCount = 0;
                for (int i=0; i < predictedPoints.count; i++)
                {
                    if (((PredictedPoint *)predictedPoints[i]).maxConfidence < 0.5)
                    {
                        invalidatedPointsCount++;
                    }
                }
                
                NSLog(@"invalidated %d", invalidatedPointsCount);
                if (invalidatedPointsCount > 5)
                    maxConfidenceThresholdExceeded = false;
                    
                if (maxConfidenceThresholdExceeded)
                {
                    for (int i=0; i < predictedPoints.count; i++)
                    {
                        NSLog(@"%f,%f - %f", ((PredictedPoint *)predictedPoints[i]).maxPoint.x, ((PredictedPoint *)predictedPoints[i]).maxPoint.y, ((PredictedPoint *)predictedPoints[i]).maxConfidence);
                    }
                }
                
            });
            //DispatchQueue.main.sync {
                // draw line
            //    self.jointView.bodyPoints = predictedPoints
                
                // show key points description
            //    self.showKeypointsDescription(with: predictedPoints)
                
                // end of measure
            //    self.👨‍🔧.🎬🤚()
            //}
        }
        
    }];
     
    */
    if (vnCoreMLError || mlmodelError)
    {
        NSLog(@"Error = %@ \n %@", vnCoreMLError.localizedDescription, mlmodelError.localizedDescription);
    }
    
    //---------------------------------------------
    //------ Add all requests for processing ------
    NSMutableArray<VNRequest *> *requests = [NSMutableArray new];
    
    //[requests addObject:self.rectangleDetectionRequest];
    // Break rectangle & face landmark detection into 2 stages to have more fluid feedback in UI.
    //[requests addObject:self.faceDetectionRequest];
    //[requests addObject:self.faceLandmarkRequest];
    //[requests addObject:self.textDetectionRequest];
    //[requests addObject:self.barcodeDetectionRequest];
    //[requests addObject:self.humanDetectionRequest];
    //st[requests addObject:self.coreml_request];
    //[requests addObject:self.pose_coreml_request];
    // Return grouped requests as a single array.
    return requests;
}


- (void) initializeTracking:(CGImageRef) frame
{
    //-------------------------
    //INITIALIZE TRACKING
    // Create initial observations
    self.sequenceRequestHandler = [VNSequenceRequestHandler new];
    
    if ([self.trackingRequests count] > 0)
    {
        [[self.trackingRequests objectAtIndex:0] setLastFrame:true];
        [self.trackingRequests removeObjectAtIndex:0];
    }
    for ( id rect in self.objectsToTrack) {
        VNDetectedObjectObservation *inputObservation = [VNDetectedObjectObservation observationWithBoundingBox:[rect boundingBox]];
        [self.inputObservations setValue:inputObservation forKey:inputObservation.uuid.UUIDString];
        [self.trackedObjects setValue:rect forKey:inputObservation.uuid.UUIDString];
    }
    
    //-------------------------
}


- (void) performTracking:(CGImageRef)frame {
    NSMutableArray *rects = [NSMutableArray new];
    self.trackingRequests = [NSMutableArray new];

    
    for ( NSString *inputObservationKey in self.inputObservations.allKeys) {
        VNDetectedObjectObservation *inputObservation = [self.inputObservations valueForKey:inputObservationKey];
        VNTrackObjectRequest *request = [[VNTrackObjectRequest alloc] initWithDetectedObjectObservation:inputObservation];
        request.trackingLevel = VNRequestTrackingLevelFast;
        [self.trackingRequests addObject:request];
    }
    
    // Perform array of requests
    NSError *error;
    [self.sequenceRequestHandler performRequests:self.trackingRequests onCGImage:frame orientation:kCGImagePropertyOrientationUp error:&error];
    if (error)
        NSLog(@"error = %@", [error localizedDescription]);
    
    for (id processedRequest in self.trackingRequests) {
        VNDetectedObjectObservation *observation;
        if ( [[processedRequest results] count] > 0 )
        {
            observation = [processedRequest results][0];
            //NSLog(@"results - %@",[processedRequest results]);
            
            //NSLog(@"processedRequestObservation - %@",observation.uuid);
            //NSLog(@"trackedObjects - %@",self.trackedObjects);
            //NSLog(@"inputObservations - %@",self.inputObservations);
            //id knownRect = [self.trackedObjects valueForKey:observation.uuid.UUIDString];
            TrackedPolyRect *trackedPolyRect = [TrackedPolyRect new];
            [trackedPolyRect setObservation:observation color:[NSColor blueColor]];
            [trackedPolyRect setUuid:observation.uuid.UUIDString];
            
            [rects addObject:trackedPolyRect];
                // Initialize inputObservation for the next iteration
            [self.inputObservations setValue:observation forKey:observation.uuid.UUIDString];
        }
    }
    
    // Draw results
    [self.delegate displayFrame:frame withAffineTransform:CGAffineTransformIdentity rects:rects];
}

@end
