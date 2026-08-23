# Local face identity

Cerebro can enroll consenting people from its main camera and expose a recently
recognized name to the local conversation context. Open **People → People &
Face Enrollment…** to manage the gallery. Recognition runs from the headless
main-camera service; the camera diagnostics window does not need to be open.

## Enrollment

Enter the person's name, optional pronunciation, and role. Confirm consent and
press **Start Enrollment**. Cerebro accepts one face at a time, rejects small or
low-quality captures, rejects near-duplicate samples, and prompts for varied
head positions. Enrollment completes after 24 accepted samples. Cancelling an
incomplete enrollment deletes its partial profile and samples.

Administrator enrollment additionally requires a paired, non-revoked operator
ROBController and a local confirmation dialog. The controller device ID is
recorded as the enrollment reference. `administrator` is deliberately only an
identity and personalization label. It is not accepted as authorization for
treads, arms, pairing, shell commands, secrets, purchases, or safety overrides;
those operations retain their existing cryptographic controller and local
confirmation requirements.

## Recognition

The current backend detects faces and landmarks with Vision, filters captures
with Vision face quality, crops the face, and generates a versioned Vision
feature print. It performs open-set nearest-sample matching across all retained
examples. A match must pass an absolute distance threshold, beat the runner-up
by a configurable margin, and remain the best candidate for three analyzed
frames. Otherwise the person remains unknown.

`ROBFaceIdentity.maximumDistance` and `ROBFaceIdentity.minimumMargin` are
developer calibration defaults, initially 8.5 and 1.0. They must be calibrated
with separate enrollment and validation footage from ROB's actual camera before
recognition is treated as reliable. Names enter scene context for only 15
seconds and camera-derived identity remains untrusted sensor data.

The gallery records its backend identifier. This provides the migration seam
for a properly licensed MobileFaceNet/ArcFace or AdaFace Core ML encoder:
retained, consented crops can be re-embedded into a new version without changing
identity IDs or silently collecting new imagery.

## Storage and deletion

Profiles use opaque UUID directories under:

```text
~/Library/Application Support/Cerebro/People/
```

Profile manifests, feature representations, and retained JPEG face crops are
AES-GCM encrypted with a 256-bit key stored in Keychain as device-only material.
Names never become directory names. **Delete Selected Person** removes the
profile and all of its retained samples.

The gallery is disabled by default. Enabling recognition never grants robot
control authority and does not upload biometric data.

## Validation

Run the storage fixture and static wiring checks with:

```sh
swiftc Cerebro/ROBFaceIdentityGallery.swift Tests/ROBFaceIdentityGalleryFixtureTests.swift -o /tmp/rob-face-gallery-tests
/tmp/rob-face-gallery-tests
python3 Tests/ROBFaceIdentityStaticTests.py
```

Production calibration should measure false accepts and false rejects using
unknown visitors, look-alikes, different lighting, glasses, masks, printed
photos, and screen replays. Depth/liveness is a future strengthening signal and
must not turn face identity into a standalone administrator credential.
