import Foundation
import UIKit
import WeappContainerNative

/// Owns a single mini-program. Commands and callbacks run on the UIKit main actor.
/// Keep the session for reattachment, and await close() to persist and release it.
@MainActor public final class WeappContainerSession {
    public typealias HostMethod = @MainActor (WeappJSON) async throws -> WeappJSON
    public typealias HostApiHandler = @MainActor (WeappHostApiCall) async throws -> WeappJSON
    public let configuration: WeappContainerConfiguration
    public var onEvent: ((WeappContainerEvent) -> Void)?
    public var onAccountCleanup: (@MainActor (String) async throws -> Void)?
    public private(set) var isClosed = false
    public private(set) var isLoaded = false
    public private(set) var frameRevision: UInt64 = 0
    public private(set) var isForeground = false
    public static var version: String { String(cString: weapp_container_sdk_version()) }

    private var native: NativeOwner?
    private var metrics: WeappJSON?
    private var metricsWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var methods: [String: HostMethod] = [:]
    private var apiHandlers: [String: HostApiHandler] = [:]
    private var hostServicesConfig: [String: WeappJSON]?
    private var authorizedApplications: [String: [String: WeappJSON]] = [:]
    private var resourceCleanups: [String: () -> Void] = [:]
    private var asyncResourceCleanups: [String: @MainActor () async throws -> Void] = [:]
    private var visibilityHandlers: [String: (Bool) -> Void] = [:]
    private var accountSwitchBlocked = false
    private var accountDetachTask: Task<Void, Never>?
    private var accountSwitchOperationID: String?
    private var accountCleanupTaskID: String?
    private var accountNativeCleanupID: String?
    private let accountCleanupQueue = AccountCleanupQueue()
    private var jobs: [String: Task<Void, Never>] = [:]
    private var apiCancellations: [String: WeappHostApiCancellation] = [:]
    private var timer: Timer?
    private var flushes: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var closeWaiter: CheckedContinuation<Void, Error>?
    private var closeResult: Result<Void, Error>?
    private var closeTask: Task<Void, Error>?
    private var nativeCloseResult: Result<Void, Error>?
    private var gate = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var requestedForeground = true
    private var surfaceForeground = false
    private var previewOccluded = false
    private var hostChrome: [String: WeappJSON]?
    private var hostSurfaceIdentity: [String: WeappJSON]?
    private var surface: MetalSurface?
    private var events: [WeappContainerEvent] = []
    private var eventDeliveryScheduled = false

    public init(configuration: WeappContainerConfiguration) { self.configuration = configuration }
    deinit {
        timer?.invalidate(); for task in jobs.values { task.cancel() }
        let p = surface, owner = native
        let cancellations = Array(apiCancellations.values), cleanups = Array(resourceCleanups.values)
        let asyncCleanups = asyncResourceCleanups
        // Retain both GPU and native owners through asynchronous final cleanup.
        Task { @MainActor in
            for cancellation in cancellations { cancellation.cancel() }; for cleanup in cleanups { cleanup() }
            await FinalResourceRetirement.retire(surface: p, owner: owner, cleanups: asyncCleanups)
        }
    }
    /// Failed final cleanup retains its native owner and core file lease until an explicit retry succeeds.
    public static var failedFinalResourceCleanups: [String: String] { FinalResourceRetirement.failures }
    @discardableResult public static func retryFinalResourceCleanups() async -> [String: String] { await FinalResourceRetirement.retry(); return FinalResourceRetirement.failures }

