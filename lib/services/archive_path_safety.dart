import 'dart:io';

import 'package:path/path.dart' as p;

/// Checks every output against every source before compression mutates disk.
/// Resolution failures (including dangling/cyclic links) deliberately fail closed.
void validateArchiveDestinations({
  required List<String> sourcePaths,
  required List<String> destinationPaths,
  required bool deleteSource,
}) {
  final resolvedDestinations = <String>[];
  for (final destination in destinationPaths) {
    final resolvedDestination = _canonicalPath(destination);
    if (resolvedDestinations.any(
      (previous) => p.equals(previous, resolvedDestination),
    )) {
      throw FileSystemException(
        'Unsafe archive destination: duplicate archive output',
        destination,
      );
    }
    resolvedDestinations.add(resolvedDestination);
    for (final source in sourcePaths) {
      final resolvedSource = _canonicalPath(source);
      final sourceType = FileSystemEntity.typeSync(source);
      final sameFile =
          sourceType == FileSystemEntityType.file &&
          FileSystemEntity.typeSync(destination) == FileSystemEntityType.file &&
          FileSystemEntity.identicalSync(source, destination);
      if (p.equals(resolvedSource, resolvedDestination) || sameFile) {
        throw FileSystemException(
          'Unsafe archive destination: output must differ from source',
          destination,
        );
      }
      if (deleteSource &&
          sourceType == FileSystemEntityType.directory &&
          p.isWithin(resolvedSource, resolvedDestination)) {
        throw FileSystemException(
          'Unsafe archive destination: output is inside a source marked for deletion',
          destination,
        );
      }
    }
  }
}

String _canonicalPath(String path) {
  final components = p.split(p.absolute(path));
  var resolved = components.first;
  for (final component in components.skip(1)) {
    if (component == '.') continue;
    if (component == '..') {
      resolved = p.dirname(resolved);
      continue;
    }
    resolved = p.join(resolved, component);
    final type = FileSystemEntity.typeSync(resolved, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      // Resolve existing ancestors even when the output does not yet exist.
      // Process '..' only AFTER resolving links; lexical normalization first
      // could hide a destination inside a source directory.
      resolved = File(resolved).resolveSymbolicLinksSync();
    }
  }
  return p.normalize(resolved);
}
