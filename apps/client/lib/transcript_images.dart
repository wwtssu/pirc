import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'pirc_controller.dart';
import 'pirc_loading.dart';
import 'pirc_localizations.dart';
import 'pirc_theme.dart';

/// Image widgets are created by the paged transcript only when near the viewport.
class TranscriptImages extends StatelessWidget {
  const TranscriptImages({
    super.key,
    required this.model,
    required this.instance,
    required this.images,
  });
  final PircController model;
  final String instance;
  final List images;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final image in images)
        _TranscriptImage(
          key: ValueKey('${identityHashCode(model)}:$instance:${image['id']}'),
          model: model,
          instance: instance,
          id: image['id'] as String,
        ),
    ],
  );
}

class _TranscriptImage extends StatefulWidget {
  const _TranscriptImage({
    super.key,
    required this.model,
    required this.instance,
    required this.id,
  });
  final PircController model;
  final String instance;
  final String id;
  @override
  State<_TranscriptImage> createState() => _TranscriptImageState();
}

class _TranscriptImageState extends State<_TranscriptImage> {
  late Future<Uint8List> image;
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    image = widget.model.readImage(
      widget.instance,
      widget.id,
      cancelled: () => !mounted,
    );
  }

  void preview(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: .5,
                maxScale: 5,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 2048,
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: context.l10n.close,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget failed() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(context.l10n.imageUnavailable, style: context.pircText.hint),
      TextButton(
        onPressed: () => setState(load),
        child: Text(context.l10n.retry),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: PircSpacing.s8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: FutureBuilder<Uint8List>(
          future: image,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: failed());
            final bytes = snapshot.data;
            if (bytes == null) return const Center(child: PircLoadingMark());
            return Semantics(
              label: context.l10n.viewImage,
              button: true,
              child: InkWell(
                onTap: () => preview(bytes),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 800,
                  errorBuilder: (_, _, _) => Center(child: failed()),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}
