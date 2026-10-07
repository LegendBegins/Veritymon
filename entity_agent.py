#!/usr/bin/env python3
"""Entity agent/client for entity_bridge.lua (Milestone 1).

The bridge exposes high-level verbs; this client speaks them. It also listens
for REQUEST events (what the player typed as the entity's nickname) and can
interpret them into effects.

    python entity_agent.py                 # manual: type verbs yourself
    python entity_agent.py --auto          # auto-interpret REQUEST events

Manual verbs (passed straight to the bridge):
    msgbox <text> | spawn <id> <level> | state | ping | raw <hex> | scratch <addr>
"""
import argparse
import difflib
import json
import re
import socket
import sys
import threading

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# Name tables (generated from the decomp). IDs the bridge sends -> readable names.
try:
    import poke_data as _pd
    SPECIES_NAMES = getattr(_pd, "SPECIES_NAMES", {})
    MOVE_NAMES    = getattr(_pd, "MOVE_NAMES", {})
    ITEM_NAMES    = getattr(_pd, "ITEM_NAMES", {})
    NATURE_NAMES  = getattr(_pd, "NATURE_NAMES", [])
    SONG_NAMES    = getattr(_pd, "SONG_NAMES", {})
except Exception:
    SPECIES_NAMES, MOVE_NAMES, ITEM_NAMES, NATURE_NAMES, SONG_NAMES = {}, {}, {}, [], {}


def _norm(s):                       # normalize a name: upper, fold é->E, drop non-alphanumerics
    return re.sub(r"[^A-Z0-9]", "", str(s).upper().replace("É", "E"))


def _rev(names):                    # {id: NAME} -> {normkey: id}, skipping placeholder "?" names
    r = {}
    for k, v in names.items():
        if isinstance(v, str) and v not in ("?", "??????????"):
            r.setdefault(_norm(v), k)
    return r


SPECIES_BY_NAME = _rev(SPECIES_NAMES)
MOVE_BY_NAME    = _rev(MOVE_NAMES)
ITEM_BY_NAME    = _rev(ITEM_NAMES)
SONG_BY_NAME    = _rev(SONG_NAMES)
for _alias in ("OFF", "SILENCE", "NONE", "STOP", "QUIET", "MUTE"):   # MUS_DUMMY (0) = dead air
    SONG_BY_NAME.setdefault(_alias, 0)
# mirror the bridge's curated eerie-song aliases (keep in sync with SONG in entity_bridge.lua)
for _a, _id in {"CREEPY": 432, "SUSPICIOUS": 423, "VSREGI": 479}.items():
    SONG_BY_NAME.setdefault(_a, _id)
NATURE_BY_NAME  = {_norm(n): i for i, n in enumerate(NATURE_NAMES)}
# Sound-effect palette (SE_ ids) -- keep in sync with the SE table in entity_bridge.lua.
SE_BY_NAME = {_norm(k): v for k, v in {
    "ding": 73, "dingdong": 73, "pin": 21,
    "low health": 90, "fall": 43, "sinkhole": 39, "warp in": 45, "warp out": 46,
    "door": 8, "sliding door": 18, "breakable door": 77, "thunder": 87, "thunder2": 88,
    "glass flute": 117, "orb": 107, "explosion": 178, "absorb": 180, "bang": 20, "ice break": 41,
    "curtain fall": 98, "elevator": 89, "blast": 103, "vend": 106,
}.items()}
NAME_TABLES     = {"species": SPECIES_BY_NAME, "item": ITEM_BY_NAME, "move": MOVE_BY_NAME,
                   "song": SONG_BY_NAME, "nature": NATURE_BY_NAME, "se": SE_BY_NAME}

# Small closed sets worth giving the LLM up front (it won't know the exact accepted tokens).
WEATHER_LIST = ["sunny", "rain", "thunderstorm", "fog", "sandstorm", "overcast",
                "ash", "snow", "clouds", "drought", "shade"]
MAP_LIST = ["petalburg", "slateport", "mauville", "rustboro", "fortree", "lilycove",
            "mossdeep", "sootopolis", "evergrande", "littleroot", "oldale", "dewford",
            "lavaridge", "fallarbor", "verdanturf", "pacifidlog", "mtpyre",
            "deoxys", "mew", "latios", "latias", "hooh", "lugia", "navelrock",
            "birthisland", "farawayisland", "southernisland", "mirageisland", "secretbase"]
TYPES = ["Normal", "Fighting", "Flying", "Poison", "Ground", "Rock", "Bug", "Ghost", "Steel",
         "???", "Fire", "Water", "Grass", "Electric", "Psychic", "Ice", "Dragon", "Dark"]

# Large tables: search on demand rather than dumping into context.
BIG_TABLES = {"songs": SONG_NAMES, "song": SONG_NAMES, "items": ITEM_NAMES, "item": ITEM_NAMES,
              "moves": MOVE_NAMES, "move": MOVE_NAMES, "species": SPECIES_NAMES,
              "pokemon": SPECIES_NAMES}


