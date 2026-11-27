import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
import 'package:tallylive/platforms/bilibili/bilibili_wbi.dart';

/// B 站弹幕客户端。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/bilibili/danmaku.go。
///
/// 协议要点：
///   - `getDanmuInfo`（WBI 签名）拿 token 与弹幕服务器域名列表；
///   - 连 `wss://<host>/sub`，发一条 auth 包（op=7），之后每 30 秒心跳（op=2）；
///   - 服务端下发的帧是 16 字节头 + body，`ver=2` 表示 body 是 **zlib 压缩的再次分包**，
///     解压后还要按同样的 16 字节头继续拆 —— 不能当成拼接的 JSON；
///   - 业务消息在 op=5 的帧里，JSON 形如 {"cmd":"DANMU_MSG","info":[...]}。
class BilibiliDanmakuClient implements DanmakuClient {
  BilibiliDanmakuClient({BilibiliClient? client})
      : _client = client ?? BilibiliClient();

  final BilibiliClient _client;

  final StreamController<DanmakuMessage> _messages =
      StreamController<DanmakuMessage>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  bool _stopped = true;
  int _sequence = 0;
  String _roomId = '';
  int _retry = 0;

  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _maxBackoff = Duration(seconds: 30);

  /// op 码。
  static const int _opHeartbeat = 2;
  static const int _opHeartbeatReply = 3;
  static const int _opNotification = 5;
  static const int _opAuth = 7;
  static const int _opAuthReply = 8;

