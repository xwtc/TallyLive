import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';

/// 斗鱼弹幕客户端。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/douyu/danmaku.go。
///
/// ⚠️ 与 B 站最大的不同：斗鱼弹幕**不是 WebSocket，而是明文 TCP + 私有 STT 协议**。
/// 旧项目连的 `wss://danmuproxy.douyu.com:8506/` 已不再提供 TLS，
/// 8601/8602/8603 上是裸 TCP，报文仍是同一套 STT 包。
///
/// 包结构（小端）：
/// ```
/// u32 长度(=msgLen+9) | u32 长度 | u16 689 | 0x00 0x00 | 消息 | 0x00
/// ```
/// 注意长度字段**不含自身那 4 字节**，所以整包 = 长度 + 4。
/// 服务端会把多个包连续写在同一连接上，必须按长度字段切包，
/// 不能假设「一次 read 就是一个包」。
class DouyuDanmakuClient implements DanmakuClient {
  final StreamController<DanmakuMessage> _messages =
      StreamController<DanmakuMessage>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();
  final StreamController<String> _errors =
      StreamController<String>.broadcast();

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;

  /// TCP 是字节流，需要自己攒缓冲区切包。
  final List<int> _pending = [];

  bool _stopped = true;
  int _retry = 0;
  int _sequence = 0;
  String _roomId = '';

  static const List<String> _endpoints = [
    'danmuproxy.douyu.com',
  ];
  static const List<int> _ports = [8601, 8602, 8603];

  static const Duration _heartbeatInterval = Duration(seconds: 45);
  static const Duration _maxBackoff = Duration(seconds: 30);
  static const int _maxPacketSize = 1 << 16;

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> start(String roomId, {String? realRoomId}) async {
    if (roomId.isEmpty) return;
    await stop();
    _stopped = false;
    _roomId = roomId;
    _retry = 0;
    await _connect();
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _pending.clear();
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
      try {
        socket.destroy();
      } catch (_) {}
    }
    if (!_connected.isClosed) _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _messages.close();
    await _errors.close();
    await _connected.close();
  }

  Future<void> _connect() async {
    if (_stopped) return;

    Object? lastError;
    for (final port in _ports) {
      if (_stopped) return;
      for (final host in _endpoints) {
        try {
          final socket = await Socket.connect(
            host,
            port,
            timeout: const Duration(seconds: 10),
          );
          if (_stopped) {
            socket.destroy();
            return;
          }
          await _attach(socket);
          _retry = 0;
          return;
        } catch (error) {
          lastError = error;
          continue;
        }
      }
    }
    if (!_stopped) {
      _scheduleReconnect(lastError ?? const _DouyuDanmakuError('所有弹幕服务器均连接失败'));
    }
  }

  Future<void> _attach(Socket socket) async {
    _socket = socket;
    _pending.clear();

    // 关闭 Nagle：弹幕是小包高频，攒包会明显增加延迟。
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    _subscription = socket.listen(
      _onData,
      onError: (Object error) {
        if (!_stopped) _scheduleReconnect(error);
      },
      onDone: () {
        if (!_stopped) {
          _scheduleReconnect(const _DouyuDanmakuError('连接被关闭'));
        }
      },
      cancelOnError: true,
    );

    // 登录 + 加房间（顺序与 Go 版一致）
    _write('type@=loginreq/roomid@=$_roomId/');
    _write('type@=joingroup/rid@=$_roomId/gid@=1/');

    // 心跳：45 秒一次 mrkl
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _write('type@=mrkl/'));

    if (!_errors.isClosed) _errors.add('');
      if (!_connected.isClosed) _connected.add(true);
  }

  void _write(String message) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(encodeStt(message));
    } catch (_) {
      // 写失败说明连接已断，交给 listen 的 onError/onDone
    }
  }

  void _scheduleReconnect(Object error) {
    // 失败原因上报给界面，否则用户只看到「正在连接…」
    if (!_errors.isClosed) _errors.add(error.toString());
    if (_stopped) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _pending.clear();
    try {
      socket?.destroy();
    } catch (_) {}
    if (!_connected.isClosed) _connected.add(false);

    _retry = (_retry + 1).clamp(1, 10).toInt();
    final shift = (_retry - 1).clamp(0, 5).toInt();
    var delay = Duration(seconds: 1 << shift);
    if (delay > _maxBackoff) delay = _maxBackoff;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_stopped) _connect();
    });
  }

  /* ------------------------------ 收包 ------------------------------ */

  void _onData(Uint8List chunk) {
    _pending.addAll(chunk);

    while (true) {
      if (_pending.length < 4) return;
      final declared = _readUint32Le(_pending, 0);
      if (declared < 8 || declared > _maxPacketSize) {
        // 长度字段异常：连接已经不可信，直接重建
        _scheduleReconnect(
          _DouyuDanmakuError('弹幕包长度异常: $declared'),
        );
        return;
      }
      final total = 4 + declared;
      if (_pending.length < total) return;

      final packet = Uint8List.fromList(_pending.sublist(0, total));
      _pending.removeRange(0, total);
      DanmakuStats.instance.countFrame();
      try {
        _handlePacket(packet);
      } catch (_) {
        // 单包解析失败不能影响连接：斗鱼的 STT 字段会随活动/版本变化，
        // 一条坏消息不该让整条 TCP 被重建（那会表现为弹幕断流后重连）。
      }
    }
  }

  void _handlePacket(Uint8List packet) {
    // 跳过 12 字节头（4+4+2+2）、去掉尾部 \0
    if (packet.length < 14) return;
    final body = utf8.decode(
      packet.sublist(12, packet.length - 1),
      allowMalformed: true,
    );
    final fields = parseStt(body);
    final type = fields['type'] ?? '';
    if (type.isNotEmpty) DanmakuStats.instance.countCommand(type);

    switch (fields['type']) {
      case 'chatmsg':
        final content = (fields['txt'] ?? '').trim();
        if (content.isEmpty) return;
        _emit(DanmakuMessage(
          id: _nextId(),
          content: content,
          at: DateTime.now().millisecondsSinceEpoch,
          nickname: (fields['nn'] ?? '').trim().isEmpty
              ? '未知用户'
              : fields['nn']!.trim(),
          level: int.tryParse((fields['level'] ?? '').trim()) ?? 0,
          color: colorFromDouyuCol(fields['col']),
          kind: DanmakuKind.chat,
        ));
        DanmakuStats.instance.countChat();
        break;
      case 'uenter':
        final name = (fields['nn'] ?? '').trim();
        if (name.isEmpty) return;
        _emit(DanmakuMessage(
          id: _nextId(),
          content: (fields['str'] ?? '进入直播间').trim(),
          at: DateTime.now().millisecondsSinceEpoch,
          nickname: name,
          level: int.tryParse((fields['level'] ?? '').trim()) ?? 0,
          kind: DanmakuKind.enter,
        ));
        break;
      case 'pingreq':
        // 服务端心跳请求：必须回 mrkl，否则会被断开
        _write('type@=mrkl/');
        break;
      default:
        break;
    }
  }

  void _emit(DanmakuMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  String _nextId() =>
      '$_roomId:${DateTime.now().microsecondsSinceEpoch}:${_sequence++}';
}

