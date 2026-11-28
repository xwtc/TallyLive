import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';
import 'package:tallylive/platforms/douyin/douyin_client.dart';
import 'package:tallylive/platforms/douyu/douyu_client.dart';
import 'package:tallylive/platforms/huya/huya_client.dart';
import 'package:tallylive/platforms/platform_client.dart';

/// 页面唯一的数据入口。
///
/// **页面只依赖这个接口**，不直接碰平台 Client —— 接功能时只换实现。
abstract class LiveRepository {
  /// 已实现「分区 / 列表 / 搜索」的平台。UI 只用这些平台构建筛选器。
  List<LivePlatform> get supportedPlatforms;

  /// 分区列表（一级分组 + 二级分区）。
  Future<List<CategoryGroup>> fetchCategories(LivePlatform platform);

  /// 分页拉直播列表。categoryId 为空表示用平台默认分区。
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
    int page = 1,
  });

  /// 取播放信息（房间 + 档位 + 线路）。
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  });

  /// 取房间信息（播放页顶部/关注刷新用）。
  Future<RoomInfo> fetchRoomInfo({
    required LivePlatform platform,
    required String roomId,
  });
}

/// 真实实现：按平台分发到各 Client。
///
/// 分区/列表/搜索目前只有 **B站 与 斗鱼** 实现了；虎牙、抖音会抛
/// [UnimplementedError]，UI 用 [supportedPlatforms] 过滤掉。
class PlatformLiveRepository implements LiveRepository {
  PlatformLiveRepository();

  final Map<LivePlatform, PlatformClient> _clients = {
    LivePlatform.bilibili: BilibiliClient(),
    LivePlatform.douyu: DouyuClient(),
    LivePlatform.huya: HuyaClient(),
    LivePlatform.douyin: DouyinClient(),
  };

  /// 已实现列表类接口的平台（顺序即 UI 展示顺序）。
  @override
  List<LivePlatform> get supportedPlatforms => const [
        LivePlatform.bilibili,
        LivePlatform.douyu,
        LivePlatform.huya,
        LivePlatform.douyin,
      ];

  PlatformClient _client(LivePlatform platform) {
    final client = _clients[platform];
    if (client == null) throw UnimplementedError('${platform.label} 尚未接入');
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
    int page = 1,
  }) =>
      _client(platform).search(keyword, page: page);

  @override
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  }) =>
      _client(platform).fetchStreamInfo(roomId);

  @override
  Future<RoomInfo> fetchRoomInfo({
    required LivePlatform platform,
    required String roomId,
  }) =>
      _client(platform).fetchRoomInfo(roomId);
}

/// 创建仓库（当前直接返回真实实现；页面可注入自定义实现便于测试）。
LiveRepository createLiveRepository() => PlatformLiveRepository();