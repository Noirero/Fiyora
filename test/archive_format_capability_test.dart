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
  late Directory output;
  late List<int> zipBytes;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar011_');
    output = Directory(p.join(fixture.path, 'out'))..createSync();
    final archive = Archive()..addFile(ArchiveFile('safe.txt', 4, [83, 65, 70, 69]));
    zipBytes = ZipEncoder().encode(archive) ??
        (throw StateError('ZIP fixture encoder returned null'));
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  File fakeArchive(String name) =>
      File(p.join(fixture.path, name))..writeAsBytesSync(zipBytes);

  Future<Map> backgroundExtract(File archive) async {
    final messages = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        BackgroundArchiveService.extractIsolateTask,
        <String, dynamic>{
          'sendPort': messages.sendPort,
          'archivePath': archive.path,
          'destinationDir': output.path,
          'password': null,
        },
      );
      final result = await messages.firstWhere(
        (event) =>
            event is Map &&
            (event['status'] == 'completed' || event['status'] == 'error'),
      ).timeout(const Duration(seconds: 30));
      return result as Map;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      messages.close();
    }
  }

  test('RAR-named archive is not treated as a ZIP preview', () async {
    final path = fakeArchive('renamed.rar');
    expect(await ArchiveService.readArchive(path.path), isNull);
  });

  test('7z-named archive is not treated as a ZIP preview', () async {
    final path = fakeArchive('renamed.7z');
    expect(await ArchiveService.readArchive(path.path), isNull);
  });

  test('direct extraction rejects RAR label even with ZIP bytes', () async {
    final archive = fakeArchive('renamed.rar');
    await expectLater(
      ArchiveService.extractArchive(archivePath: archive.path, destinationDir: output.path),
      throwsA(isA<UnsupportedError>()),
    );
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('direct extraction rejects 7z label even with ZIP bytes', () async {
    final archive = fakeArchive('renamed.7z');
    await expectLater(
      ArchiveService.extractArchive(archivePath: archive.path, destinationDir: output.path),
      throwsA(isA<UnsupportedError>()),
    );
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('background extraction rejects RAR label with explicit error', () async {
    final archive = fakeArchive('renamed.rar');
    final result = await backgroundExtract(archive);
    expect(result['status'], 'error', reason: '$result');
    expect((result['error'] as String).toLowerCase(), contains('rar'));
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('background extraction rejects 7z label with explicit error', () async {
    final archive = fakeArchive('renamed.7z');
    final result = await backgroundExtract(archive);
    expect(result['status'], 'error', reason: '$result');
    expect((result['error'] as String).toLowerCase(), contains('7z'));
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('split ZIP .zip.001 is extracted via direct reassembly', () async {
    final mid = zipBytes.length ~/ 3;
    final first = File(p.join(fixture.path, 'parts.zip.001'))
      ..writeAsBytesSync(zipBytes.sublist(0, mid));
    File(p.join(fixture.path, 'parts.zip.002'))
        .writeAsBytesSync(zipBytes.sublist(mid));
    await ArchiveService.extractArchive(
      archivePath: first.path,
      destinationDir: output.path,
    );
    expect(File(p.join(output.path, 'safe.txt')).readAsBytesSync(), [83, 65, 70, 69]);
  });

  test('split ZIP first volume preview is not mistaken for a whole ZIP', () async {
    final mid = zipBytes.length ~/ 3;
    final first = File(p.join(fixture.path, 'parts.zip.001'))
      ..writeAsBytesSync(zipBytes.sublist(0, mid));
    File(p.join(fixture.path, 'parts.zip.002'))
        .writeAsBytesSync(zipBytes.sublist(mid));
    expect(await ArchiveService.readArchive(first.path), isNull);
  });

  test('TAR-labelled .001 cannot bypass format support guard', () async {
    final file = fakeArchive('not-tar.tar.001');
    await expectLater(
      ArchiveService.extractArchive(archivePath: file.path, destinationDir: output.path),
      throwsA(isA<UnsupportedError>()),
    );
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('unlabelled .001 cannot bypass format support guard', () async {
    final file = fakeArchive('unknown.001');
    await expectLater(
      ArchiveService.extractArchive(archivePath: file.path, destinationDir: output.path),
      throwsA(isA<UnsupportedError>()),
    );
    expect(File(p.join(output.path, 'safe.txt')).existsSync(), false);
  });

  test('normal ZIP preview remains supported', () async {
    final archive = fakeArchive('normal.zip');
    final result = await ArchiveService.readArchive(archive.path);
    expect(result, isNotNull);
    expect(result!.files.single.name, 'safe.txt');
  });

  test('normal ZIP background extraction remains supported', () async {
    final archive = fakeArchive('normal.zip');
    final result = await backgroundExtract(archive);
    expect(result['status'], 'completed', reason: '$result');
    expect(File(p.join(output.path, 'safe.txt')).readAsBytesSync(), [83, 65, 70, 69]);
  });
}
