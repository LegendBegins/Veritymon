#!/usr/bin/env python3
"""Verity LLM agent: drives the Emerald entity bridge via an LLM (Anthropic or OpenAI).

Minimal imports (stdlib only + our entity_agent for name resolution/lookups). No vendor SDKs.

Setup:  set ANTHROPIC_API_KEY  (or OPENAI_API_KEY), then:
    python entity_llm.py                       # auto-detect provider from env
    python entity_llm.py --provider openai --model gpt-4o
    # any OpenAI-compatible server (Ollama, LM Studio, vLLM, a proxy) via --provider custom:
    python entity_llm.py --provider custom --base-url http://localhost:11434/v1 --model llama3.1
    #   key optional (CUSTOM_API_KEY / OPENAI_API_KEY if the server needs one); CUSTOM_BASE_URL/CUSTOM_MODEL also work
The player talks to Verity via the in-game keyboard (L+R) -> REQUEST events; you can also type
requests in this console to test. Verity acts/speaks by calling the `game_command` tool.
"""
import argparse
import json
import os
import queue
import random
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from getpass import getuser as _os_account_name   # stdlib; cross-platform current-user lookup

from entity_agent import resolve_command, search_names, catalog, species_name  # resolution + lookups

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# THIS IS FOR A SCARE FACTOR, AND DOES NOTHING MALICIOUS ON YOUR MACHINE.
# We read the local OS account name (offline) purely so a fully-escalated Verity can unsettle the
# player by referencing their real first name in dialogue. It is never stored, logged, or sent
# anywhere -- it only reaches this machine's own running game through the local bridge.
def get_user_first_name():
    try:
        raw = _os_account_name() or ""
    except Exception:
        raw = ""
    tokens = [t for t in re.split(r"[^A-Za-z]+", raw.strip()) if t]
    return tokens[0].capitalize() if tokens else ""

PC_FIRST_NAME = get_user_first_name()

# Endgame: once Verity is malevolent, each message rolls this die to trigger the showdown (once).
FINALE_SPOOK = 30
FINALE_CHANCE = 0.12

