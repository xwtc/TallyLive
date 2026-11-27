import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/core/models.dart';

/// 多线路相关的纯逻辑测试。
///
/// 线路切换是「不重新取流、只换地址」的关键，回退逻辑写错会导致
/// 用户切到没有地址的线路后黑屏，所以单独钉住。
void main() {
  const lines = [
    StreamLine(id: 'hw', label: '线路1'),
    StreamLine(id: 'ws', label: '线路2'),
    StreamLine(id: 'scdn', label: '线路3'),
  ];

  StreamVariant variantWith(List<StreamUrl> urls) => StreamVariant(
        id: '10000',
        label: '原画',
        format: 'flv',
        urls: urls,
      );

  group('StreamVariant.urlForLine', () {
    final variant = variantWith(const [
      StreamUrl(lineId: 'hw', url: 'https://a/1.flv'),
      StreamUrl(lineId: 'ws', url: 'https://a/2.flv'),
    ]);

    test('命中线路时返回该线路地址', () {
      expect(variant.urlForLine('ws'), 'https://a/2.flv');
    });

    test('线路不存在时回退到第一条', () {
      expect(variant.urlForLine('scdn'), 'https://a/1.flv');
    });

    test('lineId 为 null 或空串时返回首选地址', () {
      expect(variant.urlForLine(null), 'https://a/1.flv');
      expect(variant.urlForLine(''), 'https://a/1.flv');
    });

    test('url getter 等于第一条', () {
      expect(variant.url, 'https://a/1.flv');
    });

    test('availableLineIds 反映实际覆盖的线路', () {
      expect(variant.availableLineIds, {'hw', 'ws'});
    });
  });

  group('StreamInfoResult.usableLines', () {
    test('只保留在至少一个档位里真实有地址的线路', () {
      final result = StreamInfoResult(
        room: const RoomInfo(platform: LivePlatform.douyu, roomId: '1'),
        lines: lines,
        variants: [
          variantWith(const [
            StreamUrl(lineId: 'hw', url: 'https://a/1.flv'),
            StreamUrl(lineId: 'ws', url: 'https://a/2.flv'),
          ]),
        ],
      );
      // scdn 在所有档位里都没有地址，应被过滤掉
      expect(result.usableLines.map((e) => e.id), ['hw', 'ws']);
    });

    test('没有任何可用地址时保留原始线路表（避免 UI 空掉）', () {
      final result = StreamInfoResult(
        room: const RoomInfo(platform: LivePlatform.douyu, roomId: '1'),
        lines: lines,
        variants: const [],
      );
      expect(result.usableLines.length, 3);
    });
  });

  group('StreamVariant.isEmpty', () {
    test('无地址时为空', () {
      expect(variantWith(const []).isEmpty, isTrue);
      expect(variantWith(const []).url, isEmpty);
    });

    test('有地址时非空', () {
      expect(
        variantWith(const [StreamUrl(lineId: 'hw', url: 'https://a/1.flv')]).isEmpty,
        isFalse,
      );
    });
  });

  group('LivePlatform', () {
    test('tryParse 大小写不敏感', () {
      expect(LivePlatform.tryParse('Douyu'), LivePlatform.douyu);
      expect(LivePlatform.tryParse('bilibili'), LivePlatform.bilibili);
      expect(LivePlatform.tryParse('unknown'), isNull);
    });
  });
}
