# Get On It

*Do the thing.*

Get On It is a goal and habit tracker for Android, built with Flutter. Claude creates the plans. The app renders them from JSON and makes sure that you do the work.

- **JSON UI.** Screens, widgets, notifications, and alarms render from JSON templates.
- **Templates.** Course (YouTube playlists), book (PDF pages per day), habit, and custom templates.
- **Widgets.** Each template has its own widgets. A composite widget combines several goals.
- **Reminders that push.** Escalating alarms and distraction nudges.
- **Google Drive.** Optional backup.

## Status

The first build is in `mobile/`. It contains the JSON renderer, the event store, the five progress engines, the course, book and habit templates, the YouTube player, the PDF reader, and import by paste, share, or "Open with".

Home-screen widgets, reminders and alarms, distraction nudges, Google Drive, and the Claude skill come in later PRs. See the delivery plan in the spec.

## Development

Requirements: Flutter (stable), Java 17, and the Android SDK. `flutter test` also needs `clang` on the host, because the PDF library compiles a small native helper.

| Command | Purpose |
|---|---|
| `make test` | Unit, widget, and host flow tests |
| `make e2e DEVICE=emulator-5554` | End-to-end tests on an emulator or a device |
| `make analyze` | Static analysis |
| `make apk` | Debug APK |
| `make gen` | Regenerate the database code after a table change |

Releases: see [docs/release.md](docs/release.md).

## Documents

- [Technical specification](docs/tech-spec.md)
- [Release process](docs/release.md)
- [Sample UI cards](mockups/cards.html). Open the file in a browser. A small JavaScript reference renderer draws each card from its JSON.
