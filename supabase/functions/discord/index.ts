// ============================================================================
// discord - the live scoreboard in the crew's Discord channel.
//
// A crew pastes a channel webhook (Edit channel > Integrations > Webhooks).
// The app calls this after anything changes; it builds one embed from the same
// state the app reads and either edits the scoreboard message already in the
// channel or, for big moments (a round called, a night locked, a new round),
// posts a fresh one so it pings the channel and sits at the bottom.
//
// POST { code, device, fresh? }   ->   { ok, posted?, skipped? }
//
// The webhook link never reaches a browser: it lives in groups.discord_hook
// and only this function (with the service key) reads it.
//
// Deploy:  supabase functions deploy discord --no-verify-jwt
// Needs:   SITE_URL, same as the card function
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/+$/, "");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

/** The crews are in Australia; days follow Melbourne, not the server's UTC clock. */
const todayAU = () => new Intl.DateTimeFormat("en-CA", { timeZone: "Australia/Melbourne" }).format(new Date());
/** "Fri 26 Sept" from "2026-09-26" */
const dayName = (iso: string) =>
  new Date(iso + "T12:00:00Z").toLocaleDateString("en-AU", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" }).replace(",", "");
/** Steam hosts a header for every app; games added by hand (negative appids) have none. */
const headerFor = (appid: number) =>
  appid > 0 ? `https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/${appid}/header.jpg` : undefined;
/** "Sam and Kat", "A, B and C" */
const listNames = (xs: string[]) => xs.length < 2 ? xs.join("") : xs.slice(0, -1).join(", ") + " and " + xs[xs.length - 1];
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? "" : "s"}`;

/** The crew colour as the integer Discord wants for the embed's side bar. */
function colourOf(h: unknown, s: unknown): number {
  if (typeof h !== "number" || h < 0) return 0x6d5ae6;           // the default lavender
  const sat = Math.max(0.45, Math.min(0.88, (Number(s) || 60) / 100)), l = 0.52;
  const k = (n: number) => (n + h / 30) % 12, a = sat * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1));
  return (Math.round(f(0) * 255) << 16) + (Math.round(f(8) * 255) << 8) + Math.round(f(4) * 255);
}

// deno-lint-ignore no-explicit-any
type State = any;

/** One embed describing where the crew is at: voting, playing, or on a break. */
function buildEmbed(data: State) {
  const g = data.group ?? {};
  const members: { member_id: string; name: string }[] = data.members ?? [];
  const nameOf = (id: string) => members.find((m) => m.member_id === id)?.name ?? "someone";
  const games: Record<number, { name?: string }> = {};
  for (const row of data.games ?? []) games[row.appid] = row;
  const gname = (a: number) => games[a]?.name ?? "something";

  // the tally, same as the page: approval voting, count the picks
  const counts: Record<number, number> = {};
  const voted = new Set<string>();
  for (const b of data.ballots ?? []) {
    if ((b.picks ?? []).length) voted.add(b.member_id);
    for (const a of b.picks ?? []) counts[a] = (counts[a] ?? 0) + 1;
  }
  const ranked = Object.keys(counts).map((a) => ({ appid: +a, n: counts[+a] }))
    .sort((x, y) => y.n - x.n || gname(x.appid).localeCompare(gname(y.appid)));

  const link = SITE ? `${SITE}/#/g/${g.code}` : undefined;
  const fields: { name: string; value: string; inline?: boolean }[] = [];
  let description = "", image: string | undefined;

  const playing = g.locked_appid;
  if (g.paused_at) {
    description = "⏸ **On a break.** Picks still count, chuck them in whenever.";
  } else if (playing) {
    const n = (data.sessions ?? []).filter((x: { appid: number }) => x.appid === playing).length;
    description = `▶ Playing **${gname(playing)}**` + (n ? ` · ${plural(n, "session")} so far` : "");
    image = headerFor(playing);
    fields.push({ name: "Next sesh", value: seshLine(data, playing, members.map((m) => m.member_id), g, nameOf) });
    for (const sg of data.side ?? []) {
      fields.push({
        name: `On the side: ${gname(sg.appid)}`,
        value: (sg.players ?? []).length ? listNames(sg.players.map(nameOf)) : "nobody in yet",
        inline: true,
      });
    }
  } else {
    const total = members.length;
    const need = Math.min(g.quorum ?? total, total);
    description = `**Round ${g.round_no}** · ${voted.size} of ${total} voted` +
      (voted.size >= need && ranked.length ? " · enough to call it" : "");
    const medals = ["🥇", "🥈", "🥉"];
    fields.push({
      name: "Top picks",
      value: ranked.length
        ? ranked.slice(0, 3).map((r, i) => `${medals[i]} **${gname(r.appid)}** · ${plural(r.n, "vote")}`).join("\n")
        : "Nobody's picked yet. Get in first.",
    });
    const waiting = members.filter((m) => !voted.has(m.member_id)).map((m) => m.name);
    if (waiting.length && total > 1) fields.push({ name: "Still to vote", value: listNames(waiting) });
    if (ranked.length) image = headerFor(ranked[0].appid);
  }

  return {
    title: `${g.emoji ? g.emoji + " " : ""}${g.name ?? "Game Night"}`,
    url: link,
    description,
    color: colourOf(g.tint_h, g.tint_s),
    fields,
    image: image ? { url: image } : undefined,
    footer: { text: "Updates live · tap the title to vote or pick your nights" },
  };
}

