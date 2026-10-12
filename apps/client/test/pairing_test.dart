import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/pirc_controller.dart';

class UnreachableDevice extends PircController {
  @override
  Future<void> connect(String url, {bool pairAgain = false}) async {
    connection = 'connecting';
    notifyListeners();
  }
}

void main() {
  for (final cancel in [true, false]) {
    testWidgets(
      'unreachable pairing ${cancel ? 'can be cancelled' : 'times out'} and retains device trust',
      (tester) async {
        final controller = UnreachableDevice()
          ..endpoint = 'http://127.0.0.1:43123'
          ..serverId = 'saved-server'
          ..serverKey = 'saved-key';
        final computers = ComputerConnections(initialController: controller);
        computers.active.saved = true;
        computers.active.name = 'Saved device';
        await tester.pumpWidget(
          PircApp(computers: computers, locale: const Locale('en')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('drawer-button')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey('configure-computer-http://127.0.0.1:43123'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('repair-device')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-repair-device')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.byKey(const Key('pairing-connection-dialog')),
          findsOneWidget,
        );
        if (cancel) {
          await tester.tap(find.text('Cancel'));
        } else {
          await tester.pump(const Duration(seconds: 21));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(
          find.byKey(const Key('pairing-connection-dialog')),
          findsNothing,
        );
        expect(controller.connection, 'disconnected');
        expect(controller.serverId, 'saved-server');
        expect(controller.serverKey, 'saved-key');
        if (!cancel) {
          expect(
            find.byKey(const Key('pairing-connection-failure')),
            findsOneWidget,
          );
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('drawer-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings-drawer')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        computers.dispose();
        controller.dispose();
      },
    );
  }

  for (final approved in [true, false]) {
    testWidgets(
      'server approval ${approved ? 'automatically continues' : 'can be cancelled'} without client-side trust',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = PircController();
        await tester.pumpWidget(PircApp(controller: controller));
        controller.connection = 'pairing';
        controller.pairing = {
          'public_key': 'expected-key',
          'code': 'ABCD-2345',
          'expires_in': 300,
        };
        controller.notifyListeners();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('server-approval-dialog')), findsOneWidget);
        expect(find.text('pirc allow ABCD-2345'), findsOneWidget);
        expect(find.text('Fingerprint matches, connect'), findsNothing);
        expect(controller.serverKey, isNull);
        if (approved) {
          controller.pairing = null;
          controller.serverKey = 'expected-key';
          controller.connection = 'connected';
          controller.notifyListeners();
        } else {
          await tester.tap(find.text('Cancel'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byKey(const Key('server-approval-dialog')), findsNothing);
        expect(controller.connection, approved ? 'connected' : 'disconnected');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  }
}
