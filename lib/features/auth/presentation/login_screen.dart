import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/github_app_config.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/services/dio_client.dart';
import '../../../core/services/github_oauth_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/external_url.dart';

/// Token prefixes GitHub currently issues: classic PAT, fine-grained PAT,
/// OAuth App token, GitHub App user token.
const _gitHubTokenPrefixes = ['ghp_', 'github_pat_', 'gho_', 'ghu_'];

/// A heads-up check, never a gate. GitHub has introduced new token formats
/// twice and is the only real judge of a token, so a "no" here only warns.
/// Pre-2021 classic PATs are unprefixed 40-char hex, hence the length arm.
bool _looksLikeGitHubToken(String token) {
  final trimmed = token.trim();
  if (_gitHubTokenPrefixes.any(trimmed.startsWith)) return true;
  return trimmed.length >= 40;
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const _entrance = Duration(milliseconds: 1100);

  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscureToken = true;
  bool _showPatSection = false;
  bool _showFormatWarning = false;

  late final AnimationController _animController = AnimationController(
    duration: _entrance,
    vsync: this,
  );
  late final Animation<double> _fadeIn = CurvedAnimation(
    parent: _animController,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
  );
  late final Animation<Offset> _slideUp =
      Tween<Offset>(begin: const Offset(0, 0.18), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _animController,
          curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
        ),
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // context.motion reads MediaQuery, which initState cannot touch. Zeroing
    // the duration rather than skipping the controller keeps one code path:
    // under reduced motion the hero is simply already in place on frame one.
    _animController.duration = context.motion(_entrance);
    if (_animController.isDismissed) _animController.forward();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _onSignInWithGitHub() =>
      _startDeviceFlow(GitHubAppConfig.bundledClientId);

  Future<void> _startDeviceFlow(String clientId) async {
    final result = await showModalBottomSheet<_DeviceFlowOutcome>(
      context: context,
      isScrollControlled: true,
      // Dismissing by accident mid-authorization would look like the app
      // failed; the sheet offers an explicit Cancel instead.
      isDismissible: false,
      enableDrag: false,
      builder: (context) => _DeviceFlowSheet(clientId: clientId),
    );
    if (result == null || !mounted) return;

    final tokens = (result as _DeviceFlowSuccess).tokens;
    final success = await ref
        .read(authNotifierProvider.notifier)
        .completeDeviceLogin(tokens: tokens, clientId: clientId);
    // AuthWrapper swaps the screen out on success; the haptic is the only
    // confirmation this widget still owns.
    if (success && mounted) HapticFeedback.mediumImpact();
  }

  Future<void> _validateAndLogin() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final success = await ref
        .read(authNotifierProvider.notifier)
        .login(_tokenController.text.trim());
    if (success && mounted) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    // AuthWrapper shows the splash for AuthLoading, so this mostly guards the
    // frame between a tap and the state change - long enough for a double tap
    // to start two sign-ins.
    final isLoading = authState is AuthLoading;
    final errorMessage = authState is AuthUnauthenticated
        ? authState.message
        : null;

    return Scaffold(
      body: Container(
        decoration: AppTheme.backgroundGradient(context),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeIn,
            child: SlideTransition(
              position: _slideUp,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHero(),
                          const SizedBox(height: 44),
                          _buildDeviceSignInButton(isLoading),
                          const SizedBox(height: 14),
                          _buildScopeNote(),
                          if (errorMessage != null) ...[
                            const SizedBox(height: 20),
                            _NoticeBox(
                              icon: Icons.error_outline_rounded,
                              message: errorMessage,
                              tint: context.colorScheme.error,
                            ),
                          ],
                          const SizedBox(height: 12),
                          _buildPatToggle(isLoading),
                          if (_showPatSection) ...[
                            const SizedBox(height: 8),
                            _buildTokenField(isLoading),
                            if (_showFormatWarning) ...[
                              const SizedBox(height: 12),
                              _NoticeBox(
                                icon: Icons.info_outline_rounded,
                                message:
                                    "That doesn't look like a GitHub token - "
                                    'they usually start with ghp_ or '
                                    'github_pat_. You can still try it.',
                                tint: context.appColors.warning,
                              ),
                            ],
                            const SizedBox(height: 16),
                            _buildTokenLoginButton(isLoading),
                            const SizedBox(height: 4),
                            TextButton.icon(
                              onPressed: isLoading
                                  ? null
                                  : () => openExternalUrl(
                                      context,
                                      GitHubAppConfig.createTokenUrl,
                                    ),
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 16,
                              ),
                              label: const Text('Create a token on GitHub'),
                            ),
                            Text(
                              'That link pre-selects the public_repo scope, '
                              'which is all glickr needs.',
                              textAlign: TextAlign.center,
                              style: context.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero() {
    final scheme = context.colorScheme;

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // The glow lives here rather than baked into the PNG so it tracks
            // the scheme's primary across light and dark. The outer stop is
            // primary at zero alpha, not Colors.transparent, because
            // transparent is transparent BLACK and smudges the fade grey.
            Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    scheme.primary.withValues(alpha: 0.14),
                    scheme.primary.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
            Image.asset('assets/brand/glickr_mark.png', width: 132),
          ],
        ),
        Text(
          'glickr',
          style: AppTheme.mono(
            context,
            size: 44,
            weight: FontWeight.w700,
            letterSpacing: -2,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text('albums, versioned.', style: context.textTheme.bodyMedium),
      ],
    );
  }

  Widget _buildDeviceSignInButton(bool isLoading) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: isLoading ? null : _onSignInWithGitHub,
        child: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: context.colorScheme.onPrimary,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.verified_user_rounded, size: 20),
                  SizedBox(width: 10),
                  Text('Sign in with GitHub'),
                ],
              ),
      ),
    );
  }

  /// Says what the token can reach, next to the button that asks for it.
  /// `public_repo` is not a compromise here - an album repo has to be public
  /// for the CDN to serve the website at all - but the user should not have
  /// to take that on trust.
  Widget _buildScopeNote() {
    final scheme = context.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'glickr asks for access to your public repositories only.',
            style: context.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _buildPatToggle(bool isLoading) {
    final scheme = context.colorScheme;
    return TextButton.icon(
      onPressed: isLoading
          ? null
          : () => setState(() => _showPatSection = !_showPatSection),
      icon: Icon(
        _showPatSection
            ? Icons.keyboard_arrow_up_rounded
            : Icons.keyboard_arrow_down_rounded,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      label: Text(
        'Use a personal access token instead',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildTokenField(bool isLoading) {
    final scheme = context.colorScheme;

    return TextFormField(
      controller: _tokenController,
      enabled: !isLoading,
      obscureText: _obscureToken,
      autocorrect: false,
      enableSuggestions: false,
      style: AppTheme.mono(
        context,
        size: 15,
        letterSpacing: 1,
        color: scheme.onSurface,
      ),
      decoration: InputDecoration(
        labelText: 'Personal access token',
        hintText: 'ghp_xxxxxxxxxxxxxxxxxxxx',
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 16, right: 12),
          child: Icon(Icons.key_rounded, color: scheme.primary, size: 22),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscureToken
                ? Icons.visibility_off_rounded
                : Icons.visibility_rounded,
            color: scheme.onSurfaceVariant,
            size: 22,
          ),
          tooltip: _obscureToken ? 'Show token' : 'Hide token',
          onPressed: () => setState(() => _obscureToken = !_obscureToken),
        ),
      ),
      // Emptiness is the only thing worth blocking. An odd-looking token warns
      // below the field and still submits - GitHub decides, not this regex.
      validator: (value) => (value == null || value.trim().isEmpty)
          ? 'Paste a token to continue'
          : null,
      onChanged: (value) {
        final warn = value.trim().isNotEmpty && !_looksLikeGitHubToken(value);
        if (warn != _showFormatWarning) {
          setState(() => _showFormatWarning = warn);
        }
      },
      onFieldSubmitted: (_) => _validateAndLogin(),
    );
  }

  Widget _buildTokenLoginButton(bool isLoading) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: isLoading ? null : _validateAndLogin,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Sign in with token'),
            SizedBox(width: 8),
            Icon(Icons.arrow_forward_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

/// A tinted strip for one message. Colour is always paired with an icon so it
/// carries meaning without relying on hue.
class _NoticeBox extends StatelessWidget {
  final IconData icon;
  final String message;
  final Color tint;

  const _NoticeBox({
    required this.icon,
    required this.message,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: tint, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: context.textTheme.bodySmall?.copyWith(color: tint),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ device flow

/// What the device-flow sheet hands back. Null (a bare dismissal) means the
/// user cancelled and nothing should happen.
sealed class _DeviceFlowOutcome {
  const _DeviceFlowOutcome();
}

class _DeviceFlowSuccess extends _DeviceFlowOutcome {
  final OAuthTokens tokens;
  const _DeviceFlowSuccess(this.tokens);
}

/// The user would rather correct the client id than retry with this one.
/// Drives the GitHub Device Flow: asks for a code, copies it to the clipboard
/// the moment it arrives, opens github.com/login/device, and polls until the
/// user authorizes, cancels, or the code expires.
class _DeviceFlowSheet extends ConsumerStatefulWidget {
  final String clientId;

  const _DeviceFlowSheet({required this.clientId});

  @override
  ConsumerState<_DeviceFlowSheet> createState() => _DeviceFlowSheetState();
}

class _DeviceFlowSheetState extends ConsumerState<_DeviceFlowSheet> {
  DeviceCodeResponse? _code;
  String? _error;
  String? _errorHint;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    // The sheet can go away without the Cancel button - system back pops it
    // even with isDismissible: false - so the polling loop is stopped here
    // rather than in _cancel(), where it would be missed.
    _cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    final oauthService = ref.read(gitHubOAuthServiceProvider);
    try {
      final code = await oauthService.startDeviceFlow(
        widget.clientId,
        scope: GitHubAppConfig.scope,
      );
      if (!mounted || _cancelled) return;
      setState(() => _code = code);
      // Copied before the user can even read it: the next thing they do is
      // paste it into a browser, and typing an eight-character code by hand
      // across an app switch is where this flow usually loses people.
      await Clipboard.setData(ClipboardData(text: code.userCode));

      final result = await oauthService.pollForToken(
        clientId: widget.clientId,
        deviceCode: code.deviceCode,
        interval: code.interval,
        expiresIn: code.expiresIn,
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;

      switch (result) {
        case DeviceFlowSuccess(tokens: final tokens):
          Navigator.of(context).pop(_DeviceFlowSuccess(tokens));
        case DeviceFlowCancelled():
          break; // _cancel() already popped the sheet.
        case DeviceFlowExpired(message: final message):
          _fail(message);
        case DeviceFlowDenied(message: final message):
          _fail(
            message,
            hint: 'Nothing was shared. Try again if you tapped the wrong '
                'button on GitHub.',
          );
        case DeviceFlowDisabled(message: final message):
          _fail(
            message,
            hint: '"Enable Device Flow" is a checkbox near the bottom of the '
                "app's settings page on GitHub. Tick it, then try again.",
          );
        case DeviceFlowFailure(message: final message):
          _fail(message);
      }
    } on ApiException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Something went wrong talking to GitHub - try again.');
    }
  }

  void _fail(String message, {String? hint}) {
    if (!mounted || _cancelled) return;
    setState(() {
      _error = message;
      _errorHint = hint;
    });
  }

  void _retry() {
    setState(() {
      _error = null;
      _errorHint = null;
      _code = null;
    });
    _run();
  }

  void _cancel() {
    _cancelled = true;
    Navigator.of(context).pop();
  }

  Future<void> _copyCode() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code.userCode));
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Sign in with GitHub',
                    style: context.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: _cancel,
                  tooltip: 'Cancel sign-in',
                  icon: Icon(
                    Icons.close_rounded,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              _buildError(_error!)
            else if (_code == null)
              _buildRequesting()
            else
              _buildWaiting(_code!),
          ],
        ),
      ),
    );
  }

  Widget _buildRequesting() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Text('Getting a code from GitHub...',
              style: context.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildWaiting(DeviceCodeResponse code) {
    final scheme = context.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Enter this code on GitHub to finish signing in.',
          textAlign: TextAlign.center,
          style: context.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        // Tappable because a clipboard is shared state - a password manager or
        // a notification can take it over between here and the browser.
        InkWell(
          onTap: _copyCode,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.30),
              ),
            ),
            child: Text(
              code.userCode,
              textAlign: TextAlign.center,
              style: AppTheme.mono(
                context,
                size: 32,
                weight: FontWeight.w700,
                letterSpacing: 6,
                color: scheme.tertiary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Copied to your clipboard - select the code to copy it again.',
          textAlign: TextAlign.center,
          style: context.textTheme.bodySmall?.copyWith(
            color: context.appColors.success,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            // The code is already on the clipboard, so a browser that refuses
            // to open still leaves the user able to get there by hand.
            onPressed: () => openExternalUrl(context, code.verificationUri),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open github.com/login/device'),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('Waiting for you to authorize...',
                style: context.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _cancel,
          child: Text(
            'Cancel',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _buildError(String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NoticeBox(
          icon: Icons.error_outline_rounded,
          message: message,
          tint: context.colorScheme.error,
        ),
        if (_errorHint != null) ...[
          const SizedBox(height: 12),
          Text(_errorHint!, style: context.textTheme.bodySmall),
        ],
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _retry,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('Try again'),
        ),
        TextButton(
          onPressed: _cancel,
          child: Text(
            'Close',
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
