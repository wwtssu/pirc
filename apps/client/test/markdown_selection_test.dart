import 'package:pirc/pirc_localizations.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  testWidgets(
    'inline code has the same visible selection as surrounding text',
    (tester) async {
      const highlight = Color(0xFF9966DD);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: pircTheme().copyWith(
              textSelectionTheme: const TextSelectionThemeData(
                selectionColor: highlight,
              ),
            ),
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(20),
                child: MessageBubble(
                  item: {
                    'id': 'inline',
                    'role': 'assistant',
                    'text': 'Before `code path` after',
                    'complete': true,
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll();
      await tester.pumpAndSettle();
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText &&
              widget.text.toPlainText() == 'Before code path after',
        ),
      );
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final width = image.width;
        image.dispose();
        Color atCharacter(int offset) {
          final box = paragraph
              .getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1),
              )
              .single
              .toRect();
          final point = paragraph.localToGlobal(box.center, ancestor: boundary);
          final index = (point.dy.floor() * width + point.dx.floor()) * 4;
          return Color.fromARGB(
            bytes!.getUint8(index + 3),
            bytes.getUint8(index),
            bytes.getUint8(index + 1),
            bytes.getUint8(index + 2),
          );
        }

        // Sample spaces so font glyphs cannot hide the selection background.
        return [atCharacter(6), atCharacter(11)];
      });
      expect(pixels![0], highlight);
      expect(pixels[1], highlight);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
