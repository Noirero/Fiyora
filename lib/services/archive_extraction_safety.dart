import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves one untrusted archive entry under the user-selected extraction root.
/// Rejects parent traversal, rooted/drive paths, and existing symlinks in the
/// extracted path. This is not an atomic defense against concurrent FS changes.
String checkedArchiveExtractionPath(String destinationDir, String entryName) {
  final portableName = entryName.replaceAll('\\', '/');
  if (portableName.isEmpty ||
      portableName.contains('\u0000') ||
      portableName.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(portableName)) {
    throw FileSystemException('Unsafe archive entry path', entryName);
  }

  final parts = portableName
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.contains('..')) {
    throw FileSystemException('Archive entry contains parent traversal', entryName);
  }

  // Preserve existing behavior for a destination directory created on demand.
  final root = Directory(destinationDir);
  if (!root.existsSync()) {
    root.createSync(recursive: true);
  }
  final canonicalRoot = root.resolveSymbolicLinksSync();
  var target = canonicalRoot;

  for (final component in parts) {
    target = p.join(target, component);
    if (FileSystemEntity.typeSync(target, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Archive entry traverses an existing symbolic link',
        target,
      );
    }
  }

  // A directory entry named './' legitimately represents the root itself.
  if (parts.isNotEmpty && !p.isWithin(canonicalRoot, target)) {
    throw FileSystemException('Archive entry escapes extraction directory', entryName);
  }
  return target;
}