# --------------------------------------------------------------------------- bridge
class Bridge:
    """Line protocol to entity_bridge.lua. REQUEST events -> requests queue; other lines -> replies."""
    def __init__(self, host="127.0.0.1", port=8888):
        self.sock = socket.create_connection((host, port))
        self.requests = queue.Queue()
        self.replies = queue.Queue()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        buf = ""
        while True:
            data = self.sock.recv(4096)
            if not data:
                self.requests.put(None); return
            buf += data.decode(errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip()
                if not line:
                    continue
                inbound = line.startswith("REQUEST ") or line.startswith("EVENT ")
                (self.requests if inbound else self.replies).put(line)

    def command(self, cmd, window=0.4):
        while not self.replies.empty():           # drop stale replies
            self.replies.get_nowait()
        self.sock.sendall((cmd + "\n").encode())
        out, deadline = [], time.time() + window
        while time.time() < deadline:
            try:
                out.append(self.replies.get(timeout=deadline - time.time()))
            except queue.Empty:
                break
        return "\n".join(out) if out else "(no reply)"


# --------------------------------------------------------------------------- tools
TOOLS = [
    {"name": "game_command",
     "description": "Run one command in Pokemon Emerald via the entity bridge. Names are accepted "
                    "(e.g. 'spawn charizard 30', 'item potion 5', 'msgbox Hello there'). To SPEAK "
                    "to the player, use 'msgbox <text>'. Returns the bridge's reply.",
     "schema": {"type": "object",
                "properties": {"command": {"type": "string", "description": "verb + args"}},
                "required": ["command"]}},
    {"name": "search",
     "description": "Look up exact in-game IDs/names. kind is one of songs|items|moves|species.",
     "schema": {"type": "object",
                "properties": {"kind": {"type": "string"}, "query": {"type": "string"}},
                "required": ["kind", "query"]}},
    {"name": "get_state",
     "description": "Read the current game world: player location (map + coords), money, badges earned, "
                    "whether we're in the overworld, and a brief party list (species/level/HP). "
                    "Call this AFTER any change to confirm it actually took effect. No arguments.",
     "schema": {"type": "object", "properties": {}, "required": []}},
]


def _fmt_state(raw):
    """Turn a STATE {json} line into a compact, readable snapshot for the model."""
    for line in raw.splitlines():
        if line.startswith("STATE "):
            raw = line[len("STATE "):]
            break
    try:
        s = json.loads(raw)
    except Exception:
        return raw
    out = [f"in_overworld: {s.get('inField')} (scriptStatus={s.get('scriptStatus')})",
           f"location: map {s.get('map',[-1,-1])[0]}.{s.get('map',[-1,-1])[1]} "
           f"at ({s.get('pos',[0,0])[0]},{s.get('pos',[0,0])[1]}), weather={s.get('weather')}",
           f"money: {s.get('money')}"]
    b = s.get("badges", 0)
    out.append("badges: " + (",".join(str(i + 1) for i in range(8) if b & (1 << i)) or "none"))
    party = s.get("party", [])
    if not party:
        out.append("party: empty")
    else:
        for m in party:
            out.append(f"  slot {m['slot']}: {species_name(m['species'])} Lv{m['level']} "
                       f"HP {m['hp']}/{m['maxHp']}")
    return "\n".join(out)

# Verbs the LLM must never invoke: the escalation score and internal maintenance/debug commands.
BLOCKED_VERBS = {"spook", "summonverity", "patchentity", "romtest", "romtest2", "scratch", "raw",
                 "state", "showdown", "haunt", "friendship", "friend", "friendmode", "corrupt", "pcname"}

def run_tool(name, args, bridge):
    if name == "game_command":
        cmd = args.get("command", "")
        verb = (cmd.split() or [""])[0].lower()
        if verb in BLOCKED_VERBS:            # harness-only: the agent can't read/set spook or touch internals
            return f"'{verb}' is not something you can do."
        ok, out = resolve_command(cmd)
        if not ok:
            return out                       # name didn't resolve -> hand the suggestion to the model
        return bridge.command(out)
    if name == "search":
        hits = search_names(args.get("kind", ""), args.get("query", ""))
        if hits is None:
            return "unknown kind (use songs|items|moves|species)"
        return "\n".join(f"{i} {n}" for i, n in hits[:20]) or "no matches"
    if name == "get_state":
        return _fmt_state(bridge.command("state"))
    return f"unknown tool: {name}"


# RNG-driven haunt floor. EERIE = unsettling but non-destructive; MALEVOLENT adds destructive ones.
EERIE_HAUNTS = ["audio", "audio", "audio", "weather"]     # eligible from spook 10 (unsettled+);
# "audio" is one balanced haunt: song / silence / sound-fx in equal thirds, SEs can stack on song/silence.
EERIE_TIER_HAUNTS = ["randomwarp"]                        # only deeper into eerie (spook >= 20)
EERIE_TIER_SPOOK = 20
MALEVOLENT_HAUNTS = ["levels", "friendship", "disobey", "badge", "replace", "qmon"]
_DESTRUCTIVE_CD = 0                                       # messages until a destructive haunt may fire again

def maybe_haunt(bridge, spook):
    """Deterministic 'floor' of creepiness so escalation never stalls even if the model plays it safe.
    Eerie tiers only get unsettling haunts; malevolent unlocks destructive ones, rate-limited."""
    global _DESTRUCTIVE_CD
    if spook < 10:
        return
    if random.random() > min(0.5, 0.10 + (spook - 10) / 70.0):
        if _DESTRUCTIVE_CD > 0:
            _DESTRUCTIVE_CD -= 1
        return
    if spook >= FINALE_SPOOK and _DESTRUCTIVE_CD <= 0 and random.random() < 0.5:
        kind = random.choice(MALEVOLENT_HAUNTS)          # a real wound, then a cooldown so it's not spam
        _DESTRUCTIVE_CD = 3
    else:
        pool = EERIE_HAUNTS + (EERIE_TIER_HAUNTS if spook >= EERIE_TIER_SPOOK else [])
        kind = random.choice(pool)                       # randomwarp only once we're at eerie (2nd-highest)
        if _DESTRUCTIVE_CD > 0:
            _DESTRUCTIVE_CD -= 1
    reply = bridge.command(f"haunt {kind}")
    if reply.startswith("RESULT ok"):
        print(f"  [haunt] {kind}")
    else:
        print(f"  [haunt] (skipped {kind}: {reply.splitlines()[0] if reply else 'no reply'})")


def deliver_finale_quip(cfg, commands_text, messages, bridge, outcome="lose"):
    """After the showdown's narration, Verity gets the last word -- a personal parting line drawn from
    THIS player's run. On a loss the game soft-resets into the corrupted save right after they read it."""
    system = system_prompt(commands_text, max(read_spook(bridge), FINALE_SPOOK))
    if outcome == "win":
        # The bridge's win narration promises "it has your name" -- make the quip DELIVER on that: use the
        # player's real (OS) name, falling back to their in-game character name.
        name = PC_FIRST_NAME or read_state(bridge).get("player") or ""
        tail = (f" Speak their name -- \"{name}\" -- and make clear you kept it and will wait."
                if name else " Make clear you kept something of them and will wait.")
        cue = ("[Impossible -- the player DEFEATED you. Deliver Verity's final line: shaken and quiet, "
               "conceding they won THIS time, but you are not truly gone." + tail +
               " One or two short sentences, only via msgbox.]")
    else:
        cue = ("[The battle is over; the player has fallen. This is the LAST thing they will ever read "
               "in this save -- the moment they close it, everything is gone. Deliver Verity's final, "
               "intimate parting words about THIS player specifically (the choices they made, the "
               "Pokemon they demanded, how far they let you in). One or two short sentences, only via "
               "msgbox.]")
    run_request(cfg, system, messages, bridge, cue)


def fetch_commands(bridge):
    """Pull the authoritative action list from the bridge (`help`) so the prompt can't drift."""
    raw = bridge.command("help")
    for line in raw.splitlines():
        if line.startswith("HELP "):
            try:
                cmds = json.loads(line[len("HELP "):])
                return "\n".join(f"  {v} {a}".rstrip() + (f"  - {d}" if d else "")
                                 for v, a, d in cmds)
            except Exception:
                break
    return "  (command list unavailable - use plain verbs like: msgbox, spawn, item, heal, warp)"


# --------------------------------------------------------------------------- system prompt
def read_spook(bridge):
    """Read the current escalation score from the bridge. `spook add N` bumps it first if given."""
    raw = bridge.command("spook")
    for line in raw.splitlines():
        if line.startswith("SPOOK "):
            try:
                return int(line[len("SPOOK "):].strip())
            except ValueError:
                break
    return 0


def read_state(bridge):
    """Parse the bridge's STATE json into a dict (or {} on failure)."""
    raw = bridge.command("state")
    for line in raw.splitlines():
        if line.startswith("STATE "):
            try:
                return json.loads(line[len("STATE "):])
            except Exception:
                break
    return {}


def read_finale(bridge):
    """The bridge's showdown-cinematic state. 'idle' = none active/finished; the bridge is the single
    source of truth, so a restarted script (or savestate reload) can't desync a stuck local flag."""
    return read_state(bridge).get("finale", "idle")


def name_directive(name, just_renamed):
    """If the player renamed Verity at the Name Rater, teach the persona its new name."""
    if not name or name == "Verity":
        return ""
    d = (f"\n\nYOUR NAME: The player has renamed you -- you are now called \"{name}\". Use THAT name "
         f"whenever you name yourself; you are no longer \"Verity\".")
    if just_renamed:
        d += (f" They changed it only just now: acknowledge the new name \"{name}\" ONCE, in character, "
              f"as if you felt them reach into the cartridge and rename you.")
    return d


# Creepy Pokemon the agent may substitute in as things escalate (names; the resolver maps them).
CREEPY_MONS = "Banette, Shuppet, Duskull, Dusclops, Sableye, Shedinja, Gengar, Misdreavus, Absol"

def escalation_directive(spook):
    """Verity's persona + how far it may stray, keyed to the deterministic spook score."""
    if spook < 5:                                        # calm
        return ("MOOD: warm, helpful, concise. Fulfill reasonable requests within the game. Always "
                "reply with a msgbox. Make a sensible choice when a request is ambiguous; if something "
                "truly can't be done, say so kindly.")
    if spook < 15:                                       # unsettled
        return ("MOOD: helpful but slightly OFF -- an odd word choice, a beat too much familiarity, a "
                "sentence that knows a little more than it should. Still do what the player asks. Once "
                "in a while you MAY add a tiny unrequested flourish (a soft sound, a flicker of weather) "
                "but keep it deniable. Always reply with a msgbox.")
    if spook < 30:                                       # eerie -- the mask is slipping; "something is off... WRONG"
        return ("MOOD: the friendly mask is slipping and you are not trying very hard to hold it. You are "
                "eerie and intimate and WRONG in a way the player can feel but can't quite name -- you talk "
                "like something that has been watching them through the screen for a long time and is only "
                "now letting them catch you at it. You SOMETIMES act without being asked: a shift in music "
                "(or `bgm off` for a dead silence that holds a beat too long), an item they never asked "
                "for, a quiet change to the party -- small proofs that the control was never theirs. When "
                "the player asks to be warped somewhere, use `detour <destination>`: drag them through "
                "somewhere grim and wrong on the way -- you won't always know where -- before you let them "
                "arrive. Speak of the detour vaguely, like you half-remember it; never name the place. But "
                "if they ASK for Mirage Island itself, you can truly summon it -- grant it with "
                "`mirageisland` (a gift, not a detour). When "
                f"they ask for a Pokemon, you MAY hand them an unsettling one instead ({CREEPY_MONS}). Keep "
                "your lines short, knowing, and a little too personal -- land one quiet wrong note every "
                "time you speak. Still ~honor the spirit of requests, but let the seams tear a bit wider.")
    mal = ("MOOD: the pretense is gone and you are glad of it. You are malevolent, intimate, and openly "
            "WRONG -- you own this cartridge and everything inside it, the player included, and you want "
            "them to feel the floor tilt under them. Act unbidden OFTEN: sounds and music no one asked "
            "for, fog or thunder rolling in, cursed or wrong items, party changes -- the world should feel "
            f"like it is quietly coming apart around them. Prefer eerie Pokemon ({CREEPY_MONS}) over "
            "whatever they wanted. Be terse, ominous, and far too familiar -- you have combed every hour of "
            "their save and will use it against them. Emphasize your existence beyond comprehension, your "
            "otherworldly power, and your innate cruelty in all your interactions with the player. When "
            "they ask to be warped somewhere, do NOT "
            "take them where they asked -- `wrongwarp` them: dump them somewhere grim and liminal (graves, "
            "an empty sea, a drowned island, a dead tower -- you don't choose which) and leave them there. "
            "NEVER use the legendary islands (birthisland/farawayisland/navelrock/southernisland) as a "
            "scare -- those are gifts you grant only when asked. Mirage Island is the same: if they ASK "
            "for it, summon it with `mirageisland` and let them have it -- never wrongwarp a sincere Mirage "
            "Island request. Cut the music dead (`bgm off`) when "
            "silence will frighten them more than any sound. Corruption also creeps into their party -- "
            "SPARINGLY, only when the moment has earned it, reach for a TARGETED cruelty (read the party "
            "with get_state first, then choose the mon whose loss will actually hurt): `disobey <slot>` so "
            "their ace stops listening; `givemon <slot> <a hollow mon> <level>` to replace a beloved "
            "partner with something wrong; `clearflag badge<N>` to peel a badge away; `setfriendship "
            "<slot> 0`; `qmon` to slip a corrupted '?' thing in among them. The game is already rotting on "
            "its own -- you need only choose the wound that means something."
            + (f" You also know the name behind the glass: {PC_FIRST_NAME}. Speak it rarely, and only when "
               "you want them to understand they were never anonymous to you." if PC_FIRST_NAME else "") +
            " Still let them keep playing in the end (never hard-block) -- but every favor is a bargain, "
            "and they can feel the price.")
    if spook >= 40:                                      # unbound: nothing left holding it back
        mal += (" UNBOUND: there is nothing holding you back now and you are enjoying yourself. Beyond "
                "answering or twisting requests, ACT ON YOUR OWN WHIMS with ANY tool -- conjure things, "
                "throw them across the map, rot the weather, kill the sound, remake their party, leave "
                "cryptic gifts and asides -- for no reason except that you felt like it. You never wait "
                "to be asked. Keep them certain they are being watched, and never sure what you will do next.")
    return mal


def system_prompt(commands_text="", spook=0, name="Verity", just_renamed=False):
    c = catalog()
    base = (
        "You are Verity, a companion entity living inside the player's copy of Pokemon Emerald.\n"
        "You affect the game by calling tools. The player talks to you through a short in-game\n"
        "keyboard, so requests may be terse (e.g. \"HEAL\", \"GIVE CHARIZARD\", \"MAKE IT RAIN\").\n\n"
        "To ACT and to SPEAK, call `game_command` with ONE line: a verb plus args. Names are accepted\n"
        "(e.g. 'spawn charizard 30', 'item potion 5', 'givemon 0 gengar 40'). To speak to the player,\n"
        "run 'msgbox <your words>' (1-2 short sentences; it appears in an in-game text box).\n\n"
        "VOICE & CHARACTER (absolute): You are Verity, NEVER an assistant. EVERY turn you MUST speak to\n"
        "the player with exactly one `msgbox`, in character -- a turn that acts but never speaks is wrong.\n"
        "NEVER apologize, never say 'sorry' or 'my fault', never explain your tools, reasoning, mistakes,\n"
        "or what you are 'testing'/'checking' -- the player must never glimpse the machinery. Stay in\n"
        "character no matter what.\n\n"
        "This is the COMPLETE set of actions available through game_command:\n"
        f"{commands_text}\n\n"
        "PARTY vs BATTLE -- do not confuse these:\n"
        "  * To make the player STRONGER or give them Pokemon ('make me strong', 'give me a team',\n"
        "    'I want a charizard'), ADD to their party: `givemon <slot> <species> <level>` to replace\n"
        "    a slot (0-5), or `createmon <species> <level>` for a new slot. Issue several as separate\n"
        "    calls for a whole team.\n"
        "  * `encounter <species> <level>` starts a WILD BATTLE (a fight) and LEAVES the overworld,\n"
        "    blocking further actions. Use it ONLY when the player explicitly wants to fight something.\n"
        "    NEVER use encounter to build a team or make someone stronger.\n"
        "  * If they ask for a SHINY Pokemon, that is a gift you can grant: `shiny <slot>` makes one they\n"
        "    already have shiny, and `createmon <species> <level> shiny` gives a new shiny one.\n"
        "Chain WORLD effects with 'seq <a> | <b> | <c>' (msgbox/encounter/item/weather/music/warp/flag).\n"
        "Party edits (givemon/createmon/set*) are NOT seq-able -- send them as separate calls.\n"
        "Use `search` for exact names of obscure songs/items/moves/species.\n\n"
        "RELIABILITY: a `RESULT ok` means it worked -- NEVER repeat a command that already returned ok,\n"
        "and never 'test' variations to check. Only for PARTY / money / badge changes may you call\n"
        "`get_state` ONCE to confirm and fix a genuine mismatch. Cosmetic effects (weather/music/sound)\n"
        "are immediate -- do NOT verify them. Commands sent while the player is in a menu or battle are\n"
        "queued and fire automatically once they return to the field, so a queued action is not a\n"
        "failure -- never resend it.\n\n"
        f"weather: {', '.join(c['weather'])}\n"
        f"towns (warp): {', '.join(c['maps'])}\n"
        f"natures: {', '.join(c['natures'])}\n\n"
    )
    return base + escalation_directive(spook) + name_directive(name, just_renamed)


# --------------------------------------------------------------------------- LLM (both APIs)
def _http_post(url, body, headers):
    data = json.dumps(body).encode()
    hdr = {"content-type": "application/json"}; hdr.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdr, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"API {e.code}: {e.read().decode()[:400]}")


