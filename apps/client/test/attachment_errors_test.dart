import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_screen.dart';

void main() {
  for (final language in ['en', 'zh', 'ja']) {
    testWidgets(
      '$language shows image incompatibility instead of generic send failure',
      (tester) async {
        final strings = await AppLocalizations.delegate.load(Locale(language));
        final command = {
          'kind': 'prompt',
          'status': 'rejected',
          'code': 'MODEL_NO_IMAGES',
          'detail': 'The selected model does not support images',
        };
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale(language),
            home: Builder(
              builder: (context) =>
                  Text(context.localize(resultLabel(command))),
            ),
          ),
        );
        expect(find.text(strings.modelNoImages), findsOneWidget);
        expect(find.text(strings.sendFailed), findsNothing);
      },
    );
  }
}
