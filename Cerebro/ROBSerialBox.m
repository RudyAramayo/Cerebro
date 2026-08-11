//
//  ROBSerialBox.m
//  Cerebro
//
//  Created by Rob Makina on 1/2/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//
/*
 
 ORBITUSROBOTICS RHAPIv1.0
 
                                            brake  M1   brake  M2   brake  M3    LACT
INPUT: FULL BRAKE Command String         = ~+0001,+0000,+0001,+0000,+0001,+0000,+0000
Release Brakes Command String            = ~+0000,+0000,+0000,+0000,+0000,+0000,+0000
Full Motor Forward String                = ~+0000,+0100,+0000,+0100,+0000,+0000,+0000
Full Motor Backward String               = ~+0000,-0100,+0000,-0100,+0000,+0000,+0000

Turn Right                               = ~+0000,+0100,+0000,-0100,+0000,+0000,+0000
Turn Left                                = ~+0000,-0100,+0000,+0100,+0000,+0000,+0000

Left Motor Command String                = ~+0000,+0100,+0000,+0000,+0000,+0000,+0000
Right Motor Command String               = ~+0000,+0000,+0000,+0100,+0000,+0000,+0000
Flipper forwards MotorCommand String     = ~+0000,+0000,+0000,+0000,+0000,+0100,+0000
Flipper backwards MotorCommand String    = ~+0000,+0000,+0000,+0000,+0000,-0100,+0000
LACT forwards MotorCommand String        = ~+0000,+0000,+0000,+0000,+0000,+0000,+3200
LACT backwards MotorCommand String       = ~+0000,+0000,+0000,+0000,+0000,+0000,-3200


OUTPUT: ir sensor array in cm : (fl, fr, l, r, bl, br) from front left to back right
 
 IMU Pulse
 ax = 2.01 ay = -83.44 az = -1085.94 mg
 gx = -0.13 gy = 0.05 gz = -0.03 deg/s
 mx = -1600 my = -1261 mz = -420 mG
 q0 = 0.05 qx = 0.10 qy = -0.39 qz = 0.91
 Yaw, Pitch, Roll: 175.03, -12.40, -46.15
 Temperature is 28.9 degrees C
 rate = 0.21 Hz

*/

#import "ROBSerialBox.h"
#import "ROBMainViewController.h"
#import "ROBSpeechBox.h"
#import "ROBBaseControllerModel.h"
#import "ROBPythonRuntime.h"
#import "ROBSystemDependencyManager.h"
#import "ROBTaskLaunchGuard.h"
#include <sys/select.h>


#define kRHAPI_BAUDRATE 250000
// This exact line already exists in the long-running Base firmware. Head and Torso use
// their own role names, so Cerebro can identify Base without requiring a show-day flash.
static NSString * const kROBBaseLegacyStartupIdentity = @"BEGIN BASE STARTUP SEQUENCE";
static NSTimeInterval const kROBBaseProbeTimeoutSeconds = 15.0;

#define kRHAPI_SERIAL_PORT_HEAD     @"/dev/cu.usbmodem1431301"
#define kRHAPI_SERIAL_PORT_TORSO    @"/dev/cu.usbmodem144201"
#define kRHAPI_SERIAL_PORT_BASE     @"/dev/cu.usbmodem21201"


#define kRHAPI_MAESTRO_BAUDRATE 9600

#define kRHAPI_SERIAL_PORT_MAESTRO_COM      @"/dev/cu.usbmodem001955201"
#define kRHAPI_SERIAL_PORT_MAESTRO_TTL      @"/dev/cu.usbmodem001955203"

//*** DON'T FORGET TO UPDATE FIRMWARE OF MOTOR CONTROLLER to 1.04 ***
#define kRHAPI_SERIAL_PORT_LACT_COM     @"/dev/cu.usbmodem143401"

#define kMaxTurnSpeed 100
#define kMaxMovementSpeed 255

// ROBController publishes at 5 Hz. Three missed snapshots expire authority;
// after one neutral/braked write Cerebro stops writing so the Arduino hardware
// deadman can de-energize independently.
static NSTimeInterval const kControllerSnapshotFreshnessSeconds = 0.6;
// The Tic rotating-plate UI permits one 36,800-unit turn in either direction.
// Vision head-following intentionally uses at most the 18,400-unit half-turn.
static int const kROBTicWaistFullTurnPositionUnits = 36800;
static int const kROBTicWaistHeadFollowMaximumUnits = 18400;

#define kHeadSerialContext 0
#define kTorsoSerialContext 1
#define kBaseSerialContext 2
#define kMaestroSerialContext 3

@interface ROBSerialBox()
{
    bool exitSafeStart;
    bool exitSafeStart_waistRotation;
    bool energize_waistRotation;
}
@property (readwrite, assign) float actualSpeedL;
@property (readwrite, assign) float actualSpeedR;
@property (readwrite, assign) BOOL masterControllerInputWasFresh;
@property (readwrite, assign) int lastVisionNeckPanTarget;
@property (readwrite, assign) int lastVisionNeckTiltTarget;
@property (readwrite, assign) BOOL visionGripperStateIsKnown;
@property (readwrite, assign) BOOL lastVisionLeftGripperClosed;
@property (readwrite, assign) BOOL lastVisionRightGripperClosed;
@property (readwrite, assign) BOOL visionTorsoControlWasActive;
@property (readwrite, assign) int visionTorsoBaselinePosition;
@property (readwrite, assign) int lastVisionTorsoTarget;

@property (readwrite, retain) NSTimer *verbalInputTimer;
@property (readwrite, retain) NSTimer *controllerTimer;

@property (readwrite, retain) NSString *tempTextInput;
@property (readwrite, retain) NSMutableDictionary *controlModelDataDictionary;
@property (readwrite, retain) NSMutableData* receivedData_R11_Core;
@property (readwrite, retain) NSMutableData* receivedData_R11_log;
@property (readwrite, retain) NSMutableData* receivedData_L10_Core;
@property (readwrite, retain) NSMutableData* receivedData_L10_log;
@property (readwrite, retain) NSMutableData *baseSerialReceiveBuffer;
@property (readwrite, assign) BOOL baseDetectionInProgress;
@property (readwrite, assign) BOOL core_R11_isOnline;
@property (readwrite, assign) BOOL core_L10_isOnline;
@property (readwrite, retain) NSTask *sshTask_R11_Core;
@property (readwrite, retain) NSTask *sshTask_L10_Core;
@property (readwrite, retain) NSTask *sshTask_R11_log;
@property (readwrite, retain) NSTask *sshTask_L10_log;

- (void)runPythonArguments:(NSArray<NSString *> *)arguments operation:(NSString *)operation;
- (void)runTiccmdArguments:(NSArray<NSString *> *)arguments;
- (void)performSSHpassOperation:(NSString *)operation block:(dispatch_block_t)block;
- (BOOL)launchSSHpassTask:(NSTask *)task operation:(NSString *)operation;
- (void)reportSSHpassError:(NSError *)error operation:(NSString *)operation;
- (void)startSSHIntoAmberMasterAndRunTail_R11;
- (void)startSSHIntoAmberMasterAndRunCore_R11;
- (void)startShutdown_R11_core;
- (void)startSSHIntoAmberMasterAndRunTail_L10;
- (void)startSSHIntoAmberMasterAndRunCore_L10;
- (void)startShutdown_L10_core;

- (NSString *) openSerialPort: (NSString *)serialPortFile baud: (speed_t)baudRate serialFileDescriptor:(int *)serialFileDescriptor contextInt:(int)context;
- (NSArray<NSString *> *)usbSerialPortPaths;
- (void)connectToDetectedBase;
- (BOOL)probeBaseFirmwareAtPath:(NSString *)path fileDescriptor:(int *)matchedFileDescriptor;
- (void)consumeBaseSerialBytes:(const void *)bytes length:(NSUInteger)length;
- (void)handleBaseSerialLine:(NSString *)line;

- (void)appendToIncomingText_head: (id) text;
- (void)appendToIncomingText_torso: (id) text;
- (void)appendToIncomingText_base: (id) text;
- (void)appendToIncomingText_maestro: (id) text;


- (void)incomingTextUpdateThread_head: (NSThread *) parentThread;
- (void)incomingTextUpdateThread_torso: (NSThread *) parentThread;
- (void)incomingTextUpdateThread_base: (NSThread *) parentThread;
- (void)incomingTextUpdateThread_maestro: (NSThread *) parentThread;

- (void) refreshSerialList_head: (NSString *) selectedText;
- (void) refreshSerialList_torso: (NSString *) selectedText;
- (void) refreshSerialList_base: (NSString *) selectedText;
- (void) refreshSerialList_maestro: (NSString *) selectedText;


- (void) writeString: (NSString *)str serialFileDescriptor:(int)serialFileDescriptor;
- (void) writeByte: (uint8_t *)val serialFileDescriptor:(int)serialFileDescriptor;


//- (IBAction) baudAction: (id) cntrl;
- (IBAction) refreshAction: (id) cntrl;
- (void) sendText:(id)cntrl serialInputField:(NSTextField *)serialInputField serialFileDescriptor:(int)serialFileDescriptor;

- (void) resetButton: (NSButton *) btn;


- (IBAction)forward:(id)sender;
- (IBAction)backward:(id)sender;
- (IBAction)left:(id)sender;
- (IBAction)right:(id)sender;
- (IBAction)up:(id)sender;
- (IBAction)down:(id)sender;
- (IBAction)leanforward:(id)sender;
- (IBAction)leanback:(id)sender;



@end


typedef enum : NSUInteger {
    head = 0,
    torso,
    base,
    maestro
} SerialContext;



@implementation ROBSerialBox


- (instancetype)init
{
    self = [super init];
    if (self) {
        
    }
    return self;
}


// executes after everything in the xib/nib is initiallized
- (void)initialize_connection {
    // we don't have a serial port open yet
    self.amberHostIP = @"10.0.0.11";
    serialFileDescriptor_head = -1;
    serialFileDescriptor_torso = -1;
    serialFileDescriptor_base = -1;
    serialFileDescriptor_maestro = -1;
    self.actualSpeedL = 0;
    self.actualSpeedR = 0;
    self.lastVisionNeckPanTarget = 6000;
    self.lastVisionNeckTiltTarget = 6045;
    readThreadRunning_head = FALSE;
    readThreadRunning_torso = FALSE;
    readThreadRunning_base = FALSE;
    readThreadRunning_maestro = FALSE;
    
    exitSafeStart = false;
    exitSafeStart_waistRotation = false;
    energize_waistRotation = false;
    
    self.currentIncommingVerbalMessage = @"";
    self.baseSerialReceiveBuffer = [NSMutableData data];
    // Base is the only Arduino role presently installed. Head and Torso lists remain visible as
    // legacy UI until the planned interface cleanup, but Cerebro no longer attempts to open them.
    [self refreshSerialList_base:@"Detecting Base firmware…"];
    [self refreshSerialList_torso:kRHAPI_SERIAL_PORT_TORSO];
    [self refreshSerialList_head:kRHAPI_SERIAL_PORT_HEAD];
    [self refreshSerialList_maestro:kRHAPI_SERIAL_PORT_MAESTRO_COM];
    self.controlModelDataDictionary = [NSMutableDictionary new];
    // now put the cursor in the text field
    //[serialInputField becomeFirstResponder];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self connectToDetectedBase];
    });
    /*
     error = [self openSerialPort:kRHAPI_SERIAL_PORT_TORSO baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_torso contextInt:kTorsoSerialContext];
     
     if(error!=nil) {
     [self refreshSerialList_torso:error];
     [self appendToIncomingText_torso:error];
     } else {
     [self refreshSerialList_torso:[self.serialListPullDown_torso titleOfSelectedItem]];
     [self performSelectorInBackground:@selector(incomingTextUpdateThread_torso:) withObject:[NSThread currentThread]];
     }
     
     
     error = [self openSerialPort:kRHAPI_SERIAL_PORT_HEAD baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_head contextInt:kHeadSerialContext];
     
     if(error!=nil) {
     [self refreshSerialList_head:error];
     [self appendToIncomingText_head:error];
     } else {
     [self refreshSerialList_head:[self.serialListPullDown_head titleOfSelectedItem]];
     [self performSelectorInBackground:@selector(incomingTextUpdateThread_head:) withObject:[NSThread currentThread]];
     }
     */
    [self connectMaestro];
    
    self.controllerTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(renderController) userInfo:nil repeats:YES];
    
    //give the master controller a few seconds to boot up first
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sshIntoAmberMasterAndRunTail_L10:self];
        [self sshIntoAmberMasterAndRunTail_R11:self];
    });
}