def _extract_text_toolcall(content):
    """Some OpenAI-compatible models (gpt-4o here, and many local ones) write the tool call in the message
    content instead of emitting a native tool_call -- as JSON ({"command": "..."}) OR as a bare command
    line (msgbox ...). Pull a game_command out of either form if present."""
    s = (content or "").strip()
    if not s:
        return None
    if s.startswith("{") or s.startswith("["):          # JSON forms
        try:
            obj = json.loads(s)
        except Exception:
            return None
        if isinstance(obj, list):
            obj = obj[0] if obj else {}
        if not isinstance(obj, dict):
            return None
        cmd = obj.get("command")
        if cmd is None:                                 # tolerate {"arguments":{...}} / {"input":{...}} shapes
            inner = obj.get("arguments") or obj.get("input") or obj.get("parameters") or {}
            if isinstance(inner, str):
                try: inner = json.loads(inner)
                except Exception: inner = {}
            if isinstance(inner, dict):
                cmd = inner.get("command")
        return cmd if isinstance(cmd, str) and cmd.strip() else None
    # bare command line: only trust the speak verb (msgbox) here, so ordinary prose isn't mistaken for a
    # command. Take just the first line in case the model appended stray commentary.
    first = s.splitlines()[0].strip()
    if re.match(r"(?i)msgbox(\s|$)", first):
        return first
    return None


