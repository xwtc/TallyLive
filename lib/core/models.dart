/// 各平台共用的数据模型。
///
/// 移植自 TallyLive(Go) 的 `internal/platforms/common/types.go`：
/// 把不同平台的响应归一成同一套结构，UI 层就不需要关心平台差异。
library;

/// 支持的直播平台。
enum LivePlatform {
  douyu('斗鱼'),
  huya('虎牙'),
  douyin('抖音'),
  bilibili('B站');

  const LivePlatform(this.label);

  /// 中文显示名。
  final String label;

  /// 从字符串解析，未知返回 null。
  static LivePlatform? tryParse(String raw) {
    final lower = raw.toLowerCase();
    for (final platform in LivePlatform.values) {
      if (platform.name == lower) return platform;
    }
    return null;
  }
}

/// 直播间归一化信息。
class RoomInfo {
  const RoomInfo({
    required this.platform,
    required this.roomId,
    this.title = '',
    this.nickname = '',
    this.avatar = '',
    this.cover = '',
    this.category = '',
    this.online = 0,
    this.isLive = false,
  });

  final LivePlatform platform;

  /// 平台内部的真实房间号（短号会被解析成真实号）。
  final String roomId;
  final String title;
  final String nickname;
  final String avatar;
  final String cover;
  final String category;

  /// 人气/观看数，各平台单位不同，仅用于展示。
  final int online;
  final bool isLive;
}

/// 一个清晰度档位。
///
/// [urls] 保留同一档位的多条线路（多 CDN），便于失败时自动切换；
/// [url] 是首选地址，等于 `urls.first`。
class StreamVariant {
  const StreamVariant({
    required this.id,
    required this.label,
    required this.url,
    required this.format,
    required this.urls,
  });

  /// 平台内部档位标识（B 站是 qn，斗鱼是 rate）。
  final String id;

  /// 展示用档位名，如「原画」「蓝光」。
  final String label;
  final String url;

  /// `hls` 或 `flv`，决定播放器需要哪种解封装。
  final String format;

  /// 同档位的全部地址。
  final List<String> urls;
}

/// 一次取流的结果：房间信息 + 可用档位。
class StreamInfoResult {
  const StreamInfoResult({required this.room, required this.variants});

  final RoomInfo room;
  final List<StreamVariant> variants;

  bool get playable => variants.isNotEmpty;
}
