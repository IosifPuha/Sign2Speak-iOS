# Third-party code and models

## Reference implementation

The [Sign2Speak Android reference project](https://github.com/Pirodax/Sign2Speak-GEMMA-4-GOOD-HACKATHON) inspired the feature contract, interpreter prompt and classifier integration. The classifier source path and exact integrity pins are recorded in [tools/model-assets.json](tools/model-assets.json).

The classifier binary is excluded from Git and fetched by explicit setup from the pinned upstream revision. Reference training data is not included.

## TensorFlow Lite Swift wrapper

The local wrapper retains upstream copyright headers, [Apache 2.0 license](Packages/TensorFlowLiteSwift/LICENSE), [notice](Packages/TensorFlowLiteSwift/NOTICE.md) and [provenance](Packages/TensorFlowLiteSwift/PROVENANCE.json). Its source is pinned to Readdle's TensorFlow Lite Swift 2.16.1 revision; the package downloads its original framework archive under the verified checksum recorded in its manifest. (This was needed due to the fact that the original upstream package definition contained a checksum that did not seem to match its published framework archive) Framework binaries are not committed.

## Google runtime and landmark assets

[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) and [MediaPipe](https://github.com/google-ai-edge/mediapipe) are resolved as pinned dependencies; retain their upstream licenses and notices when distributing the app. Google landmark artifact URLs, model cards and integrity pins are recorded in [tools/model-assets.json](tools/model-assets.json). Those binaries are obtained separately during source setup.

## Gemma

The app downloads the pinned `litert-community/gemma-4-E2B-it-litert-lm` artifact from Hugging Face at runtime. Gemma weights are not included in the repository.