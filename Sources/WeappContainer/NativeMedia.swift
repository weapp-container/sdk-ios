import Foundation
import UIKit
import AVFoundation
import CoreImage
import CoreMedia

private final class NativeCameraSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "WeappContainer.camera.frames", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame: CFTimeInterval = 0
    private let lock = NSLock()
    private var latest: ([UInt8], Int, Int, UIImage?)?
    private var scheduled = false
    var receive: (([UInt8], Int, Int, UIImage?) -> Void)?
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CACurrentMediaTime() - lastFrame >= 0.2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = CACurrentMediaTime()
        let source = CIImage(cvPixelBuffer: buffer), frame = Self.rgba(source, context: ci)
        let image = ci.createCGImage(source, from: source.extent).map { UIImage(cgImage: $0) }
        lock.lock(); latest = (frame.0, frame.1, frame.2, image)
        let schedule = !scheduled; scheduled = true; lock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.deliver() } }
    }
    private func deliver() {
        lock.lock(); let frame = latest; latest = nil; lock.unlock()
        if let frame { receive?(frame.0, frame.1, frame.2, frame.3) }
        lock.lock(); let again = latest != nil; if !again { scheduled = false }; lock.unlock()
        if again { DispatchQueue.main.async { [weak self] in self?.deliver() } }
    }
    static func rgba(_ source: CIImage, context: CIContext) -> ([UInt8], Int, Int) {
        let ratio = min(1, min(320 / max(1, source.extent.width), 240 / max(1, source.extent.height)))
        let width = max(1, Int(source.extent.width * ratio)), height = max(1, Int(source.extent.height * ratio))
        let origin = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let scaled = origin.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / source.extent.width, y: CGFloat(height) / source.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { memory in context.render(scaled, toBitmap: memory.baseAddress!, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
        return (bytes, width, height)
    }
}

/// AVFoundation camera/video frames enter the accepted Skia node's paint slot, never an overlay view.
@MainActor public final class WeappNativeMedia {
    private weak var session: WeappContainerSession?
    private weak var presenter: UIViewController?
    private let files: WeappManagedFiles
    private let allowedOrigins: Set<String>
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.files.auxiliaryRoot($0) })
    private var timer: Timer?
    private var closed = false
    private let ci = CIContext(options: [.cacheIntermediates: false])
    @MainActor private final class Mount {
        var snapshot: WeappJSON
        let context: WeappJSON
        var camera: AVCaptureSession?
        var cameraDevice: AVCaptureDevice?
        var sink: NativeCameraSink?
        var image: UIImage?
        var player: AVPlayer?
        var videoOutput: AVPlayerItemVideoOutput?
        var endedObserver: NSObjectProtocol?
        var sequence: UInt64 = 0
        var eventSequence: UInt64 = 0
        var initializing = true
        var source = ""
        var metadataSent = false
        var lastTime: Double = -1
        var videoTransform = CGAffineTransform.identity
        init(_ snapshot: WeappJSON, _ context: WeappJSON) { self.snapshot = snapshot; self.context = context }
    }
    private var mounts: [String: Mount] = [:]
    private var objects: [String: (String, WeappJSON)] = [:]
    public let supportedApis: Set<String> = ["component:camera", "component:video", "wx.createCameraContext", "object:CameraContext.takePhoto", "object:CameraContext.setZoom", "wx.createVideoContext", "object:VideoContext.play", "object:VideoContext.pause", "object:VideoContext.stop", "object:VideoContext.seek", "object:VideoContext.playbackRate"]
    public init(presenter: UIViewController, files: WeappManagedFiles, allowedMediaOrigins: Set<String> = []) { self.presenter = presenter; self.files = files; allowedOrigins = allowedMediaOrigins }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil else { throw failure("Native media already installed") }; session = target
        try target.registerHostResourceCleanup("media-\(UUID().uuidString)") { [weak self] in self?.reset() }
        for api in supportedApis.sorted() { try target.registerApiHandler(api) { [weak self] call in guard let self else { throw CancellationError() }; return try await self.invoke(api, call) } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    private func failure(_ message: String, code: WeappHostError.Code = .invalidRequest) -> WeappHostError { WeappHostError(code: code, message: message) }
    private func key(_ snapshot: WeappJSON) -> String { ["sessionId", "accountEpoch", "pageId", "nodeId"].map { snapshot[$0].string ?? "" }.joined(separator: ":") }
    private func tick() {
        guard !closed, let session else { return }
        guard session.isLoaded else { reset(); return }
        do {
            let state = try session.state()
            guard state["foreground"].bool == true, state["status"].string == "ready" else { reset(); return }
            let snapshots = try session.hostServicesCommand("hostComponents").array ?? []
            let accepted = snapshots.filter { ["camera", "video"].contains($0["tag"].string ?? "") && $0["visible"].bool == true }
            let keys = Set(accepted.map(key)); for id in Array(mounts.keys) where !keys.contains(id) { unmount(id) }
            for snapshot in accepted {
                let id = key(snapshot)
                if let mount = mounts[id] {
                    let changedCamera = snapshot["tag"].string == "camera" && ["device-position", "flash", "mode", "resolution"].contains { mount.snapshot["attributes"][$0] != snapshot["attributes"][$0] }
                    if changedCamera { unmount(id) } else { mount.snapshot = snapshot; if snapshot["tag"].string == "video" { try updateVideo(mount) }; continue }
                }
                var context = state["hostServicesState"].dictionary; context["sessionId"] = snapshot["sessionId"]
                let mount = Mount(snapshot, .object(context)); mounts[id] = mount
                if snapshot["tag"].string == "camera" { Task { @MainActor [weak self, weak mount] in guard let self, let mount else { return }; await self.startCamera(id, mount) } }
                else { try updateVideo(mount); mount.initializing = false }
            }
            for mount in Array(mounts.values) where mount.snapshot["tag"].string == "video" { try videoTick(mount) }
        } catch { session.report(error) }
    }
    private func startCamera(_ id: String, _ mount: Mount) async {
        let call = WeappHostApiCall(event: .object(["callId": .string("native-camera-\(UUID().uuidString)"), "method": .string("component:camera"), "payload": .object([:]), "context": mount.context]), cancellation: WeappHostApiCancellation())
        do {
            guard mount.snapshot["attributes"]["mode"].string ?? "normal" == "normal" else { throw failure("scanCode mode requires a barcode adapter", code: .unsupported) }
            guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") is String, try await consent.request(call, "scope.camera"), await AVCaptureDevice.requestAccess(for: .video), mounts[id] === mount else { throw failure("Camera permission denied or owner retired", code: .permissionDenied) }
            let front = mount.snapshot["attributes"]["device-position"].string == "front"
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back) else { throw failure("Camera unavailable", code: .unsupported) }
            let capture = AVCaptureSession(); capture.sessionPreset = .vga640x480
            let flash = mount.snapshot["attributes"]["flash"].string ?? "off"
            if ["on", "torch"].contains(flash) {
                guard device.hasTorch else { throw failure("Camera has no torch", code: .unsupported) }
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            }
            else if flash != "off" { throw failure("Camera flash mode is not implemented", code: .unsupported) }
            let input = try AVCaptureDeviceInput(device: device), output = AVCaptureVideoDataOutput(), sink = NativeCameraSink()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]; output.alwaysDiscardsLateVideoFrames = true
            guard capture.canAddInput(input), capture.canAddOutput(output) else { throw failure("Camera capture configuration unsupported", code: .unsupported) }
            capture.addInput(input); capture.addOutput(output); output.setSampleBufferDelegate(sink, queue: sink.queue)
            if let connection = output.connection(with: .video) { if connection.isVideoOrientationSupported {
                switch presenter?.viewIfLoaded?.window?.windowScene?.interfaceOrientation {
                case .landscapeLeft: connection.videoOrientation = .landscapeLeft
                case .landscapeRight: connection.videoOrientation = .landscapeRight
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
                }
            }; if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = front } }
            sink.receive = { [weak self, weak mount] bytes, width, height, image in MainActor.assumeIsolated {
                guard let self, let mount, self.mounts[id] === mount else { return }; mount.image = image
                do { try self.submit(mount, bytes, width, height) } catch { self.session?.report(error) }
            } }
            mount.camera = capture; mount.cameraDevice = device; mount.sink = sink
            sink.queue.sync { capture.startRunning() }; mount.initializing = false
            try event(mount, "initdone", ["maxZoom": .number(Double(device.activeFormat.videoMaxZoomFactor))])
        } catch { if mounts[id] === mount { mount.initializing = false; try? event(mount, "error", ["errMsg": .string(error.localizedDescription)]) } }
    }
    private func mediaURL(_ source: String, _ context: WeappJSON) throws -> URL {
        if source.hasPrefix("wxfile://") { return try files.resolve(source, context: context) }
        guard let url = URL(string: source), let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https", components.user == nil, components.password == nil, let host = components.host else { throw failure("Managed file or configured HTTPS media origin required", code: .permissionDenied) }
        let origin = "https://" + host.lowercased() + (components.port.map { ":\($0)" } ?? "")
        guard allowedOrigins.contains(origin) else { throw failure("Media origin not allowlisted", code: .permissionDenied) }; return url
    }
    private func updateVideo(_ mount: Mount) throws {
        let source = mount.snapshot["attributes"]["src"].string ?? ""
        guard source != mount.source else { return }
        stopVideo(mount); mount.source = source; mount.metadataSent = false; mount.lastTime = -1
        guard !source.isEmpty else { return }
        let asset = AVURLAsset(url: try mediaURL(source, mount.context), options: [AVURLAssetHTTPCookiesKey: []])
        let item = AVPlayerItem(asset: asset), output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        Task { @MainActor [weak self, weak mount] in
            guard let self, let mount else { return }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let transform = try await tracks.first?.load(.preferredTransform) ?? .identity
                if self.mounts[self.key(mount.snapshot)] === mount, mount.source == source { mount.videoTransform = transform }
            } catch { if self.mounts[self.key(mount.snapshot)] === mount { self.session?.report(error) } }
        }
        item.add(output); mount.videoOutput = output; mount.player = AVPlayer(playerItem: item)
        mount.player?.isMuted = mount.snapshot["attributes"]["muted"].string.map { $0 != "false" } ?? false
        mount.endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak mount] _ in MainActor.assumeIsolated {
            guard let self, let mount, self.mounts[self.key(mount.snapshot)] === mount else { return }
            try? self.event(mount, "ended", [:])
            if mount.snapshot["attributes"]["loop"].string.map({ $0 != "false" }) == true { mount.player?.seek(to: .zero); mount.player?.play() }
        } }
        if mount.snapshot["attributes"]["autoplay"].string.map({ $0 != "false" }) == true { mount.player?.play(); try event(mount, "play", [:]) }
    }
    private func videoTick(_ mount: Mount) throws {
        guard let player = mount.player, let item = player.currentItem, let output = mount.videoOutput else { return }
        if item.status == .failed { try event(mount, "error", ["errMsg": .string(item.error?.localizedDescription ?? "Video decode failed")]); stopVideo(mount); return }
        let duration = item.duration.seconds
        if item.status == .readyToPlay, !mount.metadataSent { mount.metadataSent = true; try event(mount, "loadedmetadata", ["duration": .number(duration.isFinite ? duration : 0), "width": .number(item.presentationSize.width), "height": .number(item.presentationSize.height)]) }
        let time = player.currentTime(), current = time.seconds
        if current.isFinite, current != mount.lastTime { mount.lastTime = current; try event(mount, "timeupdate", ["currentTime": .number(current), "duration": .number(duration.isFinite ? duration : 0)]) }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime), let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            var image = CIImage(cvPixelBuffer: buffer)
            image = image.transformed(by: mount.videoTransform)
            let frame = NativeCameraSink.rgba(image, context: ci); try submit(mount, frame.0, frame.1, frame.2)
        }
    }
    private func submit(_ mount: Mount, _ bytes: [UInt8], _ width: Int, _ height: Int) throws {
        guard let session, mounts[key(mount.snapshot)] === mount else { return }
        mount.sequence += 1
        _ = try session.hostServicesCommand("hostComponentFrame", ["sessionId": mount.snapshot["sessionId"], "accountEpoch": mount.snapshot["accountEpoch"], "pageId": mount.snapshot["pageId"], "nodeId": mount.snapshot["nodeId"], "sequence": .string(String(mount.sequence)), "width": .number(Double(width)), "height": .number(Double(height)), "format": .string("rgba8"), "pixels": .array(bytes.map { .number(Double($0)) })])
    }
    private func event(_ mount: Mount, _ event: String, _ value: [String: WeappJSON]) throws {
        mount.eventSequence += 1
        _ = try session?.hostServicesCommand("hostComponentEvent", ["sessionId": mount.snapshot["sessionId"], "accountEpoch": mount.snapshot["accountEpoch"], "nodeId": mount.snapshot["nodeId"], "sequence": .string(String(mount.eventSequence)), "event": .string(event), "value": .object(value)])
    }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        guard !call.cancellation.isCancelled else { throw CancellationError() }
        let payload = call.payload
        if api == "wx.createCameraContext" || api == "wx.createVideoContext" {
            let tag = api == "wx.createCameraContext" ? "camera" : "video"
            let target = call.context["componentTarget"]
            guard target != .null, let (key, mount) = mounts.first(where: { _, mount in mount.snapshot["tag"].string == tag && mount.snapshot["sessionId"] == call.context["sessionId"] && mount.snapshot["accountEpoch"] == call.context["account"]["epoch"] && mount.snapshot["nodeId"] == target["nodeId"] && mount.snapshot["pageId"] == target["pageId"] && mount.snapshot["ownerScopeId"] == target["ownerScopeId"] }), let id = payload["objectId"].string, objects.count < 64 else { throw failure("Context requires the runtime-resolved accepted native component") }
            objects[id] = (key, call.context); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.objects.removeValue(forKey: id) }
            _ = mount; return .object(["objectId": .string(id)])
        }
        guard let id = payload["objectId"].string, let (key, owner) = objects[id], owner["application"] == call.context["application"], owner["account"] == call.context["account"], let mount = mounts[key] else { throw failure("Native component context retired") }
        switch api {
        case "object:CameraContext.takePhoto":
            guard let image = mount.image, let data = image.jpegData(compressionQuality: payload["quality"].string == "low" ? 0.5 : payload["quality"].string == "normal" ? 0.8 : 0.95) else { throw failure("Camera has no captured frame") }
            return .object(["tempImagePath": .string(try files.importTemporary(data, extension: "jpg", context: call.context)), "width": .number(image.size.width), "height": .number(image.size.height), "errMsg": .string("\(api):ok")])
        case "object:CameraContext.setZoom":
            guard let device = mount.cameraDevice, let zoom = payload["zoom"].number, zoom.isFinite, zoom >= 1, zoom <= Double(device.activeFormat.videoMaxZoomFactor) else { throw failure("Zoom outside device range") }
            try device.lockForConfiguration(); device.videoZoomFactor = CGFloat(zoom); device.unlockForConfiguration(); return .object(["zoom": .number(zoom)])
        case "object:VideoContext.play": guard let player = mount.player else { throw failure("Video source not ready") }; player.play(); try event(mount, "play", [:])
        case "object:VideoContext.pause": mount.player?.pause(); try event(mount, "pause", [:])
        case "object:VideoContext.stop": mount.player?.pause(); await mount.player?.seek(to: .zero); try event(mount, "pause", [:])
        case "object:VideoContext.seek":
            guard let position = payload["position"].number ?? payload["args"].array?.first?.number, position.isFinite, position >= 0, let player = mount.player else { throw failure("Invalid video seek") }
            await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        case "object:VideoContext.playbackRate":
            guard let rate = payload["rate"].number ?? payload["args"].array?.first?.number, rate.isFinite, (0.5...2).contains(rate), let player = mount.player else { throw failure("Unsupported video playback rate") }; player.rate = Float(rate)
        default: throw failure("Native component API not installed", code: .unsupported)
        }
        return .object(["errMsg": .string("\(api):ok")])
    }
    private func stopVideo(_ mount: Mount) { mount.player?.pause(); mount.player?.replaceCurrentItem(with: nil); mount.player = nil; mount.videoOutput = nil; if let token = mount.endedObserver { NotificationCenter.default.removeObserver(token) }; mount.endedObserver = nil }
    private func unmount(_ id: String) {
        guard let mount = mounts.removeValue(forKey: id) else { return }
        mount.sink?.receive = nil
        if let camera = mount.camera, let sink = mount.sink { sink.queue.sync { camera.stopRunning() } }
        mount.camera = nil; mount.sink = nil; mount.cameraDevice = nil; mount.image = nil; stopVideo(mount)
        objects = objects.filter { $0.value.0 != id }
    }
    private func reset() { consent.reset(); for id in Array(mounts.keys) { unmount(id) }; objects.removeAll() }
    public func close() { closed = true; timer?.invalidate(); timer = nil; reset(); session = nil }
}
