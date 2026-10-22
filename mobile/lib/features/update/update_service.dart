import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../settings/settings_screen.dart' show appVersion;

// The same mechanism as the Helios app: read the releases list, show the notes
// of every release since the installed one, download the APK, and hand it to
// the Android installer.
const _repo = 'kamrul1157024/get-on-it';
// The list rather than /releases/latest: somebody three releases behind is
// owed the notes for each one they skipped.
const releasesApiUrl = 'https://api.github.com/repos/$_repo/releases?per_page=30';
const releasesPageUrl = 'https://github.com/$_repo/releases/latest';
const _dismissedKey = 'update.dismissedVersion';

class ReleaseNote {
  const ReleaseNote({required this.version, required this.body, this.publishedAt});

  final String version;

  /// The release body in GitHub markdown. Empty when the release has none.
  final String body;
  final DateTime? publishedAt;
}

class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.apkUrl,
    this.apkSize,
    this.sha256Url,
    this.notes = const [],
  });

  final String latestVersion;
  final String? apkUrl;

  /// The APK's size in bytes, as GitHub reports it.
  final int? apkSize;

  /// The release's getonit.apk.sha256, when it has one.
  final String? sha256Url;

  /// Every release between the installed one and the newest, newest first.
  final List<ReleaseNote> notes;
}

/// Downloads the APK and opens the system installer. Tests use a fake.
abstract class ApkInstaller {
  Future<void> install(UpdateInfo info, {void Function(double progress)? onProgress});
}

class SystemApkInstaller implements ApkInstaller {
  const SystemApkInstaller(this.downloads);

  final UpdateDownloads downloads;

  @override
  Future<void> install(UpdateInfo info, {void Function(double progress)? onProgress}) async {
    final apk = await downloads.fetch(info, onProgress: onProgress);
    // Android 8+ asks the user, the first time, to allow installs from this
    // app (REQUEST_INSTALL_PACKAGES), then shows its installer.
    await OpenFile.open(apk.path, type: 'application/vnd.android.package-archive');
  }
}

/// The downloaded APKs, one per version: `getonit-<version>.apk`.
///
/// An APK is 90 MB. A complete one is reused, so tapping Install twice, or
/// again after cancelling the installer, does not download it again. Once
/// the new version runs, [cleanUp] deletes it.
class UpdateDownloads {
  UpdateDownloads(this._client, this._dir);

  final http.Client _client;
  final Future<Directory> Function() _dir;

  static final _apkName = RegExp(r'^getonit-(.+)\.apk$');

  Future<Directory> _folder() async {
    final d = await _dir();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> fileFor(String version) async => File('${(await _folder()).path}/getonit-$version.apk');

  /// The APK for [info], from disk when a complete copy is there.
  Future<File> fetch(UpdateInfo info, {void Function(double progress)? onProgress}) async {
    final url = info.apkUrl;
    if (url == null) throw StateError('This release has no APK');
    final file = await fileFor(info.latestVersion);
    if (await file.exists()) {
      if (await isComplete(file, info)) {
        onProgress?.call(1);
        return file;
      }
      await file.delete();
    }
    // Written to .part and renamed at the end: a cut download never looks
    // like a complete APK.
    final part = File('${file.path}.part');
    final res = await _client.send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode != 200) throw HttpException('Download failed: ${res.statusCode}');
    final total = res.contentLength ?? info.apkSize ?? 0;
    var received = 0;
    final sink = part.openWrite();
    try {
      await res.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }).asFuture<void>();
    } finally {
      await sink.close();
    }
    await part.rename(file.path);
    if (!await isComplete(file, info)) {
      await file.delete();
      throw const HttpException('The download is damaged. Try again.');
    }
    return file;
  }

  /// The size GitHub reports, and the SHA-256 the release publishes.
  Future<bool> isComplete(File file, UpdateInfo info) async {
    final size = info.apkSize;
    if (size != null && await file.length() != size) return false;
    final shaUrl = info.sha256Url;
    if (shaUrl == null) return true;
    final res = await _client.get(Uri.parse(shaUrl)).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return false;
    final want = res.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
    final got = (await sha256.bind(file.openRead()).first).toString();
    return got == want;
  }

  /// Deletes cut downloads, APKs that are not newer than the installed
  /// version (the update is done), and APKs older than [keep], the newest
  /// version on offer.
  Future<void> cleanUp(String installed, {String? keep}) async {
    final d = await _dir();
    if (!await d.exists()) return;
    await for (final e in d.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.endsWith('.part')) {
        await e.delete();
        continue;
      }
      final v = _apkName.firstMatch(name)?.group(1);
      if (v == null) continue;
      if (!isNewer(v, installed) || (keep != null && isNewer(keep, v))) await e.delete();
    }
  }
}

