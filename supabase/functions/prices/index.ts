// ============================================================================
// prices - what the crew's shelf costs on Steam right now, in AUD.
//
// Steam sends no CORS headers, so the browser can't ask it directly. The app
// calls this once when a crew opens; it refreshes any shelf game whose price
// is more than a few hours old and writes it to the shared prices table, which
// get_state hands back with everything else.
//
// POST { code }   ->   { ok, refreshed }
//
// Steam's appdetails takes many appids at once when filtered to price_overview,
// so a whole shelf is one or two requests.
//
// Deploy:  supabase functions deploy prices --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const STALE_MS = 4 * 60 * 60 * 1000;   // sales change daily; four hours is plenty fresh
const BATCH = 40;                      // appids per Steam request

type Price = { appid: number; is_free: boolean; discount: number; final_fmt: string | null; initial_fmt: string | null; fetched_at: string };

async function fetchBatch(appids: number[]): Promise<Price[]> {
  const url = `https://store.steampowered.com/api/appdetails?appids=${appids.join(",")}&filters=price_overview&cc=au`;
  const res = await fetch(url);
  if (!res.ok) return [];
  const body = await res.json().catch(() => null);
  if (!body) return [];
  const now = new Date().toISOString();
  const out: Price[] = [];
  for (const a of appids) {
    const e = body[String(a)];
    if (!e?.success) continue;                      // delisted or region locked: leave it alone
    const po = e.data?.price_overview;
    // a free game comes back as success with empty data
    out.push(po
      ? { appid: a, is_free: false, discount: po.discount_percent ?? 0, final_fmt: po.final_formatted ?? null,
          initial_fmt: po.initial_formatted ?? null, fetched_at: now }
      : { appid: a, is_free: true, discount: 0, final_fmt: null, initial_fmt: null, fetched_at: now });
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);
  let body: { code?: string };
  try { body = await req.json(); } catch { return reply({ error: "bad json" }, 400); }
  const code = String(body.code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!code) return reply({ error: "code please" }, 400);

  const { data: shelf } = await db.from("shelf").select("appid").eq("group_code", code);
  // games added by hand (negative appids) aren't on Steam, so there is no price to fetch
  const ids = [...new Set((shelf ?? []).map((r: { appid: number }) => r.appid))].filter((a) => a > 0);
  if (!ids.length) return reply({ ok: true, refreshed: 0 });

  const { data: have } = await db.from("prices").select("appid, fetched_at").in("appid", ids);
  const fresh = new Set((have ?? [])
    .filter((p: { fetched_at: string }) => Date.now() - new Date(p.fetched_at).getTime() < STALE_MS)
    .map((p: { appid: number }) => p.appid));
  const stale = ids.filter((a) => !fresh.has(a));
  if (!stale.length) return reply({ ok: true, refreshed: 0 });

  const rows: Price[] = [];
  for (let i = 0; i < stale.length; i += BATCH) rows.push(...await fetchBatch(stale.slice(i, i + BATCH)));
  if (rows.length) await db.from("prices").upsert(rows);
  return reply({ ok: true, refreshed: rows.length });
});
