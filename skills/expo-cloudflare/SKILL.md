---
name: expo-cloudflare
description: Build full-stack mobile apps as a Bun + Turborepo monorepo - an Expo (React Native) app backed by a Hono API on Cloudflare Workers with D1 via Drizzle and better-auth. Use when scaffolding a new Expo app with a backend, adding API routes, database tables, auth, or features to such a monorepo, wiring the typed Hono client into the app, or setting up EAS builds and in-app OTA updates.
---

# Expo + Cloudflare monorepo

One repo, one Cloudflare Worker, one Expo app. The Worker is a Hono API. It exports `AppType`,
so the app calls it through a typed `hc` client: a route change breaks the mobile build at
compile time instead of the app at runtime.

```
Expo app ──▶ apps/api (Cloudflare Worker, Hono at /api) ──▶ D1 (Drizzle)
             hc<AppType>                                  ──▶ KV / R2 / Durable Objects when needed
```

## Stack

| Layer | Choice |
|---|---|
| Runtime / PM | Bun (never npm, yarn, pnpm or npx; use `bun`, `bunx`) |
| Monorepo | Bun workspaces + Turborepo |
| Language | TypeScript strict, `noUncheckedIndexedAccess`, no `any` |
| Lint / format | Biome: tabs, double quotes, semicolons as needed, 100 cols |
| API | Hono + `@hono/zod-validator`, typed `hc` client |
| Hosting | Cloudflare Workers, `wrangler dev` / `wrangler deploy` |
| Database | Cloudflare D1 + Drizzle ORM, migrations from `drizzle-kit generate` |
| Auth | better-auth (Drizzle adapter) + `@better-auth/expo` |
| Validation | Zod, shared schemas in `packages/core` |
| Mobile | Expo (latest SDK), Expo Router, dev client, uniwind (Tailwind for RN), TanStack Query, Zustand, Reanimated |
| Mobile release | EAS Build + EAS Update |
| Tests | `bun test`, services against in-memory SQLite with the real migrations |

## Layout

```
apps/api        Hono app → Cloudflare Worker. Exports createApp + AppType
apps/mobile     Expo app
packages/db     Drizzle schema, D1 migrations, test db
packages/auth   better-auth server config
packages/core   Zod schemas, DTO types, ids, constants
packages/tokens Design tokens → global.css (uniwind) + native theme object
packages/config Shared tsconfig bases
docs/           architecture.md, decisions.md
```

Import rules (A → B means A may import B):

```
apps/mobile → api (types only), core, tokens
apps/api    → db, auth, core
auth → db, core     db → core
```

Replace the `@app/*` scope used in the references with the project's own scope.

## Non-negotiables

- Internal packages export TypeScript source (`"exports": { ".": "./src/index.ts" }`). No build step except `tokens`.
- Mobile imports `@app/api` with `import type` only. Server code never reaches the bundle.
- The Hono app is stateless. Bindings arrive per request via `fetch(request, env)`; never read env at module scope.
- Services take `(db, env)` explicitly. No DI container. Routes stay thin.
- Every error leaves the API as `{ code, message }` with `code` from a typed list. The app switches on `code`.
- Migrations are generated with `drizzle-kit generate`, never hand-written. better-auth tables come from its CLI.
- `apps/api/wrangler.toml` is the single worker config. Secrets live in `.dev.vars` locally and `wrangler secret put` in production.
- Mobile features are `api/` · `data/` · `ui/` · `index.ts`. Screens in `src/app/` stay thin.
- Never edit `android/` or `ios/`. They are prebuild output: change `app.json` or a config plugin.
- No raw hex or px in components. Use token-generated classes.
- Read the versioned Expo docs for the SDK in `package.json` before using an Expo module API.

## References

Read the one that matches the task before writing code:

- [references/monorepo.md](references/monorepo.md): scaffold, workspaces, turbo, tsconfig, Biome, tokens pipeline, root scripts
- [references/backend.md](references/backend.md): Worker entry, Hono app, wrangler, middleware, errors, services, D1/Drizzle, testing, better-auth
- [references/mobile.md](references/mobile.md): Expo app structure, Metro, uniwind, API client, auth client, data, env, EAS
- [references/expo-updates.md](references/expo-updates.md): `app.json` updates config, runtime version, channels, in-app update flow, publishing

## Commands

```sh
bun install
bun dev:api              # wrangler dev on :8787 with local D1, reachable over the LAN
bun dev:mobile           # Expo dev client (Metro)
bun check-types
bun lint                 # biome check
bun format
bun test
bun db:generate          # after editing schema; add --name <slug>
bun db:migrate:local
bun db:migrate:remote
bun types:worker         # after editing wrangler.toml
bun deploy               # wrangler deploy
```

## Git

One-line commits, `type: what changed` (feat, fix, docs, chore, refactor, api, mobile). Never
commit `.dev.vars`, `.env*`, keystores, or generated files.
