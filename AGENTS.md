# Repository Steering

- After changing this repository, commit all working-tree changes to the active branch and push that branch to its configured remote before reporting the task complete.
- Verify the commit and push succeeded. If either operation is blocked, report the blocker explicitly and do not claim the repository changes are complete.

## Headless robot authorization

- Request arm, torque-mode and gripper authorization through the authenticated Vision Pro or iPhone controller. Do not use a droid-side modal dialog or a Codex chat confirmation as the runtime approval mechanism.
- One controller approval covers the complete described operation, including its waypoints and both gripper calibrations when applicable. Keep Stop + hold immediate and retain camera, feedback, ownership and motion bounds.
- Use Cerebro's controller approval/execution path for live requests. Never manufacture an accepted response or click the controller's Approve button on the operator's behalf to test real hardware. Use isolated fixtures for automated approval tests.
- See [headless arm approval](docs/headless-arm-approval.md) for the protocol and failure behavior.
