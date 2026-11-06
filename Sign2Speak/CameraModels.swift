import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case cameraOnly, handAndFace, signCandidates, continuousSigning

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cameraOnly: return "Camera only"
        case .handAndFace: return "Hand + face landmarks"
        case .signCandidates: return "Sign candidates"
        case .continuousSigning: return "Continuous signing (experimental)"
        }
    }
    var usesLandmarks: Bool { self != .cameraOnly }
}

enum HandTestScene: String, CaseIterable, Identifiable, Codable, Sendable {
    case unspecified, noHands, anatomicalLeftOnly, anatomicalRightOnly, bothHands

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: return "Unlabelled scene"
        case .noHands: return "No hands visible"
        case .anatomicalLeftOnly: return "Only my left hand"
        case .anatomicalRightOnly: return "Only my right hand"
        case .bothHands: return "Both hands visible"
        }
    }
}

struct CameraConfiguration: Sendable {
    let mode: CaptureMode
    let framesPerSecond: Int
    let handTestScene: HandTestScene

    func measurement(id: UUID) -> CameraMeasurement {
        var value = CameraMeasurement(id: id)
        value.captureMode = mode
        value.requestedFramesPerSecond = framesPerSecond
        value.handTestScene = handTestScene
        if mode == .signCandidates {
            value.durationLimitSeconds = 3
            value.frameLimit = 64
        }
        if mode == .continuousSigning {
            value.durationLimitSeconds = 60
            value.frameLimit = 1_800
        }
        return value
    }
}

struct CameraGeometryObservation: Codable, Sendable {
    let frameNumber: Int
    let width: Int
    let height: Int
    let rotationDegrees: Double
}

// Preview angles are relative to the view/interface; capture angles are relative
// to gravity. They need not match. UI dimensions are points, not camera pixels.
struct PreviewGeometryObservation: Codable, Equatable, Sendable {
    let widthPoints: Double
    let heightPoints: Double
    let rotationDegrees: Double
    let mirrored: Bool
}

// Candidate slots, not tracking IDs or validated anatomical identities. Retain
// source indices so future feature assembly never depends on SDK result order.
struct HandSlotResolution: Codable, Sendable {
    var leftSourceIndex: Int?
    var rightSourceIndex: Int?
    var rejectionReasons: [String] = []

    static func resolve(pointCounts: [Int], labels: [String], scores: [Float],
                        mirrored: Bool, minimumScore: Float = 0.8) -> Self {
        var value = Self()
        guard !mirrored else {
            value.rejectionReasons = ["mirrored input is not calibrated"]
            return value
        }
        guard minimumScore.isFinite, (0...1).contains(minimumScore),
              pointCounts.count <= 2, pointCounts.count == labels.count,
              labels.count == scores.count else {
            value.rejectionReasons = ["invalid hand result layout"]
            return value
        }
        for index in pointCounts.indices {
            let label = labels[index]
            guard label == "Left" || label == "Right" else {
                value.rejectionReasons.append("unknown hand label")
                continue
            }
            // Do not break a duplicate-label tie by position or confidence.
            guard labels.filter({ $0 == label }).count == 1 else {
                if !value.rejectionReasons.contains("duplicate hand label") {
                    value.rejectionReasons.append("duplicate hand label")
                }
                continue
            }
            guard pointCounts[index] == 21 else {
                value.rejectionReasons.append("incomplete hand landmarks")
                continue
            }
            guard scores[index].isFinite, (minimumScore...1).contains(scores[index]) else {
                value.rejectionReasons.append("weak or invalid hand label score")
                continue
            }
            if label == "Left" { value.leftSourceIndex = index }
            else { value.rightSourceIndex = index }
        }
        return value
    }
}

struct HandIdentityCounts: Codable, Sendable {
    var processedFrames = 0
    var framesWithoutHands = 0
    var framesWithLeftCandidate = 0
    var framesWithRightCandidate = 0
    var framesWithBothCandidates = 0
    var framesWithRejectedHands = 0
    var lowScoreHandCount = 0
    var singleHandRawLabelCounts: [String: Int] = [:]

