import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/services/archive_service.dart';
import 'package:nfile/services/background_archive_service.dart';
import 'package:path/path.dart' as p;

typedef _Compress =
    Future<void> Function(
      List<String> sources,
      String destination,
      bool deleteSource,
    );

Future<void> _direct(
  List<String> sources,
  String destination,
  bool deleteSource, {
  bool separateArchives = false,
  int? splitSizeMB,
}) => ArchiveService.createArchive(
  sourcePaths: sources,
  destinationDir: p.dirname(destination),
  archiveName: p.basenameWithoutExtension(destination),
  format: 'zip',
  compressionLevel: 6,
  deleteSource: deleteSource,
  separateArchives: separateArchives,
  splitSizeMB: splitSizeMB,
);

Future<void> _background(
  List<String> sources,
  String destination,
  bool deleteSource,
) async {
  final messages = ReceivePort();
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      BackgroundArchiveService.compressIsolateTask,
      <String, dynamic>{
        'sendPort': messages.sendPort,
        'sourcePaths': sources,
        'destinationPath': destination,
        'format': 'zip',
        'level': 6,
        'deleteSource': deleteSource,
      },
      onError: messages.sendPort,
    );
    final result = await messages
        .firstWhere((event) {
          return event is! Map || event['status'] != 'progress';
        })
        .timeout(const Duration(seconds: 20));
    if (result is! Map || result['status'] != 'completed') {
      throw StateError(result is Map ? '${result['error']}' : '$result');
    }
  } finally {
    worker?.kill(priority: Isolate.immediate);
    messages.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late Directory source;
  late File original;
  const contents = 'original data must survive';

  setUp(() {
    fixture = Directory.systemTemp.createTempSync('nfile_ar001_');
    source = Directory(p.join(fixture.path, 'source'))..createSync();
    original = File(p.join(source.path, 'original.txt'))
      ..writeAsStringSync(contents);
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  Future<void> expectUnsafe(
    _Compress compress,
    List<String> sources,
    String destination, {
    bool deleteSource = true,
  }) async {
    await expectLater(
      compress(sources, destination, deleteSource),
      throwsA(
        predicate<Object>(
          (e) => e.toString().contains('Unsafe archive destination'),
        ),
      ),
    );
    expect(original.readAsStringSync(), contents);
  }

  void expectArchive(String destination) {
    final archive = ZipDecoder().decodeBytes(
      File(destination).readAsBytesSync(),
    );
    final entry = archive.files.singleWhere(
      (f) => f.name.endsWith('original.txt'),
    );
    expect(entry.content, contents.codeUnits);
  }

  for (final entry in <String, _Compress>{
    'direct': _direct,
    'background isolate': _background,
  }.entries) {
    final compress = entry.value;
    group(entry.key, () {
      test(
        'rejects current-folder output before deleting original or archive',
        () async {
          final destination = p.join(source.path, 'output.zip');
          await expectUnsafe(compress, [source.path], destination);
          expect(File(destination).existsSync(), isFalse);
        },
      );

      test(
        'rejects nested output, including missing parent directories',
        () async {
          final destination = p.join(
            source.path,
            'new',
            'nested',
            'output.zip',
          );
          await expectUnsafe(compress, [source.path], destination);
          expect(Directory(p.join(source.path, 'new')).existsSync(), isFalse);
        },
      );

      test(
        'rejects normalized relative source and destination paths',
        () async {
          Directory(p.join(source.path, 'child')).createSync();
          final destination = p.join(source.path, 'child', '..', 'output.zip');
          await expectUnsafe(compress, [
            p.relative(source.path),
          ], p.relative(destination));
          expect(File(destination).existsSync(), isFalse);
        },
      );

      for (final deleteSource in [false, true]) {
        test(
          'rejects identical source file with deleteSource=$deleteSource',
          () async {
            final input = File(p.join(source.path, 'input.zip'))
              ..writeAsStringSync(contents);
            await expectUnsafe(
              compress,
              [input.path],
              input.path,
              deleteSource: deleteSource,
            );
            expect(input.readAsStringSync(), contents);
          },
        );

        test(
          'rejects output symlink alias to source with deleteSource=$deleteSource',
          () async {
            final destination = p.join(fixture.path, 'alias.zip');
            Link(destination).createSync(original.path);
            await expectUnsafe(
              compress,
              [original.path],
              destination,
              deleteSource: deleteSource,
            );
            expect(Link(destination).existsSync(), isTrue);
          },
        );
      }

      test(
        'resolves symlinked destination ancestor with missing descendants',
        () async {
          final alias = Link(p.join(fixture.path, 'alias'))
            ..createSync(source.path);
          final destination = p.join(alias.path, 'new', 'output.zip');
          await expectUnsafe(compress, [source.path], destination);
          expect(Directory(p.join(source.path, 'new')).existsSync(), isFalse);
        },
      );

      test('resolves symlinked source directory', () async {
        final alias = Link(p.join(fixture.path, 'alias'))
          ..createSync(source.path);
        await expectUnsafe(compress, [
          alias.path,
        ], p.join(source.path, 'output.zip'));
        expect(alias.existsSync(), isTrue);
      });

      test('resolves symlinks before parent traversal', () async {
        final nested = Directory(p.join(source.path, 'nested'))..createSync();
        final alias = Link(p.join(fixture.path, 'alias'))
          ..createSync(nested.path);
        final destination = p.join(alias.path, '..', 'output.zip');
        await expectUnsafe(compress, [source.path], destination);
        expect(File(p.join(source.path, 'output.zip')).existsSync(), isFalse);
      });

      test('fails closed for dangling output symlink', () async {
        final destination = p.join(fixture.path, 'dangling.zip');
        Link(destination).createSync(p.join(source.path, 'missing.zip'));
        await expectLater(
          compress([source.path], destination, true),
          throwsA(
            predicate<Object>(
              (e) => e.toString().contains('Cannot resolve symbolic links'),
            ),
          ),
        );
        expect(original.readAsStringSync(), contents);
        expect(File(p.join(source.path, 'missing.zip')).existsSync(), isFalse);
      });

      test('checks destination against every selected source', () async {
        final other = File(p.join(fixture.path, 'other.txt'))
          ..writeAsStringSync('other');
        final destination = p.join(source.path, 'output.zip');
        await expectUnsafe(compress, [other.path, source.path], destination);
        expect(other.readAsStringSync(), 'other');
        expect(File(destination).existsSync(), isFalse);
      });

      test('rejects hard-link alias to a source file', () async {
        final destination = p.join(fixture.path, 'hardlink.zip');
        final result = Process.runSync('ln', [original.path, destination]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        await expectUnsafe(
          compress,
          [original.path],
          destination,
          deleteSource: false,
        );
        expect(File(destination).readAsStringSync(), contents);
      }, skip: Platform.isWindows);

      test(
        'allows sibling prefix destination and deletes source after success',
        () async {
          final outside = Directory('${source.path}-backups')..createSync();
          final destination = p.join(outside.path, 'output.zip');
          await compress([source.path], destination, true);
          expectArchive(destination);
          expect(source.existsSync(), isFalse);
        },
      );

      test('allows output inside source when deletion is disabled', () async {
        final destination = p.join(source.path, 'output.zip');
        await compress([source.path], destination, false);
        expectArchive(destination);
        expect(original.readAsStringSync(), contents);
      });

      test('allows external output through a safe symlink', () async {
        final outside = Directory(p.join(fixture.path, 'outside'))
          ..createSync();
        final alias = Link(p.join(fixture.path, 'alias'))
          ..createSync(outside.path);
        final destination = p.join(alias.path, 'output.zip');
        await compress([original.path], destination, false);
        expectArchive(destination);
        expect(original.readAsStringSync(), contents);
      });
    });
  }

  test(
    'direct: preflights every separate archive before any source deletion',
    () async {
      final first = File(p.join(fixture.path, 'first.txt'))
        ..writeAsStringSync('first');
      final collision = File(p.join(source.path, 'collision.zip'))
        ..writeAsStringSync(contents);
      await expectUnsafe(
        (sources, destination, deleteSource) =>
            _direct(sources, destination, deleteSource, separateArchives: true),
        [first.path, collision.path],
        p.join(source.path, 'unused.zip'),
      );
      expect(first.readAsStringSync(), 'first');
      expect(collision.readAsStringSync(), contents);
      expect(File(p.join(source.path, 'first.zip')).existsSync(), isFalse);
    },
  );

  for (final deleteSource in [false, true]) {
    test(
      'direct: rejects same-basename separate archives before any writes '
      '(deleteSource=$deleteSource)',
      () async {
        final outside = Directory(p.join(fixture.path, 'outside'))..createSync();
        final first = File(p.join(source.path, 'duplicate.txt'))
          ..writeAsStringSync('first');
        final second = File(p.join(source.path, 'duplicate.md'))
          ..writeAsStringSync('second');
        final destination = p.join(outside.path, 'duplicate.zip');
        await expectLater(
          _direct(
            [first.path, second.path],
            p.join(outside.path, 'unused.zip'),
            deleteSource,
            separateArchives: true,
          ),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString().contains('duplicate archive output'),
            ),
          ),
        );
        expect(first.readAsStringSync(), 'first');
        expect(second.readAsStringSync(), 'second');
        expect(File(destination).existsSync(), isFalse);
      },
    );
  }

  test(
    'direct: valid separate archives still compress and delete sources',
    () async {
      final outside = Directory(p.join(fixture.path, 'outside'))..createSync();
      final second = File(p.join(fixture.path, 'second.txt'))
        ..writeAsStringSync('second');
      await _direct(
        [original.path, second.path],
        p.join(outside.path, 'unused.zip'),
        true,
        separateArchives: true,
      );
      expectArchive(p.join(outside.path, 'original.zip'));
      expect(original.existsSync(), isFalse);
      expect(second.existsSync(), isFalse);
      final archive = ZipDecoder().decodeBytes(
        File(p.join(outside.path, 'second.zip')).readAsBytesSync(),
      );
      expect(archive.files.single.content, 'second'.codeUnits);
    },
  );

  test(
    'direct: rejects split volume colliding with a selected source',
    () async {
      final random = Random(1);
      final large = File(p.join(source.path, 'large.bin'))
        ..writeAsBytesSync(List.generate(1200000, (_) => random.nextInt(256)));
      final destination = p.join(fixture.path, 'output.zip');
      final volume = File('$destination.001')..writeAsStringSync(contents);
      final originalBytes = large.readAsBytesSync();
      await expectUnsafe(
        (sources, destination, deleteSource) =>
            _direct(sources, destination, deleteSource, splitSizeMB: 1),
        [large.path, volume.path],
        destination,
      );
      expect(large.readAsBytesSync(), originalBytes);
      expect(volume.readAsStringSync(), contents);
      expect(File(destination).existsSync(), isFalse);
    },
  );

  test(
    'direct: valid split volumes reconstruct the archive before deleting source',
    () async {
      final random = Random(2);
      final bytes = List.generate(1200000, (_) => random.nextInt(256));
      final input = File(p.join(source.path, 'large.bin'))
        ..writeAsBytesSync(bytes);
      final destination = p.join(fixture.path, 'split.zip');
      await _direct([input.path], destination, true, splitSizeMB: 1);
      expect(input.existsSync(), isFalse);
      expect(File(destination).existsSync(), isFalse);
      final combined = <int>[];
      for (var part = 1; ; part++) {
        final volume = File('$destination.${part.toString().padLeft(3, '0')}');
        if (!volume.existsSync()) break;
        combined.addAll(volume.readAsBytesSync());
      }
      final archive = ZipDecoder().decodeBytes(combined);
      expect(archive.files.single.name, 'large.bin');
      expect(archive.files.single.content, bytes);
    },
  );
}