    public func registerHostMethod(_ name: String, handler: @escaping HostMethod) throws {
        try ensureOpen()
        guard !isLoaded, !gate else { throw failure("ERR_INVALID_STATE", "Register host methods before loading") }
        guard !name.isEmpty, !name.hasPrefix("wx.") else { throw failure("ERR_INVALID_REQUEST", "Host method names must be nonempty and cannot use wx.*") }
        if native != nil { _ = try command("registerHostMethod", ["name": .string(name)]) }
        methods[name] = handler
    }
    /// Trusted metadata from the verified installation; credentials stay in the host/backend.
    public func configureHostServices(_ value: [String: WeappJSON]) throws {
        try ensureOpen()
        guard !isLoaded, !gate else { throw failure("ERR_INVALID_STATE", "Configure host services before loading") }
        if native != nil { _ = try command("configureHostServices", value) }
        hostServicesConfig = value
    }
    public func registerHostResourceCleanup(_ key: String, cleanup: @escaping () -> Void) throws {
        try ensureOpen()
        guard resourceCleanups[key] == nil else { throw failure("ERR_INVALID_REQUEST", "Native resource cleanup key already registered") }
        resourceCleanups[key] = cleanup
    }
    /// Native I/O must finish before account cleanup is acknowledged or close destroys its owner.
    public func registerHostAsyncResourceCleanup(_ key: String, cleanup: @escaping @MainActor () async throws -> Void) throws {
        try ensureOpen()
        guard asyncResourceCleanups[key] == nil else { throw failure("ERR_INVALID_REQUEST", "Native async cleanup key already registered") }
        asyncResourceCleanups[key] = cleanup
    }
    public func registerHostVisibilityHandler(_ key: String, handler: @escaping (Bool) -> Void) throws {
        try ensureOpen(); guard visibilityHandlers[key] == nil else { throw failure("ERR_INVALID_REQUEST", "Visibility handler already registered") }; visibilityHandlers[key] = handler; handler(isForeground)
    }
    private func drainAsyncResources(retire: Bool) async throws {
        for (key, cleanup) in asyncResourceCleanups { try await cleanup(); if retire { asyncResourceCleanups.removeValue(forKey: key) } }
    }
    public func registerApiHandler(_ name: String, handler: @escaping HostApiHandler) throws {
        try ensureOpen()
        guard !isLoaded, !gate, hostServicesConfig != nil else { throw failure("ERR_INVALID_STATE", "Configure trusted services and register APIs before loading") }
        guard !name.isEmpty, apiHandlers[name] == nil else { throw failure("ERR_INVALID_REQUEST", "Native API must be nonempty and unique") }
        if native != nil { _ = try command("registerApiHandler", ["name": .string(name)]) }
        apiHandlers[name] = handler
    }
    /// Allowlisted host-service transport shared by native, Flutter and React Native hosts.
    public func hostServicesCommand(_ operation: String, _ payload: [String: WeappJSON] = [:]) throws -> WeappJSON {
        let allowed = ["configureHostServices", "registerApiHandler", "updateHostServiceSnapshots", "authorizeInstalledPack", "migrateLegacyStorage", "deleteAccountData", "hostApiEvent", "hostComponents", "managedFileScope", "hostComponentEvent", "authorizePhoneButton", "acknowledgeAccountCleanup", "retryAccountCleanup", "switchAccount", "queryAccountSwitch", "updateAccountSwitchLaunch", "retryAccountSwitch", "cancelAccountSwitch", "hostApiResource", "createHostBinary", "readHostBinary", "retainHostBinary", "releaseHostBinary"]
        try ensureOpen()
        guard allowed.contains(operation) || ["hostComponentFrame", "prepareAccountHostServiceSnapshots"].contains(operation) else { throw failure("ERR_INVALID_REQUEST", "Not a host-services command") }
        if operation == "hostApiResource" {
            guard let native else { throw failure("ERR_NOT_READY", "A live API call owner is required") }
            return try native.command(operation, .object(payload))
        }
        if operation == "configureHostServices" { try configureHostServices(payload); return .null }
        try createNativeIfNeeded()
        if operation == "retryAccountCleanup" { beginAccountCleanup(); return try command("queryAccountSwitch") }
        if operation == "updateHostServiceSnapshots", payload["context"] != nil {
            guard WeappHostIdentitySnapshot.supportsOwnerContext(try command("capabilities")) else { throw failure("ERR_UNSUPPORTED_CAPABILITY", "Runtime does not validate native snapshot owner contexts") }
            // The negotiated runtime validates application, accepted pack, epoch
            // and session together, and preserves its ERR_CANCELLED result.
            // Update the replay cache only after this command succeeds.
        }
        let result = try command(operation, payload)
        if operation == "authorizeInstalledPack", let root = payload["packRoot"]?.string {
            guard authorizedApplications[root] != nil || authorizedApplications.count < 64 else { throw failure("ERR_INVALID_REQUEST", "Authorized pack limit reached") }
            authorizedApplications[root] = payload
        }
        if operation == "updateHostServiceSnapshots" || operation == "prepareAccountHostServiceSnapshots" {
            let values = payload["values"]?.dictionary ?? [:]
            let snapshots = (hostServicesConfig?["syncValues"]?.dictionary ?? [:]).merging(values) { _, value in value }
            hostServicesConfig?["syncValues"] = .object(snapshots)
        }
        if operation == "switchAccount", result["phase"].string != "complete" { accountSwitchBlocked = true }
        surface?.invalidate(); return result
    }
    public func emitHostApiEvent(_ event: [String: WeappJSON]) throws -> WeappJSON { try hostServicesCommand("hostApiEvent", event) }
    /// Read the asset of an exact live API call; requires apiResourceChunks 1.0.
    public func readHostApiResource(context: WeappJSON, offset: Int = 0, length: Int) throws -> WeappJSON {
        try hostServicesCommand("hostApiResource", ["context":context,"offset":.number(Double(offset)),"length":.number(Double(length))])
    }
    public func createHostBinary(_ bytes: Data) throws -> WeappJSON {
        guard bytes.count <= 1024 * 1024 else { throw failure("ERR_INVALID_REQUEST", "Host binary chunks are bounded to 1 MiB") }
        return try hostServicesCommand("createHostBinary", ["bytes": .array(bytes.map { .number(Double($0)) })])
    }

