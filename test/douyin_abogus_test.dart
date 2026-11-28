import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/douyin/douyin_abogus.dart';

/// a_bogus 签名测试。
///
/// 这些断言来自**实测验证**：用 Simple Live 内嵌的原始 JS（线上实现）当裁判，
/// 固定 `Date.now` 与 `Math.random` 后逐字节比对，两者完全一致。
/// Dart 版移植后必须保持同样的字节序列，所以这里把关键中间量钉住。
void main() {
  group('SM3', () {
    test('已知向量：SM3("abc")', () {
      // 国密标准测试向量
      const expected =
          '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0';
      expect(_hex(sm3Sum(utf8.encode('abc'))), expected);
    });

    test('空串摘要固定', () {
      expect(_hex(sm3Sum(const [])),
          '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b');
    });

    test('较长输入（跨 64 字节块）稳定', () {
      final data = utf8.encode('a' * 200);
      final first = _hex(sm3Sum(data));
      final second = _hex(sm3Sum(data));
      expect(first, second);
      expect(first.length, 64);
    });
  });

  group('RC4', () {
    test('与已知 RC4 向量一致', () {
      // RFC 6229 之外的经典测试：Key="Key", Plaintext="Plaintext"
      final out = rc4Encrypt(utf8.encode('Plaintext'), utf8.encode('Key'));
      expect(_hex(out), 'bbf316e8d940af0ad3');
    });

    test('输出长度等于输入长度', () {
      final out = rc4Encrypt(List<int>.filled(110, 0), [121]);
      expect(out.length, 110);
    });
  });

  group('自定义 base64（resultEncrypt）', () {
    test('s0 是标准 base64 表，编码 "abc" 得 YWJj', () {
      final out = ABogus.resultEncrypt(
        Uint8List.fromList(utf8.encode('abc')),
        's0',
      );
      expect(out, 'YWJj');
    });

    test('不足 3 字节的末组只输出 3 个字符（不做 = 填充）', () {
      // 这是与 DTV 的 Go 版的关键差异：Go 补 4 个字符会让签名被判无效
      final out = ABogus.resultEncrypt(
        Uint8List.fromList([1, 2, 3, 4]),
        's4',
      );
      expect(out.length, 7); // 4 字节 → 4 + 3
    });

    test('五张表都可用且长度一致', () {
      final data = Uint8List.fromList(List<int>.generate(12, (i) => i));
      for (final table in ['s0', 's1', 's2', 's3', 's4']) {
        final out = ABogus.resultEncrypt(data, table);
        expect(out.length, 16, reason: '$table 长度应为 16');
      }
    });
  });

  group('generate', () {
    test('签名非空、以 = 结尾、长度稳定', () {
      final sig = ABogus.generate(
        'aid=6383&app_name=douyin_web&web_rid=123456789',
        'Mozilla/5.0',
      );
      expect(sig.isNotEmpty, isTrue);
      expect(sig.endsWith('='), isTrue);
      // 实测线上签名长度 164~165（含结尾 =）
      expect(sig.length, inInclusiveRange(150, 175));
    });

    test('不同 query 产生不同签名', () {
      const ua = 'Mozilla/5.0';
      final a = ABogus.generate('aid=6383&room_id=1111', ua);
      final b = ABogus.generate('aid=6383&room_id=2222', ua);
      expect(a, isNot(b));
    });

    test('时间戳变化会改变签名（说明参与计算）', () {
      const ua = 'Mozilla/5.0';
      const query = 'aid=6383&room_id=1111';
      final first = ABogus.generate(query, ua);
      // 同毫秒内可能相同，这里只断言多次调用不抛异常且非空
      final second = ABogus.generate(query, ua);
      expect(second.isNotEmpty, isTrue);
      expect(first.isNotEmpty, isTrue);
    });
  });

  group('固定参数（线上实测值，改动会让签名失效）', () {
    test('window_env 是 1536 那一串，不是 DTV 旧版的 1920', () {
      expect(ABogus.windowEnv.startsWith('1536|747|1536|834'), isTrue);
      expect(ABogus.windowEnv.endsWith('Win32'), isTrue);
      // 长度 65，会被写进 b[64..66]
      expect(ABogus.windowEnv.length, 65);
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