    mutating func record(handCount: Int, labels: [String], scores: [Float],
                         resolution: HandSlotResolution, minimumScore: Float) {
        processedFrames += 1
        if handCount == 0 { framesWithoutHands += 1 }
        if resolution.leftSourceIndex != nil { framesWithLeftCandidate += 1 }
        if resolution.rightSourceIndex != nil { framesWithRightCandidate += 1 }
        if resolution.leftSourceIndex != nil && resolution.rightSourceIndex != nil {
            framesWithBothCandidates += 1
        }
        if !resolution.rejectionReasons.isEmpty { framesWithRejectedHands += 1 }
        lowScoreHandCount += scores.filter { $0.isFinite && $0 >= 0 && $0 < minimumScore }.count
        if handCount == 1 {
            let raw = labels.first ?? "unknown"
            let label = raw == "Left" || raw == "Right" ? raw : "unknown"
            singleHandRawLabelCounts[label, default: 0] += 1
        }
    }
}

struct HandIdentitySegment: Codable, Sendable {
    let geometryEpoch: Int
    let geometry: CameraGeometryObservation
    let captureMirrored: Bool
    var counts = HandIdentityCounts()
}

struct HandIdentityMeasurement: Codable, Sendable {
    var mappingStatus = "provisional raw Left/Right to anatomical Left/Right; device calibration pending"
    var minimumLabelScore: Float = 0.8 // Diagnostic cutoff; not an evaluated product threshold.
    var latestResolution = HandSlotResolution()
    var counts = HandIdentityCounts()
    var geometrySegments: [HandIdentitySegment] = [] // Latest 16; totals cover all frames.

    mutating func record(pointCounts: [Int], labels: [String], scores: [Float],
                         geometry: CameraGeometryObservation, epoch: Int, mirrored: Bool) {
        latestResolution = HandSlotResolution.resolve(pointCounts: pointCounts, labels: labels,
            scores: scores, mirrored: mirrored, minimumScore: minimumLabelScore)
        counts.record(handCount: pointCounts.count, labels: labels, scores: scores,
                      resolution: latestResolution, minimumScore: minimumLabelScore)
        if geometrySegments.last?.geometryEpoch != epoch || geometrySegments.last?.captureMirrored != mirrored {
            if geometrySegments.count == 16 { geometrySegments.removeFirst() }
            geometrySegments.append(HandIdentitySegment(geometryEpoch: epoch, geometry: geometry,
                                                       captureMirrored: mirrored))
        }
        geometrySegments[geometrySegments.count - 1].counts.record(
            handCount: pointCounts.count, labels: labels, scores: scores,
            resolution: latestResolution, minimumScore: minimumLabelScore)
    }
}

// Use capture PTS, not wall time. Reject millisecond collisions rather than invent
// timestamps: both video tasks must see the same strictly increasing timestamp.
struct VideoTimestampGate {
    private var origin: Double?
    private var lastSeconds: Double?
    private var lastMilliseconds: Int?

    mutating func accept(seconds: Double) -> Int? {
        guard seconds.isFinite, lastSeconds.map({ seconds > $0 }) ?? true else { return nil }
        let start = origin ?? seconds
        let milliseconds = ((seconds - start) * 1_000).rounded(.down)
        guard milliseconds >= 0, milliseconds < Double(Int.max) else { return nil }
        let value = Int(milliseconds)
        guard lastMilliseconds.map({ value > $0 }) ?? true else { return nil }
        origin = start
        lastSeconds = seconds
        lastMilliseconds = value
        return value
    }
}

