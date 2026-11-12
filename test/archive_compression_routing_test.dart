import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/providers/file_manager_provider.dart';

void main() {
  test('normal context archive creation retains background workflow', () {
    expect(
      FileManagerProvider.shouldUseBackgroundArchiveCreation(
        hasContext: true,
        separateArchives: false,
      ),
      isTrue,
    );
  });

  test('requested split volume must use implementation supporting split', () {
    expect(
      FileManagerProvider.shouldUseBackgroundArchiveCreation(
        hasContext: true,
        separateArchives: false,
        splitSizeMB: 1,
      ),
      isFalse,
    );
  });

  test('requested separate archives must not be silently dropped', () {
    expect(
      FileManagerProvider.shouldUseBackgroundArchiveCreation(
        hasContext: true,
        separateArchives: true,
      ),
      isFalse,
    );
  });

  test('split and separate options combined use direct implementation', () {
    expect(
      FileManagerProvider.shouldUseBackgroundArchiveCreation(
        hasContext: true,
        separateArchives: true,
        splitSizeMB: 1,
      ),
      isFalse,
    );
  });

  test('headless archive creation always uses direct implementation', () {
    for (final separate in [true, false]) {
      for (final split in <int?>[null, 1]) {
        expect(
          FileManagerProvider.shouldUseBackgroundArchiveCreation(
            hasContext: false,
            separateArchives: separate,
            splitSizeMB: split,
          ),
          isFalse,
        );
      }
    }
  });

  test('nonpositive split sizes do not change normal routing', () {
    for (final split in [0, -1]) {
      expect(
        FileManagerProvider.shouldUseBackgroundArchiveCreation(
          hasContext: true,
          separateArchives: false,
          splitSizeMB: split,
        ),
        isTrue,
      );
    }
  });
}
