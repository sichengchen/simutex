# Agent notes

## Build

Requires Zig 0.16.0 and Xcode:

```sh
zig build -Doptimize=ReleaseSafe
zig build test
```

CI runs the same on `macos-15` via `.github/workflows/ci.yml`.

## Release

1. Bump the version in `build.zig.zon` and the `simutex version` string in `src/main.zig`.
2. Merge to `main`, then tag and push (for example `v0.1.0`).
3. `.github/workflows/release.yml` builds the release binary, publishes a GitHub Release, and opens a squash-merged PR on [`sichengchen/homebrew-tap`](https://github.com/sichengchen/homebrew-tap) for `Formula/simutex.rb`.

The tag (`vX.Y.Z`) must match both version strings. The release workflow needs a `TAP_GITHUB_TOKEN` repository secret with access to the tap (`contents` + `pull requests`). Without it, the GitHub Release still publishes; the formula update is skipped.

Local source packaging / checksum helper:

```sh
./scripts/package-release.sh 0.1.0
```
