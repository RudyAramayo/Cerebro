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


#define kRHAPI_BAUDRATE 250000

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

@property (readwrite, retain) NSTimer *verbalInputTimer;
@property (readwrite, retain) NSTimer *controllerTimer;

@property (readwrite, retain) NSString *tempTextInput;
@property (readwrite, retain) NSMutableDictionary *controlModelDataDictionary;

- (NSString *) openSerialPort: (NSString *)serialPortFile baud: (speed_t)baudRate serialFileDescriptor:(int *)serialFileDescriptor contextInt:(int)context;

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
    serialFileDescriptor_head = -1;
    serialFileDescriptor_torso = -1;
    serialFileDescriptor_base = -1;
    serialFileDescriptor_maestro = -1;
    self.actualSpeedL = 0;
    self.actualSpeedR = 0;
    readThreadRunning_head = FALSE;
    readThreadRunning_torso = FALSE;
    readThreadRunning_base = FALSE;
    readThreadRunning_maestro = FALSE;
    
    exitSafeStart = false;
    exitSafeStart_waistRotation = false;
    energize_waistRotation = false;
    
    self.currentIncommingVerbalMessage = @"";
    // first thing is to refresh the serial port list
    [self refreshSerialList_base:kRHAPI_SERIAL_PORT_BASE];
    [self refreshSerialList_torso:kRHAPI_SERIAL_PORT_TORSO];
    [self refreshSerialList_head:kRHAPI_SERIAL_PORT_HEAD];
    [self refreshSerialList_maestro:kRHAPI_SERIAL_PORT_MAESTRO_COM];
    self.controlModelDataDictionary = [NSMutableDictionary new];
    // now put the cursor in the text field
    //[serialInputField becomeFirstResponder];
    [NSThread sleepForTimeInterval:1];
    NSString *error = [self openSerialPort:kRHAPI_SERIAL_PORT_BASE baud:kRHAPI_BAUDRATE serialFileDescriptor:&serialFileDescriptor_base contextInt:kBaseSerialContext];
    [NSThread sleepForTimeInterval:1];

    if(error!=nil) {
        [self refreshSerialList_base:error];
        [self appendToIncomingText_base:error];
    } else {
        [self refreshSerialList_base:[self.serialListPullDown_base titleOfSelectedItem]];
        [self performSelectorInBackground:@selector(incomingTextUpdateThread_base:) withObject:[NSThread currentThread]];
    }
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
    NSString *text; // incoming text from the serial port
    
    // assign a high priority to this thread
    [NSThread setThreadPriority:1.0];
    
    // this will loop unitl the serial port closes
    while(TRUE) {
        // read() blocks until some data is available or the port is closed
        numBytes = read(serialFileDescriptor_base, byte_buffer, BUFFER_SIZE); // read up to the size of the buffer
        if(numBytes>0) {
            // create an NSString from the incoming bytes (the bytes aren't null terminated)
            //DEPRICATION:
            text = [NSString stringWithCString:byte_buffer length:numBytes];
            //text = [NSString stringWithCString:byte_buffer encoding:NSUTF8StringEncoding];
            
            // this text can't be directly sent to the text area from this thread
            //  BUT, we can call a selctor on the main thread.
            
            //[self performSelectorOnMainThread:@selector(appendToIncomingText_base:)
            //                       withObject:text
            //                    waitUntilDone:YES];
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
    
    maestroSetTarget(serialFileDescriptor_maestro, 0, [head_pan intValue]);
    maestroSetTarget(serialFileDescriptor_maestro, 1, [head_tilt intValue]);
    
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

- (IBAction)waistRotationResetAction:(id)sender
{
    NSTask *ticcmd = [NSTask new];
    ticcmd.launchPath = @"/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd";
    ticcmd.arguments = @[@"--reset"];
    
    NSPipe *pipe = [NSPipe pipe];
    ticcmd.standardOutput = pipe;
    
    [ticcmd launch];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
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
    
    NSTask *ticcmd = [NSTask new];
    ticcmd.launchPath = @"/Applications/Pololu Tic Stepper Motor Controller.app/Contents/MacOS/ticcmd";
    ticcmd.arguments = arguments;
    
    NSPipe *pipe = [NSPipe pipe];
    ticcmd.standardOutput = pipe;
    
    [ticcmd launch];
    
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
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
    
    if (controllerModelData != nil)
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
    }
    else
    {
        //NSLog(@"//*********** %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% ***********//");
        [self controllerPassthrough:CGPointMake(0.0, 0.0) touchPadPointR:CGPointMake(0.0, 0.0) Lat:0 Long:0 tredBrakeLock:false flipperForwardIsDown:false flipperRelaxBrake:false flipperBackwardIsDown:false flipperBrakeLock:false lact1:false lact2:false lact3:false speed:0.0 speed_playPause:false speed_forward_reverse:false textInput:@""];
    }
}


//Sent by the controller to authorize autonomous mode or become the masterController input
- (void) switchToMasterControllerID:(NSString *)controllerID
{
    self.masterControllerID = controllerID;
}


- (void) controllerId:(NSString *)controllerId controllerModelData:(ROBBaseControllerModel *)controllerModelData
{
    //store the control model data in the dictionary of data
    [self.controlModelDataDictionary setValue:controllerModelData forKey:controllerId];
}


@end





