# Backend: Hono on Cloudflare Workers, D1 + Drizzle, better-auth

The API is a Hono app in `packages/api`. `apps/web` mounts it at `/api/*` inside the TanStack
Start worker (see web.md), so web and API ship as one Worker. Keeping it in a package means a
mobile app or a second client can import `AppType` later without importing the web app.

## packages/api layout

```
packages/api/src/
├─ app.ts                createApp(): basePath, error handler, auth mount, middleware, routers
├─ env.ts                Bindings interface + assertBindings()
├─ errors.ts             errorCodes list, apiError(), unauthorized(), forbidden(), notFound(), invalid()
├─ middleware/
│  ├─ session.ts         better-auth session → c.var.db, c.var.user
│  └─ require.ts         requireUser(c), requireRole(c, "admin")
├─ routes/<resource>.ts  one Hono router per resource
├─ services/<resource>.service.ts (+ .test.ts)
├─ lib/                  small helpers (hashing, etc.)
└─ index.ts              export * from app, env, errors; export type AppEnv
```

`package.json`: `"exports": { ".": "./src/index.ts" }`; tsconfig extends `@app/config/tsconfig.bun.json`.

## app.ts

```ts
import { createAuth } from "@app/auth"
import { createDb } from "@app/db"
import { Hono } from "hono"
import { HTTPException } from "hono/http-exception"
import type { ApiErrorBody } from "./errors"
import { type AppEnv, sessionMiddleware } from "./middleware/session"
import { me } from "./routes/me"
import { posts } from "./routes/posts"

/**
 * Bindings arrive per request through `app.fetch(request, env)`, not a closure,
 * so the app is stateless and can be built once.
 */
export function createApp() {
	return new Hono<AppEnv>()
		.basePath("/api")
		.onError(onError)
		.get("/health", (c) => c.json({ ok: true }))
		// better-auth owns /api/auth/*
		.on(["GET", "POST"], "/auth/*", (c) => createAuth(createDb(c.env.DB), c.env).handler(c.req.raw))
		.use("*", sessionMiddleware)
		.route("/me", me)
		.route("/posts", posts)
}

function onError(error: Error): Response {
	if (error instanceof HTTPException) return error.getResponse()
	console.error(error)
	const body: ApiErrorBody = { code: "invalid_request", message: "Something went wrong" }
	return Response.json(body, { status: 500 })
}

export type AppType = ReturnType<typeof createApp>
```

Chain `.route()` calls in a single expression. `AppType` only carries the routes typed that way.

## env.ts

```ts
import type { AuthEnv } from "@app/auth"
import type { AnyD1Database } from "drizzle-orm/d1"

export interface Bindings extends AuthEnv {
	DB: AnyD1Database
	// KV?: KVNamespace; BUCKET?: R2Bucket; …
}

/** Fails loudly at the edge of the app rather than deep inside a service. */
export function assertBindings(env: Partial<Bindings> | undefined): Bindings {
	const missing = (["DB", "APP_URL", "BETTER_AUTH_SECRET"] as const).filter((k) => !env?.[k])
	if (!env || missing.length > 0) {
		throw new Error(`Missing bindings: ${missing.join(", ")}. Copy apps/web/.dev.vars.example to .dev.vars.`)
	}
	return env as Bindings
}
```

Each package declares the env it needs (`AuthEnv`, …) and `Bindings` extends them.

## errors.ts

```ts
import { HTTPException } from "hono/http-exception"
import type { ContentfulStatusCode } from "hono/utils/http-status"

/** Add to this list rather than inventing a string at a call site. Clients switch on it. */
export const errorCodes = ["unauthorized", "forbidden", "not_found", "invalid_request", "already_exists"] as const
export type ErrorCode = (typeof errorCodes)[number]

export interface ApiErrorBody {
	code: ErrorCode
	message: string
}

export function apiError(status: ContentfulStatusCode, code: ErrorCode, message: string) {
	const body: ApiErrorBody = { code, message }
	return new HTTPException(status, { message, res: Response.json(body, { status }) })
}

export const unauthorized = (m = "Sign in to continue") => apiError(401, "unauthorized", m)
export const forbidden = (m = "You don't have access to this") => apiError(403, "forbidden", m)
export const notFound = (m = "Not found") => apiError(404, "not_found", m)
export const invalid = (m = "That request wasn't valid") => apiError(400, "invalid_request", m)
```

Report a resource that belongs to someone else as `notFound`, not `forbidden`, so ids can't be probed.

## Middleware

```ts
// middleware/session.ts
import { createAuth } from "@app/auth"
import { createDb, type Db, type User } from "@app/db"
import { createMiddleware } from "hono/factory"
import type { Bindings } from "../env"

export interface AppEnv {
	Bindings: Bindings
	Variables: { db: Db; user: User | null }
}

/** Never rejects: routes say what they need with requireUser(), so public routes stay public. */
export const sessionMiddleware = createMiddleware<AppEnv>(async (c, next) => {
	const db = createDb(c.env.DB)
	c.set("db", db)
	c.set("user", null)

	const session = await createAuth(db, c.env).api.getSession({ headers: c.req.raw.headers })
	if (session?.user) c.set("user", session.user as unknown as User)

	await next()
})
```

