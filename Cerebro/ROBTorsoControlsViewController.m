//
//  ROBTorsoControlsViewController.m
//  Cerebro
//
//  Created by Rob Makina on 5/10/19.
//  Copyright © 2019 Rob Makina. All rights reserved.
//

#import "ROBTorsoControlsViewController.h"
#import <AppKit/AppKit.h>
#import "ROBMainViewController.h"
#import "ROBSerialBox.h"
#import "ROBSpeechBox.h"
#import "Cerebro-Swift.h"
#import <netdb.h>
#import <arpa/inet.h>
#import <sys/socket.h>

static NSString * const ROBAmberHostIPDefaultsKey = @"ROBAmberHostIP";

@interface ROBTorsoControlsViewController () <NSTextFieldDelegate, NSTableViewDelegate, NSTableViewDataSource, NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (readwrite, retain) NSTimer *renderServoControlsTimer;
@property (readwrite, assign) BOOL is_in_position_mode_R11;
@property (readwrite, assign) BOOL is_in_current_mode_R11;
@property (readwrite, assign) BOOL is_in_speed_mode_R11;
@property (readwrite, assign) BOOL is_in_activated_mode_R11;

@property (readwrite, assign) BOOL is_in_position_mode_L10;
@property (readwrite, assign) BOOL is_in_current_mode_L10;
@property (readwrite, assign) BOOL is_in_speed_mode_L10;
@property (readwrite, assign) BOOL is_in_activated_mode_L10;
@property (nonatomic, strong) NSMutableArray<NSNetServiceBrowser *> *amberServiceBrowsers;
@property (nonatomic, strong) NSMutableSet<NSNetService *> *resolvingAmberServices;
- (void)startAmberHostDiscovery;
- (void)applyDiscoveredAmberHost:(NSString *)host source:(NSString *)source;
@end

@implementation ROBTorsoControlsViewController

- (void) viewDidLoad
{
    self.renderServoControlsTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                                     target:self
                                                                   selector:@selector(renderServoCommands)
                                                                   userInfo:nil
                                                                    repeats:YES];
    self.amberHostIP_TextField.delegate = self;
    NSString *savedAmberHost = [[NSUserDefaults standardUserDefaults] stringForKey:ROBAmberHostIPDefaultsKey];
    if (savedAmberHost.length > 0) {
        self.amberHostIP_TextField.stringValue = savedAmberHost;
    }
    [self startAmberHostDiscovery];
    
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
    //TODO: show this in a selectable tableView list
    keyframeAnimationManager.animations;
    
    self.keyframeNameTextField.stringValue = keyframeAnimationManager.currentAnimation.currentKeyframe.name;
}

- (IBAction)shutup:(id)sender {
    [self.robMainViewController.speechBox stopIt:nil];
    [self.robMainViewController resetSpeechResponseAttentionTimer];
    self.robMainViewController.speechBox.isSpeaking = false;
}

- (IBAction)restartSpeech:(id)sender {
    [self.robMainViewController.speechBox startRecognizer];
}

#pragma mark - KeyframeTableViewDelegate/Datasource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
    
    if (tableView == self.keyframeTableView) {
        return keyframeAnimationManager.currentAnimation.namedKeyframes.count;
    }
    if (tableView == self.keyframeSequenceDetailsTableView) {
        return keyframeAnimationManager.currentAnimation.currentSequence.keyframes.count;
    }
    if (tableView == self.keyframeSequencesTableView) {
        return keyframeAnimationManager.currentAnimation.namedSequences.count;
    }
    return 0;
}

// NSTableViewDelegate methods for view-based table views
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    // Get a reusable cell view or create a new one
    NSTableCellView *cellView = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];

    if (cellView == nil) {
        cellView = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cellView.identifier = tableColumn.identifier;

        // Add a text field to the cell view
        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.bordered = NO;
        textField.editable = NO;
        textField.backgroundColor = [NSColor clearColor];
        cellView.textField = textField;
        [cellView addSubview:textField];

        // Add constraints for the text field
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:5],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor constant:-5],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }
    
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];

    if (tableView == self.keyframeTableView) {
        // Populate the cell view with data
        if ([tableColumn.identifier isEqualToString:@"NamedKeyframes"]) { // Replace with your column identifier
            if (row < keyframeAnimationManager.currentAnimation.namedKeyframes.count) {
                cellView.textField.stringValue = keyframeAnimationManager.currentAnimation.namedKeyframes[row].name;
            }
        }
        return cellView;

    }
    if (tableView == self.keyframeSequenceDetailsTableView) {
        // Populate the cell view with data
        if ([tableColumn.identifier isEqualToString:@"SequenceDetails"]) { // Replace with your column identifier
            if (row < keyframeAnimationManager.currentAnimation.namedSequences.count) {
                int selectedSequenceRow = (int)self.keyframeSequencesTableView.selectedRow;
                if (selectedSequenceRow == -1) {
                    selectedSequenceRow = 0;
                }
                
                cellView.textField.stringValue = keyframeAnimationManager.currentAnimation.namedSequences[selectedSequenceRow].keyframes[row].name;
            }
        }
        return cellView;
    }
    if (tableView == self.keyframeSequencesTableView) {
        // Populate the cell view with data
        if ([tableColumn.identifier isEqualToString:@"NamedSequences"]) { // Replace with your column identifier
            if (row < keyframeAnimationManager.currentAnimation.namedSequences.count) {
                cellView.textField.stringValue = keyframeAnimationManager.currentAnimation.namedSequences[row].name;
            }
        }
        return cellView;
    }

    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSTableView *tableView = notification.object;
    NSInteger selectedRow = [tableView selectedRow];

    if (tableView == self.keyframeTableView) {
        if (selectedRow != -1) { // Check if a row is actually selected
            KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];

            Keyframe *selectedKeyframe = keyframeAnimationManager.currentAnimation.namedKeyframes[selectedRow];
            keyframeAnimationManager.currentAnimation.currentKeyframe = selectedKeyframe;
            self.keyframeNameTextField.stringValue = selectedKeyframe.name;
            [self.keyframeSequenceDetailsTableView reloadData];
            
        } else {
            NSLog(@"No row selected.");
        }
    }
    if (tableView == self.keyframeSequenceDetailsTableView) {
        
    }
    if (tableView == self.keyframeSequencesTableView) {
        if (selectedRow != -1) { // Check if a row is actually selected
            KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];

            KeyframeSequence *selectedSequence = keyframeAnimationManager.currentAnimation.namedSequences[selectedRow];
            keyframeAnimationManager.currentAnimation.currentSequence = selectedSequence;
            self.sequenceNameTextField.stringValue = selectedSequence.name;
            [self.keyframeSequenceDetailsTableView reloadData];
            
        } else {
            NSLog(@"No row selected.");
        }
    }
}

