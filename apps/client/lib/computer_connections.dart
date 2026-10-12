import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection_store.dart';
import 'pirc_controller.dart';

class ComputerConnection {
  ComputerConnection(this.controller, {this.name = '', this.saved = false});
  final PircController controller;
  String name;
  bool saved;

  String get id => controller.computerId;
  String get endpoint => controller.endpoint;
  List<String> get addresses =>
      controller.addresses.isEmpty ? [endpoint] : controller.addresses;
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.host.isEmpty) return endpoint;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  SavedConnection get configuration => SavedConnection(
    endpoint,
    name: name,
    id: id,
    serverId: controller.serverId,
    serverKey: controller.serverKey,
    backupAddresses: addresses.skip(1).toList(),
  );
}

class ComputerConnections extends ChangeNotifier {
  ComputerConnections({
    this.preferences,
    ConnectionStore? store,
    PircController? initialController,
    PircController Function()? controllerFactory,
  }) : store =
           store ?? (preferences == null ? null : ConnectionStore(preferences)),
       _factory =
           controllerFactory ??
           (() => PircController(preferences: preferences)),
       _externalController = initialController {
    active = _register(initialController ?? _factory());
  }

  final SharedPreferences? preferences;
  final ConnectionStore? store;
  final PircController Function() _factory;
  final PircController? _externalController;
  final List<ComputerConnection> _computers = [];
  final Map<ComputerConnection, VoidCallback> _listeners = {};
  late ComputerConnection active;
  bool startupLoading = false;
  bool _disposed = false;
  Future<void> _writes = Future.value();

  List<ComputerConnection> get computers => List.unmodifiable(
    _computers.where(
      (computer) =>
          computer.saved || computer.controller.connection != 'disconnected',
    ),
  );

  ComputerConnection _register(
    PircController controller, {
    SavedConnection? saved,
  }) {
    final computer = ComputerConnection(
      controller,
      name: saved?.name ?? '',
      saved: saved != null,
    );
    if (saved != null) {
      controller.computerId = saved.id;
      controller.addresses = saved.addresses;
      controller.serverId = saved.serverId;
      controller.serverKey = saved.serverKey;
      controller.endpoint = saved.endpoint;
    }
    var status = controller.connection;
    var count = controller.onlineSessions.length;
    var identity = controller.serverId;
    var key = controller.serverKey;
    void update() {
      if (key != controller.serverKey) {
        key = controller.serverKey;
        if (computer.saved) unawaited(_persist(profiles: true));
      }
      if (identity != controller.serverId) {
        identity = controller.serverId;
        final duplicate = _computers
            .where(
              (c) =>
                  c != computer &&
                  identity != null &&
                  c.controller.serverId == identity,
            )
            .firstOrNull;
        if (duplicate != null) {
          unawaited(
            controller.disconnect().then((_) {
              controller.error =
                  'This device is already saved as ${duplicate.displayName}. Use the existing connection.';
              if (!_disposed) {
                notifyListeners();
                unawaited(_persist(profiles: true));
              }
            }),
          );
        } else if (computer.saved) {
          unawaited(_persist(profiles: true));
        }
      }
      final changed =
          status != controller.connection ||
          count != controller.onlineSessions.length;
      status = controller.connection;
      count = controller.onlineSessions.length;
      if (!_disposed && (computer == active || changed)) notifyListeners();
    }

    _computers.add(computer);
    _listeners[computer] = update;
    controller.addListener(update);
    return computer;
  }

