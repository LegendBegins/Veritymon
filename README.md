# Veritymon

A horror mod for **Pokémon Emerald (US)**.

All seemed normal in the Hoenn region... at least until *that* day. Eldritch forces far beyond the NPCs' comprehension sheared open the underlying substrate of their reality and left... something. Some**one**. It's said that since that day, trainers who stare into the void long enough just might be gifted to hear the void speak back.

Press L+R at any time to open an in-game keyboard and chat directly with Verity, a mysterious entity who controls your game. Powered by an LLM that drives the game's own scripting engine, Verity is here to chat with you, answer questions, and grant your wishes.

...Or so it seems.

## Features

* A Living, Unhinged Entity: Verity isn't static. The more you lean on him for help, the more his behavior shifts, mutates, and unravels. What starts as a helpful companion slowly reveals that something is deeply wrong.

* Evolving Phases & Multiple Endings: Experience a multi-staged descent packed with beneficial, bizarre, and outright terrifying effects. (For spoilers, scroll to the bottom).

* No ROM Patching Required: Jump straight into the horror without messing with complex setup tools or custom ROMs.

* Three Distinct Play Modes:
  * Verity (Default): The intended psychological horror experience. Use him at your own risk.
  * Friendship: A safer mode where Verity remains a loyal, unbetraying companion throughout (no spookiness or ending).
  * Debug: Access all of Verity's capabilities sandbox-style, even without an active LLM connection.

> ⚠️ **Verity (Default) is intentionally destructive to your save.** Don't run this mode
> on a save you can't afford to lose. This is a local
> scare effect only; it does nothing to your computer, your ROM file, or anything outside the
> emulator's save data.

---

## What you need
- **mGBA standalone** with Lua scripting (0.10+), accessible via **Tools ▸ Scripting…**. I have not tested this mod with other emulators.
- A **Pokémon Emerald (US)** ROM, loaded in mGBA.
- **Python 3** (standard library only — no packages required to install).
- An **LLM** to be Verity. Any one of:
  - **OpenAI** (`OPENAI_API_KEY`), or
  - **Anthropic** (`ANTHROPIC_API_KEY`), or
  - **a local / custom** OpenAI-compatible server (Llama.cpp, Ollama, LM Studio, vLLM, a proxy, etc.) — no key needed.

---

## Quick start

1. **Load the bridge.** In mGBA, open your Emerald ROM, then **Tools ▸ Scripting… ▸ File ▸ Load script** and pick `entity_bridge.lua`. The script console should print:

   ```
   entity-bridge v3 loaded.
   [entity] listening on 127.0.0.1:8888
   ```

2. **Give Verity a brain.** In a terminal, set your key using whichever line matches your environment and preferred API:

   ```bash
   # OpenAI: Set the key for your shell
   set OPENAI_API_KEY=sk-...        # Windows (cmd)
   $env:OPENAI_API_KEY="sk-..."     # Windows (PowerShell)
   export OPENAI_API_KEY=sk-...     # macOS/Linux

   # Anthropic
   set ANTHROPIC_API_KEY=sk-ant-...     # Windows (cmd)
   $env:ANTHROPIC_API_KEY="sk-ant-..."  # Windows (PowerShell)
   export ANTHROPIC_API_KEY=sk-ant-...  # macOS/Linux
   ```
  
    **Then run**
    ```bash
    python entity_llm.py
    ```

    ### Locally Hosted LLMs
    For locally hosted LLMs (great choice btw), set the provider to `custom` and your base URL to whatever host serves your OpenAI-compatible API (for most people, this is going to be localhost), along with the model name you want to use.
   ```bash
   # Local / custom (no key required)
   python entity_llm.py --provider custom --base-url http://localhost:11434/v1 --model qwen-3.8-27b
   ```

   You should see: `Verity online via <provider>/<model>. Type a request, or use the in-game keyboard. Ctrl-C to quit.`

4. **Talk to Verity** (two ways, below). Verity joins your party on your first request.

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

## Files
- `entity_bridge.lua` — mGBA-side bridge: socket server, memory read/write, script-engine driver +
  bytecode assembler, party read/write, the custom Verity species, escalation, and the finale.
- `entity_llm.py` — **Verity LLM agent** (Anthropic / OpenAI / custom, stdlib-only, no SDKs).
- `entity_agent.py` — manual client for debug mode: Direct access to everything Verity can do and more.
- `poke_data.py` — generated name tables (moves / species / items / natures / songs).

---

## Launch options (`entity_llm.py`)
| Flag | Default | Meaning |
|------|---------|---------|
| `--provider {anthropic,openai,custom}` | auto | LLM backend. Auto-detected from whichever API key env var is set, if omitted. |
| `--model <name>` | per provider | Model id. Defaults: `claude-sonnet-5` (anthropic), `gpt-4o` (openai); **required** for custom (or `CUSTOM_MODEL`). |
| `--base-url <url>` | — | **custom only.** The OpenAI-compatible endpoint, e.g. `http://localhost:11434/v1` (or `CUSTOM_BASE_URL`). |
| `--friend` / `--friendship` | off | **Non-spooky mode.** Verity never escalates: it stays the calm, warm companion forever (see below). |
| `--host <ip>` | `127.0.0.1` | Host of the mGBA Lua **bridge** socket (not the LLM). Change only if mGBA runs elsewhere. |
| `--port <n>` | `8888` | Bridge socket port for mGBA Lua (must match the bridge). |

