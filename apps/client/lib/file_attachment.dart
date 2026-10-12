import 'dart:math';
import 'dart:typed_data';

String newUploadId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Keeps each encoded chunk below the transport record size without buffering the file.
Stream<Uint8List> attachmentChunks(Stream<Uint8List> source) async* {
  var empty = true;
  await for (final bytes in source) {
    for (var start = 0; start < bytes.length; start += 48 * 1024) {
      empty = false;
      yield Uint8List.sublistView(
        bytes,
        start,
        min(start + 48 * 1024, bytes.length),
      );
    }
  }
  if (empty) yield Uint8List(0);
}

/// A local draft. Its stream is opened only when the user sends the message.
class PendingFileAttachment {
  PendingFileAttachment({
    required this.name,
    required this.total,
    required this.openRead,
  });
  final String name;
  final int total;
  final Stream<Uint8List> Function() openRead;
  String? path;
}
