import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/platforms/huya/huya_client.dart';
import 'package:tallylive/platforms/huya/huya_tars.dart';

/// 虎牙弹幕客户端。
///
/// **1:1 移植自 DTV `internal/platforms/huya/danmaku.go`**：
///
/// ```
/// 连接    wss://cdnws.api.huya.com
/// 心跳    20s，发固定字节（TARS 编码的 OnUserHeartBeat，DTV 注明"原样保留"）
/// 进房    wscmd{ int32(tag0)=16, bytes(tag1)=oos }
///         oos{ stringList(tag0)=["live:<uid>","chat:<uid>"], string(tag1)="" }
/// 收包    外层 int32(tag0)=7 + bytes(tag1)
///           → 内层 int32(tag1)=1400 + bytes(tag2)   （1400 才是聊天）
///             → 载荷 struct(tag0)=HuyaUser{uid@0, imid@1, nick@2, gender@3}
///                      + string(tag3)=正文 + struct(tag6)=BulletFormat{color@0}
/// ```
class HuyaDanmakuClient implements DanmakuClient {
  HuyaDanmakuClient({HuyaClient? client}) : _client = client ?? HuyaClient();

  final HuyaClient _client;

  final StreamController<DanmakuMessage> _messages =
      StreamController<DanmakuMessage>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();
  final StreamController<String> _errors =
      StreamController<String>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  Timer? _watchdog;

  bool _stopped = true;
  int _retry = 0;
  int _sequence = 0;
  String _roomId = '';

  /// 订阅用的频道 ID（虎牙的 uid/yyid，进房 topic 要用）。
  int _ayyuid = 0;

  static const String _wsUrl = 'wss://cdnws.api.huya.com';
  static const Duration _heartbeatInterval = Duration(seconds: 20);
  static const Duration _readTimeout = Duration(seconds: 90);

  /// 心跳包字节（对齐 DTV 的 danmakuHeartbeatBytes）。
  ///
  /// DTV 注释：包体是 TARS 编码的 onlineui.OnUserHeartBeat 请求，
  /// 自己拼很容易错，因此从抓包原样保留。
  static const List<int> _heartbeatBytes = [
    0x00, 0x03, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ];

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
    await _errors.close();
    await _connected.close();
  }

  Future<void> _connect() async {
    if (_stopped) return;
    try {
      final info = await _client.fetchHuyaJoinInfo(_roomId);
      _ayyuid = info.ayyuid != 0 ? info.ayyuid : info.topSid;
      if (_ayyuid == 0) {
        throw const HuyaDanmakuException('没有拿到订阅用的 uid');
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
      if (!_errors.isClosed) _errors.add('');
      if (!_connected.isClosed) _connected.add(true);
      _retry = 0;
    } catch (error) {
      if (_stopped) return;
      _scheduleReconnect(error);
    }
  }

  /// 组装进房包（对齐 DTV `buildRegPayload`）。
  ///
  /// ⚠️ 不是 Simple Live 那种 `{ayyuid, true, "", "", topSid, ...}` 结构：
  /// 现在的虎牙进房是「订阅 topic」，两个 topic 名固定为 `live:<uid>` 与
  /// `chat:<uid>`，命令号固定 16。按旧结构发，连接会成功但**收不到任何弹幕**。
  Uint8List _buildRegPayload() {
    final topics = <String>['live:$_ayyuid', 'chat:$_ayyuid'];

    final oos = TarsWriter();
    oos.writeStringList(0, topics);
    oos.writeString(1, '');

    final wscmd = TarsWriter();
    wscmd.writeInt32(0, 16);
    wscmd.writeBytes(1, oos.toBytes());
    return wscmd.toBytes();
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_readTimeout, () {
      if (_stopped) return;
      _scheduleReconnect('读超时，连接可能已死');
    });
  }

  void _scheduleReconnect(Object error) {
    // 失败原因上报给界面，否则用户只看到「正在连接…」
    if (!_errors.isClosed) _errors.add(error.toString());
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
      // 单帧失败不能影响连接
    }
  }

  /// 外层 int32(tag0)=7 + bytes(tag1) → 内层 int32(tag1) + bytes(tag2)。
  void _processFrame(Uint8List data) {
    final outer = TarsReader(data);
    final outerType = outer.readInt32Tag(0, -1);
    if (outerType != 7) return;
    final innerBytes = outer.readBytesTag(1);
    if (innerBytes == null || innerBytes.isEmpty) return;
    DanmakuStats.instance.countDecodedFrame();

    final inner = TarsReader(innerBytes);
    final nested = inner.readInt32Tag(1, -1);
    final payloadBytes = inner.readBytesTag(2);
    if (payloadBytes == null || payloadBytes.isEmpty) return;

    if (nested != 1400) {
      // 非聊天（礼物/进场/人气），忽略
      return;
    }
    DanmakuStats.instance.countCommand('HYMessage:1400');
    _handleChat(payloadBytes);
  }

  /// 载荷：struct(tag0)=HuyaUser + string(tag3)=正文 + struct(tag6)=BulletFormat。
  ///
  /// ⚠️ DTV 注释里记了一个必须照做的陷阱：
  /// 进 struct(0) 后要把 tag0/1/3 都读掉（即使不用），
  /// 否则内层 struct 的 tag3 会"抢走"后面正文的 tag3，导致正文永远为空。
  void _handleChat(Uint8List data) {
    final payload = TarsReader(data);

    var nickname = '';
    if (payload.readStructBegin(0)) {
      payload.readInt64Tag(0, -1);
      payload.readInt64Tag(1, -1);
      nickname = payload.readStringTag(2, '');
      payload.readInt32Tag(3, -1); // 关键：读掉，防止抢走正文 tag3
    }

    final text = payload.readStringTag(3, '');
    if (text.trim().isEmpty) return;

    var color = '';
    if (payload.readStructBegin(6)) {
      final fontColor = payload.readInt32Tag(0, 16777215);
      if (fontColor > 0) {
        color = '#${fontColor.toRadixString(16).padLeft(6, '0')}';
      }
    }

    _emit(DanmakuMessage(
      id: '${_roomId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      content: text,
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: nickname,
      color: color,
      kind: DanmakuKind.chat,
    ));
    DanmakuStats.instance.countChat();
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