```ts
// middleware/require.ts
export function requireUser(c: Context<AppEnv>): User {
	const user = c.get("user")
	if (!user) throw unauthorized()
	return user
}
```

Clients that aren't users (devices, webhooks) get their own middleware with their own
`requireX(c)`. They never get a better-auth session.

## Routes and services

```ts
// routes/posts.ts
import { zValidator } from "@hono/zod-validator"
import { createPostSchema } from "@app/core"
import { Hono } from "hono"
import { requireUser } from "../middleware/require"
import type { AppEnv } from "../middleware/session"
import { createPost, listPosts } from "../services/posts.service"

export const posts = new Hono<AppEnv>()
	.get("/", async (c) => {
		const user = requireUser(c)
		return c.json({ posts: await listPosts(c.get("db"), user.id) })
	})
	.post("/", zValidator("json", createPostSchema), async (c) => {
		const user = requireUser(c)
		return c.json(await createPost(c.get("db"), user.id, c.req.valid("json")), 201)
	})
```

- Validate every body, query and param with `zValidator`, using schemas from `@app/core`.
- Routes do auth, validation and response shape. Logic goes in services.
- Services are plain functions with `db` (and `env` if needed) as explicit arguments. They
  return view objects, never raw rows containing secrets or hashes.

## packages/db (Drizzle on D1)

```
packages/db/
├─ src/schema/<group>.ts   one file per table group
├─ src/schema/auth.ts      GENERATED by better-auth CLI, don't hand-edit
├─ src/schema/index.ts
├─ src/client.ts           Db type + createDb(d1)
├─ src/types.ts            $inferSelect / $inferInsert exports
├─ src/testing.ts          createTestDb()
├─ src/seed.ts             writes seed.sql (gitignored)
├─ migrations/             GENERATED by drizzle-kit
└─ drizzle.config.ts       dialect sqlite, schema ./src/schema/index.ts, out ./migrations, strict
```

Exports: `"."`, `"./schema"`, `"./testing"`.

```ts
// client.ts
import { type AnyD1Database, drizzle } from "drizzle-orm/d1"
import type { BaseSQLiteDatabase } from "drizzle-orm/sqlite-core"
import * as schema from "./schema"

/** The async SQLite base type, not DrizzleD1Database, so tests can pass an in-memory db. */
export type Db = BaseSQLiteDatabase<"async", unknown, typeof schema>

export function createDb(d1: AnyD1Database): Db {
	return drizzle(d1, { schema })
}
```

Column conventions (SQLite):

```ts
id: text("id").primaryKey().$defaultFn(() => newId()),
ownerId: text("owner_id").notNull().references(() => user.id, { onDelete: "cascade" }),
isActive: integer("is_active", { mode: "boolean" }).notNull().default(false),
settings: text("settings", { mode: "json" }).$type<Record<string, unknown>>(),
createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().$defaultFn(() => new Date()),
updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().$defaultFn(() => new Date()),
```

- Text ids from `newId()` in `@app/core` (`crypto.getRandomValues`, 21 URL-safe chars).
- snake_case columns, camelCase fields. Index foreign keys you filter on.
- Store secrets hashed (SHA-256 via Web Crypto), compare with a timing-safe equal.

Workflow: edit schema → `bun db:generate --name <slug>` → `bun db:migrate:local` → tests →
`bun db:migrate:remote` on deploy.

### Testing with the real migrations

```ts
// testing.ts
import { Database } from "bun:sqlite"
import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { drizzle } from "drizzle-orm/sqlite-proxy"
import type { Db } from "./client"
import * as schema from "./schema"

const MIGRATIONS = fileURLToPath(new URL("../migrations/", import.meta.url))

/** In-memory SQLite with the shipped migrations, wrapped so services see the same async Db. */
export function createTestDb(): Db & { close: () => void } {
	const sqlite = new Database(":memory:")
	sqlite.exec("PRAGMA foreign_keys = ON")
	for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
		for (const stmt of readFileSync(`${MIGRATIONS}${file}`, "utf8").split("--> statement-breakpoint")) {
			if (stmt.trim()) sqlite.exec(stmt)
		}
	}
	const db = drizzle(
		async (query, params, method) => {
			const stmt = sqlite.query(query)
			const values = params as never[]
			if (method === "run") {
				stmt.run(...values)
				return { rows: [] }
			}
			const rows = stmt.values(...values)
			// `get` must return something falsy on no match, or findFirst always "hits".
			if (method === "get") return { rows: rows[0] as never }
			return { rows }
		},
		{ schema },
	)
	return Object.assign(db, { close: () => sqlite.close() })
}
```

Service tests: `beforeEach` creates a db and seeds rows, `afterEach` calls `db.close()`. Test
behaviour and access boundaries, e.g. that another owner's row counts as missing and that
secrets never appear in the returned view.