- (NSArray<NSString *> *)usbSerialPortPaths
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching(kIOSerialBSDServiceValue),
        &iterator
    );
    if (result != KERN_SUCCESS) {
        return paths;
    }

    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(
            service,
            CFSTR(kIOCalloutDeviceKey),
            kCFAllocatorDefault,
            0
        );
        if (value != NULL && CFGetTypeID(value) == CFStringGetTypeID()) {
            NSString *path = CFBridgingRelease(value);
            // Limit probing to USB callout devices. Never touch Bluetooth, network, or dial-in
            // channels, and never send a probe byte that another controller could interpret.
            if ([path hasPrefix:@"/dev/cu.usbmodem"] || [path hasPrefix:@"/dev/cu.usbserial"]) {
                [paths addObject:path];
            }
        } else if (value != NULL) {
            CFRelease(value);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)connectToDetectedBase
{
    @synchronized (self) {
        if (self.baseDetectionInProgress) {
            [self appendToIncomingText_base:@"\nBase firmware detection is already running.\n"];
            return;
        }
        self.baseDetectionInProgress = YES;
    }

    NSArray<NSString *> *paths = [self usbSerialPortPaths];
    for (NSString *path in paths) {
        int candidateFileDescriptor = -1;
        [self appendToIncomingText_base:[NSString stringWithFormat:@"\nDetecting Base firmware on %@…\n", path]];
        if ([self probeBaseFirmwareAtPath:path fileDescriptor:&candidateFileDescriptor]) {
            serialFileDescriptor_base = candidateFileDescriptor;
            [self.baseSerialReceiveBuffer setLength:0];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshSerialList_base:path];
            });
            [self appendToIncomingText_base:[NSString stringWithFormat:@"Base firmware verified on %@\n", path]];
            [self performSelectorInBackground:@selector(incomingTextUpdateThread_base:)
                                   withObject:[NSThread currentThread]];
            @synchronized (self) { self.baseDetectionInProgress = NO; }
            return;
        }
        if (candidateFileDescriptor != -1) {
            close(candidateFileDescriptor);
        }
    }

    NSString *message = paths.count == 0
        ? @"No USB serial devices were found. Connect the Base Arduino and refresh."
        : @"No USB serial device emitted the existing Base startup response. Check its power/IMU startup, then refresh or choose a port manually.";
    [self appendToIncomingText_base:[@"\n" stringByAppendingString:message]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshSerialList_base:message];
    });
    @synchronized (self) { self.baseDetectionInProgress = NO; }
}

- (BOOL)probeBaseFirmwareAtPath:(NSString *)path fileDescriptor:(int *)matchedFileDescriptor
{
    int candidateFileDescriptor = -1;
    NSString *error = [self openSerialPort:path
                                      baud:kRHAPI_BAUDRATE
                      serialFileDescriptor:&candidateFileDescriptor
                                contextInt:kBaseSerialContext];
    if (error != nil) {
        return NO;
    }

    // Opening an Arduino serial device commonly resets it, but make the reset pulse explicit so
    // the already-flashed sketch reliably reprints its existing role-specific startup line.
    // This changes no firmware and sends no serial command bytes.
    ioctl(candidateFileDescriptor, TIOCSDTR);
    struct timespec resetPulse = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
    nanosleep(&resetPulse, NULL);
    ioctl(candidateFileDescriptor, TIOCCDTR);

    NSData *identity = [kROBBaseLegacyStartupIdentity dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *received = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kROBBaseProbeTimeoutSeconds];
    while (deadline.timeIntervalSinceNow > 0) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(candidateFileDescriptor, &readSet);
        NSTimeInterval remaining = MAX(0, deadline.timeIntervalSinceNow);
        struct timeval timeout = {
            .tv_sec = (time_t)remaining,
            .tv_usec = (suseconds_t)((remaining - floor(remaining)) * 1000000.0)
        };
        int ready = select(candidateFileDescriptor + 1, &readSet, NULL, NULL, &timeout);
        if (ready <= 0) {
            break;
        }

        uint8_t bytes[256];
        ssize_t count = read(candidateFileDescriptor, bytes, sizeof(bytes));
        if (count <= 0) {
            break;
        }
        [received appendBytes:bytes length:(NSUInteger)count];
        if ([received rangeOfData:identity options:0 range:NSMakeRange(0, received.length)].location != NSNotFound) {
            *matchedFileDescriptor = candidateFileDescriptor;
            return YES;
        }
        if (received.length > 8192) {
            [received replaceBytesInRange:NSMakeRange(0, received.length - 4096)
                                withBytes:NULL
                                   length:0];
        }
    }
    close(candidateFileDescriptor);
    return NO;
}

- (void) connectMaestro
{
    NSString *error = [self openSerialPort:kRHAPI_SERIAL_PORT_MAESTRO_COM baud:kRHAPI_MAESTRO_BAUDRATE serialFileDescriptor:&serialFileDescriptor_maestro contextInt:kMaestroSerialContext];
    if(error!=nil) {
        //[self refreshSerialList_head:error];
        //[self appendToIncomingText_head:error];
        NSLog(@"%@", error);
    } else {
        //[self refreshSerialList_head:[self.serialListPullDown_head titleOfSelectedItem]];
        //[self performSelectorInBackground:@selector(incomingTextUpdateThread_maestro:) withObject:[NSThread currentThread]];
    }
}


// Gets the position of a Maestro channel.
// See the "Serial Servo Commands" section of the user's guide.
int maestroGetPosition(int fd, unsigned char channel)
{
    unsigned char command[] = {0x90, channel};
    if(write(fd, command, sizeof(command)) == -1)
    {
        perror("error writing");
        return -1;
    }
    
    unsigned char response[2];
    if(read(fd,response,2) != 2)
    {
        perror("error reading");
        return -1;
    }
    
    return response[0] + 256*response[1];
}

// Sets the target of a Maestro channel.
// See the "Serial Servo Commands" section of the user's guide.
// The units of 'target' are quarter-microseconds.
int maestroSetTarget(int fd, unsigned char channel, unsigned short target)
{
    unsigned char command[] = {0x84, channel, target & 0x7F, target >> 7 & 0x7F};
    if (write(fd, command, sizeof(command)) == -1)
    {
        perror("error writing");
        return -1;
    }
    return 0;
}


int maestroGetErrors(int fd)
{
    unsigned char command[] = {0xA1};
    if (write(fd, command, sizeof(command)) == -1)
    {
        perror("error writing");
        return -1;
    }
    return 0;
}

// open the serial port
//   - nil is returned on success
//   - an error message is returned otherwise
- (NSString *) openSerialPort: (NSString *)serialPortFile baud: (speed_t)baudRate serialFileDescriptor:(int *)serialFileDescriptor contextInt:(int)contextInt{
    int success;
    
    // close the pousrt if it is already open
    if ((*serialFileDescriptor) != -1) {
        close((*serialFileDescriptor));
        (*serialFileDescriptor) = -1;
        
        switch (contextInt) {
            case 0:
                while(readThreadRunning_head);
                break;
            case 1:
                while(readThreadRunning_torso);
                break;
            case 2:
                while(readThreadRunning_base);
                break;
            case 3:
                while(readThreadRunning_maestro);
                break;
                
            default:
                break;
        }
        
        // wait for the reading thread to die
        
        
        // re-opening the same port REALLY fast will fail spectacularly... better to sleep a sec
        sleep(0.5);
    }
    
    // c-string path to serial-port file
    const char *bsdPath = [serialPortFile cStringUsingEncoding:NSUTF8StringEncoding];
    
    // Hold the original termios attributes we are setting
    struct termios options;
    
    // receive latency ( in microseconds )
    unsigned long mics = 3;
    
    // error message string
    NSString *errorMessage = nil;
    
    // open the port
    //     O_NONBLOCK causes the port to open without any delay (we'll block with another call)
    (*serialFileDescriptor) = open(bsdPath, O_RDWR | O_NOCTTY | O_EXLOCK | O_NONBLOCK );
    
    if ((*serialFileDescriptor) == -1) {
        // check if the port opened correctly
        errorMessage = @"Error: couldn't open serial port";
    } else {
        // TIOCEXCL causes blocking of non-root processes on this serial-port
        success = ioctl((*serialFileDescriptor), TIOCEXCL);
        if ( success == -1) {
            errorMessage = @"Error: couldn't obtain lock on serial port";
        } else {
            success = fcntl((*serialFileDescriptor), F_SETFL, 0);
            if ( success == -1) {
                // clear the O_NONBLOCK flag; all calls from here on out are blocking for non-root processes
                errorMessage = @"Error: couldn't obtain lock on serial port";
            } else {
                // Get the current options and save them so we can restore the default settings later.
                success = tcgetattr((*serialFileDescriptor), &gOriginalTTYAttrs);
                if ( success == -1) {
                    errorMessage = @"Error: couldn't get serial attributes";
                } else {
                    // copy the old termios settings into the current
                    //   you want to do this so that you get all the control characters assigned
                    options = gOriginalTTYAttrs;
                    
                    /*
                     cfmakeraw(&options) is equivilent to:
                     options->c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
                     options->c_oflag &= ~OPOST;
                     options->c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
                     options->c_cflag &= ~(CSIZE | PARENB);
                     options->c_cflag |= CS8;
                     */
                    cfmakeraw(&options);
                    
                    // set tty attributes (raw-mode in this case)
                    success = tcsetattr((*serialFileDescriptor), TCSANOW, &options);
                    if ( success == -1) {
                        errorMessage = @"Error: coudln't set serial attributes";
                    } else {
                        // Set baud rate (any arbitrary baud rate can be set this way)
                        success = ioctl((*serialFileDescriptor), IOSSIOSPEED, &baudRate);
                        if ( success == -1) {
                            errorMessage = @"Error: Baud Rate out of bounds";
                        } else {
                            // Set the receive latency (a.k.a. don't wait to buffer data)
                            success = ioctl((*serialFileDescriptor), IOSSDATALAT, &mics);
                            if ( success == -1) {
                                errorMessage = @"Error: coudln't set serial latency";
                            }
                        }
                    }
                }
            }
        }
    }
    
    // make sure the port is closed if a problem happens
    if (((*serialFileDescriptor) != -1) && (errorMessage != nil)) {
        close((*serialFileDescriptor));
        (*serialFileDescriptor) = -1;
    }
    
    return errorMessage;
}

// updates the textarea for incoming text by appending text
- (void)appendToIncomingText_head: (id) text{
    // add the text to the textarea
    NSAttributedString* attrString = [[NSMutableAttributedString alloc] initWithString: text];
    //TODO: DISPATCH GET MAIN THREAD HERE FOR USING TEXTSTORAGE
    dispatch_async(dispatch_get_main_queue(), ^(){
        NSTextStorage *textStorage = [self.serialOutputArea_head textStorage];
        [self.delegate didOutputSerialResponse_Head:attrString.string];
        [textStorage beginEditing];
        [textStorage appendAttributedString:attrString];
        [textStorage endEditing];
        
        // scroll to the bottom
        NSRange myRange;
        myRange.length = 1;
        myRange.location = [textStorage length];
        [self.serialOutputArea_head scrollRangeToVisible:myRange];
    });
}

// updates the textarea for incoming text by appending text
- (void)appendToIncomingText_base: (id) text{
    // add the text to the textarea
    NSAttributedString* attrString = [[NSMutableAttributedString alloc] initWithString: text];
    //TODO: DISPATCH GET MAIN THREAD HERE FOR USING TEXTSTORAGE
    dispatch_async(dispatch_get_main_queue(), ^(){
        NSTextStorage *textStorage = [self.serialOutputArea_base textStorage];
        [self.delegate didOutputSerialResponse_Base:attrString.string];
        [textStorage beginEditing];
        [textStorage appendAttributedString:attrString];
        [textStorage endEditing];
        
        // scroll to the bottom
        NSRange myRange;
        myRange.length = 1;
        myRange.location = [textStorage length];
        [self.serialOutputArea_base scrollRangeToVisible:myRange];
    });
}

// updates the textarea for incoming text by appending text
- (void)appendToIncomingText_torso: (id) text{
    // add the text to the textarea
    NSAttributedString* attrString = [[NSMutableAttributedString alloc] initWithString: text];
    //TODO: DISPATCH GET MAIN THREAD HERE FOR USING TEXTSTORAGE
    dispatch_async(dispatch_get_main_queue(), ^(){
        NSTextStorage *textStorage = [self.serialOutputArea_torso textStorage];
        [self.delegate didOutputSerialResponse_Torso:attrString.string];
        [textStorage beginEditing];
        [textStorage appendAttributedString:attrString];
        [textStorage endEditing];
        
        // scroll to the bottom
        NSRange myRange;
        myRange.length = 1;
        myRange.location = [textStorage length];
        [self.serialOutputArea_torso scrollRangeToVisible:myRange];
    });
}

