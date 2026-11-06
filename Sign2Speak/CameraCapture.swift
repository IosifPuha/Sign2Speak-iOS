import AVFoundation
import CoreMedia
import Foundation

enum CameraError: LocalizedError {
    case denied, restricted, unavailable, configuration

    var errorDescription: String? {
        switch self {
        case .denied: return "Camera access is denied. Allow Camera in Settings, then try again."
        case .restricted: return "Camera access is restricted on this device."
        case .unavailable: return "A front camera is not available on this device."
        case .configuration: return "The camera could not configure a 640 × 480 video session."
        }
    }
}

// Capture/session state belongs to queue. The two explicitly main-actor properties
// own orientation observation independently of the preview's view lifetime.
// No sample buffer crosses this queue or survives its callback.
final class CameraCapture: NSObject, CameraDriver, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    private let queue = DispatchQueue(label: "dev.sign2speak.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var id: UUID?
    private var completion: CheckedContinuation<CapturedCameraClip, Error>?
    private var progress: (@Sendable (CameraProgress) async -> Void)?
    private var measurement: CameraMeasurement?
    private var deadline: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var rotationAngle: CGFloat = 90
    @MainActor private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var captureRotationObservation: NSKeyValueObservation?
    private var pendingPreviewGeometry: (id: UUID, value: PreviewGeometryObservation)?
    private var lastPublication = 0.0
    private var publicationPending = false
    private var progressTask: Task<Void, Never>?
    private var pendingStop: (id: UUID, reason: String)?
    private var landmarkProcessor: LandmarkProcessor?
    private var pendingFinishReason: String?
    private var continuousState: ContinuousSigningState?
    private var continuousClassifier: ContinuousClassifier?
    private var lastFrameUptime = 0.0

    override init() {
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                let reason = notification.name == AVCaptureSession.wasInterruptedNotification
                    ? "Camera session interrupted" : "Camera runtime error"
                self?.queue.async { [weak self] in self?.finish(reason: reason) }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func capture(id: UUID, configuration: CameraConfiguration,
                 progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CameraMeasurement {
        (try await captureClip(id: id, configuration: configuration, progress: progress)).measurement
    }

    func captureClip(id: UUID, configuration: CameraConfiguration,
                     progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CapturedCameraClip {
        // Enqueue the current capture angle before configuration. Keep observing
        // between captures, including when the SwiftUI preview is absent/offscreen.
        await prepareCaptureRotation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.id == nil, [20, 30].contains(configuration.framesPerSecond) else {
                    continuation.resume(throwing: AppError.invalidState); return
                }
                if let stop = self.pendingStop, stop.id == id {
                    self.pendingStop = nil
                    var value = configuration.measurement(id: id)
                    value.outcome = stop.reason
                    value.completionKind = .cancelled
                    value.endedAt = Date()
                    continuation.resume(returning: CapturedCameraClip(measurement: value))
                    return
                }
                self.pendingStop = nil
                self.id = id
                self.completion = continuation
                self.progress = progress
                self.measurement = configuration.measurement(id: id)
                if let pending = self.pendingPreviewGeometry, pending.id == id {
                    self.measurement?.observePreviewGeometry(pending.value)
                }
                self.pendingPreviewGeometry = nil
                self.pendingFinishReason = nil
                self.continuousState = configuration.mode == .continuousSigning ? ContinuousSigningState() : nil
                self.lastPublication = 0
                self.publicationPending = false
                self.publish(.stage("requesting camera permission"))
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: self.start()
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        self.queue.async {
                            // Stop/background may have completed while the system prompt was open.
                            guard self.id == id else { return }
                            if granted { self.start() }
                            else { self.finish(reason: "Camera permission denied", error: CameraError.denied) }
                        }
                    }
                case .denied: self.finish(reason: "Camera permission denied", error: CameraError.denied)
                case .restricted: self.finish(reason: "Camera permission restricted", error: CameraError.restricted)
                @unknown default: self.finish(reason: "Camera unavailable", error: CameraError.unavailable)
                }
            }
        }
    }

    func stop(id: UUID, reason: String) async {
        // Enqueued on the same queue as configuration and frame delivery. Completion
        // returns only after stopRunning and teardown, before another mode can start.
        await withCheckedContinuation { continuation in
            queue.async {
                if self.id == id {
                    self.finish(reason: reason, completion:
                        ["Sign capture completed by user", "Utterance finished by user"].contains(reason) ? .userFinished : .cancelled)
                }
                else if self.id == nil {
                    // Async calls may reach the capture queue out of order. Remember
                    // one preemptive stop so that a delayed start cannot activate it.
                    self.pendingStop = (id, reason)
                }
                continuation.resume()
            }
        }
    }

    func setCaptureRotation(_ angle: CGFloat) {
        guard angle.isFinite else { return }
        queue.async {
            self.rotationAngle = angle
            self.applyRotation()
        }
    }

    @MainActor
    private func prepareCaptureRotation() {
        guard let device else { return }
        if captureRotationCoordinator == nil {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            captureRotationCoordinator = coordinator
            captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                options: [.new]) { [weak self] coordinator, _ in
                    self?.setCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
                }
        }
        // Queue this read on the main actor alongside observer updates. Do not
        // return an angle for later assignment: a newer KVO update could arrive
        // before capture starts and then be overwritten by that older snapshot.
        setCaptureRotation(captureRotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90)
    }

    func recordPreviewGeometry(_ value: PreviewGeometryObservation, captureID: UUID) {
        queue.async {
            if self.id == captureID {
                self.measurement?.observePreviewGeometry(value)
            } else if self.id == nil {
                // SwiftUI may attach before capture reaches this queue. The UUID
                // prevents a delayed old preview update from entering a new capture.
                self.pendingPreviewGeometry = (captureID, value)
            }
        }
    }

    private func start() {
        guard id != nil else { return }
        do {
            guard let device else { throw CameraError.unavailable }
            if measurement?.captureMode?.usesLandmarks == true {
                publish(.stage("verifying models and initializing hand/face tasks"))
                landmarkProcessor = try LandmarkProcessor()
                if continuousState != nil {
                    publish(.stage("initializing continuous sign classifier"))
                    continuousClassifier = try ContinuousClassifier()
                    if let classifier = continuousClassifier {
                        continuousState?.recordRuntime(version: classifier.runtimeVersion, modelSHA256: classifier.modelSHA256)
                    }
                }
                measurement?.landmarks = landmarkProcessor?.measurement
                if let measurement { publish(.frames(measurement)) }
            }
            publish(.stage("starting camera"))
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            do {
                guard session.canSetSessionPreset(.vga640x480), session.canAddInput(input) else { throw CameraError.configuration }
                session.sessionPreset = .vga640x480
                session.addInput(input)
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw CameraError.configuration }
                session.addOutput(output)
                applyRotation()
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()
                throw error
            }
            // Best effort: some active formats cannot deliver the requested rate.
            let requestedFPS = measurement?.requestedFramesPerSecond ?? 20
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= Double(requestedFPS) && $0.maxFrameRate >= Double(requestedFPS)
            }) {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(requestedFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(requestedFPS))
                device.unlockForConfiguration()
            }
            let frameDuration = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            if frameDuration.isFinite, frameDuration > 0 { measurement?.configuredFramesPerSecond = 1 / frameDuration }
            session.startRunning() // Blocking API; never run on the UI thread.
            guard session.isRunning else { throw CameraError.configuration }
            measurement?.captureStartedAt = Date()
            measurement?.captureStartUptime = ProcessInfo.processInfo.systemUptime
            lastFrameUptime = ProcessInfo.processInfo.systemUptime
            publish(.stage(landmarkProcessor == nil ? "capturing camera frames" : "capturing hand/face landmarks"))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            if continuousState != nil { timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250)) }
            else { timer.schedule(deadline: .now() + .seconds(measurement?.durationLimitSeconds ?? 10)) }
            timer.setEventHandler { [weak self] in
                guard let self, let value = self.measurement else { return }
                if self.continuousState != nil {
                    if ProcessInfo.processInfo.systemUptime - self.lastFrameUptime > 3 {
                        self.finish(reason: "Camera frames stopped arriving", completion: .failed)
                    } else if value.captureLimitReached(at: ProcessInfo.processInfo.systemUptime) {
                        self.finish(reason: value.durationLimitOutcome, completion: .durationLimit)
                    }
                } else { self.finish(reason: value.durationLimitOutcome, completion: .durationLimit) }
            }
            deadline = timer
            timer.resume()
        } catch { finish(reason: "Camera failed", error: error) }
    }

    private func applyRotation() {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle), connection.videoRotationAngle != rotationAngle {
            connection.videoRotationAngle = rotationAngle
        }
        // Mirroring is for the preview only. Classifier input must have a stable contract.
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        measurement?.captureRotationDegrees = Double(connection.videoRotationAngle)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let id, var value = measurement, value.frames < value.frameLimit, value.captureEndUptime == nil,
              (value.landmarks?.errorCount ?? 0) == 0,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // A timer on this busy queue can arrive late. Enforce the admission limit
        // before another native detection starts, even if frames are queued ahead.
        if value.captureLimitReached(at: ProcessInfo.processInfo.systemUptime) {
            requestFinish(reason: value.durationLimitOutcome, completion: .durationLimit)
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(timestamp)
        if timestamp.isValid, seconds.isFinite,
           value.lastFrameTimestampSeconds.map({ seconds > $0 }) ?? true {
            value.firstFrameTimestampSeconds = value.firstFrameTimestampSeconds ?? seconds
            value.lastFrameTimestampSeconds = seconds
        } else { value.invalidTimestampCount += 1 }
        value.captureMirrored = connection.isVideoMirrored
        value.observeGeometry(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                              rotation: Double(connection.videoRotationAngle))
        value.frames += 1
        if value.frames == 1 || value.frames % 20 == 0 {
            var brightness = value.frameBrightness ?? FrameBrightnessMeasurement()
            brightness.record(Self.sampleBrightness(image))
            value.frameBrightness = brightness
        }
        measurement = value
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        // Both tasks finish on this queue before another frame can be processed.
        // Invalid PTS is never sent to a tracking graph. AVFoundation drops late frames.
        if let landmarkProcessor {
            do {
                let geometry = CameraGeometryObservation(frameNumber: value.frames, width: value.width,
                    height: value.height, rotationDegrees: Double(connection.videoRotationAngle))
                try landmarkProcessor.process(sampleBuffer, seconds: timestamp.isValid ? seconds : .nan,
                    geometry: geometry, geometryEpoch: value.geometryChangeCount ?? 0,
                    mirrored: connection.isVideoMirrored)
                value.landmarks = landmarkProcessor.measurement
                if var state = continuousState {
                    // Never treat a timestamp skip or missing callback as no hands.
                    guard value.invalidTimestampCount == 0,
                          landmarkProcessor.latestFrame?.seconds == seconds,
                          value.geometryChangeCount == 0 || value.geometryChangeCount == nil,
                          landmarkProcessor.measurement.clip?.resetCount == 0 else {
                        requestFinish(reason: "Continuous capture lost timestamp or geometry continuity", completion: .interrupted)
                        return
                    }
                    let previousPresence = state.feedback.handsVisible
                    let ended = state.observe(seconds: seconds,
                        handsVisible: !landmarkProcessor.measurement.latestHandPointCounts.isEmpty)
                    let attemptedInference = state.shouldInfer(seconds: seconds)
                    if attemptedInference, let classifier = continuousClassifier {
                        if let features = try landmarkProcessor.continuousFeatures(since: max(state.segmentStart ?? seconds, seconds - 2.5)) {
                            let prediction = try classifier.classify(features)
                            state.accept(prediction.candidates, seconds: seconds, invokeSeconds: prediction.invokeSeconds)
                        } else { state.rejectWindow() }
                    }
                    let changed = state.glosses.count != continuousState?.glosses.count
                    continuousState = state
                    value.continuous = state.measurement
                    measurement = value
                    if attemptedInference || previousPresence != state.feedback.handsVisible || ended {
                        publish(.recognition(state.feedback))
                    }
                    if changed { publish(.continuous(state.glosses)) }
                    if ended {
                        requestFinish(reason: "No hands detected for \(Int(state.measurement.noHandsTimeoutSeconds)) seconds", completion: .handsAbsent)
                        return
                    }
                    if state.glosses.count == 8 {
                        requestFinish(reason: "Eight-sign utterance limit reached; review before finishing", completion: .tokenLimit)
                        return
                    }
                }
                measurement = value
            } catch {
                value.landmarks = landmarkProcessor.measurement
                measurement = value
                requestFinish(reason: "Landmark processing failed: \(error)")
                return
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublication >= 0.5, !publicationPending {
            lastPublication = now
            publicationPending = true
            if let continuousState { publish(.recognition(continuousState.feedback)) }
            publish(.frames(value), publicationID: id)
        }
        if value.captureLimitReached(at: now) {
            requestFinish(reason: value.durationLimitOutcome, completion: .durationLimit)
        } else if value.frames >= value.frameLimit {
            requestFinish(reason: value.frameLimitOutcome, completion: .frameLimit)
        }
    }

    private static func sampleBrightness(_ image: CVPixelBuffer) -> FrameBrightnessSample? {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(image) else { return nil }
        return FrameBrightnessSample.bgra(
            UnsafeRawBufferPointer(start: address, count: CVPixelBufferGetDataSize(image)),
            width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
            bytesPerRow: CVPixelBufferGetBytesPerRow(image))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if measurement?.captureEndUptime == nil { measurement?.droppedFrames += 1 }
    }

    private func requestFinish(reason: String, completion: CameraCompletionKind = .failed) {
        guard let id, measurement?.captureEndUptime == nil else { return }
        pendingFinishReason = reason
        measurement?.completionKind = completion
        measurement?.markCaptureEnded(at: ProcessInfo.processInfo.systemUptime)
        output.setSampleBufferDelegate(nil, queue: nil)
        // Leave the delegate callback before blocking session teardown. Already
        // queued callbacks fail admission; capture and teardown have separate clocks.
        queue.async { [weak self] in
            guard let self, self.id == id else { return }
            self.finish(reason: reason)
        }
    }

    private func publish(_ event: CameraProgress, publicationID: UUID? = nil) {
        let callback = progress
        let previous = progressTask
        progressTask = Task {
            await previous?.value
            await callback?(event)
            if let publicationID {
                self.queue.async { if self.id == publicationID { self.publicationPending = false } }
            }
        }
    }

    private func finish(reason: String, completion kind: CameraCompletionKind = .interrupted, error: Error? = nil) {
        guard var value = measurement, let continuation = completion else { return }
        value.completionKind = error == nil ? (value.completionKind ?? kind) : .failed
        value.markCaptureEnded(at: ProcessInfo.processInfo.systemUptime)
        publish(.stage("releasing camera and landmark resources"))
        deadline?.cancel()
        deadline = nil
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
        var features: FeatureEncoder.Encoded?
        if let landmarkProcessor, continuousState == nil {
            let result = landmarkProcessor.finalizeEncoding()
            value.landmarks = result.measurement
            if value.captureMode == .signCandidates { features = result.features }
        }
        // finish runs after the synchronous detector returns; native objects are
        // released before the completion unlocks import/load/generation controls.
        landmarkProcessor = nil
        continuousClassifier = nil
        let automaticGlosses = continuousState?.glosses ?? []
        value.continuous = continuousState?.measurement
        continuousState = nil
        let released = ProcessInfo.processInfo.systemUptime
        if let start = value.captureStartUptime { value.elapsedSeconds = released - start }
        if let end = value.captureEndUptime { value.teardownSeconds = released - end }
        value.outcome = pendingFinishReason ?? reason
        value.endedAt = Date()
        id = nil
        completion = nil
        measurement = nil
        progress = nil
        progressTask = nil
        pendingFinishReason = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: CapturedCameraClip(measurement: value, features: features, automaticGlosses: automaticGlosses)) }
    }
}
