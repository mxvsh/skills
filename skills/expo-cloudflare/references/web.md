# Web: TanStack Start on Cloudflare

## apps/web layout

```
apps/web/
├─ src/
│  ├─ routes/
│  │  ├─ __root.tsx
│  │  ├─ index.tsx
│  │  ├─ login.tsx
│  │  ├─ _app.tsx             authenticated layout (session guard)
│  │  ├─ _app/<page>.tsx
│  │  └─ api.$.ts             catch-all → Hono
│  ├─ features/<name>/
│  │  ├─ api/<name>.api.ts    HTTP via hc. No React
│  │  ├─ data/<name>.queries.ts  queryOptions + mutations. No JSX
│  │  ├─ data/<name>.store.ts    Zustand for UI-only state
│  │  ├─ ui/*.tsx             components; read data/ only; primitives from @app/ui
│  │  └─ index.ts             the only import surface for routes and other features
│  ├─ shared/api/
│  │  ├─ client.ts            isomorphic hc client
│  │  ├─ transport.server.ts  in-process fetch for SSR
│  │  ├─ errors.ts            ApiError + unwrap()
│  │  ├─ query-client.ts
│  │  └─ index.ts
│  ├─ shared/lib/
│  ├─ server/bindings.ts      see backend.md
│  ├─ router.tsx
│  ├─ routeTree.gen.ts        GENERATED
│  └─ styles.css              imports tailwind + @app/tokens/tokens.css + @app/ui/styles.css
├─ public/
├─ wrangler.toml
├─ .dev.vars.example
├─ vite.config.ts
└─ tsconfig.json              extends @app/config/tsconfig.react.json, includes worker-configuration.d.ts
```

Rules:

- Routes stay thin: loaders call feature `data/`, components compose feature `ui/`. No business logic.
- Features import each other only through `index.ts`. Base features can be shared; leaf features are imported only by routes.
- Generic components go in `packages/ui`, not in a feature's `ui/`.

## vite.config.ts

```ts
import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
	resolve: { tsconfigPaths: true },
	server: {
		// Phones and emulators on the LAN must reach the dev API. Dev only.
		host: true,
		allowedHosts: [".local", "host.docker.internal"],
	},
	plugins: [
		// Runs SSR in real workerd during `vite dev`, with wrangler.toml bindings and .dev.vars.
		cloudflare({ viteEnvironment: { name: "ssr" } }),
		tailwindcss(),
		tanstackStart(),
		viteReact(),
	],
})
```

Use `@cloudflare/vite-plugin`, not Nitro's Cloudflare preset: Nitro's dev emulation breaks on
CJS-only deps in the SSR graph. With the plugin there is one dev command (`vite dev --port 3000`)
and dev, preview and production run the same runtime.

## Mounting Hono

```ts
// src/routes/api.$.ts
import { createApp } from "@app/api"
import { createFileRoute } from "@tanstack/react-router"
import type {} from "@tanstack/react-start" // adds `server` to route options
import { bindings } from "#/server/bindings"

function handler({ request }: { request: Request }) {
	return createApp().fetch(request, bindings())
}

export const Route = createFileRoute("/api/$")({
	server: { handlers: { GET: handler, POST: handler, PUT: handler, PATCH: handler, DELETE: handler } },
})
```

## One data path: the isomorphic hc client

All data goes through Hono. In the browser the client uses real HTTP. During SSR it calls the Hono
app in-process and forwards the page's cookie, so loaders skip a network round trip.

```ts
// shared/api/transport.server.ts
import "@tanstack/react-start/server-only"
import { createApp } from "@app/api"
import { getRequest } from "@tanstack/react-start/server"
import { bindings } from "#/server/bindings"

export function serverOrigin(): string {
	return new URL(getRequest().url).origin
}

export async function serverFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
	const request = new Request(input, init)
	const cookie = getRequest().headers.get("cookie")
	if (cookie) request.headers.set("cookie", cookie)
	return createApp().fetch(request, bindings())
}
```

