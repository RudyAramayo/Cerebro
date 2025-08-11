//
//  AppDelegate.m
//  Cerebro
//
//  Created by Rob Makina on 1/1/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "AppDelegate.h"

@interface AppDelegate ()
@property (readwrite, retain) NSTimer *rplidarCheckTimer;
@property (readwrite, retain) NSTimer *utcWebCamCheckTimer;
@property (readwrite, assign) BOOL utcWebCamIsOnline;

@end

@implementation AppDelegate

// How to set ROB's wake/sleep schedule:
//   sudo pmset repeat shutdown MTWRFSU 23:50:00 wakeorpoweron MTWRFSU 07:00:00

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    self.utcWebCamIsOnline = NO;
    [self cerebroCheck];
    [self utcWebCamCheck];
    //Give RPLidar 10 seconds to warm up as the macmini is booting quite fast
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self rpLidarCheck];
    });
    
}

- (void) cerebroCheck {
    //ps aux | grep Cerebro
    //system("ps aux | grep Cerebro");
    NSTask *cerebroIsRunning = [NSTask new];
    cerebroIsRunning.launchPath = @"/bin/ps";
    cerebroIsRunning.arguments = @[@"aux"]; // | grep Cerebro
    
    NSPipe *pipe = [NSPipe pipe];
    cerebroIsRunning.standardOutput = pipe;
    
    [cerebroIsRunning launch];
    //[cerebroIsRunning waitUntilExit];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if ([output componentsSeparatedByString:@"Cerebro.app/Contents/MacOS/Cerebro"].count > 2) { //If we have a count greater than 2 then we have multiple instances of Cerebro.app running
        NSLog(@"Cerebro is already running! Exiting");
        exit(1);
    }
    
    //NSLog(@"Cerebro check passsed...");
}
- (void) rpLidarCheck {
    
    self.rplidarCheckTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        //open RPLidar only after 10 seconds to let it start up
        // /usr/bin/open /Users/rob/Library/Developer/Xcode/DerivedData/RPLidar-fziuydzdocbagjfcyicbboaqukse/Build/Products/Debug-iphoneos/.XCInstall/RPLidar.app
        
        NSTask *rpLidarIsRunning = [NSTask new];
        rpLidarIsRunning.launchPath = @"/bin/ps";
        rpLidarIsRunning.arguments = @[@"aux"];
        
        NSPipe *pipe = [NSPipe pipe];
        rpLidarIsRunning.standardOutput = pipe;
        
        [rpLidarIsRunning launch];
        
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        
        if ([output componentsSeparatedByString:@"RPLidar.app"].count < 2) { //If we have a count of 2 then 1 RPLidar instance is running
            NSLog(@"Launching RPLidar...");
            
            NSTask *launchRPLidar = [NSTask new];
            launchRPLidar.launchPath = @"/usr/bin/open";
            launchRPLidar.arguments = @[@"/Users/rob/Library/Developer/Xcode/DerivedData/RPLidar-fziuydzdocbagjfcyicbboaqukse/Build/Products/Debug-iphoneos/.XCInstall/RPLidar.app"];
            [launchRPLidar launch];
        } else {
            //NSLog(@"RPLidar check passsed...");
        }
    }];
}

- (void) utcWebCamCheck {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self checkIfUTCWebcamIsOnline];
        self.utcWebCamCheckTimer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer * _Nonnull timer) {
            //python3 /Users/rob/Library/Mobile\ Documents/com~apple~CloudDocs/dev/Gemini/Webcam_color.py
            [self checkIfUTCWebcamIsOnline];
        }];
    });
}

- (void) checkIfUTCWebcamIsOnline {
    if (self.utcWebCamIsOnline) {
        NSLog(@"UTC Webcam is already online but timer is still running... bailing out!!!");
        [self.utcWebCamCheckTimer invalidate];
        self.utcWebCamCheckTimer = nil;
        return;
    }
    
    NSLog(@"Attempting to bring UTC Webcam Online");
    
    NSTask *utcCamIsRunning = [NSTask new];
    utcCamIsRunning.launchPath = @"~/rob_python/bin/python3";
    
    NSString *webcam_color_script_path = [[NSBundle mainBundle] pathForResource:@"Webcam_color" ofType:@"py"];
    NSLog(@"scriptPath = %@", webcam_color_script_path);
    utcCamIsRunning.arguments = @[webcam_color_script_path];
    
    NSPipe *pipe = [NSPipe pipe];
    utcCamIsRunning.standardOutput = pipe;
    utcCamIsRunning.standardError = pipe;
    
    [utcCamIsRunning launch];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"UTC Output: %@", output);
    if ([output containsString:@"Device started, please keep this process running"] ||
        [output containsString:@"another process has device opened for exclusive access"] ) {
        NSLog(@"UTC Webcam is Online");
        self.utcWebCamIsOnline = YES;
        [self.utcWebCamCheckTimer invalidate];
        self.utcWebCamCheckTimer = nil;
    } else {
        NSLog(@"Error: UTC Webcam is not running");
        self.utcWebCamIsOnline = NO;
    }
}

