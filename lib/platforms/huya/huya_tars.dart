import 'dart:convert';
import 'dart:typed_data';

/// TARS(JCE) 编解码子集。
///
/// **1:1 移植自 DTV 的 `internal/platforms/huya/tars.go`**，编码规则必须完全一致，
/// 否则虎牙 WUP 网关不认。
///
/// 类型编号（注意与常见 JCE 文档不同，以 DTV 实际实现为准）：
/// ```
/// 0 int8, 1 int16, 2 int32, 3 int64, 4 float, 5 double,
/// 6 string1(1字节长度), 7 string4(4字节长度), 8 map, 9 list,
/// 10 struct 开始, 11 struct 结束, 12 zero, 13 字节数组
/// ```
/// 头部：`tag < 15` → `(tag<<4)|type` 一个字节；否则 `(0xF0|type)` + tag 字节。
/// 整数压缩：能塞进更小的类型就用更小的；0 直接用 zero 类型、不写数据。
/// 字节数组：head(simple) + head(0, int8) + int32(0, 长度) + 数据。
class TarsTypes {
  const TarsTypes._();

  static const int int8 = 0;
  static const int int16 = 1;
  static const int int32 = 2;
  static const int int64 = 3;
  static const int float32 = 4;
  static const int float64 = 5;
  static const int string1 = 6;
  static const int string4 = 7;
  static const int map = 8;
  static const int list = 9;
  static const int structBegin = 10;
  static const int structEnd = 11;
  static const int zero = 12;
  static const int simple = 13;
}

/// TARS 编码器。
class TarsWriter {
  final BytesBuilder _buf = BytesBuilder();

  Uint8List toBytes() => _buf.toBytes();

  void _putHead(int tag, int type) {
    if (tag < 15) {
      _buf.addByte((tag << 4) | type);
    } else {
      _buf.addByte(0xF0 | type);
      _buf.addByte(tag);
    }
  }

  void writeInt8(int tag, int value) {
    if (value == 0) {
      _putHead(tag, TarsTypes.zero);
      return;
    }
    _putHead(tag, TarsTypes.int8);
    _buf.addByte(value & 0xFF);
  }

  void writeInt16(int tag, int value) {
    if (value >= -128 && value <= 127) {
      writeInt8(tag, value);
      return;
    }
    _putHead(tag, TarsTypes.int16);
    _buf.addByte((value >> 8) & 0xFF);
    _buf.addByte(value & 0xFF);
  }

  void writeInt32(int tag, int value) {
    if (value >= -32768 && value <= 32767) {
      writeInt16(tag, value);
      return;
    }
    _putHead(tag, TarsTypes.int32);
    _buf.addByte((value >> 24) & 0xFF);
    _buf.addByte((value >> 16) & 0xFF);
    _buf.addByte((value >> 8) & 0xFF);
    _buf.addByte(value & 0xFF);
  }

  void writeInt64(int tag, int value) {
    if (value >= -2147483648 && value <= 2147483647) {
      writeInt32(tag, value);
      return;
    }
    _putHead(tag, TarsTypes.int64);
    for (var shift = 56; shift >= 0; shift -= 8) {
      _buf.addByte((value >> shift) & 0xFF);
    }
  }

  void writeString(int tag, String value) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    if (bytes.length <= 255) {
      _putHead(tag, TarsTypes.string1);
      _buf.addByte(bytes.length);
      _buf.add(bytes);
      return;
    }
    _putHead(tag, TarsTypes.string4);
    _buf.addByte((bytes.length >> 24) & 0xFF);
    _buf.addByte((bytes.length >> 16) & 0xFF);
    _buf.addByte((bytes.length >> 8) & 0xFF);
    _buf.addByte(bytes.length & 0xFF);
    _buf.add(bytes);
  }

  /// 字节数组：head(simple) + 元素类型头 + 长度 + 数据。
  void writeBytes(int tag, List<int> data) {
    _putHead(tag, TarsTypes.simple);
    _putHead(0, TarsTypes.int8);
    writeInt32(0, data.length);
    _buf.add(data);
  }

  void writeEmptyMap(int tag) {
    _putHead(tag, TarsTypes.map);
    writeInt32(0, 0);
  }

  /// `map<string, bytes>`，只有一个键值对（WUP 的 UniAttribute 就是这种）。
  void writeBytesMap(int tag, String key, List<int> value) {
    _putHead(tag, TarsTypes.map);
    writeInt32(0, 1);
    writeString(0, key);
    writeBytes(1, value);
  }

  void writeStructBegin(int tag) => _putHead(tag, TarsTypes.structBegin);

  void writeStructEnd() => _putHead(0, TarsTypes.structEnd);
}

class TarsHead {
  const TarsHead(this.tag, this.type);
  final int tag;
  final int type;
}

/// TARS 解码器。
class TarsReader {
  TarsReader(this.buf);

  final Uint8List buf;
  int pos = 0;

  /// 最近一次整数读取的值，供跳过字节数组时复用长度。
  int lastSize = 0;

  int get length => buf.length;
  bool get atEnd => pos >= buf.length;

  TarsHead takeHead() {
    if (pos >= buf.length) {
      throw const TarsException('数据不足');
    }
    final b = buf[pos++];
    var tag = (b & 0xF0) >> 4;
    final type = b & 0x0F;
    if (tag == 15) {
      if (pos >= buf.length) {
        throw const TarsException('扩展 tag 数据不足');
      }
      tag = buf[pos++];
    }
    return TarsHead(tag, type);
  }

