import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/platforms/douyin/douyin_client.dart';
import 'package:tallylive/platforms/douyin/douyin_protobuf.dart';
import 'package:tallylive/platforms/douyin/douyin_sign.dart';

/// 抖音弹幕客户端。
///
/// **移植自 DTV `internal/platforms/douyin/danmaku.go`**，
/// 并用 `_refs/DouyinLiveWebFetcher/liveMan.py` 核对 WS 参数
/// （已用 node 实测：signature 有效，能连上并持续收到帧）。
///
/// 链路：
/// ```
/// 1. GET https://live.douyin.com/  拿 ttwid cookie（缺它会 200 而不是 101）
/// 2. 拼长 query（app_name/version_code/…/room_id），
///    取 13 个参数的值拼串取 MD5 → sign.js 的 get_sign(md5) → signature
/// 3. wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/?…&signature=
/// 4. 收帧：PushFrame → gzip 解压 payload → Response
///    若 need_ack，回 PushFrame{logId, payloadType:'ack', payload: internalExt}
///    遍历 messagesList：method == 'WebcastChatMessage' 是聊天
/// 5. 心跳 10s：PushFrame{payloadType:'hb'}
/// ```
class DouyinDanmakuClient implements DanmakuClient {
  DouyinDanmakuClient({DouyinClient? client}) : _client = client ?? DouyinClient();

  final DouyinClient _client;

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
  String _ttwid = '';

  static const String _host = 'webcast100-ws-web-lq.douyin.com';
  static const Duration _heartbeatInterval = Duration(seconds: 10);
  static const Duration _readTimeout = Duration(seconds: 60);
  static const String _defaultUid = '7319483754668557238';

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
      // 内部 roomId（弹幕要用它，不是 web_rid）
      final internalId = await _client.fetchInternalRoomId(_roomId);
      if (_stopped) return;
      // ttwid：缺它会握手返回 200 而不是 101
      _ttwid = await _client.fetchTtwid();
      if (_stopped) return;

      final url = await _buildWssUrl(internalId);
      final socket = await WebSocket.connect(
        url,
        headers: {
          'user-agent': DouyinClient.desktopUserAgent,
          if (_ttwid.isNotEmpty) 'cookie': _ttwid,
        },
      ).timeout(const Duration(seconds: 15));

