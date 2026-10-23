import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';

/// Where this build is installed from. Set at build time:
/// `--dart-define=DISTRIBUTION=play` for Google Play. Play does not allow an
/// app to update itself (and the Play build has no REQUEST_INSTALL_PACKAGES),
/// so there updates come from Play; the GitHub build keeps its own updater.
const buildDistribution = String.fromEnvironment('DISTRIBUTION', defaultValue: 'github');

final distributionProvider = Provider<String>((ref) => buildDistribution);

bool isPlayBuild(String distribution) => distribution == 'play';

/// Google Play's in-app updates. Tests use a fake.
abstract class PlayUpdates {
  /// Whether Play has a newer version of this app.
  Future<bool> available();

  /// Downloads the update in the background, then asks Play to install it.
  Future<void> startFlexible();
}

class GooglePlayUpdates implements PlayUpdates {
  const GooglePlayUpdates();

  @override
  Future<bool> available() async {
    try {
      final info = await InAppUpdate.checkForUpdate();
      return info.updateAvailability == UpdateAvailability.updateAvailable && info.flexibleUpdateAllowed;
    } catch (e) {
      // Not installed from Play (for example a test build): no update.
      debugPrint('[update] Play check failed: $e');
      return false;
    }
  }

  @override
  Future<void> startFlexible() async {
    final result = await InAppUpdate.startFlexibleUpdate();
    if (result == AppUpdateResult.success) await InAppUpdate.completeFlexibleUpdate();
  }
}

final playUpdatesProvider = Provider<PlayUpdates>((ref) => const GooglePlayUpdates());
