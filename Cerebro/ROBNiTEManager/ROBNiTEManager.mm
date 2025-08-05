////
////  ROBNiTEManager.m
////  Cerebro
////
////  Created by Rob Makina on 1/12/18.
////  Copyright © 2018 Rob Makina. All rights reserved.
////
//#include <opencv2/opencv.hpp>
//
//#include "NiTE.h"
//
//#import "ROBNiTEManager.h"
//#import "FreenectPCL.h"
//#import "TrackedPolyRect.h"
//#import "ROBRTSPController.h"
//
//#include <pcl/point_cloud.h>
//#include <pcl/point_types.h>
//using namespace pcl;
//
//#include <Foundation/Foundation.h>
//#include <Cocoa/Cocoa.h>
//#include <vector>
//
//@interface ROBNiTEManager () <VisionTrackerProcessorDelegate>
//{
//    FreenectPCL *_freenectPCLServer;
//    NSTimer *cameraFrameTimer;
//    bool didInitializeTracking;
//    NSString *trackingRectUUID_1;
//    NSString *trackingRectUUID_2;
//
//    int frameCounter;
//    int rtspFrameNumber;
//
//    dispatch_queue_t imageAnalysisQueue;
//}
//
//@property (readwrite, retain) ROBRTSPController *robrtspcontroller;
//
//
//
//
//
//@end
//
//@implementation ROBNiTEManager
//
//
//- (void) initializeNiTEOther
//{
//    [self initializeNiTEManager];
//}
//
//
//- (void) reinitializeTracking
//{
//    self->didInitializeTracking = false;
//}
//
//
//- (void) shutdownNiTEManager
//{
//    [_freenectPCLServer closeCameraCapture];
//}
//
//
//- (void) initializeNiTEManager
//{
//    frameCounter = 0;
//    rtspFrameNumber = 1;
//    imageAnalysisQueue = dispatch_queue_create("com.orbitusrobotics.NiTE.visionProcessorQueue", 0);
//
//    didInitializeTracking = false;
//    _freenectPCLServer = [FreenectPCL new];
//    self.visionProcessor = [VisionTrackerProcessor new];
//    self.visionProcessor.delegate = self;
//    [self.visionProcessor initializeVisionProcessor];
//    trackingRectUUID_1 = nil;
//    trackingRectUUID_2 = nil;
//
//    [[ROBRTSPController server] startup];
//    NSString *url = [[ROBRTSPController server] getURL];
//    NSLog(@"serverurl = %@", url);
//
//    TrackedPolyRect *tc = [TrackedPolyRect new];
//
//    CGSize trackingSize = CGSizeMake(60, 60);
//    NSLog(@"frameWidthHeight = %f,%f", self.viewFrame.size.width, self.viewFrame.size.height);
//    //480x360
//
//    [tc setCGRect:CGRectMake((self.viewFrame.size.width/2.0-trackingSize.width/2.0)/self.viewFrame.size.width,
//                             (self.viewFrame.size.height/2.0-trackingSize.height/2.0)/self.viewFrame.size.height,
//                             trackingSize.width/self.viewFrame.size.width,
//                             trackingSize.height/self.viewFrame.size.height) color:[NSColor blueColor]];
//
//    [self.visionProcessor.objectsToTrack addObject:tc];
//
//
//    //_freenectPCLServer.renderer = _renderer;
//    //dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(void){
//    dispatch_async(self->imageAnalysisQueue, ^{
//        //Background Thread
//        //[self->_freenectPCLServer beginCapture]; //Starts camera capture on main thread
//        [self->_freenectPCLServer startCameraCapture]; //Starts camera capture on current thread
//    });
//
//    __weak ROBNiTEManager * weakSelf = self;
//
//    cameraFrameTimer = [NSTimer scheduledTimerWithTimeInterval:.03 repeats:YES block:^(NSTimer * _Nonnull timer) {
//
//        __strong ROBNiTEManager * strongSelf = weakSelf;
//
//        dispatch_async(strongSelf->imageAnalysisQueue, ^{
//        //dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
//            NSDate *date = [NSDate date];
//
//            pcl::PointCloud<PointXYZRGB>::Ptr cloud;
//            //(pcl::PointCloud<PointXYZRGB>::Ptr)
//
//            //--------
//            //Process cloud data example
//
//            /*cloud = [self->_freenectPCLServer processCameraCloudFrame];
//             //Negative x,y transform
//             for (size_t i = 0; i < cloud->points.size(); ++i)
//             {
//             cloud->points[i].x = -cloud->points[i].x;
//             cloud->points[i].y = -cloud->points[i].y;
//             cloud->points[i].z = cloud->points[i].z;
//             cloud->points[i].r = cloud->points[i].r;
//             cloud->points[i].g = cloud->points[i].g;
//             cloud->points[i].b = cloud->points[i].b;
//
//             //printf("(%f,%f,%f) - %hhu %hhu %hhu ", cloud->points[i].x, cloud->points[i].y, cloud->points[i].z, cloud->points[i].r, cloud->points[i].g, cloud->points[i].b);
//             }
//             */
//            //--------
//            // Depth comes back as weird colors...4 channels should only be 1?
//            //cv::Mat depth = [self->_freenectPCLServer processCameraFrame];
//            //NSImage *image = [ROBNiTEManager NSImageFromDepthCVMat:depth];
//            //--------
//            // Color comes back perfectly
//            cv::Mat color = [strongSelf->_freenectPCLServer processCameraFrame];
//            cv::Mat depth = [strongSelf->_freenectPCLServer processDepthCameraFrame];
//
//            //cv::MatIterator_<float> _it = depth.begin<float>();
//            //for(;_it!=depth.end<float>(); _it++){
//            //    std::cout << *_it << std::endl;
//            //}
//
//            //CV_32FC1 at (512.0, 424.0)
//
//            //3. Prints out the top 10 rows of the image...0 means no value was determined 3000 was a general value for the
//            //std::cout << depth.rowRange(0, 10) << std::endl;
//
//            //424 rows, 512 columns --> 512 x-width and 424 y-height
//            //std::cout << depth.rows << ", " << depth.cols << std::endl;
//            //std::cout << depth.rowRange(400, 424) << std::endl;
//
//            //cv::Mat collision_depth_box = depth(cv::Rect(226,400,60,24)); //226 = 256-(60/2) --- 400 is bottom row + 24 rows
//            //std::cout << collision_depth_box.rows << ", " << collision_depth_box.cols << std::endl;
//            //std::cout << collision_depth_box.rowRange(0, 24) << std::endl;
//
//            /*
//            float average = 0;
//            int total = 0;
//
//            for (int y=400; y < 424; y++)
//            {
//                for (int x=226; x < 226+60; x++)
//                {
//                    //std::cout << depth.at<Float32>(y, x) << ", ";
//                    Float32 depthValue = depth.at<Float32>(y, x);
//                    if (depthValue > 0 && !isnan(depthValue))
//                    {
//                        average += depthValue;
//                        total++;
//                    }
//
//                }
//                //std::cout << std::endl;
//            }
//            average /= total;
//            std::cout << "\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\taverage =" << average << "\t\t" << total << std::endl;
//             */
//
//            //WORKINGJ+: PLEASE REENABLE FLOOR TEST
//            //Attempts to get the floor depth pixels so we can detect for collisions!
//            float average[100];
//
//            for (int y=324; y < 424; y++)
//            {
//                int total = 0;
//
//                for (int x=226; x < 226+60; x++)
//                {
//                    Float32 depthValue = depth.at<Float32>(y, x);
//                    if (depthValue > 0 && !isnan(depthValue))
//                    {
//                        average[y-324] += depthValue;
//
//                        total++;
//                    }
//                }
//
//                if (total > 0)
//                {
//                    average[y-324] /= total;
//                }
//                else {
//                    //std::cout << "no ave" << std::endl;
//                }
//                //Per row totals
//                //std::cout << "\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\taverage =" << average[y-324] << "\t\t" << total << std::endl;
//            }
//            cv::Point pt1;
//            int count = 10;
//
//            //vector<cv::Point> points(count)();
//            //std::vector<int> vecDraw(100);
//            //std::vector<int> pointsArray;
//            std::vector<cv::Point> pointsArray;
//
//            for (int j=100; j > 0; j-=10)
//            {
//                //std::cout << average[j-1] << ", "; //Great data is here... exact metric for incline
//                //points->push_back(average[j]);
//                cv::Point pt1;
//                pt1.x = -j + 100;
//                pt1.y = average[j-1];
//                pointsArray.push_back(pt1);
//            }
//            //std::cout << pointsArray << std::endl;
//
//            cv::Vec4f line;
//            cv::fitLine(pointsArray, line, cv::DIST_L1, 1, 0.1, 0.1);
//            //std::cout << line << std::endl;
//
//
//            //8UC1 is the type of the MAT... what kind of mat is the depth mat???
//            //std::cout << depth.type() << std::endl;
//            //std::cout << depth.channels() << std::endl;
//            //std::cout << depth.elemSize() << std::endl;
//            //std::cout << depth.elemSize1() << std::endl;
//
//            //if ( depth.type() == CV_32F)
//            //{
//            //    std::cout << "Muahahahah - i love kierie" << std::endl;
//            //}
//
//            //Print out individual elements
//            //for (int y=0; y < 424; y++)
//            //{
//            //    for (int x=0; x < 512; x++)
//            //    {
//            //        std::cout << depth.at<Float32>(y, x) << ", ";
//            //    }
//            //    std::cout << std::endl;
//            //}
//
//            NSImage *image = [strongSelf NSImageFromCVMat:color depth:depth];
//
//            //--------
//
//            dispatch_async(dispatch_get_main_queue(), ^{
//                //[strongSelf.imageView setImage:image];
//            });
//
//            //NSTimeInterval deltaTime = [date timeIntervalSinceNow];
//            //printf("frameTime = %f\n", -deltaTime);
//            //NSLog(@"timeStamp");
//        });
//    }];
//}
//
//
//- (void) didTrackHuman:(NSArray *) humanObservations
//{
//    //NSLog(@"%@", humanObservations);
//    [self.delegate didTrackHumans:humanObservations];
//}
//
//
//- (void) createResizedSampleBuffer:(CGImageRef)frame
//                                           size:(CGSize)finalSize
//                                           time:(CMTime)frameTime
//                                   sampleBuffer:(CMSampleBufferRef *)sampleBuffer
//{
//    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
//    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
//
//    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
//    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width, finalSize.height), frame);
//    //CGImageRelease(cgImageFromBytes); // <----- Release me here?!?!
//    CGContextRelease(imageContext);
//
//    CVPixelBufferRef pixel_buffer = NULL;
//    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, nil, NULL, NULL, &pixel_buffer);
//    CMVideoFormatDescriptionRef videoInfo = NULL;
//    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
//
//    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
//
//    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
//    CFRelease(videoInfo);
//    CVPixelBufferRelease(pixel_buffer);
//    //This is a hack workaround to release the memory properly but
//    //not crash the app while it is still using it
//    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        free(imageData);
//    });
//}
//
//
//- (void) createResizedSampleBufferWithColorImageRef:(CGImageRef)rgbFrame
//                                      depthImageRef:(CGImageRef)depthFrame
//                                               size:(CGSize)finalSize
//                                               time:(CMTime)frameTime
//                                       sampleBuffer:(CMSampleBufferRef *)sampleBuffer
//{
//    GLubyte *imageData = (GLubyte *) calloc(1, (int)finalSize.width * (int)finalSize.height * 4);
//    CGColorSpaceRef genericRGBColorspace = CGColorSpaceCreateDeviceRGB();
//
//    CGContextRef imageContext = CGBitmapContextCreate(imageData, (int)finalSize.width, (int)finalSize.height, 8, (int)finalSize.width * 4, genericRGBColorspace,  kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
//    //1920x1080
//    //512x424
//    CGContextDrawImage(imageContext, CGRectMake(0.0, 0.0, finalSize.width/2.0, finalSize.height), rgbFrame);
//    CGContextDrawImage(imageContext, CGRectMake(finalSize.width/2.0, 0.0, finalSize.width/2.0, finalSize.height), depthFrame);
//
//    CGContextRelease(imageContext);
//    CGColorSpaceRelease(genericRGBColorspace);
//
//    CVPixelBufferRef pixel_buffer = NULL;
//    CVPixelBufferCreateWithBytes(kCFAllocatorDefault, finalSize.width, finalSize.height, kCVPixelFormatType_32BGRA, imageData, finalSize.width * 4, nil, NULL, NULL, &pixel_buffer);
//    CMVideoFormatDescriptionRef videoInfo = NULL;
//    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel_buffer, &videoInfo);
//
//    CMSampleTimingInfo timing = {frameTime, frameTime, kCMTimeInvalid};
//
//    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixel_buffer, YES, NULL, NULL, videoInfo, &timing, sampleBuffer);
//    CFRelease(videoInfo);
//    CVPixelBufferRelease(pixel_buffer);
//    //This is a hack workaround to release the memory properly but
//    //not crash the app while it is still using it
//    //dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        free(imageData);
//    //});
//}
//
//- (NSImage *)NSImageFromDepthCVMat:(cv::Mat)cvMat {
//    NSData *data = [NSData dataWithBytes:cvMat.data length:cvMat.elemSize()*cvMat.total()];
//
//    CGColorSpaceRef colorSpace;
//    CGBitmapInfo bitmapInfo;
//
//    if (cvMat.elemSize1() == 1) {
//        colorSpace = CGColorSpaceCreateDeviceGray();
//        bitmapInfo = kCGImageAlphaNone | kCGBitmapByteOrderDefault;
//    } else {
//        colorSpace = CGColorSpaceCreateDeviceRGB();
//        bitmapInfo = kCGBitmapByteOrder32Little | (
//                                                   cvMat.elemSize() == 3? kCGImageAlphaNone : kCGImageAlphaNoneSkipFirst
//                                                   );
//    }
//
//    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
//
//    // Creating CGImage from cv::Mat
//    CGImageRef imageRef = CGImageCreate(
//                                        cvMat.cols,                 //width
//                                        cvMat.rows,                 //height
//                                        32,                          //bits per component
//                                        32 * cvMat.elemSize1(),       //bits per pixel
//                                        cvMat.step[0],              //bytesPerRow
//                                        colorSpace,                 //colorspace
//                                        bitmapInfo,                 // bitmap info
//                                        provider,                   //CGDataProviderRef
//                                        NULL,                       //decode
//                                        false,                      //should interpolate
//                                        kCGRenderingIntentDefault   //intent
//                                        );
//
//    // Getting UIImage from CGImage
//
//    NSImage *finalImage = [[NSImage alloc] initWithCGImage:imageRef size:(NSSize){ 1920.0, 1080.0 }];
//    CGImageRelease(imageRef);
//    CGDataProviderRelease(provider);
//    CGColorSpaceRelease(colorSpace);
//
//    return finalImage;
//}
//
//- (NSImage *)NSImageFromCVMat:(cv::Mat)cvMat depth:(cv::Mat)depth_cvMat {
//    NSData *data = [NSData dataWithBytesNoCopy:cvMat.data length:cvMat.elemSize()*cvMat.total()];
//    NSData *depth_data = [NSData dataWithBytesNoCopy:depth_cvMat.data length:depth_cvMat.elemSize()*depth_cvMat.total()];
//
//    CGColorSpaceRef colorSpace;
//    CGColorSpaceRef colorSpace_depth;
//    CGBitmapInfo bitmapInfo;
//    CGBitmapInfo bitmapInfo_depth;
//
//    //std::cout << depth_cvMat.elemSize() << std::endl;
//    //std::cout << depth_cvMat.elemSize1() << std::endl;
//    //std::cout << depth_cvMat.step[0] << std::endl;
//
//
//    if (cvMat.elemSize() == 1) {
//        colorSpace = CGColorSpaceCreateDeviceGray();
//        bitmapInfo = kCGImageAlphaNone | kCGBitmapByteOrderDefault;
//    } else {
//        colorSpace = CGColorSpaceCreateDeviceRGB();
//        // OpenCV defaults to either BGR or ABGR. In CoreGraphics land,
//        // this means using the "32Little" byte order, and potentially
//        // skipping the first pixel. These may need to be adjusted if the
//        // input matrix uses a different pixel format.
//        bitmapInfo = kCGBitmapByteOrder32Little | (
//                                                   cvMat.elemSize() == 3? kCGImageAlphaNone : kCGImageAlphaNoneSkipFirst
//                                                   );
//    }
//    if (depth_cvMat.elemSize1() == 1) {
//        colorSpace_depth = CGColorSpaceCreateDeviceGray();
//        bitmapInfo_depth = kCGImageAlphaNone | kCGBitmapByteOrderDefault;
//    } else {
//        colorSpace_depth = CGColorSpaceCreateDeviceRGB();
//        // OpenCV defaults to either BGR or ABGR. In CoreGraphics land,
//        // this means using the "32Little" byte order, and potentially
//        // skipping the first pixel. These may need to be adjusted if the
//        // input matrix uses a different pixel format.
//        bitmapInfo_depth = kCGBitmapByteOrder32Little | (
//                                                   depth_cvMat.elemSize() == 3? kCGImageAlphaNone : kCGImageAlphaNoneSkipFirst
//                                                   );
//    }
//
//    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
//    CGDataProviderRef provider_depth = CGDataProviderCreateWithCFData((__bridge CFDataRef)depth_data);
//
//    // Creating CGImage from cv::Mat
//
//    CGImageRef imageRef = CGImageCreate(
//                                        cvMat.cols,                 //width
//                                        cvMat.rows,                 //height
//                                        8,                          //bits per component
//                                        8 * cvMat.elemSize(),       //bits per pixel
//                                        cvMat.step[0],              //bytesPerRow
//                                        colorSpace,                 //colorspace
//                                        bitmapInfo,                 // bitmap info
//                                        provider,                   //CGDataProviderRef
//                                        NULL,                       //decode
//                                        false,                      //should interpolate
//                                        kCGRenderingIntentDefault   //intent
//                                        );
//
//    CGImageRef depthImageRef = CGImageCreate(
//                                        depth_cvMat.cols,           //width
//                                        depth_cvMat.rows,           //height
//                                        8,                          //bits per component
//                                        32,                         //bits per pixel
//                                        depth_cvMat.step[0],        //bytesPerRow
//                                        colorSpace_depth,           //colorspace
//                                        bitmapInfo_depth,           // bitmap info
//                                        provider_depth,             //CGDataProviderRef
//                                        NULL,                       //decode
//                                        false,                      //should interpolate
//                                        kCGRenderingIntentDefault   //intent
//                                        );
//
//    // Getting NSImage from CGImage
//
//    //-----------
//    // RTSP Transmission
//    CMSampleBufferRef sampleBufferFrame;
//
//    CMTime frameTime = CMTimeMake(rtspFrameNumber, 10);
//    rtspFrameNumber++;
//
//    //[self createResizedSampleBuffer:imageRef
//    //        size:CGSizeMake(640/2.0, 480/2.0)
//    //        time:frameTime
//    //sampleBuffer:&sampleBufferFrame];
//    [self createResizedSampleBufferWithColorImageRef:imageRef
//                                       depthImageRef:depthImageRef
//                                                size:CGSizeMake(640, 480*2)
//                                                time:frameTime
//                                        sampleBuffer:&sampleBufferFrame];
//    [[ROBRTSPController server] encodeFrame:sampleBufferFrame];
//
//    //CMSampleBufferInvalidate(sampleBufferFrame);
//    CFRelease(sampleBufferFrame);
//    //sampleBufferFrame = NULL;
//
//    //-----------
//    NSImage *finalImage = [[NSImage alloc] initWithCGImage:imageRef size:(NSSize){ 1920.0/3.0, 1080.0/3.0 }];
//    NSImage *finalDepthImage = [[NSImage alloc] initWithCGImage:depthImageRef size:(NSSize){ 512.0, 424.0 }];
//
//    if (frameCounter == 1)
//    {
//        //printf("imageAnalysis\n");
//        [self.delegate heartbeat_NiTE];
//        [self.visionProcessor performImageAnalysis:imageRef];
//        frameCounter = 0;
//    }
//    frameCounter++;
//
//    /* // Tracking Block
//    if (!self->didInitializeTracking)
//    {
//        [self.visionProcessor initializeTracking:imageRef];
//        self->didInitializeTracking = true;
//    }
//    else
//    {
//        dispatch_sync(imageAnalysisQueue, ^{
//            [self.visionProcessor performTracking:imageRef];
//        });
//    }
//    */
//    CGImageRelease(imageRef);
//    CGImageRelease(depthImageRef);
//    //CGDataProviderRelease(provider);
//    CGColorSpaceRelease(colorSpace);
//    CGColorSpaceRelease(colorSpace_depth);
//
//    return finalDepthImage;
//}
//
//
//- (void)displayFrame:(nonnull CGImageRef)frame withAffineTransform:(CGAffineTransform)transform rects:(nonnull NSArray *)rects {
//    if ([rects count] > 0)
//    {
//        for (TrackedPolyRect *tc in rects)
//        {
//            if (trackingRectUUID_1 == nil)
//                trackingRectUUID_1 = tc.uuid;
//            if (tc.uuid == trackingRectUUID_1)
//            {
//                [self.delegate updateTrackingRect_1:[tc boundingBox]];
//                continue;
//            }
//
//            if (trackingRectUUID_2 == nil)
//                trackingRectUUID_2 = tc.uuid;
//            if (tc.uuid == trackingRectUUID_2)
//            {
//                [self.delegate updateTrackingRect_2:[tc boundingBox]];
//            }
//        }
//    }
//}
//
//@end
