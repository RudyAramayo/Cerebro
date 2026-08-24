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
- (IBAction)showGeminiSettings:(id)sender;
- (IBAction)showInsta360Settings:(id)sender;
- (IBAction)showSystemStatus:(id)sender;
- (IBAction)toggleDevelopmentMode:(id)sender;
- (IBAction)showControllerInputDiagnostics:(id)sender;
- (IBAction)showCameraDiagnostics:(id)sender;
- (IBAction)showFaceIdentityControl:(id)sender;
- (IBAction)showAmberArmDiagnostics:(id)sender;
- (IBAction)showWakeUpCalibration:(id)sender;

@end
