import Foundation
import CryptoKit
import Darwin

/// Real asynchronous guest APIs backed by an app/account namespace in Application Support.
/// Synchronous file APIs remain unregistered; no native filesystem path is returned to guest code.
@MainActor public final class WeappManagedFiles {
    private let scopes = WeappManagedFileScopes()
    private var objects: [String: WeappJSON] = [:]
    public let supportedApis: Set<String> = ["wx.getFileSystemManager",
        "object:FileSystemManager.access", "object:FileSystemManager.readFile", "object:FileSystemManager.writeFile", "object:FileSystemManager.appendFile", "object:FileSystemManager.mkdir", "object:FileSystemManager.readdir", "object:FileSystemManager.rmdir", "object:FileSystemManager.unlink", "object:FileSystemManager.rename", "object:FileSystemManager.copyFile", "object:FileSystemManager.getFileInfo", "object:FileSystemManager.getSavedFileList", "object:FileSystemManager.removeSavedFile", "object:FileSystemManager.saveFile"]
    public init() throws {}
    public func install(in session: WeappContainerSession) throws {
        scopes.bind(session)
        try session.registerHostResourceCleanup("files-\(UUID().uuidString)") { [weak self] in self?.objects.removeAll() }
        for api in supportedApis.sorted() { try session.registerApiHandler(api) { [weak self] call in guard let self else { throw CancellationError() }; return try self.withOperationLock(call.context) { try self.invoke(api, call) } } }
    }
    internal func auxiliaryRoot(_ context: WeappJSON) throws -> URL { try scopes.auxiliaryRoot(context) }
    private func directory(_ context: WeappJSON) throws -> URL { try scopes.root(context) }
    public func resolve(_ path: String, context: WeappJSON) throws -> URL {
        guard path == "wxfile://user" || path.hasPrefix("wxfile://user/") else { throw error("Only managed wxfile://user paths are accepted") }
        let suffix = path == "wxfile://user" ? "" : String(path.dropFirst("wxfile://user/".count))
        let segments = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard suffix.isEmpty || segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".weapp-") && !$0.contains("\\") && !$0.contains("\0") }), suffix.utf8.count <= 1024 else { throw error("Unsafe managed file path") }
        let root = try directory(context).resolvingSymlinksInPath(), target = suffix.isEmpty ? root : root.appendingPathComponent(suffix).resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw error("Managed path escaped account namespace") }; return target
    }
    @discardableResult public func importTemporary(_ data: Data, extension fileExtension: String, context: WeappJSON) throws -> String {
        guard fileExtension.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil else { throw error("Invalid file extension") }
        return try withOperationLock(context) { let path = "wxfile://user/tmp/\(UUID().uuidString).\(fileExtension)"; try write(data, path, context); return path }
    }
    internal func readForNative(_ path: String, context: WeappJSON) throws -> Data {
        try withOperationLock(context) { let url = try resolve(path, context: context); let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]); guard size.isRegularFile == true, size.fileSize ?? Int.max <= 8 * 1048576 else { throw error("Managed native input exceeds file limit") }; return try Data(contentsOf: url) }
    }
    internal func writeFromNative(_ data: Data, path: String?, extension fileExtension: String, context: WeappJSON) throws -> String {
        try withOperationLock(context) { let path = path ?? "wxfile://user/tmp/\(UUID().uuidString).\(fileExtension)"; try write(data, path, context); return path }
    }
    private func withOperationLock<T>(_ context: WeappJSON, _ action: () throws -> T) throws -> T {
        let path = try directory(context).appendingPathComponent(".weapp-operations.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw error("Cannot open managed filesystem operation lock") }
        defer { Darwin.close(fd) }
        var status: Int32
        repeat { status = flock(fd, LOCK_EX) } while status != 0 && errno == EINTR
        guard status == 0 else { throw error("Cannot lock managed filesystem operation") }
        defer { _ = flock(fd, LOCK_UN) }
        return try action()
    }
    private func write(_ data: Data, _ path: String, _ context: WeappJSON) throws {
        guard data.count <= 8 * 1048576 else { throw error("File exceeds 8 MiB") }
        let target = try resolve(path, context: context), root = try directory(context)
        let current = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.intValue ?? 0
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var size = 0
        while let url = files?.nextObject() as? URL { let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]); if values.isRegularFile == true { size += values.fileSize ?? 0 } }
        guard size - current + data.count <= 32 * 1048576 else { throw error("Account file quota exceeded") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }; try handle.synchronize()
    }
    private func bytes(_ value: WeappJSON, encoding: String?) throws -> Data {
        if let values = value["__weappBinary"]["bytes"].array {
            guard value["__weappBinary"]["type"].string == "ArrayBuffer" else { throw error("ArrayBuffer required") }
            guard values.count <= 1048576 else { throw error("Binary chunk exceeds 1 MiB") }
            return try Data(values.map { item in guard let number = item.number, number.rounded(.down) == number, (0...255).contains(number) else { throw error("Invalid byte") }; return UInt8(number) })
        }
        guard let text = value.string else { throw error("String or ArrayBuffer required") }
        switch encoding ?? "utf8" {
        case "utf8", "utf-8": return Data(text.utf8)
        case "base64": guard let data = Data(base64Encoded: text) else { throw error("Invalid base64") }; return data
        default: throw error("Encoding is not supported by this adapter")
        }
    }
    private func error(_ message: String) -> WeappHostError { WeappHostError(code: .invalidRequest, message: message, details: ["errCode": .number(1300002)]) }
    private func invoke(_ api: String, _ call: WeappHostApiCall) throws -> WeappJSON {
        guard !call.cancellation.isCancelled else { throw CancellationError() }
        let value = call.payload, context = call.context
        if api == "wx.getFileSystemManager" {
            guard let id = value["objectId"].string, objects.count < 64 else { throw error("File manager object limit") }
            objects[id] = context; call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.objects.removeValue(forKey: id) }
            return .object(["objectId": .string(id)])
        }
        if api.hasPrefix("object:") {
            guard let id = value["objectId"].string, let owner = objects[id], owner["application"] == context["application"], owner["account"] == context["account"], owner["sessionId"] == context["sessionId"] else { throw error("File manager owner retired") }
        }
        let action = api.components(separatedBy: ".").last!
        var result: [String: WeappJSON] = ["errMsg": .string("\(api):ok")]
        func path(_ name: String = "filePath") throws -> URL { guard let path = value[name].string else { throw error("\(name) required") }; return try resolve(path, context: context) }
        switch action {
        case "access": guard FileManager.default.fileExists(atPath: try resolve(value["path"].string ?? "", context: context).path) else { throw error("File does not exist") }
        case "writeFile", "appendFile":
            guard let path = value["filePath"].string else { throw error("filePath required") }
            var data = try bytes(value["data"], encoding: value["encoding"].string)
            guard data.count <= 1048576 else { throw error("Write chunk exceeds 1 MiB") }
            if action == "appendFile" { let current = try Data(contentsOf: resolve(path, context: context)); data = current + data }
            try write(data, path, context)
        case "readFile":
            let url = try path(); let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let offset = value["position"].number ?? 0, length = value["length"].number ?? 1048576
            guard offset >= 0, offset.rounded(.down) == offset, offset <= 8 * 1048576, length >= 0, length.rounded(.down) == length, length <= 1048576 else { throw error("Invalid bounded read range") }
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if value["length"] == .null, size - Int(offset) > 1048576 { throw error("Read requires a bounded length") }
            try handle.seek(toOffset: UInt64(offset)); let data = try handle.read(upToCount: Int(length)) ?? Data()
            switch value["encoding"].string {
            case nil: result["data"] = .object(["__weappBinary": .object(["type": .string("ArrayBuffer"), "bytes": .array(data.map { .number(Double($0)) })])])
            case "utf8", "utf-8": guard let text = String(data: data, encoding: .utf8) else { throw error("Invalid UTF-8") }; result["data"] = .string(text)
            case "base64": result["data"] = .string(data.base64EncodedString())
            default: throw error("Unsupported read encoding")
            }
        case "mkdir": try FileManager.default.createDirectory(at: path("dirPath"), withIntermediateDirectories: value["recursive"].bool ?? false)
        case "readdir": result["files"] = .array(try FileManager.default.contentsOfDirectory(atPath: path("dirPath").path).filter { !$0.hasPrefix(".weapp-") }.sorted().map { .string($0) })
        case "unlink", "removeSavedFile", "rmdir":
            let url = try path(action == "rmdir" ? "dirPath" : "filePath")
            guard url != (try directory(context)) else { throw error("Cannot remove account root") }
            let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard action == "rmdir" ? properties.isDirectory == true : properties.isRegularFile == true else { throw error("Wrong file type for removal") }
            if action == "rmdir", value["recursive"].bool != true, try !FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty { throw error("Directory not empty") }
            try FileManager.default.removeItem(at: url)
        case "copyFile", "rename":
            let source = try path(action == "rename" ? "oldPath" : "srcPath"), destination = try path(action == "rename" ? "newPath" : "destPath")
            if action == "rename" { try FileManager.default.moveItem(at: source, to: destination) }
            else { let bytes = try Data(contentsOf: source); try write(bytes, value["destPath"].string!, context) }
        case "saveFile":
            let source = try path("tempFilePath"), destination = value["filePath"].string ?? "wxfile://user/saved/\(UUID().uuidString)"
            try write(Data(contentsOf: source), destination, context); result["savedFilePath"] = .string(destination)
        case "getFileInfo":
            let data = try Data(contentsOf: path()); guard data.count <= 8 * 1048576 else { throw error("File size limit") }
            result["size"] = .number(Double(data.count))
            switch value["digestAlgorithm"].string ?? "md5" { case "md5": result["digest"] = .string(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()); case "sha1": result["digest"] = .string(Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()); default: throw error("Invalid digest algorithm") }
        case "getSavedFileList":
            let saved = try resolve("wxfile://user/saved", context: context)
            let urls = (try? FileManager.default.contentsOfDirectory(at: saved, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey])) ?? []
            result["fileList"] = .array(try urls.compactMap { url in let properties = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey]); guard properties.isRegularFile == true else { return nil }; return .object(["filePath": .string("wxfile://user/saved/" + url.lastPathComponent), "size": .number(Double(properties.fileSize ?? 0)), "createTime": .number(properties.creationDate?.timeIntervalSince1970 ?? 0)]) })
        default: throw error("File operation not installed")
        }
        return .object(result)
    }
}
