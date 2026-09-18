# Monorepo

## Tree

```
repo/
├─ apps/
│  ├─ api/                    Hono → Cloudflare Worker (see backend.md)
│  └─ mobile/                 Expo app (see mobile.md)
├─ packages/
│  ├─ db/                     Drizzle schema, migrations, test db
│  ├─ auth/                   better-auth server config
│  ├─ core/                   Zod schemas, DTO types, ids, constants
│  ├─ tokens/                 design tokens
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
		"dev:api": "turbo dev --filter=@app/api",
		"dev:mobile": "turbo dev --filter=@app/mobile",
		"build": "turbo build",
		"check-types": "turbo check-types",
		"lint": "biome check .",
		"format": "biome format --write .",
		"test": "turbo test",
		"tokens:build": "turbo build --filter=@app/tokens",
		"db:generate": "bun --filter=@app/db generate",
		"db:migrate:local": "bun --filter=@app/api db:migrate:local",
		"db:migrate:remote": "bun --filter=@app/api db:migrate:remote",
		"types:worker": "bun --filter=@app/api types",
		"deploy": "bun --filter=@app/api deploy"
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

Every internal package is `private`, `type: module`, and exports TypeScript source. Wrangler, Metro
and tsc all read `.ts` directly, so there is nothing to build or watch.

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
- Mobile imports `@app/api` for **types only** (`import type { AppType }`), so no server code
  lands in the bundle.

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

`^build` on `check-types` and `test` makes sure generated tokens exist first.

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
- Server packages and `apps/api` extend `bun`. The Expo app extends `expo/tsconfig.base` with
  `strict` and `noUncheckedIndexedAccess` turned on.
- App-local alias `#/*` → `./src/*` via `paths` in the Expo tsconfig.

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
			"!**/.expo",
			"!**/packages/db/migrations",
			"!**/global.css"
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

## Design tokens (packages/tokens)

One TypeScript source compiled into the app's generated `global.css`, plus a plain object for React Native
code that needs raw values (e.g. `contentStyle` on a navigator).

```
packages/tokens/
├─ src/colors.ts, type.ts, shape.ts, motion.ts
├─ src/css.ts          mobileCss() for uniwind
├─ src/native.ts       export const theme = { colors, radius, type, … }
└─ scripts/build-css.ts
```

```ts
// scripts/build-css.ts
import { mobileCss } from "../src/css"

// uniwind resolves `@import 'tailwindcss'` from the app's node_modules, so this lands in the app.
await Bun.write(new URL("../../../apps/mobile/src/global.css", import.meta.url), mobileCss())
```

Package exports: `"."`, `"./native"`. The CSS output starts with
`/* Generated by @app/tokens. Do not edit; run bun tokens:build. */` and is gitignored.

## .gitignore essentials

```
node_modules
dist
.wrangler
.expo
.turbo
.env
.env.*
!.env.example
.dev.vars
*.tsbuildinfo
packages/db/seed.sql
apps/api/worker-configuration.d.ts
apps/mobile/src/global.css
apps/mobile/src/uniwind-types.d.ts
apps/mobile/ios
apps/mobile/android
*.jks
*.p8
*.p12
*.mobileprovision
```

## Scaffolding order

1. Root: `package.json`, `turbo.json`, `biome.json`, `.gitignore`, `packages/config`.
2. `packages/core` → `packages/db` → `packages/auth`.
3. `apps/api`: Hono + `worker.ts` + `wrangler.toml`. Run `wrangler d1 create`, then generate and apply the first migration.
4. `packages/tokens`.
5. `apps/mobile`: `bunx create-expo-app@latest`, move into `apps/`, wire Metro, uniwind, the API client, auth, and EAS.
6. `AGENTS.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/decisions.md`.
