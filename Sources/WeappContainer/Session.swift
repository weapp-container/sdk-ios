import Foundation
import UIKit
import WeappContainerNative

/// Owns a single mini-program. Commands and callbacks run on the UIKit main actor.
/// Keep the session for reattachment, and await close() to persist and release it.
@MainActor public final class WeappContainerSession {
    public typealias HostMethod = @MainActor (WeappJSON) async throws -> WeappJSON
    public let configuration: WeappContainerConfiguration
    public var onEvent: ((WeappContainerEvent) -> Void)?
    public private(set) var isClosed = false
    public private(set) var isLoaded = false
    public private(set) var frameRevision: UInt64 = 0
    public private(set) var isForeground = false
    public static var version: String { String(cString: weapp_container_sdk_version()) }

    private var native: NativeOwner?
    private var metrics: WeappJSON?
    private var metricsWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var methods: [String: HostMethod] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var flushes: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var closeWaiter: CheckedContinuation<Void, Error>?
    private var closeResult: Result<Void, Error>?
    private var nativeCloseResult: Result<Void, Error>?
    private var gate = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var requestedForeground = true
    private var surfaceForeground = false
    private var surface: MetalSurface?
    private var events: [WeappContainerEvent] = []
    private var eventDeliveryScheduled = false

    public init(configuration: WeappContainerConfiguration) { self.configuration = configuration }
    deinit {
        timer?.invalidate(); for task in jobs.values { task.cancel() }
        let p = surface, owner = native
        // Retain both GPU and native owners through asynchronous final cleanup.
        Task { @MainActor in
            await p?.drain()
            do {
                if p?.attached == true, let owner {
                    _ = try owner.call { h, result in weapp_container_sdk_metal_detach(h, &result) }
                    p?.attached = false
                }
                try owner?.destroy()
            } catch { NSLog("WeappContainer final cleanup failed: %@", error.localizedDescription) }
        }
    }

    public func registerHostMethod(_ name: String, handler: @escaping HostMethod) throws {
        try ensureOpen()
        guard !isLoaded, !gate else { throw failure("ERR_INVALID_STATE", "Register host methods before loading") }
        guard !name.isEmpty, !name.hasPrefix("wx.") else { throw failure("ERR_INVALID_REQUEST", "Host method names must be nonempty and cannot use wx.*") }
        methods[name] = handler
    }

    /// Waits for a view attached to a window with positive, measured bounds.
    /// Cancellation before that layout does not initialize the mini-program.
    public func load(packURL: URL, route: String? = nil, options: [String: WeappJSON] = [:]) async throws {
        _ = try await replacePack(packURL: packURL, route: route, options: options, development: false)
    }

    /// Presentation-only updates retain the live session and Metal attachment.
    /// A restart drains and detaches the old target before invoking SDK load.
    public func applyDevPack(packURL: URL, route: String? = nil, options: [String: WeappJSON] = [:]) async throws -> WeappJSON {
        try await replacePack(packURL: packURL, route: route, options: options, development: true)
    }

    public func devState() throws -> WeappJSON { try ensureAvailable(); return try command("devState") }
    public func clearDevStorage() async throws {
        try ensureAvailable()
        _ = try command("clearDevStorage")
        try await flushStorage()
    }

