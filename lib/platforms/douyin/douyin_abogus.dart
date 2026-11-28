import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 抖音 a_bogus 签名（**移植自 DTV `internal/platforms/douyin/abogus.go`**，
/// 并用 Simple Live 内嵌的原始 JS 做逐字节对齐校验）。
///
/// 算法四段，顺序不能变：
/// ```
/// 1. SM3（国密哈希，不是 SHA-256）
/// 2. RC4
/// 3. 自定义 base64 变体（s0~s4 五张表）
/// 4. 44 项主表拼装（时间戳/参数/校验位）+ 再 RC4 + s4 编码
/// ```
///
/// ⚠️ 移植时踩过的 4 个坑（DTV 的 Go 版与线上 JS 有差异，已按下表校正）：
///
/// | 项 | DTV 的 Go 版 | 线上实际 |
/// |---|---|---|
/// | pageId | 110624 | **6241** |
/// | window_env | `1920\|1080\|…` | **`1536\|747\|…`** |
/// | end_time | start + 100 | **start**（同一次 now） |
/// | result_encrypt 末组 | 补 4 字符 | **只输出 3 字符** |
///
/// 最后一条只影响一个字符，但实测会导致签名整体被判无效。
class ABogus {
  const ABogus._();

  /// 窗口环境指纹（线上 JS 里的固定值）。
  static const String windowEnv =
      '1536|747|1536|834|0|30|0|0|1536|834|1536|864|1525|747|24|24|Win32';

  static const String _suffix = 'cus';
  static const List<int> _arguments = [0, 1, 14];

  /// 生成 a_bogus。返回值已含结尾的 `=`。
  ///
  /// [query] 是 URL 上除 a_bogus 外的完整参数串（**保持原始顺序**）。
  /// [userAgent] 必须与请求头一致，否则服务端校验不过。
  static String generate(String query, String userAgent) {
    final body = _generateRc4BbStr(query, userAgent);
    final combined = Uint8List.fromList([
      ..._generateRandomStr(),
      ...body,
    ]);
    return resultEncrypt(combined, 's4') + '=';
  }

  /* ------------------------------------------------------------ 自定义 base64 */

  static const Map<String, String> _encodeTables = {
    's0': 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=',
    's1': 'Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=',
    's2': 'Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=',
    's3': 'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe',
    's4': 'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe',
  };

  static const List<int> _encodeMasks = [16515072, 258048, 4032, 63];
  static const List<int> _encodeShifts = [18, 12, 6, 0];

  static int _getLongInt(int roundNum, Uint8List data) {
    final i = roundNum * 3;
    final b1 = i < data.length ? data[i] : 0;
    final b2 = i + 1 < data.length ? data[i + 1] : 0;
    final b3 = i + 2 < data.length ? data[i + 2] : 0;
    return (b1 << 16) | (b2 << 8) | b3;
  }

  /// 用指定表编码。
  ///
  /// 注意末组：不足 3 字节时只输出 3 个字符（结尾的 `=` 由调用方补），
  /// 与线上 JS 一致；DTV 的 Go 版这里写 +4 会多一个字符。
  static String resultEncrypt(Uint8List data, String table) {
    final t = _encodeTables[table]!;
    var totalChars = (data.length ~/ 3) * 4;
    if (data.length % 3 != 0) totalChars += 3;

    final buffer = StringBuffer();
    var roundNum = 0;
    var longInt = _getLongInt(0, data);
    for (var i = 0; i < totalChars; i++) {
      if (i ~/ 4 != roundNum) {
        roundNum++;
        longInt = _getLongInt(roundNum, data);
      }
      final idx = i % 4;
      final charIndex = (longInt & _encodeMasks[idx]) >> _encodeShifts[idx];
      buffer.write(t[charIndex]);
    }
    return buffer.toString();
  }

  /* ------------------------------------------------------------- 随机串 */

  static Uint8List _generRandom(int randomNum, int opt0, int opt1) {
    final byte1 = randomNum & 255;
    final byte2 = (randomNum >> 8) & 255;
    return Uint8List.fromList([
      (byte1 & 170) | (opt0 & 85),
      (byte1 & 85) | (opt0 & 170),
      (byte2 & 170) | (opt1 & 85),
      (byte2 & 85) | (opt1 & 170),
    ]);
  }

  /// 12 字节随机前缀。
  ///
  /// 线上 JS 用 `Math.random()*10000`；这里用真正的随机数即可
  /// （服务端不校验这一段，只影响输出不同但都有效）。
  static Uint8List _generateRandomStr() {
    final random = Random();
    int rnd() => (random.nextDouble() * 10000).toInt();
    final out = BytesBuilder();
    out.add(_generRandom(rnd(), 3, 45));
    out.add(_generRandom(rnd(), 1, 0));
    out.add(_generRandom(rnd(), 1, 5));
    return out.toBytes();
  }

  /* ------------------------------------------------------------- 主体拼装 */

