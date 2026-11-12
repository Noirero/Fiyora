import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'archive_extraction_safety.dart';

/// Reject pre-existing outputs, including symbolic links and directories.
/// Caller must still create the new output with exclusive: true.
void validateNewArchiveOutputPaths(Iterable<String> paths) {
  for (final path in paths) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('Archive output already exists; overwrite refused', path);
    }
  }
}

/// Fail instead of truncating an existing file. This is an exclusive pathname
/// creation, not a lock against later concurrent filesystem changes.
void createArchiveOutputExclusively(File file, {bool recursive = false}) {
  file.createSync(recursive: recursive, exclusive: true);
}

String checkedNewArchiveExtractionFilePath(String destinationDir, String name) {
  final path = checkedArchiveExtractionPath(destinationDir, name);
  validateNewArchiveOutputPaths([path]);
  return path;
}

/// Validate the full decoded extraction plan before writing the first file.
/// Existing directories can be reused, but files/links and duplicate entries
/// may never be silently overwritten. Does not provide transactional rollback.
void validateArchiveExtractionPlan(
  String destinationDir,
  Iterable<ArchiveFile> entries,
) {
  final root = Directory(destinationDir).absolute.resolveSymbolicLinksSync();
  final targets = <String, bool>{}; // true = file, false = directory

  for (final entry in entries) {
    final path = checkedArchiveExtractionPath(destinationDir, entry.name);
    final existing = FileSystemEntity.typeSync(path, followLinks: false);

    if (entry.isFile) {
      if (existing != FileSystemEntityType.notFound ||
          targets.containsKey(path)) {
        throw FileSystemException(
          'Archive entry conflicts with an existing or duplicate output',
          path,
        );
      }
      targets[path] = true;
    } else {
      if (existing != FileSystemEntityType.notFound &&
          existing != FileSystemEntityType.directory) {
        throw FileSystemException('Archive directory conflicts with a file', path);
      }
      if (targets[path] == true) {
        throw FileSystemException('Archive file/directory name collision', path);
      }
      targets[path] = false;
    }
  }

  for (final path in targets.keys) {
    var parent = p.dirname(path);
    while (p.equals(root, parent) || p.isWithin(root, parent)) {
      if (targets[parent] == true ||
          (FileSystemEntity.typeSync(parent, followLinks: false) !=
                  FileSystemEntityType.notFound &&
              FileSystemEntity.typeSync(parent, followLinks: false) !=
                  FileSystemEntityType.directory)) {
        throw FileSystemException('Archive output parent is not a directory', parent);
      }
      if (p.equals(root, parent)) break;
      parent = p.dirname(parent);
    }
  }
}
