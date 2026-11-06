# MeetingNoteTaker development and delivery

## Platform and toolchain

The runtime baseline is **macOS 26.0 and Apple Silicon (arm64)**. Build scripts select **Xcode 27** for the current process; CI pins Xcode 27.1 on the `xcode-27` runner. The SDK/build-host version is separate from the deployment target. Existing Swift language mode is defined in [Package.swift](../Package.swift).

The two projects are self-contained repositories with matching script conventions. Neither requires the other repository to build. [build-env.sh](../scripts/build-env.sh) honors `DEVELOPER_DIR`, validates Xcode, and provides tool locations without changing global `xcode-select` or replacing the test runtime's PATH. Compiler commands use `xcrun`.

## Local commands

Run from the project root:

```sh
bash scripts/test.sh
python3 -m unittest discover -s Tests/ReleaseChecks -v
bash scripts/build-app.sh release
bash scripts/package-release.sh v0.1.0
```

Use the version matching the built app when packaging. `build-app.sh [debug|release]` defaults to release; the argument takes precedence over `CONFIGURATION`. `test.sh` forwards Swift test arguments, for example `--filter SomeTest`, and still performs its additional app-specific checks. `SWIFT_BUILD_JOBS` limits Swift build concurrency.

The native build compiles bundled Whisper and llama.cpp helpers before the Swift app. `test.sh` also runs isolated menu sizing, Settings presentation, shortcut-reference and global-shortcut checks. Optional model/performance tests require explicit existing fixtures; they are not downloaded by the test command.

## Build and release components

| Script | Responsibility |
| --- | --- |
| [build-env.sh](../scripts/build-env.sh) | Process-local Xcode selection and tool discovery |
| [test.sh](../scripts/test.sh) | Swift suites and application-specific verification |
| [build-app.sh](../scripts/build-app.sh) | Compile, assemble resources, sign, validate and replace the app |
| [validate-platform.py](../scripts/validate-platform.py) | Enforce macOS 26.0 metadata and arm64 deployment targets for bundled binaries |
| [release-version.py](../scripts/release-version.py) | Validate version tags and stamp bundle version metadata |
| [replace-directory.sh](../scripts/replace-directory.sh) | Replace generated output with rollback and backup preservation on failure |
| [package-release.sh](../scripts/package-release.sh) | Validate, optionally notarize, archive and checksum a staged release |
| [ci-signing.sh](../scripts/ci-signing.sh) | Import temporary signing credentials only in trusted hosted tag jobs |

Build output is `dist/MeetingNoteTaker.app`. Local release assets are under `dist/release/`; intermediate build and test outputs are under `.build/` and `build/`. These are generated outputs, not sources of application data.

## Signing and automation

Local builds default to ad-hoc signing. For notarization, configure `RELEASE_SIGNING=notarized`, a Developer ID Application `SIGNING_IDENTITY`, and an existing `NOTARY_PROFILE`. `NOTARY_KEYCHAIN` is optional locally. Build first, then package with the same release mode. No credentials belong in source files, documentation or logs.

The [GitHub workflow](../.github/workflows/release.yml) runs checks and builds for configured branch pushes and pull requests. Version tags matching the validated `vX.X.X` convention drive release publication. Signing/notarization requires repository configuration and credentials; the scripts do not create those accounts or credentials. Packaging stages a complete archive/checksum set before replacing prior local release assets. A successful local build is not evidence that hosted CI or notarization has run.

## Validation expectations

Before delivery, run the relevant Swift and release checks, verify the app's platform and signature, and check packaged archive checksums. Test failed writes/replacements and malformed input when changing storage or packaging. Keep hardware checks distinct from deterministic fixtures and optional tests; record skipped tests, OS/runtime failures and missing credentials explicitly.

Documentation-only changes need source/link review rather than an app rebuild. Update [Architecture](Architecture.md) and [Components](Components.md) when responsibilities, storage or processing boundaries change.

### FluidAudio ASR-only builds

The package uses Swift tools 6.2 dependency traits to pin FluidAudio 0.18.2 with no optional traits. When upgrading an existing checkout, obsolete `CNemoTextProcessing` headers in `.build/out/Products/{Debug,Release}/include` can make `canImport` succeed even though NeMo is no longer linked. Remove these generated header directories and run `swift package clean` before rebuilding if unresolved `_nemo_*` symbols appear. Do not change dependency sources or re-enable NeMo to mask stale output.

`InMemoryTranscriptionTests` covers direct samples, file fallback/cleanup, source offsets, partial chunks, echo ordering, silence, cancellation and checkpoint recovery. `ParakeetSampleIntegrationTests` checks the ASR-only configuration and provides offline file/sample comparisons for installed models. Supply `MNT_PARAKEET_V2_MODEL`, `MNT_PARAKEET_V3_MODEL` or `MNT_PARAKEET_ULTRA_MODEL` plus `MNT_TEST_AUDIO`; multilingual checks also require `MNT_FRENCH_TEST_AUDIO`. Missing fixtures produce explicit skips. These tests never download models and do not measure transcription speed.

