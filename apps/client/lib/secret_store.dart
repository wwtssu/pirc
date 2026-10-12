import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Development builds use files; production builds use the OS secure store.
const secretStoreMode = String.fromEnvironment(
  'PIRC_SECRET_STORE',
  defaultValue: kDebugMode ? 'file' : 'keychain',
);
const secretFilePath = String.fromEnvironment('PIRC_SECRET_FILE');

abstract interface class SecretStore {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

final SecretStore defaultSecretStore = switch (secretStoreMode) {
  'file' => FileSecretStore(() async {
    if (secretFilePath.isNotEmpty) return File(secretFilePath);
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/debug-secrets.json');
  }),
  'keychain' => const KeychainSecretStore(
    FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  ),
  _ => throw StateError('Invalid PIRC_SECRET_STORE: $secretStoreMode'),
};

class KeychainSecretStore implements SecretStore {
  const KeychainSecretStore(this.storage);
  final FlutterSecureStorage storage;
  @override
  Future<String?> read({required String key}) => storage.read(key: key);
  @override
  Future<void> write({required String key, required String value}) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete({required String key}) => storage.delete(key: key);
}

/// Plaintext development storage, deliberately isolated from the OS keychain.
/// A shared instance serializes changes made by multiple computer connections.
class FileSecretStore implements SecretStore {
  FileSecretStore(this.resolveFile);
  final Future<File> Function() resolveFile;
  Future<void> _pending = Future.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, String>> _load(File file) async {
    if (!await file.exists()) return {};
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Debug secret storage must be a regular file');
    }
    return (jsonDecode(await file.readAsString()) as Map)
        .cast<String, String>();
  }

  Future<void> _save(File file, Map<String, String> values) async {
    await file.parent.create(recursive: true);
    final suffix = Random.secure().nextInt(1 << 32).toRadixString(16);
    final temporary = File('${file.path}.$pid.$suffix.tmp');
    try {
      await temporary.create();
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await Process.run('/bin/chmod', ['600', temporary.path]);
        if (result.exitCode != 0) {
          throw StateError('Cannot protect debug secret file');
        }
      }
      await temporary.writeAsString(jsonEncode(values), flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<String?> read({required String key}) =>
      _serialized(() async => (await _load(await resolveFile()))[key]);
  @override
  Future<void> write({required String key, required String value}) =>
      _serialized(() async {
        final file = await resolveFile();
        final values = await _load(file);
        values[key] = value;
        await _save(file, values);
      });
  @override
  Future<void> delete({required String key}) => _serialized(() async {
    final file = await resolveFile();
    final values = await _load(file);
    if (values.remove(key) != null) await _save(file, values);
  });
}