- (void)appendToIncomingText_maestro: (id) text
{
    // add the text to the textarea
    NSAttributedString* attrString = [[NSMutableAttributedString alloc] initWithString: text];
    //TODO: DISPATCH GET MAIN THREAD HERE FOR USING TEXTSTORAGE
    dispatch_async(dispatch_get_main_queue(), ^(){
        NSTextStorage *textStorage = [self.serialOutputArea_maestro textStorage];
        [self.delegate didOutputSerialResponse_Maestro:attrString.string];
        [textStorage beginEditing];
        [textStorage appendAttributedString:attrString];
        [textStorage endEditing];
        
        // scroll to the bottom
        NSRange myRange;
        myRange.length = 1;
        myRange.location = [textStorage length];
        [self.serialOutputArea_maestro scrollRangeToVisible:myRange];
    });
}

// This selector/function will be called as another thread...
//  this thread will read from the serial port and exits when the port is closed
- (void)incomingTextUpdateThread_head: (NSThread *) parentThread{
    
    // create a pool so we can use regular Cocoa stuff
    //   child threads can't re-use the parent's autorelease pool
    //NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // mark that the thread is running
    readThreadRunning_head = TRUE;
    
    const int BUFFER_SIZE = 100;
    char byte_buffer[BUFFER_SIZE]; // buffer for holding incoming data
    long numBytes=0; // number of bytes read during read
    NSString *text; // incoming text from the serial port
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_head, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            // create an NSString from the incoming bytes (the bytes aren't null terminated)
            //DEPRICATION:
            text = [NSString stringWithCString:byte_buffer length:numBytes];
            //text = [NSString stringWithCString:byte_buffer encoding:NSUTF8StringEncoding];
            
            // this text can't be directly sent to the text area from this thread
            //  BUT, we can call a selctor on the main thread.
            
            [self performSelectorOnMainThread:@selector(appendToIncomingText_head:)
                                   withObject:text
                                waitUntilDone:YES];
        } else {
            break; // Stop the thread if there is an error
        }
    }
    
    // make sure the serial port is closed
    if (serialFileDescriptor_head != -1) {
        close(serialFileDescriptor_head);
        serialFileDescriptor_head = -1;
    }
    
    // mark that the thread has quit
    readThreadRunning_head = FALSE;
    
    // give back the pool
    //[pool release];
}


- (void)incomingTextUpdateThread_torso: (NSThread *) parentThread{
    
    // create a pool so we can use regular Cocoa stuff
    //   child threads can't re-use the parent's autorelease pool
    //NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // mark that the thread is running
    readThreadRunning_torso = TRUE;
    
    const int BUFFER_SIZE = 100;
    char byte_buffer[BUFFER_SIZE]; // buffer for holding incoming data
    long numBytes=0; // number of bytes read during read
    NSString *text; // incoming text from the serial port
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_torso, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            // create an NSString from the incoming bytes (the bytes aren't null terminated)
            //DEPRICATION:
            text = [NSString stringWithCString:byte_buffer length:numBytes];
            //text = [NSString stringWithCString:byte_buffer encoding:NSUTF8StringEncoding];
            
            // this text can't be directly sent to the text area from this thread
            //  BUT, we can call a selctor on the main thread.
            
            [self performSelectorOnMainThread:@selector(appendToIncomingText_torso:)
                                   withObject:text
                                waitUntilDone:YES];
        } else {
            break; // Stop the thread if there is an error
        }
    }
    
    // make sure the serial port is closed
    if (serialFileDescriptor_torso != -1) {
        close(serialFileDescriptor_torso);
        serialFileDescriptor_torso = -1;
    }
    
    // mark that the thread has quit
    readThreadRunning_torso = FALSE;
    
    // give back the pool
    //[pool release];
}


- (void)incomingTextUpdateThread_base: (NSThread *) parentThread{
    
    // create a pool so we can use regular Cocoa stuff
    //   child threads can't re-use the parent's autorelease pool
    //NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // mark that the thread is running
    readThreadRunning_base = TRUE;
    [NSThread sleepForTimeInterval:1];
    const int BUFFER_SIZE = 100;
    char byte_buffer[BUFFER_SIZE]; // buffer for holding incoming data
    long numBytes=0; // number of bytes read during read
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_base, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            [self consumeBaseSerialBytes:byte_buffer length:(NSUInteger)numBytes];
        } else {
            break; // Stop the thread if there is an error
        }
    }
    
    // make sure the serial port is closed
    if (serialFileDescriptor_base != -1) {
        close(serialFileDescriptor_base);
        serialFileDescriptor_base = -1;
    }
    
    // mark that the thread has quit
    readThreadRunning_base = FALSE;
    
    // give back the pool
    //[pool release];
}

- (void)consumeBaseSerialBytes:(const void *)bytes length:(NSUInteger)length
{
    [self.baseSerialReceiveBuffer appendBytes:bytes length:length];
    const uint8_t newline = '\n';
    while (self.baseSerialReceiveBuffer.length > 0) {
        NSRange newlineRange = [self.baseSerialReceiveBuffer rangeOfData:[NSData dataWithBytes:&newline length:1]
                                                                 options:0
                                                                   range:NSMakeRange(0, self.baseSerialReceiveBuffer.length)];
        if (newlineRange.location == NSNotFound) {
            // Malformed or noisy devices cannot grow the receive buffer without bound.
            if (self.baseSerialReceiveBuffer.length > 4096) {
                [self.baseSerialReceiveBuffer replaceBytesInRange:NSMakeRange(0, self.baseSerialReceiveBuffer.length - 2048)
                                                        withBytes:NULL
                                                           length:0];
            }
            return;
        }

        NSData *lineData = [self.baseSerialReceiveBuffer subdataWithRange:NSMakeRange(0, newlineRange.location)];
        [self.baseSerialReceiveBuffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(newlineRange))
                                                withBytes:NULL
                                                   length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line != nil) {
            [self handleBaseSerialLine:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        }
    }
}

- (void)handleBaseSerialLine:(NSString *)line
{
    BOOL frontWarning = [line containsString:@"WARNING! FRONT"] ||
        [line containsString:@"OBSTACLE IS BLOCKING FRONT"];
    BOOL backWarning = [line containsString:@"WARNING! BACK"] ||
        [line containsString:@"OBSTACLE IS BLOCKING BACK"];
    if (frontWarning || backWarning) {
        NSTimeInterval received = NSProcessInfo.processInfo.systemUptime;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate updateBaseLegacyIRWarningFront:frontWarning
                                                     back:backWarning
                                                 received:received];
        });
        return;
    }

    static NSString * const prefix = @"ROB:IR=";
    if (![line hasPrefix:prefix]) { return; }

    NSArray<NSString *> *fields = [[line substringFromIndex:prefix.length] componentsSeparatedByString:@","];
    if (fields.count != 6) { return; }
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:6];
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    for (NSString *field in fields) {
        if (field.length == 0 || [field rangeOfCharacterFromSet:nonDigits].location != NSNotFound) { return; }
        NSInteger value = field.integerValue;
        if (value > 1000) { return; }
        [values addObject:@(value)];
    }

    NSTimeInterval received = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate updateBaseIRFrontLeft:values[0].integerValue
                                  frontRight:values[1].integerValue
                                        left:values[2].integerValue
                                       right:values[3].integerValue
                                    backLeft:values[4].integerValue
                                   backRight:values[5].integerValue
                                    received:received];
    });
}


- (void)incomingTextUpdateThread_maestro: (NSThread *) parentThread{
    
    // create a pool so we can use regular Cocoa stuff
    //   child threads can't re-use the parent's autorelease pool
    //NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // mark that the thread is running
    readThreadRunning_maestro = TRUE;
    
    const int BUFFER_SIZE = 100;
    char byte_buffer[BUFFER_SIZE]; // buffer for holding incoming data
    long numBytes=0; // number of bytes read during read
    NSString *text; // incoming text from the serial port
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_maestro, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            // create an NSString from the incoming bytes (the bytes aren't null terminated)
            //DEPRICATION:
            text = [NSString stringWithCString:byte_buffer length:numBytes];
            //text = [NSString stringWithCString:byte_buffer encoding:NSUTF8StringEncoding];
            
            // this text can't be directly sent to the text area from this thread
            //  BUT, we can call a selctor on the main thread.
            
            [self performSelectorOnMainThread:@selector(appendToIncomingText_maestro:)
                                   withObject:text
                                waitUntilDone:YES];
        } else {
            break; // Stop the thread if there is an error
        }
    }
    
    // make sure the serial port is closed
    if (serialFileDescriptor_maestro != -1) {
        close(serialFileDescriptor_maestro);
        serialFileDescriptor_maestro = -1;
    }
    
    // mark that the thread has quit
    readThreadRunning_maestro = FALSE;
    
    // give back the pool
    //[pool release];
}


- (void) refreshSerialList_head: (NSString *) selectedText {
    io_object_t serialPort;
    io_iterator_t serialPortIterator;
    
    // remove everything from the pull down list
    [self.serialListPullDown_head removeAllItems];
    
    // ask for all the serial ports
    IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &serialPortIterator);
    
    // loop through all the serial ports and add them to the array
    while ((serialPort = IOIteratorNext(serialPortIterator))) {
        [self.serialListPullDown_head addItemWithTitle:
         //CheckHere for ARC Stuff related to the CFSTR string ownership
         (__bridge NSString*)IORegistryEntryCreateCFProperty(serialPort, CFSTR(kIOCalloutDeviceKey),  kCFAllocatorDefault, 0)];
        IOObjectRelease(serialPort);
    }
    
    // add the selected text to the top
    [self.serialListPullDown_head insertItemWithTitle:selectedText atIndex:0];
    [self.serialListPullDown_head selectItemAtIndex:0];
    
    IOObjectRelease(serialPortIterator);
}


- (void) refreshSerialList_torso: (NSString *) selectedText {
    io_object_t serialPort;
    io_iterator_t serialPortIterator;
    
    // remove everything from the pull down list
    [self.serialListPullDown_torso removeAllItems];
    
    // ask for all the serial ports
    IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &serialPortIterator);
    
    // loop through all the serial ports and add them to the array
    while ((serialPort = IOIteratorNext(serialPortIterator))) {
        [self.serialListPullDown_torso addItemWithTitle:
         //CheckHere for ARC Stuff related to the CFSTR string ownership
         (__bridge NSString*)IORegistryEntryCreateCFProperty(serialPort, CFSTR(kIOCalloutDeviceKey),  kCFAllocatorDefault, 0)];
        IOObjectRelease(serialPort);
    }
    
    // add the selected text to the top
    [self.serialListPullDown_torso insertItemWithTitle:selectedText atIndex:0];
    [self.serialListPullDown_torso selectItemAtIndex:0];
    
    IOObjectRelease(serialPortIterator);
}


- (void) refreshSerialList_base: (NSString *) selectedText {
    io_object_t serialPort;
    io_iterator_t serialPortIterator;
    
    // remove everything from the pull down list
    [self.serialListPullDown_base removeAllItems];
    
    // ask for all the serial ports
    IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &serialPortIterator);
    
    // loop through all the serial ports and add them to the array
    while ((serialPort = IOIteratorNext(serialPortIterator))) {
        [self.serialListPullDown_base addItemWithTitle:
         //CheckHere for ARC Stuff related to the CFSTR string ownership
         (__bridge NSString*)IORegistryEntryCreateCFProperty(serialPort, CFSTR(kIOCalloutDeviceKey),  kCFAllocatorDefault, 0)];
        IOObjectRelease(serialPort);
    }
    
    // add the selected text to the top
    [self.serialListPullDown_base insertItemWithTitle:selectedText atIndex:0];
    [self.serialListPullDown_base selectItemAtIndex:0];
    
    IOObjectRelease(serialPortIterator);
}

