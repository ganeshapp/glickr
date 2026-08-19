import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Skeleton placeholder shown while content loads.
///
/// A shimmer rather than a centred spinner because it tells the user the SHAPE
/// of what is coming, so the layout does not jump when it arrives. Hand-rolled
/// (25 lines) rather than pulling in the `shimmer` package for one effect.
///
/// Degrades to a plain static block when the platform asks for reduced motion:
/// a repeating sweep is exactly the kind of animation that setting exists to
/// stop.
class GlickrShimmer extends StatefulWidget {
  final Widget child;

  const GlickrShimmer({super.key, required this.child});

  @override
  State<GlickrShimmer> createState() => _GlickrShimmerState();
}

class _GlickrShimmerState extends State<GlickrShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 1400),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      if (_controller.isAnimating) _controller.stop();
      return widget.child;
    }
    if (!_controller.isAnimating) _controller.repeat();

    final highlight = context.colorScheme.onSurface.withValues(alpha: 0.06);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final slide = _controller.value * 3 - 1;
            return LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.transparent, highlight, Colors.transparent],
              stops: [
                (slide - 0.3).clamp(0.0, 1.0),
                slide.clamp(0.0, 1.0),
                (slide + 0.3).clamp(0.0, 1.0),
              ],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A plain rounded block in the shimmer's base colour.
class ShimmerBlock extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;

  const ShimmerBlock({
    super.key,
    this.width,
    this.height,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Skeleton album cards for the albums grid.
class AlbumCardSkeleton extends StatelessWidget {
  const AlbumCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return GlickrShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: ShimmerBlock(radius: 16)),
          const SizedBox(height: 8),
          const ShimmerBlock(height: 13, radius: 5),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 70,
              child: const ShimmerBlock(height: 10, radius: 5),
            ),
          ),
        ],
      ),
    );
  }
}
