# Web: TanStack Start on Cloudflare

## apps/web layout

```
apps/web/
├─ src/
│  ├─ routes/
│  │  ├─ __root.tsx              document shell, ToastProvider, ConfirmDialog, devtools
│  │  ├─ _authed.tsx             session guard + app context + DashboardShell
│  │  ├─ _authed/index.tsx       thin pages: PageHeader + a feature component
│  │  ├─ _authed/<page>.tsx
│  │  ├─ login.tsx
│  │  └─ api.$.ts                catch-all → Hono
│  ├─ features/<name>/
│  │  ├─ api/                    hc calls (and rare server functions). No React
│  │  ├─ data/                   queryOptions + types. No JSX
│  │  ├─ hooks/                  use<Name>() queries, use<Name>Mutations()
│  │  ├─ components/             kebab-case files: <name>-manager.tsx, <name>-form-dialog.tsx
│  │  ├─ lib/                    constants, nav, context providers
│  │  └─ index.ts                the only import surface for routes and other features
│  ├─ components/
│  │  ├─ ui/                     coss ui primitives (generated; treat as a library)
│  │  └─ confirm/                confirm-store.ts + confirm-dialog.tsx
│  ├─ hooks/                     cross-cutting hooks (use-media-query.ts)
│  ├─ lib/
│  │  ├─ api/                    client.ts, transport.server.ts, errors.ts
│  │  ├─ auth-client.ts          better-auth browser client
│  │  ├─ notify.ts
│  │  └─ utils.ts                cn()
│  ├─ server/bindings.ts         see backend.md
│  ├─ router.tsx
│  ├─ routeTree.gen.ts           GENERATED
│  └─ styles.css                 Tailwind + coss theme variables
├─ public/
├─ components.json               shadcn config with the @coss registry
├─ wrangler.toml                 see backend.md
├─ .dev.vars.example
├─ vite.config.ts
└─ tsconfig.json                 paths "@/*" → "./src/*"
```

Rules:

- **Routes are thin.** A page is `head` + `PageHeader` + one feature component. Loaders and guards call feature `data/` or `api/`. No business logic in routes.
- **Features import each other only through `index.ts`.** Shared cross-feature context (current user or org) lives in the feature that owns it (`features/auth/lib/session-context.tsx`).
- **Generic UI goes in `components/`.** Domain UI goes in `features/<name>/components/`. Never rebuild a button, dialog or input that coss ui already has.
- **Platform-agnostic code goes in `packages/core`:** Zod schemas, enums, constants, pure helpers.

## vite.config.ts

```ts
import { cloudflare } from "@cloudflare/vite-plugin"
import tailwindcss from "@tailwindcss/vite"
import { devtools } from "@tanstack/devtools-vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
	resolve: { tsconfigPaths: true },
	plugins: [
		devtools(),
		// Runs SSR in real workerd during `vite dev` with wrangler.toml bindings and .dev.vars.
		cloudflare({ viteEnvironment: { name: "ssr" } }),
		tailwindcss(),
		tanstackStart(),
		viteReact(),
	],
})
```

## router.tsx

```ts
import { QueryClient } from "@tanstack/react-query"
import { createRouter as createTanStackRouter } from "@tanstack/react-router"
import { setupRouterSsrQueryIntegration } from "@tanstack/react-router-ssr-query"
import { routeTree } from "./routeTree.gen"

export function getRouter() {
	const queryClient = new QueryClient({
		defaultOptions: { queries: { staleTime: 60_000 } },
	})

	const router = createTanStackRouter({
		routeTree,
		context: { queryClient },
		scrollRestoration: true,
		defaultPreload: "intent",
		defaultPreloadStaleTime: 0,
	})

	// Dehydrates the query cache across SSR and provides QueryClientProvider per request.
	setupRouterSsrQueryIntegration({ router, queryClient })

	return router
}

declare module "@tanstack/react-router" {
	interface Register {
		router: ReturnType<typeof getRouter>
	}
}
```

## __root.tsx

