import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import 'remote_store.dart';

/// A connected Drive account: who it is and where the backup lives.
class DriveConnection {
  const DriveConnection(this.email, this.store);

  final String email;
  final RemoteStore store;
}

/// Signs in to Google Drive. Tests use a fake.
abstract class DriveAccount {
  /// Connects without any prompt when the user connected before.
  Future<DriveConnection?> restore();

  /// Asks the user to choose an account and allow access to the app's files.
  Future<DriveConnection> connect();

  Future<void> disconnect();
}

/// Set at build time: `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`.
/// Android sign-in needs it. See docs/drive.md.
const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

class DriveNotConfigured implements Exception {
  @override
  String toString() =>
      'Google Drive is not set up in this build. The build needs GOOGLE_SERVER_CLIENT_ID (see docs/drive.md).';
}

class GoogleDriveAccount implements DriveAccount {
  static const scopes = [drive.DriveApi.driveFileScope];
  bool _initialized = false;

  Future<GoogleSignIn> _signIn() async {
    if (googleServerClientId.isEmpty) throw DriveNotConfigured();
    final s = GoogleSignIn.instance;
    if (!_initialized) {
      await s.initialize(serverClientId: googleServerClientId);
      _initialized = true;
    }
    return s;
  }

  Future<DriveConnection?> _authorized(GoogleSignInAccount user, {required bool prompt}) async {
    final auth = prompt
        ? await user.authorizationClient.authorizeScopes(scopes)
        : await user.authorizationClient.authorizationForScopes(scopes);
    if (auth == null) return null;
    final api = drive.DriveApi(auth.authClient(scopes: scopes));
    return DriveConnection(user.email, GoogleDriveStore(api));
  }

  @override
  Future<DriveConnection?> restore() async {
    if (googleServerClientId.isEmpty) return null;
    final user = await (await _signIn()).attemptLightweightAuthentication();
    return user == null ? null : _authorized(user, prompt: false);
  }

  @override
  Future<DriveConnection> connect() async {
    final user = await (await _signIn()).authenticate(scopeHint: scopes);
    final c = await _authorized(user, prompt: true);
    if (c == null) throw StateError('Drive access was not allowed');
    return c;
  }

  @override
  Future<void> disconnect() async => (await _signIn()).disconnect();
}
