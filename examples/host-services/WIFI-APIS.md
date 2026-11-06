# iOS Wi-Fi 公共能力范围

SDK 默认不安装 Wi-Fi。宿主显式配置：

```swift
let wifi = WeappWifiConfiguration(connectToNetworks: true, readCurrentNetwork: true)
let toolkit = try WeappNativeDeviceServices(presenter: presenter, wifiConfiguration: wifi)
```

宿主 target 需要真实签名的 Access Wi-Fi Information
(`com.apple.developer.networking.wifi-info`)；连接还需要 Hotspot Configuration
(`com.apple.developer.networking.HotspotConfiguration`)。配置布尔值只决定宿主选择的
SDK 范围，不是 entitlement 验证。实际 NEHotspotConfigurationManager / fetchCurrent
由 OS 执行签名与资格检查，缺失时失败或返回 nil，不伪装授权。

Info.plist 必须声明 NSLocationWhenInUseUsageDescription；独立小程序位置同意与
OS 前台精确位置授权分别核验。系统允许 app 配置的当前网络等其他资格条件也不能
替代 SDK 的小程序授权边界。

| API | 公共实现与限制 |
| --- | --- |
| startWifi / stopWifi | 初始化/停止当前 owner 的服务；不切系统开关。stop 保留独立注册的订阅。 |
| getConnectedWifi | 必须 partialInfo:true，返回 fetchCurrent 的真实 SSID、BSSID。nil、空值或隐私占位 BSSID 明确失败。 |
| onWifiConnectedWithPartialInfo / offWifiConnectedWithPartialInfo | NWPathMonitor 触发有界查询，前台报告真实 SSID 变化；最多 32 个订阅。 |
| connectWifi | 每次原生确认后，真实 apply open/WPA/WPA2 配置，固定 joinOnce=true。必须由 fetchCurrent 确认实际 SSID 才成功；最多等待 10 秒关联。配置成功本身不等于连接成功。 |

BSSID 定向连接、maunal 跳系统 Wi-Fi 设置、WEP/enterprise 不在此 adapter 范围。
不覆盖此 app 已有的宿主配置。取消/失败删除本 adapter 新建的配置；换号与关闭
等待仍在途的真实 apply callback，之后移除自身配置，不能提前 ACK 让旧 owner
的迟到连接进入新 owner。系统 joinOnce 的生命周期仍由 OS 管理。

以下方法或完整数据在通用 iOS container 范围内不适用，未注册对应假实现：

- getWifiList、onGetWifiList、offGetWifiList、setWifiList：无通用 Wi-Fi 扫描 API。
  HotspotHelper 需要 Apple 特许 entitlement，且只允许热点集成；不能为了普通
  配件、位置或任意扫描挪用它。
- onWifiConnected、offWifiConnected 及完整 getConnectedWifi 数据：公开
  fetchCurrent 只保证 SSID、BSSID、securityType 有效；frequency 无公开字段，
  signalStrength 属于 HotspotHelper category，不能把它在 fetchCurrent 对象上的
  默认值当成真实测量。当前用 partialInfo 契约，不猜信号或频率。

官方来源：

- [Apple TN3111: iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)：无通用扫描 API；HotspotHelper 使用限制；临时加入使用 joinOnce。
- [NEHotspotNetwork.fetchCurrent](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:))：签名 entitlement 与调用资格。
- [NEHotspotConfiguration.joinOnce](https://developer.apple.com/documentation/networkextension/nehotspotconfiguration/joinonce)：临时配置。

开发记录同时保留所读 Xcode 官方头文件 SHA、TN3111 原始 JSON SHA 和完整模块
编译证据。尚未运行带真实签名 entitlements 的 iOS app、系统连接确认、AP 关联、
SSID 读取、前后台恢复或换号清理，不能将源码/编译视为这些运行验收。
