//
//  GameViewController.h
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <SceneKit/SceneKit.h>
#import <Vision/Vision.h>
#import "ROBSpeechBox.h"


@interface ROBAlignedDepthFrame : NSObject

@property (nonatomic, readonly, copy) NSData *millimetersLittleEndian;
@property (nonatomic, readonly, assign) NSUInteger width;
@property (nonatomic, readonly, assign) NSUInteger height;
@property (nonatomic, readonly, assign) uint64_t sequence;
@property (nonatomic, readonly, assign) uint64_t timestampNanoseconds;

- (instancetype)initWithMillimetersLittleEndian:(NSData *)millimetersLittleEndian
                                          width:(NSUInteger)width
                                         height:(NSUInteger)height
                                       sequence:(uint64_t)sequence
                           timestampNanoseconds:(uint64_t)timestampNanoseconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end


@class ROBSerialBox;

@interface ROBMainViewController : NSViewController <ROBSpeechDelegate>
{
    
}
@property (readwrite, retain) IBOutlet NSImageView *cameraImageView;
@property (readwrite, assign) IBOutlet NSTextView *speechTextView;
@property (readwrite, assign) IBOutlet NSTextView *speechTranscriptTextView;
@property (readwrite, retain) ROBSerialBox *serialBox;

- (void)updateBaseIRFrontLeft:(NSInteger)frontLeft
                   frontRight:(NSInteger)frontRight
                         left:(NSInteger)left
                        right:(NSInteger)right
                     backLeft:(NSInteger)backLeft
                    backRight:(NSInteger)backRight
                     received:(NSTimeInterval)receivedAtUptime;
- (void)updateBaseLegacyIRWarningFront:(BOOL)front
                                  back:(BOOL)back
                              received:(NSTimeInterval)receivedAtUptime;
@property (readwrite, retain) ROBSpeechBox *speechBox;
/// Immutable latest depth snapshot aligned to RGB. UInt16 little-endian
/// millimeters; zero is invalid. Nil whenever RGB-D is not live.
@property (atomic, readonly, strong) ROBAlignedDepthFrame *latestAlignedDepthFrame;

- (IBAction)showControls:(id)sender;
- (IBAction)showSerialDebug:(id)sender;
- (IBAction)showMainNavigation:(id)sender;
- (IBAction)showGeminiDiagnostics:(id)sender;
- (IBAction)showMainCameraDiagnostics:(id)sender;
- (IBAction)showCameraDiagnostics:(id)sender;
- (IBAction)showInsta360Diagnostics:(id)sender;
- (IBAction)showSystemStatus:(id)sender;
- (IBAction)showStageShow:(id)sender;
- (IBAction)showBaseSerialConsole:(id)sender;

- (IBAction)showControlPairingCode:(id)sender;

//Speech
- (void) makeTextViewFirstResponder:(NSTextView *)textView;
- (void) clearInputTextMessage;
- (void) inputText:(NSString *)textInput;
- (void) didRespond: (NSString *) responseText;
//Tracking
- (void) didSeeNewPeople:(NSArray<VNFaceObservation*>*)observations;
- (void) didCaptureCameraSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)didCaptureAlignedDepthData:(NSData *)depthData
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                          sequence:(uint64_t)sequence
              timestampNanoseconds:(uint64_t)timestampNanoseconds;
- (void)clearAlignedDepthFrame;

- (void) shutdownAudioInput;
- (void) didFinishProcessingSpeech;
- (void) willStartProcessingSpeech;
- (void) didOutputSerialResponse_Base:(NSString *)response;
- (void) resetSpeechResponseAttentionTimer;
- (void) setHeadTracking:(BOOL)headTrackingEnabled;

- (void) startListeningAgain;
- (void) beginToIgnore;

@end
