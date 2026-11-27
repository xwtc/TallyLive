import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/bilibili/bilibili_danmaku.dart';

/// B 站弹幕协议的编解码测试。
///
/// 这是最容易写错的部分：16 字节大端头、`ver=2` 表示 zlib 压缩的**再次分包**。
/// 协议解析错了会表现为「一条弹幕都不显示」，且没有报错，所以必须单测。
void main() {
  group('encodePacket', () {
    test('头部字段符合协议（大端）', () {
      final body = utf8.encode('{}');
      final packet = encodePacket(2, body);

      expect(packet.length, 16 + body.length);
      final view = ByteData.view(packet.buffer);
      expect(view.getUint32(0, Endian.big), packet.length); // pack_len
      expect(view.getUint16(4, Endian.big), 16); // header_len
      expect(view.getUint16(6, Endian.big), 1); // ver
      expect(view.getUint32(8, Endian.big), 2); // op = 心跳
      expect(view.getUint32(12, Endian.big), 1); // seq
    });

    test('body 原样写入', () {
      final body = utf8.encode('{"cmd":"DANMU_MSG"}');
      final packet = encodePacket(5, body);
      expect(utf8.decode(packet.sublist(16)), '{"cmd":"DANMU_MSG"}');
    });
  });

  group('decodePackets', () {
    test('明文帧（ver=1）能拆出一条报文', () {
      final body = utf8.encode('{"cmd":"DANMU_MSG"}');
      final packets = decodePackets(encodePacket(5, body), 0);

      expect(packets.length, 1);
      expect(packets.first.op, 5);
      expect(utf8.decode(packets.first.body), '{"cmd":"DANMU_MSG"}');
    });

    test('zlib 帧（ver=2）解压后再分包', () {
      // 先构造内层两条明文包，压缩，再套上 ver=2 的外层头。
      final inner = BytesBuilder();
      inner.add(encodePacket(5, utf8.encode('{"cmd":"A"}')));
      inner.add(encodePacket(5, utf8.encode('{"cmd":"B"}')));
      final compressed = Uint8List.fromList(
        ZLibEncoder().convert(inner.toBytes()),
      );

      final outer = encodePacket(5, compressed);
      // 把 ver 从 1 改成 2
      ByteData.view(outer.buffer).setUint16(6, 2, Endian.big);

      final packets = decodePackets(outer, 0);
      expect(packets.length, 2);
      expect(utf8.decode(packets[0].body), '{"cmd":"A"}');
      expect(utf8.decode(packets[1].body), '{"cmd":"B"}');
    });

    test('一帧里可以有多条明文包', () {
      final joined = BytesBuilder();
      joined.add(encodePacket(5, utf8.encode('{"cmd":"X"}')));
      joined.add(encodePacket(3, utf8.encode('{"popularity":1}')));

      final packets = decodePackets(joined.toBytes(), 0);
      expect(packets.length, 2);
      expect(packets[0].op, 5);
      expect(packets[1].op, 3);
    });

    test('包长度超出数据时安全退出，不抛异常', () {
      final broken = Uint8List(20);
      ByteData.view(broken.buffer).setUint32(0, 999, Endian.big); // 声称很长
      expect(decodePackets(broken, 0), isEmpty);
    });

    test('数据不足 16 字节时返回空', () {
      expect(decodePackets(Uint8List(8), 0), isEmpty);
    });

    test('嵌套过深时停止（防畸形数据打爆栈）', () {
      expect(decodePackets(Uint8List(0), 9), isEmpty);
    });
  });
}
