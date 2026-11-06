# iOS 宿主能力

适配器要求匹配当前 host-services 协议的 native runtime。所有配置、安装、清理和
宿主回调在 MainActor 上执行；旧 preview framework 不包含新协议。

```swift
let toolkit = try WeappNativeDeviceServices(presenter: presenter,
    networkOrigins: ["https://api.example.com", "wss://api.example.com"],
    allowedMediaOrigins: ["https://media.example.com"],
    recordingAudioSession: hostRecordingAudioBroker)
try session.configureHostServices(trustedConfiguration)
try toolkit.install(in: session)
// 此后才 load pack；宿主持有 toolkit 直至 session 关闭。
```

可信配置必须来自宿主已验证的安装与账号，包含发行者、应用、实际 pack root、
环境、principal 和十进制 epoch。业务方法用 registerHostMethod；微信方法用
registerApiHandler。未安装的方法保持不支持。

`WeappHostServicesClient.identityState` 在可信账号明确为 `principalId: null` 且 epoch
为精确十进制 u64（快照辅助层接受 `"0"`，公开 owner 配置仍要求正数）时准备未登录快照，不再读取已撤销的宿主 bearer。初始准备、
换号清理准备与前台刷新都使用同一入口；已登录 principal 仍必须查询真实后端，
网络、权限或凭据失败继续传递，不会回退为成功。快照不包含旧用户资料或手机号授权。

`readHostApiResource(context:offset:length:)` 透传资源 setter 的原始可信 context，
返回 `{bytes,totalBytes}`；单块最多 1 MiB。先检查 runtime 的
`hostServices.apiResourceChunks == "1.0"`，保留 context 中的十进制 epoch、deadline
和 session/call ID，不用 transport ID 替换。只读命令仍受运行时账号、期限与调用
存活检查；换号、结算、取消或超时后拒绝，旧 runtime 明确不支持。它不会创建
owner、进入 JS 或触发表面呈现，也不赋予任意路径读取权限。

小程序授权和操作系统权限分别检查。即使宿主已有系统授权，每个应用与账号仍须
经过独立 native 提示；持久记录按可信应用、发行者、账号及 epoch 隔离，
`getSetting` 不把未询问过的作用域伪装为已授权。宿主按实际能力配置
NSCameraUsageDescription、NSMicrophoneUsageDescription、
NSLocationWhenInUseUsageDescription、NSBluetoothAlwaysUsageDescription 等
Info.plist 条目。CoreBluetooth 不开放任意未发现的 peripheral，也不能设置
系统 MTU；未实现的方法不注册。

真实系统服务包括剪贴板、网络状态、电池、亮度、常亮、震动、原生 UI、WGS84 定位
及传感器。传感器支持 normal 采样；GCJ-02、后台定位及未实现的系统能力不冒充成功。
前台持续定位使用同一个 CLLocationManager，提供 start/stopLocationUpdate、
on/offLocationChange 与 on/offLocationChangeError；小程序隐藏或应用进入后台暂停，
回到前台按原 owner 恢复，换号与关闭删除订阅。单次定位完成不停止仍有效的持续
定位，native 回调只保留最新位置/错误，串行交付有界订阅。

toolkit 统一拥有文件、设备、BLE、媒体、网络、录音和系统适配器，也可独立安装。
`try await session.close()` 等待原生清理，再释放核心与文件 lease；并发 close
共享同一操作，失败后可重试。deinit 的异步清理失败会保留 owner，可通过
`WeappContainerSession.failedFinalResourceCleanups` 查看并调用
`await WeappContainerSession.retryFinalResourceCleanups()` 重试，成功后再释放。

网络使用独立 ephemeral URLSession，支持 HTTP、受管 multipart 上传/下载、
响应头/分块/进度和 WebSocket。宿主列出精确 HTTPS/WSS origin；不共享宿主
Cookie/cache、不跟随重定向，显式开发选项仅放行 loopback HTTP/WS。HTTP 响应与
普通请求体 1 MiB，上传/下载文件 8 MiB，socket 消息 1 MiB。串行 delegate 对
有界数据同步交付主线程事件；取消等待真实 didComplete，socket 还须接收协程
结束，才完成换号或关闭的清理 ACK。

录音只有在宿主提供 `WeappRecordingAudioSession` 时注册。音频 broker 决定
如何与宿主已有 AVAudioSession 共存；明确没有其他音频 owner 时，才选择
`WeappExclusiveRecordingAudioSession()`。默认 nil 不接管宿主共享音频。
RecorderManager 使用真实 AVAudioRecorder，独立小程序/OS 授权，支持 AAC m4a、
100–60000ms、最多 4 MiB，默认 8000Hz、双声道、48000bps、60000ms。支持官方九档
8000–48000Hz，按各采样率分别校验官方编码码率范围；仅接受 auto audioSource、
default audioMode，其他输入源、模式与 frameSize 明确拒绝。完成后
导入受管文件。隐藏/后台/换号停止录音；音频 lease 恢复或 staging 删除失败时
保留资源供重试。
导入前以 AVAudioFile 的真实格式核对请求的采样率与声道，native encoder 降级时
发出 Error 并拒绝交付该文件，避免把不同格式的录音作为成功结果。