Upgrade validation on 2026-11-01: the consolidated suite ran 114 tests with 11 optional skips and no failures; menu/Settings/shortcut checks and 17 release checks passed. The ad-hoc signed app and all three helpers passed macOS 26.0 / arm64 validation. The release binary excludes native NeMo and optional TTS/diarization managers, and contains no TTS resource bundle; upstream shared model metadata types remain. Required dependency licenses are bundled. Allocated app size (`du -sk`) changed from 47,844 to 33,876 KiB. Rebuilding caches prevents a meaningful before/after build-time comparison; no inference-speed measurement was performed. Parakeet v2/v3/Ultra English/French recognition and timing parity remain unverified without local model/audio fixtures; no weights were downloaded.

### Download resume regressions

The consolidated suite includes the pinned FluidAudio downloader's HTTP fixture tests (adapted under its Apache-2.0 license), plus app-level incomplete-model checks. These exercise the actual upstream `FileDownloader` through an in-process URLProtocol server: dropped/stalled transfers, cancellation with retained partial bytes, persisted partial data in a new invocation, Range/If-Range offsets, changed ETags, servers ignoring Range, HTTP 416 recovery and truncated artifacts. Fixtures are tiny and require no network or model weights. Persisted-state tests simulate restart; they do not terminate/relaunch the application or exercise a live Hugging Face connection.

Parakeet downloads retain their stable destination and use FluidAudio's default `force: false`. Retry is explicit. Structural model validation rejects missing Core ML metadata and bundles containing `.partial` files, preserving those files for retry. Downloading does not activate a model; runtime loading still validates actual model compatibility.

### Parakeet speech recovery

Parakeet explicitly enables gap repair, a 0.5-second minimum gap and seam-timing correction. The consolidated test command includes 35 upstream gap-repair cases and 11 seam-timing cases from FluidAudio 0.18.2 (Apache-2.0 attribution retained). They cover leading gaps, partial words, silence/quiet speech, duplicate suppression and timing consistency without loading models. The configuration regression checks the settings passed by our provider.

These are algorithm/pipeline regressions, not measurements of recognition accuracy. Before changing chunking, perform an enabled/disabled comparison with the same installed model and English/French audio, reference transcripts and current independent 25-second jobs. Include immediate opening speech, quiet phrases, silence, speech crossing 25-second boundaries and a final chunk under 15 seconds. Record omitted/substituted/inserted words against the reference, duplicated phrases, invalid or out-of-range timestamps, elapsed time and peak process memory for both runs. Use identical preprocessing and model assets, record model/version and hardware, and alternate run order to reduce warm-up bias. Missing fixtures must be reported as unavailable; do not download models automatically or claim an accuracy/speed improvement from these unit tests.


### Recording menu responsiveness

On 2026-11-03, capture discovery, health checks and device lifecycle moved to a dedicated serial executor. The main-actor interface orders commands across asynchronous permission requests and forwards presentation updates. `AudioLevelState` isolates the meters from the shared application model; unchanged health presentation and menu dimensions no longer trigger unnecessary UI work.

An optimized temporary native menu harness supplied 100 meter pairs at 10 Hz over ten seconds using the production menu and a mock recording model. Before the change: 100 full menu-body evaluations and 100 sizing-view updates. After: zero of either; the meter views still receive updates. Neither version changed the window frame. The synthetic test did not reproduce the reported live-recording stall, so these counts demonstrate eliminated work, not a measured improvement in real-call interaction latency.

`CaptureControlTests` verifies that a simulated blocking audio-service call leaves the main actor usable, that pause/resume/stop cannot overtake a suspended start, and that failed commands do not prevent stop. Health checks preserve warnings, recovery, paused state and dropped-buffer reports while ignoring raw timestamps and free-byte counters. Native menu checks confirm 100 meter updates produce no shared-model invalidations and retain existing layouts, Settings reopening and shortcut behavior.

Validation: 194 core tests, 13 optional model/fixture/benchmark skips, no failures; 17 release checks and the consolidated menu/Settings/shortcut checks passed. Live microphone/computer capture, permission prompts, Bluetooth/hotplug and menu interaction latency during an actual meeting remain manual smoke-test requirements. No user audio was recorded or model weights downloaded for this change.


### Seekable playback validation

`MeetingPlaybackTests` covers seek clamping, stopped and playing scrubs, Stop/reset, completion/replay, rapid selection and stale loads, release, time labels, corrupt files and loading/seeking a generated silent audio file without autoplay. Transport state tests use an injected player, so they do not depend on an audio output device. Native light/dark control snapshots are written to `.build/playback-light.png` and `.build/playback-dark.png`. Real-device audible playback and manual VoiceOver/keyboard interactions remain smoke tests; automated checks do not claim these passed.


### Source recovery validation

`SourceRecoveryTests` exercises notification coalescing, bounded backoff after successful-but-empty starts, ten-second recovery stability, independent source budgets, rate-limited reconnect attempts, pinned microphone identity across device-ID changes, accepted versus rejected buffers, empty-capture preservation, partial stereo export and backward-compatible diagnostics. The existing pause/silence regression uses valid silent packets; empty streams are now explicitly rejected.

Capture journals record attempt durations and slow (100 ms or longer) audio checkpoint synchronization. These contain no spoken content and are excluded from rendered transcripts. During live investigation, correlate these events with app/coreaudiod/WindowServer sampling and disk activity. USB unplug/replug, headset profile changes, application relaunch, permissions and OS-wide lag require live device validation; simulated tests do not prove those integration behaviors or an OS-lag fix. No device settings or existing recordings are changed by the automated suite.
