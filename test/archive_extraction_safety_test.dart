import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_extraction_safety.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fixture;
  late Directory destination;
  late Directory outside;

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar002_');
    destination = Directory(p.join(fixture.path, 'extract'))..createSync();
    outside = Directory(p.join(fixture.path, 'outside'))..createSync();
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  File makeZip(String name, [List<int> content = const [65, 66, 67]]) {
    final archive = Archive()..addFile(ArchiveFile(name, content.length, content));
    final encoded = ZipEncoder().encode(archive);
    final path = p.join(fixture.path, 'input.zip');
    return File(path)..writeAsBytesSync(encoded);
  }

  Future<Map> extractInWorker(String archivePath) async {
    final messages = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        BackgroundArchiveService.extractIsolateTask,
        <String, dynamic>{
          'sendPort': messages.sendPort,
          'archivePath': archivePath,
          'destinationDir': destination.path,
          'password': null,
        },
        onError: messages.sendPort,
      );
      final event = await messages
          .firstWhere(
            (event) =>
                event is! Map ||
                event['status'] == 'completed' ||
                event['status'] == 'error',
          )
          .timeout(const Duration(seconds: 30));
      if (event is! Map) throw StateError('Unexpected worker event: $event');
      return event;
    } finally {
      worker?.kill(priority: Isolate.immediate);
      messages.close();
    }
  }

  test('rejects traversal, rooted paths, and empty entry names', () {
    const unsafe = [
      '../escape.txt',
      'nested/../../escape.txt',
      '..\\escape.txt',
      'nested\\..\\escape.txt',
      '/absolute.txt',
      '\\\\server\\share.txt',
      'C:\\windows.txt',
      '',
      'bad\u0000name',
    ];
    for (final name in unsafe) {
      expect(
        () => checkedArchiveExtractionPath(destination.path, name),
        throwsA(isA<FileSystemException>()),
        reason: 'Must reject: $name',
      );
    }
  });

  test('permits nested entries and conventional dot-prefixed TAR paths', () {
    expect(
      checkedArchiveExtractionPath(destination.path, 'sub/file.txt'),
      p.join(destination.path, 'sub', 'file.txt'),
    );
    expect(
      checkedArchiveExtractionPath(destination.path, './sub/file.txt'),
      p.join(destination.path, 'sub', 'file.txt'),
    );
    expect(
      checkedArchiveExtractionPath(destination.path, 'sub\\file.txt'),
      p.join(destination.path, 'sub', 'file.txt'),
    );
    expect(
      checkedArchiveExtractionPath(destination.path, './'),
      destination.path,
    );
  });

  test('existing symlink parent cannot redirect writes outside root', () {
    final link = Link(p.join(destination.path, 'jump'))..createSync(outside.path);
    expect(link.existsSync(), isTrue);
    expect(
      () => checkedArchiveExtractionPath(destination.path, 'jump/escaped.txt'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(p.join(outside.path, 'escaped.txt')).existsSync(), isFalse);
  });

  test('existing symlink at destination cannot overwrite an external file', () {
    final protected = File(p.join(outside.path, 'protected.txt'))..writeAsStringSync('KEEP');
    Link(p.join(destination.path, 'protected.txt')).createSync(protected.path);
    expect(
      () => checkedArchiveExtractionPath(destination.path, 'protected.txt'),
      throwsA(isA<FileSystemException>()),
    );
    expect(protected.readAsStringSync(), 'KEEP');
  });

  test('dangling symlink is rejected even when existsSync is false', () {
    Link(p.join(destination.path, 'dangling.txt'))
        .createSync(p.join(outside.path, 'not-there.txt'));
    expect(
      () => checkedArchiveExtractionPath(destination.path, 'dangling.txt'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('direct ZIP extraction preserves normal nested paths', () async {
    final archive = makeZip('safe/sub.txt');
    await ArchiveService.extractArchive(
      archivePath: archive.path,
      destinationDir: destination.path,
    );
    expect(File(p.join(destination.path, 'safe', 'sub.txt')).readAsBytesSync(), [65, 66, 67]);
  });

  test('background ZIP extraction preserves normal nested paths', () async {
    final archive = makeZip('safe/sub.txt');
    final result = await extractInWorker(archive.path);
    expect(result['status'], 'completed', reason: '$result');
    expect(File(p.join(destination.path, 'safe', 'sub.txt')).readAsBytesSync(), [65, 66, 67]);
  });

  test('direct ZIP extraction cannot write through existing symlink', () async {
    final protected = File(p.join(outside.path, 'protected.txt'))..writeAsStringSync('KEEP');
    Link(p.join(destination.path, 'redirect')).createSync(outside.path);
    final archive = makeZip('redirect/protected.txt');
    await expectLater(
      ArchiveService.extractArchive(
        archivePath: archive.path,
        destinationDir: destination.path,
      ),
      throwsA(isA<Exception>()),
    );
    expect(protected.readAsStringSync(), 'KEEP');
  });

  test('background ZIP extraction cannot write through existing symlink', () async {
    final protected = File(p.join(outside.path, 'protected.txt'))..writeAsStringSync('KEEP');
    Link(p.join(destination.path, 'redirect')).createSync(outside.path);
    final archive = makeZip('redirect/protected.txt');
    final result = await extractInWorker(archive.path);
    expect(result['status'], 'error', reason: '$result');
    expect(protected.readAsStringSync(), 'KEEP');
  });
}