- (void) refreshSerialList_maestro: (NSString *) selectedText {
    io_object_t serialPort;
    io_iterator_t serialPortIterator;
    
    // remove everything from the pull down list
    [self.serialListPullDown_maestro removeAllItems];
    
    // ask for all the serial ports
    IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &serialPortIterator);
    
    // loop through all the serial ports and add them to the array
    while ((serialPort = IOIteratorNext(serialPortIterator))) {
        [self.serialListPullDown_maestro addItemWithTitle:
         //CheckHere for ARC Stuff related to the CFSTR string ownership
         (__bridge NSString*)IORegistryEntryCreateCFProperty(serialPort, CFSTR(kIOCalloutDeviceKey),  kCFAllocatorDefault, 0)];
        IOObjectRelease(serialPort);
    }
    
    // add the selected text to the top
    [self.serialListPullDown_maestro insertItemWithTitle:selectedText atIndex:0];
    [self.serialListPullDown_maestro selectItemAtIndex:0];
    
    IOObjectRelease(serialPortIterator);
}

// send a string to the serial port
- (void) writeString: (NSString *) str serialFileDescriptor:(int)serialFileDescriptor {
    if(serialFileDescriptor!=-1) {
        write(serialFileDescriptor, [str cStringUsingEncoding:NSUTF8StringEncoding], [str length]);
    } else {
        // make sure the user knows they should select a serial port
        [self appendToIncomingText_head:@"\n ERROR:  Select a Serial Port from the pull-down menu\n"];
    }
}

// send a byte to the serial port
- (void) writeByte: (uint8_t *) val serialFileDescriptor:(int)serialFileDescriptor{
    if(serialFileDescriptor!=-1) {
        write(serialFileDescriptor, val, 1);
    } else {
        // make sure the user knows they should select a serial port
        [self appendToIncomingText_head:@"\n ERROR:  Select a Serial Port from the pull-down menu\n"];
    }
}

// action sent when serial port selected
- (void) serialPortSelected_head
{
    /*
     // open the serial port
     NSString *error = [self openSerialPort:[self.serialListPullDown_head titleOfSelectedItem] baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_head contextInt:kHeadSerialContext];
     
     if(error!=nil) {
     [self refreshSerialList_head:error];
     [self appendToIncomingText_head:error];
     } else {
     [self refreshSerialList_head:[self.serialListPullDown_head titleOfSelectedItem]];
     [self performSelectorInBackground:@selector(incomingTextUpdateThread_head:) withObject:[NSThread currentThread]];
     }*/
}

- (void) serialPortSelected_torso
{
    /*
     // open the serial port
     NSString *error = [self openSerialPort:[self.serialListPullDown_torso titleOfSelectedItem] baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_torso contextInt:kTorsoSerialContext];
     
     if(error!=nil) {
     [self refreshSerialList_torso:error];
     [self appendToIncomingText_torso:error];
     } else {
     [self refreshSerialList_torso:[self.serialListPullDown_torso titleOfSelectedItem]];
     [self performSelectorInBackground:@selector(incomingTextUpdateThread_torso:) withObject:[NSThread currentThread]];
     }*/
}

- (void) serialPortSelected_base
{
    NSString *titleOfSelectedItem = [self.serialListPullDown_base titleOfSelectedItem];
    // open the serial port
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *error = [self openSerialPort:titleOfSelectedItem baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_base contextInt:kBaseSerialContext];
        
        if(error!=nil) {
            [self refreshSerialList_base:error];
            [self appendToIncomingText_base:error];
        } else {
            [self refreshSerialList_base:titleOfSelectedItem];
            [self performSelectorInBackground:@selector(incomingTextUpdateThread_base:) withObject:[NSThread currentThread]];
        }
    });
}

- (void) serialPortSelected_maestro
{
    /*
     // open the serial port
     NSString *error = [self openSerialPort:[self.serialListPullDown_maestro titleOfSelectedItem] baud:kRHAPI_MAESTRO_BAUDRATE serialFileDescriptor:&serialFileDescriptor_maestro contextInt:kMaestroSerialContext];
     
     if(error!=nil) {
     [self refreshSerialList_maestro:error];
     [self appendToIncomingText_maestro:error];
     } else {
     [self refreshSerialList_maestro:[self.serialListPullDown_maestro titleOfSelectedItem]];
     [self performSelectorInBackground:@selector(incomingTextUpdateThread_maestro:) withObject:[NSThread currentThread]];
     }*/
}
/*
 // JUST AN EXAMPLE OF CHANGING THE BAUD RATE FOR INFORMATIONAL PUROSES
 - (IBAction) baudAction: (id) cntrl {
 if (serialFileDescriptor != -1) {
 speed_t baudRate = kRHAPI_BAUDRATE;
 
 // if the new baud rate isn't possible, refresh the serial list
 //   this will also deselect the current serial port
 if(ioctl(serialFileDescriptor, IOSSIOSPEED, &baudRate)==-1) {
 [self refreshSerialList:@"Error: Baud Rate out of bounds"];
 [self appendToIncomingText_head:@"Error: Baud Rate out of bounds"];
 }
 }
 }
 */

// action from refresh button
- (IBAction) refreshAction: (id) cntrl {
    [self refreshSerialList_head:@"Select a Serial Port"];
    [self refreshSerialList_torso:@"Select a Serial Port"];
    [self refreshSerialList_base:@"Select a Serial Port"];
    [self refreshSerialList_maestro:@"Select a Serial Port"];
    // close serial port if open
    if (serialFileDescriptor_head != -1) {
        close(serialFileDescriptor_head);
        serialFileDescriptor_head = -1;
    }
    if (serialFileDescriptor_torso != -1) {
        close(serialFileDescriptor_torso);
        serialFileDescriptor_torso = -1;
    }
    if (serialFileDescriptor_base != -1) {
        close(serialFileDescriptor_base);
        serialFileDescriptor_base = -1;
    }

    [self refreshSerialList_base:@"Detecting Base firmware\u2026"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self connectToDetectedBase];
    });
    
}

// action from send button and on return in the text field
- (void) sendText:(id)cntrl serialInputField:(NSTextField *)serialInputField serialFileDescriptor:(int)serialFileDescriptor{
    // send the text to the Arduino
    
    [self writeString:[serialInputField stringValue] serialFileDescriptor:serialFileDescriptor];
    
    // blank the field
    serialInputField.stringValue = @"";
    //[serialInputField setTitleWithMnemonic:@""];
}



- (IBAction) LACT_exitSafeStart
{
    exitSafeStart = true;
    /*
     uint8_t val = 170;    //0xAA = 170
     [self writeByte:&val];
     
     val = 13;            //0xD = 13
     [self writeByte:&val];
     
     val = 3;            //0x3 = 3
     [self writeByte:&val];
     */
    
    
    //This is not sending this crap to a listener, is it???
    //uint8_t val = 131;    //0x83 =
    //[self writeByte:&val serialFileDescriptor:serialFileDescriptor_base];
    
}


/*
 CGPoint touchPadPoint = CGPointMake([touchPad_array[0] floatValue], [touchPad_array[1] floatValue]);
 float Lat = [geoPosition_array[0] floatValue];
 float Long = [geoPosition_array[1] floatValue];
 bool tredBrakeLock = [[command_components[8] componentsSeparatedByString:@"tredBrakeLock="][1] boolValue];
 bool flipper1 = [flipper1_array[0] boolValue];
 bool flipper2 = [flipper1_array[1] boolValue];
 bool flipper3 = [flipper1_array[2] boolValue];
 bool flipper4 = [flipper1_array[3] boolValue];
 bool lact1 = [lact_array[0] boolValue];
 bool lact2 = [lact_array[1] boolValue];
 bool lact3 = [lact_array[2] boolValue];
 float speed = [speed_array[0] floatValue];
 bool speed_playPause = [speed_array[1] boolValue];
 bool speed_forward_reverse = [speed_array[2] boolValue];
 NSString *textInput = [command_components[12] componentsSeparatedByString:@"TEXT="][1];
 */

- (float) animateLeftToTargetSpeed:(float)newTargetSpeed //0-100
{
    float targetSpeed_x5 = newTargetSpeed * 10;
    //animate the target value gently to the other value with steady fixed increments per animation point
    if (self.actualSpeedL < targetSpeed_x5)
        self.actualSpeedL += 1;
    
    if (self.actualSpeedL > targetSpeed_x5)
        self.actualSpeedL -= 1;
    
    //Testing to see what happens here!!!
    self.actualSpeedL = targetSpeed_x5;
    
    return self.actualSpeedL/10;
}

- (float) animateRightToTargetSpeed:(float)newTargetSpeed //0-100
{
    float targetSpeed_x5 = newTargetSpeed * 10;
    //animate the target value gently to the other value with steady fixed increments per animation point
    if (self.actualSpeedR < targetSpeed_x5)
        self.actualSpeedR += 1;
    
    if (self.actualSpeedR > targetSpeed_x5)
        self.actualSpeedR -= 1;
    //Testing to see what happens here!!!
    self.actualSpeedR = targetSpeed_x5;
    
    return self.actualSpeedR/10;
}


