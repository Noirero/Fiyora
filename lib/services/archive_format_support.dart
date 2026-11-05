/// Format capability policy for the current FIYORA archive decoders.
///
/// Recognizing an extension as an archive is not the same as being able to
/// preview or extract it. In particular, the background extractor cannot
/// recombine split ZIP volumes, but the direct extractor can.
class ArchiveFormatSupport {
  static bool isSplitZipFirstVolume(String path) =>
      path.toLowerCase().endsWith('.zip.001');

  static String? unavailableExtractionReason(
    String path, {
    bool background = false,
  }) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.rar')) {
      return 'RAR extraction is not supported by FIYORA.';
    }
    if (lower.endsWith('.7z')) {
      return '7z extraction is not supported by FIYORA.';
    }
    if (lower.endsWith('.001')) {
      if (!isSplitZipFirstVolume(path)) {
        return 'Only split ZIP first volumes (.zip.001) can be extracted. '
            'RAR, 7z, TAR, and other split-volume formats are unsupported.';
      }
      if (background) {
        return 'Split ZIP extraction requires direct volume reassembly, '
            'which is not supported by background extraction.';
      }
    }
    return null;
  }

  static String? unavailablePreviewReason(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.rar')) {
      return 'RAR preview is not supported by FIYORA.';
    }
    if (lower.endsWith('.7z')) {
      return '7z preview is not supported by FIYORA.';
    }
    if (lower.endsWith('.001')) {
      if (isSplitZipFirstVolume(path)) {
        return 'Split ZIP volumes cannot be previewed. '
            'Use Extract on the .zip.001 first volume instead.';
      }
      return 'Preview of this split archive format is not supported.';
    }
    return null;
  }

  static void requireExtractable(String path, {bool background = false}) {
    final reason = unavailableExtractionReason(path, background: background);
    if (reason != null) throw UnsupportedError(reason);
  }
}
