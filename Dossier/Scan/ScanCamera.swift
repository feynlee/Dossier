import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import Vision

/// A page found in a camera frame or photo.
nonisolated struct PageOutline: Equatable, Sendable {
    /// Corners in normalized coordinates of the upright image, origin at the top-left.
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    /// Size of the upright image the corners were measured in; needed to map them onto the preview.
    var frameSize: CGSize

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// The whole image, for a photo with no page found.
    static func whole(_ size: CGSize) -> PageOutline {
        PageOutline(topLeft: .zero, topRight: CGPoint(x: 1, y: 0), bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1), frameSize: size)
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint, frameSize: CGSize) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
        self.frameSize = frameSize
    }

    init(corners: [CGPoint], frameSize: CGSize) {
        self.init(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3], frameSize: frameSize)
    }

    /// How much of the frame the page spans along its longer side, 0...1.
    var span: CGFloat {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }

    /// Below this the page is too small in the frame for its print to stay sharp. Low enough for an ID card.
    static let closeEnoughSpan: CGFloat = 0.4

    var isTooFar: Bool { span < Self.closeEnoughSpan }

    /// The largest distance any corner moved from `other`, as a share of the frame.
    func distance(to other: PageOutline) -> CGFloat {
        zip(corners, other.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }

    /// Converts the corners into a view that shows the frame with aspect-fill, as the camera preview does.
    func points(inAspectFillViewOf viewSize: CGSize) -> [CGPoint] {
        guard frameSize.width > 0, frameSize.height > 0 else { return [] }
        let scale = max(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        return corners.map { CGPoint(x: origin.x + $0.x * shown.width, y: origin.y + $0.y * shown.height) }
    }

    /// Moves part of the way towards `target`, so the outline glides instead of jittering frame to frame.
    func blended(towards target: PageOutline, amount: CGFloat) -> PageOutline {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount) }
        return PageOutline(
            topLeft: mix(topLeft, target.topLeft), topRight: mix(topRight, target.topRight),
            bottomRight: mix(bottomRight, target.bottomRight), bottomLeft: mix(bottomLeft, target.bottomLeft),
            frameSize: target.frameSize
        )
    }
}

/// Finds the page in an image: document segmentation first (it copes with curled paper and cards), then
/// rectangle detection for flat pages, which is also the only detector that works in the simulator.
nonisolated enum PageDetector {
    static let minimumConfidence: Float = 0.6
    static let minimumArea: CGFloat = 0.04

    static func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> PageOutline? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rotated = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        return detect(with: handler, frameSize: rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
    }

    static func detect(in image: CGImage) -> PageOutline? {
        detect(with: VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]), frameSize: CGSize(width: image.width, height: image.height))
    }

    private static func detect(with handler: VNImageRequestHandler, frameSize: CGSize) -> PageOutline? {
        #if !targetEnvironment(simulator)
        let segmentation = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([segmentation])) != nil,
           let observation = segmentation.results?.first,
           observation.confidence >= minimumConfidence,
           let page = outline(from: observation, frameSize: frameSize) {
            return page
        }
        #endif
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.15
        rectangles.quadratureTolerance = 25
        rectangles.minimumConfidence = 0.8
        rectangles.maximumObservations = 3
        guard (try? handler.perform([rectangles])) != nil else { return nil }
        return (rectangles.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .lazy
            .compactMap { outline(from: $0, frameSize: frameSize) }
            .first
    }

    private static func outline(from observation: VNRectangleObservation, frameSize: CGSize) -> PageOutline? {
        let box = observation.boundingBox
        guard box.width * box.height >= minimumArea else { return nil }
        // An outline hugging the whole frame is the edge of the image, not a page in it.
        guard box.width < 0.985 || box.height < 0.985 else { return nil }
        // Vision's origin is the bottom-left.
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1 - point.y) }
        return PageOutline(
            topLeft: flip(observation.topLeft), topRight: flip(observation.topRight),
            bottomRight: flip(observation.bottomRight), bottomLeft: flip(observation.bottomLeft),
            frameSize: frameSize
        )
    }
}

