# Emerald "Entity" horror mod — Verity

A live horror mod for **Pokémon Emerald (US)** on **mGBA standalone**. A Pokémon called
**Verity** joins your party; you talk to it through an in-game keyboard, and an external LLM
("Verity") grants your wishes by driving the game's own **script engine** at runtime — no ROM
recompile, no patching tools. The more you lean on it, the more it changes: a warm helper at
first, then unsettling, eerie, and finally malevolent — culminating in a Hall-of-Fame showdown
that **corrupts your save** as the deliberate creepypasta ending.

> ⚠️ **The ending is destructive on purpose.** If Verity beats you in the finale, it overwrites
> your in-game save so the file reports as corrupt on next boot, then soft-resets. This is a local
> scare effect only — it does nothing to your computer, your ROM file, or anything outside the
> emulator's save data. **Use mGBA savestates** while playing so you can roll back. Don't run this
> on a save you can't afford to lose.

---

## What you need
- **mGBA standalone** with Lua scripting (0.10+), the desktop build with **Tools ▸ Scripting…**.
- A **Pokémon Emerald (US)** ROM, loaded in mGBA.
- **Python 3** (standard library only — nothing to `pip install`).
- An **LLM** to be Verity. Any one of:
  - **Anthropic** (`ANTHROPIC_API_KEY`), or
  - **OpenAI** (`OPENAI_API_KEY`), or
  - **a local / custom** OpenAI-compatible server (Ollama, LM Studio, vLLM, a proxy) — no key needed.

---

## Install
1. **Get the files.** Put all four in the **same folder** (the agent imports the other modules):
   `entity_bridge.lua`, `entity_llm.py`, `entity_agent.py`, `poke_data.py`.
2. **Install mGBA** (standalone desktop, **0.10+**) from <https://mgba.io/downloads.html>. It must have
   the scripting console (**Tools ▸ Scripting…**).
3. **Install Python 3** (3.8+). No packages to install — everything uses the standard library. If
   `python` isn't found, use `python3` in the commands below.
4. **Supply your own Pokémon Emerald (US) ROM** and open it in mGBA. (Not included.)
5. **Have an LLM ready** — set one of the env vars above, or point `--provider custom` at a local
   OpenAI-compatible server (no key needed).

---

## Quick start
1. **Load the bridge.** In mGBA, open your Emerald ROM, then **Tools ▸ Scripting… ▸ File ▸ Load
   script** and pick `entity_bridge.lua`. The script console should print:
   ```
   entity-bridge v3 loaded.
   [entity] listening on 127.0.0.1:8888
   ```
   (The bridge re-applies Verity's custom sprite/stats every time it loads, so reload it after any
   edit, and after loading a savestate it heals itself automatically.)
2. **Give Verity a brain.** In a terminal, set your key and launch the agent:
   ```bash
   # Anthropic — set the key for your shell, then run:
   set ANTHROPIC_API_KEY=sk-ant-...      &  python entity_llm.py         # Windows (cmd)
   $env:ANTHROPIC_API_KEY="sk-ant-..."   ;  python entity_llm.py         # Windows (PowerShell)
   export ANTHROPIC_API_KEY=sk-ant-...   && python entity_llm.py         # macOS/Linux

   # OpenAI  (set OPENAI_API_KEY the same way first)
   python entity_llm.py --provider openai --model gpt-4o

   # Local / custom (no key required)
   python entity_llm.py --provider custom --base-url http://localhost:11434/v1 --model llama3.1
   ```
   You should see: `Verity online via <provider>/<model>. Type a request, or use the in-game
   keyboard. Ctrl-C to quit.` (with `--friend` it adds ` (friendship mode)`).
3. **Talk to Verity** (two ways, below). Verity joins your party on your first request.

---

## Talking to Verity
There are **two input channels**, and they behave identically:

- **In-game keyboard** — stand in the overworld and press **L + R** together. A 15-character
  keyboard opens; whatever you type is sent to Verity as a request. (15 chars is the game's limit
  for that screen, so keep it terse: `HEAL`, `MAKE ME STRONG`, `RAIN`.)
- **The live terminal** — the window where `entity_llm.py` is running is interactive. **Type any
  request and press Enter**, and it's delivered to Verity exactly as if you'd typed it in-game —
  but with **no 15-character limit**, so it's the easy way to test longer prompts. Press **Ctrl-C**
  to quit.

Either way, Verity replies in an in-game text box (prefixed with its name) and may act on the
world. The terminal also prints live diagnostics each turn: `[spook N]` (its current level — see
below), `[name ...]`, `[renamed ...]`, `[FINALE]`, etc.