/* ------------------------------ STT 编解码 ------------------------------ */

/// 把一条指令编码成斗鱼 STT 包（小端）。
///
/// `u32 长度(=msgLen+9) | u32 长度 | u16 689 | 0x00 0x00 | 消息 | 0x00`
Uint8List encodeStt(String message) {
  final messageBytes = utf8.encode(message);
  final declared = messageBytes.length + 9;

  final buffer = Uint8List(4 + declared);
  final view = ByteData.view(buffer.buffer);
  view.setUint32(0, declared, Endian.little);
  view.setUint32(4, declared, Endian.little);
  view.setUint16(8, 689, Endian.little);
  buffer[10] = 0;
  buffer[11] = 0;
  buffer.setRange(12, 12 + messageBytes.length, messageBytes);
  buffer[buffer.length - 1] = 0;
  return buffer;
}

/// 解析 `k1@=v1/k2@=v2/` 形式的消息体。
///
/// 值里的 `@S` 代表 `/`、`@A` 代表 `@`（斗鱼自定义转义）。
Map<String, String> parseStt(String content) {
  final result = <String, String>{};
  for (final item in content.split('/')) {
    if (item.isEmpty) continue;
    final index = item.indexOf('@=');
    if (index < 0) continue;
    final key = item.substring(0, index);
    var value = item.substring(index + 2);
    value = value.replaceAll('@S', '/').replaceAll('@A', '@');
    result[key] = value;
  }
  return result;
}

/// 斗鱼 `col` 字段 → `#RRGGBB`。
///
/// col 是**调色板索引**（官方协议：0 表示默认色）。
/// 空/0/未知一律返回空串，让渲染层用默认颜色；
/// 绝不能返回黑色（社区常见实现踩过这个坑）。
String colorFromDouyuCol(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return '';
  final value = int.tryParse(text);
  if (value == null || value <= 0) return '';
  final mapped = _douyuColColors[value];
  if (mapped != null) return mapped;
  // 兜底：万一上游改回十进制 RGB 语义
  if (value >= 0x10000 && value <= 0xFFFFFF) {
    return '#${value.toRadixString(16).toUpperCase().padLeft(6, '0')}';
  }
  return '';
}

const Map<int, String> _douyuColColors = {
  1: '#FF2E2E',
  2: '#00CCFF',
  3: '#66FF00',
  4: '#FF6600',
  5: '#CC00FF',
  6: '#F6447F',
  7: '#FF84F6',
};

int _readUint32Le(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

class _DouyuDanmakuError implements Exception {
  const _DouyuDanmakuError(this.message);
  final String message;

  @override
  String toString() => message;
}
