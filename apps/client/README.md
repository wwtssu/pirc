# PiRC Client

A Flutter client for Android, iOS, and macOS, using flutter_rust_bridge to access the shared Rust core.

The interface supports English, Japanese, and Simplified Chinese. It follows the system language by default; a language selected in the device drawer is saved independently of connection settings. Unsupported system languages fall back to English.

Translations are stored in `lib/l10n/*.arb`. Flutter generates the localization classes during builds; run `flutter gen-l10n` after editing translations.

## Development

```sh
flutter pub get
flutter run -d macos
flutter analyze
flutter test
```

Run `flutter_rust_bridge_codegen generate` after changing the Rust bridge API. The generator version must match the project's flutter_rust_bridge dependency.

## Connections

Connection addresses accept an IP, hostname, or service address. The client handles service discovery and the WebSocket upgrade automatically. The first connection requires server approval; see [Encryption and authorization](../../docs/ENCRYPTION.md).

Each device supports a primary address and an ordered list of fallback addresses. Network failures trigger an attempt with the next address. Authentication, certificate, or device identity errors stop automatic fallback. The device list and current selection are persisted; encryption keys use the system secure store.

## Debug key storage

`PIRC_SECRET_STORE` is a compile-time setting accepting `file` or `keychain`. Debug builds default to file storage; Release and Profile builds default to the system secure store. To build a Release version for debugging with file storage:

```sh
flutter build macos --release --dart-define=PIRC_SECRET_STORE=file
```

`PIRC_SECRET_FILE` selects a separate debug file. The default is `debug-secrets.json` in the application support directory. File storage and the system secure store are isolated; switching stores requires pairing again.
