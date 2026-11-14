# Fixed-view visual grasp evidence

`ROBVisualGraspVerifier` compares the same can's image and aligned depth before
closing with its motion after a small, separately reviewed lift. It runs locally
without an LLM and never sends motor, jaw or neck commands. The result is
**supported**, **failed**, or **unknown**; it does not claim a measured payload,
jaw position, contact force or guaranteed retention.

The executor captures the baseline while the detected can wall is visible, the
head is held at its registered pose and measured tool feedback is synchronized
with the image. It includes the lift and potential payload in its reviewed path.
After that lift, it holds and supplies three fresh advancing RGB-D samples. Each
sample includes the tool center and optical depth projected from **measured**
arm feedback in the registered camera frame. A commanded endpoint is not a
measurement and cannot supply this input.

`ROBRecyclingVisualInspection.begin` first reacquires a unique detector box in
the fixed registered view. Slow detector output supplies appearance only: its
texture and static background must match a new synchronized image before the
new image becomes the baseline. The old image keeps its original timestamp.
Fresh registered can sections must remain within 12 mm of the reviewed target;
a moved or occluded target stops before closing. This does not blindly chase a
moving can or reuse the old target coordinates.

The verifier tracks a distinctive central can-wall patch with normalized image
correlation and rejects ambiguous matches. Spatially separated textured
background patches must remain still and retain their depth. The can's image
displacement and depth change must agree with the measured tool motion in three
observations. Changes to head/registration identity, camera generation, target
identity, visibility, background, exposure or synchronization yield unknown.
A clearly visible can that remains on the table or moves independently of the
tool yields failed after repeated observations. Lost visibility never means
that the can was picked up.

The inspection is bounded to 12 seconds. At least 6 image pixels or 20 mm of
optical-depth movement is required to distinguish lift from stationary contact;
maximum accepted movement is 42 pixels and 120 mm in optical depth. These are
evidence bounds, not permission to perform that motion. The planner and executor
retain responsibility for the smaller physical test, complete geometry, current
feedback, ownership, authorization and immediate Stop.

`ROBArmRoutineVision.visualGraspSample` supplies lightweight raw RGB-D samples
without rerunning the object detector or moving the camera. A fresh detector
box must establish the baseline target; the tracker does not classify arbitrary
pixels as a can. `makeVisualGraspSample(frame:...)` can convert the exact frame
used by the detector. Its pixels and depth share top-left image coordinates;
optical depth is not modified by a visualization correction.

The executor records the verifier's numeric evidence, including frame and
camera identities, target ROI, correlation, uniqueness and target/tool motion
residuals. A non-supported result keeps the arm held for review; it cannot
automatically release a potentially held can, blindly retry or recalibrate a
camera transform. Corrections require a new measured correspondence or reviewed
test. Only a supported result permits the already-reviewed carry phase.

Run `Scripts/test-visual-grasp-verifier.sh` for coherent lift, stationary and
independently moving can, camera/background/exposure shifts, occlusion,
two-can ambiguity, missing depth, synchronization, identity and expiry fixtures.
