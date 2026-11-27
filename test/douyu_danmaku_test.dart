import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/douyu/douyu_danmaku.dart';

/// 斗鱼 STT 协议测试。
///
/// 斗鱼弹幕是**明文 TCP + 私有 STT 包**，长度字段是小端、且不含自身 4 字节，
/// 写错就整包错位（表现为一条弹幕都收不到），所以必须单测。
void main() {
  group('encodeStt', () {
    test('长度字段 = 消息字节数 + 9，且重复两次（小端）', () {
      const message = 'type@=mrkl/';
      final packet = encodeStt(message);
      final messageLength = utf8.encode(message).length;
      final declared = messageLength + 9;

      expect(packet.length, 4 + declared);

      final view = ByteData.view(packet.buffer);
      expect(view.getUint32(0, Endian.little), declared);
      expect(view.getUint32(4, Endian.little), declared);
      expect(view.getUint16(8, Endian.little), 689);
      expect(packet[10], 0);
      expect(packet[11], 0);
    });

    test('消息体位于 [12, len-1)，尾部补 \\0', () {
      const message = 'type@=loginreq/roomid@=9999/';
      final packet = encodeStt(message);

      expect(utf8.decode(packet.sublist(12, packet.length - 1)), message);
      expect(packet.last, 0);
    });
  });

  group('parseStt', () {
    test('解析 key@=value/ 形式', () {
      final fields = parseStt('type@=chatmsg/nn@=主播/txt@=你好/');
      expect(fields['type'], 'chatmsg');
      expect(fields['nn'], '主播');
      expect(fields['txt'], '你好');
    });

    test('@S 还原成 /，@A 还原成 @', () {
      final fields = parseStt('txt@=a@Sb@Ac/');
      expect(fields['txt'], 'a/b@c');
    });

    test('空段被忽略，缺少 @= 的段被跳过', () {
      final fields = parseStt('/type@=chatmsg//garbage/');
      expect(fields['type'], 'chatmsg');
      expect(fields.containsKey('garbage'), isFalse);
    });

    test('值里含等号也能正确切分（只在第一个 @= 处切）', () {
      final fields = parseStt('txt@=a=b=c/');
      expect(fields['txt'], 'a=b=c');
    });
  });

  group('colorFromDouyuCol', () {
    test('调色板索引映射到官方颜色', () {
      expect(colorFromDouyuCol('1'), '#FF2E2E');
      expect(colorFromDouyuCol('2'), '#00CCFF');
      expect(colorFromDouyuCol('7'), '#FF84F6');
    });

    test('空 / 0 / 非数字返回空串（用默认色，绝不返回黑色）', () {
      expect(colorFromDouyuCol(null), '');
      expect(colorFromDouyuCol(''), '');
      expect(colorFromDouyuCol('0'), '');
      expect(colorFromDouyuCol('abc'), '');
    });

    test('超出调色板的六位数值按十进制 RGB 兜底', () {
      expect(colorFromDouyuCol('16711680'), '#FF0000'); // 0xFF0000
    });

    test('超出调色板但小于 0x10000 的索引返回空串', () {
      expect(colorFromDouyuCol('8'), '');
      expect(colorFromDouyuCol('99'), '');
    });
  });

  group('整包往返', () {
    test('编码后的包按协议切出来的 body 与原文一致', () {
      const message = 'type@=chatmsg/nn@=用户/txt@=测试弹幕/col@=4/';
      final packet = encodeStt(message);

      // 模拟服务端切包逻辑：读前 4 字节长度，整包 = 长度 + 4
      final declared = ByteData.view(packet.buffer).getUint32(0, Endian.little);
      final total = 4 + declared;
      expect(total, packet.length);

      // body = [12, total-1)
      final body = utf8.decode(
        Uint8List.fromList(packet.sublist(12, total - 1)),
      );
      expect(body, message);
      expect(parseStt(body)['txt'], '测试弹幕');
    });
  });
}
