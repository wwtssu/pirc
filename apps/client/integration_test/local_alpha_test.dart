import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/src/rust/frb_generated.dart';

const url = String.fromEnvironment('PIRC_TEST_URL');
const admin = String.fromEnvironment('PIRC_TEST_ADMIN');

Future<void> action(String path, Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('$admin/$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) throw StateError(text);
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS local Alpha controls real Pi and recovers without duplicates',
    (tester) async {
      // tester.enterText injects edits without notifying the real macOS IME.
      // Use one input channel; the native app, bridge and Pi remain real.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.binding.setSurfaceSize(const Size(430, 820));
      expect(url, isNotEmpty, reason: 'Run through npm run test:flutter:e2e');
      await RustLib.init();
      // Native regression must preserve the user's saved connection and keys.
      final model = PircController()
        ..serverKey = const String.fromEnvironment('PIRC_TEST_SERVER_KEY');
      final capture = GlobalKey();
      final checks = <String>[];
      Future<void> wait(bool Function() condition, String label) async {
        final until = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(until)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (!condition()) {
          debugPrint(
            'FAIL $label: connection=${model.connection}, draft=${model.selected == null ? null : model.draft(model.selected!)}, commands=${model.commands.map((c) => {'kind': c['kind'], 'status': c['status'], 'code': c['code'], 'detail': c['detail']})}, snapshot=${model.selected?.snapshot}',
          );
        }
        expect(condition(), isTrue, reason: label);
        checks.add(label);
        debugPrint('PASS $label');
      }

      bool enabled(String label) {
        final button = tester.widget<IconButton>(
          find.byKey(const Key('composer-action')),
        );
        return button.tooltip == label && button.onPressed != null;
      }

      Future<void> open(String instance, {bool populated = false}) async {
        if (find.byKey(const Key('back-button')).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(const Key('back-button')));
          await tester.pump();
        }
        await tester.tap(find.byKey(Key('session-$instance')));
        await tester.pump();
        await wait(
          () => model.selected!.ready,
          'selected session synchronized',
        );
        if (populated) {
          await wait(
            () => model.selected!.items.isNotEmpty,
            'selected transcript loaded',
          );
        }
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: PircApp(locale: const Locale('en'), controller: model),
          ),
        );
        await tester.tap(find.byKey(const Key('connect-button')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('connection-url')), url);
        await tester.tap(find.byKey(const Key('connect-submit')));
        await wait(
          () => model.sessions.length == 3 && model.connection == 'connected',
          'three independent sessions discovered',
        );
        final one = model.sessions
            .singleWhere((s) => s.cwd.endsWith('pi-one'))
            .instance;
        final two = model.sessions
            .singleWhere((s) => s.cwd.endsWith('pi-two'))
            .instance;
        await open('retained-fixture', populated: true);
        expect(model.selected!.gaps, isEmpty);
        expect(
          model.selected!.items.single['text'],
          'Message after retention limit',
        );
        checks.add('materialized history survives raw event retention');
        await open(one);
        await tester.tap(find.byKey(const Key('session-model')));
        await wait(
          () => find
              .byKey(const ValueKey('model-pirc-test/controlled-reasoning'))
              .evaluate()
              .isNotEmpty,
          'model selector loads authenticated catalogue',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('model-pirc-test/controlled-reasoning')),
        );
        await tester.tap(
          find.byKey(const ValueKey('model-pirc-test/controlled-reasoning')),
        );
        await wait(
          () =>
              (model.selected!.snapshot['controls'] as Map?)?['model']?['id'] ==
              'controlled-reasoning',
          'native Flutter model command changes current Pi model',
        );
        await wait(
          () => find
              .byKey(const ValueKey('model-pirc-test/controlled-reasoning'))
              .evaluate()
              .isEmpty,
          'model selector closes after confirmation',
        );
        await tester.pumpAndSettle();
        expect(find.text('pirc reasoning test'), findsOneWidget);
        await tester.tap(find.byKey(const Key('session-thinking')));
        await wait(
          () =>
              find.byKey(const ValueKey('thinking-high')).evaluate().isNotEmpty,
          'thinking selector reflects current model',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('thinking-high')));
        await tester.tap(find.byKey(const ValueKey('thinking-high')));
        await wait(
          () =>
              (model.selected!.snapshot['controls']
                  as Map?)?['thinking_level'] ==
              'high',
          'native Flutter thinking command confirmed',
        );
        await wait(
          () => find.byKey(const ValueKey('thinking-high')).evaluate().isEmpty,
          'thinking selector closes',
        );
        await tester.pumpAndSettle();
        expect(find.text('high'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'Panel actions should preserve the draft',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('session-name')));
        await wait(
          () =>
              find
                  .byKey(const Key('session-name-editor'))
                  .evaluate()
                  .isNotEmpty &&
              model.commands.last['status'] == 'completed',
          'rename panel loads current name',
        );
        await tester.enterText(
          find.byKey(const Key('session-name-editor')),
          'Flutter built-in command',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-session-name')));
        await wait(
          () => model.selected!.name == 'Flutter built-in command',
          'native Flutter rename synchronized',
        );
        await wait(
          () => find.byKey(const Key('session-name-editor')).evaluate().isEmpty,
          'rename panel closes',
        );
        await tester.pumpAndSettle();
        expect(find.text('Flutter built-in command'), findsOneWidget);
        expect(
          model.draft(model.selected!),
          'Panel actions should preserve the draft',
        );
        checks.add(
          'model, thinking and name stay visible after confirmation; header actions preserve draft',
        );
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          '/session',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              find.text('Session ID').evaluate().isNotEmpty ||
              model.commands.last['kind'] == 'session' &&
                  model.commands.last['status'] == 'completed',
          'native Flutter session statistics loaded',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        final contextPrompt = 'Keep the task and results.' * 600;
        await action('input', {'pane': 'pi-one', 'text': contextPrompt});
        await wait(
          () =>
              model.selected!.state == 'idle' &&
              model.selected!.items.any(
                (i) => i['role'] == 'user' && i['text'] == contextPrompt,
              ),
          'prepare context for native compaction',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          '/compact Keep the task',
        );
        await tester.pump();
        await wait(
          () =>
              enabled('Send') &&
              model.draft(model.selected!) == '/compact Keep the task',
          'compaction composer ready',
        );
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              model.commands.any(
                (c) => c['kind'] == 'compact' && c['status'] == 'completed',
              ) &&
              model.selected!.state == 'idle',
          'native Flutter compaction completed without prompt dispatch',
        );
        expect(
          model.selected!.items
              .where((i) => i['role'] == 'user')
              .every((i) => !(i['text'] as String).startsWith('/')),
          isTrue,
        );
        await action('input', {'pane': 'pi-one', 'text': 'SLOW from terminal'});
        await wait(
          () =>
              model.selected!.state == 'running' &&
              model.selected!.items.any(
                (i) =>
                    i['role'] == 'assistant' &&
                    (i['text'] as String).isNotEmpty,
              ),
          'terminal prompt and live assistant deltas visible',
        );
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'QUICK rewritten from Flutter',
        );
        await tester.pump();
        await wait(
          () => model.draft(model.selected!) == 'QUICK rewritten from Flutter',
          'draft prepared while Pi is running',
        );
        expect(enabled('Send'), isFalse);
        expect(enabled('Stop'), isTrue);
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              model.selected!.state == 'idle' &&
              model.commands.any(
                (c) => c['kind'] == 'stop' && c['status'] == 'completed',
              ),
          'Stop waits for confirmed idle',
        );
        await wait(
          () =>
              enabled('Send') &&
              model.draft(model.selected!) == 'QUICK rewritten from Flutter',
          'rewrite draft preserved and send button ready after Stop',
        );
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              model.commands.any(
                (c) => c['kind'] == 'prompt' && c['status'] == 'accepted',
              ) &&
              model.selected!.state == 'idle',
          'Flutter prompt continues same Pi session',
        );
        expect(model.draft(model.selected!), isEmpty);
        await action('input', {
          'pane': 'pi-one',
          'text': 'STREAM thinking and tools',
        });
        await wait(
          () => model.selected!.items.any(
            (i) =>
                i['role'] == 'assistant' &&
                i['text'] == '' &&
                i['complete'] == false,
          ),
          'empty assistant renders loading while model starts',
        );
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expect(find.text('Replying…'), findsNothing);
        await wait(
          () => model.selected!.items.any(
            (i) =>
                i['role'] == 'thinking' &&
                i['text'] == 'Check first' &&
                i['complete'] == false,
          ),
          'thinking visible before thinking completes',
        );
        await wait(
          () =>
              model.selected!.items.any(
                (i) => i['text'] == 'Starting tool' && i['complete'] == false,
              ) &&
              model.selected!.items
                  .where((i) => i['role'] == 'thinking')
                  .every((i) => i['complete'] == true),
          'thinking finishes as answer streams even without thinking_end',
        );
        await wait(
          () => model.selected!.items.any(
            (i) =>
                i['role'] == 'tool' &&
                i['arguments'] == '{"label":' &&
                i['phase'] == 'generating',
          ),
          'tool arguments visible before JSON is complete',
        );
        final toolId = model.selected!.items.singleWhere(
          (i) => i['title'] == 'e2e_stream',
        )['id'];
        await wait(
          () => model.selected!.items.any(
            (i) =>
                i['id'] == toolId &&
                i['text'] == 'Tool output 1' &&
                i['complete'] == false,
          ),
          'tool output visible while execution is running',
        );
        await wait(
          () => model.selected!.items.any(
            (i) =>
                i['id'] == toolId &&
                i['text'] == 'Tool output 1\nTool output 2' &&
                i['complete'] == false,
          ),
          'tool cumulative output updates without duplicating lines',
        );
        final before = model.selected!.items.indexWhere(
          (i) => i['text'] == 'Starting tool',
        );
        final toolPosition = model.selected!.items.indexWhere(
          (i) => i['id'] == toolId,
        );
        final after = model.selected!.items.indexWhere(
          (i) => i['text'] == 'Arguments ready',
        );
        expect(before, greaterThanOrEqualTo(0));
        expect(toolPosition, greaterThan(before));
        expect(after, greaterThan(toolPosition));
        await wait(
          () =>
              model.selected!.state == 'idle' &&
              model.selected!.items.any(
                (i) => i['id'] == toolId && i['complete'] == true,
              ),
          'streamed tool completes in its original transcript position',
        );
        expect(
          model.selected!.items.indexWhere((i) => i['id'] == toolId),
          toolPosition,
        );
        checks.add('text before and after a tool call stays in content order');
        model.setDraft(model.selected!, 'Draft for session one');
        await open(two);
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'Draft for session two',
        );
        await action('input', {
          'pane': 'pi-two',
          'text': 'QUICK second terminal',
        });
        await wait(
          () =>
              model.selected!.items.any(
                (i) => i['text'] == 'QUICK second terminal',
              ) &&
              model.selected!.state == 'idle',
          'second Pi stays independent',
        );
        expect(
          model.selected!.items.any(
            (i) => (i['text'] as String).contains('rewritten from Flutter'),
          ),
          isFalse,
        );
        await open(one);
        expect(model.draft(model.selected!), 'Draft for session one');
        await wait(
          () => model.selected!.items.isNotEmpty,
          'first transcript restored on mobile navigation',
        );
        final ids = model.selected!.items.map((i) => i['id']).toList();
        await model.reconnect();
        await wait(
          () =>
              model.connection == 'reconnecting' ||
              model.connection == 'syncing' ||
              !model.selected!.ready,
          'reconnect gates controls',
        );
        await tester.pump();
        expect(enabled('Send'), isFalse);
        await wait(
          () => model.connection == 'connected' && model.selected!.ready,
          'replay completed after reconnect',
        );
        expect(model.selected!.items.map((i) => i['id']).toList(), ids);
        expect(model.draft(model.selected!), 'Draft for session one');
        checks.add('replay deduplicates messages and preserves draft');
        await action('input', {'pane': 'pi-one', 'text': 'SLOW terminal wins'});
        await wait(
          () => model.selected!.state == 'running',
          'local input gates remote send',
        );
        expect(enabled('Send'), isFalse);
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () => model.selected!.state == 'idle',
          'local task can be stopped from Flutter',
        );
        final historyBeforeRestart = model.selected!.items
            .where((item) => !['loading', 'error'].contains(item['role']))
            .map((item) => {'role': item['role'], 'text': item['text']})
            .toList();
        await action('restart', {});
        await wait(
          () =>
              model.connection == 'connected' &&
              model.selected!.ready &&
              model.selected!.snapshot['needs_local_attention'] == false &&
              model.selected!.state == 'idle' &&
              model.selected!.items.any(
                (item) => item['text'] == 'QUICK lost while offline',
              ),
          'service restart rebuilds history and offline messages',
        );
        expect(model.selected!.gaps, isEmpty);
        for (final previous in historyBeforeRestart) {
          expect(
            model.selected!.items.any(
              (item) =>
                  item['role'] == previous['role'] &&
                  item['text'] == previous['text'],
            ),
            isTrue,
            reason: 'Recovered history: $previous',
          );
        }
        expect(model.draft(model.selected!), 'Draft for session one');
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'QUICK after restart',
        );
        await tester.pump();
        expect(model.draft(model.selected!), 'QUICK after restart');
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              model.selected!.items.any(
                (i) => i['text'] == 'QUICK after restart',
              ) &&
              model.selected!.state == 'idle',
          'fresh commands work after service restart',
        );
        await model.flushDrafts();
        await tester.pump();
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await action('screenshot', {
          'png': base64Encode(bytes!.buffer.asUint8List()),
        });
        final closeStart = DateTime.now();
        await model.disconnect().timeout(const Duration(seconds: 3));
        checks.add('disconnect completes without stream cancellation deadlock');
        await model.connect(url);
        await wait(
          () =>
              model.connection == 'connected' && model.selected?.ready == true,
          'connection can be replaced after disconnect',
        );
        checks.add(
          'disconnect duration ${DateTime.now().difference(closeStart).inMilliseconds} ms including reconnect',
        );
        await action('report', {'checks': checks});
      } finally {
        await model.disconnect();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