通讯录、日历、VisionKit/照片扫码、CoreNFC NDEF 与可信 SOTER 注入的配置和实际
支持范围见 [系统能力](examples/host-services/SYSTEM-APIS.md)。NFC 仅显式
`enableNfc: true` 并具备设备、Info.plist 和 entitlement 配置时安装；SOTER signer
始终由 native 宿主注入。

iBeacon 由独立 CLLocationManager 实际 ranging，提供 start/stopBeaconDiscovery、
getBeacons、on/offBeaconUpdate 与 on/offBeaconServiceChange。仅在设备支持 ranging、
并同时声明位置和蓝牙用途时安装；操作还需独立小程序位置/蓝牙授权、前台精确位置
OS 权限和可用 Bluetooth 状态。ignoreBluetoothAvailable 只允许按官方契约忽略
poweredOff，不绕过系统拒绝授权。最多 20 UUID、每 UUID 64 个最新读数、对 guest
最多 64 个结果和 32 个订阅。proximity/accuracy/rssi 来自 CLBeacon，unknown 的
accuracy 为 -1。隐藏/后台停止自己的 ranging，前台恢复；每次恢复创建独立 manager，
迟到回调不能进入新一代或新账号。未开始搜索时 getBeacons 明确报 11004。

Wi-Fi 默认不安装。宿主按真实签名 capabilities 传入 `wifiConfiguration`，公共
joinOnce/current SSID 子集、部分信息契约和 iOS 扫描限制见
[Wi-Fi 接入](examples/host-services/WIFI-APIS.md)。

`WeappManagedFiles` 提供基础异步文件方法及受管 `wxfile://user/` 路径。同步
FileSystemManager 方法由核心直接执行，双方使用同一目录与真实 flock 操作锁。读写块最多 1 MiB、单文件 8 MiB、单账号应用 32 MiB。写入等待
原子替换及文件同步；guest 拒绝并隐藏 `.weapp-*` 内部锁文件；guest 永远得不到 Application Support 的原生路径。
SDK 创建 native session 时总是设置 app-private `managedFilesRoot`，独立于键值存储
配置。文件与授权记录只使用 core `managedFileScope` 返回并经应用/账号身份核验的
`root` 和 `auxiliaryRoot`；资源清理完成前保留共享 lease。账号删除统一调用 core
`deleteAccountData`，在清理 ACK 与 surface detach 后同时移除文件和授权记录。

相机通过 AVCaptureVideoDataOutput 取得真实帧，视频通过 AVPlayerItemVideoOutput
解码。320×240、最多 5 fps 的 RGBA 预览进入原 Skia PaintPlan 对应节点，沿用
真实裁剪、变换、层级及透明度，使用有界的最新帧队列，不创建浮动播放器或覆盖
整个容器。视频只接受受管文件和明确允许的 HTTPS origin。上下文创建需要 runtime
签发的 componentTarget。拍照保存当前捕获帧，不提供独立高分辨率静态拍摄。
直播、DRM、录制、全屏、弹幕和逐相机原始帧订阅尚未实现，不注册相应 API。
后台、节点卸载、换号及 close 停止流、播放器和旧对象。

参考身份服务通过 native closure 读取宿主已有安全凭据：

```swift
let backend = try WeappHostServicesClient(endpoint: URL(string: "https://accounts.example.com")!) {
    call in try secureHostSession.token(for: call.context)
}
let identity = WeappHostIdentity(presenter: presenter, backend: backend)
let prepared = try await identity.prepareConfiguration(trustedConfiguration)
try session.configureHostServices(prepared)
try identity.install(in: session)
// 配置和安装完成后再 load。
```

后端错误将容器分类 `code/message` 与公开 API 字段分开处理。`code/message`
只接受非空字符串；公开字段按 envelope、envelope.details、error.details、error
的顺序合并，后来的非 null 值覆盖前值，排除结构键 `code/message/error/details`。
原始 `errCode/errMsg` 和扩展字段保留到 `WeappHostError.details`；缺失的 errCode
及缺失、空白或非字符串的 errMsg 才使用适配器默认值。五种 canonical 分类及对应
大写 `ERR_*` 保留类型化类别；consent/session 身份错误归为 permission_denied，
core 的 `ERR_UNSUPPORTED_CAPABILITY` 和 `unsupported_capability` 均归为 unsupported，
未知错误归为 invalid_request。iOS 既有的 `backendCode` 字段仍在缺失时补入原始
分类字符串，不覆盖服务返回的公开字段。运行 `npm run test:host-backend-error`
可实际执行 Swift 解析与 JSON codec 回归；它不代表原生 Session/JS 或设备验收。