- (void)controlTextDidChange:(NSNotification *)obj {
    NSTextField *textField = obj.object;
    if (textField == self.amberHostIP_TextField) {
        NSLog(@"setting amberHostIP to %@", textField.stringValue);
        self.robMainViewController.serialBox.amberHostIP = textField.stringValue;
        [[NSUserDefaults standardUserDefaults] setObject:textField.stringValue
                                                  forKey:ROBAmberHostIPDefaultsKey];
    }
}

#pragma mark - Amber Ubuntu host discovery

- (void)startAmberHostDiscovery
{
    self.resolvingAmberServices = [NSMutableSet set];
    self.amberServiceBrowsers = [NSMutableArray array];

    // Ubuntu normally publishes its .local hostname through Avahi even when it
    // does not have a custom Amber service installed. ROB's controller reports
    // amber-master as its static hostname; retain amber.local as a legacy alias.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *hostName in @[@"amber-master.local", @"amber.local"]) {
            struct addrinfo hints = {0};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            struct addrinfo *results = NULL;
            int status = getaddrinfo(hostName.UTF8String, NULL, &hints, &results);
            BOOL found = NO;
            if (status == 0) {
                for (struct addrinfo *result = results; result != NULL; result = result->ai_next) {
                    struct sockaddr_in *address = (struct sockaddr_in *)result->ai_addr;
                    char buffer[INET_ADDRSTRLEN] = {0};
                    if (inet_ntop(AF_INET, &address->sin_addr, buffer, sizeof(buffer)) != NULL) {
                        NSString *host = [NSString stringWithUTF8String:buffer];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self applyDiscoveredAmberHost:host source:hostName];
                        });
                        found = YES;
                        break;
                    }
                }
            }
            if (results != NULL) { freeaddrinfo(results); }
            if (found) { break; }
        }
    });

    // This controller has been verified on ROB's LAN. Probe SSH before using
    // it so an offline/stale address does not replace a working saved value.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int descriptor = socket(AF_INET, SOCK_STREAM, 0);
        if (descriptor < 0) { return; }
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_port = htons(22);
        inet_pton(AF_INET, "10.0.0.26", &address.sin_addr);
        BOOL reachable = connect(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0;
        close(descriptor);
        if (reachable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self applyDiscoveredAmberHost:@"10.0.0.26" source:@"verified SSH controller"];
            });
        }
    });

    for (NSString *serviceType in @[@"_ssh._tcp.", @"_workstation._tcp."]) {
        NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
        browser.delegate = self;
        [self.amberServiceBrowsers addObject:browser];
        [browser searchForServicesOfType:serviceType inDomain:@"local."];
    }
    NSLog(@"Searching the local network for the Amber Ubuntu controller");
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    NSString *identity = [NSString stringWithFormat:@"%@ %@", service.name, service.hostName ?: @""];
    if ([identity rangeOfString:@"amber" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return;
    }
    service.delegate = self;
    [self.resolvingAmberServices addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    for (NSData *addressData in service.addresses) {
        const struct sockaddr *socketAddress = addressData.bytes;
        if (socketAddress == NULL || socketAddress->sa_family != AF_INET) { continue; }
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)socketAddress;
        char buffer[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer)) != NULL) {
            [self applyDiscoveredAmberHost:[NSString stringWithUTF8String:buffer]
                                   source:service.name];
            break;
        }
    }
    [self.resolvingAmberServices removeObject:service];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    NSLog(@"Could not resolve Amber service %@: %@", service.name, errorDict);
    [self.resolvingAmberServices removeObject:service];
}

- (void)applyDiscoveredAmberHost:(NSString *)host source:(NSString *)source
{
    if (host.length == 0) { return; }
    self.amberHostIP_TextField.stringValue = host;
    self.robMainViewController.serialBox.amberHostIP = host;
    [[NSUserDefaults standardUserDefaults] setObject:host forKey:ROBAmberHostIPDefaultsKey];
    NSLog(@"Discovered Amber controller at %@ via %@", host, source);
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];

    if (obj.object == self.keyframeNameTextField) {
        keyframeAnimationManager.currentAnimation.currentKeyframe.name = self.keyframeNameTextField.stringValue;
        [keyframeAnimationManager saveCurrentKeyframeAnimation];
    }
    if (obj.object == self.sequenceNameTextField) {
        keyframeAnimationManager.currentAnimation.currentSequence.name = self.sequenceNameTextField.stringValue;
        [keyframeAnimationManager saveCurrentKeyframeAnimation];
        [self.keyframeSequencesTableView reloadData];
    }
    
}