  /// protover=2：接受 zlib 压缩帧。官方前端已用 3（brotli），但 2 仍有效，
  /// 且 zlib 是 Dart SDK 自带，不需要额外依赖。
  static const int _protover = 2;

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  Future<void> start(String roomId) async {
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
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {
        // 关闭失败无所谓
      }
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
      // 1. 拿真实房间号 + 弹幕服务器信息
      final room = await _client.fetchRoomInfo(_roomId);
      final serverInfo = await _client.fetchDanmuInfo(room.roomId);
      if (serverInfo.token.isEmpty || serverInfo.hosts.isEmpty) {
        throw const _DanmakuConnectError('没有可用的弹幕服务器');
      }
      if (_stopped) return;

      // 2. 依次尝试各域名
      Object? lastError;
      for (final host in serverInfo.hosts) {
        if (_stopped) return;
        try {
          await _openSocket(host, room.roomId, serverInfo.token);
          // 连上就先算成功，剩余错误交给 readLoop 之后的退避
          _retry = 0;
          return;
        } catch (error) {
          lastError = error;
          continue;
        }
      }
      throw _DanmakuConnectError('所有弹幕服务器均连接失败：$lastError');
    } catch (error) {
      // 连接失败：按指数退避重试，避免频繁打上游
      if (_stopped) return;
      _scheduleReconnect(error);
    }
  }

  Future<void> _openSocket(String host, String realRoomId, String token) async {
    final socket = await WebSocket.connect(
      'wss://$host/sub',
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Origin': 'https://live.bilibili.com',
        'Referer': 'https://live.bilibili.com/',
      },
    ).timeout(const Duration(seconds: 12));

    if (_stopped) {
      await socket.close();
      return;
    }
    _socket = socket;

    // 发 auth
    final auth = jsonEncode({
      'uid': 0,
      'roomid': int.tryParse(realRoomId) ?? 0,
      'protover': _protover,
      'platform': 'web',
      'type': 2,
      'key': token,
    });
    socket.add(encodePacket(_opAuth, utf8.encode(auth)));

    // 心跳
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      try {
        socket.add(encodePacket(_opHeartbeat, utf8.encode('{}')));
      } catch (_) {
        // 写失败说明连接已断，交给 readLoop 的错误处理
      }
    });

    _subscription = socket.listen(
      _handleFrame,
      onError: (Object error) {
        if (!_stopped) _scheduleReconnect(error);
      },
      onDone: () {
        if (!_stopped) {
          _scheduleReconnect(const _DanmakuConnectError('连接被关闭'));
        }
      },
      cancelOnError: true,
    );

    if (!_connected.isClosed) _connected.add(true);
  }

  void _scheduleReconnect(Object error) {
    if (_stopped) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    try {
      socket?.close();
    } catch (_) {}
    if (!_connected.isClosed) _connected.add(false);

    _retry = (_retry + 1).clamp(1, 10).toInt();
    // 1s, 2s, 4s ... 最多 30s
    final shift = (_retry - 1).clamp(0, 5).toInt();
    var delay = Duration(seconds: 1 << shift);
    if (delay > _maxBackoff) delay = _maxBackoff;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_stopped) _connect();
    });
  }

  /* ------------------------------ 解包 ------------------------------ */

  void _handleFrame(dynamic data) {
    Uint8List? bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    }
    if (bytes == null) return;

    final packets = decodePackets(bytes, 0);
    for (final packet in packets) {
      _handlePacket(packet);
    }
  }

  void _handlePacket(DanmakuPacket packet) {
    switch (packet.op) {
      case _opAuthReply:
        if (packet.body.isNotEmpty) {
          try {
            final reply = jsonDecode(utf8.decode(packet.body));
            final code = (reply is Map) ? reply['code'] : null;
            if (code != 0 && code != null) {
              // auth 被拒：停止重连，避免死循环刷日志
              _stopped = true;
            }
          } catch (_) {}
        }
        return;
      case _opHeartbeatReply:
        // 心跳回执里带人气值，当前不展示
        return;
      case _opNotification:
        _handleCommand(packet.body);
        return;
      default:
        return;
    }
  }

  void _handleCommand(Uint8List body) {
    if (body.isEmpty) return;
    dynamic env;
    try {
      env = jsonDecode(utf8.decode(body, allowMalformed: true));
    } catch (_) {
      return;
    }
    if (env is! Map) return;

    final cmd = env['cmd']?.toString() ?? '';
    switch (cmd) {
      case 'DANMU_MSG':
        _handleDanmuMsg(env['info']);
        break;
      case 'SEND_GIFT':
        _handleGift(env['data']);
        break;
      case 'INTERACT_WORD':
        _handleInteract(env['data']);
        break;
      default:
        break;
    }
  }

  /// DANMU_MSG 的 info 是个「万用数组」，位置约定（实测）：
  ///   info[0][3] 弹幕颜色（十进制 RGB）
  ///   info[1]    弹幕内容
  ///   info[2][1] 用户名
  ///   info[3][0] 用户等级（可能缺失）
  void _handleDanmuMsg(dynamic info) {
    if (info is! List || info.length < 3) return;

    final content = (info[1]?.toString() ?? '').trim();
    if (content.isEmpty) return;

    var nickname = '匿名';
    final user = info[2];
    if (user is List && user.length > 1) {
      final name = user[1]?.toString().trim() ?? '';
      if (name.isNotEmpty) nickname = name;
    }

    var color = '';
    final meta = info[0];
    if (meta is List && meta.length > 3) {
      color = _colorHex(_asInt(meta[3]));
    }

    var level = 0;
    if (info.length > 3) {
      final medal = info[3];
      if (medal is List && medal.isNotEmpty) {
        level = _asInt(medal[0]);
      }
    }

    _emit(DanmakuMessage(
      id: _nextId(),
      content: content,
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: nickname,
      color: color,
      level: level,
      kind: DanmakuKind.chat,
    ));
  }

  void _handleGift(dynamic data) {
    if (data is! Map) return;
    final giftName = data['giftName']?.toString() ?? '';
    if (giftName.isEmpty) return;
    final action = (data['action']?.toString().isNotEmpty ?? false)
        ? data['action'].toString()
        : '赠送';
    final num = data['num']?.toString() ?? '1';
    _emit(DanmakuMessage(
      id: _nextId(),
      content: '[礼物] $action $giftName×$num',
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: data['uname']?.toString() ?? '',
      kind: DanmakuKind.gift,
    ));
  }

  void _handleInteract(dynamic data) {
    if (data is! Map) return;
    final uname = data['uname']?.toString().trim() ?? '';
    if (uname.isEmpty) return;
    _emit(DanmakuMessage(
      id: _nextId(),
      content: '进入直播间',
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: uname,
      kind: DanmakuKind.enter,
    ));
  }

  void _emit(DanmakuMessage message) {
    if (!_messages.isClosed) _messages.add(message);
  }

  String _nextId() => '${_roomId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  static String _colorHex(int color) {
    if (color <= 0) return '';
    final r = (color >> 16) & 0xFF;
    final g = (color >> 8) & 0xFF;
    final b = color & 0xFF;
    String hex(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');
    return '#${hex(r)}${hex(g)}${hex(b)}';
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

/* ------------------------------ 协议编解码 ------------------------------ */

class DanmakuPacket {
  const DanmakuPacket({required this.op, required this.ver, required this.body});

  final int op;
  final int ver;
  final Uint8List body;
}

/// 组装 16 字节头 + body 的包。
Uint8List encodePacket(int op, List<int> body) {
  final buffer = Uint8List(16 + body.length);
  final view = ByteData.view(buffer.buffer);
  view.setUint32(0, buffer.length, Endian.big); // pack_len
  view.setUint16(4, 16, Endian.big); // header_len
  view.setUint16(6, 1, Endian.big); // ver
  view.setUint32(8, op, Endian.big); // op
  view.setUint32(12, 1, Endian.big); // seq
  buffer.setRange(16, buffer.length, body);
  return buffer;
}

/// 把一帧拆成若干报文。
///
/// `ver=2` 的 body 是 zlib 压缩的**再次分包**数据，解压后要递归再拆；
/// 深度上限 8 防止畸形数据打爆栈。
List<DanmakuPacket> decodePackets(Uint8List data, int depth) {
  if (depth > 8) return const [];

  final result = <DanmakuPacket>[];
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  var offset = 0;

  while (offset + 16 <= data.length) {
    final packLen = view.getUint32(offset, Endian.big);
    var headerLen = view.getUint16(offset + 4, Endian.big);
    final ver = view.getUint16(offset + 6, Endian.big);
    final op = view.getUint32(offset + 8, Endian.big);

    if (headerLen < 16) headerLen = 16;
    if (packLen < headerLen + 1 || offset + packLen > data.length) break;

    final body = Uint8List.sublistView(data, offset + headerLen, offset + packLen);
    offset += packLen;

    if (ver == 2) {
      final plain = _inflate(body);
      if (plain != null) {
        result.addAll(decodePackets(plain, depth + 1));
      }
    } else if (ver == 3) {
      // brotli：我们用 protover=2，正常不会收到
      continue;
    } else {
      result.add(DanmakuPacket(op: op, ver: ver, body: body));
    }
  }

  return result;
}

Uint8List? _inflate(Uint8List data) {
  try {
    return Uint8List.fromList(const ZLibDecoder().convert(data));
  } catch (_) {
    return null;
  }
}

class _DanmakuConnectError implements Exception {
  const _DanmakuConnectError(this.message);
  final String message;

  @override
  String toString() => message;
}
