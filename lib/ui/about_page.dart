import 'package:flutter/material.dart';
import 'package:tallylive/core/danmaku_stats.dart';
import 'package:tallylive/ui/debug_page.dart';
import 'package:tallylive/ui/theme.dart';

/// 「关于」Tab。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: TallyColors.raised,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TallyColors.hairline),
                ),
                child: const Center(
                  child: Text(
                    'T',
                    style: TextStyle(
                      color: TallyColors.tallyRed,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TallyLive · 在播',
                    style: TextStyle(
                      color: TallyColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '直播聚合客户端',
                    style: TextStyle(
                      color: TallyColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _Card(
            children: [
              _KV('技术栈', 'Flutter + media_kit（libmpv）'),
              _KV('支持平台', 'Windows / iOS / Android'),
              _KV('已接入', 'bilibili、斗鱼'),
              _KV('待接入', '虎牙、抖音'),
            ],
          ),
          const SizedBox(height: 16),
          const _Card(
            children: [
              _KV('说明', '仅供学习编程使用，未进行逆向工程。'),
              _KV('版权', '所有直播版权归各平台所有。'),
            ],
          ),
          const SizedBox(height: 16),
          const _Card(
            children: [
              _KV('架构来源', '参考 DTV（Wails）与 Simple Live 的思路'),
              _KV('播放内核', 'libmpv，视频与弹幕同一合成器'),
            ],
          ),
          const SizedBox(height: 24),
          // 调试入口：仅在非 release 构建出现（kReleaseMode 会整段剔除）
          if (kDiagnosticsEnabled)
            _Card(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.build_outlined,
                      size: 18, color: TallyColors.textSecondary),
                  title: const Text(
                    '调试页（选平台 + 输房间号）',
                    style: TextStyle(
                      color: TallyColors.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: const Text(
                    '排障用；正式版不显示',
                    style: TextStyle(
                      color: TallyColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      size: 18, color: TallyColors.textTertiary),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DebugPage(),
                      ),
                    );
                  },
                ),
              ],
            ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'v0.1.0',
              style: TextStyle(color: TallyColors.textTertiary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: TallyColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TallyColors.hairline),
      ),
      child: Column(children: children),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.key_, this.value);

  final String key_;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              key_,
              style: const TextStyle(
                color: TallyColors.textTertiary,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: TallyColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
