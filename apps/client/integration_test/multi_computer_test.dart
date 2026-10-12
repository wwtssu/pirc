import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/connection_store.dart';
import 'package:pirc/main.dart';
import 'package:pirc/src/rust/frb_generated.dart';

// Two isolated real Servers and simulated local agents. No user's agent is touched.
class ComputerPeer {
  ComputerPeer(this.url, this.name, this.socket);
  final String url;
  final String name;
  final WebSocket socket;
  final prompts = <String>[];
  bool closed = false;
  int sequence = 0;
  Timer? heartbeat;
  Map<String, dynamic> get identity => {
    'session_id': 'same-session',
    'instance_id': 'same-instance',
  };
  Map<String, dynamic> get snapshot => {
    ...identity,
    'agent_id': 'pi',
    'cwd': '/tmp/$name',
    'name': 'Conversation $name',
    'state': 'idle',
    'revision': 1,
    'needs_local_attention': false,
  };
  static Future<ComputerPeer> start(String name) async {
    const a = String.fromEnvironment('PIRC_TEST_SERVER_A');
    const b = String.fromEnvironment('PIRC_TEST_SERVER_B');
    final url = name == 'A' ? a : b;
    if (url.isEmpty) {
      throw StateError(
        'Run npm run test:flutter:encrypted from the project root',
      );
    }
    const agentA = String.fromEnvironment('PIRC_TEST_AGENT_SERVER_A');
    const agentB = String.fromEnvironment('PIRC_TEST_AGENT_SERVER_B');
    final agentUrl = name == 'A' ? agentA : agentB;
    final endpoint = Uri.parse(
      computerAddress(agentUrl.isEmpty ? url : agentUrl),
    ).replace(scheme: 'ws', path: '/extension');
    final socket = await WebSocket.connect(endpoint.toString());
    final peer = ComputerPeer(url, name, socket);
    socket.listen((raw) {
      final envelope = jsonDecode(raw as String) as Map<String, dynamic>;
      final message = envelope['message'] as Map<String, dynamic>;
      final request = envelope['request_id'] as String;
      if (message['type'] == 'welcome') {
        peer.send('register', {'type': 'register', 'session': peer.snapshot});
      } else if (message['type'] == 'prompt') {
        peer.prompts.add(message['text'] as String);
        peer.send(request, {
          'type': 'command_result',
          ...peer.identity,
          'status': 'accepted',
          'code': null,
          'detail': null,
        });
      }
    });
    peer.send('auth', {'type': 'auth'});
    peer.heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
      peer.send('heartbeat', {
        'type': 'heartbeat',
        'session': peer.snapshot,
        'source_seq': peer.sequence,
      });
    });
    return peer;
  }

  void send(String requestId, Map<String, dynamic> message) => socket.add(
    jsonEncode({'version': 1, 'request_id': requestId, 'message': message}),
  );
  void message(String text) {
    sequence++;
    send('event-$sequence', {
      'type': 'event',
      ...identity,
      'seq': 0,
      'source_seq': sequence,
      'event': {
        'kind': 'user_message',
        'message_id': 'message-$sequence',
        'text': text,
        'content_index': null,
        'tool_call_id': null,
        'tool_name': null,
        'is_error': false,
        'truncated': false,
      },
    });
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    heartbeat?.cancel();
    await socket.close();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('PIRC_TEST_REPORT_COMPLETION')) {
    unawaited(
      binding.allTestsPassed.future.then(
        (passed) => debugPrint('PIRC_TEST_RESULT ${passed ? 'PASS' : 'FAIL'}'),
      ),
    );
  }
  testWidgets(
    'native app maintains two live Rust clients and routes switching, updates and commands independently',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await RustLib.init();
      final a = await ComputerPeer.start('A');
      final b = await ComputerPeer.start('B');
      final computers = ComputerConnections();
      Future<void> wait(bool Function() check, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!check() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(check(), isTrue, reason: label);
        debugPrint('PASS $label');
      }

      try {
        await tester.pumpWidget(
          PircApp(locale: const Locale('en'), computers: computers),
        );
        await computers.addComputer(a.url, name: 'Device A');
        final first = computers.active;
        expect(
          first.controller.error,
          isNull,
          reason: 'computer A initializes development key storage',
        );
        await wait(
          () => find
              .byKey(const Key('server-approval-dialog'))
              .evaluate()
              .isNotEmpty,
          'computer A waits for server approval',
        );
        expect(first.controller.connection, 'pairing');
        expect(first.controller.serverKey, isNull);
        expect(
          first.controller.pairing?['code'],
          matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')),
        );
        debugPrint('PIRC_TEST_ALLOW A ${first.controller.pairing!['code']}');
        await wait(
          () =>
              first.controller.connection == 'connected' &&
              find
                  .byKey(const Key('server-approval-dialog'))
                  .evaluate()
                  .isEmpty,
          'computer A encrypted channel authenticated',
        );
        await computers.addComputer(b.url, name: 'Device B');
        final second = computers.active;
        await wait(
          () =>
              second.controller.pairing != null &&
              find
                  .byKey(const Key('server-approval-dialog'))
                  .evaluate()
                  .isNotEmpty,
          'computer B waits for server approval',
        );
        expect(second.controller.serverKey, isNull);
        expect(
          second.controller.pairing?['code'],
          matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$')),
        );
        debugPrint('PIRC_TEST_ALLOW B ${second.controller.pairing!['code']}');
        await wait(
          () => computers.computers.every(
            (c) =>
                c.controller.connection == 'connected' &&
                c.controller.selected?.ready == true,
          ),
          'both real Rust sockets connected and synchronized',
        );
        first.controller.setDraft(first.controller.selected!, 'Draft for A');
        second.controller.setDraft(second.controller.selected!, 'Send to B');

        Future<void> select(ComputerConnection computer) async {
          if (find.byKey(const Key('back-button')).evaluate().isNotEmpty) {
            await tester.tap(find.byKey(const Key('back-button')));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const Key('drawer-button')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(ValueKey('computer-${computer.endpoint}')),
          );
          await tester.pumpAndSettle();
          expect(computers.active, computer);
          await tester.tap(find.byKey(const Key('session-same-instance')));
          await tester.pumpAndSettle();
        }

        await select(first);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('prompt-editor')))
              .controller!
              .text,
          'Draft for A',
        );
        await select(second);
        a.message('New message received by A in background');
        await wait(
          () => first.controller.selected!.items.any(
            (i) => i['text'] == 'New message received by A in background',
          ),
          'inactive computer continues receiving live messages',
        );
        expect(
          find.text('New message received by A in background'),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('composer-action')));
        await wait(
          () =>
              b.prompts.length == 1 &&
              second.controller.draft(second.controller.selected!).isEmpty,
          'prompt and acknowledgment routed only to computer B',
        );
        expect(a.prompts, isEmpty);
        expect(
          first.controller.draft(first.controller.selected!),
          'Draft for A',
        );
        await select(first);
        expect(
          find.text('New message received by A in background'),
          findsOneWidget,
        );
        expect(first.controller.serverKey, isNotNull);
        expect(second.controller.serverKey, isNotNull);
        expect(first.controller.currentAddress, computerAddress(a.url));
        expect(second.controller.currentAddress, computerAddress(b.url));
        debugPrint('PASS switching never reconnects either computer');
        await first.controller.disconnect();
        await wait(
          () => first.controller.connection == 'disconnected',
          'computer A disconnect is isolated',
        );
        expect(second.controller.connection, 'connected');
        expect(tester.takeException(), isNull);
      } finally {
        for (final computer in computers.computers) {
          await computer.controller.disconnect();
        }
        await tester.pumpWidget(const SizedBox());
        computers.dispose();
        await a.close();
        await b.close();
      }
    },
  );
}