def search_names(kind, query, limit=30):
    """Substring search over a big name table -> [(id, name)]. kind: songs/items/moves/species."""
    tbl = BIG_TABLES.get(kind.lower())
    if tbl is None:
        return None
    q = _norm(query)
    return [(i, n) for i, n in sorted(tbl.items())
            if isinstance(n, str) and n not in ("?", "??????????") and q in _norm(n)][:limit]


def catalog():
    """The small closed sets, for the LLM's context window."""
    return {"weather": WEATHER_LIST, "maps": MAP_LIST, "natures": list(NATURE_NAMES),
            "types": TYPES, "badges": [f"badge{i}" for i in range(1, 9)]}

# Per-verb argument schemas: "num" = pass a number through, name-types are resolved to IDs.
# A trailing "?" marks an optional arg. Verbs not listed pass through untouched
# (state/party/warp/weather/setflag/noclip/msgbox/... -- the bridge resolves those names).
SCHEMAS = {
    "encounter": ["species", "num"], "spawn": ["species", "num"], "setspecies": ["num", "species"],
    "createmon": ["species", "num", "nature?"], "givemon": ["num", "species", "num"],
    "item": ["item", "num?"], "give_item": ["item", "num?"], "setitem": ["num", "item"],
    "haskeyitem": ["item"],
    "setmove": ["num", "num", "move"], "setmoveset": ["num"],
    "bgm": ["song"], "song": ["song"], "music": ["song"], "fanfare": ["song"],
    "sound": ["se"], "se": ["se"],
}


def _resolve_name(tokens, i, table, maxwords=3):
    """Greedily match the longest run of tokens from i that forms a known name."""
    for n in range(min(maxwords, len(tokens) - i), 0, -1):
        rid = table.get(_norm("".join(tokens[i:i + n])))
        if rid is not None:
            return rid, n
    return None, 0


# id->name tables per schema type, for building "did you mean" suggestions.
_ID_NAME = {"species": SPECIES_NAMES, "item": ITEM_NAMES, "move": MOVE_NAMES, "song": SONG_NAMES,
            "nature": {i: n for i, n in enumerate(NATURE_NAMES)}}
_SEARCH_KIND = {"species": "species", "item": "items", "move": "moves", "song": "songs"}


def suggest_names(typ, token, n=5):
    """Closest known names to a mistyped token (fuzzy), for a schema type -> [display names]."""
    tbl = _ID_NAME.get(typ) or {}
    norm2disp = {}
    for v in tbl.values():
        if isinstance(v, str) and v not in ("?", "??????????"):
            norm2disp.setdefault(_norm(v), v)
    hits = difflib.get_close_matches(_norm(token), list(norm2disp), n=n, cutoff=0.4)
    return [norm2disp[k] for k in hits]


def resolve_command(line):
    """Like translate(), but returns (ok, out). On an unresolved name, ok is False and out is a
    helpful message (with suggestions) the caller can hand straight back to the model."""
    parts = line.split()
    if not parts:
        return True, line
    verb = parts[0].lower()
    if verb == "seq":                                     # resolve names inside each |-separated action
        body = line[len(parts[0]):].strip()
        resolved = []
        for sub in (p.strip() for p in body.split("|")):
            if not sub:
                continue
            ok, out = resolve_command(sub)
            if not ok:
                return False, out
            resolved.append(out)
        return True, "seq " + " | ".join(resolved)
    schema = SCHEMAS.get(verb)
    if not schema:
        return True, line
    args, out, i = parts[1:], [verb], 0
    for slot in schema:
        optional, typ = slot.endswith("?"), slot.rstrip("?")
        if i >= len(args):
            if optional:
                break
            return True, line                             # missing required arg -> let bridge error
        if typ == "num" or re.fullmatch(r"-?\d+|0x[0-9a-fA-F]+", args[i]):
            out.append(args[i]); i += 1
        else:
            rid, n = _resolve_name(args, i, NAME_TABLES[typ])
            if rid is None:
                if optional:
                    break
                sugg = suggest_names(typ, args[i])
                hint = (" Did you mean: " + ", ".join(sugg) + "?") if sugg else ""
                kind = _SEARCH_KIND.get(typ)
                tail = f" Or use `search {kind} <query>`." if kind else ""
                return False, f"unknown {typ} '{args[i]}'.{hint}{tail}"
            out.append(str(rid)); i += n
    out += args[i:]
    return True, " ".join(out)


def translate(line):
    """Resolve names to IDs per the verb schema; leave everything else untouched (manual client)."""
    ok, out = resolve_command(line)
    if not ok:
        print("  [translate] " + out)
        return line
    return out


