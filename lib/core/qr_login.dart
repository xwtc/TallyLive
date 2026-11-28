import 'dart:convert';

import 'package:tallylive/core/http.dart';
import 'package:tallylive/core/models.dart';

/// 扫码登录的二维码内容。
class QrLoginCode {
  const QrLoginCode({
    required this.url,
    required this.key,
    required this.expiresIn,
  });

  /// 二维码里真正要编码的字符串。
  final String url;

  /// 只用于轮询状态，不要展示给用户。
  final String key;
  final int expiresIn;
}

/// 扫码状态。
enum QrLoginStatus {
  pending('等待手机扫码'),
  scanned('已扫码，请在手机上确认'),
  expired('二维码已失效，请刷新'),
  success('登录成功'),
  error('登录失败');

  const QrLoginStatus(this.label);
  final String label;
}

class QrLoginResult {
  const QrLoginResult({required this.status, this.message = '', this.cookie = ''});

  final QrLoginStatus status;
  final String message;

  /// 仅 success 时有值（格式与浏览器 Cookie 头一致）。
  final String cookie;
}

/// 斗鱼扫码登录。
///
/// **移植自 DTV `internal/platforms/douyu/qrlogin.go`**：
/// ```
/// 1. POST https://passport.douyu.com/scan/generateCode
///      form: client_id=1, isMultiAccount=0
///      → data.code（轮询用 key）+ data.url（二维码内容）
/// 2. GET  https://passport.douyu.com/japi/scan/auth?time=<ms>&code=<key>
///      error:  0=已确认  1=已扫码  -2=等待  -1=失效
/// 3. 确认后 data.url 是登录回调地址，GET 一次收集 Set-Cookie
/// ```
class DouyuQrLogin {
  DouyuQrLogin({LiveHttp? http}) : _http = http ?? LiveHttp();

  final LiveHttp _http;

  Map<String, String> get _headers => {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36',
        'Referer': 'https://www.douyu.com/',
        'Origin': 'https://www.douyu.com',
      };

  /// 申请二维码。
  Future<QrLoginCode> generate() async {
    final raw = await _http.postForm(
      'https://passport.douyu.com/scan/generateCode',
      <String, String>{'client_id': '1', 'isMultiAccount': '0'},
      headers: _headers,
    );
    final decoded = jsonDecode(raw);
    final json = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};