# 极狐车况小组件 · iOS 移植版（v3.0）

Android 版 v3.0 正式版的 iOS 移植：SwiftUI 主 App + WidgetKit 小组件，功能与 Android 版对齐。

## 功能对照（Android v3.0 → iOS）

| Android v3.0 | iOS 移植 |
|---|---|
| 手机号 + 短信登录（极狐官方签名接口） | ✅ 同链路，MD5 签名算法逐行照搬 |
| 车况授权（第二条短信，auth/signin） | ✅ |
| 车况拉取（carState/query + getVehicleCondition） | ✅ 含 token 过期自动续期 |
| 远程控车：空调 / 门锁 / 车窗 / 寻车（remoteOperate + 回执轮询） | ✅ App 内按钮 + 大组件交互按钮（iOS 17） |
| 逆地理流水线：高德(内置Key) → Nominatim → Photon → BigDataCloud → 系统 → 城市表 | ✅ 150 城市表原样导出 |
| 车型识别：官方代号 > VIN 前 7 位 > 车型名 | ✅ |
| 车漆识别（colorName/colorCode 十余个候选字段） | ✅ |
| 4×2 紧凑卡片（车图 + 续航/电量/里程/温度/胎压/位置） | ✅ medium 小组件 |
| 4×4 带车控卡片（锁车/空调/车窗/寻车/刷新按钮） | ✅ large 小组件（AppIntents 交互式） |
| 卡片配色 浅/深/跟随、圆角、不透明度、字号缩放 | ✅ 设置页可调，App Group 共享 |
| 自定义车图（相册选图，448px 压缩） | ✅ 存 App Group 容器 |
| 自动刷新（AlarmManager 5/10/15/30/60 分钟） | ✅ BGAppRefreshTask + 后台 fetch |
| 使用须知（首次弹一次） / 关于·隐私 / 原始车况探测 | ✅ |

## 构建（本仓库自带 CI，无需 Mac）

推送到 GitHub 后 Actions 自动构建：

1. `xcodegen` 生成 Xcode 工程
2. `xcodebuild` 未签名编译（macos-15 runner，iOS SDK）
3. `ldid` 按 entitlements 伪签（保留 App Group）
4. 打包 `ArcfoxWidget-v3.0-ios-unsigned.ipa` 上传 artifact

本地有 Mac 时：

```bash
brew install xcodegen
xcodegen generate
open ArcfoxWidget.xcodeproj   # 选真机，Cmd+R
```

## 安装（按你手上的签名手段选）

| 手段 | 说明 |
|---|---|
| TrollStore | 未签名 ipa 直接装（TrollStore 内核绕过签名校验），App Group 权限完整 |
| Sideloadly / AltStore | 免费 Apple ID 重签，7 天续签 |
| 付费证书 | 用 p12 + 描述文件重签（如 巨魔商店外/爱思助手/证书工具），包 id 已固定 `com.arcfoxplus.widget` |

## 结构

```
project.yml                  # xcodegen 工程定义（App + WidgetExt 两个 target）
App/                         # 主 App：登录、首页折叠、高级设置、关于、诊断
Shared/                      # 与 Android 版逐文件对应的业务层
  ArcApi.swift               #   官方接口签名（MD5）+ HTTP
  Session.swift              #   登录态 / 车况授权 / getDefaultVehicle 解析
  Fetcher.swift              #   carState 解析（含 JsonProbe 宽松取值）
  TspControl.swift           #   远程控车指令 + 回执轮询 + hold 记账
  Geo.swift + CityTable.swift#   逆地理六级流水线
  CarModel.swift             #   车型/车漆识别 + 车图加载
Widget/                      # WidgetKit：medium 紧凑 + large 带车控（AppIntents）
.github/workflows/build.yml  # 云编译流水线
```

## 已知差异

- Android 桌面小组件的「双击进 App」「跳极狐官方 App」在 iOS 没有对应概念；点击小组件默认进本 App。
- 官方极狐 iOS App 的深链未做（Android 版跳的是安卓包名）。
- iOS 小组件刷新由系统调度，无法像 Android AlarmManager 那样精确 5 分钟；点组件上的刷新按钮可即时拉取。
