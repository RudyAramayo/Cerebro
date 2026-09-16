# Controller latency diagnostics

Open **Development → Control Latency…** in Cerebro. Development Mode does not
need to be enabled. The window is read-only and refreshes four times per second;
opening it does not move ROB or send test commands. It previews the most recently
received tread/full controller snapshot, including release/brake state, sender,
sequence (when supplied), and time since receipt. Grey input older than 0.5 seconds
is labeled stale/idle. This is received input, not confirmation of applied motion.

| Measurement | What it measures |
| --- | --- |
| Main queue wait | A background probe's wait to execute on Cerebro's main queue, sampled every 100 ms. Only one probe can be pending, even during a long stall. |
| Command handler | Time in the generic controller delegate, including parsing, synchronous serial output, preview updates and acknowledgements. Excludes time waiting to enter the main queue. |
| Base serial write | Duration of the OS write call. Status reports unavailable/incomplete writes. This does not measure transmission completion, firmware handling or physical tread response. |
| Connection round trip | Existing authenticated connection probe/echo timing, including network and scheduling delays at both endpoints. Older clients may not support probes. |
| Sender clock age | Difference between the received tread snapshot's timestamp and Cerebro's wall clock at processing. Requires synchronized clocks; it is an estimate, can be negative, and is unavailable on full snapshots. |

Peaks persist after a stall until **Reset peaks** or app restart. A frozen UI
cannot redraw while its main thread is blocked; the independent probe retains
the wait and shows it after recovery. Compare the queue and handler peaks with
connection round trip to locate delays rather than adding these overlapping
measurements into an end-to-end total. A slow camera preview is a separate path.

## Blocking calls removed

A live sample during the reported multi-second delay caught the main thread in
`NSHost.name` / `blockingResolveUntil:` inside the full controller snapshot ACK.
Since ROBControl receive callbacks also run on the main queue, a hostname lookup
after one frame delayed subsequent tread/release frames. ACKs now reuse a local
hostname obtained once with `gethostname`, without DNS. Startup uses the same
cached value.

The same sample also caught the five-second RPLidar timer synchronously draining
`ps aux` output on the main thread. It now uses NSWorkspace's running-application
snapshot without launching or waiting for `ps`.

The existing client already coalesces pending tread snapshots on a
`userInteractive` transport queue. Cerebro's nonurgent serial render limiter is
75 ms, with urgent changes bypassing it; it is not a multi-second timer. The
server still owns its transport and control state on the main queue, so other
future blocking work there can cause stalls. These changes remove the observed
blocking operations; physical response must be measured with a rebuilt app.

## Validation

`bash Scripts/test-control-latency.sh` exercises concurrent measurement updates,
a deliberate main-thread stall and recovery, bounded pending probes, and the
read-only preview window. An optional PNG output path captures the fixture UI.
The fixture has no robot/transport dependencies and sends no commands.
