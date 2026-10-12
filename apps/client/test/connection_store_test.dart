import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pirc/connection_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('computer addresses normalize HTTP bases and host plus port', () {
    expect(
      computerAddress(' 192.168.1.10:43123 '),
      'http://192.168.1.10:43123',
    );
    expect(computerAddress('http://[::1]:43123/'), 'http://[::1]:43123');
    expect(computerAddress('192.168.1.10'), 'http://192.168.1.10:43123');
    expect(computerAddress('agent.local'), 'http://agent.local:43123');
    expect(computerAddress('http://[::1]'), 'http://[::1]:43123');
    expect(computerAddress('http://example.com:80'), 'http://example.com:80');
    expect(computerAddress('https://example.com'), 'https://example.com:43123');
    expect(
      computerAddress('https://example.com:443'),
      'https://example.com:443',
    );
    expect(
      computerAddressForEditing('http://agent.local:43123'),
      'http://agent.local',
    );
    expect(computerAddressForEditing('http://[::1]:43123'), 'http://[::1]');
    expect(
      computerAddressForEditing('http://agent.local:43124'),
      'http://agent.local:43124',
    );
    expect(
      computerAddress('http://agent.local:43124'),
      'http://agent.local:43124',
    );
    expect(
      computerAddress('https://example.com/pirc/'),
      'https://example.com:43123/pirc',
    );
  });

  test('restart retains computer addresses and trusted keys', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    );
    await store.saveComputers([
      const SavedConnection(
        'https://example.com',
        name: 'Devices',
        backupAddresses: ['http://vpn:43123'],
        serverId: 'stable-server',
        serverKey: 'trusted-server-public-key',
        id: 'https://example.com',
      ),
    ], 'https://example.com');
    final restarted = ConnectionStore(
      preferences,
      storage: const FlutterSecureStorage(),
    );
    final saved = (await restarted.loadComputers()).single;
    expect(saved.endpoint, 'https://example.com:43123');
    expect(saved.name, 'Devices');
    expect(saved.backupAddresses, ['http://vpn:43123']);
    expect(saved.serverId, 'stable-server');
    expect(saved.serverKey, 'trusted-server-public-key');
    expect(
      preferences.getString(ConnectionStore.computersKey),
      isNot(contains('trusted-server-public-key')),
    );
    expect(restarted.activeId, saved.id);
  });
}
