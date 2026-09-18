# Project structure and conventions

## Setup

```sh
bunx create-expo-app@latest my-app
cd my-app
bunx expo install @supabase/supabase-js expo-secure-store @react-native-async-storage/async-storage \
  expo-auth-session expo-web-browser expo-linking expo-updates expo-haptics expo-image \
  react-native-reanimated react-native-gesture-handler react-native-safe-area-context
bun add zustand uniwind tailwindcss
supabase init && supabase link --project-ref <ref>
```

If the repo also has Bun workspaces (e.g. a web console), add a `bunfig.toml` with
`[install] linker = "hoisted"`. Metro and Babel resolve presets relative to themselves and need a
flat `node_modules`.

## package.json scripts

```json
{
	"main": "expo-router/entry",
	"scripts": {
		"start": "expo start",
		"ios": "expo run:ios",
		"android": "expo run:android",
		"lint": "biome check . --write",
		"format": "biome format --write .",
		"db:push": "supabase db push --linked",
		"sb:types": "supabase gen types typescript --project-id <ref> --schema public > src/types/database.types.ts"
	}
}
```

## tsconfig.json

```json
{
	"extends": "expo/tsconfig.base",
	"compilerOptions": {
		"strict": true,
		"paths": { "@/*": ["./src/*"], "@/assets/*": ["./assets/*"] }
	},
	"include": ["**/*.ts", "**/*.tsx", ".expo/types/**/*.ts", "expo-env.d.ts"],
	"exclude": ["supabase/functions", "scripts"]
}
```

Exclude `supabase/functions`: it's Deno code with its own imports and types.

## metro.config.js

```js
const { getDefaultConfig } = require('expo/metro-config')
const { withUniwindConfig } = require('uniwind/metro')

const config = getDefaultConfig(__dirname)
config.resolver.unstable_enablePackageExports = true

module.exports = withUniwindConfig(config, { cssEntryFile: './src/global.css' })
```

Keep unrelated sub-projects (Remotion, web, console) out of Metro's graph with `config.resolver.blockList`.

## babel.config.js

```js
module.exports = (api) => {
	api.cache(true)
	return {
		presets: ['babel-preset-expo'],
		// Add '@lingui/babel-plugin-lingui-macro' first if using Lingui.
		plugins: [],
	}
}
```

## app.config.js

`app.json` holds the static config. `app.config.js` adds build-time extras:

```js
const { execSync } = require('node:child_process')
const appJson = require('./app.json')

let commitSha = 'unknown'
try {
	commitSha = execSync('git rev-parse --short HEAD').toString().trim()
} catch {}

module.exports = {
	expo: {
		...appJson.expo,
		extra: {
			...appJson.expo.extra,
			posthogProjectToken: process.env.POSTHOG_PROJECT_TOKEN,
			posthogHost: process.env.POSTHOG_HOST,
			commitSha,
		},
	},
}
```

Show the version, build number and commit on the About screen:

```ts
const APP_VERSION = Constants.expoConfig?.version ?? '—'
const BUILD_NUMBER = Constants.expoConfig?.ios?.buildNumber ?? Constants.expoConfig?.android?.versionCode ?? '—'
const COMMIT_SHA = (Constants.expoConfig?.extra as { commitSha?: string })?.commitSha ?? '—'
```

Set `"experiments": { "typedRoutes": true, "reactCompiler": true }` and `"newArchEnabled": true` in `app.json`.

## .env

`.env.local` (gitignored), with `.env.example` committed:

```
# Supabase: Dashboard → Project Settings → API
EXPO_PUBLIC_SUPABASE_URL=
EXPO_PUBLIC_SUPABASE_KEY=          # publishable/anon key; RLS protects data
SUPABASE_SECRET_KEY=               # scripts only, never imported by the app

POSTHOG_PROJECT_TOKEN=
POSTHOG_HOST=https://us.i.posthog.com
```

## biome.json

```json
{
	"vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
	"files": {
		"includes": ["src/**", "scripts/**", "*.ts", "*.tsx", "*.js", "!src/types/database.types.ts", "!**/uniwind-types.d.ts", "!**/*.css"]
	},
	"formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
	"javascript": { "formatter": { "quoteStyle": "single", "semicolons": "asNeeded" } },
	"assist": { "actions": { "source": { "organizeImports": "on" } } },
	"linter": { "enabled": true, "rules": { "recommended": true } }
}
```

## Styling

