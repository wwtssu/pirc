import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

const outputUrl = String.fromEnvironment('PIRC_SCREENSHOT_URL');

// Documentation screenshots use the real client with public demonstration data.
Map<String, dynamic> session(
  String id,
  String name,
  String cwd, {
  List<Map<String, dynamic>> items = const [],
}) => {
  'snapshot': {
    'agent_id': 'pi',
    'session_id': id,
    'instance_id': id,
    'cwd': cwd,
    'name': name,
    'state': 'idle',
    'revision': 1,
    'needs_local_attention': false,
    'controls': {
      'model': {
        'provider': 'anthropic',
        'id': 'claude-sonnet-4-5',
        'name': 'Claude Sonnet 4.5',
      },
      'thinking_level': 'medium',
      'compacting': false,
    },
    'slash_commands': [
      for (final name in ['model', 'thinking', 'name', 'session'])
        {'name': name, 'description': '', 'source': 'builtin'},
    ],
  },
  'ready': true,
  'gaps': [],
  'items': items,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture English client screenshots for the README', (
    tester,
  ) async {
    expect(outputUrl, isNotEmpty);
    await tester.binding.setSurfaceSize(const Size(430, 880));
    final controller = PircController()
      ..applyDecodedView({
        'connection': 'connected',
        'error': null,
        'commands': [],
        'sessions': [
          session(
            'api',
            'Refactor API client',
            '/workspace/atlas',
            items: [
              {
                'id': 'question',
                'role': 'user',
                'text': 'Simplify the API client and check the tests.',
                'complete': true,
              },
              {
                'id': 'thinking',
                'role': 'thinking',
                'text': 'I will inspect the request helpers, remove duplicate handling, and run the focused tests.',
                'complete': true,
              },
              {
                'id': 'tool',
                'role': 'tool',
                'title': 'bash',
                'phase': 'completed',
                'arguments': '{"command":"npm test"}',
                'text': '12 tests passed',
                'complete': true,
              },
              {
                'id': 'answer',
                'role': 'assistant',
                'text': 'The API client now uses a **single request helper**.\n\n- Shared timeout and error handling\n- Clearer response types\n- All **12 tests** passed\n\n| Area | Result |\n| --- | --- |\n| Requests | Simplified |\n| Tests | Passed |\n\nThe changes are ready for review.',
                'complete': true,
              },
            ],
          ),
          session('docs', 'Update documentation', '/workspace/docs'),
          session('release', 'Prepare a release', '/workspace/cli'),
        ],
      });
    final devices = ComputerConnections(initialController: controller);
    devices.active.name = 'Development workstation';
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: PircApp(computers: devices, locale: const Locale('en')),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> save(String name) async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final client = HttpClient();
      try {
        final request = await client.postUrl(Uri.parse('$outputUrl/$name'));
        request.add(data!.buffer.asUint8List());
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      } finally {
        client.close();
      }
    }

    await save('client-sessions-en.png');
    await tester.tap(find.byKey(const Key('session-api')));
    await tester.pumpAndSettle();
    await save('client-conversation-en.png');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    devices.dispose();
    controller.dispose();
  });
}
