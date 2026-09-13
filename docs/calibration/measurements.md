# ROB measurement sheet

Capture date/time:

Dataset / scan filename:

Camera model, lens, image dimensions:

Power state and arm support used:

Amber startup/session identifier (or exact startup time):

Waist / lean / flipper / neck pose during this dataset:

Do not fill unknown values with zero. Dimensions below are in millimeters.
Record an estimated uncertainty based on the instrument and repeatability.

| Measurement | Value mm | Uncertainty ±mm | Instrument / landmark definition |
| --- | --- | --- | --- |
| Rigid reference length A | | | |
| Independent check length B | | | |
| Independent check length C | | | |
| Overall height in this pose | | | |
| Outside tread width | | | |
| Tread center separation | | | |
| Tread ground-contact length | | | |
| Tread width, left / right | | | |
| Lean pivot height above ground | | | |
| Turntable center height above ground | | | |
| Left shoulder plate center height | | | |
| Right shoulder plate center height | | | |
| Shoulder plate center separation | | | |
| Shoulder fore/aft offset, left / right | | | |
| Left flange-to-grasp-center distance | | | |
| Right flange-to-grasp-center distance | | | |
| Gripper open gap, left / right | | | |
| Lower-neck to upper-neck pivot separation | | | |
| Upper-neck to Insta360 body datum | | | |
| Upper-neck to OAK body datum | | | |
| LACT pin-to-pin distance in this pose | | | |
| Flipper pivot to end | | | |
| Target ball diameter | | | |
| Table surface height above ground | | | |

## Landmark coordinates

Draw the base and torso datum axes on an annotated photo first. Use X forward,
Y ROB-left and Z up. A reference point may be a measured sticker or bolt center;
do not call it a joint center unless the offset to the actual axis is known.

| Label | Parent frame | X mm | Y mm | Z mm | Uncertainty ±mm | Fit or independent check? | Photo / physical feature |
| --- | --- | --- | --- | --- | --- | --- | --- |
| BASE_A | base_link | | | | | fit | |
| BASE_B | base_link | | | | | fit | |
| BASE_C | base_link | | | | | fit | |
| BASE_CHECK | base_link | | | | | check | |
| L_BASE_A | torso_link | | | | | fit | |
| L_BASE_B | torso_link | | | | | fit | |
| L_BASE_C | torso_link | | | | | fit | |
| L_BASE_CHECK | torso_link | | | | | check | |
| R_BASE_A | torso_link | | | | | fit | |
| R_BASE_B | torso_link | | | | | fit | |
| R_BASE_C | torso_link | | | | | fit | |
| R_BASE_CHECK | torso_link | | | | | check | |
| NECK_LOWER_AXIS | torso_link | | | | | | |
| NECK_PAN_AXIS | lower_neck_link | | | | | | |
| NECK_UPPER_AXIS | neck_pan_link | | | | | | |
| LACT_FIXED_PIN | base_link | | | | | | |
| LACT_MOVING_PIN | lean_link | | | | | | |

## Stationary startup observations

Read only. Do not move or re-home a joint to fill this sheet. Record radians or
the exact raw units the interface reports; do not silently convert counts to
angles. Physical model angles and signs remain unknown until measured.

| Physical arm | Joint | Raw feedback | Raw unit | Observed model angle rad | Direction verified ±1 | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| ROB-left | 1 | | | | | Reported at initialization position; verify |
| ROB-left | 2 | | | | | Gravity-hanging offset; measure |
| ROB-left | 3 | | | | | Reported at initialization position; verify |
| ROB-left | 4 | | | | | Gravity-hanging offset; measure |
| ROB-left | 5 | | | | | Reported at initialization position; verify |
| ROB-left | 6 | | | | | Reported at initialization position; verify |
| ROB-left | 7 | | | | | Wrist orientation needs a directional tool landmark |
| ROB-right | 1 | | | | | Reported at initialization position; verify |
| ROB-right | 2 | | | | | Gravity-hanging offset; measure |
| ROB-right | 3 | | | | | Reported at initialization position; verify |
| ROB-right | 4 | | | | | Gravity-hanging offset; measure |
| ROB-right | 5 | | | | | Reported at initialization position; verify |
| ROB-right | 6 | | | | | Reported at initialization position; verify |
| ROB-right | 7 | | | | | Wrist orientation needs a directional tool landmark |