// Queue-local raw observations. Deliberately not Codable: coordinates never enter
// exported reports. Slots remain provisional candidates, not persistent identities.
struct LandmarkPoint: Sendable {
    let x: Float
    let y: Float
    let z: Float
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

struct LandmarkClipFrame: Sendable {
    let seconds: Double
    let left: [LandmarkPoint]?
    let right: [LandmarkPoint]?
    let face: [LandmarkPoint]?
}

struct LandmarkClipMeasurement: Codable, Sendable {
    var capacity = 64
    var bufferedFrames = 0
    var admittedFrames = 0
    var evictedFrames = 0
    var resetCount = 0
    var invalidTimestampFrames = 0
    var invalidParts = 0
    var framesWithBothCandidates = 0
    var framesWithFace = 0
    var firstTimestampSeconds: Double?
    var lastTimestampSeconds: Double?
    var spanSeconds = 0.0
    var maximumIntervalSeconds = 0.0
    var gapResetSeconds = 0.25
    var lastResetReason: String?
    var status = "raw window; temporal resampling and training cadence pending"
}

struct LandmarkClipBuffer {
    private struct Geometry: Equatable {
        let width: Int
        let height: Int
        let rotation: Double
        let epoch: Int
        let mirrored: Bool
    }
    private var geometry: Geometry?
    private(set) var frames: [LandmarkClipFrame] = []
    private var totals = LandmarkClipMeasurement()

    mutating func append(seconds: Double, left: [LandmarkPoint]?, right: [LandmarkPoint]?,
                         face: [LandmarkPoint]?, geometry observation: CameraGeometryObservation,
                         epoch: Int, mirrored: Bool) {
        guard seconds.isFinite, seconds >= 0,
              frames.last.map({ seconds > $0.seconds }) ?? true else {
            totals.invalidTimestampFrames += 1
            reset("invalid or non-increasing timestamp")
            return
        }
        let current = Geometry(width: observation.width, height: observation.height,
                               rotation: observation.rotationDegrees, epoch: epoch, mirrored: mirrored)
        if let geometry, geometry != current { reset("capture geometry changed") }
        if let previous = frames.last, seconds - previous.seconds > totals.gapResetSeconds {
            reset("capture gap exceeded diagnostic limit")
        }
        geometry = current
        // Preserve absence; never carry forward stale detections or synthesize zeros.
        let frame = LandmarkClipFrame(seconds: seconds,
                                      left: validated(left, count: 21),
                                      right: validated(right, count: 21),
                                      face: validated(face, count: 478))
        if frames.count == totals.capacity {
            frames.removeFirst()
            totals.evictedFrames += 1
        }
        frames.append(frame)
        totals.admittedFrames += 1
    }

    private mutating func validated(_ points: [LandmarkPoint]?, count: Int) -> [LandmarkPoint]? {
        guard let points else { return nil }
        guard points.count == count, points.allSatisfy({ $0.isFinite }) else {
            totals.invalidParts += 1
            return nil
        }
        return points
    }

    private mutating func reset(_ reason: String) {
        frames.removeAll(keepingCapacity: true)
        totals.resetCount += 1
        totals.lastResetReason = reason
    }

