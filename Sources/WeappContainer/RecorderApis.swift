import Foundation
import UIKit
import AVFoundation

/// The host decides how recording leases coexist with its own shared AVAudioSession.
@MainActor public protocol WeappRecordingAudioSession {
    func acquireRecording() throws -> @MainActor () throws -> Void
    /// Retry rollback if acquireRecording threw after partially changing audio state.
    func recoverFailedAcquisition() throws
}
public extension WeappRecordingAudioSession { func recoverFailedAcquisition() throws {} }

/// Explicit option for a host with no other audio owner while the recorder is active.
@MainActor public final class WeappExclusiveRecordingAudioSession: WeappRecordingAudioSession {
    private static var leased = false
    private var failedRestore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    public init() {}
    public func acquireRecording() throws -> @MainActor () throws -> Void {
        try recoverFailedAcquisition()
        guard !Self.leased else { throw WeappHostError(code: .invalidRequest, message: "Another recording audio lease is active") }
        let audio = AVAudioSession.sharedInstance(), category = audio.category, mode = audio.mode, options = audio.categoryOptions
        try audio.setCategory(.record, mode: .default)
        do { try audio.setActive(true) }
        catch {
            Self.leased = true; failedRestore = (category, mode, options)
            do { try recoverFailedAcquisition() }
            catch let cleanup { throw WeappHostError(code: .invalidRequest, message: "Audio acquisition failed: \(error.localizedDescription); restoration requires retry: \(cleanup.localizedDescription)") }
            throw error
        }
        Self.leased = true
        var released = false
        return { guard !released else { return }; try audio.setActive(false, options: .notifyOthersOnDeactivation); try audio.setCategory(category, mode: mode, options: options); released = true; Self.leased = false }
    }
    public func recoverFailedAcquisition() throws {
        guard let (category, mode, options) = failedRestore else { return }
        let audio = AVAudioSession.sharedInstance()
        try audio.setActive(false, options: .notifyOthersOnDeactivation); try audio.setCategory(category, mode: mode, options: options)
        failedRestore = nil; Self.leased = false
    }
}

