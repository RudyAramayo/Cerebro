# Amber internal Drake model review — September 22, 2026

Amber's internal solver uses a different model and coordinate convention from
Cerebro's whole-robot preview. The read-only comparison supports preparing an
adaptation, but does not establish a URDF defect as the cause of lost motor
replies or a controller-thread stall. No replacement model is activated.

The [captured configuration and comparison](evidence/2026-09-22-right-arm/amber-internal-model-comparison.json)
contains hashes, seven-joint definitions, launch parameters and process
observations from Amber at 22:55 PDT. The configured files match the repository
copies line-for-line, with different final line termination. Startup logs name
the same selected paths; this inspection does not extract an in-memory Drake
plant or prove its exact loaded contents.

| Physical arm | Core / port | Configured URDF, relative to core directory | Solver endpoint |
| --- | --- | --- | --- |
| ROB right | L-10 / 26001 | `urdf/dual_b1/DualArmL.urdf` | `Lseven_Link` |
| ROB left | R-11 / 26002 | `urdf/dual_b1/DualArmR.urdf` | `Rseven_Link` |

Both launch files enable Drake, set seven robot degrees of freedom and use
`base_link` as the solver base. `Robot.Rotation_Direction` is all positive;
`Solver.Rotation_Direction` is `[1, −1, 1, −1, 1, −1, 1]`. The vendor URDF also
uses negative Z axes on J2, J4 and J6. Both layers must be accounted for before
changing an axis or interpreting a vendor Cartesian result.

The vendor models combine the old dual-arm mounting frame into J1's origin.
Cerebro places each arm under `torso_link` using a fixed B1 mount, with a
separate J1 origin. It also adds a fixed tool frame 0.11 m beyond the seventh
link. Raw shoulder Euler angles are expressed in different parent frames and
are not directly comparable physical mounting angles. Identical `base_link`
names do not identify a shared Cartesian reference.

J2–J7 translation magnitudes agree to source rounding. The vendor URDF bounds
all seven model joints at ±2.09 rad; Cerebro's model uses joint-specific bounds.
Those bounds refer to model coordinates. They must be transformed with the
encoder reference before comparison with startup vendor positions. This
review does not authorize broadening motion limits.

Rob's physically verified upright vectors remain calibration priors. They
were supplied before subsequent controller restarts. The current zero mapping
and all seven direction signs have not been independently fitted. Preserve
the mount cant separately from the session encoder offset; updating fixed
geometry alone will not establish the current encoder-to-model mapping.

A deployable update needs a separate seven-DOF URDF for each physical arm,
with explicit base/tool conventions and compatible core names. It must account
for the solver direction conversion, the session zero mapping and conservative
joint limits. Compare forward-kinematic predictions with the observed poses
and an independent validation pose before installing it through a guarded
core restart. Copying the complete ROB URDF into either seven-joint core is
not a compatible update.

The vendor cores each exposed 19 threads and stayed alive during inspection.
Their thread names do not identify the solver or establish its lock behavior.
The separate Mac preview planner launches a Python worker; that worker was
not running during this check. The confirmed Mac diagnostics rendering/export
delay is a separate finding from the vendor solver's internal scheduling.

The right arm is holding `[+0.60, −0.60, 0, 0, 0, 0, 0]` in the current
controller session. The unsent +0.75 slider target was cleared. No Cartesian
target, gripper action, zero reset, model deployment or core restart was sent
by this model inspection.