- (IBAction)controllerPassthrough:(CGPoint)touchPadPointL
                   touchPadPointR:(CGPoint)touchPadPointR
                              Lat:(float)Lat
                             Long:(float)Long
                    tredBrakeLock:(bool)tredBrakeLock
             flipperForwardIsDown:(bool)flipperForwardIsDown
                flipperRelaxBrake:(bool)flipperRelaxBrake
            flipperBackwardIsDown:(bool)flipperBackwardIsDown
                 flipperBrakeLock:(bool)flipperBrakeLock
                            lact1:(bool)lact1
                            lact2:(bool)lact2
                            lact3:(bool)lact3
                            speed:(float)speed
                  speed_playPause:(bool)speed_playPause
            speed_forward_reverse:(bool)speed_forward_reverse
                        textInput:(NSString *)textInput
{
    //0 - 320 limit on touchPadPoint
    //Do we need independent brakes for each tred? or if its on only animate the tred that is asking for commands...
    //Can we make a tred lock pulse pattern to allow the robot to travel slowly downhill
    //Can we do this once we get interrupts working and tested for the speed controllers?!?!? lots of resoldering required
    int tredBrakeLockL = tredBrakeLock;
    int tredBrakeLockR = tredBrakeLock;
    
    float speedMagnitudeL = 0;
    float speedMagnitudeR = 0;
    NSString *motorDirection_forwardBackward_M1L = @"+";
    NSString *motorDirection_forwardBackward_M2R = @"+";
    NSString *actual_tred_speed_M1L = @"0000";
    NSString *actual_tred_speed_M2R = @"0000";
    
    int actual_speed_M1L = 0;
    int actual_speed_M2R = 0;
    
    //printf("-");
    ///------- DUPLICATED BLOCK IN ROBSerialBox.m ---------
    
    NSString *deltaText = [textInput stringByReplacingOccurrencesOfString:self.currentIncommingVerbalMessage withString:@""];
    
    if (![self.currentIncommingVerbalMessage isEqualToString:textInput] && ![self.tempTextInput isEqualToString:deltaText])
    {
        
        
        if (![self.tempTextInput isEqualToString:deltaText]) {
            //Only invalidate if the text is updated
            [self.verbalInputTimer invalidate];
            self.verbalInputTimer = nil;
            self.tempTextInput = deltaText;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (self.verbalInputTimer) {
                [self.verbalInputTimer invalidate];
                self.verbalInputTimer = nil;
            }
            self.verbalInputTimer = [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:false block:^(NSTimer *timer){
                if (deltaText != nil && ![deltaText isEqualToString:@""] && ![deltaText isEqualToString:@"(null)"])
                {
                    NSLog(@"heSaid: %@", deltaText);
                    [self.delegate resetSpeechResponseAttentionTimer];
                    [self.delegate inputText:deltaText];
                    [self.delegate clearInputTextMessage];
                    self.currentIncommingVerbalMessage = textInput;
                }
            }];
        });
        
    }
    //-----------------------------------------------------
    
    
    if (touchPadPointL.x > -999 && touchPadPointL.y > -999)
    {
        //normalize touchPadPoint
        //touchPadPointL = CGPointMake((touchPadPointL.x - 0.5), -(touchPadPointL.y - 0.5));
        //touchPadPointR = CGPointMake((touchPadPointR.x - 125.0)/125.0, -(touchPadPointR.y - 125.0)/125.0);
        
        speedMagnitudeL = sqrt(touchPadPointL.x * touchPadPointL.x + touchPadPointL.y * touchPadPointL.y);
        //speedMagnitudeR = sqrt(touchPadPointR.x * touchPadPointR.x + touchPadPointR.y * touchPadPointR.y);
        
        //touchPadPoint.x;
        float angleL = atan(touchPadPointL.y/touchPadPointL.x);
        float actualSpeedL = [self animateLeftToTargetSpeed:speed];
        
        //float angleR = atan(touchPadPointR.y/touchPadPointR.x);
        //float actualSpeedR = [self animateToTargetSpeed:speed];
        
        //Set MotorDirection
        motorDirection_forwardBackward_M1L = (touchPadPointL.y > 0 ) ? @"+" : @"-";
        //motorDirection_forwardBackward_M2R = (touchPadPointR.y > 0 ) ? @"+" : @"-";
        
        //Magnitude is between -0.5 and 0.5 so If we want 255 we have to multiply 0.5 * 2 for speed value
        actual_speed_M1L = (kMaxMovementSpeed*speedMagnitudeL*2)*actualSpeedL/100;
        //actual_speed_M2R = (kMaxMovementSpeed*speedMagnitudeR)*actualSpeedL/100;
        actual_speed_M1L = (actual_speed_M1L > 255) ? 255 : actual_speed_M1L;
        
        actual_tred_speed_M1L = [NSString stringWithFormat:@"%04d", actual_speed_M1L];
        //actual_tred_speed_M2R = [NSString stringWithFormat:@"%04d", actual_speed_M2R];
        
        tredBrakeLockL = false;
        //  Animate target_speed to the actual_speed values 0-255
        
        //replace255 with touchPadPointMagnitude --- speed is from 0-100
    }
    
    //Right Tred Code
    
    if (touchPadPointR.x > -999 && touchPadPointR.y > -999)
    {
        //normalize touchPadPoint
        //touchPadPointL = CGPointMake((touchPadPointL.x - 125.0)/125.0, -(touchPadPointL.y - 125.0)/125.0);
        //touchPadPointR = CGPointMake((touchPadPointR.x - 0.5), -(touchPadPointR.y - 0.5));
        
        //speedMagnitudeL = sqrt(touchPadPointL.x * touchPadPointL.x + touchPadPointL.y * touchPadPointL.y);
        speedMagnitudeR = sqrt(touchPadPointR.x * touchPadPointR.x + touchPadPointR.y * touchPadPointR.y);
        
        //float angleL = atan(touchPadPointL.y/touchPadPointL.x);
        //float actualSpeedL = [self animateToTargetSpeed:speed];
        
        float angleR = atan(touchPadPointR.y/touchPadPointR.x);
        float actualSpeedR = [self animateRightToTargetSpeed:speed];
        
        //Set MotorDirection
        //motorDirection_forwardBackward_M1L = (touchPadPointL.y > 0 ) ? @"+" : @"-";
        motorDirection_forwardBackward_M2R = (touchPadPointR.y > 0 ) ? @"+" : @"-";
        
        //Magnitude is between -0.5 and 0.5 so If we want 255 we have to multiply 0.5 * 2 for speed value
        //actual_speed_M1L = (kMaxMovementSpeed*speedMagnitudeL)*actualSpeedL/100;
        actual_speed_M2R = (kMaxMovementSpeed*speedMagnitudeR*2)*actualSpeedR/100;
        actual_speed_M2R = (actual_speed_M2R > 255) ? 255 : actual_speed_M2R;
        //actual_tred_speed_M1L = [NSString stringWithFormat:@"%04d", actual_speed_M1L];
        actual_tred_speed_M2R = [NSString stringWithFormat:@"%04d", actual_speed_M2R];
        
        tredBrakeLockR = false;
        //  Animate target_speed to the actual_speed values 0-255
        
        //replace255 with touchPadPointMagnitude --- speed is from 0-100
    }
    
    if (speed_playPause)
    {
        int actual_speed_M1L = (kMaxMovementSpeed)*speed/100;
        int actual_speed_M2R = (kMaxMovementSpeed)*speed/100;
        
        actual_tred_speed_M1L = [NSString stringWithFormat:@"%04d", actual_speed_M1L];
        actual_tred_speed_M2R = [NSString stringWithFormat:@"%04d", actual_speed_M2R];
        
        motorDirection_forwardBackward_M1L = (speed_forward_reverse) ? @"+" : @"-";
        motorDirection_forwardBackward_M2R = (speed_forward_reverse) ? @"+" : @"-";
        
        tredBrakeLockL = false;
        tredBrakeLockR = false;
    }
    
    
    int actual_speed_flipper = 0;
    NSString *flipper_direction = (flipperForwardIsDown) ? @"+" : @"-";
    actual_speed_flipper = (flipperForwardIsDown || flipperBackwardIsDown) ? 255 : 0 ;
    NSString *actual_flipper_speed = [NSString stringWithFormat:@"%04d", actual_speed_flipper];
    
    if (actual_speed_flipper > 0 || flipperRelaxBrake)
        flipperBrakeLock = false;
    
    NSString *lactDirection = (lact1) ? @"-" : @"+";
    NSString *lactSpeed = (lact1 || lact3) ? @"3200" : @"0000";
    if (exitSafeStart)
        lactSpeed = (lact1 || lact3) ? @"3201" : @"0000";
    //self.flipper_FORWARD_isDown, self.flipper_RELAX_isDown, self.flipper_BACKWARD_isDown, self.flipper_BRAKELOCK,
    //self.lact_BACK_isDown, self.lact_GRAVITY_toggle, self.lact_FRONT_isDown,
    
    
    NSString *base_command = [NSString stringWithFormat:@"~+000%i,%@%@,+000%i,%@%@,+000%i,%@%@,%@%@", (int)tredBrakeLockL,
                              motorDirection_forwardBackward_M1L, actual_tred_speed_M1L, (int)tredBrakeLockR, motorDirection_forwardBackward_M2R,
                              actual_tred_speed_M2R, (int)flipperBrakeLock, flipper_direction, actual_flipper_speed, lactDirection, lactSpeed];
    
    //NSLog(@"command = %@", command);
    
    [self writeString:base_command serialFileDescriptor:serialFileDescriptor_base];
    
    //******
    //Shows me i need to keep pulsing the data
    //Only worked with old wiring system which is now severed
    //[self debugTorsoCommandStrings];
    //******
}


- (void) torso_controllerPassthrough_head_pan:(NSString *)head_pan
                                    head_tilt:(NSString *)head_tilt
                           head_upperNeckTilt:(NSString *)head_upperNeckTilt
                           arm_R_shoulder_pan:(NSString *)arm_R_shoulder_pan
                          arm_R_shoulder_tilt:(NSString *)arm_R_shoulder_tilt
                              arm_R_elbow_pan:(NSString *)arm_R_elbow_pan
                             arm_R_elbow_tilt:(NSString *)arm_R_elbow_tilt
                              arm_R_wrist_pan:(NSString *)arm_R_wrist_pan
                             arm_R_wrist_tilt:(NSString *)arm_R_wrist_tilt
                                arm_R_gripper:(NSString *)arm_R_gripper
                           arm_L_shoulder_pan:(NSString *)arm_L_shoulder_pan
                          arm_L_shoulder_tilt:(NSString *)arm_L_shoulder_tilt
                              arm_L_elbow_pan:(NSString *)arm_L_elbow_pan
                             arm_L_elbow_tilt:(NSString *)arm_L_elbow_tilt
                              arm_L_wrist_pan:(NSString *)arm_L_wrist_pan
                             arm_L_wrist_tilt:(NSString *)arm_L_wrist_tilt
                                arm_L_gripper:(NSString *)arm_L_gripper

