import 'package:pirc/pirc_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/pirc_screen.dart';
import 'package:pirc/pirc_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

String view({
  String state = 'idle',
  String connection = 'connected',
  bool ready = true,
  List<Map<String, dynamic>> commands = const [],
}) => jsonEncode({
  'connection': connection,
  'error': null,
  'commands': commands,
  'sessions': [
    for (final id in ['one', 'two'])
      {
        'snapshot': {
          'agent_id': 'pi',
          'session_id': id,
          'instance_id': id,
          'cwd': '/tmp/$id',
          'name': id,
          'state': state,
          'revision': 1,
          'needs_local_attention': false,
        },
        'ready': ready,
        'items': [],
        'gaps': [],
      },
  ],
});

class ActionController extends PircController {
  int sends = 0;
  int stops = 0;
  @override
  Future<void> send() async {
    sends++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  testWidgets('entering and reentering a session opens at latest messages', (
    tester,
  ) async {
    final model = PircController();
    final data = decodeView(view());
    data['sessions'][0]['items'] = List.generate(
      60,
      (i) => <String, dynamic>{
        'id': 'history-$i',
        'role': 'user',
        'text': List.filled(i % 7 + 1, 'History $i').join('\n'),
        'complete': true,
      },
    );
    model.applyDecodedView(data);
    await tester.pumpWidget(PircApp(controller: model));
    Future<ScrollPosition> open() async {
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pumpAndSettle();
      final transcript = find.byKey(const Key('transcript'));
      return tester
          .state<ScrollableState>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
    }

    final first = await open();
    expect(first.extentAfter, lessThan(1));
    first.jumpTo(first.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('back-button')));
    await tester.pumpAndSettle();
    final second = await open();
    expect(second.extentAfter, lessThan(1));
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('startup displays loading until configuration is restored', (
    tester,
  ) async {
    final model = PircController()..startupLoading = true;
    await tester.pumpWidget(PircApp(controller: model));
    expect(find.text('Restoring connection'), findsOneWidget);
    expect(find.text('Syncing sessions…'), findsOneWidget);
    expect(find.text('View sessions on your device'), findsNothing);
    model.startupLoading = false;
    model.notifyListeners();
    await tester.pump();
    expect(find.text('Syncing sessions…'), findsNothing);
    expect(find.text('No device connected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'slash suggestions use session metadata and insert selected template',
    (tester) async {
      final model = PircController();
      final data = decodeView(view());
      data['sessions'][0]['snapshot']['slash_commands'] = [
        {'name': 'review', 'description': 'Inspect code', 'source': 'prompt'},
        {'name': 'custom', 'description': 'Local menu', 'source': 'extension'},
      ];
      model.applyDecodedView(data);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('prompt-editor')), '/');
      await tester.pump();
      expect(find.text('/review'), findsOneWidget);
      expect(find.text('/custom · On device'), findsOneWidget);
      await tester.tap(find.text('/review'));
      await tester.pump();
      expect(model.draft(model.selected!), '/review ');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'sending from older history jumps to latest while incoming updates preserve reading position',
    (tester) async {
      final model = ActionController();
      final data = decodeView(view());
      final items = List.generate(
        40,
        (i) => <String, dynamic>{
          'id': 'u$i',
          'role': 'user',
          'text': 'History message $i',
          'complete': true,
        },
      );
      data['sessions'][0]['items'] = items;
      model.applyDecodedView(data);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pumpAndSettle();
      final transcript = find.byKey(const Key('transcript'));
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: transcript, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      await tester.enterText(
        find.byKey(const Key('prompt-editor')),
        'New message',
      );
      position.jumpTo(position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(position.extentAfter, greaterThan(100));
      final reading = find.byKey(const ValueKey<dynamic>('u1'));
      final readingTop = tester.getTopLeft(reading).dy;
      items.add({
        'id': 'new',
        'role': 'user',
        'text': 'Other message',
        'complete': true,
      });
      model.applyDecodedView(data);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(reading).dy, closeTo(readingTop, .01));
      await tester.tap(find.byKey(const Key('composer-action')));
      await tester.pumpAndSettle();
      expect(model.sends, 1);
      expect(position.extentAfter, lessThan(1));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'formatted reply renders bold table and streamed unfinished code on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> render(String text) => tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: Scaffold(
            body: ListView(
              children: [
                MessageBubble(
                  item: {
                    'id': 'format',
                    'role': 'assistant',
                    'text': text,
                    'complete': false,
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await render(
        'Total **4 parts**\n\n| Part | Language | Duration |\n|---|---|---|\n| p01 | English (main) | **2:14** |\n| p02 | Japanese | 2:11 |',
      );
      await tester.pump();
      expect(find.byType(Table), findsOneWidget);
      final spans = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join(' ');
      expect(spans, contains('4 parts'));
      expect(spans, isNot(contains('**')));
      expect(spans, contains('2:14'));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Future<String?> copyReply() async {
        final region = tester.state<SelectableRegionState>(
          find.byType(SelectableRegion),
        );
        region.selectAll();
        await tester.pumpAndSettle();
        region.contextMenuButtonItems
            .firstWhere((button) => button.type == ContextMenuButtonType.copy)
            .onPressed!();
        await tester.pump();
        return copied;
      }

      expect(await copyReply(), contains('4 parts'));
      expect(copied, contains('2:14'));
      expect(copied, contains('p02'));
      expect(tester.takeException(), isNull);
      await render(
        '```dart\nfinal longLine = "${List.filled(80, 'x').join()}";',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await copyReply(), contains('final longLine'));
      await render(
        '# Title\n\n- First item\n- Second item\n\n> Quote\n\n`code`',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'first response wait is replaced by thinking or body with no author label',
    (tester) async {
      final model = PircController();
      final data = decodeView(view(state: 'running'));
      final items = <Map<String, dynamic>>[
        {'id': 'u', 'role': 'user', 'text': 'hello', 'complete': true},
        {'id': 'a', 'role': 'assistant', 'text': '', 'complete': false},
      ];
      data['sessions'][0]['items'] = items;
      model.applyDecodedView(data);
      model.select(model.sessions.first.instance);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      expect(find.text('Waiting for response…'), findsOneWidget);
      expect(find.text('Pi'), findsNothing);
      // The projection removes the empty assistant placeholder when a
      // thinking block starts. It is not a second pending response.
      items.removeLast();
      items.add({
        'id': 't',
        'role': 'thinking',
        'text': 'Start thinking',
        'complete': false,
      });
      model.applyDecodedView(data);
      await tester.pump();
      expect(find.text('Waiting for response…'), findsNothing);
      items.removeLast();
      items.add({
        'id': 'a',
        'role': 'assistant',
        'text': 'reply',
        'complete': false,
      });
      model.applyDecodedView(data);
      await tester.pump();
      expect(find.text('Waiting for response…'), findsNothing);
      expect(find.text('Pi'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'Enter sends, Shift Enter and IME do not send, running Enter never stops',
    (tester) async {
      final model = ActionController()..applyView(view());
      model.select(model.sessions.first.instance);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      final field = find.byKey(const Key('prompt-editor'));
      await tester.tap(field);
      await tester.enterText(field, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(model.sends, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(model.sends, 1);
      final editor = tester.widget<TextField>(field).controller!;
      editor.value = editor.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(model.sends, 1);
      editor.value = editor.value.copyWith(composing: TextRange.empty);
      model.applyView(view(state: 'running'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(model.sends, 1);
      expect(model.stops, 0);
      model.applyView(view());
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(model.sends, 2);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'connection dialog accepts no credential field on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ConnectionOptions? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: pircTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<ConnectionOptions>(
                    context: context,
                    builder: (_) => const ConnectionDialog(
                      endpoint: 'http://127.0.0.1:43123',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Primary address'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('connection-url')))
            .controller!
            .text,
        'http://127.0.0.1',
      );
      expect(find.text('Connection credential (optional)'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('connect-submit')));
      await tester.pumpAndSettle();
      expect(result?.url, 'http://127.0.0.1:43123');
    },
  );
  testWidgets('message roles follow the active theme and semantic overrides', (
    tester,
  ) async {
    final base = pircTheme();
    final body = base.textTheme.bodyLarge!.copyWith(
      fontSize: 18,
      color: Colors.purple,
    );
    final extra = base.extension<PircExtraTheme>()!.copyWith(
      warning: Colors.deepOrange,
      code: base.extension<PircExtraTheme>()!.code.copyWith(
        fontSize: 15,
        color: Colors.teal,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        theme: base.copyWith(
          textTheme: base.textTheme.copyWith(bodyLarge: body),
          extensions: [extra],
        ),
        home: const Scaffold(
          body: Column(
            children: [
              MessageBubble(
                item: {
                  'id': 'theme-body',
                  'role': 'assistant',
                  'text': 'Theme answer',
                  'complete': true,
                },
              ),
              MessageBubble(
                item: {
                  'id': 'theme-tool',
                  'role': 'tool',
                  'title': 'bash',
                  'text': 'theme output',
                  'complete': false,
                },
              ),
              MessageBubble(
                item: {
                  'id': 'theme-error',
                  'role': 'error',
                  'text': 'Theme notice',
                  'complete': true,
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final renderedBody = tester
        .widget<MarkdownBody>(find.byType(MarkdownBody))
        .styleSheet!
        .p!;
    final renderedCode = tester
        .widget<SelectableText>(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText && widget.data == 'theme output',
          ),
        )
        .style!;
    expect(renderedBody.fontSize, 18);
    expect(renderedBody.color, Colors.purple);
    expect(renderedCode.fontSize, 15);
    expect(renderedCode.color, Colors.teal);
    expect(
      tester.widget<Text>(find.text('Theme notice')).style!.color,
      Colors.deepOrange,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final kind in ['thinking', 'tool', 'arguments']) {
    testWidgets('$kind follows streamed content unless reader scrolls up', (
      tester,
    ) async {
      final id = 'following-$kind';
      var lines = 40;
      Future<void> render() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: ThemeData(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: MessageBubble(
                item: {
                  'id': id,
                  'role': kind == 'arguments' ? 'tool' : kind,
                  'title': 'bash',
                  'phase': 'running',
                  'text': kind == 'arguments'
                      ? ''
                      : List.generate(
                          lines,
                          (i) => 'Live content $i',
                        ).join('\n'),
                  'arguments': kind == 'arguments'
                      ? List.generate(
                          lines,
                          (i) => 'Live arguments $i',
                        ).join('\n')
                      : '',
                  'complete': false,
                },
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));
        await tester.pump(const Duration(milliseconds: 30));
      }

      final contents = find.byKey(PageStorageKey('content-scroll-$id'));
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find
                .descendant(of: contents, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      await render();
      expect(position().maxScrollExtent, greaterThan(0));
      expect(position().extentAfter, lessThan(1));
      lines += 8;
      await render();
      expect(position().extentAfter, lessThan(1));
      await tester.drag(contents, const Offset(0, 130));
      await tester.pump(const Duration(seconds: 1));
      final readingOffset = position().pixels;
      expect(position().extentAfter, greaterThan(60));
      lines += 8;
      await render();
      expect(position().pixels, closeTo(readingOffset, 1));
      await tester.drag(contents, const Offset(0, -4000));
      await tester.pump(const Duration(seconds: 2));
      expect(position().extentAfter, lessThan(1));
      lines += 8;
      await render();
      expect(position().extentAfter, lessThan(1));
      // Desktop wheel scrolling also pauses following, without drag details.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(contents),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
      final wheelOffset = position().pixels;
      expect(position().extentAfter, greaterThan(60));
      lines += 8;
      await render();
      expect(position().pixels, closeTo(wheelOffset, 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final role in ['thinking', 'tool']) {
    testWidgets('$role survives repeated collapse and reopen on macOS', (
      tester,
    ) async {
      final scroll = ScrollController();
      final item = <String, dynamic>{
        'id': 'reopen-$role',
        'role': role,
        'title': 'bash',
        'phase': 'completed',
        'text': List.filled(
          40,
          'Checking tool output and session context.',
        ).join('\n'),
        'complete': true,
      };
      final title = role == 'thinking' ? 'Thinking' : 'bash · Completed';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [MessageBubble(item: item)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      final contents = find.byKey(
        PageStorageKey('content-scroll-reopen-$role'),
      );
      await tester.drag(contents, const Offset(0, -150));
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(
            find
                .descendant(of: contents, matching: find.byType(Scrollable))
                .first,
          )
          .position
          .pixels;
      expect(offset, greaterThan(0));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsNothing);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(tester.takeException(), isNull);
        expect(
          tester
              .state<ScrollableState>(
                find
                    .descendant(of: contents, matching: find.byType(Scrollable))
                    .first,
              )
              .position
              .pixels,
          closeTo(offset, 1),
        );
      }
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
  }
  testWidgets('empty reply shows loading and final empty reply disappears', (
    tester,
  ) async {
    final item = <String, dynamic>{
      'id': 'loading',
      'role': 'assistant',
      'text': '',
      'complete': false,
    };
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: MessageBubble(item: item)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Replying…'), findsNothing);
    item['complete'] = true;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: MessageBubble(item: item)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets(
    'live thinking and tool details remain between surrounding text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PircController();
      final incoming = decodeView(view(state: 'running'));
      final items = <Map<String, dynamic>>[
        {
          'id': 'before',
          'role': 'assistant',
          'text': 'Starting tool',
          'complete': true,
        },
        {
          'id': 'thinking',
          'role': 'thinking',
          'text': 'Thinking part one',
          'complete': false,
        },
        {
          'id': 'call',
          'role': 'tool',
          'text': '',
          'title': 'bash',
          'arguments': '{"command":',
          'phase': 'generating',
          'complete': false,
        },
        {
          'id': 'after',
          'role': 'assistant',
          'text': 'Arguments ready',
          'complete': true,
        },
      ];
      incoming['sessions'][0]['items'] = items;
      incoming['sessions'][0]['last_seq'] = 1;
      model.applyDecodedView(incoming);
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      expect(find.text('Thinking part one'), findsOneWidget);
      expect(find.text('{"command":'), findsOneWidget);
      final callPosition = tester
          .getTopLeft(find.byKey(const ValueKey<dynamic>('call')))
          .dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<dynamic>('before'))).dy,
        lessThan(callPosition),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<dynamic>('after'))).dy,
        greaterThan(callPosition),
      );
      items[1]['text'] = 'Thinking parts one and two';
      items[1]['complete'] = true;
      items[2]['arguments'] = '{"command":"echo hi"}';
      items[2]['phase'] = 'running';
      items[2]['text'] = 'Live output';
      incoming['sessions'][0]['last_seq'] = 2;
      model.applyDecodedView(incoming);
      await tester.pump();
      expect(find.text('Thinking parts one and two'), findsOneWidget);
      expect(find.text('Live output'), findsOneWidget);
      expect(find.text('bash · Running'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<dynamic>('thinking')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<dynamic>('call')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      final finalPosition = tester
          .getTopLeft(find.byKey(const ValueKey<dynamic>('call')))
          .dy;
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<dynamic>('before'))).dy,
        lessThan(finalPosition),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<dynamic>('after'))).dy,
        greaterThan(finalPosition),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('Shows disconnected state before sessions are available', (
    tester,
  ) async {
    await tester.pumpWidget(const PircApp());
    expect(find.text('No device connected'), findsOneWidget);
  });
  testWidgets('STOPPING and reconnect allow editing but disable send', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = PircController();
    model.applyView(view(state: 'stopping'));
    await tester.pumpWidget(PircApp(controller: model));
    await tester.tap(find.byKey(const Key('session-one')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('prompt-editor')),
      'Rewritten instruction',
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('composer-action')))
          .onPressed,
      isNull,
    );
    expect(model.draft(model.selected!), 'Rewritten instruction');
    model.applyView(view(connection: 'reconnecting', ready: false));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('composer-action')))
          .onPressed,
      isNull,
    );
    model.applyView(view());
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('composer-action')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'one composer action switches between send, stop, and confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = ActionController()..applyView(view());
      await tester.pumpWidget(PircApp(controller: model));
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('prompt-editor')),
        'Next instruction',
      );
      await tester.pump();
      final action = find.byKey(const Key('composer-action'));
      final element = tester.element(action);
      final position = tester.getRect(action);
      IconButton button() => tester.widget<IconButton>(action);
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsNothing);
      await tester.tap(action);
      await tester.pump();
      expect(model.sends, 1);
      model.applyView(view(state: 'running'));
      await tester.pump();
      expect(tester.element(action), same(element));
      expect(tester.getRect(action), position);
      expect(button().tooltip, 'Stop');
      expect(find.byTooltip('Send'), findsNothing);
      expect(button().onPressed, isNotNull);
      await tester.tap(action);
      await tester.pump();
      expect(model.stops, 1);
      for (final state in ['running', 'stopping', 'idle']) {
        model.applyView(
          view(
            state: state,
            commands: [
              {
                'request_id': 'stop-one',
                'instance_id': 'one',
                'kind': 'stop',
                'status': 'accepted',
              },
            ],
          ),
        );
        await tester.pump();
        expect(button().tooltip, 'Stopping');
        expect(button().onPressed, isNull);
        expect(tester.getRect(action), position);
      }
      model.applyView(
        view(
          commands: [
            {
              'request_id': 'stop-one',
              'instance_id': 'one',
              'kind': 'stop',
              'status': 'completed',
            },
          ],
        ),
      );
      await tester.pump();
      expect(button().tooltip, 'Send');
      expect(button().onPressed, isNotNull);
      expect(
        model.sends,
        1,
        reason: 'Confirmed stop never sends the draft automatically',
      );
      expect(model.draft(model.selected!), 'Next instruction');
      model.applyView(
        view(
          commands: [
            {
              'request_id': 'unknown-one',
              'instance_id': 'one',
              'kind': 'prompt',
              'status': 'unknown',
            },
          ],
        ),
      );
      await tester.pump();
      expect(button().tooltip, 'Waiting for terminal confirmation');
      expect(button().onPressed, isNull);
      model.applyView(view(connection: 'reconnecting', ready: false));
      await tester.pump();
      expect(button().tooltip, 'Waiting for connection');
      expect(button().onPressed, isNull);
      model.applyView(view(state: 'running'));
      model.setDraft(model.selected!, '');
      await tester.pump();
      expect(button().tooltip, 'Stop');
      expect(
        button().onPressed,
        isNotNull,
        reason: 'Stopping does not require a draft',
      );
      expect(model.stops, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'mobile layout fits a $width wide phone with larger text and keyboard',
      (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final model = PircController()..applyView(view());
        await tester.pumpWidget(PircApp(controller: model));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('session-one')));
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 230);
        await tester.enterText(
          find.byKey(const Key('prompt-editor')),
          'First line of Unicode draft\nSecond line of longer input is preserved\nThird line\nFourth line',
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final action = tester.getRect(find.byKey(const Key('composer-action')));
        expect(action.width, greaterThanOrEqualTo(48));
        expect(action.height, greaterThanOrEqualTo(48));
        expect(action.bottom, lessThanOrEqualTo(470));
        final settings = find.byKey(const Key('session-settings'));
        expect(
          find.descendant(
            of: find.byKey(const Key('composer')),
            matching: settings,
          ),
          findsOneWidget,
        );
        expect(tester.getRect(settings).bottom, lessThanOrEqualTo(470));
        model.applyView(view(state: 'stopping'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(model.draft(model.selected!), contains('Fourth line'));
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }
  test(
    'drafts survive restart and accepted prompt does not erase newer editing',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final model = PircController(preferences: preferences)..applyView(view());
      model.setDraft(model.sessions[0], 'old');
      model.setDraft(model.sessions[1], 'Another session');
      await model.flushDrafts();
      model.endpoint = 'https://backup.example.com';
      expect(model.draft(model.sessions[0]), 'old');
      model.setDraft(model.sessions[0], 'new');
      model.applyView(
        view(
          commands: [
            {
              'request_id': 'r',
              'instance_id': 'one',
              'kind': 'prompt',
              'text': 'old',
              'status': 'accepted',
            },
          ],
        ),
      );
      expect(model.draft(model.sessions[0]), 'new');
      await model.flushDrafts();
      model.dispose();
      final restarted = PircController(preferences: preferences)
        ..computerId = model.computerId
        ..applyView(view());
      expect(restarted.draft(restarted.sessions[0]), 'new');
      expect(restarted.draft(restarted.sessions[1]), 'Another session');
      restarted.applyView(
        view(
          commands: [
            {
              'request_id': 'r2',
              'instance_id': 'one',
              'kind': 'prompt',
              'text': 'new',
              'status': 'unknown',
            },
          ],
        ),
      );
      expect(restarted.canSend(restarted.sessions[0]), isFalse);
      expect(restarted.draft(restarted.sessions[0]), 'new');
      restarted.dispose();
    },
  );
  testWidgets(
    'mobile navigation and incoming events preserve editing and IME',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PircController()..applyView(view());
      await tester.pumpWidget(PircApp(controller: model));
      expect(find.byKey(const Key('prompt-editor')), findsNothing);
      await tester.tap(find.byKey(const Key('session-one')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('prompt-editor')),
        'Unicode draft',
      );
      final input = tester
          .widget<TextField>(find.byKey(const Key('prompt-editor')))
          .controller!;
      input.value = input.value.copyWith(
        selection: const TextSelection.collapsed(offset: 2),
        composing: const TextRange(start: 0, end: 2),
      );
      final editing = input.value;
      for (var i = 0; i < 30; i++) {
        final incoming = decodeView(view(state: 'running'));
        incoming['sessions'][0]['items'] = [
          {
            'id': 'm',
            'role': 'assistant',
            'text': 'Live reply $i',
            'complete': false,
            'is_error': false,
            'truncated': false,
          },
        ];
        model.applyDecodedView(incoming);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(input.value, editing);
      expect(model.draft(model.selected!), 'Unicode draft');
      await tester.tap(find.byKey(const Key('back-button')));
      await tester.pump();
      expect(find.byKey(const Key('session-two')), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-two')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-editor')))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