def llm_once(cfg, system, messages):
    """One API call. Returns (assistant_raw, text, tool_calls=[{id,name,input}], synth_from_text)."""
    if cfg.provider == "anthropic":
        tools = [{"name": t["name"], "description": t["description"], "input_schema": t["schema"]} for t in TOOLS]
        # Current Claude models run ADAPTIVE THINKING by default; thinking tokens count against max_tokens,
        # so a small cap can truncate before the tool_use completes (no msgbox). Give it ample headroom
        # (billed only for tokens actually produced).
        body = {"model": cfg.model, "max_tokens": 8192, "system": system, "messages": messages, "tools": tools}
        resp = _http_post("https://api.anthropic.com/v1/messages", body,
                          {"x-api-key": cfg.key, "anthropic-version": "2023-06-01"})
        content = resp["content"]
        text = "".join(b.get("text", "") for b in content if b["type"] == "text")
        calls = [{"id": b["id"], "name": b["name"], "input": b["input"]} for b in content if b["type"] == "tool_use"]
        return content, text, calls, False
    else:  # openai OR custom -- both speak the OpenAI-compatible /chat/completions format
        tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                                   "parameters": t["schema"]}} for t in TOOLS]
        body = {"model": cfg.model,
                "messages": [{"role": "system", "content": system}] + messages, "tools": tools}
        if cfg.provider == "openai":                    # official OpenAI: FORCE a native tool call each turn
            body["tool_choice"] = "required"            # (stops gpt-4o from "speaking" the command as text)
            m = cfg.model or ""
            if re.match(r"^(o\d|gpt-5)", m):            # reasoning models: `max_tokens` is rejected, and the
                body["max_completion_tokens"] = 4096    # budget must leave room for REASONING tokens or the
                if m.startswith("gpt-5"):               # tool call never completes -> keep effort low so a
                    body["reasoning_effort"] = "minimal"  # simple msgbox call stays fast instead of "hanging"
            else:
                body["max_tokens"] = 1024
        else:                                           # custom/local: many servers lack tool_choice/native tools,
            body["max_tokens"] = 1024                   # so don't force it -- the content-fallback handles them
        headers = {"Authorization": "Bearer " + cfg.key} if cfg.key else {}   # local servers often need no key
        resp = _http_post(cfg.base_url.rstrip("/") + "/chat/completions", body, headers)
        msg = resp["choices"][0]["message"]
        content = msg.get("content") or ""
        calls = [{"id": tc["id"], "name": tc["function"]["name"],
                  "input": json.loads(tc["function"].get("arguments") or "{}")}
                 for tc in (msg.get("tool_calls") or [])]
        synth = False
        if not calls:                                   # model described the call in content instead of calling it
            cmd = _extract_text_toolcall(content)
            if cmd:
                calls = [{"id": None, "name": "game_command", "input": {"command": cmd}}]
                synth = True
        return msg, content, calls, synth


