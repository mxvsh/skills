# App structure

## Layout

```
MyApp/                    App target (Xcode file-system synchronized group)
  App/                    @main, AppDelegate, StatusMenuController (NSStatusItem + NSMenu)
  <Feature>/              Panels, controllers, views, persisted stores
  Onboarding/             First-run window and steps
  Services/               PermissionCenter, LaunchAtLogin, UpdaterService, ...
  Settings/               SettingsWindowController (toolbar-style NSTabViewController) + SwiftUI panes
  Resources/              Assets.xcassets (AppIcon, AccentColor)
Packages/
  MyAppKit/               Public SDK: protocols, theme, shared components, host services
  MyAppFeatures/          First-party features built on the SDK
Config/
  MyApp.entitlements      Extra entitlements merged with build-setting entitlements
  MyApp-Info.plist        Extra Info.plist keys (Sparkle) merged with the generated plist
scripts/release-notes.sh
.github/workflows/release.yml
Makefile
```

Files added under the app folder are picked up automatically by the synchronized group. Do
**not** add them to `project.pbxproj`.

## AppKit lifecycle

- `@main` is an `NSApplication` entry point with an `AppDelegate`, not a SwiftUI `App`.
- `Info.plist`: `LSUIElement = YES` (agent app, no Dock icon).
- `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
- The status item is an `NSMenu` rebuilt in `menuNeedsUpdate(_:)` so titles and checkmarks
  reflect current state. A small `NSMenuItem` subclass that runs a closure avoids `@objc`
  selectors:

```swift
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, keyEquivalent: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
```

- Settings and onboarding are `NSWindow`s hosting SwiftUI (`NSHostingController`).
  Objects that outlive a window (updater, stores) are owned by `AppDelegate` and passed in.

## Floating panels

- `NSPanel` with `.nonactivatingPanel`, borderless, `level` above normal windows,
  `collectionBehavior` for all Spaces. It must never steal focus.
- Hover: `NSTrackingArea` with `.activeAlways`. Reveal from a hidden state with global and
  local mouse-moved monitors. This needs no Accessibility permission.
- If the SwiftUI content draws a shadow, pad the panel and offset it by the same margin so
  the padding does not change the visible gap. Keep the two constants in sync.

## Liquid Glass

- Glass is chrome: the bar and controls. Content sits on a subtle filled surface.
- Group adjacent glass in a `GlassEffectContainer`. Use `.buttonStyle(.glass)` and
  `.glassProminent`.
- Pull every size and font from the theme (`theme.scaled(_:)`, `theme.contentPadding`), all
  derived from one reference cell size. No hardcoded point sizes in features.

## Local Swift packages

- `swift-tools-version: 6.2`, `platforms: [.macOS("26.0")]`, `.defaultIsolation(MainActor.self)`.
- A new local package needs manual `project.pbxproj` entries: an `XCLocalSwiftPackageReference`,
  an `XCSwiftPackageProductDependency`, a `PBXBuildFile` in the Frameworks phase, and
  `packageProductDependencies` on the target. Run `plutil -lint` afterwards.
- A remote package (Sparkle) is the same shape with `XCRemoteSwiftPackageReference`
  (`repositoryURL`, `requirement = { kind = upToNextMajorVersion; minimumVersion = 2.9.0; }`),
  and the product dependency carries `package = <ref id>`.
- Package tests: `cd Packages/MyAppKit && swift test`.

## Persistence

- Settings in `UserDefaults` with namespaced keys (`dock.autoHide`, `onboarding.completed`).
- Larger state as JSON in Application Support under a folder named by the bundle ID.
- Edit modes are drafts: snapshot on begin, write on commit, restore on cancel.

## Sandbox and permissions

- Sandbox on, hardened runtime on (required for notarization).
- Each permission is a usage-description key (`INFOPLIST_KEY_*UsageDescription`) plus an
  `ENABLE_RESOURCE_ACCESS_*` build setting, in both Debug and Release.
- Talking to other apps over Apple Events needs `NSAppleEventsUsageDescription`, the
  `automation.apple-events` entitlement and a `temporary-exception.apple-events` list. These
  pass notarization.
- A sandboxed app cannot disable the system Dock. Anything that changes the user's real
  system settings must not run during agent testing without the user's say-so.

## Debug vs release identity

Debug builds: bundle ID `com.you.MyApp.Debug`, display name "MyApp Debug"
(`INFOPLIST_KEY_CFBundleDisplayName`). Their window owner name and sandbox container differ
from release. To check the app is on screen from a shell, list windows with
`CGWindowListCopyWindowInfo` and match owner names starting with the app name. Launch with
`open <App>.app` so the app outlives the shell. Screen capture is usually unavailable.

## Makefile

```make
DERIVED := build
XCB := xcodebuild -project MyApp.xcodeproj -scheme MyApp -derivedDataPath $(DERIVED)
debug: ; $(XCB) -configuration Debug build && open "$(DERIVED)/Build/Products/Debug/MyApp.app"
prod:  ; $(XCB) -configuration Release build && open "$(DERIVED)/Build/Products/Release/MyApp.app"
test:  ; cd Packages/MyAppKit && swift test
kill:  ; -pkill -x MyApp
clean: ; rm -rf $(DERIVED)
```

Use a scratch `-derivedDataPath` when building from a shell.

## App icon

An empty `AppIcon.appiconset` ships the default blank icon. Provide all ten macOS sizes
(16, 32, 128, 256, 512 at 1x and 2x) and name them in `Contents.json`.

macOS does not mask icons for you. Draw the rounded body **824x824 centered in a 1024 canvas**
(about 100px transparent margin, corner radius about 185), then downscale that master.

```sh
magick src.png -resize 824x824 -alpha set \
  \( +clone -alpha transparent -fill white -draw "roundrectangle 0,0 823,823 185,185" \) \
  -compose DstIn -composite -compose Over -background none -gravity center -extent 1024x1024 master.png
for spec in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 \
            256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  magick master.png -resize ${spec##*:}x${spec##*:} icon_${spec%%:*}.png
done
```

Reset `-compose Over` before `-extent`. If `DstIn` is still active, the padded canvas comes
out fully transparent. To preview an icon with transparency, flatten it on a grey background
(`-background "#30363d" -flatten`) because many viewers show transparency as white.

For a README logo, the same recipe at 256px, saved as WebP (`-define webp:alpha-quality=100
-quality 90`), is a few KB. Keep it in a top-level `assets/` folder, not `docs/`.