    private func replacePack(packURL: URL, route: String?, options: [String: WeappJSON], development: Bool) async throws -> WeappJSON {
        try ensureOpen()
        try await waitForMetrics()
        await acquireGate()
        defer { releaseGate() }
        try ensureOpen()
        try Task.checkCancellation()
        guard packURL.isFileURL else { throw failure("ERR_INVALID_REQUEST", "load requires a verified local portable-pack directory") }
        var payload: [String: WeappJSON] = ["packPath": .string(packURL.path), "options": .object(options)]
        if let route { payload["route"] = .string(route) }
        var restart = true
        if development, isLoaded {
            let classification = try command("classifyDevPack", payload)
            guard let kind = classification["reloadKind"].string, ["inPlace", "restart"].contains(kind) else {
                throw failure("ERR_INVALID_REQUEST", "Invalid development reload classification")
            }
            restart = kind == "restart"
        }
        let p = surface
        p?.cancelInput?()
        await p?.drain()
        try ensureOpen()
        if restart { try p?.detach() }
        var loadError: Error?
        var result: WeappJSON = .null
        do {
            if !isLoaded {
                try native?.destroy()
                native = try NativeOwner(config: makeConfig())
                for name in methods.keys.sorted() { _ = try command("registerHostMethod", ["name": .string(name)]) }
                startPump()
            }
            result = try command(development ? "applyDevPack" : "load", payload)
            isLoaded = true
            if restart {
                if let metrics { _ = try command("windowMetrics", metrics.dictionary) }
                _ = try command("lifecycle", ["event": .string(isForeground ? "show" : "hide")])
            }
        } catch { loadError = error }
        // Failed validation/startup keeps the previous runtime. A failure after
        // accepted startup may require explicit rollback; no old JS heap claim.
        if isLoaded {
            do { if restart { try p?.attach() }; p?.invalidate() }
            catch { if loadError == nil { loadError = error }; report(error) }
        }
        if let loadError { throw loadError }
        return result
    }

    public func sendMessage(_ message: WeappJSON) throws { try ensureAvailable(); _ = try command("sendMessage", ["message": message]) }
    public func navigate(route: String, query: [String: WeappJSON] = [:], replace: Bool = false) throws {
        try ensureAvailable(); _ = try command("navigate", ["route": .string(route), "query": .object(query), "replace": .bool(replace)])
    }
    public func back() throws { try ensureAvailable(); _ = try command("back") }
    /// Allows a host feature or framework controller to suspend this session.
    /// Resuming also requires a visible view in an active scene. View polling
    /// cannot override an explicit host suspension; completion pumping continues.
    public func setForeground(_ active: Bool) throws {
        try ensureOpen()
        surface?.observeVisibility?()
        if !active { surface?.cancelInput?() }
        requestedForeground = active
        try applyForeground()
        surface?.observeVisibility?()
    }
    public func state() throws -> WeappJSON { try ensureOpen(); return try command("state") }
    public func capabilities() throws -> WeappJSON { try ensureOpen(); return try command("capabilities") }

