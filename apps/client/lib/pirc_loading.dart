import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pirc_theme.dart';

/// Shared loading state. Only the small activity mark animates; labels stay still.
class PircLoading extends StatelessWidget {
  const PircLoading({
    super.key,
    required this.title,
    this.detail,
    this.compact = false,
  });

  final String title;
  final String? detail;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    label: [title, ?detail].join(', '),
    liveRegion: true,
    child: ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PircLoadingMark(),
          SizedBox(height: compact ? PircSpacing.s12 : PircSpacing.s20),
          Text(
            title,
            style: compact ? context.pircText.body : context.pircText.cardTitle,
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

class PircLoadingMark extends StatefulWidget {
  const PircLoadingMark({super.key, this.color});
  final Color? color;

  @override
  State<PircLoadingMark> createState() => _ActivityMarkState();
}

class _ActivityMarkState extends State<PircLoadingMark>
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
                      color: widget.color ?? context.pircColors.primary,
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