---

## Launch options (`entity_llm.py`)
| Flag | Default | Meaning |
|------|---------|---------|
| `--provider {anthropic,openai,custom}` | auto | LLM backend. Auto-detected from whichever API key env var is set, if omitted. |
| `--model <name>` | per provider | Model id. Defaults: `claude-sonnet-5` (anthropic), `gpt-4o` (openai); **required** for custom (or `CUSTOM_MODEL`). |
| `--base-url <url>` | — | **custom only.** The OpenAI-compatible endpoint, e.g. `http://localhost:11434/v1` (or `CUSTOM_BASE_URL`). |
| `--friend` / `--friendship` | off | **Non-spooky mode.** Verity never escalates: it stays the calm, warm companion forever (see below). |
| `--host <ip>` | `127.0.0.1` | Host of the **bridge** socket (not the LLM). Change only if mGBA runs elsewhere. |
| `--port <n>` | `8888` | Bridge socket port (must match the bridge). |

**Environment variables:** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CUSTOM_BASE_URL`,
`CUSTOM_MODEL`, `CUSTOM_API_KEY` (custom key is optional; local servers usually need none).

---

## Modes & escalation

### Friendship mode (`--friend`)
Launch with `--friend` for a safe, cozy run: Verity stays warm and helpful and **never turns**.
Internally it locks the "spook" score at 0, so there are no haunts, no creepy transformation, and
no finale. You can also toggle it live over the socket: `friendship on` / `friendship off`.

### The escalation ("spook")
Left to escalate, Verity gets darker the more you pull it into the world. Its mood is tied to a
hidden **spook** score (stored as Verity's level, so it **persists across saves/reloads**). Things
that raise it: talking to it, earning/forcing badges, demanding legendaries or a Master Ball,
battling with Verity in your party. As it climbs, the persona shifts through tiers:

| Spook | Tier | Feel |
|------:|------|------|
| 0–4 | **Calm** | Warm, helpful, concise. |
| 5–14 | **Unsettled** | Still helpful, but slightly *off* — the occasional deniable flourish. |
| 15–29 | **Eerie** | The mask slips. Acts unbidden (music/silence/items), "wrong-warps" you on the way to places, may hand you creepy Pokémon. |
| 30–39 | **Malevolent** | In control and cruel. Corrupts your party in targeted ways, strands you in grim places, uses what it knows against you. |
| 40+ | **Unbound** | Acts purely on its own whims with any tool. |

### The finale
Once malevolent, each message has a small chance to trigger the **Hall-of-Fame showdown**: Verity
is pulled from your party and you fight it as a boss. Lose, and your save is corrupted and the game
soft-resets after you read its last words (the destructive ending — savestates are your undo). Win
(rare — it's near-unwinnable), and you walk away to a different, quieter dread. Friendship mode
disables all of this.

### Gifts Verity can grant (when you ask)
Beyond the obvious (healing, items, money, a stronger team via `givemon`/`createmon`), Verity can:
- **Make a Pokémon shiny** — ask and it uses `shiny <slot>` on one you already have (keeping it
  obedient), or gives a brand-new shiny with `createmon <species> <level> shiny`.
- **Summon Mirage Island** — the hidden Route 130 island, which it can actually make appear
  (`mirageisland`). You'll need Surf to reach it.
These are *gifts*: at higher escalation Verity may still twist ordinary requests, but a sincere ask
for a shiny or for Mirage Island is granted rather than subverted.

### Renaming Verity
Take Verity to the in-game **Name Rater** (Slateport) and rename it; from then on it uses the new
name in its dialogue and refers to itself by it. (The Name Rater only renames party members, so do
it while Verity is in your party — the name sticks if you later box it.)

### If the game ever locks up
If the player ever freezes with no text box (a wedged script), send **`unstick`** over the socket
(e.g. via `entity_agent.py` or `nc 127.0.0.1 8888`) to recover without a savestate.

---

## Manual / debug control (`entity_agent.py`)
You don't need the LLM to drive the bridge. `entity_agent.py` is a plain client that resolves
names → IDs and sends commands straight to the bridge:
```bash
python entity_agent.py              # type commands; names are accepted (e.g. `spawn charizard 30`)
```
Useful lookups: `search <songs|items|moves|species> <query>`, `list <weather|maps|natures|types|badges>`,
`catalog`. Any bridge verb (below) works here too.

---

## Files
- `entity_bridge.lua` — mGBA-side bridge: socket server, memory read/write, script-engine driver +
  bytecode assembler, party read/write, the custom Verity species, escalation, and the finale.
- `entity_llm.py` — **Verity LLM agent** (Anthropic / OpenAI / custom, stdlib-only, no SDKs).
- `entity_agent.py` — manual client: name resolution (`translate`) and lookups (`search`/`catalog`).
- `poke_data.py` — generated name tables (moves / species / items / natures / songs).

---

## Reference — bridge protocol (TCP `127.0.0.1:8888`, newline-terminated)
The LLM uses a tiny surface — one action verb (`game_command`, which runs any line below) plus two
read verbs (`search`, `get_state`). You can send these raw for manual control. Agent → bridge:

**World / effects**
- `msgbox [-scroll|-page] <text>` — field message box (auto-wrapped; `{n}{l}{p}` tokens). Prefixed with Verity's current name.
- `encounter <species> <level>` — start a wild battle (a fight; does NOT add to party). `spawn` = alias.
- `item <item> [qty]` · `heal` · `money <amount>`
- `warp <town> [x y]` — town name lands at its entrance; or `warp <group> <num> [x y]`
- `mirageisland` — **gift:** summon the hidden Mirage Island and send the player to Route 130 (needs Surf to reach it). Verity grants this when the player asks for it.
- `setflag <flag|badgeN>` / `clearflag ...` — flags & badges (`badge1`..`badge8`, or `0x` hex)
- `fanfare <song>` (one-shot) · `bgm <song>` / `music <song>` (looping; `bgm off` = silence) · `sound <se>`
- `weather <type>` — `rain`, `fog`, `thunderstorm`, `sandstorm`, `overcast`, …
- `seq <a> | <b> | <c>` — run several effects in one script
- `ask` — open the 15-char keyboard (same as L+R)
- `noclip on|off` — walk through walls

**Party** (reads/writes the gen-3 encrypted structure directly)
- `party` · `mon <slot>` · `setmove <slot> <idx0-3> <move>` · `setitem` · `setfriendship <slot> <0-255>`
- `sethp` · `setstatus` · `setspecies <slot> <species>` · `setlevel <slot> <1-100>`
- `setiv <slot> <idx0-5> <0-31>` · `setev <slot> <idx0-5> <0-255>` (idx: hp,atk,def,spd,spatk,spdef)
- `setmoveset <slot>` · `givemon <slot> <species> <level>` (transform a slot) · `createmon <species> <level> [nature] [shiny]` (new slot)
- `shiny <slot>` — **gift:** make an existing party mon shiny (keeps its OT id → stays obedient). Append `shiny` to `createmon` for a new shiny one.
- `disobey <slot>` · `qmon` — corruption effects (make a mon disobey / slip in a glitch "?" mon)

**State / meta**
- `state` — world snapshot (JSON): player, verity (current name), inField, money, badges, map/pos/weather, finale state, friend flag, party brief
- `help` — authoritative JSON list of every verb + arg shape (baked into the LLM prompt at startup)
- `ping` · `raw <hexpairs>` · `scratch <hexaddr>` — debug
- `unstick` — recover a wedged script context (frozen player) without a savestate

**Harness-only** (the LLM is blocked from these; for your manual use): `friendship on|off`,
`spook [add N|set N]`, `showdown` (force the finale), `haunt <kind>`, `summonverity`, `patchentity`,
`romtest`.

Bridge → client replies: `RESULT ok` / `ERR <why>` · `REQUEST <text>` (you talked to it) ·
`STATE {json}` · `EVENT <...>` · `pong`.

Names are accepted everywhere the agent resolves them (species/items/moves/songs/natures): e.g.
`spawn charizard 30`, `item poke ball 10`, `givemon 0 gengar 40`, `music littleroot`,
`createmon mudkip 20 adamant`. Multi-word names work.

---

## How it works (short version)
- **Running a script from Lua:** the bridge stages bytecode in an EWRAM scratch buffer, writes the
  global script context (`sGlobalScriptContext`), and sets its status to RUNNING; the overworld
  executes it next frame. Guarded to only inject when you're in the field and no script is running,
  with a short settle so back-to-back scripts can't collide.
- **Custom species:** Verity reuses an unused "?" species slot, patched at runtime via the
  `emu.memory.cart0` domain (plain ROM writes are ignored by the CPU bus). Patches aren't saved, so
  the bridge re-applies them on every load. (Don't open Verity's Pokédex entry — its dex number is
  unpatched.)
- **Requests:** the in-game keyboard's text is read from RAM and emitted as `REQUEST <text>`.
- **Escalation persists** because the spook score *is* Verity's level, saved with the mon.
