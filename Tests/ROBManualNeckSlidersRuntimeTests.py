#!/usr/bin/env python3
"""Run actual manual neck actions with inert controls and a command recorder.

No AppKit window, transport, preferences, or robot service is opened.
"""
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import re
import subprocess
import tempfile
from ROBNeckSafetyStaticTests import objective_c_method
ROOT=Path(__file__).resolve().parents[1]
torso=(ROOT/'Cerebro/ROBTorsoControlsViewController.m').read_text()
serial=(ROOT/'Cerebro/ROBSerialBox.m').read_text()
selectors=['synchronizeUneditedNeckSlidersForControl:','applyServoCommand:','renderServoCommands','renderServoCommandsOperatorInitiated:']
methods=[objective_c_method(torso,s)for s in selectors]
getter=objective_c_method(serial,'upperNeckOperatorDemandTarget')
action=methods[1]
assert action.index('synchronizeUneditedNeckSlidersForControl:slider')<action.index('BOOL allNeckAxesEnabled')
assert 'torso_controllerPassthrough_head_pan:' in methods[-1]
assert 'allowSupervisedLowerRecovery:lowerTiltOperatorInitiated' in objective_c_method(serial,'torso_controllerPassthrough_head_pan:')
controls=sorted(set(re.findall(r'self\.(\w+)\.(?:state|integerValue|doubleValue|floatValue)', '\n'.join(methods))))
controls=[n for n in controls if n not in ['robMainViewController']]
props='\n'.join('@property(strong) NSControl *'+n+';'for n in controls)
render=objective_c_method(serial,'torso_controllerPassthrough_head_pan:')
renderSignature=render[:render.index('{')].strip()
recordingBody='''{ self.sent=@[@(head_pan.integerValue),@(head_tilt.integerValue),@(head_upperNeckTilt.integerValue)];self.operatorSent=operatorInitiated;self.lowerOperatorSent=lowerTiltOperatorInitiated;self.commandCount+=1; }'''
harness=r'''
#import <Foundation/Foundation.h>
#import "ROBNeckSafetyPolicy.h"
#include <assert.h>
#ifndef IBAction
#define IBAction void
#endif
static NSInteger const NSControlStateValueOn=1,NSControlStateValueOff=0;
static int beeps=0;
static void NSBeep(void){beeps++;}
typedef NS_ENUM(NSInteger,ROBNeckCommandDisposition){ROBNeckCommandDispositionRejected,ROBNeckCommandDispositionAppliedCommand,ROBNeckCommandDispositionHeldForSafety};
@interface NSControl:NSObject
@property double doubleValue;
@property NSInteger state;
@property NSInteger integerValue;
@property float floatValue;
@end
@implementation NSControl
- (NSInteger)integerValue{return lround(self.doubleValue);}
- (void)setIntegerValue:(NSInteger)v{self.doubleValue=v;}
- (float)floatValue{return (float)self.doubleValue;}
- (void)setFloatValue:(float)v{self.doubleValue=v;}
@end
@interface NSButton:NSControl @end
@implementation NSButton @end
@interface ROBBubbleRuntime:NSObject
+ (instancetype)shared;
- (void)releaseMount;
- (void)manualPan:(NSInteger)pan tilt:(NSInteger)tilt;
- (void)legacyMotorControlWithFan:(BOOL)fan on:(BOOL)on;
@end
@implementation ROBBubbleRuntime
+ (instancetype)shared{static ROBBubbleRuntime*x;if(!x)x=[self new];return x;}
- (void)releaseMount{}
- (void)manualPan:(NSInteger)p tilt:(NSInteger)t{}
- (void)legacyMotorControlWithFan:(BOOL)f on:(BOOL)o{}
@end
@interface ROBSerialBox:NSObject
@property BOOL upperNeckTiltCommandKnown,lowerNeckTiltCommandKnown,neckPanCommandKnown;
@property(getter=isSafeNeckStartupInProgress) BOOL safeNeckStartupInProgress;
@property BOOL neckCommandStateKnown,lastDesiredUpperNeckTargetIsKnown;
@property NSInteger commandedNeckPanTarget,commandedLowerNeckTiltTarget,commandedUpperNeckTiltTarget;
@property int lastDesiredUpperNeckTarget;
@property(readonly)NSNumber*upperNeckOperatorDemandTarget;
@property(strong)NSArray<NSNumber*>*sent;
@property NSInteger commandCount,startups,cancels;
@property BOOL operatorSent,lowerOperatorSent;
- (ROBNeckSafetyConfig)neckSafetyConfiguration;
- (ROBNeckCommandDisposition)startSafeNeckStartup;
- (void)cancelSafeNeckStartup;
__RENDER_DECL__;
@end
@implementation ROBSerialBox
__GETTER__
- (ROBNeckSafetyConfig)neckSafetyConfiguration{return ROBNeckSafetyDefaultConfig();}
- (ROBNeckCommandDisposition)startSafeNeckStartup{self.startups++;self.safeNeckStartupInProgress=YES;return ROBNeckCommandDispositionAppliedCommand;}
- (void)cancelSafeNeckStartup{self.cancels++;self.safeNeckStartupInProgress=NO;}
__RENDER_RECORDER__
@end
@interface ROBMainViewController:NSObject
@property(strong)ROBSerialBox*serialBox;
@end
@implementation ROBMainViewController @end
@interface Harness:NSObject
@property(strong)ROBMainViewController*robMainViewController;
@property BOOL pendingNeckOperatorCommandAfterStartup,pendingLowerTiltOperatorCommandAfterStartup;
@property NSInteger refreshCount;
__PROPS__
__DECLS__
- (void)refreshNeckCommandReadouts;
@end
@implementation Harness
__METHODS__
- (void)refreshNeckCommandReadouts{self.refreshCount++;}
@end
static Harness* active(void){
 Harness*h=[Harness new];h.robMainViewController=[ROBMainViewController new];ROBSerialBox*b=[ROBSerialBox new];h.robMainViewController.serialBox=b;
 b.neckCommandStateKnown=YES;b.neckPanCommandKnown=YES;b.lowerNeckTiltCommandKnown=YES;b.upperNeckTiltCommandKnown=YES;
 b.commandedNeckPanTarget=6000;b.commandedLowerNeckTiltTarget=6411;b.commandedUpperNeckTiltTarget=5650;b.lastDesiredUpperNeckTarget=5650;b.lastDesiredUpperNeckTargetIsKnown=YES;
 h.headPan=[NSControl new];h.headTilt=[NSControl new];h.headUpperNeckTilt=[NSControl new];
 h.headPan.integerValue=6000;h.headTilt.integerValue=6011;h.headUpperNeckTilt.integerValue=5300;
 h.headPan_enabled=[NSControl new];h.headTilt_enabled=[NSControl new];h.headUpperNeckTilt_enabled=[NSControl new];
 h.headPan_enabled.state=1;h.headTilt_enabled.state=1;h.headUpperNeckTilt_enabled.state=1;return h;
}
static void expect(ROBSerialBox*b,NSInteger p,NSInteger l,NSInteger u){assert(([b.sent isEqual:@[@(p),@(l),@(u)]]));assert(b.operatorSent);}
int main(void){@autoreleasepool{
 Harness*h=active();ROBSerialBox*b=h.robMainViewController.serialBox;
 h.headPan.integerValue=6450;[h applyServoCommand:h.headPan];expect(b,6450,6411,5650);assert(h.headPan.integerValue==6450 && h.headTilt.integerValue==6411 && h.headUpperNeckTilt.integerValue==5650);
 // Another automatic update between manual events must supersede stale peers.
 b.commandedNeckPanTarget=6600;b.commandedLowerNeckTiltTarget=6461;b.commandedUpperNeckTiltTarget=5900;b.lastDesiredUpperNeckTarget=5900;
 h.headUpperNeckTilt.integerValue=5750;[h applyServoCommand:h.headUpperNeckTilt];expect(b,6600,6461,5750);
 // Applied6400 includes400units of lower compensation. Feed the original6000
 // demand once, never6400 through the same compensation again.
 h=active();b=h.robMainViewController.serialBox;b.commandedUpperNeckTiltTarget=6400;b.lastDesiredUpperNeckTarget=6000;
 h.headTilt.integerValue=6461;[h applyServoCommand:h.headTilt];expect(b,6000,6461,6000);assert(b.commandedUpperNeckTiltTarget==6400 && b.lastDesiredUpperNeckTarget==6000);
 // Checkbox actions preserve the edited axis's enabled/OFF semantics.
 h=active();b=h.robMainViewController.serialBox;h.headPan_enabled.state=0;[h applyServoCommand:h.headPan_enabled];expect(b,0,6411,5650);
 // Stale enabled checkboxes must never revive an untouched OFF/unknown
 // lower or upper axis when the operator edits only pan.
 for(int unknown=0;unknown<2;unknown++)for(int axis=0;axis<2;axis++){
  h=active();b=h.robMainViewController.serialBox;h.headPan.integerValue=6450;
  if(axis==0){b.lowerNeckTiltCommandKnown=!unknown;if(!unknown)b.commandedLowerNeckTiltTarget=0;}
  else{b.upperNeckTiltCommandKnown=!unknown;if(!unknown)b.commandedUpperNeckTiltTarget=0;}
  b.neckCommandStateKnown=!unknown;
  [h applyServoCommand:h.headPan];assert(b.commandCount==0);
  assert(b.startups==0 && !b.safeNeckStartupInProgress);
  assert((axis==0?h.headTilt_enabled:h.headUpperNeckTilt_enabled).state==NSControlStateValueOff);
 }
 // The same rule protects an untouched pan axis when upper is edited.
 h=active();b=h.robMainViewController.serialBox;b.neckPanCommandKnown=NO;b.neckCommandStateKnown=NO;h.headUpperNeckTilt.integerValue=5800;
 [h applyServoCommand:h.headUpperNeckTilt];assert(b.commandCount==0 && b.startups==0 && h.headPan_enabled.state==NSControlStateValueOff);
 h=active();b=h.robMainViewController.serialBox;b.commandedNeckPanTarget=0;h.headUpperNeckTilt.integerValue=5800;[h applyServoCommand:h.headUpperNeckTilt];assert(b.commandCount==0 && b.startups==0 && h.headPan_enabled.state==NSControlStateValueOff);
 // An explicit disable toggle still reaches its original coupled shutdown.
 h=active();b=h.robMainViewController.serialBox;b.neckPanCommandKnown=NO;b.neckCommandStateKnown=NO;h.headTilt_enabled.state=NSControlStateValueOff;
 [h applyServoCommand:h.headTilt_enabled];expect(b,0,0,0);assert(b.startups==0);
 // A deliberate enable-checkbox ON still requests the original coupled safe
 // startup, even when another untouched axis is OFF.
 h=active();b=h.robMainViewController.serialBox;b.commandedLowerNeckTiltTarget=0;b.commandedUpperNeckTiltTarget=0;h.headTilt_enabled.state=NSControlStateValueOn;
 [h applyServoCommand:h.headTilt_enabled];assert(b.startups==1 && b.commandCount==0 && b.safeNeckStartupInProgress);
 assert(h.headPan_enabled.state==1 && h.headTilt_enabled.state==1 && h.headUpperNeckTilt_enabled.state==1);
 // A missing current demand is never replaced by an old slider value.
 h=active();b=h.robMainViewController.serialBox;b.lastDesiredUpperNeckTargetIsKnown=NO;h.headPan.integerValue=6450;int priorBeeps=beeps;[h applyServoCommand:h.headPan];assert(b.commandCount==0 && beeps==priorBeeps+1 && b.upperNeckOperatorDemandTarget==nil);
 // Session invalidation/OFF must not expose stale upper metadata.
 b.lastDesiredUpperNeckTargetIsKnown=YES;b.upperNeckTiltCommandKnown=NO;assert(b.upperNeckOperatorDemandTarget==nil);b.upperNeckTiltCommandKnown=YES;b.commandedUpperNeckTiltTarget=0;assert(b.upperNeckOperatorDemandTarget==nil);
 // Startup queues retain the user's complete requested pose, not temporary
 // applied clearance targets. Only its original timer path replays it.
 h=active();b=h.robMainViewController.serialBox;b.safeNeckStartupInProgress=YES;h.headPan.integerValue=6500;h.headTilt.integerValue=6300;h.headUpperNeckTilt.integerValue=5700;
 [h applyServoCommand:h.headPan];assert(h.pendingNeckOperatorCommandAfterStartup && b.commandCount==0);assert(h.headTilt.integerValue==6300 && h.headUpperNeckTilt.integerValue==5700);
 b.safeNeckStartupInProgress=NO;[h renderServoCommands];expect(b,6500,6300,5700);assert(!h.pendingNeckOperatorCommandAfterStartup);
 h=active();b=h.robMainViewController.serialBox;h.pendingNeckOperatorCommandAfterStartup=YES;h.headTilt.integerValue=6350;h.headUpperNeckTilt.integerValue=5800;h.headPan.integerValue=6550;[h applyServoCommand:h.headPan];expect(b,6550,6350,5800);
 // Passive rendering and non-neck actions do not become manual axis edits.
 h=active();b=h.robMainViewController.serialBox;[h renderServoCommands];assert(!b.operatorSent && h.headTilt.integerValue==6011 && h.headUpperNeckTilt.integerValue==5300);
 puts("PASS actual manual neck actions: untouched axes follow latest applied targets, upper compensation once, edited drag preserved, startup queue preserved, untouched OFF/unknown axes stay disabled, explicit enable recovery preserved, passive authority unchanged; no GUI or hardware");
}}
'''
replacements={'RENDER_DECL':renderSignature,'RENDER_RECORDER':renderSignature+'\n'+recordingBody,'GETTER':getter,'PROPS':props,'DECLS':'\n'.join(m[:m.index('{')].strip()+';'for m in methods),'METHODS':'\n'.join(methods)}
for key,value in replacements.items():harness=harness.replace('__'+key+'__',value)
with tempfile.TemporaryDirectory(prefix='rob-manual-neck-',dir='/private/tmp')as folder:
 path=Path(folder);source=path/'Fixture.m';binary=path/'Fixture';source.write_text(harness)
 subprocess.run(['clang','-O2','-fobjc-arc','-framework','Foundation','-I',str(ROOT/'Cerebro'),str(source),str(ROOT/'Cerebro/ROBNeckSafetyPolicy.c'),'-o',str(binary)],check=True,timeout=45)
 subprocess.run([str(binary)],check=True,timeout=10)
