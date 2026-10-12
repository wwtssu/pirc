import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/attachment_button.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  testWidgets('attachment menu separates image and file selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? choice;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: pircTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: AttachmentButton(
              loading: false,
              images: true,
              onSelected: (kind) => choice = kind,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byKey(const Key('attachment-options')));
    final button = tester.getRect(find.byType(IconButton));
    expect(menu.bottom, lessThan(button.top));
    expect(menu.right, lessThanOrEqualTo(320));
    expect(
      tester.getCenter(find.text('Image')).dy,
      lessThan(tester.getCenter(find.text('File')).dy),
    );
    await tester.tapAt(const Offset(300, 20));
    await tester.pumpAndSettle();
    expect(find.text('File'), findsNothing);
    expect(choice, isNull);
    for (final kind in ['Image', 'File']) {
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.text('Image'), findsOneWidget);
      expect(find.text('File'), findsOneWidget);
      await tester.tap(find.text(kind));
      await tester.pumpAndSettle();
      expect(choice, kind.toLowerCase());
    }
  });
  testWidgets('attachment loading preserves composer and editor geometry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var taps = 0;
    Widget composer(bool loading) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: pircTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: TextField(
            key: const Key('editor'),
            textAlignVertical: TextAlignVertical.center,
            style: const TextStyle(fontSize: 16),
            decoration: PircInputDecorations.composer.copyWith(
              prefixIcon: AttachmentButton(
                key: const Key('attachment'),
                loading: loading,
                onSelected: (_) => taps++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(composer(false));
    final button = tester.getRect(find.byKey(const Key('attachment')));
    final editor = tester.getRect(find.byType(EditableText));
    final field = tester.getRect(find.byKey(const Key('editor')));
    expect((editor.center.dy - button.center.dy).abs(), lessThan(1));
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(taps, 0);
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(taps, 1);

    await tester.pumpWidget(composer(true));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getRect(find.byKey(const Key('attachment'))), button);
    expect(tester.getRect(find.byType(EditableText)), editor);
    expect(tester.getRect(find.byKey(const Key('editor'))), field);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
