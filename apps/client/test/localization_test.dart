import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/main.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:pirc/pirc_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> sessionFixture() => {
  'connection': 'connected',
  'error': 'SERVER_BUSY: A client is already connected',
  'commands': [],
  'sessions': [
    {
      'snapshot': {
        'session_id': 'session',
        'instance_id': 'session',
        'cwd': '/workspace/example',
        'name': null,
        'state': 'idle',
        'revision': 1,
        'needs_local_attention': false,
        'slash_commands': [],
      },
      'ready': true,
      'items': [],
      'gaps': [],
    },
  ],
};

void main() {
  for (final language in ['en', 'zh', 'ja']) {
    testWidgets('$language localizes session, device form, and server errors', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final strings = await AppLocalizations.delegate.load(Locale(language));
      final controller = PircController()..applyDecodedView(sessionFixture());
      final devices = ComputerConnections(initialController: controller);
      devices.active.name = 'Development device';
      await tester.pumpWidget(
        PircApp(computers: devices, locale: Locale(language)),
      );
      await tester.pumpAndSettle();
      expect(find.text(strings.sessions), findsOneWidget);
      expect(find.text(strings.unnamedSession), findsOneWidget);
      expect(find.text('SERVER_BUSY: ${strings.serverBusy}'), findsOneWidget);
      await tester.tap(find.byKey(const Key('drawer-button')));
      await tester.pumpAndSettle();
      expect(find.text(strings.devices), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('settings-drawer')),
          matching: find.text('Development device'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('add-computer')));
      await tester.pumpAndSettle();
      expect(find.text(strings.addDevice), findsOneWidget);
      await tester.tap(find.byKey(const Key('connect-submit')));
      await tester.pump();
      expect(find.text(strings.enterAddress), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      devices.dispose();
      controller.dispose();
    });
  }

  testWidgets('language switching persists without replacing device state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    tester.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final controller = PircController()..applyDecodedView(sessionFixture());
    controller.setDraft(controller.selected!, 'Keep this draft');
    final devices = ComputerConnections(
      initialController: controller,
      preferences: preferences,
    );
    final english = await AppLocalizations.delegate.load(const Locale('en'));
    final japanese = await AppLocalizations.delegate.load(const Locale('ja'));
    await tester.pumpWidget(PircApp(computers: devices));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(english.japaneseLanguage).last);
    await tester.pumpAndSettle();
    expect(find.text(japanese.devices), findsOneWidget);
    expect(preferences.getString('app-language'), 'ja');
    expect(devices.active.controller, same(controller));
    expect(controller.draft(controller.selected!), 'Keep this draft');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(PircApp(computers: devices));
    await tester.pumpAndSettle();
    expect(find.text(japanese.sessions), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    devices.dispose();
    controller.dispose();
  });

  testWidgets('unsupported system languages fall back to English', (
    tester,
  ) async {
    final controller = PircController()..applyDecodedView(sessionFixture());
    await tester.pumpWidget(
      PircApp(controller: controller, locale: const Locale('fr')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sessions'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
