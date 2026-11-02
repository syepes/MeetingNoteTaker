# MeetingNoteTaker components

## Component map

This map groups responsibilities rather than listing every type. Links point to representative implementation entry points; follow their dependencies for details.

| Component | Responsibility | Source entry points |
| --- | --- | --- |
| Application and coordination | Menu bar scenes, notebook, settings, recording/job lifecycle | [AppModel.swift](../Sources/MeetingNoteTaker/AppModel.swift) · [MeetingNoteTakerApp.swift](../Sources/MeetingNoteTaker/MeetingNoteTakerApp.swift) |
| Menu and shortcuts | Status, meters, global recording actions and shortcut reference | [MenuPanel.swift](../Sources/MeetingNoteTaker/MenuPanel.swift) · [GlobalHotkey.swift](../Sources/MeetingNoteTaker/GlobalHotkey.swift) |
| Settings and model UI | Provider configuration, installed/active models and authentication forms | [SettingsView.swift](../Sources/MeetingNoteTaker/SettingsView.swift) · [ModelsView.swift](../Sources/MeetingNoteTaker/ModelsView.swift) |
| Profiles and prompts | Profile persistence, revisions, snapshots and analysis instructions | [MeetingProfiles.swift](../Sources/MeetingCore/MeetingProfiles.swift) · [Prompts.swift](../Sources/MeetingCore/Prompts.swift) |
| Domain and persistence | Session/settings structures, atomic stores, filename reservation and retention | [Domain.swift](../Sources/MeetingCore/Domain.swift) · [Storage.swift](../Sources/MeetingCore/Storage.swift) |
| Capture and buffering | Microphone/process-tap capture, cached device discovery, visibility-gated meters, bounded batched writes and C++ audio buffering | [AudioCapture.swift](../Sources/MeetingCore/AudioCapture.swift) · [AudioDSP.cpp](../Sources/AudioDSP/AudioDSP.cpp) |
| Audio finalization | Timeline alignment, source channels, echo reduction and audio files | [AudioFiles.swift](../Sources/MeetingCore/AudioFiles.swift) · [CaptureHealth.swift](../Sources/MeetingCore/CaptureHealth.swift) |
| Processing orchestration | Transcription/analysis sequencing, cancellation ownership and progress | [Pipeline.swift](../Sources/MeetingCore/Pipeline.swift) · [Processing.swift](../Sources/MeetingCore/Processing.swift) |
| Transcription engines | Whisper, Parakeet/FluidAudio, Apple Speech and remote providers | [Transcription.swift](../Sources/MeetingCore/Transcription.swift) · [WhisperWorker.swift](../Sources/MeetingCore/WhisperWorker.swift) |
| Analysis engines | Built-in llama.cpp, Ollama and OpenAI-compatible generation; validation and chunking | [Analysis.swift](../Sources/MeetingCore/Analysis.swift) · [AnalysisModelCatalog.swift](../Sources/MeetingCore/AnalysisModelCatalog.swift) |
| Models and networking | Model validation/downloads plus endpoint authentication | [Models.swift](../Sources/MeetingCore/Models.swift) · [ServerAuthentication.swift](../Sources/MeetingCore/ServerAuthentication.swift) |
| Markdown and viewing | Generated sections, evidence links, parsing, snapshots and native display | [Markdown.swift](../Sources/MeetingCore/Markdown.swift) · [MeetingDocumentReader.swift](../Sources/MeetingCore/MeetingDocumentReader.swift) |

## Dependency boundaries

The UI depends on MeetingCore; MeetingCore depends on AudioDSP, FluidAudio and Swift Markdown. Whisper and llama.cpp are separate bundled native processes built by the native-helper script. Apple frameworks supply capture, speech assets, playback, Keychain and UI integration. The package and helper build script pin third-party versions; do not duplicate version decisions in UI code.

TranscriptionProvider and AnalysisProvider are the main inference extension points. Session snapshots, prompt provenance and exporter validation connect their output to durable files. The viewer consumes saved Markdown rather than requiring audio or a loaded model.

Parakeet additionally implements `InMemoryTranscriptionProvider`, accepting mono 16 kHz floating-point samples with source, meeting offset and chunk duration. Its file entry point delegates to the same decoder-state and result-conversion path. Model preparation remains offline through `AsrModels.loadLocal`; downloads remain explicit model-management actions.

FluidAudio is pinned to **0.18.2** (`e396cf780c4abf8e395087467c0585d3b0d17f68`) with `traits: []`. This excludes optional TTS, Diarizer and NeMo text-normalization code/resources while retaining ASR/VAD. Swift tools 6.2+ are required for dependency traits; the app retains Swift 5 language mode, Xcode 27 and the macOS 26 deployment target.

## Change and validation guide

| Change | Review alongside the implementation |
| --- | --- |
| New user action or shortcut | Menu availability, command routing, Settings/reference text and cancellation behavior |
| Persisted model or file format | Decoding of existing data, atomic writes, recovery and documentation |
| Background processing | Ownership, cancellation, bounded resources and late-result protection |
| New output or integration | Permissions, data leaving the app, failure reporting and source validation |
| Toolchain or packaging | Deployment target, architecture, signatures, helper/resource inclusion and CI |

Use [Architecture](Architecture.md) for the end-to-end flows and [Development](Development.md) for commands. Existing tests are behavior checks, not a substitute for live hardware and permission testing.

Meeting management additionally uses `SessionStore.trashMeeting` for resumable Trash operations and [MeetingSearch.swift](../Sources/MeetingCore/MeetingSearch.swift) for background content filtering. `MeetingSession.deletionRequestedAt` is optional for compatibility with existing history. The document reader can clear its snapshot and invalidate pending reads after a selected meeting is deleted.
