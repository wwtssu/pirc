import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc/src/rust/api/simple.dart';
import 'package:pirc/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets('Rust core encodes prompt and rejects stopping state', (
    tester,
  ) async {
    expect(protocolVersion(), 1);
    final encoded = await encodePrompt(
      requestId: 'req-1',
      generationId: 'generation-1',
      expectedRevision: 3,
      sessionId: 'session-1',
      instanceId: 'instance-1',
      text: 'Continue 🦀',
      state: ExecutionState.idle,
    );
    final message = jsonDecode(encoded) as Map<String, dynamic>;
    expect(message['message']['text'], 'Continue 🦀');
    expect(message['message']['instance_id'], 'instance-1');
    expect(message['message']['generation_id'], 'generation-1');
    expect(message['message']['expected_revision'], 3);
    await expectLater(
      encodePrompt(
        requestId: 'req-2',
        generationId: 'generation-1',
        expectedRevision: 3,
        sessionId: 'session-1',
        instanceId: 'instance-1',
        text: 'Continue',
        state: ExecutionState.stopping,
      ),
      throwsA(anything),
    );
  });
}