      if (_stopped) {
        await socket.close();
        return;
      }
      _socket = socket;

      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
        try {
          socket.add(_encodeHeartbeat());
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

  /// 拼 WS URL。
  ///
  /// signature 的算法：把 13 个参数按固定顺序拼成 `k=v,k=v…`，
  /// 取 MD5 后交给 sign.js 的 get_sign()（对齐参考实现 generateSignature）。
  Future<String> _buildWssUrl(String internalRoomId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final uid = _defaultUid;
    final params = <String>[
      'app_name=douyin_web',
      'version_code=180800',
      'webcast_sdk_version=1.0.14-beta.0',
      'update_version_code=1.0.14-beta.0',
      'compress=gzip',
      'device_platform=web',
      'cookie_enabled=true',
      'screen_width=1536',
      'screen_height=864',
      'browser_language=zh-CN',
      'browser_platform=Win32',
      'browser_name=Mozilla',
      'browser_online=true',
      'tz_name=Asia/Shanghai',
      'cursor=d-1_u-1_fh-1_t-${now}_r-1',
      'internal_ext=internal_src:dim|wss_push_room_id:$internalRoomId'
          '|wss_push_did:$uid|first_req_ms:$now|fetch_time:$now'
          '|seq:1|wss_info:0-$now-0-0|wrds_v:1',
      'host=https://live.douyin.com',
      'aid=6383',
      'live_id=1',
      'did_rule=3',
      'endpoint=live_pc',
      'support_wrds=1',
      'user_unique_id=$uid',
      'im_path=/webcast/im/fetch/',
      'identity=audience',
      'need_persist_msg_count=15',
      'insert_task_id=',
      'live_reason=',
      'room_id=$internalRoomId',
      'heartbeatDuration=0',
    ];
    final query = params.join('&');

    // 取 13 个参数的值拼串 → MD5 → sign
    final values = <String, String>{};
    for (final kv in params) {
      final index = kv.indexOf('=');
      values[kv.substring(0, index)] = kv.substring(index + 1);
    }
    const signKeys = [
      'live_id', 'aid', 'version_code', 'webcast_sdk_version',
      'room_id', 'sub_room_id', 'sub_channel_id', 'did_rule',
      'user_unique_id', 'device_platform', 'device_type', 'ac',
      'identity',
    ];
    final plain = signKeys.map((key) => '$key=${values[key] ?? ''}').join(',');
    final md5Hex = md5.convert(utf8.encode(plain)).toString();
    final signature = await DouyinSign.getSign(md5Hex);

    return 'wss://$_host/webcast/im/push/v2/?$query'
        '&signature=${Uri.encodeComponent(signature)}';
  }

  /// 心跳：PushFrame{ payloadType: 'hb' }（字段 7 是 string）。
  Uint8List _encodeHeartbeat() {
    final writer = ProtoWriter();
    writer.writeStringField(7, 'hb');
    return writer.toBytes();
  }

  /// 收到一帧。
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
      // 单帧失败不影响连接
    }
  }

  /// PushFrame → gzip 解压 payload → Response。
  void _processFrame(Uint8List data) {
    var logId = 0;
    Uint8List payload = Uint8List(0);

    final frame = ProtoReader(data);
    frame.forEachField((field, wire) {
      switch (field) {
        case 2: // logId
          logId = frame.readVarint();
          return true;
        case 8: // payload
          payload = frame.readBytes();
          return true;
        default:
          return false;
      }
    });
    if (payload.isEmpty) return;

    Uint8List plain;
    try {
      plain = Uint8List.fromList(gzip.decode(payload));
    } catch (_) {
      // 有的帧不带 gzip（比如 ack 回执）
      plain = payload;
    }
    DanmakuStats.instance.countDecodedFrame();

    var needAck = false;
    var internalExt = '';
    final messagePayloads = <Uint8List>[];

    final response = ProtoReader(plain);
    response.forEachField((field, wire) {
      switch (field) {
        case 1: // messagesList
          messagePayloads.add(response.readBytes());
          return true;
        case 5: // internalExt
          internalExt = response.readString();
          return true;
        case 9: // needAck
          needAck = response.readVarint() != 0;
          return true;
        default:
          return false;
      }
    });

    if (needAck && _socket != null) {
      try {
        _socket!.add(_encodeAck(logId, internalExt));
      } catch (_) {}
    }

    for (final messageBytes in messagePayloads) {
      _handleMessage(messageBytes);
    }
  }

  /// ack：PushFrame{ logId, payloadType:'ack', payload: internalExt }
  Uint8List _encodeAck(int logId, String internalExt) {
    final writer = ProtoWriter();
    writer.writeVarintField(2, logId);
    writer.writeStringField(7, 'ack');
    writer.writeBytesField(8, utf8.encode(internalExt));
    return writer.toBytes();
  }

  /// Message{ method@1, payload@2 }
  void _handleMessage(Uint8List data) {
    var method = '';
    var payload = Uint8List(0);
    final reader = ProtoReader(data);
    reader.forEachField((field, wire) {
      switch (field) {
        case 1:
          method = reader.readString();
          return true;
        case 2:
          payload = reader.readBytes();
          return true;
        default:
          return false;
      }
    });
    if (method.isEmpty || payload.isEmpty) return;
    DanmakuStats.instance.countCommand(method);

    if (method == 'WebcastChatMessage') {
      _handleChat(payload);
    }
  }

  /// ChatMessage{ user@2, content@3 }
  /// User{ nickName@3 }
  void _handleChat(Uint8List data) {
    var content = '';
    var nickname = '';
    final reader = ProtoReader(data);
    reader.forEachField((field, wire) {
      switch (field) {
        case 2: // user
          final userBytes = reader.readBytes();
          final user = ProtoReader(userBytes);
          user.forEachField((f, w) {
            if (f == 3) {
              nickname = user.readString();
              return true;
            }
            return false;
          });
          return true;
        case 3: // content
          content = reader.readString();
          return true;
        default:
          return false;
      }
    });
    if (content.trim().isEmpty) return;

    _emit(DanmakuMessage(
      id: '${_roomId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      content: content,
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: nickname,
      kind: DanmakuKind.chat,
    ));
    DanmakuStats.instance.countChat();
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

  void _emit(DanmakuMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }
}
