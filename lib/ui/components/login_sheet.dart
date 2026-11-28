import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tallylive/core/account.dart';
import 'package:tallylive/core/models.dart';
import 'package:tallylive/core/qr_login.dart';
import 'package:tallylive/ui/theme.dart';

/// 登录弹层（对齐 DTV 的扫码登录弹窗 + UI-DESIGN §4.4.1）。
///
/// 结构（按需求调整）：
/// - **默认显示二维码**，下方状态文案（等待扫码 / 已扫码 / 已失效 / 成功）
/// - 底部一行「使用 Cookie 登录」→ 切换到粘贴框
/// - Cookie 入口是必备能力（桌面场景粘贴最快，且与 DTV 的 Set*Cookie 对齐）
///
/// 只支持 B站 / 斗鱼：其它平台没有登录体系。
class LoginSheet extends StatefulWidget {
  const LoginSheet({super.key, required this.platform});

  final LivePlatform platform;

  @override
  State<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<LoginSheet> {
  /// 当前模式：扫码（默认）/ 粘贴 Cookie
  bool _cookieMode = false;

  // 扫码状态
  QrLoginCode? _code;
  String _status = '正在获取二维码…';
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  Timer? _expireTimer;

  // Cookie 模式状态
  final TextEditingController _controller = TextEditingController();
  bool _verifying = false;
  String? _cookieError;
  AccountProfile? _success;

  bool get _isBilibili => widget.platform == LivePlatform.bilibili;

  @override
  void initState() {
    super.initState();
    _startQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _expireTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /* ------------------------------------------------------------------ 扫码 */

  Future<void> _startQr() async {
    _pollTimer?.cancel();
    _expireTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _status = '正在获取二维码…';
      _code = null;
    });
    try {
      final code = _isBilibili
          ? await BilibiliQrLogin().generate()
          : await DouyuQrLogin().generate();
      if (!mounted) return;
      setState(() {
        _code = code;
        _loading = false;
        _status = '等待手机扫码';
      });
      // 2 秒轮询一次
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
      // 到有效期后标记失效（不主动取消轮询，服务端也会返回 expired）
      _expireTimer = Timer(Duration(seconds: code.expiresIn), () {
        if (!mounted) return;
        setState(() => _status = '二维码已失效，点击刷新');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _poll() async {
    final code = _code;
    if (code == null || !mounted) return;
    try {
      final result = _isBilibili
          ? await BilibiliQrLogin().poll(code.key)
          : await DouyuQrLogin().poll(code.key);
      if (!mounted) return;

      if (result.status == QrLoginStatus.success) {
        _pollTimer?.cancel();
        // 扫码成功后**先校验登录态再落盘**：拿到 Set-Cookie 不等于真登录
        // （偶尔会缺 SESSDATA），直接把无效 Cookie 存下来会让用户以为已登录。
        var userName = '';
        if (_isBilibili) {
          final check = await BilibiliQrLogin().verify(result.cookie);
          if (!mounted) return;
          if (!check.loggedIn) {
            setState(() {
              _status = '扫码通过但登录态无效，请重试';
              _loading = false;
            });
            _startQr();
            return;
          }
          userName = check.userName;
        }
        if (!mounted) return;
        await AccountStore.instance.setCookie(
          widget.platform,
          result.cookie,
          userName: userName,
        );
        if (!mounted) return;
        setState(() {
          _status = '登录成功';
          _success = AccountProfile(loggedIn: true, userName: userName);
        });
        return;
      }
      setState(() => _status = result.message.isEmpty
          ? result.status.label
          : result.message);
      if (result.status == QrLoginStatus.expired) {
        _pollTimer?.cancel();
      }
    } catch (_) {
      // 单次轮询失败不打断（网络抖动很常见）
    }
  }

  /* ------------------------------------------------------------- Cookie */

  Future<void> _submitCookie() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) return;
    setState(() {
      _verifying = true;
      _cookieError = null;
    });

    if (_isBilibili) {
      final profile = await CookieLogin.verifyBilibili(raw);
      if (!mounted) return;
      if (!profile.loggedIn) {
        setState(() {
          _verifying = false;
          _cookieError = 'Cookie 无效或已过期（nav 接口返回未登录）';
        });
        return;
      }
      await AccountStore.instance.setCookie(widget.platform, raw, userName: profile.userName);
      setState(() {
        _verifying = false;
        _success = profile;
      });
    } else {
      final profile = CookieLogin.verifyDouyu(raw);
      if (!mounted) return;
      if (!profile.loggedIn) {
        setState(() {
          _verifying = false;
          _cookieError = 'Cookie 里没有找到登录字段\n'
              '需要 acf_auth + acf_jwt_token 成对，或 dy_auth';
        });
        return;
      }
      await AccountStore.instance.setCookie(widget.platform, raw, userName: profile.userName);
      setState(() {
        _verifying = false;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('${widget.platform.label}扫码登录',
                    style: TallyType.pageTitle.copyWith(fontSize: 16)),
                const Spacer(),
                IconButton(
                  iconSize: 18,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, color: TallyColors.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: TallySpace.sm),
            if (_success != null)
              _buildSuccess()
            else if (_cookieMode)
              _buildCookieForm()
            else
              _buildQrView(),
          ],
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ 扫码视图 */

  Widget _buildQrView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 220,
          child: Center(
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: TallyColors.signalBlue,
                    ),
                  )
                : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(TallySpace.md),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: TallyColors.tallyRed,
                            height: 1.4,
                          ),
                        ),
                      )
                    : _buildQrImage(),
          ),
        ),
        const SizedBox(height: TallySpace.sm),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TallyType.subtitle.copyWith(
            color: _status.contains('失效') || _error != null
                ? TallyColors.stateAmber
                : TallyColors.textSecondary,
          ),
        ),
        const SizedBox(height: TallySpace.sm),
        Text(
          '打开手机${widget.platform.label} App → 我的 → 扫一扫',
          textAlign: TextAlign.center,
          style: TallyType.meta,
        ),
        const SizedBox(height: TallySpace.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: _startQr,
              child: const Text('刷新二维码'),
            ),
            const SizedBox(width: TallySpace.sm),
            TextButton(
              onPressed: () => setState(() => _cookieMode = true),
              child: const Text('使用 Cookie 登录'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQrImage() {
    final code = _code;
    if (code == null) return const SizedBox.shrink();
    return Container(
      width: 220,
      height: 220,
      padding: const EdgeInsets.all(TallySpace.sm),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TallyRadius.card),
      ),
      child: QrImageView(
        data: code.url,
        version: QrVersions.auto,
        backgroundColor: Colors.white,
        // 纠错等级用中等：二维码在深色弹层里对比度高，容错够用
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ Cookie 视图 */

  Widget _buildCookieForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '在浏览器登录后：F12 → Network → 任一请求 → Request Headers → Cookie',
          style: TallyType.meta,
        ),
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
            hintText: _isBilibili
                ? 'SESSDATA=xxx; bili_jct=xxx; buvid3=xxx;'
                : 'acf_auth=xxx; acf_jwt_token=xxx;',
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
          children: const [
            Icon(Icons.lock_outline, size: 13, color: TallyColors.textTertiary),
            SizedBox(width: 4),
            Expanded(
              child: Text(
                'Cookie 等同于账号密码，仅保存在本机，不会上传',
                style: TallyType.tiny,
              ),
            ),
          ],
        ),
        if (_cookieError != null) ...[
          const SizedBox(height: TallySpace.sm),
          Text(
            _cookieError!,
            style: const TextStyle(
              fontSize: 12,
              color: TallyColors.tallyRed,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: TallySpace.md),
        FilledButton(
          onPressed: _verifying ? null : _submitCookie,
          style: FilledButton.styleFrom(backgroundColor: TallyColors.signalBlue),
          child: _verifying
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
        TextButton(
          onPressed: () => setState(() => _cookieMode = false),
          child: const Text('返回扫码登录'),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final profile = _success!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, size: 40, color: TallyColors.signalBlue),
        const SizedBox(height: TallySpace.md),
        const Text('登录成功', style: TallyType.nickname),
        if (profile.userName.isNotEmpty) ...[
          const SizedBox(height: TallySpace.sm),
          Text(profile.userName, style: TallyType.subtitle),
        ],
        const SizedBox(height: TallySpace.lg),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
