//
//  AppDelegate.h
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

- (IBAction)showPythonSettings:(id)sender;
- (IBAction)toggleDevelopmentMode:(id)sender;
- (IBAction)showControllerInputDiagnostics:(id)sender;
- (IBAction)showHologramCaptureSettings:(id)sender;
- (IBAction)startHologramMovieRecording:(id)sender;
- (IBAction)stopHologramMovieRecording:(id)sender;
- (IBAction)shareLatestHologramViaAirDrop:(id)sender;

@end
