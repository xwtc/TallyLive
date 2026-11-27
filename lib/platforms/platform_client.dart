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
}
