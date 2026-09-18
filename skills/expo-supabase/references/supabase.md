# Supabase

## Client (lib/supabase.ts)

```ts
import { createClient, type SupabaseClient, type SupabaseClientOptions } from '@supabase/supabase-js'
import * as SecureStore from 'expo-secure-store'
import { Platform } from 'react-native'
import type { Database } from '@/types/database.types'

const secureStorage = {
	getItem: (key: string) => SecureStore.getItemAsync(key),
	setItem: (key: string, value: string) => SecureStore.setItemAsync(key, value),
	removeItem: (key: string) => SecureStore.deleteItemAsync(key),
}

const auth: SupabaseClientOptions<'public'>['auth'] = {
	storage: Platform.OS === 'web' ? undefined : secureStorage,
	autoRefreshToken: true,
	persistSession: true,
	detectSessionInUrl: false,
}

let _client: SupabaseClient<Database> | null = null

function build(): SupabaseClient<Database> {
	const url = process.env.EXPO_PUBLIC_SUPABASE_URL
	const key = process.env.EXPO_PUBLIC_SUPABASE_KEY
	if (!url || !key) {
		throw new Error('Missing EXPO_PUBLIC_SUPABASE_URL or EXPO_PUBLIC_SUPABASE_KEY. Add them to .env.local and restart.')
	}
	return createClient<Database>(url, key, { auth })
}

/** Lazy: built on first use, so a missing env var fails with a clear message instead of at import. */
export const supabase: SupabaseClient<Database> = new Proxy({} as SupabaseClient<Database>, {
	get(_t, prop) {
		if (!_client) _client = build()
		return Reflect.get(_client as object, prop)
	},
})
```

## Auth (features/auth/hooks/use-session.tsx)

A `SessionProvider` context owns the session and every auth action. It's the only place
besides the root layout that calls `supabase.auth.*`.

```tsx
import type { Session } from '@supabase/supabase-js'
import * as AuthSession from 'expo-auth-session'
import * as Linking from 'expo-linking'
import * as WebBrowser from 'expo-web-browser'

WebBrowser.maybeCompleteAuthSession()

const redirectTo = AuthSession.makeRedirectUri({ scheme: '<app-scheme>', path: 'auth-callback' })
```

`consumeAuthRedirect(url)` handles every way a session comes back to the app:

```ts
const consumeAuthRedirect = useCallback(async (url: string): Promise<boolean> => {
	try {
		const u = new URL(url)
		const hash = u.hash.startsWith('#') ? u.hash.slice(1) : ''
		const query = u.search.startsWith('?') ? u.search.slice(1) : u.search
		const params = new URLSearchParams(hash || query)

		const urlError = params.get('error')
		if (urlError) {
			const desc = params.get('error_description')
			toast.error(desc ? decodeURIComponent(desc.replace(/\+/g, ' ')) : 'Something went wrong', 4000)
			return false
		}

		// PKCE: ?code=…
		const code = params.get('code')
		if (code) {
			if (params.get('type') === 'recovery') setRecoveryMode(true)
			const { error } = await supabase.auth.exchangeCodeForSession(code)
			return !error
		}

		// Implicit: #access_token=…&refresh_token=…
		const access_token = params.get('access_token')
		const refresh_token = params.get('refresh_token')
		if (!access_token || !refresh_token) return false
		if (params.get('type') === 'recovery') setRecoveryMode(true)
		const { error } = await supabase.auth.setSession({ access_token, refresh_token })
		return !error
	} catch {
		return false
	}
}, [])
```

On mount: `getSession()` → state, subscribe to `onAuthStateChange` (set the session; on
`PASSWORD_RECOVERY` set `recoveryMode`; identify or reset analytics), and feed
`Linking.getInitialURL()` and `Linking.addEventListener('url')` into `consumeAuthRedirect`.
Clean all three up on unmount.

Actions the provider exposes:

```ts
// OAuth (google | apple): open the provider in an auth session, then consume the redirect
const { data, error } = await supabase.auth.signInWithOAuth({ provider, options: { redirectTo, skipBrowserRedirect: true } })
if (error) throw error
const result = await WebBrowser.openAuthSessionAsync(data.url, redirectTo)
if (result.type === 'success' && result.url) await consumeAuthRedirect(result.url)

// Email OTP
await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: true } })
await supabase.auth.verifyOtp({ email, token, type: 'email' })

// Password
await supabase.auth.signUp({ email, password, options: { data: { full_name }, emailRedirectTo: redirectTo } })
await supabase.auth.signInWithPassword({ email, password })
await supabase.auth.resetPasswordForEmail(email, { redirectTo })
await supabase.auth.updateUser({ password })
```

Sign-out: wait about 300ms (the confirm modal is still closing), `loading.show()`, clear this
device's push token while still authenticated, `signOut()`, and fall back to
`signOut({ scope: 'local' })` on error. Clear the stores in `finally` and hide the loading overlay.

- Add `<app-scheme>://auth-callback` to **Auth → URL Configuration → Redirect URLs** (and to `additional_redirect_urls` in `config.toml` for local development).
- Add an `app/auth-callback.tsx` route that renders nothing, so deep links resolve.
- Every action throws on `error`. Screens catch and call `toast.error(e.message)`.

## Repositories and models

```
data/
├── models/post.ts           app-facing types (camelCase, optional fields) the UI uses
└── repositories/
    ├── profiles.ts          one file per aggregate
    └── posts/               split big aggregates: read.ts, write.ts, mappers.ts, index.ts
```

```ts
// data/repositories/profiles.ts
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type Profile = Database['public']['Tables']['profiles']['Row']

export async function fetchProfile(userId: string): Promise<Profile | null> {
	const { data } = await supabase.from('profiles').select('*').eq('id', userId).maybeSingle()
	return data ?? null
}

/** Writes go through an RPC so protected columns (counts, flags) can't be touched. */
export async function updateProfile(updates: { full_name?: string; username?: string }): Promise<string | null> {
	const { error } = await supabase.rpc('update_profile', {
		...(updates.full_name !== undefined && { p_full_name: updates.full_name }),
		...(updates.username !== undefined && { p_username: updates.username }),
	})
	return error?.message ?? null
}
```

- Row types come from `Database['public']['Tables'][T]['Row']`. Never hand-write DB types.
- Map rows to models in repositories (`toUserSummary(row)`). Hooks and UI never see snake_case rows unless the row type is the model.
- Select only the columns you need. Batch joins with `.in('id', ids)` plus a `Map`, not N+1 queries.
- File uploads: an Edge Function returns a presigned URL, and the client `PUT`s the file straight to storage. Compress images with `expo-image-manipulator` before uploading.
- Call Edge Functions with `supabase.functions.invoke<T>('name', { body })`, and only from repositories. Throw on `error`.

## Cache (stores/cache.ts): offline-first reads

A persisted Zustand store keyed by user id with a TTL per resource. Cached data is **always
shown**. The TTL only decides whether to refetch in the background.

```ts
const TTL = { posts: 5 * 60_000, friends: 10 * 60_000 } as const

interface CacheEntry<T> { data: T; ts: number }

interface CacheStore {
	posts: Record<string, CacheEntry<Post[]>>
	getPosts: (userId: string) => { data: Post[]; stale: boolean } | null
	setPosts: (userId: string, posts: Post[]) => void
	invalidatePosts: (userId: string) => void
}

export const useCacheStore = create<CacheStore>()(
	persist(
		(set, get) => ({
			posts: {},
			getPosts: (userId) => {
				const entry = get().posts[userId]
				if (!entry) return null
				return { data: entry.data, stale: Date.now() - entry.ts > TTL.posts }
			},
			setPosts: (userId, posts) =>
				set((s) => ({ posts: { ...s.posts, [userId]: { data: posts, ts: Date.now() } } })),
			invalidatePosts: (userId) =>
				set((s) => {
					const next = { ...s.posts }
					delete next[userId]
					return { posts: next }
				}),
		}),
		{ name: '<app>-cache', storage: createJSONStorage(() => AsyncStorage) },
	),
)
```