    /// Waits for a view attached to a window with positive, measured bounds.
    /// Cancellation before that layout does not initialize the mini-program.
    public func load(packURL: URL, route: String? = nil, options: [String: WeappJSON] = [:], initialHostChrome: [String: WeappJSON]? = nil, initialHostLayout: [String: WeappJSON]? = nil) async throws {
        _ = try await replacePack(packURL: packURL, route: route, options: options, initialHostChrome: initialHostChrome, initialHostLayout: initialHostLayout, development: false)
    }

    /// Presentation-only updates retain the live session and Metal attachment.
    /// A restart drains and detaches the old target before invoking SDK load.
    public func applyDevPack(packURL: URL, route: String? = nil, options: [String: WeappJSON] = [:], initialHostChrome: [String: WeappJSON]? = nil, initialHostLayout: [String: WeappJSON]? = nil) async throws -> WeappJSON {
        try await replacePack(packURL: packURL, route: route, options: options, initialHostChrome: initialHostChrome, initialHostLayout: initialHostLayout, development: true)
    }

    /// Versioned SDK command transport. Decimal identities remain JSON strings.
    /// Attempt submission owns native/GPU reconciliation even if presentation fails.
    public func executeCommand(_ name: String, _ payload: [String: WeappJSON] = [:]) async throws -> WeappJSON {
        try ensureOpen()
        if name == "queryDevPackAttempt" {
            // Journal metadata remains readable for an existing empty or
            // poisoned owner. A query must not create an owner, replay startup,
            // change isLoaded or invalidate/acknowledge a Metal drawable.
            guard let native else { throw failure("ERR_NOT_READY", "No native owner for development attempt query") }
            await acquireGate(); defer { releaseGate() }
            try ensureOpen(); try Task.checkCancellation()
            return try native.command(name, .object(payload))
        }
        if native == nil { _ = try await prepareView() }
        await acquireGate(); defer { releaseGate() }
        try ensureOpen(); try Task.checkCancellation()
        if name == "applyDevPackAttempt" {
            let receipt = try command("queryDevPackAttempt", ["ownerId": payload["ownerId"] ?? .null, "attemptId": payload["attemptId"] ?? .null])
            let restart = receipt["reloadKind"].string == "restart" && receipt["status"].string == "prepared"
            let current = surface
            current?.cancelInput?(); await current?.drain()
            if restart { try current?.detach() }
            var result: WeappJSON = .null
            var operationError: Error?
            do {
                result = try command(name, payload)
                if result["status"].string == "accepted" { isLoaded = true }
            } catch {
                operationError = error
                if let retained = try? command("queryDevPackAttempt", ["ownerId": payload["ownerId"] ?? .null, "attemptId": payload["attemptId"] ?? .null]), retained["status"].string == "accepted" {
                    isLoaded = true
                }
            }
            if isLoaded {
                // An empty atomic owner has only a logical surface. After its
                // first accepted attempt, attach even if a retried receipt is
                // already terminal rather than classified as a new restart.
                do { try applyForeground(synchronizeNative: true); try current?.attach(); current?.invalidate() }
                catch { operationError = operationError ?? error; report(error) }
            }
            if let operationError { throw operationError }
            return result
        }
        let result = try command(name, payload)
        surface?.invalidate()
        return result
    }