  static List<int> _splitToBytes(int num) => [
        (num >> 24) & 255,
        (num >> 16) & 255,
        (num >> 8) & 255,
        num & 255,
      ];

  static int _byteAt(Uint8List data, int i) =>
      i < data.length ? data[i] : 0;

  static Uint8List _generateRc4BbStr(String query, String userAgent) {
    final startTime = DateTime.now().millisecondsSinceEpoch;

    // 三次加密：query+suffix 双 SM3、suffix 双 SM3、UA 经 RC4 再 s3 编码后 SM3
    final urlList = sm3Sum(sm3Sum(utf8.encode('$query$_suffix')));
    final cus = sm3Sum(sm3Sum(utf8.encode(_suffix)));
    final ua = sm3Sum(utf8.encode(
      resultEncrypt(rc4Encrypt(utf8.encode(userAgent), Uint8List.fromList([0, 1, 14])), 's3'),
    ));

    // 线上 JS 用第二次 Date.now()，同一次调用内与 start 相同；
    // DTV 的 Go 版写成 start+100，会导致 b[44..47] 与校验位不同。
    final endTime = startTime;

    final b = List<int>.filled(80, 0);
    b[8] = 3;
    b[10] = endTime;
    b[16] = startTime;
    b[18] = 44;

    final st = _splitToBytes(b[16]);
    b[20] = st[0];
    b[21] = st[1];
    b[22] = st[2];
    b[23] = st[3];
    b[24] = (b[16] ~/ 256 ~/ 256 ~/ 256 ~/ 256) & 255;
    b[25] = (b[16] ~/ 256 ~/ 256 ~/ 256 ~/ 256 ~/ 256) & 255;

    final a0 = _splitToBytes(_arguments[0]);
    b[26] = a0[0];
    b[27] = a0[1];
    b[28] = a0[2];
    b[29] = a0[3];

    b[30] = (_arguments[1] ~/ 256) & 255;
    b[31] = _arguments[1] % 256 & 255;
    final a1 = _splitToBytes(_arguments[1]);
    b[32] = a1[0];
    b[33] = a1[1];
    final a2 = _splitToBytes(_arguments[2]);
    b[34] = a2[0];
    b[35] = a2[1];
    b[36] = a2[2];
    b[37] = a2[3];

    b[38] = _byteAt(urlList, 21);
    b[39] = _byteAt(urlList, 22);
    b[40] = _byteAt(cus, 21);
    b[41] = _byteAt(cus, 22);
    b[42] = _byteAt(ua, 23);
    b[43] = _byteAt(ua, 24);

    final et = _splitToBytes(b[10]);
    b[44] = et[0];
    b[45] = et[1];
    b[46] = et[2];
    b[47] = et[3];
    b[48] = b[8];
    b[49] = (b[10] ~/ 256 ~/ 256 ~/ 256 ~/ 256) & 255;
    b[50] = (b[10] ~/ 256 ~/ 256 ~/ 256 ~/ 256 ~/ 256) & 255;

    const pageId = 6241;
    b[51] = pageId;
    final pid = _splitToBytes(pageId);
    b[52] = pid[0];
    b[53] = pid[1];
    b[54] = pid[2];
    b[55] = pid[3];

    const aid = 6383;
    b[56] = aid;
    b[57] = aid & 255;
    b[58] = (aid >> 8) & 255;
    b[59] = (aid >> 16) & 255;
    b[60] = (aid >> 24) & 255;

    final windowEnvBytes = utf8.encode(windowEnv);
    b[64] = windowEnvBytes.length;
    b[65] = windowEnvBytes.length & 255;
    b[66] = (windowEnvBytes.length >> 8) & 255;
    b[69] = 0;
    b[70] = 0;
    b[71] = 0;

    final checksum = b[18] ^
        b[20] ^
        b[26] ^
        b[30] ^
        b[38] ^
        b[40] ^
        b[42] ^
        b[21] ^
        b[27] ^
        b[31] ^
        b[35] ^
        b[39] ^
        b[41] ^
        b[43] ^
        b[22] ^
        b[28] ^
        b[32] ^
        b[36] ^
        b[23] ^
        b[29] ^
        b[33] ^
        b[37] ^
        b[44] ^
        b[45] ^
        b[46] ^
        b[47] ^
        b[48] ^
        b[49] ^
        b[50] ^
        b[24] ^
        b[25] ^
        b[52] ^
        b[53] ^
        b[54] ^
        b[55] ^
        b[57] ^
        b[58] ^
        b[59] ^
        b[60] ^
        b[65] ^
        b[66] ^
        b[70] ^
        b[71];
    b[72] = checksum;

    final bb = BytesBuilder();
    bb.add([
      b[18], b[20], b[52], b[26], b[30], b[34], b[58], b[38], b[40], b[53],
      b[42], b[21], b[27], b[54], b[55], b[31], b[35], b[57], b[39], b[41],
      b[43], b[22], b[28], b[32], b[60], b[36], b[23], b[29], b[33], b[37],
      b[44], b[45], b[59], b[46], b[47], b[48], b[49], b[50], b[24], b[25],
      b[65], b[66], b[70], b[71],
    ]);
    bb.add(windowEnvBytes);
    bb.addByte(checksum);

    // 最后用单字节密钥 'y' 再 RC4
    return rc4Encrypt(bb.toBytes(), Uint8List.fromList([121]));
  }
}

