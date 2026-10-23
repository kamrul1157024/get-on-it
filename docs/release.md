# Release

The **Release** workflow (`.github/workflows/release.yml`) builds a signed APK and publishes it as a GitHub release.

## How to make a release

1. Open **Actions → Release → Run workflow** on GitHub.
2. Select which part of the version moves: `patch`, `minor`, or `major`.
3. Start the workflow.

The workflow calculates the version from the newest release (`scripts/next-version.sh`). You do not type a version. The first release is `0.0.1`, `0.1.0`, or `1.0.0`, depending on the part that you select.

The workflow stops in these cases:
- There are no new commits since the last release.
- A tag for the new version already exists.
- A signing secret is missing.

The release contains:

- `getonit.apk` and `getonit.apk.sha256`: the GitHub build. It updates itself from GitHub releases.
- `getonit.aab` and `getonit.aab.sha256`: the Google Play build (`DISTRIBUTION=play`). It has no GitHub updater and no "install apps" permission. Upload it to Play Console ([docs/play-store/checklist.md](play-store/checklist.md)).

The asset names do not contain the version. So this link always gives the newest APK:

```
https://github.com/kamrul1157024/get-on-it/releases/latest/download/getonit.apk
```


## Signing key (one-time setup)

Android installs an update only if the update has the same signing key as the installed app. **If you lose the key, users must uninstall the app to install a new version.** Keep a backup of the keystore file and its passwords in a password manager.

### 1. Create the keystore

```bash
keytool -genkeypair -v \
  -keystore getonit-release.jks \
  -alias getonit \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Get On It"
```

`keytool` asks for a store password and a key password.

### 2. Add the repository secrets

```bash
gh secret set KEYSTORE_BASE64 --repo kamrul1157024/get-on-it < <(base64 -w0 getonit-release.jks)
gh secret set KEY_ALIAS       --repo kamrul1157024/get-on-it --body getonit
gh secret set STORE_PASSWORD  --repo kamrul1157024/get-on-it
gh secret set KEY_PASSWORD    --repo kamrul1157024/get-on-it
```

`gh secret set` without `--body` asks for the value, so the passwords do not go into your shell history.

### 3. Remove the local copy

Move `getonit-release.jks` to a safe place. Do not commit it. `.gitignore` ignores `*.jks`.

## Local builds

| Command | Result |
|---|---|
| `make apk` | A debug APK. It installs beside the release app as `app.getonit.dev`. |
| `make apk-release VERSION=0.1.0` | A release APK. Without `KEYSTORE_PATH`, it uses the debug key. |
| `make aab-release VERSION=0.1.0` | The Google Play app bundle, signed like the APK. |
