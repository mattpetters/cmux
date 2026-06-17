# Spec: Upgrade cmux Zig toolchain for latest Xcode/macOS SDK linking

Date: 2026-05-31
Branch: `vis/zig-016-xcode-265-spec`
Status: Draft sizing spec

## Summary

Upgrade cmux's Zig-dependent build paths from Zig `0.15.2` to the latest stable Zig (`0.16.0`) and remove the current macOS 26/Xcode 26 helper-linking workaround if Zig 0.16 can link the Ghostty CLI helper against the latest Apple toolchain.

This is scoped as a toolchain/build-system migration first, not a product feature. The desired end state is that local tagged Debug builds, CI, nightly, and release builds can use the latest Xcode/macOS SDK for both the Swift app and Zig-built helper artifacts without stubbing or requiring a pre-26 Xcode.

## Version targets

- Zig: `0.16.0`
  - Official Zig download page lists `0.16.0` as a stable release.
  - Zig news page announces `0.16.0 Released` on 2026-04-14.
- Xcode: `26.5`
  - Apple Developer release page lists Xcode `26.5 (17F42)` on 2026-05-11.
  - Xcode 26.5 includes macOS 26.5 SDK and Swift 6.3.x.
- cmux Xcode pin: `.xcode-version` currently says `26.0`.
  - Proposed update: pin to `26.5` while keeping `cmux.xcodeproj/project.pbxproj` `objectVersion = 60` unless Xcode rewrites it during validation.

## Current state and problem

cmux currently pins Zig to `0.15.2` in:

- `scripts/install-zig-ci.sh`
- `scripts/build-ghostty-cli-helper.sh`

The repo has multiple explicit workarounds for Zig `0.15.2` not linking the Ghostty CLI helper against macOS SDK 26:

- `.github/workflows/ci-macos-compat.yml`
  - `skip_zig: true` for macOS 26 compatibility coverage.
- `.github/workflows/nightly.yml`
  - Selects two Xcodes: a macOS 26+ Xcode for the app and a pre-26 Xcode for the Zig helper.
  - Builds the real universal helper separately, then builds the app with `CMUX_SKIP_ZIG_BUILD=1`, then injects the helper.
- `.github/workflows/release.yml` and `.github/workflows/ci.yml`
  - Comments keep release/nightly paths on macOS 15 because release artifacts need a real helper.
- `docs/macos-ci-runners.md`
  - Documents that nightly/stable release stay on macOS 15 until Zig can link the real universal helper on macOS 26.
- `scripts/build-ghostty-cli-helper.sh`
  - Has comments and behavior around the `CMUX_SKIP_ZIG_BUILD=1` stub path.

Observed local failure with Xcode 26.5 + Zig 0.15.2:

- `scripts/build-ghostty-cli-helper.sh --target aarch64-macos ...` failed while linking with undefined symbols like `__availability_version_check`, `_abort`, `_arc4random_buf`, `_dispatch_queue_create`, and many other libSystem symbols.
- A tagged app build only succeeded after setting `CMUX_SKIP_ZIG_BUILD=1`, which creates a stub helper.

## Goals

1. Bump the Zig version used by cmux CI/build scripts to stable Zig `0.16.0`.
2. Verify the Ghostty CLI helper builds and links with only the latest Xcode/macOS SDK installed.
3. If Zig 0.16 fixes the link issue, remove or relax the pre-26-Xcode workaround from nightly/release/compat workflows.
4. Keep Debug, nightly, release, and GhosttyKit build paths consistent.
5. Update docs/comments so future agents do not cargo-cult the obsolete Zig 0.15.2 workaround.

## Non-goals

- Do not change Ghostty runtime behavior except what is required for Zig 0.16 build compatibility.
- Do not bump the Ghostty submodule unless the existing pinned Ghostty fork cannot build with Zig 0.16.
- Do not change cmux's Swift language mode or app architecture as part of this migration.
- Do not remove `CMUX_SKIP_ZIG_BUILD` entirely; it remains useful as an explicit escape hatch for CI compatibility or local app-only builds.

## Proposed implementation plan

### Phase 0: Toolchain spike

Size: S/M, roughly 0.5 day.

Tasks:

1. Install or download Zig `0.16.0` locally without replacing user state unnecessarily.
2. Run targeted helper builds in the worktree:
   - `scripts/build-ghostty-cli-helper.sh --target aarch64-macos --output /tmp/cmux-ghostty-helper-arm64`
   - `scripts/build-ghostty-cli-helper.sh --target x86_64-macos --output /tmp/cmux-ghostty-helper-x86_64`
   - `scripts/build-ghostty-cli-helper.sh --universal --output /tmp/cmux-ghostty-helper-universal`
3. Verify output architecture with `file` and `lipo -archs`.
4. If Zig 0.16 fails before linking, identify whether this is a Ghostty fork source-compatibility issue vs a cmux wrapper-script issue.

Exit criteria:

- We know whether Zig 0.16 can produce a real universal Ghostty helper against Xcode 26.5/macOS SDK 26.5.

### Phase 1: Script updates

Size: M, roughly 0.5-1 day if the spike is clean; larger if Ghostty needs source changes.

Likely edits:

- `scripts/install-zig-ci.sh`
  - Change default `ZIG_REQUIRED` from `0.15.2` to `0.16.0`.
  - Confirm download index lookup and minisign/SHA verification still work for 0.16 tarballs.
