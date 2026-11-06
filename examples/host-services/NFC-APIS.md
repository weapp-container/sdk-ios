# iOS NFC

基线固定为微信基础库 3.17.3、miniprogram-api-typings 5.2.3，66 个官方叶及
CoreNFC SDK header 哈希见 NFC-CONTRACT.json。

默认不注册 NFC。旧 `enableNfc: true` 保持 NDEF-only。新增
`nfcConfiguration: WeappNfcConfiguration(ndef: true, isoDep: true,
mifareUltralight: true, nfcF: true, nfcV: true)` 可显式选择其他技术。
必须有非空 NFCReaderUsageDescription、真实设备 readingAvailable；ISO7816
另需 Info.plist 的 select-identifiers，FeliCa 另需具体 systemcodes。
这些配置不证明签名资质：CoreNFC 在真实 begin/activation 时核验 TAG entitlement
及 AID/systemcode。startDiscovery 只有收到真实 didBecomeActive 才成功，安全
拒绝或缺失资质按系统 invalidation 失败。模拟器不注册 NFC。

| 对象 | 公开实现与限制 |
| --- | --- |
| NFCAdapter | factory/tech/startDiscovery/stopDiscovery/onDiscovered/offDiscovered；tech 仅含真实注册的 get* 子集。 |
| Ndef | connect/close/isConnected/setTimeout/writeNdefMessage/onNdefMessage/offNdefMessage；真实 CoreNFC NDEF read/status/write。 |
| IsoDep | connect/close/isConnected/setTimeout/transceive/getHistoricalBytes；只接受真实 ISO7816 APDU，响应包含 SW1/SW2；系统限制已声明 AID。无 Type A historicalBytes 时失败。 |
| MifareUltralight | connect/close/isConnected/setTimeout/transceive；必须实际 Ultralight family，原生 sendMiFareCommand。 |
| NfcF | connect/close/isConnected/setTimeout/transceive/getMaxTransceiveLength；原生 254-byte packet 不含 LEN/CRC，适配器校验/移除输入 LEN 并重建真实响应 LEN，wire 上限 255。 |
| NfcV | connect/close/isConnected/setTimeout/transceive/getMaxTransceiveLength；原生 flag/command/data，总长最多 256，响应重组真实 response flag/data。 |

不注册 Classic/Crypto1、通用 NfcA/NfcB raw、ATQA/SAK，也不编造 CoreNFC
未提供的 IsoDep/Ultralight 最大传输长度。仅上述 41 个候选叶按真实配置协商。

子对象首次绑定实际 tag epoch；读到新标签、stop、后台或账号退休后旧对象失效，
需重新获取。close 会失效此容器自己的 reader，不关闭宿主其他 NFC session。
超时是此 reader 的总操作期限，不修改系统全局 NFC 配置。
普通取消立即阻止旧结果，但清理还须等待 reader didInvalidate 和每个真实 native
command callback；二者不可互相代替，5 秒内未终结会保留 owner 并要求重试。
事件发送错误立即停止本 reader，单个 NDEF/二进制响应最多 1 MiB、NDEF 最多 64 records。

`node tools/test-nfc-boundary.mjs` 使用真实 host Swift 执行取消/终态分离和帧边界测试。
编译与此测试均不等于签名设备、标签读写或权限 UI 验收。