- uniwind: use `className` on RN components for colour, spacing, layout and type size.
- Define tokens in `src/global.css` for light and dark. Import it once at the top of `src/app/_layout.tsx` (`import '../global.css'`).
- Semantic tokens: `bg-background`, `text-foreground`, `text-muted`, `bg-surface`, `bg-input`, `bg-border`, `text-accent`/`bg-accent`, `text-danger`.
- Use inline `style` only for `fontFamily`, `fontWeight`, `letterSpacing`, `lineHeight`, `transform`, dynamic values, or sizes Tailwind can't express.
- `className` doesn't work on `SafeAreaView`. Use a `View` with `useSafeAreaInsets()` padding.
- Never use `StyleSheet.create`, and never hardcode hex in components. Where a raw colour is unavoidable (icon colour, navigator `contentStyle`), derive it from `useColorScheme()` in one place.
- Fonts: `@expo-google-fonts/*`, embedded with the `expo-font` config plugin and also loaded with `useFonts` in the root layout. Refer to them by name (`fontFamily: 'Inter_600SemiBold'`). Headings use Bold with `letterSpacing: -0.5`, buttons use SemiBold.
- Use one icon set (Ionicons). Theme choice (`system | light | dark`) lives in the app store and is applied with `Appearance.setColorScheme`.

## UI hosts: toast, confirm, loading

Each is a small Zustand store in `lib/` with an imperative API, plus a host component in
`components/ui/` mounted once at the end of the root layout.

```ts
// lib/toast.ts
import { create } from 'zustand'

export type ToastVariant = 'success' | 'error' | 'info'
export interface ToastAction { label: string; onPress: () => void }
export interface ToastPayload { id: number; message: string; variant: ToastVariant; duration: number; action?: ToastAction }

interface ToastStore {
	current: ToastPayload | null
	show: (message: string, variant: ToastVariant, duration?: number, action?: ToastAction) => void
	hide: () => void
}

export const useToastStore = create<ToastStore>((set) => ({
	current: null,
	show: (message, variant, duration = 2500, action) =>
		set({ current: { id: Date.now(), message, variant, duration, action } }),
	hide: () => set({ current: null }),
}))

export const toast = {
	success: (message: string, duration?: number, action?: ToastAction) =>
		useToastStore.getState().show(message, 'success', duration, action),
	error: (message: string, duration?: number, action?: ToastAction) =>
		useToastStore.getState().show(message, 'error', duration, action),
	info: (message: string, duration?: number, action?: ToastAction) =>
		useToastStore.getState().show(message, 'info', duration, action),
}
```

```ts
// lib/confirm.ts
import { create } from 'zustand'

interface ConfirmPayload {
	title: string
	message: string
	confirmLabel?: string
	cancelLabel?: string
	destructive?: boolean
	resolve: (value: boolean) => void
}

interface ConfirmStore {
	current: ConfirmPayload | null
	_show: (payload: ConfirmPayload) => void
	_resolve: (value: boolean) => void
}

export const useConfirmStore = create<ConfirmStore>((set, get) => ({
	current: null,
	_show: (payload) => set({ current: payload }),
	_resolve: (value) => {
		get().current?.resolve(value)
		set({ current: null })
	},
}))

/** if (await ask('Delete post?', 'This can't be undone.', { destructive: true })) { … } */
export function ask(
	title: string,
	message: string,
	options?: { confirmLabel?: string; cancelLabel?: string; destructive?: boolean },
): Promise<boolean> {
	return new Promise((resolve) => useConfirmStore.getState()._show({ title, message, resolve, ...options }))
}
```

- `lib/loading.ts` follows the same shape: `loading.show({ message })` / `loading.hide()` for a blocking overlay during sign-out, uploads and similar work.
- iOS can't present a modal while another is dismissing. After `ask()` resolves, wait about 300ms before showing the loading overlay.
- `components/ui/` also holds the shared primitives every screen reuses: `BackButton`, `AuthButton`, `AuthInput`, `ActionSheet`, `Divider`. Never re-create them per screen.

## Haptics

```ts
// lib/haptics.ts
import * as Haptics from 'expo-haptics'
import { Platform } from 'react-native'

const enabled = Platform.OS === 'ios' || Platform.OS === 'android'

export function tapLight() {
	if (!enabled) return
	Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {})
}
// tapMedium, tapHeavy, selectChange, notifySuccess, notifyWarning, notifyError: same shape
```

Call `tapLight()` on every button press, `selectChange()` on pickers, and `notifySuccess()` after saves.

## Features

```
features/posts/
├── screens/        view-post-screen.tsx, edit-post-screen.tsx: orchestration only
├── components/     post-card.tsx, post-detail/photo-carousel.tsx…: one concern per file
├── hooks/          use-edit-post.ts, use-post.ts: state + calls into repositories
└── store.ts        feature-local Zustand store, only if the state must outlive a screen
```

- Use kebab-case file names and named exports (`export function PostCard`).
- A screen composes components and wires hooks. It contains no fetch logic and no large blocks of UI.
- Split any file that grows past 200 lines.
- Every user-facing string goes through Lingui macros (`` t`Save` ``, `<Trans>`) when i18n is enabled. Run `bun lingui` after changing strings.
