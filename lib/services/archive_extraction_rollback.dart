import 'dart:io';

import 'package:path/path.dart' as p;

/// Best-effort rollback of new paths created by one extraction attempt.
///
/// Snapshot checks prevent deletion of *observably changed* paths, but
/// dart:io does not expose an atomic compare-identity-and-unlink primitive.
/// Concurrent replacements that reproduce the same metadata or occur between
/// the final check and deletion are NOT proven safe. Do not use this as a
/// full transactional or concurrent-ownership guarantee.
class ArchiveExtractionRollback {
  final List<_TrackedPath> _createdFiles = [];
  final List<_TrackedPath> _createdDirectories = [];

  void createFile(String path) {
    _ensureParentDirectories(path);
    final file = File(path);
    file.createSync(exclusive: true);
    _createdFiles.add(_TrackedPath(file.path, file.statSync()));
    _refreshCreatedParentStamps(path);
  }

  /// Must be called after closing an output stream (including on write error).
  /// If a different actor has changed the output by rollback time, skip it.
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
    Directory(path).createSync();
    _createdDirectories.add(_TrackedPath(path, FileStat.statSync(path)));
    _refreshCreatedParentStamps(path);
  }

  void _ensureParentDirectories(String path) {
    var parent = p.dirname(path);
    final missing = <String>[];
    while (!Directory(parent).existsSync()) {
      if (FileSystemEntity.typeSync(parent, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Archive output parent is not a directory',
          parent,
        );
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
      Directory(directory).createSync();
      _createdDirectories.add(_TrackedPath(directory, FileStat.statSync(directory)));
      _refreshCreatedParentStamps(directory);
    }
  }

  void _refreshCreatedParentStamps(String path) {
    for (final tracked in _createdDirectories) {
      if (!p.isWithin(tracked.path, path)) continue;
      try {
        tracked.stamp = FileStat.statSync(tracked.path);
      } catch (_) {}
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

  bool _unchanged(_TrackedPath tracked, FileSystemEntityType kind) {
    try {
      if (!_parentsHaveNoSymlinks(tracked.path) ||
          FileSystemEntity.typeSync(tracked.path, followLinks: false) != kind) {
        return false;
      }
      final current = FileStat.statSync(tracked.path);
      final expected = tracked.stamp;
      return current.type == kind &&
          current.size == expected.size &&
          current.mode == expected.mode &&
          current.changed == expected.changed &&
          current.modified == expected.modified;
    } catch (_) {
      return false;
    }
  }

  void rollback() {
    // Evaluate directories BEFORE file cleanup, which changes parent stamps.
    final originalDirectories = <String, bool>{
      for (final tracked in _createdDirectories)
        tracked.path: _unchanged(tracked, FileSystemEntityType.directory),
    };

    for (final tracked in _createdFiles.reversed) {
      try {
        if (_unchanged(tracked, FileSystemEntityType.file)) {
          File(tracked.path).deleteSync();
        }
      } catch (_) {
        // Original extraction error takes priority over cleanup failure.
      }
    }
    for (final tracked in _createdDirectories.reversed) {
      try {
        if (originalDirectories[tracked.path] == true &&
            _parentsHaveNoSymlinks(tracked.path) &&
            FileSystemEntity.typeSync(tracked.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          // Nonrecursive; refuse to delete directories with any contents.
          Directory(tracked.path).deleteSync();
        }
      } catch (_) {}
    }
  }
}

class _TrackedPath {
  _TrackedPath(this.path, this.stamp);
  final String path;
  FileStat stamp;
}
