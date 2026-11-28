import 'dart:math';

import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
import 'package:tallylive/platforms/douyu/douyu_client.dart';
import 'package:tallylive/platforms/huya/huya_client.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// 是否使用 Mock 数据。
///
/// 第一阶段页面只接 Mock：**不联网也能跑完所有页面**，便于先把布局/交互/空态定下来。
/// 后期接真实接口时把它切成 false，并把 [PlatformLiveRepository] 的方法补完即可，
/// 页面代码不需要改。
///
/// 可用 `--dart-define=MOCK_DATA=false` 覆盖（不必改源码）。
const bool kUseMockData = bool.fromEnvironment('MOCK_DATA', defaultValue: true);

/// 页面唯一的数据入口。
///
/// **页面只依赖这个接口**，不直接碰平台 Client —— 这样接功能时只换实现。
abstract class LiveRepository {
  /// 分区列表（一级分组 + 二级分区）。
  Future<List<CategoryGroup>> fetchCategories(LivePlatform platform);

  /// 分页拉直播列表。categoryId 为空表示「全部」。
  Future<StreamerPage> fetchLiveList({
    required LivePlatform platform,
    String? categoryId,
    int page = 1,
    int limit = 30,
  });

  /// 搜索主播/房间。抖音只支持房间号（UI 需要提示）。
  Future<List<SearchHit>> search({
    required LivePlatform platform,
    required String keyword,
  });

  /// 取播放信息（房间 + 档位 + 线路）。
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  });
}

/// 真实实现：按平台分发到各 Client。
///
/// **待接入**：现在各 Client 还没有列表/分区/搜索实现，调用会抛 [UnimplementedError]。
/// 补实现时逐个平台替换即可，页面无感。
class PlatformLiveRepository implements LiveRepository {
  final Map<LivePlatform, PlatformClient> _clients = {
    LivePlatform.bilibili: BilibiliClient(),
    LivePlatform.douyu: DouyuClient(),
    LivePlatform.huya: HuyaClient(),
  };

  PlatformClient _client(LivePlatform platform) {
    final client = _clients[platform];
    if (client == null) {
      throw UnimplementedError('${platform.label} 尚未接入');
    }
    return client;
  }

  @override
  Future<List<CategoryGroup>> fetchCategories(LivePlatform platform) =>
      _client(platform).fetchCategories();

  @override
  Future<StreamerPage> fetchLiveList({
    required LivePlatform platform,
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) =>
      _client(platform).fetchLiveList(
        categoryId: categoryId,
        page: page,
        limit: limit,
      );

  @override
  Future<List<SearchHit>> search({
    required LivePlatform platform,
    required String keyword,
  }) =>
      _client(platform).search(keyword);

  @override
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  }) =>
      _client(platform).fetchStreamInfo(roomId);
}

/// 按当前配置创建仓库。
LiveRepository createLiveRepository() {
  // 真实实现尚未完成，无论开关如何都先返回 Mock；
  // 接功能时把下面这行换成 kUseMockData ? Mock... : Platform...
  return MockLiveRepository();
}

/* ==================================================================== Mock */

/// Mock 数据仓库。
///
/// 数据特征：
/// - 昵称/标题/分区都用真实感的中文文案，便于判断排版（不用「测试1/测试2」）
/// - 人气数字量级真实（几千 ~ 数百万），用于验证 tabular 数字对齐
/// - **封面/头像留空**，由 UI 的占位组件渲染 → 保证离线可用
/// - 支持分页、按分区过滤、按关键词搜索、模拟延迟
class MockLiveRepository implements LiveRepository {
  MockLiveRepository({
    this.latency = const Duration(milliseconds: 260),
    this.failFirstPage = false,
  });

  /// 模拟网络延迟，便于观察加载骨架。
  final Duration latency;

  /// 第一页是否失败（用于查看错误态）。
  final bool failFirstPage;

