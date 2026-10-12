import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

import 'widget_test.dart' show view;

import 'package:pirc/pirc_screen.dart' show MessageBubble;

class PagedController extends PircController {
  final requests = <(String, int?)>[];
  @override
  void select(String instance) {
    selectedInstance = instance;
    notifyListeners();
  }

  @override
  Future<void> loadHistory(String direction, {int? cursor}) async {
    requests.add((direction, cursor));
    selected!.history['loading'] = direction;
    selected!.history['error'] = null;
    notifyListeners();
  }

  @override
  Future<void> retryHistory() => loadHistory('latest');
}

List<Map<String, dynamic>> items(int start, int end) => [
  for (var i = start; i < end; i++)
    {
      'id': 'h$i',
      'first_seq': i + 1,
      'last_seq': i + 1,
      'role': 'user',
      'text': List.filled(i % 4 + 2, 'Message $i').join('\n'),
      'complete': true,
    },
];
Map<String, dynamic> data(
  List<Map<String, dynamic>> entries, {
  bool before = false,
  bool after = false,
  int revision = 1,
  int? anchor,
  String? loading,
  String? error,
  bool initialized = true,
  int seq = 100,
}) {
  final result = decodeView(view());
  result['sessions'][0]['items'] = entries;
  result['sessions'][0]['last_seq'] = seq;
  result['sessions'][0]['history'] = {
    'enabled': true,
    'initialized': initialized,
    'has_before': before,
    'has_after': after,
    'revision': revision,
    'anchor': anchor,
    'loading': loading,
    'error': error,
    'truncated': false,
  };
  return result;
}

ScrollPosition position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const Key('transcript')),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;
Finder visibleBlock(WidgetTester tester) {
  final viewport = tester.getRect(find.byKey(const Key('transcript')));
  final blocks = find.byType(MessageBubble).evaluate();
  for (final element in blocks) {
    final candidate = find.byKey(element.widget.key!);
    final rect = tester.getRect(candidate);
    if (rect.top <= viewport.top && rect.bottom > viewport.top) {
      return candidate;
    }
  }
  for (final element in blocks) {
    final candidate = find.byKey(element.widget.key!);
    final rect = tester.getRect(candidate);
    if (rect.top >= viewport.top && rect.top < viewport.bottom) {
      return candidate;
    }
  }
  throw StateError('No visible transcript block');
}

Future<void> open(WidgetTester tester, PagedController model) async {
  await tester.pumpWidget(PircApp(controller: model));
  await tester.tap(find.byKey(const Key('session-one')));
  await tester.pump();
}

Future<void> close(WidgetTester tester, PagedController model) async {
  await tester.pumpWidget(const SizedBox());
  model.dispose();
}

