import 'package:flutter/foundation.dart';

/// 诊断功能总开关。
///
/// **规则：所有测试/诊断相关代码只在非 release 构建里存在。**
/// `kReleaseMode` 是编译期常量，所以 release 构建会把下面所有打点
/// 连同调试面板一起 tree-shake 掉，不产生任何运行时开销、也不出现在正式包里。
const bool kDiagnosticsEnabled = !kReleaseMode;

/// 弹幕管线计数器（**仅诊断用，release 构建自动剔除**）。
///
/// 目的：**在不依赖官方数据的前提下，自证弹幕有没有在某一环被丢弃**。
///
/// 数据流：
/// ```
/// 帧(frame) → 解压成功(decoded) → 命令(commands) → 聊天(chat)
///   → 入队(enqueued) → 队列丢弃(dropped) → 画到画布(rendered)
/// ```
/// 如果 `chat → enqueued → rendered` 数字守恒，说明客户端一条没丢，
/// 屏幕密度就是服务端给的全部；有断层就说明问题在那一环。
///
/// 用法：播放页长按标题栏展开调试面板（release 构建里长按无效）。
class DanmakuStats extends ChangeNotifier {
  DanmakuStats._();

  static final DanmakuStats instance = DanmakuStats._();

  int frames = 0;
  int framesDecoded = 0;
  int commands = 0;
  int chat = 0;
  int enqueued = 0;
  int droppedByQueue = 0;
  int rendered = 0;

  /// 按 cmd 分类计数，用来发现「我们没处理的命令类型」。
  final Map<String, int> byCommand = {};

  void reset() {
    if (!kDiagnosticsEnabled) return;
    frames = 0;
    framesDecoded = 0;
    commands = 0;
    chat = 0;
    enqueued = 0;
    droppedByQueue = 0;
    rendered = 0;
    byCommand.clear();
    notifyListeners();
  }

  void countFrame() {
    if (!kDiagnosticsEnabled) return;
    frames++;
  }

  void countDecodedFrame() {
    if (!kDiagnosticsEnabled) return;
    framesDecoded++;
  }

  void countRendered() {
    if (!kDiagnosticsEnabled) return;
    rendered++;
  }

  void countEnqueued() {
    if (!kDiagnosticsEnabled) return;
    enqueued++;
  }

  void countDropped() {
    if (!kDiagnosticsEnabled) return;
    droppedByQueue++;
  }

  void countCommand(String cmd) {
    if (!kDiagnosticsEnabled) return;
    commands++;
    // cmd 可能带后缀（DANMU_MSG:4:0:...），统计时截断便于归类
    final key = cmd.contains(':') ? cmd.substring(0, cmd.indexOf(':')) : cmd;
    byCommand[key] = (byCommand[key] ?? 0) + 1;
    notifyListeners();
  }

  void countChat() {
    if (!kDiagnosticsEnabled) return;
    chat++;
  }

  /// 一行摘要，便于显示在调试面板。
  String get summary {
    final top = byCommand.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final cmdText = top.take(4).map((e) => '${e.key}=${e.value}').join(' ');
    return '帧 $frames / 解压 $framesDecoded / 命令 $commands / 聊天 $chat\n'
        '入队 $enqueued（队列丢弃 $droppedByQueue）/ 已画 $rendered\n'
        'cmd: ${cmdText.isEmpty ? '—' : cmdText}';
  }
}