  /// 从当前位置向后找 tag 匹配的字段，途中跳过其它字段；找不到回到起点。
  TarsHead? find(int tag) {
    final start = pos;
    while (pos < buf.length) {
      final head = takeHead();
      if (head.tag == tag && head.type != TarsTypes.structEnd) {
        return head;
      }
      if (!_skipField(head.type)) break;
    }
    pos = start;
    return null;
  }

  /// 跳过当前字段（供外部遍历结构体用）。`r`n  bool skipField(int type) => _skipField(type);`r`n`r`n  bool _skipField(int type) {
    bool advance(int n) {
      if (pos + n > buf.length) return false;
      pos += n;
      return true;
    }

    switch (type) {
      case TarsTypes.int8:
        return advance(1);
      case TarsTypes.int16:
        return advance(2);
      case TarsTypes.int32:
      case TarsTypes.float32:
        return advance(4);
      case TarsTypes.int64:
      case TarsTypes.float64:
        return advance(8);
      case TarsTypes.zero:
      case TarsTypes.structEnd:
        return true;
      case TarsTypes.string1:
        if (pos >= buf.length) return false;
        final size = buf[pos++];
        return advance(size);
      case TarsTypes.string4:
        if (pos + 4 > buf.length) return false;
        final size = (buf[pos] << 24) |
            (buf[pos + 1] << 16) |
            (buf[pos + 2] << 8) |
            buf[pos + 3];
        pos += 4;
        return advance(size);
      case TarsTypes.simple:
        takeHead(); // 元素类型
        readInt32Seq(0);
        return advance(lastSize);
      case TarsTypes.map:
        final count = readInt32Seq(0);
        for (var i = 0; i < count * 2; i++) {
          final head = takeHead();
          if (!_skipField(head.type)) return false;
        }
        return true;
      case TarsTypes.list:
        final count = readInt32Seq(0);
        for (var i = 0; i < count; i++) {
          final head = takeHead();
          if (!_skipField(head.type)) return false;
        }
        return true;
      case TarsTypes.structBegin:
        while (pos < buf.length) {
          final head = takeHead();
          if (head.type == TarsTypes.structEnd) return true;
          if (!_skipField(head.type)) return false;
        }
        return false;
      default:
        return false;
    }
  }

  /// 顺序读取（不做 tag 搜索），用于 map/list 的计数。
  int readInt32Seq(int tag) {
    final head = takeHead();
    if (head.tag != tag) {
      pos--;
      return 0;
    }
    return _intFromHead(head, 0);
  }

  int _intFromHead(TarsHead head, int def) {
    int value;
    switch (head.type) {
      case TarsTypes.zero:
        return 0;
      case TarsTypes.int8:
        if (pos + 1 > buf.length) return def;
        value = buf[pos] >= 128 ? buf[pos] - 256 : buf[pos];
        pos += 1;
        break;
      case TarsTypes.int16:
        if (pos + 2 > buf.length) return def;
        value = (buf[pos] << 8) | buf[pos + 1];
        if (value >= 0x8000) value -= 0x10000;
        pos += 2;
        break;
      case TarsTypes.int32:
        if (pos + 4 > buf.length) return def;
        value = (buf[pos] << 24) |
            (buf[pos + 1] << 16) |
            (buf[pos + 2] << 8) |
            buf[pos + 3];
        if (value >= 0x80000000) value -= 0x100000000;
        pos += 4;
        break;
      case TarsTypes.int64:
        if (pos + 8 > buf.length) return def;
        value = 0;
        for (var i = 0; i < 8; i++) {
          value = (value << 8) | buf[pos + i];
        }
        pos += 8;
        break;
      default:
        return def;
    }
    lastSize = value;
    return value;
  }

  int readInt32Tag(int tag, int def) {
    final head = find(tag);
    if (head == null) return def;
    return _intFromHead(head, def);
  }

  String readStringTag(int tag, String def) {
    final head = find(tag);
    if (head == null) return def;
    switch (head.type) {
      case TarsTypes.zero:
        return def;
      case TarsTypes.string1:
        if (pos + 1 > buf.length) return def;
        final size = buf[pos++];
        if (pos + size > buf.length) return def;
        final text = utf8.decode(buf.sublist(pos, pos + size), allowMalformed: true);
        pos += size;
        return text;
      case TarsTypes.string4:
        if (pos + 4 > buf.length) return def;
        final size = (buf[pos] << 24) |
            (buf[pos + 1] << 16) |
            (buf[pos + 2] << 8) |
            buf[pos + 3];
        pos += 4;
        if (pos + size > buf.length) return def;
        final text = utf8.decode(buf.sublist(pos, pos + size), allowMalformed: true);
        pos += size;
        return text;
      default:
        return def;
    }
  }

  Uint8List? readBytesTag(int tag) {
    final head = find(tag);
    if (head == null) return null;
    if (head.type != TarsTypes.simple) return null;
    takeHead(); // 元素类型头，忽略
    final size = readInt32Seq(0);
    if (size < 0 || pos + size > buf.length) return null;
    final out = Uint8List.sublistView(buf, pos, pos + size);
    pos += size;
    return out;
  }

  /// 定位结构体起点（tag 匹配且类型为 struct 开始）。
  bool readStructBegin(int tag) {
    final head = find(tag);
    return head != null && head.type == TarsTypes.structBegin;
  }
}

class TarsException implements Exception {
  const TarsException(this.message);
  final String message;

  @override
  String toString() => 'TARS: $message';
}
