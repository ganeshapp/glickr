import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/deployment_provider.dart';
import '../services/deployment_service.dart';
import '../utils/external_url.dart';

class DeploymentBanner extends ConsumerWidget {
  const DeploymentBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(deploymentProvider);
    if (status == null) return const SizedBox.shrink();
    final tracker = ref.read(deploymentProvider.notifier);
    final live = status.phase == DeploymentPhase.live;
    final failed = status.phase == DeploymentPhase.failed;
    final label = switch (status.phase) {
      DeploymentPhase.saved => 'Saved → Building → Live',
      DeploymentPhase.building => 'Saved ✓ → Building → Live',
      DeploymentPhase.live => 'Saved ✓ → Built ✓ → Live ✓',
      DeploymentPhase.failed => 'Saved ✓ → Build failed',
      DeploymentPhase.unknown => 'Saved ✓ → Status unavailable',
      DeploymentPhase.unpublished => 'Saved ✓ → Built ✓ → No public page',
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  live
                      ? Icons.check_circle_outline
                      : failed
                      ? Icons.error_outline
                      : Icons.cloud_upload_outlined,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(status.message, style: Theme.of(context).textTheme.bodySmall),
            Wrap(
              spacing: 8,
              children: [
                if (!live)
                  TextButton(
                    onPressed: tracker.retry,
                    child: const Text('Check again'),
                  ),
                if (!live)
                  TextButton(
                    onPressed:
                        () => openExternalUrl(
                          context,
                          status.buildUrl ?? tracker.githubUrl!,
                        ),
                    child: const Text('View build'),
                  ),
                if (live && (tracker.publicUrl?.isNotEmpty ?? false))
                  TextButton(
                    onPressed:
                        () => openExternalUrl(context, tracker.publicUrl!),
                    child: const Text('View site'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