```tsx
import type { QueryClient } from "@tanstack/react-query"
import { createRootRouteWithContext, HeadContent, Scripts } from "@tanstack/react-router"
import { TanStackRouterDevtoolsPanel } from "@tanstack/react-router-devtools"
import { TanStackDevtools } from "@tanstack/react-devtools"
import { ConfirmDialog } from "@/components/confirm/confirm-dialog"
import { ToastProvider } from "@/components/ui/toast"
import appCss from "../styles.css?url"

export interface RouterContext {
	queryClient: QueryClient
}

export const Route = createRootRouteWithContext<RouterContext>()({
	head: () => ({
		meta: [
			{ charSet: "utf-8" },
			{ name: "viewport", content: "width=device-width, initial-scale=1" },
			{ title: "App" },
		],
		links: [{ rel: "stylesheet", href: appCss }],
	}),
	shellComponent: RootDocument,
})

function RootDocument({ children }: { children: React.ReactNode }) {
	return (
		<html lang="en">
			<head>
				<HeadContent />
			</head>
			<body>
				<ToastProvider>
					{children}
					<ConfirmDialog />
				</ToastProvider>
				<TanStackDevtools
					config={{ position: "bottom-right" }}
					plugins={[{ name: "TanStack Router", render: <TanStackRouterDevtoolsPanel /> }]}
				/>
				<Scripts />
			</body>
		</html>
	)
}
```

## Mounting Hono

```ts
// src/routes/api.$.ts
import { createApp } from "@app/api"
import { createFileRoute } from "@tanstack/react-router"
import type {} from "@tanstack/react-start" // adds `server` to route options
import { bindings } from "@/server/bindings"

function handler({ request }: { request: Request }) {
	return createApp().fetch(request, bindings())
}

export const Route = createFileRoute("/api/$")({
	server: { handlers: { GET: handler, POST: handler, PUT: handler, PATCH: handler, DELETE: handler } },
})
```

## One data path: the isomorphic hc client

All data goes through Hono. In the browser the client uses real HTTP. During SSR it calls the Hono
app in-process and forwards the page's cookie, so loaders skip a round trip and see exactly what
the browser would. Use `createServerFn` only for things that are SSR-only by nature.

```ts
// lib/api/transport.server.ts
import "@tanstack/react-start/server-only"
import { createApp } from "@app/api"
import { getRequest } from "@tanstack/react-start/server"
import { bindings } from "@/server/bindings"

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
// lib/api/client.ts
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
// lib/api/errors.ts
import type { ApiErrorBody, ErrorCode } from "@app/api" // type-only

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

/** For notify.error descriptions. */
export function errorMessage(e: unknown): string {
	return e instanceof Error ? e.message : "Something went wrong."
}
```

## Feature slice example

```ts
// features/posts/api/posts.api.ts
import type { CreatePost } from "@app/core"
import type { InferResponseType } from "hono/client"
import { api } from "@/lib/api/client"
import { unwrap } from "@/lib/api/errors"

type PostsResponse = InferResponseType<ReturnType<typeof api>["api"]["posts"]["$get"]>
export type Post = PostsResponse["posts"][number]

export async function fetchPosts(): Promise<Post[]> {
	return (await unwrap(await api().api.posts.$get())).posts
}

export const createPost = async (input: CreatePost) =>
	unwrap(await api().api.posts.$post({ json: input }))

export const updatePost = async (id: string, input: CreatePost) =>
	unwrap(await api().api.posts[":id"].$patch({ param: { id }, json: input }))

export const deletePost = async (id: string) =>
	unwrap(await api().api.posts[":id"].$delete({ param: { id } }))
```

```ts
// features/posts/data/posts.ts
import { queryOptions } from "@tanstack/react-query"
import { fetchPosts } from "@/features/posts/api/posts.api"

export const postsKey = ["posts"] as const

export function postsQueryOptions() {
	return queryOptions({ queryKey: postsKey, queryFn: fetchPosts })
}
```

```ts
// features/posts/hooks/use-posts.ts
import type { CreatePost } from "@app/core"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { createPost, deletePost, updatePost } from "@/features/posts/api/posts.api"
import { postsKey, postsQueryOptions } from "@/features/posts/data/posts"

export function usePosts() {
	return useQuery(postsQueryOptions())
}

/** Every mutation invalidates the same list, so they share one hook. */
export function usePostMutations() {
	const qc = useQueryClient()
	const invalidate = () => qc.invalidateQueries({ queryKey: postsKey })

	const create = useMutation({ mutationFn: createPost, onSuccess: invalidate })
	const update = useMutation({
		mutationFn: ({ id, input }: { id: string; input: CreatePost }) => updatePost(id, input),
		onSuccess: invalidate,
	})
	const remove = useMutation({ mutationFn: deletePost, onSuccess: invalidate })

	return { create, update, remove }
}
```

