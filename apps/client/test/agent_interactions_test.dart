import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/agent_interactions.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';

class AnswerController extends PircController {
  List<Map<String, dynamic>>? submitted;
  @override
  Future<void> answerAsk(
    SessionView session,
    String id,
    List<Map<String, dynamic>> answers,
  ) async {
    submitted = answers;
  }
}

Widget frame(Widget child) => MaterialApp(
  theme: pircTheme(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);
void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'Ask selections, custom text and notes submit without overflow at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 650));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final model = AnswerController()
          ..applyDecodedView({
            'connection': 'connected',
            'error': null,
            'commands': [],
            'sessions': [],
          });
        final session = SessionView({
          'snapshot': {'agent_id': 'omp', 'instance_id': 'i'},
          'ready': true,
          'items': [],
          'gaps': [],
        });
        final request = {
          'id': 'p',
          'questions': [
            {
              'id': 'a',
              'question': 'Pick one option',
              'multi': false,
              'recommended': 1,
              'options': [
                {'label': 'First'},
                {'label': 'Second'},
              ],
            },
            {
              'id': 'b',
              'question': 'Pick multiple options',
              'multi': true,
              'options': [
                {'label': 'Ask'},
                {'label': 'Todo'},
              ],
            },
          ],
        };
        await tester.pumpWidget(
          frame(AskPanel(request: request, session: session, model: model)),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('ask-option-a-0')),
        );
        await tester.tap(find.byKey(const ValueKey('ask-option-a-0')));
        for (final id in ['ask-option-b-0', 'ask-option-b-1']) {
          await tester.ensureVisible(find.byKey(ValueKey(id)));
          await tester.tap(find.byKey(ValueKey(id)));
          await tester.pump();
        }
        await tester.ensureVisible(find.byKey(const ValueKey('ask-text-b')));
        await tester.enterText(
          find.byKey(const ValueKey('ask-text-b')),
          'Custom',
        );
        await tester.ensureVisible(find.byKey(const ValueKey('ask-note-b')));
        await tester.enterText(
          find.byKey(const ValueKey('ask-note-b')),
          'Note',
        );
        // Transcript rebasing can dispose and recreate the block in another sliver.
        await tester.pumpWidget(frame(const SizedBox()));
        await tester.pumpWidget(
          frame(AskPanel(request: request, session: session, model: model)),
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('ask-text-b')))
              .controller!
              .text,
          'Custom',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('submit-ask')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('submit-ask')));
        await tester.pump();
        expect(model.submitted![0]['selected'], [0]);
        expect(model.submitted![1]['selected'], [0, 1]);
        expect(model.submitted![1]['text'], 'Custom');
        expect(model.submitted![1]['note'], 'Note');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }
  testWidgets(
    'Todo tool blocks show phases, all states and blockers instead of raw arguments',
    (tester) async {
      await tester.pumpWidget(
        frame(
          MessageBubble(
            item: {
              'id': 'todo',
              'role': 'tool',
              'title': 'todo',
              'complete': true,
              'phase': 'completed',
              'text': 'Raw tool result',
              'arguments': '{"op":"init"}',
              'todo': [
                {
                  'name': 'Build',
                  'tasks': [
                    for (final status in [
                      'pending',
                      'in_progress',
                      'completed',
                      'abandoned',
                      'blocked',
                    ])
                      {
                        'content': 'Task $status',
                        'status': status,
                        if (status == 'blocked') 'blocker': 'Needs input',
                      },
                  ],
                },
                {
                  'name': 'Validation',
                  'tasks': [
                    {'content': 'Check restoration', 'status': 'pending'},
                  ],
                },
              ],
            },
          ),
        ),
      );
      await tester.tap(find.text('Tasks · 1/6'));
      await tester.pumpAndSettle();
      expect(find.byType(TodoList), findsOneWidget);
      expect(find.text('Build'), findsOneWidget);
      expect(find.text('Validation'), findsOneWidget);
      expect(
        tester.getRect(find.text('Task blocked')).left,
        greaterThan(tester.getRect(find.text('Build')).left),
      );
      expect(
        tester.getRect(find.text('Validation')).top,
        greaterThan(tester.getRect(find.text('Task blocked')).bottom),
      );
      expect(find.text('Needs input'), findsOneWidget);
      expect(find.text('Task blocked'), findsOneWidget);
      expect(find.text('Raw tool result'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'Persistent tasks stay bounded and expanded across updates at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 650));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        Widget screen(int completed) => MaterialApp(
          theme: pircTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: Center(child: Text('Chat history'))),
                PersistentTodoPanel(
                  key: const ValueKey('session-tasks'),
                  phases: [
                    {
                      'name': 'Build',
                      'tasks': [
                        for (var i = 0; i < 30; i++)
                          {
                            'content':
                                'Task $i with a long description that must fit on small screens',
                            'status': i < completed
                                ? 'completed'
                                : i == completed
                                ? 'in_progress'
                                : 'pending',
                          },
                      ],
                    },
                  ],
                ),
                const SizedBox(key: Key('input'), height: 100),
              ],
            ),
          ),
        );
        await tester.pumpWidget(screen(0));
        expect(find.byType(TodoList), findsNothing);
        expect(find.text('0/30'), findsOneWidget);
        await tester.tap(find.byKey(const Key('toggle-todo-panel')));
        await tester.pump();
        expect(find.byType(TodoList), findsOneWidget);
        final panelRect = tester.getRect(
          find.byKey(const Key('persistent-todo-panel')),
        );
        expect(panelRect.height, lessThan(300));
        final inputRect = tester.getRect(find.byKey(const Key('input')));
        await tester.pumpWidget(screen(1));
        expect(find.byType(TodoList), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('toggle-todo-panel')),
            matching: find.text('1/30'),
          ),
          findsOneWidget,
        );
        expect(tester.getRect(find.byKey(const Key('input'))), inputRect);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