final httpClientProvider = Provider<http.Client>((ref) => http.Client());
final updateDownloadsProvider = Provider<UpdateDownloads>(
  (ref) => UpdateDownloads(
    ref.read(httpClientProvider),
    () async => Directory('${(await getTemporaryDirectory()).path}/updates'),
  ),
);
final apkInstallerProvider = Provider<ApkInstaller>((ref) => SystemApkInstaller(ref.read(updateDownloadsProvider)));

/// The installed version. Debug builds report "dev" and do not check on start.
final installedVersionProvider = Provider<String>((ref) => appVersion);

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(
    ref.read(httpClientProvider),
    ref.read(installedVersionProvider),
    ref.read(repositoryProvider).settings,
    ref.read(repositoryProvider).setSetting,
  ),
);

class UpdateService {
  UpdateService(this._client, this.currentVersion, this._settings, this._setSetting);

  final http.Client _client;
  final String currentVersion;
  final Future<Map<String, String>> Function() _settings;
  final Future<void> Function(String key, String value) _setSetting;

  bool get isReleaseBuild => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(currentVersion);

  /// Whether this version was waved away. Kept per version: the next release
  /// is mentioned once, this one never again.
  Future<bool> isDismissed(String version) async => (await _settings())[_dismissedKey] == version;

  Future<void> dismiss(String version) => _setSetting(_dismissedKey, version);

  /// The update, or null when there is none or the check failed.
  Future<UpdateInfo?> check() async {
    try {
      final res = await _client
          .get(Uri.parse(releasesApiUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        debugPrint('[update] GitHub said ${res.statusCode}');
        return null;
      }
      // A draft is not published and a prerelease is not for everyone.
      final published = (jsonDecode(res.body) as List)
          .cast<Map<String, dynamic>>()
          .where((r) => r['draft'] != true && r['prerelease'] != true)
          .where((r) => ((r['tag_name'] as String?) ?? '').isNotEmpty)
          .toList();
      final newer = releasesSince(published, currentVersion);
      if (newer.isEmpty) return null;
      final latest = newer.first;
      final assets = ((latest['assets'] as List?) ?? const []).cast<Map<String, dynamic>>();
      final apk = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk')).firstOrNull;
      final sha = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk.sha256')).firstOrNull;
      return UpdateInfo(
        latestVersion: _tagOf(latest),
        apkUrl: apk?['browser_download_url'] as String?,
        apkSize: apk?['size'] as int?,
        sha256Url: sha?['browser_download_url'] as String?,
        notes: [
          for (final r in newer)
            ReleaseNote(
              version: _tagOf(r),
              body: ((r['body'] as String?) ?? '').trim(),
              publishedAt: DateTime.tryParse((r['published_at'] as String?) ?? ''),
            ),
        ],
      );
    } catch (e) {
      // A check that never succeeds looks like being up to date; say so.
      debugPrint('[update] check failed: $e');
      return null;
    }
  }
}

/// Every release newer than [current], newest first. Sorted here, not taken
/// from the API: a moved tag can put an older release first.
@visibleForTesting
List<Map<String, dynamic>> releasesSince(List<Map<String, dynamic>> releases, String current) {
  final newer = releases.where((r) => isNewer(_tagOf(r), current)).toList();
  newer.sort((a, b) => isNewer(_tagOf(a), _tagOf(b)) ? -1 : (isNewer(_tagOf(b), _tagOf(a)) ? 1 : 0));
  return newer;
}

/// Compares dotted versions. Tolerates "0.2.0-dev" and "dev": the leading
/// digits of each part count, anything else is zero.
@visibleForTesting
bool isNewer(String latest, String current) {
  final l = _parts(latest);
  final c = _parts(current);
  for (var i = 0; i < l.length || i < c.length; i++) {
    final a = i < l.length ? l[i] : 0;
    final b = i < c.length ? c[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}

String _tagOf(Map<String, dynamic> r) => ((r['tag_name'] as String?) ?? '').replaceFirst('v', '');

List<int> _parts(String v) =>
    v.split('.').map((p) => int.tryParse(RegExp(r'^\d+').firstMatch(p)?.group(0) ?? '') ?? 0).toList();
