# Agent notes

## Build

Requires Zig 0.16.0 and Xcode:

```sh
zig build -Doptimize=ReleaseSafe
zig build test
```

CI runs the same on `macos-15` via `.github/workflows/ci.yml`.

## Release

Preferred: run **Bump and Release** from the Actions tab and choose `patch`, `minor`, or `major` (`vMAJOR.MINOR.PATCH`). That workflow bumps `build.zig.zon` + `src/main.zig`, commits to `main`, tags, then runs the release pipeline.

Manual alternative:

1. Bump the version in `build.zig.zon` and the `simutex version` string in `src/main.zig`.
2. Merge to `main`, then tag and push (for example `v0.1.0`).
3. `.github/workflows/release.yml` builds the macOS arm64 binary, publishes a GitHub Release, and opens a squash-merged PR on [`sichengchen/homebrew-tap`](https://github.com/sichengchen/homebrew-tap) for `Formula/simutex.rb` (installs the release binary, no Zig/Xcode at `brew install` time).

The tag (`vMAJOR.MINOR.PATCH`) must match both version strings. The release workflow needs a `TAP_GITHUB_TOKEN` repository secret with access to the tap (`contents` + `pull requests`). Without it, the GitHub Release still publishes; the formula update is skipped.

Note: `GITHUB_TOKEN` pushes do not re-trigger workflows, so **Bump and Release** calls the release workflow directly after tagging.

Local source packaging / checksum helper:

```sh
./scripts/package-release.sh 0.1.0
```
