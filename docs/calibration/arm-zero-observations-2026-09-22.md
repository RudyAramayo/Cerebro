# Operator-reported B1-zero references — September 22, 2026

Source: Rob's calibration report in the September 22 session
(America/Los_Angeles). Joint order is servo 1 through servo 7; sides are ROB's
physical left and right, not the observer's sides. These are pose coordinates,
not joint travel limits.

Rob identifies B1 zero as the fully upright arm configuration relative to its
own mounting frame. The arm is still tilted in the robot frame by its fixed
shoulder mounting angle. Preserve the approved mount transform in the model
and URDF; do not absorb that cant into an encoder-zero correction.

## Operator-verified upright reference

Values are retained exactly as supplied. The Amber V2 joint-position API uses
radians. These are operator-reported Amber coordinates, not independently
captured encoder telemetry or physical URDF joint angles.

| Joint | ROB-right / L-10 | ROB-left / R-11 |
| --- | ---: | ---: |
| J1 | 0.00 | 0.00 |
| J2 | -2.080432 | 2.080432 |
| J3 | 0.00 | 0.0 |
| J4 | 0.687254 | -0.687254 |
| J5 | 0.00 | 0.0 |
| J6 | -0.027043 | 0.027043 |
| J7 | 0.00 | 0.0 |

```text
ROB-right: [0.00, -2.080432, 0.00, 0.687254, 0.00, -0.027043, 0.00]
ROB-left:  [0.00,  2.080432, 0.0, -0.687254, 0.0,  0.027043, 0.0]
```

Rob explicitly confirmed that **both arms were physically verified at the
upright B1-zero pose in the current controller session**. The left vector is
therefore operator-verified, not merely an inferred mirror. The small opposing
J6 corrections are intentional supplied values and must not be rounded to zero.

This is operator observation of the pose coordinates. No synchronized
photographs, independent raw telemetry capture, controller boot ID, or gateway
session generation were supplied with the vectors. Preserve that distinction
when establishing the runtime's measured, session-bound reference. This note
does not itself authorize or execute an automatic reset command.

## Earlier small lift

Earlier in the conversation, Rob reported right-arm J2 displaying `0` at app
startup with the arm hanging. A position target of `-0.155168` produced a slight
lift. Thus the reported command change was negative. Forward versus outward
motion was not specified, and this observation does not establish the
vendor-to-URDF sign for every joint. The controller was subsequently rebooted;
the earlier lift and the upright vectors must not be assumed to share an
encoder reference.

## Using a verified reference

After independently verifying the physical B1-zero pose, raw units, individual
joint directions, and current controller session, the existing
`ROBAmberArmReferenceTransform` supports:

```text
q_model = direction * (q_vendor - q_vendor_at_verified_B1_zero)
q_vendor = q_vendor_at_verified_B1_zero + direction * q_model
```

`direction` is established separately for each joint; mirrored target vectors
alone do not establish it. This assumes B1 zero has been verified against the
specific joint frames in the loaded URDF. Preserve these operator-verified
vectors as durable calibration priors across power cycles. Rob clarified that
startup should expect hanging arms, then use a camera-visible extension and
small independent servo movements to estimate any session offset changes.
A manual return to B1 zero is not required at each boot. The active encoder
mapping must come from current observations rather than blindly copying an
old session offset. Fixed mount geometry remains separate. See the
[camera-guided startup workflow](camera-guided-arm-startup.md).

Keep physical side identity explicit when integrating these vectors. The
geometry handoff identifies ROB-right as L-10 and ROB-left as R-11. The gateway's
current defaults instead call UDP 26001 / L-10 `left` and UDP 26002 / R-11
`right`. These gateway labels must be reconciled with observed physical arm
identity before using either vector in a runtime calibration. No side routing
was changed as part of the protocol compatibility fix.

At the time of this report, partial servo mode transitions and failed
deactivation were under investigation. The independently identified Cerebro /
gateway compatibility fault does not validate the physical arm state or resolve
those servo symptoms. Re-establish fresh seven-joint feedback and confirmed
modes before any supervised return-to-zero motion.
