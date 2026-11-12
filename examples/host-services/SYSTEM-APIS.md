<a id="native-system-api"></a>
# 原生系统 API

**简体中文** · [English](SYSTEM-APIS.en.md)


`WeappSystemApis` 由 `WeappNativeDeviceServices` 统一安装，也可在可信宿主配置后、加载小程序前独立安装。联系人、日历、相机扫码与 NFC 均使用系统 UI 或原生框架；编译通过不代表真机验收。

| 能力 | 原生实现与配置 | 边界 |
| --- | --- | --- |
| `wx.addPhoneContact` | ContactsUI 新联系人编辑器；`NSContactsUsageDescription`；图片仅通过共享 `WeappManagedFiles` 读取当前账号的虚拟路径 | 用户保存后才成功；取消返回取消。受限制的备注/微信专用字段明确拒绝 |
| `wx.addPhoneCalendar` / `wx.addPhoneRepeatCalendar` | EventKitUI 编辑器；iOS 17+ 使用写入授权及 `NSCalendarsWriteOnlyAccessUsageDescription`，iOS 16 使用 `NSCalendarsUsageDescription` | 支持日/周/月/年重复与提醒；微信签名跳转链接需另配宿主链接适配器 |
| `wx.scanCode` | VisionKit 相机识别、PhotosUI 选择图片后交给 Vision；相机需 `NSCameraUsageDescription`、系统授权和受支持的设备 | QR、常用条码、Data Matrix、PDF417；微信小程序码要求官方专用解码器，不能伪装为 QR |
| NFC / NDEF 对象 | `enableNfc: true`，实体硬件、`NFCReaderUsageDescription`、签名配置中的 NFC TAG entitlement；CoreNFC 读写 | ISO14443/15693；配置 FeliCa systemcodes 后才启用 ISO18092。未实现的原始技术收发方法不注册 |
| SOTER 支持与登记查询 | LocalAuthentication 与可选的真实 `WeappSoterAttestationProvider` 共同协商 | 未提供签名集成时返回空支持列表及未登记，不注册认证入口 |
| `wx.startSoterAuthentication` | 真实 Face ID/Touch ID 后调用宿主签名提供方；Face ID 需 `NSFaceIDUsageDescription` | 验证挑战与结果 `raw` 一致、结果和签名编码有界；签名信任、RSA/PSS 与服务端验签由真实 SOTER 集成负责 |

SOTER 提供方接收完整可信 `WeappHostApiCall`、认证方式和已认证的 `LAContext`，必须使用与应用、用户和账号 epoch 绑定的密钥/会话。不要用随机字符串、普通本地认证成功或自制证书冒充微信 SOTER 结果。后端应验证提供方信任链、签名、防重放计数和挑战归属。

CoreNFC 每次只允许一个活动 reader，NDEF 连接、读写和发现监听按 native object 身份归属。写入前查询真实标签容量与写入状态，原始记录使用受控 ArrayBuffer 通道。取消与超时停止本地操作，不承诺标签写入已回滚。退出、换号和隐藏会停止 reader、终止授权/编辑器和失效旧对象；关闭还等待 CoreNFC 失效回调及系统编辑器销毁。五秒内未完成时保留资源与清理失败，可重试，不能提前释放账号存储租约。

运行 `node sdk/ios/tools/test-system-api-payloads.mjs` 可复现本机 Swift 的二进制、日历参数和跨挑战证明拒绝测试。真实联系人保存/取消、日历权限/保存、相机与图片识别、NFC 读写/移走标签/后台、Face ID/Touch ID 与真实签名后端仍需使用配置好的实体 iOS 设备验收并记录版本、硬件和授权状态。
