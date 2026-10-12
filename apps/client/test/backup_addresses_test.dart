import 'package:pirc/pirc_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'backup addresses validate, reorder and save on a $width phone',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        ConnectionOptions? result;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: pircTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<ConnectionOptions>(
                      context: context,
                      builder: (_) =>
                          const ConnectionDialog(endpoint: 'http://lan:43123'),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add-backup-address')));
        await tester.pumpAndSettle();
        final backup = find.byType(TextFormField).at(2);
        await tester.ensureVisible(backup);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetViewInsets);
        await tester.enterText(backup, 'lan');
        await tester.ensureVisible(find.byKey(const Key('connect-submit')));
        await tester.tap(find.byKey(const Key('connect-submit')));
        await tester.pumpAndSettle();
        expect(find.text('Duplicate address'), findsNWidgets(2));
        await tester.ensureVisible(backup);
        await tester.enterText(backup, 'https://vpn.example.com');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final up = find.byTooltip('Move up').last;
        await tester.ensureVisible(up);
        await tester.tap(up);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('connection-url')))
              .controller!
              .text,
          'https://vpn.example.com',
        );
        expect(find.byKey(const Key('connection-token')), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('connect-submit')));
        await tester.tap(find.byKey(const Key('connect-submit')));
        await tester.pumpAndSettle();
        expect(result!.url, 'https://vpn.example.com:43123');
        expect(result!.backupAddresses, ['http://lan:43123']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