- (NSArray<NSTableViewRowAction *> *)tableView:(NSTableView *)tableView rowActionsForRow:(NSInteger)row edge:(NSTableRowActionEdge)edge {
    if (tableView == self.keyframeTableView) {
        if (edge == NSTableRowActionEdgeTrailing) { // Right swipe
            NSTableViewRowAction *deleteAction = [NSTableViewRowAction rowActionWithStyle:NSTableViewRowActionStyleDestructive
                                                                                    title:@"Delete"
                                                                                  handler:^(NSTableViewRowAction * _Nonnull action, NSInteger row) {
                // 1. Update your data source: Remove the item at 'row' from your underlying data model.
                //    For example, if you have an NSMutableArray called 'dataArray':
                //    [self.dataArray removeObjectAtIndex:row];
                KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
                Keyframe *removedKeyframe = [keyframeAnimationManager.currentAnimation.namedKeyframes objectAtIndex:row];
                [keyframeAnimationManager.currentAnimation removeNamedKeyframeWithName:removedKeyframe.name];
                [keyframeAnimationManager saveCurrentKeyframeAnimation];
                
                // 2. Update the table view: Remove the row from the NSTableView with animation.
                [tableView beginUpdates];
                [tableView removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:row] withAnimation:NSTableViewAnimationEffectFade];
                [tableView endUpdates];
            }];
            return @[deleteAction];
        }
    }
    if (tableView == self.keyframeSequenceDetailsTableView) {
        if (edge == NSTableRowActionEdgeTrailing) { // Right swipe
            NSTableViewRowAction *deleteAction = [NSTableViewRowAction rowActionWithStyle:NSTableViewRowActionStyleDestructive
                                                                                    title:@"Delete"
                                                                                  handler:^(NSTableViewRowAction * _Nonnull action, NSInteger row) {
                // 1. Update your data source: Remove the item at 'row' from your underlying data model.
                //    For example, if you have an NSMutableArray called 'dataArray':
                //    [self.dataArray removeObjectAtIndex:row];
                int selectedSequenceRow = (int)self.keyframeSequencesTableView.selectedRow;
                if (selectedSequenceRow == -1) {
                    selectedSequenceRow = 0;
                }
                KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
                //Keyframe *removedKeyframeFromSequence = [keyframeAnimationManager.currentAnimation.namedSequences objectAtIndex:selectedSequenceRow].keyframes[row];
                [keyframeAnimationManager.currentAnimation removeSequenceKeyframeWithIndex:row];
                [keyframeAnimationManager saveCurrentKeyframeAnimation];
                
                // 2. Update the table view: Remove the row from the NSTableView with animation.
                [tableView beginUpdates];
                [tableView removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:row] withAnimation:NSTableViewAnimationEffectFade];
                [tableView endUpdates];
            }];
            return @[deleteAction];
        }
    }
    if (tableView == self.keyframeSequencesTableView) {
        if (edge == NSTableRowActionEdgeTrailing) { // Right swipe
            NSTableViewRowAction *deleteAction = [NSTableViewRowAction rowActionWithStyle:NSTableViewRowActionStyleDestructive
                                                                                    title:@"Delete"
                                                                                  handler:^(NSTableViewRowAction * _Nonnull action, NSInteger row) {
                // 1. Update your data source: Remove the item at 'row' from your underlying data model.
                //    For example, if you have an NSMutableArray called 'dataArray':
                //    [self.dataArray removeObjectAtIndex:row];
                int selectedSequenceRow = (int)self.keyframeSequencesTableView.selectedRow;

                KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
                [keyframeAnimationManager.currentAnimation removeSequenceWithIndex:row];
                [keyframeAnimationManager saveCurrentKeyframeAnimation];
                
                // 2. Update the table view: Remove the row from the NSTableView with animation.
                [tableView beginUpdates];
                [tableView removeRowsAtIndexes:[NSIndexSet indexSetWithIndex:row] withAnimation:NSTableViewAnimationEffectFade];
                [tableView endUpdates];
            }];
            return @[deleteAction];
        }
    }
    return @[]; // No actions for leading edge (left swipe) or if not trailing edge
        
}

#pragma mark -

- (IBAction)newSequence:(id)sender {
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
    [keyframeAnimationManager.currentAnimation addNewNamedSequence];
    [self.keyframeSequencesTableView reloadData];
    [keyframeAnimationManager saveCurrentKeyframeAnimation];
}

- (IBAction)copyNamedKeyframeToCurrentSequence:(id)sender {
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];

    int selectedNamedKeyframe = (int) self.keyframeTableView.selectedRow;
    if (selectedNamedKeyframe == -1) {
        selectedNamedKeyframe = 0;
    }
    if (selectedNamedKeyframe < keyframeAnimationManager.currentAnimation.namedKeyframes.count) {
        Keyframe *keyframe = keyframeAnimationManager.currentAnimation.namedKeyframes[selectedNamedKeyframe];
        [keyframeAnimationManager.currentAnimation addKeyframeToCurrentSequence:keyframe];
        [self.keyframeSequenceDetailsTableView reloadData];
        [keyframeAnimationManager saveCurrentKeyframeAnimation];
    }
    
}

