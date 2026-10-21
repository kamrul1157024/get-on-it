import 'dart:async';
import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;

/// A small file store addressed by slash paths inside the app's folder, for
/// example `goals/cs229.json`. Spec §13.2.
abstract class RemoteStore {
  Future<void> put(String path, String content);

  Future<String?> get(String path);

  /// Paths of the files directly in [folder], for example `goals`.
  Future<List<String>> list(String folder);

  /// Names of the folders directly in [folder], for example the device ids
  /// in `events`.
  Future<List<String>> folders(String folder);

  /// Deletes the app's whole folder.
  Future<void> deleteAll();
}

/// Kept in memory. Used by tests.
class MemoryStore implements RemoteStore {
  final files = <String, String>{};

  @override
  Future<void> put(String path, String content) async => files[path] = content;

  @override
  Future<String?> get(String path) async => files[path];

  @override
  Future<List<String>> list(String folder) async => [
    for (final p in files.keys)
      if (p.startsWith('$folder/') && !p.substring(folder.length + 1).contains('/')) p,
  ]..sort();

  @override
  Future<List<String>> folders(String folder) async => {
    for (final p in files.keys)
      if (p.startsWith('$folder/') && p.substring(folder.length + 1).contains('/'))
        p.substring(folder.length + 1).split('/').first,
  }.toList()..sort();

  @override
  Future<void> deleteAll() async => files.clear();
}

/// The app's folder in the user's Google Drive, through the Drive v3 API.
///
/// With the `drive.file` scope the app sees only files it created, so the
/// folder is found by name among those.
class GoogleDriveStore implements RemoteStore {
  GoogleDriveStore(this.api, {this.rootName = 'Get On It'});

  final drive.DriveApi api;
  final String rootName;

  static const folderMime = 'application/vnd.google-apps.folder';

  final _folders = <String, String>{}; // folder path ('' = root) → id

  String _q(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Future<drive.File?> _find(String name, String parent, {bool folder = false}) async {
    final res = await api.files.list(
      q:
          "name = '${_q(name)}' and '$parent' in parents and trashed = false"
          "${folder ? " and mimeType = '$folderMime'" : ''}",
      spaces: 'drive',
      $fields: 'files(id,name,mimeType)',
    );
    return res.files?.firstOrNull;
  }

  Future<String> _folder(String path, {bool create = true}) async {
    final cached = _folders[path];
    if (cached != null) return cached;
    final String parent;
    final String name;
    if (path.isEmpty) {
      parent = 'root';
      name = rootName;
    } else {
      final i = path.lastIndexOf('/');
      parent = await _folder(i < 0 ? '' : path.substring(0, i), create: create);
      name = i < 0 ? path : path.substring(i + 1);
    }
    final found = await _find(name, parent, folder: true);
    if (found?.id != null) return _folders[path] = found!.id!;
    if (!create) throw StateError('No folder $path');
    final made = await api.files.create(
      drive.File()
        ..name = name
        ..mimeType = folderMime
        ..parents = [parent],
      $fields: 'id',
    );
    return _folders[path] = made.id!;
  }

  (String, String) _split(String path) {
    final i = path.lastIndexOf('/');
    return (i < 0 ? '' : path.substring(0, i), i < 0 ? path : path.substring(i + 1));
  }

  drive.Media _media(String content) {
    final bytes = utf8.encode(content);
    return drive.Media(Stream.value(bytes), bytes.length, contentType: 'application/json');
  }

  @override
  Future<void> put(String path, String content) async {
    final (folder, name) = _split(path);
    final parent = await _folder(folder);
    final existing = await _find(name, parent);
    if (existing?.id != null) {
      await api.files.update(drive.File(), existing!.id!, uploadMedia: _media(content));
    } else {
      await api.files.create(
        drive.File()
          ..name = name
          ..parents = [parent],
        uploadMedia: _media(content),
        $fields: 'id',
      );
    }
  }

  @override
  Future<String?> get(String path) async {
    final (folder, name) = _split(path);
    final String parent;
    try {
      parent = await _folder(folder, create: false);
    } on StateError {
      return null;
    }
    final file = await _find(name, parent);
    if (file?.id == null) return null;
    final media = await api.files.get(file!.id!, downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
    return utf8.decode(await media.stream.expand((b) => b).toList());
  }

  @override
  Future<List<String>> list(String folder) async {
    final String id;
    try {
      id = await _folder(folder, create: false);
    } on StateError {
      return const [];
    }
    final names = <String>[];
    String? page;
    do {
      final res = await api.files.list(
        q: "'$id' in parents and trashed = false and mimeType != '$folderMime'",
        spaces: 'drive',
        pageToken: page,
        $fields: 'nextPageToken,files(name)',
      );
      names.addAll([
        for (final f in res.files ?? const <drive.File>[])
          if (f.name != null) f.name!,
      ]);
      page = res.nextPageToken;
    } while (page != null);
    return [for (final n in names..sort()) '$folder/$n'];
  }

  @override
  Future<List<String>> folders(String folder) async {
    final String id;
    try {
      id = await _folder(folder, create: false);
    } on StateError {
      return const [];
    }
    final res = await api.files.list(
      q: "'$id' in parents and trashed = false and mimeType = '$folderMime'",
      spaces: 'drive',
      $fields: 'files(name)',
    );
    return [
      for (final f in res.files ?? const <drive.File>[])
        if (f.name != null) f.name!,
    ]..sort();
  }

  @override
  Future<void> deleteAll() async {
    final root = await _find(rootName, 'root', folder: true);
    if (root?.id != null) await api.files.delete(root!.id!);
    _folders.clear();
  }
}
