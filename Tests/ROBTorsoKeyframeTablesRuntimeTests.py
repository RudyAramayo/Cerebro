#!/usr/bin/env python3
"""Exercise production table methods with real Swift-array/NSArray bridging.

Only inert view objects and the manager's persistence seam are substituted.
No application, window, robot service, motor or file persistence is started.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Cerebro/ROBTorsoControlsViewController.m").read_text()
helper = source[source.index("static BOOL ROBTorsoTableRowIsValid"):source.index("static NSTextField *ROBNeckLabel")]
tables = source[source.index("- (NSInteger)numberOfRowsInTableView:"):source.index("- (void)controlTextDidChange:")]
# Foundation may load CoreAutoLayout, which owns NSLayoutConstraint. Keep the
# inert layout seam uniquely named instead of shadowing that runtime class.
tables = tables.replace("[NSLayoutConstraint activateConstraints:", "[ROBFixtureLayoutConstraint activateConstraints:")
actions = source[source.index("- (NSArray<NSTableViewRowAction *> *)tableView:"):source.index("- (IBAction)captureKeyframe_Torso:")]
models = (ROOT / "Cerebro/KeyframeAnimationManager.swift").read_text()
models = "import Foundation\n" + models[models.index("@objcMembers public class KeyframeAnimation: "):]
models += """
@objcMembers public class KeyframeAnimationManager: NSObject {
    public static let shared = KeyframeAnimationManager()
    public var currentAnimation: KeyframeAnimation?
    public var saveCount = 0
    public func saveCurrentKeyframeAnimation() { saveCount += 1 }
}
"""

HARNESS = r'''
#import <Foundation/Foundation.h>
#import "FixtureModels-Swift.h"
#include <assert.h>
typedef NSString *NSUserInterfaceItemIdentifier;
typedef NS_ENUM(NSInteger, NSTableRowActionEdge) { NSTableRowActionEdgeLeading, NSTableRowActionEdgeTrailing };
static NSInteger const NSTableViewRowActionStyleDestructive=1, NSTableViewAnimationEffectFade=1;
@interface Anchor : NSObject
- (id)constraintEqualToAnchor:(id)anchor constant:(CGFloat)constant;
- (id)constraintEqualToAnchor:(id)anchor;
@end
@implementation Anchor
- (id)constraintEqualToAnchor:(id)a constant:(CGFloat)c { return [NSObject new]; }
- (id)constraintEqualToAnchor:(id)a { return [NSObject new]; }
@end
@interface NSView : NSObject
@property(strong) Anchor *leadingAnchor, *trailingAnchor, *centerYAnchor;
- (id)initWithFrame:(NSRect)frame;
- (void)addSubview:(id)view;
@end
@implementation NSView
- (id)initWithFrame:(NSRect)frame { if((self=[super init])) { _leadingAnchor=[Anchor new]; _trailingAnchor=[Anchor new]; _centerYAnchor=[Anchor new]; } return self; }
- (void)addSubview:(id)view {}
@end
@interface NSTextField : NSView
@property(copy) NSString *stringValue;
@property BOOL translatesAutoresizingMaskIntoConstraints, bordered, editable;
@property(strong) id backgroundColor;
@end
@implementation NSTextField @end
@interface NSColor : NSObject
+ (id)clearColor;
@end
@implementation NSColor
+ (id)clearColor { return [NSObject new]; }
@end
@interface ROBFixtureLayoutConstraint : NSObject
+ (void)activateConstraints:(NSArray *)constraints;
@end
@implementation ROBFixtureLayoutConstraint
+ (void)activateConstraints:(NSArray *)constraints {}
@end
@interface NSTableCellView : NSView
@property(copy) NSString *identifier;
@property(strong) NSTextField *textField;
@end
@implementation NSTableCellView @end
@interface NSTableColumn : NSObject
@property(copy) NSString *identifier;
@end
@implementation NSTableColumn @end
@interface NSTableView : NSView
@property NSInteger selectedRow;
@property NSUInteger reloads;
@property(strong) NSTableCellView *reused;
- (id)makeViewWithIdentifier:(NSString *)identifier owner:(id)owner;
- (void)reloadData;
- (void)beginUpdates;
- (void)endUpdates;
- (void)removeRowsAtIndexes:(NSIndexSet *)rows withAnimation:(NSInteger)animation;
- (void)selectRowIndexes:(NSIndexSet *)rows byExtendingSelection:(BOOL)extend;
@end
@implementation NSTableView
- (id)makeViewWithIdentifier:(NSString *)identifier owner:(id)owner { return self.reused; }
- (void)reloadData { self.reloads++; }
- (void)beginUpdates {}
- (void)endUpdates {}
- (void)removeRowsAtIndexes:(NSIndexSet *)rows withAnimation:(NSInteger)animation {}
- (void)selectRowIndexes:(NSIndexSet *)rows byExtendingSelection:(BOOL)extend { self.selectedRow=rows.firstIndex; }
@end
@interface NSTableViewRowAction : NSObject
@property(copy) void (^handler)(NSTableViewRowAction *, NSInteger);
+ (id)rowActionWithStyle:(NSInteger)style title:(NSString *)title handler:(void (^)(NSTableViewRowAction *, NSInteger))handler;
@end
@implementation NSTableViewRowAction
+ (id)rowActionWithStyle:(NSInteger)s title:(NSString *)t handler:(void (^)(NSTableViewRowAction *, NSInteger))h { NSTableViewRowAction *a=[self new]; a.handler=h; return a; }
@end
@interface Slider : NSObject
@property double doubleValue;
@end
@implementation Slider @end
__HELPER__
@interface Harness : NSObject
@property(strong) NSTableView *keyframeTableView, *keyframeSequencesTableView, *keyframeSequenceDetailsTableView;
@property(strong) NSTextField *keyframeNameTextField, *sequenceNameTextField;
@property BOOL is_in_position_mode_R11, is_in_position_mode_L10;
@property NSUInteger motorCalls;
__SLIDERS__
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table;
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (void)tableViewSelectionDidChange:(NSNotification *)notification;
@end
@implementation Harness
- (void)set_position_mode_R11_SendCommand:(id)s { self.motorCalls++; }
- (void)set_position_mode_L10_SendCommand:(id)s { self.motorCalls++; }
- (void)update_arm_R11_Action:(id)s { self.motorCalls++; }
- (void)update_arm_L10_Action:(id)s { self.motorCalls++; }
- (void)update_arm_R11_position_SendCommand:(id)s { self.motorCalls++; }
- (void)update_arm_L10_position_SendCommand:(id)s { self.motorCalls++; }
__TABLES__
__ACTIONS__
@end
static NSString *cell(Harness *h, NSTableView *table, NSString *identifier, NSInteger row) {
    NSTableColumn *column=[NSTableColumn new]; column.identifier=identifier;
    NSTableCellView *view=(id)[h tableView:table viewForTableColumn:column row:row];
    table.reused=view;
    return view.textField.stringValue;
}
static Keyframe *key(NSString *name) { Keyframe *k=[Keyframe new]; k.name=name; return k; }
int main(void) { @autoreleasepool {
    Harness *h=[Harness new]; h.keyframeTableView=[NSTableView new];
    h.keyframeSequencesTableView=[NSTableView new]; h.keyframeSequenceDetailsTableView=[NSTableView new];
    h.keyframeNameTextField=[NSTextField new]; h.sequenceNameTextField=[NSTextField new];
    KeyframeAnimationManager *manager=KeyframeAnimationManager.shared;
    manager.currentAnimation=nil;
    assert([h numberOfRowsInTableView:h.keyframeSequenceDetailsTableView]==0);
    assert([cell(h,h.keyframeSequenceDetailsTableView,@"SequenceDetails",0) isEqual:@""]);
    KeyframeAnimation *a=[KeyframeAnimation new]; manager.currentAnimation=a;
    KeyframeSequence *shortSequence=[KeyframeSequence new]; shortSequence.name=@"short";
    shortSequence.keyframes=@[key(@"other")]; a.namedSequences=@[shortSequence];
    KeyframeSequence *current=[KeyframeSequence new]; current.name=@"current";
    current.keyframes=@[key(@"one"),key(@"two"),key(@"three"),key(@"four")]; a.currentSequence=current;
    a.namedKeyframes=@[key(@"named")];
    // Restored table selection and saved currentSequence can disagree. Row
    // count and display must still refer to the same current model snapshot.
    for(NSNumber *n in @[@(-3),@(-1),@(0),@(1),@(NSIntegerMax)]) {
        h.keyframeSequencesTableView.selectedRow=n.integerValue;
        assert([h numberOfRowsInTableView:h.keyframeSequenceDetailsTableView]==4);
        assert([cell(h,h.keyframeSequenceDetailsTableView,@"SequenceDetails",3) isEqual:@"four"]);
    }
    // Both negative and stale rows clear reused text for every table type.
    NSArray *tables=@[h.keyframeTableView,h.keyframeSequencesTableView,h.keyframeSequenceDetailsTableView];
    NSArray *columns=@[@"NamedKeyframes",@"NamedSequences",@"SequenceDetails"];
    for(NSUInteger i=0;i<tables.count;i++) {
        NSTableView *t=tables[i]; NSString *identifier=columns[i];
        assert(cell(h,t,identifier,0).length>0);
        for(NSNumber *n in @[@(-2),@(-1),@(8),@(NSIntegerMax)]) {
            assert([cell(h,t,identifier,n.integerValue) isEqual:@""]);
            t.selectedRow=n.integerValue;
            [h tableViewSelectionDidChange:[NSNotification notificationWithName:@"Selection" object:t]];
        }
        assert([cell(h,t,@"Unknown",0) isEqual:@""]);
    }
    assert(a.currentSequence==current);
    h.keyframeSequencesTableView.selectedRow=0;
    [h tableViewSelectionDidChange:[NSNotification notificationWithName:@"Selection" object:h.keyframeSequencesTableView]];
    assert(a.currentSequence==shortSequence);
    assert([h numberOfRowsInTableView:h.keyframeSequenceDetailsTableView]==1);
    assert([cell(h,h.keyframeSequenceDetailsTableView,@"SequenceDetails",0) isEqual:@"other"]);
    assert([cell(h,h.keyframeSequenceDetailsTableView,@"SequenceDetails",3) isEqual:@""]);
    // Swift arrays can become empty while AppKit still asks for stale rows.
    a.namedSequences=@[]; a.namedKeyframes=@[]; a.currentSequence=[KeyframeSequence new];
    for(NSUInteger i=0;i<tables.count;i++) {
        NSTableView *t=tables[i];
        assert([h numberOfRowsInTableView:t]==0);
        assert([cell(h,t,columns[i],0) isEqual:@""]);
        for(NSNumber *n in @[@(-2),@(-1),@(0),@(999)]) {
            t.selectedRow=n.integerValue;
            [h tableViewSelectionDidChange:[NSNotification notificationWithName:@"Selection" object:t]];
            NSArray *actions=[h tableView:t rowActionsForRow:n.integerValue edge:NSTableRowActionEdgeTrailing];
            for(NSTableViewRowAction *action in actions) action.handler(action,n.integerValue);
        }
    }
    for(NSNumber *n in @[@(-2),@(-1),@(0),@(999)]) {
        h.keyframeTableView.selectedRow=n.integerValue;
        [h copyNamedKeyframeToCurrentSequence:nil];
        [h playCurrentlySelectedKeyframeAnimation:nil];
    }
    assert(manager.saveCount==0 && h.motorCalls==0);
    puts("Torso keyframe tables passed: real Swift-array bridging, coherent sequence rows, stale/negative/empty selection, reusable cells and inert invalid actions; no UI or hardware");
} return 0; }
'''


def main():
    import re
    slider_names = sorted(set(re.findall(r"self\.(arm_(?:R11|L10)_[A-Za-z0-9_]+)\.doubleValue", actions)))
    sliders = "\n".join(f"@property(strong) Slider *{name};" for name in slider_names)
    harness = HARNESS.replace("__HELPER__", helper).replace("__TABLES__", tables)
    harness = harness.replace("__ACTIONS__", actions).replace("__SLIDERS__", sliders)
    with tempfile.TemporaryDirectory(prefix="rob-torso-keyframe-tables-") as directory:
        folder = Path(directory)
        (folder / "Models.swift").write_text(models)
        (folder / "Harness.m").write_text(harness)
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-emit-library", "-emit-objc-header",
                        "-emit-objc-header-path", str(folder / "FixtureModels-Swift.h"), "-module-name", "FixtureModels",
                        str(folder / "Models.swift"), "-o", str(folder / "libFixtureModels.dylib")], check=True)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-c", str(folder / "Harness.m"),
                        "-I", str(folder), "-o", str(folder / "Harness.o")], check=True)
        subprocess.run(["xcrun", "swiftc", str(folder / "Harness.o"), "-L", str(folder), "-lFixtureModels",
                        "-framework", "Foundation", "-lobjc", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                        "-o", str(folder / "test")], check=True)
        subprocess.run([str(folder / "test")], check=True, timeout=10)


if __name__ == "__main__":
    main()