void main() {
  testWidgets(
    'streaming during inertia has the same reading motion as scrolling alone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<double> displacement(bool stream) async {
        Map<String, dynamic> frame(int lines, int seq) => data([
          ...items(0, 40),
          {
            'id': 'live-answer',
            'role': 'assistant',
            'text': List.filled(lines, 'Live output').join('\n\n'),
            'complete': false,
            'first_seq': 101,
            'last_seq': seq,
          },
        ], seq: seq);
        final model = PagedController()..applyDecodedView(frame(1, 101));
        await open(tester, model);
        await tester.pumpAndSettle();
        await tester.fling(
          find.byKey(const Key('transcript')),
          const Offset(0, 250),
          1000,
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(position(tester).isScrollingNotifier.value, isTrue);
        final target = visibleBlock(tester);
        final top = tester.getTopLeft(target).dy;
        if (stream) model.applyDecodedView(frame(30, 102));
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(target, findsOneWidget);
        final moved = tester.getTopLeft(target).dy - top;
        await close(tester, model);
        return moved;
      }

      final ordinary = await displacement(false);
      final streamed = await displacement(true);
      expect(streamed, closeTo(ordinary, 1));
    },
  );
  testWidgets(
    'reading history during an active drag stays stable when output below grows',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic> frame(int lines, int seq) {
        final result = data([
          ...items(0, 40),
          {
            'id': 'live-answer',
            'role': 'assistant',
            'text': List.filled(lines, 'Live output').join('\n\n'),
            'complete': false,
            'first_seq': 101,
            'last_seq': seq,
          },
        ], seq: seq);
        result['sessions'][0]['snapshot']['state'] = 'running';
        return result;
      }

      final model = PagedController()..applyDecodedView(frame(1, 101));
      await open(tester, model);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byKey(const Key('transcript')));
      final gesture = await tester.startGesture(viewport.center);
      await gesture.moveBy(const Offset(0, 180));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      final target = visibleBlock(tester);
      final top = tester.getTopLeft(target).dy;
      model.applyDecodedView(frame(30, 102));
      await tester.pump();
      await tester.pump();
      expect(target, findsOneWidget);
      expect(tester.getTopLeft(target).dy, closeTo(top, .5));
      await gesture.up();
      await tester.pumpAndSettle();
      await close(tester, model);
    },
  );
  testWidgets(
    'shrinking an offscreen tool result preserves the historical reading position',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic> frame(String output, int seq) => data([
        ...items(0, 10),
        {
          'id': 'tail-tool',
          'role': 'tool',
          'title': 'read',
          'text': output,
          'complete': true,
          'phase': 'completed',
          'first_seq': 101,
          'last_seq': seq,
        },
      ], seq: seq);
      final model = PagedController()
        ..applyDecodedView(
          frame(List.filled(30, 'Streaming tool output').join('\n'), 101),
        );
      await open(tester, model);
      await tester.pumpAndSettle();
      final tile = find.byType(ExpansionTile);
      await tester.tapAt(tester.getTopLeft(tile) + const Offset(24, 24));
      await tester.pumpAndSettle();
      final scroll = position(tester);
      scroll.jumpTo(scroll.pixels - 420);
      await tester.pumpAndSettle();
      final target = visibleBlock(tester);
      final top = tester.getTopLeft(target).dy;
      model.applyDecodedView(frame('Final tool output', 102));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(top, .5));
      await close(tester, model);
    },
  );
  testWidgets(
    'expanded historical block and reading position survive rebasing and streaming',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entries = items(0, 40);
      entries[25] = {
        ...entries[25],
        'id': 'historical-tool',
        'role': 'tool',
        'title': 'read',
        'phase': 'completed',
        'text': 'Stable historical line\nSecond historical line\nThird historical line',
      };
      Map<String, dynamic> streaming(int seq) {
        final result = data(
          [
            ...entries,
            {
              'id': 'live-answer',
              'role': 'assistant',
              'text': List.filled(seq - 99, 'Live output').join('\n\n'),
              'complete': false,
              'first_seq': 101,
              'last_seq': seq,
            },
          ],
          anchor: 26,
          seq: seq,
        );
        result['sessions'][0]['snapshot']['state'] = 'running';
        return result;
      }

      final model = PagedController()..applyDecodedView(streaming(101));
      await open(tester, model);
      await tester.pumpAndSettle();
      final block = find.byKey(const ValueKey<dynamic>('historical-tool'));
      final tile = find.descendant(
        of: block,
        matching: find.byType(ExpansionTile),
      );
      await tester.tapAt(tester.getTopLeft(tile) + const Offset(24, 24));
      await tester.pumpAndSettle();
      final expandedHeight = tester.getSize(block).height;
      expect(expandedHeight, greaterThan(100));

      // Cross the expanded block and come back, forcing the reading anchor to
      // move between slivers before new response events arrive.
      final scroll = position(tester);
      final viewport = tester.getRect(find.byKey(const Key('transcript')));
      final travel = tester.getRect(block).bottom - viewport.top + 12;
      scroll.jumpTo(scroll.pixels + travel);
      await tester.pumpAndSettle();
      scroll.jumpTo(scroll.pixels - travel);
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(block).dy;
      expect(tester.getRect(block).bottom, greaterThan(viewport.top));
      expect(top, lessThan(viewport.bottom));
      expect(tester.getSize(block).height, expandedHeight);
      for (final seq in [102, 105, 115]) {
        model.applyDecodedView(streaming(seq));
        await tester.pumpAndSettle();
        expect(tester.getSize(block).height, expandedHeight);
        expect(tester.getTopLeft(block).dy, closeTo(top, .5));
        expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await close(tester, model);
    },
  );
  for (final startInOlderReply in [true, false]) {
    testWidgets('selection stays in its starting reply $startInOlderReply', (
      tester,
    ) async {
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
      final model = PagedController()
        ..applyDecodedView(
          data([
            for (final (id, text) in [
              ('older-reply', 'Earlier reply.'),
              ('newer-reply', 'Later reply.'),
            ])
              {'id': id, 'role': 'assistant', 'text': text, 'complete': true},
          ]),
        );
      await open(tester, model);
      await tester.pumpAndSettle();
      final older = tester.getRect(
        find.text('Earlier reply.', findRichText: true).first,
      );
      final newer = tester.getRect(
        find.text('Later reply.', findRichText: true).first,
      );
      final gesture = await tester.startGesture(
        startInOlderReply
            ? older.topLeft + const Offset(1, 12)
            : newer.bottomRight - const Offset(1, 12),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        startInOlderReply
            ? newer.bottomRight - const Offset(1, 12)
            : older.topLeft + const Offset(1, 12),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      region.contextMenuButtonItems
          .firstWhere((button) => button.type == ContextMenuButtonType.copy)
          .onPressed!();
      await tester.pump();
      expect(copied, startInOlderReply ? 'Earlier reply.' : 'Later reply.');
      await close(tester, model);
    });
  }
  testWidgets(
    'transcript inertia continues until the scrolling activity ends',
    (tester) async {
      final model = PagedController()..applyDecodedView(data(items(0, 60)));
      await open(tester, model);
      await tester.pumpAndSettle();
      final scroll = position(tester);
      await tester.fling(
        find.byKey(const Key('transcript')),
        const Offset(0, 260),
        1500,
      );
      await tester.pump(const Duration(milliseconds: 16));
      final before = scroll.pixels;
      await tester.pump(const Duration(milliseconds: 16));
      expect(scroll.isScrollingNotifier.value, isTrue);
      expect(scroll.pixels, lessThan(before));
      await tester.pumpAndSettle();
      await close(tester, model);
    },
  );
  testWidgets('dragging back near latest does not snap or cancel the gesture', (
    tester,
  ) async {
    final model = PagedController()..applyDecodedView(data(items(0, 60)));
    await open(tester, model);
    await tester.pumpAndSettle();
    final scroll = position(tester);
    scroll.jumpTo(scroll.maxScrollExtent - 120);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('transcript'))),
    );
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.extentAfter, lessThan(80));
    expect(scroll.isScrollingNotifier.value, isTrue);
    final before = scroll.pixels;
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.pixels, closeTo(before + 20, .5));
    expect(scroll.isScrollingNotifier.value, isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    await close(tester, model);
  });
  for (final distance in [40.0, 120.0]) {
    testWidgets(
      'transcript drag $distance survives anchor updates and incoming messages',
      (tester) async {
        final model = PagedController()..applyDecodedView(data(items(0, 60)));
        await open(tester, model);
        await tester.pumpAndSettle();
        final scroll = position(tester);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('transcript'))),
        );
        await gesture.moveBy(Offset(0, distance));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.isScrollingNotifier.value, isTrue);
        model.applyDecodedView(data(items(0, 61), seq: 101));
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(scroll.isScrollingNotifier.value, isTrue);
        for (var step = 0; step < 3; step++) {
          final reading = visibleBlock(tester);
          final before = tester.getTopLeft(reading).dy;
          await gesture.moveBy(const Offset(0, 40));
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));
          expect(scroll.isScrollingNotifier.value, isTrue);
          // Anchor rebasing changes logical offsets. Content must still move
          // with the pointer, without interrupting the drag.
          expect(tester.getTopLeft(reading).dy, closeTo(before + 40, .5));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        await close(tester, model);
      },
    );
  }
  for (final touch in [false, true]) {
    testWidgets(
      'drag ${touch ? "touch" : "mouse"} selection copies across markdown paragraphs',
      (tester) async {
        debugDefaultTargetPlatformOverride = touch
            ? TargetPlatform.iOS
            : TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
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
        final model = PagedController()
          ..applyDecodedView(
            data([
              ...items(0, 30),
              {
                'id': 'reply',
                'first_seq': 101,
                'last_seq': 101,
                'role': 'assistant',
                'text': 'Alpha first paragraph.\n\nBravo second paragraph.',
                'complete': true,
              },
            ], seq: 101),
          );
        await open(tester, model);
        await tester.pumpAndSettle();
        final first = find
            .text('Alpha first paragraph.', findRichText: true)
            .first;
        final last = find
            .text('Bravo second paragraph.', findRichText: true)
            .first;
        final before = tester.getTopLeft(first);
        final gesture = await tester.startGesture(
          tester.getTopLeft(first) + const Offset(1, 12),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(tester.getBottomRight(last) - const Offset(1, 12));
        await gesture.up();
        await tester.pumpAndSettle();
        final region = tester.state<SelectableRegionState>(
          find.byType(SelectableRegion),
        );
        final buttons = region.contextMenuButtonItems;
        buttons
            .firstWhere((b) => b.type == ContextMenuButtonType.copy)
            .onPressed!();
        await tester.pump();
        expect(copied, contains('Alpha first paragraph.'));
        expect(copied, contains('Bravo second paragraph.'));
        expect(tester.getTopLeft(first).dy, closeTo(before.dy, .5));
        await close(tester, model);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  for (final scenario in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    final (longReply, touch) = scenario;
    testWidgets(
      'selecting the latest ${longReply ? "long" : "short"} reply with ${touch ? "touch" : "mouse"} preserves position and selection',
      (tester) async {
        debugDefaultTargetPlatformOverride = touch
            ? TargetPlatform.iOS
            : TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final entries = [
          ...items(0, 30),
          {
            'id': 'reply',
            'first_seq': 101,
            'last_seq': 101,
            'role': 'assistant',
            'text': List.filled(
              longReply ? 80 : 1,
              'Latest response. Selecting this text should keep the session at its current position.',
            ).join(''),
            'complete': true,
          },
        ];
        final model = PagedController()
          ..applyDecodedView(data(entries, seq: 101));
        await open(tester, model);
        await tester.pumpAndSettle();
        final reply = find.byKey(const ValueKey<dynamic>('reply'));
        final region = find.byType(SelectableRegion);
        final state = tester.state<SelectableRegionState>(region);
        final render = tester.renderObject<RenderParagraph>(
          find.descendant(of: reply, matching: find.byType(RichText)).first,
        );
        final before = tester.getTopLeft(reply);
        Offset caret(int offset) => render.localToGlobal(
          render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
              const Offset(0, 12),
        );
        final length = (entries.last['text'] as String).length;
        final gesture = await tester.startGesture(
          caret(length - 20),
          kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse,
        );
        if (touch) await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(caret(length - 5));
        if (longReply && touch) {
          final edge = tester.getRect(find.byKey(const Key('transcript'))).top;
          await gesture.moveTo(Offset(caret(length - 5).dx, edge - 12));
          await tester.pump(const Duration(milliseconds: 600));
        }
        await gesture.up();
        await tester.pump();
        await tester.pumpAndSettle();
        if (!longReply || !touch) {
          expect(tester.getTopLeft(reply).dy, closeTo(before.dy, .5));
        }
        expect(tester.state<SelectableRegionState>(region), same(state));
        expect(
          state.contextMenuButtonItems.any(
            (button) =>
                button.type == ContextMenuButtonType.copy &&
                button.onPressed != null,
          ),
          isTrue,
        );
        expect(
          position(tester).pixels,
          longReply && touch ? lessThan(-1) : closeTo(0, .5),
        );
        await close(tester, model);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'prepending varying height history preserves visible message and offset',
    (tester) async {
      final model = PagedController()
        ..applyDecodedView(data(items(10, 50), before: true));
      await open(tester, model);
      await tester.pumpAndSettle();
      final scroll = position(tester);
      for (var i = 0; i < 5 && model.requests.isEmpty; i++) {
        scroll.jumpTo(scroll.minScrollExtent + 80);
        await tester.pump();
        await tester.pump();
      }
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(model.requests.map((r) => r.$1), ['before']);
      final target = visibleBlock(tester);
      final top = tester.getTopLeft(target).dy;
      final offset = scroll.pixels;
      model.applyDecodedView(data(items(0, 50)));
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(offset, .01));
      expect(tester.getTopLeft(target).dy, closeTo(top, .01));
      expect(model.requests.length, 1);
      await close(tester, model);
    },
  );
  testWidgets(
    'incoming message shows unread control while historical reading stays anchored',
    (tester) async {
      final model = PagedController()..applyDecodedView(data(items(0, 40)));
      await open(tester, model);
      await tester.pumpAndSettle();
      final scroll = position(tester);
      scroll.jumpTo(-500);
      await tester.pumpAndSettle();
      final readOffset = scroll.pixels;
      final target = visibleBlock(tester);
      final readTop = tester.getTopLeft(target).dy;
      model.applyDecodedView(data(items(0, 41), seq: 101));
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(readOffset, .01));
      expect(tester.getTopLeft(target).dy, closeTo(readTop, .01));
      expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);
      await tester.tap(find.byKey(const Key('jump-to-latest')));
      await tester.pumpAndSettle();
      expect(scroll.extentAfter, lessThan(1));
      expect(find.byKey(const Key('jump-to-latest')), findsNothing);
      await close(tester, model);
    },
  );
  testWidgets(
    'around window anchors target, loads newer page and returns to latest',
    (tester) async {
      final model = PagedController()
        ..applyDecodedView(
          data(items(10, 30), before: true, after: true, anchor: 21),
        );
      await open(tester, model);
      await tester.pumpAndSettle();
      final transcript = tester.getRect(find.byKey(const Key('transcript')));
      final target = tester.getRect(find.byKey(const ValueKey<dynamic>('h20')));
      expect(target.top, greaterThanOrEqualTo(transcript.top));
      expect(target.top, lessThan(transcript.bottom));
      final scroll = position(tester);
      scroll.jumpTo(scroll.maxScrollExtent - 50);
      await tester.pump();
      await tester.pump();
      expect(model.requests.last.$1, 'after');
      final offset = scroll.pixels;
      model.applyDecodedView(data(items(10, 50), before: true, anchor: 21));
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(offset, .01));
      await tester.tap(find.byKey(const Key('jump-to-latest')));
      await tester.pumpAndSettle();
      expect(scroll.extentAfter, lessThan(1));
      await close(tester, model);
    },
  );
  testWidgets(
    'initial history loading and failed retry do not flash empty session',
    (tester) async {
      final model = PagedController()
        ..applyDecodedView(data([], initialized: false, loading: 'latest'));
      await open(tester, model);
      expect(find.text('Loading session…'), findsOneWidget);
      expect(find.text('Continue the session'), findsNothing);
      model.applyDecodedView(
        data([], initialized: false, error: 'Unable to load messages'),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('history-initial-retry')));
      await tester.pump();
      expect(model.requests.last.$1, 'latest');
      model.applyDecodedView(data(items(30, 40)));
      await tester.pumpAndSettle();
      expect(position(tester).extentAfter, lessThan(1));
      await close(tester, model);
    },
  );
  testWidgets(
    'streaming body growth below the reader preserves the visible message',
    (tester) async {
      final entries = items(0, 40);
      entries.add({
        'id': 'reply',
        'first_seq': 101,
        'last_seq': 101,
        'role': 'assistant',
        'text': 'Answer\n\nAnswer',
        'complete': false,
      });
      final model = PagedController()
        ..applyDecodedView(data(entries, seq: 101));
      await open(tester, model);
      await tester.pumpAndSettle();
      final scroll = position(tester);
      scroll.jumpTo(-500);
      await tester.pumpAndSettle();
      final target = visibleBlock(tester);
      final top = tester.getTopLeft(target).dy;
      final grown = [
        ...entries.take(40),
        {
          ...entries.last,
          'text': List.filled(40, 'Growing streamed answer').join('\n\n'),
          'last_seq': 102,
        },
      ];
      model.applyDecodedView(data(grown, seq: 102));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(top, .01));
      expect(find.byKey(const Key('jump-to-latest')), findsOneWidget);
      await close(tester, model);
    },
  );
}
