// ============================================================================
// card - the link you actually paste into Discord.
//
// The app is one static page with a hash route (#/g/CODE). Two problems with
// pasting that anywhere:
//   1. crawlers do not run JavaScript, so they see the same empty shell
//   2. the part after # is never sent to a server, so even a crawler that did
//      run JS could not be told which group it is looking at
// So the shareable link points here instead. This returns a tiny HTML page
// carrying real Open Graph tags for one group, and bounces humans straight on
// to the app. Discord, Slack, iMessage, WhatsApp, Notion and Teams all read
// those tags, so the link unfurls with the actual state of the vote.
//
// Link shape:  https://<project>.supabase.co/functions/v1/card?g=XXXXXXX
//
// Deploy:  supabase functions deploy card --no-verify-jwt
// Needs:   SITE_URL secret pointing at the GitHub Pages site, e.g.
//          supabase secrets set SITE_URL=https://you.github.io/game-night/
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// where the real app lives; the trailing slash is normalised either way
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/+$/, "");

const esc = (v: unknown) =>
  String(v ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!)
  );

/** Steam hosts a 460x215 header for every app, so there is no image to render. */
const headerFor = (appid: number) =>
  `https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/${appid}/header.jpg`;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = (url.searchParams.get("g") ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  const target = code && SITE ? `${SITE}/#/g/${code}` : SITE || "/";

  let title = "Game Night";
  let desc = "Pick what we play next.";
  let image = "";

  if (code) {
    // get_state is a security-definer RPC, so this is the same read the app does
    const { data } = await db.rpc("get_state", { p_code: code });
    if (data) {
      const g = data.group ?? {};
      const shelf = data.shelf ?? [];
      const games: Record<number, { name?: string }> = {};
      for (const row of data.games ?? []) games[row.appid] = row;

      // tally the same way the page does: approval voting, count the picks
      const counts: Record<number, number> = {};
      let voters = 0;
      for (const b of data.ballots ?? []) {
        if ((b.picks ?? []).length) voters++;
        for (const a of b.picks ?? []) counts[a] = (counts[a] ?? 0) + 1;
      }
      const ranked = Object.keys(counts)
        .map((a) => ({ appid: +a, n: counts[+a] }))
        .sort((x, y) => y.n - x.n || x.appid - y.appid);

      const members = (data.members ?? []).length;
      const playing = (data.plays ?? []).find((p: { finished_at: string | null }) => !p.finished_at);

      title = g.name ?? "Game Night";

      // there is no deadline to report; a round runs until someone calls it
      if (g.paused_at) {
        desc = ranked.length
          ? `On a break. ${games[ranked[0].appid]?.name ?? "Something"} is out in front when you're back`
          : "On a break. Chuck picks in whenever";
        if (ranked.length) image = headerFor(ranked[0].appid);
      } else if (playing) {
        const nm = games[playing.appid]?.name ?? "something";
        desc = `Playing ${nm} right now`;
        image = headerFor(playing.appid);
      } else if (ranked.length) {
        const top = ranked[0];
        const nm = games[top.appid]?.name ?? "Something";
        const tied = ranked.filter((r) => r.n === top.n).length > 1;
        desc = tied
          ? `Dead heat on ${top.n} ${top.n === 1 ? "vote" : "votes"}`
          : `${nm} leading with ${top.n} ${top.n === 1 ? "vote" : "votes"}`;
        desc += ` · ${voters} of ${members} in`;
        image = headerFor(top.appid);
      } else {
        desc = `${shelf.length} games on the shelf, nobody has picked yet`;
      }
    }
  }

  // No JS in the redirect path on purpose: a meta refresh works even where
  // scripts are blocked, and the anchor is there for anything that ignores both.
  const html = `<!doctype html>
<html lang="en-AU"><head>
<meta charset="utf-8">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Game Night">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
${image ? `<meta property="og:image" content="${esc(image)}">
<meta property="og:image:width" content="460">
<meta property="og:image:height" content="215">` : ""}
<meta name="twitter:card" content="${image ? "summary_large_image" : "summary"}">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="theme-color" content="#5B2AB8">
<meta http-equiv="refresh" content="0; url=${esc(target)}">
<link rel="canonical" href="${esc(target)}">
</head><body style="font:15px -apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;padding:40px">
<p><a href="${esc(target)}">Open ${esc(title)}</a></p>
</body></html>`;

  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      // short cache: the whole point is that the unfurl reflects the live vote,
      // but the chat apps hammer this on every paste so it should not be zero
      "Cache-Control": "public, max-age=120",
      "Access-Control-Allow-Origin": "*",
    },
  });
});
