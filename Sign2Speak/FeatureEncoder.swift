import CryptoKit
import Foundation

// Independently implemented from the documented mathematical/tensor contract.
// Host synthetic parity is recorded in docs/classifier-parity-results.json.
enum FeatureEncoder {
    static let schema = "reference-training-xy-forward-differences-v1"
    static let frames = 64
    static let channels = 708
    static let padding: Float = -100
    static let lips = [0, 61, 185, 40, 39, 37, 267, 269, 270, 409,
                       291, 146, 91, 181, 84, 17, 314, 405, 321, 375,
                       78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
                       95, 88, 178, 87, 14, 317, 402, 318, 324, 308]
    static let nose = [1, 2, 98, 327]
    static let rightEye = [33, 7, 163, 144, 145, 153, 154, 155, 133, 246, 161, 160, 159, 158, 157, 173]
    static let leftEye = [263, 249, 390, 373, 374, 380, 381, 382, 362, 466, 388, 387, 386, 385, 384, 398]
    static let pointOrder = lips + Array(468..<489) + Array(522..<543) + nose + rightEye + leftEye

    struct Encoded: Sendable {
        let values: [Float]
        let validFrames: Int
        let discardedEmptyFrames: Int
        let handFrames: Int
        var data: Data { values.withUnsafeBytes { Data($0) } }
    }

    static func encode(_ observations: [LandmarkClipFrame]) throws -> Encoded {
        guard observations.count <= frames else { throw EncoderError.tooManyFrames }
        var previous: Double?
        var selected: [[LandmarkPoint]] = []
        var handFrames = 0
        let missing = LandmarkPoint(x: .nan, y: .nan, z: .nan)
        for frame in observations {
            guard frame.seconds.isFinite, frame.seconds >= 0,
                  previous.map({ frame.seconds > $0 }) ?? true else { throw EncoderError.invalidTimestamp }
            previous = frame.seconds
            guard frame.face.map({ $0.count == 478 || $0.count == 468 }) ?? true,
                  frame.left.map({ $0.count == 21 }) ?? true,
                  frame.right.map({ $0.count == 21 }) ?? true else { throw EncoderError.invalidLayout }
            let points = pointOrder.map { index -> LandmarkPoint in
                if index < 468 { return frame.face?[index] ?? missing }
                if index < 489 { return frame.left?[index - 468] ?? missing }
                return frame.right?[index - 522] ?? missing
            }
            // Training drops a frame only if ALL selected xyz coordinates are NaN.
            guard points.contains(where: { !$0.x.isNaN || !$0.y.isNaN || !$0.z.isNaN }) else { continue }
            guard points.allSatisfy({ !$0.x.isInfinite && !$0.y.isInfinite && !$0.z.isInfinite }) else {
                throw EncoderError.nonfiniteOutput
            }
            selected.append(points)
            if frame.left != nil || frame.right != nil { handFrames += 1 }
        }
        guard selected.count >= 3 else { throw EncoderError.insufficientFrames }
        let anchorIndex = 15 // pointOrder[15] is face landmark 17 (lip, despite Android's nose name).
        func coordinate(_ point: LandmarkPoint, _ axis: Int) -> Float { axis == 0 ? point.x : point.y }
        var center = [Float](repeating: 0.5, count: 2)
        var scale = [Float](repeating: 0, count: 2)
        for axis in 0..<2 {
            let anchors = selected.map { coordinate($0[anchorIndex], axis) }.filter { !$0.isNaN }
            if !anchors.isEmpty { center[axis] = anchors.reduce(0, +) / Float(anchors.count) }
            var squares: Float = 0
            var count = 0
            for points in selected {
                for point in points {
                    let value = coordinate(point, axis)
                    if !value.isNaN {
                        let delta = value - center[axis]
                        squares += delta * delta
                        count += 1
                    }
                }
            }
            scale[axis] = count == 0 ? .nan : (squares / Float(count)).squareRoot()
        }
        // One contiguous normalization buffer instead of one allocation per row.
        var normalized = [Float](repeating: 0, count: selected.count * 236)
        for (time, points) in selected.enumerated() {
            for (index, point) in points.enumerated() {
                for axis in 0..<2 {
                    // Keep NaN until AFTER differencing, as training does.
                    normalized[time * 236 + index * 2 + axis] = (coordinate(point, axis) - center[axis]) / scale[axis]
                }
            }
        }
        var output = [Float](repeating: padding, count: frames * channels)
        for time in selected.indices {
            for channel in 0..<236 {
                let current = normalized[time * 236 + channel]
                for block in 0..<3 {
                    // No three-element temporary array for every time/channel pair
                    // (up to 15,104 per window in an unoptimized Debug build).
                    let raw: Float
                    if block == 0 { raw = current }
                    else if time + block < selected.count { raw = normalized[(time + block) * 236 + channel] - current }
                    else { raw = 0 }
                    let value = raw.isNaN ? 0 : raw
                    guard value.isFinite else { throw EncoderError.nonfiniteOutput }
                    output[time * channels + block * 236 + channel] = value
                }
            }
        }
        return Encoded(values: output, validFrames: selected.count,
                       discardedEmptyFrames: observations.count - selected.count, handFrames: handFrames)
    }
}

