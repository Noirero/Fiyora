import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:nfile/services/diagnostic_logger.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fiyora_observability_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('archive diagnostic records start, failure, duration, phase and safe frames', () {
    final logger = DiagnosticLogger.forTesting(temp);
    logger.startManual();
    final id = logger.nextArchiveOperationId();
    const inputPath = '/storage/emulated/0/Private/secret-report.zip';
    final fmt = DiagnosticLogger.archiveFormatCode(inputPath);
    logger.recordArchivePhase(
      operationId: id,
      phase: DiagnosticArchivePhase.requested,
      format: fmt,
    );
    logger.recordArchivePhase(
      operationId: id,
      phase: DiagnosticArchivePhase.failed,
      format: fmt,
      elapsedMs: 87,
      failure: DiagnosticArchiveFailure.destinationConflict,
      exceptionType: 'FileSystemException',
      applicationFrames:
          'extractIsolateTask@package:nfile/services/background_archive_service.dart:433:5'
          '|evil@file:///storage/secret.txt:1:1',
    );
    logger.stopManual();

    final log = logger.preview(crash: false);
    expect(log, contains('phase=requested'));
    expect(log, contains('phase=failed'));
    expect(log, contains('failure=destinationConflict'));
    expect(log, contains('duration_ms=87'));
    expect(log, contains('exception_type=FileSystemException'));
    expect(log, contains('package:nfile/services/background_archive_service.dart:433:5'));
    expect(log, isNot(contains(inputPath)));
    expect(log, isNot(contains('secret-report.zip')));
    expect(log, isNot(contains('file:///storage/secret.txt')));
    expect(log, isNot(contains('evil@')));
  });

  test('file paths, raw exception text and unsupported types never reach manual log', () {
    final logger = DiagnosticLogger.forTesting(temp);
    logger.startManual();
    logger.recordArchivePhase(
      operationId: '/secret/path',
      phase: DiagnosticArchivePhase.failed,
      format: '/private/credential.zip',
      exceptionType: 'PASSWORD=abc /secret/files.zip',
      applicationFrames: 'mySecretPassword@example.org',
    );
    final err = FileSystemException(
      'Password=abc and private filename',
      '/storage/emulated/0/private/secret.txt',
      const OSError('No space left on device', 28),
    );
    logger.recordHandledError(
      DiagnosticEvent.directoryLoad,
      err,
      StackTrace.fromString(
        '#0 FileManagerProvider.loadDirectory '
        '(package:nfile/providers/file_manager_provider.dart:1732:3)\n'
        '#1 User.run (file:///storage/emulated/0/secret.txt:7:8)',
      ),
    );
    logger.stopManual();

    final report = logger.preview(crash: false);
    expect(report, contains('op_id=invalid'));
    expect(report, contains('format=unknown'));
    expect(report, contains('exception_type=unavailable'));
    expect(report, contains('handled_error operation=directoryLoad'));
    expect(report, contains('failure=storageFull'));
    expect(report, isNot(contains('Password=abc')));
    expect(report, isNot(contains('secret.txt')));
    expect(report, isNot(contains('credential.zip')));
    expect(report, isNot(contains('/storage/emulated')));
    expect(report, isNot(contains('mySecretPassword')));
  });

  test('only package:nfile stack frames are retained', () {
    final input = StackTrace.fromString(
      '#0 ArchiveService.extractArchive '
      '(package:nfile/services/archive_service.dart:910:12)\n'
      '#1 Other.run (file:///storage/emulated/0/secret.dart:1:2)',
    );
    final summary = DiagnosticLogger.safeApplicationFrames(input);
    expect(summary, contains('ArchiveService.extractArchive@package:nfile/services/archive_service.dart:910:12'));
    expect(summary, isNot(contains('file:///')));
    expect(summary, isNot(contains('secret.dart')));
  });

  test('background extraction sends typed failure, even for early returns', () async {
    final port = ReceivePort();
    final events = <Map<String, dynamic>>[];
    final completed = Completer<Map<String, dynamic>>();
    final subscription = port.listen((dynamic message) {
      if (message is! Map<String, dynamic>) return;
      events.add(message);
      if (message['status'] == 'error' && !completed.isCompleted) {
        completed.complete(message);
      }
    });
    try {
      final archivePath = '${temp.path}/secret_data_missing.zip';
      await BackgroundArchiveService.extractIsolateTask({
        'sendPort': port.sendPort,
        'archivePath': archivePath,
        'destinationDir': '${temp.path}/destination',
        'password': 'TOP_SECRET',
      });
      final result = await completed.future.timeout(const Duration(seconds: 5));
      expect(result['diagnosticCode'], DiagnosticArchiveFailure.sourceMissing.name);
      expect(result['diagnosticType'], 'MissingSource');
      expect(result['diagnosticFrames'], '');
      expect(events.any((m) =>
          m['status'] == 'diagnostic' &&
          m['phase'] == DiagnosticArchivePhase.sourceCheck.name), isTrue);
      // The UI has its own error text, but diagnostic fields must be safe.
      final safeFields = [
        result['diagnosticCode'],
        result['diagnosticType'],
        result['diagnosticFrames'],
      ].join(' ');
      expect(safeFields, isNot(contains(archivePath)));
      expect(safeFields, isNot(contains('TOP_SECRET')));
    } finally {
      await subscription.cancel();
      port.close();
    }
  });
}
