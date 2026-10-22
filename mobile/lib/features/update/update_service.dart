import 'dart:convert';
import 'dart:io';

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
  const UpdateInfo({required this.latestVersion, required this.apkUrl, this.notes = const []});

  final String latestVersion;
  final String? apkUrl;

  /// Every release between the installed one and the newest, newest first.
  final List<ReleaseNote> notes;
}

/// Downloads the APK and opens the system installer. Tests use a fake.
abstract class ApkInstaller {
  Future<void> install(String url, {void Function(double progress)? onProgress});
}

class SystemApkInstaller implements ApkInstaller {
  const SystemApkInstaller();

  @override
  Future<void> install(String url, {void Function(double progress)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/getonit-update.apk');
    final res = await http.Client().send(http.Request('GET', Uri.parse(url)));
    if (res.statusCode != 200) throw HttpException('Download failed: ${res.statusCode}');
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    await res.stream.listen((chunk) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }).asFuture<void>();
    await sink.close();
    // Android 8+ asks the user, the first time, to allow installs from this
    // app (REQUEST_INSTALL_PACKAGES), then shows its installer.
    await OpenFile.open(file.path, type: 'application/vnd.android.package-archive');
  }
}

final httpClientProvider = Provider<http.Client>((ref) => http.Client());
final apkInstallerProvider = Provider<ApkInstaller>((ref) => const SystemApkInstaller());

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
      final apk = ((latest['assets'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
          .firstOrNull;
      return UpdateInfo(
        latestVersion: _tagOf(latest),
        apkUrl: apk?['browser_download_url'] as String?,
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