/// The camera session. All session work happens on a private queue, per AVFoundation guidance.
nonisolated final class ScanCamera: @unchecked Sendable {
    enum CameraError: LocalizedError {
        case accessDenied, unavailable, captureFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Dossier needs the camera to scan documents. Allow it in Settings › Privacy & Security › Camera."
            case .unavailable: "The camera isn’t available."
            case .captureFailed: "The photo couldn’t be taken. Try again."
            }
        }
    }

    let session = AVCaptureSession()
    let analyzer = FrameAnalyzer()

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "liziyue.Dossier.scan")
    private let analysisQueue = DispatchQueue(label: "liziyue.Dossier.scan.analysis", qos: .userInitiated)
    private var device: AVCaptureDevice?
    // Only touched on `sessionQueue`.
    private var isConfigured = false
    private var inFlight: [Int64: PhotoDelegate] = [:]
    private let lock = NSLock()
    /// The rotation that turns the sensor's frames upright for how the phone is held. Set by the preview.
    private var _captureAngle: CGFloat = 90

    var captureAngle: CGFloat {
        get { lock.withLock { _captureAngle } }
        set {
            lock.withLock { _captureAngle = newValue }
            analyzer.orientation = CGImagePropertyOrientation(rotationAngle: newValue)
        }
    }

    static var backCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    var cameraDevice: AVCaptureDevice? { Self.backCamera }

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.accessDenied }
        default: throw CameraError.accessDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.analysisQueue.async { self.analyzer.reset() }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    /// Takes a photo, upright for how the phone is held.
    func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.isConfigured, self.session.isRunning else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                if let connection = self.photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(self.captureAngle) {
                    connection.videoRotationAngle = self.captureAngle
                }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                let id = settings.uniqueID
                let delegate = PhotoDelegate { result in
                    self.sessionQueue.async { self.inFlight[id] = nil }
                    continuation.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = Self.backCamera, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(photoOutput) else { throw CameraError.unavailable }
        self.device = device
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
            if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
        }
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.setSampleBufferDelegate(analyzer, queue: analysisQueue)
            session.addOutput(videoOutput)
        }
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        isConfigured = true
    }
}

private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            completion(.success(image))
        } else {
            completion(.failure(ScanCamera.CameraError.captureFailed))
        }
    }
}

/// Receives camera frames and reports where the page is, a few times a second.
nonisolated final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let interval: TimeInterval = 0.12
    /// How long the outline stays after the page was last seen, so one missed frame doesn't blink it.
    static let holdDuration: TimeInterval = 0.5

    /// Called on the analysis queue with the smoothed outline, or nil once the page is gone.
    var onChange: (@Sendable (PageOutline?) -> Void)?

    private let lock = NSLock()
    private var _orientation = CGImagePropertyOrientation.right
    var orientation: CGImagePropertyOrientation {
        get { lock.withLock { _orientation } }
        set { lock.withLock { _orientation = newValue } }
    }

    // Only touched on the analysis queue.
    private var lastAnalysis = Date.distantPast
    private var lastSeen = Date.distantPast
    private var current: PageOutline?

    func reset() {
        current = nil
        lastSeen = .distantPast
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= Self.interval else { return }
        lastAnalysis = now
        if let found = PageDetector.detect(in: pixelBuffer, orientation: orientation) {
            lastSeen = now
            let next = current.map { $0.frameSize == found.frameSize ? $0.blended(towards: found, amount: 0.6) : found } ?? found
            current = next
            onChange?(next)
        } else if current != nil, now.timeIntervalSince(lastSeen) > Self.holdDuration {
            current = nil
            onChange?(nil)
        }
    }
}

nonisolated extension CGImagePropertyOrientation {
    /// The orientation that turns a back-camera sensor frame upright, given the capture rotation angle.
    init(rotationAngle angle: CGFloat) {
        switch Int((angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360).rounded()) {
        case 90: self = .right
        case 180: self = .down
        case 270: self = .left
        default: self = .up
        }
    }
}

// MARK: Preview

/// The live camera. Keeps the preview and every capture level with the horizon however the phone is held.
struct ScanCameraPreview: UIViewRepresentable {
    let camera: ScanCamera

    func makeUIView(context: Context) -> ScanPreviewView {
        let view = ScanPreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.attach(camera)
        return view
    }

    func updateUIView(_ uiView: ScanPreviewView, context: Context) {}
}

final class ScanPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private weak var camera: ScanCamera?

    func attach(_ camera: ScanCamera) {
        self.camera = camera
        previewLayer.session = camera.session
        guard let device = camera.cameraDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak camera] coordinator, _ in
                camera?.captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            },
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(sessionStarted), name: AVCaptureSession.didStartRunningNotification, object: camera.session)
    }

    @objc private func sessionStarted() {
        DispatchQueue.main.async { self.applyRotation() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    private func applyRotation() {
        guard let coordinator, let connection = previewLayer.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
}
