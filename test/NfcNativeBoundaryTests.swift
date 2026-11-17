import Foundation

@main struct NfcNativeBoundaryTests {
    @MainActor static func main() throws {
        var replies = 0, terminals = 0
        let pending = WeappNfcNativeBoundary<Int>(settle: { result in if case .success = result { preconditionFailure("late native result escaped") }; replies += 1 }, terminal: { terminals += 1 })
        pending.cancel(CancellationError()); pending.cancel(CancellationError())
        precondition(replies == 1 && terminals == 0 && !pending.nativeFinished)
        pending.finish(.success(7)); pending.finish(.success(9))
        precondition(replies == 1 && terminals == 1 && pending.nativeFinished)
        var value = 0
        let successful = WeappNfcNativeBoundary<Int>(settle: { if case .success(let number) = $0 { value = number } }, terminal: { terminals += 1 })
        successful.finish(.success(11)); successful.cancel(CancellationError()); successful.finish(.success(22))
        precondition(value == 11 && terminals == 2)
        let commandPacket = try WeappNfcFrames.felicaCommand(Data([3, 0x06, 0x01]))
        let responseFrame = try WeappNfcFrames.felicaResponse(Data([0x07, 0x01]))
        precondition(commandPacket == Data([0x06, 0x01]) && responseFrame == Data([3, 0x07, 0x01]))
        let (flag, command, data) = try WeappNfcFrames.vicinityCommand(Data([0x22, 0x20, 0x01]))
        precondition(flag == 0x22 && command == 0x20 && data == Data([1]))
        let maximumFrame = Data([255]) + Data(repeating: 1, count: 254)
        let maximumPacket = try WeappNfcFrames.felicaCommand(maximumFrame)
        let maximumResponse = try WeappNfcFrames.felicaResponse(maximumPacket)
        let (_, _, maximumVicinityData) = try WeappNfcFrames.vicinityCommand(Data(repeating: 1, count: 256))
        precondition(maximumPacket.count == 254 && maximumResponse == maximumFrame && maximumVicinityData.count == 254)
        for data in [Data(), Data([2]), Data([2, 0, 0]), Data(repeating: 0, count: 256)] {
            do { _ = try WeappNfcFrames.felicaCommand(data); preconditionFailure("malformed FeliCa frame escaped") } catch is WeappHostError {}
        }
        for data in [Data(), Data([1]), Data(repeating: 0, count: 257)] {
            do { _ = try WeappNfcFrames.vicinityCommand(data); preconditionFailure("invalid ISO15693 frame escaped") } catch is WeappHostError {}
        }
        print("iOS NFC caller cancellation waits for distinct native terminal acknowledgment; FeliCa and ISO15693 framing stays exact and bounded")
    }
}