- (IBAction) playCurrentlySelectedKeyframeAnimation:(id)sender {
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
    int row = (int) self.keyframeTableView.selectedRow;
    if (row == -1) {
        row = 0;
        [self.keyframeTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    Keyframe *keyframe = keyframeAnimationManager.currentAnimation.namedKeyframes[row];

    BOOL shouldSleep = NO;
    if (!self.is_in_position_mode_R11 && keyframe.arm_R11_keyframe) {
        [self set_position_mode_R11_SendCommand:self];
        shouldSleep = YES;
    }
    if (!self.is_in_position_mode_L10 && keyframe.arm_L10_keyframe) {
        [self set_position_mode_L10_SendCommand:self];
        shouldSleep = YES;
    }
    if (shouldSleep) {
        sleep(2);
    }
    //Since we only have 1 keyframe selected... animate it... just for test purposes
    //1. get selected keyframe
    if (keyframe.arm_R11_keyframe) {
        self.arm_R11_cmdTime.doubleValue = keyframe.arm_R11_cmd_time;
        self.arm_R11_cmdSleep.doubleValue = keyframe.arm_R11_cmd_sleep;
        self.arm_R11_position_servo1.doubleValue = keyframe.arm_R11_servo1;
        self.arm_R11_position_servo2.doubleValue = keyframe.arm_R11_servo2;
        self.arm_R11_position_servo3.doubleValue = keyframe.arm_R11_servo3;
        self.arm_R11_position_servo4.doubleValue = keyframe.arm_R11_servo4;
        self.arm_R11_position_servo5.doubleValue = keyframe.arm_R11_servo5;
        self.arm_R11_position_servo6.doubleValue = keyframe.arm_R11_servo6;
        self.arm_R11_position_servo7.doubleValue = keyframe.arm_R11_servo7;
        
        [self update_arm_R11_Action:self]; //Updates all the label values with new servo values
        [self update_arm_R11_position_SendCommand:self]; //Sends the command to the arm
    }
    if (keyframe.arm_L10_keyframe) {
        NSLog(@"keyframe = %f, %f, %f, %f, %f, %f, %f", keyframe.arm_L10_servo1, keyframe.arm_L10_servo2, keyframe.arm_L10_servo3, keyframe.arm_L10_servo4, keyframe.arm_L10_servo5, keyframe.arm_L10_servo6, keyframe.arm_L10_servo7);
        self.arm_L10_position_cmdTime.doubleValue = keyframe.arm_L10_cmd_time;
        self.arm_L10_position_cmdSleep.doubleValue = keyframe.arm_L10_cmd_sleep;
        self.arm_L10_position_servo1.doubleValue = keyframe.arm_L10_servo1;
        self.arm_L10_position_servo2.doubleValue = keyframe.arm_L10_servo2;
        self.arm_L10_position_servo3.doubleValue = keyframe.arm_L10_servo3;
        self.arm_L10_position_servo4.doubleValue = keyframe.arm_L10_servo4;
        self.arm_L10_position_servo5.doubleValue = keyframe.arm_L10_servo5;
        self.arm_L10_position_servo6.doubleValue = keyframe.arm_L10_servo6;
        self.arm_L10_position_servo7.doubleValue = keyframe.arm_L10_servo7;
        
        [self update_arm_L10_Action:self]; //Updates all the label values with new servo values
        [self update_arm_L10_position_SendCommand:self]; //Sends the command to the arm
    }
//    for (Keyframe* keyframe in keyframeAnimationManager.currentAnimation.keyframeSequence) {
//        //This is for animating thorugh the sequence... we only have a selectable keyframe at the moment...
//    }
}

- (IBAction)captureKeyframe_Torso:(id)sender {
    //Example of setting properties to add keyframes. should be saved and loaded properly
    KeyframeAnimationManager *keyframeAnimationManager = [KeyframeAnimationManager shared];
    Keyframe *currentKeyframe = keyframeAnimationManager.currentAnimation.currentKeyframe;
    currentKeyframe.name = self.keyframeNameTextField.stringValue;
    currentKeyframe.arm_R11_keyframe = self.arm_R11_keyframe_enabled.state == NSControlStateValueOn ? YES : NO;
    if (currentKeyframe.arm_R11_keyframe) {
        currentKeyframe.arm_R11_cmd_time = self.arm_R11_cmdTime.doubleValue;
        currentKeyframe.arm_R11_cmd_sleep = self.arm_R11_cmdSleep.doubleValue;
        currentKeyframe.arm_R11_servo1 = self.arm_R11_position_servo1.doubleValue;
        currentKeyframe.arm_R11_servo2 = self.arm_R11_position_servo2.doubleValue;
        currentKeyframe.arm_R11_servo3 = self.arm_R11_position_servo3.doubleValue;
        currentKeyframe.arm_R11_servo4 = self.arm_R11_position_servo4.doubleValue;
        currentKeyframe.arm_R11_servo5 = self.arm_R11_position_servo5.doubleValue;
        currentKeyframe.arm_R11_servo6 = self.arm_R11_position_servo6.doubleValue;
        currentKeyframe.arm_R11_servo7 = self.arm_R11_position_servo7.doubleValue;
    }
    currentKeyframe.arm_L10_keyframe = self.arm_L10_keyframe_enabled.state == NSControlStateValueOn ? YES : NO;
    if (currentKeyframe.arm_L10_keyframe) {
        currentKeyframe.arm_L10_cmd_time = self.arm_L10_position_cmdTime.doubleValue;
        currentKeyframe.arm_L10_cmd_sleep = self.arm_L10_position_cmdSleep.doubleValue;
        currentKeyframe.arm_L10_servo1 = self.arm_L10_position_servo1.doubleValue;
        currentKeyframe.arm_L10_servo2 = self.arm_L10_position_servo2.doubleValue;
        currentKeyframe.arm_L10_servo3 = self.arm_L10_position_servo3.doubleValue;
        currentKeyframe.arm_L10_servo4 = self.arm_L10_position_servo4.doubleValue;
        currentKeyframe.arm_L10_servo5 = self.arm_L10_position_servo5.doubleValue;
        currentKeyframe.arm_L10_servo6 = self.arm_L10_position_servo6.doubleValue;
        currentKeyframe.arm_L10_servo7 = self.arm_L10_position_servo7.doubleValue;
    }
    //TODO: Bind cartesian commands as well
    
    //validate output is set
//    NSLog(@"servo1 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo1);
//    NSLog(@"servo2 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo2);
//    NSLog(@"servo3 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo3);
//    NSLog(@"servo4 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo4);
//    NSLog(@"servo5 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo5);
//    NSLog(@"servo6 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo6);
//    NSLog(@"servo7 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_R11_servo7);
//    
    NSLog(@"servo1 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo1);
    NSLog(@"servo2 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo2);
    NSLog(@"servo3 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo3);
    NSLog(@"servo4 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo4);
    NSLog(@"servo5 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo5);
    NSLog(@"servo6 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo6);
    NSLog(@"servo7 - %f", keyframeAnimationManager.currentAnimation.currentKeyframe.arm_L10_servo7);

    
    [keyframeAnimationManager.currentAnimation addNewNamedKeyframe];
    [keyframeAnimationManager saveCurrentKeyframeAnimation];
    [self.keyframeTableView reloadData];
    self.keyframeNameTextField.stringValue = keyframeAnimationManager.currentAnimation.currentKeyframe.name;
}

- (IBAction)mirrorPosition_R11_to_L10:(id)sender {
    self.arm_L10_position_cmdTime.doubleValue = self.arm_R11_position_cmdTime.doubleValue;
    self.arm_L10_position_cmdSleep.doubleValue = self.arm_R11_position_cmdSleep.doubleValue;
    self.arm_L10_position_servo1.doubleValue = -self.arm_R11_position_servo1.doubleValue;
    self.arm_L10_position_servo2.doubleValue = -self.arm_R11_position_servo2.doubleValue;
    self.arm_L10_position_servo3.doubleValue = -self.arm_R11_position_servo3.doubleValue;
    self.arm_L10_position_servo4.doubleValue = -self.arm_R11_position_servo4.doubleValue;
    self.arm_L10_position_servo5.doubleValue = -self.arm_R11_position_servo5.doubleValue;
    self.arm_L10_position_servo6.doubleValue = -self.arm_R11_position_servo6.doubleValue;
    self.arm_L10_position_servo7.doubleValue = -self.arm_R11_position_servo7.doubleValue;
    [self update_arm_L10_Action:self];
}

- (IBAction)mirrorPosition_L10_to_R11:(id)sender {
    self.arm_R11_position_cmdTime.doubleValue = self.arm_L10_position_cmdTime.doubleValue;
    self.arm_R11_position_cmdSleep.doubleValue = self.arm_L10_position_cmdSleep.doubleValue;
    self.arm_R11_position_servo1.doubleValue = -self.arm_L10_position_servo1.doubleValue;
    self.arm_R11_position_servo2.doubleValue = -self.arm_L10_position_servo2.doubleValue;
    self.arm_R11_position_servo3.doubleValue = -self.arm_L10_position_servo3.doubleValue;
    self.arm_R11_position_servo4.doubleValue = -self.arm_L10_position_servo4.doubleValue;
    self.arm_R11_position_servo5.doubleValue = -self.arm_L10_position_servo5.doubleValue;
    self.arm_R11_position_servo6.doubleValue = -self.arm_L10_position_servo6.doubleValue;
    self.arm_R11_position_servo7.doubleValue = -self.arm_L10_position_servo7.doubleValue;
    [self update_arm_R11_Action:self];
}

- (void) bindArm_controls
{
    self.robMainViewController.serialBox.amberHostIP = self.amberHostIP_TextField.stringValue;
    self.robMainViewController.serialBox.amberMasterCoreOutput_R11 = self.amberMasterCore_R11;
    self.robMainViewController.serialBox.amberMasterCoreOutput_L10 = self.amberMasterCore_L10;
    
    self.robMainViewController.serialBox.arm_R11_force = self.arm_R11_force;
    
    self.robMainViewController.serialBox.arm_R11_cmdTime = self.arm_R11_cmdTime;
    self.robMainViewController.serialBox.arm_R11_cmdSleep = self.arm_R11_cmdSleep;
    self.robMainViewController.serialBox.arm_R11_positionX = self.arm_R11_positionX;
    self.robMainViewController.serialBox.arm_R11_positionY = self.arm_R11_positionY;
    self.robMainViewController.serialBox.arm_R11_positionZ = self.arm_R11_positionZ;
    self.robMainViewController.serialBox.arm_R11_roll = self.arm_R11_roll;
    self.robMainViewController.serialBox.arm_R11_pitch = self.arm_R11_pitch;
    self.robMainViewController.serialBox.arm_R11_yaw = self.arm_R11_yaw;
    
    self.robMainViewController.serialBox.arm_R11_position_cmdTime = self.arm_R11_position_cmdTime;
    self.robMainViewController.serialBox.arm_R11_position_cmdSleep = self.arm_R11_position_cmdSleep;
    self.robMainViewController.serialBox.arm_R11_position_servo1 = self.arm_R11_position_servo1;
    self.robMainViewController.serialBox.arm_R11_position_servo2 = self.arm_R11_position_servo2;
    self.robMainViewController.serialBox.arm_R11_position_servo3 = self.arm_R11_position_servo3;
    self.robMainViewController.serialBox.arm_R11_position_servo4 = self.arm_R11_position_servo4;
    self.robMainViewController.serialBox.arm_R11_position_servo5 = self.arm_R11_position_servo5;
    self.robMainViewController.serialBox.arm_R11_position_servo6 = self.arm_R11_position_servo6;
    self.robMainViewController.serialBox.arm_R11_position_servo7 = self.arm_R11_position_servo7;
    
    self.robMainViewController.serialBox.arm_L10_force = self.arm_L10_force;
    
    self.robMainViewController.serialBox.arm_L10_cartesian_cmdTime = self.arm_L10_cartesian_cmdTime;
    self.robMainViewController.serialBox.arm_L10_cartesian_cmdSleep = self.arm_L10_cartesian_cmdSleep;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionX = self.arm_L10_cartesian_positionX;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionY = self.arm_L10_cartesian_positionY;
    self.robMainViewController.serialBox.arm_L10_cartesian_positionZ = self.arm_L10_cartesian_positionZ;
    self.robMainViewController.serialBox.arm_L10_cartesian_roll = self.arm_L10_cartesian_roll;
    self.robMainViewController.serialBox.arm_L10_cartesian_pitch = self.arm_L10_cartesian_pitch;
    self.robMainViewController.serialBox.arm_L10_cartesian_yaw = self.arm_L10_cartesian_yaw;
    
    self.robMainViewController.serialBox.arm_L10_position_cmdTime = self.arm_L10_position_cmdTime;
    self.robMainViewController.serialBox.arm_L10_position_cmdSleep = self.arm_L10_position_cmdSleep;
    self.robMainViewController.serialBox.arm_L10_position_servo1 = self.arm_L10_position_servo1;
    self.robMainViewController.serialBox.arm_L10_position_servo2 = self.arm_L10_position_servo2;
    self.robMainViewController.serialBox.arm_L10_position_servo3 = self.arm_L10_position_servo3;
    self.robMainViewController.serialBox.arm_L10_position_servo4 = self.arm_L10_position_servo4;
    self.robMainViewController.serialBox.arm_L10_position_servo5 = self.arm_L10_position_servo5;
    self.robMainViewController.serialBox.arm_L10_position_servo6 = self.arm_L10_position_servo6;
    self.robMainViewController.serialBox.arm_L10_position_servo7 = self.arm_L10_position_servo7;
    
}

#pragma mark - Servo Commands

- (IBAction) reconnectMaestro:(id)sender;
{
    [self.robMainViewController.serialBox connectMaestro];
}


- (IBAction) applyServoCommand:(NSSlider *)slider
{
    [self renderServoCommands];
}


- (void) renderServoCommands
{
    int offValue = 0;
    //[self.robMainViewController.serialBox connectMaestro];
    [self.robMainViewController.serialBox
     torso_controllerPassthrough_head_pan:[NSString stringWithFormat:@"%.f", self.headPan_enabled.state == NSControlStateValueOn? self.headPan.floatValue : offValue]
     head_tilt:[NSString stringWithFormat:@"%.f", self.headTilt_enabled.state == NSControlStateValueOn? self.headTilt.floatValue : offValue]
     head_upperNeckTilt:[NSString stringWithFormat:@"%.f", self.headUpperNeckTilt_enabled.state == NSControlStateValueOn? self.headUpperNeckTilt.floatValue : offValue]
     arm_R_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Shoulder_Pan.floatValue: offValue]
     arm_R_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Shoulder_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Shoulder_Tilt.floatValue: offValue]
     arm_R_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Elbow_Pan.floatValue : offValue]
     arm_R_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Elbow_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Elbow_Tilt.floatValue : offValue]
     arm_R_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Pan_enabled.state == NSControlStateValueOn? self.arm_R_Wrist_Pan.floatValue : offValue]
     arm_R_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_R_Wrist_Tilt_enabled.state == NSControlStateValueOn? self.arm_R_Wrist_Tilt.floatValue : offValue]
     arm_R_gripper:[NSString stringWithFormat:@"%.f", self.arm_R_Gripper_enabled.state == NSControlStateValueOn? self.arm_R_Gripper.floatValue : offValue]
     arm_L_shoulder_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Shoulder_Pan.floatValue : offValue]
     arm_L_shoulder_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Shoulder_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Shoulder_Tilt.floatValue : offValue]
     arm_L_elbow_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Elbow_Pan.floatValue : offValue]
     arm_L_elbow_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Elbow_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Elbow_Tilt.floatValue : offValue]
     arm_L_wrist_pan:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Pan_enabled.state == NSControlStateValueOn? self.arm_L_Wrist_Pan.floatValue : offValue]
     arm_L_wrist_tilt:[NSString stringWithFormat:@"%.f", self.arm_L_Wrist_Tilt_enabled.state == NSControlStateValueOn? self.arm_L_Wrist_Tilt.floatValue : offValue]
     arm_L_gripper:[NSString stringWithFormat:@"%.f", self.arm_L_Gripper_enabled.state == NSControlStateValueOn? self.arm_L_Gripper.floatValue : offValue]
     ];
}