  static const List<CategoryGroup> _douyuCategories = [
    CategoryGroup(id: 'douyu-1', name: '网游竞技', categories: [
      Category(id: 'douyu-1-1', name: '英雄联盟'),
      Category(id: 'douyu-1-2', name: '无畏契约'),
      Category(id: 'douyu-1-3', name: '穿越火线'),
      Category(id: 'douyu-1-4', name: 'DOTA2'),
      Category(id: 'douyu-1-5', name: 'CS2'),
    ]),
    CategoryGroup(id: 'douyu-2', name: '单机热游', categories: [
      Category(id: 'douyu-2-1', name: '主机游戏'),
      Category(id: 'douyu-2-2', name: '怀旧游戏'),
      Category(id: 'douyu-2-3', name: 'steam新游'),
    ]),
    CategoryGroup(id: 'douyu-3', name: '手游休闲', categories: [
      Category(id: 'douyu-3-1', name: '王者荣耀'),
      Category(id: 'douyu-3-2', name: '和平精英'),
      Category(id: 'douyu-3-3', name: '金铲铲之战'),
    ]),
    CategoryGroup(id: 'douyu-4', name: '娱乐天地', categories: [
      Category(id: 'douyu-4-1', name: '户外'),
      Category(id: 'douyu-4-2', name: '美食'),
      Category(id: 'douyu-4-3', name: '音乐'),
    ]),
    CategoryGroup(id: 'douyu-5', name: '科技文化', categories: [
      Category(id: 'douyu-5-1', name: '数码'),
      Category(id: 'douyu-5-2', name: '编程'),
    ]),
  ];

  static const Map<LivePlatform, List<CategoryGroup>> _categories = {
    LivePlatform.douyu: _douyuCategories,
    LivePlatform.huya: [
      CategoryGroup(id: 'huya-1', name: '网游', categories: [
        Category(id: 'huya-1-1', name: '英雄联盟'),
        Category(id: 'huya-1-2', name: '穿越火线'),
        Category(id: 'huya-1-3', name: '地下城与勇士'),
      ]),
      CategoryGroup(id: 'huya-2', name: '手游', categories: [
        Category(id: 'huya-2-1', name: '王者荣耀'),
        Category(id: 'huya-2-2', name: '和平精英'),
      ]),
      CategoryGroup(id: 'huya-3', name: '娱乐', categories: [
        Category(id: 'huya-3-1', name: '星秀'),
        Category(id: 'huya-3-2', name: '户外'),
      ]),
    ],
    LivePlatform.douyin: [
      CategoryGroup(id: 'douyin-1', name: '游戏', categories: [
        Category(id: 'douyin-1-1', name: '手游'),
        Category(id: 'douyin-1-2', name: '端游'),
      ]),
      CategoryGroup(id: 'douyin-2', name: '娱乐', categories: [
        Category(id: 'douyin-2-1', name: '才艺'),
        Category(id: 'douyin-2-2', name: '生活'),
      ]),
    ],
    LivePlatform.bilibili: [
      CategoryGroup(id: 'bili-1', name: '网游', categories: [
        Category(id: 'bili-1-1', name: '英雄联盟'),
        Category(id: 'bili-1-2', name: 'Apex英雄'),
        Category(id: 'bili-1-3', name: '原神'),
      ]),
      CategoryGroup(id: 'bili-2', name: '手游', categories: [
        Category(id: 'bili-2-1', name: '明日方舟'),
        Category(id: 'bili-2-2', name: '崩坏：星穹铁道'),
      ]),
      CategoryGroup(id: 'bili-3', name: '虚拟主播', categories: [
        Category(id: 'bili-3-1', name: '虚拟日常'),
        Category(id: 'bili-3-2', name: '虚拟歌势'),
      ]),
    ],
  };

  /// 每个平台的昵称池（真实感，便于判断排版）。
  static const Map<LivePlatform, List<String>> _nicknames = {
    LivePlatform.douyu: [
      '老王打游戏', '深夜食堂', '峡谷小帅', '棋圣阿明', '机械师小李',
      '暴躁老哥', '摸鱼选手', '一把梭哈', '键盘侠本侠', '熬夜冠军',
    ],
    LivePlatform.huya: [
      '虎牙小北', '南风知我意', '一枪一个', '老玩家回归', '晚风与酒',
      '不浪不欢', '稳如老狗', '月光下的猫',
    ],
    LivePlatform.douyin: [
      '阿星日常', '山野食记', '手作小铺', '夜跑少年', '小城故事',
      '厨房实验室', '街头观察', '睡前一曲',
    ],
    LivePlatform.bilibili: [
      '不咕鸟', '银河摸鱼', '猫猫头子', '像素工坊', '临时工UP',
      '深夜代码', '弦上月', '手绘小站',
    ],
  };