/* ==================================================================== SM3 */

const List<int> _sm3Iv = [
  0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
  0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
];

int _rotl32(int x, int n) {
  x &= 0xFFFFFFFF;
  n %= 32;
  if (n == 0) return x;
  return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
}

int _sm3Tj(int j) => j < 16 ? 0x79CC4519 : 0x7A879D8A;

int _sm3Ff(int j, int x, int y, int z) => j < 16
    ? (x ^ y ^ z) & 0xFFFFFFFF
    : ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;

int _sm3Gg(int j, int x, int y, int z) => j < 16
    ? (x ^ y ^ z) & 0xFFFFFFFF
    : ((x & y) | ((~x & 0xFFFFFFFF) & z)) & 0xFFFFFFFF;

void _sm3Compress(List<int> reg, List<int> block) {
  final w = List<int>.filled(132, 0);
  for (var t = 0; t < 16; t++) {
    final i = 4 * t;
    w[t] = (block[i] << 24) | (block[i + 1] << 16) | (block[i + 2] << 8) | block[i + 3];
  }
  for (var j = 16; j < 68; j++) {
    var a = w[j - 16] ^ w[j - 9] ^ _rotl32(w[j - 3], 15);
    a = a ^ _rotl32(a, 15) ^ _rotl32(a, 23);
    w[j] = a ^ _rotl32(w[j - 13], 7) ^ w[j - 6];
  }
  for (var j = 0; j < 64; j++) {
    w[j + 68] = w[j] ^ w[j + 4];
  }

  var a = reg[0], b = reg[1], c = reg[2], d = reg[3];
  var e = reg[4], f = reg[5], g = reg[6], h = reg[7];

  for (var j = 0; j < 64; j++) {
    final ss1 = _rotl32((_rotl32(a, 12) + e + _rotl32(_sm3Tj(j), j)) & 0xFFFFFFFF, 7);
    final ss2 = ss1 ^ _rotl32(a, 12);
    final tt1 = (_sm3Ff(j, a, b, c) + d + ss2 + w[j + 68]) & 0xFFFFFFFF;
    final tt2 = (_sm3Gg(j, e, f, g) + h + ss1 + w[j]) & 0xFFFFFFFF;

    d = c;
    c = _rotl32(b, 9);
    b = a;
    a = tt1;
    h = g;
    g = _rotl32(f, 19);
    f = e;
    e = tt2 ^ _rotl32(tt2, 9) ^ _rotl32(tt2, 17);
  }

  reg[0] ^= a;
  reg[1] ^= b;
  reg[2] ^= c;
  reg[3] ^= d;
  reg[4] ^= e;
  reg[5] ^= f;
  reg[6] ^= g;
  reg[7] ^= h;
}

/// 计算 SM3 摘要（32 字节）。
Uint8List sm3Sum(List<int> data) {
  final reg = List<int>.from(_sm3Iv);
  var offset = 0;

  while (data.length - offset >= 64) {
    _sm3Compress(reg, data.sublist(offset, offset + 64));
    offset += 64;
  }

  final buf = <int>[...data.sublist(offset)];
  buf.add(0x80);
  while (buf.length % 64 != 56) {
    buf.add(0);
  }
  final bitLength = data.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    buf.add((bitLength >> shift) & 255);
  }

  for (var i = 0; i < buf.length; i += 64) {
    _sm3Compress(reg, buf.sublist(i, i + 64));
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (reg[i] >> 24) & 255;
    out[i * 4 + 1] = (reg[i] >> 16) & 255;
    out[i * 4 + 2] = (reg[i] >> 8) & 255;
    out[i * 4 + 3] = reg[i] & 255;
  }
  return out;
}

/* ==================================================================== RC4 */

/// RC4 加密（明文与密钥都按字节处理）。
Uint8List rc4Encrypt(List<int> plaintext, List<int> key) {
  final s = List<int>.generate(256, (i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) % 256;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
  }

  var i = 0;
  j = 0;
  final out = Uint8List(plaintext.length);
  for (var k = 0; k < plaintext.length; k++) {
    i = (i + 1) % 256;
    j = (j + s[i]) % 256;
    final tmp = s[i];
    s[i] = s[j];
    s[j] = tmp;
    final t = (s[i] + s[j]) % 256;
    out[k] = plaintext[k] ^ s[t];
  }
  return out;
}
