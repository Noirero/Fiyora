import 'dart:io';

import 'package:path/path.dart' as p;

/// Best-effort rollback of outputs created by ONE extraction attempt.
///
/// Existing files are never registered here: all file creation is exclusive.
/// This covers ordinary Dart exceptions, not isolate force-kill, app crashes,
/// power loss or concurrent replacement of an output path.
class ArchiveExtractionRollback {
  final List<String> _createdFiles = [];
  final List<String> _createdDirectories = [];

  void createFile(String path) {
    _ensureParentDirectories(path);
    final file = File(path);
    file.createSync(exclusive: true);
    _createdFiles.add(file.path);
  }

  void createDirectory(String path) {
    _ensureParentDirectories(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) return;
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException('Archive output directory conflicts with existing entity', path);
    }
    Directory(path).createSync();
    _createdDirectories.add(path);
  }

  void _ensureParentDirectories(String path) {
    var parent = p.dirname(path);
    final missing = <String>[];
    while (!Directory(parent).existsSync()) {
      if (FileSystemEntity.typeSync(parent, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Archive output parent is not a directory', parent);
      }
      missing.add(parent);
      final next = p.dirname(parent);
      if (next == parent) {
        throw FileSystemException('Archive output has no valid ancestor', path);
      }
      parent = next;
    }
    for (final directory in missing.reversed) {
      Directory(directory).createSync();
      _createdDirectories.add(directory);
    }
  }

  void rollback() {
    // Never remove user files that predated extraction: createFile records
    // a path only after exclusive creation by this operation succeeded.
    for (final path in _createdFiles.reversed) {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.file) {
          File(path).deleteSync();
        }
      } catch (_) {
        // A cleanup error must not replace the original extraction failure.
      }
    }
    // Non-recursive directory deletion refuses to remove nonempty directories.
    for (final path in _createdDirectories.reversed) {
      try {
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.directory) {
          Directory(path).deleteSync();
        }
      } catch (_) {}
    }
  }
}
