import CryptoKit
import Foundation

// Owned arithmetic fixture. These channels and outputs carry no ASL meaning.
enum ClassifierFixture {
    static let filename = "classifier_fixture_v1.tflite"
    static let bytes = 142_904
    static let sha256 = "147b367d40f4c62027f11ff718ca76c46663a2db9dc2d445b6dd9be8a49cb6d6"
    static let inputShape = [1, 64, 708]
    static let outputShape = [1, 50]
    static let inputBytes = 64 * 708 * MemoryLayout<Float>.size
    static let outputBytes = 50 * MemoryLayout<Float>.size
    static let recipes = ["zeros", "ones", "ramp", "padded"]
    static let absoluteTolerance = 0.00001
    static let relativeTolerance = 0.00001

    static func verify(_ data: Data) throws {
        guard data.count == bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw AppError.invalidModel("Classifier fixture size or SHA-256 mismatch. Rebuild with the approved owned fixture.")
        }
    }

    static func input(recipe: String) throws -> Data {
        guard recipes.contains(recipe) else { throw AppError.invalidModel("Unknown classifier fixture case.") }
        var words = [UInt32]()
        words.reserveCapacity(64 * 708)
        for frame in 0..<64 {
            for channel in 0..<708 {
                let value: Float
                switch recipe {
                case "zeros": value = 0
                case "ones": value = 1
                case "ramp": value = Float(channel % 17 - 8) / 8 + Float(frame) / 64
                default: value = frame < 48 ? 1 : -100
                }
                words.append(value.bitPattern.littleEndian)
            }
        }
        return words.withUnsafeBytes { Data($0) }
    }

    static func expected(recipe: String) throws -> [Double] {
        guard recipes.contains(recipe) else { throw AppError.invalidModel("Unknown classifier fixture case.") }
        func mean(_ channel: Int) -> Double {
            switch recipe {
            case "zeros": return 0
            case "ones": return 1
            case "padded": return -24.25
            default: return Double(channel % 17 - 8) / 8 + 63.0 / 128
            }
        }
        var values = [Double]()
        for index in 0..<50 {
            let sign: Double = index.isMultiple(of: 2) ? 1 : -1
            let primary = sign * mean(index)
            let secondary = 0.5 * mean(658 + index)
            values.append(primary + secondary + Double(index) / 8)
        }
        return values
    }

    static func compare(_ data: Data, recipe: String, pass: Int, repetition: Int,
                        seconds: Double) throws -> ClassifierCaseMeasurement {
        guard data.count == outputBytes else { throw AppError.invalidModel("Wrong classifier output byte count.") }
        let expected = try expected(recipe: recipe)
        let values = data.withUnsafeBytes { raw in
            (0..<50).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
        var mismatches = [Int]()
        var nonfinite = [Int]()
        var maximumError = 0.0
        for index in values.indices {
            guard values[index].isFinite else {
                nonfinite.append(index)
                mismatches.append(index)
                continue
            }
            let error = abs(Double(values[index]) - expected[index])
            maximumError = max(maximumError, error)
            if error > absoluteTolerance + relativeTolerance * abs(expected[index]) {
                mismatches.append(index)
            }
        }
        return ClassifierCaseMeasurement(
            pass: pass, repetition: repetition, recipe: recipe, invokeSeconds: seconds,
            passed: mismatches.isEmpty, mismatchIndices: mismatches, nonfiniteIndices: nonfinite,
            maximumAbsoluteError: nonfinite.isEmpty ? maximumError : nil,
            outputs: nonfinite.isEmpty ? values : nil // JSON cannot represent NaN/Inf.
        )
    }
}

struct ClassifierCaseMeasurement: Codable, Sendable {
    let pass: Int
    let repetition: Int
    let recipe: String
    let invokeSeconds: Double
    let passed: Bool
    let mismatchIndices: [Int]
    let nonfiniteIndices: [Int]
    let maximumAbsoluteError: Double?
    let outputs: [Float]?
}

struct ClassifierMeasurement: Codable, Sendable {
    let id: UUID
    var startedAt = Date()
    var endedAt: Date?
    var fixtureFilename = ClassifierFixture.filename
    var fixtureBytes = ClassifierFixture.bytes
    var fixtureSHA256 = ClassifierFixture.sha256
    var integrityVerified = false
    var tensorContractVerified = false
    var package = "readdle/tensorflow-lite-swift 2.16.1"
    var nativeRuntimeVersion: String?
    var backend = "CPU"
    var threadCount = 1
    var xnnpackRequested = false
    var inputShape = ClassifierFixture.inputShape
    var outputShape = ClassifierFixture.outputShape
    var dtype = "float32"
    var absoluteTolerance = ClassifierFixture.absoluteTolerance
    var relativeTolerance = ClassifierFixture.relativeTolerance
    var plannedCases = 16
    var loadSeconds: [Double] = []
    var completedReleases = 0
    var cases: [ClassifierCaseMeasurement] = []
    var elapsedSeconds = 0.0
    var outcome = "pending"
    var error: String?
    var trainedValidation: ClassifierValidationMeasurement?
    var cameraPrediction: CameraPredictionMeasurement?

    // Keep historical report files readable while using application terminology
    // throughout Swift. The compatibility spelling stays at the serialization edge.
    enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, fixtureFilename, fixtureBytes, fixtureSHA256
        case integrityVerified, tensorContractVerified, package, nativeRuntimeVersion
        case backend, threadCount, xnnpackRequested, inputShape, outputShape, dtype
        case absoluteTolerance, relativeTolerance, plannedCases, loadSeconds
        case completedReleases, cases, elapsedSeconds, outcome, error, cameraPrediction
        case trainedValidation = "trainedProbe"
    }
}

enum ClassifierProgress: Sendable {
    case stage(String)
    case measurement(ClassifierMeasurement)
}

protocol ClassifierDriver: Sendable {
    func run(id: UUID, progress: @escaping @Sendable (ClassifierProgress) async -> Void) async -> ClassifierMeasurement
    func stop(id: UUID, reason: String) async
}
