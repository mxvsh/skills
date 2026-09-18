# Edge Functions with a shared toolkit

Every function repeats the same work: CORS preflight, auth, body parsing and validation, error
responses, clients, env checks, and calls to the same third-party APIs. That work lives **once**
in `supabase/functions/_shared/`. A function file contains only its own logic, usually 20–60 lines.

```
supabase/functions/
├── _shared/
│   ├── handler.ts           handler(): OPTIONS, auth mode, body validation, errors → JSON
│   ├── http.ts              corsHeaders, json(), HttpError + shortcuts (badRequest, notFound…)
│   ├── env.ts               env('NAME') that throws if missing, optionalEnv()
│   ├── clients.ts           userClient(req), adminClient() (service role, memoised)
│   ├── auth.ts              getUser(req), checkWebhookSecret(req)
│   ├── database.types.ts    GENERATED, same as the app's types
│   ├── push.ts              sendPush(tokens, message): Expo push, batched
│   ├── storage.ts           presignPut(key), publicUrl(key): R2/S3 SigV4, written once
│   ├── ai.ts                chat(), json(): one OpenAI/OpenRouter client + observability
│   └── analytics.ts         capture(): PostHog HTTP capture, fire-and-forget
├── _templates/deno.json     copied into each new function
└── <function-name>/
    ├── index.ts             Deno.serve(handler({ … }, async (ctx) => …))
    └── deno.json
```

Rules:

- Anything used by two functions moves to `_shared/`. The second copy is the signal.
- `_shared/` modules are small and single-purpose. No barrel file: import exactly what you use, which keeps cold starts small.
- Functions never read `Deno.env` directly, never build CORS headers, and never hand-roll `new Response(JSON.stringify(…))`.
- Integrations (push, storage, AI, email, payments) are wrapped once in `_shared/` with typed inputs, so switching providers means changing one file.

## deno.json

Each function directory needs one. Keep a template and copy it:

```json
{
	"imports": {
		"@supabase/functions-js": "jsr:@supabase/functions-js@^2",
		"@supabase/supabase-js": "npm:@supabase/supabase-js@^2",
		"zod": "npm:zod@^4"
	}
}
```

```sh
supabase functions new follow-user
cp supabase/functions/_templates/deno.json supabase/functions/follow-user/deno.json
```

Imports used by `_shared/` must be present in every function's `deno.json`, which is why the
template carries them all.

## _shared/http.ts

```ts
export const corsHeaders = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-webhook-secret',
	'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

export function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { ...corsHeaders, 'Content-Type': 'application/json' },
	})
}

/** Throw anywhere in a function; handler() turns it into { error, code } with this status. */
export class HttpError extends Error {
	constructor(readonly status: number, message: string, readonly code = 'error') {
		super(message)
	}
}

export const badRequest = (m = 'Invalid request') => new HttpError(400, m, 'bad_request')
export const unauthorized = (m = 'Not authenticated') => new HttpError(401, m, 'unauthorized')
export const forbidden = (m = 'Not allowed') => new HttpError(403, m, 'forbidden')
export const notFound = (m = 'Not found') => new HttpError(404, m, 'not_found')
export const conflict = (m = 'Already exists') => new HttpError(409, m, 'conflict')
```

## _shared/env.ts

```ts
/** Required config: fails the request with a clear log instead of a confusing downstream error. */
export function env(name: string): string {
	const value = Deno.env.get(name)
	if (!value) throw new Error(`Missing env ${name}. Set it with: supabase secrets set ${name}=…`)
	return value
}

export function optionalEnv(name: string, fallback = ''): string {
	return Deno.env.get(name) ?? fallback
}
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform.
Everything else is set with `supabase secrets set`.

## _shared/clients.ts

```ts
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types.ts'
import { env } from './env.ts'

export type Db = SupabaseClient<Database>

/** Acts as the caller: RLS applies. Use this by default. */
export function userClient(req: Request): Db {
	return createClient<Database>(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
		global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
		auth: { persistSession: false },
	})
}

let admin: Db | null = null

/** Service role: bypasses RLS. Only for work the caller isn't allowed to do directly. */
export function adminClient(): Db {
	admin ??= createClient<Database>(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
		auth: { persistSession: false },
	})
	return admin
}
```

## _shared/auth.ts

```ts
import type { User } from '@supabase/supabase-js'
import type { Db } from './clients.ts'
import { forbidden, unauthorized } from './http.ts'
import { env } from './env.ts'

export async function getUser(db: Db): Promise<User> {
	const { data: { user } } = await db.auth.getUser()
	if (!user) throw unauthorized()
	return user
}

/** For DB triggers / webhooks: they send no JWT, so they prove themselves with a shared secret. */
export function checkWebhookSecret(req: Request): void {
	if (req.headers.get('x-webhook-secret') !== env('WEBHOOK_SECRET')) throw forbidden('Bad webhook secret')
}
```

## _shared/handler.ts

```ts
import '@supabase/functions-js/edge-runtime.d.ts'
import type { User } from '@supabase/supabase-js'
import type { z } from 'zod'
import { checkWebhookSecret, getUser } from './auth.ts'
import { adminClient, type Db, userClient } from './clients.ts'
import { badRequest, corsHeaders, HttpError, json } from './http.ts'

type Auth = 'user' | 'webhook' | 'public'

interface BaseCtx {
	req: Request
	/** RLS-scoped client for the caller (anon for public/webhook). */
	db: Db
	/** Service-role client. Reach for it only when RLS must be bypassed. */
	admin: () => Db
}

type Ctx<A extends Auth, B> = BaseCtx & { body: B } & (A extends 'user' ? { user: User } : { user: null })