- (void) checkIfUTCWebCamIsOnline_SUDO {
    // The password for the sudo user. In a real application, this should be handled securely,
    // not hardcoded or passed directly as a string like this.
//    let sudoPassword = "your_sudo_password" // Replace with actual password or secure retrieval method
//    let passwordWithNewline = sudoPassword + "\n"
//
//    // The command to execute with sudo privileges
//    let commandToExecute = "ls -l /private/var/log" // Example: list contents of a restricted directory
//
//    let sudoProcess = Process()
//    sudoProcess.launchPath = "/usr/bin/sudo"
//    sudoProcess.arguments = ["-S", "/bin/sh", "-c", commandToExecute]
//
//    // Create pipes for standard input, output, and error
//    let stdinPipe = Pipe()
//    let stdoutPipe = Pipe()
//    let stderrPipe = Pipe()
//
//    sudoProcess.standardInput = stdinPipe
//    sudoProcess.standardOutput = stdoutPipe
//    sudoProcess.standardError = stderrPipe
//
//    do {
//        try sudoProcess.run()
//
//        // Write the password to the standard input of the sudo process
//        stdinPipe.fileHandleForWriting.write(passwordWithNewline.data(using: .utf8)!)
//        try stdinPipe.fileHandleForWriting.close() // Close the write handle to signal end of input
//
//        // Read output from the sudo command
//        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
//        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
//
//        let output = String(data: outputData, encoding: .utf8) ?? ""
//        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
//
//        sudoProcess.waitUntilExit()
//
//        if sudoProcess.terminationStatus == 0 {
//            print("Command executed successfully:")
//            print(output)
//        } else {
//            print("Command failed with error:")
//            print(errorOutput)
//        }
//
//    } catch {
//        print("Error launching sudo process: \(error.localizedDescription)")
//    }
    
    OSStatus status;
    AuthorizationRef authorizationRef;
    
    // Create an authorization reference
    status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorizationRef);
    if (status != errSecSuccess) {
        NSLog(@"Error creating authorization reference: %d", status);
        return;
    }
    NSString *webcam_color_script_path = [[NSBundle mainBundle] pathForResource:@"Webcam_color" ofType:@"py"];
    NSLog(@"scriptPath = %@", webcam_color_script_path);

    // Define the command to execute
    const char *toolPath = "~/rob_python/bin/python3"; // Example: create a file
    const char *arguments[] = {[webcam_color_script_path cStringUsingEncoding:NSUTF8StringEncoding], NULL}; // Example: file path

    // Request authorization to execute the command as root
    AuthorizationItem items[] = { { kAuthorizationRuleAuthenticateAsAdmin, 0, NULL, 0 } };
    AuthorizationRights rights = { sizeof(items) / sizeof(items[0]), items };
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
    
    status = AuthorizationCopyRights(authorizationRef, &rights, NULL, flags, NULL);
    if (status != errSecSuccess) {
        NSLog(@"Error copying rights: %d", status);
        AuthorizationFree(authorizationRef, kAuthorizationFlagDefaults);
        return;
    }
    
    // Execute the command with root privileges
    FILE *pipe = NULL;
    status = AuthorizationExecuteWithPrivileges(authorizationRef, toolPath, kAuthorizationFlagDefaults, (char *const *)arguments, &pipe);
    if (status != errSecSuccess) {
        NSLog(@"Error executing command with privileges: %d", status);
        AuthorizationFree(authorizationRef, kAuthorizationFlagDefaults);
        return;
    }
    
    // Close the pipe if opened
    if (pipe) {
        fclose(pipe);
    }
    
    NSLog(@"Command executed successfully with sudo privileges.");
    
    // Free the authorization reference
    AuthorizationFree(authorizationRef, kAuthorizationFlagDefaults);
}

@end
