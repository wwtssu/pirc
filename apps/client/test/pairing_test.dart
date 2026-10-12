import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';

void main() {
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
