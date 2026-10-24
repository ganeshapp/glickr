import 'package:dio/dio.dart';

enum DeploymentPhase { saved, building, live, failed, unknown, unpublished }

class DeploymentStatus {
  final DeploymentPhase phase;
  final String message;
  final String? buildUrl;
  final String? publicUrl;
  const DeploymentStatus(
    this.phase,
    this.message, {
    this.buildUrl,
    this.publicUrl,
  });
}

/// GitHub deployment evidence is tied to the saved commit. A successful
/// unrelated workflow, or a 200 response from an old page, is not enough.
class DeploymentService {
  final Dio api;
  final Dio publicClient;
  DeploymentService({required this.api, Dio? publicClient})
    : publicClient =
          publicClient ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          );

  Future<DeploymentStatus> check({
    required String owner,
    required String repo,
    required String branch,
    required String sha,
    required String siteUrl,
    String? pageUrl,
    String? sourcePath,
  }) async {
    final base = '/repos/$owner/$repo';
    // This client has NO GitHub credentials. Never forward API auth to a site.
    var markerAvailable = false;
    if (siteUrl.isNotEmpty) {
      try {
        final marker = await publicClient.get(
          '${siteUrl.replaceFirst(RegExp(r'/+$'), '')}/deployment.json',
          queryParameters: {'v': DateTime.now().millisecondsSinceEpoch},
          options: Options(headers: {'Cache-Control': 'no-cache'}),
        );
        final liveSha = marker.data is Map ? marker.data['commit'] : null;
        if (liveSha is String && RegExp(r'^[a-f0-9]{40}$').hasMatch(liveSha)) {
          markerAvailable = true;
          var includes = liveSha == sha;
          if (!includes) {
            final comparison = await api.get('$base/compare/$sha...$liveSha');
            includes = [
              'ahead',
              'identical',
            ].contains(comparison.data['status']);
          }
          if (includes) {
            var visibleUrl = pageUrl ?? siteUrl;
            final pages = marker.data['pages'];
            if (sourcePath != null && pages is Map) {
              final path = pages[sourcePath];
              if (path is! String) {
                return const DeploymentStatus(
                  DeploymentPhase.unpublished,
                  'Site built. This file has no public page yet. Check its date and publication settings.',
                );
              }
              visibleUrl =
                  '${siteUrl.replaceFirst(RegExp(r'/+$'), '')}/'
                  '${path.replaceFirst(RegExp(r'^/+'), '')}';
            }
            if (await _pageAvailable(visibleUrl)) {
              return DeploymentStatus(
                DeploymentPhase.live,
                'The saved changes are live on your site.',
                publicUrl: visibleUrl,
              );
            }
          }
        }
      } on DioException {
        /* The marker is optional on other Jekyll sites. */
      }
    }

    final deployments = await api.get(
      '$base/deployments',
      queryParameters: {
        'sha': sha,
        'environment': 'github-pages',
        'per_page': 10,
      },
    );
    final entries = deployments.data as List;
    if (entries.isNotEmpty) {
      final deployment = entries.first as Map;
      final statuses = await api.get(
        '$base/deployments/${deployment['id']}/statuses',
        queryParameters: {'per_page': 1},
      );
      final list = statuses.data as List;
      if (list.isNotEmpty) {
        final status = list.first as Map;
        final url = status['log_url'] as String?;
        if (['failure', 'error'].contains(status['state'])) {
          return DeploymentStatus(
            DeploymentPhase.failed,
            'Saved to GitHub, but the site deployment failed.',
            buildUrl: url,
          );
        }
        if (status['state'] == 'success') {
          // If a version marker exists, wait until the public site catches up.
          if (!markerAvailable && await _pageAvailable(pageUrl ?? siteUrl)) {
            return DeploymentStatus(
              DeploymentPhase.live,
              'GitHub Pages deployed these changes; the page is reachable.',
              buildUrl: url,
            );
          }
          return DeploymentStatus(
            DeploymentPhase.building,
            'Deployed on GitHub; waiting for the public page.',
            buildUrl: url,
          );
        }
      }
    }

    // Build failures happen before a deployment object is created. Only the
    // Pages/deploy workflow counts, never a generic CI success or failure.
    final response = await api.get(
      '$base/actions/runs',
      queryParameters: {'head_sha': sha, 'branch': branch, 'per_page': 30},
    );
    final runs =
        (response.data['workflow_runs'] as List).where((run) {
          final path = (run['path'] as String? ?? '').split('@').first;
          return path == '.github/workflows/deploy.yml' ||
              path == '.github/workflows/deploy.yaml' ||
              path.contains('pages-build-deployment');
        }).toList();
    if (runs.isNotEmpty) {
      final run = runs.first as Map;
      final url = run['html_url'] as String?;
      if ([
        'failure',
        'timed_out',
        'action_required',
      ].contains(run['conclusion'])) {
        return DeploymentStatus(
          DeploymentPhase.failed,
          'Saved to GitHub, but the site build failed.',
          buildUrl: url,
        );
      }
      if (run['conclusion'] == 'cancelled') {
        return DeploymentStatus(
          DeploymentPhase.saved,
          'Build replaced or cancelled. Waiting for the next deployment.',
          buildUrl: url,
        );
      }
      return DeploymentStatus(
        DeploymentPhase.building,
        'Building and deploying your site…',
        buildUrl: url,
      );
    }
    return const DeploymentStatus(
      DeploymentPhase.saved,
      'Saved to GitHub. Waiting for the site build…',
    );
  }

  Future<bool> _pageAvailable(String url) async {
    if (url.isEmpty) return false;
    try {
      final result = await publicClient.get(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Cache-Control': 'no-cache'},
        ),
      );
      return result.statusCode == 200;
    } on DioException {
      return false;
    }
  }
}
