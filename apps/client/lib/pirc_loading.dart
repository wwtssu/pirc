import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pirc_theme.dart';

/// Shared loading state. Only the small activity mark animates; labels stay still.
class PircLoading extends StatelessWidget {
  const PircLoading({super.key, required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Semantics(
    label: [title, ?detail].join(', '),
    liveRegion: true,
    child: ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _ActivityMark(),
          const SizedBox(height: PircSpacing.s20),
          Text(
            title,
            style: context.pircText.cardTitle,
            textAlign: TextAlign.center,
          ),
          if (detail != null) ...[
            const SizedBox(height: PircSpacing.s8),
            Text(
              detail!,
              style: context.pircText.hint,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    ),
  );
}

class _ActivityMark extends StatefulWidget {
  const _ActivityMark();

  @override
  State<_ActivityMark> createState() => _ActivityMarkState();
}

class _ActivityMarkState extends State<_ActivityMark>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: PircMotion.loadingCycle,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      animation.stop();
      animation.value = 0;
    } else if (!animation.isAnimating) {
      animation.repeat();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: PircLayout.loadingMarkWidth,
      height: PircLayout.loadingMarkSize,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            final phase = (animation.value - index * .25) % 1;
            final pulse = reducedMotion
                ? 1.0
                : math.pow(math.sin(phase * math.pi), 2).toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: PircSpacing.s3),
              child: Transform.scale(
                scale: .8 + .2 * pulse,
                child: Opacity(
                  opacity: .28 + .72 * pulse,
                  child: Container(
                    width: PircLayout.loadingDotSize,
                    height: PircLayout.loadingDotSize,
                    decoration: BoxDecoration(
                      color: context.pircColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
