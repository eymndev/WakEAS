@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import SwiftUI
import Vision
#if os(iOS)
import ARKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated struct EyeReading: Sendable {
    var face: Bool
    var closed: Bool
    var openness: Double
}

enum CamAuth {
    case unknown
    case granted
    case denied
    case unavailable
}

@MainActor
@Observable
final class EyeMonitor: NSObject {
    var permission: CamAuth = .unknown
    var faceVisible = false
    var eyesClosed = false
    var openness = 1.0
    var cameraReady = false
    var usingARKit = false
    var failure: String?
    private(set) var lastReadingAt = Date.distantPast

    #if os(iOS)
    @ObservationIgnored
    lazy var arView: ARSCNView = {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = true
        return view
    }()
    #endif

    nonisolated(unsafe) let captureSession = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "wakeas.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let clock = SampleClock()
    private let probe = VisionProbe(candidates: EyeMonitor.orientations, lenient: EyeMonitor.lenientFaceGate)
    private var configured = false

    func start() async {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            permission = .unavailable
            return
        }
        #if os(iOS) || os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = .granted
            beginTracking()
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            permission = ok ? .granted : .denied
            if ok { beginTracking() }
        case .denied, .restricted:
            permission = .denied
        default:
            permission = .unavailable
        }
        #else
        permission = .unavailable
        #endif
    }

    func stop() {
        #if os(iOS)
        if usingARKit {
            arView.session.pause()
            cameraReady = false
            return
        }
        #endif
        let session = captureSession
        cameraQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
        cameraReady = false
    }

    func resume() {
        guard permission == .granted else { return }
        #if os(iOS)
        if usingARKit {
            guard ARFaceTrackingConfiguration.isSupported else { return }
            let config = ARFaceTrackingConfiguration()
            config.isLightEstimationEnabled = false
            config.maximumNumberOfTrackedFaces = 1
            arView.session.run(config)
            cameraReady = true
            return
        }
        #endif
        guard configured else { return }
        let session = captureSession
        cameraQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
            Task { @MainActor in
                self.cameraReady = session.isRunning
            }
        }
    }

    private func beginTracking() {
        guard !configured else {
            resume()
            return
        }
        failure = nil
        #if os(iOS)
        if ARFaceTrackingConfiguration.isSupported {
            startARKit()
            configured = true
            return
        }
        #endif
        startVision()
    }

    #if os(iOS)
    private func startARKit() {
        usingARKit = true
        arView.session.delegate = self
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = false
        config.maximumNumberOfTrackedFaces = 1
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        cameraReady = true
    }
    #endif

    private func startVision() {
        usingARKit = false
        captureSession.beginConfiguration()
        #if os(iOS)
        captureSession.automaticallyConfiguresApplicationAudioSession = false
        #endif
        #if os(macOS)
        let presets: [AVCaptureSession.Preset] = [.hd1280x720, .high, .medium]
        #else
        let presets: [AVCaptureSession.Preset] = [.vga640x480, .medium]
        #endif
        if let preset = presets.first(where: { captureSession.canSetSessionPreset($0) }) {
            captureSession.sessionPreset = preset
        }
        guard let device = Self.pickCamera() else {
            captureSession.commitConfiguration()
            permission = .unavailable
            failure = "No camera found"
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                captureSession.commitConfiguration()
                failure = "Couldn't open the camera"
                return
            }
            captureSession.addInput(input)
            if let _ = try? device.lockForConfiguration() {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            }
        } catch {
            captureSession.commitConfiguration()
            failure = "Couldn't open the camera"
            return
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        #if os(iOS)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        #endif
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            failure = "Couldn't open the camera"
            return
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()
        configured = true
        let session = captureSession
        cameraQueue.async {
            session.startRunning()
            Task { @MainActor in
                self.cameraReady = session.isRunning
            }
        }
    }

    private func apply(_ reading: EyeReading) {
        lastReadingAt = Date()
        faceVisible = reading.face
        eyesClosed = reading.face && reading.closed
        openness = reading.openness
    }

    #if os(iOS)
    private static let orientations: [CGImagePropertyOrientation] = [
        .leftMirrored, .right, .rightMirrored, .downMirrored, .upMirrored, .left, .up, .down
    ]
    private static let lenientFaceGate = false
    #elseif os(macOS)
    private static let orientations: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .left, .right, .down, .leftMirrored, .rightMirrored
    ]
    private static let lenientFaceGate = true
    #else
    private static let orientations: [CGImagePropertyOrientation] = [.up]
    private static let lenientFaceGate = true
    #endif

    private static func pickCamera() -> AVCaptureDevice? {
        #if os(macOS)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices.filter { $0.deviceType != .deskViewCamera }
        if let builtIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtIn
        }
        if let continuity = devices.first(where: { $0.deviceType == .continuityCamera }) {
            return continuity
        }
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        return AVCaptureDevice.default(for: .video)
        #else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        #endif
    }
}

