---
name: web-cloudflare
description: Build full-stack web apps and admin dashboards as a Bun + Turborepo monorepo - TanStack Start (React 19) with coss ui (Base UI) and a Hono API mounted at /api, deployed as one Cloudflare Worker with D1 via Drizzle and better-auth. Use when scaffolding a new web app or dashboard on Cloudflare, adding pages, features, API routes, database tables or auth to such a repo, or building dashboard UI (sidebar shell, tables, form dialogs, toasts, confirms).
---

# Web + Cloudflare monorepo

One repo, one Cloudflare Worker. The Worker serves the TanStack Start app and a Hono API at
`/api/*`. The Hono app lives in its own package and exports `AppType`, so the web app calls it
through a typed `hc` client. During SSR the client runs the Hono app in-process, and in the
browser it uses plain HTTP.

```
browser ──▶ apps/web (Cloudflare Worker) ──▶ D1 (Drizzle)
             TanStack Start + Hono at /api ──▶ KV / R2 / Durable Objects when needed
```

## Stack

| Layer | Choice |
|---|---|
| Runtime / PM | Bun (never npm, yarn, pnpm or npx; use `bun`, `bunx`) |
| Monorepo | Bun workspaces + Turborepo |
| Language | TypeScript strict, `noUncheckedIndexedAccess`, no `any` |
| Lint / format | Biome: tabs, double quotes, semicolons as needed, 100 cols |
| Web | TanStack Start (React 19, TanStack Router, Vite), `@tanstack/react-router-ssr-query` |
| UI | coss ui (`@base-ui/react`, shadcn-style registry), Tailwind v4, lucide-react, motion |
| State | TanStack Query (server), Zustand (UI: confirm store, local UI state) |
| API | Hono + `@hono/zod-validator`, typed `hc` client, mounted at `/api/*` |
| Hosting | Cloudflare Workers via `@cloudflare/vite-plugin` + `wrangler` (not Nitro) |
| Database | Cloudflare D1 + Drizzle ORM, migrations from `drizzle-kit generate` |
| Auth | better-auth (Drizzle adapter, Google), cookie sessions on the same origin |
| Validation | Zod, shared schemas in `packages/core` |
| Tests | `bun test`, services against in-memory SQLite with the real migrations |

## Layout

```
apps/web        TanStack Start + Hono at /api → Cloudflare Worker
packages/api    Hono app: routes, services, middleware. Exports createApp + AppType
packages/db     Drizzle schema, D1 migrations, test db
packages/auth   better-auth server config + browser client
packages/core   Zod schemas, DTO types, enums, constants, pure helpers
packages/config Shared tsconfig bases
docs/           architecture.md, decisions.md
```

```
apps/web/src/
  routes/            thin file routes: __root, _authed guard, login, api.$ → Hono
  features/<name>/   api/ data/ hooks/ components/ lib/ index.ts
  components/ui/     coss ui primitives (generated; treat as a library)
  components/        cross-cutting components (confirm/)
  lib/               api client, auth client, notify, utils
```

Import rules (A → B means A may import B):

```
apps/web → api, auth, core
api → db, auth, core     auth → db, core     db → core
```

Replace the `@app/*` scope used in the references with the project's own scope. Inside the app, the alias is `@/*` → `src/*`.

## Non-negotiables

- All data goes through Hono via `api()` from `@/lib/api/client`. Use `createServerFn` only for SSR-only needs.
- Internal packages export TypeScript source. No build step.
- The Hono app is stateless. Bindings arrive per request via `bindings()` from `cloudflare:workers`, never at module scope.
- Services take `(db, env)` explicitly. Routes stay thin, in both Hono and TanStack Router.
- Every error leaves the API as `{ code, message }` with `code` from a typed list.
- Migrations are generated with `drizzle-kit generate`, never hand-written. better-auth tables come from its CLI.
- `apps/web/wrangler.toml` is the single worker config for dev, build and deploy. Secrets live in `.dev.vars` locally and `wrangler secret put` in production.
- Reuse coss ui. Never hand-roll buttons, dialogs or inputs, and don't edit `components/ui/*` per page.
- Toasts go through `notify.*`. Destructive actions go through `await confirm({ … })`.
- Only semantic colour classes (`bg-background`, `text-muted-foreground`, …). No raw hex.
- Pages are `PageHeader` + one feature component. Every list handles loading, error and empty states.

## References

Read the one that matches the task before writing code:

- [references/monorepo.md](references/monorepo.md): scaffold, workspaces, turbo, tsconfig, Biome, root scripts
- [references/backend.md](references/backend.md): Hono app, errors, middleware, services, D1/Drizzle, testing, better-auth, wrangler
- [references/web.md](references/web.md): app layout, Vite + Cloudflare plugin, router, `/api` mount, isomorphic `hc` client, feature slices, auth guard
- [references/ui.md](references/ui.md): coss ui setup, notify, confirm, dashboard shell and sidebar, manager tables, form dialogs, copy

## Commands

```sh
bun install
bun dev:web              # web + API on :3000 in workerd with local D1 and HMR
bun check-types
bun lint                 # biome check
bun format
bun test
bun db:generate          # after editing schema; add --name <slug>
bun db:migrate:local
bun db:migrate:remote
bun types:worker         # after editing wrangler.toml
bun deploy               # vite build && wrangler deploy
bunx --bun shadcn@latest add @coss/<component>   # from apps/web
```

## Git

One-line commits: `area: short lowercase message` (e.g. `posts: add publish toggle`). No body, no
trailers. Never commit `.dev.vars`, `.env*`, or generated files.