- (IBAction)sshIntoAmberMasterAndRunTail_R11:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunTail_R11:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunTail_L10:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunTail_L10:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunCore_L10:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunCore_L10:self];
    });
}

- (IBAction)sshIntoAmberMasterAndRunCore_R11:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.robMainViewController.serialBox sshIntoAmberMasterAndRunCore_R11:self];
    });
}

- (IBAction) watchPositionOut_R11:(id)sender {
    [self.robMainViewController.serialBox watch_position_out_R11:self];
}

- (IBAction) watchPositionOut_L10:(id)sender {
    [self.robMainViewController.serialBox watch_position_out_L10:self];
}


- (IBAction) zeroPosition_R11:(id)sender {
    [self.arm_R11_position_servo1 setFloatValue:0.0];
    [self.arm_R11_position_servo1_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo2 setFloatValue:0.0];
    [self.arm_R11_position_servo2_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo3 setFloatValue:0.0];
    [self.arm_R11_position_servo3_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo4 setFloatValue:0.0];
    [self.arm_R11_position_servo4_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo5 setFloatValue:0.0];
    [self.arm_R11_position_servo5_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo6 setFloatValue:0.0];
    [self.arm_R11_position_servo6_label setStringValue:@"0.0"];
    [self.arm_R11_position_servo7 setFloatValue:0.0];
    [self.arm_R11_position_servo7_label setStringValue:@"0.0"];
    
    [self.robMainViewController.serialBox zeroPosition_R11:sender];
}

