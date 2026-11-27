import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/douyu/douyu_client.dart';

/// 斗鱼签名的纯函数测试。
///
/// 签名链是取流失败最常见的原因，而网络与时间不可控，
/// 所以把「确定的部分」抽出来单测。
void main() {
  group('douyuMd5Hex', () {
    test('空串 md5', () {
      expect(douyuMd5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('已知值', () {
      expect(douyuMd5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
    });
  });

  group('douyuSignSecret', () {
    test('enc_time 为 0 时 secret 等于 rand_str', () {
      expect(
        douyuSignSecret(randStr: 'rs', key: 'k', encTime: 0),
        'rs',
      );
    });

    test('enc_time 为 1 时是 md5(rand_str + key)', () {
      expect(
        douyuSignSecret(randStr: 'rs', key: 'k', encTime: 1),
        douyuMd5Hex('rsk'),
      );
    });

    test('enc_time 递增时逐层嵌套', () {
      final once = douyuMd5Hex('rsk');
      final twice = douyuMd5Hex('${once}k');
      expect(
        douyuSignSecret(randStr: 'rs', key: 'k', encTime: 2),
        twice,
      );
    });

    test('结果恒为 32 位小写十六进制', () {
      final secret = douyuSignSecret(randStr: 'abc', key: 'def', encTime: 5);
      expect(secret.length, 32);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(secret), isTrue);
    });
  });

  group('douyuSignAuth', () {
    test('auth = md5(secret + key + suffix)', () {
      expect(
        douyuSignAuth(secret: 's', key: 'k', suffix: '9999123'),
        douyuMd5Hex('sk9999123'),
      );
    });

    test('is_special=1 时 suffix 为空串', () {
      expect(
        douyuSignAuth(secret: 's', key: 'k', suffix: ''),
        douyuMd5Hex('sk'),
      );
    });
  });

  group('douyuApplyExpirePatch', () {
    test('ws CDN 的 300 秒直链补 expire=0', () {
      const url = 'https://x.douyucdn.cn/live/a.flv?expire=300&fcdn=ws&x=1';
      expect(douyuApplyExpirePatch(url), '$url&expire=0');
    });

    test('非 ws/非 300 秒的地址不改动', () {
      const url = 'https://x.douyucdn.cn/live/a.flv?expire=300&fcdn=hw';
      expect(douyuApplyExpirePatch(url), url);
    });

    test('已经带 expire=0 的地址不重复追加', () {
      const url = 'https://x.douyucdn.cn/live/a.flv?expire=0&fcdn=ws';
      expect(douyuApplyExpirePatch(url), url);
    });
  });

  group('douyuFormatOf', () {
    test('m3u8 判为 hls', () {
      expect(douyuFormatOf('https://a/b/index.m3u8?x=1'), 'hls');
    });

    test('flv 判为 flv', () {
      expect(douyuFormatOf('https://a/b/live.flv?x=1'), 'flv');
    });

    test('无后缀默认按 flv', () {
      expect(douyuFormatOf('https://a/b/stream'), 'flv');
    });
  });
}