```ts
// shared/api/client.ts
import type { AppType } from "@app/api"
import { createIsomorphicFn } from "@tanstack/react-start"
import { hc } from "hono/client"
import { serverFetch, serverOrigin } from "./transport.server"

const transport = createIsomorphicFn()
	.server(() => ({ origin: serverOrigin(), fetch: serverFetch }))
	.client(() => ({
		origin: window.location.origin,
		fetch: (input: RequestInfo | URL, init?: RequestInit) =>
			globalThis.fetch(input, { ...init, credentials: "include" }),
	}))

/** Call per use; on the server it's bound to the request being rendered. */
export function api() {
	const { origin, fetch } = transport()
	return hc<AppType>(origin, { fetch })
}
```

```ts
// shared/api/errors.ts
import type { ApiErrorBody, ErrorCode } from "@app/api" // type-only: keeps server code out of the bundle

export class ApiError extends Error {
	readonly code: ErrorCode
	readonly status: number
	constructor(body: ApiErrorBody, status: number) {
		super(body.message)
		this.name = "ApiError"
		this.code = body.code
		this.status = status
	}
}

interface JsonResponse<T> {
	ok: boolean
	status: number
	json: () => Promise<T>
}

type SuccessBody<R> = R extends { ok: true; json: () => Promise<infer B> } ? B : never

/** Every call in a feature's api/ goes through this; nothing downstream inspects a Response. */
export async function unwrap<R extends JsonResponse<unknown>>(response: R): Promise<SuccessBody<R>> {
	if (!response.ok) {
		const body = (await response.json().catch(() => null)) as Partial<ApiErrorBody> | null
		throw typeof body?.code === "string" && typeof body.message === "string"
			? new ApiError(body as ApiErrorBody, response.status)
			: new ApiError({ code: "invalid_request", message: "Something went wrong" }, response.status)
	}
	return response.json() as Promise<SuccessBody<R>>
}
```

## Feature example

```ts
// features/posts/api/posts.api.ts
import type { CreatePost } from "@app/core"
import type { InferResponseType } from "hono/client"
import { api, unwrap } from "#/shared/api"

type PostsResponse = InferResponseType<ReturnType<typeof api>["api"]["posts"]["$get"]>
export type Post = PostsResponse["posts"][number]

export async function fetchPosts(): Promise<Post[]> {
	return (await unwrap(await api().api.posts.$get())).posts
}

export async function createPost(input: CreatePost) {
	return unwrap(await api().api.posts.$post({ json: input }))
}
```

```ts
// features/posts/data/posts.queries.ts
import { queryOptions, useMutation, useQueryClient } from "@tanstack/react-query"
import { createPost, fetchPosts } from "../api/posts.api"

export const postsQueryKey = ["posts"] as const

export function postsQueryOptions() {
	return queryOptions({ queryKey: postsQueryKey, queryFn: fetchPosts })
}

export function useCreatePost() {
	const queryClient = useQueryClient()
	return useMutation({
		mutationFn: createPost,
		onSuccess: () => queryClient.invalidateQueries({ queryKey: postsQueryKey }),
	})
}
```

Derive response types from the route with `InferResponseType` rather than redeclaring them.
Route loaders call `queryClient.ensureQueryData(postsQueryOptions())`, and components use
`useSuspenseQuery` with the same options.

## Auth on web

`createAuthClient()` from `@app/auth/client` (better-auth/react) with `basePath: "/api/auth"` and
no `baseURL`: app and API share an origin. Read the session in the root loader through a server
function, and guard `_app.tsx` in `beforeLoad`.

## packages/ui

- Base UI (`@base-ui-components/react`) primitives, Tailwind v4, `cva` variants, `cn()` = `twMerge(clsx())`.
- Folders: `foundations/`, `overlays/`, `product/`, `lib/cn.ts`, `styles.css`, `index.ts`.
- PascalCase files, one component per file, a `*.stories.tsx` next to it. Build and review in
  Storybook before the app uses a component.
- Tokens only: no raw hex or px.
- One icon set (e.g. Phosphor).
