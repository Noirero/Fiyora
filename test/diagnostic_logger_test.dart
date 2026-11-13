import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/diagnostic_logger.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fiyora_diagnostics_test_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('starting again replaces manual session but retains crash report', () {
    final logger = DiagnosticLogger.forTesting(temp);
    expect(logger.startManual(), isTrue);
    logger.record(DiagnosticEvent.fileCopy);
    logger.stopManual();

    logger.captureException(
      'flutter_framework',
      FileSystemException('PASSWORD=should-not-leak', '/secret/private.zip'),
      StackTrace.fromString(
        '#0 ArchiveService.extract (package:nfile/services/archive_service.dart:12:3)\n'
        '#1 Unsafe.run (file:///storage/emulated/0/secret/private.zip:1:2)',
      ),
    );
    expect(logger.hasCrashReport, isTrue);

    expect(logger.startManual(), isTrue);
    logger.record(DiagnosticEvent.fileDelete);
    logger.stopManual();

    final manual = logger.preview(crash: false);
    final crash = logger.preview(crash: true);
    expect(manual, contains('fileDelete'));
    expect(manual, isNot(contains('fileCopy')));
    expect(crash, contains('FileSystemException'));
    expect(crash, contains('package:nfile/services/archive_service.dart:12:3'));
    expect(crash, isNot(contains('PASSWORD')));
    expect(crash, isNot(contains('/secret/private.zip')));
    expect(crash, isNot(contains('file:///storage')));
  });

  test('breadcrumbs remain active when manual recording is off', () {
    final logger = DiagnosticLogger.forTesting(temp);
    logger.record(DiagnosticEvent.fileOpen);
    expect(logger.hasManualLog, isFalse);
    expect(File('${temp.path}/breadcrumbs.txt').readAsStringSync(), contains('fileOpen'));
    expect(logger.startManual(), isTrue);
    logger.stopManual();
    logger.record(DiagnosticEvent.folderCreate);
    expect(logger.preview(crash: false), isNot(contains('folderCreate')));
    expect(File('${temp.path}/breadcrumbs.txt').readAsStringSync(), contains('folderCreate'));
  });

  test('manual session and breadcrumbs remain bounded', () {
    final logger = DiagnosticLogger.forTesting(
      temp,
      manualLimit: 640,
      breadcrumbLimit: 480,
    );
    logger.startManual();
    for (var i = 0; i < 150; i++) {
      logger.record(DiagnosticEvent.directoryLoad);
    }
    logger.stopManual();
    expect(File('${temp.path}/manual_session.txt').lengthSync(), lessThanOrEqualTo(640));
    expect(File('${temp.path}/breadcrumbs.txt').lengthSync(), lessThanOrEqualTo(480));
    expect(logger.preview(crash: false), contains('older entries truncated'));
  });

  test('operation outcomes expose types, never error messages or paths', () {
    final logger = DiagnosticLogger.forTesting(temp);
    expect(logger.startManual(), isTrue);
    logger.recordOutcome(DiagnosticEvent.fileMove,
        success: false,
        failure: FileSystemException('token=private', '/storage/private/secret.zip'));
    logger.stopManual();
    final report = logger.preview(crash: false);
    expect(report, contains('outcome_fileMove_failure_FileSystemException'));
    expect(report, isNot(contains('token=private')));
    expect(report, isNot(contains('secret.zip')));
  });

  test('unknown error sources and external frames are not persisted', () {
    final logger = DiagnosticLogger.forTesting(temp);
    logger.captureException(
      '/storage/emulated/0/passwords.txt',
      ArgumentError('secret=abc'),
      StackTrace.fromString(
        '#0 Foo.bar (file:///data/user/0/private.dart:1:1)',
      ),
    );
    final report = logger.preview(crash: true);
    expect(report, contains('Source: unknown'));
    expect(report, contains('Stack: unavailable'));
    expect(report, isNot(contains('passwords.txt')));
    expect(report, isNot(contains('secret=abc')));
  });
}
