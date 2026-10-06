# AGENTS.md

## What this is
Game Night: a no-account voting app for picking which game a friend group plays next. One shelf, one vote, many crews. Live on GitHub Pages with a free Supabase backend.

## Stack
Single-file vanilla JS app (`index.html`, about 6,000 lines, no build step). Supabase (Postgres with row level security, RPC functions) and Deno edge functions. `supabase-js` loaded from a CDN with a Subresource Integrity hash.

## Folders
- `index.html` the whole app; `CONFIG` block near the top of the script holds the Supabase URL and anon key.
- `supabase/schema.sql` tables, RLS, RPCs. `supabase/functions/{enrich,prices,card,discord}/index.ts` edge functions.
- `data/curated.json` verified games with caps and energy, mirrored as `CURATED` in `index.html`.
- `.github/workflows/keepalive.yml` weekly Supabase ping.

## Commands
There is no build, test runner or package.json. Real commands only:
- Preview: serve the folder statically (for example `python3 -m http.server`) and open `index.html`.
- Deploy functions: `supabase functions deploy <name> --no-verify-jwt` (all four need `--no-verify-jwt`).
- Set the share-link site URL: `supabase secrets set SITE_URL=...`
- Schema changes: run `supabase/schema.sql` in the Supabase SQL editor.
Read `README.md` (Setup, Changing things, When things break) before deploying or changing the backend.

## Rules
- Security model is no direct table access: every table is locked by RLS with no policies, and the app only calls RPCs that take a group code. Keep it that way; new data access goes through a function.
- The anon key is public by design. The `service_role` key must never appear in the repo or client code.
- Steam has no CORS, so Steam data is fetched only through the `enrich` and `prices` edge functions.
- Keep `CURATED` in `index.html` and `data/curated.json` in step.
- No deletes in the app, on purpose.
- The keepalive workflow is required or the free Supabase project pauses. Secrets live in GitHub Actions secrets.
- Group codes are a shared secret in links; do not log or commit real ones.
- Never commit secrets, tokens or private data.

## Standards
- UI: WCAG 2.2 AA minimum, including focus visible, target size (40px+ on phones) and reduced motion. All added motion must sit behind `prefers-reduced-motion`. Dialogs trap focus and return it. WAI-ARIA APG patterns for interactive components. Open UI names for new components where one exists.
- AGENTS.md is the agent instructions file; CLAUDE.md only points to it.
- Commits use Conventional Commits 1.0.