#if os(iOS)
extension EyeMonitor: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = CACurrentMediaTime()
        guard clock.allow(now, interval: 0.08) else { return }
        let reading = Self.reading(from: frame)
        Task { @MainActor in
            self.apply(reading)
        }
    }

    nonisolated private static func reading(from frame: ARFrame) -> EyeReading {
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            return EyeReading(face: false, closed: false, openness: 1)
        }
        let left = blink(face, .eyeBlinkLeft)
        let right = blink(face, .eyeBlinkRight)
        let closed = left > 0.78 && right > 0.78
        let openness = Double(1 - min(1, (left + right) * 0.5))
        return EyeReading(face: true, closed: closed, openness: openness)
    }

    nonisolated private static func blink(_ face: ARFaceAnchor, _ key: ARFaceAnchor.BlendShapeLocation) -> Float {
        face.blendShapes[key]?.floatValue ?? 0
    }
}
#endif

extension EyeMonitor: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard clock.allow(CACurrentMediaTime(), interval: 0.06) else { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = probe.nextOrientation()
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Task { @MainActor in
                self.apply(EyeReading(face: false, closed: false, openness: 1))
            }
            return
        }
        let reading = probe.interpret(request.results ?? [], used: orientation)
        Task { @MainActor in
            self.apply(reading)
        }
    }
}

nonisolated final class SampleClock: @unchecked Sendable {
    private var last = 0.0

    func allow(_ now: CFTimeInterval, interval: CFTimeInterval) -> Bool {
        if now - last < interval { return false }
        last = now
        return true
    }
}

nonisolated final class VisionProbe: @unchecked Sendable {
    private var locked: CGImagePropertyOrientation?
    private var misses = 0
    private var frames = 0
    private var lostFrames = 0
    private var leftEye: EyeTrack
    private var rightEye: EyeTrack
    private let candidates: [CGImagePropertyOrientation]
    private let lenient: Bool

    init(candidates: [CGImagePropertyOrientation], lenient: Bool) {
        self.candidates = candidates.isEmpty ? [.up] : candidates
        self.lenient = lenient
        leftEye = EyeTrack(lenient: lenient)
        rightEye = EyeTrack(lenient: lenient)
    }

    func nextOrientation() -> CGImagePropertyOrientation {
        if let locked { return locked }
        frames += 1
        if frames <= 12 { return candidates[0] }
        return candidates[(frames - 13) % candidates.count]
    }

    func interpret(_ observations: [VNFaceObservation], used: CGImagePropertyOrientation) -> EyeReading {
        let minConfidence: Float = lenient ? 0.25 : 0.40
        let minWidth: CGFloat = lenient ? 0.04 : 0.08
        guard let face = observations.max(by: { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }), face.confidence > minConfidence, face.boundingBox.width > minWidth else {
            misses += 1
            if misses > 8 { locked = nil }
            lostFrames += 1
            leftEye.interrupt(resetCalibration: lostFrames > 20)
            rightEye.interrupt(resetCalibration: lostFrames > 20)
            return EyeReading(face: false, closed: false, openness: 1)
        }
        let left = face.landmarks.flatMap { eyeOpenness($0.leftEye) }
        let right = face.landmarks.flatMap { eyeOpenness($0.rightEye) }
        let minAperture = lenient ? 0.005 : 0.02
        guard let left, let right,
              (minAperture...0.65).contains(left), (minAperture...0.65).contains(right) else {
            misses += 1
            if misses > 8 { locked = nil }
            leftEye.interrupt(resetCalibration: false)
            rightEye.interrupt(resetCalibration: false)
            return EyeReading(face: false, closed: false, openness: 1)
        }
        locked = used
        misses = 0
        lostFrames = 0
        let leftClosed = leftEye.ingest(left)
        let rightClosed = rightEye.ingest(right)
        return EyeReading(
            face: true,
            closed: leftClosed && rightClosed,
            openness: (leftEye.smooth + rightEye.smooth) / 2
        )
    }

    private func eyeOpenness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
        guard let region, region.pointCount >= 4 else { return nil }
        let pts = region.normalizedPoints
        guard pts.count >= 4 else { return nil }
        let xs = pts.map(\.x)
        guard let minX = xs.min(), let maxX = xs.max() else { return nil }
        let width = Double(maxX - minX)
        guard width > 0.0001 else { return nil }
        // Corners stay close together even with open eyes; measure the eyelids near the center.
        let center = pts.filter { point in
            let x = Double(point.x - minX) / width
            return (0.2...0.8).contains(x)
        }.map(\.y)
        if center.count >= 2, let top = center.max(), let bottom = center.min() {
            return Double(top - bottom) / width
        }
        guard lenient, let top = pts.map(\.y).max(), let bottom = pts.map(\.y).min() else { return nil }
        return Double(top - bottom) / width
    }
}

