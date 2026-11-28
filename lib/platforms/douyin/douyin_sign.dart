import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';

/// 抖音弹幕签名（X-MS-STUB → get_sign）。
///
/// **为什么必须用 JS 引擎**：抖音的弹幕签名由字节的爬虫风控 SDK
/// `byted_acrawler` 生成，官方只提供混淆后的 JS。经逐个核对：
///
/// | 项目 | 弹幕签名怎么处理 |
/// |---|---|
/// | DTV | goja 跑混淆 `sign.js`（12952 处 `_0x` 变量名） |
/// | Simple Live | dart_quickjs 跑混淆 `kWebMsSDK` |
/// | DouyinLiveWebFetcher | MiniRacer 跑同一份 `sign.js` |
/// | DouyinLiveRecorder | **不支持弹幕**（只有可读的 a_bogus，用于取流） |
///
/// 也就是说：**没有任何开源项目把弹幕签名逆成可读算法**，
/// 全部是"丢给 JS 引擎跑"。本项目因此引入 QuickJS（flutter_js）。
///
/// 脚本取自 **DTV 的 `assets/sign.js`**（480KB），
/// 已实测在只有 `document`/`window`/`navigator` 的纯浏览器环境下可执行
/// （脚本里的 `require` 在惰性分支里，正常路径不会触发）。
class DouyinSign {
  DouyinSign._();

  static JavascriptRuntime? _runtime;
  static bool _loaded = false;

  /// 初始化运行时并加载脚本（只做一次，约几百毫秒）。
  static Future<void> _ensureReady() async {
    if (_loaded && _runtime != null) return;

    final runtime = getJavascriptRuntime();
    // 提供脚本需要的浏览器环境 shim
    runtime.evaluate('''
      var document = {};
      var window = {};
      var navigator = {userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'};
    ''');

    final script = await rootBundle.loadString('assets/douyin_sign.js');
    final result = runtime.evaluate(script);
    if (result.isError) {
      throw DouyinSignException('加载抖音签名脚本失败: ${result.stringResult}');
    }
    _runtime = runtime;
    _loaded = true;
  }

  /// 用 md5 换签名。
  ///
  /// [md5Hex] 是 13 个参数按固定顺序拼串后的 MD5（见 DouyinDanmakuClient）。
  static Future<String> getSign(String md5Hex) async {
    await _ensureReady();
    final runtime = _runtime!;
    final result = runtime.evaluate("get_sign('$md5Hex')");
    if (result.isError) {
      throw DouyinSignException('抖音签名失败: ${result.stringResult}');
    }
    final signature = result.stringResult.trim();
    if (signature.isEmpty) {
      throw const DouyinSignException('抖音签名返回空');
    }
    return signature;
  }

  /// 释放运行时（退出播放时调用）。
  static void dispose() {
    _runtime?.dispose();
    _runtime = null;
    _loaded = false;
  }
}

class DouyinSignException implements Exception {
  const DouyinSignException(this.message);
  final String message;

  @override
  String toString() => message;
}
