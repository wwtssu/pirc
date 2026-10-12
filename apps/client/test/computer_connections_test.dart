import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/computer_connections.dart';
import 'package:pirc/connection_store.dart';
import 'package:pirc/pirc_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestComputer extends PircController {
  TestComputer({this.gate, this.started});
  final Completer<void>? gate;
  final List<String>? started;
  int connects = 0;
  bool pairingRequested = false;
  @override
  Future<void> connect(String url, {bool pairAgain = false}) async {
    connects++;
    pairingRequested = pairAgain;
    started?.add(url);
    endpoint = url;
    connection = 'connecting';
    notifyListeners();
    await gate?.future;
    connection = 'connected';
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'pairing again preserves stored trust until approval succeeds',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = ConnectionStore(
        preferences,
        storage: const FlutterSecureStorage(),
      );
      final computers = ComputerConnections(
        preferences: preferences,
        store: store,
        controllerFactory: TestComputer.new,
      );
      await computers.addComputer(
        'http://saved',
        name: 'Saved',
        backupAddresses: ['http://backup'],
      );
      final device = computers.active;
      final controller = device.controller as TestComputer;
      controller.serverId = 'old-id';
      controller.serverKey = 'old-key';
      await store.saveComputers([device.configuration], device.id);
      await computers.repairCurrent();
      expect(computers.active, same(device));
      expect(controller.connects, 2);
      expect(device.addresses, ['http://saved:43123', 'http://backup:43123']);
      expect(device.name, 'Saved');
      expect(controller.pairingRequested, isTrue);
      expect(controller.serverId, 'old-id');
      expect(controller.serverKey, 'old-key');
      final saved = await store.loadComputers();
      expect(saved.single.serverId, 'old-id');
      expect(saved.single.serverKey, 'old-key');
      computers.dispose();
    },
  );

  test('multi-computer persistence isolates secure keys', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    );
    await store.saveComputers([
      const SavedConnection(
        'http://a',
        name: 'A',
        serverKey: 'trusted-key-a',
        id: 'http://a',
      ),
      const SavedConnection(
        'https://b',
        name: 'B',
        serverKey: 'trusted-key-b',
        id: 'https://b',
      ),
    ], 'https://b');
    final restored = await ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    ).loadComputers();
    expect(restored.map((c) => c.name), ['A', 'B']);
    expect(restored.map((c) => c.serverKey), [
      'trusted-key-a',
      'trusted-key-b',
    ]);
    expect(store.activeId, 'https://b');
    expect(
      preferences.getString(ConnectionStore.computersKey),
      isNot(contains('trusted-key-a')),
    );
  });

  test('restart connects every saved computer in parallel and restores the selected one', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    );
    await store.saveComputers([
      const SavedConnection('http://a', name: 'A', id: 'http://a'),
      const SavedConnection('http://b', name: 'B', id: 'http://b'),
      const SavedConnection('http://c', name: 'C', id: 'http://c'),
    ], 'http://b');
    final gate = Completer<void>();
    final started = <String>[];
    final computers = ComputerConnections(
      preferences: preferences,
      store: store,
      controllerFactory: () => TestComputer(gate: gate, started: started),
    );
    final restoring = computers.restoreConnections();
    for (var i = 0; started.length < 3 && i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(started, ['http://a:43123', 'http://b:43123', 'http://c:43123']);
    expect(computers.startupLoading, isTrue);
    expect(computers.active.displayName, 'B');
    gate.complete();
    await restoring;
    expect(computers.startupLoading, isFalse);
    expect(computers.computers.map((c) => c.controller.connection), [
      'connected',
      'connected',
      'connected',
    ]);
    computers.dispose();
  });

  test('adding an existing computer selects it without opening a second connection', () async {
    final computers = ComputerConnections(controllerFactory: TestComputer.new);
    await computers.addComputer('http://a', name: 'A');
    final a = computers.active;
    await computers.addComputer('http://b', name: 'B');
    await computers.addComputer('http://a/', name: 'A');
    expect(computers.computers.length, 2);
    expect(computers.active, a);
    expect((a.controller as TestComputer).connects, 1);
    expect(
      computers.computers.every((c) => c.controller.connection == 'connected'),
      isTrue,
    );
    computers.dispose();
  });

  test(
    'retry after a closed transport retains the saved computer and reconnects',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final store = ConnectionStore(
        preferences,
        storage: const FlutterSecureStorage(),
      );
      final computers = ComputerConnections(
        store: store,
        controllerFactory: TestComputer.new,
      );
      await computers.addComputer('http://a', name: 'A');
      final computer = computers.active;
      await computer.controller.disconnect();
      expect(computers.computers.single, computer);
      expect((await store.loadComputers()).single.name, 'A');
      await computers.reconnectCurrent();
      expect(computers.active, computer);
      expect((computer.controller as TestComputer).connects, 2);
      expect(computer.controller.connection, 'connected');
      computers.dispose();
    },
  );

  test('editing one computer preserves the other connection and removes only its obsolete address', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    );
    final computers = ComputerConnections(
      preferences: preferences,
      store: store,
      controllerFactory: TestComputer.new,
    );
    await computers.addComputer('http://a', name: 'A');
    final a = computers.active;
    await computers.addComputer('http://b', name: 'B');
    final b = computers.active;
    await computers.configureCurrent('http://b-new', name: 'New address for B');
    expect(computers.active, b);
    expect(computers.computers.length, 2);
    expect(a.controller.connection, 'connected');
    expect((a.controller as TestComputer).connects, 1);
    final profiles = await store.loadComputers();
    expect(profiles.map((c) => c.endpoint), [
      'http://a:43123',
      'http://b-new:43123',
    ]);

    computers.dispose();
  });
  test('reordering retained addresses keeps the socket and stable computer identity', () async {
    final computers = ComputerConnections(controllerFactory: TestComputer.new);
    await computers.addComputer('http://a', backupAddresses: ['https://vpn']);
    final computer = computers.active;
    final id = computer.id;
    computer.controller.currentAddress = 'http://a:43123';
    computer.controller.serverId = 'stable-server';
    await computers.configureCurrent(
      'https://vpn',
      backupAddresses: ['http://a'],
    );
    expect(computer.id, id);
    expect(computer.configuration.id, id);
    expect(computer.addresses, ['https://vpn:43123', 'http://a:43123']);
    expect(computer.controller.serverId, 'stable-server');
    expect((computer.controller as TestComputer).connects, 1);
    computers.dispose();
  });
}
