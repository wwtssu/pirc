import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/src/rust/frb_generated.dart';

const url = String.fromEnvironment('PIRC_TEST_URL');
const admin = String.fromEnvironment('PIRC_TEST_ADMIN');
const cwd = String.fromEnvironment('PIRC_TEST_CWD');
const saved = String.fromEnvironment('PIRC_TEST_SAVED');
Future<void> action(String path, [Map<String, dynamic> body = const {}]) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('$admin/$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    expect(
      response.statusCode,
      200,
      reason: await utf8.decoder.bind(response).join(),
    );
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native session management preserves viewing and explicitly exits Server-launched Pi',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.binding.setSurfaceSize(const Size(430, 820));
      expect(url, isNotEmpty);
      await RustLib.init();
      final model = PircController()
        ..serverKey = const String.fromEnvironment('PIRC_TEST_SERVER_KEY');
      final checks = <String>[];
      Future<void> wait(bool Function() check, String label) async {
        final until = DateTime.now().add(const Duration(seconds: 55));
        while (!check() && DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (!check()) {
          debugPrint(
            'FAIL $label: connection=${model.connection}, error=${model.error}, sessions=${model.sessions.map((s) => s.snapshot)}, uiError=${find.byKey(const Key('new-session-error')).evaluate().map((e) => (e.widget as Text).data)}',
          );
        }
        expect(check(), isTrue, reason: label);
        checks.add(label);
        debugPrint('PASS $label');
      }

      try {
        await tester.pumpWidget(
          PircApp(locale: const Locale('en'), controller: model),
        );
        await model.connect(url);
        await wait(
          () => model.connection == 'connected',
          'isolated server connected',
        );
        expect(find.text('No active sessions'), findsOneWidget);
        await tester.tap(find.byKey(const Key('create-session')));
        await tester.pump();
        await wait(
          () => find.byKey(Key('restore-$saved')).evaluate().isNotEmpty,
          'real Pi saved history listed',
        );
        await tester.tap(find.byKey(Key('restore-$saved')));
        await tester.pump();
        await wait(
          () =>
              find.byKey(const Key('prompt-editor')).evaluate().isNotEmpty &&
              model.selected?.session == saved,
          'restore opens terminal and waits for Pi registration',
        );
        await wait(
          () => model.selected!.items.any(
            (i) => i['text'] == 'Answer after restoration',
          ),
          'restored assistant body loaded',
        );
        expect(
          model.selected!.items.any(
            (i) =>
                i['role'] == 'thinking' && i['text'] == 'Historical thinking',
          ),
          isTrue,
        );
        expect(
          model.selected!.items.any(
            (i) => i['role'] == 'tool' && i['text'] == 'Historical tool output',
          ),
          isTrue,
        );
        expect(
          model.selected!.items
              .where((i) => i['text'] == 'Answer after restoration')
              .length,
          1,
        );
        expect(find.text('Restoration check'), findsOneWidget);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('back-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('create-session')));
        await tester.pump();
        await wait(
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'saved catalog refresh completes',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('restore-$saved')),
          findsNothing,
          reason: 'Online session is excluded from restore catalog',
        );
        await tester.tap(find.byKey(const Key('new-session-back')));
        await tester.pumpAndSettle();
        final originalInstance = model.selected!.instance;
        await tester.tap(find.text('Restoration check'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'SLOW DETACH',
        );
        await model.send();
        await wait(
          () => model.selected?.state == 'running',
          'Pi is running before mobile leaves',
        );
        await tester.tap(find.byKey(const Key('back-button')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.onlineSessions.single.state, 'running');
        expect(
          model.commands.where(
            (c) => c['kind'] == 'stop' || c['kind'] == 'close',
          ),
          isEmpty,
        );
        await model.disconnect();
        await tester.pump();
        await action('assert-alive', {'index': 0});
        await model.connect(url);
        await wait(
          () =>
              model.connection == 'connected' &&
              model.onlineSessions.any(
                (s) => s.instance == originalInstance && s.state == 'running',
              ),
          'disconnecting mobile keeps the same Pi running',
        );
        model.select(originalInstance);
        await wait(
          () => model.selected!.items.any(
            (i) => '${i['text']}'.contains('reply:SLOW DETACH'),
          ),
          'stream resumes after reconnect without aborting',
        );
        await wait(
          () => model.selected!.state == 'idle',
          'Pi finishes its reply without mobile intervention',
        );
        expect(
          model.selected!.items.any((i) => i['is_error'] == true),
          isFalse,
        );
        await tester.tap(find.byKey(Key('session-menu-$originalInstance')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('session-management')), findsOneWidget);
        await tester.tap(find.byKey(const Key('exit-session')));
        await tester.pumpAndSettle();
        expect(find.text('Exit the session on the device?'), findsOneWidget);
        await action('assert-alive', {'index': 0});
        await tester.tap(find.byKey(const Key('confirm-exit-session')));
        await tester.pump();
        await wait(
          () => model.onlineSessions.isEmpty,
          'confirmed management exit removes the restored Pi session',
        );
        await action('assert-closed', {'index': 0});
        await wait(
          () => find.byKey(const Key('session-management')).evaluate().isEmpty,
          'exit waits for confirmation and dismisses management',
        );
        await tester.pumpAndSettle();
        expect(find.text('Restoration check'), findsNothing);
        await tester.tap(find.byKey(const Key('create-session')));
        await tester.pump();
        await wait(
          () => find.byKey(Key('restore-$saved')).evaluate().isNotEmpty,
          'closed session becomes restorable again',
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('new-session-cwd')), cwd);
        await tester.pump();
        await tester.tap(find.byKey(const Key('launch-new-session')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('confirm-create-session')));
        await tester.pump();
        await wait(
          () =>
              find.byKey(const Key('prompt-editor')).evaluate().isNotEmpty &&
              model.selected?.session != saved,
          'create launches a separate Pi session',
        );
        expect(model.onlineSessions.length, 1);
        expect(model.selected!.cwd, cwd);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('back-button')));
        await tester.pumpAndSettle();
        await model.disconnect();
        await action('assert-alive', {'index': 1});
        await model.connect(url);
        await wait(
          () =>
              model.onlineSessions.length == 1 &&
              model.onlineSessions.single.ready,
          'new Pi remains online after mobile disconnect',
        );
        final newInstance = model.onlineSessions.single.instance;
        await tester.tap(find.byKey(Key('session-menu-$newInstance')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('exit-session')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-exit-session')));
        await tester.pump();
        await wait(
          () => model.onlineSessions.isEmpty,
          'confirmed management exit also closes newly created Pi',
        );
        await action('assert-closed', {'index': 1});
        await wait(
          () => find.byKey(const Key('session-management')).evaluate().isEmpty,
          'new Pi exit confirmation finishes',
        );
        await action('report', {
          'checks': checks,
          'historyBlocks': ['body', 'thinking', 'tool'],
        });
      } finally {
        await model.disconnect();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
}
