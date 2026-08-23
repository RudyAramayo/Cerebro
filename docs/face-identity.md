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

The backend detects faces and landmarks with Vision, filters captures with
Vision face quality, and runs normalized square crops through a locally installed AdaFace
IR-18 Core ML encoder. Choose **AdaFace R18 — WebFace4M** or **AdaFace R18 —
VGGFace2** from the Face model menu. The selection persists across launches.
Profiles are tagged with their encoder; a profile made with one model is never
compared against vectors from the other model. Switch back to its model to use
that profile, or delete it and enroll again with the preferred model.

WebFace4M is the recommended default when both are installed because its
training set is broader. VGGFace2 is useful as a second option for evaluating
which model performs better on ROB's camera and environment.

`ROBFaceIdentity.maximumCosineDistance` and
`ROBFaceIdentity.minimumCosineMargin` are developer calibration defaults,
initially 0.35 and 0.06. They must be calibrated
with separate enrollment and validation footage from ROB's actual camera before
recognition is treated as reliable. Names enter scene context for only 15
seconds and camera-derived identity remains untrusted sensor data.

The gallery records its backend identifier and stores normalized 512-dimensional
embeddings alongside retained, consented crops.

## Installing AdaFace models

The checkpoint files and converted model packages are intentionally kept out of
Git. Place the official checkpoints in Cerebro's model directory using these
exact names:

```text
~/Library/Application Support/Cerebro/Models/adaface_ir18_vgg2.ckpt
~/Library/Application Support/Cerebro/Models/adaface_ir18_webface4m.ckpt
```

Then run the reproducible converter from the repository root:

```sh
python3 Scripts/install_adaface_models.py \
  --source-root "$HOME/Library/Application Support/Cerebro/ModelTools/AdaFace" \
  --checkpoint-dir "$HOME/Library/Application Support/Cerebro/Models" \
  --output-dir "$HOME/Library/Application Support/Cerebro/Models"
```

The installer converts each IR-18 network to FP16 Core ML, validates its output
against PyTorch, compiles it for runtime use, and writes SHA-256 provenance to
`adaface-models.json`.

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
