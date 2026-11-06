import CoreMedia
import CryptoKit
import Foundation
import MediaPipeTasksVision

// Created, used, and released on CameraCapture's serial queue. SDK objects and
// sample buffers never cross actors; only summaries and an ephemeral encoded
// value tensor leave the queue. Raw landmark points remain queue-local.
final class LandmarkProcessor {
    private let hands: HandLandmarker
    private let face: FaceLandmarker
    private var timestamps = VideoTimestampGate()
    private var clip = LandmarkClipBuffer()
    private(set) var measurement = LandmarkMeasurement()
    var latestFrame: LandmarkClipFrame? { clip.frames.last }
    func continuousFeatures(since start: Double) throws -> FeatureEncoder.Encoded? {
        let frames = clip.frames.filter { $0.seconds >= start }
        var handCount = 0
        var firstHand: Double?
        var lastHand: Double?
        for frame in frames where frame.left != nil || frame.right != nil {
            handCount += 1
            firstHand = firstHand ?? frame.seconds
            lastHand = frame.seconds
        }
        guard handCount >= 6, let firstHand, let lastHand,
              lastHand - firstHand >= 0.25,
              frames.contains(where: { $0.face != nil }) else { return nil }
        return try FeatureEncoder.encode(frames)
    }

    init(bundle: Bundle = .main) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let pins = LandmarkMeasurement().models
        let paths = try pins.map { try Self.verifiedPath(for: $0, bundle: bundle) }
        let handOptions = HandLandmarkerOptions()
        handOptions.baseOptions.modelAssetPath = paths[0]
        handOptions.baseOptions.delegate = .CPU
        handOptions.runningMode = .video
        handOptions.numHands = 2
        handOptions.minHandDetectionConfidence = 0.5
        handOptions.minHandPresenceConfidence = 0.5
        handOptions.minTrackingConfidence = 0.5
        hands = try HandLandmarker(options: handOptions)

