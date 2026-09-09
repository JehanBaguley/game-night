// ============================================================================
// enrich - the only place Steam data can be fetched.
//
// Steam sends no CORS headers, so a browser can never call it directly. This
// runs on Supabase's edge (Deno), where CORS does not apply, and caches the
// result into the shared `games` table so each app id is fetched once.
//
// Two actions:
//   { action: "search", q: "valheim" }   -> autocomplete results
//   { action: "get", appid | url }       -> validated, normalised game row
//
// Deploy:  supabase functions deploy enrich --no-verify-jwt
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// The page is served from GitHub Pages, so the browser needs these back.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Service role key: this function is the only writer to `games`, which is why
// the table has row level security on with no write policy for anon.
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CACHE_DAYS = 30; // T5: anything older than this re-fetches

// ----------------------------------------------------------------------------
// Facet derivation. This is the "smarter genre" work: Steam's genre field says
// Action/Indie/Adventure on nearly everything, so we ignore it for classification
// and read the user tags instead, which describe how a game actually plays.
// ----------------------------------------------------------------------------

/* WHAT WE'LL BE DOING
   This replaced a "vibe" axis (cozy / chaotic / tense / competitive) that was
   blank on 44% of a real shelf and, when it did fire, restated energy: every
   one of its cozy keywords was also an energy-1 keyword. Mode of play answers
   a different question from effort, so the two stop colliding.

   Weighted rather than counted, because one strong signal should beat three
   weak ones. Barotrauma is tagged Survival AND Survival Horror; the horror has
   to win. PICO PARK 2 carries a junk "Psychological Horror" tag, so horror at
   low weight has to lose to Casual. Order matters on ties: first listed wins,
   which is why the broadest bucket is last. */
const DOING_RULES: Array<[string, Record<string, number>]> = [
  ["scary", { "survival horror":5, "horror":4, "lovecraftian":2, "psychological horror":1, "zombies":1 }],
  ["rounds", { "roguelike":4, "roguelite":4, "rogue-lite":4, "rogue-like":4, "run based roguelike":4,
               "action roguelike":4, "battle royale":3, "extraction shooter":3, "moba":3,
               "arena shooter":3, "hero shooter":2, "fighting":2, "arcade":2, "pvp":2, "pve":2, "shooter":1 }],
  ["mucking", { "party game":5, "funny":3, "comedy":3, "physics":2, "silly":2, "memes":2,
                "casual":2, "family friendly":2, "puzzle":2, "cute":1, "platformer":1, "sports":1 }],
  ["story", { "story rich":5, "narrative":3, "choose your own adventure":3, "visual novel":3,
              "adventure":2, "dungeon crawler":2, "metroidvania":2, "point & click":2, "rpg":1 }],
  ["building", { "base building":5, "base-building":5, "open world survival craft":5, "colony sim":4,
                 "city builder":4, "automation":4, "farming sim":4, "crafting":3, "management":2,
                 "resource management":2, "sandbox":2, "survival":2, "life sim":2, "building":2, "simulation":1 }],
];

/* Steam's categories are declared by the publisher rather than voted on by the
   crowd, so they are close to always present and close to always right. Tags
   are neither. Letting categories contribute is what takes the blank rate to
   zero on games too new or too small for SteamSpy to know about. */
const CATEGORY_HINTS: Record<string, [string, number]> = {
  "co-op campaign": ["story", 3],
  "shared/split screen": ["mucking", 2],
  "shared/split screen co-op": ["mucking", 2],
  "online pvp": ["rounds", 2],
  "shared/split screen pvp": ["rounds", 1],
  "pvp": ["rounds", 1],
};

function classifyDoing(tags: string[], categories: string[]): string | null {
  const hay = tags.map((t) => t.toLowerCase());
  const score: Record<string, number> = {};
  for (const [label, kws] of DOING_RULES) {
    score[label] = 0;
    for (const [kw, w] of Object.entries(kws)) {
      if (hay.some((t) => t.includes(kw))) score[label] += w;
    }
  }
  for (const c of categories) {
    const hit = CATEGORY_HINTS[c.toLowerCase()];
    if (hit) score[hit[0]] = (score[hit[0]] ?? 0) + hit[1];
  }
  let best: string | null = null, bestScore = 0;
  for (const [label] of DOING_RULES) {      // first listed wins a tie
    if (score[label] > bestScore) { best = label; bestScore = score[label]; }
  }
  return best;
}

