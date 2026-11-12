import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Fixed event names only. Never pass file paths, filenames, URI, or credentials.
enum DiagnosticEvent {
  appStarted,
  appResumed,
  appPaused,
  navigationPush,
  navigationPop,
  diagnosticsOpened,
  directoryLoad,
  fileOpen,
  fileCopy,
  fileMove,
  fileDelete,
  fileRename,
  fileCreate,
  folderCreate,
  archiveCreate,
  archiveExtract,
  pasteStarted,
  sessionStarted,
  sessionStopped,
}


enum DiagnosticArchivePhase {
  requested, unsupported, dialogCanceled, configured, workerStarted,
  sourceCheck, decoding, validatePaths, writingOutput,
  completed, failed, canceled,
}

enum DiagnosticArchiveFailure {
  sourceMissing, destinationConflict, permissionDenied, storageFull,
  unsafeArchive, unsupportedFormat, passwordOrEncryption,
  invalidArchive, filesystemError, unknown,
}

/// A small, local-only recorder. Crash breadcrumbs are independent of manual logs.
/// Disk I/O is best-effort and cannot change the outcome of an app operation.
class DiagnosticLogger {
  DiagnosticLogger._() : _manualLimit = 192 * 1024, _breadcrumbLimit = 32 * 1024;
  DiagnosticLogger.forTesting(
    Directory directory, {
    int manualLimit = 192 * 1024,
    int breadcrumbLimit = 32 * 1024,
  })  : _dir = directory,
        _manualLimit = manualLimit,
        _breadcrumbLimit = breadcrumbLimit {
    directory.createSync(recursive: true);
  }

  static final DiagnosticLogger instance = DiagnosticLogger._();
  static const MethodChannel _android = MethodChannel('com.rubex.nfile/diagnostics');

  final int _manualLimit;
  final int _breadcrumbLimit;
  Directory? _dir;
  bool _manualActive = false;
  bool _writeFailed = false;
  String? _startupClassification;

  bool get manualActive => _manualActive;
  bool get storageReady => _dir != null;
  bool get writeFailed => _writeFailed;
  String? get startupClassification => _startupClassification;
  bool get hasManualLog => _exists('manual_session.txt');
  bool get hasCrashReport => _exists('crash_report.txt');

