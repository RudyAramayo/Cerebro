#!/usr/bin/env python3
"""Build the reviewed, fillable Amber takeover/backup plan. No robot/network I/O."""
import argparse
import hashlib
import json
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.pdfgen import canvas
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import Paragraph

W, H, M = 612, 792, 42
CW = W - 2 * M
NAVY = colors.HexColor('#153247')
INK = colors.HexColor('#294455')
TEAL = colors.HexColor('#087F8C')
GREEN = colors.HexColor('#287A60')
AMBER = colors.HexColor('#A96412')
RED = colors.HexColor('#A4483D')
MUTED = colors.HexColor('#637583')
LINE = colors.HexColor('#D6E0E5')
PALE = colors.HexColor('#EFF5F6')
WARM = colors.HexColor('#FBF3E6')
BG = colors.HexColor('#F9FBFC')
WHITE = colors.white

STYLES = {
    'body': ParagraphStyle('body', fontName='Helvetica', fontSize=10.2, leading=14.1, textColor=INK),
    'small': ParagraphStyle('small', fontName='Helvetica', fontSize=8.8, leading=11.8, textColor=MUTED),
    'tiny': ParagraphStyle('tiny', fontName='Helvetica', fontSize=7.8, leading=10.1, textColor=MUTED),
    'label': ParagraphStyle('label', fontName='Helvetica-Bold', fontSize=10.5, leading=13.3, textColor=NAVY),
    'white': ParagraphStyle('white', fontName='Helvetica', fontSize=10.4, leading=14.5, textColor=WHITE),
    'mono': ParagraphStyle('mono', fontName='Courier', fontSize=8.1, leading=11, textColor=INK),
}
SOURCES = {
    'S1': ('Controller validation and handoff', 'https://github.com/RudyAramayo/Cerebro/blob/c1a0cd508f6759f9da5b08e10a30d5a98f1e0969/docs/calibration/amber-overnight-preparation-2026-11-03.md'),
    'S2': ('Legacy recovery / startup inhibit', 'https://github.com/RudyAramayo/Amber-HomeFolder/blob/7c3b2449936a017c5f7049f6d562764a9fdb3f94/docs/amber-stack-recovery.md'),
    'S3': ('Linux SocketCAN: multiple senders', 'https://docs.kernel.org/networking/can.html'),
    'S4': ('Linux network namespace lifetime', 'https://man7.org/linux/man-pages/man7/network_namespaces.7.html'),
    'S5': ('Clonezilla: LVM2, UEFI and offline imaging', 'https://clonezilla.org/'),
    'S6': ('Clonezilla: save a whole-disk image', 'https://clonezilla.org/show-live-doc-content.php?topic=clonezilla-live/doc/01_Save_disk_image'),
    'S7': ('Clonezilla: restore an image to a disk', 'https://clonezilla.org/show-live-doc-content.php?topic=clonezilla-live/doc/02_Restore_disk_image'),
    'S8': ('CANable2 advertised source: flashed image unverified', 'https://github.com/normaldotcom/canable2-fw/blob/b158aa7ab106bc018715cd4d5f02f544f9de1830/src/can.c'),
}


def ref(key):
    return f'<link href="{escape(SOURCES[key][1], {chr(34): "&quot;"})}" color="#087F8C">[{key}]</link>'


