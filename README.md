# Game Night

Pick what we play next. One shelf, one vote, as many friend groups as you need.

Live on GitHub Pages, data in your own free Supabase project. No accounts for anyone who votes, just a link.

---

## Setup

About an hour, most of it waiting for Supabase to provision. Do the steps in order.

### 1. Supabase project

1. Sign up at [supabase.com](https://supabase.com) and create a project. Any region, Sydney is closest.
2. Wait for it to finish provisioning.
3. **Project settings → API**, copy two values:
   - Project URL, looks like `https://abcdefgh.supabase.co`
   - `anon` `public` key, a long string starting `eyJ`

Both are safe in a public repo. The `anon` key can only call the functions granted at the bottom of `schema.sql`, and every one of them needs a group code.

The `service_role` key is **not** safe. It never leaves the Supabase dashboard.

### 2. Schema

**SQL Editor → New query**, paste the whole of `supabase/schema.sql`, run it.

You should see `Success. No rows returned`. That creates eight tables, locks them all behind row level security with no policies, and exposes nineteen functions to the anon key. That is the whole security model: no direct table access, everything through a function that takes a group code.

### 3. Edge functions

Two of them. `enrich` is the only place Steam data can be fetched, because Steam sends no CORS headers and a browser can never call it directly. `card` is what makes a pasted link unfurl in Discord.

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF     # the abcdefgh bit from your URL
supabase functions deploy enrich --no-verify-jwt
supabase functions deploy card   --no-verify-jwt
```

`--no-verify-jwt` matters on both: they're called with the anon key, not a logged-in user token.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically. `card` needs one more, but you won't know its value until step 5.

### 4. Paste your config

Open `index.html`, find the `CONFIG` block near the top of the script, replace both placeholders.

```js
const CONFIG = {
  SUPABASE_URL: "https://abcdefgh.supabase.co",
  SUPABASE_ANON_KEY: "eyJ...",
};
```

### 5. Publish

Push to a public GitHub repo, then **Settings → Pages → Source: deploy from branch → main / root**.

Live at `https://<you>.github.io/<repo>/` within a minute or two.

Now that you know the address, give it to the `card` function so share links redirect to the right place:

```bash
supabase secrets set SITE_URL=https://<you>.github.io/<repo>
```

Skip this and the app still works fine, share links just won't unfurl.

### 6. Keepalive

This one is not optional.

Supabase pauses free projects after roughly a week of inactivity. Your cadence is "whenever we finish a game", which can be two months, so without this the project sleeps and the link is dead the next time someone opens it.

**Settings → Secrets and variables → Actions**, add:

| Secret | Value |
| --- | --- |
| `SUPABASE_URL` | same project URL |
| `SUPABASE_ANON_KEY` | same anon key |

The workflow in `.github/workflows/keepalive.yml` then runs weekly and also refreshes any Steam data older than 30 days.

### 7. Seed both groups

Open the site, create a group, name yourself. It loads the 15 games from `SEED` automatically, which takes about 20 seconds.

**Vote before you send the link.** An empty vote is a dead vote: the first person to arrive and see zero picks decides it is not a real thing yet and closes the tab. Cast your three, then share.

Repeat for the second group. Same shelf, separate everything else.

---

## How it works

### Voting

Approval style, three picks each. Single choice splits the vote across ten survival games and nothing wins, so everyone approves up to three and the tally is derived at render time from the ballots, never stored.

A round has no end date. **Call it** is always there once something has a vote, and once the quorum has voted (default 5) the strip says it's enough. Quorum is a column on `groups` if you want it different.

### Rounds don't expire

There's no countdown. The cadence was always "whenever we finish a game", which can be a fortnight or three months, so a five day clock was inventing a deadline nobody agreed to and then sitting there saying *time's up* for weeks.

A round stays open until someone calls it. The strip shows **3 of 5 in · 2 more to call it**, and **Call it** appears the moment anything has a vote.

### Taking a break

Between games, hit **Taking a break** on the round strip:

> ⏸ **Taking a break** · since 12 Aug
> Chuck picks in whenever. Nobody is counting. **[Pick it back up]**

Voting still works, so people can throw picks in whenever they think of something. The share text says *on a break, votes still welcome* rather than reporting a tally nobody is acting on. Wrapping up a game offers it directly, **Not yet / Take a break / Next round**, since between games is exactly when you know.

**Pick it back up** asks one thing: how many of you this time. It sets your crew filter so a night with three people isn't shown the games that need six. It's your own filter, not the group's, and it's skippable. The crew filter always existed; the problem was remembering to use it, and coming back with a different crowd is the moment it matters.

### Game states

Every game on the shelf is in exactly one state. It's derived from `benched` and the play history, never stored twice, so there's one definition and nothing to keep in sync.

| State | What it means | Action | How it moves |
| --- | --- | --- | --- |
| **Up for a vote** | On the shelf. Which is nearly everything | Pick | Wins a round, or gets benched |
| **On right now** | Won the round | Locked | Finished it, or Changed our minds |
| **Benched** | Someone parked it, or it got a never-again | Put it back | One tap, any member |

**There is no backlog.** There used to be: a game nobody owned sat in a second list until two people boosted it. For ten mates that's a nomination process nobody asked for, and it created the worst kind of bug, where a game is *technically there* but invisible. Now a game is up for a vote the moment it's added, and the only thing that takes one out of view is someone deliberately benching it.

**Played** is not a state, it's history. A game can be up for a vote and also have been played three times, so it shows as a line on the card rather than a place games go.

One card component serves all three. Same cover art, same facets, same layout, with the badge and the primary action changing.

**There are no tabs either.** The whole shelf is on screen, always, split into sections with a count on each. The default split is the one that matters on the night:

- **▶ On right now** — if a round is locked in
- **In the running** — anything with at least one vote
- **Nobody's picked it yet** — the rest

That's a free consequence of the default sort, so the headings just make the boundary explicit. At the start of a round nothing has votes, so the split collapses to one unlabelled shelf rather than putting an empty header on screen.

Sections are a grouping, so you can switch them to energy, length, faff or played, or flatten to one long list. The count line above the shelf only appears when it has something to add: *9 of 15 shown* while filtering, or *nothing has been picked yet* on a fresh round. Unfiltered it was repeating the section heading sitting directly below it.

### What happens to a finished game

Nothing is guessed. **Finished it** asks two questions and both are one tap:

1. How was it: banger, fine, never again. Skippable
2. Where does it go: leave it up, or bench it

**Leave it up is the default**, and it means exactly that: the game is up for a vote again immediately, carrying its verdict and play count on the card. Playing it again is just voting for it again. Nothing is hidden and nothing has to be resurrected.

**Bench it** takes it off the shelf and out of everyone's picks. It's still there behind the **Benched** filter chip, and one tap on **Put it back** returns it.

That's deliberate. Auto-benching would bury a long-haul game you're still enjoying, and auto-keeping lets a dud keep winning. Picking *never again* pre-selects benching, since that's almost always what you meant. Either way everyone's picks and energy reset for the next round.

### Who added it

For a while this section was about tracking who *owns* each game, with a tappable pill on every card. It got cut, and the reasoning is worth keeping because it applies to most features like it.

The pitch was that it answers "who can host this". That was wrong. Most co-op games need **everyone** to own a copy, not one host, so a single owner name never actually told you whether the night could go ahead. Tracking it honestly would mean ten people ticking a box on seventy-odd games, which nobody was ever going to do, and a half-filled ownership list is worse than none because it looks authoritative.

What replaced it costs nothing: the card says **Added by Soli**. It's set once, automatically, never goes stale, and it points at the person who can actually tell you how the game plays. If you want to know whether everyone's got it, ask in the chat, which is where that conversation was always going to happen.

### Facets, not genres

Steam's genre field says Action / Adventure / Indie / RPG on nearly everything on your shelf. It does not help anyone choose. The edge function reads Steam **user tags** instead and classifies each game on two axes:

- **Vibe** — cozy, chaotic, tense, competitive
- **Shape** — drop in, one sitting, campaign, long haul

Three more come from a curated list rather than Steam, because Steam does not publish them:

- **Energy** — chill, normal, heavy
- **Player cap** — Steam knows a game is co-op, it does not know the cap
- **Setup** — just launch, someone hosts, dedicated server. The silent killer of game nights

### Editing history

Every group starts with a shelf they have already been playing for years, so a card that says *never played* for all of it is just wrong. Open a game's detail sheet and under **Have we played it** you can log one, with or without a verdict. It files as *Before this* rather than a round number, since it happened before any of this existed.

Tapping a different verdict on a game already logged changes it. The ✕ on a row removes it. The game currently on can't be removed this way, because that's what **Changed our minds** is for.

### The curated list

`data/curated.json` covers 76 games. Every app ID and player cap in it was verified against Steam store pages, official wikis or developer posts, not guessed. Anything unconfirmed is `null`, and the app says **cap unknown** rather than inventing a number.

Adding a game that's already in the list means it arrives knowing its cap, energy and setup. Anything outside it starts blank and whoever knows fills it in.

Caps get re-checked against the store page when something looks off. The most recent pass found Voyagers of Nera listed as *cap unknown* when Steam plainly says "up to 10 people on a server", and softened Necesse's note to quote the devs ("a dedicated server takes hundreds") rather than implying a number you could filter on.

**Mods are tracked separately, on purpose.** Plenty of games go higher than their official cap with a mod or a server config: Lethal Company is 4 until someone installs MoreCompany, Palworld is 4 co-op but 32 on a dedicated server, Stardew is 4 cabins until you unlock the config. So `crew_max` stays the official number and `crew_mod` carries the bigger one.

That matters for the crew-size filter. A game that can't seat everyone is hidden. A game that *could* with a mod is kept and labelled **needs a mod**, because "you can play this if someone installs something" is useful and "it silently vanished" is not.

### What Steam fills in by itself

Paste a Steam link or pick from search and the edge function fetches the lot:

| Filled automatically | Not in Steam's data |
| --- | --- |
| Name, cover image, short and long description | Co-op player cap |
| Review score, review count, review wording | How much energy a night costs |
| Genres, user tags, categories | Whether someone has to host |
| Release date, and the derived vibe and shape | |

The right-hand column is what `data/curated.json` is for, and for anything outside that list the card says **cap unknown** until whoever owns it fills it in.

Cover art comes straight off Steam's CDN by app ID, so there is nothing to upload and nothing to keep in sync.

### Adding a game

Type a name and hit the arrow, or press Enter. Paste a Steam link or an app ID and it skips search entirely and fetches that exact game, which is what you want when you already have the store page open.

A game counts as addable if Steam lists it as multiplayer, co-op, PvP or split screen. Party games often list only "Online PvP" with no co-op category at all, and rejecting those would throw out exactly the sort of thing a game night is for.

One button. It goes straight up for a vote:

| Button | What it does |
| --- | --- |
| **Add it** | Onto the shelf, up for a vote, credited to you |

### After you've played it

A game never leaves the shelf. What changes is that it gains history.

| Stage | What you see |
| --- | --- |
| You call it | **Now playing** replaces the round strip, the card gets a *playing now* badge |
| You finish it | **Finished it** asks how it went: banger, fine, or never again. Skippable |
| Later | The card carries a *played* badge and a line reading *Played 3d ago · ★ Banger*, with the count when there's been more than one go |

Play it again by voting for it again, same as anything else. Nothing needs resurrecting, because nothing was buried. Two filter chips, **Never played** and **Played before**, are there for when you want one or the other, and **By played** as a grouping if you'd rather see the split.

The verdict is the only memory the group keeps about whether something was actually any good, and it's the thing that stops you rediscovering the same mistake in eight months. `plays` stores one row per game per round, so a game you come back to stacks up rather than overwriting.

**Changed our minds** reopens a locked round if you called it too early and nobody has played yet.

### Where each facet comes from

Worth knowing which numbers are ours and which are Steam's, because it changes how much to trust them.

| Facet | Source | Correctable |
| --- | --- | --- |
| Energy | Us. Curated for 76 games, blank otherwise | Yes, any member |
| Player cap | Us. Steam says "co-op", never how many | Yes, any member |
| Setup | Us. Steam does not model who has to host | Yes, any member |
| Vibe | Steam user tags, scored into four buckets | Yes, the group overrides the guess |
| Session length | Same tag scoring | Not yet |
| Everything else | Steam, directly | No, it's their data |

Vibe is a guess and is treated like one. It stays blank when the tags say nothing useful, rather than defaulting to a confident wrong answer, and any member can correct it from the game's detail sheet.

### Chrome, deliberately thin on a phone

An earlier pass stacked a scrolling tab row, a scrolling toolbar and a header that all moved independently. Everything looked clipped and nothing sat still. The fix was less, not better:

| | Phone | Desktop |
| --- | --- | --- |
| Tabs | None. One shelf, sectioned | Same |
| Toolbar | Search on its own row, then Filters, Arrange, layout | One row, same four things |
| Filters | Full screen, staged, Apply commits | Centred dialog, staged, Apply commits |
| Theme | One toggle, light or dark | Same |
| On scroll | The toolbar sticks under the header as one unit | Same |

**One filter surface.** There used to be two: a staged sheet on phones and a live inline panel on desktop. Two layouts, two behaviours and two sets of bugs for one feature. Now it is the same dialog everywhere, full screen where the screen is small and centred where it isn't, staged in both.

Arrange and the card/list toggle stay out on the toolbar at every size, because you change them far more often than you filter and burying them behind a modal is two taps too many.

Nothing scrolls sideways and nothing animates out of the way, because a control that moves while you are reaching for it is worse than one that takes up a bit of room.

### Filters

Nine filters, all combinable.

Each group used to carry an explanatory sentence under its heading. Six of them in one dialog turned out to be more reading than the entire shelf, and "Chill / Normal / Heavy" under a heading that says **Energy** does not need help. The sentences are gone and the dialog now fits on one screen without scrolling.

When a stack of filters matches nothing, the footer button doesn't go dead. It becomes **Nothing matches. Start again** and clears them in one tap, because a disabled button over seven selected chips is a dead end you have to dig yourself out of.

| Filter | What it answers |
| --- | --- |
| Crew size | Can this seat everyone who's in tonight |
| Energy | How much brain does it need |
| Session shape | A quick one, or something you commit to |
| Vibe | Cozy, chaotic, tense, competitive |
| Setup | Who has to do work before anyone plays |
| My picks | What have I already chosen |
| Never played / Played before | Fresh, or a return visit |
| Nobody's picked it | What's being quietly ignored |
| 85%+ on Steam | Is it actually any good |

On a phone the filters take over the whole screen, with the page behind them locked, and changes are **staged**: the sheet covers the results, so committing every tap would mean applying changes you can't see. Instead the Apply button carries the live count, closing without applying changes nothing, and Clear shows how many are on. Desktop keeps the inline panel and applies live, because with a mouse you can see the shelf react.

### Once the shelf is long

Three things stop 70 games becoming an unscrollable wall:

- **Arrange** is one control for order and sections together, split into **One list** (Most votes, A to Z, Best reviewed, Newest) and **In sections** (What's in play, Energy, Length, Faff, Played or not). Those two headings replaced a subtitle under every single option. Same chip pattern as the filters, so it's one interaction to learn, not two
- **List view** is the dense table
- **Just pick one** rolls at random from whatever survived your filters

### What the filters cover

Everything, uniformly. One pool, one filter pass, no exceptions. This used to be a genuinely awkward question, because with a backlog sitting in its own tab there was no good answer to "does this filter reach it". Removing the backlog removed the question.

Benched games are the single exception, and only because being out of the way is the entire point of benching one. The **Benched** chip shows *only* the bench, and appears only when there's something on it.

It used to say *Show benched* and add them to the shelf, which made it the one chip that widened the results while every other one narrowed. That's why the label read two ways. Now it narrows like the rest, and it matches what you actually want it for: finding something to put back.

### Identity, and never typing your name twice

A person is a `member` row with a stable `member_id`. Devices are a separate table pointing at it, so one human on a phone and a laptop stays one human. Ballots, picks and takes all key on `member_id`, never on a device, which means linking a second device carries the whole history with it.

Three things fall out of that:

| Situation | What happens |
| --- | --- |
| You come back on the same device | `whoami` recognises you before the page renders. Never asked again |
| You open the link on a second device | You type a name, and if it looks like someone already here you are offered them |
| Someone types `soli` when `Soli` exists | Same offer. Tap it and your picks carry across |

The matcher normalises case, accents and punctuation, then scores four ways: exact match, one name being a prefix of the other (`Soli` / `Soli L`), a shared first token (`Soli L` / `Soli B`), and an edit distance of one or two (`Soli` / `Solli`). Anything scoring 60 or above is offered, with enough context to recognise yourself: how many picks they have, when they were last here, how many devices.

Claiming is additive, not a takeover. The original device keeps working, and a person with more than one device linked shows a small count in the crew list, which is the only visible signal that it happened.

Nobody is asked for a name until they tap their first pick. Every step before the payoff is a place to leave.

### Removing things

Nothing is ever deleted. Any member can take a game off the shelf with **Bench it** in the game's detail sheet, which pulls it out of everyone's current picks. Takes and the whole play history survive, the **Benched** filter chip finds it again, and **Put it back** undoes it. Reversible, and nobody can nuke the shelf.

---

### Links that unfurl in Discord

The app is one static page with a hash route (`#/g/CODE`), and hash fragments are never sent to a server, so a crawler can't tell which group a link points at. Pasting the raw link into Discord gets you a bare URL.

`supabase/functions/card` fixes that. It serves a tiny HTML page carrying real Open Graph tags for one group, then bounces humans straight on to the app:

```
https://<project>.supabase.co/functions/v1/card?g=XXXXXXX
```

Paste that anywhere and it unfurls with the live state:

> **Brisbane crew**
> Valheim leading with 3 votes · 4 of 5 in
> *(with Valheim's Steam header as the image)*

The image is Steam's own 460x215 header for whichever game is leading, so there's no image rendering anywhere in the stack. Discord, Slack, iMessage, WhatsApp, Teams and Notion all read those tags. Cached for two minutes, because the chat apps re-fetch on every paste but the whole point is that it's current.

Both are covered in steps 3 and 5 of the setup above.

**Notion** also takes the plain app link as an `/embed` block and renders the whole thing in an iframe, which works but won't show a preview when collapsed. The `card` link is the better one to paste inline.

---

## Files

| File | What it is |
| --- | --- |
| `index.html` | The whole app. No build step |
| `supabase/schema.sql` | Eight tables, row level security, nineteen RPCs |
| `supabase/functions/card/index.ts` | Serves Open Graph tags per group so links unfurl in chat, then redirects |
| `supabase/functions/enrich/index.ts` | Steam search, fetch, validation, facet classification |
| `data/curated.json` | 76 verified games with caps, energy, setup and mod caveats, mirrored as `CURATED` inside index.html |
| `.github/workflows/keepalive.yml` | Weekly ping and stale-data refresh |

---

## Changing things

**Different seed games.** Edit the `SEED` array in `index.html`, which is just a list of app IDs. To add facets for a game, add it to `CURATED` in the same file and to `data/curated.json` so the two stay in step.

**Different quorum.** How many have to vote before *Call it* says it's enough. Ships at 5, which suits a group of about ten. `update groups set quorum = 3 where code = 'XXXXXXX';`

**Typography.** No webfont. The page uses the native UI face on whatever device you open it on, San Francisco on Apple, Segoe on Windows, Roboto on Android, so there is no font file to download, nothing to flash while it loads, and one less external request the page depends on. If you ever want a custom face, the whole thing is one token: `--f-body` at the top of the style block.

**Realtime instead of polling.** The page polls every 10 seconds while the tab is visible. Supabase realtime would be live, but needs replication enabled per table in the dashboard. Polling is one less setup step and for six people it is indistinguishable.

---

## Costs and limits

Free on both tiers, comfortably.

| | Free tier | You will use |
| --- | --- | --- |
| Supabase database | 500 MB | Well under 1 MB |
| Supabase edge invocations | 500k / month | A few hundred |
| GitHub Pages | 100 GB / month | Nothing close |
| GitHub Actions | 2000 min / month | Roughly 1 minute a week |

Steam is called once per game ever, then cached globally, then refreshed monthly.

---

## Known limits, stated honestly

- **Group codes are obscurity, not security.** Seven characters from a 30-character alphabet is fine for keeping a game night private. It is not a login, and it should not hold anything you would mind a stranger reading.
- **The anon key is public.** It has to be. Row level security and the RPC-only interface are what actually protect the data, not the key.
- **Player caps can be wrong.** Steam does not publish them. The seeded ones are best-effort and some are deliberately left blank rather than guessed. Correct them in the app.
- **No deletes.** Nothing in the app can remove a game or a person, on purpose. If something needs to go, do it in the Supabase table editor.
