import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    let camera: CameraCapture
    let captureID: UUID
    var fillsView = false

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private weak var camera: CameraCapture?
        private var captureID: UUID?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var previewObservation: NSKeyValueObservation?
        private var renderingObservation: NSKeyValueObservation?
        private var lastRecordedGeometry: PreviewGeometryObservation?

        func configure(camera: CameraCapture, captureID: UUID) {
            let newCapture = self.captureID != captureID
            if newCapture {
                resetRotationObservation()
                renderingObservation?.invalidate()
                renderingObservation = nil
                lastRecordedGeometry = nil
                // The driver removes all inputs at Stop. The next capture must
                // bind to its newly created connection, even for the same session.
                previewLayer.session = nil
            }
            self.camera = camera
            self.captureID = captureID
            if previewLayer.session !== camera.session { previewLayer.session = camera.session }
            if renderingObservation == nil {
                renderingObservation = previewLayer.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] _, _ in
                    // Rendering can start after the last layout/angle callback.
                    // Delivery need not be on the main queue. Check current state
                    // and capture identity there, never carry a cached angle.
                    Task { @MainActor [weak self] in
                        guard let self, self.captureID == captureID,
                              self.previewLayer.isPreviewing else { return }
                        self.resetRotationObservation()
                        self.refreshRotation()
                        self.setNeedsLayout()
                    }
                }
            }
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                resetRotationObservation()
                lastRecordedGeometry = nil
            } else { refreshRotation() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshRotation()
        }

        func refreshRotation() {
            guard window != nil, bounds.width > 0, bounds.height > 0,
                  previewLayer.isPreviewing, let connection = previewLayer.connection,
                  let camera, let device = camera.device, let captureID else { return }
            // Outside the hierarchy the coordinator may supply a 0-degree preview
            // angle. Wait for both attachment and the live preview connection;
            // initialize again when rendering starts after session configuration.
            if rotationCoordinator == nil {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                rotationCoordinator = coordinator
                previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                    options: [.new]) { [weak self] _, _ in
                        // Apple documents main-queue delivery. Read the current
                        // angle now instead of enqueueing a cached angle for later.
                        MainActor.assumeIsolated { self?.refreshRotation() }
                    }
            }
            guard let rotationCoordinator else { return }
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
            CATransaction.commit()
            let geometry = PreviewGeometryObservation(widthPoints: Double(bounds.width),
                heightPoints: Double(bounds.height), rotationDegrees: Double(connection.videoRotationAngle),
                mirrored: connection.isVideoMirrored)
            if geometry != lastRecordedGeometry {
                lastRecordedGeometry = geometry
                camera.recordPreviewGeometry(geometry, captureID: captureID)
            }
        }

        private func resetRotationObservation() {
            previewObservation?.invalidate()
            previewObservation = nil
            rotationCoordinator = nil
        }

        func disconnect() {
            renderingObservation?.invalidate()
            renderingObservation = nil
            resetRotationObservation()
            previewLayer.session = nil
            camera = nil
            captureID = nil
            lastRecordedGeometry = nil
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .systemBackground
        view.previewLayer.videoGravity = fillsView ? .resizeAspectFill : .resizeAspect
        view.configure(camera: camera, captureID: captureID)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.videoGravity = fillsView ? .resizeAspectFill : .resizeAspect
        view.configure(camera: camera, captureID: captureID)
        view.refreshRotation()
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.disconnect()
    }
}
