import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Best-effort rollback of new paths created by a single extraction attempt.
///
/// Exclusive file creation and operation-specific directory markers protect
/// against commonly observable replacement races. File metadata is a
/// conservative change detector, NOT a stable object identity. Dart has no
/// portable atomic identity-checked unlink; an external actor can still race
/// the final check/delete. This is not a concurrent transaction.
class ArchiveExtractionRollback {
  final List<_TrackedPath> _createdFiles = [];
  final List<_TrackedDirectory> _createdDirectories = [];
  final String _token = _newToken();
  int _markerSerial = 0;

  static String _newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void createFile(String path) {
    _ensureParentDirectories(path);
    final file = File(path);
    file.createSync(exclusive: true);
    _createdFiles.add(_TrackedPath(file.path, file.statSync()));
  }

  /// Call after closing the writer, including when a write throws.
  void noteFileWritten(String path) {
    for (final tracked in _createdFiles.reversed) {
      if (tracked.path != path) continue;
      try {
        if (_parentsHaveNoSymlinks(path) &&
            FileSystemEntity.typeSync(path, followLinks: false) ==
                FileSystemEntityType.file) {
          tracked.stamp = FileStat.statSync(path);
        }
      } catch (_) {}
      return;
    }
  }

  void createDirectory(String path) {
    _ensureParentDirectories(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) return;
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Archive output directory conflicts with existing entity',
        path,
      );
    }
    _createTrackedDirectory(path);
  }

  void _createTrackedDirectory(String path) {
    Directory(path).createSync();
    // The marker is created only in a directory made by THIS extraction.
    // A replacement directory will lack this marker even if timestamps match.
    final marker = p.join(path, '.fiyora-extract-rollback-$_token-${_markerSerial++}');
    try {
      final file = File(marker);
      file.createSync(exclusive: true);
      file.writeAsStringSync(_token);
      _createdDirectories.add(_TrackedDirectory(path, marker));
    } catch (_) {
      // Do not delete an uncertain path on marker failure.
      rethrow;
    }
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
    if (!_parentsHaveNoSymlinks(path)) {
      throw FileSystemException('Archive output parent is a symbolic link', path);
    }
    for (final directory in missing.reversed) {
      _createTrackedDirectory(directory);
    }
  }

  bool _parentsHaveNoSymlinks(String path) {
    var parent = p.dirname(path);
    while (true) {
      if (FileSystemEntity.typeSync(parent, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      final next = p.dirname(parent);
      if (next == parent) return true;
      parent = next;
    }
  }

  bool _unchangedFile(_TrackedPath tracked) {
    try {
      if (!_parentsHaveNoSymlinks(tracked.path) ||
          FileSystemEntity.typeSync(tracked.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      final current = FileStat.statSync(tracked.path);
      final expected = tracked.stamp;
      return current.type == FileSystemEntityType.file &&
          current.size == expected.size &&
          current.mode == expected.mode &&
          current.changed == expected.changed &&
          current.modified == expected.modified;
    } catch (_) {
      return false;
    }
  }

  bool _ownsDirectory(_TrackedDirectory dir) {
    try {
      if (!_parentsHaveNoSymlinks(dir.path) ||
          FileSystemEntity.typeSync(dir.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          FileSystemEntity.typeSync(dir.marker, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      return File(dir.marker).readAsStringSync() == _token;
    } catch (_) {
      return false;
    }
  }

  /// Remove private markers after successful extraction; keep user outputs.
  void complete() {
    for (final dir in _createdDirectories.reversed) {
      try {
        if (_ownsDirectory(dir)) File(dir.marker).deleteSync();
      } catch (_) {}
    }
  }

  void rollback() {
    // Delete only unchanged files and operation-marked directories.
    // Never use recursive deletion on a user-visible destination.
    for (final tracked in _createdFiles.reversed) {
      try {
        if (_unchangedFile(tracked)) File(tracked.path).deleteSync();
      } catch (_) {
        // Keep original extraction failure; leave ambiguous ownership intact.
      }
    }
    for (final dir in _createdDirectories.reversed) {
      try {
        if (!_ownsDirectory(dir)) continue;
        File(dir.marker).deleteSync();
        // Nonrecursive delete refuses to remove another actor's new contents.
        Directory(dir.path).deleteSync();
      } catch (_) {}
    }
  }
}

class _TrackedPath {
  _TrackedPath(this.path, this.stamp);
  final String path;
  FileStat stamp;
}

class _TrackedDirectory {
  _TrackedDirectory(this.path, this.marker);
  final String path;
  final String marker;
}
