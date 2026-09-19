---
name: macos-swiftui
description: Build and ship native macOS apps in SwiftUI + AppKit - menu bar (LSUIElement) agent apps, floating non-activating panels, local Swift packages, Liquid Glass chrome, sandboxing - and release them outside the App Store with a GitHub Actions pipeline (Developer ID signing, notarized DMG, generated release notes) and Sparkle in-app updates that work inside the sandbox. Use when scaffolding or extending a macOS 26+ SwiftUI app, wiring Sparkle, setting up signing and notarization in CI, writing release notes from conventional commits, or debugging a failed macOS release run.
---

# macOS SwiftUI app, shipped outside the App Store

A native macOS 26+ app: SwiftUI views inside AppKit-managed windows, sandboxed, signed with a
Developer ID certificate, distributed as a notarized DMG on GitHub Releases, updating itself
through Sparkle. Only macOS. Do not add iOS or cross-platform code.

```
git tag vX.Y.Z ─▶ GitHub Actions (macos runner)
                    archive + export (Developer ID) ─▶ DMG ─▶ sign ─▶ notarize ─▶ staple
                    generate_appcast (EdDSA) ─▶ appcast.xml
                  ─▶ GitHub Release: formatted notes + DMG + appcast.xml
Installed app ─▶ Sparkle ─▶ releases/latest/download/appcast.xml ─▶ DMG from the release
```

## Stack

| Layer | Choice |
|---|---|
| UI | SwiftUI, Liquid Glass (`.glassEffect`) for chrome only |
| App shell | AppKit lifecycle (`NSApplicationDelegate`), `NSStatusItem` + `NSMenu`, `NSPanel`, `NSWindow` hosting SwiftUI |
| Structure | App target + local Swift packages (SDK, features) |
| Isolation | Swift 6.2 packages with `.defaultIsolation(MainActor.self)`, app target MainActor by default |
| Updates | Sparkle 2 via SPM, EdDSA-signed appcast |
| Release | GitHub Actions on `macos-26`, `create-dmg`, `notarytool`, tag-triggered |
| Notes | `scripts/release-notes.sh` groups conventional commits into a formatted body |
| Local tasks | `Makefile`: `debug`, `prod`, `test`, `kill`, `clean` |

## Reference files

Read the one that matches the task:

- `references/app-structure.md`: project layout, AppKit lifecycle, panels and menus, packages, `project.pbxproj` edits, sandbox and entitlements, debug vs release identity, icons.
- `references/sparkle.md`: adding Sparkle to a **sandboxed** app end to end: package, Info.plist keys, entitlements, `UpdaterService`, menu and settings buttons, key generation, appcast.
- `references/release.md`: the tag-to-release pipeline, certificate and secret setup, versioning, release notes, and every failure hit while building it.

Templates to copy and adapt (replace `MyApp`, `OWNER/REPO`):

- `templates/release.yml`: the full workflow, drop in `.github/workflows/`
- `templates/release-notes.sh`: notes generator, drop in `scripts/`
- `templates/UpdaterService.swift`: Sparkle wrapper
- `templates/App-Info.plist`: the Sparkle keys, merged into the generated Info.plist

## Rules that save time

1. **Menu bar UI is AppKit.** SwiftUI `MenuBarExtra` menus lag on hover. Use a plain `NSMenu` rebuilt in `menuNeedsUpdate`, and `NSWindow`s hosting SwiftUI. No SwiftUI `Settings` scene.
2. **Floating UI never takes focus.** Use a non-activating borderless `NSPanel`. Hover via `NSTrackingArea(.activeAlways)`; global and local mouse monitors avoid needing Accessibility permission.
3. **Sizes come from a theme**, never hardcoded points. Glass is chrome; content sits on a plain filled surface so glass never samples glass.
4. **Debug and release are different apps.** Give Debug its own bundle ID and display name so settings, login items and permissions don't collide with an installed release.
5. **Custom Info.plist keys need a plist file.** `INFOPLIST_KEY_*` build settings only pass through keys Xcode knows. Sparkle's `SU*` keys go in a small plist referenced by `INFOPLIST_FILE`, merged with the generated one.
6. **A sandboxed Sparkle needs three extras**: `SUEnableInstallerLauncherService`, the `network.client` entitlement, and mach-lookup exceptions for `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`.
7. **Sparkle compares `CFBundleVersion`**, not the marketing version. CI must pass an increasing `CURRENT_PROJECT_VERSION` (the run number works).
8. **`releases/latest` skips pre-releases.** A feed at `.../releases/latest/download/appcast.xml` won't resolve until a stable release exists.
9. **The runner's Xcode must open your project.** A project saved by a newer Xcode fails with "future Xcode project file format", and a deployment target above the runner's SDK fails the build. Keep both in check.
10. **Never test by moving the mouse or clicking menus from an agent.** Build, launch with `open <App>.app`, and ask the user to click.
11. **One commit per feature or fix.** Conventional prefixes (`feat:`, `fix:`, `build:`, `docs:`, `refactor:`, `perf:`) drive the release notes, so write them as user-readable sentences.