```ts
// features/posts/index.ts
export { PostsManager } from "@/features/posts/components/posts-manager"
export { postsQueryOptions } from "@/features/posts/data/posts"
```

- Derive types from routes with `InferResponseType`. Don't redeclare them.
- Query keys start with the resource name, then scope ids: `["posts", orgId]`.
- To prefetch on the server, a route `loader` calls `context.queryClient.ensureQueryData(postsQueryOptions())`, and the component calls `useQuery` with the same options.

## Auth

The API exposes `GET /api/me` → `{ user: { id, email, name, image } | null }` (it reads `c.var.user`).

```ts
// lib/auth-client.ts
import { createAuthClient } from "@app/auth/client"
export const authClient = createAuthClient()
```

```ts
// features/auth/data/session.ts
import { queryOptions } from "@tanstack/react-query"
import { api } from "@/lib/api/client"
import { unwrap } from "@/lib/api/errors"

export type SessionUser = { id: string; email: string; name: string; image: string | null }

export const sessionKey = ["session"] as const

export function sessionQueryOptions() {
	return queryOptions({
		queryKey: sessionKey,
		queryFn: async () => (await unwrap(await api().api.me.$get())) as { user: SessionUser | null },
		staleTime: 5 * 60_000,
	})
}
```

```ts
// features/auth/api/auth.ts
import { authClient } from "@/lib/auth-client"

export async function signInWithGoogle(next = "/") {
	await authClient.signIn.social({ provider: "google", callbackURL: next })
}

export async function signOut() {
	await authClient.signOut()
}
```

```tsx
// routes/_authed.tsx
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router"
import { SessionProvider, sessionQueryOptions } from "@/features/auth"
import { DashboardShell } from "@/features/dashboard"

export const Route = createFileRoute("/_authed")({
	beforeLoad: async ({ context, location }) => {
		const { user } = await context.queryClient.ensureQueryData(sessionQueryOptions())
		if (!user) throw redirect({ to: "/login", search: { next: location.href } })
		return { user }
	},
	loader: ({ context }) => ({ user: context.user }),
	component: AuthedLayout,
})

function AuthedLayout() {
	const { user } = Route.useLoaderData()
	return (
		<SessionProvider value={{ user }}>
			<DashboardShell>
				<Outlet />
			</DashboardShell>
		</SessionProvider>
	)
}
```

- `SessionProvider` / `useSession()` is a plain React context in `features/auth/lib/session-context.tsx`. It throws if used outside the provider. Extend it with the active org and role when the app has them, and load those in the `_authed` loader.
- `/login` checks for a user in `beforeLoad` and redirects to `next` if one is found. `validateSearch` types `?next=` and `?error=`.
- On sign-out, call `signOut()`, then `queryClient.clear()`, then `navigate({ to: "/login" })`.
- Role gates, such as a non-admin landing on an admin dashboard, happen in the `_authed` loader and redirect to a `/no-access` page.

## Pages

```tsx
// routes/_authed/posts.tsx
import { createFileRoute } from "@tanstack/react-router"
import { PageHeader } from "@/features/dashboard"
import { PostsManager } from "@/features/posts"

export const Route = createFileRoute("/_authed/posts")({
	head: () => ({ meta: [{ title: "Posts · App" }] }),
	component: () => (
		<>
			<PageHeader title="Posts" description="Everything your team has published" />
			<PostsManager />
		</>
	),
})
```

Nested sections (e.g. `/_authed/projects/$slug/*`) get their own layout route. The sidebar can
swap to a section nav when the param is present (see ui.md).

## Testing

- `bun test` for `packages/*`. API service tests run against the in-memory D1 replica (see backend.md).
- For web hooks and components, use Vitest + Testing Library + jsdom only once a feature needs it.
- Verify changes by exercising them: run `bun dev:web`, curl `/api/...`, click through the page. Type-checking alone isn't enough.
