# Game Night

Pick what we play next. One shelf, one vote, as many friend groups as you need.

Live on GitHub Pages, data in a free Supabase project. No accounts for anyone who votes, just a link.

## What it runs on

| | |
| --- | --- |
| App | GitHub Pages, e.g. `https://your-name.github.io/game-night/` |
| Backend | A free Supabase project, with edge functions `enrich`, `prices`, `card` and `discord` |

### How the links work

There are three kinds of link and they do different jobs.

| Link | Looks like | Use it for |
| --- | --- | --- |
| **Group link** | `…/game-night/#/g/ABC1234` | The one to send round. Opens straight onto that crew's shelf. First visit asks your name once, then that device is you |
| **Card link** | `https://YOUR_PROJECT_REF.supabase.co/functions/v1/card?g=ABC1234` | Meant to unfurl with the group name, the current leader and its cover art, then bounce people to the group link. **Caveat:** Supabase serves HTML from edge functions on its own domain as plain text, so Discord likely shows no preview. For Discord, use the scoreboard instead (below) |
| **Bare link** | `…/game-night/` | The landing page. Start a crew, or type in a code. Not the one to share: a mate who lands here without a code will start a new crew by accident, which is exactly what happened on day one |

The seven-character code is the group. Anyone with it can vote, add and call rounds, so treat it like a Discord invite rather than a password. **Send to the chat** in the app has a **Copy the link** button so nobody has to build it by hand.

The join box on the landing page takes either the seven characters or the whole link pasted in (the code gets pulled out of it), uppercases as you type, and says what's wrong inline rather than in a browser alert.

### Who can get in

| Question | Answer |
| --- | --- |
| Can a stranger find a crew? | Not by browsing. There's no list of crews anywhere, and codes are 7 characters from a 30-letter alphabet (no 0/O, 1/I/L): about 22 billion combinations. Guessing one is not a realistic attack |
| So what's the actual risk? | The link leaking, e.g. someone screenshots the group chat. Then they can do what any member can: vote, add games, bench them, call a round |
| What can't they do? | Delete anything. For everyone else benching is reversible, rounds reopen, and play history can be edited but not wiped. Only whoever started the crew can remove things for good (see **Looking after a crew**), and nobody can become them by typing their name |
| What protects the database itself? | Row level security with zero policies, so the public key can read one table (`games`, Steam data) and nothing else. Every write goes through a function that checks the group code, and editing the crew checks you're a member of it |

### Crew name and emoji

Each crew has an emoji. It's the browser tab icon while you're looking at that crew, the tile in your crews list and the button in front of the crew name in the header. Tap that button (or **⋯ → Edit crew**) to change the name or emoji. Anyone in the crew can, same as anyone can bench a game.

The picker is about 330 hand-picked emoji in nine tabs (games, faces, animals, food, nature, activity, travel, objects, symbols) with search words on each, plus your recent picks at the top. Anything outside the set can be pasted into the search box, or typed with the OS emoji picker (Ctrl+Cmd+Space on a Mac, Win+. on Windows).

**Crew colour.** The accent takes the emoji's main colour: 🦀 goes orange, 👾 purple, 🌿 green, 💙 blue. The emoji is drawn on a small off-screen canvas and the strongest colour wins; only its hue and a capped saturation carry over, with lightness set per theme. In light mode each gradient stop is walked darker until white text clears 4.5:1, and the second stop never swings into yellow under a white label (yellows get dark text instead). Emoji with no real colour, like 🎮 or 💀, keep the lavender. The first member to open the crew after the emoji changes works the colour out and saves it with `set_tint`, so every phone and PC shows the same shade even though they draw emoji differently. Picking an emoji in Edit crew previews the colour before you save.

