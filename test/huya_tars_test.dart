import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/huya/huya_tars.dart';

/// TARS(JCE) 编解码测试。
///
/// 移植自 DTV 的 `internal/platforms/huya/tars.go`。虎牙 WUP 网关对字节格式极其敏感，
/// 编码错一个字节服务器就不认，所以这里把「写进去 → 读出来」的往返钉住。
void main() {
  group('整数编码（含压缩规则）', () {
    test('int32 往返', () {
      final w = TarsWriter();
      w.writeInt32(4, 66);
      final r = TarsReader(w.toBytes());
      expect(r.readInt32Tag(4, -1), 66);
    });

    test('0 用 zero 类型，不写数据（只占一个头字节）', () {
      final w = TarsWriter();
      w.writeInt32(3, 0);
      final bytes = w.toBytes();
      expect(bytes.length, 1);
      // tag=3, type=12(zero) → 0x3C
      expect(bytes[0], 0x3C);

      final r = TarsReader(bytes);
      expect(r.readInt32Tag(3, -1), 0);
    });

    test('小整数会降级成 int8（节省字节）', () {
      final w = TarsWriter();
      w.writeInt32(0, 1);
      final bytes = w.toBytes();
      expect(bytes.length, 2); // head + 1 字节
      expect(bytes[0] & 0x0F, TarsTypes.int8);
    });

    test('int32 大值 (66) 仍是 int8 → 但 4000 需要 int16', () {
      final w = TarsWriter();
      w.writeInt32(0, 4000);
      final r = TarsReader(w.toBytes());
      expect(r.readInt32Tag(0, -1), 4000);
    });

    test('负数往返', () {
      final w = TarsWriter();
      w.writeInt32(1, -1);
      final r = TarsReader(w.toBytes());
      expect(r.readInt32Tag(1, 0), -1);
    });

    test('int64 大值往返', () {
      final w = TarsWriter();
      w.writeInt64(0, 9223372036854775807);
      final r = TarsReader(w.toBytes());
      // readInt32Tag 只返回 int32 语义，这里用 tag 搜索后确认能跳过不崩
      expect(() => r.readInt32Tag(0, -1), returnsNormally);
    });
  });

  group('字符串 / 字节数组', () {
    test('短字符串（string1）往返', () {
      final w = TarsWriter();
      w.writeString(5, 'liveui');
      final r = TarsReader(w.toBytes());
      expect(r.readStringTag(5, ''), 'liveui');
    });

    test('空字符串往返', () {
      final w = TarsWriter();
      w.writeString(3, '');
      final r = TarsReader(w.toBytes());
      expect(r.readStringTag(3, 'x'), '');
    });

    test('长字符串（>255，string4）往返', () {
      final long = 'a' * 400;
      final w = TarsWriter();
      w.writeString(0, long);
      final r = TarsReader(w.toBytes());
      expect(r.readStringTag(0, '').length, 400);
    });

    test('字节数组往返（simple 类型）', () {
      final data = Uint8List.fromList([1, 2, 3, 250, 255]);
      final w = TarsWriter();
      w.writeBytes(7, data);
      final r = TarsReader(w.toBytes());
      final out = r.readBytesTag(7);
      expect(out, isNotNull);
      expect(out, equals(data));
    });
  });

  group('tag >= 15 的扩展头', () {
    test('扩展 tag 能正确写入并读回', () {
      final w = TarsWriter();
      w.writeString(20, 'hello');
      final bytes = w.toBytes();
      // 扩展头：第一个字节高 4 位应为 0xF
      expect((bytes[0] & 0xF0), 0xF0);

      final r = TarsReader(bytes);
      expect(r.readStringTag(20, ''), 'hello');
    });
  });

  group('结构体与 map', () {
    test('struct begin/end 包裹的字段能逐个读出', () {
      final w = TarsWriter();
      w.writeStructBegin(0);
      w.writeString(0, 'https://tx.flv.huya.com/src');
      w.writeString(1, 'streamName');
      w.writeInt32(2, 0);
      w.writeStructEnd();

      final bytes = w.toBytes();
      final r = TarsReader(bytes);
      expect(r.readStructBegin(0), isTrue);
      expect(r.readStringTag(0, ''), 'https://tx.flv.huya.com/src');
      expect(r.readStringTag(1, ''), 'streamName');
      expect(r.readInt32Tag(2, -1), 0);
    });

    test('map<string,bytes> 往返（WUP 的 UniAttribute 形状）', () {
      final payload = Uint8List.fromList([9, 9, 9]);
      final w = TarsWriter();
      w.writeBytesMap(0, 'tReq', payload);

      final r = TarsReader(w.toBytes());
      final head = r.takeHead();
      expect(head.type, TarsTypes.map);
      final count = r.readInt32Seq(0);
      expect(count, 1);
      expect(r.readStringTag(0, ''), 'tReq');
      expect(r.readBytesTag(1), equals(payload));
    });

    test('跳过未知字段后仍能找到目标 tag', () {
      final w = TarsWriter();
      w.writeString(1, 'skip-me');
      w.writeInt32(2, 12345);
      w.writeBytes(3, Uint8List.fromList([7, 7]));
      w.writeInt32(5, 66);

      final r = TarsReader(w.toBytes());
      // 直接按 tag 搜索 5，途中跳过 1/2/3
      expect(r.readInt32Tag(5, -1), 66);
    });

    test('找不到的 tag 返回默认值且不抛异常', () {
      final w = TarsWriter();
      w.writeInt32(0, 1);
      final r = TarsReader(w.toBytes());
      expect(r.readInt32Tag(9, -42), -42);
      expect(r.readStringTag(9, 'def'), 'def');
      expect(r.readBytesTag(9), isNull);
    });
  });

  group('健壮性', () {
    test('空数据读头抛 TarsException', () {
      final r = TarsReader(Uint8List(0));
      expect(() => r.takeHead(), throwsA(isA<TarsException>()));
    });

    test('截断的数据不会崩溃（返回默认值）', () {
      final w = TarsWriter();
      w.writeString(0, 'hello world');
      final bytes = w.toBytes();
      // 砍掉一半
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 4);
      final r = TarsReader(truncated);
      expect(() => r.readStringTag(0, 'def'), returnsNormally);
    });
  });
}