def handle_local(line):
    """Agent-local lookups (not sent to the bridge). Returns True if handled."""
    p = line.split()
    if not p:
        return False
    c = p[0].lower()
    if c == "search" and len(p) >= 3:
        hits = search_names(p[1], " ".join(p[2:]))
        if hits is None:
            print("  usage: search <songs|items|moves|species> <query>")
        elif not hits:
            print("  (no matches)")
        else:
            for i, n in hits:
                print(f"  {i:>4}  {n}")
        return True
    if c == "list" and len(p) >= 2:
        sets, w = catalog(), p[1].lower()
        if w in sets:
            print("  " + ", ".join(map(str, sets[w])))
        elif w in BIG_TABLES:
            print(f"  {w} is large ({len(BIG_TABLES[w])} entries) -- use: search {w} <query>")
        else:
            print("  list <weather|maps|natures|types|badges>   |   search <songs|items|moves|species> <q>")
        return True
    if c == "catalog":
        print(json.dumps(catalog(), ensure_ascii=False))
        return True
    return False


def species_name(i): return SPECIES_NAMES.get(i, f"#{i}")
def move_name(i):    return "-" if i == 0 else MOVE_NAMES.get(i, f"#{i}")
def item_name(i):    return "none" if i == 0 else ITEM_NAMES.get(i, f"#{i}")
def nature_name(i):  return NATURE_NAMES[i] if 0 <= i < len(NATURE_NAMES) else f"#{i}"


def render_mon(js):
    try:
        m = json.loads(js)
    except Exception:
        print("\n<< MON " + js); return
    moves = ", ".join(f"{move_name(mv)}({pp})" for mv, pp in zip(m["moves"], m["pp"]) if mv)
    print(f"\n[slot {m['slot']}] {species_name(m['species'])} Lv{m['level']} "
          f"({nature_name(m['nature'])})  HP {m['hp']}/{m['maxHp']}  held: {item_name(m['item'])}")
    print(f"    moves: {moves}")
    print(f"    IVs {'/'.join(map(str, m['ivs']))}  "
          f"EVs {'/'.join(map(str, m['evs']))}  friendship {m['friendship']}")


def interpret(request, sock):
    """Trivial placeholder 'agent': species name -> spawn; else echo via msgbox.
    (This is where an LLM would map free text -> one or more high-level verbs.)"""
    sid = SPECIES_BY_NAME.get(_norm(request))
    if sid is not None:
        print(f"  [auto] '{request}' -> spawn {sid} (lvl 5)")
        sock.sendall(f"spawn {sid} 5\n".encode())
    else:
        print(f"  [auto] '{request}' -> msgbox echo")
        sock.sendall(f"msgbox {request}\n".encode())


def reader(sock, auto, stop):
    buf = ""
    while not stop.is_set():
        try:
            data = sock.recv(4096)
        except OSError:
            return                                        # socket closed on shutdown -- exit quietly
        if not data:
            if not stop.is_set():
                print("\n[disconnected]")
            return
        buf += data.decode(errors="replace")
        while "\n" in buf:
            if stop.is_set():
                return
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if line.startswith("REQUEST "):
                req = line[len("REQUEST "):]
                print(f"\n>>> entity heard: {req!r}")
                if auto:
                    interpret(req, sock)
            elif line.startswith("MON {"):
                render_mon(line[4:])
            elif line.startswith("MON none"):
                print("\n[party] empty")
            else:
                print("\n<< " + line)
            print("> ", end="", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8888)
    ap.add_argument("--auto", action="store_true", help="auto-interpret REQUEST events")
    args = ap.parse_args()

    sock = socket.create_connection((args.host, args.port))
    print(f"connected to {args.host}:{args.port}  (species table: {len(SPECIES_BY_NAME)} names)")
    try:                                                  # give the bridge the real OS name (finale narration)
        import getpass
        _toks = [t for t in re.split(r"[^A-Za-z]+", (getpass.getuser() or "").strip()) if t]
        if _toks:
            sock.sendall(("pcname " + _toks[0].capitalize() + "\n").encode())
    except Exception:
        pass
    stop = threading.Event()
    rt = threading.Thread(target=reader, args=(sock, args.auto, stop), daemon=True)
    rt.start()

    print("Names work everywhere: `spawn charizard 30`, `item potion 5`, `givemon 0 gengar 40`,")
    print("`setmove 0 0 flamethrower`, `music littleroot`, `warp littleroot 8 8`, `weather fog`,")
    print("`noclip on`, `patchentity`, `party`, `mon 0`, `seq a | b | c`, `quit`.")
    print("Lookups: search <songs|items|moves|species> <q>  |  list <weather|maps|natures|types|badges>  |  catalog")
    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            continue
        if line in ("quit", "exit"):
            break
        if handle_local(line):                            # search/list/catalog lookups
            continue
        sock.sendall((translate(line) + "\n").encode())   # resolve names -> IDs
    # clean shutdown: stop the reader and close the socket BEFORE we return, so the daemon thread isn't
    # mid-I/O at interpreter finalization (which prints the scary "_enter_buffered_busy" fatal error).
    stop.set()
    try: sock.shutdown(socket.SHUT_RDWR)
    except OSError: pass
    try: sock.close()
    except OSError: pass
    rt.join(timeout=1.0)


if __name__ == "__main__":
    main()