Hook pattern:

```ts
export function usePosts() {
	const { session } = useSession()
	const me = session?.user.id
	const cached = me ? useCacheStore.getState().getPosts(me) : null
	const [posts, setPosts] = useState(cached?.data ?? [])
	const [loading, setLoading] = useState(!cached)
	const [refreshing, setRefreshing] = useState(false)

	const load = useCallback(async (mode: 'initial' | 'refresh') => {
		if (!me) return
		mode === 'refresh' ? setRefreshing(true) : setLoading(true)
		try {
			const list = await fetchPosts(me)          // repository
			useCacheStore.getState().setPosts(me, list)
			setPosts(list)
		} finally {
			setLoading(false)
			setRefreshing(false)
		}
	}, [me])

	useEffect(() => {
		if (!cached || cached.stale) void load('initial')
	}, [load])

	return { posts, loading, refreshing, refresh: () => load('refresh') }
}
```

- After a mutation, invalidate the related cache keys, then call `refresh()`.
- Gate the first render on cache hydration (`persist.hasHydrated()` / `onFinishHydration`) so screens never flash an empty state. See root-layout.md.
- `stores/app.ts` persists `userId`, `profile` and `theme` (`partialize`) so the app boots straight into the right place offline. Its `clear()` runs on sign-out.

## Migrations and RLS

```sh
supabase migration new create_follows     # never hand-name migration files
# edit supabase/migrations/<ts>_create_follows.sql
bun db:push                                # supabase db push --linked
bun sb:types                               # regenerate src/types/database.types.ts
```

Pushing to the linked project needs the owner's credentials. If you can't run it, ask the user
to push and regenerate types, then continue against the result.

Migration template:

```sql
-- What this migration does, in one or two lines.

create table public.follows (
  follower_id  uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_no_self check (follower_id <> following_id)
);

create index follows_follower_idx on public.follows (follower_id, created_at desc);

alter table public.follows enable row level security;

create policy "follows are readable by signed-in users"
  on public.follows for select to authenticated using (true);

-- Writes via RPC only: security definer so triggers and counters run with elevated rights.
create or replace function public.follow_user(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into follows (follower_id, following_id) values (auth.uid(), p_user_id)
  on conflict do nothing;
end;
$$;

grant execute on function public.follow_user(uuid) to authenticated;
```

Rules:

- `enable row level security` on every table, in the same migration that creates it.
- Scope policies `to authenticated` and use `auth.uid()`. Owner checks look like `using (user_id = auth.uid())`.
- **No recursive policies.** A policy on table A that queries A (or queries B whose policy queries A) loops. Move the check into a `security definer` function (`is_member(p_group uuid) returns boolean`) and call that.
- Every `security definer` function sets `set search_path = public`, and the migration grants `execute` to `authenticated`.
- Protected columns (counters, flags, roles): drop the blanket update policy and expose an `update_x(p_field default null, …)` RPC that uses `coalesce(p_field, field)`.
- Keep denormalised counters in sync with triggers, not client code.
- Postgres validates `language sql` function bodies at create time, so create tables before the functions that reference them.
- Trigger → Edge Function calls use `pg_net` with secrets from Supabase Vault, never literal keys in SQL.
- Don't apply migrations through the Supabase MCP. Always use the CLI.

## Edge Functions

See [edge-functions.md](edge-functions.md). Every function is built on the shared toolkit in
`supabase/functions/_shared/` (handler, clients, auth, errors, integrations), so a function file
holds only its own logic.

## Generated types

- `src/types/database.types.ts` comes from `bun sb:types`. Never edit it, and exclude it from Biome.
- Regenerate after every migration push. Fix type errors in repositories before touching UI.
