import 'package:tallylive/core/live_repository.dart';
import 'package:tallylive/core/models.dart';

/// 测试用的假仓库：不联网、立即返回。
///
/// 生产代码里已经删掉 Mock 数据（页面只接真实接口），
/// 这个 fake 只存在于 test/ 下，供 widget 测试使用。
class FakeLiveRepository implements LiveRepository {
  FakeLiveRepository({
    this.streamers = const [],
    this.groups = const [],
    this.failCategories = false,
    this.failList = false,
  });

  final List<Streamer> streamers;
  final List<CategoryGroup> groups;
  final bool failCategories;
  final bool failList;

  @override
  List<LivePlatform> get supportedPlatforms => const [
        LivePlatform.bilibili,
        LivePlatform.douyu,
      ];

  @override
  Future<List<CategoryGroup>> fetchCategories(LivePlatform platform) async {
    if (failCategories) throw Exception('分区接口失败');
    if (groups.isNotEmpty) return groups;
    return const [
      CategoryGroup(id: 'g1', name: '网游', categories: [
        Category(id: '2_86', name: '英雄联盟'),
        Category(id: '2_87', name: '无畏契约'),
      ]),
    ];
  }

  @override
  Future<StreamerPage> fetchLiveList({
    required LivePlatform platform,
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async {
    if (failList) throw Exception('列表接口失败');
    if (page > 1) {
      return const StreamerPage(items: [], page: 1, hasMore: false);
    }
    return StreamerPage(items: streamers, page: 1, hasMore: false);
  }

  @override
  Future<List<SearchHit>> search({
    required LivePlatform platform,
    required String keyword,
    int page = 1,
  }) async =>
      const [];

  @override
  Future<StreamInfoResult> fetchStreamInfo({
    required LivePlatform platform,
    required String roomId,
  }) async =>
      StreamInfoResult(
        room: RoomInfo(
          platform: platform,
          roomId: roomId,
          title: '测试房间',
          nickname: '测试主播',
          isLive: true,
        ),
        variants: const [],
      );

  @override
  Future<RoomInfo> fetchRoomInfo({
    required LivePlatform platform,
    required String roomId,
  }) async =>
      RoomInfo(
        platform: platform,
        roomId: roomId,
        title: '测试房间',
        nickname: '测试主播',
        isLive: true,
      );
}

/// 构造一页假主播。
List<Streamer> fakeStreamers({int count = 4}) => List<Streamer>.generate(
      count,
      (index) => Streamer(
        platform: LivePlatform.bilibili,
        id: '${1000 + index}',
        nickname: '主播$index',
        title: '标题$index',
        viewers: 1200 + index * 10,
        categoryName: '英雄联盟',
        isLive: index != 2, // 留一个未开播，验证置灰
      ),
    );