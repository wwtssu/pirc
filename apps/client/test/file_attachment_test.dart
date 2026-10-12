import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc/file_attachment.dart';
import 'package:pirc/pirc_controller.dart';

void main() {
  test(
    'selecting a file stages a local draft without opening or sending it',
    () {
      final model = PircController()..connection = 'connected';
      final session = SessionView({
        'snapshot': {
          'session_id': 's',
          'instance_id': 'i',
          'state': 'idle',
          'cwd': '/tmp',
          'needs_local_attention': false,
        },
        'ready': true,
        'items': [],
        'gaps': [],
      });
      var reads = 0;
      model.stageFile(session, 'log.txt', 3, () {
        reads++;
        return Stream.value(Uint8List.fromList([1, 2, 3]));
      });
      expect(model.draftFile(session)?.name, 'log.txt');
      expect(model.draftFile(session)?.path, isNull);
      expect(reads, 0);
      expect(model.commands, isEmpty);
      expect(model.draft(session), isEmpty);
      expect(model.canSend(session), isTrue);
      model.setDraft(session, 'Please inspect this log');
      expect(model.promptWithAttachments(session), 'Please inspect this log');
      expect(reads, 0);
      model.removeFile(session);
      expect(model.draftFile(session), isNull);
      expect(model.draft(session), 'Please inspect this log');
      model.dispose();
    },
  );
  test(
    'file chunking preserves bytes across arbitrary stream boundaries',
    () async {
      final data = Uint8List.fromList(List.generate(200000, (i) => i % 256));
      final chunks = await attachmentChunks(
        Stream.fromIterable([
          Uint8List.sublistView(data, 0, 70000),
          Uint8List(0),
          Uint8List.sublistView(data, 70000),
        ]),
      ).toList();
      expect(chunks.every((c) => c.length <= 48 * 1024), isTrue);
      expect(chunks.expand((c) => c).toList(), data);
    },
  );
  test('empty attachments send one final empty chunk', () async {
    final chunks = await attachmentChunks(const Stream.empty()).toList();
    expect(chunks, hasLength(1));
    expect(chunks.single, isEmpty);
  });
}
