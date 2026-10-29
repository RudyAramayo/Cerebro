# Animation Studio

Open **Animation Studio…** at the bottom of Torso Servo Controls. Its three tables and the compact panel share the same library:

1. **Pose library** stores named, reusable joint/channel targets.
2. **Selected sequence** contains independent clips, in playback order.
3. **Sequences** selects the animation being edited.

Choose **New draft**, include the individual joints or groups you want, set values (or **Capture controls**), name the pose, and **Record new**. Capture reads the editable control targets; it is not a claim of measured arrival. **Update selected** edits exactly the identified library pose or sequence clip shown above the inspector. Unsaved edits are retained until saved or discarded. Duplicate names are allowed: UUIDs identify everything.

Select a library pose and a sequence, then **Add →**. Each insertion takes a value snapshot. Editing/deleting the source pose leaves existing clips intact. **Refresh from pose** deliberately replaces only the selected clip's values from its source. Clip timing is independent. Use ↑/↓, Duplicate, Remove, Transition, Hold and Smooth/Linear to arrange the timeline. The shaded tail of a block is its hold interval. Undo/Redo saves a new library revision.

## Channels and grasp-ready poses

- `arm.right.j1`…`j7`: physical RIGHT/L10, gateway `left`; **vendor radians**. `arm.left.*`: physical LEFT/R11, gateway `right`. No implicit mirroring, encoder reset, or URDF conversion occurs in stored targets. These poses depend on the robot's existing startup datum.
- `maestro.0/1/2`: neck pan/lower/upper; targets in **quarter-microseconds**. Other available Maestro channels: **4, 5, 10–17**. Channel 3 has no assigned control; 6–9 remain exclusively managed by the Bubble runtime.
- `torso.heading`: degrees relative to the existing torso-to-base reference, positive ROB-left. The Torso Rotation window selects and supervises the hardware source, count calibration and pulse ceiling. Headings are circular, not a count of complete turns; debug mode chooses the equivalent heading near its tracked cable reference to unwind. Ghost interpolation uses that same reference when available.
- `lact.speed`: signed percentage, positive forward. This timed demand runs for the clip's transition + hold, then returns to zero. It is not a position or lean-angle measurement.

Missing channels are untouched by that pose. An arm trajectory fills omitted joints from its fresh measured hold; a later clip does not reset omitted joints to zero. The neck gateway retains its necessary coupled staging/compensation.

The role menu assigns a taught library pose to `grasp.horizontal.right`, `grasp.vertical.right`, `grasp.horizontal.left`, or `grasp.vertical.left`. Only one pose owns each role. Values must be taught or edited; no vertical posture is guessed. `graspReadyValues(physicalSide:vertical:)` exposes a read-only sparse lookup to native mission consumers. This release stores the profiles; it does not replace the recycling planner's measured path admission.

## Ghost output and robot playback

**Ghost output**, **Preview sequence**, and timeline scrubbing are nonactuating. The existing diagnostic ghost window shows both arms, neck and torso. Its mappings are display priors; the original mesh/depth evidence stays separate. Unmapped Maestro channels and LACT remain timeline tracks rather than invented 3D joint calibration. Choose a ghost preset to return to that window's original gesture editor.

**Run on robot** is a direct local panel command covering the saved sequence. It takes over automatic owners once, enters position mode for included arms, and stops on manual takeover, Stop, close, sleep, connection change, stale feedback, rejected/late acknowledgement or current-limit trip. Arm segments use the gateway lease, existing joint bounds and 0.20 rad/s transport admission; timing must accommodate the selected easing and measured start. Torso turns retain both-arm clearance and the existing TIC/camera supervision. No additional voice authorization is requested.

The timeline describes nominal command timing. Amber arrival is checked from advancing feedback; torso arrival uses the selected controller source. Neck safety staging, servo ramps and physical settling can extend a clip before the next begins. Maestro has command estimates rather than shaft feedback. LACT stops at its requested clip duration even if another channel is still settling. Stop holds issued targets and discards pending neck staging; it does not promise an instantaneous mechanical stop.

