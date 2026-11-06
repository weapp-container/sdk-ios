import Foundation

private final class GuestNetworkDelegate: NSObject, URLSessionDataDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    var opened: (@Sendable (Int, String?) -> Void)?
    var closed: (@Sendable (Int, Int, Data?) -> Void)?
    var completed: (@Sendable (Int, Error?) -> Void)?
    var response: (@Sendable (Int, HTTPURLResponse) -> URLSession.ResponseDisposition)?
    var data: (@Sendable (Int, Data) -> Void)?
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) { completionHandler((response as? HTTPURLResponse).map { self.response?(dataTask.taskIdentifier, $0) ?? .cancel } ?? .cancel) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { self.data?(dataTask.taskIdentifier, data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol selected: String?) { opened?(webSocketTask.taskIdentifier, selected) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) { closed?(webSocketTask.taskIdentifier, code.rawValue, reason) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { completed?(task.taskIdentifier, error) }
}

/// Ephemeral guest-only URLSession. No host credentials/cookies; native policy permits exact origins.
@MainActor public final class WeappNetworkApis {
    private let files: WeappManagedFiles
    private let origins: Set<String>
    private let allowLoopback: Bool
    private let delegate = GuestNetworkDelegate()
    private var transport: URLSession!
    private weak var session: WeappContainerSession?
    private var closed = false
    private var closing = false
    private var resetting = false
    private final class Transfer { let call: WeappHostApiCall; var task: Task<WeappJSON, Error>?; init(_ call: WeappHostApiCall) { self.call = call } }
    private final class HttpTransfer {
        let object: String; let api: String; let call: WeappHostApiCall; let native: URLSessionDataTask; let limit: Int
        var response: HTTPURLResponse?; var data = Data(); var progress = Date.distantPast; var failure: Error?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        init(_ object: String, _ api: String, _ call: WeappHostApiCall, _ native: URLSessionDataTask) { self.object = object; self.api = api; self.call = call; self.native = native; self.limit = api == "wx.downloadFile" ? 8 * 1048576 : 1048576 }
    }
    private final class Socket { let call: WeappHostApiCall; let native: URLSessionWebSocketTask; var receiver: Task<Void, Never>?; var retired = false; var terminal = false; var nativeCompleted = false; var receiverFinished = false; var open = false; init(_ call: WeappHostApiCall, _ native: URLSessionWebSocketTask) { self.call = call; self.native = native } }
    private struct Subscription { let call: WeappHostApiCall; let object: String; let event: String; var sequence: UInt64 = 0 }
    private var transfers: [String: Transfer] = [:]
    private var httpTransfers: [Int: HttpTransfer] = [:]
    private var sockets: [String: Socket] = [:]
    private var subscriptions: [String: Subscription] = [:]
    public let supportedApis: Set<String> = ["wx.request", "wx.uploadFile", "wx.downloadFile", "wx.connectSocket",
        "object:RequestTask.abort", "object:RequestTask.onHeadersReceived", "object:RequestTask.offHeadersReceived", "object:RequestTask.onChunkReceived", "object:RequestTask.offChunkReceived",
        "object:UploadTask.abort", "object:UploadTask.onHeadersReceived", "object:UploadTask.offHeadersReceived", "object:UploadTask.onProgressUpdate", "object:UploadTask.offProgressUpdate",
        "object:DownloadTask.abort", "object:DownloadTask.onHeadersReceived", "object:DownloadTask.offHeadersReceived", "object:DownloadTask.onProgressUpdate", "object:DownloadTask.offProgressUpdate",
        "object:SocketTask.send", "object:SocketTask.close", "object:SocketTask.onOpen", "object:SocketTask.onMessage", "object:SocketTask.onError", "object:SocketTask.onClose"]
    public init(files: WeappManagedFiles, allowedOrigins: [String] = [], allowLoopbackForDevelopment: Bool = false) throws {
        self.files = files; self.origins = Set(allowedOrigins); self.allowLoopback = allowLoopbackForDevelopment
        guard origins.count <= 128 else { throw Self.error("Network origin limit") }
        for origin in origins { guard let url = URL(string: origin), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.isEmpty, parts.query == nil, parts.fragment == nil, Self.origin(url) == origin else { throw Self.error("Configure exact HTTPS/WSS origins") }; _ = try target(origin) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData; configuration.timeoutIntervalForRequest = 60
        transport = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.opened = { [weak self] task, selected in Task { @MainActor in self?.didOpen(task, selected) } }
        delegate.closed = { [weak self] task, code, reason in Task { @MainActor in self?.didClose(task, code, reason) } }
        // URLSession's private serial delegate queue waits for each bounded
        // main-actor delivery. It cannot enqueue an unbounded task per chunk.
        delegate.response = { [weak self] task, response in DispatchQueue.main.sync { MainActor.assumeIsolated { self?.httpResponse(task, response) ?? .cancel } } }
        delegate.data = { [weak self] task, data in DispatchQueue.main.sync { MainActor.assumeIsolated { self?.httpData(task, data) } } }
        delegate.completed = { [weak self] task, error in DispatchQueue.main.sync { MainActor.assumeIsolated { self?.didComplete(task, error) } } }
    }
    private static func error(_ text: String) -> WeappHostError { WeappHostError(code: .invalidRequest, message: text, details: ["errCode": .number(-1)]) }
    private static func origin(_ url: URL) -> String { "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? "")\(url.port.map { ":\($0)" } ?? "")" }
    private func target(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme, url.host != nil, url.user == nil, url.password == nil, url.fragment == nil,
            ["https", "wss"].contains(scheme) || allowLoopback && ["http", "ws"].contains(scheme) && ["localhost", "127.0.0.1", "::1"].contains(url.host!) else { throw Self.error("HTTPS/WSS or explicitly enabled loopback URL required") }; return url
    }
    private func permitted(_ raw: String, socket: Bool) throws -> URL { let url = try target(raw); guard ["ws", "wss"].contains(url.scheme!) == socket, origins.contains(Self.origin(url)) else { throw WeappHostError(code: .permissionDenied, message: "Native network origin is not allowed") }; return url }
    public func install(in session: WeappContainerSession) throws {
        guard self.session == nil else { throw Self.error("Network adapter already installed") }; self.session = session
        try session.registerHostAsyncResourceCleanup("network-\(UUID().uuidString)") { try await self.reset() }
        for api in supportedApis.sorted() { try session.registerApiHandler(api) { [weak self] call in guard let self, !self.closed, !self.closing, !self.resetting, !call.cancellation.isCancelled else { throw CancellationError() }; return try await self.invoke(api, call) } }
    }
    private func ok(_ api: String) -> WeappJSON { .object(["errMsg": .string("\(api.replacingOccurrences(of: "wx.", with: "")):ok")]) }
    private func binary(_ data: Data) -> WeappJSON { .object(["__weappBinary": .object(["type": .string("ArrayBuffer"), "bytes": .array(data.map { .number(Double($0)) })])]) }
    private func bytes(_ value: WeappJSON) throws -> Data {
        if value == .null { return Data() }; if let text = value.string { return Data(text.utf8) }
        if let values = value["__weappBinary"]["bytes"].array { guard value["__weappBinary"]["type"].string == "ArrayBuffer", values.count <= 1048576 else { throw Self.error("Bounded ArrayBuffer required") }; return try Data(values.map { guard let byte = $0.number, byte.rounded(.down) == byte, (0...255).contains(byte) else { throw Self.error("Invalid byte") }; return UInt8(byte) }) }
        return try JSONEncoder().encode(value)
    }
    private func text(_ value: WeappJSON) throws -> String { if let text = value.string { return text }; return String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func emit(_ object: String, _ event: String, _ value: WeappJSON) {
        for (id, var subscription) in subscriptions where subscription.object == object && subscription.event == event && !subscription.call.cancellation.isCancelled {
            subscription.sequence += 1; subscriptions[id] = subscription
            do { _ = try session?.emitHostApiEvent(["sessionId": subscription.call.context["sessionId"], "accountEpoch": subscription.call.context["account"]["epoch"], "subscriptionId": .string(id), "objectId": .string(object), "sequence": .string(String(subscription.sequence)), "event": .string(event), "value": value]) }
            catch { transfers[object]?.task?.cancel(); sockets[object]?.native.cancel() }
        }
    }
    private func sameOwner(_ a: WeappHostApiCall, _ b: WeappHostApiCall) -> Bool { a.context["sessionId"] == b.context["sessionId"] && a.context["application"] == b.context["application"] && a.context["account"] == b.context["account"] }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let value = call.payload; guard let object = value["objectId"].string else { throw Self.error("Runtime task identity required") }
        if api.hasPrefix("object:") {
            if api.contains(".on") || api.contains(".off") {
                guard let id = value["subscriptionId"].string else { throw Self.error("Task subscription identity required") }
                if api.contains(".off") || value["action"].string == "unsubscribe" { subscriptions.removeValue(forKey: id) }
                else { guard subscriptions.count < 256 else { throw Self.error("Subscription limit") }; let event = String(api.split(separator: ".").last!.dropFirst(2)); subscriptions[id] = Subscription(call: call, object: object, event: event); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id) } }
            } else if api.hasSuffix(".abort") { if let transfer = transfers[object] { guard sameOwner(transfer.call, call) else { throw CancellationError() }; transfer.task?.cancel() } }
            else {
                guard let socket = sockets[object], !socket.retired, sameOwner(socket.call, call), !socket.call.cancellation.isCancelled else { throw CancellationError() }
                if api.hasSuffix(".send") { let data = try bytes(value["data"]); guard socket.open, data.count <= 1048576 else { throw Self.error("Socket is not open or message too large") }; try await socket.native.send(value["data"].string.map { .string($0) } ?? .data(data)) }
                else { let code = Int(value["code"].number ?? 1000), reason = value["reason"].string ?? ""; guard code == 1000 || (3000...4999).contains(code), Data(reason.utf8).count <= 123, let selected = URLSessionWebSocketTask.CloseCode(rawValue: code) else { throw Self.error("Invalid close code/reason") }; socket.native.cancel(with: selected, reason: Data(reason.utf8)) }
            }; return ok(api)
        }
        if api == "wx.connectSocket" { return try connect(object, value, call) }
        guard transfers.count < 64, transfers[object] == nil else { throw Self.error("Transfer concurrency limit") }
        let transfer = Transfer(call); transfers[object] = transfer
        let operation = Task { @MainActor in try await self.request(api, object, call) }; transfer.task = operation
        call.cancellation.onCancel { operation.cancel() }
        defer { if transfers[object] === transfer { transfers.removeValue(forKey: object) } }
        do { return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() }) }
        catch { if error is CancellationError { throw error }; if let host = error as? WeappHostError { throw host }; let native = error as NSError; throw WeappHostError(code: native.code == NSURLErrorCancelled ? .cancelled : .invalidRequest, message: native.localizedDescription, details: ["errCode": .number(Double(native.code)), "errMsg": .string("\(api.replacingOccurrences(of: "wx.", with: "")):fail \(native.localizedDescription)"), "nativeDomain": .string(native.domain)]) }
    }
    private func request(_ api: String, _ object: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let value = call.payload; var url = try permitted(value["url"].string ?? "", socket: false)
        let method = api == "wx.uploadFile" ? "POST" : (value["method"].string ?? "GET").uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { throw Self.error("Unsupported HTTP method") }
        var body: Data?, contentType: String?
        if api == "wx.uploadFile" {
            guard let name = value["name"].string, name.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, let path = value["filePath"].string else { throw Self.error("Safe upload name and managed path required") }
            let file = try files.readForNative(path, context: call.context), boundary = "weapp-\(UUID().uuidString)"; var data = Data()
            guard try JSONEncoder().encode(value["formData"]).count <= 65536 else { throw Self.error("Form fields exceed limit") }
            for (key, item) in value["formData"].dictionary { guard key.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw Self.error("Unsafe form field name") }; data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(try self.text(item))\r\n".utf8)) }
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"upload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)); data.append(file); data.append(Data("\r\n--\(boundary)--\r\n".utf8)); body = data; contentType = "multipart/form-data; boundary=\(boundary)"
        } else if method == "GET" || method == "HEAD" {
            if case .object(let data) = value["data"] { var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; var query = parts.queryItems ?? []; for (key, item) in data { query.append(URLQueryItem(name: key, value: try self.text(item))) }; parts.queryItems = query; guard let resolved = parts.url else { throw Self.error("Invalid query") }; url = resolved }
            else if value["data"] != .null && value["data"].string != "" { throw Self.error("GET data must be a query object") }
        } else { let data = try bytes(value["data"]); guard data.count <= 1048576 else { throw Self.error("Request body limit") }; body = data; contentType = "application/json" }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = min(300, max(0.001, (value["timeout"].number ?? 60000) / 1000)); request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        guard value["header"].dictionary.count <= 64 else { throw Self.error("Header limit") }
        for (name, item) in value["header"].dictionary { guard let text = item.string, !["host", "content-length", "connection", "upgrade"].contains(name.lowercased()), !name.contains("\r"), !name.contains("\n"), !text.contains("\r"), !text.contains("\n") else { throw Self.error("Invalid header") }; request.setValue(text, forHTTPHeaderField: name) }
        if api == "wx.uploadFile" { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let native = transport.dataTask(with: request), transfer = HttpTransfer(object, api, call, native)
        let (data, response) = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in transfer.continuation = continuation; httpTransfers[native.taskIdentifier] = transfer; native.resume() }
        }, onCancel: { native.cancel() })
        try Task.checkCancellation(); guard !call.cancellation.isCancelled else { throw CancellationError() }
        let headers = headerValues(response)
        var result = ok(api).dictionary; result["statusCode"] = .number(Double(response.statusCode)); result["header"] = headers
        if api == "wx.downloadFile" { let path = try files.writeFromNative(data, path: value["filePath"].string, extension: "bin", context: call.context); result[value["filePath"].string == nil ? "tempFilePath" : "filePath"] = .string(path); emit(object, "ProgressUpdate", .object(["progress": .number(100), "totalBytesWritten": .number(Double(data.count)), "totalBytesExpectedToWrite": .number(Double(data.count))])) }
        else if value["responseType"].string == "arraybuffer" { result["data"] = binary(data) }
        else { let text = String(decoding: data, as: UTF8.self); result["data"] = api == "wx.request" && value["dataType"].string != "text" ? ((try? JSONDecoder().decode(WeappJSON.self, from: data)) ?? .string(text)) : .string(text) }
        if api == "wx.uploadFile" { emit(object, "ProgressUpdate", .object(["progress": .number(100), "totalBytesSent": .number(Double(body?.count ?? 0)), "totalBytesExpectedToSend": .number(Double(body?.count ?? 0))])) }; return .object(result)
    }
    private func connect(_ object: String, _ value: WeappJSON, _ call: WeappHostApiCall) throws -> WeappJSON {
        guard sockets.count < 32, sockets[object] == nil else { throw Self.error("Socket limit") }; let url = try permitted(value["url"].string ?? "", socket: true)
        let protocols = value["protocols"].array ?? []; guard protocols.count <= 16, protocols.allSatisfy({ $0.string?.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil }) else { throw Self.error("Invalid WebSocket protocols") }
        var request = URLRequest(url: url); for (name, item) in value["header"].dictionary { guard let text = item.string, !["host", "content-length", "connection", "upgrade", "sec-websocket-key", "sec-websocket-version"].contains(name.lowercased()) else { throw Self.error("Invalid WebSocket header") }; request.setValue(text, forHTTPHeaderField: name) }
        if !protocols.isEmpty { request.setValue(protocols.map { $0.string! }.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let native = transport.webSocketTask(with: request); native.maximumMessageSize = 1048576; let socket = Socket(call, native); sockets[object] = socket
        socket.receiver = Task { @MainActor [weak self] in
            defer { socket.receiverFinished = true; self?.retireSocketIfDrained(object, socket) }
            do { while !Task.isCancelled && !socket.retired && !call.cancellation.isCancelled { let message = try await native.receive(); guard !socket.retired && !call.cancellation.isCancelled else { return }; switch message { case .string(let text): self?.emit(object, "Message", .object(["data": .string(text)])); case .data(let data): self?.emit(object, "Message", .object(["data": self?.binary(data) ?? .null])); @unknown default: break } } } catch { self?.finishSocket(object, socket, error: error) }
        }
        call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { socket.retired = true; socket.receiver?.cancel(); native.cancel() }; native.resume()
        return .object(["objectId": .string(object), "errMsg": .string("connectSocket:ok")])
    }
    private func didOpen(_ task: Int, _ selected: String?) { guard let (object, socket) = sockets.first(where: { $0.value.native.taskIdentifier == task }), !socket.retired, !socket.call.cancellation.isCancelled else { return }; socket.open = true; emit(object, "Open", .object(["header": .object([:]), "protocol": selected.map { .string($0) } ?? .null])) }
    private func finishSocket(_ object: String, _ socket: Socket, code: Int? = nil, reason: Data? = nil, error: Error? = nil) {
        guard sockets[object] === socket, !socket.terminal else { return }; socket.terminal = true; socket.open = false
        if !socket.retired && !socket.call.cancellation.isCancelled {
            let closeCode = code ?? (socket.native.closeCode != .invalid ? socket.native.closeCode.rawValue : nil)
            if let closeCode { emit(object, "Close", .object(["code": .number(Double(closeCode)), "reason": .string((reason ?? socket.native.closeReason).map { String(decoding: $0, as: UTF8.self) } ?? "")])) }
            else if let error { emit(object, "Error", .object(["errMsg": .string("SocketTask:fail \(error.localizedDescription)"), "errCode": .number(Double((error as NSError).code)), "nativeDomain": .string((error as NSError).domain)])) }
            else { emit(object, "Close", .object(["code": .number(1006), "reason": .string("")])) }
        }
        socket.retired = true; socket.receiver?.cancel(); socket.native.cancel()
        retireSocketIfDrained(object, socket)
    }
    private func retireSocketIfDrained(_ object: String, _ socket: Socket) { if sockets[object] === socket, socket.terminal, socket.nativeCompleted, socket.receiverFinished { sockets.removeValue(forKey: object) } }
    private func didClose(_ task: Int, _ code: Int, _ reason: Data?) { guard let (object, socket) = sockets.first(where: { $0.value.native.taskIdentifier == task }) else { return }; finishSocket(object, socket, code: code, reason: reason) }
    private func headerValues(_ response: HTTPURLResponse) -> WeappJSON { .object(Dictionary(uniqueKeysWithValues: response.allHeaderFields.map { (String(describing: $0.key), .string(String(describing: $0.value))) })) }
    private func httpResponse(_ task: Int, _ response: HTTPURLResponse) -> URLSession.ResponseDisposition {
        guard let transfer = httpTransfers[task], !transfer.call.cancellation.isCancelled, !resetting, !closing else { return .cancel }
        transfer.response = response
        guard response.expectedContentLength <= transfer.limit else { transfer.failure = Self.error("Response byte limit"); return .cancel }
        emit(transfer.object, "HeadersReceived", .object(["header": headerValues(response)])); return .allow
    }
    private func httpData(_ task: Int, _ data: Data) {
        guard let transfer = httpTransfers[task], transfer.failure == nil else { return }
        guard !transfer.call.cancellation.isCancelled, !resetting, !closing else { transfer.native.cancel(); return }
        guard data.count <= transfer.limit - transfer.data.count else { transfer.failure = Self.error("Response byte limit"); transfer.native.cancel(); return }
        transfer.data.append(data)
        if transfer.api == "wx.request", transfer.call.payload["enableChunked"].bool == true {
            var offset = 0
            while offset < data.count { let end = min(data.count, offset + 32768); emit(transfer.object, "ChunkReceived", .object(["data": binary(data.subdata(in: offset..<end))])); offset = end }
        }
        if transfer.api == "wx.downloadFile", Date().timeIntervalSince(transfer.progress) >= 0.1 {
            transfer.progress = Date(); let total = transfer.response?.expectedContentLength ?? -1
            emit(transfer.object, "ProgressUpdate", .object(["totalBytesWritten": .number(Double(transfer.data.count)), "totalBytesExpectedToWrite": .number(Double(total)), "progress": .number(total > 0 ? Double(transfer.data.count * 100) / Double(total) : 0)]))
        }
    }
    private func didComplete(_ task: Int, _ error: Error?) {
        if let transfer = httpTransfers.removeValue(forKey: task) {
            if let failure = transfer.failure ?? error { transfer.continuation?.resume(throwing: failure) }
            else if let response = transfer.response { transfer.continuation?.resume(returning: (transfer.data, response)) }
            else { transfer.continuation?.resume(throwing: Self.error("HTTP response required")) }
            transfer.continuation = nil; return
        }
        guard let (object, socket) = sockets.first(where: { $0.value.native.taskIdentifier == task }) else { return }
        socket.nativeCompleted = true; finishSocket(object, socket, error: error); retireSocketIfDrained(object, socket)
    }
    private func reset() async throws {
        resetting = true
        let transfers = Array(self.transfers.values), sockets = Array(self.sockets.values)
        transfers.forEach { $0.task?.cancel() }; httpTransfers.values.forEach { $0.native.cancel() }; sockets.forEach { $0.retired = true; $0.receiver?.cancel(); $0.native.cancel() }
        for transfer in transfers { _ = await transfer.task?.result }; for socket in sockets { await socket.receiver?.value }
        let deadline = Date().addingTimeInterval(5)
        while sockets.contains(where: { !$0.nativeCompleted || !$0.receiverFinished || $0.native.state != .completed }) { guard Date() < deadline else { throw Self.error("Native WebSocket did not drain") }; try await Task.sleep(nanoseconds: 20_000_000) }
        self.transfers.removeAll(); self.sockets.removeAll(); subscriptions.removeAll(); resetting = false
    }
    public func close() async throws { if closed { return }; closing = true; try await reset(); closed = true; transport.invalidateAndCancel() }
}
