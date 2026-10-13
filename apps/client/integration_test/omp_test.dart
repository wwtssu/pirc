import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'OMP uses existing client history, model, reasoning and streaming UI',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await RustLib.init();
      final model = PircController()
        ..serverKey = const String.fromEnvironment('PIRC_TEST_SERVER_KEY');
      Future<void> wait(bool Function() ready, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(ready(), isTrue, reason: '$label: ${model.error}');
        debugPrint('PASS $label');
      }

      try {
        await tester.pumpWidget(
          PircApp(locale: const Locale('en'), controller: model),
        );
        await model.connect(const String.fromEnvironment('PIRC_TEST_URL'));
        await wait(
          () =>
              model.connection == 'connected' &&
              model.onlineSessions.any((s) => s.agentId == 'omp'),
          'App connects to the real OMP session',
        );
        final session = model.onlineSessions.firstWhere(
          (s) => s.agentId == 'omp',
        );
        await tester.tap(find.byKey(Key('session-${session.instance}')));
        await wait(
          () =>
              model.selected?.ready == true &&
              find.byKey(const Key('prompt-editor')).evaluate().isNotEmpty,
          'App loads OMP history',
        );
        expect(model.selected!.currentModel?['id'], 'fixture-large');
        expect(find.text('Renamed OMP'), findsOneWidget);
        await tester.tap(find.byKey(const Key('session-model')));
        await wait(
          () => find
              .byKey(const ValueKey('model-pirc-test/controlled'))
              .evaluate()
              .isNotEmpty,
          'existing model picker receives OMP models',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.ensureVisible(
          find.byKey(const ValueKey('model-pirc-test/fixture-large')),
        );
        await tester.tap(
          find.byKey(const ValueKey('model-pirc-test/fixture-large')),
        );
        await wait(
          () =>
              find.byKey(const Key('model-search')).evaluate().isEmpty &&
              model.selected?.state == 'idle',
          'OMP model selection completes',
        );
        await tester.tap(find.byKey(const Key('session-thinking')));
        await wait(
          () =>
              find.byKey(const ValueKey('thinking-max')).evaluate().isNotEmpty,
          'existing reasoning picker receives OMP efforts',
        );
        expect(find.byKey(const ValueKey('thinking-low')), findsOneWidget);
        expect(find.byKey(const ValueKey('thinking-medium')), findsNothing);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.ensureVisible(find.byKey(const ValueKey('thinking-high')));
        await tester.tap(find.byKey(const ValueKey('thinking-high')));
        await wait(
          () =>
              find.byKey(const ValueKey('thinking-max')).evaluate().isEmpty &&
              model.selected?.thinkingLevel == 'high',
          'OMP effort updates in the composer',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'Hello from App',
        );
        await wait(
          () =>
              tester
                  .widget<IconButton>(find.byKey(const Key('composer-action')))
                  .onPressed !=
              null,
          'composer is ready to send',
        );
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              model.selected?.items.any(
                    (i) => (i['text'] as String? ?? '').contains(
                      'reply:Hello from App',
                    ),
                  ) ==
                  true &&
              model.selected?.state == 'idle',
          'App receives a streamed OMP answer',
        );
        expect(tester.takeException(), isNull);
      } finally {
        model.disconnect();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
}
