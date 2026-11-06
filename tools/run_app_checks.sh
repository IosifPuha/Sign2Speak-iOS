#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 tools/prepare_models.py --fixture-only
mkdir -p .build/ModuleCache
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
swiftc_path=$(xcrun --find swiftc)
"$swiftc_path" -sdk "$sdk_path" -module-cache-path .build/ModuleCache \
  Sign2Speak/AppError.swift Sign2Speak/ModelStore.swift \
  Sign2Speak/SentenceGeneration.swift Sign2Speak/CameraModels.swift \
  Sign2Speak/ContinuousSigning.swift Sign2Speak/SpeechModels.swift Sign2Speak/ReplyRecognition.swift \
  Sign2Speak/DiagnosticsReport.swift Sign2Speak/ModelDownloadService.swift \
  Sign2Speak/FeatureEncoder.swift Sign2Speak/ClassifierFixture.swift \
  Sign2Speak/ConversationController.swift tests/app_checks.swift tests/reply_checks.swift -o .build/app-checks
.build/app-checks "$@"
