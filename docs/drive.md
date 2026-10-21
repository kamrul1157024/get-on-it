# Google Drive backup: setup

The app backs up goals, imported templates, progress events, and settings to a folder named **Get On It** in the user's Google Drive (spec §13). The app uses the `drive.file` scope. So it can see only the files that it created.

Google sign-in on Android needs an OAuth client in a Google Cloud project. Without it, **Connect Google Drive** shows "Google Drive is not set up in this build".

## 1. Create the Google Cloud project

1. Open the [Google Cloud console](https://console.cloud.google.com/).
2. Create a project, for example `get-on-it`.
3. Open **APIs & Services → Library**.
4. Enable the **Google Drive API**.

## 2. Configure the OAuth consent screen

1. Open **APIs & Services → OAuth consent screen**.
2. Select **External**.
3. Enter the app name **Get On It** and your support email.
4. Add the scope `https://www.googleapis.com/auth/drive.file`. This scope is not sensitive, so Google does not require a security review.
5. While the app is in **Testing**, add the Google accounts that may sign in as **test users**.

## 3. Create the OAuth clients

Android sign-in needs **two** clients.

**Android client (one for each signing key)**

1. Open **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Select **Android**.
3. Enter the package name:
   - `app.getonit` for release builds.
   - `app.getonit.dev` for debug builds.
4. Enter the SHA-1 fingerprint of the signing key:
   - Release key: `keytool -list -v -keystore getonit-release.jks -alias getonit`
   - Debug key: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`

**Web client**

1. Create one more OAuth client ID of type **Web application**.
2. Copy its client ID. It ends with `.apps.googleusercontent.com`.

## 4. Build with the web client ID

The app reads the web client ID at build time:

```bash
flutter build apk --release --dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>
```

For the release workflow, add the repository secret `GOOGLE_SERVER_CLIENT_ID`. The **Release** workflow passes it to the build.

## 5. Check

1. Open **Settings → Google Drive backup → Connect Google Drive**.
2. Select the Google account. Allow access.
3. Tap **Back up now**.
4. Open Google Drive. The **Get On It** folder contains `goals/`, `events/`, and `settings.json`.

## How the backup works

| Item | Behavior |
|---|---|
| Automatic backup | 60 seconds after a change to a goal, an event, or a template, and when the app goes to the background |
| Folder layout | `goals/<id>.json`, `templates/<id>@<version>.json`, `events/<deviceId>/<yyyy-mm>.jsonl`, `settings.json` |
| Restore | Goals and templates replace local copies with the same id. Events are added once and never removed. |
| Several phones | Each phone writes only its own event files. A restore merges the events of all phones. |
| PDFs | The backup does not contain PDF files. After a restore, select the PDF again. |
| Delete backup | Deletes the **Get On It** folder from Drive. Data on the phone stays. |

## Tests

The tests do not need a Google account:

- `test/drive_test.dart` runs the real `GoogleDriveStore` against a fake Drive v3 server (`test/support/fake_drive_server.dart`). It also tests backup, restore, a repeated restore, and the merge of two phones.
- The **drive** flow in `test/app_flow_test.dart` and `integration_test/app_test.dart` uses a fake account. It covers connect, back up, the automatic backup, restore after a delete, delete backup, and disconnect.

Real sign-in is not tested yet. It needs the OAuth clients above.
