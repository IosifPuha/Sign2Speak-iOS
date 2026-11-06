import Foundation

enum RecognitionFeedbackStatus: Equatable, Sendable {
    case collecting, lowScore, ambiguous, stabilizing, added, alreadyAdded, noHands
}

// Live session text only. Never Codable or included in camera/report measurements.
struct ContinuousRecognitionFeedback: Sendable {
    var candidates: [ClassifierCandidate] = []
    var status: RecognitionFeedbackStatus = .collecting
    var handsVisible = false
    var hasSeenHands = false
    var noHandsSeconds = 0.0
}

// Counts/timings only. Thresholds are experimental policy, not calibrated accuracy.
enum ContinuousSigningPolicy {
    static let noHandsTimeoutSeconds = 2.0
}

struct ContinuousSigningMeasurement: Codable, Sendable {
    var policyRevision = "continuous-v4-score60-pause2"
    var noHandsTimeoutSeconds = ContinuousSigningPolicy.noHandsTimeoutSeconds
    var minimumScore: Float = 0.60
    var minimumMargin: Float = 0.20
    var minimumHandFrames = 6
    var inferenceCount = 0
    var rejectedWindows = 0
    var committedGlossCount = 0
    var maximumInvokeSeconds = 0.0
    var totalInvokeSeconds = 0.0
    var discontinuities = 0
    var nativeRuntimeVersion: String?
    var modelSHA256: String?
    var tensorContractVerified = false
    var recognitionValidated = false
    var cadenceValidated = false
    var handPresenceFrames = 0
    var latestNoHandsSeconds = 0.0
    var latestTopScore: Float?
}

// Queue-confined, deterministic policy shared by the native camera and host checks.
// Raw hand presence drives utterance completion, even when handedness is rejected.
struct ContinuousSigningState {
    private(set) var glosses: [ClassifierCandidate] = []
    private(set) var measurement = ContinuousSigningMeasurement()
    private(set) var feedback = ContinuousRecognitionFeedback()
    private var sawHands = false
    private var absentSince: Double?
    private var previousFrame: Double?
    private var lastInference: Double?
    private var pending: ClassifierCandidate?
    private var pendingSince = 0.0
    private var pendingCount = 0
    private var lastCommittedIndex: Int?
    private(set) var segmentStart: Double?

    mutating func observe(seconds: Double, handsVisible: Bool) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        if let previousFrame, seconds <= previousFrame || seconds - previousFrame > 0.25 {
            measurement.discontinuities += 1
            absentSince = nil
            pending = nil
            pendingCount = 0
            lastInference = nil
            segmentStart = seconds
            feedback.candidates = []
            feedback.status = .collecting
            measurement.latestNoHandsSeconds = 0
        }
        previousFrame = seconds
        if handsVisible {
            if !feedback.handsVisible {
                feedback.status = .collecting
                feedback.candidates = []
            }
            feedback.handsVisible = true
            feedback.hasSeenHands = true
            feedback.noHandsSeconds = 0
            measurement.handPresenceFrames += 1
            measurement.latestNoHandsSeconds = 0
            // A brief hand release rearms the same label for intentional repetition.
            if let absentSince, seconds >= absentSince + 0.30 {
                lastCommittedIndex = nil
                segmentStart = seconds
                pending = nil
                pendingCount = 0
            }
            sawHands = true
            absentSince = nil
            segmentStart = segmentStart ?? seconds
        } else if sawHands {
            absentSince = absentSince ?? seconds
            measurement.latestNoHandsSeconds = seconds - (absentSince ?? seconds)
            pending = nil
            pendingCount = 0
        }
        if !handsVisible {
            feedback.handsVisible = false
            feedback.noHandsSeconds = measurement.latestNoHandsSeconds
            feedback.status = .noHands
            feedback.candidates = []
        }
        return sawHands && absentSince.map { seconds >= $0 + measurement.noHandsTimeoutSeconds } == true
    }

    mutating func shouldInfer(seconds: Double) -> Bool {
        guard sawHands, absentSince == nil, glosses.count < 8,
              lastInference.map({ seconds >= $0 + 0.35 }) ?? true else { return false }
        lastInference = seconds
        return true
    }

    mutating func rejectWindow() {
        measurement.rejectedWindows += 1
        pending = nil
        pendingCount = 0
        feedback.status = .collecting
        feedback.candidates = []
    }

    mutating func recordRuntime(version: String, modelSHA256: String) {
        measurement.nativeRuntimeVersion = version
        measurement.modelSHA256 = modelSHA256
    }

    mutating func accept(_ candidates: [ClassifierCandidate], seconds: Double, invokeSeconds: Double) {
        measurement.tensorContractVerified = true // Native helper validated input and invoked output.
        measurement.inferenceCount += 1
        measurement.maximumInvokeSeconds = max(measurement.maximumInvokeSeconds, invokeSeconds)
        measurement.totalInvokeSeconds += invokeSeconds
        measurement.latestTopScore = candidates.first?.score
        feedback.candidates = Array(candidates.prefix(3))
        guard let best = candidates.first, candidates.count >= 2,
              best.score.isFinite, candidates[1].score.isFinite else {
            rejectWindow()
            return
        }
        guard best.score >= measurement.minimumScore,
              best.score - candidates[1].score >= measurement.minimumMargin else {
            rejectWindow()
            feedback.candidates = Array(candidates.prefix(3))
            feedback.status = best.score < measurement.minimumScore ? .lowScore : .ambiguous
            return
        }
        if best.index == lastCommittedIndex {
            feedback.status = .alreadyAdded
            pending = nil
            pendingCount = 0
            return
        }
        if pending?.index == best.index { pendingCount += 1 }
        else { pending = best; pendingCount = 1; pendingSince = seconds }
        feedback.status = .stabilizing
        guard pendingCount >= 2, seconds >= pendingSince + 0.30, glosses.count < 8 else { return }
        glosses.append(best)
        feedback.status = .added
        measurement.committedGlossCount = glosses.count
        lastCommittedIndex = best.index
        pending = nil
        pendingCount = 0
        // New predictions must be built from fresh observations after this sign.
        segmentStart = seconds
    }
}

// Transient tensor handoff only. Never Codable, checkpointed, or retained in a report.
