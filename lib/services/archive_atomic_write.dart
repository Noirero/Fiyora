import 'dart:io';

import 'package:path/path.dart' as p;

/// Stage bytes on the same filesystem and replace the archive only after
/// the complete staged file is flushed. No delete-then-rename fallback:
/// a failed rename must leave the original archive unchanged.
///
/// POSIX rename is atomic on one filesystem, but durability and SAF/provider
/// behavior still require platform validation. Concurrent writers are out of
/// scope (AR-007).
void replaceArchiveFileContentsAtomically(
  File archive,
  List<int> encoded, {
  void Function(File staged)? beforeCommit,
}) {
  // Temporary directory is a sibling of the target, ensuring same volume.
  // createTempSync guarantees a unique location for concurrent staging.
  final stageDir = archive.parent.createTempSync('.fiyora-archive-stage-');
  try {
    final stage = File(p.join(stageDir.path, p.basename(archive.path)));
    stage.writeAsBytesSync(encoded, flush: true);
    if (stage.lengthSync() != encoded.length) {
      throw FileSystemException('Incomplete staged archive write', stage.path);
    }
    beforeCommit?.call(stage); // Deterministic fault injection in tests.
    stage.renameSync(archive.path);
  } finally {
    // Cleanup must not turn a successful publish into an error response.
    try {
      if (stageDir.existsSync()) stageDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
