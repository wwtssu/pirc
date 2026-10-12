import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'pirc_localizations.dart';
import 'pirc_theme.dart';

class DraftAttachments extends StatelessWidget {
  const DraftAttachments({
    super.key,
    this.fileName,
    this.image,
    this.imageName,
    this.onRemoveFile,
    this.onRemoveImage,
  });

  final String? fileName;
  final Uint8List? image;
  final String? imageName;
  final VoidCallback? onRemoveFile;
  final VoidCallback? onRemoveImage;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (image != null)
        item(
          context,
          imageName ?? context.l10n.attachmentImage,
          ClipRRect(
            borderRadius: PircRadii.badge,
            child: Image.memory(image!, fit: BoxFit.cover, cacheWidth: 100),
          ),
          onRemoveImage,
        ),
      if (fileName != null)
        item(
          context,
          fileName!,
          DecoratedBox(
            decoration: BoxDecoration(
              color: context.pircColors.primaryContainer,
              borderRadius: PircRadii.badge,
            ),
            child: Icon(
              LucideIcons.file,
              size: PircIconSizes.small,
              color: context.pircColors.primary,
            ),
          ),
          onRemoveFile,
        ),
    ],
  );

  Widget item(
    BuildContext context,
    String name,
    Widget preview,
    VoidCallback? remove,
  ) => Padding(
    padding: const EdgeInsets.all(PircSpacing.s4),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.pircColors.surfaceContainerLowest,
        border: Border.all(color: context.pircColors.outlineVariant),
        borderRadius: PircRadii.notice,
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: PircSpacing.s8),
        child: Row(
          children: [
            SizedBox.square(
              dimension: PircLayout.attachmentPreviewSize,
              child: preview,
            ),
            const SizedBox(width: PircSpacing.s12),
            Expanded(
              child: Text(
                name,
                style: context.pircText.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: context.l10n.removeAttachment,
              onPressed: remove,
              icon: const Icon(LucideIcons.x, size: PircIconSizes.small),
            ),
          ],
        ),
      ),
    ),
  );
}
