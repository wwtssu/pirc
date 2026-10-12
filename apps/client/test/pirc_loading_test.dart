import 'package:pirc/pirc_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_loading.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  testWidgets(
    'loading fits a narrow dialog with large text and reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              disableAnimations: true,
              textScaler: TextScaler.linear(2),
            ),
            child: const Dialog(
              child: Padding(
                padding: EdgeInsets.all(PircSpacing.s24),
                child: PircLoading(
                  title: 'Loading saved sessions',
                  detail: 'Reading sessions saved on the device',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Loading saved sessions'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
