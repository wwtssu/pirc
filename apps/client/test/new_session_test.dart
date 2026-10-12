import 'package:pirc/pirc_localizations.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/new_session_page.dart';
import 'package:pirc/pirc_theme.dart';
import 'package:pirc/pirc_loading.dart';

class CreationController extends PircController {
  final catalog = Completer<SavedSessionCatalog>();
  final launched = Completer<String>();
  final calls = <(String, String?)>[];
  final names = <String?>[];
  @override
  Future<SavedSessionCatalog> loadSavedSessions() => catalog.future;
  @override
  Future<String> launchSession(String cwd, {String? sessionId, String? name}) {
    calls.add((cwd, sessionId));
    names.add(name);
    return launched.future;
  }
}

Map<String, dynamic> view(String state) => {
  'connection': 'connected',
  'error': null,
  'commands': [],
  'sessions': [
    {
      'snapshot': {
        'session_id': 's',
        'instance_id': 'i',
        'cwd': '/tmp/project',
        'name': 'Old instance',
        'state': state,
        'needs_local_attention': false,
      },
      'ready': true,
      'items': [],
      'gaps': [],
    },
  ],
};
SavedSession saved(String id, String name) => SavedSession({
  'session_id': id,
  'name': name,
  'cwd': '/tmp/project',
  'modified_ms': 1700000000000,
});
void main() {
  testWidgets(
    'returning to the list only ends viewing and keeps the session and draft',
    (tester) async {
      for (final state in ['idle', 'running']) {
        final model = CreationController()..applyDecodedView(view(state));
        final snapshot = model.sessions.single.snapshot;
        snapshot['launch_id'] = 'legacy-launch';
        snapshot['can_close'] = true;
        await tester.pumpWidget(
          PircApp(key: ValueKey(state), controller: model),
        );
        await tester.tap(find.text('Old instance'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'Preserved draft',
        );
        expect(find.byKey(const Key('close-session')), findsNothing);
        expect(find.byKey(const Key('session-menu')), findsNothing);
        await tester.tap(find.byKey(const Key('back-button')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.connection, 'connected');
        expect(model.sessions.single.state, state);
        expect(model.commands, isEmpty);
        expect(model.draft(model.sessions.single), 'Preserved draft');
        expect(find.byKey(const Key('create-session')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
  testWidgets(
    'offline instances stay out of the main list and leave creation available',
    (tester) async {
      final model = CreationController()..applyDecodedView(view('offline'));
      await tester.pumpWidget(PircApp(controller: model));
      expect(find.text('Old instance'), findsNothing);
      expect(find.text('No active sessions'), findsOneWidget);
      await tester.tap(find.byKey(const Key('create-session')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('New conversation'), findsOneWidget);
      expect(find.byType(PircLoading), findsOneWidget);
      model.catalog.complete(
        SavedSessionCatalog(
          sessions: [saved('s', 'Restored name')],
          defaultCwd: '/tmp/project',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restored name'), findsOneWidget);
      await tester.tap(find.byKey(const Key('restore-s')));
      await tester.pump();
      expect(model.calls, [('/tmp/project', 's')]);
      expect(
        find.text('Restoring conversation and waiting for the session…'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('launch-new-session')))
            .onPressed,
        isNull,
      );
      model.applyDecodedView(view('idle'));
      model.launched.complete('i');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('prompt-editor')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'saved sessions filter live identities and support searching and creation',
    (tester) async {
      final model = CreationController()..applyDecodedView(view('idle'));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      model.catalog.complete(
        SavedSessionCatalog(
          sessions: [
            saved('s', 'Online session'),
            saved('old', 'Fix login'),
            saved('other', 'Protocol cleanup'),
          ],
          defaultCwd: '/tmp/project',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Online session'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('saved-session-search')),
        'login',
      );
      await tester.pump();
      expect(find.text('Fix login'), findsOneWidget);
      expect(find.text('Protocol cleanup'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('new-session-cwd')),
        '/tmp/new',
      );
      await tester.tap(find.byKey(const Key('launch-new-session')));
      await tester.pump();
      expect(model.calls, isEmpty);
      await tester.tap(find.byKey(const Key('confirm-create-session')));
      await tester.pump();
      expect(model.calls, [('/tmp/new', null)]);
      expect(model.names, [null]);
      model.launched.completeError(
        StateError('Working directory does not exist'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Working directory does not exist'), findsOneWidget);
      await tester.tap(find.byKey(const Key('dismiss-session-launch-error')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('new-session-cwd')))
            .controller!
            .text,
        '/tmp/new',
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'creation name can be cancelled and submitted with the keyboard',
    (tester) async {
      final model = CreationController()..applyDecodedView(view('idle'));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      model.catalog.complete(
        SavedSessionCatalog(sessions: [], defaultCwd: '/tmp/project'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('launch-new-session')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('create-session-name-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('/256'), findsNothing);
      expect(model.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(model.calls, isEmpty);
      await tester.tap(find.byKey(const Key('launch-new-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('create-session-name')),
        '  Fix login  ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 400));
      expect(model.names, ['Fix login']);
      expect(model.calls, [('/tmp/project', null)]);
      expect(find.byKey(const Key('session-launch-dialog')), findsOneWidget);
      model.launched.completeError(StateError('Test finished'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('dismiss-session-launch-error')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'restore loading stays visible after scrolling and times out safely',
    (tester) async {
      final model = CreationController()..applyDecodedView(view('offline'));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      model.catalog.complete(
        SavedSessionCatalog(
          sessions: List.generate(
            25,
            (i) => saved('old-$i', 'Saved session $i'),
          ),
          defaultCwd: '/tmp/project',
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('restore-old-24')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('restore-old-24')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('session-launch-dialog')), findsOneWidget);
      expect(
        find.text('Restoring conversation and waiting for the session…'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(find.byKey(const Key('session-launch-dialog')), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pump();
      expect(
        find.textContaining('Timed out waiting for the session'),
        findsOneWidget,
      );
      expect(find.byType(PircLoading), findsNothing);
      await tester.tap(find.byKey(const Key('dismiss-session-launch-error')));
      await tester.pumpAndSettle();
      model.launched.complete('late-instance');
      await tester.pumpAndSettle();
      expect(find.byType(NewSessionPage), findsOneWidget);
      expect(model.calls, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'creation stays usable on narrow phones with keyboard and large text',
    (tester) async {
      final model = CreationController()..applyDecodedView(view('idle'));
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: NewSessionPage(model: model),
        ),
      );
      model.catalog.complete(
        SavedSessionCatalog(
          sessions: [saved('old', 'A very long session name' * 10)],
          defaultCwd: '/tmp/project',
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