**Linked browsers.** Every browser or phone that opens a crew as you is linked to you, so *That's you* might say "Linked on 6 browsers". They all vote as the same person; votes, takes and history belong to you, not the device. **Unlink the others** keeps the one you're on and forgets the rest (they'll ask who you are next time), which is worth doing after swapping phones or using someone else's laptop.

Your crews list is saved per browser, not per account. There are no accounts. A browser that has never opened a crew link has an empty list; open the link or type the code and it's added.

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

You should see `Success. No rows returned`. That creates nineteen tables, locks them all behind row level security with no policies, and exposes forty-six functions to the anon key. That is the whole security model: no direct table access, everything through a function that takes a group code.

### 3. Edge functions

Four of them. `enrich` is the only place Steam data can be fetched, because Steam sends no CORS headers and a browser can never call it directly. `prices` does the same for Steam prices. `card` serves link-preview tags. `discord` keeps the crew's Discord scoreboard up to date.

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF     # the abcdefgh bit from your URL
supabase functions deploy enrich --no-verify-jwt
supabase functions deploy card   --no-verify-jwt
supabase functions deploy discord --no-verify-jwt
supabase functions deploy prices  --no-verify-jwt
```

`--no-verify-jwt` matters on all four: they're called with the anon key, not a logged-in user token.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically. `card` and `discord` need one more, but you won't know its value until step 5.

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

### 7. Start your crews

Open the site, pick an emoji and a name, and create the crew. It starts with an **empty shelf**, which says what to do: **Add a game** (search Steam by name or paste a store link) or **Send the link to the crew**. Anything in the curated list arrives with its player cap, energy and setup already filled in.

**Add a few and vote before you send the link.** An empty vote is a dead vote: the first person to arrive and see zero picks decides it is not a real thing yet and closes the tab. Chuck in a handful, cast your three, then share.

Each crew has its own shelf, members and history.

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

### Next sesh

Picking the game and picking the nights are two separate decisions. A game like Valheim runs over several nights, so the date vote hangs off whatever's being played, not off the round. It only shows up once a game is called, so it never competes with the vote.

| Step | What you see |
| --- | --- |
| A game gets called | A line on the status card: "When are we playing? Tap your nights" |
| Tap it | The next 10 days as chips. Tap every night you're free; yours get a tick. Each chip says how many are free and fills towards the crew's number, and the line says how far off the best night is ("Thu 24 is 1 short"). **Can't do any of these** counts as an answer too |
| A night reaches the number | It's **pencilled in**, and the line turns lilac. Anyone can tap **Lock in Thu 24, 8pm** to lock it |
| Locked | The line goes solid. **Add to Google Cal** opens Google Calendar with the event filled in (no download); Apple or Outlook get a calendar file instead. **Change night** unlocks it |
| The night passes | The line asks **Did you play Thursday 24 Sept?** "We did" logs a session and the card counts them ("3 nights so far"). Either answer clears the slate for the next one |

**The crew's number** lives in **⋯ → Night rules** (also one tap from the day picker, which shows the current rule): "A night works when all 4 / 8 of 10 / … are free", plus the usual start time (typed as you'd say it: 8pm, 7:30pm, 20:00). "All" means everyone in the crew and keeps meaning that as people join. You can also set a number bigger than the crew is today (up to 12): a crew of one can say "3 free", and it counts as everyone until the others join. A small crew might only play when everyone's free; a bigger one might go at 80%.

On a phone it's the line on the status card. On desktop it's also a **Next sesh** card at the top of the right-hand rail, with ten little bars per game so you can see the shape of the fortnight at a glance.

Taps save 600ms after the last one, so picking four nights is one request, and the background refresh stands down while a save is in flight so the server can't briefly undo a tap.

**Reminders:** there are no accounts, so there are no push notifications. **Send to the chat → When's next** writes it up for Discord instead: which night has how many, what's pencilled or locked, and who still owes their nights. The Discord preview from the card link carries it too: "· next sesh Fri 26 Sept, 8pm" once locked, the pencilled night before that, otherwise how many have picked their nights.

### Discord scoreboard

A link preview can't update itself or carry buttons, so instead the crew gets one message in their channel that keeps itself current.

| Step | What happens |
| --- | --- |
| Set up (once) | **⋯ → Send to the chat → Live Discord scoreboard**. In Discord: channel cog → Integrations → Webhooks → New Webhook → Copy Webhook URL. Paste, **Connect**, and the first scoreboard posts straight away |
| While voting | Round number, how many have voted, the top picks, who's still to vote, the leader's cover art |
| While playing | What's on, nights so far, where the next night is at (locked, pencilled, or who still owes their nights) and any side games |
| Small changes | A vote, a night ticked, a game added: the same message is edited, batched over three seconds so a flurry of taps is one edit. Nothing changed, nothing sent |
| Big moments | A round called, a new round, a night locked, a side game started: a fresh message posts (so the channel lights up) and the old one is marked as old |

The title links to the crew, so it's one tap from Discord to voting. The webhook link lives in the database and only the `discord` function reads it; `get_state` only says whether one is set. If someone deletes the webhook in Discord, the next update notices and switches the scoreboard off. Voting from inside Discord (buttons, a `/gamenight` command) would need a proper Discord bot, and this is the base it would build on.

### Sending to the chat

Everything that goes to a group chat lives in one sheet, **⋯ → Send to the chat** (also on the Who's in card and the empty shelf):

| Option | Where it works | How |
| --- | --- | --- |
| **Live Discord scoreboard** | Discord | One message that edits itself (below). The only one that updates on its own |
| **Snapshot** (the default) | Anywhere that takes a picture: Discord DMs and group DMs, Messenger, WhatsApp, iMessage | The Discord scoreboard drawn as a PNG in the browser: same card, crew colour, top picks or next sesh, the leader's cover. **Copy image** and paste, **Share…** on a phone (the link goes with it), or **Save**. It doesn't update itself |
| **Link / Update / Reminder / When's next** | Anywhere: WhatsApp, Messenger, iMessage, Slack, Teams | A one-off message, previewed. **Copy it**, or on a phone **Share…** opens the system share sheet straight into those apps |

WhatsApp and Messenger have no webhooks for group chats, so they can't have a live scoreboard; a one-off message is as good as it gets there. Slack, Teams and Google Chat do have incoming webhooks and could get their own scoreboard later.

### The right-hand side

On desktop it's a rail; on a phone the same panels sit under the shelf. Order: Who's in, Next sesh (while playing), Ready to play, On sale now, Our record.

| Panel | What it shows |
| --- | --- |
| **Next sesh** | While something's being played: ten little bars per game for the nights ahead |
| **Ready to play** | Games the whole crew already owns, most voted first. **Tick what you own** opens a checklist of the shelf; each tap saves. Cards say "✓ everyone owns it" or "3 to buy", and details says who owns it |
| **On sale now** | Shelf games discounted on Steam right now, biggest cut first, with price, was-price and how many still need to buy. Cards get a green −50% badge. Prices are AUD, refreshed by the `prices` function when a crew opens, at most every four hours |
| **Our record** | Games played, nights played, bangers, a hall of fame, and the last few things that happened ("Sam and Alex voted", "Alex added 3 games", "Wrapped up Valheim · ★ Banger"), pieced together from timestamps the crew already has |
| **Who's in** | The crew, who's here now, who's voted |

**A dead heat is never dressed up as a ranking.** The ranking is grouped by vote count, so three games on two votes each are one tier, not first, second and third. A tier with one game in it gets its medal (🥇 🥈 🥉); a tier with several gets 🤝 and "2 votes each". The heading changes from **Top picks** to **Dead heat**, no cover art is picked (there is no single face to show), and the copy-text version marks the tie as `=1.` rather than numbering it 1, 2, 3. The status card names the tied games instead of saying "and 2 more", and the line opens a list of them with who picked each. These rules live in both `index.html` and `supabase/functions/discord/index.ts` and have to agree, or the snapshot and the live scoreboard will tell the crew different things.

**Spin for it:** on a dead heat the status card gets a 🎡 button. It spins a wheel of the tied games, lands on one, and **Lock in** calls the round for that game rather than whichever happened to be first.

### Folding sections

With the shelf split into sections (**In the running**, **Nobody's picked it yet**, …), click a heading to fold it shut and again to open it. It's remembered per crew in that browser, like your filters.

### Side games

For when a few of you want something else going alongside the main game, without a second vote or a second crew.

- Open any game's **⋯** while something is called, then **Play it on the side**. It gets its own strip under the status card, with who's in and an **I'm in / I'm out** button
- A side game picks its own nights the same way, and it needs everyone who's in on it
- **⋯ → Wrap it up** asks for a verdict and puts it in play history like any other game. Nothing is deleted
- Up to three at once. The card carries an "on the side" badge

A separate crew is still right for a different friend group. Side games are for the same crew splitting for a bit.

### Games that aren't on Steam

Browser games (skribbl.io), Epic (Fortnite), console games: **Add a game → Not on Steam? … add it yourself**. Type a web address like `skribbl.io` first and it fills the name and link and guesses Browser + free.

| Field | Notes |
| --- | --- |
| Name | Up to 60 characters. The same name in the same crew puts the existing one back rather than doubling up |
| Where you play it | Browser, Epic, Xbox, PlayStation, Switch, Elsewhere. Shows as a badge on the card |
| Link | Optional. Details gets **Play ↗** (browser) or **Open ↗** instead of Steam ↗ |
| Free to play | Free games count as everyone owns them, so they land in Ready to play straight away |
| Up to how many | The player cap, same as Steam games |

They're stored in the games table under a negative appid (`add_custom_game`), owned by the crew that added them, so voting, nights, side games, the Discord scoreboard and the snapshot all work unchanged. There's no Steam data, so no cover art (a coloured tile instead), reviews or sale price, and the weekly Steam refresh skips them. Fix a name, link or platform later from details (`update_custom_game`).

### Details

Tap a card's **⋯**, or in the list view tap anywhere on a row (each has a › chevron). Long Steam descriptions fold to four lines with **Read more / Show less**.

On a phone, short bottom sheets open at about half the screen with a grabber, content from the top and actions at the foot; tall ones (details, filters) are full screen.

### Released, early access, not out yet

Steam flags "coming soon" itself and lists Early Access as a genre (only the genre counts: player-voted tags keep "Early Access" for years after 1.0), so every game is one of **Released**, **Early access** or **Not out yet**. Cards badge the last two in the corner, the details sheet says so next to the reviews (with the date text for unreleased ones, e.g. "Q2 2027"), and **Filters → Release** narrows to any of them. Games with a free demo get **Try the demo ↗** in details and a **Has a demo** filter.

### Game states

Every game on the shelf is in exactly one state. It's derived from `benched` and the play history, never stored twice, so there's one definition and nothing to keep in sync.

| State | What it means | Action | How it moves |
| --- | --- | --- | --- |
| **Up for a vote** | On the shelf. Which is nearly everything | Pick | Wins a round, or gets benched |
| **On right now** | Won the round | Locked | Done for now, or Changed our minds |
| **Benched** | Someone parked it, or it got a never-again | Put it back | One tap, any member |

**There is no backlog.** There used to be: a game nobody owned sat in a second list until two people boosted it. For ten mates that's a nomination process nobody asked for, and it created the worst kind of bug, where a game is *technically there* but invisible. Now a game is up for a vote the moment it's added, and the only thing that takes one out of view is someone deliberately benching it.

**Played** is not a state, it's history. A game can be up for a vote and also have been played three times, so it shows as a line on the card rather than a place games go.

One card component serves all three. Same cover art, same facets, same layout, with the badge and the primary action changing.

**There are no tabs either.** The whole shelf is on screen, always, split into sections with a count on each. The default split is the one that matters on the night:

- **▶ On right now**: if a round is locked in
- **In the running**: anything with at least one vote
- **Nobody's picked it yet**: the rest

That's a free consequence of the default sort, so the headings just make the boundary explicit. At the start of a round nothing has votes, so the split collapses to one unlabelled shelf rather than putting an empty header on screen.

Sections are a grouping, so you can switch them to energy, length, faff or played, or flatten to one long list. The count line above the shelf only appears when it has something to add: *9 of 15 shown* while filtering, or *nothing has been picked yet* on a fresh round. Unfiltered it was repeating the section heading sitting directly below it.

### What happens to a finished game

Nothing is guessed. **Done for now** asks two questions and both are one tap:

1. How was it: banger, fine, never again. Skippable
2. Where does it go: leave it up, or bench it

**Leave it up is the default**, and it means exactly that: the game is up for a vote again immediately, carrying its verdict and play count on the card. Playing it again is just voting for it again. Nothing is hidden and nothing has to be resurrected.

**Bench it** takes it off the shelf and out of everyone's picks. It's still there behind the **Benched** filter chip, and one tap on **Put it back** returns it.

That's deliberate. Auto-benching would bury a long-haul game you're still enjoying, and auto-keeping lets a dud keep winning. Picking *never again* pre-selects benching, since that's almost always what you meant. Either way everyone's picks and energy reset for the next round.

### Who added it

For a while this section was about tracking who *owns* each game, with a tappable pill on every card. It got cut, and the reasoning is worth keeping because it applies to most features like it.

The pitch was that it answers "who can host this". That was wrong. Most co-op games need **everyone** to own a copy, not one host, so a single owner name never actually told you whether the night could go ahead. Tracking it honestly would mean ten people ticking a box on seventy-odd games, which nobody was ever going to do, and a half-filled ownership list is worse than none because it looks authoritative.

What replaced it costs nothing: the card says **Added by Sam**. It's set once, automatically, never goes stale, and it points at the person who can actually tell you how the game plays. If you want to know whether everyone's got it, ask in the chat, which is where that conversation was always going to happen.

### Facets, not genres

Steam's genre field says Action / Adventure / Indie / RPG on nearly everything on your shelf. It does not help anyone choose. The edge function reads Steam **user tags** instead and classifies each game on two axes:

- **What we'll be doing**: mucking about, building something, a story, scary, runs and rounds
- **Shape**: drop in, one sitting, campaign, long haul

Three more come from a curated list rather than Steam, because Steam does not publish them:

- **Energy**: chill, normal, heavy
- **Player cap**: Steam knows a game is co-op, it does not know the cap
- **Setup**: just launch, someone hosts, dedicated server. The silent killer of game nights

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

**+** on the toolbar opens a sheet. Type a name and hit the arrow, or press Enter. Paste a Steam link or an app ID and it skips search entirely and fetches that exact game, which is what you want when you already have the store page open.

A game counts as addable if Steam lists it as multiplayer, co-op, PvP or split screen. Party games often list only "Online PvP" with no co-op category at all, and rejecting those would throw out exactly the sort of thing a game night is for.

One button. It goes straight up for a vote:

| Button | What it does |
| --- | --- |
| **Add it** | Onto the shelf, up for a vote, credited to you |

**Two search boxes on one page was the single most confusing thing in the app.** The toolbar one filters the shelf you already have. The Steam one finds something you don't. For a while they sat on the same page, one at the top and one 6,000px down at the bottom, and renaming them only half fixed it. Now the Steam search lives in its own sheet behind **+**, so at any moment there is exactly one search box on screen and it is obvious which shelf it searches.

The sheet also fixed a real bug: the Steam box used to sit inside the page, and the page re-renders on every keystroke and every poll, which emptied the field and dropped focus after the first character. Search looked broken because it was. The field now keeps its value in state and the renderer puts the caret back where it was, so a poll landing mid-word changes nothing.

### After you've played it

A game never leaves the shelf. What changes is that it gains history.

| Stage | What you see |
| --- | --- |
| You call it | **Now playing** replaces the round strip, the card gets a *playing now* badge |
| The crew moves on | **Done for now** asks first, then how it went: banger, fine, or not for us. Skippable. "Finished" was the wrong word: nobody finishes Valheim, the vote just reopens |
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
| What we'll be doing | Steam tags scored into five buckets, categories as tiebreak, genres as fallback | Yes, the group overrides the guess |
| Session length | Same tag scoring | Not yet |
| Everything else | Steam, directly | No, it's their data |

It is a guess and is treated like one, but unlike the axis it replaced it is never blank, and any member can correct it from the game's detail sheet.

**This one replaced a "vibe" axis, and the reason is worth keeping.** Vibe sorted games into cozy / chaotic / tense / competitive off Steam user tags. Measured against a real 16-game shelf it was **blank on 7 of them**, including every big survival game, because their tags never hit a vibe keyword. And when it did fire it was redundant: every one of its `cozy` keywords was also an `energy` keyword, so cozy meant chill, computed twice. Length and energy agreed 81% of the time as well. Four axes were behaving like about one and a half.

**Mode of play asks a different question from effort**, so the two stop colliding, and it can fall back through tags, then Steam's publisher-declared `categories`, then genres. Blank rate on the same shelf went from 7 of 16 to **0 of 16**.

The rules are weighted rather than counted, because one strong signal should beat three weak ones. Barotrauma is tagged both *Survival* and *Survival Horror* and has to come out scary. PICO PARK 2 carries a junk *Psychological Horror* tag from SteamSpy, so horror sits at low weight and loses to *Casual*.

### Chrome, deliberately thin on a phone

An earlier pass stacked a scrolling tab row, a scrolling toolbar and a header that all moved independently. Everything looked clipped and nothing sat still. A later pass had fixed that and then quietly grown a round panel, a cover-art hero, a vote leaderboard in the rail and a bottom bar, four of which named the same leading game. Measured on a 390px phone: 579px of controls before the first card, 87 tappable things on the page, 8 screens of scroll for 15 games.

The fix, both times, was less:

| | Phone | Desktop |
| --- | --- | --- |
| Tabs | None. One shelf, sectioned | Same |
| Status | One strip: round, who leads, how many are in, **Call it** when it is ready, and a ⋯ menu for the rest | Same |
| Toolbar | Search with **🎲** and **+** beside it, then Filters, Arrange, layout | One row, same six things |
| Filters | Full screen, staged, Apply commits | Centred dialog, staged, Apply commits |
| Leaderboard | The shelf, sorted. Nothing else lists the votes | Same |
| Bottom bar | Your own picks and a Share button. Group state stays in the strip | None; the rail has Who's in and Send to the chat |
| Theme | One toggle, light or dark | Same |

After: 305px before the first card, 57 tappable things, 5.3 screens for the same shelf. The card went from 13 pieces of text and six pills to 8 and none: cover, name, one line, energy, cap, length, and the first take. Reviews, setup, Steam link, who added it and the long blurb moved behind **⋯** on the card, along with the take box and the cap editor, so there is one details surface per game instead of three.

**One filter surface.** There used to be two: a staged sheet on phones and a live inline panel on desktop. Two layouts, two behaviours and two sets of bugs for one feature. Now it is the same dialog everywhere, full screen where the screen is small and centred where it isn't, staged in both.

Arrange and the card/list toggle stay out on the toolbar at every size, because you change them far more often than you filter and burying them behind a modal is two taps too many.

Nothing scrolls sideways and nothing animates out of the way, because a control that moves while you are reaching for it is worse than one that takes up a bit of room.

### Filters

Every filter combines with every other, in one staged dialog at every screen size.

The eight filters sit in three named sections, because what they are about differs:

| Section | Holds | Why together |
| --- | --- | --- |
| **Tonight** | How many of us, Energy, How long | Changes every session, depends who turned up |
| **The game** | What we'll be doing, Setup, Release | Properties of the game, not of tonight |
| **Our record** | Have we played it, Only show | The crew's history with it |

Each section owns a two-column grid, and a group with a lot of chips spans both columns so nothing wraps to a line of one.

Three earlier mistakes are worth recording, because all three looked fine until someone used it:

- **Six identically weighted grey headings.** *How many of us* and *Vibe* were typographically the same thing, so nothing looked more important than anything else. Nothing was findable because everything was equally findable. There are two levels now: the section name, then the filter label.
- **A group called Shortcuts.** It held *Only my picks*, *Never played*, *Played before*, *85%+ on Steam* and *Benched*. That is not a category, it is a leftovers drawer, and two of those five were mutually exclusive while looking like independent toggles. *Never played* and *Played before* are now one three-way control (**Either / Never / We have**), and the rest sit under **Only show**, which says what they do.
- **A fold called "More filters".** Hiding the five less-used filters behind one disclosure made the same mistake again under a new name: *More filters* is not a category either. Worse, `<details>` was a single grid item, so everything inside it was squeezed into one column while the other half of the dialog sat empty. Grouping them honestly removed the need for a fold at all. On a phone the dialog scrolls, which is cheaper than hiding things.

**Options with nothing behind them are hidden, not greyed out.** A chip reading *One sitting 0* is a dead control taking up a row. The exception is one you have already selected, which stays visible or you could not turn it off.

**Filters are remembered per group.** Coming back to the same crew should not mean setting up "six of us, nothing heavy" from scratch every visit. The search box and the bench view are deliberately not saved: a search term you can't see the source of, or a shelf that opens showing only benched games, both read as the app being broken.

When a stack of filters matches nothing, the footer button doesn't go dead. It becomes **Nothing matches. Start again** and clears them in one tap, because a disabled button over seven selected chips is a dead end you have to dig yourself out of.

| Filter | What it answers |
| --- | --- |
| How many of us tonight | Can this seat everyone who's in |
| Energy | How much brain does it need |
| How long | A quick one, or something you commit to |
| What we'll be doing | Mucking about, building, a story, scary, or runs and rounds |
| Faff to get going | Who has to do work before anyone plays |
| Have we played it | Either, never, or a return visit |
| Only show → my picks | What have I already chosen |
| Only show → 85%+ on Steam | Is it actually any good |
| Only show → the bench | What did we park, and should it come back |

Changes are **staged everywhere**, phone and desktop alike. The dialog covers the results at both sizes, so committing every tap would mean applying changes you can't see. The Apply button carries the live count, closing without applying changes nothing, and Clear shows how many are on.

It does not fit on one phone screen any more, and that is a deliberate trade. Chips are 40px tall so a thumb hits them, and the crew block earns its space. The Apply button is pinned to the bottom and never moves, so scrolling the middle costs you nothing.

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
| Someone types `sam` when `Sam` exists | Same offer. Tap it and your picks carry across. Two people can't have exactly the same name in a crew, so if it isn't you, it asks for an initial or a nickname instead of making a `Sam (2)` |
| You start using a new phone or computer | **Link another device** (below) brings every crew across at once |
| A crew gets a new code | Every device already in it finds it again under the new code (`my_crews`), and says the old link doesn't work any more |

**Opening a crew link and giving your name joins you to that crew** and adds it to **Your crews** on that device's landing page. That's per device, because there are no accounts.

**Link another device.** On the device you already use, tap your name, then **Link another device**. It shows a six-character code (and a link to copy or share) that works once, for ten minutes. On the new device, open Game Night and tap **Using it somewhere else already? Link this device**, or just open the link. The new device becomes you in every crew the old one is in, and they all appear under Your crews. A crew the new device had already joined keeps whoever it already was there. `start_pairing` / `finish_pairing` do this server-side; the code is short-lived and single use, so it's safe to send to yourself in a chat.

The matcher normalises case, accents and punctuation, then scores four ways: exact match, one name being a prefix of the other (`Sam` / `Sam L`), a shared first token (`Sam L` / `Sam B`), and an edit distance of one or two (`Sam` / `Samm`). Anything scoring 60 or above is offered, with enough context to recognise yourself: how many picks they have, when they were last here, how many devices.

Claiming is additive, not a takeover. The one exception is whoever started the crew: they can't be claimed by name at all, only linked from a device they already use, so nobody can pick "that's me" and take over the tidy-up powers. The original device keeps working, and a person with more than one device linked shows a small count in the crew list, which is the only visible signal that it happened.

Nobody is asked for a name until they tap their first pick. Every step before the payoff is a place to leave.

### Removing things

Any member can take a game off the shelf with **Bench it** (in the game's detail sheet, under **Off the shelf**), which pulls it out of everyone's current picks. Takes and the whole play history survive, the **Benched** filter chip finds it again, and **Put it back** undoes it. Reversible, and nobody can nuke the shelf.

### Looking after a crew

The first person in (whoever made it) looks after the crew. There's no role to hand out or password to set; the server works it out as the earliest member each time. They get:

| Where | What | Why |
| --- | --- | --- |
| Game details, **Off the shelf** | **Remove for good** | A game added twice or by mistake. Votes, nights and who-owns-it go; finished games stay in the record |
| Menu, **Manage crew** | **Merge** two people | The same person joined twice. Picks, nights, owns and devices move across; where both answered, the one you keep wins. Likely double-ups are flagged |
| Menu, **Manage crew** | **Remove** someone | Their picks and nights go, they can join again with the link |
| Menu, **Manage crew** | **Delete this crew** | For good, for everyone. Asks first |

Every one of these shows up in **Our record** with who did it, and so do calling a round and taking a call back (`crew_log`), so nothing happens quietly. Everyone else sees none of these buttons. All four are checked server-side (`crew_remove_game`, `crew_merge_members`, `crew_remove_member`, `crew_delete`), so hiding the buttons isn't the security.

### The owner page

`…/#/admin` is for whoever runs the Supabase project. It takes an owner key (stored in `admin_keys` only as a SHA-256 hash; add one with `insert into admin_keys(hash) values (encode(sha256(convert_to('your-long-key','UTF8')),'hex'))`) and then lists every crew with its link, who's in, their devices and when they were last here. From there you can give a crew a **New code** (everything follows it; handy if a link leaks) or **Delete** it. The key lives in that browser only, and without it the page shows nothing.

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
| `supabase/schema.sql` | Nineteen tables, row level security, forty-six RPCs |
| `supabase/functions/card/index.ts` | Serves Open Graph tags per group so links unfurl in chat, then redirects |
| `supabase/functions/prices/index.ts` | Refreshes Steam prices (AUD) for a crew's shelf, at most every four hours per game |
| `supabase/functions/discord/index.ts` | Posts and edits the crew's live Discord scoreboard through their webhook |
| `supabase/functions/enrich/index.ts` | Steam search, fetch, validation, facet classification |
| `data/curated.json` | 76 verified games with caps, energy, setup and mod caveats, mirrored as `CURATED` inside index.html |
| `.github/workflows/keepalive.yml` | Weekly ping and stale-data refresh |

---

## Changing things

**Pre-filled facets for more games.** New crews start empty; nothing is seeded. To have a game arrive with its cap, energy and setup already set, add it to `CURATED` in `index.html` and to `data/curated.json` so the two stay in step.

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

## Accessibility

Checked with an automated pass that drives the real UI at 375, 768 and 1440px in both themes, rather than by reading the CSS and hoping.

| | What was wrong | Where it is now |
| --- | --- | --- |
| Contrast | 49 failures in light, 18 in dark | 0 |
| Page structure | No `h1`, no dialog had an accessible name | Group name is the `h1`, every dialog is named by its own heading |
| Keyboard | Focus never entered a dialog, Tab walked out the back | Focus moves in, is trapped, and returns to whatever opened it |
| Tap targets | Chips and buttons at 34px | 40px and up on phones |

**One token caused most of the contrast failures.** `--muted` sat at `#7A7E87`, which is 3.6:1 on the surface grey. Every pill, count, eyebrow and section heading in the app uses it, at 10 to 13px, so one value under the line failed the whole interface. It is neutral 600 in light and neutral 300 in dark now.

Two more worth naming. The generated avatar circles were white text on `hsl(h 38% 48%)`, which is 2.5:1 , and they carry a person's initial, so that is real text failing badly. And **"Out in front"** on the leader banner was the violet accent over a photograph, which is unreadable over anything bright; it is white on a deeper scrim now.

Motion is opt-out: everything added for feel sits behind `prefers-reduced-motion`, including the confetti, which is skipped entirely rather than shortened.

**Colour.** Borders are translucent rather than a solid grey, so a hairline works on whatever is behind it instead of only on one background. Dark is near-black with lifted surfaces and a 1px top bevel, which is what stops a stack of dark panels reading as one flat sheet. The action colour is used as a glow as well as a fill.

**Alignment.** Every section on the page now starts and ends on the same 14px gutter, measured rather than eyeballed. The one that had drifted was the shelf header: hiding its heading on phones left the empty wrapper as a flex item, and the row's 14px gap pushed both buttons off the grid by exactly that much.

## Motion, and what each bit means

Four pieces, each tied to something that actually happened rather than added for decoration.

| | When | Why |
| --- | --- | --- |
| **Leader glow** | Continuously, on the card with the most votes | Once you have scrolled past the banner, nothing marked the leader. An ambient ring plus a travelling highlight does it without spending a badge or a colour on it |
| **Pointer glow** | On any card, under the cursor | The border lights up where your mouse is. Pointer devices only, so a phone never pays for the listener or the paint |
| **Count tick** | When a tally goes up | A number that snaps looks like a re-render, a number that rolls looks like a vote |
| **Reel** | While **Roll for it** decides | A result that just appears reads as the computer picking. A reel that runs down and lands reads as a roll |
| **Tumbling die** | Alongside the reel | So the button and the answer read as one action rather than two |
| **Confetti** | Once, when a round is called | The moment the whole app exists for, and it used to just swap a strip of text |
| **Name scramble** | In the status strip, when a different game takes over | Characters resolve left to right, so it reads as the name landing rather than as a glitch |
| **Call it shimmer** | Once enough people have voted | Says the round is ready without a badge or a colour change shouting about it |
| **Night sky** | Always, behind everything | A few dozen faint stars with a slow twinkle and a shooting star every few seconds. One canvas at 30fps, stops when the tab is hidden. Light mode inverts it: ink-lavender specks on paper, same field |

Both glows are a gradient behind a ring-shaped mask. The mask is what keeps them a border rather than a wash over the card. The leader's is a conic gradient rotating on `@property --beam`, which is what lets the angle animate at all, since custom properties are plain strings until you give them a type; browsers without `@property` get a still gradient ring, which is a fine place to land. The pointer one is the same mask with a radial gradient parked at the cursor instead.

**A travelling arc was not enough on its own.** First pass lit only a thin slice of the perimeter, and on a tall card that slice sits on one long edge most of the time, so it read as a stray violet line rather than as light going round. The leader now carries a permanent soft ring and bloom, with the highlight as detail on top.

The reel only ever changes text inside one `<span>`, so nothing else on the page re-renders while it runs, and it lands on the game the button will actually pick.

Under `prefers-reduced-motion` every one of these stops. The sky paints its stars once and leaves them there.

## Colour

Dark first. The accent is a soft lavender (`#C4B5FD`) leaning periwinkle, and the "blend" is a real two-stop gradient, lavender to periwinkle, that only the things that matter get: the primary button, the ring on a picked card, the beam on the leader, the progress line in the strip. Everything else is a near-black with a hint of blue so the greys sit in the same family as the accent rather than fighting it. Light mode uses the same hues two steps deeper (`#6252DA` to `#4B62DB`) because white text has to hold 4.5:1 on both ends of the gradient, and the QA suite checks that at the gradient's worst stop, not its average.

Borders went. Cards, the strip and the rail panels get depth from a 1px top bevel and a soft drop shadow instead of a hairline, which is what stops a stack of near-black panels reading as one flat sheet without drawing boxes around everything. Light mode keeps a hairline because white on off-white needs an edge to exist at all. Three radii, nested: 16 for panels and sheets, 12 for cards and inputs, 8 for the buttons inside a card. Seven type sizes and three weights, down from fifteen and five.

The page background is a mesh of three soft radials under a film-grain layer at a few percent, so the gradients never band, with the starfield behind that.

## When things break

**If the CDN doesn't load, you get a real message.** The app pulls `supabase-js` from jsdelivr. If that is blocked, or you are offline, or the integrity hash doesn't match, the library never arrives and `createClient` throws before anything renders . The old failure mode was a blank white page with nothing in it and nothing in the console for a non-developer to read. It is now checked for, and says what happened with a retry button.

The script tag carries a **Subresource Integrity hash**, so a compromised CDN cannot quietly serve different JavaScript to a page holding your group's data.

**The shelf does not flash any more.** The page used to rebuild its entire HTML on every 10-second poll, which destroyed every `<img>` and re-ran its fade from transparent. That was the flicker. Two fixes: the render is skipped entirely when a poll comes back identical to what is already on screen, and any image the browser already has is marked as loaded without animating. As a side effect your scroll position and your place in a text field now survive polling too.

## Known limits, stated honestly

- **Group codes are obscurity, not security.** Seven characters from a 30-character alphabet is fine for keeping a game night private. It is not a login, and it should not hold anything you would mind a stranger reading.
- **The anon key is public.** It has to be. Row level security and the RPC-only interface are what actually protect the data, not the key.
- **Player caps can be wrong.** Steam does not publish them. The seeded ones are best-effort and some are deliberately left blank rather than guessed. Correct them in the app.
- **No deletes.** Nothing in the app can remove a game or a person, on purpose. If something needs to go, do it in the Supabase table editor.
- **One CDN dependency.** `supabase-js` comes from jsdelivr rather than being vendored into the repo. Pinned and integrity-hashed, and it fails with a message rather than a blank page, but it is still a third party in the load path.
- **Sorting by session length is not wired up.** The list view header offers it, the comparator exists, and nothing sets it. It is in `ARRANGE` as a gap, not a bug.

**Quorum used to be able to exceed the group.** It ships at 5. A two-person group where both had voted still read *"3 more to call it"*, and the Call it shimmer could never fire, because the target was unreachable. Quorum is a floor for a group big enough to have one: everybody having had their say is now always enough, whatever the number says.

### Little things

A few bits that aren't load-bearing. None of them run with reduced motion on.

**The status strip lights up under your cursor.** A fine dot grid sits over the strip, masked by a soft circle that follows the pointer, so the dots only exist where you are looking. It is one CSS layer and a masked gradient rather than a canvas: the pointer handler writes `--mx`/`--my` at most once per frame and nothing is redrawn. The dot colour comes from your own member colour blended toward the accent, so the same strip is slightly different per person without ever leaving the palette. Desktop with a real pointer only (`hover: hover and pointer: fine`, 900px up), because on a touch screen there is no cursor to follow, and it is removed entirely with reduced motion on.

One roll in twenty on the dice is a natural 20 and picks the least-voted game on the shelf. Three rounds running on the same game and the strip says **Again?!**. Between 1am and 5am the round line adds "who's still up?".

The crew's emoji strolls across the bottom of the page when the whole crew has picked, once a visit. Tapping the emoji in the header three times inside a second and a bit sends it across on demand. The emoji isn't a button, editing the crew is the small pencil next to the name.

Typing certain things into the shelf search gets an answer back. They fire on a pause in typing, not on each keystroke, so searching a real title that starts with one of these words is safe.

| Type | Get |
| --- | --- |
| `gg`, `gg wp` | gg wp, plus nine bursts of paper across about five seconds |
| `steam` | we know |
| `xyzzy` | Nothing happens. |
| `42`, `the answer` | The answer, but not to what we're playing. |
| `iddqd`, `idkfa`, `godmode` | God mode's off. You still have to pick. |
| `rosebud`, `motherlode` | No money here, just games. |
| `please`, `pls` | Manners noted. |
| `help` | Pick three, the rest sorts itself out. |
| A crew member's name | *name* isn't a game. |
| The crew's emoji | Sends it for a lap |

They live in one `TYPED_EGGS` array, a `test` and a `run` per entry, so adding another is a line.