  File _file(String name) => File(_dir!.path + Platform.pathSeparator + name);
  bool _exists(String name) {
    try {
      return _dir != null && _file(name).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Called once, before other services initialize. Previous session data is
  /// intentionally kept until the user explicitly starts a fresh manual session.
  Future<void> initialize() async {
    try {
      final support = await getApplicationSupportDirectory();
      _dir = Directory(support.path + Platform.pathSeparator + 'diagnostics');
      _dir!.createSync(recursive: true);
      final marker = _file('manual_active.flag');
      final interrupted = marker.existsSync();
      if (interrupted) {
        _appendBounded(_file('manual_session.txt'), _line('session_interrupted'), _manualLimit);
        marker.deleteSync();
      }

      final previousLaunch = _readInt('last_launch_ms.txt');
      final previousExit = _readInt('consumed_exit_ms.txt');
      Map<dynamic, dynamic>? exit;
      if (Platform.isAndroid) {
        try {
          exit = await _android.invokeMapMethod<dynamic, dynamic>('lastExit');
        } on PlatformException {
          // Native exit history is best-effort, including on older Android.
        } on MissingPluginException {
          // Tests and non-Android builds do not provide this channel.
        }
      }

      final timestamp = exit?['timestamp'];
      if (previousLaunch > 0 && timestamp is int &&
          timestamp >= previousLaunch && timestamp > previousExit) {
        final reason = _safeCode(exit?['reason']);
        final category = _safeCode(exit?['classification']);
        final classification = category == 'confirmed_crash'
            ? 'confirmed_crash'
            : 'process_termination';
        _startupClassification = classification;
        final exceptionReport = _exists('crash_report.txt') &&
                _file('crash_report.txt').lastModifiedSync().millisecondsSinceEpoch >= previousLaunch
            ? _file('crash_report.txt').readAsStringSync()
            : '';
        if (classification == 'confirmed_crash' ||
            exceptionReport.isNotEmpty ||
            !_exists('crash_report.txt')) {
          _writeCrashReport(
          'Classification: $classification\n'
          'Android exit reason: $reason\n'
          'Exit time (epoch ms): $timestamp\n'
          'Note: Android exit reason does not guarantee a stack trace.\n'
          + (exceptionReport.isEmpty ? '' : '\nCaptured Dart exception:\n$exceptionReport\n'),
          );
        }
        _file('consumed_exit_ms.txt').writeAsStringSync('$timestamp', flush: true);
      } else if (interrupted) {
        _startupClassification = 'unknown_termination';
        if (!_exists('crash_report.txt')) {
          _writeCrashReport(
            'Classification: unknown_termination\n'
            'Manual recording was interrupted. No confirmed OS crash reason available.\n'
            'No stack trace was recovered.\n',
          );
        }
      }

      _file('last_launch_ms.txt')
          .writeAsStringSync('${DateTime.now().millisecondsSinceEpoch}', flush: true);
      record(DiagnosticEvent.appStarted);
    } catch (_) {
      _writeFailed = true;
      // Never make app startup depend on diagnostics storage or Android APIs.
    }
  }

  int _readInt(String name) {
    try {
      final f = _file(name);
      return f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) ?? 0 : 0;
    } catch (_) {
      return 0;
    }
  }

  String _safeCode(Object? value) {
    final s = value is String ? value : 'unavailable';
    final safe = s.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    return safe.length <= 48 ? safe : safe.substring(0, 48);
  }

  String _line(String event) =>
      '${DateTime.now().toUtc().toIso8601String()} | $event\n';

  bool startManual() {
    if (_dir == null) return false;
    try {
      // Replaces the previous session; does NOT touch the independent crash log.
      _file('manual_session.txt').writeAsStringSync(
        'FIYORA MANUAL DIAGNOSTICS\n'
        'Privacy: event codes only; no filenames, paths or file contents.\n'
        'Timestamp: UTC\n',
        flush: true,
      );
      _file('manual_active.flag').writeAsStringSync('active', flush: true);
      _manualActive = true;
      record(DiagnosticEvent.sessionStarted);
      return true;
    } catch (_) {
      _manualActive = false;
      _writeFailed = true;
      return false;
    }
  }

  void stopManual() {
    if (!_manualActive) return;
    record(DiagnosticEvent.sessionStopped);
    _manualActive = false;
    try {
      final marker = _file('manual_active.flag');
      if (marker.existsSync()) marker.deleteSync();
    } catch (_) {
      _writeFailed = true;
    }
  }

  void record(DiagnosticEvent event) => _recordSafeCode(event.name);

  /// Outcome captures the operation and exception TYPE, never its message.
  void recordOutcome(DiagnosticEvent operation, {required bool success, Object? failure}) {
    final status = success ? 'success' : 'failure';
    final type = failure == null ? '' : '_' + _safeCode(failure.runtimeType.toString());
    _recordSafeCode('outcome_' + operation.name + '_' + status + type);
  }

  void _recordSafeCode(String code) {
    if (_dir == null) return;
    try {
      final entry = _line(code);
      _appendBounded(_file('breadcrumbs.txt'), entry, _breadcrumbLimit);
      if (_manualActive) {
        _appendBounded(_file('manual_session.txt'), entry, _manualLimit);
      }
    } catch (_) {
      _writeFailed = true;
    }
  }


  int _archiveSequence = 0;

  String nextArchiveOperationId() {
    _archiveSequence++;
    return 'extract_${DateTime.now().microsecondsSinceEpoch}_$_archiveSequence';
  }

  /// Path classification is closed-vocabulary. No filename or directory
  /// appears in diagnostic output.
  static String archiveFormatCode(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.zip.001')) return 'split_zip';
    if (p.endsWith('.zip')) return 'zip';
    if (p.endsWith('.tar.gz') || p.endsWith('.tgz')) return 'tar_gz';
    if (p.endsWith('.tar.bz2') || p.endsWith('.tbz2')) return 'tar_bz2';
    if (p.endsWith('.tar.lz4') || p.endsWith('.tlz4')) return 'tar_lz4';
    if (p.endsWith('.tar.zst') || p.endsWith('.tzst')) return 'tar_zst';
    if (p.endsWith('.tar')) return 'tar';
    if (p.endsWith('.gz')) return 'gz';
    if (p.endsWith('.bz2')) return 'bz2';
    if (p.endsWith('.lz4')) return 'lz4';
    if (p.endsWith('.zst') || p.endsWith('.zstd')) return 'zst';
    return 'unknown';
  }

  /// Inspect text only in memory to derive a coarse category. Never write the
  /// exception message, which may contain a path, filename or secret.
  static DiagnosticArchiveFailure archiveFailureCode(Object error) {
    if (error is FileSystemException) {
      switch (error.osError?.errorCode) {
        case 2: return DiagnosticArchiveFailure.sourceMissing;
        case 13: return DiagnosticArchiveFailure.permissionDenied;
        case 17: return DiagnosticArchiveFailure.destinationConflict;
        case 28: return DiagnosticArchiveFailure.storageFull;
      }
    }
    final text = error.toString().toLowerCase();
    if (text.contains('already exists') || text.contains('file exists') ||
        text.contains('destination conflict')) {
      return DiagnosticArchiveFailure.destinationConflict;
    }
    if (text.contains('unsafe') || text.contains('traversal') ||
        text.contains('zip slip') || text.contains('symlink')) {
      return DiagnosticArchiveFailure.unsafeArchive;
    }
    if (text.contains('password') || text.contains('decrypt') ||
        text.contains('encrypted')) {
      return DiagnosticArchiveFailure.passwordOrEncryption;
    }
    if (text.contains('not found') || text.contains('no such file')) {
      return DiagnosticArchiveFailure.sourceMissing;
    }
    if (text.contains('unsupported') || text.contains('not supported')) {
      return DiagnosticArchiveFailure.unsupportedFormat;
    }
    if (text.contains('corrupt') || text.contains('invalid archive') ||
        text.contains('checksum') || text.contains('invalid signature') ||
        text.contains('crc')) {
      return DiagnosticArchiveFailure.invalidArchive;
    }
    return error is FileSystemException
        ? DiagnosticArchiveFailure.filesystemError
        : DiagnosticArchiveFailure.unknown;
  }

  /// Keep source coordinates in package:nfile only; discard all external,
  /// absolute, URI and user-dependent frame paths.
  static String safeApplicationFrames(StackTrace? trace) {
    if (trace == null) return '';
    final frame = RegExp(r'^#\d+\s+(.+?)\s+\((package:nfile/[a-zA-Z0-9_./:-]+)\)');
    final result = <String>[];
    for (final line in trace.toString().split('\n')) {
      final match = frame.firstMatch(line.trim());
      if (match == null) continue;
      final method = match.group(1)!.replaceAll(RegExp(r'[^a-zA-Z0-9_.$<> ]'), '');
      result.add('$method@${match.group(2)}');
      if (result.length >= 6) break;
    }
    return result.join('|');
  }

  void recordArchivePhase({
    required String operationId,
    required DiagnosticArchivePhase phase,
    required String format,
    int? elapsedMs,
    DiagnosticArchiveFailure? failure,
    String? exceptionType,
    String? applicationFrames,
  }) {
    final id = RegExp(r'^extract_[0-9]{10,20}_[0-9]{1,6}$').hasMatch(operationId)
        ? operationId : 'invalid';
    const validFormats = {
      'split_zip', 'zip', 'tar_gz', 'tar_bz2', 'tar_lz4',
      'tar_zst', 'tar', 'gz', 'bz2', 'lz4', 'zst', 'unknown',
    };
    final knownFormat = validFormats.contains(format) ? format : 'unknown';
    final duration = elapsedMs == null
        ? '' : ' duration_ms=${elapsedMs.clamp(0, 86400000)}';
    final code = failure == null ? '' : ' failure=${failure.name}';
    final type = exceptionType == null ? '' :
        ' exception_type=${_safeCode(exceptionType)}';
    final safeFrames = <String>[];
    final framePattern = RegExp(r'^[a-zA-Z0-9_.$<> ]+@package:nfile/[a-zA-Z0-9_./:-]+$');
    for (final frame in applicationFrames?.split('|') ?? const <String>[]) {
      if (framePattern.hasMatch(frame)) safeFrames.add(frame);
      if (safeFrames.length >= 6) break;
    }
    final frames = safeFrames.isEmpty ? '' : ' app_frames=${safeFrames.join('|')}';
    _recordSafeCode(
      'operation=archiveExtract op_id=$id phase=${phase.name} '
      'format=$knownFormat$duration$code$type$frames',
    );
  }

  /// Explicitly record handled failures; these never reach global error hooks.
  void recordHandledError(
    DiagnosticEvent operation,
    Object error,
    StackTrace trace,
  ) {
    final type = _safeCode(error.runtimeType.toString());
    final code = archiveFailureCode(error);
    _recordSafeCode(
      'handled_error operation=${operation.name} exception_type=$type '
      'failure=${code.name} app_frames=${safeApplicationFrames(trace)}',
    );
  }

  /// Store exception *type* and in-package stack frames only. The exception's
  /// message and external paths are deliberately excluded for privacy.
  void captureException(String source, Object error, StackTrace? trace) {
    if (_dir == null) return;
    try {
      const allowedSources = {'flutter_framework', 'platform_dispatcher'};
      final origin = allowedSources.contains(source) ? source : 'unknown';
      final type = _safeCode(error.runtimeType.toString());
      final safeFrames = <String>[];
      if (trace != null) {
        final frame = RegExp(r'^#\d+\s+(.+?)\s+\((package:nfile/[a-zA-Z0-9_./:-]+)\)');
        for (final line in trace.toString().split('\n')) {
          final m = frame.firstMatch(line.trim());
          if (m == null) continue;
          final method = m.group(1)!.replaceAll(RegExp(r'[^a-zA-Z0-9_.$<> ]'), '');
          safeFrames.add('$method @ ${m.group(2)}');
          if (safeFrames.length >= 12) break;
        }
      }
      _recordSafeCode(
        'unhandled_error source=$origin exception_type=$type '
        'app_frames=${safeApplicationFrames(trace)}',
      );
      _writeCrashReport(
        'Classification: unhandled_exception (process crash NOT confirmed)\n'
        'Captured: ${DateTime.now().toUtc().toIso8601String()} UTC\n'
        'Source: $origin\n'
        'Exception type: $type\n'
        'Stack: ${safeFrames.isEmpty ? "unavailable" : safeFrames.join(" | ")}\n',
      );
    } catch (_) {
      _writeFailed = true;
    }
  }

  void _writeCrashReport(String content) {
    if (_dir == null) return;
    try {
      String recent = '';
      if (_exists('breadcrumbs.txt')) {
        recent = _file('breadcrumbs.txt').readAsStringSync();
      }
      final maxHead = content.length > 16 * 1024 ? content.substring(0, 16 * 1024) : content;
      _file('crash_report.txt').writeAsStringSync(
        'FIYORA CRASH / TERMINATION DIAGNOSTICS\n'
        '$maxHead\nRecent breadcrumbs (bounded):\n$recent',
        flush: true,
      );
    } catch (_) {
      _writeFailed = true;
    }
  }

  void clearCrashReport() {
    try {
      if (_exists('crash_report.txt')) _file('crash_report.txt').deleteSync();
    } catch (_) {
      _writeFailed = true;
    }
  }

  String preview({required bool crash, int maxCharacters = 4500}) {
    final name = crash ? 'crash_report.txt' : 'manual_session.txt';
    try {
      if (!_exists(name)) return 'No report available.';
      final s = _file(name).readAsStringSync();
      return s.length > maxCharacters ? '... earlier entries omitted ...\n' + s.substring(s.length - maxCharacters) : s;
    } catch (_) {
      return 'Unable to read diagnostics.';
    }
  }

  /// Explicit, user-initiated export. Reports stay in app-private storage until
  /// requested, then are copied to visible Downloads for the user's file manager.
  Future<File> exportToDownloads({required bool crash}) async {
    if (_dir == null) throw StateError('Diagnostics storage unavailable');
    final source = _file(crash ? 'crash_report.txt' : 'manual_session.txt');
    if (!await source.exists()) throw StateError('No report exists');
    if (!Platform.isAndroid) throw UnsupportedError('Downloads export requires Android');
    final destination = Directory('/storage/emulated/0/Download/FIYORA/Diagnostics');
    await destination.create(recursive: true);
    final name = crash ? 'crash' : 'manual';
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    return source.copy(destination.path + '/FIYORA_' + name + '_' + stamp.toString() + '.txt');
  }

  void _appendBounded(File target, String entry, int limit) {
    final size = utf8.encode(entry).length;
    if (size > limit) return;
    final previous = target.existsSync() ? target.lengthSync() : 0;
    if (previous + size > limit) {
      final lines = target.existsSync() ? target.readAsLinesSync() : <String>[];
      final retained = <String>[];
      var used = 0;
      for (final line in lines.reversed) {
        final bytes = utf8.encode(line).length + 1;
        if (used + bytes > limit ~/ 2) break;
        retained.insert(0, line);
        used += bytes;
      }
      // Write the replacement separately, then swap it into place. A crash
      // during trimming must not leave the previous breadcrumb file empty.
      final replacement = File(target.path + '.rotating');
      replacement.writeAsStringSync(
        '... older entries truncated (bounded log) ...\n'
        + (retained.isEmpty ? '' : retained.join('\n') + '\n'),
        flush: true,
      );
      replacement.renameSync(target.path);
    }
    // A completed kernel write survives an app process crash; avoid fsync on
    // every UI event to reduce main-isolate stalls. Fatal reports use flush.
    target.writeAsStringSync(entry, mode: FileMode.append);
  }
}