## packages/auth (better-auth)

```
packages/auth/src/
├─ env.ts       AuthEnv: BETTER_AUTH_SECRET, APP_URL (the web origin), provider keys
├─ server.ts    createAuth(db, env)
├─ client.ts    browser client (better-auth/react)
└─ index.ts
```

Exports: `"."` (server), `"./client"` (browser). The browser only ever imports `./client`.

```ts
// server.ts
import { newId } from "@app/core"
import { account, type Db, session, user, verification } from "@app/db"
import { betterAuth } from "better-auth"
import { drizzleAdapter } from "better-auth/adapters/drizzle"
import type { AuthEnv } from "./env"

/** One instance per request: D1 and secrets only exist inside a fetch handler. */
export function createAuth(db: Db, env: AuthEnv) {
	return betterAuth({
		appName: "App",
		secret: env.BETTER_AUTH_SECRET,
		baseURL: env.APP_URL,
		basePath: "/api/auth",
		trustedOrigins: [env.APP_URL],
		database: drizzleAdapter(db, { provider: "sqlite", schema: { user, session, account, verification } }),
		socialProviders: {
			google: { clientId: env.GOOGLE_CLIENT_ID, clientSecret: env.GOOGLE_CLIENT_SECRET },
		},
		advanced: { database: { generateId: () => newId() } },
		// databaseHooks.user.create.before/after for allowlists, default records, etc.
	})
}
```

Regenerating the auth tables: point a temporary config at `createAuth({} as never, …)` and run
`bunx @better-auth/cli generate`, write the output to `packages/db/src/schema/auth.ts`, then
`bun db:generate`.

```ts
// client.ts
import { createAuthClient as createBetterAuthClient } from "better-auth/react"

/** No baseURL: app and API share an origin, so relative requests work in every environment. */
export function createAuthClient() {
	return createBetterAuthClient({ basePath: "/api/auth" })
}
```

Check the better-auth docs for the current API before wiring plugins. It moves between releases.

## Cloudflare config (apps/web)

`wrangler.toml` is the single config: `@cloudflare/vite-plugin` reads it for `vite dev`,
`vite build` and `wrangler deploy`, so dev runs the same workerd with the same bindings.

```toml
#:schema node_modules/wrangler/config-schema.json
name = "app"
main = "@tanstack/react-start/server-entry"
compatibility_date = "2026-08-01"
compatibility_flags = ["nodejs_compat"]

[assets]
directory = "./dist/client"
not_found_handling = "none"

# Non-secret config. .dev.vars overrides locally.
[vars]
APP_URL = "https://example.com"

[[d1_databases]]
binding = "DB"
database_name = "app-db"
database_id = "<from `wrangler d1 create app-db`>"
migrations_dir = "../../packages/db/migrations"

# Secrets (never here): wrangler secret put BETTER_AUTH_SECRET / GOOGLE_CLIENT_SECRET / …
```

apps/web scripts:

```json
"dev": "vite dev --port 3000",
"build": "vite build",
"db:migrate:local": "wrangler d1 migrations apply app-db --local --config wrangler.toml",
"db:migrate:remote": "wrangler d1 migrations apply app-db --remote --config wrangler.toml",
"db:seed:local": "wrangler d1 execute app-db --local --config wrangler.toml --file=../../packages/db/seed.sql",
"types": "wrangler types",
"postinstall": "wrangler types",
"check-types": "tsc --noEmit",
"deploy": "vite build && wrangler deploy"
```

- `worker-configuration.d.ts` is generated by `wrangler types` and gitignored. Rerun it after editing `wrangler.toml`.
- Secrets: `apps/web/.dev.vars` locally (commit a `.dev.vars.example` that says where each value
  comes from). In production, `wrangler secret put NAME`. Document secret names as comments in `wrangler.toml`.
- `APP_URL` must equal the browser origin exactly (`http://localhost:3000` in dev). better-auth
  builds the Google callback from it: register `<APP_URL>/api/auth/callback/google`.
- Read bindings with a `bindings()` helper built on `cloudflare:workers`, always inside a handler
  or server function, never at module scope:

```ts
// apps/web/src/server/bindings.ts
import { env } from "cloudflare:workers"
import { assertBindings, type Bindings } from "@app/api"

export function bindings(): Bindings {
	return assertBindings(env as Partial<Bindings>)
}
```

- Use `@cloudflare/vite-plugin`, not Nitro's `cloudflare_module` preset. Nitro's dev emulation dies
  on CJS-only deps in the SSR graph, needs a second build/deploy path, and doesn't populate
  `process.env` without extra flags. The plugin gives one dev command and the same runtime everywhere.
- Add KV, R2 and Durable Objects as `wrangler.toml` bindings plus fields on `Bindings`. A Durable
  Object class is either exported from the worker entry or shipped as a small sibling worker
  bound by service binding.
- Don't use in-process state (EventEmitters, module-level caches) for cross-request coordination:
  isolates don't share memory. Poll with `refetchInterval` first, move to a Durable Object when that's not enough.
