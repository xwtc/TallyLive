import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// 注意：brotli 包导出的**实例**就叫 brotli，这里不能加 `as` 别名，
// 否则 `brotli.decode()` 会被解析成库里的顶层 decode 函数（不存在）。
import 'package:brotli/brotli.dart';

import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';

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
  Timer? _watchdog;
  bool _stopped = true;
  int _sequence = 0;
  String _roomId = '';

  /// 播放页已知的真实房间号（省掉一次 room get_info）。
  String _realRoomId = '';
  int _retry = 0;

  /// 连续 auth 被拒次数：用于把退避拉长，避免快速重连被上游限流。
  int _authFailures = 0;

  static const Duration _heartbeatInterval = Duration(seconds: 30);

  /// 超过这么久没收到任何帧就认为连接已死（B 站服务端会静默丢弃半死连接）。
  static const Duration _readTimeout = Duration(seconds: 90);

  static const Duration _maxBackoff = Duration(seconds: 30);

  /// op 码。
  static const int _opHeartbeat = 2;
  static const int _opHeartbeatReply = 3;
  static const int _opNotification = 5;
  static const int _opAuth = 7;
  static const int _opAuthReply = 8;

  /// protover=2（zlib）。
  ///
  /// 跟 DTV 的选择一致：2 依然有效，且 zlib 是 Dart SDK 自带。
  /// 官方前端已用 3（brotli），所以下面**同时保留** brotli 解码能力——
  /// 万一服务端按 3 下发，我们也能解，不会整帧丢弃。
  static const int _protover = 2;

  @override
  Stream<DanmakuMessage> get messages => _messages.stream;

  @override
  Stream<bool> get connected => _connected.stream;

  @override
  Future<void> start(String roomId, {String? realRoomId}) async {
    if (roomId.isEmpty) return;
    await stop();
    _stopped = false;
    _roomId = roomId;
    _realRoomId = (realRoomId ?? '').trim();
    _retry = 0;
    // 不 await：让播放页先出画面，弹幕在后台连上就出现
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
      //
      // 播放页取流时已经知道真实房间号，直接用；只有没传时才回退到再查一次。
      // 之前每次都重新 fetchRoomInfo，等于串行多花一个往返，首帧弹幕明显变慢。
      var realRoomId = _realRoomId;
      if (realRoomId.isEmpty) {
        final room = await _client.fetchRoomInfo(_roomId);
        realRoomId = room.roomId;
      }
      final serverInfo = await _client.fetchDanmuInfo(realRoomId);
      if (serverInfo.token.isEmpty || serverInfo.hosts.isEmpty) {
        throw const _DanmakuConnectError('没有可用的弹幕服务器');
      }
      if (_stopped) return;

      // 2. 依次尝试各域名
      Object? lastError;
      for (final host in serverInfo.hosts) {
        if (_stopped) return;
        try {
          await _openSocket(host, realRoomId, serverInfo.token);
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

  Future<void> _openSocket(
    String host,
    String realRoomId,
    String token,
  ) async {
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

    // 发 auth（参数与 DTV 的 Go 实现保持一致：不带 buvid）
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
        // 写失败说明连接已断，交给 listen 的错误处理
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

    _resetWatchdog();
    if (!_connected.isClosed) _connected.add(true);
  }

  /// 每收到一帧就重置看门狗；超时视为半死连接并主动重连。
  ///
  /// B 站服务端有时会静默丢弃连接（TCP 不 FIN），只靠 onDone 是发现不了的，
  /// 表现就是「一直显示已连接但再没有弹幕」。
  void _resetWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(_readTimeout, () {
      if (_stopped) return;
      _scheduleReconnect(const _DanmakuConnectError('读超时，连接可能已死'));
    });
  }

  void _scheduleReconnect(Object error) {
    if (_stopped) return;
    _heartbeat?.cancel();
    _heartbeat = null;
    _watchdog?.cancel();
    _watchdog = null;
    _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    try {
      socket?.close();
    } catch (_) {}
    if (!_connected.isClosed) _connected.add(false);

    _retry = (_retry + 1).clamp(1, 12).toInt();
    // 1s, 2s, 4s ... 最多 30s；连续 auth 失败时从更长的退避起步，避免被限流。
    final floor = _authFailures >= 3 ? 3 : 0;
    final shift = (_retry - 1).clamp(0, 5).toInt() + floor;
    final seconds = 1 << shift.clamp(0, 6).toInt();
    var delay = Duration(seconds: seconds);
    if (delay > _maxBackoff) delay = _maxBackoff;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_stopped) _connect();
    });
  }

  /* ------------------------------ 解包 ------------------------------ */

  void _handleFrame(dynamic data) {
    // 收到任何帧都说明连接活着，重置看门狗。
    _resetWatchdog();

    Uint8List? bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    }
    if (bytes == null) return;

    DanmakuStats.instance.countFrame();
    try {
      _processFrame(bytes);
    } catch (_) {
      // 单帧解析失败绝不能影响连接：弹幕协议会随版本变化，
      // 一条坏消息不应该让整条 WS 被丢掉（那会表现为反复重连）。
    }
  }

  /// 处理一个 WS 消息。
  ///
  /// 只读**外层**的 16 字节头拿 ver/op，body 交给对应的处理器。
  void _processFrame(Uint8List data) {
    if (data.length < 16) return;
    final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);

    var headerLen = view.getUint16(4, Endian.big);
    if (headerLen < 16) headerLen = 16;
    final ver = view.getUint16(6, Endian.big);
    final op = view.getUint32(8, Endian.big);

    final body = data.length > headerLen
        ? Uint8List.sublistView(data, headerLen)
        : Uint8List(0);

    switch (op) {
      case _opAuthReply:
        _handleAuthReply(body);
        return;
      case _opHeartbeatReply:
        // 心跳回执里带人气值，当前不展示
        return;
      case _opNotification:
        _handleNotification(body, ver);
        return;
      default:
        return;
    }
  }

  void _handleAuthReply(Uint8List body) {
    if (body.isEmpty) return;
    try {
      final reply = jsonDecode(utf8.decode(body, allowMalformed: true));
      final code = (reply is Map) ? reply['code'] : null;
      if (code != null && code != 0) {
        // auth 被拒：不直接停止（否则圆点会一直黄），
        // 计入失败次数后按更长的退避重连。
        _authFailures++;
        _scheduleReconnect(_DanmakuConnectError('auth 被拒 code=$code'));
      } else {
        _authFailures = 0;
      }
    } catch (_) {}
  }

  /// 处理 op=5 的通知帧。
  ///
  /// 流程：按外层头取 ver → 解压（zlib / brotli）→ 按 16 字节头逐包解析。
  ///
  /// 与 DTV（Go 版）的差别只有一处：**失步时重同步**。
  /// DTV 遇到长度异常的包直接 break，把同一帧后面的弹幕全丢掉；
  /// 这里改为向后逐字节寻找下一个合法头继续解析。
  void _handleNotification(Uint8List body, int ver) {
    if (body.isEmpty) return;

    Uint8List payload = body;
    if (ver == 2) {
      payload = _inflate(body) ?? Uint8List(0);
    } else if (ver == 3) {
      // 我们请求的是 protover=2，理论上不会收到 brotli；
      // 但服务端如果按 3 下发，这里能解就不会整帧丢弃。
      payload = _unbrotli(body) ?? Uint8List(0);
    }
    if (payload.isEmpty) return;
    DanmakuStats.instance.countDecodedFrame();

    for (final packet in decodePackets(payload, 0)) {
      if (packet.op != _opNotification || packet.body.isEmpty) continue;
      _handleCommandJson(utf8.decode(packet.body, allowMalformed: true));
    }
  }

  void _handleCommandJson(String jsonText) {
    dynamic env;
    try {
      env = jsonDecode(jsonText);
    } catch (_) {
      return;
    }
    if (env is! Map) return;

    final cmd = env['cmd']?.toString() ?? '';
    if (cmd.isEmpty) return;
    DanmakuStats.instance.countCommand(cmd);

    // ⚠️ B 站的 cmd 会带后缀，形如 "DANMU_MSG:4:0:2:2:2:0"。
    // 用 == "DANMU_MSG" 精确匹配会丢掉全部带后缀的普通弹幕，
    // 表现就是「弹幕比官方直播间少很多」。
    if (cmd == 'DANMU_MSG' || cmd.startsWith('DANMU_MSG:')) {
      _handleDanmuMsg(env['info']);
      return;
    }
    // 醒目留言也是用户发的文字（不是礼物），官方会把它显示在弹幕区
    if (cmd == 'SUPER_CHAT_MESSAGE') {
      _handleSuperChat(env['data']);
      return;
    }
    if (cmd == 'SEND_GIFT' || cmd.startsWith('SEND_GIFT:')) {
      _handleGift(env['data']);
      return;
    }
    if (cmd == 'INTERACT_WORD' || cmd.startsWith('INTERACT_WORD:')) {
      _handleInteract(env['data']);
      return;
    }
  }

  /// 醒目留言：付费留言，内容是用户打的字，按聊天弹幕处理。
  void _handleSuperChat(dynamic data) {
    if (data is! Map) return;
    final content = (data['message']?.toString() ?? '').trim();
    if (content.isEmpty) return;
    _emit(DanmakuMessage(
      id: _nextId(),
      content: content,
      at: DateTime.now().millisecondsSinceEpoch,
      nickname: data['user_info'] is Map
          ? (data['user_info']['uname']?.toString() ?? '')
          : '',
      kind: DanmakuKind.chat,
    ));
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
    DanmakuStats.instance.countChat();
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
///
/// **失步重同步**：DTV（Go 版）遇到长度异常的包会直接 break，导致同一帧
/// 后面的弹幕全部丢失。这里改为向后逐字节探测下一个合法包头继续解析，
/// 最多探测到帧尾；解析出的坏包会在 JSON 解析阶段被自然丢弃。
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

    // 空 body 的包（packLen == headerLen）是合法的：
    // 用 `packLen < headerLen + 1` 判断会把同一帧后面的包全丢掉。
    final valid =
        packLen >= headerLen && offset + packLen <= data.length;
    if (!valid) {
      final next = _resync(data, offset + 1);
      if (next < 0) break;
      offset = next;
      continue;
    }

    final body = Uint8List.sublistView(data, offset + headerLen, offset + packLen);
    offset += packLen;

    if (ver == 2) {
      if (body.isNotEmpty) {
        final plain = _inflate(body);
        if (plain != null) {
          result.addAll(decodePackets(plain, depth + 1));
        }
      }
    } else if (ver == 3) {
      if (body.isNotEmpty) {
        final plain = _unbrotli(body);
        if (plain != null) {
          result.addAll(decodePackets(plain, depth + 1));
        }
      }
    } else {
      result.add(DanmakuPacket(op: op, ver: ver, body: body));
    }
  }

  return result;
}

/// 从 [from] 起逐字节寻找下一个看起来合法的包头，返回其偏移；找不到返回 -1。
///
/// 合法条件：header_len >= 16、pack_len >= header_len、且 offset+pack_len 不越界。
/// 这是"失步重同步"的核心：宁可多解析几个垃圾包（后续 JSON 解析会丢弃），
/// 也不要因为一个坏包丢掉整帧剩余内容。
int _resync(Uint8List data, int from) {
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  for (var i = from; i + 16 <= data.length; i++) {
    final packLen = view.getUint32(i, Endian.big);
    final headerLen = view.getUint16(i + 4, Endian.big);
    if (headerLen >= 16 && packLen >= headerLen && i + packLen <= data.length) {
      return i;
    }
  }
  return -1;
}

Uint8List? _inflate(Uint8List data) {
  try {
    // ZLibDecoder 的构造不是 const，这里不能加 const。
    return Uint8List.fromList(ZLibDecoder().convert(data));
  } catch (_) {
    return null;
  }
}

Uint8List? _unbrotli(Uint8List data) {
  try {
    return Uint8List.fromList(brotli.decode(data));
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
