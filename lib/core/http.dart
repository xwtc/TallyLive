import 'dart:convert';

import 'package:dio/dio.dart';

/// 各平台共用的 HTTP 层。
///
/// 移植自 TallyLive(Go) 的 internal/platforms/common/http.go，保留三个关键行为：
///   - 强制直连（不走系统代理）：斗鱼/虎牙走代理反而更容易被风控；
///   - 统一桌面 UA + Accept-Language：国内站点按 UA/语言返回不同内容；
///   - 瞬时错误重试一次：直播接口抖动很常见。
///
/// 与 Go 版的差异：Dart 侧没有 cookie jar，各平台自己维护 cookie 字符串
/// 并通过 headers 显式带上（B 站匿名用 `buvid3=i;` 占位即可）。
class LiveHttp {
  LiveHttp({
    this.timeout = const Duration(seconds: 45),
    Map<String, String>? defaultHeaders,
  }) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: timeout,
        // 关闭自动重定向之外的额外行为，保持与 Go 版一致。
        followRedirects: true,
        maxRedirects: 10,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    if (defaultHeaders != null) {
      _dio.options.headers.addAll(defaultHeaders);
    }
    // 忽略系统代理：Go 版显式设置 Proxy=nil。
    // Dio 默认不走系统代理（只有 HttpClient 的 findProxy 会），这里无需额外处理。
  }

  final Duration timeout;
  late final Dio _dio;

  static const String defaultUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
  static const String acceptLanguage = 'zh-CN,zh;q=0.9';

  Dio get dio => _dio;

  /// 发 GET 并返回文本。瞬时错误重试一次。
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _dio.get<String>(
          url,
          queryParameters: query,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              'User-Agent': defaultUA,
              'Accept-Language': acceptLanguage,
              if (headers != null) ...headers,
            },
          ),
        );
        final status = response.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          throw HttpStatusException(url, status, response.data ?? '');
        }
        return response.data ?? '';
      } catch (error) {
        lastError = error;
        if (attempt == 0 && _isTransient(error)) {
          await Future<void>.delayed(const Duration(milliseconds: 180));
          continue;
        }
        break;
      }
    }
    throw HttpRequestException(url, lastError);
  }

  /// 发 GET 并把 JSON 解码成 Map/List。
  Future<dynamic> getJson(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
  }) async {
    final text = await getText(url, headers: headers, query: query);
    try {
      return jsonDecode(text);
    } catch (error) {
      throw HttpDecodeException(url, text, error);
    }
  }

  /// 判断是否值得重试：超时、连接重置、握手失败等。
  static bool _isTransient(Object? error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.connectionError:
          return true;
        default:
          final message = (error.message ?? '').toLowerCase();
          return message.contains('connection reset') ||
              message.contains('handshake') ||
              message.contains('eof');
      }
    }
    return false;
  }
}

/// 拼 query 字符串（值会做 URL 编码）。移植自 Go 版 BuildQuery。
String buildQuery(String base, Map<String, String> params) {
  if (params.isEmpty) return base;
  final query = params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return base.contains('?') ? '$base&$query' : '$base?$query';
}

class HttpRequestException implements Exception {
  HttpRequestException(this.url, this.cause);
  final String url;
  final Object? cause;

  @override
  String toString() => '请求失败 ($url): $cause';
}

class HttpStatusException implements Exception {
  HttpStatusException(this.url, this.status, this.body);
  final String url;
  final int status;
  final String body;

  @override
  String toString() =>
      'GET $url 返回 HTTP $status: ${body.length > 200 ? body.substring(0, 200) : body}';
}

class HttpDecodeException implements Exception {
  HttpDecodeException(this.url, this.body, this.cause);
  final String url;
  final String body;
  final Object? cause;

  @override
  String toString() =>
      '解析 JSON 失败 ($url): $cause, body=${body.length > 200 ? body.substring(0, 200) : body}';
}
