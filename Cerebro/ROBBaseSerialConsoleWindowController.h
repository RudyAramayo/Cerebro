//
//  ROBBaseSerialConsoleWindowController.h
//  Cerebro
//

#import <Cocoa/Cocoa.h>

@class ROBSerialBox;

/// Optional Base Arduino diagnostics. The serial engine remains active when
/// this window is closed; only the potentially noisy UI output sink is
/// attached while the window is visible.
@interface ROBBaseSerialConsoleWindowController : NSWindowController

- (instancetype)initWithSerialBox:(ROBSerialBox *)serialBox NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithWindow:(NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)bindSerialBox:(ROBSerialBox *)serialBox;

@end
