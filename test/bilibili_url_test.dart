import 'package:flutter_test/flutter_test.dart';
import 'package:tallylive/platforms/bilibili/bilibili_client.dart';

void main() {
  group('joinUrl', () {
    test('host + base_url + extra 正确拼接（真实 B 站响应形状）', () {
      const host = 'https://d1--cn-gotcha104.bilivideo.com';
      const base = '/live-bvc/904361/live_7734200_bs_1348183_2500.m3u8';
      const extra = '?expires=1795797036&len=0&oi=3084399396&qn=250';

      final url = joinUrl(host, base, extra);

      expect(url, startsWith('https://d1--cn-gotcha104.bilivideo.com/live-bvc/'));
      expect(url, contains('.m3u8?expires='));
      // 回归保护：曾经把 host 和 base 拼反，导致 URL 以 "/" 开头、
      // media_kit 报 "Failed to open \live-bvc\...m3u8?https://..."
      expect(url.startsWith('/'), isFalse);
    });

    test('host 结尾带斜杠时不会出现双斜杠', () {
      final url = joinUrl('https://a.example.com/', '/path/x.m3u8', '');
      expect(url, 'https://a.example.com/path/x.m3u8');
    });

    test('base 已含 ? 且 extra 也以 ? 开头时用 & 连接', () {
      final url = joinUrl('https://h.example.com', '/a.m3u8?x=1', '?y=2');
      expect(url, 'https://h.example.com/a.m3u8?x=1&y=2');
    });

    test('base 不含 ? 且 extra 不带 ? 时补问号', () {
      final url = joinUrl('https://h.example.com', '/a.m3u8', 'y=2');
      expect(url, 'https://h.example.com/a.m3u8?y=2');
    });

    test('http 会被升级为 https', () {
      final url = joinUrl('http://h.example.com', '/a.m3u8', '');
      expect(url, 'https://h.example.com/a.m3u8');
    });

    test('缺 host 或 base 时返回空串', () {
      expect(joinUrl('', '/a.m3u8', '?x=1'), isEmpty);
      expect(joinUrl('https://h.example.com', '', '?x=1'), isEmpty);
    });
  });
}
