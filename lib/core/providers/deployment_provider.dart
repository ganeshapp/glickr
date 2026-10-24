import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import '../models/app_config.dart';
import '../services/deployment_service.dart';
import '../services/dio_client.dart';
import 'config_provider.dart';

final deploymentProvider =
    StateNotifierProvider<DeploymentNotifier, DeploymentStatus?>((ref) {
      final config = ref.watch(configNotifierProvider);
      final tracker = DeploymentNotifier(
        config: config,
        service: DeploymentService(api: ref.watch(apiClientProvider).dio),
        box: Hive.box<Map>('deployment_state'),
      );
      return tracker;
    });

class DeploymentNotifier extends StateNotifier<DeploymentStatus?> {
  final AppConfig? config;
  final DeploymentService service;
  final Box<Map> box;
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;
  String? _sha;
  String? _pageUrl;
  String? _sourcePath;
  DateTime _started = DateTime.now();
  int _generation = 0;
  bool _checking = false;
  String get _key =>
      '${config?.repoOwner}/${config?.repoName}/${config?.branch}';

  DeploymentNotifier({
    required this.config,
    required this.service,
    required this.box,
  }) : super(null) {
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (_sha != null) retry();
      },
      onPause: () => _timer?.cancel(),
    );
    if (config == null) return;
    final saved = box.get(_key);
    if (saved != null) {
      _sha = saved['sha'] as String?;
      _pageUrl = saved['pageUrl'] as String?;
      _sourcePath = saved['sourcePath'] as String?;
      if (_sha != null) {
        state = const DeploymentStatus(
          DeploymentPhase.saved,
          'Checking the last saved changes…',
        );
        _timer = Timer(Duration.zero, _check);
      }
    }
  }

  /// Publishing already succeeded. Tracking errors must never turn it into a
  /// failed publish (which would encourage publishing the same post again).
  void track(String sha, {String? pageUrl, String? sourcePath}) {
    _generation++;
    _sha = sha;
    _pageUrl = pageUrl;
    _sourcePath = sourcePath;
    _started = DateTime.now();
    _timer?.cancel();
    state = const DeploymentStatus(
      DeploymentPhase.saved,
      'Saved to GitHub. Waiting for the site build…',
    );
    unawaited(
      box
          .put(_key, {'sha': sha, 'pageUrl': pageUrl, 'sourcePath': sourcePath})
          .catchError((Object _) {}),
    );
    _timer = Timer(Duration.zero, _check);
  }

  void retry() {
    _started = DateTime.now();
    _timer?.cancel();
    _timer = Timer(Duration.zero, _check);
  }

  Future<void> _check() async {
    if (!mounted || _sha == null || config == null) return;
    if (_checking) {
      _timer = Timer(const Duration(seconds: 2), _check);
      return;
    }
    _checking = true;
    final generation = _generation;
    try {
      final result = await service.check(
        owner: config!.repoOwner,
        repo: config!.repoName,
        branch: config!.branch,
        sha: _sha!,
        siteUrl: config!.siteUrl,
        pageUrl: _pageUrl,
        sourcePath: _sourcePath,
      );
      if (mounted && generation == _generation) state = result;
    } catch (e) {
      if (mounted && generation == _generation) {
        final denied =
            e is DioException && [401, 403].contains(e.response?.statusCode);
        state = DeploymentStatus(
          DeploymentPhase.unknown,
          denied
              ? 'Saved. Build status needs Actions and Deployments read access on your GitHub token.'
              : 'Saved. Could not check deployment status; retry when connected.',
        );
      }
    } finally {
      _checking = false;
    }
    if (!mounted || generation != _generation) return;
    if (state?.phase == DeploymentPhase.live ||
        state?.phase == DeploymentPhase.failed ||
        state?.phase == DeploymentPhase.unpublished) {
      return;
    }
    if (DateTime.now().difference(_started) >= const Duration(minutes: 10)) {
      state = DeploymentStatus(
        DeploymentPhase.unknown,
        'Saved. Deployment is taking longer than expected. Check again or open GitHub.',
        buildUrl: state?.buildUrl,
      );
      return;
    }
    _timer = Timer(const Duration(seconds: 10), _check);
  }

  String? get publicUrl => state?.publicUrl ?? _pageUrl ?? config?.siteUrl;
  String? get githubUrl =>
      config == null
          ? null
          : 'https://github.com/${config!.repoOwner}/${config!.repoName}/actions';

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }
}
