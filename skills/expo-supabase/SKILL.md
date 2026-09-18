---
name: expo-supabase
description: Build Expo (React Native) apps backed by Supabase - Postgres with RLS, Auth (OAuth, OTP, password), Edge Functions and generated types - with a strict repository data layer, persisted Zustand cache, uniwind styling and background OTA updates with a restart prompt. Use when scaffolding a new Expo + Supabase app, adding screens, features, tables, RLS policies, RPCs, edge functions or auth flows to one, or setting up in-app OTA updates.
---

# Expo + Supabase

A single Expo app with its backend in a `supabase/` folder in the same repo. Supabase is the
whole backend: Postgres with **RLS as the security boundary**, Auth, Storage and Edge Functions.
The app talks to it only through a repository layer typed by the generated `Database` types.

```
Expo app ──▶ data/repositories ──▶ supabase-js ──▶ Postgres (RLS) / RPCs
                                             └──▶ Edge Functions (Deno) for secrets, 3rd-party APIs, webhooks
```

## Stack

| Layer | Choice |
|---|---|
| Framework | Expo (latest SDK), React Native new architecture, React Compiler |
| Language | TypeScript strict |
| Routing | expo-router (file-based, typed routes) |
| Styling | uniwind + Tailwind v4 via `className`; tokens in `src/global.css` |
| State | Zustand, persisted to AsyncStorage for app state and the offline cache |
| Backend | Supabase: Postgres + RLS, Auth, Storage, Edge Functions |
| Auth storage | `expo-secure-store` |
| Animations | react-native-reanimated |
| Images / icons | expo-image, one icon set (Ionicons) |
| Haptics | `src/lib/haptics.ts`, with `tapLight()` on every button press |
| i18n (optional) | Lingui v5 macros |
| Analytics (optional) | PostHog |
| Lint / format | Biome: 2 spaces, single quotes, no semicolons, 100 cols |
| Runtime / PM | Bun for scripts; `bunx expo install` for dependencies |

## Layout

```
src/
├── app/               routes only: thin re-exports of feature screens
├── features/<domain>/ screens/ components/ hooks/ (+ store.ts when needed)
├── data/
│   ├── repositories/  the ONLY place that issues Supabase queries
│   └── models/        app-facing types + row → model mappers
├── components/ui/     generic design-system primitives and hosts (toast, confirm, loading)
├── lib/               cross-cutting: supabase, haptics, toast, confirm, loading, posthog…
├── stores/            global Zustand stores (app, cache, preferences)
├── types/             database.types.ts: GENERATED, never edit
└── global.css         uniwind theme tokens (light + dark)
supabase/
├── config.toml
├── migrations/        created with `supabase migration new`
└── functions/
    ├── _shared/       handler, clients, auth, http errors, env, integrations (push, storage, AI)
    └── <name>/        index.ts (only this function's logic) + deno.json
```

## Layering rules

- `data/repositories/` is the only code that imports `@/lib/supabase` for DB, RPC, storage or function calls.
- `supabase.auth.*` is only called in `features/auth/hooks/` and `app/_layout.tsx`.
- Screens → hooks → repositories. Components receive data from hooks. No layer is skipped.
- A feature never imports another feature's internals. Share through `components/ui/`, `lib/`, `data/` or `stores/`.
- Route files in `src/app/` only re-export: `export { HomeScreen as default } from '@/features/home/screens/home-screen'`.

## Non-negotiables

- RLS is on for every table. Clients never get a service key. Writes that must protect columns go through `security definer` RPCs.
- Never write recursive RLS policies. Use `security definer` helper functions instead.
- Migrations come from `supabase migration new <name>`. Regenerate types after every schema change.
- Secrets live in Edge Functions (`supabase secrets set`). Only `EXPO_PUBLIC_*` values reach the app.
- Every Edge Function uses `handler()` and helpers from `_shared/`. Anything needed twice moves into `_shared/`.
- `android/` and `ios/` are generated. Change native config through `app.json` or config plugins.
- Use `className` for colour, spacing and layout. Never use `StyleSheet.create` or hardcode hex values in components.
- One concern per file. Screens are orchestration only. Keep files under 200 lines.
- Toasts go through `toast.*`, confirms through `await ask(…)`, and blocking work through `loading.show()`.
- OTA updates never block startup or reload unprompted: download in the background, then ask to restart.
- Read the versioned Expo docs for the SDK in `package.json` before using an Expo module.

## References

- [references/structure.md](references/structure.md): project setup, configs, styling and tokens, UI hosts, feature conventions
- [references/supabase.md](references/supabase.md): client, auth provider, repositories and models, cache, migrations and RLS, RPCs, types
- [references/edge-functions.md](references/edge-functions.md): the `_shared/` toolkit (handler wrapper, clients, auth modes, errors, integrations) and how to write a function on it
- [references/root-layout.md](references/root-layout.md): boot gating, splash handling, auth and onboarding redirects, deep links, notifications
- [references/expo-updates.md](references/expo-updates.md): OTA policy (off the startup path, foreground checks, restart prompt, themed reload), Settings update row, build info, `app.json` and `eas.json`, publishing

## Commands

```sh
bun start                          # expo start (dev client)
bun ios / bun android              # native build + run
bunx expo install <pkg>            # add deps (SDK-matched versions)
bun tsc --noEmit                   # type check
bun lint                           # biome check --write
supabase migration new <name>      # new migration
bun db:push                        # supabase db push --linked
bun sb:types                       # regenerate src/types/database.types.ts
supabase functions new <name>      # then copy _templates/deno.json in
supabase functions deploy <name>
supabase secrets set KEY=value
bunx eas-cli update --channel production --message "…"   # OTA update
```

After every change, run `bun tsc --noEmit` and `bun lint` (and `bun lingui` if strings changed).

## Git

Single-line commit messages. No trailers or co-author lines.
