# iOS NFC

[简体中文](NFC-APIS.md) · **English**


Baseline is WeChat Foundation Library 3.17.3, miniprogram-api-typings 5.2.3. 66 official leafs and CoreNFC SDK header hashes are listed in NFC-CONTRACT.json.

NFC is disabled by default. Legacy `enableNfc: true` retains NDEF-only mode. A new configuration `nfcConfiguration: WeappNfcConfiguration(ndef: true, isoDep: true, mifareUltralight: true, nfcF: true, nfcV: true)` allows explicit selection of other technologies.
A non-empty NFCReaderUsageDescription and actual device readingAvailable are required. For ISO7816, the Info.plist must include select-identifiers; for FeliCa, specific system codes are required.
These configurations do not prove signature credentials: CoreNFC validates TAG entitlements and AID/systemcode at real begin/activation. `startDiscovery` only succeeds upon receiving a genuine `didBecomeActive` notification. Security-denied or missing credentials result in system-level invalidation failure. NFC is not registered in simulators.

| Object | Public Implementation and Limitations |
|-------|----------------------------------------|
| NFCAdapter | factory/tech/startDiscovery/stopDiscovery/onDiscovered/offDiscovered; tech contains only the get* subset of genuinely registered technologies. |
| Ndef | connect/close/isConnected/setTimeout/writeNdefMessage/onNdefMessage/offNdefMessage; real CoreNFC NDEF read/status/write operations. |
| IsoDep | connect/close/isConnected/setTimeout/transceive/getHistoricalBytes; accepts only real ISO7816 APDU; response includes SW1/SW2; system-enforced AID is declared. Fails if no Type A historical bytes are present. |
| MifareUltralight | connect/close/isConnected/setTimeout/transceive; must be an actual Ultralight family; native sendMiFareCommand is used. |
| NfcF | connect/close/isConnected/setTimeout/transceive/getMaxTransceiveLength; native 254-byte packet without LEN/CRC; adapter validates/removes input LEN and reconstructs real response LEN; wire-level limit is 255. |
| NfcV | connect/close/isConnected/setTimeout/transceive/getMaxTransceiveLength; native flag/command/data format; total length up to 256; response is reassembled with real response flag/data. |

Classic/Crypto1, generic NfcA/NfcB raw, ATQA/SAK are not supported. No spoofing of CoreNFC-unsupported IsoDep/Ultralight maximum transfer lengths. Only the 41 candidate leafs listed above are activated based on actual configuration negotiation.

Child objects are first bound to a real tag epoch; upon reading a new tag, stop, backgrounding, or account retirement, old objects become invalid and must be reacquired. `close` invalidates the reader for this container only, does not close the host's other NFC sessions.
Timeouts apply to the total operation duration of this reader and do not modify system-wide NFC settings.
Normal cancellation immediately blocks old results, but cleanup must wait for `didInvalidate` and each real native command callback; neither can replace the other; if cleanup is not complete within 5 seconds, the owner remains retained and retry is required.
Event delivery errors immediately terminate the reader; individual NDEF or binary responses are capped at 1 MiB, with NDEF limited to 64 records.

`node tools/test-nfc-boundary.mjs` uses real host Swift to perform cancellation/terminal separation and frame boundary testing.
Compilation and testing do not equate to device signing, tag read/write, or UI permission validation.
