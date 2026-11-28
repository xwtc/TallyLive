import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/huya/huya_client.dart';
import 'package:tallylive/platforms/huya/huya_tars.dart';

/// 虎牙弹幕客户端。
///
/// **移植自 DTV `internal/platforms/huya/danmaku.go`**：
/// - 连接 `wss://cdnws.api.huya.com`
/// - 心跳：DTV 注释写明「包体是 TARS 编码的 OnUserHeartBeat，自己拼容易错，
///   因此原样保留」，这里同样用那串固定字节
/// - 进房包：TARS 嵌套（ayyuid / topSid / subSid 来自房间信息）
/// - 收包：外层 type==7 时取 body → HYPushMessage，uri==1400 是聊天
class HuyaDanmakuClient implements DanmakuClient {
  HuyaDanmakuClient({HuyaClient? client}) : _client = client ?? HuyaClient();

  final HuyaClient _client;

  final StreamController<DanmakuMessage> _messages =
      StreamController<DanmakuMessage>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Timer? _watchdog;

  bool _stopped = true;
  int _retry = 0;
  int _sequence = 0;
  String _roomId = '';

  /// 进房参数（从房间信息里取）。
  int _ayyuid = 0;
  int _topSid = 0;
  int _subSid = 0;

  static const String _wsUrl = 'wss://cdnws.api.huya.com';
  static const Duration _heartbeatInterval = Duration(seconds: 20);
  static const Duration _readTimeout = Duration(seconds: 90);

