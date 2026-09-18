# Expo updates: config and in-app policy

## app.json

```json
{
	"expo": {
		"name": "App",
		"slug": "app",
		"version": "1.0.0",
		"scheme": "app",
		"runtimeVersion": { "policy": "fingerprint" },
		"updates": {
			"url": "https://u.expo.dev/<projectId>"
		},
		"extra": { "eas": { "projectId": "<projectId>" } },
		"owner": "<expo-account>",
		"ios": { "bundleIdentifier": "com.example.app" },
		"android": { "package": "com.example.app" },
		"plugins": ["expo-router", "expo-secure-store"],
		"experiments": { "typedRoutes": true }
	}
}
```

- **`updates.url`** is the EAS Update endpoint for this project. `eas update:configure` writes it, and it must match `extra.eas.projectId`.
- **`runtimeVersion`** decides which binaries can take an update. An update only reaches builds with the same runtime version.
  - `"fingerprint"` (default here): a hash of the native project. It changes only when native code or config changes, so JS-only releases keep reaching every installed build.
  - `"appVersion"`: the runtime is `version`. Simpler, but a version bump cuts off OTA delivery to everyone on the old version, even if no native code changed. Use it only if you bump `version` exclusively for native releases.
- **Channel:** with EAS Build, the channel comes from the build profile in `eas.json` and is baked into the binary. Don't hardcode it in `app.json`.
  - **Exception, local release builds** (`gradlew bundleRelease` / Xcode archive without EAS): no channel is injected, so set it yourself:

    ```json
    "updates": {
    	"url": "https://u.expo.dev/<projectId>",
    	"requestHeaders": { "expo-channel-name": "production" }
    }
    ```

    Every local binary, debug included, then reports `production`. The in-app check below guards on `__DEV__` for that reason.
- **`checkAutomatically`** defaults to `ON_LOAD`: expo-updates checks natively on each cold start and applies on the *next* cold start. Keep it. The in-app flow adds a prompt so users don't have to kill the app twice. Set `"ON_ERROR_RECOVERY"` or `"NEVER"` only if the app must fully control when updates happen.

## eas.json

```json
{
	"cli": { "version": ">= 16.0.0", "appVersionSource": "remote" },
	"build": {
		"development": {
			"developmentClient": true,
			"distribution": "internal",
			"channel": "development"
		},
		"preview": {
			"distribution": "internal",
			"channel": "preview"
		},
		"production": {
			"channel": "production",
			"autoIncrement": true
		}
	},
	"submit": { "production": {} }
}
```

- One channel per profile. By default channel `X` serves branch `X`.
- `appVersionSource: "remote"` + `autoIncrement` lets EAS own build numbers and versionCodes. You bump `version` in `app.json` by hand for user-visible releases.

## Publishing

```sh
cd apps/mobile
bunx eas-cli@latest update --channel preview --message "what changed"      # try it first
bunx eas-cli@latest update --channel production --message "what changed"
```

- JS and asset changes ship as updates. Anything native (new module, config plugin, `app.json` native fields, SDK upgrade) needs a new build. With `fingerprint`, EAS computes the new runtime for you.
- Roll back with `eas update:rollback` or republish a previous update to the channel.

## In-app update policy

The rules:

1. **Guard.** Do nothing in `__DEV__`, when `!Updates.isEnabled`, or off the production channel. Dev and preview builds are for testing and shouldn't get production updates.
2. **Boot check.** On launch, check, and if an update is available, **download it in the background**.
3. **Never reload by surprise.** A downloaded update raises a "Restart to update" prompt. Only a user tap calls `reloadAsync()`.
4. **Cancel keeps the download.** Dismissing the prompt leaves `available = true`, so Settings can offer "Restart to update" without downloading again. If ignored, `ON_LOAD` applies it on the next cold start anyway.
5. **Manual check in Settings.** A row showing `v<version> (<commit>)` that checks on tap and reports the result in words.
6. **Optional:** check again when the app returns to the foreground if the last check was more than N hours ago (`AppState` listener).

### features/updates/data/updates.ts

```ts
import * as Updates from "expo-updates"
import { useUpdateStore } from "./update.store"

export type UpdateResult = "none" | "downloaded" | "unavailable" | "failed"

export async function checkForUpdate(): Promise<UpdateResult> {
	if (__DEV__ || !Updates.isEnabled || Updates.channel !== "production") return "unavailable"

	try {
		const check = await Updates.checkForUpdateAsync()
		if (!check.isAvailable) return "none"
		await Updates.fetchUpdateAsync()
		return "downloaded"
	} catch {
		return "failed"
	}
}

/** Restarts into the downloaded bundle. Only ever called from a user action. */
export async function applyUpdate(): Promise<void> {
	await Updates.reloadAsync().catch(() => {})
}

/** Boot check: fetch only, never apply. Raises the prompt. */
export async function checkForUpdateOnBoot(): Promise<void> {
	if ((await checkForUpdate()) !== "downloaded") return
	useUpdateStore.getState().setAvailable(true)
	useUpdateStore.getState().setPromptOpen(true)
}
```

### features/updates/data/update.store.ts

```ts
import { create } from "zustand"

interface UpdateState {
	/** A new bundle is downloaded and waiting for a restart. */
	available: boolean
	promptOpen: boolean
	setAvailable: (available: boolean) => void
	setPromptOpen: (promptOpen: boolean) => void
}

export const useUpdateStore = create<UpdateState>((set) => ({
	available: false,
	promptOpen: false,
	setAvailable: (available) => set({ available }),
	setPromptOpen: (promptOpen) => set({ promptOpen }),
}))
```

### features/updates/ui/UpdatePrompt.tsx

A modal or bottom sheet mounted once in the root layout: title "Update available", body "A new
version has downloaded. Restart to update now?", buttons **Restart** (`applyUpdate()`, then show
"Restarting…") and **Later** (`setPromptOpen(false)`).

### Settings row

```ts
import Constants from "expo-constants"

/** "v1.2.0 (7c5f7c9)": which build this is, without a laptop. */
export function versionLabel(): string {
	const name = Constants.expoConfig?.version
	if (!name) return ""
	const commit = Constants.expoConfig?.extra?.commit as string | undefined
	return commit ? `v${name} (${commit})` : `v${name}`
}

export const UPDATE_WORDS: Record<UpdateResult, string> = {
	none: "Up to date",
	downloaded: "Restarting…",
	unavailable: "Not available here",
	failed: "Couldn't check",
}
```

- When `available` is true, the row reads "Restart to update" and calls `applyUpdate()`.
- Otherwise it reads "Check for update" with `versionLabel()` as its value. On tap, show "Checking…", run `checkForUpdate()`, show the result from `UPDATE_WORDS`, and if the result is `downloaded`, call `applyUpdate()` (the user asked for it).

Also available: `Updates.useUpdates()`, a hook that exposes `isUpdateAvailable`, `isUpdatePending`
and `downloadedUpdate`. It works in place of the store if you don't need the prompt state shared
elsewhere.