- `scripts/build-ghostty-cli-helper.sh`
  - Change default `ZIG_REQUIRED` to `0.16.0`.
  - Remove/update comments that are specifically about Zig 0.15.x cross-link failures.
  - Keep `CMUX_SKIP_ZIG_BUILD=1` as an opt-in stub escape hatch.
- `.xcode-version`
  - Update from `26.0` to `26.5` if the team wants patch-level pinning to match the latest Apple release.
- `scripts/check-pbxproj.sh`
  - Confirm Xcode major `26` still maps to `objectVersion = 60`.
  - No project file bump expected unless Xcode 26.5 rewrites the pbxproj differently.

Exit criteria:

- The scripts select Zig 0.16.0 by default.
- Existing override env vars still work (`ZIG_REQUIRED`, `CMUX_ZIG`, `CMUX_SKIP_ZIG_BUILD`).

### Phase 2: Workflow cleanup

Size: M, roughly 0.5-1 day.

Likely edits if Zig 0.16 links successfully on macOS SDK 26.5:

- `.github/workflows/ci-macos-compat.yml`
  - Remove `skip_zig: true` for macOS 26, or add a non-skipped macOS 26 lane.
- `.github/workflows/nightly.yml`
  - Simplify `Select Xcode`: no longer require a pre-26 helper Xcode.
  - Build helper under the same latest Xcode selected for the app.
  - Re-evaluate whether the separate helper build/inject step is still needed for universal release artifacts. It may remain useful, but should no longer depend on older Xcode.
- `.github/workflows/release.yml`
  - Move release build back to the latest macOS/Xcode runner if runner availability supports it.
  - Remove comments that say release must stay on macOS 15 because of Zig 0.15.2.
- `.github/workflows/ci.yml`, `.github/workflows/perf-activation.yml`
  - Remove stale comments and keep explicit `CMUX_SKIP_ZIG_BUILD=1` only where an app-only build is intentionally faster.

Exit criteria:

- CI no longer documents or encodes a mandatory pre-26-Xcode helper link workaround.
- Release/nightly artifacts still include a real universal Ghostty helper.

### Phase 3: Docs and validation

Size: S/M, roughly 0.5 day.

Likely edits:

- `docs/macos-ci-runners.md`
  - Update runner guidance to say latest Xcode is supported for the helper, assuming validation passes.
- `AGENTS.md` / `CLAUDE.md`
  - Update any Zig/Xcode local-dev notes if behavior changes.
- `docs/ghostty-fork.md`
  - Add a merge-conflict note if Ghostty fork patches require Zig 0.16 compatibility edits.

Validation:

- Local, tagged Debug build:
  - `./scripts/reload.sh --tag zig-016-xcode-265`
  - Should build a real helper without `CMUX_SKIP_ZIG_BUILD=1`.
- Helper artifact checks:
  - `file <app>/Contents/Resources/bin/ghostty`
  - `lipo -archs <app>/Contents/Resources/bin/ghostty` for universal builds.
- CI:
  - Run the relevant macOS compatibility workflow with the non-skipped Zig lane.
  - Run release/nightly-equivalent build job or a dry-run variant if available.

## Risks and unknowns

1. Ghostty fork may not be Zig 0.16 source-compatible.
   - Mitigation: keep Phase 0 separate; if it fails at compile-time, split a Ghostty-fork compatibility PR before cmux workflow cleanup.
2. Zig 0.16 may fix arm64 native linking but still fail x86_64 cross-linking against macOS SDK 26.5.
   - Mitigation: validate `--universal`, not only arm64.
   - If x86_64 still fails, the release/nightly dual-Xcode workaround may need to remain for universal artifacts even after the version bump.
3. CI runner images may not have Xcode 26.5 installed everywhere yet.
   - Mitigation: keep version selection robust and fail with clear messages; do not hardcode one `/Applications/Xcode.app` path.
4. `.xcode-version` patch-level pinning may be stricter than the existing major-only policy.
   - Mitigation: explicitly decide whether `.xcode-version` should be `26.5` or remain `26.0` as a major pin. This spec proposes `26.5` because the request says latest Xcode.
5. Release artifact signing/notarization path is high stakes.
   - Mitigation: preserve the current helper injection step until a full release-equivalent build proves the simpler path produces the same artifact shape.

## Sizing

Overall estimated size: M/L.

Best case: 1-2 engineering days if Zig 0.16 builds the existing Ghostty fork cleanly and links universal helpers against Xcode 26.5.

Worst likely case: 3-5 engineering days if the Ghostty fork needs Zig 0.16 source migration or universal x86_64 cross-linking still fails and CI/release workflows need a more nuanced hybrid path.

Recommended execution sequence:

1. Land this spec PR as a planning artifact.
2. Open an implementation PR from a fresh branch or update this branch after the Phase 0 spike.
3. Keep workflow simplification behind proven helper artifacts, not assumptions.

## Acceptance criteria for the implementation PR

- `scripts/install-zig-ci.sh` installs/verifies Zig `0.16.0` by default.
- `scripts/build-ghostty-cli-helper.sh` requires/selects Zig `0.16.0` by default.
- On a machine with only Xcode 26.5/macOS SDK 26.5, the Ghostty helper builds without `CMUX_SKIP_ZIG_BUILD=1`.
- `./scripts/reload.sh --tag zig-016-xcode-265` produces an app whose bundled `Contents/Resources/bin/ghostty` is a real executable, not the stub.
- Universal helper builds contain both `arm64` and `x86_64` slices.
- CI/nightly/release comments no longer claim Zig 0.15.2 constraints after the project no longer uses Zig 0.15.2.
- Docs reflect the new supported toolchain.
