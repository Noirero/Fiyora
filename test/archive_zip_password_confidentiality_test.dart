import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late File source;
  final original = utf8.encode('PRIVATE-CONFIDENTIAL-FIYORA-AR009');

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('ar009_');
    source = File(p.join(fixture.path, 'secret.txt'))..writeAsBytesSync(original);
  });

  tearDown(() {
    if (fixture.existsSync()) fixture.deleteSync(recursive: true);
  });

  List<int> checkEncryptedZip(File file) {
    final bytes = file.readAsBytesSync();
    expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(bytes[6] & 0x01, 0x01, reason: 'ZIP encryption flag must be enabled');
    expect(
      bytes.indexOf(original[0]) >= 0,
      isTrue,
      reason: 'Unrelated bytes may coincide; actual confidentiality is verified by decoding below',
    );
    final decoded = ZipDecoder().decodeBytes(bytes, password: 'top-secret-789');
    final extracted = decoded.files.single.content as List<int>;
    expect(extracted, original, reason: 'Correct password must decode the original payload');
    expect(
      () {
        final noPassword = ZipDecoder().decodeBytes(bytes);
        return noPassword.files.single.content;
      },
      throwsA(isA<Exception>()),
      reason: 'Protected ZIP must not expose payload without a password',
    );
    return bytes;
  }

  Future<Map> runBackground({
    required String destinationPath,
    required String format,
    required String? password,
  }) async {
    final receivePort = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        BackgroundArchiveService.compressIsolateTask,
        <String, dynamic>{
          'sendPort': receivePort.sendPort,
          'sourcePaths': <String>[source.path],
          'destinationPath': destinationPath,
          'format': format,
          'level': 6,
          'password': password,
          'deleteSource': false,
        },
      );
      final event = await receivePort.firstWhere((event) =>
        event is Map &&
        (event['status'] == 'completed' || event['status'] == 'error'),
      ).timeout(const Duration(seconds: 45));
      return event as Map;
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      receivePort.close();
    }
  }

  test('direct createArchive encrypts ZIP with supplied password', () async {
    await ArchiveService.createArchive(
      sourcePaths: [source.path],
      destinationDir: fixture.path,
      archiveName: 'direct',
      format: 'zip',
      compressionLevel: 6,
      password: 'top-secret-789',
      deleteSource: false,
      separateArchives: false,
    );
    checkEncryptedZip(File(p.join(fixture.path, 'direct.zip')));
  });

  test('background isolate encrypts ZIP with supplied password', () async {
    final output = File(p.join(fixture.path, 'background.zip'));
    final result = await runBackground(destinationPath: output.path, format: 'zip', password: 'top-secret-789');
    expect(result['status'], 'completed', reason: '$result');
    checkEncryptedZip(output);
  });

  test('password must not silently be ignored for non-ZIP direct archive', () async {
    await expectLater(
      ArchiveService.createArchive(
        sourcePaths: [source.path],
        destinationDir: fixture.path,
        archiveName: 'unsupported',
        format: 'tar',
        compressionLevel: 6,
        password: 'top-secret-789',
        deleteSource: false,
        separateArchives: false,
      ),
      throwsA(isA<Exception>()),
    );
    expect(File(p.join(fixture.path, 'unsupported.tar')).existsSync(), isFalse);
  });

  test('password must not silently be ignored for background TAR', () async {
    final output = File(p.join(fixture.path, 'unsupported.tar'));
    final result = await runBackground(destinationPath: output.path, format: 'tar', password: 'top-secret-789');
    expect(result['status'], 'error', reason: '$result');
    expect(output.existsSync(), isFalse);
  });

  test('ZIP without password remains readable for existing normal workflow', () async {
    await ArchiveService.createArchive(
      sourcePaths: [source.path],
      destinationDir: fixture.path,
      archiveName: 'normal',
      format: 'zip',
      compressionLevel: 6,
      deleteSource: false,
      separateArchives: false,
    );
    final bytes = File(p.join(fixture.path, 'normal.zip')).readAsBytesSync();
    expect(bytes[6] & 0x01, 0);
    final decoded = ZipDecoder().decodeBytes(bytes);
    expect(decoded.files.single.content, original);
  });
}