    /// Passive journal metadata on this owner actor, including while an async
    /// GPU reconciliation holds its gate. This neither waits for that gate nor
    /// creates a native owner; the Rust query is read-only and actor serialized.
    public func queryDevPackAttemptForLayout(ownerId: String, attemptId: String) throws -> WeappJSON {
        try ensureOpen()
        guard let native else { throw failure("ERR_NOT_READY", "No native owner for development attempt query") }
        let receipt = try native.command("queryDevPackAttempt", .object(["ownerId": .string(ownerId), "attemptId": .string(attemptId)]))
        let state = try native.command("state", .object([:]))
        return .object(["receipt": receipt, "state": state])
    }

    /// Requests another complete native measurement even if its dimensions match.
    public func requestHostLayoutObservation() async throws -> WeappJSON {
        _ = try await prepareView()
        return try command("state")["pendingHostLayout"]
    }

    private func createNativeIfNeeded() throws {
        guard native == nil else { return }
        native = try NativeOwner(config: makeConfig())
        for name in methods.keys.sorted() { _ = try command("registerHostMethod", ["name": .string(name)]) }
        for name in apiHandlers.keys.sorted() { _ = try command("registerApiHandler", ["name": .string(name)]) }
        for application in authorizedApplications.values { _ = try command("authorizeInstalledPack", application) }
        if previewOccluded { _ = try command("setPreviewOccluded", ["occluded": .bool(true)]) }
        startPump()
    }

    private func observeAtomicLayout() throws {
        guard configuration.atomicHostLayout, let metrics, native != nil else { return }
        if hostSurfaceIdentity == nil {
            hostSurfaceIdentity = try command("hostSurface", ["action": .string("attach")]).dictionary
        }
        guard let identity = hostSurfaceIdentity else { return }
        _ = try command("observeHostLayout", identity.merging(["schemaVersion": .number(1), "windowMetrics": metrics]) { _, value in value })
    }

    public func devState() throws -> WeappJSON { try ensureAvailable(); return try command("devState") }
    public func clearDevStorage() async throws {
        try ensureAvailable()
        _ = try command("clearDevStorage")
        try await flushStorage()
    }

