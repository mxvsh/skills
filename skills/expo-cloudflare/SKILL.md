---
name: expo-cloudflare
description: Build full-stack TypeScript products as a Bun + Turborepo monorepo - an Expo (React Native) mobile app and a TanStack Start web app, both backed by one Hono API on Cloudflare Workers with D1 via Drizzle and better-auth. Use when scaffolding a new Expo app with a backend, adding API routes, database tables, auth, or features to such a monorepo, wiring the typed Hono client into web or mobile, or setting up EAS builds and in-app OTA updates.
---

# Expo + Cloudflare monorepo

One repo, one Cloudflare Worker, one Expo app. The Worker serves the TanStack Start web app
and the Hono API at `/api/*`. The Hono app lives in its own package and exports `AppType`, so
web and mobile call it through the same typed `hc` client: a route change breaks the mobile
build at compile time instead of the app at runtime.

```
browser  ──▶ apps/web (Cloudflare Worker) ──▶ D1 (Drizzle)
              TanStack Start + Hono at /api ──▶ KV / R2 / Durable Objects when needed
Expo app ──▶ same /api via hc<AppType>
```

## Stack

| Layer | Choice |
|---|---|
| Runtime / PM | Bun (never npm, yarn, pnpm or npx; use `bun`, `bunx`) |
| Monorepo | Bun workspaces + Turborepo |
| Language | TypeScript strict, `noUncheckedIndexedAccess`, no `any` |
| Lint / format | Biome: tabs, double quotes, semicolons as needed, 100 cols |
| API | Hono + `@hono/zod-validator`, typed `hc` client |
| Hosting | Cloudflare Workers via `@cloudflare/vite-plugin` + `wrangler` |
| Database | Cloudflare D1 + Drizzle ORM, migrations from `drizzle-kit generate` |
| Auth | better-auth (Drizzle adapter), `@better-auth/expo` for mobile |
| Validation | Zod, shared schemas in `packages/core` |
| Web | TanStack Start (React 19, TanStack Router, Vite), TanStack Query, Zustand, Tailwind v4, Base UI |
| Mobile | Expo (latest SDK), Expo Router, dev client, uniwind (Tailwind for RN), TanStack Query, Zustand, Reanimated |
| Mobile release | EAS Build + EAS Update |
| Tests | `bun test`, services against in-memory SQLite with the real migrations |

## Layout

```
apps/web        TanStack Start + Hono mounted at /api/* → Cloudflare Worker
apps/mobile     Expo app
packages/api    Hono app: routes, services, middleware. Exports createApp + AppType
packages/db     Drizzle schema, D1 migrations, test db
packages/auth   better-auth server config + clients
packages/core   Zod schemas, DTO types, ids, constants
packages/ui     Web components (Base UI + Tailwind), optional Storybook
packages/tokens Design tokens → tokens.css (web) + global.css (mobile, uniwind)
packages/config Shared tsconfig bases
docs/           architecture.md, decisions.md
```

Import rules (A → B means A may import B):

```
apps/web    → ui, api, auth, core, tokens
apps/mobile → api (types only), auth/expo-client, core, tokens
ui → tokens, core     api → db, auth, core     auth → db, core     db → core
```

Replace the `@app/*` scope used in the references with the project's own scope.

## Non-negotiables

- Internal packages export TypeScript source (`"exports": { ".": "./src/index.ts" }`). No build step except `tokens`.
- The Hono app is stateless. Bindings arrive per request via `app.fetch(request, env)`; never read env at module scope.
- Services take `(db, env)` explicitly. No DI container. Routes stay thin.
- Every error leaves the API as `{ code, message }` with `code` from a typed list. Clients switch on `code`.
- Migrations are generated with `drizzle-kit generate`, never hand-written. better-auth tables come from its CLI.
- `wrangler.toml` in `apps/web` is the single worker config for dev, build and deploy. Secrets live in `.dev.vars` locally and `wrangler secret put` in production.
- Web features are `api/` · `data/` · `ui/` · `index.ts`. Routes only compose features.
- Mobile features are `api/` · `data/` · `ui/` · `index.ts` too. Screens in `src/app/` stay thin.
- Never edit `android/` or `ios/`. They are prebuild output: change `app.json` or a config plugin.
- No raw hex or px in components. Use token-generated Tailwind classes.
- Read the versioned Expo docs for the SDK in `package.json` before using an Expo module API.

## References

Read the one that matches the task before writing code:

- [references/monorepo.md](references/monorepo.md): scaffold, workspaces, turbo, tsconfig, Biome, tokens pipeline, root scripts
- [references/backend.md](references/backend.md): Hono app, wrangler, bindings, middleware, errors, services, D1/Drizzle, testing, better-auth server
- [references/web.md](references/web.md): TanStack Start, `/api` mount, isomorphic `hc` client, feature layout, Query
- [references/mobile.md](references/mobile.md): Expo app structure, Metro, uniwind, API client, auth client, env, EAS profiles
- [references/expo-updates.md](references/expo-updates.md): `app.json` updates config, runtime version, channels, in-app update flow, publishing

## Commands

```sh
bun install
bun dev:web              # web + API on :3000 in workerd with local D1 and HMR
bun dev:mobile           # Expo dev client (Metro)
bun check-types
bun lint                 # biome check
bun format
bun test
bun db:generate          # after editing schema; add --name <slug>
bun db:migrate:local
bun db:migrate:remote
bun types:worker         # after editing wrangler.toml
bun deploy               # vite build && wrangler deploy
```

## Git

One-line commits, `type: what changed` (feat, fix, docs, chore, refactor, ui, api, mobile). Never
commit `.dev.vars`, `.env*`, keystores, or generated files.
