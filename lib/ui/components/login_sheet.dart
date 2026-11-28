import 'package:flutter/material.dart';
import 'package:tallylive/core/account.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/ui/theme.dart';

/// 登录弹层（对齐 UI-DESIGN §4.4.1）。
///
/// 两个 tab：扫码 / 粘贴 Cookie。**Cookie 是必备能力**：
/// 扫码要求手机在手，桌面场景粘贴最快，而且与 DTV 的 `Set*Cookie` 接口天然对齐。
///
/// 本轮先做 Cookie 入口；扫码页留占位（需要扫码协议，见 DEV-NOTES §16）。
class LoginSheet extends StatefulWidget {
  const LoginSheet({super.key, required this.platform});

  final LivePlatform platform;

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  AccountProfile? _success;

  /// 各平台的必需字段（用于提示文案，不做强制校验）。
  String get _hint {
    switch (widget.platform) {
      case LivePlatform.bilibili:
        return 'SESSDATA=xxx; bili_jct=xxx; buvid3=xxx;\n'
            '（SESSDATA 必需；缺 buvid3 时部分接口会 412）';
      case LivePlatform.douyu:
        return 'acf_auth=xxx; acf_jwt_token=xxx;\n'
            '（两者必须成对，只带其一会被直接 403；或改用 dy_auth）';
      default:
        return '';
    }
  }

  String get _tips {
    switch (widget.platform) {
      case LivePlatform.bilibili:
        return '在浏览器登录 live.bilibili.com 后：\n'
            'F12 → Network → 任一请求 → Request Headers → Cookie';
      case LivePlatform.douyu:
        return '在浏览器登录 www.douyu.com 后：\n'
            'F12 → Network → 任一请求 → Request Headers → Cookie';
      default:
        return '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });

    if (widget.platform == LivePlatform.bilibili) {
      final profile = await CookieLogin.verifyBilibili(raw);
      if (!mounted) return;
      if (!profile.loggedIn) {
        setState(() {
          _busy = false;
          _error = 'Cookie 无效或已过期（nav 接口返回未登录）';
        });
        return;
      }
      AccountStore.instance.setCookie(widget.platform, raw);
      setState(() {
        _busy = false;
        _success = profile;
      });
    } else {
      // 斗鱼按 DTV 的做法只校验字段，不发网络请求
      final profile = CookieLogin.verifyDouyu(raw);
      if (!profile.loggedIn) {
        setState(() {
          _busy = false;
          _error = 'Cookie 里没有找到登录字段\n'
              '需要 acf_auth + acf_jwt_token 成对，或 dy_auth';
        });
        return;
      }
      AccountStore.instance.setCookie(widget.platform, raw);
      setState(() {
        _busy = false;
        _success = profile;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            TallySpace.lg, TallySpace.md, TallySpace.lg, TallySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${widget.platform.label}登录',
                    style: TallyType.pageTitle.copyWith(fontSize: 16)),
                const Spacer(),
                IconButton(
                  iconSize: 18,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close,
                      color: TallyColors.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: TallySpace.sm),
            if (_success != null)
              _buildSuccess(_success!)
            else ...[
              Text(_tips, style: TallyType.meta),
              const SizedBox(height: TallySpace.sm),
              TextField(
                controller: _controller,
                maxLines: 5,
                minLines: 3,
                style: TallyType.subtitle.copyWith(
                  color: TallyColors.textPrimary,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: _hint,
                  hintStyle: TallyType.meta.copyWith(fontSize: 11),
                  filled: true,
                  fillColor: TallyColors.inset,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(TallyRadius.card),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: TallySpace.sm),
              Row(
                children: [
                  const Icon(Icons.lock_outline,
                      size: 13, color: TallyColors.textTertiary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Cookie 等同于账号密码，仅保存在本机，不会上传',
                      style: TallyType.tiny,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: TallySpace.sm),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: TallyColors.tallyRed,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: TallySpace.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: TallyColors.signalBlue,
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('校验并保存'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess(AccountProfile profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle,
                size: 18, color: TallyColors.signalBlue),
            const SizedBox(width: TallySpace.sm),
            Text('登录成功',
                style: TallyType.subtitle.copyWith(
                  color: TallyColors.textPrimary,
                )),
          ],
        ),
        if (profile.userName.isNotEmpty) ...[
          const SizedBox(height: TallySpace.sm),
          Text(profile.userName, style: TallyType.nickname),
        ],
        const SizedBox(height: TallySpace.lg),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('完成'),
          ),
        ),
      ],
    );
  }
}