    private func replacePack(packURL: URL, route: String?, options: [String: WeappJSON], initialHostChrome: [String: WeappJSON]?, initialHostLayout: [String: WeappJSON]?, development: Bool) async throws -> WeappJSON {
        try ensureOpen()
        try await waitForMetrics()
        await acquireGate()
        defer { releaseGate() }
        try ensureOpen()
        try Task.checkCancellation()
        guard packURL.isFileURL else { throw failure("ERR_INVALID_REQUEST", "load requires a verified local portable-pack directory") }
        var payload: [String: WeappJSON] = ["packPath": .string(packURL.path), "options": .object(options)]
        if let route { payload["route"] = .string(route) }
        if let initialHostChrome { payload["initialHostChrome"] = .object(initialHostChrome) }
        if let initialHostLayout { payload["initialHostLayout"] = .object(initialHostLayout) }
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
            if !isLoaded && !configuration.atomicHostLayout {
                try native?.destroy()
                native = try NativeOwner(config: makeConfig())
                if let hostChrome { _ = try command("hostChrome", hostChrome) }
                if previewOccluded { _ = try command("setPreviewOccluded", ["occluded": .bool(true)]) }
                for name in methods.keys.sorted() { _ = try command("registerHostMethod", ["name": .string(name)]) }
                for name in apiHandlers.keys.sorted() { _ = try command("registerApiHandler", ["name": .string(name)]) }
                for application in authorizedApplications.values { _ = try command("authorizeInstalledPack", application) }
                startPump()
            }
            result = try command(development ? "applyDevPack" : "load", payload)
            if let accepted = try? command("state")["hostChrome"], case .object(var geometry) = accepted {
                geometry.removeValue(forKey: "sessionId");geometry.removeValue(forKey: "pageId");hostChrome=geometry
            }
            isLoaded = true
            if restart {
                if !configuration.atomicHostLayout, let metrics { _ = try command("windowMetrics", metrics.dictionary) }
                try applyForeground(synchronizeNative: true)
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
    public func switchTab(route: String) throws { try ensureAvailable(); _ = try command("switchTab", ["route": .string(route)]) }
    /// Verified configuration preflight. The temporary empty owner executes no
    /// App/Page code and never claims view metrics or presentation authority.
    public func inspectPackChrome(packURL: URL, route: String? = nil) throws -> WeappJSON {
        try ensureOpen()
        guard packURL.isFileURL else { throw failure("ERR_INVALID_REQUEST", "inspectPackChrome requires a local directory") }
        let owner = try NativeOwner(config: .object(["engine": .string("quickjs")]))
        defer { do { try owner.destroy() } catch { report(error) } }
        var payload: [String: WeappJSON] = ["packPath": .string(packURL.path)]
        if let route { payload["route"] = .string(route) }
        return try owner.command("inspectPackChrome", .object(payload))
    }
    public func updateHostChrome(_ value: [String: WeappJSON]) throws {
        try ensureOpen()
        guard !configuration.atomicHostLayout else { throw failure("ERR_UNSUPPORTED_CAPABILITY", "Atomic host layout requires a complete hostLayout") }
        if native != nil { _ = try command("hostChrome", value) }
        else {
            let owner = try NativeOwner(config: .object(["engine": .string("quickjs")]))
            defer { do { try owner.destroy() } catch { report(error) } }
            _ = try owner.command("hostChrome", .object(value))
        }
        hostChrome = value
        surface?.invalidate()
    }
    /// Developer controls cover the view without changing app lifecycle.
    public func setPreviewOccluded(_ value: Bool) throws {
        try ensureOpen()
        if native != nil { _ = try command("setPreviewOccluded", ["occluded": .bool(value)]) }
        let wasOccluded = previewOccluded
        previewOccluded = value
        if value { surface?.cancelInput?() }
        else if wasOccluded && isLoaded { try surface?.attach() }
        surface?.invalidate()
    }
    /// Allows a host feature or framework controller to suspend this session.
    /// Resuming also requires a visible view in an active scene. View polling
    /// cannot override an explicit host suspension; completion pumping continues.
    public func setForeground(_ active: Bool) throws {
        try ensureOpen()
        surface?.observeVisibility?()
        if !active { surface?.cancelInput?() }
        requestedForeground = active
        try applyForeground(synchronizeNative: true)
        surface?.observeVisibility?()
    }
    public func state() throws -> WeappJSON { try ensureOpen(); return try command("state") }
    public func capabilities() throws -> WeappJSON { try ensureOpen(); return try command("capabilities") }
    /// Wait for a real attached view, then inspect an empty runtime before any
    /// App/Page module executes. The C ABI and normal capabilities stay unchanged.
    public func prepareView() async throws -> WeappJSON {
        try ensureOpen()
        try await waitForMetrics()
        await acquireGate(); defer { releaseGate() }
        try ensureOpen(); try Task.checkCancellation()
        try createNativeIfNeeded()
        if configuration.atomicHostLayout { try observeAtomicLayout() }
        else if let hostChrome { _ = try command("hostChrome", hostChrome) }
        return try command("capabilities")
    }

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
        if let closeTask { return try await closeTask.value }
        // Claim the operation before its first suspension. All callers join the
        // same cleanup; a failed attempt remains retryable once it has finished.
        closing = true
        let task = Task { @MainActor in try await self.finishClose() }
        closeTask = task
        defer { closeTask = nil }
        try await task.value
    }
    private func finishClose() async throws {
        surface?.cancelInput?()
        accountDetachTask?.cancel()
        await accountCleanupQueue.drain()
        for cancellation in apiCancellations.values { cancellation.cancel() }; apiCancellations.removeAll()
        for cleanup in resourceCleanups.values { cleanup() }; resourceCleanups.removeAll()
        try await drainAsyncResources(retire: true)
        visibilityHandlers.removeAll()
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
        if surface === oldSurface {
            if let identity = hostSurfaceIdentity, native != nil, !closing {
                _ = try command("hostSurface", identity.merging(["action": .string("detach")]) { _, value in value })
            }
            hostSurfaceIdentity = nil; surface = nil; metrics = nil; setSurfaceForeground(false)
        }
    }
    /// A detached/reassigned window must not seed a later owner or load from
    /// its old observations. Existing native snapshots remain historical while
    /// the surface is paused; only a complete new observation can resume it.
    func invalidateMetrics() { metrics = nil }
    func updateMetrics(_ value: WeappJSON) {
        guard !closing, !isClosed else { return }
        if !configuration.atomicHostLayout && metrics == value { return }
        metrics = value
        let waiting = metricsWaiters.values; metricsWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        if configuration.atomicHostLayout {
            do {
                try createNativeIfNeeded()
                try observeAtomicLayout()
                try surface?.attach()
            } catch { report(error) }
        } else if isLoaded, !gate {
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
    private func applyForeground(synchronizeNative: Bool = false) throws {
        let active = requestedForeground && surfaceForeground
        let changed = active != isForeground; isForeground = active
        if changed { for handler in visibilityHandlers.values { handler(active) } }
        guard isLoaded, !accountSwitchBlocked, synchronizeNative || (changed && !gate) else { return }
        // SDK replacement may commit while the host changes visibility during
        // a Metal drain. Synchronize actual desired lifecycle before reattach;
        // developer occlusion is deliberately absent from this calculation.
        if try command("state")["foreground"].bool != active {
            _ = try command("lifecycle", ["event": .string(active ? "show" : "hide")])
        }
    }
    var canPresent: Bool {
        guard isLoaded && isForeground && !previewOccluded && !closing && !isClosed && !gate, let native,
              let state=try? native.command("state",.object([:])) else { return false }
        return state["chromeGeometryReady"].bool != false
    }
    func presentationIdentity() throws -> (generation: WeappJSON, revision: UInt64, layout: [String: WeappJSON]) {
        let value = try command("state")
        guard let generation = value["generation"].number, let revision = value["frameRevision"].number,
              generation >= 0, revision >= 0, generation.isFinite, revision.isFinite,
              generation.rounded(.down) == generation, revision.rounded(.down) == revision,
              revision < Double(UInt64.max) else {
            throw failure("ERR_RENDER", "Runtime returned an invalid presentation identity")
        }
        let accepted = value["acceptedLayout"]
        let layout = configuration.atomicHostLayout ? Dictionary(uniqueKeysWithValues: ["ownerId", "surfaceGeneration", "observationId", "layoutRevision"].map { ($0, accepted[$0]) }) : [:]
        return (.number(generation), UInt64(revision), layout)
    }
    func acknowledgePresentation(generation: WeappJSON, revision: UInt64, layout: [String: WeappJSON]) throws {
        _ = try command("presented", layout.merging(["generation": generation, "revision": .number(Double(revision))]) { _, value in value })
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
        guard !accountSwitchBlocked else { throw failure("ERR_IDENTITY_SWITCHING", "Account replacement is not presented") }
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
        let managedRoot = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WeappContainer/managed-files", isDirectory: true)
        config["managedFilesRoot"] = .string(managedRoot.path)
        if let required = configuration.gpuRequired { config["gpuRequired"] = .bool(required) }
        if configuration.devDiagnostics { config["devDiagnostics"] = .bool(true) }
        if configuration.atomicHostLayout { config["hostLayout"] = .object(["protocolVersion": .string("1.0"), "atomic": .bool(true)]) }
        if let hostServicesConfig { config["hostServices"] = .object(hostServicesConfig) }
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
            case "ready": retainTrustedState(event["state"]); enqueue(.ready(event["state"]))
            case "devReload":
                if let state = try? native.command("state", .object([:])) { retainTrustedState(state) }
                enqueue(.raw(event))
            case "navigation": enqueue(.navigation(event))
            case "chrome": enqueue(.chrome(event))
            case "message": enqueue(.message(event["message"]))
            case "error": enqueue(.error(WeappContainerError(event["error"])))
            case "hostCall": dispatchHostCall(event)
            case "hostCallCancelled": if let id = event["callId"].string { jobs.removeValue(forKey: id)?.cancel(); apiCancellations.removeValue(forKey: id)?.cancel() }
            case "accountSwitch": handleAccountSwitch(event); enqueue(.raw(event))
            case "storageFlushed":
                if let ticket = event["ticket"].number, let c = flushes.removeValue(forKey: UInt64(ticket)) {
                    if event["ok"].bool == true { c.resume() } else { c.resume(throwing: WeappContainerError(event["error"])) }
                }
            case "closed":
                isClosed = true; isLoaded = false; isForeground = false
                for job in jobs.values { job.cancel() }; jobs.removeAll()
                for cancellation in apiCancellations.values { cancellation.cancel() }; apiCancellations.removeAll()
                for cleanup in resourceCleanups.values { cleanup() }; resourceCleanups.removeAll()
                let error = event["ok"].bool == false ? WeappContainerError(event["error"]) : nil
                nativeCloseResult = error.map { .failure($0) } ?? .success(())
                let c = closeWaiter; closeWaiter = nil
                if let error { c?.resume(throwing: error) } else { c?.resume() }
                enqueue(.closed(error))
            default: enqueue(.raw(event))
            }
        }
    }
    private func dispatchHostCall(_ event: WeappJSON) {
        guard let id = event["callId"].string, let name = event["method"].string else { return }
        let handler = methods[name]
        let apiHandler = apiHandlers[name]
        let cancellation = WeappHostApiCancellation()
        cancellation.retained = event["retainUntilCancelled"].bool == true
        apiCancellations[id] = cancellation
        jobs[id] = Task { @MainActor [weak self] in
            var response: [String: WeappJSON] = ["callId": .string(id)]
            do {
                if event["context"] != .null {
                    guard let apiHandler else { throw WeappHostError(code: .unsupported, message: "No native API handler registered for \(name)") }
                    response["result"] = try await apiHandler(WeappHostApiCall(event: event, cancellation: cancellation))
                } else {
                    guard let handler else { throw WeappHostError(code: .unsupported, message: "No handler registered for \(name)") }
                    response["result"] = try await handler(event["payload"])
                }
            } catch {
                let e = error as? WeappHostError ?? WeappHostError(code: error is CancellationError ? .cancelled : .invalidRequest, message: error.localizedDescription)
                response["error"] = .object(["code": .string(e.code.rawValue), "message": .string(e.message), "retryable": .bool(e.retryable), "details": .object(e.details)])
            }
            cancellation.finishSetup(failed: response["error"] != nil)
            guard !Task.isCancelled, let self, !self.accountSwitchBlocked, self.jobs.removeValue(forKey: id) != nil, !self.closing else { return }
            if !cancellation.retained || response["error"] != nil { self.apiCancellations.removeValue(forKey: id) }
            do { _ = try self.command("completeHostCall", response) } catch { self.report(error) }
        }
    }
    private func retainTrustedState(_ state: WeappJSON) {
        let trusted = state["hostServicesState"]
        if trusted["application"] != .null { hostServicesConfig?["application"] = trusted["application"] }
        if trusted["account"] != .null { hostServicesConfig?["account"] = trusted["account"] }
    }
    private func handleAccountSwitch(_ event: WeappJSON) {
        let receipt = event["receipt"]
        if event["account"] != .null { hostServicesConfig?["account"] = event["account"] }
        if event["syncValues"] != .null { hostServicesConfig?["syncValues"] = event["syncValues"] }
        switch receipt["phase"].string {
        case "revoking":
            accountSwitchBlocked = true; isLoaded = false; hostChrome = nil
            accountSwitchOperationID = receipt["operationId"].string
            for job in jobs.values { job.cancel() }; jobs.removeAll()
            for cancellation in apiCancellations.values { cancellation.cancel() }; apiCancellations.removeAll()
            for cleanup in resourceCleanups.values { cleanup() }
            surface?.cancelInput?(); surface?.layer.opacity = 0
            beginAccountCleanup()
        case "awaitingPresentation":
            isLoaded = receipt["sessionId"].string != nil
            if isLoaded { do { try surface?.attach(); surface?.invalidate() } catch { report(error) } }
        case "complete":
            accountSwitchBlocked = false; isLoaded = receipt["sessionId"].string != nil
            if isLoaded { do { try applyForeground(synchronizeNative: true); try surface?.attach(); surface?.invalidate() } catch { report(error) } }
        case "failed", "superseded": accountSwitchBlocked = true; isLoaded = false
        default: break
        }
    }
    private func beginAccountCleanup() {
        guard accountSwitchBlocked, let operationID = accountSwitchOperationID, accountCleanupTaskID != operationID else { return }
        accountDetachTask?.cancel(); accountCleanupTaskID = operationID
        accountDetachTask = accountCleanupQueue.enqueue { [weak self] in
            guard let self else { return }
            var ownsGate = false
            defer {
                if ownsGate { self.releaseGate() }
                if self.accountCleanupTaskID == operationID { self.accountCleanupTaskID = nil; self.accountDetachTask = nil }
            }
            do {
                await self.acquireGate(); ownsGate = true
                try self.ensureOpen(); try Task.checkCancellation()
                if self.accountNativeCleanupID != operationID {
                    await self.surface?.drain(); try Task.checkCancellation(); try self.surface?.detach()
                    try await self.surface?.clear(); try Task.checkCancellation()
                    guard self.accountSwitchOperationID == operationID else { return }
                    self.hostSurfaceIdentity = nil
                    if self.configuration.atomicHostLayout { try self.observeAtomicLayout() }
                    self.accountNativeCleanupID = operationID
                }
                // Custom toolkit cleanup may await its own UI actor. Keep native commands
                // and close available while the revoked identity remains blocked in Rust.
                self.releaseGate(); ownsGate = false
                try await self.drainAsyncResources(retire: false); try Task.checkCancellation()
                try await self.onAccountCleanup?(operationID); try Task.checkCancellation()
                await self.acquireGate(); ownsGate = true
                try self.ensureOpen()
                guard self.accountSwitchOperationID == operationID else { return }
                _ = try self.command("acknowledgeAccountCleanup", ["operationId": .string(operationID)])
                self.surface?.layer.opacity = 1
                if self.isLoaded { try self.surface?.attach(); self.surface?.invalidate() }
            } catch { if !(error is CancellationError), !self.closing, self.accountSwitchOperationID == operationID { self.report(error) } }
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

@MainActor private enum FinalResourceRetirement {
    @MainActor private final class Entry {
        let surface: MetalSurface?
        let owner: NativeOwner?
        var cleanups: [String: @MainActor () async throws -> Void]
        var failure = ""
        var finishing = false
        init(_ surface: MetalSurface?, _ owner: NativeOwner?, _ cleanups: [String: @MainActor () async throws -> Void]) { self.surface = surface; self.owner = owner; self.cleanups = cleanups }
        func finish() async throws {
            var errors: [String] = []
            for (key, cleanup) in cleanups { do { try await cleanup(); cleanups.removeValue(forKey: key) } catch { errors.append("\(key): \(error.localizedDescription)") } }
            guard errors.isEmpty else { throw WeappContainerError(code: "ERR_FINAL_RESOURCE_CLEANUP", message: errors.joined(separator: "; ")) }
            await surface?.drain()
            if surface?.attached == true, let owner { _ = try owner.call { h, result in weapp_container_sdk_metal_detach(h, &result) }; surface?.attached = false }
            try owner?.destroy()
        }
    }
    private static var entries: [String: Entry] = [:]
    static var failures: [String: String] { entries.reduce(into: [:]) { if !$1.value.failure.isEmpty { $0[$1.key] = $1.value.failure } } }
    static func retire(surface: MetalSurface?, owner: NativeOwner?, cleanups: [String: @MainActor () async throws -> Void]) async {
        let id = UUID().uuidString, entry = Entry(surface, owner, cleanups); entries[id] = entry
        await attempt(id, entry)
    }
    private static func attempt(_ id: String, _ entry: Entry) async {
        guard entries[id] === entry, !entry.finishing else { return }
        entry.finishing = true
        defer { entry.finishing = false }
        do { try await entry.finish(); entries.removeValue(forKey: id) }
        catch { entry.failure = error.localizedDescription; NSLog("WeappContainer native owner quarantined after final cleanup failure (%@): %@", id, entry.failure) }
    }
    static func retry() async { for (id, entry) in entries { await attempt(id, entry) } }
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
