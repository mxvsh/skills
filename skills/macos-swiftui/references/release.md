# Release pipeline

Push a `v*.*.*` tag on `main`. The workflow (`templates/release.yml`) runs three jobs:

1. **verify** (ubuntu): fails unless the tagged commit is an ancestor of `origin/main`. GitHub
   cannot restrict a tag trigger to a branch, so this guard does it.
2. **build** (macOS): import cert, archive, export, DMG, sign, notarize, staple, appcast.
3. **release** (ubuntu): generate notes, `gh release create` with the DMG and `appcast.xml`.

Tags containing `-` (`v0.1.0-beta.1`) are published as pre-releases. Push `main` **before** the
tag so the guard and the tagged commit agree.

## Secrets

| Secret | What it is |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application cert + private key as `.p12`, base64 |
| `P12_PASSWORD` | the password you choose when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string, protects the runner's temporary keychain |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_ID` | Apple ID email of the developer account |
| `APPLE_APP_SPECIFIC_PASSWORD` | from account.apple.com, Sign-In and Security |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key from `generate_keys -x` |

### Getting the certificate

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

It must be **Developer ID Application**, not Apple Development or Distribution. If it is missing:
Xcode, Settings, Accounts, Manage Certificates, +, Developer ID Application (needs the Account
Holder or an Admin role).

Export from Keychain Access: login, My Certificates, expand the cert so the private key shows
underneath, right-click the certificate, Export, `.p12`. Choose a password, that is
`P12_PASSWORD`. If Export is greyed out, the private key is on another Mac.

### Setting the secrets (fish)

Fish has no `<( )`, so pipe instead:

```fish
base64 -i ~/Documents/Certificates.p12 | gh secret set BUILD_CERTIFICATE_BASE64 -R OWNER/REPO
gh secret set P12_PASSWORD -R OWNER/REPO
gh secret set APPLE_TEAM_ID --body TEAMID -R OWNER/REPO
openssl rand -hex 16 | gh secret set KEYCHAIN_PASSWORD -R OWNER/REPO
gh secret set APPLE_ID -R OWNER/REPO
gh secret set APPLE_APP_SPECIFIC_PASSWORD -R OWNER/REPO
rm ~/Documents/Certificates.p12
```

Commands with no `--body` or pipe prompt for the value. Confirm with `gh secret list -R OWNER/REPO`.
With several `gh` accounts, check `gh auth status` and `gh auth switch -u <user>` first, and use
`-R` for org repos. The account needs admin on the repo to set secrets.

## Signing and notarization

- Archive and export with `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY="Developer ID Application"`,
  `DEVELOPMENT_TEAM`, and an `ExportOptions.plist` with `method = developer-id`.
- Build the DMG with `create-dmg` (`--app-drop-link` gives the drag-to-Applications shortcut),
  sign the DMG itself, then `xcrun notarytool submit --wait` and `xcrun stapler staple`.
- Notarize the **DMG**. Stapling it covers the app inside. Verify with
  `spctl -a -t open --context context:primary-signature -vv`.
- Hardened runtime must be on. Sandbox entitlements such as `temporary-exception.apple-events`
  pass notarization.

## Versioning

- `MARKETING_VERSION="${TAG#v}"`: what users read.
- `CURRENT_PROJECT_VERSION="${{ github.run_number }}"`: what Sparkle compares.
- Keep the project's own `MARKETING_VERSION` at the current released version, not `1.0`, so a
  dev build's About pane is honest.

## Release notes

`templates/release-notes.sh <tag> [previous-tag]` groups commits since the previous tag by
conventional prefix into a formatted body: Breaking changes, Features, Fixes, Performance,
Refactoring, Build, Documentation, then a compare link. It drops prefixes and hashes and
capitalises each line. `chore`, `test` and other prefixes are left out. It needs
`fetch-depth: 0` in checkout, and `GITHUB_REPOSITORY` or an `origin` remote for the link.

Because the notes are the commit subjects, write commits as short user-readable sentences:
`fix: settings panes switch instantly without fade`.

Tag, release and CI details: no changesets, no release-it. Changesets is for versioning npm
packages and needs a hand-written file per change. Conventional commits plus this script give
formatted notes with no extra ceremony.

## Failures already hit

| Symptom | Cause and fix |
|---|---|
| Run fails in 0s on a push to `main` | The workflow file is invalid. GitHub reports it on every push. Run `actionlint`. |
| Invalid workflow: `runner` context | `${{ runner.temp }}` is not allowed in job-level `env`. Export from a step via `$GITHUB_ENV`, or use `$RUNNER_TEMP` in `run:`. |
| `in a future Xcode project file format (110)` | Project saved by a newer Xcode than the runner's. Downgrade in CI (`sed 's/objectVersion = 110;/objectVersion = 77;/'`) or use a runner with the newer Xcode. |
| Build fails for the runner's SDK | `MACOSX_DEPLOYMENT_TARGET` is higher than the SDK, often set to the newest by a beta Xcode. Match the documented minimum (macOS 26). |
| `SU*` keys missing from Info.plist | Custom `INFOPLIST_KEY_*` names are dropped. Use `INFOPLIST_FILE`. |
| Tag run never starts | The tag points at a commit whose workflow was invalid. Fix, push `main`, delete and recreate the tag. |
| Release shows as Draft | The tagged release was created as a draft. Check the release step and the Releases page before announcing. |
| Update feed 404 | Only pre-releases exist. `releases/latest` skips them. |
| Second release, old icon or code | A tag is a snapshot. Anything not pushed before tagging is not in the build. Cut a new version. |
| `actionlint` SC2046 on `security list-keychains` | Intentional word-splitting from Apple's keychain recipe, safe to ignore. |

Recreating a tag: `git tag -d T; git push origin :refs/tags/T; git tag T; git push origin T`,
plus deleting the release for it. Only do this if nobody has downloaded it.

## Before the first tag

1. All seven secrets set (`gh secret list`).
2. App icon present, About link and version correct.
3. `main` pushed, workflow passes `actionlint`.
4. Tag a pre-release first (`v0.1.0-beta.1`) to prove signing, notarization and the appcast.
   Then a stable tag, then a second stable tag to prove updating.