interface Options<A extends Auth, S extends z.ZodType | undefined> {
	auth: A
	/** Validates the JSON body; the parsed value arrives as ctx.body. */
	body?: S
}

/**
 * Wraps a function body with everything every function needs: preflight, auth,
 * body validation, and turning thrown errors into JSON. Return a plain value to
 * send it as JSON, or a Response for anything else (streams, redirects).
 */
export function handler<A extends Auth, S extends z.ZodType | undefined = undefined>(
	options: Options<A, S>,
	fn: (ctx: Ctx<A, S extends z.ZodType ? z.infer<S> : undefined>) => Promise<unknown>,
) {
	return async (req: Request): Promise<Response> => {
		if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

		try {
			if (options.auth === 'webhook') checkWebhookSecret(req)

			const db = userClient(req)
			const user = options.auth === 'user' ? await getUser(db) : null

			let body: unknown
			if (options.body) {
				const raw = await req.json().catch(() => {
					throw badRequest('Body must be JSON')
				})
				const parsed = options.body.safeParse(raw)
				if (!parsed.success) throw badRequest(parsed.error.issues[0]?.message ?? 'Invalid body')
				body = parsed.data
			}

			const result = await fn({ req, db, admin: adminClient, user, body } as never)
			return result instanceof Response ? result : json(result ?? { ok: true })
		} catch (e) {
			if (e instanceof HttpError) return json({ error: e.message, code: e.code }, e.status)
			console.error(`[${new URL(req.url).pathname}]`, e)
			return json({ error: 'Something went wrong', code: 'internal' }, 500)
		}
	}
}
```

## A function, before and after

Without the toolkit, each function carries about 40 lines of boilerplate. With it:

```ts
// supabase/functions/follow-user/index.ts
import { z } from 'zod'
import { handler } from '../_shared/handler.ts'
import { badRequest, HttpError } from '../_shared/http.ts'
import { sendPush } from '../_shared/push.ts'

const Body = z.object({ userId: z.uuid() })

Deno.serve(
	handler({ auth: 'user', body: Body }, async ({ user, body, admin }) => {
		if (body.userId === user.id) throw badRequest("You can't follow yourself")

		const { error } = await admin().from('follows').insert({ follower_id: user.id, following_id: body.userId })
		if (error && error.code !== '23505') throw new HttpError(500, error.message)

		const { data: tokens } = await admin().from('device_tokens').select('token').eq('user_id', body.userId)
		await sendPush(tokens?.map((t) => t.token) ?? [], {
			title: 'New follower',
			body: `${user.user_metadata.full_name ?? 'Someone'} followed you`,
			data: { type: 'new_follower' },
		})

		return { ok: true }
	}),
)
```

Trigger-invoked:

```ts
Deno.serve(
	handler({ auth: 'webhook', body: z.object({ record: z.object({ id: z.uuid(), image_keys: z.array(z.string()) }) }) },
		async ({ body }) => {
			await deleteObjects(body.record.image_keys)   // _shared/storage.ts
			return { deleted: body.record.image_keys.length }
		}),
)
```

## Shared integrations

Write each integration once, with a typed surface and env read inside:

```ts
// _shared/push.ts: Expo push service, batched by 100
export interface PushMessage { title: string; body: string; data?: Record<string, string> }

export async function sendPush(tokens: string[], message: PushMessage): Promise<void> {
	for (let i = 0; i < tokens.length; i += 100) {
		const batch = tokens.slice(i, i + 100).map((to) => ({ to, sound: 'default', ...message }))
		await fetch('https://exp.host/--/api/v2/push/send', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(batch),
		}).catch((e) => console.error('[push]', e))
	}
}
```

- **`storage.ts`:** `presignPut(key, ttl)`, `publicUrl(key)`, `deleteObjects(keys)`. SigV4 signing lives here, not in each upload function. Key prefixes come from one `keyFor(kind, userId)` map.
- **`ai.ts`:** one client (base URL, key, default model), `chat(messages, opts)`, and `json(schema, prompt)` that validates the model's output with Zod. It records tokens and latency through `analytics.ts`.
- **`analytics.ts`:** `capture(distinctId, event, props)`, fire-and-forget, a no-op when the token isn't set.
- **Dates, time zones, pagination, rate limits:** also `_shared/` helpers with plain functions and no side effects.

## Types in functions

Generate the same types into `_shared` so functions get typed queries too:

```json
"sb:types": "supabase gen types typescript --project-id <ref> --schema public > src/types/database.types.ts && cp src/types/database.types.ts supabase/functions/_shared/database.types.ts"
```

## config.toml

```toml
[functions.follow-user]
verify_jwt = true          # auth: 'user'

[functions.delete-post-images]
verify_jwt = false         # auth: 'webhook': no JWT, checked by x-webhook-secret

[functions.search-places]
verify_jwt = false         # auth: 'public'
```

Keep `verify_jwt` in line with the handler's `auth` mode. The gateway check and the handler check back each other up.

## Calling from the app

Only from repositories:

```ts
export async function followUser(userId: string): Promise<void> {
	const { error } = await supabase.functions.invoke('follow-user', { body: { userId } })
	if (error) throw error
}
```

## Deploy and secrets

```sh
supabase secrets set WEBHOOK_SECRET=$(openssl rand -hex 32) OPENROUTER_API_KEY=…
supabase functions deploy follow-user
supabase functions serve        # local, with supabase start
```

Store the webhook secret in Vault too, so SQL triggers (`pg_net`) can send it in `x-webhook-secret` without the value appearing in migrations.