  Future<void> restoreConnections() async {
    startupLoading = true;
    notifyListeners();
    try {
      final saved = await store?.loadComputers() ?? [];
      if (_disposed || saved.isEmpty) return;
      final initial = active;
      _unregister(initial);
      for (final profile in saved) {
        // Duplicate addresses must never create two sockets to the same computer.
        if (_computers.any((c) => c.endpoint == profile.endpoint)) continue;
        _register(_factory(), saved: profile);
      }
      active =
          _computers.where((c) => c.id == store?.activeId).firstOrNull ??
          _computers.first;
      notifyListeners();
      await Future.wait(_computers.map((c) => _connect(c)));
      if (_disposed) return;
      await _persist(profiles: true);
    } catch (_) {
      active.controller.error = 'Unable to read saved devices. Add them again.';
    } finally {
      startupLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> addComputer(
    String endpoint, {
    String name = '',
    List<String> backupAddresses = const [],
  }) async {
    endpoint = computerAddress(endpoint);
    final addresses = [endpoint, ...backupAddresses.map(computerAddress)];
    if (addresses.toSet().length != addresses.length) {
      throw ArgumentError('Duplicate connection address');
    }
    var computer = _computers
        .where((c) => c.addresses.any(addresses.contains))
        .firstOrNull;
    computer ??= !active.saved && active.controller.connection == 'disconnected'
        ? active
        : _register(_factory());
    final addressesChanged = !listEquals(computer.addresses, addresses);
    final currentRetained = addresses.contains(
      computer.controller.currentAddress,
    );
    computer.controller.addresses = addresses;
    computer.name = name.trim();
    computer.saved = true;
    final alreadyConnected =
        computer.controller.connection == 'connected' &&
        (!addressesChanged || currentRetained);
    computer.controller.endpoint = endpoint;
    active = computer;
    notifyListeners();
    if (!alreadyConnected) {
      await _connect(computer);
    } else {
      await computer.controller.updateAddresses();
    }
    // Save even a currently unreachable computer so it can reconnect later.
    if (_disposed) return;
    await _persist(profiles: true);
  }

  Future<void> _connect(ComputerConnection computer) {
    computer.controller.otherServerIds = _computers
        .where((c) => c != computer)
        .map((c) => c.controller.serverId)
        .whereType<String>()
        .toList();
    return computer.controller.connect(computer.endpoint);
  }

  Future<void> reconnectCurrent() {
    final computer = active;
    return computer.controller.connection == 'disconnected'
        ? _connect(computer)
        : computer.controller.reconnect();
  }

  void selectComputer(ComputerConnection computer) {
    if (!_computers.contains(computer) || active == computer) return;
    active = computer;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> configureCurrent(
    String endpoint, {
    String name = '',
    List<String> backupAddresses = const [],
  }) async {
    final computer = active;
    endpoint = computerAddress(endpoint);
    final addresses = [endpoint, ...backupAddresses.map(computerAddress)];
    if (addresses.toSet().length != addresses.length) {
      throw ArgumentError('Duplicate connection address');
    }
    final existing = _computers
        .where((c) => c != computer && c.addresses.any(addresses.contains))
        .firstOrNull;
    if (existing != null) {
      selectComputer(existing);
      return;
    }
    if (computer.endpoint == endpoint) {
      await addComputer(endpoint, name: name, backupAddresses: backupAddresses);
      return;
    }
    final addressesChanged = !listEquals(computer.addresses, addresses);
    final currentRetained = addresses.contains(
      computer.controller.currentAddress,
    );
    computer.controller.addresses = addresses;
    computer.name = name.trim();
    computer.saved = true;
    computer.controller.endpoint = endpoint;
    if (computer.controller.connection != 'connected' ||
        (addressesChanged && !currentRetained)) {
      await _connect(computer);
    } else {
      await computer.controller.updateAddresses();
    }
    if (_disposed) return;
    await _persist(profiles: true);
  }

  Future<void> _persist({bool profiles = false}) async {
    if (_disposed) return;
    final configurations = computers.map((c) => c.configuration).toList();
    final id = active.id;
    final write = _writes.then((_) async {
      if (profiles) {
        await store?.saveComputers(configurations, id);
      } else {
        await store?.selectComputer(id);
      }
    });
    _writes = write.catchError((Object _) {});
    try {
      await write;
    } catch (_) {
      if (!_disposed) {
        active.controller.error = 'Unable to save device settings';
        notifyListeners();
      }
    }
  }

  void _unregister(ComputerConnection computer) {
    computer.controller.removeListener(_listeners.remove(computer)!);
    _computers.remove(computer);
    if (computer.controller != _externalController) {
      computer.controller.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final computer in List<ComputerConnection>.of(_computers)) {
      _unregister(computer);
    }
    super.dispose();
  }
}