    public func flushStorage() async throws {
        try ensureAvailable()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do {
                guard let native else { throw failure("ERR_NOT_READY", "No native session") }
                let value = try native.command("flushStorage", .object([:]))
                if value["pending"].bool == true, let ticket = value["ticket"].number {
                    flushes[UInt64(ticket)] = c
                } else { c.resume() }
                // A fast writer may already have completed. Register its waiter
                // before consuming events, in the same main-actor transaction.
                drainEvents()
            } catch { drainEvents(); c.resume(throwing: error) }
        }
    }

    /// Drains submitted Metal work, detaches the surface, then awaits durable storage.
    /// This is idempotent and may be called with a view still attached.
    public func close() async throws {
        if let closeResult { return try closeResult.get() }
        surface?.cancelInput?()
        closing = true
        let waiting = metricsWaiters.values; metricsWaiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: failure("ERR_CLOSED", "Session closed before layout")) }
        await acquireGate()
        defer { releaseGate() }
        if let closeResult { return try closeResult.get() }
        await surface?.drain()
        try surface?.detach()
        if native != nil, !isClosed {
            do {
                // Install before command: memory-only close can emit closed immediately.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    closeWaiter = continuation
                    do { _ = try command("close") }
                    catch { closeWaiter = nil; continuation.resume(throwing: error) }
                }
            } catch {
                // A persistence failure is still a completed shutdown; preserve
                // it while destroying the closed native owner below.
                guard isClosed else { throw error }
            }
        }
        // Destruction may fail. Keep the handle and native close result so a
        // later close retries cleanup without waiting for a second closed event.
        try native?.destroy()
        native = nil
        if !isClosed { isClosed = true; enqueue(.closed(nil)) }
        timer?.invalidate(); timer = nil
        let result = nativeCloseResult ?? .success(())
        closeResult = result
        return try result.get()
    }

    func claim(_ newSurface: MetalSurface) throws {
        try ensureOpen()
        guard surface == nil else { throw failure("ERR_SURFACE_ATTACHED", "A session supports exactly one view") }
        if isLoaded { try newSurface.attach() }
        surface = newSurface
    }
    func release(_ oldSurface: MetalSurface) async throws {
        await acquireGate(); defer { releaseGate() }
        oldSurface.cancelInput?()
        await oldSurface.drain()
        try oldSurface.detach()
        if surface === oldSurface { surface = nil; metrics = nil; setSurfaceForeground(false) }
    }
    func updateMetrics(_ value: WeappJSON) {
        guard !closing, !isClosed, metrics != value else { return }
        metrics = value
        let waiting = metricsWaiters.values; metricsWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        if isLoaded, !gate {
            do { _ = try command("windowMetrics", value.dictionary) }
            catch { report(error) }
            // Geometry commits before onResize. A hook error must not revert it.
            surface?.invalidate()
        }
    }
    func setSurfaceForeground(_ active: Bool) {
        guard !closing, !isClosed else { return }
        surfaceForeground = active
        do { try applyForeground() } catch { report(error) }
    }
    private func applyForeground() throws {
        let active = requestedForeground && surfaceForeground
        let changed = active != isForeground; isForeground = active
        if changed, isLoaded, !gate {
            _ = try command("lifecycle", ["event": .string(active ? "show" : "hide")])
        }
    }
    var canPresent: Bool { isLoaded && isForeground && !closing && !isClosed && !gate }
    func presentationIdentity() throws -> (generation: WeappJSON, revision: UInt64) {
        let value = try command("state")
        guard let generation = value["generation"].number, let revision = value["frameRevision"].number,
              generation >= 0, revision >= 0, generation.isFinite, revision.isFinite,
              generation.rounded(.down) == generation, revision.rounded(.down) == revision,
              revision < Double(UInt64.max) else {
            throw failure("ERR_RENDER", "Runtime returned an invalid presentation identity")
        }
        return (.number(generation), UInt64(revision))
    }
    func acknowledgePresentation(generation: WeappJSON, revision: UInt64) throws {
        _ = try command("presented", ["generation": generation, "revision": .number(Double(revision))])
    }
    func input(_ values: [WeappJSON], cancellation: Bool = false) throws {
        if cancellation { try ensureOpen(); guard isLoaded else { return } } else { try ensureAvailable() }
        _ = try command("input", ["events": .array(values)])
    }
    func metal(_ operation: (OpaquePointer, inout weapp_container_sdk_buffer) -> Int32) throws {
        guard let native else { throw failure("ERR_NOT_READY", "Wait for load and layout") }
        _ = try native.call(operation)
    }
    func report(_ error: Error) { enqueue(.error(error as? WeappContainerError ?? failure("ERR_HOST", error.localizedDescription))) }

    private func ensureOpen() throws { if closing || isClosed { throw failure("ERR_CLOSED", "Session is closing or closed") } }
    private func ensureAvailable() throws {
        try ensureOpen()
        guard isLoaded, !gate else { throw failure("ERR_NOT_READY", "Session is loading or has no app") }
    }
    private func failure(_ code: String, _ message: String) -> WeappContainerError { WeappContainerError(code: code, message: message) }
    private func waitForMetrics() async throws {
        if metrics != nil { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()) }
                else { metricsWaiters[id] = c }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.metricsWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) } })
    }
    private func acquireGate() async {
        if gate { await withCheckedContinuation { gateWaiters.append($0) } }
        else { gate = true }
    }
    private func releaseGate() {
        if !gateWaiters.isEmpty { gateWaiters.removeFirst().resume() }
        else { gate = false }
    }
    private func makeConfig() throws -> WeappJSON {
        guard let metrics else { throw failure("ERR_NOT_READY", "A measured viewport is required") }
        guard configuration.gpuRequired != false else { throw failure("ERR_UNSUPPORTED_CAPABILITY", "iOS native preview requires GPU") }
        var display = metrics.dictionary
        display.removeValue(forKey: "windowWidth"); display.removeValue(forKey: "windowHeight")
        var config: [String: WeappJSON] = ["engine": .string("quickjs"), "sessionId": .string(configuration.sessionID), "host": .object([
            "kind": .string("ios"), "platform": .string("ios"), "version": .string(UIDevice.current.systemVersion),
            "user_agent": .string("WeappContainer/\(Self.version) iOS"),
            "windowWidth": metrics["windowWidth"], "windowHeight": metrics["windowHeight"], "displayMetrics": .object(display)
        ])]
        if let required = configuration.gpuRequired { config["gpuRequired"] = .bool(required) }
        if configuration.devDiagnostics { config["devDiagnostics"] = .bool(true) }
        if case .persistent(let key, let suppliedRoot) = configuration.storage {
            guard !key.isEmpty else { throw failure("ERR_INVALID_REQUEST", "Persistent storage requires a stable nonempty key") }
            let root = try suppliedRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WeappContainer", isDirectory: true)
            guard root.isFileURL else { throw failure("ERR_INVALID_REQUEST", "Storage root must be a local directory") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            config["storageKey"] = .string(key); config["storageRoot"] = .string(root.path)
        }
        return .object(config)
    }
    private func startPump() {
        guard timer == nil else { return }
        // This timer remains independent of CADisplayLink and scene visibility.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.native != nil else { return }
                self.surface?.observeVisibility?()
                do { _ = try self.command("pump") } catch { self.report(error) }
            }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    @discardableResult private func command(_ name: String, _ payload: [String: WeappJSON] = [:]) throws -> WeappJSON {
        guard let native else { throw failure("ERR_NOT_READY", "Attach and lay out the view before loading") }
        // Drain on failures too: resize may commit and storage completion must settle.
        do { let result = try native.command(name, .object(payload)); drainEvents(); return result }
        catch { drainEvents(); throw error }
    }
    private func drainEvents() {
        guard let native, let list = try? native.command("takeEvents", .object([:])).array else { return }
        for event in list {
            switch event["type"].string {
            case "frame": frameRevision = UInt64(event["revision"].number ?? 0)
            case "ready": enqueue(.ready(event["state"]))
            case "navigation": enqueue(.navigation(event))
            case "message": enqueue(.message(event["message"]))
            case "error": enqueue(.error(WeappContainerError(event["error"])))
            case "hostCall": dispatchHostCall(event)
            case "hostCallCancelled": if let id = event["callId"].string { jobs.removeValue(forKey: id)?.cancel() }
            case "storageFlushed":
                if let ticket = event["ticket"].number, let c = flushes.removeValue(forKey: UInt64(ticket)) {
                    if event["ok"].bool == true { c.resume() } else { c.resume(throwing: WeappContainerError(event["error"])) }
                }
            case "closed":
                isClosed = true; isLoaded = false; isForeground = false
                for job in jobs.values { job.cancel() }; jobs.removeAll()
                let error = event["ok"].bool == false ? WeappContainerError(event["error"]) : nil
                nativeCloseResult = error.map { .failure($0) } ?? .success(())
                let c = closeWaiter; closeWaiter = nil
                if let error { c?.resume(throwing: error) } else { c?.resume() }
                enqueue(.closed(error))
            default: break
            }
        }
    }
    private func dispatchHostCall(_ event: WeappJSON) {
        guard let id = event["callId"].string, let name = event["method"].string else { return }
        let handler = methods[name]
        jobs[id] = Task { @MainActor [weak self] in
            var response: [String: WeappJSON] = ["callId": .string(id)]
            do {
                guard let handler else { throw WeappHostError(code: .unsupported, message: "No handler registered for \(name)") }
                response["result"] = try await handler(event["payload"])
            } catch {
                let e = error as? WeappHostError ?? WeappHostError(code: error is CancellationError ? .cancelled : .invalidRequest, message: error.localizedDescription)
                response["error"] = .object(["code": .string(e.code.rawValue), "message": .string(e.message), "retryable": .bool(e.retryable)])
            }
            guard !Task.isCancelled, let self, self.jobs.removeValue(forKey: id) != nil, !self.closing else { return }
            do { _ = try self.command("completeHostCall", response) } catch { self.report(error) }
        }
    }
    private func enqueue(_ event: WeappContainerEvent) {
        events.append(event)
        guard !eventDeliveryScheduled else { return }
        eventDeliveryScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let delivered = self.events; self.events.removeAll(); self.eventDeliveryScheduled = false
            for event in delivered { self.onEvent?(event) }
        }
    }
}

