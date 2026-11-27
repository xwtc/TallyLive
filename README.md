# TallyLive（在播）— Flutter 重建版

斗鱼 / 虎牙 / 抖音 / bilibili 直播聚合客户端。**Windows + iOS + Android 三端**，一套代码。

> 这是从 [TallyLive（Wails 版）](https://github.com/xwtc/TallyLIve) 重建的项目。
> Wails 版保留作为**协议移植参考**：它的 Go 实现里四个平台的取流签名、弹幕协议、
> TARS/protobuf 编解码都有详尽注释，是这份 Dart 代码的原始依据。

## 为什么换 Flutter

原项目是 Wails（WebView）+ xgplayer/MSE。这套栈为桌面选的，在桌面工作得很好，
但有两个结构性问题：

1. **iOS 上 WKWebView 没有 MSE**（caniuse: "Fully supported only in iPadOS"），
   斗鱼/虎牙的 HTTP-FLV 在 iPhone 上无法播放，这是核心功能缺失。
2. **WebView 不能把原生视频合成进 UI**。要把 libmpv 塞进 Wails，只能用独立
   Win32 子窗口，而它会盖住 WebView 里的弹幕层 —— 这是合成器能力缺失，不是代码问题。

Flutter 的 `media_kit`（底层 libmpv）把视频渲染成 **Flutter 纹理**，和 UI 走同一个
合成器，所以弹幕能自然叠在视频上、五端一套代码 —— 这也是
[Simple Live](https://github.com/xiaoyaocz/dart_simple_live) 的做法。

## 技术栈

| 层 | 选型 |
|---|---|
| UI | Flutter（Material 3，夜间导播台配色） |
| 播放器 | `media_kit` + `media_kit_video`（libmpv，三端官方支持） |
| 弹幕 | `canvas_danmaku`（下一阶段接入） |
| 网络 | `dio` |
| 平台协议 | 自研 Dart 实现，从 Wails 版的 Go 代码移植 |

## 目录

```
lib/
  main.dart                       应用入口、夜间主题、临时验证首页
  core/http.dart                  HTTP 层（移植 Go 的 common/http.go）
  platforms/bilibili/             B 站协议（第一阶段）
  ui/player_page.dart             播放页（media_kit Video + 预留弹幕层）
.github/workflows/build.yml       三端 CI
```

## 当前进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| S1 | Flutter 骨架 + media_kit + 三端 CI | ✅ 完成 |
| S2 | B 站协议（房间信息 + 取流） | ✅ 真机验证可播放 |
| S2 | 抽出共享模型 + `PlatformClient` 接口 | ✅ 完成 |
| S3 | 斗鱼协议（签名链 + getH5PlayV1 + 多 CDN） | ✅ 真机验证可播放 |
| S3 | 多线路（CDN）切换：档位 × 线路全组合 | ✅ 完成 |
| S3+ | B 站弹幕（WBI 签名 + WS + zlib 解包） | ✅ 已实现，待验证 |
| S3+ | 弹幕渲染层（canvas_danmaku，叠加在视频上） | ✅ 已实现 |
| S3+ | 斗鱼弹幕（裸 TCP + STT 帧） | ⬜ 待做 |
| S4 | 虎牙（TARS）、抖音（a_bogus + HEVC-FLV） | ⬜ 待做 |
| S5 | 夜间 Tally UI（四 Tab）、收藏、搜索、同步 | ⬜ 待做 |

**当前首页是临时验证入口**：选平台 + 输入房间号直接播放，用来确认
「协议取流 → libmpv → 画面」这条链路。跑通后替换为分区/列表/关注的正规首页。

## 构建

平台脚手架（`android/` `ios/` `windows/`）由 CI 用 `flutter create .` 生成，
本地不需要预先存在。

### CI（推荐，本地无需工具链）

推送到 GitHub 后手动 Run `Flutter Build` workflow，三个产物：

- `TallyLive-windows-x64.zip`
- `TallyLive-android.apk`
- `TallyLive-ios-unsigned.ipa` — 未签名，用 **LiveContainer** 安装

### 本地

```bash
flutter create . --platforms=windows,android,ios --org com.tally --project-name tallylive
flutter pub get
flutter run -d windows          # 或 -d <android device>
```

## 已知限制

- iOS 未签名是刻意的：LiveContainer 会自行重签或绕过 codesign，不需要开发者账号。
- 目前只接了 B 站；其余三个平台待移植。
- 弹幕尚未接入。
