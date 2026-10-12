import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';

void main() {
  testWidgets(
    'prefill after a completed tool uses the same waiting block as the first response',
    (tester) async {
      final strings = await AppLocalizations.delegate.load(const Locale('en'));
      Widget transcript(String text, {bool complete = false}) => MaterialApp(
        theme: pircTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Column(
            children: [
              const MessageBubble(
                item: {
                  'id': 'tool',
                  'role': 'tool',
                  'title': 'read',
                  'text': 'File contents',
                  'complete': true,
                  'phase': 'completed',
                },
              ),
              MessageBubble(
                key: const ValueKey('next-response'),
                item: {
                  'id': 'next-response',
                  'role': 'assistant',
                  'text': text,
                  'complete': complete,
                },
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(transcript(''));
      expect(find.text(strings.waitingForResponse), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(2));
      expect(
        find.ancestor(
          of: find.byType(LoadingIndicator),
          matching: find.byType(Card),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(transcript('Next response'));
      expect(find.text(strings.waitingForResponse), findsNothing);
      expect(find.byType(LoadingIndicator), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Next response'), findsOneWidget);

      await tester.pumpWidget(transcript('', complete: true));
      expect(find.text(strings.waitingForResponse), findsNothing);
      expect(find.byType(Card), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