// Energy is normally ours, curated per game. For anything outside that list a
// tag-derived guess is far better than a blank, because a game with no energy
// can never match "fits tonight" and quietly disappears from the one filter
// that matters. The group can always correct it.
const ENERGY_RULES: Array<[string, string[]]> = [
  ["1", ["relaxing", "cozy", "casual", "party game", "short", "puzzle", "cute",
         "wholesome", "family friendly", "farming sim", "idler", "point & click"]],
  ["3", ["difficult", "souls-like", "hardcore", "permadeath", "survival",
         "base building", "grand strategy", "colony sim", "simulation",
         "open world survival craft", "tactical", "realistic"]],
];

const SHAPE_RULES: Array<[string, string[]]> = [
  ["longhaul",  ["base building", "survival", "open world survival craft", "colony sim", "sandbox", "crafting"]],
  ["campaign",  ["story rich", "rpg", "adventure", "dungeon crawler", "metroidvania"]],
  ["sitting",   ["roguelike", "roguelite", "run based roguelike", "puzzle", "short"]],
  ["dropin",    ["arcade", "party game", "shooter", "casual", "fast-paced"]],
];

/** Score each bucket by how many of its keywords appear in the tag list.
 *  Returns null rather than a fallback when nothing matches: a wrong label that
 *  looks confident is worse than an honest blank someone can correct. */
function classify(rules: Array<[string, string[]]>, tags: string[]) {
  const lower = tags.map((t) => t.toLowerCase());
  let best: string | null = null;
  let bestScore = 0;
  for (const [label, keywords] of rules) {
    const score = keywords.reduce(
      (n, kw) => n + (lower.some((t) => t.includes(kw)) ? 1 : 0),
      0,
    );
    if (score > bestScore) {
      best = label;
      bestScore = score;
    }
  }
  return best;
}

/** Pull an app id out of anything a person might paste. */
function parseAppid(input: string): number | null {
  const s = String(input).trim();
  if (/^\d+$/.test(s)) return Number(s);
  const m = s.match(/\/app\/(\d+)/); // store, community and help urls all match
  return m ? Number(m[1]) : null;
}

// ----------------------------------------------------------------------------
// Steam calls
// ----------------------------------------------------------------------------

async function steamSearch(q: string) {
  const url =
    `https://store.steampowered.com/api/storesearch/?term=${encodeURIComponent(q)}&l=en&cc=au`;
  const res = await fetch(url, { headers: { "Accept-Language": "en" } });
  if (!res.ok) return [];
  const data = await res.json().catch(() => null);
  return (data?.items ?? [])
    .filter((i: any) => i.id && i.name)
    .slice(0, 8)
    .map((i: any) => ({
      appid: i.id,
      name: i.name,
      header: i.tiny_image ?? null,
    }));
}

async function steamDetails(appid: number) {
  const url =
    `https://store.steampowered.com/api/appdetails?appids=${appid}&cc=au&l=en`;
  const res = await fetch(url);
  if (!res.ok) return null;
  const body = await res.json().catch(() => null);
  const entry = body?.[String(appid)];
  return entry?.success ? entry.data : null;
}

async function steamReviews(appid: number) {
  // num_per_page=0 means "summary only", which is all we want
  const url =
    `https://store.steampowered.com/appreviews/${appid}?json=1&language=all&purchase_type=all&num_per_page=0`;
  const res = await fetch(url);
  if (!res.ok) return null;
  const body = await res.json().catch(() => null);
  return body?.query_summary ?? null;
}

/** SteamSpy exposes user tags as clean JSON. Best effort: if it is down or
 *  slow we fall back to genres, which is worse but never blocks an add. */