    var measurement: LandmarkClipMeasurement {
        var value = totals
        value.bufferedFrames = frames.count
        value.firstTimestampSeconds = frames.first?.seconds
        value.lastTimestampSeconds = frames.last?.seconds
        value.spanSeconds = (frames.last?.seconds ?? 0) - (frames.first?.seconds ?? 0)
        // Count in place: this runs every frame, so avoid allocating three
        // temporary arrays just to summarize the bounded window.
        value.framesWithBothCandidates = 0
        value.framesWithFace = 0
        value.maximumIntervalSeconds = 0
        var previous: Double?
        for frame in frames {
            if frame.left != nil && frame.right != nil { value.framesWithBothCandidates += 1 }
            if frame.face != nil { value.framesWithFace += 1 }
            if let previous { value.maximumIntervalSeconds = max(value.maximumIntervalSeconds, frame.seconds - previous) }
            previous = frame.seconds
        }
        return value
    }
}

struct LandmarkMeasurement: Codable, Sendable {
    var runtime = "MediaPipe 1.1.0"
    var runtimeRevision = "821db8a4428baf58bf4c09a0330c937e6e0a3753"
    var delegate = "CPU"
    var runningMode = "video (synchronous)"
    var maximumHands = 2
    var maximumFaces = 1
    var confidenceThreshold = 0.5
    var models = [
        ModelManifest(filename: "hand_landmarker.task", revision: "1", bytes: 7_819_105,
                      sha256: "fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1"),
        ModelManifest(filename: "face_landmarker.task", revision: "1", bytes: 3_758_596,
                      sha256: "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff")
    ]
    var initializationSeconds = 0.0
    var processedFrames = 0
    var skippedTimestampFrames = 0
    var framesWithoutHands = 0
    var framesWithOneHand = 0
    var framesWithTwoHands = 0
    var framesWithFace = 0
    var framesWithoutFace = 0
    var latestHandPointCounts: [Int] = []
    var latestFacePointCount = 0
    var latestRawHandedness: [String] = []
    // Optional additions preserve decoding of version-5 captures.
    var latestRawHandednessScores: [Float]?
    var singleHandRawLabelCounts: [String: Int]?
    var duplicateRawLabelFrames: Int?
    var handIdentity: HandIdentityMeasurement? // Absent in reports before version 7.
    var clip: LandmarkClipMeasurement? // Aggregate only; absent before version 11.
    var featureEncoding: FeatureEncodingMeasurement? // No tensors exported, version 13.
    var firstTimestampMilliseconds: Int?
    var lastTimestampMilliseconds: Int?
    var totalProcessingSeconds = 0.0
    var maximumProcessingSeconds = 0.0
    var totalHandSeconds = 0.0
    var totalFaceSeconds = 0.0
    var errorCount = 0
    var lastError: String?

    mutating func recordHandIdentity(geometry: CameraGeometryObservation, epoch: Int, mirrored: Bool) {
        // Mutating an optional child while reading sibling fields through a class's
        // stored measurement property overlaps Swift's exclusive write access.
        // Read into a local value, finish its update, then write it back once.
        var identity = handIdentity ?? HandIdentityMeasurement()
        identity.record(pointCounts: latestHandPointCounts, labels: latestRawHandedness,
                        scores: latestRawHandednessScores ?? [], geometry: geometry,
                        epoch: epoch, mirrored: mirrored)
        handIdentity = identity
    }

    var meanProcessingSeconds: Double? {
        processedFrames > 0 ? totalProcessingSeconds / Double(processedFrames) : nil
    }

    var processedFramesPerSecond: Double? {
        guard processedFrames > 1, let first = firstTimestampMilliseconds,
              let last = lastTimestampMilliseconds, last > first else { return nil }
        return Double(processedFrames - 1) * 1_000 / Double(last - first)
    }
}

struct FrameBrightnessSample: Codable, Sendable {
    let minimum: Int
    let maximum: Int
    let mean: Double
    let nearBlackFraction: Double

    // Sparse 16 × 16 grid; this is a signal diagnostic, not exposure calibration.
    // Row padding is respected. No pixels or buffers survive this call.
    static func bgra(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int,
                     bytesPerRow: Int) -> Self? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              bytesPerRow > 0, width <= bytesPerRow / 4,
              height <= bytes.count / bytesPerRow else { return nil }
        var minimum = 255
        var maximum = 0
        var sum = 0
        var nearBlack = 0
        for row in 0..<16 {
            let y = (2 * row + 1) * height / 32
            for column in 0..<16 {
                let x = (2 * column + 1) * width / 32
                let offset = y * bytesPerRow + x * 4
                let luma = (77 * Int(bytes[offset + 2]) + 150 * Int(bytes[offset + 1])
                            + 29 * Int(bytes[offset])) >> 8
                minimum = min(minimum, luma)
                maximum = max(maximum, luma)
                sum += luma
                if luma <= 8 { nearBlack += 1 }
            }
        }
        return Self(minimum: minimum, maximum: maximum, mean: Double(sum) / 256,
                    nearBlackFraction: Double(nearBlack) / 256)
    }
}

