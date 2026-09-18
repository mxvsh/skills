# Monorepo

## Tree

```
repo/
├─ apps/
│  └─ web/                    TanStack Start + Hono at /api → Cloudflare Worker (see web.md)
├─ packages/
│  ├─ api/                    Hono app (see backend.md)
│  ├─ db/                     Drizzle schema, migrations, test db
│  ├─ auth/                   better-auth server + browser client
│  ├─ core/                   Zod schemas, DTO types, ids, constants
│  └─ config/                 tsconfig bases
├─ docs/
│  ├─ architecture.md         system, stack, data model
│  └─ decisions.md            numbered decisions (D1, D2…) with reasons; superseded ones struck through
├─ AGENTS.md                  working summary for agents: layout, import rules, conventions, commands
├─ CLAUDE.md                  `@AGENTS.md` plus Claude-only notes
├─ package.json
├─ turbo.json
├─ biome.json
└─ docker-compose.yml         local third-party services, if any
```

Each app may also carry its own `AGENTS.md` for rules that only apply there.

## Root package.json

```json
{
	"name": "app",
	"private": true,
	"type": "module",
	"packageManager": "bun@1.3.14",
	"workspaces": ["apps/*", "packages/*"],
	"scripts": {
		"dev": "turbo dev",
		"dev:web": "turbo dev --filter=@app/web",
		"build": "turbo build",
		"check-types": "turbo check-types",
		"lint": "biome check .",
		"format": "biome format --write .",
		"test": "turbo test",
		"db:generate": "bun --filter=@app/db generate",
		"db:migrate:local": "bun --filter=@app/web db:migrate:local",
		"db:migrate:remote": "bun --filter=@app/web db:migrate:remote",
		"types:worker": "bun --filter=@app/web types",
		"deploy": "bun --filter=@app/web deploy"
	},
	"devDependencies": {
		"@biomejs/biome": "latest",
		"@types/bun": "latest",
		"turbo": "latest",
		"typescript": "latest"
	}
}
```

Root scripts are thin wrappers. The real commands live in each package.

## Internal packages

Every internal package is `private`, `type: module`, and exports TypeScript source. Vite and tsc read `.ts` directly, so there is nothing to build or watch.

```json
{
	"name": "@app/core",
	"version": "0.0.0",
	"private": true,
	"type": "module",
	"exports": { ".": "./src/index.ts" },
	"scripts": {
		"check-types": "tsc --noEmit",
		"test": "bun test --pass-with-no-tests"
	},
	"dependencies": { "zod": "^4" },
	"devDependencies": { "@app/config": "workspace:*" }
}
```

- Depend on siblings with `"workspace:*"`.
- Use multiple entry points to keep server code out of clients, e.g.
  `"exports": { ".": "./src/index.ts", "./client": "./src/client.ts" }`.
- Browser code imports `@app/api` and `@app/auth` for **types only**, plus `@app/auth/client`.
  Server-only modules (the in-process transport, bindings) import `@tanstack/react-start/server-only`.

## turbo.json

```json
{
	"$schema": "https://turbo.build/schema.json",
	"ui": "tui",
	"tasks": {
		"build": {
			"dependsOn": ["^build"],
			"inputs": ["$TURBO_DEFAULT$", ".env*"],
			"outputs": ["dist/**"]
		},
		"check-types": { "dependsOn": ["^build"] },
		"test": { "dependsOn": ["^build"] },
		"dev": { "cache": false, "persistent": true }
	}
}
```

## TypeScript (packages/config)

`tsconfig.base.json`:

```json
{
	"compilerOptions": {
		"target": "ES2022",
		"lib": ["ES2023", "DOM", "DOM.Iterable"],
		"module": "ESNext",
		"moduleResolution": "bundler",
		"moduleDetection": "force",
		"allowImportingTsExtensions": true,
		"verbatimModuleSyntax": true,
		"resolveJsonModule": true,
		"isolatedModules": true,
		"noEmit": true,
		"strict": true,
		"skipLibCheck": true,
		"noFallthroughCasesInSwitch": true,
		"noUncheckedIndexedAccess": true,
		"noImplicitOverride": true,
		"noUnusedLocals": true
	}
}
```

- `tsconfig.bun.json` extends base and adds `"types": ["bun"]`.
- `tsconfig.react.json` extends base and adds `"jsx": "react-jsx"`.
- Server packages extend `bun`; `apps/web` extends `react` and adds `"types": ["vite/client"]`
  and `worker-configuration.d.ts` to `include`.
- App alias `@/*` → `./src/*` via `paths` in `apps/web/tsconfig.json` (coss ui / shadcn expect `@/`).

Conventions: `interface` for object shapes, `type` for unions. No `any`.

## biome.json

```json
{
	"root": true,
	"vcs": { "enabled": true, "clientKind": "git", "useIgnoreFile": true },
	"files": {
		"includes": [
			"**",
			"!**/node_modules",
			"!**/dist",
			"!**/.wrangler",
			"!**/.tanstack",
			"!**/routeTree.gen.ts",
			"!**/packages/db/migrations"
		]
	},
	"formatter": { "enabled": true, "indentStyle": "tab", "lineWidth": 100 },
	"javascript": {
		"formatter": { "quoteStyle": "double", "semicolons": "asNeeded", "trailingCommas": "all" }
	},
	"css": { "parser": { "tailwindDirectives": true } },
	"linter": {
		"enabled": true,
		"rules": { "preset": "recommended", "suspicious": { "noExplicitAny": "error" } }
	},
	"assist": { "actions": { "source": { "organizeImports": "on" } } }
}
```

## .gitignore essentials

```
node_modules
dist
.wrangler
.tanstack
.turbo
.env
.env.*
!.env.example
.dev.vars
*.tsbuildinfo
packages/db/seed.sql
apps/web/worker-configuration.d.ts
```

## Scaffolding order

1. Root: `package.json`, `turbo.json`, `biome.json`, `.gitignore`, `packages/config`.
2. `packages/core` → `packages/db` → `packages/auth` → `packages/api`.
3. `apps/web`: `bunx create-tsrouter-app@latest` (TanStack Start), switch to `@cloudflare/vite-plugin`,
   add `wrangler.toml`, mount `/api`. Run `wrangler d1 create`, then generate and apply the first migration.
4. coss ui: `components.json`, `styles.css` theme, the primitives you need, then notify, confirm and the shell (see ui.md).
5. `AGENTS.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/decisions.md`.
