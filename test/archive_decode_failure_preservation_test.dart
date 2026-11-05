import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late File incoming;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar003_');
    incoming = File(p.join(fixture.path, 'incoming.txt'))
      ..writeAsStringSync('NEW CONTENT');
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  Future<void> rejectsInvalidArchive(String extension, List<int> malformed) async {
    final archive = File(p.join(fixture.path, 'existing.$extension'))
      ..writeAsBytesSync(malformed);
    final result = await ArchiveService.addFileToArchive(
      archivePath: archive.path,
      filePathToAdd: incoming.path,
      internalPath: '',
    );
    expect(result, isFalse, reason: 'Must fail closed for a corrupted $extension archive');
    expect(archive.readAsBytesSync(), malformed, reason: 'Original archive bytes must remain unchanged');
  }

  test('malformed ZIP is never overwritten by an added file', () async {
    await rejectsInvalidArchive('zip', [0x50, 0x4b, 0x03, 0x04, 0, 0, 0]);
  });

  test('malformed TAR.GZ is never overwritten by an added file', () async {
    await rejectsInvalidArchive('tar.gz', [0x1f, 0x8b, 0, 1, 2, 3]);
  });

  test('malformed ZIP fallback on unknown extension is not overwritten', () async {
    await rejectsInvalidArchive('arc', [0, 1, 2, 3, 4, 5, 6]);
  });

  test('malformed TAR is never overwritten by an added file', () async {
    await rejectsInvalidArchive('tar', [0x11, 0x22, 0x33, 0x44, 0x55]);
  });

  test('existing valid ZIP retains old and new entries', () async {
    final archive = Archive()..addFile(ArchiveFile('old.txt', 3, [79, 76, 68]));
    final encoded = ZipEncoder().encode(archive) ?? (throw StateError('ZIP encoding failed'));
    final archiveFile = File(p.join(fixture.path, 'valid.zip'))..writeAsBytesSync(encoded);
    final result = await ArchiveService.addFileToArchive(
      archivePath: archiveFile.path,
      filePathToAdd: incoming.path,
      internalPath: '',
    );
    expect(result, isTrue);
    final decoded = ZipDecoder().decodeBytes(archiveFile.readAsBytesSync());
    expect(decoded.files.map((f) => f.name).toList(), containsAll(['old.txt', 'incoming.txt']));
  });

  test('missing input file does not mutate existing archive', () async {
    final original = <int>[0x50, 0x4b, 0x03, 0x04, 0, 0];
    final archive = File(p.join(fixture.path, 'bad.zip'))..writeAsBytesSync(original);
    final result = await ArchiveService.addFileToArchive(
      archivePath: archive.path,
      filePathToAdd: p.join(fixture.path, 'absent.bin'),
      internalPath: '',
    );
    expect(result, isFalse);
    expect(archive.readAsBytesSync(), original);
  });
}
