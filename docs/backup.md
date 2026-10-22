# Backup

## Android backup (default)

Get On It uses Android's own backup. Android copies the app's database to the user's Google account. You do not need a Google Cloud project or a sign-in in the app.

- **What is backed up:** the database `app_flutter/getonit.sqlite` (with its `-wal` and `-shm` files). It holds goals, templates, progress events, and settings.
- **What is not backed up:** caches, downloaded update files, the widget data, the scheduled reminders, and the nudge service's copy of the settings. The app makes these again when it starts.
- **When:** about once a day, while the phone charges on Wi-Fi, if backup is on in the phone's settings (**Settings → System → Backup** on most phones).
- **Restore:** when the user sets up a new phone or reinstalls the app with the same Google account. After a restore, the app plans the reminders and updates the widgets when it starts.
- **Permissions are not restored.** The user allows notifications, alarms, and usage access again. The first-start popup asks for them.
- **Rules:** `mobile/android/app/src/main/res/xml/data_extraction_rules.xml` (Android 12 and higher) and `backup_rules.xml` (Android 11 and lower).

In the app, **Settings → Backup** explains this and opens the phone's backup settings.

### Test it on an emulator

```bash
adb shell bmgr enable true
adb shell bmgr transport com.android.localtransport/.LocalTransport
adb shell bmgr backupnow app.getonit.dev
adb shell pm clear app.getonit.dev
adb shell bmgr restore app.getonit.dev
```

## Google Drive sign-in (optional)

The app also has a Google Drive backup with sign-in. It needs a Google Cloud project and OAuth clients: see [drive.md](drive.md). Settings shows it only in a build that has `GOOGLE_SERVER_CLIENT_ID`. Without it, Settings shows the Android backup above.