{
    //int position = maestroGetPosition(serialFileDescriptor_maestro, 0);
    //printf("Current position is %d.\n", position);
    //---
    //NSLog(@"headPan = %d, headTilt = %d, headUpperNeckTilt = %d", [head_pan intValue], [head_tilt intValue], [head_upperNeckTilt intValue]);
    //---
    //7790 max for upperNeckTilt, 4300 min for uppperNeckTilt
    //7675 max for headTilt, 4375 max for the headTilt
    
    maestroSetTarget(serialFileDescriptor_maestro, 0, [head_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 1, [head_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 2, [head_upperNeckTilt intValue]);
    
    maestroSetTarget(serialFileDescriptor_maestro, 4, [arm_L_elbow_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 5, [arm_R_elbow_pan intValue]);
    
    maestroSetTarget(serialFileDescriptor_maestro, 6, [arm_R_shoulder_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 7, [arm_R_shoulder_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 8, [arm_R_elbow_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 9, [arm_R_wrist_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 10, [arm_R_wrist_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 11, [arm_R_gripper intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 12, [arm_L_shoulder_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 13, [arm_L_shoulder_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 14, [arm_L_elbow_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 15, [arm_L_wrist_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 16, [arm_L_wrist_tilt intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 17, [arm_L_gripper intValue]);
    
    // Open the Maestro's virtual COM port.
    //"/dev/cu.usbmodem00034567";  // Mac OS X
    
    
    /*const char * device = [kRHAPI_SERIAL_PORT_MAESTRO_COM cStringUsingEncoding:NSUTF8StringEncoding];
     
     int fd = open(device, O_RDWR | O_NOCTTY);
     if (fd == -1)
     {
     perror(device);
     return;
     }
     
     
     struct termios options;
     tcgetattr(fd, &options);
     options.c_iflag &= ~(INLCR | IGNCR | ICRNL | IXON | IXOFF);
     options.c_oflag &= ~(ONLCR | OCRNL);
     options.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
     tcsetattr(fd, TCSANOW, &options);
     
     int position = maestroGetPosition(fd, 0);
     printf("Current position is %d.\n", position);
     
     int target = (position < 6000) ? 7000 : 5000;
     printf("Setting target to %d (%d us).\n", target, target/4);
     maestroSetTarget(fd, 0, target);
     
     close(fd);
     */
    
    
    
    //Track something!!! move this to affect SimpleUserTracker data
    //4000-8000
    /*
     NSString *head_pan = @"5875"; //6000-left 5800-right 5875-center
     NSString *head_tilt = @"5000";
     
     NSString *arm_R_shoulder_pan = @"7000"; //5000 points downward 7000 up
     NSString *arm_R_shoulder_tilt = @"6000";
     NSString *arm_R_elbow = @"6000";
     NSString *arm_R_wrist_pan = @"6000";
     NSString *arm_R_wrist_tilt = @"8000";
     NSString *arm_R_gripper = @"6000";
     
     NSString *arm_L_shoulder_pan = @"8000"; //4000 rotate 6000 neutral up backward 7000 points down
     NSString *arm_L_shoulder_tilt = @"6000";
     NSString *arm_L_elbow = @"6000";
     NSString *arm_L_wrist_pan = @"4000";
     NSString *arm_L_wrist_tilt = @"6000";
     NSString *arm_L_gripper = @"6000";
     */
    /*
     NSString *torso_command = [NSString stringWithFormat:@"~%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@",
     head_pan,
     head_tilt,
     arm_R_shoulder_pan,
     arm_R_shoulder_tilt,
     arm_R_elbow,
     arm_R_wrist_pan,
     arm_R_wrist_tilt,
     arm_R_gripper,
     arm_L_shoulder_pan,
     arm_L_shoulder_tilt,
     arm_L_elbow,
     arm_L_wrist_pan,
     arm_L_wrist_tilt,
     arm_L_gripper];
     
     [self writeString:torso_command serialFileDescriptor:serialFileDescriptor_torso];*/
}

- (void)applyVisionNeckPan:(float)pan tilt:(float)tilt
{
    if (!isfinite(pan) || !isfinite(tilt) || serialFileDescriptor_maestro < 0) {
        return;
    }
    // Normalized Vision Pro demands are converted only here, behind Cerebro's
    // fresh-master-controller gate. Channel 0 is neck pan and channel 2 is the
    // upper camera tilt used by the existing face tracker.
    float boundedPan = MAX(-1.0f, MIN(1.0f, pan));
    float boundedTilt = MAX(-1.0f, MIN(1.0f, tilt));
    int requestedPan = (int)lroundf(6000.0f + boundedPan * 2000.0f);
    int requestedTilt = (int)lroundf(6045.0f - boundedTilt * 1745.0f);
    // renderController runs at 10 Hz. Limit each accepted step so a tracking
    // discontinuity or rapid head turn cannot command a full-range servo jump.
    int maximumStep = 80;
    int panDelta = MAX(-maximumStep, MIN(maximumStep, requestedPan - self.lastVisionNeckPanTarget));
    int tiltDelta = MAX(-maximumStep, MIN(maximumStep, requestedTilt - self.lastVisionNeckTiltTarget));
    self.lastVisionNeckPanTarget += panDelta;
    self.lastVisionNeckTiltTarget += tiltDelta;
    maestroSetTarget(serialFileDescriptor_maestro, 0, self.lastVisionNeckPanTarget);
    maestroSetTarget(serialFileDescriptor_maestro, 2, self.lastVisionNeckTiltTarget);
}

- (void)applyVisionGrippersActive:(BOOL)active leftClosed:(BOOL)leftClosed rightClosed:(BOOL)rightClosed
{
    if (!active) {
        // Force a fresh edge after the operator reacquires the dead-man hold;
        // releasing safety authority never opens or closes a gripper by itself.
        self.visionGripperStateIsKnown = NO;
        return;
    }
    BOOL updateLeft = !self.visionGripperStateIsKnown
        || leftClosed != self.lastVisionLeftGripperClosed;
    BOOL updateRight = !self.visionGripperStateIsKnown
        || rightClosed != self.lastVisionRightGripperClosed;
    self.visionGripperStateIsKnown = YES;
    self.lastVisionLeftGripperClosed = leftClosed;
    self.lastVisionRightGripperClosed = rightClosed;

    if (updateLeft) {
        leftClosed ? [self closeGripper_L10:nil] : [self openGripper_L10:nil];
    }
    if (updateRight) {
        rightClosed ? [self closeGripper_R11:nil] : [self openGripper_R11:nil];
    }
}

- (void)applyVisionTorsoActive:(BOOL)active rotation:(float)rotation
{
    if (!active || !isfinite(rotation)) {
        if (self.visionTorsoControlWasActive) {
            self.visionTorsoControlWasActive = NO;
            exitSafeStart_waistRotation = false;
            energize_waistRotation = false;
            [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOff];
            [self.energizeWaistRotationButton setState:NSControlStateValueOff];
            [self runTiccmdArguments:@[@"--enter-safe-start", @"--deenergize"]];
        }
        return;
    }

    float boundedRotation = MAX(-1.0f, MIN(1.0f, rotation));
    BOOL justActivated = !self.visionTorsoControlWasActive;
    if (!self.visionTorsoControlWasActive) {
        self.visionTorsoControlWasActive = YES;
        self.visionTorsoBaselinePosition = self.waistRotationSlider != nil
            ? self.waistRotationSlider.intValue
            : self.lastVisionTorsoTarget;
        self.lastVisionTorsoTarget = self.visionTorsoBaselinePosition;
        exitSafeStart_waistRotation = true;
        energize_waistRotation = true;
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOn];
        [self.energizeWaistRotationButton setState:NSControlStateValueOn];
    }

    int minimumPosition = self.waistRotationSlider != nil
        ? (int)self.waistRotationSlider.minValue
        : -kROBTicWaistFullTurnPositionUnits;
    int maximumPosition = self.waistRotationSlider != nil
        ? (int)self.waistRotationSlider.maxValue
        : kROBTicWaistFullTurnPositionUnits;
    int requested = self.visionTorsoBaselinePosition
        + (int)lroundf(boundedRotation * kROBTicWaistHeadFollowMaximumUnits);
    requested = MAX(minimumPosition, MIN(maximumPosition, requested));
    // At the 10 Hz controller render rate, this limits target movement to 6000
    // Tic position units per second. The Tic's configured motor limits remain authoritative.
    int maximumStep = 600;
    int delta = MAX(-maximumStep, MIN(maximumStep, requested - self.lastVisionTorsoTarget));
    int target = self.lastVisionTorsoTarget + delta;
    if (!justActivated && target == self.lastVisionTorsoTarget && self.waistRotationSlider.intValue == target) {
        return;
    }
    self.lastVisionTorsoTarget = target;
    [self.waistRotationSlider setIntValue:target];
    [self runTiccmdArguments:@[
        @"--exit-safe-start", @"--energize", @"-p", [NSString stringWithFormat:@"%d", target]
    ]];
}

- (void) debugTorsoCommandStrings
{
    //~5875,5000,7000,6000,6000,6000,8000,6000,8000,6000,6000,4000,6000,6000
    
    NSString *head_pan = @"5875"; //6000-left 5800-right 5875-center
    NSString *head_tilt = @"5000";
    
    NSString *arm_R_shoulder_pan = @"7000"; //5000 points downward 7000 up
    NSString *arm_R_shoulder_tilt = @"6000";
    NSString *arm_R_elbow = @"6000";
    NSString *arm_R_wrist_pan = @"6000";
    NSString *arm_R_wrist_tilt = @"8000";
    NSString *arm_R_gripper = @"6000";
    
    NSString *arm_L_shoulder_pan = @"8000"; //4000 rotate 6000 neutral up backward 7000 points down
    NSString *arm_L_shoulder_tilt = @"6000";
    NSString *arm_L_elbow = @"6000";
    NSString *arm_L_wrist_pan = @"4000";
    NSString *arm_L_wrist_tilt = @"6000";
    NSString *arm_L_gripper = @"6000";
    
    
    NSString *torso_command = [NSString stringWithFormat:@"~%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@",
                               head_pan,
                               head_tilt,
                               arm_R_shoulder_pan,
                               arm_R_shoulder_tilt,
                               arm_R_elbow,
                               arm_R_wrist_pan,
                               arm_R_wrist_tilt,
                               arm_R_gripper,
                               arm_L_shoulder_pan,
                               arm_L_shoulder_tilt,
                               arm_L_elbow,
                               arm_L_wrist_pan,
                               arm_L_wrist_tilt,
                               arm_L_gripper];
    
    [self writeString:torso_command serialFileDescriptor:serialFileDescriptor_torso];
}

- (IBAction)forward:(id)sender
{
    [self writeString:@"~+0000,+0100,+0000,+0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)backward:(id)sender
{
    [self writeString:@"~+0000,-0100,+0000,-0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)left:(id)sender
{
    [self writeString:@"~+0000,-0100,+0000,+0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)right:(id)sender
{
    [self writeString:@"~+0000,+0100,+0000,-0100,+0000,+0000,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)flipperForwardPush:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0255,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)flipperBackwardPush:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,-0255,+0000" serialFileDescriptor:serialFileDescriptor_base];
}


- (IBAction)leanforward:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0000,+3200" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)leanback:(id)sender
{
    [self writeString:@"~+0000,+0000,+0000,+0000,+0000,+0000,-3200" serialFileDescriptor:serialFileDescriptor_base];
}

- (IBAction)speedSliderAction:(id)sender
{
    //we need to control a local speed value that is going to compete with the controller. who overrides who?
}

- (void)runTiccmdArguments:(NSArray<NSString *> *)arguments
{
    NSString *configuredPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"ROBTiccmdExecutablePath"];
    NSString *selection = configuredPath.length > 0
        ? configuredPath
        : @"/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd";
    NSString *ticcmdPath = [[selection stringByExpandingTildeInPath] stringByStandardizingPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:ticcmdPath]) {
        NSLog(@"Pololu ticcmd is unavailable at %@. Install the Pololu Tic software or set ROBTiccmdExecutablePath.", ticcmdPath);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *ticcmd = [[NSTask alloc] init];
        ticcmd.executableURL = [NSURL fileURLWithPath:ticcmdPath];
        ticcmd.arguments = arguments;
        NSPipe *pipe = [NSPipe pipe];
        ticcmd.standardOutput = pipe;
        ticcmd.standardError = pipe;

        NSError *launchError = nil;
        if (!ROBLaunchTaskSafely(ticcmd, &launchError)) {
            NSLog(@"Pololu ticcmd could not start: %@", launchError.localizedDescription);
            return;
        }
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (ticcmd.terminationStatus != 0 || output.length > 0) {
            NSLog(@"Pololu ticcmd: %@", output);
        }
    });
}

- (IBAction)waistRotationResetAction:(id)sender
{
    [self runTiccmdArguments:@[@"--reset"]];
}

- (IBAction)waistRotationSliderAction:(NSSlider *)sender
{
    NSLog(@"waistRotationSlider = %i", [sender intValue]);
    NSString *waistRotationValue = [NSString stringWithFormat:@"%i", [sender intValue]];
    NSMutableArray *arguments = @[].mutableCopy;
    if (exitSafeStart_waistRotation) {
        [arguments addObject:@"--exit-safe-start"];
    } else {
        [arguments addObject:@"--enter-safe-start"];
    }
    
    if (energize_waistRotation) {
        [arguments addObject:@"--energize"];
    } else {
        [arguments addObject:@"--deenergize"];
    }
    
    [arguments addObject:@"-p"];
    [arguments addObject:waistRotationValue];
    
    [self runTiccmdArguments:arguments];
}

- (IBAction)exitSafeStartWaistRotationToggle:(id)sender
{
    exitSafeStart_waistRotation = !exitSafeStart_waistRotation;
    if (exitSafeStart_waistRotation) {
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOn];
    } else {
        [self.exitSafeStartWaistRotationButton setState:NSControlStateValueOff];
    }
}

- (IBAction)energizeToggle:(id)sender
{
    energize_waistRotation = !energize_waistRotation;
    if (energize_waistRotation) {
        [self.energizeWaistRotationButton setState:NSControlStateValueOn];
    } else {
        [self.energizeWaistRotationButton setState:NSControlStateValueOff];
    }
}

- (void)performSSHpassOperation:(NSString *)operation block:(dispatch_block_t)block
{
    ROBSystemDependencyManager *manager = [ROBSystemDependencyManager sharedManager];
    if (manager.sshpassPath.length == 0) {
        NSString *managerName = ROBSystemPackageManagerDisplayName(manager.preferredPackageManager);
        NSError *error = [NSError errorWithDomain:ROBSystemDependencyErrorDomain
                                             code:ROBSystemDependencyErrorToolUnavailable
                                         userInfo:@{
            NSLocalizedDescriptionKey: @"sshpass is not installed.",
            NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:
                @"Open Cerebro Settings and explicitly install sshpass with %@.", managerName]
        }];
        [self reportSSHpassError:error operation:operation];
        return;
    }
    block();
}

- (BOOL)launchSSHpassTask:(NSTask *)task operation:(NSString *)operation
{
    NSError *error = nil;
    if (![[ROBSystemDependencyManager sharedManager] launchSSHpassTask:task
                                                              password:@"a"
                                                                 error:&error]) {
        [self reportSSHpassError:error operation:operation];
        return NO;
    }
    return YES;
}

- (void)reportSSHpassError:(NSError *)error operation:(NSString *)operation
{
    NSString *suggestion = error.userInfo[NSLocalizedRecoverySuggestionErrorKey];
    NSString *message = suggestion.length > 0
        ? [NSString stringWithFormat:@"%@ unavailable: %@ %@\n",
            operation,
            error.localizedDescription ?: @"unknown SSH error",
            suggestion]
        : [NSString stringWithFormat:@"%@ unavailable: %@\n",
            operation,
            error.localizedDescription ?: @"unknown SSH error"];
    NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.amberMasterCoreOutput_R11 != nil) {
            self.amberMasterCoreOutput_R11.string =
                [self.amberMasterCoreOutput_R11.string stringByAppendingString:message];
            [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
        }
        if (self.amberMasterCoreOutput_L10 != nil) {
            self.amberMasterCoreOutput_L10.string =
                [self.amberMasterCoreOutput_L10.string stringByAppendingString:message];
            [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
        }
    });
}

#pragma mark - R11 actions

- (IBAction) sshIntoAmberMasterAndRunTail_R11:(id)sender {
    if (self.sshTask_R11_log.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"R11 log connection" block:^{
        [self startSSHIntoAmberMasterAndRunTail_R11];
    }];
}

- (void)startSSHIntoAmberMasterAndRunTail_R11
{
    if (self.sshTask_R11_log.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_R11_log = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"tail", @"-n", @"+1", @"-f", @"/home/amber/R-11/core.log"
        ]
        error:&taskError];
    if (self.sshTask_R11_log == nil) {
        [self reportSSHpassError:taskError operation:@"R11 log connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_R11_log.standardOutput = pipe;
    self.sshTask_R11_log.standardError = pipe;
    
    self.receivedData_R11_log = [NSMutableData new];
    
    NSFileHandle *readFileHandle_R11 = [pipe fileHandleForReading];
    readFileHandle_R11.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_R11_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_R11_log encoding:NSUTF8StringEncoding];
            //NSLog(@"L10:\n%@", finalOutput);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_R11_isOnline = true;
            [self.receivedData_R11_log appendData:data];
            
            // For demonstration, print the partial output.
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            //NSLog(@"L10: %@", partialString);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_R11_log operation:@"R11 log connection"]) {
        readFileHandle_R11.readabilityHandler = nil;
        self.sshTask_R11_log = nil;
    }
}

- (IBAction) sshIntoAmberMasterAndRunCore_R11:(id)sender {
    if (self.sshTask_R11_Core.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"R11 core connection" block:^{
        [self startSSHIntoAmberMasterAndRunCore_R11];
    }];
}

- (void)startSSHIntoAmberMasterAndRunCore_R11
{
    if (self.sshTask_R11_Core.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_R11_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"cd", @"/home/amber/R-11/;", @"./amber_core_R"
        ]
        error:&taskError];
    if (self.sshTask_R11_Core == nil) {
        [self reportSSHpassError:taskError operation:@"R11 core connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_R11_Core.standardOutput = pipe;
    self.sshTask_R11_Core.standardError = pipe;
    
    self.receivedData_R11_Core = [NSMutableData new];
    
    NSFileHandle *readFileHandle_R11 = [pipe fileHandleForReading];
    readFileHandle_R11.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_R11_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_R11_Core encoding:NSUTF8StringEncoding];
            //NSLog(@"R11:\n%@", finalOutput);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        } else {
            self.core_R11_isOnline = true;
            // Append the new data to our storage.
            [self.receivedData_R11_Core appendData:data];
            
            // For demonstration, print the partial output.
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            //NSLog(@"R11: %@", partialString);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_R11.string = [self.amberMasterCoreOutput_R11.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_R11 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_R11 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_R11_Core operation:@"R11 core connection"]) {
        readFileHandle_R11.readabilityHandler = nil;
        self.sshTask_R11_Core = nil;
    }
}

- (IBAction) shutdown_R11_core:(id)sender {
    if (self.sshTask_R11_Core.isRunning) {
        [self.sshTask_R11_Core terminate];
    }
    self.sshTask_R11_Core = nil;
    [self performSSHpassOperation:@"R11 core shutdown" block:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self startShutdown_R11_core];
        });
    }];
}

- (void)startShutdown_R11_core
{
    NSError *taskError = nil;
    NSTask *sshTask_kill_R11_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"echo", @"a", @"|", @"sudo", @"-S", @"killall", @"amber_core_R"
        ]
        error:&taskError];
    if (sshTask_kill_R11_Core == nil) {
        [self reportSSHpassError:taskError operation:@"R11 core shutdown"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    sshTask_kill_R11_Core.standardOutput = pipe;
    sshTask_kill_R11_Core.standardError = pipe;

    if (![self launchSSHpassTask:sshTask_kill_R11_Core operation:@"R11 core shutdown"]) {
        return;
    }
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"sshTask_kill_R11_Core: %@", output);
}

- (IBAction)zeroPosition_R11:(id)sender {
    [self zeroPosition:sender port:26002];
}

- (IBAction)calibrateGripper_R11:(id)sender {
    [self calibrateGripper:sender port:26002];
}

- (IBAction)openGripper_R11:(id)sender {
    [self openGripper:sender port:26002 force:[NSString stringWithFormat:@"%i",[self.arm_R11_force intValue]]];
}

- (IBAction)closeGripper_R11:(id)sender {
    [self closeGripper:sender port:26002 force:[NSString stringWithFormat:@"%i",[self.arm_R11_force intValue]]];
}

- (IBAction) watch_position_out_R11:(id)sender {
    [self watch_position_out:sender port:26002];
}

- (IBAction)set_position_mode_R11:(id)sender {
    [self set_position_mode_v2:sender port: 26002];
}

- (IBAction)set_current_mode_R11:(id)sender {
    [self set_current_mode_v2:sender port: 26002];
}

- (IBAction)update_arm_R11_cartesian_Action:(id)sender {
    double cmdTime = [self.arm_R11_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_R11_positionX doubleValue]/100.0;
    double posY = [self.arm_R11_positionY doubleValue]/100.0;
    double posZ = [self.arm_R11_positionZ doubleValue]/100.0;
    double roll = [self.arm_R11_roll doubleValue]/100.0;
    double pitch = [self.arm_R11_pitch doubleValue]/100.0;
    double yaw = [self.arm_R11_yaw doubleValue]/100.0;
    
    [self update_arm_cartesian_v1:sender
                             port:26002
                          cmdTime:cmdTime
                         cmdSleep:cmdSleep
                             posX:posX
                             posY:posY
                             posZ:posZ
                             roll:roll
                            pitch:pitch
                              yaw:yaw];
}

- (IBAction)update_arm_R11_position_Action:(id)sender {
    double cmdTime = [self.arm_R11_position_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_R11_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_R11_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_R11_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_R11_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_R11_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_R11_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_R11_position_servo7 doubleValue]/100.0;
    
    [self update_arm_position_v1:sender
                            port:26002
                         cmdTime:cmdTime
                        cmdSleep:cmdSleep
                          servo1:servo1
                          servo2:servo2
                          servo3:servo3
                          servo4:servo4
                          servo5:servo5
                          servo6:servo6
                          servo7:servo7];
}

- (IBAction)activate_R11:(id)sender {
    [self activate:(id)sender port: 26002];
}

- (IBAction)deactivate_R11:(id)sender {
    [self deactivate:(id)sender port: 26002];
}

#pragma mark - L10 actions

- (IBAction) sshIntoAmberMasterAndRunTail_L10:(id)sender {
    if (self.sshTask_L10_log.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"L10 log connection" block:^{
        [self startSSHIntoAmberMasterAndRunTail_L10];
    }];
}

- (void)startSSHIntoAmberMasterAndRunTail_L10
{
    if (self.sshTask_L10_log.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_L10_log = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"tail", @"-n", @"+1", @"-f", @"/home/amber/L-10/core.log"
        ]
        error:&taskError];
    if (self.sshTask_L10_log == nil) {
        [self reportSSHpassError:taskError operation:@"L10 log connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_L10_log.standardOutput = pipe;
    self.sshTask_L10_log.standardError = pipe;
    
    self.receivedData_L10_log = [NSMutableData new];
    
    NSFileHandle *readFileHandle_L10 = [pipe fileHandleForReading];
    readFileHandle_L10.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_L10_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_L10_log encoding:NSUTF8StringEncoding];
            //NSLog(@"L10:\n%@", finalOutput);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_L10_isOnline = true;
            [self.receivedData_L10_log appendData:data];
            
            // For demonstration, print the partial output.
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            //NSLog(@"L10: %@", partialString);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_L10_log operation:@"L10 log connection"]) {
        readFileHandle_L10.readabilityHandler = nil;
        self.sshTask_L10_log = nil;
    }
}

- (IBAction) sshIntoAmberMasterAndRunCore_L10:(id)sender {
    if (self.sshTask_L10_Core.isRunning) {
        return;
    }
    [self performSSHpassOperation:@"L10 core connection" block:^{
        [self startSSHIntoAmberMasterAndRunCore_L10];
    }];
}

- (void)startSSHIntoAmberMasterAndRunCore_L10
{
    if (self.sshTask_L10_Core.isRunning) {
        return;
    }
    NSError *taskError = nil;
    self.sshTask_L10_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"cd", @"/home/amber/L-10/;", @"./amber_core_L"
        ]
        error:&taskError];
    if (self.sshTask_L10_Core == nil) {
        [self reportSSHpassError:taskError operation:@"L10 core connection"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    self.sshTask_L10_Core.standardOutput = pipe;
    self.sshTask_L10_Core.standardError = pipe;
    
    self.receivedData_L10_Core = [NSMutableData new];
    
    NSFileHandle *readFileHandle_L10 = [pipe fileHandleForReading];
    readFileHandle_L10.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        
        // If data is empty, the pipe has closed and we've reached EOF.
        if ([data length] == 0) {
            // Stop the handler to prevent further calls.
            handle.readabilityHandler = nil;
            self.core_L10_isOnline = false;
            // At this point, the task might still be running, but the pipe is closed.
            // You can process the final data here.
            NSString *finalOutput = [[NSString alloc] initWithData:self.receivedData_L10_Core encoding:NSUTF8StringEncoding];
            //NSLog(@"L10:\n%@", finalOutput);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:finalOutput];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });

        } else {
            // Append the new data to our storage.
            self.core_L10_isOnline = true;
            [self.receivedData_L10_Core appendData:data];
            
            // For demonstration, print the partial output.
            NSString *partialString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            //NSLog(@"L10: %@", partialString);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.amberMasterCoreOutput_L10.string = [self.amberMasterCoreOutput_L10.string stringByAppendingString:partialString];
                [self.amberMasterCoreOutput_L10 setNeedsDisplay:YES];
                [self.amberMasterCoreOutput_L10 scrollToEndOfDocument:nil];
            });
        }
    };

    if (![self launchSSHpassTask:self.sshTask_L10_Core operation:@"L10 core connection"]) {
        readFileHandle_L10.readabilityHandler = nil;
        self.sshTask_L10_Core = nil;
    }
}

- (IBAction) shutdown_L10_core:(id)sender {
    if (self.sshTask_L10_Core.isRunning) {
        [self.sshTask_L10_Core terminate];
    }
    self.sshTask_L10_Core = nil;
    [self performSSHpassOperation:@"L10 core shutdown" block:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self startShutdown_L10_core];
        });
    }];
}

