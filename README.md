# Sign2Speak-iOS
iOS native application inspired by Pirodax's writeup for the Gemma 4 Good Hackathon (see https://github.com/Pirodax/Sign2Speak-GEMMA-4-GOOD-HACKATHON).

The app turns a small vocabulary of ASL signs into spoken English, using on-device models. Start signing, review the detected words, then lower your hands to finish the utterance. The signer can correct the words or sentence and replay or stop speech. The signer can tap **Let the hearing person speak** to show spoken English as large live captions for the signer.

The current vocabulary contains 50 signs. Recognition, sentence quality, speed and memory use are still being evaluated; this is an MVP rather than general ASL translation. Camera frames and conversation text are not uploaded anywhere.

<img width="2605" height="1910" alt="image" src="https://github.com/user-attachments/assets/63024852-324b-43e1-95f1-86b6cee552b9" />

## Requirements

- macOS on Apple Silicon, full Xcode and its command-line tools, Python 3.9 or newer, and Git LFS.
- An iPhone running iOS 17 or newer for signing and performance testing. The arm64 iOS Simulator supports UI development; it does not establish camera/model performance.
- Internet access for initial dependencies and models, and space for the 2.59 GB Gemma download. Personal Apple signing is needed for physical-device builds.

## Build and run

1. Clone this repository. From the repository root, download and prepare the bundled recognition models:

   ```sh
   python3 tools/prepare_models.py --download
   python3 tools/check_checkout.py
   ```

   This downloads and verifies the pinned classifier and two Google landmark models, and generates the small diagnostic fixture. It does not install Python packages or download Gemma. Model binaries remain ignored by Git.

2. For a physical iPhone, copy the signing template and enter your own team and unique bundle identifier in the local file:

   ```sh
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```

   Skip this step for the Simulator. `Signing.xcconfig` is shared; `Signing.local.xcconfig` is private and overrides it.

3. Install Git LFS if needed (for example, `brew install git-lfs`). Quit Xcode, then open the project through the launcher:

   ```sh
   sh tools/open-xcode.command
   ```

   The launcher exposes Git LFS and skips unrelated LiteRT-LM LFS prebuilts. Xcode still downloads and verifies the required Apple frameworks. It does not change global Git settings or quit Xcode for you.

4. Select the **Sign2Speak** scheme and an iPhone or arm64 Simulator, then press **⌘R**. If packages need resolving, use **File → Packages → Resolve Package Versions**. Keep TensorFlowLite before LiteRTLM in the target's framework link order.
5. On first use, tap **Download** to install Gemma. On an iPhone, grant camera permission and tap **Start signing**. Lowering your hands for the configured pause finishes the utterance; **Finish now** is also available once signs have been collected.

## Spoken replies

The conversation and caption screens keep the display awake while the app is in the foreground, including when reading completed text. Normal Auto-Lock resumes on idle setup/about/diagnostics screens and when leaving the app. Active capture/generation/playback/transcription also keeps the screen awake while viewing diagnostics. The device's manual lock and brightness controls remain available.

After setup, tap **Let the hearing person speak** on the conversation screen. Allow Speech Recognition and Microphone access when prompted. Captions update as the listener speaks; **Stop listening** finalizes the reply, **Clear** removes it, and **Done** closes the sheet and stops capture. A previous reply can be reopened with **Read spoken reply**. Listening stops after one minute or 4,096 characters; the latest text remains readable.

This first implementation uses Apple's `SFSpeechRecognizer` with on-device recognition required, starting with en-US. If local recognition is unavailable, the app shows an error rather than using server recognition. Availability depends on the device and installed language support; test on the physical iPhone, including airplane mode after setup. Model setup and Simulator UI checks do not establish speech-recognition availability.

Captions are not sent to Gemma, saved as recordings, or included in reports. They remain in memory until cleared or the app process ends. Camera/native inference and playback are excluded while preparing/listening; playback and any loaded diagnostic Gemma engine are released before microphone capture. Closing the sheet, backgrounding, interruptions, a disconnected audio device or a memory warning cancels capture without automatic restart. On iOS 26+, a future `SpeechAnalyzer` adapter can reuse this driver boundary; it is not implemented in this version.

## Model assets

The source checkout deliberately contains no model binaries. The four bundled files under `Sign2Speak/Models/` must exist before an Xcode build; their names, sizes and SHA-256 hashes are recorded in [the asset manifest](tools/model-assets.json).

| Asset | Provisioning |
| --- | --- |
| Hand and face landmark `.task` files | Setup script downloads pinned Google artifacts and verifies each file. |
| `reference_classifier_v1.tflite` | Setup script downloads the pinned reference artifact and verifies it. For an existing copy, use `--classifier /path/to/classifier.tflite --download-landmarks` instead. |
| `classifier_fixture_v1.tflite` | Setup script generates the owned arithmetic fixture; it is not a sign-recognition model. |
| Gemma `.litertlm` | The app downloads and verifies it on first use. Do not add it to Git. |

The classifier comes from the [reference Android project](https://github.com/Pirodax/Sign2Speak-GEMMA-4-GOOD-HACKATHON). The binary remains outside Git and is fetched explicitly during setup. See [third-party notices](THIRD_PARTY_NOTICES.md).

To check installed build assets without downloads or writes:

```sh
python3 tools/prepare_models.py --verify
```

## Project layout

| Path | Purpose |
| --- | --- |
| `Sign2Speak/` | SwiftUI screens, camera/recognition, Gemma, speech and bundled UI assets. |
| `Sign2Speak.xcodeproj/` | Build settings, resources, package references, shared scheme and dependency lock. |
| `Config/` | Shared signing defaults and the private-settings template. |
| `Packages/TensorFlowLiteSwift/` | Local TensorFlow Lite source wrapper with a verified binary checksum; retain its license and notices. |
| `tools/` | Model setup, checkout checks, Xcode launcher and host-test entry point; never bundled into the app. |
| `tests/` | Host regression tests and synthetic/legacy fixtures, including reply-caption lifecycle/privacy checks. |
| [Architecture](docs/architecture.md) | Main components, data flow and development boundaries. |

## Development checks

```sh
zsh tools/run_app_checks.sh
PYTHONPATH=tools python3 -B -m unittest discover -s tests -p 'test_*.py'
```

These check host-side policy, storage migration, download integrity, reply-caption lifecycle/cancellation and privacy. They do not build iOS, resolve native packages or establish recognition/translation quality. Run `python3 tools/check_checkout.py --source-only` to inspect a source checkout before provisioning models.

The shared bundle ID defaults to `dev.sign2speak.app`. Existing development installations should retain their previous ID in the ignored local configuration and be updated with ⌘R. Changing the ID creates a separate app container; deleting the app removes its downloaded model. Storage directories migrate within the same container. Legacy names remain only where migration and backward-compatible report decoding require them.

## Current limits and licensing

Memory-pressure cancellation remains enabled, and some requests can require a retry on constrained devices. Normal signing uses the full interpreter prompt; compact prompt experiments are restricted to Diagnostics. Wider signer/device coverage, sustained resource use, offline cold launch and interruption recovery still need evaluation. TestFlight distribution is not configured in this repository.