        let faceOptions = FaceLandmarkerOptions()
        faceOptions.baseOptions.modelAssetPath = paths[1]
        faceOptions.baseOptions.delegate = .CPU
        faceOptions.runningMode = .video
        faceOptions.numFaces = 1
        faceOptions.minFaceDetectionConfidence = 0.5
        faceOptions.minFacePresenceConfidence = 0.5
        faceOptions.minTrackingConfidence = 0.5
        faceOptions.outputFaceBlendshapes = false
        faceOptions.outputFacialTransformationMatrixes = false
        face = try FaceLandmarker(options: faceOptions)
        measurement.initializationSeconds = ProcessInfo.processInfo.systemUptime - start
    }

    func process(_ sample: CMSampleBuffer, seconds: Double, geometry: CameraGeometryObservation,
                 geometryEpoch: Int, mirrored: Bool) throws {
        guard let timestamp = timestamps.accept(seconds: seconds) else {
            measurement.skippedTimestampFrames += 1
            return
        }
        do {
            // AVFoundation physically rotates the BGRA pixels and disables capture
            // mirroring. MPImage defaults to .up; applying rotation again is wrong.
            // autoreleasepool drains each frame's Objective-C/SDK result objects.
            try autoreleasepool {
                let started = ProcessInfo.processInfo.systemUptime
                let image = try MPImage(sampleBuffer: sample)
                let handResult = try hands.detect(videoFrame: image, timestampInMilliseconds: timestamp)
                let handEnded = ProcessInfo.processInfo.systemUptime
                let faceResult = try face.detect(videoFrame: image, timestampInMilliseconds: timestamp)
                let ended = ProcessInfo.processInfo.systemUptime
                measurement.processedFrames += 1
                measurement.firstTimestampMilliseconds = measurement.firstTimestampMilliseconds ?? timestamp
                measurement.lastTimestampMilliseconds = timestamp
                measurement.totalProcessingSeconds += ended - started
                measurement.maximumProcessingSeconds = max(measurement.maximumProcessingSeconds, ended - started)
                measurement.totalHandSeconds += handEnded - started
                measurement.totalFaceSeconds += ended - handEnded
                switch handResult.landmarks.count {
                case 0: measurement.framesWithoutHands += 1
                case 1: measurement.framesWithOneHand += 1
                default: measurement.framesWithTwoHands += 1
                }
                if faceResult.faceLandmarks.isEmpty { measurement.framesWithoutFace += 1 }
                else { measurement.framesWithFace += 1 }
                // Only bounded queue-local raw points survive the callback. Reports
                // contain aggregate diagnostics, never coordinates or camera images.
                measurement.latestHandPointCounts = handResult.landmarks.prefix(2).map { $0.count }
                measurement.latestFacePointCount = faceResult.faceLandmarks.first?.count ?? 0
                measurement.latestRawHandedness = handResult.handedness.prefix(2).map {
                    $0.first?.categoryName ?? "unknown"
                }
                measurement.latestRawHandednessScores = handResult.handedness.prefix(2).map {
                    $0.first?.score ?? 0
                }
                if measurement.singleHandRawLabelCounts == nil { measurement.singleHandRawLabelCounts = [:] }
                if handResult.landmarks.count == 1 {
                    let label = measurement.latestRawHandedness.first ?? "unknown"
                    measurement.singleHandRawLabelCounts?[label, default: 0] += 1
                }
                if measurement.duplicateRawLabelFrames == nil { measurement.duplicateRawLabelFrames = 0 }
                if handResult.landmarks.count == 2, measurement.latestRawHandedness.count == 2,
                   measurement.latestRawHandedness[0] == measurement.latestRawHandedness[1] {
                    measurement.duplicateRawLabelFrames? += 1
                }
                measurement.recordHandIdentity(geometry: geometry, epoch: geometryEpoch, mirrored: mirrored)
                let resolution = measurement.handIdentity?.latestResolution ?? HandSlotResolution()
                func handPoints(_ index: Int?) -> [LandmarkPoint]? {
                    guard let index, handResult.landmarks.indices.contains(index) else { return nil }
                    return handResult.landmarks[index].map { LandmarkPoint(x: $0.x, y: $0.y, z: $0.z) }
                }
                let facePoints = faceResult.faceLandmarks.first.map {
                    $0.map { LandmarkPoint(x: $0.x, y: $0.y, z: $0.z) }
                }
                clip.append(seconds: seconds, left: handPoints(resolution.leftSourceIndex),
                            right: handPoints(resolution.rightSourceIndex), face: facePoints,
                            geometry: geometry, epoch: geometryEpoch, mirrored: mirrored)
                measurement.clip = clip.measurement
            }
        } catch {
            measurement.errorCount += 1
            measurement.lastError = String(describing: error)
            // A partially executed pair must not be retried with a reused timestamp.
            throw error
        }
    }

    func finalizeEncoding() -> (measurement: LandmarkMeasurement, features: FeatureEncoder.Encoded?) {
        let start = ProcessInfo.processInfo.systemUptime
        var features: FeatureEncoder.Encoded?
        do {
            let encoded = try FeatureEncoder.encode(clip.frames)
            features = encoded
            measurement.featureEncoding = FeatureEncodingMeasurement(
                status: "encoded; candidate inference requires a sign capture",
                validFrames: encoded.validFrames, discardedEmptyFrames: encoded.discardedEmptyFrames,
                handFrames: encoded.handFrames, tensorBytes: encoded.values.count * MemoryLayout<Float>.size,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - start)
        } catch {
            measurement.featureEncoding = FeatureEncodingMeasurement(
                status: "not encoded: \(error)", elapsedSeconds: ProcessInfo.processInfo.systemUptime - start)
        }
        return (measurement, features)
    }

    private static func verifiedPath(for pin: ModelManifest, bundle: Bundle) throws -> String {
        let name = (pin.filename as NSString).deletingPathExtension
        guard let url = bundle.url(forResource: name, withExtension: "task"),
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(pin.bytes) else {
            throw AppError.invalidModel("Missing or wrong-sized \(pin.filename). Verify the bundled landmark models before building.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            let more = try autoreleasepool {
                guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { return false }
                digest.update(data: data)
                return true
            }
            if !more { break }
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == pin.sha256 else {
            throw AppError.invalidModel("SHA-256 mismatch for bundled \(pin.filename). Landmark capture was not started.")
        }
        return url.path
    }
}