## Shared human/LLM JSON edits

The canonical file is `~/Documents/ROB Animations/library.json` (`schemaVersion: 1`). The application is the single writer. Each successful change increments `revision`, writes atomically and keeps `library.json.previous`. Existing files in `~/Documents/ROB KeyframeAnimations` remain unchanged. Migration imports their saved poses/sequences once and marks the ambiguous legacy unit conversions for review. Review and Update selected confirms an imported pose or clip; updating a library pose does not implicitly confirm its old clip snapshots.

```sh
python3 Scripts/rob-animation.py export /tmp/animation-edit.json
# Edit this exported copy, preserving document ID/revision and existing UUIDs.
python3 Scripts/rob-animation.py apply /tmp/animation-edit.json
```

Create new UUIDs for new poses, sequences, clips **and each clip's embedded pose**. A clip contains `id`, optional `sourcePoseID`, `pose`, `transition`, `hold`, and `easing` (`smooth` or `linear`). A pose contains `id`, `name`, sparse `values`, optional `role`, `note`, and `needsReview`. Body tracks use the units above. Unknown/reserved channels, invalid IDs, ranges, duplicate roles and invalid timing are rejected.

The CLI writes a request into `inbox/`; the running controller validates and applies it on the same serialized path as UI edits. The `.result` file records acceptance/conflict and the actual resulting revision. Stale revisions reject the complete edit; re-export and merge by UUID. A timeout means pending, not saved. Import JSON edit uses the same identity/revision check. Neither path can execute a sequence. Unsaved UI drafts survive incoming edits, and a stale draft cannot overwrite the newer library.

## Basic gesture pack

`Animations/basic-gestures.json` contains five sequences and their reusable poses:

- **Hands Folded Up:** raise both hands, bring them inward and hold in front of the chest.
- **Wave · Right Hand:** raise, wave three times and return to the raised ready pose.
- **Handshake · Right Hand:** offer the hand, make three small vertical gestures and withdraw. This is a mime; it does not sense contact or close the jaws.
- **Kung Fu · Guard and Flow:** salute, alternate outward blocks and palm presses, then return.
- **Sword Form · Right Hand · 60 cm:** salute, high guards, two diagonal sweeps, blade presentation and recovery. The left hand remains raised away from the blade path; jaw settings are unchanged.

Install without replacing existing animations:

```sh
python3 Scripts/rob-animation.py add-pack Animations/basic-gestures.json
```

Repeated installation preserves existing edits by stable ID. The app still validates the whole merged document and its revision before saving. All five sequences contain arm tracks only. Clip timings use smooth easing and a nominal peak below 0.20 rad/s; the 18-second first clip is sized from hanging coordinates, and native playback checks the actual measured start. Each pose can be edited independently in the studio. The targets were authored with the bundled model's FK and each arm's own vendor-coordinate mapping; they are model-derived gestures, not physically commissioned motions.

An optional pose field, `previewProp: {"kind":"sword", "arm":"right", "lengthMeters":0.6}`, draws a reference sword along the tool's +Z axis. It follows the ghost hand while scrubbing, survives pose/clip copies and JSON edits, and disappears for poses without the field. This is display geometry, not a measured grip transform, jaw command or payload-clearance model. Other values remain unchanged.

## Verification

`Scripts/test-animation-studio.sh` runs the production model, native table/editor, and playback coordinator with inert hardware. It covers aliasing, duplicate names, row-selection errors, sparse tracks, timeline intervals, migrations, atomic revision conflicts, acknowledgements, Stop/takeover and reconnects. `Tests/ROBNeckOutputRuntimeTests.py` exercises the real Maestro gateway with recorded bytes; torso/gateway/ghost regression suites retain their hardware isolation. Physical multi-channel playback still needs commissioning on ROB; no robot movement is part of editor verification.
