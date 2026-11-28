import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/bilibili/bilibili_danmaku.dart';

/// 分包解析的鲁棒性测试。
///
/// 背景：B 站把约 1 秒的弹幕压成一个帧，帧内是「16 字节头 + body」的重复结构。
/// DTV（Go 版）按 pack_len 逐包推进，遇到长度异常的包直接 break，
/// 把同一帧后面的弹幕全丢掉——这是「弹幕比官方少」的主要来源之一。
///
/// 我们的做法是**失步重同步**：长度不对时不放弃整帧，而是向后逐字节
/// 探测下一个合法包头继续解析。下面几个用例就是钉住这个行为。
void main() {
  Uint8List packet(int op, String json, {int ver = 1}) {
    final body = utf8.encode(json);
    final buffer = Uint8List(16 + body.length);
    final view = ByteData.view(buffer.buffer);
    view.setUint32(0, buffer.length, Endian.big);
    view.setUint16(4, 16, Endian.big);
    view.setUint16(6, ver, Endian.big);
    view.setUint32(8, op, Endian.big);
    view.setUint32(12, 1, Endian.big);
    buffer.setRange(16, buffer.length, body);
    return buffer;
  }

  List<String> bodies(List<DanmakuPacket> packets) => packets
      .map((p) => utf8.decode(p.body, allowMalformed: true))
      .where((s) => s.isNotEmpty)
      .toList();

  group('正常帧', () {
    test('顺序多个包全部解出', () {
      final joined = BytesBuilder();
      for (var i = 0; i < 5; i++) {
        joined.add(packet(5, '{"cmd":"DANMU_MSG","i":$i}'));
      }
      final packets = decodePackets(joined.toBytes(), 0);
      expect(bodies(packets).length, 5);
    });

    test('空 body 的包合法，且不截断后续（回归）', () {
      final joined = BytesBuilder();
      joined.add(packet(3, ''));
      joined.add(packet(5, '{"cmd":"AFTER_EMPTY"}'));

      final packets = decodePackets(joined.toBytes(), 0);
      expect(packets.length, 2);
      expect(packets[0].body, isEmpty);
      expect(bodies(packets), ['{"cmd":"AFTER_EMPTY"}']);
    });
  });

  group('失步重同步', () {
    test('头部长度被写坏时，后续包仍能被捞回', () {
      // 第一条的 pack_len 被改成 0（非法）。DTV 在这里就 break 了。
      final broken = Uint8List.fromList(packet(5, '{"cmd":"BROKEN"}'));
      ByteData.view(broken.buffer).setUint32(0, 0, Endian.big);

      final joined = BytesBuilder();
      joined.add(broken);
      joined.add(packet(5, '{"cmd":"RECOVERED_1"}'));
      joined.add(packet(5, '{"cmd":"RECOVERED_2"}'));

      final found = bodies(decodePackets(joined.toBytes(), 0));
      expect(found.where((s) => s.contains('RECOVERED_1')).length, 1);
      expect(found.where((s) => s.contains('RECOVERED_2')).length, 1);
    });

    test('中间夹一段垃圾字节时，能重新对齐', () {
      final joined = BytesBuilder();
      joined.add(packet(5, '{"cmd":"BEFORE"}'));
      // 一段随机垃圾（不含合法头）
      joined.add(Uint8List.fromList(List<int>.filled(20, 0xFF)));
      joined.add(packet(5, '{"cmd":"AFTER_GARBAGE"}'));

      final found = bodies(decodePackets(joined.toBytes(), 0));
      expect(found, contains('{"cmd":"BEFORE"}'));
      expect(found, contains('{"cmd":"AFTER_GARBAGE"}'));
    });
  });

  group('边界', () {
    test('数据不足 16 字节返回空', () {
      expect(decodePackets(Uint8List(8), 0), isEmpty);
    });

    test('嵌套过深直接返回空（防畸形数据打爆栈）', () {
      expect(decodePackets(Uint8List(0), 9), isEmpty);
    });

    test('整帧垃圾不会抛异常', () {
      final junk = Uint8List.fromList(List<int>.generate(64, (i) => i + 1));
      expect(() => decodePackets(junk, 0), returnsNormally);
    });
  });
}