- (IBAction)calibrateGripper_R11:(id)sender {
    [self.robMainViewController.serialBox calibrateGripper_R11:sender];
}

- (IBAction) openGripper_R11:(id)sender {
    [self.robMainViewController.serialBox openGripper_R11:sender];
}

- (IBAction) closeGripper_R11:(id)sender {
    [self.robMainViewController.serialBox closeGripper_R11:sender];
}

- (IBAction)update_arm_R11_Action:(id)sender {
    
    int force = [self.arm_R11_force intValue];
    self.arm_R11_force_label.stringValue = [NSString stringWithFormat:@"%i", force];
    
    //-----
    
    double cmdTime = [self.arm_R11_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_R11_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_R11_positionX doubleValue]/100.0;
    double posY = [self.arm_R11_positionY doubleValue]/100.0;
    double posZ = [self.arm_R11_positionZ doubleValue]/100.0;
    double roll = [self.arm_R11_roll doubleValue]/100.0;
    double pitch = [self.arm_R11_pitch doubleValue]/100.0;
    double yaw = [self.arm_R11_yaw doubleValue]/100.0;
    
    self.arm_R11_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime];
    self.arm_R11_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep];
    self.arm_R11_positionX_label.stringValue = [NSString stringWithFormat:@"%f", posX];
    self.arm_R11_positionY_label.stringValue = [NSString stringWithFormat:@"%f", posY];
    self.arm_R11_positionZ_label.stringValue = [NSString stringWithFormat:@"%f", posZ];
    self.arm_R11_roll_label.stringValue = [NSString stringWithFormat:@"%f", roll];
    self.arm_R11_pitch_label.stringValue = [NSString stringWithFormat:@"%f", pitch];
    self.arm_R11_yaw_label.stringValue = [NSString stringWithFormat:@"%f", yaw];
    
    //-----
    
    double cmdTime_pos = [self.arm_R11_position_cmdTime doubleValue]/10.0;
    double cmdSleep_pos = [self.arm_R11_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_R11_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_R11_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_R11_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_R11_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_R11_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_R11_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_R11_position_servo7 doubleValue]/100.0;
    
    self.arm_R11_position_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime_pos];
    self.arm_R11_position_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep_pos];
    self.arm_R11_position_servo1_label.stringValue = [NSString stringWithFormat:@"%f", servo1];
    self.arm_R11_position_servo2_label.stringValue = [NSString stringWithFormat:@"%f", servo2];
    self.arm_R11_position_servo3_label.stringValue = [NSString stringWithFormat:@"%f", servo3];
    self.arm_R11_position_servo4_label.stringValue = [NSString stringWithFormat:@"%f", servo4];
    self.arm_R11_position_servo5_label.stringValue = [NSString stringWithFormat:@"%f", servo5];
    self.arm_R11_position_servo6_label.stringValue = [NSString stringWithFormat:@"%f", servo6];
    self.arm_R11_position_servo7_label.stringValue = [NSString stringWithFormat:@"%f", servo7];
}

