import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

class ComputerController extends PircController {
  int connects = 0;
  int disconnects = 0;
  final sends = <String>[];

  void update([String text = '']) => applyDecodedView({
    'connection': 'connected',
    'error': null,
    'commands': [],
    'sessions': [
      {
        'snapshot': {
          'agent_id': 'pi',
          'session_id': 'same-session',
          'instance_id': 'same-instance',
          'cwd': '/tmp/project',
          'name': 'Conversation',
          'state': 'idle',
          'revision': 1,
          'needs_local_attention': false,
        },
        'ready': true,
        'items': text.isEmpty
            ? []
            : [
                {
                  'id': 'reply',
                  'role': 'assistant',
                  'text': text,
                  'complete': true,
                },
              ],
        'gaps': [],
      },
    ],
  });

  @override
  Future<void> connect(String url, {bool pairAgain = false}) async {
    connects++;
    endpoint = url;
    update();
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    await super.disconnect();
  }

  @override
  Future<void> send() async => sends.add(draft(selected!));
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'flat computer list switches views on a $width phone while both connections and drafts stay isolated',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final computers = ComputerConnections(
          controllerFactory: ComputerController.new,
        );
        await computers.addComputer(
          'http://computer-a/control',
          name: 'Device A',
        );
        final a = computers.active;
        await computers.addComputer(
          'http://computer-b/control',
          name: 'Device B',
        );
        final b = computers.active;
        a.controller.setDraft(a.controller.selected!, 'Draft for A');
        b.controller.setDraft(b.controller.selected!, 'Draft for B');
        await tester.pumpWidget(PircApp(computers: computers));

        Future<void> switchTo(ComputerConnection computer) async {
          if (find.byKey(const Key('back-button')).evaluate().isNotEmpty) {
            await tester.tap(find.byKey(const Key('back-button')));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byKey(const Key('drawer-button')));
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(find.byKey(const Key('settings-drawer'))).dx,
            0,
          );
          final drawer = find.byKey(const Key('settings-drawer'));
          expect(
            find.descendant(of: drawer, matching: find.text('Device A')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: drawer, matching: find.text('Device B')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('add-computer')), findsOneWidget);
          await tester.tap(
            find.byKey(ValueKey('computer-${computer.endpoint}')),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('connection-url')), findsNothing);
          expect(computers.active, computer);
          await tester.tap(find.byKey(const Key('session-same-instance')));
          await tester.pumpAndSettle();
        }

        await switchTo(a);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('prompt-editor')))
              .controller!
              .text,
          'Draft for A',
        );
        await tester.tap(find.byKey(const Key('composer-action')));
        await tester.pumpAndSettle();
        expect((a.controller as ComputerController).sends, ['Draft for A']);
        expect((b.controller as ComputerController).sends, isEmpty);
        await switchTo(b);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('prompt-editor')))
              .controller!
              .text,
          'Draft for B',
        );
        (a.controller as ComputerController).update(
          'New background message for A',
        );
        await tester.pumpAndSettle();
        expect(find.text('New background message for A'), findsNothing);
        await switchTo(a);
        expect(find.text('New background message for A'), findsOneWidget);
        expect((a.controller as ComputerController).connects, 1);
        expect((b.controller as ComputerController).connects, 1);
        expect((a.controller as ComputerController).disconnects, 0);
        expect((b.controller as ComputerController).disconnects, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        computers.dispose();
      },
    );
  }

  testWidgets(
    'adding a computer from the list uses its own connection; cancelling preserves the current computer and draft',
    (tester) async {
      final computers = ComputerConnections(
        controllerFactory: ComputerController.new,
      );
      await computers.addComputer(
        'http://computer-a/control',
        name: 'Device A',
      );
      final a = computers.active;
      a.controller.setDraft(a.controller.selected!, 'Draft for A');
      await tester.pumpWidget(PircApp(computers: computers));
      await tester.tap(find.byKey(const Key('session-same-instance')));
      await tester.pumpAndSettle();
      Future<void> add() async {
        if (find.byKey(const Key('back-button')).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(const Key('back-button')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('drawer-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('add-computer')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('connection-url')))
              .controller!
              .text,
          '',
        );
        expect(find.byKey(const Key('connection-token')), findsNothing);
      }

      await add();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(computers.active, a);
      await tester.tap(find.byKey(const Key('session-same-instance')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-editor')))
            .controller!
            .text,
        'Draft for A',
      );
      await add();
      await tester.enterText(
        find.byKey(const Key('connection-name')),
        'Device B',
      );
      await tester.enterText(
        find.byKey(const Key('connection-url')),
        'http://computer-b/control',
      );
      await tester.tap(find.byKey(const Key('connect-submit')));
      await tester.pumpAndSettle();
      expect(computers.computers.length, 2);
      expect(computers.active.displayName, 'Device B');
      expect(a.controller.connection, 'connected');
      expect((a.controller as ComputerController).disconnects, 0);
      expect(find.byKey(const Key('prompt-editor')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      computers.dispose();
    },
  );
}
