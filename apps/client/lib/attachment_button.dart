import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_loading.dart';
import 'pirc_localizations.dart';
import 'pirc_theme.dart';

class AttachmentButton extends StatefulWidget {
  const AttachmentButton({
    super.key,
    required this.loading,
    required this.onSelected,
    this.images = true,
  });

  final bool loading;
  final bool images;
  final ValueChanged<String>? onSelected;

  @override
  State<AttachmentButton> createState() => _AttachmentButtonState();
}

class _AttachmentButtonState extends State<AttachmentButton> {
  final overlay = OverlayPortalController();
  final anchor = LayerLink();

  @override
  void didUpdateWidget(AttachmentButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.loading || widget.onSelected == null) && overlay.isShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (widget.loading || widget.onSelected == null)) {
          overlay.hide();
        }
      });
    }
  }

  void select(String kind) {
    overlay.hide();
    widget.onSelected?.call(kind);
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: anchor,
    child: SizedBox.square(
      dimension: PircLayout.actionSize,
      child: OverlayPortal(
        controller: overlay,
        overlayChildBuilder: (context) {
          final width = math.min(
            PircLayout.attachmentMenuWidth,
            MediaQuery.sizeOf(context).width - PircSpacing.s24,
          );
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): overlay.hide,
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: overlay.hide,
                  ),
                ),
                CompositedTransformFollower(
                  link: anchor,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.topLeft,
                  followerAnchor: Alignment.bottomLeft,
                  offset: const Offset(0, -PircSpacing.s8),
                  child: Material(
                    key: const Key('attachment-options'),
                    elevation: PircEffects.popupElevation,
                    color: context.pircColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: PircRadii.activity,
                      side: BorderSide(
                        color: context.pircColors.outlineVariant,
                        width: PircLayout.borderWidth,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: width,
                      child: Padding(
                        padding: const EdgeInsets.all(PircSpacing.s4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.images)
                              choice(
                                context,
                                'image',
                                LucideIcons.image,
                                context.l10n.attachmentImage,
                              ),
                            choice(
                              context,
                              'file',
                              LucideIcons.file,
                              context.l10n.attachmentFile,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: IconButton(
          tooltip: context.l10n.attachAttachment,
          onPressed: widget.loading || widget.onSelected == null
              ? null
              : overlay.toggle,
          icon: SizedBox.square(
            dimension: PircIconSizes.small,
            child: widget.loading
                ? const FittedBox(child: PircLoadingMark())
                : const Icon(LucideIcons.paperclip, size: PircIconSizes.small),
          ),
        ),
      ),
    ),
  );

  Widget choice(
    BuildContext context,
    String kind,
    IconData icon,
    String label,
  ) => Semantics(
    button: true,
    child: InkWell(
      onTap: () => select(kind),
      borderRadius: PircRadii.brand,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PircLayout.attachmentChoiceHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PircSpacing.s12,
            vertical: PircSpacing.s8,
          ),
          child: Row(
            children: [
              Container(
                width: PircLayout.attachmentIconBox,
                height: PircLayout.attachmentIconBox,
                decoration: BoxDecoration(
                  color: context.pircColors.primaryContainer,
                  borderRadius: PircRadii.badge,
                ),
                child: Icon(
                  icon,
                  size: PircIconSizes.small,
                  color: context.pircColors.primary,
                ),
              ),
              const SizedBox(width: PircSpacing.s12),
              Expanded(child: Text(label, style: context.pircText.body)),
            ],
          ),
        ),
      ),
    ),
  );
}