- (IBAction) zeroPosition_L10:(id)sender {
    [self.arm_L10_position_servo1 setFloatValue:0.0];
    [self.arm_L10_position_servo1_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo2 setFloatValue:0.0];
    [self.arm_L10_position_servo2_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo3 setFloatValue:0.0];
    [self.arm_L10_position_servo3_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo4 setFloatValue:0.0];
    [self.arm_L10_position_servo4_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo5 setFloatValue:0.0];
    [self.arm_L10_position_servo5_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo6 setFloatValue:0.0];
    [self.arm_L10_position_servo6_label setStringValue:@"0.0"];
    [self.arm_L10_position_servo7 setFloatValue:0.0];
    [self.arm_L10_position_servo7_label setStringValue:@"0.0"];
    
    [self.robMainViewController.serialBox zeroPosition_L10:sender];
}

- (IBAction)calibrateGripper_L10:(id)sender {
    [self.robMainViewController.serialBox calibrateGripper_L10:sender];
}

- (IBAction) openGripper_L10:(id)sender {
    [self.robMainViewController.serialBox openGripper_L10:sender];
}

- (IBAction) closeGripper_L10:(id)sender {
    [self.robMainViewController.serialBox closeGripper_L10:sender];
}

- (IBAction)update_arm_L10_Action:(id)sender {
    int force = [self.arm_L10_force intValue];
    self.arm_L10_force_label.stringValue = [NSString stringWithFormat:@"%i", force];
    
    //-----
    
    double cmdTime = [self.arm_L10_cartesian_cmdTime doubleValue]/10.0;
    double cmdSleep = [self.arm_L10_cartesian_cmdSleep doubleValue]/10.0;
    double posX = [self.arm_L10_cartesian_positionX doubleValue]/100.0;
    double posY = [self.arm_L10_cartesian_positionY doubleValue]/100.0;
    double posZ = [self.arm_L10_cartesian_positionZ doubleValue]/100.0;
    double roll = [self.arm_L10_cartesian_roll doubleValue]/100.0;
    double pitch = [self.arm_L10_cartesian_pitch doubleValue]/100.0;
    double yaw = [self.arm_L10_cartesian_yaw doubleValue]/100.0;
    
    self.arm_L10_cartesian_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime];
    self.arm_L10_cartesian_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep];
    self.arm_L10_cartesian_positionX_label.stringValue = [NSString stringWithFormat:@"%f", posX];
    self.arm_L10_cartesian_positionY_label.stringValue = [NSString stringWithFormat:@"%f", posY];
    self.arm_L10_cartesian_positionZ_label.stringValue = [NSString stringWithFormat:@"%f", posZ];
    self.arm_L10_cartesian_roll_label.stringValue = [NSString stringWithFormat:@"%f", roll];
    self.arm_L10_cartesian_pitch_label.stringValue = [NSString stringWithFormat:@"%f", pitch];
    self.arm_L10_cartesian_yaw_label.stringValue = [NSString stringWithFormat:@"%f", yaw];
    
    //-----
    
    double cmdTime_pos = [self.arm_L10_position_cmdTime doubleValue]/10.0;
    double cmdSleep_pos = [self.arm_L10_position_cmdSleep doubleValue]/10.0;
    double servo1 = [self.arm_L10_position_servo1 doubleValue]/100.0;
    double servo2 = [self.arm_L10_position_servo2 doubleValue]/100.0;
    double servo3 = [self.arm_L10_position_servo3 doubleValue]/100.0;
    double servo4 = [self.arm_L10_position_servo4 doubleValue]/100.0;
    double servo5 = [self.arm_L10_position_servo5 doubleValue]/100.0;
    double servo6 = [self.arm_L10_position_servo6 doubleValue]/100.0;
    double servo7 = [self.arm_L10_position_servo7 doubleValue]/100.0;
    
    self.arm_L10_position_cmdTime_label.stringValue = [NSString stringWithFormat:@"%f", cmdTime_pos];
    self.arm_L10_position_cmdSleep_label.stringValue = [NSString stringWithFormat:@"%f", cmdSleep_pos];
    self.arm_L10_position_servo1_label.stringValue = [NSString stringWithFormat:@"%f", servo1];
    self.arm_L10_position_servo2_label.stringValue = [NSString stringWithFormat:@"%f", servo2];
    self.arm_L10_position_servo3_label.stringValue = [NSString stringWithFormat:@"%f", servo3];
    self.arm_L10_position_servo4_label.stringValue = [NSString stringWithFormat:@"%f", servo4];
    self.arm_L10_position_servo5_label.stringValue = [NSString stringWithFormat:@"%f", servo5];
    self.arm_L10_position_servo6_label.stringValue = [NSString stringWithFormat:@"%f", servo6];
    self.arm_L10_position_servo7_label.stringValue = [NSString stringWithFormat:@"%f", servo7];
}



