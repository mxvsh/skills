# UI: coss ui dashboard patterns

## coss ui

[coss ui](https://coss.com/ui) is a shadcn-style component registry built on Base UI
(`@base-ui/react`). Components are copied into `src/components/ui/` and owned by the app. Treat
them as a library: add new ones with the CLI, and don't restyle them per page.

`components.json`:

```json
{
	"$schema": "https://ui.shadcn.com/schema.json",
	"style": "new-york",
	"rsc": false,
	"tsx": true,
	"tailwind": { "config": "", "css": "src/styles.css", "baseColor": "neutral", "cssVariables": true, "prefix": "" },
	"aliases": {
		"components": "@/components",
		"utils": "@/lib/utils",
		"ui": "@/components/ui",
		"lib": "@/lib",
		"hooks": "@/hooks"
	},
	"registries": { "@coss": "https://coss.com/ui/r/{name}.json" }
}
```

```sh
cd apps/web
bunx --bun shadcn@latest add @coss/button @coss/dialog @coss/alert-dialog @coss/toast @coss/sidebar
```

Common set: accordion, alert, alert-dialog, avatar, badge, breadcrumb, button, card, checkbox,
combobox, dialog, drawer, empty, field, input, menu, popover, select, separator, sheet, sidebar,
skeleton, spinner, switch, table, tabs, textarea, toast, tooltip.

API differences from Radix-based shadcn: popups are `DialogPopup`, `SelectPopup`,
`AlertDialogPopup`; composition uses `render={<Link to="…" />}` instead of `asChild`. Read the
generated component file before using one.

Supporting deps: `@base-ui/react`, `class-variance-authority`, `clsx`, `tailwind-merge`,
`lucide-react`, `motion`, `tw-animate-css`, a variable font via `@fontsource-variable/*`.

```ts
// lib/utils.ts
import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]): string {
	return twMerge(clsx(inputs))
}
```

## Styling

- `src/styles.css`: `@import "tailwindcss"`, the font import, `@custom-variant dark (&:is(.dark *))`,
  and `@theme inline` mapping coss CSS variables (`--color-background: var(--background)`, …) plus
  `:root` / `.dark` values. Set brand colours there, never inline.
- Use semantic classes only: `bg-background`, `text-foreground`, `text-muted-foreground`,
  `border-border`, `bg-card`, `text-destructive`, `bg-sidebar`, … No raw hex, no arbitrary colours.
- Headings use `font-heading`; body uses `font-sans`.
- Icons come from `lucide-react` only: `size-4` in buttons, `opacity-70` for decorative icons in titles.
- Use `motion/react` for small transitions (opacity plus a few px of x/y, around 0.18s ease-out). Nothing bouncy.

## Toasts: notify

```ts
// lib/notify.ts
import { toastManager } from "@/components/ui/toast"

type Kind = "success" | "error" | "info" | "warning"

function show(type: Kind, title: string, description?: string) {
	return toastManager.add({ title, description, type })
}

/** App-wide toasts: notify.success("Saved"), notify.error("Could not save", errorMessage(e)). */
export const notify = {
	success: (title: string, description?: string) => show("success", title, description),
	error: (title: string, description?: string) => show("error", title, description),
	info: (title: string, description?: string) => show("info", title, description),
	warning: (title: string, description?: string) => show("warning", title, description),
}
```

`<ToastProvider>` wraps the app in `__root.tsx`. Never wire up toasts anywhere else.

## Confirms: await confirm()

```ts
// components/confirm/confirm-store.ts
import { create } from "zustand"

export type ConfirmOptions = {
	title: string
	description?: string
	confirmText?: string
	cancelText?: string
	/** Style the confirm action as destructive (red). */
	destructive?: boolean
}

type ConfirmState = {
	open: boolean
	options: ConfirmOptions | null
	_resolve: ((value: boolean) => void) | null
	request: (options: ConfirmOptions) => Promise<boolean>
	resolve: (value: boolean) => void
}

export const useConfirmStore = create<ConfirmState>((set, get) => ({
	open: false,
	options: null,
	_resolve: null,
	request: (options) => new Promise<boolean>((resolve) => set({ open: true, options, _resolve: resolve })),
	resolve: (value) => {
		get()._resolve?.(value)
		set({ open: false, _resolve: null })
	},
}))

/** if (await confirm({ title: "Delete post?", destructive: true })) { … } */
export function confirm(options: ConfirmOptions): Promise<boolean> {
	return useConfirmStore.getState().request(options)
}
```

```tsx
// components/confirm/confirm-dialog.tsx: mount once in __root.tsx
import { useConfirmStore } from "@/components/confirm/confirm-store"
import {
	AlertDialog,
	AlertDialogDescription,
	AlertDialogFooter,
	AlertDialogHeader,
	AlertDialogPopup,
	AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"

export function ConfirmDialog() {
	const open = useConfirmStore((s) => s.open)
	const options = useConfirmStore((s) => s.options)
	const resolve = useConfirmStore((s) => s.resolve)

	return (
		<AlertDialog open={open} onOpenChange={(next) => !next && resolve(false)}>
			<AlertDialogPopup className="max-w-md">
				<AlertDialogHeader>
					<AlertDialogTitle>{options?.title}</AlertDialogTitle>
					{options?.description ? (
						<AlertDialogDescription>{options.description}</AlertDialogDescription>
					) : null}
				</AlertDialogHeader>
				<AlertDialogFooter>
					<Button variant="outline" onClick={() => resolve(false)}>
						{options?.cancelText ?? "Cancel"}
					</Button>
					<Button variant={options?.destructive ? "destructive" : "default"} onClick={() => resolve(true)}>
						{options?.confirmText ?? "Confirm"}
					</Button>
				</AlertDialogFooter>
			</AlertDialogPopup>
		</AlertDialog>
	)
}
```

Every destructive action goes through `confirm()`, with a specific title ("Remove Sam as admin?")
and a description of the consequence.

## Dashboard shell (features/dashboard)

```
features/dashboard/
├─ components/dashboard-shell.tsx   SidebarProvider + AppSidebar + SidebarInset + header bar
├─ components/app-sidebar.tsx       brand header, nav, NavUser footer
├─ components/nav-user.tsx          avatar menu: account, sign out
├─ components/page-header.tsx       title / description / actions
├─ lib/nav.ts                       NAV_ITEMS
└─ index.ts                         DashboardShell, PageHeader
```

```tsx
// dashboard-shell.tsx
export function DashboardShell({ children }: { children: ReactNode }) {
	return (
		<SidebarProvider>
			<AppSidebar />
			<SidebarInset>
				<header className="flex h-14 shrink-0 items-center gap-2 px-4">
					<SidebarTrigger className="-ms-1.5" />
					<Separator orientation="vertical" className="me-1 h-4" />
					<span className="font-medium text-foreground text-sm">{/* org or section name */}</span>
				</header>
				<div className="flex-1 px-4 pb-8 sm:px-6">{children}</div>
			</SidebarInset>
		</SidebarProvider>
	)
}
```

```ts
// lib/nav.ts
import type { LucideIcon } from "lucide-react"
import { LayoutDashboard, Settings, Users } from "lucide-react"

/** `to` is a union of real routes so <Link> stays typed. */
export type NavItem = { label: string; to: "/" | "/members" | "/settings"; icon: LucideIcon }

export const NAV_ITEMS: NavItem[] = [
	{ label: "Overview", to: "/", icon: LayoutDashboard },
	{ label: "Members", to: "/members", icon: Users },
	{ label: "Settings", to: "/settings", icon: Settings },
]
```

```tsx
// app-sidebar.tsx (main nav)
const { pathname } = useLocation()
// …
{NAV_ITEMS.map((item) => {
	const active = item.to === "/" ? pathname === "/" : pathname.startsWith(item.to)
	return (
		<SidebarMenuItem key={item.to}>
			<SidebarMenuButton isActive={active} tooltip={item.label} render={<Link to={item.to} />}>
				<item.icon />
				<span>{item.label}</span>
			</SidebarMenuButton>
		</SidebarMenuItem>
	)
})}
```

- `<Sidebar variant="inset">`. The header shows the brand (logo plus org name). The footer holds `NavUser`.
- **Section nav:** inside a detail route (`useParams({ strict: false }).slug` is set), swap the main nav for the section's nav with `AnimatePresence mode="wait"` and a small x-slide. The section nav lives in its own feature (`features/projects/lib/nav.ts`).

```tsx
// page-header.tsx
export function PageHeader({
	title,
	description,
	actions,
}: {
	title: ReactNode
	description?: ReactNode
	actions?: ReactNode
}) {
	return (
		<div className="flex flex-wrap items-end justify-between gap-4 py-6">
			<div className="space-y-1">
				<h1 className="font-heading font-semibold text-2xl text-foreground tracking-tight">{title}</h1>
				{description ? <p className="text-muted-foreground text-sm">{description}</p> : null}
			</div>
			{actions ? <div className="flex items-center gap-2">{actions}</div> : null}
		</div>
	)
}
```

## Manager components (list pages)

`<Name>Manager` owns one resource's list: data hook, mutations, table or cards, and the dialogs
that edit it.

- Wrap tables in `rounded-xl border border-border overflow-hidden` with `<Table>`.
- Every list renders all three states inside the table body:
  - **Loading:** a centred `<Spinner />` row.
  - **Error:** "Couldn't load posts. Try refreshing." in `text-destructive`.
  - **Empty:** a short muted sentence, or coss `Empty` with a primary action.
- Header rows use `hover:bg-transparent`. The actions column is right-aligned with `size="sm" variant="outline"` buttons.
- Guard actions that would break an invariant (e.g. "Can't remove the last admin") with `disabled` plus a `title`, not an error after the fact.
- Pattern: `if (!(await confirm(…))) return` → `await mutation.mutateAsync(…)` → `notify.success(…)`, with a `catch` that calls `notify.error("Could not …", errorMessage(e))`.

## Form dialogs

`<Name>FormDialog` handles both create and edit: `{ item?, open, onOpenChange }`.

```tsx
const EMPTY = { title: "", body: "", published: false }

export function PostFormDialog({ post, open, onOpenChange }: {
	/** Absent when creating. */
	post?: Post
	open: boolean
	onOpenChange: (open: boolean) => void
}) {
	const { create, update } = usePostMutations()
	const [values, setValues] = useState(EMPTY)
	const [error, setError] = useState<string | null>(null)
	const editing = Boolean(post)
	const pending = create.isPending || update.isPending

	// Reset on every open, so reopening after a cancel never shows stale text.
	useEffect(() => {
		if (!open) return
		setError(null)
		setValues(post ? { title: post.title, body: post.body, published: post.published } : EMPTY)
	}, [open, post])

	async function submit(event: React.FormEvent) {
		event.preventDefault()
		const parsed = createPostSchema.safeParse(values) // from @app/core, same schema the API validates with
		if (!parsed.success) {
			setError(parsed.error.issues[0]?.message ?? "Check the form and try again.")
			return
		}
		try {
			if (post) await update.mutateAsync({ id: post.id, input: parsed.data })
			else await create.mutateAsync(parsed.data)
			notify.success(editing ? "Post updated" : "Post created")
			onOpenChange(false)
		} catch (e) {
			notify.error(editing ? "Could not update post" : "Could not create post", errorMessage(e))
		}
	}

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogPopup className="max-w-lg">
				<form onSubmit={submit} className="flex min-h-0 flex-1 flex-col">
					<DialogHeader>
						<DialogTitle>{editing ? "Edit post" : "New post"}</DialogTitle>
						<DialogDescription>One line on what this is for.</DialogDescription>
					</DialogHeader>
					<div className="grid min-h-0 flex-1 gap-5 overflow-y-auto px-6 pb-2">
						<Field>
							<FieldLabel>Title</FieldLabel>
							<Input value={values.title} onChange={(e) => setValues((v) => ({ ...v, title: e.target.value }))} autoFocus />
						</Field>
						{/* … */}
						{error ? <FieldError>{error}</FieldError> : null}
					</div>
					<DialogFooter>
						<Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={pending}>
							Cancel
						</Button>
						<Button type="submit" disabled={pending}>
							{editing ? "Save post" : "Create post"}
						</Button>
					</DialogFooter>
				</form>
			</DialogPopup>
		</Dialog>
	)
}
```

- Validate on the client with the same Zod schema from `@app/core` that the Hono route uses.
- Boolean settings are a bordered row: label, muted helper text, and a `Switch` on the right.
- Show hints under inputs as `text-muted-foreground text-xs`.

## Responsive

`hooks/use-media-query.ts` provides `useMediaQuery("max-md" | "lg" | { min, max, pointer })`,
built on `useSyncExternalStore` (it returns `false` on the server), plus `useIsMobile()`. On
mobile, use a `Drawer` or `Sheet` instead of a `Dialog`.

## Copy

- Sentence case everywhere.
- Buttons name the outcome: "Create post", "Remove admin", not "Submit" or "OK".
- Toast titles: "Post created" on success, "Could not create post" on failure, with the reason as the description.
- Empty states say what's missing and what to do next.
