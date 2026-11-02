import Foundation
import CoreBluetooth
import UIKit

/// Owns one CoreBluetooth central and its discovered peripherals. iOS controls MTU negotiation.
@MainActor public final class WeappBluetoothApis: NSObject {
    private weak var presenter: UIViewController?
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private weak var session: WeappContainerSession?
    private var central: CBCentralManager?
    private var opened = false
    private var opens: [String: CheckedContinuation<WeappJSON, Error>] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var devices: [UUID: WeappJSON] = [:]
    private var retiring: Set<UUID> = []
    private var subscriptions: [String: WeappHostApiCall] = [:]
    private var sequences: [String: UInt64] = [:]
    private struct Pending {
        let call: WeappHostApiCall
        let kind: String
        let uuid: CBUUID?
        let continuation: CheckedContinuation<WeappJSON, Error>
    }
    private var pending: [UUID: Pending] = [:]
    public let supportedApis: Set<String> = [
        "wx.openBluetoothAdapter", "wx.closeBluetoothAdapter", "wx.getBluetoothAdapterState", "wx.onBluetoothAdapterStateChange", "wx.offBluetoothAdapterStateChange",
        "wx.startBluetoothDevicesDiscovery", "wx.stopBluetoothDevicesDiscovery", "wx.getBluetoothDevices", "wx.getConnectedBluetoothDevices", "wx.onBluetoothDeviceFound", "wx.offBluetoothDeviceFound",
        "wx.createBLEConnection", "wx.closeBLEConnection", "wx.getBLEDeviceServices", "wx.getBLEDeviceCharacteristics", "wx.readBLECharacteristicValue", "wx.writeBLECharacteristicValue", "wx.notifyBLECharacteristicValueChange",
        "wx.onBLEConnectionStateChange", "wx.offBLEConnectionStateChange", "wx.onBLECharacteristicValueChange", "wx.offBLECharacteristicValueChange", "wx.getBLEDeviceRSSI", "wx.getBLEMTU",
    ]
    public override init() { super.init() }
    public init(presenter: UIViewController) { self.presenter = presenter; super.init() }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil else { throw failure("wx.openBluetoothAdapter", "Bluetooth adapter already installed") }
        session = target; scopes.bind(target)
        try target.registerHostResourceCleanup("bluetooth-\(UUID().uuidString)") { [weak self] in self?.reset() }
        for api in supportedApis.sorted() {
            try target.registerApiHandler(api) { [weak self] call in
                guard let self else { throw CancellationError() }
                do { return try await self.invoke(api, call) }
                catch let error as WeappHostError { throw error }
                catch is CancellationError { throw WeappHostError(code: .cancelled, message: "Bluetooth call cancelled") }
                catch { throw self.failure(api, error.localizedDescription) }
            }
        }
    }
    private func ok(_ api: String, _ values: [String: WeappJSON] = [:]) -> WeappJSON {
        .object(values.merging(["errMsg": .string("\(api):ok")]) { _, value in value })
    }
    private func failure(_ api: String, _ message: String, _ code: Int = 10008) -> WeappHostError {
        WeappHostError(code: code == 2001 ? .permissionDenied : .invalidRequest, message: message,
                       details: ["errCode": .number(Double(code)), "errMsg": .string("\(api):fail \(message)")])
    }
    private func uuid(_ text: String?) throws -> CBUUID {
        guard let text, text.range(of: "^(?:[0-9a-fA-F]{4}|[0-9a-fA-F]{8}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$", options: .regularExpression) != nil else {
            throw failure("BLE", "Invalid Bluetooth UUID")
        }
        return CBUUID(string: text)
    }
    private func binary(_ data: Data) -> WeappJSON {
        .object(["__weappBinary": .object(["type": .string("ArrayBuffer"), "bytes": .array(data.map { .number(Double($0)) })])])
    }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        try Task.checkCancellation()
        guard !call.cancellation.isCancelled, call.context != .null else { throw CancellationError() }
        let value = call.payload
        if api.hasPrefix("wx.on") || api.hasPrefix("wx.off") {
            guard let id = value["subscriptionId"].string else { throw failure(api, "Subscription identity required") }
            if api.hasPrefix("wx.off") { subscriptions.removeValue(forKey: id); sequences.removeValue(forKey: id) }
            else {
                subscriptions[id] = call; call.cancellation.retainUntilCancelled()
                call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id); self?.sequences.removeValue(forKey: id) }
            }
            return ok(api)
        }
        if api == "wx.openBluetoothAdapter" {
            guard try await consent.request(call, "scope.bluetooth") else { throw failure(api, "App permission denied", 2001) }
            guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") is String else { throw failure(api, "Configure NSBluetoothAlwaysUsageDescription", 2001) }
            if let central, central.state == .poweredOn { opened = true; return ok(api) }
            return try await withCheckedThrowingContinuation { continuation in
                opens[call.id] = continuation
                call.cancellation.onCancel { [weak self] in self?.opens.removeValue(forKey: call.id)?.resume(throwing: CancellationError()) }
                if central == nil { central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
                else { updateCentralState() }
            }
        }
        guard opened, let central, central.state == .poweredOn else { throw failure(api, "Bluetooth unavailable or adapter not open", 10001) }
        switch api {
        case "wx.closeBluetoothAdapter": reset(); return ok(api)
        case "wx.getBluetoothAdapterState": return ok(api, ["available": .bool(true), "discovering": .bool(central.isScanning)])
        case "wx.startBluetoothDevicesDiscovery":
            guard !central.isScanning else { throw failure(api, "Discovery already running") }
            let services = try value["services"].array?.map { try uuid($0.string) }
            central.scanForPeripherals(withServices: services?.isEmpty == true ? nil : services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: value["allowDuplicatesKey"].bool ?? false]); return ok(api)
        case "wx.stopBluetoothDevicesDiscovery": central.stopScan(); return ok(api)
        case "wx.getBluetoothDevices": return ok(api, ["devices": .array(Array(devices.values))])
        case "wx.getConnectedBluetoothDevices":
            let filters = try value["services"].array?.map { try uuid($0.string) } ?? []
            return ok(api, ["devices": .array(peripherals.values.filter { peripheral in
                peripheral.state == .connected && (filters.isEmpty || peripheral.services?.contains { filters.contains($0.uuid) } == true)
            }.map { devices[$0.identifier] ?? .object(["deviceId": .string($0.identifier.uuidString), "name": .string($0.name ?? "")]) })])
        case "wx.createBLEConnection":
            let peripheral = try selected(value, connected: false)
            guard peripheral.state == .disconnected else { throw failure(api, "Device already connecting or connected") }
            peripheral.delegate = self
            return try await operation(call, peripheral, "connect") { central.connect(peripheral) }
        case "wx.closeBLEConnection": let peripheral = try selected(value, connected: false); retire(peripheral); return ok(api)
        case "wx.getBLEDeviceServices":
            let peripheral = try selected(value)
            if let services = peripheral.services { return serviceResult(api, services) }
            return try await operation(call, peripheral, "services") { peripheral.discoverServices(nil) }
        case "wx.getBLEDeviceCharacteristics":
            let peripheral = try selected(value), service = try service(peripheral, value)
            if let values = service.characteristics { return characteristicResult(api, values) }
            return try await operation(call, peripheral, "characteristics", service.uuid) { peripheral.discoverCharacteristics(nil, for: service) }
        case "wx.readBLECharacteristicValue", "wx.writeBLECharacteristicValue", "wx.notifyBLECharacteristicValueChange":
            let peripheral = try selected(value), characteristic = try characteristic(peripheral, value)
            if api == "wx.readBLECharacteristicValue" {
                guard !characteristic.isNotifying else { throw failure(api, "Stop notifications before an explicit read") }
                return try await operation(call, peripheral, "read", characteristic.uuid) { peripheral.readValue(for: characteristic) }
            }
            if api == "wx.notifyBLECharacteristicValueChange" {
                guard let enabled = value["state"].bool else { throw failure(api, "state must be boolean") }
                return try await operation(call, peripheral, "notify", characteristic.uuid) { peripheral.setNotifyValue(enabled, for: characteristic) }
            }
            guard let bytes = value["value"]["__weappBinary"]["bytes"].array, bytes.count <= 512 else { throw failure(api, "Bounded ArrayBuffer required") }
            let data = try Data(bytes.map { item -> UInt8 in
                guard let number = item.number, number.rounded(.down) == number, (0...255).contains(number) else { throw failure(api, "Invalid byte") }; return UInt8(number)
            })
            let type: CBCharacteristicWriteType = value["writeType"].string == "writeNoResponse" ? .withoutResponse : .withResponse
            guard data.count <= peripheral.maximumWriteValueLength(for: type) else { throw failure(api, "Value exceeds negotiated MTU") }
            if type == .withoutResponse {
                guard pending[peripheral.identifier] == nil, peripheral.canSendWriteWithoutResponse else { throw failure(api, "Peripheral write queue busy") }
                peripheral.writeValue(data, for: characteristic, type: type); return ok(api)
            }
            return try await operation(call, peripheral, "write", characteristic.uuid) { peripheral.writeValue(data, for: characteristic, type: type) }
        case "wx.getBLEDeviceRSSI": let peripheral = try selected(value); return try await operation(call, peripheral, "rssi") { peripheral.readRSSI() }
        case "wx.getBLEMTU": let peripheral = try selected(value); return ok(api, ["mtu": .number(Double(peripheral.maximumWriteValueLength(for: value["writeType"].string == "writeNoResponse" ? .withoutResponse : .withResponse) + 3))])
        default: throw failure(api, "API not installed")
        }
    }
    private func selected(_ value: WeappJSON, connected: Bool = true) throws -> CBPeripheral {
        guard let text = value["deviceId"].string, let id = UUID(uuidString: text), let peripheral = peripherals[id], !connected || peripheral.state == .connected else { throw failure("BLE", "No owned device connection", 10006) }
        return peripheral
    }
    private func service(_ peripheral: CBPeripheral, _ value: WeappJSON) throws -> CBService {
        let id = try uuid(value["serviceId"].string)
        guard let service = peripheral.services?.first(where: { $0.uuid == id }) else { throw failure("BLE", "Service not discovered", 10004) }; return service
    }
    private func characteristic(_ peripheral: CBPeripheral, _ value: WeappJSON) throws -> CBCharacteristic {
        let id = try uuid(value["characteristicId"].string)
        guard let characteristic = try service(peripheral, value).characteristics?.first(where: { $0.uuid == id }) else { throw failure("BLE", "Characteristic not discovered", 10005) }; return characteristic
    }
    private func operation(_ call: WeappHostApiCall, _ peripheral: CBPeripheral, _ kind: String, _ uuid: CBUUID? = nil, submit: () -> Void) async throws -> WeappJSON {
        guard pending[peripheral.identifier] == nil else { throw failure(call.method, "One operation at a time per device") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[peripheral.identifier] = Pending(call: call, kind: kind, uuid: uuid, continuation: continuation)
            call.cancellation.onCancel { [weak self, weak peripheral] in
                guard let self, let peripheral, self.pending[peripheral.identifier]?.call.id == call.id else { return }
                self.retire(peripheral)
            }
            submit()
        }
    }
    private func finish(_ peripheral: CBPeripheral, _ kind: String, _ uuid: CBUUID? = nil, _ error: Error? = nil, values: [String: WeappJSON] = [:]) {
        guard peripherals[peripheral.identifier] === peripheral, let active = pending[peripheral.identifier], active.kind == kind, active.uuid == uuid else { return }
        pending.removeValue(forKey: peripheral.identifier)
        if let error { active.continuation.resume(throwing: failure(active.call.method, error.localizedDescription)) }
        else { active.continuation.resume(returning: ok(active.call.method, values)) }
    }
    private func serviceResult(_ api: String, _ services: [CBService]) -> WeappJSON {
        ok(api, ["services": .array(services.map { .object(["uuid": .string($0.uuid.uuidString), "isPrimary": .bool($0.isPrimary)]) })])
    }
    private func characteristicResult(_ api: String, _ values: [CBCharacteristic]) -> WeappJSON {
        ok(api, ["characteristics": .array(values.map { item in .object(["uuid": .string(item.uuid.uuidString), "properties": .object([
            "read": .bool(item.properties.contains(.read)), "write": .bool(item.properties.contains(.write)), "writeNoResponse": .bool(item.properties.contains(.writeWithoutResponse)),
            "notify": .bool(item.properties.contains(.notify)), "indicate": .bool(item.properties.contains(.indicate)),
        ])]) })])
    }
    private func retire(_ peripheral: CBPeripheral) {
        pending.removeValue(forKey: peripheral.identifier)?.continuation.resume(throwing: failure("BLE", "Owned connection closed", 10006))
        peripheral.delegate = nil
        if peripheral.state != .disconnected { retiring.insert(peripheral.identifier); central?.cancelPeripheralConnection(peripheral) }
        peripherals.removeValue(forKey: peripheral.identifier)
    }
    private func updateCentralState() {
        guard let central else { return }
        if [.unknown, .resetting].contains(central.state) { return }
        let available = central.state == .poweredOn
        let waiting = opens; opens.removeAll(); opened = available
        for continuation in waiting.values {
            if available { continuation.resume(returning: ok("wx.openBluetoothAdapter")) }
            else { continuation.resume(throwing: failure("wx.openBluetoothAdapter", "Bluetooth unavailable", central.state == .unauthorized ? 2001 : 10001)) }
        }
        if !available { for peripheral in Array(peripherals.values) { retire(peripheral) } }
        emit("wx.onBluetoothAdapterStateChange", ["available": .bool(available), "discovering": .bool(central.isScanning)])
    }
    private func emit(_ api: String, _ value: [String: WeappJSON]) {
        for (id, call) in subscriptions where call.method == api && !call.cancellation.isCancelled {
            let next = (sequences[id] ?? 0) + 1; sequences[id] = next
            guard next <= 9007199254740991 else { continue }
            do { _ = try session?.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "subscriptionId": .string(id), "sequence": .string(String(next)), "value": .object(value)]) }
            catch { session?.report(error) }
        }
    }
    private func reset() {
        consent.reset()
        central?.stopScan()
        for peripheral in Array(peripherals.values) { retire(peripheral) }
        let waiting = opens; opens.removeAll(); for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
        central?.delegate = nil; central = nil; retiring.removeAll(); devices.removeAll(); subscriptions.removeAll(); sequences.removeAll(); opened = false
    }
    public func close() { reset(); session = nil }
}

