import Foundation
import UIKit

/// Shared lifecycle owner for native UIKit, Flutter and React Native device adapters.
@MainActor public final class WeappNativeDeviceServices {
    private let files: WeappManagedFiles
    private let device: WeappDeviceApis
    private let bluetooth: WeappBluetoothApis?
    private let beacon: WeappBeaconApis?
    private let media: WeappNativeMedia
    private let network: WeappNetworkApis
    private let recorder: WeappRecorderApis?
    private let system: WeappSystemApis
    private var installed = false
    private var closed = false
    public init(presenter: UIViewController, networkOrigins: [String] = [], allowLoopbackForDevelopment: Bool = false,
                enableBluetooth: Bool = true, allowedMediaOrigins: [String] = [], recordingAudioSession: (any WeappRecordingAudioSession)? = nil,
                enableNfc: Bool = false, soterAttestationProvider: (any WeappSoterAttestationProvider)? = nil) throws {
        let files = try WeappManagedFiles(); self.files = files
        self.device = WeappDeviceApis(presenter: presenter)
        self.bluetooth = enableBluetooth ? WeappBluetoothApis(presenter: presenter) : nil
        self.beacon = enableBluetooth ? WeappBeaconApis(presenter: presenter) : nil
        self.media = WeappNativeMedia(presenter: presenter, files: files, allowedMediaOrigins: Set(allowedMediaOrigins))
        self.network = try WeappNetworkApis(files: files, allowedOrigins: networkOrigins, allowLoopbackForDevelopment: allowLoopbackForDevelopment)
        self.recorder = recordingAudioSession.map { WeappRecorderApis(presenter: presenter, files: files, audioSession: $0) }
        self.system = WeappSystemApis(presenter: presenter, files: files, soterAttestationProvider: soterAttestationProvider, enableNfc: enableNfc)
    }
    public func install(in session: WeappContainerSession) throws {
        guard !installed, !closed else { throw WeappHostError(code: .invalidRequest, message: "Device toolkit already installed or closed") }; installed = true
        try files.install(in: session); try device.install(in: session); try bluetooth?.install(in: session); try beacon?.install(in: session); try media.install(in: session); try network.install(in: session); try recorder?.install(in: session); try system.install(in: session)
    }
    /// Await session.close() first. Network and audio cleanup failures remain available for retry.
    public func close() async throws { guard !closed else { return }; try await network.close(); try await system.close(); try recorder?.close(); media.close(); bluetooth?.close(); beacon?.close(); device.close(); closed = true }
}
