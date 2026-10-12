import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/draft_attachments.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  testWidgets(
    'image and file drafts remain listed while composing and can be removed',
    (tester) async {
      var removals = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: pircTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: Column(
                children: [
                  DraftAttachments(
                    image: base64Decode(
                      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4XzDhPzJmIF0AAFteL+Hl/kTRAAAAAElFTkSuQmCC',
                    ),
                    imageName: 'screenshot.png',
                    fileName: 'application.log',
                    onRemoveImage: () => removals++,
                    onRemoveFile: () => removals++,
                  ),
                  const TextField(key: Key('draft-editor')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('draft-editor')),
        'Review these attachments',
      );
      await tester.pump();
      expect(find.text('screenshot.png'), findsOneWidget);
      expect(find.text('application.log'), findsOneWidget);
      expect(find.text('Review these attachments'), findsOneWidget);
      expect(removals, 0);
      await tester.tap(find.byType(IconButton).first);
      await tester.tap(find.byType(IconButton).last);
      expect(removals, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
