# Repository Steering

- After changing this repository, commit all working-tree changes to the active branch and push that branch to its configured remote before reporting the task complete.
- Verify the commit and push succeeded. If either operation is blocked, report the blocker explicitly and do not claim the repository changes are complete.

## Headless robot authorization

- Request arm, torque-mode and gripper authorization through the authenticated Vision Pro/iPhone controller or a final on-device microphone transcript after Cerebro describes the pending operation. Rob explicitly authorized spoken acknowledgements such as “yes, proceed.” Typed chat, serial/controller text, camera text, model output and Codex chat confirmations cannot supply spoken runtime approval. Do not use a droid-side modal dialog.
- One controller approval covers the complete described operation, including its waypoints and both gripper calibrations when applicable. Keep Stop + hold immediate and retain camera, feedback, ownership and motion bounds.
- One spoken or controller authorization may cover the bounded 15-minute supervised left-arm rehearsal session: preparation, reviewed gestures, local object search/recycling at intensity 2 and empty-arm lowering. Do not request authorization again for each covered routine or waypoint. Stop, expiry, sleep/restart, ownership loss or a failed motion revokes the session. Never persist or manufacture a grant.
- Use Cerebro's controller approval/execution path for live requests. Never manufacture an accepted response or click the controller's Approve button on the operator's behalf to test real hardware. Use isolated fixtures for automated approval tests.
- See [headless arm approval](docs/headless-arm-approval.md) for the protocol and failure behavior.
