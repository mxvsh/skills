# Expo updates: config and in-app policy

## Policy

OTA updates stay **entirely off the startup path**. The splash never waits on the network:
`Updates.checkForUpdateAsync()` has no timeout of its own, so gating launch on it holds the
app on the launch image for as long as a slow, captive or offline connection takes to give up.

1. **Check once, shortly after the app is interactive** (about 4s after `ready`).
2. **Check again every time the app returns from the background.**
3. **Download in the background.** Never reload unprompted, because that would pull the user off whatever screen they're on.
4. **Ask:** "Update available. Restart now?" with **Restart now** and **Later**.
5. **Later** keeps the downloaded update. The prompt returns on the next foreground, and Settings has a manual row to restart into it at any time.
6. **Restart through a themed reload screen** so the relaunch doesn't flash white.
7. If the user never restarts, expo-updates applies the downloaded bundle on the next cold start anyway.

```
features/updates/
├── hooks/use-ota-updates.ts     startup + foreground check, download, prompt
├── lib/reload.ts                reloadWithThemedScreen()
├── lib/build-info.ts            buildLabel, copyBuildDetails(): what's running, for support
└── components/update-row.tsx    Settings row: check / download / restart
```

## hooks/use-ota-updates.ts

```ts
import * as Updates from 'expo-updates'
import { useEffect, useRef } from 'react'
import { AppState, type AppStateStatus } from 'react-native'
import { ask } from '@/lib/confirm'
import { reloadWithThemedScreen } from '../lib/reload'

/** How long after the app is up and interactive to look for an update. */
const STARTUP_UPDATE_DELAY_MS = 4000

/**
 * OTA updates, off the startup path: check once shortly after the app is
 * interactive, then on every return from the background. An update downloads in
 * the background and is only applied when the user agrees.
 */
export function useOtaUpdates(appReady: boolean) {
	// Native-held, so it survives a JS remount. A ref alone would forget an
	// already-downloaded update, and checkForUpdateAsync() reports "none available"
	// for a bundle that's already on disk, leaving no way back to the prompt.
	const { isUpdatePending } = Updates.useUpdates()
	const appState = useRef(AppState.currentState)
	const checkingRef = useRef(false)
	const promptOpenRef = useRef(false)
	const pendingRef = useRef(false)
	pendingRef.current ||= isUpdatePending

	useEffect(() => {
		if (!Updates.isEnabled) return

		const promptRestart = async () => {
			if (promptOpenRef.current) return
			promptOpenRef.current = true
			const restart = await ask('Update available', 'A new version is ready. Restart now to get the latest version.', {
				confirmLabel: 'Restart now',
				cancelLabel: 'Later',
			})
			promptOpenRef.current = false
			if (restart) await reloadWithThemedScreen()
		}

		const checkForUpdate = async () => {
			if (checkingRef.current) return
			if (pendingRef.current) {
				void promptRestart()
				return
			}
			checkingRef.current = true
			try {
				const check = await Updates.checkForUpdateAsync()
				if (!check.isAvailable) return
				await Updates.fetchUpdateAsync()
				pendingRef.current = true
				void promptRestart()
			} catch {
				// Best-effort: the next foreground retries.
			} finally {
				checkingRef.current = false
			}
		}

		const subscription = AppState.addEventListener('change', (next: AppStateStatus) => {
			if (/inactive|background/.test(appState.current) && next === 'active') void checkForUpdate()
			appState.current = next
		})

		let startupCheck: ReturnType<typeof setTimeout> | undefined
		if (appReady) startupCheck = setTimeout(() => void checkForUpdate(), STARTUP_UPDATE_DELAY_MS)

		return () => {
			subscription.remove()
			if (startupCheck) clearTimeout(startupCheck)
		}
	}, [appReady])
}
```

Call it once in the root layout with the same `ready` flag that hides the splash:

```ts
const ready = fontsLoaded && hydrated && cacheHydrated && sessionChecked /* … */
useOtaUpdates(ready)
```

## lib/reload.ts

```ts
import * as Updates from 'expo-updates'
import { Appearance } from 'react-native'

/**
 * Applies a downloaded update. expo-updates paints its own native screen while the
 * JS runtime restarts, and its default is white with a system-blue spinner. Match
 * the splash colours so the restart reads as one continuous relaunch.
 */
export async function reloadWithThemedScreen(): Promise<void> {
	const dark = Appearance.getColorScheme() === 'dark'
	await Updates.reloadAsync({
		reloadScreenOptions: {
			backgroundColor: dark ? '<dark background>' : '<light background>',
			fade: true,
			spinner: { color: '<accent>', size: 'large' },
		},
	})
}
```

Take the colours from the theme constants that also feed `global.css` and the `expo-splash-screen`
plugin config, so they stay in sync.

## components/update-row.tsx

The manual path in Settings. It shows the right action for the current state:

```tsx
import * as Updates from 'expo-updates'
import { useState } from 'react'
import { toast } from '@/lib/toast'
import { reloadWithThemedScreen } from '../lib/reload'

export function UpdateRow() {
	const { isUpdateAvailable, isUpdatePending, isDownloading } = Updates.useUpdates()
	const [checking, setChecking] = useState(false)

	// Nothing to apply in dev or when updates are disabled.
	if (__DEV__ || !Updates.isEnabled) return null

	const apply = async () => {
		try {
			await reloadWithThemedScreen()
		} catch {
			toast.error("Couldn't restart. Close and reopen the app.")
		}
	}

	const download = async () => {
		try {
			await Updates.fetchUpdateAsync()
		} catch {
			toast.error("Couldn't download the update")
		}
	}

	const check = async () => {
		setChecking(true)
		try {
			const result = await Updates.checkForUpdateAsync()
			if (!result.isAvailable) {
				toast.success("You're on the latest version")
				return
			}
			await Updates.fetchUpdateAsync()
		} catch {
			toast.error("Couldn't check for updates")
		} finally {
			setChecking(false)
		}
	}

	if (isUpdatePending) return <Button label="Restart to apply update" onPress={apply} />
	if (isUpdateAvailable) {
		return <Button label={isDownloading ? 'Downloading update…' : 'Download update'} variant="secondary" busy={isDownloading} onPress={download} />
	}
	return <Button label="Check for updates" variant="ghost" busy={checking || isDownloading} onPress={check} />
}
```

## lib/build-info.ts

Show which bundle is running so a support conversation can be tied to a specific `eas update`:

```ts
import Constants from 'expo-constants'
import * as Clipboard from 'expo-clipboard'
import * as Updates from 'expo-updates'

const version = Constants.expoConfig?.version ?? '?'
const build = Constants.expoConfig?.ios?.buildNumber ?? Constants.expoConfig?.android?.versionCode

/** "production · 3f2a9c1b · 2026-09-18", or "production · embedded" before any OTA update. */
export const buildLabel = (() => {
	if (__DEV__) return 'dev bundle'
	if (Updates.isEmbeddedLaunch || !Updates.updateId) return `${Updates.channel || 'embedded'} · embedded`
	const short = Updates.updateId.split('-')[0]
	const created = Updates.createdAt ? ` · ${Updates.createdAt.toISOString().slice(0, 10)}` : ''
	return `${Updates.channel || 'update'} · ${short}${created}`
})()

/** The full details. Short ids are for reading, not for reporting. */
export async function copyBuildDetails(): Promise<void> {
	await Clipboard.setStringAsync(
		[
			`v${version}${build ? ` (${build})` : ''}`,
			`runtime ${Updates.runtimeVersion ?? '?'}`,
			`channel ${Updates.channel ?? '-'}`,
			`update ${Updates.updateId ?? 'embedded'}`,
		].join('\n'),
	)
	toast.success('Build details copied')
}
```

Settings or About shows `v{version} ({build})`, the `buildLabel`, and the `UpdateRow`. A long
press copies the build details.

## app.json

```json
{
	"expo": {
		"version": "1.0.0",
		"runtimeVersion": "1.0.0",
		"updates": {
			"url": "https://u.expo.dev/<projectId>",
			"requestHeaders": { "expo-channel-name": "production" }
		},
		"plugins": ["expo-router", "expo-updates"],
		"extra": { "eas": { "projectId": "<projectId>" } },
		"ios": { "buildNumber": "1" },
		"android": { "versionCode": 1 }
	}
}
```

- **`updates.url`** is written by `bunx eas-cli update:configure`. It must match `extra.eas.projectId`.
- **`expo-channel-name`** is set explicitly, so locally built binaries (Xcode archive, `gradlew`) listen to `production` too. EAS Build writes the profile's channel over it.
- **`runtimeVersion`** is an explicit string. An update only reaches binaries with the same value.
  - Bump it with `version` for each store release that changes native code: a new or upgraded native module, a config plugin, native `app.json` fields, or an SDK upgrade. Shipping JS that calls native code the installed binary lacks will crash it.
  - For a JS-only fix, publish an update and leave both alone.
  - Alternative: `"runtimeVersion": { "policy": "fingerprint" }` derives it from the native project automatically.
- The default `checkAutomatically: "ON_LOAD"` stays. It's the native cold-start check and doesn't block the JS startup path.

## eas.json

```json
{
	"cli": { "version": ">= 16.0.0", "appVersionSource": "local" },
	"build": {
		"production": { "channel": "production" }
	},
	"submit": { "production": {} }
}
```

`appVersionSource: "local"` keeps `version`, `buildNumber` and `versionCode` in `app.json` as the
single source of truth. Add `development` (`developmentClient: true`) and `preview` profiles with
their own channels when you need them.

## Publishing

```sh
bunx eas-cli@latest update --channel production --message "fix: post card layout"
```

- The update reaches binaries whose `runtimeVersion` matches the current `app.json`. Check that before publishing.
- Native changes need a new store build with a bumped `runtimeVersion`. Updates for that runtime come after.
- Roll back with `eas update:rollback`, or republish the previous update.
- Add a `.easignore` for folders that shouldn't be uploaded (web, console, docs).