async function steamspyTags(appid: number): Promise<string[]> {
  try {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 4000);
    const res = await fetch(
      `https://steamspy.com/api.php?request=appdetails&appid=${appid}`,
      { signal: ctl.signal },
    );
    clearTimeout(timer);
    if (!res.ok) return [];
    const body = await res.json().catch(() => null);
    const tags = body?.tags;
    if (!tags || Array.isArray(tags)) return [];
    // tags is { "Co-op": 1234, "Survival": 980, ... } - sort by vote weight
    return Object.entries(tags)
      .sort((a, b) => Number(b[1]) - Number(a[1]))
      .slice(0, 14)
      .map(([name]) => name);
  } catch {
    return [];
  }
}

// ----------------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "expected a json body" }, 400);
  }

  // ---- autocomplete ----
  if (payload.action === "search") {
    const q = String(payload.q ?? "").trim();
    if (q.length < 2) return json({ results: [] });
    try {
      return json({ results: await steamSearch(q) });
    } catch {
      return json({ error: "Steam search is not responding, try again in a moment" }, 502);
    }
  }

  // ---- fetch one game ----
  const appid = parseAppid(payload.appid ?? payload.url ?? "");
  if (!appid) {
    return json({ error: "That does not look like a Steam link or app id" }, 400);
  }

  // Serve from cache when it is fresh enough (T5)
  const { data: cached } = await db
    .from("games").select("*").eq("appid", appid).maybeSingle();

  if (cached && !payload.force) {
    const ageDays =
      (Date.now() - new Date(cached.fetched_at).getTime()) / 86_400_000;
    if (ageDays < CACHE_DAYS) return json({ game: cached, cached: true });
  }

  const details = await steamDetails(appid);
  if (!details) {
    return json({ error: "Steam has no store page for that id" }, 404);
  }

  // T3: reject anything that is not a real, playable, multiplayer game before
  // it can become a permanent dead card on someone's shelf.
  if (details.type !== "game") {
    return json(
      { error: `That is a ${details.type ?? "non-game"}, not a game. Link the base game instead.` },
      422,
    );
  }

  const categories: string[] = (details.categories ?? []).map((c: any) => c.description);
  const coop = categories.some((c) => /co-?op/i.test(c));
  // Anything you can play in the same room or lobby counts. Party games often
  // list only "Online PvP" and no co-op category at all, and rejecting those
  // would throw out exactly the sort of thing a game night is for.
  const together = categories.some((c) =>
    /multi-?player|co-?op|pvp|shared\s*\/?\s*split/i.test(c)
  );

  if (!together) {
    return json(
      { error: `${details.name} looks single-player only, so there is nothing to vote on` },
      422,
    );
  }

  const [summary, tags] = await Promise.all([
    steamReviews(appid),
    steamspyTags(appid),
  ]);

  const genres: string[] = (details.genres ?? []).map((g: any) => g.description);
  const forClassify = tags.length ? tags : genres;

  const total = Number(summary?.total_reviews ?? 0);
  const positive = Number(summary?.total_positive ?? 0);

  const row = {
    appid,
    name: details.name,
    short_desc: details.short_description ?? null,
    // strip Steam's marketing html down to plain text for the expanded view
    long_desc: (details.about_the_game ?? details.detailed_description ?? "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 1200) || null,
    header: details.header_image ?? null,
    review_desc: summary?.review_score_desc ?? null,
    review_pct: total > 0 ? Math.round((positive / total) * 100) : null,
    review_count: total || null,
    genres,
    tags,
    categories,
    coop,
    online_coop: categories.some((c) => /online co-?op/i.test(c)),
    released: details.release_date?.date ?? null,
    doing: classifyDoing(forClassify, categories),
    shape: classify(SHAPE_RULES, forClassify),
    // no strong signal either way lands on 2, a normal night
    energy_guess: Number(classify(ENERGY_RULES, forClassify) ?? 2),
    fetched_at: new Date().toISOString(),
  };

  const { error } = await db.from("games").upsert(row, { onConflict: "appid" });
  if (error) return json({ error: error.message }, 500);

  return json({ game: row, cached: false });
});
