---
name: simutex
description: Coordinate exclusive access to local iOS Simulators between coding agents. Use whenever an agent needs to discover, claim, inspect, operate, or release an iOS Simulator on a shared Mac.
---

# Simutex

Use `simutex` before interacting with any local iOS Simulator so concurrent agents do not select the same device.

1. Choose a stable owner identifier for the current agent or task and set `SIMUTEX_AGENT`.
2. Run `simutex list` to inspect available and locked simulators.
3. Run `simutex claim [UDID]`. With no UDID, simutex atomically claims the first unlocked simulator. Treat stdout as the claimed UDID.
4. Perform simulator work only on that UDID.
5. Always run `simutex release <UDID>` when the work ends, including after failures.

Only run `simutex reset` with explicit user authorization. It releases every lock regardless of owner, so it can disrupt other agents that are actively using their claims.

Never use or release a simulator locked by another owner. Same-owner claims are idempotent. Locks intentionally do not expire; report abandoned locks rather than taking them over without authorization.

For destructive simulator inventory changes, first use `simutex list` to ensure every target is unlocked and obtain explicit user authorization immediately before mutation.
