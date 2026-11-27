# TallyLive · 在播

斗鱼 / 虎牙 / 抖音 / bilibili 直播聚合客户端。**Windows + iOS + Android**，一套 Flutter 代码。

> 从 Wails 版 [DTV](https://github.com/chen-zeong/DTV) 重建。原项目是 WebView + xgplayer，
> 在 iOS 上播不了 HTTP-FLV（WKWebView 无 MSE），且 WebView 无法把原生视频合成进 UI
> （弹幕会被原生窗口遮住），所以改用 Flutter + media_kit（libmpv），视频与弹幕走同一个合成器。

## 技术栈

| 层 | 选型 |
|---|---|
| UI | Flutter（Material 3，夜间「Tally / 导播台」配色） |
| 播放器 | `media_kit` + `media_kit_video`（底层 libmpv，三端官方支持） |
| 弹幕渲染 | `canvas_danmaku`（CustomPainter，与 Video 同 Stack） |
| 网络 | `dio` |
| 平台协议 | 自研 Dart 实现，从 Go 版移植 |

## 进度

| 平台 | 播放 | 弹幕 | 多线路 |
|---|---|---|---|
| bilibili | ✅ | ✅ | ✅ |
| 斗鱼 | ✅ | ✅ | ✅ |
| 虎牙 | ⬜ | ⬜ | — |
| 抖音 | ⬜ | ⬜ | — |

虎牙（TARS 编解码）与抖音（a_bogus 签名 + HEVC-FLV）尚未移植。

## 使用

首页选平台 → 输房间号 → 播放。播放页支持切换清晰度、线路、弹幕开关。

## 构建

平台脚手架由 CI 用 `flutter create .` 生成，本地不需要预置。

推送到 GitHub 后手动 Run **Flutter Build** workflow：

- 默认只构建 Windows（快）
- 勾选 `build_all` 同时构建 Android + iOS

产物：
- `TallyLive-windows` — 解压即运行
- `TallyLive-android.apk` — debug key 签名，可直接安装
- `TallyLive-ios-unsigned.ipa` — 未签名，用 **LiveContainer** 安装（不需要开发者账号）

本地构建：

```bash
flutter create . --platforms=windows,android,ios --org com.tally --project-name tallylive
flutter pub get
flutter run -d windows
```

## 测试

```bash
flutter test
```

覆盖协议层里最容易错的纯逻辑：B 站 playinfo 地址拼接、WBI 签名、
弹幕分包（含 zlib 嵌套）、斗鱼 STT 包编解码、线路回退。

## 声明

本项目仅供学习编程使用，未进行任何逆向工程；所有直播版权归各平台所有。
