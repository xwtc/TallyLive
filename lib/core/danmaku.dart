/// 弹幕消息模型与跨平台抽象。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/common/types.go 里 DanmakuMessage 的形状，
/// 但 Dart 侧直接用对象传递，不再需要 JSON 序列化（同进程内）。
library;

/// 弹幕类型。只显示聊天弹幕，礼物/进场保留字段但 UI 默认不过滤展示。
enum DanmakuKind {
  chat,
  gift,
  enter,
  other,
}

/// 一条弹幕。
class DanmakuMessage {
  DanmakuMessage({
    required this.id,
    required this.content,
    required this.at,
    this.nickname = '',
    this.color = '',
    this.level = 0,
    this.kind = DanmakuKind.chat,
  });

  /// 全局唯一 id（平台+房间+时间+序号）。
  final String id;

  /// 弹幕正文。
  final String content;

  /// 毫秒时间戳。
  final int at;

  final String nickname;

  /// `#RRGGBB` 形式的颜色；空串表示用默认色。
  final String color;

  /// 用户等级（部分平台没有）。
  final int level;

  final DanmakuKind kind;

  @override
  String toString() => '$nickname: $content';
}

/// 弹幕来源平台的通用接口。
///
/// 实现方负责：建立连接、断线重连、把原始协议转成 [DanmakuMessage]。
/// UI 只订阅 [messages] 拿数据，不关心平台差异。
abstract class DanmakuClient {
  /// 弹幕流（广播，可多处订阅）。
  Stream<DanmakuMessage> get messages;

  /// 连接状态流：true=已连接并在收弹幕。
  Stream<bool> get connected;

  /// 开始监听某房间。重复调用会先停掉上一个连接。
  /// 启动弹幕。
  ///
  /// [realRoomId] 是播放页已经取到的**真实房间号**（B 站的短号需要换真实号）。
  /// 传了就能省掉一次 room get_info 请求 —— 这是首帧弹幕慢的主要来源。
  Future<void> start(String roomId, {String? realRoomId});

  /// 停止监听并关闭连接。
  Future<void> stop();

  /// 释放资源。
  Future<void> dispose();
}