@MainActor public final class WeappRecorderApis: NSObject, AVAudioRecorderDelegate {
    private weak var presenter: UIViewController?
    private let files: WeappManagedFiles
    private let audioSession: any WeappRecordingAudioSession
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [weak self] context in guard let self else { throw CancellationError() }; return try self.files.auxiliaryRoot(context) })
    private weak var session: WeappContainerSession?
    private var closed = false
    private var sessionVisible = true
    private var generation: UInt64 = 0
    private var pendingStart: String?
    private var objects: [String: WeappHostApiCall] = [:]
    private struct Subscription { let call: WeappHostApiCall; let object: String; let event: String; var sequence: UInt64 = 0 }
    private var subscriptions: [String: Subscription] = [:]
    private final class Recording {
        let object: String; let owner: WeappHostApiCall; let recorder: AVAudioRecorder; let file: URL; let sampleRate: Double; let channels: Int; var release: (@MainActor () throws -> Void)?; var stopped = false; var duration = 0.0; var published = false
        init(_ object: String, _ owner: WeappHostApiCall, _ recorder: AVAudioRecorder, _ file: URL, _ release: @escaping @MainActor () throws -> Void, sampleRate: Double, channels: Int) { self.object = object; self.owner = owner; self.recorder = recorder; self.file = file; self.release = release; self.sampleRate = sampleRate; self.channels = channels }
    }
    private var recording: Recording?
    private final class FailedStart {
        let file: URL
        var release: (@MainActor () throws -> Void)?
        init(_ file: URL, _ release: @escaping @MainActor () throws -> Void) { self.file = file; self.release = release }
    }
    private var failedStart: FailedStart?
    private var backgroundObserver: NSObjectProtocol?
    public let supportedApis: Set<String> = ["wx.getRecorderManager", "object:RecorderManager.start", "object:RecorderManager.stop", "object:RecorderManager.pause", "object:RecorderManager.resume", "object:RecorderManager.onStart", "object:RecorderManager.onStop", "object:RecorderManager.onPause", "object:RecorderManager.onResume", "object:RecorderManager.onError", "object:RecorderManager.onInterruptionBegin"]
    public init(presenter: UIViewController, files: WeappManagedFiles, audioSession: any WeappRecordingAudioSession) { self.presenter = presenter; self.files = files; self.audioSession = audioSession; super.init() }
    public func install(in session: WeappContainerSession) throws {
        guard self.session == nil else { throw failure("Recorder already installed") }; self.session = session
        try session.registerHostAsyncResourceCleanup("recorder-\(UUID().uuidString)") { try self.reset() }
        try session.registerHostVisibilityHandler("recorder-\(UUID().uuidString)") { [weak self] visible in self?.sessionVisible = visible; if !visible { self?.invalidatePending(); do { try self?.stop(publish: true) } catch { self?.emitError(error) } } }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.invalidatePending(); do { try self?.stop(publish: true) } catch { self?.emitError(error) } } }
        for api in supportedApis.sorted() { try session.registerApiHandler(api) { [weak self] call in guard let self, !self.closed, !call.cancellation.isCancelled else { throw CancellationError() }; return try await self.invoke(api, call) } }
    }
    private func failure(_ text: String) -> WeappHostError { WeappHostError(code: .invalidRequest, message: text, details: ["errMsg": .string("RecorderManager:fail \(text)"), "errCode": .number(-1)]) }
    private func sameOwner(_ a: WeappHostApiCall, _ b: WeappHostApiCall) -> Bool { a.context["sessionId"] == b.context["sessionId"] && a.context["application"] == b.context["application"] && a.context["account"] == b.context["account"] }
    private func emit(_ object: String, _ event: String, _ value: WeappJSON = .object([:])) {
        for (id, var subscription) in subscriptions where subscription.object == object && subscription.event == event && !subscription.call.cancellation.isCancelled {
            subscription.sequence += 1; subscriptions[id] = subscription
            do { _ = try session?.emitHostApiEvent(["sessionId": subscription.call.context["sessionId"], "accountEpoch": subscription.call.context["account"]["epoch"], "subscriptionId": .string(id), "objectId": .string(object), "sequence": .string(String(subscription.sequence)), "event": .string(event), "value": value]) }
            catch { try? stop(publish: false) }
        }
    }
    private func emitError(_ error: Error) { if let recording { emit(recording.object, "Error", .object(["errMsg": .string("RecorderManager:fail \(error.localizedDescription)"), "errCode": .number(Double((error as NSError).code))])) }; try? stop(publish: false) }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let value = call.payload; guard let object = value["objectId"].string else { throw failure("Runtime recorder identity required") }
        if api == "wx.getRecorderManager" { guard objects.count < 16 else { throw failure("Recorder object limit") }; objects[object] = call; call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in if self?.recording?.object == object { try? self?.stop(publish: false) }; self?.objects.removeValue(forKey: object) }; return .object(["objectId": .string(object)]) }
        guard let owner = objects[object], sameOwner(owner, call) else { throw CancellationError() }
        if api.contains(".on") {
            guard let id = value["subscriptionId"].string else { throw failure("Recorder subscription identity required") }
            if value["action"].string == "unsubscribe" { subscriptions.removeValue(forKey: id) }
            else { guard subscriptions.count < 128 else { throw failure("Recorder subscription limit") }; subscriptions[id] = Subscription(call: call, object: object, event: String(api.split(separator: ".").last!.dropFirst(2))); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id) } }
        } else if api.hasSuffix(".start") {
            guard recording == nil, failedStart == nil, pendingStart == nil, foreground, Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String != nil else { throw failure("Idle foreground recorder and NSMicrophoneUsageDescription required") }
            pendingStart = call.id; let acceptedGeneration = generation
            defer { if pendingStart == call.id { pendingStart = nil } }
            guard try await consent.request(call, "scope.record") else { throw WeappHostError(code: .permissionDenied, message: "App microphone consent denied") }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio); try Task.checkCancellation(); guard acceptedGeneration == generation, pendingStart == call.id, foreground, !call.cancellation.isCancelled else { throw CancellationError() }; guard allowed else { throw WeappHostError(code: .permissionDenied, message: "Microphone OS permission denied") }
            try start(object, owner, value)
        } else {
            guard let recording, recording.object == object else { throw failure("Recorder is not active") }
            if api.hasSuffix(".stop") { try stop(publish: true) }
            else if api.hasSuffix(".pause") { guard !recording.stopped, recording.recorder.isRecording else { throw failure("Recorder is not recording") }; recording.recorder.pause(); emit(object, "Pause") }
            else { guard !recording.stopped, !recording.recorder.isRecording, recording.recorder.record() else { throw failure("Recorder resume failed") }; emit(object, "Resume") }
        }
        return .object(["errMsg": .string("\(api.split(separator: ".").last!):ok")])
    }
    private func start(_ object: String, _ owner: WeappHostApiCall, _ value: WeappJSON) throws {
        guard recording == nil, foreground, !owner.cancellation.isCancelled, (value["format"].string ?? "aac") == "aac" else { throw failure("This recorder supports AAC in foreground only") }
        guard value["audioSource"] == .null || value["audioSource"].string == "auto", value["audioMode"] == .null || value["audioMode"].string == "default", value["frameSize"] == .null else { throw failure("AAC recorder supports auto audioSource, default audioMode and no frameSize") }
        func integer(_ key: String, _ fallback: Double) throws -> Double { if value[key] == .null { return fallback }; guard let number = value[key].number, number.isFinite, number.rounded(.down) == number else { throw failure("\(key) must be an integer") }; return number }
        let rate = try integer("sampleRate", 8000), channels = try integer("numberOfChannels", 2), bitrate = try integer("encodeBitRate", 48000), duration = try integer("duration", 60000)
        let ranges: [Double: ClosedRange<Double>] = [8000: 16000...48000, 11025: 16000...48000, 12000: 24000...64000, 16000: 24000...96000, 22050: 32000...128000, 24000: 32000...128000, 32000: 48000...192000, 44100: 64000...320000, 48000: 64000...320000]
        guard let range = ranges[rate], range.contains(bitrate), [1, 2].contains(channels), (100...60000).contains(duration) else { throw failure("Recorder option outside supported bounds or bitrate incompatible with sampleRate") }
        let file = try files.auxiliaryRoot(owner.context).appendingPathComponent("recording-\(UUID().uuidString).m4a"), release = try audioSession.acquireRecording()
        do {
            let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: Int(channels), AVEncoderBitRateKey: Int(bitrate)])
            recorder.delegate = self; guard recorder.prepareToRecord(), recorder.record(forDuration: duration / 1000) else { throw failure("Native recorder rejected recording") }
            recording = Recording(object, owner, recorder, file, release, sampleRate: rate, channels: Int(channels)); emit(object, "Start")
        } catch {
            // A failed native start can still own a host audio lease. Retain
            // that lease and staging path until actual rollback succeeds.
            failedStart = FailedStart(file, release)
            do { try retireFailedStart() }
            catch let cleanupError { throw failure("Recorder startup failed: \(error.localizedDescription); cleanup requires retry: \(cleanupError.localizedDescription)") }
            throw error
        }
    }
    private func stop(publish: Bool) throws {
        guard let active = recording else { return }
        if !active.stopped { active.duration = active.recorder.currentTime; active.recorder.stop(); active.stopped = true }
        if active.duration <= 0, let file = try? AVAudioFile(forReading: active.file), file.processingFormat.sampleRate > 0 { active.duration = Double(file.length) / file.processingFormat.sampleRate }
        if let release = active.release { try release(); active.release = nil }
        if publish, !active.published, !active.owner.cancellation.isCancelled, !closed {
            let properties = try active.file.resourceValues(forKeys: [.fileSizeKey]); guard let size = properties.fileSize, size > 0, size <= 4 * 1048576 else { throw failure("Recorder output byte limit") }
            let format = try AVAudioFile(forReading: active.file).processingFormat
            guard format.sampleRate == active.sampleRate, Int(format.channelCount) == active.channels else {
                let error = failure("Native encoder format differs from requested sampleRate/numberOfChannels")
                if FileManager.default.fileExists(atPath: active.file.path) { try FileManager.default.removeItem(at: active.file) }; recording = nil
                emit(active.object, "Error", .object(["errMsg": .string(error.message), "errCode": .number(-1)])); throw error
            }
            let path = try files.importTemporary(Data(contentsOf: active.file), extension: "m4a", context: active.owner.context)
            emit(active.object, "Stop", .object(["tempFilePath": .string(path), "duration": .number(active.duration * 1000), "fileSize": .number(Double(size))])); active.published = true
        }
        if FileManager.default.fileExists(atPath: active.file.path) { try FileManager.default.removeItem(at: active.file) }; recording = nil
    }
    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { Task { @MainActor [weak self] in guard self?.recording?.recorder === recorder else { return }; do { if !flag { throw self!.failure("Native recorder interrupted") }; try self?.stop(publish: true) } catch { self?.emitError(error) } } }
    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { Task { @MainActor [weak self] in guard self?.recording?.recorder === recorder else { return }; if let object = self?.recording?.object { self?.emit(object, "InterruptionBegin") }; self?.emitError(error ?? WeappHostError(code: .invalidRequest, message: "Audio encoder error")) } }
    private var foreground: Bool { sessionVisible && UIApplication.shared.applicationState != .background && presenter?.viewIfLoaded?.window != nil }
    private func invalidatePending() { generation += 1; pendingStart = nil; consent.reset() }
    private func retireFailedStart() throws {
        guard let pending = failedStart else { return }
        if let release = pending.release { try release(); pending.release = nil }
        if FileManager.default.fileExists(atPath: pending.file.path) { try FileManager.default.removeItem(at: pending.file) }
        failedStart = nil
    }
    private func reset() throws { invalidatePending(); try retireFailedStart(); try stop(publish: false); try audioSession.recoverFailedAcquisition(); objects.removeAll(); subscriptions.removeAll() }
    public func close() throws { guard !closed else { return }; try reset(); closed = true; if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer); backgroundObserver = nil } }
}
