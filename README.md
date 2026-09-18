<p align="center">
  <img src="assets/banner.webp" alt="Skills" width="100%">
</p>

# Skills

Reusable agent skills for Claude Code, Cursor, Codex, and other agents that support [Agent Skills](https://agentskills.io).

## Skills

| Skill | Description |
| --- | --- |
| [expo-cloudflare](skills/expo-cloudflare) | Expo app + Hono API on Cloudflare Workers, D1 + Drizzle, better-auth, EAS updates (Bun + Turborepo) |
| [web-cloudflare](skills/web-cloudflare) | TanStack Start + coss ui dashboard, Hono API on Cloudflare Workers, D1 + Drizzle, better-auth (Bun + Turborepo) |
| [expo-supabase](skills/expo-supabase) | Expo app on Supabase: RLS, auth, repository data layer, offline cache, shared edge-function toolkit, EAS updates |

## Install

Any agent:

```bash
npx skills add mxvsh/skills                          # pick interactively
npx skills add mxvsh/skills -s expo-cloudflare -g    # one skill, globally
```

Claude Code plugin:

```
/plugin marketplace add mxvsh/skills
/plugin install expo-cloudflare@mxvsh-skills
/plugin install web-cloudflare@mxvsh-skills
/plugin install expo-supabase@mxvsh-skills
```
