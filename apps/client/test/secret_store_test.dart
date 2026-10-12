import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/secret_store.dart';

void main() {
  test(
    'file store persists concurrent computer keys without invoking keychain',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pirc-secret-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/secrets.json');
      final store = FileSecretStore(() async => file);
      await Future.wait([
        store.write(key: 'client', value: 'test-client-key'),
        store.write(key: 'computer-a', value: 'test-public-a'),
        store.write(key: 'computer-b', value: 'test-key-b'),
      ]);
      final restarted = FileSecretStore(() async => file);
      expect(await restarted.read(key: 'client'), 'test-client-key');
      expect(await restarted.read(key: 'computer-a'), 'test-public-a');
      expect(await restarted.read(key: 'computer-b'), 'test-key-b');
      await restarted.delete(key: 'computer-a');
      expect(await store.read(key: 'computer-a'), isNull);
      expect(await store.read(key: 'computer-b'), 'test-key-b');
      expect(directory.listSync().length, 1);
      if (Platform.isMacOS) {
        final mode = await Process.run('/usr/bin/stat', [
          '-f',
          '%Lp',
          file.path,
        ]);
        expect(mode.stdout.toString().trim(), '600');
      }
    },
  );

  test('invalid file never silently replaces existing identities', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pirc-secret-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/secrets.json');
    await file.writeAsString('invalid');
    final store = FileSecretStore(() async => file);
    await expectLater(
      store.write(key: 'client', value: 'replacement'),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'invalid');
  });
}
