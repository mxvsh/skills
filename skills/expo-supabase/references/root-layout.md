# Root layout: boot, splash, redirects

`src/app/_layout.tsx` owns everything that has to be true before the first screen paints:
fonts, store hydration, the session, i18n and the profile. The OTA update check is deliberately
**not** a gate: it runs after the app is interactive (see expo-updates.md). It holds the
native splash until all of them are ready and the redirect has landed, so the user never sees
a blank frame or a flash of the wrong screen.

## Structure

```tsx
import '../global.css'
import * as SplashScreen from 'expo-splash-screen'
// …

SplashScreen.preventAutoHideAsync()

export default function RootLayout() {
	return (
		<GestureHandlerRootView style={{ flex: 1 }}>
			<PostHogProvider client={posthog} autocapture={{ captureScreens: false, captureTouches: true }}>
				<SessionProvider>
					<RootLayoutNav />
				</SessionProvider>
			</PostHogProvider>
		</GestureHandlerRootView>
	)
}
```

`RootLayoutNav` renders the `Stack` plus the hosts (`ToastHost`, `ConfirmHost`, `LoadingHost`, and any global overlays) once `ready` is true.

## Readiness gates

```ts
const [hydrated, setHydrated] = useState(useAppStore.persist.hasHydrated())
const [cacheHydrated, setCacheHydrated] = useState(useCacheStore.persist.hasHydrated())
const [sessionChecked, setSessionChecked] = useState(false)
const [fontsLoaded] = useFonts({ Inter_400Regular: require('…'), /* … */ })

useEffect(() => {
	if (hydrated) return
	return useAppStore.persist.onFinishHydration(() => setHydrated(true))
}, [hydrated])
// same for cacheHydrated

const profileLoadedForUser = !!userId && profile?.id === userId
const ready =
	fontsLoaded && hydrated && cacheHydrated && sessionChecked &&
	(!userId || profileLoadedForUser)

useOtaUpdates(ready)   // starts its first check a few seconds after this flips true
```

While not `ready`, render a plain `View` in the background colour (the splash still covers it).
If a session exists but the profile is still loading, show a spinner and "Signing in…" so the
wait after OAuth doesn't look frozen.

## Session bootstrap

Two effects, kept separate so StrictMode's double-invoke doesn't kill the listener:

```ts
// 1. Listener: reacts to sign-in and sign-out for the life of the app.
useEffect(() => {
	const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
		if (!session) {
			clear()                      // app store, subscription state, purchases identity…
			return
		}
		setUserId(session.user.id)
		void fetchProfile(session.user.id)
		// hydrate per-user stores, identify analytics and purchases
	})
	return () => subscription.unsubscribe()
}, [])

// 2. One-time bootstrap once the app store has hydrated.
useEffect(() => {
	if (!hydrated || bootstrapped.current) return
	bootstrapped.current = true
	supabase.auth.getSession().then(async ({ data }) => {
		const session = data.session
		if (!session) {
			clear()
			setSessionChecked(true)
			return
		}
		setUserId(session.user.id)
		// Cached profile for this user: go now, refresh in the background.
		if (useAppStore.getState().profile?.id === session.user.id) {
			setSessionChecked(true)
			void fetchProfile(session.user.id)
			return
		}
		const found = await fetchProfile(session.user.id)
		if (!found) {
			await supabase.auth.signOut()   // orphaned auth user with no profile row
			clear()
		}
		setSessionChecked(true)
	})
}, [hydrated])
```

## Splash hide

Hide the splash only after the redirect from `index` has landed on a real route, one frame
after it paints:

```ts
useEffect(() => {
	if (!ready) return
	if (!segments[0]) {
		const timer = setTimeout(() => SplashScreen.hideAsync(), 1000) // safety net
		return () => clearTimeout(timer)
	}
	let inner = 0
	const outer = requestAnimationFrame(() => {
		inner = requestAnimationFrame(() => SplashScreen.hideAsync())
	})
	return () => {
		cancelAnimationFrame(outer)
		cancelAnimationFrame(inner)
	}
}, [ready, segments[0]])
```

Set the Stack's `contentStyle.backgroundColor` to the same colour as `bg-background` for the
current scheme, so no off-colour frame shows between the splash and the screen.

## Route groups and redirects

```
app/
├── index.tsx              <Redirect> based on userId + profile.onboarding_complete
├── (app-onboarding)/      signed-out intro
├── (auth)/                sign-in, sign-up, verify, forgot-password, reset-password
├── (user-onboarding)/     profile setup steps after first sign-in
├── (tabs)/                the signed-in app
├── <stack screens>…       settings/, post/[id]/, user/[id].tsx, paywall.tsx…
├── auth-callback.tsx      empty route so OAuth deep links resolve
└── +not-found.tsx
```

```ts
// Ongoing redirect when auth or onboarding state changes after boot.
useEffect(() => {
	if (!ready || recoveryMode) return
	const group = segments[0]
	if (!userId) {
		if (group !== '(app-onboarding)' && group !== '(auth)') router.replace('/(app-onboarding)')
		return
	}
	if (!profileLoadedForUser) return
	if (!profile?.onboarding_complete) {
		if (group !== '(user-onboarding)') router.replace('/(user-onboarding)')
		return
	}
	if (!SIGNED_IN_SEGMENTS.has(group) && !pendingDeepLink.current) router.replace('/(tabs)')
}, [ready, recoveryMode, userId, profileLoadedForUser, profile?.onboarding_complete, segments[0]])
```

- Keep `SIGNED_IN_SEGMENTS` as a `Set` of the top-level signed-in routes, so a new screen isn't bounced back to tabs.
- In password recovery (`recoveryMode`), `router.push('/(auth)/reset-password')` once `ready` is true.
- Use `animation: 'none'` on group switches (index, tabs, onboarding) and `gestureEnabled: false` on auth and app onboarding.
- Prefer `presentation: 'card'` with `animation: 'slide_from_bottom'` over `fullScreenModal` for full-screen flows that must dismiss cleanly.

## Deep links and notifications at cold start

Capture them before the Stack mounts and act on them once the app is ready and the user is signed in and onboarded:

```ts
const pendingDeepLink = useRef<string | null>(null)
useEffect(() => {
	Linking.getInitialURL().then((url) => {
		if (!url || url.includes('auth-callback') || url.includes('code=') || url.includes('access_token')) return
		if (url.startsWith('<scheme>://')) pendingDeepLink.current = url
	})
}, [])

const pendingNotification = useRef<Notifications.NotificationResponse | null>(null)
useEffect(() => {
	Notifications.getLastNotificationResponseAsync().then((r) => { if (r) pendingNotification.current = r })
	const sub = Notifications.addNotificationResponseReceivedListener((r) => { pendingNotification.current = r })
	return () => sub.remove()
}, [])
```

Once `ready && userId && onboardingComplete`, route the pending link or notification
(`data.type` → path) inside a `setTimeout`, and mark it handled. Sync the push token and
timezone at the same point.

## Screen tracking

Track screens manually (`posthog.screen(pathname, { previous_screen, ...params })`) in a
`usePathname` effect, rather than using autocapture.
