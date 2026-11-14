import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfile/models/file_item_model.dart';
import 'package:nfile/models/folder_tab_model.dart';
import 'package:nfile/providers/file_manager_provider.dart';
import 'package:nfile/providers/media_provider.dart';

class _Provider extends FileManagerProvider {
  @override
  Future<void> loadDirectory(
    String path, {
    bool showLoading = true,
    bool clearCache = false,
  }) async {}
}

class _DelayedDocument extends Fake implements FileSystemEntity {
  _DelayedDocument(this.path);

  @override
  final String path;
  final pending = Completer<FileStat>();

  @override
  Future<FileStat> stat() => pending.future;
}

class _Media extends Fake implements MediaProvider {
  _Media(this.documents);

  @override
  final List<FileSystemEntity> documents;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Provider provider;
  const folder = '/origin/folder';

  setUp(() {
    provider = _Provider();
    provider.tabs
      ..clear()
      ..add(FolderTab(
        id: 'origin',
        currentPath: '/origin',
        currentFiles: [
          FileItemModel.fromCustom(
            path: folder,
            isDirectory: true,
            size: 0,
            modified: DateTime(2026),
          ),
        ],
      ));
  });

  tearDown(() => provider.dispose());

  test('a result from the previous query cannot enter the new query', () async {
    final doc = _DelayedDocument('/origin/old.txt');
    final media = _Media([doc]);
    provider.executeSearchForTab(0, 'old', 'Docs', media);
    provider.executeSearchForTab(0, 'new', 'Docs', media);
    doc.pending.complete(FileStat.statSync('/'));
    await Future<void>.delayed(Duration.zero);
    expect(provider.tabs.single.searchQuery, 'new');
    expect(provider.tabs.single.searchResults, isEmpty);
  });

  test('turning search off invalidates a pending document result', () async {
    final doc = _DelayedDocument('/origin/old.txt');
    final tab = provider.tabs.single;
    provider.executeSearchForTab(0, 'old', 'Docs', _Media([doc]));
    provider.deactivateSearchForTab(tab);
    doc.pending.complete(FileStat.statSync('/'));
    await Future<void>.delayed(Duration.zero);
    expect(tab.searchQuery, isEmpty);
    expect(tab.searchResults, isEmpty);
  });

  test('opening selected folder preserves the origin and opens exactly one tab', () {
    if (!provider.enableMultipleTabs) provider.toggleMultipleTabs();
    provider.toggleSelection(folder);
    expect(provider.canOpenSelectedFolderInNewTab, isTrue);
    provider.openSelectedFolderInNewTab();
    expect(provider.tabs.map((tab) => tab.currentPath), ['/origin', folder]);
    expect(provider.activeTabIndex, 1);
    expect(provider.tabs.first.selectedPaths, isEmpty);
  });

  test('split screen does not open an extra tab', () {
    if (!provider.enableMultipleTabs) provider.toggleMultipleTabs();
    provider.toggleSelection(folder);
    if (!provider.enableSplitScreen) provider.toggleSplitScreen();
    final before = provider.tabs.length;
    expect(provider.canOpenSelectedFolderInNewTab, isFalse);
    provider.openSelectedFolderInNewTab();
    expect(provider.tabs, hasLength(before));
  });
}