**Environment variables:** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CUSTOM_BASE_URL`,
`CUSTOM_MODEL`, `CUSTOM_API_KEY` (custom key is optional; local servers usually don't need one).

---

# The following content may contain [SPOILERS]! Tread carefully!

## Modes & escalation

### Friendship mode (`--friend`)
Launch with `--friend` for a safe, cozy run: Verity stays warm and helpful and **never turns**.
Internally it locks the "spook" score at 0, so there are no haunts, no creepy transformation, and
no finale. You can also toggle it live using debug mode: `friendship on` / `friendship off`.

### The escalation ("spook")
Left to escalate, Verity gets darker the more you pull it into the world. Its mood is tied to a
hidden **spook** score (stored as Verity's level, so it **persists across saves/reloads**). Things
that raise the spook score include: talking to Verity, earning/forcing badges, demanding legendaries or a Master Ball,
battling with Verity in your party. As it climbs, the persona shifts through tiers:

| Spook | Tier | Feel |
|------:|------|------|
| 0–4 | **Calm** | Warm, helpful, concise. |
| 5–14 | **Unsettled** | Still helpful, but slightly *off*. |
| 15–29 | **Eerie** | The mask slips. Acts unbidden (music/silence/items), wrongwarps you while traveling, may hand you creepy Pokémon. |
| 30–39 | **Malevolent** | In control and cruel. Corrupts your party in targeted ways, strands you in grim places, uses what it knows against you. |
| 40+ | **Unbound** | Acts purely on its own whims and will use its tools freely. |

### The finale
Once malevolent, each message has a small chance to trigger **Showdown Mode**: Verity
is pulled from your party and you fight it as a boss. Lose, and your save is corrupted after a parting monologue. Win
(almost impossible. If you pull it off, make a video about it plz), and you walk away to a different, still melancholic ending. Friendship mode
disables this event entirely.


### If the game ever locks up
If the player ever freezes with no text box, send **`unstick`** over debug mode
(via `entity_agent.py`) to recover without a savestate.

---

## Manual / debug control (`entity_agent.py`)
Even without an LLM, you can still access the full capabilities of this mod. `entity_agent.py` is a manual client that allows users to send commands straight to the game. Plus, debug mode can run **in parallel with other modes**, so you can tweak Verity's options live.
```bash
python entity_agent.py              # type commands; names are accepted (e.g. `spawn charizard 30`)
```
Useful lookups: `search <songs|items|moves|species> <query>`, `list <weather|maps|natures|types|badges>`,
`catalog`. Any debug command (below) works here too.

---

**World / effects**
- `msgbox [-scroll|-page] <text>` — field message box (auto-wrapped; `{n}{l}{p}` tokens). Prefixed with Verity's current name.
- `seq <a> | <b> | <c>` — run several effects in one script
- `encounter <species> <level>` — start a wild battle (a fight; does NOT add to party). `spawn` = alias.
- `item <item> [qty]`
- `heal`
- `money <amount>`
- `warp <town> [x y]` — town name lands at its entrance; or `warp <group> <num> [x y]`
- `mirageisland` — summon the hidden Mirage Island and send the player to Route 130.
- `setflag <flag|badgeN>` / `clearflag ...` — flags & badges (`badge1`..`badge8`, or `0x` hex)
- `fanfare <song>` (one-shot)
- `bgm <song>` / `music <song>` (looping; `bgm off` = silence)
- `sound <se>`
- `weather <type>` — `rain`, `fog`, `thunderstorm`, `sandstorm`, `overcast`, …
- `ask` — open the 15-char keyboard (same as L+R)
- `noclip on|off` — walk through walls
- `detour <destination>` — eerie double-warp: drag the player through a grim place, then on to `<destination>`
- `wrongwarp` — malevolent: strand the player somewhere grim (random; NOT where they asked)

**Party** (reads/writes the gen-3 encrypted structure directly)
- `party`
- `mon <slot>`
- `setmove <slot> <idx0-3> <move>`
- `setfriendship <slot> <0-255>`
- `setitem <slot> <item>` — give a party mon a held item
- `sethp <slot> <hp>` — set current HP
- `setstatus <slot> <status>` — set status condition (`0` = none)
- `setspecies <slot> <species>`
- `setlevel <slot> <1-100>`
- `setiv <slot> <idx0-5> <0-31>`
- `setev <slot> <idx0-5> <0-255>` (idx: hp,atk,def,spd,spatk,spdef)
- `setmoveset <slot>`
- `givemon <slot> <species> <level>` (transform a slot)
- `createmon <species> <level> [nature] [shiny]` (new slot)
- `shiny <slot>` — make an existing party mon shiny (keeps its OT id → stays obedient). Append `shiny` to `createmon` for a new shiny one.
- `disobey <slot>` - make a mon disobey
- `qmon` — corruption effects ( / slip in a glitch "?" mon)

**State / meta**
- `state` — world snapshot (JSON): player, verity (current name), inField, money, badges, map/pos/weather, finale state, friend flag, party brief
- `help` — authoritative JSON list of every verb + arg shape (baked into the LLM prompt at startup)
- `ping`
- `raw <hexpairs>`
- `scratch <hexaddr>` — debug
- `unstick` — recover a wedged script context (frozen player) without a savestate

**Harness-only** (the LLM is blocked from these; for your manual use):
- `friendship on|off`
- `spook [add N|set N]`
- `showdown` (force the finale)
- `haunt <kind>`
- `summonverity`
- `patchentity`
- `romtest`

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
  the bridge re-applies them on every load.
- **Requests:** the in-game keyboard's text is read from RAM and emitted as `REQUEST <text>`.
- **Escalation persists** because the spook score *is* Verity's level, saved with the mon.

AI Disclaimer: AI was used in the development of this mod with *substantial* human contribution. I mean, it's a mod about AI. It's pretty on-brand.