- (void)startShutdown_L10_core
{
    NSError *taskError = nil;
    NSTask *sshTask_kill_L10_Core = [[ROBSystemDependencyManager sharedManager]
        newSSHpassTaskWithSSHArguments:@[
            [NSString stringWithFormat:@"amber@%@", self.amberHostIP],
            @"echo", @"a", @"|", @"sudo", @"-S", @"killall", @"amber_core_L"
        ]
        error:&taskError];
    if (sshTask_kill_L10_Core == nil) {
        [self reportSSHpassError:taskError operation:@"L10 core shutdown"];
        return;
    }
    NSPipe *pipe = [NSPipe pipe];
    sshTask_kill_L10_Core.standardOutput = pipe;
    sshTask_kill_L10_Core.standardError = pipe;

    if (![self launchSSHpassTask:sshTask_kill_L10_Core operation:@"L10 core shutdown"]) {
        return;
    }
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"sshTask_kill_L10_Core: %@", output);
}

- (IBAction)zeroPosition_L10:(id)sender {
    [self zeroPosition:sender port:26001];
}

- (IBAction)calibrateGripper_L10:(id)sender {
    [self calibrateGripper:sender port:26001];
}

- (IBAction)openGripper_L10:(id)sender {
    [self openGripper:sender port:26001 force:[NSString stringWithFormat:@"%i",[self.arm_L10_force intValue]]];
}

- (IBAction)closeGripper_L10:(id)sender {
    [self closeGripper:sender port:26001 force:[NSString stringWithFormat:@"%i",[self.arm_L10_force intValue]]];
}

- (IBAction) watch_position_out_L10:(id)sender {
    [self watch_position_out:sender port:26001];
}

- (IBAction)set_position_mode_L10:(id)sender {
    [self set_position_mode_v2:sender port: 26001];
}

- (IBAction)set_current_mode_L10:(id)sender {
    [self set_current_mode_v2:sender port: 26001];
}

- (IBAction)update_arm_L10_cartesian_Action:(id)sender {
    double cmdTime = [self.arm_L10_cartesian_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_cartesian_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_L10_cartesian_positionX doubleValue]/100.0;
    double posY = [self.arm_L10_cartesian_positionY doubleValue]/100.0;
    double posZ = [self.arm_L10_cartesian_positionZ doubleValue]/100.0;
    double roll = [self.arm_L10_cartesian_roll doubleValue]/100.0;
    double pitch = [self.arm_L10_cartesian_pitch doubleValue]/100.0;
    double yaw = [self.arm_L10_cartesian_yaw doubleValue]/100.0;
    
    [self update_arm_cartesian_v1:sender
                             port:26001
                          cmdTime:cmdTime
                         cmdSleep:cmdSleep
                             posX:posX
                             posY:posY
                             posZ:posZ
                             roll:roll
                            pitch:pitch
                              yaw:yaw];
}

- (IBAction)update_arm_L10_position_Action:(id)sender {
    double cmdTime = [self.arm_L10_position_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_L10_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_L10_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_L10_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_L10_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_L10_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_L10_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_L10_position_servo7 doubleValue]/100.0;
    
    [self update_arm_position_v1:sender
                            port:26001
                         cmdTime:cmdTime
                        cmdSleep:cmdSleep
                          servo1:servo1
                          servo2:servo2
                          servo3:servo3
                          servo4:servo4
                          servo5:servo5
                          servo6:servo6
                          servo7:servo7];
}

- (IBAction)activate_L10:(id)sender {
    [self activate:(id)sender port: 26001];
}

- (IBAction)deactivate_L10:(id)sender {
    [self deactivate:(id)sender port: 26001];
}

#pragma mark -

- (void)runPythonArguments:(NSArray<NSString *> *)arguments operation:(NSString *)operation
{
    NSError *error = nil;
    NSString *output = [[ROBPythonRuntime sharedRuntime] runPythonWithArguments:arguments error:&error];
    if (error != nil) {
        NSLog(@"%@: %@", operation, error.localizedDescription);
        return;
    }
    NSLog(@"%@: %@", operation, output ?: @"");
}

