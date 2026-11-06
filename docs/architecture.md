# Architecture

Sign2Speak is a native SwiftUI iPhone app. The signing pipeline is camera → landmarks → sign candidates → accepted glosses → English sentence → local speech. The reverse pipeline is microphone → Apple on-device recognition → readable captions. Gemma receives accepted text glosses, not camera frames. A 50-label classifier and heuristic sign boundaries do not establish general or fluent ASL recognition.

## Components

| Component | Responsibility |
| --- | --- |
| `Sign2SpeakApp` / `AppRootView` | App entry, setup gate, shared controller and lifecycle notifications. |
| `ConversationView` / `ModelSetupView` | Signing/review UI and first-use download. System light/dark appearance is inherited. |
| `ConversationController` | Coordinates capture, generation, speech, cancellation and transient conversation state. |
| `CameraCapture` / `CameraPreview` | Serialized camera lifecycle and mirrored preview. Preview cropping does not change inference geometry. |
| `LandmarkProcessor` / `CameraModels` | CPU MediaPipe hand/face detection and bounded landmark windows. |
| `FeatureEncoder` | Builds the reference classifier's `[1, 64, 708]` float32 tensor. |
| `ContinuousSigning` | Candidate stability, acceptance, repeat handling and hands-absent completion. |
| `TrainedClassifierRunner` | TensorFlow Lite sign inference. Model bytes outlive the interpreter that borrows them. |
| `GemmaRunner` / `SentenceGeneration` | LiteRT-LM engine ownership, prompt policy, fresh conversations and resource measurements. |
| `ModelStore` / `ModelDownloadService` | Pinned hashes, bounded verification, installation and background Gemma transfer recovery. |
| `LocalSpeechDriver` / `SpeechModels` | Apple speech playback, stop, replay and interruption handling. |
| `LocalReplyRecognitionDriver` / `ReplyRecognition` / `ReplyCaptionView` | Microphone capture, on-device English transcription, live caption sheet and typed lifecycle events. |
| `DiagnosticsView` / `DiagnosticsReport` | Developer controls and bounded, text-redacted measurements. |
| `ClassifierRunner` / `ClassifierFixture` | Arithmetic runtime diagnostics, separate from sign recognition. |

## Session flow

1. At startup, the app looks for the installed Gemma model. If absent, setup presents Download/progress/retry. The smaller recognition assets are provisioned before building, as described in the [README](../README.md#model-assets).
2. Starting signing releases any diagnostic Gemma engine, initializes camera/landmark/classifier resources, and begins bounded continuous capture. Frames are processed synchronously on the capture queue; UI feedback is delivered to the main actor.
3. The recognition state machine shows tentative candidates before acceptance. The current policy requires a score of at least 0.60, a top-two margin of 0.20 and stable predictions. Scores are not calibrated accuracy probabilities. Raw hand presence determines the end-of-utterance pause; its current value is two seconds in `ContinuousSigningPolicy`.
4. Accepted signs are collected in order. Continuous capture has duration/utterance bounds; absent hands before any sign do not create a sentence. Users may finish explicitly or correct accepted signs later.
5. Capture and landmark/classifier resources are released before sentence generation. Normal conversation uses GPU Gemma, a fresh conversation and the full interpreter prompt. Short inputs request 768 context tokens; longer corrections request 1024. Output is capped at 64 tokens. Separate diagnostic prompt/context experiments do not change this flow.
6. The engine is released before automatic speech begins. The result can be edited or replayed. New signing and edits invalidate stale results; Stop and interruptions suppress late generation/audio callbacks.

## Spoken reply flow

`ConversationController` reserves native-work exclusion before preparing recognition, waits for speech playback to stop and awaits a loaded diagnostic Gemma engine's release. The injected `ReplyRecognitionDriver` then requests permission, checks Apple's English on-device capability, configures the microphone and supplies partial text updates. The current adapter uses `SFSpeechRecognizer` across supported iOS versions, with `requiresOnDeviceRecognition = true`; there is no server fallback or SpeechAnalyzer adapter yet.

Partial hypotheses replace earlier text rather than appending repeated words. Stop ends microphone input and allows up to three seconds for final text, then cancels the recognizer and retains partial captions. Listening is bounded at 60 seconds/4,096 characters. Done/background/audio interruption/audio disconnection/memory pressure cancels capture and invalidates its session ID; late permission/results callbacks cannot start capture again or overwrite a later session. Cancellation while Gemma is unloading retains exclusion until the native release completes.

The reply sheet inherits system appearance, displays large selectable captions and offers Listen/Stop/Clear. Captions are memory-only and go directly to the signer; Gemma is not used to rewrite them. `replyRuns` is optional for old-report compatibility and stores bounded IDs, locale, timestamps, character counts and outcome metadata only. No audio files, transcript text or native recognition-error strings are written to diagnostics.

## Ownership and safety

`ConversationView` owns the UIKit idle-timer override. It disables inactivity sleep while the foreground conversation/review/caption surface is visible or session work is running, and restores the timer when inactive, removed, or showing an idle setup/about/diagnostic sheet. This supports hands-free signing and reading without changing system brightness or global Auto-Lock preferences.

The main-actor controller owns user-visible state. Native operations have request identities, watchdogs and cancellation/drain barriers: cancellation does not mean native work has already stopped. Keep resources alive until completion and prevent another native operation from overlapping teardown. Memory warnings retain cancellation protection and user-visible retry feedback.

No camera recordings or conversation text are uploaded. Frames and editable text are transient. Diagnostic exports retain bounded aggregate timings, model identity and resource observations; conversation inputs/outputs are redacted. Fixed nonprivate diagnostic prompts may retain outputs. A report's sampled process footprint is not total GPU/device memory or a guarantee against termination.

`AppStorage` uses `Sign2Speak` under Application Support and `Sign2SpeakRuntime` under Caches. Its legacy directory names are intentional migration inputs. Renaming preserves model/report/durable-download files without copying the large model. A failed rename falls back to the old location and retries on a later launch; an existing destination is not overwritten. This migration cannot cross app containers after a bundle-ID change.

## Build boundaries

- Xcode builds the Swift sources and bundles the storyboard, images, model manifest and four model binaries listed in the project.
- LiteRT-LM and MediaPipe are pinned remote packages. `Packages/TensorFlowLiteSwift` is a local source package; SwiftPM downloads its checksum-pinned framework. It is not a cache. Keep TensorFlowLite before LiteRTLM in framework link order.
- `Config/Signing.xcconfig` supplies shared defaults; its optional local include supplies private overrides. Git must exclude the local file.
- `tools/` and `tests/` are developer-only. The app does not execute Python/shell scripts or fetch build-time model assets. Gemma is the only model downloaded through the app's setup UI.
- Host tests and structural checks do not prove native linking or device behavior. Native builds and physical-device evaluation use Xcode; Simulator results are useful for UI, not resource acceptance.

## Further work

Measure first-load and subsequent-load resource use before adding warm-up or engine residency. Preserve cancellation protection. Evaluate held-out signers, unknown signs, segmentation/repeats and sentence meaning; compact prompts have shown semantic omissions. Performance improvements should be accepted only with measured memory/latency and language-quality evidence.
