# Sparkle in a sandboxed app

Updates come from GitHub Releases. The appcast is a release asset, so no `gh-pages` branch is
needed.

```
SUFeedURL = https://github.com/OWNER/REPO/releases/latest/download/appcast.xml
enclosure  = https://github.com/OWNER/REPO/releases/download/<tag>/MyApp-<tag>.dmg
```

## 1. Add the package

SPM package `https://github.com/sparkle-project/Sparkle`, up to next major from 2.9.0, product
`Sparkle`, linked into the app target. In `project.pbxproj`: an `XCRemoteSwiftPackageReference`,
an `XCSwiftPackageProductDependency` with `package = <ref>`, a `PBXBuildFile` in Frameworks,
`packageProductDependencies` on the target, and the reference in the project's
`packageReferences`. `plutil -lint` afterwards, then a build resolves the package.

## 2. Info.plist keys, as a file

`INFOPLIST_KEY_SUFeedURL` and friends are **silently dropped**: Xcode only forwards known
keys. Put them in a plist and merge it with the generated one:

- Create `Config/MyApp-Info.plist` from `templates/App-Info.plist`.
- Set `INFOPLIST_FILE = Config/MyApp-Info.plist;` in both Debug and Release, alongside
  `GENERATE_INFOPLIST_FILE = YES`.
- Verify: `plutil -p <built>.app/Contents/Info.plist | grep '"SU'`.

| Key | Value |
|---|---|
| `SUFeedURL` | the `releases/latest/download/appcast.xml` URL |
| `SUPublicEDKey` | public key printed by `generate_keys` |
| `SUEnableAutomaticChecks` | `true` |
| `SUEnableInstallerLauncherService` | `true` (required in a sandbox) |

## 3. Entitlements (sandbox)

Add to `Config/MyApp.entitlements`:

```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

`$(PRODUCT_BUNDLE_IDENTIFIER)` resolves per configuration, so Debug and release each get their
own names. Check with `codesign -d --entitlements - <built>.app`. The sandboxed install path is
the riskiest part and is only proven by a real update from one released build to the next.

## 4. Code

`templates/UpdaterService.swift` wraps `SPUStandardUpdaterController`. Debug builds do not start
the updater, so they never offer to replace a dev build with a release.

Own it in `AppDelegate` and pass a `checkForUpdates` closure to the UI:

- Menu bar menu: "Check for Updates…" above Settings…
- Settings, About pane: a "Check for Updates…" button under the version line.

Show the version from the bundle: `CFBundleShortVersionString` and `CFBundleVersion`.

## 5. Keys

Use a separate account per app so a new key never overwrites another app's:

```fish
set GK build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
$GK --account myapp                              # creates the key in the login keychain, prints the public key
$GK --account myapp -x ~/Documents/myapp.key     # export the private key
gh secret set SPARKLE_PRIVATE_KEY -R OWNER/REPO < ~/Documents/myapp.key
rm ~/Documents/myapp.key
```

Put the printed public key in `SUPublicEDKey`. The Sparkle tools sit in the resolved package
artifacts, so build once first.

**Losing the private key means existing installs can never verify another update.** Back it up
somewhere safe.

## 6. Appcast in CI

After the DMG is notarized and stapled, sign it into an appcast. Pass the key on stdin:

```sh
BIN=$(find build/SourcePackages/artifacts -name generate_appcast -type f | head -1)
mkdir appcast && cp "MyApp-${TAG}.dmg" appcast/
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN" --ed-key-file - \
  --download-url-prefix "https://github.com/${{ github.repository }}/releases/download/${TAG}/" \
  appcast
```

Attach `appcast/appcast.xml` to the GitHub release next to the DMG (see `templates/release.yml`).
Only the newest item is needed for Sparkle to work.

## Version numbers

Sparkle decides "newer" from `CFBundleVersion` (`sparkle:version`). Pass an increasing
`CURRENT_PROJECT_VERSION` on the archive command, for example `${{ github.run_number }}`.
`MARKETING_VERSION` is what people read (`${TAG#v}`). A suffix such as `0.1.0-beta.1` builds and
notarizes fine outside the App Store.

## Pre-releases

`releases/latest` ignores pre-releases, so until a stable release exists the feed 404s and
"Check for Updates…" cannot find an update. Fine for a first beta, but you cannot test updates
with beta tags alone. Test with two stable tags (`v0.1.0`, then `v0.1.1`), or point the feed at a
fixed release that always holds the newest appcast.

## Verifying

1. Release `vA`, install its DMG.
2. Release `vB`. In `vA`, run "Check for Updates…". It should offer `vB`, download, and relaunch.
3. If the install step fails inside the sandbox, recheck the three extras: installer-launcher
   key, `network.client`, and the `-spks` / `-spki` mach-lookup names.