//#pragma mark - R11 actions
//
//- (IBAction)set_position_mode_R11:(id)sender;
//- (IBAction)set_current_mode_R11:(id)sender;
//- (IBAction)update_arm_R11_cartesian_Action:(id)sender;
//- (IBAction)update_arm_R11_position_Action:(id)sender;
//- (IBAction)deactivate_R11:(id)sender;
//
//#pragma mark - L10 actions
//
//- (IBAction)set_position_mode_L10:(id)sender;
//- (IBAction)set_current_mode_L10:(id)sender;
//- (IBAction)update_arm_L10_cartesian_Action:(id)sender;
//- (IBAction)update_arm_L10_position_Action:(id)sender;
//- (IBAction)deactivate_L10:(id)sender;


#pragma mark - R11 arm

- (IBAction)set_position_mode_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = YES;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox set_position_mode_R11:sender];
}

- (IBAction)set_current_mode_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = YES;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox set_current_mode_R11:sender];
}

- (IBAction)update_arm_R11_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_cartesian_Action:sender];
}

- (IBAction)update_arm_R11_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_R11_position_Action:sender];
}

- (IBAction)activate_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = YES;
    [self.robMainViewController.serialBox activate_R11:sender];
}

- (IBAction)deactivate_R11_SendCommand:(id)sender {
    self.is_in_position_mode_R11 = NO;
    self.is_in_current_mode_R11 = NO;
    self.is_in_speed_mode_R11 = NO;
    self.is_in_activated_mode_R11 = NO;
    [self.robMainViewController.serialBox deactivate_R11:sender];
}

#pragma mark - L10 arm

- (IBAction)set_position_mode_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = YES;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox set_position_mode_L10:sender];
}

- (IBAction)set_current_mode_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = YES;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox set_current_mode_L10:sender];
}

- (IBAction)update_arm_L10_cartesian_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_cartesian_Action:sender];
}

- (IBAction)update_arm_L10_position_SendCommand:(id)sender {
    [self.robMainViewController.serialBox update_arm_L10_position_Action:sender];
}

- (IBAction)activate_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = YES;
    [self.robMainViewController.serialBox activate_L10:sender];
}

- (IBAction)deactivate_L10_SendCommand:(id)sender {
    self.is_in_position_mode_L10 = NO;
    self.is_in_current_mode_L10 = NO;
    self.is_in_speed_mode_L10 = NO;
    self.is_in_activated_mode_L10 = NO;
    [self.robMainViewController.serialBox deactivate_L10:sender];
}

- (IBAction) shutdown_R11_core:(id)sender {
    [self.robMainViewController.serialBox shutdown_R11_core:sender];
}

- (IBAction) shutdown_L10_core:(id)sender {
    [self.robMainViewController.serialBox shutdown_L10_core:sender];
}



@end
