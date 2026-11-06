import Foundation
import TensorFlowLite

// No native object crosses this actor. Stop is cooperative between synchronous
// calls; the controller remains locked until run returns after interpreter release.
actor ClassifierRunner: ClassifierDriver {
    private var interpreter: Interpreter?
    private var activeID: UUID?
    private var stopReason: String?

    func stop(id: UUID, reason: String) {
        guard activeID == id, stopReason == nil else { return }
        stopReason = reason
    }

    func run(id: UUID, progress: @escaping @Sendable (ClassifierProgress) async -> Void) async -> ClassifierMeasurement {
        var measurement = ClassifierMeasurement(id: id)
        guard activeID == nil else {
            measurement.outcome = "failed"
            measurement.error = "Classifier runner is already active."
            measurement.endedAt = Date()
            return measurement
        }
        activeID = id
        stopReason = nil
        let started = ProcessInfo.processInfo.systemUptime
        defer { activeID = nil; stopReason = nil }
        do {
            await progress(.stage("verifying classifier fixture"))
            try checkStop()
            guard let url = Bundle.main.url(forResource: "classifier_fixture_v1", withExtension: "tflite") else {
                throw AppError.invalidModel("Bundled classifier fixture is missing. Rebuild the app.")
            }
            try ClassifierFixture.verify(Data(contentsOf: url))
            measurement.integrityVerified = true
            measurement.nativeRuntimeVersion = Runtime.version
            await progress(.measurement(measurement))

            for pass in 1...2 {
                await progress(.stage("loading classifier pass \(pass)"))
                try checkStop()
                let seconds = try autoreleasepool { try load(url) }
                measurement.tensorContractVerified = true
                measurement.loadSeconds.append(seconds)
                await progress(.measurement(measurement))
                for repetition in 1...2 {
                    for recipe in ClassifierFixture.recipes {
                        await progress(.stage("classifier pass \(pass), \(recipe), repeat \(repetition)"))
                        try checkStop()
                        let result = try autoreleasepool {
                            try infer(recipe: recipe, pass: pass, repetition: repetition)
                        }
                        measurement.cases.append(result)
                        await progress(.measurement(measurement))
                    }
                }
                release(&measurement)
                await progress(.stage("classifier released pass \(pass); observing memory"))
                await progress(.measurement(measurement))
                try await Task.sleep(nanoseconds: 2_000_000_000)
                await progress(.stage("classifier post-release sample pass \(pass)"))
                try checkStop()
            }
            let passed = measurement.cases.count == measurement.plannedCases
                && measurement.completedReleases == 2 && measurement.cases.allSatisfy(\.passed)
            measurement.outcome = passed ? "passed" : "failed numerical comparison"
        } catch {
            measurement.outcome = stopReason ?? "failed"
            measurement.error = String(describing: error)
        }
        // Also release when integrity, allocation, tensor layout, or inference fails.
        release(&measurement)
        await progress(.stage("classifier resources released"))
        if let stopReason { measurement.outcome = stopReason }
        measurement.endedAt = Date()
        measurement.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        return measurement
    }

    private func checkStop() throws {
        try Task.checkCancellation()
        if stopReason != nil { throw CancellationError() }
    }

    private func load(_ url: URL) throws -> Double {
        guard interpreter == nil else { throw AppError.invalidState }
        var options = Interpreter.Options()
        options.threadCount = 1
        options.isXNNPackEnabled = false
        let start = ProcessInfo.processInfo.systemUptime
        let candidate = try Interpreter(modelPath: url.path, options: options)
        try candidate.allocateTensors()
        guard candidate.inputTensorCount == 1, candidate.outputTensorCount == 1 else {
            throw AppError.invalidModel("Classifier fixture must have exactly one input and output.")
        }
        try validate(candidate.input(at: 0), input: true)
        try validate(candidate.output(at: 0), input: false)
        interpreter = candidate
        return ProcessInfo.processInfo.systemUptime - start
    }

    private func infer(recipe: String, pass: Int, repetition: Int) throws -> ClassifierCaseMeasurement {
        guard let interpreter else { throw AppError.invalidState }
        let data = try ClassifierFixture.input(recipe: recipe)
        try interpreter.copy(data, toInputAt: 0)
        let start = ProcessInfo.processInfo.systemUptime
        try interpreter.invoke()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        let output = try interpreter.output(at: 0)
        try validate(output, input: false)
        return try ClassifierFixture.compare(output.data, recipe: recipe, pass: pass,
                                             repetition: repetition, seconds: seconds)
    }

    private func validate(_ tensor: Tensor, input: Bool) throws {
        guard tensor.dataType == .float32,
              tensor.shape.dimensions == (input ? ClassifierFixture.inputShape : ClassifierFixture.outputShape),
              tensor.data.count == (input ? ClassifierFixture.inputBytes : ClassifierFixture.outputBytes) else {
            throw AppError.invalidModel("Classifier \(input ? "input" : "output") dtype, shape, or byte count is wrong.")
        }
    }

    private func release(_ measurement: inout ClassifierMeasurement) {
        guard interpreter != nil else { return }
        autoreleasepool { interpreter = nil }
        measurement.completedReleases += 1
    }
}
