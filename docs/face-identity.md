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

The People window shows accepted and remaining photo counts, live guidance, and
the enrolled lighting range. Visual guidance updates continuously; each spoken
correction is given at most once per requested session and corrections are
spaced at least 30 seconds apart. Prompts distinguish no
face, more than one face, too far away (**stand closer**), too dark,
overexposed, blurred or obstructed, misaligned, and repeated-pose conditions.
Select any completed profile and choose **Refine Selected Identity** to add eight
current-lighting and pose samples without changing its name, role, model, or
trusted controller allowlist.

Names need not be unique: a parent and child named Rudy have separate UUID
profiles and separate face samples. **Rename Selected…** corrects a label
without changing that profile's ID, consent, samples, role, or controller
bindings. Selection follows the profile ID across refreshes and renames; a
row's tooltip shows its enrollment date and full ID for disambiguation.

Administrator enrollment additionally requires at least one paired, non-revoked
operator controller and a local confirmation dialog. Every active operator controller
is recorded in an explicit allowlist. Select a completed Administrator and choose
**Authorize Active Controllers** to replace that allowlist after controller pairing or
revocation without changing any face samples. A legacy single-controller profile is
expanded once only if its original controller is still active. `administrator` is deliberately only an
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

`ROBFaceIdentity.maximumPossibleMatchDistance` (0.52) allows only a spatially
continuous, already confirmed track to bridge a temporary weak match.
`ROBFaceIdentity.maximumRefinementConsentDistance` (0.52) controls ambiguous
matches during a requested enrollment. Neither threshold establishes a new
identity or grants authority.

The gallery records its backend identifier and stores normalized 512-dimensional
embeddings alongside retained, consented crops. Ordinary recognition is
read-only with respect to face samples: it never appends images or embeddings,
including background lighting or pose adaptation. New face samples are stored
only during an explicitly requested enrollment or refinement session. Existing
profiles, names, roles, controller bindings, and samples remain intact.

Recognition accepts quality-gated faces at least 60 pixels wide and high, with
an encodable crop of at least 80 pixels. This replaces a fixed fraction-of-frame
area cutoff that discarded usable faces farther from high-resolution cameras.
Three strong, spatially consistent matches establish identity. Brief unusable
frames do not erase this evidence, but a gap of more than two seconds, a
different identity, or a disjoint face starts confirmation again.

Three strong AdaFace matches also seed a Vision pixel tracker on that face.
While the tracker remains fresh and above 0.42 confidence, its 10 Hz bounding
box keeps ROB's opt-in head tracking centered on the same recognized person and
keeps the name in short-lived scene context between the slower embedding
checks. Face detections are spatially associated with the tracked box, with bounded
position and size changes and rejection of ambiguous crossing faces, so a
small or briefly soft face does not immediately erase identity. The last
strongly confirmed embedding provides an additional in-memory appearance
reference during lighting changes; it is never written as a new face sample. A clear
conflicting embedding, prolonged spatial ambiguity, tracker loss, model or
enrollment changes, or 120 seconds without strong biometric revalidation drops
the identity latch. This continuity is still untrusted personalization data
and never authorizes motion or any other privileged action.

Ordinary recognition stays quiet when a face is unknown, small, blurred, or
uncertain. It does not ask anyone to hold still, face the camera, identify
themselves, or enroll. Camera-position and pose guidance is reserved for an
explicitly requested enrollment or refinement.

## Conversation and hands-free friend enrollment

Recognition publishes a conversation cue independent of an authorized autonomy
session. ROB greets a newly recalled person by name once, then observes a
five-minute per-person greeting cooldown. Recognized names enter cloud and local
conversation context as untrusted personalization data, never as authority.

Start hands-free enrollment with **“ROB, remember this person”** or
**“ROB, remember me”**. Ordinary introductions such as **“I'm Rudy”**, agreement
such as **“yes”**, and merely seeing an unfamiliar face never start this flow.
Negated, quoted, or hypothetical remember phrases do not start enrollment.
A fresh, single, quality-gated face must be visible when the command arrives;
otherwise ROB asks the requester to bring one person into view and repeat the
command. Only an in-memory embedding is held before the requested capture.

**“Remember this person”** asks for that person's consent and name, including a
reminder about a grown-up's permission for children. **“Remember me”** expresses
self-consent and asks for a name if missing; **“Remember me, my name is Rudy”**
provides both. Once the request is active, consent and names may arrive in
either order, as natural replies or word-by-word fragments. A name alone does
not provide consent for an operator's request to remember someone else.
Repeated transcripts do not repeat the same pending question. A decline saves
nothing. After consent, ROB creates only a `knownPerson` profile and binds
capture to the face present at the request. A different person stepping into
view is rejected. **“ROB, cancel enrollment”** stops capture and deletes its
partial profile and samples.

Each relevant reply refreshes a two-minute idle timeout, with a ten-minute
maximum for one invitation. Follow-up questions wait for two seconds without a
new fragment and are not repeated for duplicate transcripts. Declines,
uncertainty, expiration, and a new command cannot reuse earlier agreement;
unrelated requests end the exchange. Uncertain or hypothetical statements prompt
clarification instead of enrollment. **“Stop enrollment”**, **“Don't remember
me”**, and **“I've changed my mind”** also cancel hands-free capture.

Cerebro compares the consenting face against every compatible profile, regardless
of its name. Only a strong, unique match to a completed profile starts refinement,
preserving that profile's name, role, and controller bindings. A different face
gets a separate UUID even when the spoken name is already in use. Weak matches,
competing matches, and matches to incomplete enrollments require operator help;
they never merge people based on a shared name. The hands-free flow cannot
create or promote an administrator.

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
swiftc Cerebro/ROBFaceConversationPolicy.swift Tests/ROBFaceConversationPolicyFixtureTests.swift -o /tmp/rob-face-conversation-tests
/tmp/rob-face-conversation-tests
swiftc Cerebro/ROBFaceTrackingPolicy.swift Tests/ROBFaceTrackingPolicyFixtureTests.swift -o /tmp/rob-face-tracking-tests
/tmp/rob-face-tracking-tests
python3 Tests/ROBFaceIdentityStaticTests.py
python3 Tests/ROBFaceRecognitionServiceRuntimeTests.py
```

The runtime fixtures use synthetic Vision observations, a fake encoder, and an
isolated encrypted gallery. They check quiet recognition, distant faces, identity
continuity and conflicts, command/consent gating, requested capture and
cancellation, existing-profile refinement, and correction prompt suppression.
They never open a camera or connect to robot hardware.

Production calibration should measure false accepts and false rejects using
unknown visitors, look-alikes, different lighting, glasses, masks, printed
photos, and screen replays. Depth/liveness is a future strengthening signal and
must not turn face identity into a standalone administrator credential.
