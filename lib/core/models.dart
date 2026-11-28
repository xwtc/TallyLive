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

/// 一条线路（CDN）。各平台叫法不同：斗鱼是 cdn 标识、B 站是 host。
class StreamLine {
  const StreamLine({required this.id, required this.label});

  /// 平台内部线路标识（斗鱼是 cdn 名，B 站是 host）。
  final String id;

  /// 展示名，如「线路1」「cn-gotcha104」。
  final String label;
}

/// 某个清晰度在某个线路下的地址。
class StreamUrl {
  const StreamUrl({required this.lineId, required this.url});

  /// 对应 [StreamLine.id]；空串表示平台的默认线路。
  final String lineId;
  final String url;
}

/// 一个清晰度档位。
///
/// 同一档位在不同线路上有不同的地址，所以 [urls] 是「线路 → 地址」的列表，
/// 顺序与 [StreamInfoResult.lines] 一致，便于 UI 直接按线路切换。
class StreamVariant {
  const StreamVariant({
    required this.id,
    required this.label,
    required this.format,
    required this.urls,
  });

  /// 平台内部档位标识（B 站是 qn，斗鱼是 rate）。
  final String id;

  /// 展示用档位名，如「原画」「蓝光」。
  final String label;

  /// `hls` 或 `flv`，决定播放器需要哪种解封装。
  final String format;

  /// 各线路地址；至少一条。
  final List<StreamUrl> urls;

  /// 首选地址（第一条线路）。
  String get url => urls.isEmpty ? '' : urls.first.url;

  bool get isEmpty => urls.isEmpty;

  /// 按线路取地址；该线路没有地址时回退到第一条。
  String urlForLine(String? lineId) {
    if (lineId == null || lineId.isEmpty) return url;
    for (final item in urls) {
      if (item.lineId == lineId) return item.url;
    }
    return url;
  }

  /// 该档位实际覆盖到的线路 id 集合。
  Set<String> get availableLineIds => urls.map((e) => e.lineId).toSet();
}

/// 一次取流的结果：房间信息 + 可用线路 + 可用档位。
class StreamInfoResult {
  const StreamInfoResult({
    required this.room,
    required this.variants,
    this.lines = const [],
  });

  final RoomInfo room;
  final List<StreamLine> lines;
  final List<StreamVariant> variants;

  bool get playable => variants.isNotEmpty;

  /// 只保留在至少一个档位里真实存在地址的线路。
  List<StreamLine> get usableLines {
    final used = <String>{};
    for (final variant in variants) {
      used.addAll(variant.availableLineIds);
    }
    final filtered = lines.where((line) => used.contains(line.id)).toList();
    return filtered.isEmpty ? lines : filtered;
  }
}

/* ------------------------------------------------------------------ 列表页模型 */
/* 以下字段与 DTV internal/platforms/common/types.go 一一对应。              */
/* 页面只依赖这些模型；Mock 与真实实现返回同一套结构，接功能时不用改 UI。      */

/// 一级分区下的二级分区（分区页的条目）。
class Category {
  const Category({required this.id, required this.name});

  final String id;
  final String name;
}

/// 分区分组（斗鱼对应 cate1，如「热门游戏」「娱乐天地」）。
class CategoryGroup {
  const CategoryGroup({
    required this.id,
    required this.name,
    required this.categories,
  });

  final String id;
  final String name;
  final List<Category> categories;
}

/// 主播卡片数据（列表行/网格卡片共用）。
class Streamer {
  const Streamer({
    required this.platform,
    required this.id,
    required this.nickname,
    this.title = '',
    this.cover = '',
    this.avatar = '',
    this.viewers = 0,
    this.categoryName = '',
    this.isLive = false,
  });

  final LivePlatform platform;

  /// 房间号（真实房间号，不是短号）。
  final String id;
  final String nickname;
  final String title;
  final String cover;
  final String avatar;

  /// 人气/观看数。
  final int viewers;
  final String categoryName;
  final bool isLive;
}

/// 一页主播卡片 + 分页信息（列表无限滚动需要 hasMore）。
class StreamerPage {
  const StreamerPage({
    required this.items,
    this.page = 1,
    this.hasMore = false,
    this.totalPages = 0,
  });

  final List<Streamer> items;
  final int page;
  final bool hasMore;

  /// 0 表示上游没给总页数（此时 hasMore 由「本页是否满页」推断）。
  final int totalPages;

  static const StreamerPage empty = StreamerPage(items: []);
}

/// 搜索结果条目。
class SearchHit {
  const SearchHit({
    required this.platform,
    required this.id,
    required this.nickname,
    this.title = '',
    this.avatar = '',
    this.isLive = false,
  });

  final LivePlatform platform;
  final String id;
  final String nickname;
  final String title;
  final String avatar;
  final bool isLive;
}