  static const Map<LivePlatform, List<String>> _titles = {
    LivePlatform.douyu: [
      '今晚冲分，目标王者', '休闲下棋，随便聊', '新游开荒 第3天', '老版本怀旧局',
      '带粉上车 缺2个', '首胜就下播', '通宵夜聊',
    ],
    LivePlatform.huya: [
      '排位陪练，稳上分', '老玩家回归第一晚', '看比赛聊赛况', '单排冲榜',
      '凌晨还在这', '技术教学：压枪',
    ],
    LivePlatform.douyin: [
      '带你逛逛夜市', '今晚做三道家常菜', '手工皮具制作过程', '城市夜跑打卡',
      '睡前一小时轻音乐', '街头随手拍',
    ],
    LivePlatform.bilibili: [
      '今晚继续打之前那个存档', '画画直播 第12回', '代码重构实录', '周末杂谈',
      '新番同步观看', '练琴打卡',
    ],
  };

  static const Map<LivePlatform, String> _platformCategory = {
    LivePlatform.douyu: '英雄联盟',
    LivePlatform.huya: '英雄联盟',
    LivePlatform.douyin: '娱乐',
    LivePlatform.bilibili: '网游',
  };

  Future<T> _delayed<T>(T value) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    return value;
  }

  @override
  Future<List<CategoryGroup>> fetchCategories(LivePlatform platform) =>
      _delayed(_categories[platform] ?? const <CategoryGroup>[]);

  /// 用固定种子生成稳定的假数据（同一页每次一样，翻页才变）。
  List<Streamer> _mockStreamers(LivePlatform platform, int count, int seedBase) {
    final random = Random(seedBase);
    final nicknames = _nicknames[platform]!;
    final titles = _titles[platform]!;
    return List<Streamer>.generate(count, (index) {
      final nickname = nicknames[(seedBase + index) % nicknames.length];
      final title = titles[(seedBase + index) % titles.length];
      // 人气量级：几百 ~ 数百万
      final viewers = (random.nextDouble() * 1500000).round() + 300;
      return Streamer(
        platform: platform,
        id: '${platform.name}-${seedBase + index}',
        nickname: nickname,
        title: title,
        viewers: viewers,
        categoryName: _platformCategory[platform] ?? '',
        // 约 1/6 为未开播，用于验证「下播置灰」的显示
        isLive: random.nextInt(6) != 0,
      );
    });
  }

  @override
  Future<StreamerPage> fetchLiveList({
    required LivePlatform platform,
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async {
    if (failFirstPage && page == 1) {
      await Future<void>.delayed(latency);
      throw const LiveRepositoryException('网络不可达，请检查连接后重试');
    }
    // 最多 4 页，用于验证「加载到底」的表现
    const maxPages = 4;
    if (page > maxPages) {
      return _delayed(const StreamerPage(items: [], page: 0, hasMore: false));
    }
    final seedBase = (page - 1) * limit;
    final items = _mockStreamers(platform, limit, seedBase);
    return _delayed(StreamerPage(
      items: items,
      page: page,
      hasMore: page < maxPages,
      totalPages: maxPages,
    ));
  }

  @override
  Future<List<SearchHit>> search({
    required LivePlatform platform,
    required String keyword,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return _delayed(const <SearchHit>[]);

    final nicknames = _nicknames[platform]!;
    final titles = _titles[platform]!;
    final hits = <SearchHit>[];
    for (var i = 0; i < nicknames.length; i++) {
      final nickname = nicknames[i];
      final title = titles[i % titles.length];
      if (!nickname.contains(trimmed) && !title.contains(trimmed)) continue;
      hits.add(SearchHit(
        platform: platform,
        id: '${platform.name}-search-$i',
        nickname: nickname,
        title: title,
        isLive: i.isEven,
      ));
    }
    return _delayed(hits);
  }

  @override
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  }) async {
    // Mock 不提供播放地址：播放页走真实 Client（B站/斗鱼已可用）。
    throw const LiveRepositoryException('Mock 数据不提供播放地址');
  }
}

class LiveRepositoryException implements Exception {
  const LiveRepositoryException(this.message);
  final String message;

  @override
  String toString() => message;
}
