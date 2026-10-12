import 'dart:typed_data';
import 'dart:math' as math;

import 'package:image/image.dart' as image;

/// Bounds dimensions and payload size off the UI thread before transmission.
Uint8List prepareImageAttachment(Uint8List bytes) {
  if (bytes.length > 20 * 1024 * 1024) throw StateError('Image is too large');
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 32 * 1024 * 1024) {
    throw StateError('Image format or dimensions are unsupported');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw StateError('Unable to decode image');
  var oriented = image.bakeOrientation(decoded);
  var limit = 1600;
  while (limit >= 400) {
    final scale = math.min(
      1.0,
      limit / math.max(oriented.width, oriented.height),
    );
    final resized = image.copyResize(
      oriented,
      width: (oriented.width * scale).round(),
      height: (oriented.height * scale).round(),
    );
    final encoded = image.encodeJpg(resized, quality: 85);
    if (encoded.length <= 440 * 1024) return encoded;
    limit = (limit * .75).floor();
  }
  throw StateError('Image is too large');
}