/// The only owner of a C handle. Explicit close is asynchronous; deinit is a
/// last-resort storage barrier dispatched to the creating (main) thread.
private final class NativeOwner {
    private var handle: OpaquePointer?
    init(config: WeappJSON) throws {
        guard weapp_container_sdk_abi_version() == 1 else { throw WeappContainerError(code: "ERR_ABI", message: "Unsupported native ABI") }
        let bytes = try JSONEncoder().encode(config)
        var result = weapp_container_sdk_buffer(data: nil, len: 0)
        defer { weapp_container_sdk_buffer_free(&result) }
        let status = bytes.withUnsafeBytes { p in weapp_container_sdk_session_new(p.bindMemory(to: UInt8.self).baseAddress, p.count, &handle, &result) }
        _ = try Self.decode(status, result)
    }
    deinit {
        guard let h = handle else { return }
        DispatchQueue.main.async {
            var h: OpaquePointer? = h
            var result = weapp_container_sdk_buffer(data: nil, len: 0)
            let status = weapp_container_sdk_session_destroy(&h, &result)
            if status != 0 {
                do { _ = try Self.decode(status, result) }
                catch { NSLog("WeappContainer final cleanup failed: %@", error.localizedDescription) }
            }
            weapp_container_sdk_buffer_free(&result)
        }
    }
    func destroy() throws {
        var result = weapp_container_sdk_buffer(data: nil, len: 0)
        defer { weapp_container_sdk_buffer_free(&result) }
        let status = weapp_container_sdk_session_destroy(&handle, &result)
        _ = try Self.decode(status, result)
    }
    func command(_ name: String, _ value: WeappJSON) throws -> WeappJSON {
        let op = Data(name.utf8), payload = try JSONEncoder().encode(value)
        return try call { h, result in op.withUnsafeBytes { o in payload.withUnsafeBytes { p in
            weapp_container_sdk_session_command(h, o.bindMemory(to: UInt8.self).baseAddress, o.count, p.bindMemory(to: UInt8.self).baseAddress, p.count, &result)
        } } }
    }
    func call(_ operation: (OpaquePointer, inout weapp_container_sdk_buffer) -> Int32) throws -> WeappJSON {
        precondition(Thread.isMainThread)
        guard let handle else { throw WeappContainerError(code: "ERR_CLOSED", message: "Native handle is closed") }
        var result = weapp_container_sdk_buffer(data: nil, len: 0)
        defer { weapp_container_sdk_buffer_free(&result) }
        let status = operation(handle, &result)
        return try Self.decode(status, result)
    }
    private static func decode(_ status: Int32, _ result: weapp_container_sdk_buffer) throws -> WeappJSON {
        guard let data = result.data, result.len > 0 else { throw WeappContainerError(code: "ERR_ABI", message: "Native operation returned no result (\(status))") }
        let envelope = try JSONDecoder().decode(WeappJSON.self, from: Data(bytes: data, count: result.len))
        guard status == 0, envelope["ok"].bool == true else { throw WeappContainerError(envelope["error"]) }
        return envelope["value"]
    }
}
