//
//  ROBBaseSerialConsoleWindowController.m
//  Cerebro
//

#import "ROBBaseSerialConsoleWindowController.h"
#import "ROBSerialBox.h"

@interface ROBBaseSerialConsoleWindowController () <NSWindowDelegate>
@property (nonatomic, weak) ROBSerialBox *serialBox;
@property (nonatomic, strong) NSTextView *baseOutputTextView;
@property (nonatomic, strong) NSTextField *baseCommandField;
@property (nonatomic, strong) NSButton *sendButton;
@end

@implementation ROBBaseSerialConsoleWindowController

- (instancetype)initWithSerialBox:(ROBSerialBox *)serialBox
{
    NSRect frame = NSMakeRect(0, 0, 760, 460);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _serialBox = serialBox;
        window.title = @"Base Arduino Serial Console";
        window.releasedWhenClosed = NO;
        window.minSize = NSMakeSize(560, 320);
        window.delegate = self;
        [window center];
        [self buildInterface];
    }
    return self;
}

- (void)buildInterface
{
    NSView *contentView = self.window.contentView;

    NSTextField *explanation = [NSTextField labelWithString:
        @"Live Base output is displayed only while this window is open. Closing it stops UI capture but does not stop the Base connection or robot telemetry processing."];
    explanation.frame = NSMakeRect(20, 410, 720, 34);
    explanation.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    explanation.maximumNumberOfLines = 2;
    explanation.lineBreakMode = NSLineBreakByWordWrapping;
    explanation.textColor = NSColor.secondaryLabelColor;
    [contentView addSubview:explanation];

    NSScrollView *scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(20, 72, 720, 328)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.borderType = NSBezelBorder;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = NSColor.textBackgroundColor;
    scrollView.contentView.drawsBackground = YES;
    scrollView.contentView.backgroundColor = NSColor.textBackgroundColor;

    self.baseOutputTextView = [[NSTextView alloc]
        initWithFrame:scrollView.contentView.bounds];
    self.baseOutputTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.baseOutputTextView.editable = NO;
    self.baseOutputTextView.selectable = YES;
    self.baseOutputTextView.richText = NO;
    self.baseOutputTextView.font = [NSFont monospacedSystemFontOfSize:12.0
                                                             weight:NSFontWeightRegular];
    self.baseOutputTextView.textColor = NSColor.labelColor;
    self.baseOutputTextView.backgroundColor = NSColor.textBackgroundColor;
    self.baseOutputTextView.insertionPointColor = NSColor.labelColor;
    self.baseOutputTextView.drawsBackground = YES;
    self.baseOutputTextView.textContainerInset = NSMakeSize(6, 6);
    self.baseOutputTextView.accessibilityLabel = @"Base Arduino serial output";
    self.baseOutputTextView.accessibilityIdentifier = @"ROB.BaseSerialConsole.Output";
    scrollView.documentView = self.baseOutputTextView;
    [contentView addSubview:scrollView];

    self.baseCommandField = [[NSTextField alloc]
        initWithFrame:NSMakeRect(20, 22, 618, 28)];
    self.baseCommandField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.baseCommandField.placeholderString = @"Send a Base serial command";
    self.baseCommandField.target = self;
    self.baseCommandField.action = @selector(sendBaseCommand:);
    self.baseCommandField.accessibilityLabel = @"Base Arduino command";
    self.baseCommandField.accessibilityIdentifier = @"ROB.BaseSerialConsole.Command";
    [contentView addSubview:self.baseCommandField];

    self.sendButton = [NSButton buttonWithTitle:@"Send"
                                         target:self
                                         action:@selector(sendBaseCommand:)];
    self.sendButton.frame = NSMakeRect(650, 20, 90, 32);
    self.sendButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    self.sendButton.bezelStyle = NSBezelStyleRounded;
    self.sendButton.keyEquivalent = @"\r";
    self.sendButton.accessibilityIdentifier = @"ROB.BaseSerialConsole.Send";
    [contentView addSubview:self.sendButton];
}

- (void)bindSerialBox:(ROBSerialBox *)serialBox
{
    if (_serialBox == serialBox) {
        return;
    }
    [self detachConsole];
    _serialBox = serialBox;
    if (self.window.visible) {
        [self attachConsole];
    }
}

- (void)showWindow:(id)sender
{
    [self attachConsole];
    [super showWindow:sender];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:sender];
    [self.window makeFirstResponder:self.baseCommandField];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self detachConsole];
}

- (void)attachConsole
{
    self.serialBox.serialOutputArea_base = self.baseOutputTextView;
    BOOL available = self.serialBox != nil;
    self.baseCommandField.enabled = available;
    self.sendButton.enabled = available;
}

- (void)detachConsole
{
    ROBSerialBox *serialBox = self.serialBox;
    if (serialBox.serialOutputArea_base == self.baseOutputTextView) {
        serialBox.serialOutputArea_base = nil;
    }
}

- (void)sendBaseCommand:(id)sender
{
    NSString *command = [self.baseCommandField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (command.length == 0 || self.serialBox == nil) {
        NSBeep();
        return;
    }
    [self.serialBox sendBaseCommand:command];
    self.baseCommandField.stringValue = @"";
}

- (void)dealloc
{
    [self detachConsole];
}

@end
