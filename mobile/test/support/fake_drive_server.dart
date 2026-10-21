import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A small stand-in for the Google Drive v3 REST API, enough for
/// GoogleDriveStore: files.list with `q`, files.create (folder metadata and
/// multipart uploads), files.update (multipart and media uploads), files.get
/// with alt=media, and files.delete (recursive, as Drive trashes children).
class FakeDriveServer {
  final files = <String, FakeDriveFile>{};
  final requests = <String>[];
  var _next = 0;

  http.Client get client => MockClient(_handle);

  /// Path of a file from the Drive root, for assertions: `Get On It/goals/x.json`.
  String pathOf(FakeDriveFile f) {
    final parts = <String>[f.name];
    var parent = f.parent;
    while (parent != 'root') {
      final p = files[parent]!;
      parts.insert(0, p.name);
      parent = p.parent;
    }
    return parts.join('/');
  }

  Map<String, String> get contentsByPath => {
    for (final f in files.values)
      if (!f.isFolder) pathOf(f): f.content,
  };

  Future<http.Response> _handle(http.Request r) async {
    requests.add('${r.method} ${r.url.path}');
    final segs = r.url.pathSegments;
    final upload = segs.first == 'upload';
    final id = segs.last == 'files' ? null : segs.last;

    if (r.method == 'GET' && id == null) return _json({'files': _query(r.url.queryParameters['q'] ?? '')});
    if (r.method == 'GET' && r.url.queryParameters['alt'] == 'media') {
      final f = files[id];
      return f == null
          ? _notFound()
          : http.Response.bytes(utf8.encode(f.content), 200, headers: {'content-type': f.mimeType});
    }
    if (r.method == 'POST' && id == null) {
      final (meta, content) = upload ? _multipart(r) : (jsonDecode(r.body) as Map<String, dynamic>, '');
      final f = FakeDriveFile(
        id: 'f${_next++}',
        name: meta['name'] as String,
        parent: ((meta['parents'] as List?)?.first as String?) ?? 'root',
        mimeType: (meta['mimeType'] as String?) ?? 'application/json',
        content: content,
      );
      files[f.id] = f;
      return _json({'id': f.id, 'name': f.name});
    }
    if (r.method == 'PATCH' && id != null) {
      final f = files[id];
      if (f == null) return _notFound();
      f.content = r.url.queryParameters['uploadType'] == 'media' ? r.body : _multipart(r).$2;
      return _json({'id': f.id});
    }
    if (r.method == 'DELETE' && id != null) {
      void remove(String fid) {
        for (final child in files.values.where((c) => c.parent == fid).toList()) {
          remove(child.id);
        }
        files.remove(fid);
      }

      if (!files.containsKey(id)) return _notFound();
      remove(id);
      return http.Response('', 204);
    }
    return http.Response('unsupported ${r.method} ${r.url}', 400);
  }

  /// Supports the query forms GoogleDriveStore sends.
  List<Map<String, String>> _query(String q) {
    final name = RegExp(r"name = '((?:[^'\\]|\\.)*)'").firstMatch(q)?[1]?.replaceAll(r"\'", "'");
    final parent = RegExp(r"'([^']+)' in parents").firstMatch(q)?[1];
    final isFolder = q.contains("mimeType = 'application/vnd.google-apps.folder'");
    final notFolder = q.contains("mimeType != 'application/vnd.google-apps.folder'");
    return [
      for (final f in files.values)
        if ((name == null || f.name == name) &&
            (parent == null || f.parent == parent) &&
            (!isFolder || f.isFolder) &&
            (!notFolder || !f.isFolder))
          {'id': f.id, 'name': f.name, 'mimeType': f.mimeType},
    ];
  }

  (Map<String, dynamic>, String) _multipart(http.Request r) {
    final boundary = RegExp(r'boundary="?([^";]+)"?').firstMatch(r.headers['content-type']!)![1]!;
    final parts = r.body.split('--$boundary').where((p) => p.trim().isNotEmpty && p.trim() != '--').toList();
    String bodyOf(String part) => part.substring(part.indexOf('\r\n\r\n') + 4).trimRight();
    final meta = jsonDecode(bodyOf(parts[0])) as Map<String, dynamic>;
    final media = parts[1];
    final raw = bodyOf(media);
    final content = media.toLowerCase().contains('content-transfer-encoding: base64')
        ? utf8.decode(base64.decode(raw))
        : raw;
    return (meta, content);
  }

  http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

  http.Response _notFound() => http.Response('{"error":{"code":404}}', 404);
}

class FakeDriveFile {
  FakeDriveFile({
    required this.id,
    required this.name,
    required this.parent,
    required this.mimeType,
    this.content = '',
  });

  final String id;
  final String name;
  final String parent;
  final String mimeType;
  String content;

  bool get isFolder => mimeType == 'application/vnd.google-apps.folder';
}
