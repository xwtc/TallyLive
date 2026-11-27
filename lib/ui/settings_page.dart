import 'package:flutter/material.dart';
import 'package:tallylive/core/settings.dart';
import 'package:tallylive/ui/theme.dart';

/// 「设置」Tab：弹幕与本地数据。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const _SectionTitle('弹幕'),
              SwitchListTile(
                title: const Text('显示弹幕'),
                subtitle: const Text('关闭后视频画面不受影响'),
                value: settings.danmakuEnabled,
                onChanged: settings.setDanmakuEnabled,
              ),
              _SliderTile(
                label: '字号',
                value: settings.danmakuFontSize,
                min: 12,
                max: 32,
                divisions: 20,
                suffix: '${settings.danmakuFontSize.round()}',
                onChanged: settings.setDanmakuFontSize,
              ),
              _SliderTile(
                label: '不透明度',
                value: settings.danmakuOpacity,
                min: 0.3,
                max: 1.0,
                divisions: 14,
                suffix: '${(settings.danmakuOpacity * 100).round()}%',
                onChanged: settings.setDanmakuOpacity,
              ),
              _SliderTile(
                label: '存活时间',
                value: settings.danmakuDuration,
                min: 4,
                max: 16,
                divisions: 12,
                suffix: '${settings.danmakuDuration.round()}s',
                onChanged: settings.setDanmakuDuration,
              ),
              _SliderTile(
                label: '显示区域',
                value: settings.danmakuArea,
                min: 0.2,
                max: 1.0,
                divisions: 8,
                suffix: '${(settings.danmakuArea * 100).round()}%',
                onChanged: settings.setDanmakuArea,
              ),
              const Divider(height: 32),
              const _SectionTitle('本地数据'),
              ListTile(
                title: const Text('清空最近打开'),
                subtitle: Text('${settings.recentRooms.length} 条记录'),
                trailing: const Icon(Icons.delete_outline, size: 20),
                onTap: settings.recentRooms.isEmpty
                    ? null
                    : () async {
                        await settings.clearRecentRooms();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清空')),
                        );
                      },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: TallyColors.signalBlue,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(color: TallyColors.textPrimary, fontSize: 14),
              ),
              const Spacer(),
              Text(
                suffix,
                style: const TextStyle(
                  color: TallyColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
