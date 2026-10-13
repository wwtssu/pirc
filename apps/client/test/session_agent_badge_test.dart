import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

void main() {
  for (final width in [320.0, 390.0, 480.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'agent badge remains visible with a long title at $width and scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final model = PircController();
          const title =
              'A very long session name that fills the entire row and must be truncated';
          model.applyDecodedView({
            'connection': 'connected',
            'error': null,
            'commands': [],
            'sessions': [
              {
                'snapshot': {
                  'agent_id': 'omp',
                  'session_id': 's',
                  'instance_id': 'i',
                  'cwd': '/projects/client',
                  'name': title,
                  'state': 'idle',
                  'needs_local_attention': false,
                },
                'ready': true,
                'items': [],
                'gaps': [],
              },
            ],
          });
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(PircApp(controller: model));
          await tester.pumpAndSettle();
          final badge = find.text('OMP');
          expect(badge, findsOneWidget);
          expect(tester.takeException(), isNull);
          final tile = tester.getRect(find.byKey(const Key('session-i')));
          final badgeRect = tester.getRect(badge);
          final menu = tester.getRect(find.byKey(const Key('session-menu-i')));
          expect(badgeRect.left, greaterThanOrEqualTo(tile.left));
          expect(badgeRect.right, lessThan(menu.left));
          expect(badgeRect.bottom, lessThanOrEqualTo(tile.bottom));
          expect(
            tester.renderObject<RenderParagraph>(badge).didExceedMaxLines,
            isFalse,
          );
          final titleWidget = tester.widget<Text>(find.text(title));
          expect(titleWidget.overflow, TextOverflow.ellipsis);
          expect(
            tester
                .renderObject<RenderParagraph>(find.text(title))
                .didExceedMaxLines,
            isTrue,
          );
          await tester.pumpWidget(const SizedBox());
          model.dispose();
        },
      );
    }
  }
}
