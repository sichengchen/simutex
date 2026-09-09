# Desktop compatibility and validation

The initial application targets Apple Silicon, macOS 15 or later, and local
Apple iPhone/iPad simulators. Bundle identifier: `com.scchan.simutex`.

Validated on September 8, 2026 with macOS 27 beta (26A5425a), Xcode 27 beta
(27A5237l), and iOS 27 simulators. Older OS/Xcode combinations have not received
live display/input validation. Private APIs can change between Xcode releases.
The application loads frameworks from the selected Xcode; restart after changing
that selection. No private desktop frameworks are required by the standalone CLI.

The bridge uses CoreSimulator display ports, SimScreen IOSurface callbacks,
SimulatorKit HID transport and the Xcode 27 DTUHID endpoint. ABI research used
[facebook/idb](https://github.com/facebook/idb), particularly its
FBSimulatorControl HID implementation and private framework declarations.
The bridge is maintained here and does not require idb at runtime.

## Checks

Automated validation covers Zig locking behavior, legacy ownership, claim
contention, expected-owner takeovers, metadata persistence/concurrent writes,
hook precedence and device isolation, hook failure/timeouts, post-hook lock
retention, lifecycle context and event snapshots. Swift checks cover inventory
parsing, exact-device instructions and adaptive layout.

Live checks exercised embedded IOSurface display, taps, Home, physical keyboard
entry, manual claim/unlock, metadata
round-trip, and the workspace with two manual tiles and four preview tiles.
Six simultaneous first boots caused CoreSimulator to stall on the test host;
therefore sustained six-device input/performance acceptance remains unverified.
Only the additional test devices were stopped during recovery. Other agents'
reservations were preserved.

## Rendering budget

The focused tile is capped at 60 fps, other manual tiles at 30 fps and previews
at 5 fps. Unchanged surface generations are skipped. Each view allows one GPU
command in flight and retains its surface until completion, dropping intermediate
frames rather than building a frame queue. Hidden/minimized views suspend their
timers. These implementation limits are not measured throughput guarantees.
Simulator process CPU/memory must be reported separately from app overhead.

Before a public release, repeat sustained two-manual/four-preview profiling,
keyboard/paste, rotations, reconnects and lifecycle/ownership transitions on the
release Xcode and each supported macOS version. Distribution builds also require
Developer ID signing and notarization; local build scripts use ad-hoc signing.

A spot measurement with one manual screen and one preview at rest showed 80 MiB
RSS for the application and 23 MiB for its CLI watcher, both at 0.0% sampled CPU.
This is an idle observation, not a sustained animation or six-device benchmark.
