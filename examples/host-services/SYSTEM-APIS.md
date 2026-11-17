<a id="native-system-api"></a>
# 原生系统 API

**简体中文** · [English](SYSTEM-APIS.en.md)


`WeappSystemApis` 由 `WeappNativeDeviceServices` 统一安装，也可在可信宿主配置后、加载小程序前独立安装。联系人、日历、相机扫码与 NFC 均使用系统 UI 或原生框架；编译通过不代表真机验收。

| 能力 | 原生实现与配置 | 边界 |
| --- | --- | --- |
| `wx.addPhoneContact` | ContactsUI 新联系人编辑器；`NSContactsUsageDescription`；图片仅通过共享 `WeappManagedFiles` 读取当前账号的虚拟路径 | 用户保存后才成功；取消返回取消。未支持字段交给私有宿主适配器 |
| `wx.addPhoneCalendar` / `wx.addPhoneRepeatCalendar` | EventKitUI 编辑器；iOS 17+ 使用写入授权及 `NSCalendarsWriteOnlyAccessUsageDescription`，iOS 16 使用 `NSCalendarsUsageDescription` | 支持日/周/月/年重复与提醒；签名跳转链接交给私有宿主适配器 |
| `wx.scanCode` | VisionKit 相机识别、PhotosUI 选择图片后交给 Vision；相机需 `NSCameraUsageDescription`、系统授权和受支持的设备 | QR、常用条码、Data Matrix、PDF417；其他格式交给私有解码器 |
| NFC / NDEF 对象 | `enableNfc: true`，实体硬件、`NFCReaderUsageDescription`、签名配置中的 NFC TAG entitlement；CoreNFC 读写 | ISO14443/15693；配置 FeliCa systemcodes 后才启用 ISO18092。未实现的原始技术收发方法不注册 |

CoreNFC 每次只允许一个活动 reader，NDEF 连接、读写和发现监听按 native object 身份归属。写入前查询真实标签容量与写入状态，原始记录使用受控 ArrayBuffer 通道。取消与超时停止本地操作，不承诺标签写入已回滚。退出、换号和隐藏会停止 reader、终止授权/编辑器和失效旧对象；关闭还等待 CoreNFC 失效回调及系统编辑器销毁。五秒内未完成时保留资源与清理失败，可重试，不能提前释放账号存储租约。

运行 `node sdk/ios/tools/test-system-api-payloads.mjs` 可复现本机 Swift 的二进制和日历参数边界测试。真实联系人保存/取消、日历权限/保存、相机与图片识别、NFC 读写/移走标签/后台仍需使用配置好的实体 iOS 设备验收并记录版本、硬件和授权状态。