- (void) watch_position_out:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *watch_position_out = [[NSBundle mainBundle] pathForResource:@"watch_position_out" ofType:@"py"];
        //cmd_deactivate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:watch_position_out];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"watch_position_out"];
    });
}

- (void) deactivate:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_deactivate_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_deactivate_mode_v2" ofType:@"py"];
        //cmd_deactivate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_deactivate_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_deactivate_mode_v2"];
    });
}


- (void) activate:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_activate_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_activate_mode_v2" ofType:@"py"];
        //cmd_activate_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_activate_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_activate_mode_v2"];
    });
}

- (void) zeroPosition:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *zero_position_mode_v2 = [[NSBundle mainBundle] pathForResource:@"zero_position_mode_v2" ofType:@"py"];
        //zero_position_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:zero_position_mode_v2];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", 2.0]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", 0.0]];

        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"zero_position_mode_v2"];
    });
}

- (void) calibrateGripper:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *calibrateGripper_v2 = [[NSBundle mainBundle] pathForResource:@"calibrate_gripper_v2" ofType:@"py"];
        //calibrate_gripper_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:calibrateGripper_v2];
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"calibrateGripper_v2"];
    });

}

- (void) openGripper:(id)sender port:(int)port force:(NSString *)force {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *open_gripper_v2 = [[NSBundle mainBundle] pathForResource:@"open_gripper_v2" ofType:@"py"];
        //open_gripper_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:open_gripper_v2];
        
        [arguments addObject:@"--force"];
        [arguments addObject:force];
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"open_gripper_v2"];
    });
}

- (void) closeGripper:(id)sender port:(int)port force:(NSString *)force {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *close_gripper_v2 = [[NSBundle mainBundle] pathForResource:@"close_gripper_v2" ofType:@"py"];
        //close_gripper_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:close_gripper_v2];
        
        [arguments addObject:@"--force"];
        [arguments addObject:force];
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"close_gripper_v2"];
    });
}

- (void)set_position_mode_v2:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_position_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_position_mode_v2" ofType:@"py"];
        //cmd_position_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_position_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_position_mode_v2"];
    });
}

- (void)set_current_mode_v2:(id)sender port:(int)port {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_current_mode_v2 = [[NSBundle mainBundle] pathForResource:@"cmd_current_mode_v2" ofType:@"py"];
        //cmd_current_mode_v2.py --ip 10.0.0.5 --port 26002
        
        [arguments addObject:cmd_current_mode_v2];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_current_mode_v2"];
    });
    
}

- (void) update_arm_position_v1:(id)sender port:(int)port cmdTime:(double)cmdTime cmdSleep:(double)cmdSleep servo1:(double)servo1  servo2:(double)servo2 servo3:(double)servo3 servo4:(double)servo4 servo5:(double)servo5 servo6:(double)servo6 servo7:(double)servo7 {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSLog(@"arm_R11_servo1 = %f", servo1);
        NSLog(@"arm_R11_servo2 = %f", servo2);
        NSLog(@"arm_R11_servo3 = %f", servo3);
        NSLog(@"arm_R11_servo4 = %f", servo4);
        NSLog(@"arm_R11_servo5 = %f", servo5);
        NSLog(@"arm_R11_servo6 = %f", servo6);
        NSLog(@"arm_R11_servo7 = %f", servo7);
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_position_input = [[NSBundle mainBundle] pathForResource:@"cmd_position_input_v2" ofType:@"py"];
        //cmd_cartesian_input.py --ip 10.0.0.5 --port 26002 --cmd_time 2 --cmd_sleep 2 --pos_x 0.1 --pos_y -0.33 --pos_z 0.2 --roll 0.0 --pitch -1.5 --yaw 0.5
        //NSLog(@"cmd_cartesian_input = %@", cmd_cartesian_input);
        
        [arguments addObject:cmd_position_input];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdTime]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdSleep]];
        
        [arguments addObject:@"--servo1"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo1]];
        
        [arguments addObject:@"--servo2"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo2]];
        
        [arguments addObject:@"--servo3"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo3]];
        
        [arguments addObject:@"--servo4"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo4]];
        
        [arguments addObject:@"--servo5"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo5]];
        
        [arguments addObject:@"--servo6"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo6]];
        
        [arguments addObject:@"--servo7"];
        [arguments addObject:[NSString stringWithFormat:@"%f", servo7]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_position_input"];
    });
}

- (void) update_arm_cartesian_v1:(id)sender port:(int)port cmdTime:(double)cmdTime cmdSleep:(double)cmdSleep posX:(double)posX posY:(double)posY posZ:(double)posZ roll:(double)roll pitch:(double)pitch yaw:(double)yaw {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        NSLog(@"arm_R11_cmdTime = %f", cmdTime);
        NSLog(@"arm_R11_cmdSleep = %f", cmdSleep);
        NSLog(@"arm_R11_positionX = %f", posX);
        NSLog(@"arm_R11_positionY = %f", posY);
        NSLog(@"arm_R11_positionZ = %f", posZ);
        NSLog(@"arm_R11_roll = %f", roll);
        NSLog(@"arm_R11_pitch = %f", pitch);
        NSLog(@"arm_R11_yaw = %f", yaw);
        
        
        NSMutableArray *arguments = @[].mutableCopy;
        
        NSString *cmd_cartesian_input = [[NSBundle mainBundle] pathForResource:@"cmd_cartesian_input" ofType:@"py"];
        //cmd_cartesian_input.py --ip 10.0.0.5 --port 26002 --cmd_time 2 --cmd_sleep 2 --pos_x 0.1 --pos_y -0.33 --pos_z 0.2 --roll 0.0 --pitch -1.5 --yaw 0.5
        //NSLog(@"cmd_cartesian_input = %@", cmd_cartesian_input);
        
        [arguments addObject:cmd_cartesian_input];
        
        
        [arguments addObject:@"--ip"];
        [arguments addObject:self.amberHostIP];
        
        [arguments addObject:@"--port"];
        [arguments addObject:[NSString stringWithFormat:@"%i", port]];
        
        [arguments addObject:@"--cmd_time"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdTime]];
        
        [arguments addObject:@"--cmd_sleep"];
        [arguments addObject:[NSString stringWithFormat:@"%f", cmdSleep]];
        
        [arguments addObject:@"--pos_x"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posX]];
        
        [arguments addObject:@"--pos_y"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posY]];
        
        [arguments addObject:@"--pos_z"];
        [arguments addObject:[NSString stringWithFormat:@"%f", posZ]];
        
        [arguments addObject:@"--roll"];
        [arguments addObject:[NSString stringWithFormat:@"%f", roll]];
        
        [arguments addObject:@"--pitch"];
        [arguments addObject:[NSString stringWithFormat:@"%f", pitch]];
        
        [arguments addObject:@"--yaw"];
        [arguments addObject:[NSString stringWithFormat:@"%f", yaw]];
        
        NSLog(@"args = %@", arguments);
        
        [self runPythonArguments:arguments operation:@"cmd_cartesian_input"];
    });
}

#pragma mark -

- (void) sendHeadCommand:(NSString *)command
{
    [self writeString:command serialFileDescriptor:serialFileDescriptor_head];
}


- (void) sendTorsoCommand:(NSString *)command
{
    [self writeString:command serialFileDescriptor:serialFileDescriptor_torso];
}


- (void) sendBaseCommand:(NSString *)command
{
    [self writeString:command serialFileDescriptor:serialFileDescriptor_base];
}


- (void) sendMaestroCommand:(NSString *)command
{
    [self writeString:command serialFileDescriptor:serialFileDescriptor_maestro];
}


- (void) maestro_getErrors_command
{
    maestroGetErrors(serialFileDescriptor_maestro);
}

// action from the reset button
- (void) resetButton: (NSButton *) btn{
    // set and clear DTR to reset an arduino
    struct timespec interval = {0,100000000}, remainder;
    if(serialFileDescriptor_head!=-1) {
        ioctl(serialFileDescriptor_head, TIOCSDTR);
        nanosleep(&interval, &remainder); // wait 0.1 seconds
        ioctl(serialFileDescriptor_head, TIOCCDTR);
    }
    if(serialFileDescriptor_torso!=-1) {
        ioctl(serialFileDescriptor_torso, TIOCSDTR);
        nanosleep(&interval, &remainder); // wait 0.1 seconds
        ioctl(serialFileDescriptor_torso, TIOCCDTR);
    }
    if(serialFileDescriptor_base!=-1) {
        ioctl(serialFileDescriptor_base, TIOCSDTR);
        nanosleep(&interval, &remainder); // wait 0.1 seconds
        ioctl(serialFileDescriptor_base, TIOCCDTR);
    }
}




- (void) renderController
{
    //NSLog(@"self.masterControllerID = %@", self.masterControllerID);
    
    //render should fire the code [below here:]
    ROBBaseControllerModel *controllerModelData = [self.controlModelDataDictionary valueForKey:self.masterControllerID];
    
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL snapshotIsFresh = controllerModelData != nil &&
        controllerModelData.receivedAtUptime > 0 &&
        now - controllerModelData.receivedAtUptime <= kControllerSnapshotFreshnessSeconds;

    if (snapshotIsFresh)
    {
        //NSLog(@"//       ---------             RENDER CONTROLLER           ----------              //");
        //MasterControllerId data should go through
        [self controllerPassthrough:controllerModelData.touchPadPointL
                     touchPadPointR:controllerModelData.touchPadPointR
                                Lat:controllerModelData.Lat
                               Long:controllerModelData.Long
                      tredBrakeLock:controllerModelData.tredBrakeLock
               flipperForwardIsDown:controllerModelData.flipperForwardIsDown
                  flipperRelaxBrake:controllerModelData.flipperRelaxBrake
              flipperBackwardIsDown:controllerModelData.flipperBackwardIsDown
                   flipperBrakeLock:controllerModelData.flipperBrakeLock
                              lact1:controllerModelData.lact1
                              lact2:controllerModelData.lact2
                              lact3:controllerModelData.lact3
                              speed:controllerModelData.speed
                    speed_playPause:controllerModelData.speed_playPause
              speed_forward_reverse:controllerModelData.speed_forward_reverse
                          textInput:controllerModelData.textInput];
        if (controllerModelData.neckControlActive) {
            [self applyVisionNeckPan:controllerModelData.neckPan tilt:controllerModelData.neckTilt];
        }
        [self applyVisionGrippersActive:controllerModelData.gripperControlActive
                             leftClosed:controllerModelData.leftGripperClosed
                            rightClosed:controllerModelData.rightGripperClosed];
        [self applyVisionTorsoActive:controllerModelData.torsoControlActive
                           rotation:controllerModelData.torsoRotation];
        self.masterControllerInputWasFresh = YES;
    }
    else if (self.masterControllerInputWasFresh)
    {
        [self stopBaseMotionAndDropHeartbeat];
    }
}

- (void)stopBaseMotionAndDropHeartbeat
{
    [self applyVisionTorsoActive:NO rotation:0];
    // Values below -999 bypass joystick processing so the requested tread
    // brake bits remain set. This is written exactly once; renderController
    // then stays silent until a fresh authorized snapshot arrives.
    [self controllerPassthrough:CGPointMake(-1000.0, -1000.0)
                  touchPadPointR:CGPointMake(-1000.0, -1000.0)
                             Lat:0
                            Long:0
                   tredBrakeLock:true
            flipperForwardIsDown:false
               flipperRelaxBrake:false
           flipperBackwardIsDown:false
                flipperBrakeLock:true
                           lact1:false
                           lact2:false
                           lact3:false
                           speed:0.0
                 speed_playPause:false
           speed_forward_reverse:false
                       textInput:@""];
    self.masterControllerInputWasFresh = NO;
}


//Sent by the controller to authorize autonomous mode or become the masterController input
- (void) switchToMasterControllerID:(NSString *)controllerID
{
    if (![self.masterControllerID isEqualToString:controllerID] && self.masterControllerInputWasFresh) {
        [self stopBaseMotionAndDropHeartbeat];
    }
    self.masterControllerID = controllerID;
}


- (void) controllerId:(NSString *)controllerId controllerModelData:(ROBBaseControllerModel *)controllerModelData
{
    //store the control model data in the dictionary of data
    controllerModelData.receivedAtUptime = NSProcessInfo.processInfo.systemUptime;
    [self.controlModelDataDictionary setValue:controllerModelData forKey:controllerId];
}


@end
