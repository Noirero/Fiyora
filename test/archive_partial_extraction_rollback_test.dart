import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:nfile/services/archive_extraction_rollback.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late Directory destination;
  late Directory blocked;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar012_');
    destination = Directory(p.join(fixture.path, 'output'))..createSync();
    blocked = Directory(p.join(destination.path, 'blocked'))..createSync();
  });

  tearDown(() {
    if (Platform.isLinux && blocked.existsSync()) {
      Process.runSync('chmod', ['0755', blocked.path]);
    }
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  File makeArchive(String format) {
    final archive = Archive()
      ..addFile(ArchiveFile('first.txt', 5, utf8.encode('FIRST')))
      ..addFile(ArchiveFile('blocked/second.txt', 6, utf8.encode('SECOND')));
    final bytes = format == 'zip'
        ? (ZipEncoder().encode(archive) ??
            (throw StateError('ZIP fixture encoding failed')))
        : TarEncoder().encode(archive);
    return File(p.join(fixture.path, 'partial.$format'))
      ..writeAsBytesSync(bytes);
  }

  void denySecondOutputWrites() {
    // GitHub's Linux CI runner is unprivileged: fail the second file write
    // after the first entry was successfully written.
    final result = Process.runSync('chmod', ['0555', blocked.path]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final probe = File(p.join(blocked.path, 'probe.txt'));
    expect(
      () => probe.createSync(exclusive: true),
      throwsA(isA<FileSystemException>()),
      reason: 'Controlled permission-denied fixture requires non-root Linux',
    );
    expect(probe.existsSync(), false);
  }

  Future<Map> extractInWorker(String archivePath) async {
    final port = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        BackgroundArchiveService.extractIsolateTask,
        <String, dynamic>{
          'sendPort': port.sendPort,
          'archivePath': archivePath,
          'destinationDir': destination.path,
          'password': null,
        },
      );
      final result = await port.firstWhere((event) =>
        event is Map &&
        (event['status'] == 'completed' || event['status'] == 'error'),
      ).timeout(const Duration(seconds: 30));
      return result as Map;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  for (final format in ['zip', 'tar']) {
    test('direct $format failure rolls back the first output', () async {
      final input = makeArchive(format);
      denySecondOutputWrites();
      await expectLater(
        ArchiveService.extractArchive(
          archivePath: input.path,
          destinationDir: destination.path,
        ),
        throwsA(anything),
      );
      expect(
        File(p.join(destination.path, 'first.txt')).existsSync(),
        false,
        reason: 'Newly extracted files should not remain after failure',
      );
    });

    test('background $format error rolls back the first output', () async {
      final input = makeArchive(format);
      denySecondOutputWrites();
      final response = await extractInWorker(input.path);
      expect(response['status'], 'error', reason: '$response');
      expect(
        File(p.join(destination.path, 'first.txt')).existsSync(),
        false,
        reason: 'Error acknowledgement must not hide leaked new output',
      );
    });
  }

  test('AR-005 still preserves a pre-existing file on conflict', () async {
    final preserved = File(p.join(destination.path, 'first.txt'))
      ..writeAsStringSync('KEEP');
    final archive = makeArchive('zip');
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(anything),
    );
    expect(preserved.readAsStringSync(), 'KEEP');
  });
  test('direct ZIP extraction succeeds with ordinary nested outputs', () async {
    final input = makeArchive('zip');
    await ArchiveService.extractArchive(
      archivePath: input.path,
      destinationDir: destination.path,
    );
    expect(File(p.join(destination.path, 'first.txt')).readAsStringSync(), 'FIRST');
    expect(File(p.join(destination.path, 'blocked/second.txt')).readAsStringSync(), 'SECOND');
  });

  test('background TAR extraction succeeds with ordinary nested outputs', () async {
    final input = makeArchive('tar');
    final result = await extractInWorker(input.path);
    expect(result['status'], 'completed', reason: '$result');
    expect(File(p.join(destination.path, 'first.txt')).readAsStringSync(), 'FIRST');
    expect(File(p.join(destination.path, 'blocked/second.txt')).readAsStringSync(), 'SECOND');
  });

  File makeNestedArchive(String format) {
    final entries = Archive()
      ..addFile(ArchiveFile('created/sub/first.txt', 5, utf8.encode('FIRST')))
      ..addFile(ArchiveFile('blocked/second.txt', 6, utf8.encode('SECOND')));
    final bytes = format == 'zip'
        ? (ZipEncoder().encode(entries) ??
            (throw StateError('ZIP fixture failed')))
        : TarEncoder().encode(entries);
    return File(p.join(fixture.path, 'nested.$format'))..writeAsBytesSync(bytes);
  }

  test('direct ZIP failure removes nested staging directories', () async {
    final input = makeNestedArchive('zip');
    denySecondOutputWrites();
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: input.path,
        destinationDir: destination.path,
      ),
      throwsA(anything),
    );
    expect(Directory(p.join(destination.path, 'created')).existsSync(), false);
    expect(blocked.existsSync(), true, reason: 'Existing directory must remain');
  });

  test('background TAR failure removes nested staging directories', () async {
    final input = makeNestedArchive('tar');
    denySecondOutputWrites();
    final result = await extractInWorker(input.path);
    expect(result['status'], 'error', reason: '$result');
    expect(Directory(p.join(destination.path, 'created')).existsSync(), false);
    expect(blocked.existsSync(), true, reason: 'Existing directory must remain');
  });

  test('rollback must not delete a different file replacing a recorded path', () {
    final target = File(p.join(destination.path, 'owned.txt'));
    final rollback = ArchiveExtractionRollback();
    rollback.createFile(target.path);
    target.writeAsStringSync('EXTRACTION OUTPUT');
    rollback.noteFileWritten(target.path);

    target.deleteSync();
    target.writeAsStringSync('USER REPLACEMENT WITH DIFFERENT LENGTH');
    rollback.rollback();

    expect(target.readAsStringSync(), 'USER REPLACEMENT WITH DIFFERENT LENGTH');
  });

  test('rollback must not delete a replacement directory', () {
    final path = p.join(destination.path, 'temporary');
    final rollback = ArchiveExtractionRollback();
    rollback.createDirectory(path);
    // Simulate an external actor discarding the original directory,
    // including its operation-private marker, before replacing it.
    Directory(path).deleteSync(recursive: true);

    // Another actor creates a directory with the same pathname.
    final replacement = Directory(path)..createSync();
    rollback.rollback();

    expect(replacement.existsSync(), isTrue);
  });

  test('rollback must not follow a newly substituted symlink parent', () {
    if (!Platform.isLinux) return;
    final directoryPath = p.join(destination.path, 'staged-parent');
    final filePath = p.join(directoryPath, 'victim.txt');
    final rollback = ArchiveExtractionRollback();
    rollback.createFile(filePath);
    File(filePath).writeAsStringSync('ORIGINAL');
    rollback.noteFileWritten(filePath);

    final moved = Directory(directoryPath).renameSync(p.join(fixture.path, 'moved-original'));
    expect(File(p.join(moved.path, 'victim.txt')).existsSync(), isTrue);

    final outside = Directory(p.join(fixture.path, 'outside'))..createSync();
    final protected = File(p.join(outside.path, 'victim.txt'))
      ..writeAsStringSync('USER FILE OUTSIDE DESTINATION');
    Link(directoryPath).createSync(outside.path);
    rollback.rollback();

    expect(protected.readAsStringSync(), 'USER FILE OUTSIDE DESTINATION');
  });

  test('ordinary rollback remains idempotent and permits retry', () {
    final path = p.join(destination.path, 'retry', 'generated.txt');
    final rollback = ArchiveExtractionRollback();
    rollback.createFile(path);
    File(path).writeAsStringSync('INCOMPLETE');
    rollback.noteFileWritten(path);
    rollback.rollback();
    rollback.rollback();
    expect(File(path).existsSync(), isFalse);
    expect(Directory(p.join(destination.path, 'retry')).existsSync(), isFalse);

    final next = ArchiveExtractionRollback();
    next.createFile(path);
    File(path).writeAsStringSync('RETRY OK');
    expect(File(path).readAsStringSync(), 'RETRY OK');
  });

  test('successful completion removes private ownership markers', () {
    final path = p.join(destination.path, 'created', 'nested', 'ok.txt');
    final rollback = ArchiveExtractionRollback();
    rollback.createFile(path);
    File(path).writeAsStringSync('OK');
    rollback.noteFileWritten(path);
    rollback.complete();

    expect(File(path).readAsStringSync(), 'OK');
    final files = Directory(p.join(destination.path, 'created'))
        .listSync(recursive: true);
    expect(
      files.where((e) => p.basename(e.path).startsWith('.fiyora-extract-rollback-')),
      isEmpty,
      reason: 'Internal ownership markers must not persist on success',
    );
  });

  test('rollback preserves another actor file inside a created directory', () {
    final path = p.join(destination.path, 'created-by-extractor');
    final rollback = ArchiveExtractionRollback();
    rollback.createDirectory(path);
    final external = File(p.join(path, 'added-by-user.txt'))
      ..writeAsStringSync('KEEP USER FILE');
    rollback.rollback();

    expect(external.readAsStringSync(), 'KEEP USER FILE');
    expect(Directory(path).existsSync(), true);
  });

}