nonisolated struct EyeTrack: @unchecked Sendable {
    let lenient: Bool
    private(set) var smooth = 0.0
    private var openBaseline = 0.0
    private var hasSample = false
    private var calibrationFrames = 0
    private var closedFrames = 0

    init(lenient: Bool) {
        self.lenient = lenient
    }

    mutating func interrupt(resetCalibration: Bool) {
        closedFrames = 0
        hasSample = false
        if resetCalibration {
            openBaseline = 0
            calibrationFrames = 0
        }
    }

    mutating func ingest(_ value: Double) -> Bool {
        if hasSample {
            smooth = smooth * 0.55 + value * 0.45
        } else {
            smooth = value
            hasSample = true
        }
        // Mac landmarks have a smaller aperture; keep the iOS gate conservative.
        let minimumOpen = lenient ? 0.065 : 0.12
        let requiredCalibration = lenient ? 5 : 8
        if calibrationFrames < requiredCalibration {
            if value >= minimumOpen {
                openBaseline = calibrationFrames == 0 ? value : openBaseline * 0.8 + value * 0.2
                calibrationFrames += 1
            }
            return false
        }
        let closing = value < openBaseline * (lenient ? 0.76 : 0.6)
            && smooth < openBaseline * (lenient ? 0.80 : 0.65)
        closedFrames = closing ? closedFrames + 1 : 0
        if value >= openBaseline * 0.85 {
            openBaseline = openBaseline * 0.995 + value * 0.005
        }
        return closedFrames >= (lenient ? 2 : 4)
    }
}

#if os(iOS)
struct MonitorPreview: UIViewRepresentable {
    let monitor: EyeMonitor

    func makeUIView(context: Context) -> UIView {
        if monitor.usingARKit {
            return monitor.arView
        }
        let view = CapturePreviewView()
        view.previewLayer.session = monitor.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if monitor.usingARKit {
            return
        }
        guard let view = uiView as? CapturePreviewView else { return }
        view.previewLayer.session = monitor.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

final class CapturePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
#elseif os(macOS)
struct MonitorPreview: NSViewRepresentable {
    let monitor: EyeMonitor

    func makeNSView(context: Context) -> CapturePreviewView {
        let view = CapturePreviewView()
        view.previewLayer.session = monitor.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: CapturePreviewView, context: Context) {
        nsView.previewLayer.session = monitor.captureSession
        nsView.previewLayer.videoGravity = .resizeAspectFill
        nsView.mirrorIfNeeded()
    }
}

final class CapturePreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        mirrorIfNeeded()
    }

    func mirrorIfNeeded() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
#endif
