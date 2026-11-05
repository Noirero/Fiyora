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
}