enum EncoderError: Error {
    case tooManyFrames, insufficientFrames, invalidTimestamp, invalidLayout, nonfiniteOutput
}

struct FeatureEncodingMeasurement: Codable, Sendable {
    var schema = FeatureEncoder.schema
    var status: String
    var validFrames: Int?
    var discardedEmptyFrames: Int?
    var handFrames: Int?
    var tensorBytes: Int?
    var elapsedSeconds: Double
    var trainingParityVerified = false
}

// Deliberately contains no embedded reference weights or assumed label ordering.
// Provisioning and training/export parity evidence must accompany a real artifact.
struct TrainedClassifierManifest: Codable, Sendable {
    let schema: String
    let pointOrder: [Int]
    let labels: [String]
    let modelSHA256: String
    let modelBytes: Int
    let permissionReference: String
    let trainingParityReference: String?
    let cadenceReference: String?
    let outputSemantics: String

    func validate() throws {
        guard schema == FeatureEncoder.schema, pointOrder == FeatureEncoder.pointOrder,
              labels.count == 50, Set(labels).count == 50,
              labels.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              modelBytes > 0, modelBytes <= 100_000_000,
              modelSHA256.count == 64, modelSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !permissionReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["probabilities", "logits"].contains(outputSemantics) else { throw EncoderError.invalidLayout }
    }

    func verify(_ bytes: Data) throws {
        try validate()
        guard bytes.count == modelBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == modelSHA256 else {
            throw AppError.invalidModel("Trained classifier integrity does not match its manifest.")
        }
    }

    func candidates(_ scores: [Float]) throws -> [ClassifierCandidate] {
        try validate()
        guard scores.count == labels.count, scores.allSatisfy(\.isFinite) else { throw EncoderError.nonfiniteOutput }
        let probabilities: [Float]
        if outputSemantics == "logits" {
            // Subtract in Double to avoid overflow even for extreme finite Float logits.
            let maximum = Double(scores.max()!)
            let exponentials = scores.map { exp(Double($0) - maximum) }
            let sum = exponentials.reduce(0, +)
            probabilities = exponentials.map { Float($0 / sum) }
        } else {
            probabilities = scores
        }
        guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.reduce(0, +) - 1) <= 0.001 else { throw EncoderError.nonfiniteOutput }
        return probabilities.indices.sorted {
            probabilities[$0] == probabilities[$1] ? $0 < $1 : probabilities[$0] > probabilities[$1]
        }.prefix(3).map { ClassifierCandidate(label: labels[$0], score: probabilities[$0], index: $0) }
    }
}

struct ClassifierCandidate: Codable, Sendable {
    let label: String
    let score: Float
    let index: Int
}

struct CameraPredictionMeasurement: Codable, Sendable {
    let captureID: UUID
    var status = "pending"
    var candidates: [ClassifierCandidate] = []
    var validFrames: Int?
    var handFrames: Int?
    var invokeSeconds: Double?
    var hostSyntheticParityVerified = true // Eight synthetic cases; see recorded audit.
    var deviceLogitParityVerified = false
    var cadenceValidated = false
    var recognitionValidated = false
    var requiresConfirmation = true
}

struct CameraInference: Sendable {
    let candidates: [ClassifierCandidate]
    let loadSeconds: Double
    let invokeSeconds: Double
}

struct ClassifierValidationCase: Codable, Sendable {
    let pass: Int
    let repetition: Int
    let recipe: String
    let invokeSeconds: Double
    let maximumRepeatAbsoluteError: Double?
    let candidates: [ClassifierCandidate]
}

struct ClassifierValidationMeasurement: Codable, Sendable {
    var outputSemantics = "logits"
    var inputKind = "synthetic runtime inputs; not recorded signs"
    var trainingParityVerified = false
    var recognitionValidated = false
    var plannedInvocations = 16
    var cases: [ClassifierValidationCase] = []
}