struct FrameBrightnessMeasurement: Codable, Sendable {
    var sampledFrames = 0
    var failedSamples = 0
    var nearBlackFrames = 0
    var first: FrameBrightnessSample?
    var latest: FrameBrightnessSample?
    var maximumObservedMean = 0.0

    mutating func record(_ sample: FrameBrightnessSample?) {
        guard let sample else { failedSamples += 1; return }
        sampledFrames += 1
        if sample.nearBlackFraction >= 0.99 { nearBlackFrames += 1 }
        first = first ?? sample
        latest = sample
        maximumObservedMean = max(maximumObservedMean, sample.mean)
    }
}

enum CameraCompletionKind: String, Codable, Sendable {
    case durationLimit, frameLimit, userFinished, cancelled, interrupted, failed, handsAbsent, tokenLimit
    var permitsClassification: Bool {
        self == .durationLimit || self == .frameLimit || self == .userFinished
    }
}

struct CameraMeasurement: Codable, Sendable {
    let id: UUID
    var requestedAt = Date()
    var captureStartedAt: Date?
    var endedAt: Date?
    var frames = 0
    var droppedFrames = 0
    var invalidTimestampCount = 0
    var width = 0
    var height = 0
    var firstFrameTimestampSeconds: Double?
    var lastFrameTimestampSeconds: Double?
    var captureRotationDegrees: Double?
    var elapsedSeconds = 0.0
    var outcome = "pending"
    var completionKind: CameraCompletionKind?
    var frameLimit = 300
    var durationLimitSeconds = 10
    var requestedFramesPerSecond = 30
    var captureMirrored = false
    var captureMode: CaptureMode?
    var landmarks: LandmarkMeasurement?
    var handTestScene: HandTestScene?
    var configuredFramesPerSecond: Double?
    var captureEndedAt: Date?
    var captureElapsedSeconds: Double?
    var teardownSeconds: Double?
    var geometryChangeCount: Int?
    var geometryObservations: [CameraGeometryObservation]?
    var latestPreviewGeometry: PreviewGeometryObservation?
    var previewGeometryObservations: [PreviewGeometryObservation]?
    var frameBrightness: FrameBrightnessMeasurement? // Aggregate signal check, version 12.
    var candidateRejection: String?
    var continuous: ContinuousSigningMeasurement?
    var durationLimitOutcome: String {
        durationLimitSeconds == 10 ? "Ten-second capture limit reached" : "\(durationLimitSeconds)-second capture limit reached"
    }
    var frameLimitOutcome: String { "\(frameLimit)-frame capture limit reached" }
    var captureStartUptime: Double? // Queue-local clock; deliberately excluded from JSON.
    var captureEndUptime: Double?
    var lastObservedFrameGeometry: CameraGeometryObservation? // Not exported.

    mutating func observePreviewGeometry(_ value: PreviewGeometryObservation) {
        guard value.widthPoints.isFinite, value.heightPoints.isFinite, value.rotationDegrees.isFinite,
              value.widthPoints > 0, value.heightPoints > 0, value != latestPreviewGeometry else { return }
        if previewGeometryObservations == nil { previewGeometryObservations = [] }
        if (previewGeometryObservations?.count ?? 0) < 16 { previewGeometryObservations?.append(value) }
        latestPreviewGeometry = value
    }

    func captureLimitReached(at uptime: Double) -> Bool {
        guard let start = captureStartUptime else { return false }
        return uptime - start >= Double(durationLimitSeconds)
    }

    mutating func markCaptureEnded(at uptime: Double) {
        guard captureEndUptime == nil else { return }
        captureEndUptime = uptime
        captureEndedAt = Date()
        if let start = captureStartUptime { captureElapsedSeconds = max(0, uptime - start) }
    }

