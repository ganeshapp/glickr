import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glickr/core/services/deployment_service.dart';

Dio stub(Object Function(RequestOptions) response) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = response(request);
        handler.resolve(
          Response(requestOptions: request, statusCode: 200, data: data),
        );
      },
    ),
  );
  return dio;
}

void main() {
  final sha = 'a' * 40;
  final newer = 'b' * 40;
  Future<DeploymentStatus> check(
    Dio api,
    Dio site, {
    String? page,
    String? sourcePath,
  }) => DeploymentService(api: api, publicClient: site).check(
    owner: 'me',
    repo: 'blog',
    branch: 'main',
    sha: sha,
    siteUrl: 'https://gapp.in',
    pageUrl: page,
    sourcePath: sourcePath,
  );

  test(
    'an old page returning 200 and unrelated CI success do not mean Live',
    () async {
      final api = stub(
        (r) =>
            r.path.endsWith('/deployments')
                ? []
                : {
                  'workflow_runs': [
                    {
                      'path': '.github/workflows/ci.yml',
                      'status': 'completed',
                      'conclusion': 'success',
                    },
                  ],
                },
      );
      final result = await check(api, stub((_) => '<html>Old page</html>'));
      expect(result.phase, DeploymentPhase.saved);
    },
  );
  test(
    'a Pages build failure is reported even before deployment exists',
    () async {
      final api = stub(
        (r) =>
            r.path.endsWith('/deployments')
                ? []
                : {
                  'workflow_runs': [
                    {
                      'path': '.github/workflows/deploy.yml',
                      'conclusion': 'failure',
                      'html_url': 'https://github.com/build',
                    },
                  ],
                },
      );
      final result = await check(api, stub((_) => 'old'));
      expect(result.phase, DeploymentPhase.failed);
      expect(result.buildUrl, 'https://github.com/build');
    },
  );
  test(
    'the exact public revision plus a reachable page is Live without API credentials at the site',
    () async {
      final result = await check(
        stub((_) => throw StateError('API not needed')),
        stub((r) {
          expect(r.headers.containsKey('Authorization'), isFalse);
          return r.path.contains('deployment.json')
              ? {'commit': sha}
              : 'new page';
        }),
        page: 'https://gapp.in/my-post/',
      );
      expect(result.phase, DeploymentPhase.live);
    },
  );
  test(
    'a newer deployed revision containing the saved commit is Live',
    () async {
      final result = await check(
        stub((r) {
          expect(r.path, endsWith('/compare/$sha...$newer'));
          return {'status': 'ahead'};
        }),
        stub(
          (r) =>
              r.path.contains('deployment.json') ? {'commit': newer} : 'page',
        ),
      );
      expect(result.phase, DeploymentPhase.live);
    },
  );
  test(
    'deployment success still waits while the public marker is stale',
    () async {
      final api = stub((r) {
        if (r.path.contains('/compare/')) return {'status': 'behind'};
        if (r.path.endsWith('/statuses')) {
          return [
            {'state': 'success'},
          ];
        }
        return [
          {'id': 3},
        ];
      });
      final result = await check(api, stub((_) => {'commit': newer}));
      expect(result.phase, DeploymentPhase.building);
    },
  );
  test('deployment failure is tied to the saved SHA', () async {
    final api = stub((r) {
      if (r.path.endsWith('/statuses')) {
        return [
          {'state': 'failure'},
        ];
      }
      expect(r.queryParameters['sha'], sha);
      expect(r.queryParameters['environment'], 'github-pages');
      return [
        {'id': 3},
      ];
    });
    expect(
      (await check(api, stub((_) => 'old'))).phase,
      DeploymentPhase.failed,
    );
  });
  test(
    'the deployed URL map handles collection and custom permalinks',
    () async {
      final result = await check(
        stub((_) => throw StateError('API not needed')),
        stub((r) {
          if (r.path.contains('deployment.json')) {
            return {
              'commit': sha,
              'pages': {'_wiki/note.md': '/wiki/note/'},
            };
          }
          expect(r.path, 'https://gapp.in/wiki/note/');
          return 'page';
        }),
        page: 'https://gapp.in/blog/note/',
        sourcePath: '_wiki/note.md',
      );
      expect(result.phase, DeploymentPhase.live);
      expect(result.publicUrl, 'https://gapp.in/wiki/note/');
    },
  );
  test('a built future or excluded document is not called Live', () async {
    final result = await check(
      stub((_) => throw StateError('API not needed')),
      stub((_) => {'commit': sha, 'pages': {}}),
      sourcePath: '_posts/future.md',
    );
    expect(result.phase, DeploymentPhase.unpublished);
  });
}