应用后端用独立 confidential client 兑换短时、单次且绑定 app/pack 的 code。
小程序得不到宿主 bearer 和应用后端密钥。手机号与昵称头像分别提示和授权。
原生提示先从可信后端取得授权政策，展示登记 purpose，并在授权和 code 中绑定
purpose 与 permissionVersion。guest desc 不决定用途；拒绝同步服务端并刷新状态，
取消仍作为取消处理，服务端政策变更使旧授权失效。
`wx.checkSession` 检查真实已兑换的应用会话，签发 code 本身不会把 appLoggedIn
置为 true。宿主在兑换、撤权、凭据刷新及前台恢复后调用
`identity.refreshState(in:trustedContext:)`，更新同步 getState 和 onChange。
刷新在后端请求前读取 native state，核对可信 application/account 并冻结实际内部
sessionId；只有 ready owner 能开始该刷新，切换中或空 owner 直接拒绝。
响应完成后继续使用同一身份，不会重贴到新 owner。API 回调的原始
ApiCallContext 继续透传，运行时按完整应用/包、账号 epoch 和内部会话拒绝旧快照；
人工 native refresh 不需要伪装成 pending API call。
发起异步身份刷新前及提交带 context 的快照时，SDK 都要求 runtime 声明
`hostServices.snapshotOwnerContext == "1.0"`；缺失则报
`ERR_UNSUPPORTED_CAPABILITY`，不允许旧 runtime 静默忽略 owner 校验字段。
换号清理 hook 应先准备新宿主凭据，再等待
`identity.prepareAccountState(in:operationID:trustedContext:)`，最后返回清理成功；
旧账号快照不能用于新 owner。

连续换号会取消旧操作的 Task，但下一轮清理仍等待旧 Task 的实际终结，再执行
当前 hook 和 ACK。尚未开始的过时操作跳过；close 等待包括已过时任务的完整队列。
宿主 hook 必须在准确的设备、文件及后台任务真正释放后才返回，不能把发出取消
请求当成释放完成。`node tools/test-account-cleanup.mjs` 在 Swift 实际并发调度中
验证旧清理迟到、取消、连续换号、重试和关闭屏障；它不构成设备验收。

`WeappAppPayments` 同时注册 `wx.requestPayment` 与 `weappContainer.payment.request`，只接受服务端 orderId。官方渠道为
WeappWechatAppPay(appID:universalLink:) 和 WeappAlipayAppPay(urlScheme:)；官方 SDK
须作为该集成 target 的实际可见依赖，canImport 不成立时渠道明确不可用。SPM 宿主
也可以在自己的 target 中实现 WeappNativeAppPayChannel；仅在宿主 target 链接一个
库，并不自动使另一个独立 target 能 import 它。宿主处理官方 URL/Universal Link
回调，服务器验签和订单归属、金额、商户及交易校验后确认 paid，才报告支付成功。
取消等待不表示退款或交易关闭。

官方公开头文件 WechatOpenSDK 2.0.9 与 AlipaySDK-iOS 15.8.30 已用于 Swift 类型
检查，验证调用的选择器和字段。类型检查、后端本地测试、源码清单均不表示已经
链接运行官方钱包或完成真实商户、相机、外设和账号切换验收。
## 编译验证记录

[当前开发记录](test/evidence/host-services-development.json) 记录完整 Swift 模块和
`ReferenceHostServices.swift` 的源码哈希，以及实际微信 OpenSDK 2.0.9、支付宝
15.8.30 官方包的来源和哈希。本轮以 `arm64-apple-ios16.0-simulator` 发射生产模块，
启用两个官方 SDK 的 `canImport` 分支，再针对该模块编译示例，均无编译诊断。
这是编译证据；实际 iOS 二进制链接、设备交互、相机/蓝牙、官方钱包和商户交易仍需
各自对应的运行验证。

[前台定位与授权政策编译记录](test/evidence/host-services-location-policy-development.json)
另行绑定本批全部生产 Swift 源码与 sample，在官方支付头文件可见时完整发射模块、
编译示例且无诊断；定位订阅与授权 UI 的 iOS 实际交互仍待运行验收。

[Beacon 与录音编译记录](test/evidence/host-services-beacon-recorder-development.json)
保留本批完整模块与 sample 的源码哈希和零诊断日志。真实 Beacon、权限转换、
前后台 ranging 和 iOS 麦克风录音仍待独立运行验收。
已完成且未保留的 host call 会释放 setup 取消回调的捕获对象，保留资源的调用仍
等待取消，失败则运行一次清理；`tools/test-host-cancellation.mjs` 用实际 Swift
弱引用检查这三个生命周期边界。

Native snapshot owner validation belongs to the negotiated runtime. The SDK passes the complete captured context unchanged and preserves the runtime error, including `ERR_CANCELLED` for a retired owner; it updates its rebuild cache only after successful validation. A credential refresh cannot replace this owner check.
