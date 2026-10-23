# Publish Get On It on Google Play: checklist

Do these steps in order. The texts and files are in this folder:

- [listing.md](listing.md): store texts, declarations, Data safety and content rating answers.
- `icon-512.png`, `feature-graphic.png`, and `screenshots/`.
- Privacy policy: https://kamrul1157024.github.io/get-on-it/privacy

## 1. Developer account

1. Open https://play.google.com/console and create a developer account. The fee is 25 USD, one time.
2. Complete Google's identity check. It can take a few days.
3. New personal accounts must run a closed test before production: **at least 12 testers, opted in, for 14 days in a row**. Start this early (step 5). It decides the earliest date you can publish.

## 2. Create the app

1. Click **Create app**.
2. App name: **Get On It**. Default language: English (United States).
3. Type: **App**. Free.
4. Accept the declarations.

## 3. Choose how Google signs the app (Play App Signing)

Play App Signing is required. Google keeps the key that signs the app for users. You upload with an "upload key".

You have two choices. Decide before the first upload; you cannot change it later.

| Choice | What happens |
|---|---|
| **A. Use your existing key** (recommended) | In "App signing", choose to upload your own app signing key, and export it with Google's PEPK tool from `~/.getonit-release/getonit-release.jks`. Play installs then have the same signature as the GitHub APK, so users can move between the two without uninstalling. |
| **B. Let Google create the key** | Simpler. Your release key becomes only the upload key. Play installs and GitHub APK installs then have different signatures: a phone with one must uninstall it (and lose its data) to install the other. |

Either way, keep `~/.getonit-release/` backed up. It holds the upload key.

## 4. Get the app bundle

The release workflow attaches `getonit.aab` (the Google Play build) to every GitHub release, next to `getonit.apk`.

- The Play build has no GitHub updater and no "install apps" permission. Updates come from Google Play.
- Download it from the newest release on https://github.com/kamrul1157024/get-on-it/releases.
- Or build it yourself: `make aab-release VERSION=x.y.z` with `KEYSTORE_PATH`, `KEY_ALIAS`, `KEY_PASSWORD`, and `STORE_PASSWORD` set.

Each upload needs a higher version code. Every new release from the workflow has one.

## 5. Closed test (12 testers, 14 days)

1. Go to **Test and release → Testing → Closed testing**. Create a track.
2. Add testers: an email list or a Google Group with at least 12 people.
3. Upload `getonit.aab` to the track. Add release notes.
4. Send the opt-in link to the testers. Each must accept it and install the app from Play.
5. Wait 14 days. Keep at least 12 testers opted in the whole time.
6. Then apply for production access in the Dashboard. Google asks short questions about the test.

## 6. Store listing

**Grow users → Store presence → Main store listing.** Copy from [listing.md](listing.md):

1. Short and full description.
2. App icon `icon-512.png` and feature graphic `feature-graphic.png`.
3. Phone screenshots from `screenshots/` (at least 2, at most 8).
4. Category **Productivity**, contact email, website, privacy policy URL.

## 7. App content forms

**Policy and programs → App content.** Answers are in [listing.md](listing.md).

1. Privacy policy: the URL above.
2. Ads: no ads.
3. App access: all features work without an account. No login details needed.
4. Content rating: fill in the IARC questionnaire.
5. Target audience: 13 and older.
6. Data safety: no data collected or shared.
7. Government app: no. Financial features: none. Health: no. News: no.
8. Foreground service: "Special use", with the text and a demo video.
9. Full-screen intent: core use "Alarms", with the text.

## 8. Production release

1. After Google approves production access, go to **Production → Create new release**.
2. Upload the newest `getonit.aab` (or promote the closed test release).
3. Choose the countries.
4. Send the release for review. The first review can take several days.

## After launch

- For each new version: run the release workflow, then upload the new `getonit.aab` to Play.
- Users of the Play version get updates from Play. The app asks them with Google's in-app update screen.
- Users of the GitHub APK keep getting updates from GitHub.
