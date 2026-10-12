import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

import 'src/rust/api/client.dart' as bridge;

/// User-facing computer address; the Rust transport owns the control route.
String computerAddress(String value) {
  final input = value.trim();
  if (input.isEmpty) return input;
  final source = input.contains('://') ? input : 'http://$input';
  final uri = Uri.tryParse(source);
  if (uri == null || uri.host.isEmpty) return input;
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  final authority = source.split('://').last.split(RegExp(r'[/#?]')).first;
  final explicitPort = RegExp(r':(\d+)$').firstMatch(authority);
  final port = explicitPort == null ? 43123 : int.parse(explicitPort.group(1)!);
  final normalized = uri.replace(path: path, port: port).toString();
  // Keep explicit scheme-default ports when Dart would omit them.
  if ((uri.scheme == 'http' && port == 80) ||
      (uri.scheme == 'https' && port == 443)) {
    return normalized.replaceFirst(
      '${uri.scheme}://${uri.authority}',
      '${uri.scheme}://${uri.authority}:$port',
    );
  }
  return normalized;
}

/// Hide the optional service-default port in address fields.
String computerAddressForEditing(String value) {
  final address = computerAddress(value);
  final uri = Uri.tryParse(address);
  if (uri != null && uri.port == 43123) {
    return address.replaceFirst(RegExp(r':43123(?=/|$)'), '');
  }
  return address;
}

String createComputerId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class SavedConnection {
  const SavedConnection(
    this.endpoint, {
    this.name = '',
    required this.id,
    this.serverId,
    this.serverKey,
    this.backupAddresses = const [],
  });
  final String endpoint;
  final String name;
  final String id;
  final String? serverId;
  final String? serverKey;
  final List<String> backupAddresses;
  List<String> get addresses => [endpoint, ...backupAddresses];
}

class ConnectionStore {
  ConnectionStore(
    this.preferences, {
    FlutterSecureStorage? storage,
    SecretStore? secretStore,
  }) : storage =
           secretStore ??
           (storage == null
               ? defaultSecretStore
               : KeychainSecretStore(storage));
  final SharedPreferences preferences;
  final SecretStore storage;
  static const computersKey = 'pirc.computer-profiles';
  static const activeComputerKey = 'pirc.selected-computer';

  static Future<String>? _localKey;
  static Future<String> localKey() =>
      _localKey ??= _loadLocalKey().catchError((Object failure) {
        _localKey = null;
        throw failure;
      });
  static Future<String> _loadLocalKey() async {
    final storage = defaultSecretStore;
    final saved = await storage.read(key: 'pirc.noise.client-key');
    if (saved != null) return saved;
    final key = await bridge.generateCryptoKey();
    await storage.write(key: 'pirc.noise.client-key', value: key);
    return key;
  }

  static String computerKeyKey(String id) => 'pirc.computer.$id.noise-key';

  String? get activeId => preferences.getString(activeComputerKey);
  Future<List<SavedConnection>> loadComputers() async {
    final encoded = preferences.getString(computersKey);
    if (encoded == null) return [];
    final profiles = (jsonDecode(encoded) as List).cast<Map<String, dynamic>>();
    return Future.wait(
      profiles.map((profile) async {
        final addresses = (profile['addresses'] as List).cast<String>();
        final id = profile['id'] as String;
        return SavedConnection(
          addresses.first,
          name: profile['name'] as String? ?? '',
          id: id,
          serverId: profile['server_id'] as String?,
          serverKey: await storage.read(key: computerKeyKey(id)),
          backupAddresses: addresses.skip(1).toList(),
        );
      }),
    );
  }

  Future<void> selectComputer(String id) =>
      preferences.setString(activeComputerKey, id);

  Future<void> saveComputers(
    List<SavedConnection> computers,
    String active,
  ) async {
    computers = [
      for (final computer in computers)
        SavedConnection(
          computerAddress(computer.endpoint),
          name: computer.name,
          id: computer.id,
          serverId: computer.serverId,
          serverKey: computer.serverKey,
          backupAddresses: computer.backupAddresses
              .map(computerAddress)
              .toList(),
        ),
    ];
    final previous = preferences.getString(computersKey);
    for (final computer in computers) {
      final trustedKey = computerKeyKey(computer.id);
      if (computer.serverKey != null) {
        await storage.write(key: trustedKey, value: computer.serverKey!);
      } else {
        await storage.delete(key: trustedKey);
      }
    }
    await preferences.setString(
      computersKey,
      jsonEncode([
        for (final computer in computers)
          {
            'id': computer.id,
            'addresses': computer.addresses,
            'server_id': computer.serverId,
            'name': computer.name,
          },
      ]),
    );
    await selectComputer(active);
    if (previous != null) {
      for (final profile
          in (jsonDecode(previous) as List).cast<Map<String, dynamic>>()) {
        final id = profile['id'] as String;
        if (!computers.any((c) => c.id == id)) {
          await storage.delete(key: computerKeyKey(id));
        }
      }
    }
  }
}