  /// 心跳包字节（对齐 DTV 的 danmakuHeartbeatBytes，原样保留）。
  ///
  /// 注释里明确写过：包体是 TARS 编码的 onlineui.OnUserHeartBeat 请求，
  /// 自己拼很容易错，所以直接照抄抓包得到的固定字节。
  static const List<int> _heartbeatBytes = [
    0x00, 0x03, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  Future<void> start(String roomId, {String? realRoomId}) async {
    if (roomId.isEmpty) return;
    await stop();
    _stopped = false;
    _roomId = (realRoomId ?? roomId).trim();
    _retry = 0;
    unawaited(_connect());
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.cancel();
    _watchdog = null;
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
    if (!_connected.isClosed) _connected.add(false);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _messages.close();
    await _connected.close();
  }

  Future<void> _connect() async {
    if (_stopped) return;
    try {
      // 进房需要 ayyuid / topSid / subSid，只能从房间信息接口拿。
      final info = await _client.fetchHuyaJoinInfo(_roomId);
      _ayyuid = info.ayyuid;
      _topSid = info.topSid;
      _subSid = info.subSid;
      if (_topSid == 0) {
        throw const HuyaDanmakuException('没有拿到 topSid，无法进房');
      }
      if (_stopped) return;

      final socket = await WebSocket.connect(_wsUrl).timeout(
        const Duration(seconds: 12),
      );
      if (_stopped) {
        await socket.close();
        return;
      }
      _socket = socket;

      // 进房包
      socket.add(_buildRegPayload());

      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
        try {
          socket.add(Uint8List.fromList(_heartbeatBytes));
        } catch (_) {}
      });

      _subscription = socket.listen(
        _handleFrame,
        onError: (Object error) {
          if (!_stopped) _scheduleReconnect(error);
        },
        onDone: () {
          if (!_stopped) _scheduleReconnect('连接被关闭');
        },
        cancelOnError: true,
      );

      _resetWatchdog();
      if (!_connected.isClosed) _connected.add(true);
      _retry = 0;
    } catch (error) {
      if (_stopped) return;
      _scheduleReconnect(error);
    }
  }

  /// 组装进房包（对齐 DTV `buildRegPayload`）。
  ///
  /// 外层：int 1 固定 + 内层字节数组；内层依次是
  /// ayyuid / true / "" / "" / topSid / subSid / 0 / 0。
  Uint8List _buildRegPayload() {
    final inner = TarsWriter();
    inner.writeInt64(0, _ayyuid);
    inner.writeInt8(1, 1); // true
    inner.writeString(2, '');
    inner.writeString(3, '');
    inner.writeInt64(4, _topSid);
    inner.writeInt64(5, _subSid);
    inner.writeInt64(6, 0);
    inner.writeInt64(7, 0);

    final outer = TarsWriter();
    outer.writeInt32(0, 1);
    outer.writeBytes(1, inner.toBytes());
    return outer.toBytes();
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_readTimeout, () {
      if (_stopped) return;
      _scheduleReconnect('读超时，连接可能已死');
    });
  }

  void _scheduleReconnect(Object error) {
    if (_stopped) return;
    if (!_connected.isClosed) _connected.add(false);
    final socket = _socket;
    _socket = null;
    socket?.close().catchError((_) => null);
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.cancel();
    _watchdog = null;

    _retry = _retry >= 6 ? 6 : _retry + 1;
    final seconds = (1 << (_retry - 1)).clamp(1, 30);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      if (!_stopped) _connect();
    });
  }

  void _handleFrame(dynamic data) {
    _resetWatchdog();
    Uint8List? bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    }
    if (bytes == null || bytes.isEmpty) return;
    DanmakuStats.instance.countFrame();
    try {
      _processFrame(bytes);
    } catch (_) {
      // 单帧解析失败不能影响连接
    }
  }

  void _processFrame(Uint8List data) {
    final reader = TarsReader(data);
    // 外层 type：DTV 里读 tag0，期望 7
    final type = reader.takeHead();
    if (type.type != TarsTypes.int8 && type.type != TarsTypes.int32 &&
        type.type != TarsTypes.zero) {
      return;
    }
    final body = reader.readBytesTag(1);
    if (body == null || body.isEmpty) return;
    DanmakuStats.instance.countDecodedFrame();

    final push = TarsReader(body);
    final head = push.takeHead();
    if (head.type != TarsTypes.structBegin) {
      // 也可能是扁平结构：直接按 tag 读
    }
    final uri = push.readInt32Tag(1, -1);
    final msg = push.readBytesTag(2);

    if (uri == 1400 && msg != null && msg.isNotEmpty) {
      DanmakuStats.instance.countCommand('HYMessage');
      _handleChat(msg);
    } else if (uri == 8006) {
      // 人气值，当前不展示
    }
  }

  /// 解析 HYMessage：userInfo(0).nickName(2)、content(3)、bulletFormat(6).fontColor(0)
  void _handleChat(Uint8List data) {
    final reader = TarsReader(data);
    final head = reader.takeHead();
    if (head.type != TarsTypes.structBegin) return;

    // userInfo 是嵌套结构体（tag 0）
    var nickname = '';
    final userBytes = _readStructBytes(reader, 0);
    if (userBytes != null) {
      final userReader = TarsReader(userBytes);
      final userHead = userReader.takeHead();
      if (userHead.type == TarsTypes.structBegin) {
        nickname = userReader.readStringTag(2, '');
      }
    }

    final content = reader.readStringTag(3, '');
    if (content.trim().isEmpty) return;

    var color = '';
    final formatBytes = _readStructBytes(reader, 6);
    if (formatBytes != null) {
      final formatReader = TarsReader(formatBytes);
      final formatHead = formatReader.takeHead();
      if (formatHead.type == TarsTypes.structBegin) {
        final fontColor = formatReader.readInt32Tag(0, 0);
        if (fontColor > 0) {
          color = '#${fontColor.toRadixString(16).padLeft(6, '0')}';
        }
      }
    }

    _emit(DanmakuMessage(
      id: '${_roomId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      content: content,
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: nickname,
      color: color,
      kind: DanmakuKind.chat,
    ));
    DanmakuStats.instance.countChat();
  }

  /// 读一个嵌套结构体的原始字节（用于再解析）。找不到返回 null。
  Uint8List? _readStructBytes(TarsReader reader, int tag) {
    final head = reader.find(tag);
    if (head == null || head.type != TarsTypes.structBegin) return null;
    final start = reader.pos;
    // 跳到该结构体的结束
    var depth = 1;
    while (reader.pos < reader.length && depth > 0) {
      final inner = reader.takeHead();
      if (inner.type == TarsTypes.structBegin) depth++;
      if (inner.type == TarsTypes.structEnd) depth--;
      if (depth > 0 && inner.type != TarsTypes.structBegin &&
          inner.type != TarsTypes.structEnd) {
        reader.skipField(inner.type);
      }
    }
    return Uint8List.sublistView(reader.buf, start, reader.pos - 1);
  }

  void _emit(DanmakuMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }
}

class HuyaDanmakuException implements Exception {
  const HuyaDanmakuException(this.message);
  final String message;

  @override
  String toString() => message;
}