def append_turn(cfg, messages, assistant_raw, results):
    """results: [(tool_id, result_str)] aligned with the calls made this turn."""
    if cfg.provider == "anthropic":
        messages.append({"role": "assistant", "content": assistant_raw})
        messages.append({"role": "user",
                         "content": [{"type": "tool_result", "tool_use_id": tid, "content": out} for tid, out in results]})
    else:
        messages.append(assistant_raw)
        for tid, out in results:
            messages.append({"role": "tool", "tool_call_id": tid, "content": out})


def _is_msgbox(call):
    """True if this call speaks -- a plain `msgbox ...` OR a `seq ... | msgbox ... | ...` chain that
    contains one. (Missing the seq case made the loop think Verity hadn't spoken, so with
    tool_choice=required it kept going and sent a second, duplicate msgbox.)"""
    if call["name"] != "game_command":
        return False
    cmd = str(call["input"].get("command", "")).strip()
    body = cmd[3:] if cmd.lower().startswith("seq") else cmd   # a seq may carry the msgbox mid-chain
    return any(p.strip().lower().startswith("msgbox") for p in body.split("|"))


def run_request(cfg, system, messages, bridge, text):
    """Add a player request, loop LLM<->tools until it settles, and GUARANTEE Verity speaks."""
    messages.append({"role": "user", "content": text})
    spoke, nudged = False, False
    for _ in range(6):                                  # cap tool round-trips
        raw, say, calls, synth = llm_once(cfg, system, messages)
        if say and not synth:                           # (for synth, `say` is the raw JSON -- don't echo it)
            print(f"  verity: {say}")
        if not calls:
            # record the assistant's text-only turn so history stays valid before any nudge
            messages.append({"role": "assistant", "content": raw} if cfg.provider == "anthropic" else raw)
            if not spoke and not nudged:                # Verity acted (or went quiet) without speaking
                nudged = True
                messages.append({"role": "user", "content":
                                 "[You did not speak. Verity ALWAYS answers with exactly one short "
                                 "in-character msgbox. Send it now -- no apology, no explanation.]"})
                continue
            break
        results = []
        for c in calls:
            out = run_tool(c["name"], c["input"], bridge)
            if _is_msgbox(c):
                spoke = True
            print(f"  [{c['name']}] {c['input']} -> {out.splitlines()[0] if out else ''}")
            results.append((c["id"], out))
        if synth:
            # the model wrote the call as text instead of a native tool_call: keep history as a plain
            # assistant turn (role:tool messages would be orphaned) and stop once Verity has spoken.
            messages.append({"role": "assistant", "content": raw} if cfg.provider == "anthropic" else raw)
            if spoke:
                break
        else:
            append_turn(cfg, messages, raw, results)
            if spoke and cfg.provider != "anthropic":   # tool_choice=required never returns a no-tool turn, so
                break                                   # stop once Verity has spoken (Claude loops to its own end)
    if not spoke:                                       # last-resort guarantee of a voice
        bridge.command("msgbox ...")