class Plan:
    def __init__(self, output, backup, startup, storage):
        self.c = canvas.Canvas(str(output), pagesize=(W, H), pageCompression=1)
        self.c.setTitle('Amber CAN takeover and recovery plan - 2026-11-04')
        self.c.setAuthor('ROB engineering / Codex')
        self.c.setSubject('Traceable takeover steps, whole-disk backup, rollback and fillable execution log')
        self.backup, self.startup, self.storage = backup, startup, storage
        self.fields = []
        self.page = 0
        self.bounds = []

    def para(self, text, x, top, width, style='body', bottom=52):
        p = Paragraph(text, STYLES[style])
        _, h = p.wrap(width, H)
        if top - h < bottom:
            raise ValueError(f'Page {self.page}: text exceeds its area: {text[:60]}')
        p.drawOn(self.c, x, top - h)
        self.bounds.append({'page': self.page, 'x': x, 'top': top, 'width': width, 'height': h})
        return top - h

    def rect(self, x, top, width, height, fill=WHITE, stroke=LINE, radius=8):
        self.c.setFillColor(fill)
        self.c.setStrokeColor(stroke)
        self.c.setLineWidth(.7)
        self.c.roundRect(x, top-height, width, height, radius, fill=1, stroke=1)

    def label(self, text, x, y, size=10, color=NAVY, font='Helvetica-Bold'):
        self.c.setFillColor(color)
        self.c.setFont(font, size)
        self.c.drawString(x, y, text)

    def badge(self, text, x, top, color=TEAL):
        width = self.c.stringWidth(text, 'Helvetica-Bold', 8) + 16
        self.rect(x, top, width, 19, fill=color, stroke=color, radius=5)
        self.label(text, x+8, top-13, size=8, color=WHITE)

    def start(self, section, title, subtitle):
        self.page += 1
        c = self.c
        c.setFillColor(BG); c.rect(0, 0, W, H, fill=1, stroke=0)
        c.setFillColor(TEAL); c.rect(0, H-8, W, 8, fill=1, stroke=0)
        self.label('ROB  /  AMBER ENGINEERING', M, 757, 9, TEAL)
        c.setFont('Helvetica', 8); c.setFillColor(MUTED)
        c.drawRightString(W-M, 757, '04 NOV 2026  |  REV 1')
        self.label(section.upper(), M, 730, 8.4, MUTED)
        self.label(title, M, 701, 25)
        self.para(subtitle, M, 684, CW, 'small')
        c.setStrokeColor(LINE); c.line(M, 47, W-M, 47)
        self.label('Controlled change plan  |  Physical output remains disabled in the candidate', M, 31, 7.5, MUTED, 'Helvetica')
        c.drawRightString(W-M, 31, f'{self.page} / 8')

    def end(self):
        self.c.showPage()

    def section(self, title, y):
        self.label(title, M, y, 12)

    def card(self, x, top, width, height, title, body, fill=WHITE, style='body'):
        self.rect(x, top, width, height, fill=fill)
        self.label(title, x+14, top-23, 11)
        self.para(body, x+14, top-36, width-28, style, bottom=top-height+10)

    def page_overview(self):
        self.start('01 / Readiness and scope', 'Amber CAN takeover', 'A recovery-first plan for one persistent controller and safe, traceable target switching.')
        self.rect(M, 650, CW, 83, NAVY, NAVY)
        self.label('READY TO BEGIN: BACKUP + READ-ONLY PREPARATION', M+16, 626, 10.3, WHITE)
        self.para('The candidate is staged and tested. Privileged takeover, physical transmission, adapter reset and motor-stop commissioning remain unfinished. Preparation can begin; robot testing remains paused.', M+16, 612, CW-32, 'white', bottom=573)

        phases = [('A', 'Evidence', 'VERIFIED', GREEN), ('B', 'Full disk backup', 'PENDING', AMBER),
                  ('C', 'CAN handoff', 'PENDING', AMBER), ('D', 'Gentle raise', 'HOLD', MUTED),
                  ('E', 'Target switching', 'HOLD', MUTED)]
        for i, (code, title, status, color) in enumerate(phases):
            x=M+i*107
            self.rect(x, 548, 100, 72, WHITE)
            self.label(code, x+10, 530, 10, TEAL)
            self.label(title, x+10, 511, 8.7)
            self.label(status, x+10, 492, 7.6, color)
            if i<4:
                self.c.setStrokeColor(LINE);self.c.line(x+101,512,x+106,512)

        self.card(M, 454, 256, 136, 'Verified evidence',
                  '84 Linux checks pass in Release and ASan/UBSan. 58 portable C++ groups pass TSan. Five inert rehearsals pass on Amber with zero network syscalls. Recovery/startup code passes 27 offline tests. '+ref('S1'), fill=PALE)
        self.card(M+272, 454, 256, 136, 'Still required',
                  'A full disk image and spare-disk restore test; a completed privileged handoff; verified physical CAN isolation; fresh joint/mode feedback; measured stopping, limits and actual sweep clearance.', fill=WARM)

        self.section('Protect the original machine', 291)
        self.para('<b>Preferred route:</b> image the original SSD, restore to a compatible spare, prove that spare boots with CAN disconnected, then develop on the clone. Store the original SSD disconnected and labelled as the recovery baseline.', M, 278, CW)
        self.card(M, 215, 256, 112, 'Changes planned later',
                  'Protected startup/recovery guards, service launch state, CAN namespace placement and one new controller service. Capture each prior state before changing it.', style='small')
        self.card(M+272, 215, 256, 112, 'Preserve throughout',
                  'Vendor executables and libraries, OS packages, URDF assets, adapter/motor firmware, encoder zeros and motor calibration. No in-place binary patching is planned.', style='small')
        self.para('Current intent: gentle arm raise first, then finite mid-motion retargets. A completed head mount is not required for the arm-only test. Face pointing and VR follow separate camera/mapping validation.', M, 88, CW, 'small')
        self.end()

    def page_backup(self):
        self.start('02 / Backup coverage', 'What we can recover today', 'Fresh read-only storage inventory and archive verification on November 4. No disk or boot configuration changed.')
        self.card(M, 650, CW, 83, 'Original controller archive - VERIFIED',
                  f'{self.backup["files_verified"]} files match their recorded SHA-256 hashes; {self.backup["archive_bytes"]:,} bytes. Contains both vendor cores, 42 mapped libraries, two launch files, gateway code and rc.local. This is a file-level recovery resource.', fill=PALE)
        self.card(M, 553, CW, 90, 'Startup/recovery baseline - PARTIAL',
                  'Seven files were saved with hashes, permissions and owner/group IDs. The protected sudoers file was unreadable. Privileged-file and full service-state coverage remain incomplete.', fill=WARM)

        self.section('The whole boot disk must be covered', 442)
        self.rect(M, 426, CW, 132)
        self.label('HOGE SSD 64GB   /dev/sda   64,023,257,088 bytes', M+14, 405, 11)
        self.label('UEFI boot observed. Device names must be rechecked in the recovery environment.', M+14, 387, 8.5, MUTED, 'Helvetica')
        for i, (title, detail) in enumerate([
            ('sda1  |  1.13 GB', 'FAT /boot/efi'),
            ('sda2  |  2.15 GB', 'ext4 /boot'),
            ('sda3  |  28.74 GB', 'LVM2 -> ext4 root')]):
            x=M+14+i*168
            self.rect(x, 370, 156, 57, PALE, PALE, 5)
            self.label(title, x+9, 350, 9.4)
            self.label(detail, x+9, 332, 8.2, MUTED, 'Helvetica')
        self.para('Partition boxes are not to scale. The whole-disk operation must include the partition table, EFI, /boot, LVM metadata and root filesystem. Copying /home alone cannot establish boot recovery. Record UEFI settings/boot entries separately.', M, 280, CW)

        self.section('Backup acceptance gates', 215)
        rows = [
            ('File integrity', 'PASS', '48 original payload files rechecked; 7 new startup files verified.'),
            ('Complete boot image', 'OPEN', 'Not yet captured or identified as a verified full-disk image.'),
            ('Independent second copy', 'OPEN', 'Different physical storage; a second folder on this Mac is insufficient.'),
            ('Restore + boot on spare', 'OPEN', 'No boot restore has been demonstrated.'),
        ]
        for i,(label,status,detail) in enumerate(rows):
            y=194-i*31
            self.label(label, M, y, 9.2)
            self.label(status, M+165, y, 8.5, GREEN if status=='PASS' else AMBER)
            self.para(detail, M+215, y+9, CW-215, 'tiny', bottom=60)
        self.para('The host image does not back up actuator EEPROM or prove mechanical recovery. Those remain separate; this takeover must not write firmware or encoder calibration.', M, 77, CW, 'small')
        self.end()

    def page_image(self):
        self.start('03 / B1-B4 backup procedure', 'Prove recovery on a spare', 'Recommended protective sequence. Media and physical maintenance have not yet been selected or performed.')
        self.card(M, 650, CW, 85, 'Prepare the recovery kit',
                  'Checksum-verified Clonezilla Live media; image storage with at least 70 GB free (conservative uncompressed budget); compatible spare SSD of at least 64,023,257,088 bytes; local keyboard/display. A nominal 128 GB spare adds capacity margin. Check connector and form factor.', fill=PALE, style='small')
        steps = [
            ('B1', 'Identify source and destination',
             'Record model, exact capacity, serial/label and partition layout. Recheck after booting recovery media: /dev/sda may change. Never select a destination solely by its device name. The original disk is the source, never the restore-test target.'),
            ('B2', 'Capture an offline whole-disk image',
             'With arms supported, motor power disabled and CAN adapters disconnected, shut Ubuntu down cleanly and boot recovery media. Use device-image / savedisk to save the entire identified SSD to external storage. Keep source filesystems unmounted. '+ref('S5')+' '+ref('S6')),
            ('B3', 'Verify and duplicate the image',
             'Run the image integrity check, preserve the tool log and generate a checksum manifest for every image component. Copy to different physical storage and verify that copy. Full images contain credentials: keep them private, preferably encrypted, with the recovery key available offline.'),
            ('B4', 'Restore to the spare and prove boot',
             'Restore the image only to the identified spare SSD. Disconnect the original before the boot test; duplicate filesystem IDs can confuse boot selection. Keep CAN disconnected and motor power disabled. Confirm UEFI boot, root/boot mounts, expected files and read-only service state. '+ref('S7')),
        ]
        top=546
        for code,title,body in steps:
            self.rect(M, top, CW, 99)
            self.badge(code, M+12, top-12)
            self.label(title, M+55, top-25, 11)
            self.para(body, M+15, top-39, CW-30, 'small', bottom=top-92)
            top-=110
        self.rect(M, 99, CW, 40, NAVY, NAVY, 6)
        self.para('GO only after the spare boots and both image copies verify. Use the clone for takeover; keep the original disconnected.', M+12, 92, CW-24, 'white', bottom=62)
        self.end()

    def page_takeover(self):
        self.start('04 / T1-T5 controlled handoff', 'One owner, one fresh session', 'Planned privileged operations. The staged candidate cannot yet transmit to physical motors.')
        self.para('Opening a CAN socket or holding a lock file does not exclude other SocketCAN writers. The takeover combines process removal, restart inhibition, namespace isolation and fresh feedback. '+ref('S3')+' '+ref('S4'), M, 651, CW)
        steps = [
            ('T1', 'Establish the supported starting state',
             'Both arms supported and drives disabled; no active hold takeover. Coordinate all control sessions. Existing startup/recovery couples both arms, even for a RIGHT-only test.',
             'PASS: physical support and disabled state recorded. Otherwise stop here.'),
            ('T2', 'Exclude the legacy writers',
             'With root administration, hold the existing maintenance lock. Back up exact service state and protected files; install/verify guards, persist the inhibit, block legacy launches, then stop old cores and serial handlers.',
             'PASS: processes gone, guards effective, prior state recorded. Do not use recovery as a privilege shortcut.'),
            ('T3', 'Prove old traffic cannot survive',
             'Close old host queues. Establish a verified adapter MCU restart/power-cycle and reinitialization procedure while motors remain disabled. CAN close alone is not a proven queue flush. '+ref('S8'),
             'PASS: reset/queue behavior and transport age measured. Presently uncommissioned.'),
            ('T4', 'Isolate the physical CAN interface',
             'Move the intended bus into a pinned, root-managed network namespace. Admit only the driver; restrict serial access. Clients use private IPC. Confirm physical RIGHT = CAN10/L-10, LEFT = CAN11/R-11.',
             'PASS: correct physical adapter/arm identity and exclusion verified on real slcan, not only vcan.'),
            ('T5', 'Create a fresh controller generation',
             'Discard cached targets and telemetry. Collect new replies from all seven joints, using verified read-only queries if needed. Check mode, stationary history, limits and the whole sweep/stop reserve.',
             'PASS: new source epoch, bounded fresh feedback and explicit start grant. Missing evidence leaves TX disabled.'),
        ]
        top=594
        for code,title,body,gate in steps:
            self.rect(M,top,CW,96)
            self.badge(code,M+10,top-10)
            self.label(title,M+54,top-23,10.7)
            y=self.para(body,M+13,top-36,CW-26,'small',bottom=top-77)
            self.para('<b>'+gate+'</b>',M+13,y-5,CW-26,'tiny',bottom=top-91)
            top-=104
        self.para('Retargeting retains ownership. Crash/reconnect must not replay targets or revive the vendor core. The persistent inhibit is staged source, not installed protection. '+ref('S2'), M, 74, CW, 'tiny', bottom=52)
        self.end()

    def page_rollback(self):
        self.start('05 / Rollback and stop rules', 'Recover without improvising', 'A controller crash must not automatically reactivate the old controller or return CAN to unrestricted use.')
        rows=[
            ('Only staged files changed', 'Keep the original runtime untouched.',
             'Stop an inert rehearsal if needed. Retain logs. Remove only the task-owned staging directory after verifying its identity; original files need no restore.'),
            ('Handoff fails / feedback missing', 'Leave all motion output disabled.',
             'Retain the inhibit and namespace isolation. Do not retry buffered commands, clear a fault automatically or run the legacy recovery helper. Record the last verified state.'),
            ('Need to return to vendor control', 'Restore software before authorizing motion.',
             'With supported, disabled arms, stop the replacement and verify it cannot write. Resolve queued traffic. Restore only changed files and their original metadata, plus exact prior service state. Remove inhibits/masks only as part of a reviewed return; no automatic activation.'),
            ('Working clone fails to boot / SSH lost', 'Use local console and the preserved original.',
             'Motor power off and CAN disconnected first. Shut down, then use the original SSD or restore the verified image to a spare. Confirm boot and configuration with hardware disconnected before resuming control.'),
            ('Unexpected motion or loss of control', 'Use the independent shutdown switch.',
             'Prepare mechanical support before testing because torque loss can let an arm fall. Software Stop is useful when available, but bus/process failure may prevent it. End the run, preserve evidence and investigate; do not auto-restart.'),
        ]
        top=650
        for i,(title,action,body) in enumerate(rows):
            self.rect(M,top,CW,100, WARM if i==4 else WHITE)
            self.label(title,M+14,top-22,10.7,RED if i==4 else NAVY)
            self.para('<b>'+action+'</b> '+body,M+14,top-34,CW-28,'small',bottom=top-92)
            top-=112
        self.para('<b>Restore rehearsal matters:</b> matching checksums prove file integrity, not a successful boot or correct arm behavior. The original controller archive is not a substitute for the full disk image and spare-disk test.', M, 76, CW, 'small')
        self.end()

    def page_commissioning(self):
        self.start('06 / Before physical output', 'Prove the stop before the stream', 'These are outstanding hardware gates, not results. The current candidate has no physical transmit mode.')
        self.card(M,650,CW,100,'C0 / Record the actual limits and stopping envelope',
                  'Confirm each physical joint ID, sign, zero and mode against measured feedback. Establish position, velocity, acceleration, current and transport-age limits from verified hardware data and bounded commissioning. Check the entire arm sweep and stopping distance against the body, other arm, table and people. The absent head camera cannot certify clearance.',fill=PALE,style='small')
        self.card(M,536,CW,117,'Verify what happens when commands stop',
                  'With supported arms, first validate Stop and the independent cutoff. Then commission bounded loss-of-command, process failure and transport-loss cases with the operator present. Measure stop latency, travel, current, drive mode and gravity behavior. Record whether a drive-side timeout exists and what it does. The reported present-day motion freeze is not a measured independent watchdog. Choose timeouts and stop reserve from those observations.',fill=WARM,style='small')
        self.card(M,405,CW,101,'M1 / One gentle raise, followed by measured Stop',
                  'Rudy explicitly resumes testing. Select the joint, sign and small excursion from fresh measured posture; do not replay the synthetic five-degree test as a real pose. Use a reviewed low-speed, empty-arm path and immediate filming cue. Log timestamps, measured and commanded joint state, current/mode, owner generation and Stop outcome.',style='small')
        self.card(M,290,CW,101,'M2 / A finite set of mid-motion target changes',
                  'Only after M1 and stop gates pass, switch between two reviewed nearby poses while moving. The same persistent owner receives each latest target; it never launches a second worker. Record accepted/applied target sequences, timing, one owner/generation and bounded tracking. Stop on missing feedback, unexpected current, expired target or ownership loss.',style='small')
        self.rect(M,172,CW,105,NAVY,NAVY)
        self.label('Decision rule',M+14,149,11,WHITE)
        self.para('Any failed or unmeasured gate keeps physical streaming disabled. A hardware cutoff supports supervised commissioning; it does not establish an automatic motor watchdog. No unattended face tracking or VR control until stopping, mapping and tracking loss are validated.',M+14,135,CW-28,'white',bottom=76)
        self.end()

    def textfield(self, name, x, y, width, height, value='', multiline=False):
        self.fields.append(name)
        self.c.acroForm.textfield(name=name, tooltip=name.replace('_',' '), x=x,y=y,width=width,height=height,
            value=value, fontName='Helvetica',fontSize=9, textColor=INK, borderColor=LINE,fillColor=WHITE,
            borderWidth=.7,borderStyle='solid',forceBorder=True,fieldFlags='multiline' if multiline else '',maxlen=2000 if multiline else 100)

    def page_log(self):
        self.start('07 / Fillable execution record', 'Track each gate before advancing', 'All execution gates start Pending. Only observed evidence changes a gate to Pass; this sheet is not motor authorization.')
        self.label('Run ID',M,646,9)
        self.textfield('run_id',M,619,155,20)
        self.label('Date / operator',M+171,646,9)
        self.textfield('date_operator',M+171,619,202,20)
        self.label('Physical arm',M+390,646,9)
        self.textfield('physical_arm',M+390,619,138,20)
        self.label('Original SSD identity / image repository / working spare ID',M,601,9)
        self.textfield('disk_and_image_identity',M,570,CW,24)
        self.label('GATE',M,549,8.5,TEAL)
        self.label('RESULT',M+206,549,8.5,TEAL)
        self.label('TIME',M+281,549,8.5,TEAL)
        self.label('EVIDENCE / LOG REFERENCE',M+359,549,8.5,TEAL)
        rows=[('B1','Source/destination identified'),('B2','Full disk image verified'),('B3','Independent copy verified'),
              ('B4','Spare restored and booted'),('T1','Arms supported / disabled'),('T2','Legacy writers excluded'),
              ('T3','Adapter queues/reset proven'),('T4','Real CAN ownership proven'),('T5','Fresh state / new generation'),
              ('C0','Hardware stop / limits proven'),('M1','Gentle raise + measured Stop'),('M2','Mid-motion target switching')]
        for i,(code,label) in enumerate(rows):
            top=535-i*27
            if i%2==0:
                self.c.setFillColor(PALE);self.c.rect(M,top-24,CW,26,fill=1,stroke=0)
            self.label(code,M+5,top-13,9,TEAL)
            self.label(label,M+31,top-13,8.4,INK,'Helvetica')
            name=code.lower()+'_result';self.fields.append(name)
            self.c.acroForm.choice(name=name,tooltip=code+' result',x=M+206,y=top-19,width=65,height=21,
                value='Pending',options=['Pending','Pass','Fail','Hold'],fontName='Helvetica',fontSize=8.3,
                borderWidth=.7,borderColor=LINE,fillColor=WHITE,textColor=INK,forceBorder=True,fieldFlags='combo')
            self.textfield(code.lower()+'_time',M+281,top-19,68,21)
            self.textfield(code.lower()+'_evidence',M+359,top-19,169,21)
        self.label('Deviation / failure / rollback notes',M,200,9)
        self.textfield('notes',M,124,CW,67,multiline=True)
        self.para('<b>Motion cues:</b> after planning and clearance checks, say and send "Start filming now" with the specific action immediately before dispatch. If delayed, repeat the cue. Restore Messages access before relying on that delivery route.',M,108,CW,'small')
        self.end()

    def page_evidence(self):
        self.start('08 / Evidence and reference map', 'Know exactly what we are using', 'Hashes identify files; they do not certify physical behavior. Full private records remain outside Git.')
        self.label('Original controller archive',M,648,10)
        self.para(self.backup['archive_sha256'],M,637,CW,'mono')
        self.para('amber-host-controller-originals-20261102.tar.gz | 43,686,735 bytes | 48 files verified',M,621,CW,'tiny')
        self.label('New partial startup baseline',M,596,10)
        self.para(self.startup['archive_sha256'],M,585,CW,'mono')
        self.para('amber-startup-baseline-20261104.tar.gz | 7 files captured | live sudoers file not readable',M,569,CW,'tiny')
        self.label('Staged controller package',M,543,10)
        self.para('3628a1d4bc60aeacc40fb9fc3930ebb65419a019f3afe730c5734853fd9a909e',M,532,CW,'mono')
        self.para('Controller source d98ebd3 | /home/amber/rob-controller-staging/d98ebd3<br/>Ownership source 7c3b244 | /home/amber/rob-controller-staging/ownership-7c3b244-complete',M,516,CW,'small')
        self.section('Where the working evidence lives',469)
        self.para('Original backup: Documents/ROB Test Reports/2026-11-02/amber-backup<br/>New verification + startup baseline: Documents/ROB Test Reports/2026-11-04/amber-backup-review<br/>Controller tests/staging: Documents/ROB Test Reports/2026-11-03/amber-deployment',M,456,CW,'small')
        self.section('Primary sources and pinned project records',393)
        for i,(key,(title,url)) in enumerate(SOURCES.items()):
            self.para(f'<b>{key}</b> &nbsp; <link href="{escape(url, {chr(34): "&quot;"})}" color="#087F8C">{escape(title)}</link>',M,378-i*24,CW,'small')
        self.card(M,171,CW,106,'Operating boundary',
                  'Fresh storage/hash reads and backup verification were performed for this report. No reboot, disk imaging/restore, protected-file install, namespace move, adapter reset, mode change or motor command was performed. Physical testing requires Rudy to resume it. Head/camera work remains a separate track.',fill=PALE)
        self.end()

    def build(self):
        self.page_overview();self.page_backup();self.page_image();self.page_takeover()
        self.page_rollback();self.page_commissioning();self.page_log();self.page_evidence()
        self.c.save()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    backup=json.loads((args.evidence_dir/'backup-verification.json').read_text())
    startup=json.loads((args.evidence_dir/'startup-baseline-manifest.json').read_text())
    storage=json.loads((args.evidence_dir/'host-storage-inventory.json').read_text())
    disks=json.loads(storage['disks']['stdout'])['blockdevices']
    source=next(x for x in disks if x['name']=='sda' and x['type']=='disk')
    if source['size']!=64023257088 or source['model']!='HOGE SSD 64GB':
        raise SystemExit('Observed source disk changed; update the reviewed plan before building')
    if backup['files_verified']!=48 or sum('sha256' in x for x in startup['files'])!=7:
        raise SystemExit('Backup scope changed; update the reviewed plan')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    plan=Plan(args.output,backup,startup,storage)
    plan.build()
    manifest={'report_date':'2026-11-04','pages':plan.page,'fillable_fields':plan.fields,
        'pdf_sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),'pdf_bytes':args.output.stat().st_size,
        'generator_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'input_sha256':{name:hashlib.sha256((args.evidence_dir/name).read_bytes()).hexdigest()
            for name in ['backup-verification.json','startup-baseline-manifest.json','host-storage-inventory.json']},
        'physical_actions_performed':False,'full_disk_image_created':False,'restore_test_performed':False}
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest))


if __name__=='__main__':
    main()
