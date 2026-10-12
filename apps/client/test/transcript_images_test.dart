import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';

class ImagesController extends PircController {
  int reads = 0;
  bool fail = false;
  @override
  Future<Uint8List> readImage(
    String instance,
    String id, {
    bool Function()? cancelled,
  }) async {
    reads++;
    if (fail) throw StateError('Unavailable');
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4XzDhPzJmIF0AAFteL+Hl/kTRAAAAAElFTkSuQmCC',
    );
  }
}

void main() {
  testWidgets('tool images load once across updates and support preview', (
    tester,
  ) async {
    final model = ImagesController();
    Future<void> show(String text) => tester.pumpWidget(
      MaterialApp(
        theme: pircTheme(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageBubble(
            model: model,
            instance: 'i',
            item: {
              'id': 'tool',
              'role': 'tool',
              'title': 'read',
              'phase': 'completed',
              'complete': true,
              'text': text,
              'images': [
                {'id': 'image', 'mime_type': 'image/png', 'size': 68},
              ],
            },
          ),
        ),
      ),
    );
    await show('Result');
    expect(model.reads, 0);
    await tester.tap(find.text('read · Completed'));
    await tester.pumpAndSettle();
    expect(model.reads, 1);
    expect(find.byType(Image), findsOneWidget);
    await show('Updated result');
    await tester.pumpAndSettle();
    expect(model.reads, 1);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
