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
export SIMUTEX_AGENT="agent:checkout-tests-task42"
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

## Session names

New reservations use `agent:<purpose>` or `manual:<macOS short username>`:

```sh
export SIMUTEX_AGENT="agent:checkout-tests-task42"
simutex claim
```

Each concurrent agent needs a distinct name. Names are coordination identifiers,
not authentication. Existing legacy reservations can still be reclaimed
idempotently and released using their exact owner string. Newly acquired names
must have a nonempty suffix, contain no control characters, and fit in 256 UTF-8
bytes.

## Simulator descriptions

Descriptions persist independently of reservations and are keyed by UDID:

```sh
simutex describe "$UDID" "Checkout tests only. Uses the staging account."
simutex list --json
simutex status "$UDID" --json
simutex describe "$UDID" ""  # clear the description
```

Agents must read descriptions and follow applicable device restrictions. A
simulator description is separate from the purpose in an agent's session name;
it does not mechanically enforce routing or run commands.

Metadata defaults to `~/Library/Application Support/simutex/metadata.json`.
`SIMUTEX_METADATA_PATH` overrides the file. Writes are serialized and committed
by atomic rename, preserving unrelated simulators' metadata.

## Claim hooks

Hooks are optional local executables. They run outside the ownership mutation
guard. No repository configuration is automatically discovered or executed.

A defaults file has optional `pre_claim` and `post_claim` entries:

```json
{
  "pre_claim": {
    "argv": ["./check-environment"],
    "cwd": ".",
    "timeout_seconds": 60
  },
  "post_claim": {
    "argv": ["./prepare-simulator", "--staging"],
    "timeout_seconds": 120
  }
}
```

```sh
simutex claim "$UDID" --hooks ./hooks.json
export SIMUTEX_HOOKS=/absolute/path/hooks.json
```

`--hooks` takes precedence over `SIMUTEX_HOOKS`. For each event, configuration
resolves independently: invocation override, then per-simulator override, then
the defaults file, then no hook. Overrides replace rather than append commands.
A JSON `null` explicitly disables an event; an omitted event inherits it.

A per-device custom-hook file contains one definition:

```json
{"argv":["./prepare-checkout","--staging"],"cwd":".","timeout_seconds":120}
```

```sh
simutex hooks set "$UDID" --event post-claim --config ./checkout-hook.json
simutex hooks show "$UDID" --json
simutex hooks disable "$UDID" --event pre-claim
simutex hooks inherit "$UDID" --event post-claim
simutex claim "$UDID" --post-claim /absolute/path/one-off-setup
simutex claim "$UDID" --no-pre-claim --no-post-claim
```

Custom per-device definitions are stored in metadata with resolved absolute
paths. Relative paths in configuration are resolved against the defining file's
directory. Invocation executable paths resolve against the current directory.
Commands run directly, without shell expansion; use `argv: ["/bin/sh", "…"]`
explicitly when needed. The working directory defaults to the defining file's
directory. Timeout defaults to 60 seconds (maximum 86400); timeout terminates the
hook's process group.

Lifecycle:

1. Select a simulator and resolve its hooks. Same-owner reclaims skip hooks.
2. Run pre-claim without ownership. Use this for checks, not simulator mutations.
   Failure aborts without acquiring a lock. The candidate can still be claimed
   by someone else while this hook runs.
3. Atomically acquire ownership, rechecking contention. Automatic selection may
   try another eligible simulator if a competing claim won.
4. Run post-claim while reserved. Failure returns a nonzero exit code, identifies
   the UDID and current owner on stderr, and leaves the reservation intact.
   Inspect and clean up explicitly; retrying the same-owner claim skips setup.

Hook stdout/stderr both go to CLI stderr. Claim stdout contains only the UDID,
and only after success. Hooks receive `SIMUTEX_HOOK_EVENT` (`pre-claim` or
`post-claim`), `SIMUTEX_UDID`, `SIMUTEX_OWNER`, `SIMUTEX_PREVIOUS_OWNER` (empty
for ordinary claims), `SIMUTEX_OPERATION` (`claim` or `takeover`),
`SIMUTEX_STATE_DIR`, and `SIMUTEX_METADATA_PATH`. Hooks can read descriptions via
`simutex status "$SIMUTEX_UDID" --json`. Side effects are not rolled back.

## Structured snapshots and takeover

`simutex list --json` returns `{"version":1,"devices":[…]}`. Each device includes
`udid`, `name`, `runtime`, `state`, nullable `owner`, `description`, and raw
per-device `hooks` overrides. `status --json` returns the ownership/metadata
object for one UDID, even if that device is currently unavailable.

```sh
simutex watch --json
simutex takeover "$UDID" --owner "manual:$(id -un)" --expected-owner agent:checkout-tests-task42
```

Watch emits an initial snapshot followed by changed snapshots as newline-delimited
JSON. It listens for CoreSimulator and directory events, with a periodic recovery
refresh and a one-second inventory fallback when CoreSimulator is unavailable.
Takeover checks the expected owner again after pre-claim, and runs post-claim
after the transfer. It does not stop an agent or its in-flight commands.

Updated writers serialize claim, release, reset, and takeover through a shared
advisory guard. Older binaries still understand the symlink format but do not
participate in that guard; upgrade all writers for the stronger guarantees.
Locks remain cooperative: external simulator tools do not enforce them.

## Desktop app

```sh
zig build app -Doptimize=ReleaseSafe
```

Open `zig-out/Simutex.app`. The app targets Apple Silicon and macOS 15+, and its
bundle identifier is `com.scchan.simutex`. The standalone CLI does not depend on
AppKit, Metal, or the application bundle.

The workspace fits manually reserved simulators to the window, with a collapsible
preview rail for other running devices. Locked devices show the exact session
owner beneath their name, including legacy owners. Hover or focus a simulator
for controls below its screen; the header menu opens ownership actions, copied
agent instructions, descriptions, and hooks. The inspector separates Description,
Hooks, and Device panels. Custom hook fields appear only when Custom is selected. The app uses the bundled CLI for the same ownership,
metadata, and hooks as agents. Quit preserves reservations and running devices.

Settings select Xcode, optional shared state/metadata paths, and a default hooks
file. Existing environment overrides are honored. Changing Xcode requires
restarting the app because private frameworks are loaded once per process.
The Edit menu provides **Paste into Simulator** (Shift-Command-V).

Display uses shared IOSurfaces and Metal. Only the focused simulator receives
keyboard input; agent-owned previews cannot receive input. Rendering is capped at
60 fps focused, 30 fps for other large tiles, and 5 fps for previews, with no redraw
when the framebuffer is unchanged. These are caps, not guaranteed device frame
rates. See [desktop compatibility](desktop/COMPATIBILITY.md) for tested coverage.

App builds are ad-hoc signed for local development. Public distribution requires
Developer ID signing and notarization for normal Gatekeeper installation; this
repository does not contain signing credentials.

Additional checks:

```sh
zig build test
zig build test-integration
```

The integration tests link a fake CoreSimulator inventory into a separate test
executable; they never claim or modify real simulators.
