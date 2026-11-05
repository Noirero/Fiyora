import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late Directory destination;
  late File source;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar005_');
    destination = Directory(p.join(fixture.path, 'output'))..createSync();
    source = File(p.join(fixture.path, 'input.txt'))..writeAsStringSync('NEW');
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  File zip(String archiveName, List<ArchiveFile> entries) {
    final archive = Archive();
    for (final entry in entries) {
      archive.addFile(entry);
    }
    final encoded = ZipEncoder().encode(archive)
        ?? (throw StateError('ZIP encoder returned null'));
    return File(p.join(fixture.path, archiveName))..writeAsBytesSync(encoded);
  }

  File tar(String archiveName, List<ArchiveFile> entries) {
    final archive = Archive();
    for (final entry in entries) {
      archive.addFile(entry);
    }
    final encoded = TarEncoder().encode(archive);
    return File(p.join(fixture.path, archiveName))..writeAsBytesSync(encoded);
  }

  Future<Map> background(String worker, String archivePath, {String? destinationPath}) async {
    final port = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        worker == 'extract'
            ? BackgroundArchiveService.extractIsolateTask
            : BackgroundArchiveService.compressIsolateTask,
        <String, dynamic>{
          'sendPort': port.sendPort,
          'archivePath': archivePath,
          'destinationDir': destination.path,
          'sourcePaths': <String>[source.path],
          'destinationPath': destinationPath,
          'format': 'zip',
          'level': 6,
          'deleteSource': false,
          'password': null,
        },
      );
      final result = await port.firstWhere((msg) =>
        msg is Map &&
        (msg['status'] == 'completed' || msg['status'] == 'error'),
      ).timeout(const Duration(seconds: 45));
      return result as Map;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  test('direct ZIP creation must not overwrite an existing archive', () async {
    final existing = File(p.join(destination.path, 'files.zip'))
      ..writeAsStringSync('KEEP-EXISTING-ARCHIVE');
    await expectLater(
      ArchiveService.createArchive(
        sourcePaths: [source.path],
        destinationDir: destination.path,
        archiveName: 'files',
        format: 'zip',
        compressionLevel: 6,
        deleteSource: false,
        separateArchives: false,
      ),
      throwsA(isA<Exception>()),
    );
    expect(existing.readAsStringSync(), 'KEEP-EXISTING-ARCHIVE');
    expect(source.readAsStringSync(), 'NEW');
  });

  test('background ZIP creation must not overwrite an existing archive', () async {
    final existing = File(p.join(destination.path, 'files.zip'))
      ..writeAsStringSync('KEEP-EXISTING-ARCHIVE');
    final result = await background('compress', '', destinationPath: existing.path);
    expect(result['status'], 'error', reason: '$result');
    expect(existing.readAsStringSync(), 'KEEP-EXISTING-ARCHIVE');
    expect(source.readAsStringSync(), 'NEW');
  });

  test('direct ZIP extraction must not overwrite existing file', () async {
    final existing = File(p.join(destination.path, 'file.txt'))
      ..writeAsStringSync('KEEP-USER-DATA');
    final archive = zip('files.zip', [ArchiveFile('file.txt', 3, utf8.encode('NEW'))]);
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(existing.readAsStringSync(), 'KEEP-USER-DATA');
  });

  test('background ZIP extraction must not overwrite existing file', () async {
    final existing = File(p.join(destination.path, 'file.txt'))
      ..writeAsStringSync('KEEP-USER-DATA');
    final archive = zip('files.zip', [ArchiveFile('file.txt', 3, utf8.encode('NEW'))]);
    final result = await background('extract', archive.path);
    expect(result['status'], 'error', reason: '$result');
    expect(existing.readAsStringSync(), 'KEEP-USER-DATA');
  });

  test('direct TAR extraction must not overwrite existing file', () async {
    final existing = File(p.join(destination.path, 'file.txt'))
      ..writeAsStringSync('KEEP-USER-DATA');
    final archive = tar('files.tar', [ArchiveFile('file.txt', 3, utf8.encode('NEW'))]);
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(existing.readAsStringSync(), 'KEEP-USER-DATA');
  });

  test('background TAR extraction must not overwrite existing file', () async {
    final existing = File(p.join(destination.path, 'file.txt'))
      ..writeAsStringSync('KEEP-USER-DATA');
    final archive = tar('files.tar', [ArchiveFile('file.txt', 3, utf8.encode('NEW'))]);
    final result = await background('extract', archive.path);
    expect(result['status'], 'error', reason: '$result');
    expect(existing.readAsStringSync(), 'KEEP-USER-DATA');
  });

  test('preflight catches second-file conflict before extracting first file', () async {
    final existing = File(p.join(destination.path, 'conflict.txt'))
      ..writeAsStringSync('KEEP');
    final archive = zip('two.zip', [
      ArchiveFile('first.txt', 5, utf8.encode('FIRST')),
      ArchiveFile('conflict.txt', 3, utf8.encode('NEW')),
    ]);
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(existing.readAsStringSync(), 'KEEP');
    expect(File(p.join(destination.path, 'first.txt')).existsSync(), isFalse);
  });

  test('duplicate file entries fail before extraction begins', () async {
    final archive = zip('duplicate.zip', [
      ArchiveFile('same.txt', 1, utf8.encode('A')),
      ArchiveFile('same.txt', 1, utf8.encode('B')),
    ]);
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(File(p.join(destination.path, 'same.txt')).existsSync(), isFalse);
  });

  test('single-stream gzip cannot silently overwrite extracted output', () async {
    final existing = File(p.join(destination.path, 'payload'))
      ..writeAsStringSync('KEEP');
    final zipped = GZipEncoder().encode(utf8.encode('NEW'))!;
    final input = File(p.join(fixture.path, 'payload.gz'))..writeAsBytesSync(zipped);
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: input.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(existing.readAsStringSync(), 'KEEP');
  });

  test('normal ZIP extraction to empty folder still works', () async {
    final archive = zip('normal.zip', [ArchiveFile('sub/new.txt', 3, utf8.encode('NEW'))]);
    await ArchiveService.extractArchive(
      archivePath: archive.path,
      destinationDir: destination.path,
    );
    expect(File(p.join(destination.path, 'sub/new.txt')).readAsStringSync(), 'NEW');
  });
}
