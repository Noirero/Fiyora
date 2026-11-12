import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_atomic_write.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late File archiveFile;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar004_');
    archiveFile = File(p.join(fixture.path, 'current.zip'));
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  void expectNoStagingLeft() {
    final remaining = fixture.listSync().where(
      (entity) => p.basename(entity.path).startsWith('.fiyora-archive-stage-'),
    );
    expect(remaining, isEmpty);
  }

  test('fault before rename preserves exact original bytes', () {
    final original = <int>[10, 20, 30, 40, 50];
    archiveFile.writeAsBytesSync(original);
    expect(
      () => replaceArchiveFileContentsAtomically(
        archiveFile,
        [90, 91, 92],
        beforeCommit: (_) => throw StateError('injected failure before replace'),
      ),
      throwsStateError,
    );
    expect(archiveFile.readAsBytesSync(), original);
    expectNoStagingLeft();
  });

  test('successful replacement commits complete staged bytes and cleans up', () {
    archiveFile.writeAsBytesSync([1, 2, 3]);
    replaceArchiveFileContentsAtomically(archiveFile, [4, 5, 6, 7]);
    expect(archiveFile.readAsBytesSync(), [4, 5, 6, 7]);
    expectNoStagingLeft();
  });

  test('new target can be created by staged rename', () {
    expect(archiveFile.existsSync(), isFalse);
    replaceArchiveFileContentsAtomically(archiveFile, [11, 12, 13]);
    expect(archiveFile.readAsBytesSync(), [11, 12, 13]);
    expectNoStagingLeft();
  });

  test('add-file retains all original entries in valid ZIP', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('old.txt', 3, [79, 76, 68]));
    archiveFile.writeAsBytesSync(
      ZipEncoder().encode(archive) ?? (throw StateError('ZIP encode failed')),
    );
    final source = File(p.join(fixture.path, 'new.txt'))..writeAsStringSync('NEW');
    expect(
      await ArchiveService.addFileToArchive(
        archivePath: archiveFile.path,
        filePathToAdd: source.path,
        internalPath: '',
      ),
      isTrue,
    );
    final decoded = ZipDecoder().decodeBytes(archiveFile.readAsBytesSync());
    expect(decoded.files.map((f) => f.name), containsAll(['old.txt', 'new.txt']));
    expectNoStagingLeft();
  });

  test('delete-items preserves undeleted entries in valid ZIP', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('retain.txt', 4, [75, 69, 69, 80]))
      ..addFile(ArchiveFile('remove.txt', 3, [68, 69, 76]));
    archiveFile.writeAsBytesSync(
      ZipEncoder().encode(archive) ?? (throw StateError('ZIP encode failed')),
    );
    expect(
      await ArchiveService.deleteItemsFromArchive(
        archivePath: archiveFile.path,
        internalPathsToDelete: ['remove.txt'],
      ),
      isTrue,
    );
    final decoded = ZipDecoder().decodeBytes(archiveFile.readAsBytesSync());
    expect(decoded.files.map((f) => f.name).toList(), ['retain.txt']);
    expectNoStagingLeft();
  });

  test('corrupt archive remains byte-identical when add fails', () async {
    final corrupt = <int>[0x50, 0x4b, 0x03, 0x04, 0, 0, 0];
    archiveFile.writeAsBytesSync(corrupt);
    final source = File(p.join(fixture.path, 'new.txt'))..writeAsStringSync('NEW');
    expect(
      await ArchiveService.addFileToArchive(
        archivePath: archiveFile.path,
        filePathToAdd: source.path,
        internalPath: '',
      ),
      isFalse,
    );
    expect(archiveFile.readAsBytesSync(), corrupt);
    expectNoStagingLeft();
  });
}
