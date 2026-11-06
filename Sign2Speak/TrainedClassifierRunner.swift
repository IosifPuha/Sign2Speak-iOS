import Foundation
import TensorFlowLite

// Native runtime smoke test and verified one-shot inference helper. Camera
// candidates use the host-checked contract; cadence/recognition remain unvalidated.
actor TrainedClassifierRunner: ClassifierDriver {
    private var activeID: UUID?
    private var stopReason: String?

    func stop(id: UUID, reason: String) {
        guard activeID == id, stopReason == nil else { return }
        stopReason = reason
    }

    private func checkStop() throws {
        try Task.checkCancellation()
        if stopReason != nil { throw CancellationError() }
    }

    func run(id: UUID, progress: @escaping @Sendable (ClassifierProgress) async -> Void) async -> ClassifierMeasurement {
        var measurement = ClassifierMeasurement(id: id)
        measurement.fixtureFilename = "reference_classifier_v1.tflite"
        measurement.fixtureBytes = 7_057_180
        measurement.fixtureSHA256 = "08d0af17c7dcf3a690b9228415513ded5452d3fcd1889ef9268db659e3fc1bcb"
        measurement.plannedCases = 0 // No expected-output numerical comparisons in this diagnostic.
        measurement.trainedValidation = ClassifierValidationMeasurement()
        guard activeID == nil else {
            measurement.outcome = "failed"
            measurement.error = "Trained classifier runner is already active."
            measurement.endedAt = Date()
            return measurement
        }
        activeID = id
        stopReason = nil
        let started = ProcessInfo.processInfo.systemUptime
        defer { activeID = nil; stopReason = nil }
        var interpreter: Interpreter?
        var retainedModelBytes: Data?
        // The pinned Swift wrapper does not retain Model in Interpreter. Its
        // borrowed bytes must survive normal/error/cancel interpreter destruction.
        defer {
            interpreter = nil
            withExtendedLifetime(retainedModelBytes) {}
        }
        func release() {
            guard interpreter != nil else { return }
            autoreleasepool { interpreter = nil }
            measurement.completedReleases += 1
        }
        do {
            await progress(.stage("verifying trained classifier and metadata"))
            try checkStop()
            guard let url = Bundle.main.url(forResource: "reference_classifier_v1", withExtension: "tflite"),
                  let manifestURL = Bundle.main.url(forResource: "reference_classifier_v1", withExtension: "json") else {
                throw AppError.invalidModel("Bundled trained classifier or manifest is missing. Rebuild the app.")
            }
            let manifest = try JSONDecoder().decode(TrainedClassifierManifest.self, from: Data(contentsOf: manifestURL))
            // Pin the manifest to the audited artifact, independently of its own claims.
            guard manifest.modelSHA256 == measurement.fixtureSHA256,
                  manifest.modelBytes == measurement.fixtureBytes,
                  manifest.outputSemantics == "logits" else { throw EncoderError.invalidLayout }
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == manifest.modelBytes else {
                throw EncoderError.invalidLayout
            }
            let bytes = try Data(contentsOf: url)
            try manifest.verify(bytes)
            retainedModelBytes = bytes
            measurement.integrityVerified = true
            measurement.nativeRuntimeVersion = Runtime.version
            await progress(.measurement(measurement))
            var baseline: [String: [Float]] = [:]
            for pass in 1...2 {
                await progress(.stage("loading trained classifier pass \(pass)"))
                try checkStop()
                let loadStarted = ProcessInfo.processInfo.systemUptime
                try autoreleasepool {
                    var options = Interpreter.Options()
                    options.threadCount = 1
                    options.isXNNPackEnabled = false
                    interpreter = try Interpreter(modelData: bytes, options: options)
                    try interpreter!.allocateTensors()
                    guard interpreter!.inputTensorCount == 1, interpreter!.outputTensorCount == 1 else {
                        throw EncoderError.invalidLayout
                    }
                    try validate(interpreter!.input(at: 0), input: true)
                    // Dynamic output storage may be unavailable until the first invoke.
                }
                measurement.loadSeconds.append(ProcessInfo.processInfo.systemUptime - loadStarted)
                await progress(.measurement(measurement))
                for repetition in 1...2 {
                    for recipe in ClassifierFixture.recipes {
                        await progress(.stage("trained classifier pass \(pass), \(recipe), repeat \(repetition)"))
                        try checkStop()
                        let item: ClassifierValidationCase = try autoreleasepool {
                            try interpreter!.copy(ClassifierFixture.input(recipe: recipe), toInputAt: 0)
                            let invokeStarted = ProcessInfo.processInfo.systemUptime
                            try interpreter!.invoke()
                            let seconds = ProcessInfo.processInfo.systemUptime - invokeStarted
                            let tensor = try interpreter!.output(at: 0)
                            try validate(tensor, input: false)
                            measurement.tensorContractVerified = true
                            let values = tensor.data.withUnsafeBytes { raw in
                                (0..<50).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
                            }
                            let candidates = try manifest.candidates(values)
                            let error = baseline[recipe].map { prior in
                                zip(prior, values).map { abs(Double($0) - Double($1)) }.max() ?? 0
                            }
                            if baseline[recipe] == nil { baseline[recipe] = values }
                            return ClassifierValidationCase(pass: pass, repetition: repetition, recipe: recipe,
                                                    invokeSeconds: seconds, maximumRepeatAbsoluteError: error,
                                                    candidates: candidates)
                        }
                        measurement.trainedValidation?.cases.append(item)
                        await progress(.measurement(measurement))
                        try checkStop()
                    }
                }
                release()
                await progress(.stage("trained classifier released pass \(pass); observing memory"))
                await progress(.measurement(measurement))
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try checkStop()
            }
            measurement.outcome = "completed runtime smoke test; numerical parity and recognition unverified"
        } catch {
            measurement.outcome = stopReason ?? "failed"
            measurement.error = String(describing: error)
        }
        release()
        await progress(.stage("trained classifier resources released"))
        measurement.outcome = stopReason ?? measurement.outcome
        measurement.endedAt = Date()
        measurement.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        return measurement
    }

    private func validate(_ tensor: Tensor, input: Bool) throws {
        guard tensor.dataType == .float32,
              tensor.shape.dimensions == (input ? [1, 64, 708] : [1, 50]),
              tensor.data.count == (input ? 181_248 : 200) else { throw EncoderError.invalidLayout }
    }

    func classify(modelURL: URL, manifest: TrainedClassifierManifest,
                  features: FeatureEncoder.Encoded) throws -> CameraInference {
        guard activeID == nil else { throw AppError.invalidState }
        try Task.checkCancellation()
        try manifest.validate()
        guard (3...64).contains(features.validFrames), features.handFrames > 0,
              features.values.count == 64 * 708, features.values.allSatisfy(\.isFinite) else {
            throw EncoderError.invalidLayout
        }
        // Verify the exact bytes passed to the native runtime, not a path that can
        // change between hashing and loading. File size is checked before allocation.
        guard try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == manifest.modelBytes else {
            throw AppError.invalidModel("Trained classifier size does not match its manifest.")
        }
        let bytes = try Data(contentsOf: modelURL)
        defer { withExtendedLifetime(bytes) {} }
        try manifest.verify(bytes)
        try Task.checkCancellation()
        return try autoreleasepool {
            let loadStarted = ProcessInfo.processInfo.systemUptime
            var options = Interpreter.Options()
            options.threadCount = 1
            options.isXNNPackEnabled = false
            let interpreter = try Interpreter(modelData: bytes, options: options)
            try interpreter.allocateTensors()
            guard interpreter.inputTensorCount == 1, interpreter.outputTensorCount == 1 else {
                throw EncoderError.invalidLayout
            }
            let input = try interpreter.input(at: 0)
            guard input.dataType == .float32, input.shape.dimensions == [1, 64, 708],
                  input.data.count == 181_248 else {
                throw EncoderError.invalidLayout
            }
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStarted
            try interpreter.copy(features.data, toInputAt: 0)
            try Task.checkCancellation()
            let invokeStarted = ProcessInfo.processInfo.systemUptime
            try interpreter.invoke()
            let invokeSeconds = ProcessInfo.processInfo.systemUptime - invokeStarted
            try Task.checkCancellation()
            let result = try interpreter.output(at: 0)
            guard result.dataType == .float32, result.shape.dimensions == [1, 50],
                  result.data.count == 200 else { throw EncoderError.invalidLayout }
            let values = result.data.withUnsafeBytes { raw in
                (0..<50).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            return CameraInference(candidates: try manifest.candidates(values), loadSeconds: loadSeconds,
                                   invokeSeconds: invokeSeconds)
        }
    }
}

// Created, invoked and released only on CameraCapture's serial queue. Vision and
// classifier calls are sequential; Gemma remains excluded for the entire session.
final class ContinuousClassifier {
    private var interpreter: Interpreter?
    private let modelBytes: Data
    private let manifest: TrainedClassifierManifest
    var runtimeVersion: String { Runtime.version }
    var modelSHA256: String { manifest.modelSHA256 }

    init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: "reference_classifier_v1", withExtension: "tflite"),
              let manifestURL = bundle.url(forResource: "reference_classifier_v1", withExtension: "json") else {
            throw AppError.invalidModel("Bundled classifier is missing.")
        }
        manifest = try JSONDecoder().decode(TrainedClassifierManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        guard manifest.modelSHA256 == "08d0af17c7dcf3a690b9228415513ded5452d3fcd1889ef9268db659e3fc1bcb",
              manifest.modelBytes == 7_057_180, manifest.outputSemantics == "logits",
              try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == manifest.modelBytes else {
            throw EncoderError.invalidLayout
        }
        modelBytes = try Data(contentsOf: modelURL)
        try manifest.verify(modelBytes)
        var options = Interpreter.Options()
        options.threadCount = 1
        options.isXNNPackEnabled = false
        let candidate = try Interpreter(modelData: modelBytes, options: options)
        try candidate.allocateTensors()
        guard candidate.inputTensorCount == 1, candidate.outputTensorCount == 1 else {
            throw EncoderError.invalidLayout
        }
        let input = try candidate.input(at: 0)
        // The pinned Swift wrapper exposes output only after invoke(). Validate
        // the output contract in classify(), before any candidate is returned.
        guard input.dataType == .float32, input.shape.dimensions == [1, 64, 708], input.data.count == 181_248 else {
            throw EncoderError.invalidLayout
        }
        interpreter = candidate
    }

    deinit {
        // Destroy native users before releasing their borrowed model buffer.
        interpreter = nil
        withExtendedLifetime(modelBytes) {}
    }

    func classify(_ features: FeatureEncoder.Encoded) throws -> CameraInference {
        guard let interpreter else { throw AppError.invalidState }
        guard (3...64).contains(features.validFrames), features.handFrames >= 6,
              features.values.count == 64 * 708, features.values.allSatisfy(\.isFinite) else {
            throw EncoderError.invalidLayout
        }
        return try autoreleasepool {
            try interpreter.copy(features.data, toInputAt: 0)
            let start = ProcessInfo.processInfo.systemUptime
            try interpreter.invoke()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let output = try interpreter.output(at: 0)
            guard output.dataType == .float32, output.shape.dimensions == [1, 50], output.data.count == 200 else {
                throw EncoderError.invalidLayout
            }
            let values = output.data.withUnsafeBytes { raw in
                (0..<50).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
            return CameraInference(candidates: try manifest.candidates(values), loadSeconds: 0, invokeSeconds: elapsed)
        }
    }
}

// One capture, one invocation. The controller owns exclusion/deadline and keeps
// all controls locked until this actor returns after native interpreter release.
actor CameraClassifierRunner: ClassifierDriver {
    private let captureID: UUID
    private var features: FeatureEncoder.Encoded?
    private var activeID: UUID?
    private var stopReason: String?

    init(captureID: UUID, features: FeatureEncoder.Encoded) {
        self.captureID = captureID
        self.features = features
    }

    func stop(id: UUID, reason: String) {
        guard activeID == id, stopReason == nil else { return }
        stopReason = reason
    }

    func run(id: UUID, progress: @escaping @Sendable (ClassifierProgress) async -> Void) async -> ClassifierMeasurement {
        var value = ClassifierMeasurement(id: id)
        value.fixtureFilename = "reference_classifier_v1.tflite"
        value.fixtureBytes = 7_057_180
        value.fixtureSHA256 = "08d0af17c7dcf3a690b9228415513ded5452d3fcd1889ef9268db659e3fc1bcb"
        value.plannedCases = 0
        value.nativeRuntimeVersion = Runtime.version
        value.cameraPrediction = CameraPredictionMeasurement(captureID: captureID)
        guard activeID == nil, let features else {
            value.outcome = "failed"
            value.error = "No unused camera clip is available."
            return value
        }
        self.features = nil
        activeID = id
        let start = ProcessInfo.processInfo.systemUptime
        defer { activeID = nil; stopReason = nil }
        value.cameraPrediction?.validFrames = features.validFrames
        value.cameraPrediction?.handFrames = features.handFrames
        do {
            await progress(.stage("verifying and classifying captured sign"))
            try Task.checkCancellation()
            if stopReason != nil { throw CancellationError() }
            guard let url = Bundle.main.url(forResource: "reference_classifier_v1", withExtension: "tflite"),
                  let manifestURL = Bundle.main.url(forResource: "reference_classifier_v1", withExtension: "json") else {
                throw AppError.invalidModel("Bundled trained model or manifest is missing.")
            }
            let manifest = try JSONDecoder().decode(TrainedClassifierManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.modelSHA256 == value.fixtureSHA256, manifest.modelBytes == value.fixtureBytes,
                  manifest.outputSemantics == "logits" else { throw EncoderError.invalidLayout }
            // Only the value tensor crosses actors. The helper owns all native objects.
            let result = try await TrainedClassifierRunner().classify(modelURL: url, manifest: manifest, features: features)
            value.completedReleases = 1
            value.integrityVerified = true
            value.tensorContractVerified = true
            value.loadSeconds = [result.loadSeconds]
            value.cameraPrediction?.invokeSeconds = result.invokeSeconds
            try Task.checkCancellation()
            if stopReason != nil { throw CancellationError() }
            value.cameraPrediction?.candidates = result.candidates
            value.cameraPrediction?.status = "unconfirmed candidates; recognition quality and cadence unvalidated"
            value.outcome = "candidate inference completed"
        } catch {
            value.outcome = stopReason ?? "failed"
            value.error = String(describing: error)
            value.cameraPrediction?.candidates = []
            value.cameraPrediction?.status = value.outcome
        }
        await progress(.stage("camera classifier resources released"))
        if let stopReason {
            value.outcome = stopReason
            value.cameraPrediction?.status = stopReason
            value.cameraPrediction?.candidates = []
        }
        value.endedAt = Date()
        value.elapsedSeconds = ProcessInfo.processInfo.systemUptime - start
        return value
    }
}