extension WeappBluetoothApis: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor [weak self] in if self?.central === central { self?.updateCentralState() } } }
    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self, self.central === central, self.opened, central.isScanning, !self.retiring.contains(peripheral.identifier), self.peripherals.count < 256 || self.peripherals[peripheral.identifier] != nil else { return }
            self.peripherals[peripheral.identifier] = peripheral
            let device: WeappJSON = .object(["deviceId": .string(peripheral.identifier.uuidString), "name": .string(peripheral.name ?? ""), "localName": .string(advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""), "RSSI": .number(RSSI.doubleValue),
                "advertisData": self.binary(advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()), "advertisServiceUUIDs": .array((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { .string($0.uuidString) })])
            self.devices[peripheral.identifier] = device; self.emit("wx.onBluetoothDeviceFound", ["devices": .array([device])])
        }
    }
    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { Task { @MainActor [weak self] in guard let self, self.central === central, self.peripherals[peripheral.identifier] === peripheral, !self.retiring.contains(peripheral.identifier) else { return }; self.finish(peripheral, "connect"); self.emit("wx.onBLEConnectionStateChange", ["deviceId": .string(peripheral.identifier.uuidString), "connected": .bool(true)]) } }
    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { Task { @MainActor [weak self] in guard let self, self.central === central else { return }; self.finish(peripheral, "connect", nil, error ?? self.failure("BLE", "Connection failed")); self.retire(peripheral) } }
    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { Task { @MainActor [weak self] in
        guard let self, self.central === central else { return }
        let retiring = self.retiring.remove(peripheral.identifier) != nil
        guard retiring || self.peripherals[peripheral.identifier] === peripheral else { return }
        self.retire(peripheral); self.emit("wx.onBLEConnectionStateChange", ["deviceId": .string(peripheral.identifier.uuidString), "connected": .bool(false)])
    } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor [weak self] in guard let self else { return }; self.finish(peripheral, "services", nil, error, values: self.serviceResult("", peripheral.services ?? [])["services"].array.map { ["services": .array($0)] } ?? [:]) } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) { Task { @MainActor [weak self] in guard let self else { return }; self.finish(peripheral, "characteristics", service.uuid, error, values: ["characteristics": self.characteristicResult("", service.characteristics ?? [])["characteristics"]]) } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { Task { @MainActor [weak self] in self?.finish(peripheral, "write", characteristic.uuid, error) } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) { Task { @MainActor [weak self] in self?.finish(peripheral, "notify", characteristic.uuid, error) } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) { Task { @MainActor [weak self] in self?.finish(peripheral, "rssi", nil, error, values: ["RSSI": .number(RSSI.doubleValue)]) } }
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value ?? Data()
        Task { @MainActor [weak self] in
            guard let self, self.peripherals[peripheral.identifier] === peripheral else { return }
            self.finish(peripheral, "read", characteristic.uuid, error, values: ["value": self.binary(data)])
            if error == nil { self.emit("wx.onBLECharacteristicValueChange", ["deviceId": .string(peripheral.identifier.uuidString), "serviceId": .string(characteristic.service?.uuid.uuidString ?? ""), "characteristicId": .string(characteristic.uuid.uuidString), "value": self.binary(data)]) }
        }
    }
}
