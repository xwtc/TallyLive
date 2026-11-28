import 'package:tallylive/core/models.dart';

/// 各平台客户端的统一接口。
///
/// UI 只依赖这个接口，切平台时不需要改页面代码。
abstract class PlatformClient {
  LivePlatform get platform;

  /// 拉取房间信息 + 可播档位。
  ///
  /// [roomId] 由用户输入，各平台格式不同（斗鱼/B站支持短号，抖音只支持房间号）。
  Future<StreamInfoResult> fetchStreamInfo(String roomId);

  /// 只取房间信息（用于关注列表刷新、预览）。
  Future<RoomInfo> fetchRoomInfo(String roomId);

  /* ------------------------------------------------------------------ */
  /* 以下三个方法供列表页使用。当前各平台尚未实现，默认抛 UnimplementedError；*/
  /* 页面走 Mock 数据（见 core/live_repository.dart），不会触发。           */
  /* 接功能时按平台逐个 override 即可。                                    */
  /* ------------------------------------------------------------------ */

  /// 分区列表（一级分组 + 二级分区）。
  Future<List<CategoryGroup>> fetchCategories() async =>
      throw UnimplementedError('${platform.label} 的 fetchCategories 尚未实现');

  /// 分页拉直播列表；[categoryId] 为空表示「全部」。
  Future<StreamerPage> fetchLiveList({
    String? categoryId,
    int page = 1,
    int limit = 30,
  }) async =>
      throw UnimplementedError('${platform.label} 的 fetchLiveList 尚未实现');

  /// 搜索主播/房间（抖音只支持房间号）。
  Future<List<SearchHit>> search(String keyword) async =>
      throw UnimplementedError('${platform.label} 的 search 尚未实现');
}
