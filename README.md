# TallyLive · 在播

斗鱼 / 虎牙 / 抖音 / bilibili 直播聚合客户端。**Windows + iOS + Android**，一套 Flutter 代码。

> 从 Wails 版 [DTV](https://github.com/chen-zeong/DTV) 重建。原项目是 WebView + xgplayer，
> 在 iOS 上播不了 HTTP-FLV（WKWebView 无 MSE），且 WebView 无法把原生视频合成进 UI
> （弹幕会被原生窗口遮住），所以改用 Flutter + media_kit（libmpv），视频与弹幕走同一个合成器。
>
> **本项目的实现一律以 DTV 的 Go 源码为移植来源**，未搬用其他项目的代码。

## 技术栈

| 层 | 选型 |
|---|---|
| UI | Flutter（Material 3，夜间「Tally / 导播台」配色） |
| 播放器 | `media_kit` + `media_kit_video`（底层 libmpv，三端官方支持） |
| 弹幕渲染 | `canvas_danmaku`（CustomPainter，与 Video 同 Stack） |
| 网络 | `dio` |
| 桌面全屏 | `window_manager` |
| JS 引擎 | `flutter_js`（QuickJS，仅抖音弹幕签名用） |
| 平台协议 | 自研 Dart 实现，从 Go 版移植 |

## 进度

| 平台 | 分区/列表 | 播放 | 弹幕 | 多线路 |
|---|---|---|---|---|
| bilibili | ✅ | ✅ | ✅ | ✅ |
| 斗鱼 | ✅ | ✅ | ✅ | ✅ |
| 虎牙 | ✅ | ✅ | ✅ | ✅ |
| 抖音 | ✅ | ✅ | ✅ | — |

四个平台的播放与弹幕均已接通。

抖音弹幕的签名（X-MS-STUB）由字节的爬虫风控 SDK 生成，官方只提供混淆 JS，
所有已知开源实现（DTV 用 goja、Simple Live 用 dart_quickjs）都是「丢给 JS 引擎跑」，
因此本项目也引入 QuickJS（`flutter_js`）执行 DTV 的 `assets/douyin_sign.js`。

## 使用

顶栏切平台 → 选分区 → 点卡片进播放。播放时左侧关注栏仍可用，可以直接换台。

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

覆盖协议层里最容易错的纯逻辑：
- B 站：playinfo 地址拼接、WBI 签名、弹幕分包（含 zlib/brotli 嵌套与失步重同步）
- 斗鱼：STT 包编解码、MD5 签名链、线路回退
- 虎牙：TARS 编解码（整数压缩、扩展 tag、结构体、字节数组）
- 抖音：a_bogus（SM3 / RC4 / 5 张自定义 base64 表 / 末组填充规则）、protobuf 编解码

## 协议溯源

各平台的协议细节参考了以下项目（仅用于**核对协议事实**，未搬运代码）：

| 用途 | 项目 | 活跃度 |
|---|---|---|
| 移植来源 | [chen-zeong/DTV](https://github.com/chen-zeong/DTV) | 活跃 |
| 交叉参考 | [xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live) | 活跃 |
| B 站弹幕 | [xfgryujk/blivedm](https://github.com/xfgryujk/blivedm) | 活跃 |
| 抖音弹幕 | [saermart/DouyinLiveWebFetcher](https://github.com/saermart/DouyinLiveWebFetcher) | 活跃 |
| 抖音签名（算法不可读） | [ihmily/DouyinLiveRecorder](https://github.com/ihmily/DouyinLiveRecorder) | 活跃（仅取流） |
| 虎牙 | [liuchuancong/pure_live](https://github.com/liuchuancong/pure_live) | 活跃 |

## 声明

本项目仅供学习编程使用，未进行任何逆向工程；所有直播版权归各平台所有。
