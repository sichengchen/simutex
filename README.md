# simutex

`simutex` is a tiny mutex for iOS Simulators. It lets multiple local agents discover simulators, claim one atomically, check its lock, and release it when finished.

## Install

```sh
brew install sichengchen/tap/simutex
```

## Build

Requires Zig 0.16.0 and Xcode:

```sh
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/simutex`.

## Release

1. Bump the version in `build.zig.zon` and the `simutex version` string in `src/main.zig`.
2. Merge to `main`, then tag and push (for example `v0.1.0`).
3. GitHub Actions builds the release, publishes a GitHub Release, and updates [`sichengchen/homebrew-tap`](https://github.com/sichengchen/homebrew-tap).

The release workflow needs a `TAP_GITHUB_TOKEN` repository secret with write access to the tap. Without it, the GitHub Release still publishes; the formula update is skipped.

## Install the agent skill

Run the interactive terminal setup after installing the CLI:

```sh
simutex init
```

It detects supported local agent homes, selects all of them by default, and installs the bundled `simutex` skill. For non-interactive setup or upgrades:

```sh
simutex init --all
```

## Agent workflow

Give each agent a stable, unique owner name:

```sh
export SIMUTEX_AGENT="agent-42"
```

Then follow the claim/use/release lifecycle:

```sh
# See every available iOS Simulator and whether simutex has locked it.
simutex list

# Watch simulator and lock status in a full-screen, auto-updating terminal UI.
simutex monitor

# Atomically claim the first unlocked simulator. stdout is its UDID.
UDID="$(simutex claim)"

# Use the simulator.
xcrun simctl boot "$UDID"

# Check a particular lock.
simutex status "$UDID"

# Always release it when finished.
simutex release "$UDID"
```

To release every claim regardless of owner:

```sh
simutex reset
```

`reset` is an administrative recovery command; do not run it while other agents are
actively using claimed simulators.

To request a particular simulator, pass its UDID to `claim`:

```sh
simutex claim 00000000-0000-0000-0000-000000000000
```

`claim` uses atomic symbolic-link creation, so concurrent agents cannot both acquire the same simulator and the owner metadata appears atomically with the lock. Re-claiming with the same owner is idempotent. A different owner cannot release the lock.

Locks live in `$SIMUTEX_STATE_DIR`, or `$TMPDIR/simutex` by default. They intentionally do not expire: if an agent crashes, inspect the owner with `status` and release using that owner identity.

`simutex monitor` listens for CoreSimulator, lock-directory, and terminal-resize events and updates the display only when its contents change. It falls back to polling if the private CoreSimulator connection is unavailable. Press `q` or Ctrl-C to leave it and return to the previous terminal contents.
