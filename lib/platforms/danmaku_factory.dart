import 'package:tallylive/core/danmaku.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/platforms/bilibili/bilibili_danmaku.dart';
import 'package:tallylive/platforms/douyu/douyu_danmaku.dart';

/// 按平台创建弹幕客户端。
///
/// 尚未接入弹幕的平台返回 null，UI 会退化成「无弹幕」而不是报错。
DanmakuClient? createDanmakuClient(LivePlatform platform) {
  switch (platform) {
    case LivePlatform.bilibili:
      return BilibiliDanmakuClient();
    case LivePlatform.douyu:
      return DouyuDanmakuClient();
    case LivePlatform.huya:
    case LivePlatform.douyin:
      // 待移植
      return null;
  }
}