    mutating func observeGeometry(width: Int, height: Int, rotation: Double) {
        // Bound the history and retain the latest geometry for comparisons after
        // that history fills. Count pixel layout changes, independent of UI rotation.
        let changed = lastObservedFrameGeometry.map {
            $0.width != width || $0.height != height || abs($0.rotationDegrees - rotation) >= 0.5
        } ?? false
        if geometryChangeCount == nil { geometryChangeCount = 0 }
        if geometryObservations == nil { geometryObservations = [] }
        if lastObservedFrameGeometry == nil || changed {
            if changed { geometryChangeCount? += 1 }
            if (geometryObservations?.count ?? 0) < 16 {
                geometryObservations?.append(CameraGeometryObservation(
                    frameNumber: frames + 1, width: width, height: height, rotationDegrees: rotation))
            }
        }
        self.width = width
        self.height = height
        captureRotationDegrees = rotation
        lastObservedFrameGeometry = CameraGeometryObservation(
            frameNumber: frames + 1, width: width, height: height, rotationDegrees: rotation)
    }

    var deliveredFramesPerSecond: Double? {
        guard frames > 1, invalidTimestampCount == 0, let first = firstFrameTimestampSeconds,
              let last = lastFrameTimestampSeconds, last > first else { return nil }
        return Double(frames - 1) / (last - first)
    }

    enum CodingKeys: String, CodingKey {
        case id, requestedAt, captureStartedAt, endedAt, frames, droppedFrames, invalidTimestampCount
        case width, height, firstFrameTimestampSeconds, lastFrameTimestampSeconds, captureRotationDegrees
        case elapsedSeconds, outcome, frameLimit, durationLimitSeconds, requestedFramesPerSecond, captureMirrored
        case captureMode, landmarks
        case handTestScene, configuredFramesPerSecond, captureEndedAt, captureElapsedSeconds, teardownSeconds
        case geometryChangeCount, geometryObservations
        case latestPreviewGeometry, previewGeometryObservations
        case frameBrightness, candidateRejection, completionKind, continuous
    }
}

enum CameraProgress: Sendable {
    case stage(String)
    case frames(CameraMeasurement)
    case continuous([ClassifierCandidate]) // Transient session text, never checkpointed.
    case recognition(ContinuousRecognitionFeedback)
}
struct CapturedCameraClip: Sendable {
    var measurement: CameraMeasurement
    var features: FeatureEncoder.Encoded?
    var automaticGlosses: [ClassifierCandidate] = []

    var classificationRejection: String? {
        guard measurement.captureMode == .signCandidates else { return "Not a sign capture." }
        guard measurement.completionKind?.permitsClassification == true else {
            return "Capture did not complete normally: \(measurement.outcome)"
        }
        guard let landmarks = measurement.landmarks, landmarks.errorCount == 0,
              let clip = landmarks.clip else { return "Landmark capture was incomplete." }
        guard measurement.invalidTimestampCount == 0, landmarks.skippedTimestampFrames == 0,
              clip.invalidTimestampFrames == 0 else { return "Capture timestamps were invalid. Please retry." }
        guard clip.resetCount == 0, clip.evictedFrames == 0 else {
            return "Capture changed orientation or lost continuity. Keep the phone still and retry."
        }
        guard let features, features.validFrames >= 3 else { return "Too few usable frames. Record one complete sign." }
        guard features.handFrames > 0 else { return "No accepted hand landmarks. Keep your signing hand visible." }
        guard clip.framesWithFace > 0 else { return "Face landmarks are missing. Keep your face visible." }
        return nil
    }
}

protocol CameraDriver: Sendable {
    func capture(id: UUID, configuration: CameraConfiguration,
                 progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CameraMeasurement
    func stop(id: UUID, reason: String) async
    func captureClip(id: UUID, configuration: CameraConfiguration,
                     progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CapturedCameraClip
}

extension CameraDriver {
    func captureClip(id: UUID, configuration: CameraConfiguration,
                     progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CapturedCameraClip {
        CapturedCameraClip(measurement: try await capture(id: id, configuration: configuration, progress: progress))
    }
}
