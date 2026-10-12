import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

Map<String, dynamic> session(
  String id, {
  bool managed = true,
  String state = 'idle',
}) => {
  'snapshot': {
    'session_id': 's-$id',
    'instance_id': id,
    'cwd': '/tmp/$id',
    'name': 'Session $id',
    'state': state,
    'revision': 1,
    'needs_local_attention': false,
    if (managed) 'launch_id': 'launch-$id',
    'can_close': managed,
  },
  'ready': true,
  'items': [],
  'gaps': [],
};

class ManagementController extends PircController {
  final exits = <String>[];
  final completed = Completer<void>();
  void update({
    bool managed = true,
    String state = 'idle',
    String connection = 'connected',
  }) {
    applyDecodedView({
      'connection': connection,
      'error': null,
      'commands': [],
      'sessions': [
        session('i', managed: managed, state: state),
        session('other'),
      ],
    });
  }

  @override
  Future<void> exitSession(SessionView target) async {
    final reason = exitDisabledReason(target);
    if (reason != null) throw StateError(reason);
    exits.add(target.instance);
    await completed.future;
    update(state: 'offline');
  }
}

void main() {
  testWidgets(
    'list menu button requires confirmation and exits only its target with drafts retained',
    (tester) async {
      final model = ManagementController()..update();
      model.select('other');
      model.setDraft(model.sessions.first, 'Keep draft');
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-menu-i')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-management')), findsOneWidget);
      expect(model.exits, isEmpty);
      expect(model.selectedInstance, 'other');
      expect(find.byKey(const Key('prompt-editor')), findsNothing);
      await tester.tap(find.byKey(const Key('exit-session')));
      await tester.pumpAndSettle();
      expect(find.text('Exit the session on the device?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(model.exits, isEmpty);
      await tester.tap(find.byKey(const Key('exit-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-exit-session')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(model.exits, ['i']);
      expect(find.text('Exiting…'), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.byKey(const Key('exit-session'))).onTap,
        isNull,
      );
      model.completed.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('session-management')), findsNothing);
      expect(model.onlineSessions.single.instance, 'other');
      expect(model.draft(model.sessions.first), 'Keep draft');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'manual sessions and running managed sessions are disabled with an explanation',
    (tester) async {
      final model = ManagementController()..update(managed: false);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-menu-i')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This session was started on the device. Exit it on the device.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ListTile>(find.byKey(const Key('exit-session'))).enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('exit-session')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exit-session-confirmation')), findsNothing);
      model.update(state: 'running');
      await tester.pumpAndSettle();
      expect(
        find.text('A task is running. Stop it before exiting.'),
        findsOneWidget,
      );
      expect(
        tester.widget<ListTile>(find.byKey(const Key('exit-session'))).onTap,
        isNull,
      );
      model.update(connection: 'syncing');
      await tester.pumpAndSettle();
      expect(
        find.text('Wait for the connection and session to sync, then retry.'),
        findsOneWidget,
      );
      expect(model.exits, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'a task starting during confirmation disables exit without stopping Pi',
    (tester) async {
      final model = ManagementController()..update();
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-menu-i')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exit-session')));
      await tester.pumpAndSettle();
      model.update(state: 'running');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('confirm-exit-session')))
            .onPressed,
        isNull,
      );
      expect(
        find.text('A task is running. Stop it before exiting.'),
        findsNWidgets(2),
      );
      expect(model.exits, isEmpty);
      expect(model.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
