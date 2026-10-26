# Optional estimated optical pitch refinement

This refines the existing **estimated** head-camera orientation. It does not register the camera to an arm, change raw optical depth, classify robot surfaces, authorize motion, reduce the visual trial's assumed spatial error, or alter the historical QR fit. Model base Z being vertical remains an explicit assumption. Origin, image-right heading, servo scales and yaw stay prior values.

Do not activate an old body's evidence after a relaunch or body motion. Capture new original source frames in the current body context. At least three distinct training raw P/L/U poses and one different held-out P/L/U pose are required. The active camera generation must come from a held-out source, and actual-frame consumers must confirm its exact generation, runtime calibration identity and camera-service source hash before using the estimated projection.

The optional field in `ActiveRGBDisplayProfile.json` is:

```json
{
  "estimatedGravityPitchRefinement": {
    "evidencePath": "/absolute/private/path/refinement.json",
    "evidenceSHA256": "SHA256_OF_EXACT_EVIDENCE_BYTES"
  }
}
```

The private evidence JSON has this exact structure. Replace placeholders with the actual captured values; do not restamp, rebind, or synthesize a capture:

```json
{
  "schemaVersion": 1,
  "kind": "estimated_stationary_imu_optical_x_pitch_refinement",
  "method": "mean_training_post_optical_x_preserve_origin_image_right_v1",
  "modelID": "CURRENT_MODEL_SHA256",
  "referenceID": "CURRENT_REFERENCE_SHA256",
  "geometryID": "CURRENT_GEOMETRY_SHA256",
  "mappingID": "ORIGINAL_CAPTURE_ARM_MAPPING_SHA256",
  "oldEstimatedCameraProjectionIdentity": "IDENTITY_WITHOUT_THIS_OPTIONAL_REFINEMENT",
  "bodyMotionIdentity": "CURRENT_BODY_UUID",
  "activeCameraGeneration": "ORIGINAL_HELD_OUT_CAPTURE_CAMERA_UUID",
  "cameraRole": "face",
  "actualDeviceMXID": "ACTUAL_FACE_DEVICE_MXID",
  "runtimeCalibrationIdentity": "ACTUAL_RUNTIME_CALIBRATION_SHA256",
  "cameraServiceSourceSHA256": "ACTUAL_CAMERA_SERVICE_SOURCE_SHA256",
  "deltaRadians": -0.1,
  "registrationVerified": false,
  "armMotionAuthority": false,
  "rawDepthCorrected": false,
  "modelBaseUpAssumed": true,
  "opticalOriginPriorUnchanged": true,
  "imageRightHeadingPriorUnchanged": true,
  "captures": [
    {"role":"training","captureInputPath":"/absolute/capture-A/capture-input.json","captureInputSHA256":"ACTUAL_MANIFEST_SHA256"},
    {"role":"training","captureInputPath":"/absolute/capture-B/capture-input.json","captureInputSHA256":"ACTUAL_MANIFEST_SHA256"},
    {"role":"training","captureInputPath":"/absolute/capture-C/capture-input.json","captureInputSHA256":"ACTUAL_MANIFEST_SHA256"},
    {"role":"held_out","captureInputPath":"/absolute/capture-D/capture-input.json","captureInputSHA256":"ACTUAL_MANIFEST_SHA256"}
  ]
}
```

Write the evidence privately (mode `0600`) and hash its final exact bytes. Do not copy private camera captures, evidence, user observations or their paths into the repository.

For each source, the loader verifies its pinned manifest, exact model/geometry/mapping/body scope, original advancing frame sequences/timestamps, camera generation, runtime provenance and actual raw depth hashes. The evidence mapping is the original capture UI's arm mapping. It must be one of the two actual legal mappings for that same canonical model, and every captured scope must retain that exact mapping. Either arm may use the resulting shared head-camera estimate only after the source and caller models' head reference frames and articulated camera chains are proven identical. The loader does not relabel captures, mirror arm FK, measure another arm, or change either arm's own mapping/collision checks; both callers receive the same camera projection identity. Source `frame-i.depth-u16le` files must remain beside their original capture manifest. The calculation consumes IMU observations, not RGB semantics or manufactured CAD landmarks. JPEGs do not contribute to this pitch measurement.

All source frames must have the same actual FACE device/runtime calibration and camera service. IMU-to-RGB rotation must be a proper orthonormal factory rotation. Stationary IMU observations need at least 10 samples over 100–1000 ms, age at most 100 ms matching original IMU timestamps, gravity magnitude 7–12 m/s², per-axis standard deviation at most 0.10 m/s², and gyro magnitude at most 0.03 rad/s. Source means must have at most 1° angular spread. The loader accepts 4–16 captures of 3–8 distinct original frames, with at most 64 MB of raw depth.

To derive `deltaRadians`, first compute the existing unrefined rotation `R` for each capture's actual raw P/L/U, including its existing pan calibration. Normalize and average the capture's actual `imu_to_rgb_rotation * gravity_mps2` vectors to obtain `g`. Let `s = Rᵀ (0,0,1)`. Its required post-optical-X pitch is:

```
atan2(s.z * g.y - s.y * g.z, s.y * g.y + s.z * g.z)
```

Use the arithmetic mean of the **training capture** requirements, giving each capture one vote. The loader independently recomputes this mean (agreement within `1e-9` rad), caps its magnitude at 20°, and requires every training and held-out capture's corrected gravity direction to agree with assumed model up within 1°. Held-out poses cannot duplicate training poses. These are consistency limits for an estimated mounting refinement, not a measured global hand-eye error bound.
The frozen mount estimate is applied by the articulated prior at other raw neck poses; the 1° agreement is established only for the listed sources. Include the poses used by a wider search in new training/held-out captures before claiming their alignment. This option does not measure servo scales, servo zeros or generalize a verified calibration to unsampled angles.

The central `Pose.provisionalCameraToModel` applies the frozen post-X rotation once, preserving its optical-origin and image-right columns exactly. Its estimated projection identity includes the old identity, exact evidence hash, delta, body, active camera generation, runtime identity and service hash. An absent optional field preserves prior matrices and identities. Invalid or mismatched requested evidence returns no refined profile or estimated identity; it never keeps a corrected identity with an uncorrected fallback.

Actual-frame callers must additionally require:

```swift
ROBNeckRGBPoseDisplay.estimatedProjectionAcceptsSource(
    model: model,
    cameraGeneration: frame.cameraGeneration,
    runtimeCalibrationIdentity: frame.intrinsics?.runtimeCalibration?.identity,
    cameraServiceSourceSHA256: frame.intrinsics?.cameraServiceSourceSHA256)
```

This is in addition to their existing exact held-neck, body/session, normalized RGB/depth, freshness, ownership and trial checks. The method returns legacy `true` when the optional refinement is absent, and `false` for a requested invalid refinement or source mismatch. Rebuild observations and maps from original fresh pixels after changing the refinement; do not rotate or relabel an existing map. Registered projection paths keep their measured transform.

The historical common QR display gauge and cosmetic lifts stay unchanged. That gauge may rotate the entire displayed world relative to screen up; do not add a second physical camera correction to cancel it.