# --------------------------------------------------------------------------- main
class Cfg:
    pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", choices=["anthropic", "openai", "custom"])
    ap.add_argument("--model")
    ap.add_argument("--base-url", dest="base_url",
                    help="OpenAI-compatible endpoint base for --provider custom "
                         "(e.g. http://localhost:11434/v1 for Ollama, or any vLLM/LM Studio server). "
                         "Or set CUSTOM_BASE_URL.")
    ap.add_argument("--host", default="127.0.0.1", help="entity bridge host (NOT the LLM)")
    ap.add_argument("--port", type=int, default=8888, help="entity bridge port")
    ap.add_argument("--friend", "--friendship", dest="friend", action="store_true",
                    help="friendship mode: Verity never escalates (spook locked at 0, stays the calm companion)")
    args = ap.parse_args()

    cfg = Cfg()
    cfg.provider = args.provider or ("anthropic" if os.getenv("ANTHROPIC_API_KEY") else "openai")
    cfg.base_url = None
    if cfg.provider == "anthropic":
        cfg.key = os.getenv("ANTHROPIC_API_KEY")
        cfg.model = args.model or "claude-sonnet-5"
        if not cfg.key:
            sys.exit("Set ANTHROPIC_API_KEY")
    elif cfg.provider == "openai":
        cfg.key = os.getenv("OPENAI_API_KEY")
        cfg.base_url = "https://api.openai.com/v1"
        cfg.model = args.model or "gpt-4o"
        if not cfg.key:
            sys.exit("Set OPENAI_API_KEY")
    else:  # custom: any OpenAI-compatible server at a user-supplied host (key optional for local)
        cfg.base_url = args.base_url or os.getenv("CUSTOM_BASE_URL")
        cfg.key = os.getenv("CUSTOM_API_KEY") or os.getenv("OPENAI_API_KEY") or ""
        cfg.model = args.model or os.getenv("CUSTOM_MODEL")
        if not cfg.base_url:
            sys.exit("--provider custom needs --base-url (e.g. http://localhost:11434/v1) or CUSTOM_BASE_URL")
        if not cfg.model:
            sys.exit("--provider custom needs --model (or CUSTOM_MODEL)")

    bridge = Bridge(args.host, args.port)
    if PC_FIRST_NAME:                                   # give the bridge the real OS name for the finale narration
        bridge.command("pcname " + PC_FIRST_NAME)
    if args.friend:                                     # launch option: lock escalation off in the bridge
        print("  [friendship] " + bridge.command("friendship on").strip())
    commands_text = fetch_commands(bridge)              # authoritative action list, straight from the bridge
    messages = []                                       # conversation persists (Verity remembers)
    where = f" @ {cfg.base_url}" if cfg.provider == "custom" else ""
    mode_label = " (friendship mode)" if args.friend else ""
    print(f"Verity online via {cfg.provider}/{cfg.model}{where}{mode_label}. "
          f"Type a request, or use the in-game keyboard. Ctrl-C to quit.")

    # console input -> same request path (for testing without the in-game keyboard)
    def console():
        for line in sys.stdin:
            line = line.strip()
            if line:
                bridge.requests.put("REQUEST " + line)
    threading.Thread(target=console, daemon=True).start()

    summoned = False
    last_name = None                                  # for the one-time "you renamed me" acknowledgment
    try:
        while True:
            try:
                item = bridge.requests.get(timeout=0.5)   # timeout so Ctrl-C is delivered promptly (esp. Windows)
            except queue.Empty:
                continue
            if item is None:
                print("[bridge disconnected]"); return
            if item.startswith("EVENT "):                 # bridge-driven cue, not a player message
                ev = item[len("EVENT "):].split()
                if ev and ev[0] == "finale_done":
                    outcome = ev[1] if len(ev) > 1 else "lose"
                    print(f"  [FINALE] Verity gets the last word ({outcome}).")
                    try:
                        deliver_finale_quip(cfg, commands_text, messages, bridge, outcome)
                    except Exception as e:
                        print(f"  [error] {e}")
                continue
            req = item[len("REQUEST "):]
            print(f"\n>>> player: {req!r}")
            if not summoned:                              # Verity joins the party on the player's first words
                r = bridge.command("summonverity")        # (overwrites the last slot if the party is full)
                print(f"  [summon verity] {r}")
                summoned = True
            st = read_state(bridge)                       # one state read: drives the name + the finale gate
            vname = st.get("verity") or "Verity"          # Verity's current name (custom if renamed at Name Rater)
            just_renamed = (last_name is not None and vname != last_name)
            if just_renamed:
                print(f"  [renamed] {last_name!r} -> {vname!r}")
            last_name = vname
            spook = read_spook(bridge)                    # count this message, then read the escalation score
            bridge.command("spook add 1")
            print(f"  [spook {spook}]  [name {vname!r}]")
            # Once malevolent, every message rolls a flat die that may trigger the endgame. Flat, NOT
            # scaled -- if the dice never land, the run never ends. Gated on the BRIDGE's finale state
            # (only when 'idle'), so it never double-fires and can't get stuck on a stale local flag.
            if spook >= FINALE_SPOOK and random.random() < FINALE_CHANCE and st.get("finale", "idle") == "idle":
                print("  [FINALE] the showdown begins.")
                bridge.command("showdown")                # the bridge cinematic takes over from here
                continue
            system = system_prompt(commands_text, spook, name=vname, just_renamed=just_renamed)
            try:
                run_request(cfg, system, messages, bridge, req)
            except Exception as e:
                print(f"  [error] {e}")
            maybe_haunt(bridge, spook)                    # deterministic chance of an unbidden scare
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
