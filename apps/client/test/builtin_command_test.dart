import 'package:pirc/pirc_localizations.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/builtin_command_sheet.dart';
import 'package:pirc/pirc_theme.dart';

class BuiltinController extends PircController {
  final calls = <(String, String)>[];
  final query = Completer<Map<String, dynamic>>();
  String? failure;
  @override
  Future<Map<String, dynamic>> runBuiltin(
    SessionView session,
    String command, [
    String args = '',
  ]) async {
    calls.add((command, args));
    if (args.isEmpty) return query.future;
    if (failure != null) throw StateError(failure!);
    return {'kind': command};
  }
}

class RoleController extends BuiltinController {
  String? taskSelector;
  final catalogModels = [
    {'provider': 'test', 'id': 'first', 'name': 'First model'},
    {'provider': 'test', 'id': 'second', 'name': 'Second model'},
  ];
  Map<String, dynamic> get catalog => {
    'kind': 'model',
    'current': catalogModels.first,
    'models': catalogModels,
    'roles': [
      {
        'id': 'default',
        'category': 'chat',
        'selector': 'test/first',
        'resolved': catalogModels.first,
        'source': 'global',
      },
      {
        'id': 'task',
        'category': 'chat',
        'selector': taskSelector,
        'resolved': taskSelector == 'test/second'
            ? catalogModels.last
            : catalogModels.first,
        'source': 'global',
      },
      {
        'id': 'image',
        'category': 'kind',
        'selector': null,
        'resolved': null,
        'source': 'default',
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> runBuiltin(
    SessionView session,
    String command, [
    String args = '',
  ]) async {
    if (args.isEmpty) return super.runBuiltin(session, command, args);
    calls.add((command, args));
    final request = jsonDecode(args) as Map;
    if (request['op'] == 'set_role') {
      taskSelector = request['selector'] as String;
    }
    if (request['op'] == 'clear_role') taskSelector = null;
    return catalog;
  }
}

Map<String, dynamic> sessionView({
  List<Map<String, dynamic>> items = const [],
  List<Map<String, dynamic>> commands = const [],
  bool compacting = false,
}) => {
  'connection': 'connected',
  'error': null,
  'commands': commands,
  'sessions': [
    {
      'snapshot': <String, dynamic>{
        'agent_id': 'pi',
        'session_id': 's',
        'instance_id': 'i',
        'cwd': '/tmp/test',
        'name': 'test',
        'state': compacting ? 'running' : 'idle',
        'revision': 1,
        'needs_local_attention': false,
        'slash_commands': [
          for (final name in builtinNames)
            {'name': name, 'source': 'builtin', 'description': name},
        ],
        'controls': {
          'compacting': compacting,
          'thinking_level': 'off',
          'model': null,
        },
      },
      'ready': true,
      'last_seq': 20,
      'items': items,
      'gaps': [],
    },
  ],
};

Future<void> sheet(
  WidgetTester tester,
  BuiltinController model,
  String command,
) async {
  model.applyDecodedView(sessionView());
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: pircTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showBuiltinCommandSheet(
              context,
              model,
              model.sessions.first,
              command,
            ),
            child: const Text('Open panel'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open panel'));
  await tester.pump();
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'role overview edits and resets assignments without closing the sheet at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final model = RoleController();
        await sheet(tester, model, 'model');
        model.query.complete(model.catalog);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('model-role-current')), findsOneWidget);
        expect(find.byKey(const ValueKey('model-role-image')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('model-role-task')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('model-search')), 'Second');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('model-test/first')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('model-test/second')));
        await tester.pumpAndSettle();
        expect(model.taskSelector, 'test/second');
        expect(find.byKey(const ValueKey('model-role-task')), findsOneWidget);
        expect(find.byKey(const Key('model-role-current')), findsOneWidget);
        expect(find.text('First model'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('model-role-task')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('reset-model-role')));
        await tester.pumpAndSettle();
        expect(model.taskSelector, isNull);
        expect(find.byKey(const ValueKey('model-role-task')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }

  testWidgets('unsupported settings are hidden and reasoning can stand alone', (
    tester,
  ) async {
    final model = PircController();
    final view = sessionView();
    final snapshot = (view['sessions'] as List).first['snapshot'] as Map;
    snapshot['slash_commands'] = [];
    model.applyDecodedView(view);
    await tester.pumpWidget(PircApp(controller: model));
    await tester.tap(find.byKey(const Key('session-i')));
    await tester.pump();
    expect(find.byKey(const Key('session-model')), findsNothing);
    expect(find.byKey(const Key('session-thinking')), findsNothing);
    snapshot['slash_commands'] = [
      {'name': 'thinking', 'source': 'builtin'},
    ];
    snapshot['controls']['model'] = null;
    model.applyDecodedView(view);
    await tester.pump();
    expect(find.byKey(const Key('session-model')), findsNothing);
    expect(find.byKey(const Key('session-thinking')), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(const Key('session-thinking')),
              matching: find.byType(InkWell),
            ),
          )
          .onTap,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets('session header reflects Pi state and updates while running', (
    tester,
  ) async {
    final model = PircController();
    final view = sessionView();
    final snapshot = (view['sessions'] as List).first['snapshot'] as Map;
    snapshot['name'] = 'Fix login flow';
    snapshot['controls'] = {
      'model': {'provider': 'fixture', 'id': 'sonnet', 'name': 'Sonnet 4.5'},
      'thinking_level': 'high',
      'compacting': false,
    };
    model.applyDecodedView(view);
    await tester.pumpWidget(PircApp(controller: model));
    expect(find.text('Fix login flow'), findsOneWidget);
    expect(find.text('/tmp/test'), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-i')));
    await tester.pump();
    expect(find.text('Fix login flow'), findsOneWidget);
    expect(find.text('Sonnet 4.5'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    snapshot['name'] = 'Name changed in terminal';
    snapshot['state'] = 'running';
    snapshot['controls'] = {
      'model': {'provider': 'fixture', 'id': 'new', 'name': 'New model'},
      'thinking_level': 'low',
      'compacting': false,
    };
    model.applyDecodedView(view);
    await tester.pump();
    expect(find.text('Name changed in terminal'), findsOneWidget);
    expect(find.text('New model'), findsOneWidget);
    expect(find.text('low'), findsOneWidget);
    final nameButton = tester.widget<InkWell>(
      find.byKey(const Key('session-name')),
    );
    expect(nameButton.onTap, isNull);
    await tester.tap(find.byKey(const Key('back-button')));
    await tester.pump();
    expect(find.text('Name changed in terminal'), findsOneWidget);
    expect(find.text('/tmp/test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'header opens settings without requiring or replacing the draft',
    (tester) async {
      final model = BuiltinController()..applyDecodedView(sessionView());
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-model')));
      await tester.pump();
      expect(model.calls, [('model', '')]);
      model.query.complete({'kind': 'model', 'current': null, 'models': []});
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      model.setDraft(model.selected!, 'Draft being edited');
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-name')));
      await tester.pumpAndSettle();
      expect(model.calls.last, ('name', ''));
      expect(model.draft(model.selected!), 'Draft being edited');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-editor')))
            .controller!
            .text,
        'Draft being edited',
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'unsynchronized settings are distinct from no model and thinking off',
    (tester) async {
      final model = PircController();
      final view = sessionView();
      final snapshot = (view['sessions'] as List).first['snapshot'] as Map;
      snapshot.remove('controls');
      snapshot.remove('slash_commands');
      snapshot['name'] = null;
      model.applyDecodedView(view);
      await tester.pumpWidget(PircApp(controller: model));
      expect(find.text('Unnamed session'), findsOneWidget);
      expect(find.text('test'), findsNothing);
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      expect(find.text('Unnamed session'), findsOneWidget);
      for (final key in ['session-model', 'session-thinking']) {
        expect(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.text('Not synced'),
          ),
          findsOneWidget,
        );
      }
      expect(
        tester.widget<InkWell>(find.byKey(const Key('session-name'))).onTap,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('settings adapt to phone width and large text inside composer', (
    tester,
  ) async {
    final model = PircController();
    final view = sessionView();
    final snapshot = (view['sessions'] as List).first['snapshot'] as Map;
    snapshot['name'] = 'A very long session name' * 10;
    snapshot['controls'] = {
      'model': {
        'provider': 'fixture',
        'id': 'long',
        'name': 'A particularly long model name' * 10,
      },
      'thinking_level': 'xhigh',
      'compacting': false,
    };
    model.applyDecodedView(view);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(PircApp(controller: model));
    await tester.tap(find.byKey(const Key('session-i')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final composer = find.byKey(const Key('composer'));
    for (final scale in [1.0, 2.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      for (final width in [320.0, 390.0, 430.0]) {
        tester.view.physicalSize = Size(width, 640);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final status = tester.getRect(
          find.byKey(const Key('session-status-row')),
        );
        final badge = tester.getRect(
          find.byKey(const Key('session-state-badge')),
        );
        expect(badge.right, closeTo(status.right, .01));
        final composerRect = tester.getRect(composer);
        for (final key in ['session-model', 'session-thinking']) {
          final button = find.byKey(Key(key));
          expect(
            find.descendant(of: composer, matching: button),
            findsOneWidget,
          );
          final rect = tester.getRect(button);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(composerRect.left));
          expect(rect.right, lessThanOrEqualTo(composerRect.right));
          expect(rect.bottom, lessThanOrEqualTo(composerRect.bottom));
        }
        expect(
          tester
              .renderObject<RenderParagraph>(find.text('xhigh'))
              .didExceedMaxLines,
          isFalse,
          reason: 'The selected thinking level must remain fully visible',
        );
        final modelRect = tester.getRect(
          find.byKey(const Key('session-model')),
        );
        final thinkingRect = tester.getRect(
          find.byKey(const Key('session-thinking')),
        );
        if (scale == 1 && width == 320) {
          if ((thinkingRect.top - modelRect.top).abs() < 1) {
            expect(thinkingRect.left, greaterThanOrEqualTo(modelRect.right));
          } else {
            expect(thinkingRect.top, greaterThanOrEqualTo(modelRect.bottom));
          }
        } else if (scale == 2 && width == 320) {
          expect(thinkingRect.top, greaterThanOrEqualTo(modelRect.bottom));
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'loaded command sheet does not leave composer loading behind it',
    (tester) async {
      final model = BuiltinController()..applyDecodedView(sessionView());
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('prompt-editor')), '/name');
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-action')));
      model.query.complete({'kind': 'name', 'name': null});
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('session-name-editor')), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('composer-action')))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  for (final command in ['name', 'model', 'thinking']) {
    testWidgets('$command opens only after loading and ignores repeat taps', (
      tester,
    ) async {
      final model = BuiltinController()..applyDecodedView(sessionView());
      final snapshot =
          (sessionView()['sessions'] as List).first['snapshot'] as Map;
      snapshot['controls']['model'] = {
        'provider': 'fixture',
        'id': 'plain',
        'name': 'Plain',
      };
      final view = sessionView();
      (view['sessions'] as List).first['snapshot'] = snapshot;
      model.applyDecodedView(view);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      final entry = find.byKey(Key('session-$command'));
      await tester.tap(entry);
      await tester.pump();
      expect(find.byType(BuiltinCommandSheet), findsNothing);
      expect(find.byKey(Key('builtin-loading-$command')), findsOneWidget);
      await tester.tap(entry);
      await tester.pump();
      expect(model.calls, [(command, '')]);
      model.query.complete(switch (command) {
        'model' => {
          'current': null,
          'models': [
            {'provider': 'fixture', 'id': 'plain', 'name': 'Plain'},
          ],
        },
        'thinking' => {
          'level': 'off',
          'levels': ['off', 'high'],
        },
        _ => {'name': 'Test'},
      });
      await tester.pumpAndSettle();
      expect(find.byType(BuiltinCommandSheet), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(model.calls.length, 1);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });
  }
  testWidgets('failed preload keeps the sheet closed and releases the entry', (
    tester,
  ) async {
    final model = BuiltinController()..applyDecodedView(sessionView());
    await tester.pumpWidget(PircApp(controller: model));
    await tester.tap(find.byKey(const Key('session-i')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('session-name')));
    await tester.pump();
    model.query.completeError(StateError('Connection lost'));
    await tester.pumpAndSettle();
    expect(find.byType(BuiltinCommandSheet), findsNothing);
    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<InkWell>(find.byKey(const Key('session-name'))).onTap,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'leaving the session during preload does not open a stale sheet',
    (tester) async {
      final model = BuiltinController()..applyDecodedView(sessionView());
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('session-model')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('back-button')));
      await tester.pump();
      model.query.complete({'current': null, 'models': []});
      await tester.pumpAndSettle();
      expect(find.byType(BuiltinCommandSheet), findsNothing);
      expect(find.byKey(const Key('session-i')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('model sheet loads, filters and selects provider/model', (
    tester,
  ) async {
    final model = BuiltinController();
    await sheet(tester, model, 'model');
    expect(find.byType(BuiltinCommandSheet), findsNothing);
    model.query.complete({
      'kind': 'model',
      'current': null,
      'models': [
        {'provider': 'fixture', 'id': 'plain', 'name': 'Plain'},
        {'provider': 'fixture', 'id': 'reasoning', 'name': 'Reasoning'},
      ],
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('model-search')), 'reason');
    await tester.pump();
    expect(find.text('Plain'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('model-fixture/reasoning')));
    await tester.pump();
    expect(model.calls, [('model', ''), ('model', 'fixture/reasoning')]);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('thinking sheet uses only model-supported levels', (
    tester,
  ) async {
    final model = BuiltinController();
    await sheet(tester, model, 'thinking');
    model.query.complete({
      'kind': 'thinking',
      'level': 'off',
      'levels': ['off', 'low'],
    });
    await tester.pumpAndSettle();
    expect(find.text('off'), findsOneWidget);
    expect(find.text('low'), findsOneWidget);
    expect(find.text('xhigh'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('thinking-low')));
    await tester.pump();
    expect(model.calls.last, ('thinking', 'low'));
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('name sheet preserves edited text when saving fails', (
    tester,
  ) async {
    final model = BuiltinController()..failure = 'Session state changed';
    await sheet(tester, model, 'name');
    model.query.complete({'kind': 'name', 'name': null});
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('session-name-editor')),
      'Unicode new name',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-session-name')));
    await tester.pumpAndSettle();
    expect(find.text('Session state changed'), findsOneWidget);
    expect(model.calls.last, ('name', 'Unicode new name'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-name-editor')))
          .controller!
          .text,
      'Unicode new name',
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'session sheet shows totals and unknown context after compaction',
    (tester) async {
      final model = BuiltinController();
      await sheet(tester, model, 'session');
      model.query.complete({
        'kind': 'session',
        'info': {
          'session_id': 's',
          'name': 'Test',
          'cwd': '/tmp/test',
          'session_file': null,
          'context_tokens': null,
          'context_window': 100000,
          'total_messages': 4,
          'user_messages': 2,
          'assistant_messages': 2,
          'tool_calls': 0,
          'tool_results': 0,
          'input_tokens': 10,
          'output_tokens': 5,
          'cache_read_tokens': 3,
          'cache_write_tokens': 2,
          'cost_usd': '0.010000',
        },
      });
      await tester.pumpAndSettle();
      expect(find.text('Updates after the next response'), findsOneWidget);
      expect(find.text('4 · User 2 · Assistant 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'compaction stays at its chronological position and uses its own loading',
    (tester) async {
      final model = PircController();
      final items = [
        {
          'id': 'before',
          'role': 'assistant',
          'text': 'Answer before compaction',
          'complete': true,
          'first_seq': 1,
          'last_seq': 5,
        },
        {
          'id': 'after',
          'role': 'user',
          'text': 'Message after compaction',
          'complete': true,
          'first_seq': 11,
          'last_seq': 11,
        },
      ];
      final commands = [
        <String, dynamic>{
          'request_id': 'c',
          'instance_id': 'i',
          'kind': 'compact',
          'text': '/compact',
          'status': 'accepted',
          'after_seq': 10,
        },
      ];
      model.applyDecodedView(
        sessionView(items: items, commands: commands, compacting: true),
      );
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-i')));
      await tester.pump();
      expect(find.text('Compact context · Running'), findsOneWidget);
      expect(find.text('Waiting for response…'), findsNothing);
      expect(model.canSend(model.selected!), isFalse);
      expect(
        tester.getTopLeft(find.text('Answer before compaction')).dy,
        lessThan(tester.getTopLeft(find.text('Compact context · Running')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Compact context · Running')).dy,
        lessThan(tester.getTopLeft(find.text('Message after compaction')).dy),
      );
      commands[0] = {
        ...commands[0],
        'status': 'completed',
        'data': {
          'kind': 'compact',
          'summary': 'Task retained',
          'tokens_before': 500,
        },
      };
      model.applyDecodedView(sessionView(items: items, commands: commands));
      await tester.pump();
      expect(find.text('Compact context · Completed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  for (final command in ['model', 'thinking']) {
    testWidgets('$command selector wraps short lists and caps long lists', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      for (final count in [2, 30]) {
        final model = BuiltinController();
        model.applyDecodedView(sessionView());
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            key: ValueKey(count),
            theme: pircTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showBuiltinCommandSheet(
                    context,
                    model,
                    model.sessions.first,
                    command,
                  ),
                  child: const Text('Open options'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open options'));
        model.query.complete(
          command == 'model'
              ? {
                  'current': null,
                  'models': [
                    for (var i = 0; i < count; i++)
                      {'provider': 'fixture', 'id': '$i', 'name': 'Model $i'},
                  ],
                }
              : {
                  'level': 'level0',
                  'levels': [for (var i = 0; i < count; i++) 'level$i'],
                },
        );
        await tester.pumpAndSettle();
        final panel = find.byType(BuiltinCommandSheet);
        expect(tester.getSize(panel).height, lessThanOrEqualTo(844 * .8));
        if (count == 2) {
          expect(tester.getSize(panel).height, lessThan(450));
        } else {
          final list = find.descendant(
            of: panel,
            matching: find.byType(ListView),
          );
          await tester.drag(list, const Offset(0, -3000));
          await tester.pumpAndSettle();
          expect(
            find.text(command == 'model' ? 'Model 29' : 'level29'),
            findsOneWidget,
          );
          expect(model.calls.length, 1);
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          await tester.pumpAndSettle();
          if (command == 'model') {
            final search = find.byKey(const Key('model-search'));
            expect(tester.getRect(search).bottom, lessThan(844 - 320));
            await tester.enterText(search, 'Model 0');
            await tester.pumpAndSettle();
            expect(tester.getSize(panel).height - 320, lessThan(350));
          }
          expect(tester.getRect(panel).top, greaterThanOrEqualTo(0));
          expect(tester.takeException(), isNull);
          tester.view.resetViewInsets();
        }
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    });
  }
  testWidgets(
    'name editor dialog is centered, wraps content and avoids the keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final model = BuiltinController();
      model.applyDecodedView(sessionView());
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showBuiltinCommandSheet(
                  context,
                  model,
                  model.sessions.first,
                  'name',
                ),
                child: const Text('Edit name'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit name'));
      model.query.complete({'kind': 'name', 'name': 'Test'});
      await tester.pumpAndSettle();
      final panel = find.byType(BuiltinCommandSheet);
      expect(find.byKey(const Key('session-name-dialog')), findsOneWidget);
      expect(tester.getRect(panel).center.dy, closeTo(844 / 2, 1));
      expect(tester.getRect(panel).center.dx, closeTo(390 / 2, 1));
      expect(tester.getRect(panel).left, greaterThanOrEqualTo(24));
      expect(tester.getSize(panel).height, lessThan(350));
      final saveButton = find.byKey(const Key('save-session-name'));
      expect(
        tester.getRect(panel).bottom - tester.getRect(saveButton).bottom,
        lessThan(40),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(tester.getRect(saveButton).bottom, lessThanOrEqualTo(844 - 320));
      expect(tester.getRect(panel).center.dy, closeTo((844 - 320) / 2, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('name dialog fits a narrow phone with large text and keyboard', (
    tester,
  ) async {
    final model = BuiltinController()..applyDecodedView(sessionView());
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: pircTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showBuiltinCommandSheet(
                context,
                model,
                model.sessions.first,
                'name',
              ),
              child: const Text('Edit name'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit name'));
    model.query.complete({'name': 'Test name'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('save-session-name'))).bottom,
      lessThanOrEqualTo(400),
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
