import 'dart:convert';
import 'dart:typed_data';

/// 极简 protobuf 编解码。
///
/// 抖音弹幕只用到一个很小的子集（varint / length-delimited），
/// 为这几个字段引入 `protobuf` 包 + protoc 代码生成不划算，
/// 所以这里手写：既能精确控制字节，也不增加构建步骤。
///
/// 字段编号与类型对照 `_refs/DouyinLiveWebFetcher/protobuf/douyin.proto`
/// 与 DTV `internal/platforms/douyin/pb.go`。
class ProtoReader {
  ProtoReader(this.buf, [this.pos = 0, int? end]) : end = end ?? buf.length;

  final Uint8List buf;
  int pos;
  final int end;

  bool get hasMore => pos < end;

  /// 读一个 varint（protobuf 的 base-128 变长整数）。
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (pos < end) {
      final byte = buf[pos++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) break;
    }
    return result;
  }

  /// 读下一个字段头，返回 (fieldNumber, wireType)。
  ({int field, int wire}) readTag() {
    final tag = readVarint();
    return (field: tag >> 3, wire: tag & 0x07);
  }

  /// 读 length-delimited（bytes / string / 嵌套 message）。
  Uint8List readBytes() {
    final length = readVarint();
    final next = pos + length;
    if (next > end) {
      pos = end;
      return Uint8List(0);
    }
    final out = Uint8List.sublistView(buf, pos, next);
    pos = next;
    return out;
  }

  /// 读 UTF-8 字符串。
  ///
  /// ⚠️ 不能用 String.fromCharCodes：那会把每个字节当成一个码点，
  /// 中文（UTF-8 三字节）会变成三个乱码字符 —— 抖音弹幕乱码就是这么来的。
  String readString() => utf8.decode(readBytes(), allowMalformed: true);

  /// 跳过当前字段（用于忽略不关心的字段）。
  void skip(int wire) {
    switch (wire) {
      case 0:
        readVarint();
        break;
      case 1:
        pos += 8;
        break;
      case 2:
        readBytes();
        break;
      case 5:
        pos += 4;
        break;
      default:
        pos = end;
    }
  }

  /// 遍历所有字段，回调 (field, wire)。
  /// 回调返回 true 表示"我自己消费了值"，否则自动 skip。
  void forEachField(bool Function(int field, int wire) handler) {
    while (hasMore) {
      final tag = readTag();
      final consumed = handler(tag.field, tag.wire);
      if (!consumed) skip(tag.wire);
    }
  }
}

/// protobuf 编码器。
class ProtoWriter {
  final BytesBuilder _buf = BytesBuilder();

  Uint8List toBytes() => _buf.toBytes();

  void _varint(int value) {
    var v = value;
    while (v > 0x7F) {
      _buf.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.addByte(v & 0x7F);
  }

  void writeVarintField(int field, int value) {
    if (value == 0) return; // proto3 默认值不写
    _varint((field << 3) | 0);
    _varint(value);
  }

  void writeBytesField(int field, List<int> value) {
    if (value.isEmpty) return;
    _varint((field << 3) | 2);
    _varint(value.length);
    _buf.add(value);
  }

  void writeStringField(int field, String value) {
    if (value.isEmpty) return;
    // 同样必须用 UTF-8 编码（codeUnits 对中文会写错）
    writeBytesField(field, utf8.encode(value));
  }
}