/** Where the next night is at for the game in play. */
function seshLine(data: State, appid: number, ids: string[], g: State, nameOf: (id: string) => string) {
  const today = todayAU(), total = ids.length;
  const need = Math.max(1, Math.min(total, g.sesh_need ?? total));
  const lock = (data.sesh_lock ?? []).find((l: { appid: number }) => l.appid === appid);
  if (lock && lock.day >= today) return `✅ **${dayName(lock.day)}, ${g.sesh_time ?? "8pm"}** · locked in`;
  const byDay: Record<string, number> = {};
  const answered = new Set<string>();
  for (const f of data.sesh_free ?? []) {
    if (f.appid !== appid || f.day < today) continue;
    byDay[f.day] = (byDay[f.day] ?? 0) + 1;
    answered.add(f.member_id);
  }
  for (const n of data.sesh_none ?? []) if (n.appid === appid) answered.add(n.member_id);
  const days = Object.keys(byDay).sort();
  const pencil = days.find((d) => byDay[d] >= need);
  if (pencil) return `✏️ **${dayName(pencil)}** pencilled in · ${byDay[pencil]} of ${total} free · tap to lock it`;
  const waiting = ids.filter((id) => !answered.has(id)).map(nameOf);
  const best = days.sort((a, b) => byDay[b] - byDay[a] || a.localeCompare(b))[0];
  return `📅 ${answered.size} of ${total} have picked their nights` +
    (best ? ` · best so far **${dayName(best)}** (${need - byDay[best]} short)` : "") +
    (waiting.length ? `\nWaiting on ${listNames(waiting)}` : "");
}

async function hook(url: string, method: string, body?: unknown) {
  const res = await fetch(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json: State = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not json */ }
  return { ok: res.ok, status: res.status, json };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);

  let body: { code?: string; device?: string; fresh?: boolean };
  try { body = await req.json(); } catch { return reply({ error: "bad json" }, 400); }
  const code = String(body.code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  const device = String(body.device ?? "");
  if (!code || !/^[0-9a-f-]{36}$/i.test(device)) return reply({ error: "code and device please" }, 400);

  // only members of the crew can make it post
  const { data: me } = await db.rpc("member_of", { p_code: code, p_device: device });
  if (!me) return reply({ error: "not in this crew" }, 403);

  const { data: row } = await db.from("groups").select("discord_hook, discord_msg, discord_sig").eq("code", code).single();
  if (!row?.discord_hook) return reply({ ok: true, skipped: "no webhook" });

  const { data: state, error } = await db.rpc("get_state", { p_code: code });
  if (error || !state) return reply({ error: "couldn't read the crew" }, 500);

  const embed = buildEmbed(state);
  const sig = JSON.stringify(embed);
  // nothing changed and no big moment: leave the message alone
  if (!body.fresh && row.discord_msg && row.discord_sig === sig) return reply({ ok: true, skipped: "unchanged" });

  const msg = { username: "Game Night", embeds: [{ ...embed, timestamp: new Date().toISOString() }], allowed_mentions: { parse: [] } };
  const base = row.discord_hook;
  let posted = false, id = row.discord_msg as string | null;

  if (id && !body.fresh) {
    const r = await hook(`${base}/messages/${id}`, "PATCH", msg);
    if (!r.ok) id = null;                 // deleted in Discord: fall through and post a new one
  } else if (id && body.fresh) {
    // the old scoreboard stops claiming to be live
    await hook(`${base}/messages/${id}`, "PATCH", {
      embeds: [{ ...embed, fields: [], image: undefined, description: "Old scoreboard. The live one is further down ↓", footer: undefined }],
    });
    id = null;
  }
  if (!id) {
    const r = await hook(`${base}?wait=true`, "POST", msg);
    if (!r.ok) {
      // a deleted webhook is a 401/404: forget it so the app stops trying
      if (r.status === 401 || r.status === 404) {
        await db.from("groups").update({ discord_hook: null, discord_msg: null, discord_sig: null }).eq("code", code);
        return reply({ error: "That webhook's gone from Discord. Paste a new one." }, 410);
      }
      return reply({ error: `Discord said ${r.status}` }, 502);
    }
    id = r.json?.id ?? null;
    posted = true;
  }
  await db.from("groups").update({ discord_msg: id, discord_sig: sig }).eq("code", code);
  return reply({ ok: true, posted });
});
