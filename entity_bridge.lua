-- entity_bridge.lua  (Emerald "Entity" horror mod - Milestone 1)
-- mGBA (standalone) bridge for Pokemon Emerald (US).
--
-- Runs the game's OWN script engine from Lua by staging bytecode in RAM and
-- kicking the global script context. The external agent sends HIGH-LEVEL verbs
-- (e.g. `msgbox Hello`, `spawn 4 5`); this bridge assembles the bytecode.
--
-- Load in mGBA: Tools > Scripting... > File > Load script.
-- Protocol (newline-terminated, TCP :8888):
--   msgbox <text>        -> show a field message box
--   spawn <id> <level>   -> start a wild battle vs species id at level
--   raw <hexpairs>       -> stage & run raw bytecode (debug), e.g. "raw 0F00...0902 02"
--   state                -> report status + entity nickname
--   scratch <hexaddr>    -> relocate the staging buffer (debug)
-- Emits:  REQUEST <text>  when the entity's nickname changes (you "talk" to it)

------------------------------------------------------------------------
-- Config / validated addresses (vanilla Emerald US, pret symbols)
------------------------------------------------------------------------
-- hotkey = GBA key bitmask to summon the entity's keyboard (default L+R).
-- bits: A=1 B=2 SELECT=4 START=8 RIGHT=0x10 LEFT=0x20 UP=0x40 DOWN=0x80 R=0x100 L=0x200
-- (Avoid SELECT: in RSE it's "register an item"; L and R are unused in the field.)
local CFG = { port = 8888, entitySlot = 0, hotkey = 0x300 }

local CTX       = 0x03000E40   -- sGlobalScriptContext (0x74 bytes)
local STATUS    = 0x03000E38   -- sGlobalScriptContextStatus (0=RUNNING,1=WAITING,2=SHUTDOWN)
local CMDTABLE  = 0x081DB67C   -- gScriptCmdTable
local CMDEND    = 0x081DBA08   -- gScriptCmdTableEnd
local BATTLEFLAGS = 0x02022FEC -- gBattleTypeFlags (stale in overworld -- info only, NOT a guard)
local GMAIN     = 0x030022C0   -- gMain; callback2 at +0x04
local CB2_OVERWORLD = 0x08085E5C -- steady-state field callback (compare with Thumb bit masked)
local PARTY     = 0x020244EC   -- gPlayerParty
local PARTYCOUNT= 0x020244E9   -- gPlayerPartyCount
local MON_SIZE  = 100

local SCRIPT_MODE_BYTECODE = 1
local CONTEXT_RUNNING, CONTEXT_SHUTDOWN = 0, 2

-- ScriptContext field offsets
local C_stackDepth, C_mode, C_cmp, C_native, C_scriptPtr = 0x00, 0x01, 0x02, 0x04, 0x08
local C_cmdTable, C_cmdEnd, C_data = 0x5C, 0x60, 0x64

local OP = { end_ = 0x02, callstd = 0x09, loadword = 0x0F, setvar = 0x16, addvar = 0x17,
             special = 0x25, waitstate = 0x27, delay = 0x28, setflag = 0x29, clearflag = 0x2A,
             playse = 0x2F, playfanfare = 0x31, waitfanfare = 0x32, playbgm = 0x33, fadeoutbgm = 0x36, warp = 0x39,
             additem = 0x44, removeitem = 0x45, lockall = 0x69, releaseall = 0x6B,
             addmoney = 0x90, setweather = 0xA4, doweather = 0xA5,
             setwildbattle = 0xB6, dowildbattle = 0xB7 }
local SPECIAL_HEAL_PARTY = 0x0000    -- HealPlayerParty
local WARP_ID_NONE = 0xFF            -- warp by coords
local MSGBOX_DEFAULT = 4
local SPECIAL_WALDA_NAMING = 0x0201  -- DoWaldaNamingScreen: 15-char keyboard; result -> gStringVar2
local GSTRINGVAR2 = 0x02021DC4       -- 0x100 bytes; holds the typed phrase after the screen closes
local REQUEST_CAP = 15               -- WALDA_PHRASE_LENGTH
local SAVEBLOCK1_PTR = 0x03005D8C    -- gSaveBlock1Ptr (IWRAM pointer to SaveBlock1)
local WALDA_TEXT_OFF = 0x3D74        -- offsetof(SaveBlock1, waldaPhrase.text) = 0x3D70 + 0x04

-- request-capture state (declared early so both the command handler and onFrame can see them)
local askState, lastCombo, lastRequest = "idle", false, ""

-- Free tail of EWRAM (highest static ~0x0203CF60; heap+decompbuf are <0x02020000).
-- Survives battles, unlike gDecompressionBuffer. Relocatable via `scratch` cmd.
local scratch = 0x0203F000

-- ascii(32..126) -> GBA charmap byte (from pret charmap.txt; '$'/0xFF omitted)
-- 34='"' -> 0xB2 (”), 39="'" -> 0xB4 (apostrophe) -- both were missing, so quotes/apostrophes got dropped.
local CHARMAP = {[32]=0,[33]=171,[34]=178,[37]=91,[38]=45,[39]=180,[40]=92,[41]=93,[43]=46,[44]=184,[45]=174,
[46]=173,[47]=186,[48]=161,[49]=162,[50]=163,[51]=164,[52]=165,[53]=166,[54]=167,[55]=168,
[56]=169,[57]=170,[58]=240,[59]=54,[60]=133,[61]=53,[62]=134,[63]=172,[65]=187,[66]=188,
[67]=189,[68]=190,[69]=191,[70]=192,[71]=193,[72]=194,[73]=195,[74]=196,[75]=197,[76]=198,
[77]=199,[78]=200,[79]=201,[80]=202,[81]=203,[82]=204,[83]=205,[84]=206,[85]=207,[86]=208,
[87]=209,[88]=210,[89]=211,[90]=212,[97]=213,[98]=214,[99]=215,[100]=216,[101]=217,[102]=218,
[103]=219,[104]=220,[105]=221,[106]=222,[107]=223,[108]=224,[109]=225,[110]=226,[111]=227,
[112]=228,[113]=229,[114]=230,[115]=231,[116]=232,[117]=233,[118]=234,[119]=235,[120]=236,
[121]=237,[122]=238}
local UNMAP = {}          -- GBA byte -> ascii (for decoding nicknames)
for a, g in pairs(CHARMAP) do UNMAP[g] = string.char(a) end

------------------------------------------------------------------------
-- Memory helpers
------------------------------------------------------------------------
local function r8(a)  return emu:read8(a)  end
local function w8(a,v)  emu:write8(a, v & 0xFF) end
local function w32(a,v) emu:write32(a, v & 0xFFFFFFFF) end
local function cb2() return emu:read32(GMAIN + 4) end
local function inField() return (cb2() & 0xFFFFFFFE) == CB2_OVERWORLD end
local function inBattle() return emu:read32(BATTLEFLAGS) ~= 0 end  -- info only
local function scriptIdle() return emu:read8(STATUS) == CONTEXT_SHUTDOWN end

local function writeBytes(addr, bytes)
  for i = 1, #bytes do emu:write8(addr + i - 1, bytes[i] & 0xFF) end
end

-- Control bytes: \n=0xFE (newline), \l=0xFA (scroll), \p=0xFB (new paragraph), EOS=0xFF.
-- The GBA text engine does NOT auto-wrap, so we insert breaks ourselves.
-- Agent may force breaks with tokens {n} {l} {p}; otherwise we word-wrap.
local WRAP = 35   -- max chars per line (approx; variable-width font, so tune to taste)

local function putStr(out, s)
  for i = 1, #s do local g = CHARMAP[s:byte(i)]; if g then out[#out + 1] = g end end
end

-- Fold the "smart" Unicode punctuation an LLM loves to emit down to the ASCII the charmap understands,
-- so apostrophes/dashes/quotes render instead of silently vanishing (they arrive as multi-byte UTF-8).
local function normalizePunct(s)
  s = s:gsub("\226\128\152", "'"):gsub("\226\128\153", "'")    -- ' '  (U+2018/2019) -> '
  s = s:gsub("\226\128\156", '"'):gsub("\226\128\157", '"')    -- " "  (U+201C/201D) -> "
  s = s:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")    -- en/em dash (U+2013/2014) -> -
  s = s:gsub("\226\128\166", "...")                            -- ellipsis (U+2026) -> ...
  s = s:gsub("\194\160", " ")                                  -- non-breaking space -> space
  return s
end

-- scroll=true -> continuous \l scroll (creepy); false -> \p page-clear pagination.
local function encodeText(s, scroll)
  local out = {}
  s = normalizePunct(s)                           -- fold smart quotes/dashes/ellipsis to ASCII first
  if s:find("{[nlp]}") then                       -- explicit formatting: honor tokens
    local i = 1
    while i <= #s do
      local tok = s:sub(i, i + 2)
      if tok == "{n}" then out[#out + 1] = 0xFE; i = i + 3
      elseif tok == "{l}" then out[#out + 1] = 0xFA; i = i + 3
      elseif tok == "{p}" then out[#out + 1] = 0xFB; i = i + 3
      else local g = CHARMAP[s:byte(i)]; if g then out[#out + 1] = g end; i = i + 1 end
    end
  else                                            -- auto word-wrap
    local lines, cur = {}, ""
    local function flush() if #cur > 0 then lines[#lines + 1] = cur; cur = "" end end
    for word in s:gmatch("%S+") do
      while #word > WRAP do              -- hard-break a word too long to ever fit a line
        flush()
        lines[#lines + 1] = word:sub(1, WRAP)
        word = word:sub(WRAP + 1)
      end
      if #cur == 0 then cur = word
      elseif #cur + 1 + #word <= WRAP then cur = cur .. " " .. word
      else flush(); cur = word end
    end
    flush()
    -- page mode: \n (0xFE) for line 2, \p (0xFB) to clear+advance each page.
    -- scroll mode: \n for line 2, then \l (0xFA) to scroll every further line.
    for li, line in ipairs(lines) do
      if li > 1 then
        if scroll then out[#out + 1] = (li == 2) and 0xFE or 0xFA
        else out[#out + 1] = (li % 2 == 0) and 0xFE or 0xFB end
      end
      putStr(out, line)
    end
  end
  out[#out + 1] = 0xFF
  return out
end

local function decodeStr(addr, cap)          -- GBA charmap bytes -> ascii, until 0xFF or cap
  local chars = {}
  for i = 0, cap - 1 do
    local b = r8(addr + i)
    if b == 0xFF then break end             -- EOS
    chars[#chars + 1] = UNMAP[b] or "?"
  end
  return table.concat(chars)
end

------------------------------------------------------------------------
-- Script engine driver: stage a bytecode blob and run it
------------------------------------------------------------------------
-- Returns true if launched, or false, reason.
-- Actually launch a staged bytecode blob (assumes the field is idle & in the overworld).
local function startBlob(blob)
  writeBytes(scratch, blob)
  -- Build the global script context the way InitScriptContext + SetupBytecodeScript would.
  w8(CTX + C_stackDepth, 0)
  w8(CTX + C_mode, SCRIPT_MODE_BYTECODE)
  w8(CTX + C_cmp, 0)
  w32(CTX + C_native, 0)
  w32(CTX + C_scriptPtr, scratch)
  w32(CTX + C_cmdTable, CMDTABLE)
  w32(CTX + C_cmdEnd, CMDEND)
  for i = 0, 3 do w32(CTX + C_data + i * 4, 0) end
  w8(STATUS, CONTEXT_RUNNING)          -- field loop runs it next frame
  if console then console:log(string.format("[entity] launch op=0x%02X len=%d t=%d", blob[1] or 0xFF, #blob, patchTick or 0)) end
end

-- Run now if the field is idle; otherwise QUEUE it (a text box is open, or we're in a menu/battle)
-- and it fires automatically the moment the field goes idle. Returns true so callers never retry.
scriptQueue = {}                       -- global (see the 200-locals note); drained in onFrame
SCRIPT_QUEUE_MAX = 8
-- SETTLE: after any injected script we wait a few IDLE frames before launching the next. A fast script
-- (a bgm change ends in ~1 frame) otherwise lets the next blob (e.g. the forced msgbox) fire while the
-- FIELD is still tearing the previous one down -- that collision wedged msgbox (lockall issued, releaseall
-- never reached): player locked, no box, audio still playing, only a savestate cleared it. lastBusyTick is
-- refreshed every non-idle frame (onFrame); settled() means the context has been idle >= SETTLE_FRAMES.
lastBusyTick = 0
SETTLE_FRAMES = 5
function settled() return ((patchTick or 0) - (lastBusyTick or 0)) >= SETTLE_FRAMES end
local function runBlob(blob)
  if inField() and scriptIdle() and settled() then startBlob(blob); return true end
  if #scriptQueue >= SCRIPT_QUEUE_MAX then table.remove(scriptQueue, 1) end   -- drop the oldest
  scriptQueue[#scriptQueue + 1] = blob
  return true                          -- queued; will run when the field is next idle + settled
end

-- little-endian byte helpers for the assembler
local function u16(v) return v & 0xFF, (v >> 8) & 0xFF end
local function u32b(v) return v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF end

------------------------------------------------------------------------
-- Effect assembler: emitters append script commands to a builder; a builder
-- may hold several effects (a sequence) and is finalized into ONE script.
------------------------------------------------------------------------
-- Named-constant tables so the agent uses words, not magic numbers.
local WEATHER = { sunnyclouds=1, clouds=1, sunny=2, drought=2, harshsun=2, rain=3, snow=4,
                  thunderstorm=5, storm=5, thunder=5, fog=6, ash=7, volcanicash=7,
                  sandstorm=8, sand=8, fogdiagonal=9, overcast=11, cloudy=11, shade=11, dark=11 }
local SONG = { badge=369, item=370, heal=368, levelup=367, tmhm=372,               -- MUS_ ids
               creepy=432, mtpyre=432, mtpyreexterior=434, caveoforigin=386,        -- verified eerie tracks
               sealedchamber=438, abnormalweather=443, suspicious=423, vsregi=479,
               silence=0, none=0, off=0, stop=0 }                                   -- MUS_DUMMY = dead air
local SE   = { pin=21, ding=73, dingdong=73,                                       -- SE_ ids (scary palette)
               lowhealth=90, fall=43, sinkhole=39, warpin=45, warpout=46,
               door=8, slidingdoor=18, breakabledoor=77, thunder=87, thunder2=88,
               glassflute=117, orb=107, explosion=178, absorb=180, bang=20, icebreak=41,
               curtainfall=98, elevator=89, blast=103, vend=106 }
local MAP  = { petalburg={0,0}, slateport={0,1}, mauville={0,2}, rustboro={0,3}, fortree={0,4},
               lilycove={0,5}, mossdeep={0,6}, sootopolis={0,7}, evergrande={0,8},
               littleroot={0,9}, oldale={0,10}, dewford={0,11}, lavaridge={0,12},
               fallarbor={0,13}, verdanturf={0,14}, pacifidlog={0,15},
               -- event/creepy destinations (map_groups.json: Dungeons=24, SpecialArea=26; verified vs live)
               mtpyre={24,15,17,11},                                  -- Mt. Pyre {group,num,x,y}: 13N/3W of warp 0
               deoxys={26,58}, birthisland={26,58},                   -- Birth Island Exterior (Deoxys)
               mew={26,57}, farawayisland={26,57},                    -- Faraway Island Interior (Mew)
               latios={26,10}, latias={26,10}, southernisland={26,10},-- Southern Island Interior
               hooh={26,75}, lugia={26,87}, navelrock={26,66},        -- Navel Rock top / bottom / exterior
               mirageisland={0,45,41,25},                              -- Route 130 (80x40, NO warps -> warp 0 is OOB); captured on-island landing tile
               secretbase={24,117},                                    -- a secret-base map (bonus spot; messes with state)
               halloffame={16,11} }                                    -- Ever Grande Hall of Fame (the showdown stage)
local BADGE = {}
for i = 1, 8 do BADGE["badge" .. i] = 0x866 + i end   -- FLAG_BADGE01_GET 0x867 .. BADGE08 0x86E
VERITY_SPECIES = { [252] = true, [253] = true }  -- entity slots (see ENTITY/ENTITY2): protected, can't be overwritten
-- Escalation ("spook") score: rises with player behavior; the agent reads it to scale Verity's
-- tone + how far it strays. Tracked deterministically here so it can't drift. Weather box legendaries
-- (internal ids in THIS rom: Kyogre 404, Groudon 405, Rayquaza 406) -- duplicates are extra unnerving.
SPOOK_LEGENDARY = { [404] = true, [405] = true, [406] = true }
-- PERSISTENCE: spook IS Verity's LEVEL (getSpook/addSpook/setSpook, defined later, read/write it in the
-- party or the PC box). So the escalation is saved with the mon and survives reloads. No spookLevel var.
spookBadges = nil     -- last-seen badge mask (detect newly-hacked badges)
finaleState = "idle"  -- showdown cinematic state machine (see finaleStep); driven by `showdown`
finaleSawBattle = false
finaleWeak = false    -- `showdown weak`: a BEATABLE Lv5 boss (test the rare WIN ending); normal = buffed/unwinnable
pcName = ""           -- the player's REAL (OS) name; pushed by a client via `pcname` (bridge can't read the OS)
finaleOutcome = ""    -- "win"/"lose" (set at battle end); resetTick/sawQuip pace the post-loss soft-reset
resetTick, sawQuip, quipWaitTick = 0, false, 0   -- sawQuip: quip box appeared; resetTick: frames cleared since;
                                                 -- quipWaitTick: frames waiting for the quip to arrive (LLM latency)
detourState = "idle"  -- eerie "double warp": drag the player through a grim place, then on to <dest>
detourG, detourN, detourX, detourY = 0, 0, nil, nil   -- the RESOLVED destination (so the 2nd warp can't fail)
detourTick = 0
GRIM = { "mtpyre", "mirageisland", "secretbase" }      -- grim waypoints (see MAP); shared by detour + wrongwarp
-- Conjuring a box legendary (spawn/create/give/setspecies) is deeply unnerving -> raise the score.
function noteLegendary(species) if SPOOK_LEGENDARY[species] then addSpook(3) end end
-- Asking for a Master Ball or any KEY ITEM is a "you're breaking the world" tell -> raise the score.
-- Key items: 259-288 (bikes/rods/tickets/fossils/orbs/keys/Devon Scope) + 365-376 (passes/tickets/
-- Magma Emblem/Ruby/Sapphire/Old Sea Map). (Master Ball = item 1.)
function noteItem(item)
  if item == 1 or (item >= 259 and item <= 288) or (item >= 365 and item <= 376) then
    addSpook(3)
  end
end

local function norm(s) return (s or ""):lower():gsub("[%s_]", "") end
local function resolve(tbl, s) return tonumber(s) or tbl[norm(s)] end

-- builder = { code = {bytes}, texts = {{pos, text, scroll}} }
local function newBuilder() return { code = {}, texts = {} } end
local function emit(B, ...)
  local n = select("#", ...)
  for i = 1, n do B.code[#B.code + 1] = (select(i, ...)) & 0xFF end
end

-- msgbox: lockall ; loadword 0,<textptr> ; callstd MSGBOX_DEFAULT ; releaseall
-- (text is placed in the data section during finalize and the pointer patched in)
local function emitMsgbox(B, text, scroll)
  emit(B, OP.lockall, OP.loadword, 0x00)
  local pos = #B.code + 1                 -- where the 4-byte text pointer goes
  emit(B, 0, 0, 0, 0)                     -- placeholder, patched in finalize
  emit(B, OP.callstd, MSGBOX_DEFAULT, OP.releaseall)
  B.texts[#B.texts + 1] = { pos = pos, text = text, scroll = scroll }
end

local function emitSpawn(B, species, level)
  noteLegendary(species)
  local s1, s2 = u16(species)
  emit(B, OP.setwildbattle, s1, s2, level & 0xFF, 0, 0, OP.dowildbattle)
end

-- ask: open the 15-char Walda keyboard (== the player talking to the entity).
--   special DoWaldaNamingScreen ; waitstate ; end
-- The typed text lands in gStringVar2; onFrame reads it when the screen closes -> REQUEST.
local function effectAsk()
  local sp1, sp2 = u16(SPECIAL_WALDA_NAMING)
  local blob = { OP.special, sp1, sp2, OP.waitstate, OP.end_ }
  local ok, why = runBlob(blob)
  if ok then askState = "opening" end   -- arm capture for both hotkey and `ask` command
  return ok, why
end

local function emitItem(B, item, qty) noteItem(item); local i1,i2=u16(item); local q1,q2=u16(qty); emit(B, OP.additem, i1,i2, q1,q2) end
local function emitHeal(B) local s1,s2=u16(SPECIAL_HEAL_PARTY); emit(B, OP.special, s1,s2) end
local function emitMoney(B, amt) local a,b,c,d=u32b(amt); emit(B, OP.addmoney, a,b,c,d, 0x00) end
-- warpId defaults to WARP_ID_NONE (use x/y). Pass warpId=0 to land at the map's designed
-- entrance (warp 0) and ignore x/y -- a guaranteed-walkable spot when no coords are given.
local function emitWarp(B, g, n, x, y, warpId) local x1,x2=u16(x); local y1,y2=u16(y); emit(B, OP.warp, g&0xFF, n&0xFF, warpId or WARP_ID_NONE, x1,x2, y1,y2, OP.waitstate) end
local function emitFlag(B, flag, set) local f1,f2=u16(flag); emit(B, set and OP.setflag or OP.clearflag, f1,f2) end
local function emitFanfare(B, song) local s1,s2=u16(song); emit(B, OP.playfanfare, s1,s2, OP.waitfanfare) end
-- song 0 = "silence": fade the CURRENT track out (playbgm MUS_DUMMY doesn't reliably stop it,
-- especially just after a warp when the new map is starting its own music).
local function emitBgm(B, song)
  if song == 0 then emit(B, OP.fadeoutbgm, 0x04)
  else local s1, s2 = u16(song); emit(B, OP.playbgm, s1, s2, 0x00) end
end
local function emitSound(B, se) local s1,s2=u16(se); emit(B, OP.playse, s1,s2) end
local function emitWeather(B, t) local t1,t2=u16(t); emit(B, OP.setweather, t1,t2, OP.doweather) end

-- finalize: append `end`, lay out the text data section, patch msgbox pointers, run.
local function finalizeAndRun(B)
  emit(B, OP.end_)
  for _, t in ipairs(B.texts) do
    local off = #B.code                       -- 0-based offset of this text within the blob
    local a, b, c, d = u32b(scratch + off)
    B.code[t.pos], B.code[t.pos+1], B.code[t.pos+2], B.code[t.pos+3] = a, b, c, d
    local enc = encodeText(t.text, t.scroll)
    for i = 1, #enc do B.code[#B.code + 1] = enc[i] end
  end
  return runBlob(B.code)
end

-- Verity's speech is auto-attributed in the in-game text box, using its CURRENT name (verityDisplayName,
-- defined later): "Verity: " until the player renames it at the Name Rater, then "<custom>: ".
MSGBOX_PREFIX = "Verity: "   -- fallback only (if verityDisplayName is somehow unavailable)
-- Parse ONE effect line into the builder. Returns ok, err.
local function emitCommand(B, line)
  local cmd, rest = line:match("^(%S+)%s*(.*)$"); if not cmd then return false, "empty" end
  cmd, rest = cmd:lower(), rest or ""
  if cmd == "msgbox" then
    local scroll = false
    local flag, body = rest:match("^%-(%a+)%s+(.*)$")
    if flag == "scroll" then scroll, rest = true, body elseif flag == "page" then scroll, rest = false, body end
    local who = (type(verityDisplayName) == "function" and verityDisplayName()) or MSGBOX_PREFIX:gsub(": $", "")
    emitMsgbox(B, who .. ": " .. rest, scroll); return true
  elseif cmd == "encounter" or cmd == "spawn" then     -- start a WILD BATTLE (spawn kept as alias)
    local sp, lv = rest:match("(%S+)%s+(%S+)"); sp, lv = tonumber(sp), tonumber(lv)
    if sp and lv then emitSpawn(B, sp, lv); return true end; return false, "encounter <species> <level>"
  elseif cmd == "item" or cmd == "give_item" then
    local it, q = rest:match("(%S+)%s*(%S*)"); it = tonumber(it); q = tonumber(q) or 1
    if it then emitItem(B, it, q); return true end; return false, "item <id> [qty]"
  elseif cmd == "heal" then emitHeal(B); return true
  elseif cmd == "money" then local a = tonumber(rest); if a then emitMoney(B, a); return true end; return false, "money <amount>"
  elseif cmd == "warp" then
    local first, r2 = rest:match("^(%S+)%s*(.*)$"); local m = first and MAP[norm(first)]
    if first and norm(first) == "mirageisland" then forceMirageIsland() end   -- make the island actually be there
    local g, n, x, y
    if m then
      g, n = m[1], m[2]
      x, y = (r2 or ""):match("(%-?%d+)%s+(%-?%d+)"); x, y = tonumber(x), tonumber(y)
      if not (x and y) and m[3] and m[4] then x, y = m[3], m[4] end   -- map's own default landing coords
    else g, n, x, y = rest:match("(%S+)%s+(%S+)%s*(%S*)%s*(%S*)"); g,n,x,y = tonumber(g),tonumber(n),tonumber(x),tonumber(y) end
    if g and n then
      if x and y then emitWarp(B, g, n, x, y) else emitWarp(B, g, n, 0, 0, 0) end   -- else warp 0 (entrance)
      return true
    end
    return false, "warp <town> [x y]  (town alone lands at its entrance, e.g. `warp evergrande`)"
  elseif cmd == "mirageisland" or cmd == "mirage" then   -- GIFT: summon the island, then deliver the player to it
    forceMirageIsland()                                  -- set VAR_MIRAGE_RND_H so the island renders on load
    local m = MAP["mirageisland"]
    if m[3] and m[4] then emitWarp(B, m[1], m[2], m[3], m[4])   -- Route 130 has NO warps -> must use coords
    else emitWarp(B, m[1], m[2], 0, 0, 0) end
    return true
  elseif cmd == "setflag" or cmd == "clearflag" then
    local f = resolve(BADGE, rest); if f then emitFlag(B, f, cmd == "setflag"); return true end; return false, cmd .. " <flag|badgeN>"
  elseif cmd == "fanfare" then local s = resolve(SONG, rest); if s then emitFanfare(B, s); return true end; return false, "fanfare <song|name>"
  elseif cmd == "bgm" or cmd == "song" or cmd == "music" then local s = resolve(SONG, rest); if s then emitBgm(B, s); return true end; return false, "music <song|name>"
  elseif cmd == "sound" or cmd == "se" then local s = resolve(SE, rest); if s then emitSound(B, s); return true end; return false, "sound <se|name>"
  elseif cmd == "weather" then local w = resolve(WEATHER, rest); if w then emitWeather(B, w); return true end; return false, "weather <type|name>"
  else return false, "unknown action '" .. cmd .. "' (send `help` for the full list)" end
end

local function runEffect(line)
  local B = newBuilder()
  local ok, err = emitCommand(B, line); if not ok then return false, err end
  return finalizeAndRun(B)
end

-- seq: run several effects, in order, in ONE script. Parts are separated by `|`.
local function runSeq(rest)
  local B = newBuilder()
  for part in rest:gmatch("[^|]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if #part > 0 then local ok, err = emitCommand(B, part); if not ok then return false, err end end
  end
  if #B.code == 0 then return false, "seq: no effects (use: seq a | b | c)" end
  return finalizeAndRun(B)
end

------------------------------------------------------------------------
-- Party data: gen-3 encrypted Pokemon structure (getters/setters)
-- 100-byte struct: 0x1C checksum(u16), 0x20 secure[48] (4x12 substructs, XOR-
-- encrypted per 32-bit word with key = personality ^ otId; substruct order is a
-- permutation of personality%24). Battle stats at 0x50+ are PLAINTEXT.
------------------------------------------------------------------------
local BATTLEMOVES = 0x0831C898        -- BattleMove[12 bytes each]; base PP at +4
local GSPECIES = 0x083203CC           -- SpeciesInfo[28B]: baseHP@0..baseSpDef@5, growthRate@0x13
local GEXPTAB  = 0x0831F72C           -- gExperienceTables[growthRate][level] u32 (101 per rate)
local SHEDINJA = 303                  -- HP is always 1
local GLEARNSETS = 0x0832937C         -- ptr per species -> u16[] (move=e&0x1FF, lvl=(e>>9), end 0xFFFF)
local GSPECIESNAMES = 0x083185C8      -- species name table, 11 bytes each (GBA charset)
local GSAVEBLOCK2PTR = 0x03005D90     -- ->SaveBlock2: playerName@0, gender@8, trainerId@0x0A
local createCtr = 0                   -- varies personality across createmon calls

-- Custom entity species tables + config ("Verity", a repurposed "?" placeholder slot)
local GMON_FRONT, GMON_BACK   = 0x0830A18C, 0x083028B8   -- {data*,size,tag} 8B each
local GMON_PAL, GMON_PALSHINY = 0x08303678, 0x08304438   -- {data*,tag} 8B each
local GMON_ICON, GMON_ICONPAL = 0x0857BCA8, 0x0857C388   -- ptr 4B each / u8 palIdx
local GICONPAL = 0x08DDE1F8                              -- 3 shared icon palettes, 32B (16 colors) each
-- Entity configs (ENTITY = calm Verity slot 252, ENTITY2 = creepy slot 253) are defined
-- lower down, after the sprite data + icon draw functions they reference.

-- ROM is read-only on the CPU bus (emu:write is ignored), but the cart0 memory DOMAIN
-- writes the underlying buffer and the game reads it. Use these for all ROM (0x08…) writes.
local CART0 = emu.memory and emu.memory.cart0
local function romW8(a, v)  CART0:write8(a - 0x08000000, v & 0xFF) end
local function romW16(a, v) CART0:write16(a - 0x08000000, v & 0xFFFF) end
local function romW32(a, v) CART0:write32(a - 0x08000000, v & 0xFFFFFFFF) end

-- Walk-through-walls: patch GetCollisionAtCoords to `movs r0,#0 ; bx lr` (always no collision).
local GETCOLLISION = 0x08092BC8
local NOCLIP_PATCH = 0x47702000       -- Thumb: 0x2000 (movs r0,#0) + 0x4770 (bx lr), LE
local collisionOrig = nil             -- saved original bytes for toggling off

-- Reserved EWRAM (below the script buffer at 0x0203F000) for the custom sprite data.
-- ENTITY (calm) uses 0x0203D000-0x0203DFFF; ENTITY2 (creepy) uses 0x0203E000-0x0203EFFF.
local SPR_FRONT,  SPR_BACK,  SPR_PAL,  SPR_ICON  = 0x0203D000, 0x0203D400, 0x0203D800, 0x0203DC00
local SPR2_FRONT, SPR2_BACK, SPR2_PAL, SPR2_ICON = 0x0203E000, 0x0203E400, 0x0203E800, 0x0203EC00
local LEARNSET2 = 0x0203FF00   -- tiny EWRAM buffer for a custom level-up learnset (clear of scripts at 0x0203F000)

-- base64 decoder: decode -> write bytes to an address, return count.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}; for i = 1, #B64 do B64DEC[B64:sub(i, i)] = i - 1 end
local function b64write(addr, s)
  local bits, nbits, n = 0, 0, 0
  for i = 1, #s do
    local v = B64DEC[s:sub(i, i)]
    if v then
      bits = (bits << 6) | v; nbits = nbits + 6
      if nbits >= 8 then nbits = nbits - 8; emu:write8(addr + n, (bits >> nbits) & 0xFF); n = n + 1 end
    end
  end
  return n
end

-- Smiley sprite as LZ77, base64 (generated offline; roundtrip-verified). 64x64 4bpp:
-- front = smiley face, back = yellow circle; pal = transparent/black/yellow/white.
local SPR_B64 = {
  front = "EAAIAH0A8ADwAPAA8ACwABEAAlIRAAIi0BgQETAAIW0iMACQGwEQOAAAEgAD9EAe4D8gXAAoEQAEIhL/EAnwAPAA8ADwAPAAkLZg00MQANMQISIAAKEACn8iEKkQrFDP8ADwAPAA8ACvcAASEF4S8BcwACEzQRPZEQ4ALgAAkQADEgEQO/nwyvAAgONA5xADECEQA/8RqFDf8OPwAJC4QLvwAEAA//Ac8EPwEnAYQiXxH8EfYSO/AAMSEScAAwEiIAMw5xKn//ADEAPwAODFMgUCtGALgbP/IT8QAxAZUAvxBlAzUANgz98TKTADEYAL8PDwAFBAAOf/APDwAzADIsvw9/D/8ADwAL/SthJj5vAA8ADwAPAAsF//dCbwAIEA8PeA/0LnMANiJv9TCwNH8ABTC0J+Qd1hv/Ga/4AvMiFE4yIz8zOAACBeEUb/Yj/zh/AAkE9C5xADUvtQ5P/1PPAAEHMU5xIKIisU/xUH/0En8HKw7/AA8CfwAPAA8AD3dAZCbATvEesRJQcmI/Dj//AA8ADwAPAAcR8hG6EToAD/oQ8AABb/8B9S0jAAkLMg2/4A0BAV9u3w3/AA8ACQAA==",
  back  = "EAAIAH0A8ADwAPAA8ACwABEAAlIRAAIi0BgQETAAIW0iMACQGwEQOAAAEgAD9EAe4D8gXAAoEQAEIhL/EAnwAPAA8ADwAPAAkLZg00MQANMQISIAAKEACn8iEKkQrFDP8ADwAPAA8ACvcAASEF4S8BcwACEzQRPZEQ4ALgAAkQADEgEQO/nwyvAAgONA5xADECEQA/8RqFDf8OPwAPAA8ADwAPAA/vAA8ABAAPEfwR9hIwADEv8RJwADASIgAzDnEqfwAxAD//AA8ADwAPAA8ADwAPAA8AD/8ADwALEdAOcA8PADMAMiy//w9/D/8ADwAPAA8ADwAPAA//AA8ADwAPAAQQDw94D/Quf/MANiJlMLA0fwAFML8R3wAP/wAPAA8ADwAPAA8ADwAAMX/0LnEANS+1Dk9TzwABP/FOf/EgoiKxT/FQdBJ/BycSPxH//wAPAA8ADwAIDfIGYVIxTvvxHrESUHJiPw4/AA8ADwAP/wAHEfIRuhE6AAoQ8AABb///AfVekwAJCzINsA0BAV9u3w8N/wAPAAkAA=",
  pal   = "ECAAAEMAAAD/A/9/EAfwAAAAAA==",
}
-- Creepy Verity (front = void eyes + red dot pupils + jack-o-lantern gaping mouth).
local SPR2_B64 = {
  front = "EAAIAH0A8ADwAPAA8ACwABEAAlIRAAIi0BgQETAAIW0iMACQGwEQOAAAEgAD9EAe4D8gXAAoEQAEIhL/EAnwAPAA8ADwAPAAkLZg00MQANMQISIAAKEACn8iEKkQrFDP8ADwAPAA8ACvcAASEF4S8BcwACEzQRPZEQ4ALgAAkQADEgEQO/nwyvAAgONA5xADECEQA/4RqFDf8OOgpxEMIbtwADH/YccQABA/EBAgU0AD8AAg6+8gJkADkF4hwF5QI6EfUKv3EAMRH2EjAAMSEScAAwEi/yADMOcSp/ADEAPhexBUEBFnEiDBAAAzEyCIQAAiu78ivxIw7xIfgO/yKyHfkAPvoG/AXlAAIVAlkZtAVwAG/yEsAAIQcADnAPDwAzADIsvf8PeA/xEATBCjIAORmzEF/SMDEGkgAwB8AHcQASEAC/1zxiAjIR8AIJAD0B8iABT3oAMAYkJTAFESUAMQKBDh7wBiMVRQoSEADhADIJwwWf/w95D/QucwA2ImUwsDR/AA9VFrIXsAdBCHEhFwIQEr/wCdYIwAGVDnUSAQyyADUP//sO9Q62ATABAA4wAVAGiA/79BZSHzl9NLQucQA1L7UOT/9TzwABFeFOcSCiIrFP8VB/9BJ0FpUQ5iu2AQgetxAxD3/zI54e9B3iHdICyDQ/DrQo/vIXAE7xHrESUHJiPw4/AA//AA8ADwAHEfIRuhE6AAoQ//AAAW/5AfkM9VO5CzINsA0PwQFfbt8N/wAPAAkAA=",
  back  = "EAAIAH0A8ADwAPAA8ACwABEAAlIRAAIi0BgQETAAIW0iMACQGwEQOAAAEgAD9EAe4D8gXAAoEQAEIhL/EAnwAPAA8ADwAPAAkLZg00MQANMQISIAAKEACn8iEKkQrFDP8ADwAPAA8ACvcAASEF4S8BcwACEzQRPZEQ4ALgAAkQADEgEQO/nwyvAAgONA5xADECEQA/4RqFDf8OOgpxEMIbtwADH/YccQABA/EBAgU0AD8AAg6+8gJkADkF4hwF5QI6EfUKv3EAMRH2EjAAMSEScAAwEi/yADMOcSp/ADEAPhexBUEBFnEiDBAAAzEyCIQAAiu78ivxIw7xIfgO/yKyHfkAPvoG/AXlAAIVAlkZtAVwAG/yEsAAIQcADnAPDwAzADIsvf8PeA/xEATBCjIAORmzEF/SMDEGkgAwB8AHcQASEAC/1zxiAjIR8AIJAD0B8iABT3oAMAYkJTAFESUAMQKBDh7wBiMVRQoSEADhADIJwwWf/w95D/QucwA2ImUwsDR/AA9VFrIXsAdBCHEhFwIQEr/wCdYIwAGVDnUSAQyyADUP//sO9Q62ATABAA4wAVAGiA/79BZSHzl9NLQucQA1L7UOT/9TzwABFeFOcSCiIrFP8VB/9BJ0FpUQ5iu2AQgetxAxD3/zI54e9B3iHdICyDQ/DrQo/vIXAE7xHrESUHJiPw4/AA//AA8ADwAHEfIRuhE6AAoQ//AAAW/5AfkM9VO5CzINsA0PwQFfbt8N/wAPAAkAA=",
  pal   = "ECAAAEcAAAD/Ax8QBvAAAAA=",
}
-- ORDER[personality%24][type] -> slot (0-3). type: 1=Growth 2=Attacks 3=EVs 4=Misc.
local ORDER = {
  [0]={0,1,2,3},[1]={0,1,3,2},[2]={0,2,1,3},[3]={0,3,1,2},[4]={0,2,3,1},[5]={0,3,2,1},
  [6]={1,0,2,3},[7]={1,0,3,2},[8]={2,0,1,3},[9]={3,0,1,2},[10]={2,0,3,1},[11]={3,0,2,1},
  [12]={1,2,0,3},[13]={1,3,0,2},[14]={2,1,0,3},[15]={3,1,0,2},[16]={2,3,0,1},[17]={3,2,0,1},
  [18]={1,2,3,0},[19]={1,3,2,0},[20]={2,1,3,0},[21]={3,1,2,0},[22]={2,3,1,0},[23]={3,2,1,0},
}
local T_GROWTH, T_ATTACKS, T_EVS, T_MISC = 1, 2, 3, 4

local function monBase(slot) return PARTY + slot * MON_SIZE end
local function partyCount() return r8(PARTYCOUNT) end

-- decrypt secure block -> key, D (byte table, 0-based 0..47), personality
local function decryptMon(base)
  local pid = emu:read32(base + 0x00)
  local key = (pid ~ emu:read32(base + 0x04)) & 0xFFFFFFFF
  local D = {}
  for w = 0, 11 do
    local word = (emu:read32(base + 0x20 + w * 4) ~ key) & 0xFFFFFFFF
    D[w*4], D[w*4+1], D[w*4+2], D[w*4+3] = word & 0xFF, (word>>8)&0xFF, (word>>16)&0xFF, (word>>24)&0xFF
  end
  return key, D, pid
end

local function subOff(pid, t) return ORDER[pid % 24][t] * 12 end
local function d16(D, o) return D[o] | (D[o+1] << 8) end
local function d32(D, o) return D[o] | (D[o+1] << 8) | (D[o+2] << 16) | (D[o+3] << 24) end
local function setd16(D, o, v) D[o], D[o+1] = v & 0xFF, (v >> 8) & 0xFF end

-- recompute checksum (u16 sum of decrypted block), then re-encrypt and write back
local function encryptMon(base, key, D)
  local sum = 0
  for i = 0, 23 do sum = sum + (D[i*2] | (D[i*2+1] << 8)) end
  emu:write16(base + 0x1C, sum & 0xFFFF)
  for w = 0, 11 do
    local word = D[w*4] | (D[w*4+1]<<8) | (D[w*4+2]<<16) | (D[w*4+3]<<24)
    emu:write32(base + 0x20 + w*4, (word ~ key) & 0xFFFFFFFF)
  end
end

local function readMon(slot)
  local base = monBase(slot)
  local key, D, pid = decryptMon(base)
  local g, a, e, m = subOff(pid,T_GROWTH), subOff(pid,T_ATTACKS), subOff(pid,T_EVS), subOff(pid,T_MISC)
  local iv = d32(D, m+4)
  return {
    species = d16(D,g), item = d16(D,g+2), exp = d32(D,g+4), ppBonuses = D[g+8], friendship = D[g+9],
    moves = { d16(D,a), d16(D,a+2), d16(D,a+4), d16(D,a+6) },
    pp    = { D[a+8], D[a+9], D[a+10], D[a+11] },
    evs   = { D[e], D[e+1], D[e+2], D[e+3], D[e+4], D[e+5] },
    ivs   = { iv&0x1F, (iv>>5)&0x1F, (iv>>10)&0x1F, (iv>>15)&0x1F, (iv>>20)&0x1F, (iv>>25)&0x1F },
    nature = pid % 25,
    level = r8(base+0x54), hp = emu:read16(base+0x56), maxhp = emu:read16(base+0x58),
    stats = { emu:read16(base+0x5A), emu:read16(base+0x5C), emu:read16(base+0x5E), emu:read16(base+0x60), emu:read16(base+0x62) },
    status = emu:read32(base+0x50),
  }
end

local function monToJson(slot, m)
  return string.format(
    '{"slot":%d,"species":%d,"level":%d,"hp":%d,"maxHp":%d,"item":%d,"friendship":%d,"nature":%d,'
    .. '"moves":[%d,%d,%d,%d],"pp":[%d,%d,%d,%d],"ivs":[%d,%d,%d,%d,%d,%d],"evs":[%d,%d,%d,%d,%d,%d],'
    .. '"stats":[%d,%d,%d,%d,%d],"status":%d}',
    slot, m.species, m.level, m.hp, m.maxhp, m.item, m.friendship, m.nature,
    m.moves[1],m.moves[2],m.moves[3],m.moves[4], m.pp[1],m.pp[2],m.pp[3],m.pp[4],
    m.ivs[1],m.ivs[2],m.ivs[3],m.ivs[4],m.ivs[5],m.ivs[6],
    m.evs[1],m.evs[2],m.evs[3],m.evs[4],m.evs[5],m.evs[6],
    m.stats[1],m.stats[2],m.stats[3],m.stats[4],m.stats[5], m.status)
end

-- Setters that DON'T change stats (safe: no recalculation needed).
local function setMove(slot, idx, move)
  if idx < 0 or idx > 3 then return false, "move idx 0-3" end
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local a = subOff(pid, T_ATTACKS)
  setd16(D, a + idx*2, move)
  D[a + 8 + idx] = emu:read8(BATTLEMOVES + move * 12 + 4) & 0xFF  -- reset PP to the move's max
  encryptMon(base, key, D); return true
end
local function setItem(slot, item)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  setd16(D, subOff(pid, T_GROWTH) + 2, item); encryptMon(base, key, D); return true
end
local function setFriendship(slot, val)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  D[subOff(pid, T_GROWTH) + 9] = val & 0xFF; encryptMon(base, key, D); return true
end
-- Plaintext party fields (no encryption).
local function setHP(slot, hp) emu:write16(monBase(slot) + 0x56, hp & 0xFFFF); return true end
local function setStatus(slot, st) emu:write32(monBase(slot) + 0x50, st & 0xFFFFFFFF); return true end

-- ---- stat recalculation (gen-3 formula) --------------------------------------
local function baseStat(species, i) return emu:read8(GSPECIES + species * 0x1C + i) end  -- i: 0=HP..5=SpDef
local function growthRate(species) return emu:read8(GSPECIES + species * 0x1C + 0x13) end
local function expAt(species, level) return emu:read32(GEXPTAB + (growthRate(species) * 101 + level) * 4) end

-- Recompute the PLAINTEXT battle stats (0x54..0x63) from the decrypted mon + level.
-- stat order after HP: [ATK, DEF, SPEED, SPATK, SPDEF] (matches storage/EV/IV order).
local function recalcStats(base, D, pid, level)
  local g, e, m = subOff(pid,T_GROWTH), subOff(pid,T_EVS), subOff(pid,T_MISC)
  local species = d16(D, g)
  local iv = d32(D, m + 4)
  local ivs = { iv&0x1F, (iv>>5)&0x1F, (iv>>10)&0x1F, (iv>>15)&0x1F, (iv>>20)&0x1F, (iv>>25)&0x1F }
  local evs = { D[e], D[e+1], D[e+2], D[e+3], D[e+4], D[e+5] }

  local hp
  if species == SHEDINJA then hp = 1
  else hp = ((2*baseStat(species,0) + ivs[1] + (evs[1]//4)) * level)//100 + level + 10 end

  local nature = pid % 25
  local up, down = nature // 5, nature % 5          -- indices into [ATK,DEF,SPEED,SPATK,SPDEF]
  local st = {}
  for k = 1, 5 do
    local v = ((2*baseStat(species,k) + ivs[k+1] + (evs[k+1]//4)) * level)//100 + 5
    if up ~= down then
      if (k-1) == up then v = (v*110)//100 elseif (k-1) == down then v = (v*90)//100 end
    end
    st[k] = v
  end

  emu:write8(base + 0x54, level & 0xFF)
  emu:write16(base + 0x58, hp & 0xFFFF)             -- maxHP
  emu:write16(base + 0x56, hp & 0xFFFF)             -- current HP = full
  emu:write16(base + 0x5A, st[1] & 0xFFFF)          -- attack
  emu:write16(base + 0x5C, st[2] & 0xFFFF)          -- defense
  emu:write16(base + 0x5E, st[3] & 0xFFFF)          -- speed
  emu:write16(base + 0x60, st[4] & 0xFFFF)          -- spAttack
  emu:write16(base + 0x62, st[5] & 0xFFFF)          -- spDefense
end

-- Setters that change stats: modify data, sync exp, recompute, re-encrypt.
local function setSpecies(slot, species)
  if VERITY_SPECIES[readMon(slot).species] and not VERITY_SPECIES[species] then
    return false, "slot " .. slot .. " is Verity and cannot be overwritten"
  end
  noteLegendary(species)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local g, level = subOff(pid, T_GROWTH), r8(base + 0x54)
  setd16(D, g, species)
  local exp = expAt(species, level)                 -- keep exp consistent with new growth curve
  D[g+4],D[g+5],D[g+6],D[g+7] = exp&0xFF,(exp>>8)&0xFF,(exp>>16)&0xFF,(exp>>24)&0xFF
  recalcStats(base, D, pid, level); encryptMon(base, key, D); return true
end

local function setLevel(slot, level)
  if level < 1 or level > 100 then return false, "level 1-100" end
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local g = subOff(pid, T_GROWTH)
  local exp = expAt(d16(D, g), level)
  D[g+4],D[g+5],D[g+6],D[g+7] = exp&0xFF,(exp>>8)&0xFF,(exp>>16)&0xFF,(exp>>24)&0xFF
  recalcStats(base, D, pid, level); encryptMon(base, key, D); return true
end

local function setIV(slot, idx, val)                 -- idx 0..5 [hp,atk,def,spd,spatk,spdef]
  if idx < 0 or idx > 5 or val < 0 or val > 31 then return false, "iv idx 0-5 val 0-31" end
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local m = subOff(pid, T_MISC)
  local iv = (d32(D, m+4) & ~(0x1F << (idx*5))) | ((val & 0x1F) << (idx*5))
  D[m+4],D[m+5],D[m+6],D[m+7] = iv&0xFF,(iv>>8)&0xFF,(iv>>16)&0xFF,(iv>>24)&0xFF
  recalcStats(base, D, pid, r8(base+0x54)); encryptMon(base, key, D); return true
end

local function setEV(slot, idx, val)                 -- idx 0..5
  if idx < 0 or idx > 5 or val < 0 or val > 255 then return false, "ev idx 0-5 val 0-255" end
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  D[subOff(pid, T_EVS) + idx] = val & 0xFF
  recalcStats(base, D, pid, r8(base+0x54)); encryptMon(base, key, D); return true
end

-- ---- level-up learnset (auto moveset) ----------------------------------------
-- Returns up to 4 moves a freshly-generated mon of this species would know at
-- `level` (the last 4 learned, in order) -- matches the game's initial moveset.
local function levelUpMoves(species, level)
  local ptr = emu:read32(GLEARNSETS + species * 4)
  local moves = {}
  if ptr < 0x08000000 or ptr >= 0x0A000000 then return moves end
  local i = 0
  while i < 400 do
    local e = emu:read16(ptr + i * 2)
    if e == 0xFFFF then break end
    if ((e & 0xFE00) >> 9) <= level then
      moves[#moves + 1] = e & 0x1FF
      if #moves > 4 then table.remove(moves, 1) end   -- FIFO, keep last 4
    end
    i = i + 1
  end
  return moves
end

-- write 4 move slots (and PP) into a decrypted mon from a move-id list (pad with 0)
local function writeMoveset(D, pid, mv)
  local a = subOff(pid, T_ATTACKS)
  for idx = 0, 3 do
    local m = mv[idx + 1] or 0
    setd16(D, a + idx * 2, m)
    D[a + 8 + idx] = (m ~= 0) and (emu:read8(BATTLEMOVES + m * 12 + 4) & 0xFF) or 0
  end
  D[subOff(pid, T_GROWTH) + 8] = 0                     -- reset ppBonuses
end

-- populate the current species+level's level-up moveset into a party slot
local function setMoveset(slot)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local mv = levelUpMoves(d16(D, subOff(pid, T_GROWTH)), r8(base + 0x54))
  writeMoveset(D, pid, mv); encryptMon(base, key, D); return true
end

-- one-shot "conjure": transform an EXISTING party slot into species@level with
-- correct stats, synced exp, and the level-appropriate moveset. (Does not create
-- a mon in an empty slot -- that needs full personality/otId init; see spawn.)
local function giveMon(slot, species, level)
  if level < 1 or level > 100 then return false, "level 1-100" end
  if VERITY_SPECIES[readMon(slot).species] and not VERITY_SPECIES[species] then
    return false, "slot " .. slot .. " is Verity and cannot be overwritten"
  end
  noteLegendary(species)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  local g = subOff(pid, T_GROWTH)
  setd16(D, g, species)
  local exp = expAt(species, level)
  D[g+4],D[g+5],D[g+6],D[g+7] = exp&0xFF,(exp>>8)&0xFF,(exp>>16)&0xFF,(exp>>24)&0xFF
  writeMoveset(D, pid, levelUpMoves(species, level))
  recalcStats(base, D, pid, level); encryptMon(base, key, D); return true
end

-- Pick a PID that is SHINY for `otId` (so (otHi^otLo^pidHi^pidLo) < 8), honoring `nature` (%25) if given.
-- A fresh mon has full PID freedom, so this is a short bounded search with a deterministic guaranteed fallback.
local function shinyPidFresh(seed, otId, nature)
  local C = ((otId >> 16) & 0xFFFF) ~ (otId & 0xFFFF)
  for d = 0, 0xFFFF do
    local lo = (seed + d) & 0xFFFF
    local p  = (((lo ~ C) << 16) | lo) & 0xFFFFFFFF        -- hi = lo^C -> the two halves XOR to 0 -> shiny
    if (not nature) or (p % 25 == (nature % 25)) then return p end
  end
  local lo = seed & 0xFFFF
  return (((lo ~ C) << 16) | lo) & 0xFFFFFFFF              -- guaranteed-shiny fallback (ignores nature)
end

-- Build a brand-new valid mon in the next FREE party slot (from nothing).
-- otId = the player's trainer id so the mon obeys; IVs default to 31. shiny=true -> a shiny PID.
local function createMon(species, level, nature, shiny)
  if species < 1 or species > 411 then return false, "species 1-411" end
  if level < 1 or level > 100 then return false, "level 1-100" end
  noteLegendary(species)
  local slot = partyCount()
  if slot >= 6 then return false, "party full" end
  local base = monBase(slot)

  local sb2 = emu:read32(GSAVEBLOCK2PTR)
  if sb2 < 0x02000000 or sb2 >= 0x02040000 then return false, "no saveblock2" end
  local otId = emu:read8(sb2+0x0A) | (emu:read8(sb2+0x0B)<<8) | (emu:read8(sb2+0x0C)<<16) | (emu:read8(sb2+0x0D)<<24)
  local otGender = emu:read8(sb2 + 0x08) & 1

  createCtr = createCtr + 1
  local pers = (0x41C64E6D * createCtr + 0x3039 + otId) & 0xFFFFFFFF
  if nature then pers = (pers - (pers % 25) + (nature % 25)) & 0xFFFFFFFF end
  if shiny then pers = shinyPidFresh(pers, otId, nature) end
  local key = (pers ~ otId) & 0xFFFFFFFF

  local D = {}; for i = 0, 47 do D[i] = 0 end
  local g, mi = subOff(pers, T_GROWTH), subOff(pers, T_MISC)
  setd16(D, g, species)
  local exp = expAt(species, level)
  D[g+4],D[g+5],D[g+6],D[g+7] = exp&0xFF,(exp>>8)&0xFF,(exp>>16)&0xFF,(exp>>24)&0xFF
  D[g+9] = emu:read8(GSPECIES + species*0x1C + 0x12)            -- base friendship
  writeMoveset(D, pers, levelUpMoves(species, level))          -- Attacks (EVs stay 0)
  local ivword = (0x3FFFFFFF & ~(1 << 31)) | ((pers & 1) << 31) -- all IVs 31; abilityNum from personality
  D[mi+4],D[mi+5],D[mi+6],D[mi+7] = ivword&0xFF,(ivword>>8)&0xFF,(ivword>>16)&0xFF,(ivword>>24)&0xFF
  setd16(D, mi+2, (level & 0x7F) | (3 << 7) | (4 << 11) | (otGender << 15)) -- origins: metLvl/Emerald/PokeBall/gender

  emu:write32(base+0x00, pers)
  emu:write32(base+0x04, otId)
  for k = 0, 9 do emu:write8(base+0x08+k, emu:read8(GSPECIESNAMES + species*11 + k)) end  -- nickname = species name
  emu:write8(base+0x12, 2)                                     -- language: English
  emu:write8(base+0x13, 0x02)                                  -- flags: hasSpecies
  for k = 0, 6 do emu:write8(base+0x14+k, emu:read8(sb2 + k)) end  -- otName = player name
  emu:write8(base+0x1B, 0)                                     -- markings
  emu:write16(base+0x1E, 0)                                    -- unused (clear leftover in a reused slot)

  recalcStats(base, D, pers, level)                           -- plaintext stats + level + full HP
  emu:write32(base+0x50, 0)                                    -- status
  emu:write8(base+0x55, 0xFF)                                  -- mail = none (clear leftover)
  encryptMon(base, key, D)                                     -- checksum + encrypt secure block
  emu:write8(PARTYCOUNT, slot + 1)                             -- grow the party
  return true
end

-- Make an existing party mon SHINY without changing its OT id (so it stays obedient). Gen-3 shininess is
-- derived: shiny iff (otHi ^ otLo ^ pidHi ^ pidLo) < 8, so we only need to change the PID. Two tiers:
--  1) bounded search for a PID that KEEPS pid%24 (so the already-decrypted substruct bytes stay valid as-is)
--     AND preserves nature/ability/gender AND is shiny -- no reorder, no stat change;
--  2) deterministic O(1) fallback (reuse the low half, hi = lo ^ otXor -> halves XOR to 0 -> always shiny),
--     which keeps gender+ability but changes nature+permutation, so we physically reorder the 4 substructs
--     into the new permutation and recompute stats. Tier 2 can never fail or loop -> reliable and bounded.
function makeShiny(slot)
  local se = slotErr(slot); if se then return false, se end
  local base = monBase(slot)
  local key, D, pid = decryptMon(base)
  local ot = emu:read32(base + 0x04)
  local otXor = ((ot >> 16) & 0xFFFF) ~ (ot & 0xFFFF)
  local pidHi, pidLo = (pid >> 16) & 0xFFFF, pid & 0xFFFF
  if (otXor ~ pidHi ~ pidLo) < 8 then return true end          -- already shiny -> no-op
  local old24, oldNat, oldAbil = pid % 24, pid % 25, pid & 1
  local species = d16(D, subOff(pid, T_GROWTH))
  local ratio = emu:read8(GSPECIES + species * 0x1C + 0x10)    -- gender ratio (0/254/255 = fixed/genderless)
  local fixedGender = (ratio == 0 or ratio == 254 or ratio == 255)
  local oldFemale = (pidLo & 0xFF) < ratio
  -- Tier 1: bounded (<=120k), preserve perm + nature + ability + gender, shiny
  local newpid, tries = nil, 0
  for j = 0, 7 do
    for lo = 0, 0xFFFF do
      if (lo & 1) == oldAbil and (fixedGender or (((lo & 0xFF) < ratio) == oldFemale)) then
        local p = ((((lo ~ otXor ~ j) & 0xFFFF) << 16) | lo) & 0xFFFFFFFF
        if p % 24 == old24 and p % 25 == oldNat then newpid = p; break end
      end
      tries = tries + 1; if tries >= 120000 then break end
    end
    if newpid or tries >= 120000 then break end
  end
  if newpid then                                               -- same permutation -> D stays valid, just re-key
    emu:write32(base + 0x00, newpid)
    encryptMon(base, (newpid ~ ot) & 0xFFFFFFFF, D)
    return true
  end
  -- Tier 2 (guaranteed): deterministic shiny PID, reorder the substructs into the new permutation, recalc stats
  newpid = ((((pidLo ~ otXor) & 0xFFFF) << 16) | pidLo) & 0xFFFFFFFF
  local newD = {}; for i = 0, 47 do newD[i] = 0 end
  for t = T_GROWTH, T_MISC do
    local src, dst = ORDER[old24][t] * 12, ORDER[newpid % 24][t] * 12
    for b = 0, 11 do newD[dst + b] = D[src + b] end
  end
  emu:write32(base + 0x00, newpid)
  recalcStats(base, newD, newpid, r8(base + 0x54))             -- nature changed -> recompute plaintext stats
  encryptMon(base, (newpid ~ ot) & 0xFFFFFFFF, newD)
  return true
end

-- ---- custom entity species (runtime ROM patch of a "?" placeholder slot) -------
-- Overwrite the placeholder's species DATA (name/stats/types/learnset). ROM writes.
local function patchEntityData(e)
  local S = e.slot
  local nb, ci = GSPECIESNAMES + S * 11, 0
  for i = 1, #e.name do
    local g = CHARMAP[e.name:byte(i)]; if g then romW8(nb + ci, g); ci = ci + 1 end
  end
  romW8(nb + ci, 0xFF)                                   -- name terminator
  local si = GSPECIES + S * 0x1C
  for i = 1, 6 do romW8(si + (i - 1), e.base[i]) end     -- base stats
  romW8(si + 6, e.type1); romW8(si + 7, e.type2)         -- types (??? = 9)
  romW8(si + 8, e.catchRate); romW8(si + 9, e.expYield)
  romW8(si + 0x12, e.friendship); romW8(si + 0x13, e.growthRate)
  romW8(si + 0x16, e.ability); romW8(si + 0x17, e.ability)
  if e.moves and e.learnbuf then                          -- custom learnset in EWRAM: all moves at Lv1
    for i, mv in ipairs(e.moves) do emu:write16(e.learnbuf + (i - 1) * 2, (1 << 9) | (mv & 0x1FF)) end
    emu:write16(e.learnbuf + #e.moves * 2, 0xFFFF)        -- LEVEL_UP_END
    romW32(GLEARNSETS + S * 4, e.learnbuf)                -- point the species' learnset at our buffer
  else
    romW32(GLEARNSETS + S * 4, emu:read32(GLEARNSETS + e.donor * 4))  -- borrow the donor's learnset
  end
end

-- Step-2 checkpoint: repoint sprite/palette/icon to the donor mon (validate repointing
-- before injecting the custom smiley). Copies the pointer-table entries donor -> slot.
local function patchEntitySpriteDonor(e)
  local S, D = e.slot, e.donor
  for _, t in ipairs({ GMON_FRONT, GMON_BACK, GMON_PAL, GMON_PALSHINY }) do
    for k = 0, 7 do romW8(t + S * 8 + k, emu:read8(t + D * 8 + k)) end
  end
  romW32(GMON_ICON + S * 4, emu:read32(GMON_ICON + D * 4))
  romW8(GMON_ICONPAL + S, emu:read8(GMON_ICONPAL + D))
end

-- Stage the custom sprite in EWRAM and repoint the entity's front/back/palette to it.
-- (Runs after patchEntitySpriteDonor, which supplied valid tags.)
local function patchEntitySpriteCustom(e)
  local S = e.slot
  b64write(e.spr.front, e.b64.front)
  b64write(e.spr.back,  e.b64.back)
  b64write(e.spr.pal,   e.b64.pal)
  romW32(GMON_FRONT + S * 8, e.spr.front); romW16(GMON_FRONT + S * 8 + 4, 0x800)
  romW32(GMON_BACK  + S * 8, e.spr.back);  romW16(GMON_BACK  + S * 8 + 4, 0x800)
  romW32(GMON_PAL      + S * 8, e.spr.pal)
  romW32(GMON_PALSHINY + S * 8, e.spr.pal)
end

-- Party ICON: icons share one of 3 palettes, so we borrow Pikachu's (yellow) palette and
-- draw the smiley using its nearest yellow/black slots -- non-destructive to other mons.
local function iconPaletteFor()
  local P = emu:read8(GMON_ICONPAL + 25)          -- Pikachu (species 25) icon palette index
  local base = GICONPAL + P * 32
  local ys, bs, ybest, bbest = 2, 1, -999, -999
  for s = 1, 15 do                                 -- skip slot 0 (transparent)
    local c = emu:read16(base + s * 2)
    local r, g, b = c & 0x1F, (c >> 5) & 0x1F, (c >> 10) & 0x1F
    if r + g - 2 * b > ybest then ybest = r + g - 2 * b; ys = s end   -- most yellow
    if -(r + g + b) > bbest then bbest = -(r + g + b); bs = s end     -- darkest
  end
  return P, ys, bs
end

local function iconPxHappy(x, y, ys, bs)          -- 32x32 smiley pixel -> palette slot
  local ex1, ey1, ex2, ey2 = x - 11, y - 13, x - 21, y - 13
  if ex1*ex1 + ey1*ey1 <= 5 or ex2*ex2 + ey2*ey2 <= 5 then return bs end   -- eyes
  local mx, my = x - 16, y - 18
  local m2 = mx*mx + my*my
  if m2 >= 36 and m2 <= 64 and my > 1 then return bs end                    -- smile arc
  local dx, dy = x - 16, y - 16
  if dx*dx + dy*dy <= 14*14 then return ys end                             -- face
  return 0
end

local function iconPxCreepy(x, y, ys, bs)         -- void eyes + jack-o-lantern gaping mouth
  local ex1, ey1, ex2, ey2 = x - 10, y - 12, x - 22, y - 12
  if ex1*ex1 + ey1*ey1 <= 7 or ex2*ex2 + ey2*ey2 <= 7 then return bs end          -- big black eyes
  local t = (x - 16) / 13                                                          -- big wide crescent grin
  local yt, yb = 19 - 3*t*t, 33 - 17*t*t                                           -- top/bottom lips meet at corners
  if x >= 3 and x <= 29 and y >= yt and y <= yb then return (x % 3 == 0) and ys or bs end  -- black mouth + yellow teeth
  local dx, dy = x - 16, y - 16
  if dx*dx + dy*dy <= 14*14 then return ys end
  return 0
end

local function patchEntityIcon(e)
  local P, ys, bs = iconPaletteFor()
  local px, idx = e.iconpx, 0                       -- 32x32 = 4x4 tiles, row-major, 4bpp
  for ty = 0, 3 do for tx = 0, 3 do for py = 0, 7 do
    local y = ty * 8 + py
    for pxx = 0, 7, 2 do
      local x = tx * 8 + pxx
      local b0 = ((px(x+1, y,   ys, bs) & 0xF) << 4) | (px(x, y,   ys, bs) & 0xF)
      local b1 = ((px(x+1, y-1, ys, bs) & 0xF) << 4) | (px(x, y-1, ys, bs) & 0xF)
      emu:write8(e.spr.icon + idx, b0)             -- frame 0
      emu:write8(e.spr.icon + 0x200 + idx, b1)     -- frame 1 = content 1px down -> idle bounce
      idx = idx + 1
    end
  end end end
  romW32(GMON_ICON + e.slot * 4, e.spr.icon)
  romW8(GMON_ICONPAL + e.slot, P)
end

-- Front-sprite anim fix: the summary/battle front sprite plays an affine animation chosen by
-- sMonFrontAnimIdsTable[species-1] (both it and sMonAnimationDelayTable are u8[NUM_SPECIES-1], indexed
-- species-1). Unused "?" slots hold a GARBAGE id there, so the game runs an out-of-range affine that
-- scales the sprite to nothing for ~1s (the "blink"). The table's address isn't stable to hardcode, so
-- scan for it by an EXACT byte signature: its first 24 entries are the real anim ids of species 1-24
-- (Bulbasaur..Arbok), resolved from src/pokemon.c + include/pokemon_animation.h. (The old zero/nonzero
-- fingerprint was too loose and matched a decoy table.) Then write ANIM_V_SQUISH_AND_BOUNCE (0) -- the
-- gentle stretch/squish the player wants -- at our slot in both tables.
-- sMonFrontAnimIdsTable[0..23] = anim ids of Bulbasaur..Arbok:
local FRONT_SIG = { 6,23,47,82,37,16,11,19,25,11,11,29,70,32,2,71,23,41,67,43,24,43,22,23 }
local ANIM_DELAY_SIG = { 0x32,0,0,0,0x0A,0x14,0x23,0,0x19,0,0,0,0,0x02,0x1E }  -- delayTbl[8..22]
local ANIM_DELAY_SIG_OFF = 8
local sAnimIdsTbl, sAnimDelayTbl, sAnimTriedLocate = nil, nil, false

local function locateAnimTables()
  if sAnimTriedLocate then return sAnimIdsTbl ~= nil end
  sAnimTriedLocate = true
  if not CART0 then return false end
  local fs, fl = FRONT_SIG, #FRONT_SIG
  local sig, slen = ANIM_DELAY_SIG, #ANIM_DELAY_SIG
  for o = 0x00100000, 0x00400000 do                       -- cart0 offsets (ROM 0x0810.. - 0x0840..); wide net
    local b0 = CART0:read8(o)
    if not sAnimIdsTbl and b0 == fs[1] then               -- exact-match sMonFrontAnimIdsTable[0..23]
      local hit = true
      for k = 2, fl do if CART0:read8(o + k - 1) ~= fs[k] then hit = false; break end end
      if hit then sAnimIdsTbl = o + 0x08000000 end         -- base = species 1 (table indexed species-1)
    end
    if not sAnimDelayTbl and b0 == sig[1] then            -- exact-match the delay table
      local hit = true
      for k = 2, slen do if CART0:read8(o + k - 1) ~= sig[k] then hit = false; break end end
      if hit then sAnimDelayTbl = (o - ANIM_DELAY_SIG_OFF) + 0x08000000 end
    end
    if sAnimIdsTbl and sAnimDelayTbl then break end
  end
  if console then
    console:log(("anim tables: ids=%s delay=%s"):format(
      sAnimIdsTbl and ("0x%08X"):format(sAnimIdsTbl) or "NOT-FOUND",
      sAnimDelayTbl and ("0x%08X"):format(sAnimDelayTbl) or "NOT-FOUND"))
  end
  return sAnimIdsTbl ~= nil
end

local function patchEntityAnim(e)
  locateAnimTables()
  local i = e.slot - 1                                    -- both tables are indexed species-1
  if sAnimIdsTbl   then romW8(sAnimIdsTbl + i, 0) end     -- ANIM_V_SQUISH_AND_BOUNCE: gentle stretch/squish
  if sAnimDelayTbl then romW8(sAnimDelayTbl + i, 0) end   -- no entrance delay
end

-- Entity configs (defined here, after the sprite data + icon draw fns they reference).
local ENTITY = {                                   -- calm Verity
  slot = 252, donor = 94, name = "VERITY", type1 = 9, type2 = 9,
  base = { 70, 80, 70, 80, 90, 80 }, catchRate = 45, expYield = 180, growthRate = 4,
  friendship = 70, ability = 0,
  spr = { front = SPR_FRONT, back = SPR_BACK, pal = SPR_PAL, icon = SPR_ICON },
  b64 = SPR_B64, iconpx = iconPxHappy,
}
local ENTITY2 = {                                  -- creepier Verity (escalation + the showdown boss)
  slot = 253, donor = 94, name = "VERITY", type1 = 9, type2 = 9,
  -- maxed base stats + a devastating, high-accuracy coverage moveset: at Lv100 this OHKOs almost
  -- anything and out-speeds a hacked team. Near-unwinnable, but a lucky/prepared player can still win.
  base = { 255, 255, 255, 255, 255, 255 }, catchRate = 0, expYield = 200, growthRate = 4,
  friendship = 0, ability = 23,           -- SHADOW_TAG: the player CANNOT run or switch -> only win or lose
  moves = { 89, 58, 85, 126 },            -- EARTHQUAKE, ICE BEAM, THUNDERBOLT, FIRE BLAST
  learnbuf = LEARNSET2,                    -- custom learnset lives here (so the wild boss knows these)
  spr = { front = SPR2_FRONT, back = SPR2_BACK, pal = SPR2_PAL, icon = SPR2_ICON },
  b64 = SPR2_B64, iconpx = iconPxCreepy,
}
local ENTITIES = { ENTITY, ENTITY2 }

local function patchEntity()
  for _, e in ipairs(ENTITIES) do
    patchEntityData(e)
    patchEntitySpriteDonor(e)   -- valid tags (sprite/icon overwritten below)
    patchEntitySpriteCustom(e)  -- front/back/palette pixels = custom sprite
    patchEntityIcon(e)          -- party-menu icon
    patchEntityAnim(e)          -- valid front-sprite anim id (stop the summary-screen "blink")
  end
  return true
end

-- Loading a savestate reverts our ROM-table pointers AND the EWRAM sprite bytes, so Verity would
-- render as a glitch until the Lua is reloaded. Cheaply verify the patch is intact each frame:
-- the front-pic ROM pointer must still point at our EWRAM buffer, and that buffer must still start
-- with the LZ77 header (0x00080010 = magic 0x10 + uncompressed size 0x800). If either is gone, the
-- state was reloaded (or ROM/EWRAM was clobbered) -> re-apply the whole patch.
function verityIntact()
  for _, e in ipairs(ENTITIES) do
    if emu:read32(GMON_FRONT + e.slot * 8) ~= e.spr.front then return false end
    if emu:read32(e.spr.front) ~= 0x00080010 then return false end
  end
  return true
end

------------------------------------------------------------------------
-- Socket server (mGBA sockettest pattern)
------------------------------------------------------------------------
local sockets, server, rxbuf, nextId = {}, nil, {}, 1
local function sendTo(id, s) local k = sockets[id]; if k then k:send(s .. "\n") end end
local function broadcast(s) for _, k in pairs(sockets) do k:send(s .. "\n") end end
local handleCommand

local function stop(id)
  local k = sockets[id]; if not k then return end
  sockets[id], rxbuf[id] = nil, nil; k:close()
  console:log("[entity] client " .. id .. " disconnected")
end

local function onReceive(id)
  local k = sockets[id]; if not k then return end
  while true do
    local data, err = k:receive(1024)
    if data and #data > 0 then
      rxbuf[id] = (rxbuf[id] or "") .. data
      while true do
        local line, rest = rxbuf[id]:match("([^\n]*)\n(.*)")
        if not line then break end
        rxbuf[id] = rest; handleCommand(id, (line:gsub("\r", "")))
      end
    else
      if err and err ~= socket.ERRORS.AGAIN then console:error("[entity] " .. tostring(err)); stop(id) end
      return
    end
  end
end

local function onAccept()
  local k, err = server:accept()
  if not k then if err then console:error("[entity] accept: " .. tostring(err)) end return end
  local id = nextId; nextId = nextId + 1
  sockets[id] = k
  k:add("received", function() onReceive(id) end)
  k:add("error", function(e) console:error("[entity] " .. tostring(e)); stop(id) end)
  console:log("[entity] client " .. id .. " connected")
  sendTo(id, "hello entity-bridge v3")
end

------------------------------------------------------------------------
-- World-state readout (for the agent to VERIFY the result of its actions)
------------------------------------------------------------------------
function sb1() return emu:read32(SAVEBLOCK1_PTR) end
function readMoney()
  local s1, s2 = sb1(), emu:read32(GSAVEBLOCK2PTR)
  if s1 < 0x02000000 or s2 < 0x02000000 then return -1 end
  return (emu:read32(s1 + 0x490) ~ emu:read32(s2 + 0xAC)) & 0xFFFFFFFF   -- money ^ encryptionKey
end
function badgeMask()                                   -- bit i set => badge (i+1) earned
  local s1 = sb1(); if s1 < 0x02000000 then return 0 end
  local flags, mask = s1 + 0x1270, 0                         -- SaveBlock1.flags[]; FLAG_BADGE01_GET=0x867
  for i = 0, 7 do
    local f = 0x867 + i
    if (emu:read8(flags + (f >> 3)) & (1 << (f & 7))) ~= 0 then mask = mask | (1 << i) end
  end
  return mask
end
function playerName()                       -- decoded in-game trainer name (SaveBlock2 + 0)
  local s2 = emu:read32(GSAVEBLOCK2PTR)
  if s2 < 0x02000000 then return "" end
  return decodeStr(s2, 7)                          -- PLAYER_NAME_LENGTH = 7
end
function curMap()                            -- current map group,num from SaveBlock1.location
  local s1 = sb1()
  if s1 < 0x02000000 then return -1, -1 end
  return emu:read8(s1 + 0x04), emu:read8(s1 + 0x05)
end
function hasKeyItem(id)                       -- is item `id` in the KEY ITEMS pocket? (ids are plaintext)
  local s1 = sb1()                            -- SaveBlock1.bagPocket_KeyItems @ 0x5D8, 30 slots x 4 bytes
  if s1 < 0x02000000 then return false end
  for i = 0, 29 do if emu:read16(s1 + 0x5D8 + i * 4) == id then return true end end
  return false
end
function s16(v) return v >= 0x8000 and v - 0x10000 or v end
function locationFrag()
  local s1 = sb1()
  if s1 < 0x02000000 then return '"map":[-1,-1],"pos":[0,0],"weather":-1' end
  return string.format('"map":[%d,%d],"pos":[%d,%d],"weather":%d',
    emu:read8(s1 + 0x04), emu:read8(s1 + 0x05),               -- location.mapGroup, mapNum (WarpData@0x04)
    s16(emu:read16(s1 + 0x00)), s16(emu:read16(s1 + 0x02)),   -- pos.x, pos.y (Coords16@0x00)
    emu:read8(s1 + 0x2E))                                     -- weather
end
function partyBrief()
  local n, parts = partyCount(), {}
  for s = 0, n - 1 do
    local m = readMon(s)
    parts[#parts + 1] = string.format('{"slot":%d,"species":%d,"level":%d,"hp":%d,"maxHp":%d}',
      s, m.species, m.level, m.hp, m.maxhp)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- Ensure the entity itself is in the party (idempotent). If the party is full, OVERWRITE the last
-- slot with Verity (part of the spook). Level defaults to the party's max (>=5). Returns ok, err.
function partyHasVerity()
  for s = 0, partyCount() - 1 do
    local sp = readMon(s).species
    if sp == ENTITY.slot or sp == ENTITY2.slot then return s end
  end
  return nil
end
-- ---- Spook = Verity's LEVEL (persistent) -------------------------------------------------------
-- Verity may live in the party (level is the plaintext byte @ base+0x54) or the PC box (BoxPokemon has
-- NO level field -> level is derived from EXP + growth rate). These read/write it wherever it is.
local GPOKEMONSTORAGE = 0x03005D94     -- gPokemonStoragePtr (adjacent to gSaveBlock1/2 ptrs)
local BOXMON = 80                      -- sizeof BoxPokemon; boxes[] start at storage+4; 14*30 = 420 slots
local verityBoxCache = nil             -- cached box-mon base of a boxed Verity (revalidated cheaply)

local function boxBase(i) return emu:read32(GPOKEMONSTORAGE) + 4 + i * BOXMON end
local function speciesAtBase(base) local _, D, pid = decryptMon(base); return d16(D, subOff(pid, T_GROWTH)) end
local function expToLevel(species, exp)                  -- inverse of expAt(): highest level whose exp <= exp
  for lv = 1, 100 do if expAt(species, lv) > exp then return lv - 1 end end
  return 100
end
local function setBoxLevel(base, lvl)                    -- no level byte in a box mon -> set its EXP
  local key, D, pid = decryptMon(base); local g = subOff(pid, T_GROWTH)
  local exp = expAt(d16(D, g), lvl)
  D[g+4],D[g+5],D[g+6],D[g+7] = exp&0xFF,(exp>>8)&0xFF,(exp>>16)&0xFF,(exp>>24)&0xFF
  encryptMon(base, key, D)
end
local function setSpeciesAtBase(base, species)           -- change only the species id (box turn 252->253)
  local key, D, pid = decryptMon(base); setd16(D, subOff(pid, T_GROWTH), species); encryptMon(base, key, D)
end
function findVerityBox()               -- box-mon base holding Verity, or nil (cached; revalidate cheap)
  if emu:read32(GPOKEMONSTORAGE) < 0x02000000 then return nil end
  if verityBoxCache and VERITY_SPECIES[speciesAtBase(verityBoxCache)] then return verityBoxCache end
  for i = 0, 419 do
    if VERITY_SPECIES[speciesAtBase(boxBase(i))] then verityBoxCache = boxBase(i); return verityBoxCache end
  end
  verityBoxCache = nil; return nil
end

-- CUSTOM NAME: if the player renames Verity at the Name Rater, the new nickname (plaintext @ base+0x08,
-- 10 bytes, 0xFF-terminated) drives both the in-game speech prefix and the LLM prompt. We read it live
-- (no event hook needed). createMon seeds the nickname = species name "VERITY", so we treat that exact
-- value as "unrenamed" and keep the nicer "Verity" casing until the player actually changes it.
DEFAULT_VERITY_NICK = "VERITY"
function verityNick()                    -- Verity's current nickname (party or box), decoded; nil if absent
  local s = partyHasVerity(); if s then return decodeStr(monBase(s) + 0x08, 10) end
  local base = findVerityBox(); if base then return decodeStr(base + 0x08, 10) end
  return nil
end
function verityDisplayName()             -- what to call it: "Verity" until the player renames it
  local nk = verityNick()
  if not nk or nk == "" or nk == DEFAULT_VERITY_NICK then return "Verity" end
  return nk
end

-- FRIENDSHIP MODE (launch option): when on, Verity never escalates -- spook is pinned at 0 and all score
-- writes are no-ops, so the calm persona, no haunts, no turn-to-creepy, and no finale all follow for free
-- (every consumer reads through getSpook). enforceFriend() also keeps Verity the calm (252) Lv1 companion.
friendMode = false

function getSpook()                    -- = Verity's level (0 if Verity is nowhere); forced 0 in friendship mode
  if friendMode then return 0 end
  local s = partyHasVerity()
  if s then return readMon(s).level end
  local base = findVerityBox()
  if base then local _, D, pid = decryptMon(base); return expToLevel(d16(D, subOff(pid,T_GROWTH)), d32(D, subOff(pid,T_GROWTH)+4)) end
  return 0
end
function addSpook(n)                   -- raise Verity's level by n (capped 100); ignored in friendship mode
  if friendMode then return end
  local s = partyHasVerity()
  if s then setLevel(s, math.min(100, readMon(s).level + n)); return end
  local base = findVerityBox()
  if base then setBoxLevel(base, math.min(100, getSpook() + n)) end
end
function setSpook(n)                   -- set Verity's level to n (1..100); ignored in friendship mode
  if friendMode then return end
  n = n < 1 and 1 or (n > 100 and 100 or n)
  local s = partyHasVerity()
  if s then setLevel(s, n); return end
  local base = findVerityBox()
  if base then setBoxLevel(base, n) end
end
-- Keep Verity calm (252) and at Lv1 while friendship mode is on: reverts the creepy form and undoes any
-- natural leveling, whether Verity is in the party or the PC box. (setLevel/setSpecies bypass the no-ops.)
function enforceFriend()
  local s = partyHasVerity()
  if s then
    if readMon(s).species == ENTITY2.slot then setSpecies(s, ENTITY.slot) end   -- creepy -> calm
    if readMon(s).level > 1 then setLevel(s, 1) end                             -- undo any level gain
    return
  end
  local base = findVerityBox()
  if base then
    if speciesAtBase(base) == ENTITY2.slot then setSpeciesAtBase(base, ENTITY.slot) end
    setBoxLevel(base, 1)
  end
end

-- Deterministic spook input checked periodically: newly-hacked badges (+1 each -> Verity levels up).
function spookScan()
  local bm = badgeMask()
  if spookBadges == nil then
    spookBadges = bm
  elseif bm ~= spookBadges then
    local newbits, c = bm & ~spookBadges, 0
    for i = 0, 7 do if (newbits & (1 << i)) ~= 0 then c = c + 1 end end
    if c > 0 then addSpook(c) end
    spookBadges = bm
  end
end

-- At 'malevolent' (spook >= 30), Verity drops its friendly face: swap calm Verity (252) -> creepy (253),
-- WHEREVER it is (party or box). Idempotent; retries until a Verity is present to turn.
verityTurned = false
function maybeTurnVerity()
  if verityTurned or getSpook() < 30 then return end
  local s = partyHasVerity()
  if s then
    if readMon(s).species == ENTITY.slot then setSpecies(s, ENTITY2.slot) end   -- guard allows Verity->Verity
    verityTurned = true; return
  end
  local base = findVerityBox()
  if base then
    if speciesAtBase(base) == ENTITY.slot then setSpeciesAtBase(base, ENTITY2.slot) end
    verityTurned = true
  end
end

function summonVerity(level)
  if partyHasVerity() ~= nil then return true end          -- already here
  level = level or 1                                       -- spook = Verity's level, so it STARTS at calm (1)
  local n = partyCount()
  if n < 6 then return createMon(ENTITY.slot, level) end    -- free slot: add Verity
  return giveMon(5, ENTITY.slot, level)                      -- party full: overwrite the last mon
end

-- Authoritative action catalog: THE list of game_command verbs (single source the agent reads
-- via `help`, so it always knows every possible action and its arg shape). Names resolve to IDs.
local COMMANDS = {
  { "msgbox",        "[-scroll|-page] <text>",     "speak to the player in a text box" },
  { "encounter",     "<species> <level>",          "start a WILD BATTLE vs this species (a fight; does NOT add it to the party, and it leaves the overworld)" },
  { "item",          "<item> [qty]",               "add an item to the bag" },
  { "heal",          "",                           "fully heal the party" },
  { "money",         "<amount>",                   "add money" },
  { "warp",          "<town> [x y]",               "warp the player to a town (coords optional; town alone lands at its entrance)" },
  { "mirageisland",  "",                           "GIFT: summon the hidden Mirage Island and send the player there -- grant ONLY when they ASK for it (they need Surf to reach it). A gift, never a wrongwarp." },
  { "setflag",       "<flag|badgeN>",              "set a story flag / award a badge (badge1..badge8)" },
  { "clearflag",     "<flag|badgeN>",              "clear a flag" },
  { "fanfare",       "<song>",                     "play a short one-shot jingle" },
  { "bgm",           "<song>",                     "set looping background music (aka music/song; `bgm off` = dead silence)" },
  { "detour",        "<destination>",              "eerie double-warp: drag the player through a grim place, then on to <destination>" },
  { "wrongwarp",     "",                           "malevolent: strand the player somewhere grim (random; NOT where they asked)" },
  { "sound",         "<se>",                       "play a sound effect (aka se)" },
  { "weather",       "<type>",                     "set weather: rain, fog, thunderstorm, sandstorm, overcast..." },
  { "seq",           "<a> | <b> | <c>",            "chain WORLD effects in one script (msgbox/encounter/item/weather/music/warp/flag). NOT for party edits (givemon/createmon/set*) -- send those as separate calls" },
  { "ask",           "",                           "open the in-game keyboard for the player to type" },
  { "noclip",        "on|off",                     "let the player walk through walls" },
  { "party",         "",                           "list all party mons (brief)" },
  { "mon",           "<slot>",                     "full details of one party mon (0-5)" },
  { "setmove",       "<slot> <idx0-3> <move>",     "set a move in a slot (PP refills to max)" },
  { "setitem",       "<slot> <item>",              "give a party mon a held item" },
  { "setfriendship", "<slot> <0-255>",             "set friendship" },
  { "sethp",         "<slot> <hp>",                "set current HP" },
  { "setstatus",     "<slot> <status>",            "set status condition (0=none)" },
  { "setspecies",    "<slot> <species>",           "change a slot's species (stats recalc)" },
  { "setlevel",      "<slot> <1-100>",             "set a slot's level (stats + exp recalc)" },
  { "setiv",         "<slot> <idx0-5> <0-31>",     "set an IV; idx: hp,atk,def,spd,spatk,spdef" },
  { "setev",         "<slot> <idx0-5> <0-255>",    "set an EV; same idx order as setiv" },
  { "setmoveset",    "<slot>",                     "fill the level-up moveset for the slot's species+level" },
  { "disobey",       "<slot>",                     "make a party mon an outsider so it disobeys the player without enough badges" },
  { "qmon",          "",                           "add a corrupted '?' glitch Pokemon to the party" },
  { "givemon",       "<slot> <species> <level>",   "ADD a mon to the party by overwriting an existing slot (0-5) -- use this to make the player stronger" },
  { "createmon",     "<species> <level> [nature] [shiny]", "ADD a NEW mon to the first free party slot -- use this to give the player a Pokemon (append `shiny` for a shiny one)" },
  { "shiny",         "<slot>",                     "GIFT: make the party mon in <slot> SHINY (it stays obedient). Grant when the player asks." },
}
function commandsJson()
  local parts = {}
  for _, c in ipairs(COMMANDS) do
    parts[#parts + 1] = string.format('["%s","%s","%s"]', c[1], c[2], c[3])
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

------------------------------------------------------------------------
-- Command dispatch (agent sends high-level verbs; bridge assembles bytecode)
------------------------------------------------------------------------
local function reply(id, ok, why) sendTo(id, ok and "RESULT ok" or ("ERR " .. (why or "?"))) end
-- Instructive slot check: distinguishes "slot out of range" from a plain usage error.
function slotErr(s)
  if s == nil then return nil end                        -- not a number -> let the usage string fire
  local n = partyCount()
  if n == 0 then return "party is empty" end
  if s < 0 or s >= n then return string.format("no mon in slot %d (party has %d: slots 0-%d)", s, n, n - 1) end
  return nil
end

handleCommand = function(id, line)
  local cmd, rest = line:match("^(%S+)%s*(.*)$"); if not cmd then return end
  cmd = cmd:lower()

  if cmd == "ask" then                -- open the 15-char keyboard (same as the L+R hotkey)
    reply(id, effectAsk())

  elseif cmd == "seq" then            -- chain effects in one script: seq a | b | c
    reply(id, runSeq(rest))

  elseif cmd == "raw" then            -- debug: run raw bytecode
    local blob = {}
    for h in rest:gmatch("%x%x") do blob[#blob + 1] = tonumber(h, 16) end
    if #blob > 0 then reply(id, runBlob(blob)) else sendTo(id, "ERR raw <hexpairs>") end

  elseif cmd == "scratch" then
    local a = tonumber(rest)
    if a then scratch = a; sendTo(id, string.format("OK scratch 0x%08X", a)) else sendTo(id, "ERR scratch <addr>") end

  elseif cmd == "state" then          -- rich world state, so the agent can verify its actions
    sendTo(id, string.format(              -- NB: spook level is deliberately NOT exposed here (agent must not see/set it)
      'STATE {"player":"%s","verity":"%s","inField":%s,"scriptStatus":%d,"askState":"%s","lastRequest":"%s",'
      .. '"money":%d,"badges":%d,"finale":"%s","friend":%s,%s,"party":%s}',
      playerName(), verityDisplayName(), tostring(inField()), emu:read8(STATUS), askState, lastRequest,
      readMoney(), badgeMask(), finaleState, tostring(friendMode), locationFrag(), partyBrief()))

  elseif cmd == "help" then           -- authoritative list of every game_command action
    sendTo(id, "HELP " .. commandsJson())

  elseif cmd == "spook" then          -- escalation score: `spook` reads, `spook add N` / `spook set N`
    local op, val = rest:match("^(%a*)%s*(-?%d*)"); val = tonumber(val)
    if op == "add" and val then addSpook(val)
    elseif op == "set" and val then setSpook(val) end
    sendTo(id, string.format("SPOOK %d", getSpook()))

  elseif cmd == "friendship" or cmd == "friend" or cmd == "friendmode" then   -- launch-option lock; `on`/`off`/read
    local arg = rest:match("^(%S*)"):lower()
    if arg == "on" or arg == "yes" or arg == "1" or arg == "true" then
      friendMode = true; enforceFriend()      -- revert to the calm Lv1 companion right now
      sendTo(id, "RESULT ok friendship on (Verity locked calm, spook 0)")
    elseif arg == "off" or arg == "no" or arg == "0" or arg == "false" then
      friendMode = false
      sendTo(id, "RESULT ok friendship off (escalation resumes)")
    else
      sendTo(id, string.format("RESULT ok friendship is %s", friendMode and "on" or "off"))
    end

  elseif cmd == "ping" then
    sendTo(id, "pong")

  elseif cmd == "unstick" then        -- recover a wedged script context (frozen player, no text box) w/o a savestate
    emu:write8(STATUS, CONTEXT_SHUTDOWN)        -- clear the stuck "running" status
    scriptQueue = {}; lastBusyTick = 0          -- drop anything queued behind it; allow an immediate relaunch
    runBlob({ OP.releaseall, OP.end_ })         -- tear down a dangling lockall -> player can move again
    sendTo(id, "RESULT ok unstick")

  elseif cmd == "corrupt" then        -- TEST the finale save-corruption in isolation (harness-only; reboot to see it)
    local ok = corruptSave()
    sendTo(id, ok and "RESULT ok save scribbled (reboot to see the corrupt screen)" or "ERR corruptSave failed -- see mGBA console")

  elseif cmd == "pcname" then         -- a client tells the bridge the player's real OS name (for the finale narration)
    pcName = rest:gsub("^%s+", ""):gsub("%s+$", "")
    sendTo(id, "RESULT ok pcname=" .. (pcName ~= "" and pcName or "(cleared)"))

  elseif cmd == "romtest" then        -- GATE: is the ROM writable at runtime?
    local a = GSPECIESNAMES + ENTITY.slot * 11
    local orig = emu:read8(a); local test = orig ~ 0xFF
    emu:write8(a, test); local rb = emu:read8(a); emu:write8(a, orig)   -- write, read back, restore
    sendTo(id, string.format("ROMTEST 0x%08X orig=%d wrote=%d readback=%d writable=%s",
      a, orig, test, rb, tostring(rb == test)))

  elseif cmd == "romtest2" then       -- GATE (attempt 2): direct memory-domain write to ROM
    local dom = emu.memory and emu.memory.cart0
    if not dom then sendTo(id, "ROMTEST2 no cart0 domain")
    else
      local off = (GSPECIESNAMES + ENTITY.slot * 11) - 0x08000000
      local orig = dom:read8(off); local test = (orig ~ 0xFF) & 0xFF
      dom:write8(off, test)
      local drb = dom:read8(off)                 -- did the domain buffer change?
      local brb = emu:read8(0x08000000 + off)    -- does the CPU bus (what the GAME reads) see it?
      dom:write8(off, orig)                        -- restore
      sendTo(id, string.format("ROMTEST2 off=0x%06X orig=%d wrote=%d dom=%d bus=%d writable=%s",
        off, orig, test, drb, brb, tostring(drb == test and brb == test)))
    end

  elseif cmd == "patchentity" then    -- apply species data + donor sprite to the entity slot
    reply(id, patchEntity())

  elseif cmd == "summonverity" then   -- ensure Verity is in the party (overwrites last slot if full)
    reply(id, summonVerity(tonumber(rest)))

  elseif cmd == "noclip" then         -- walk through walls (patch/restore GetCollisionAtCoords)
    if not CART0 then sendTo(id, "ERR no cart0 domain")
    elseif rest == "on" then
      if not collisionOrig then collisionOrig = emu:read32(GETCOLLISION) end
      romW32(GETCOLLISION, NOCLIP_PATCH); sendTo(id, "OK noclip on")
    elseif rest == "off" then
      if collisionOrig then romW32(GETCOLLISION, collisionOrig) end
      sendTo(id, "OK noclip off")
    else sendTo(id, "ERR noclip on|off") end

  elseif cmd == "party" then          -- getter: dump all party mons
    local n = partyCount()
    if n == 0 then sendTo(id, "MON none")
    else for s = 0, n - 1 do sendTo(id, "MON " .. monToJson(s, readMon(s))) end end

  elseif cmd == "mon" then            -- getter: one mon
    local s = tonumber(rest)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s then sendTo(id, "MON " .. monToJson(s, readMon(s)))
    else sendTo(id, "ERR mon <slot>  (which party slot, 0-5)") end

  elseif cmd == "setmove" then
    local s, i, mv = rest:match("(%S+)%s+(%S+)%s+(%S+)"); s,i,mv = tonumber(s),tonumber(i),tonumber(mv)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and i and mv then reply(id, setMove(s, i, mv)) else sendTo(id, "ERR setmove <slot> <idx0-3> <move>") end

  elseif cmd == "setitem" then
    local s, it = rest:match("(%S+)%s+(%S+)"); s,it = tonumber(s),tonumber(it)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and it then reply(id, setItem(s, it)) else sendTo(id, "ERR setitem <slot> <item>") end

  elseif cmd == "setfriendship" then
    local s, v = rest:match("(%S+)%s+(%S+)"); s,v = tonumber(s),tonumber(v)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and v then reply(id, setFriendship(s, v)) else sendTo(id, "ERR setfriendship <slot> <0-255>") end

  elseif cmd == "sethp" then
    local s, hp = rest:match("(%S+)%s+(%S+)"); s,hp = tonumber(s),tonumber(hp)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and hp then reply(id, setHP(s, hp)) else sendTo(id, "ERR sethp <slot> <hp>") end

  elseif cmd == "setstatus" then
    local s, st = rest:match("(%S+)%s+(%S+)"); s,st = tonumber(s),tonumber(st)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and st then reply(id, setStatus(s, st)) else sendTo(id, "ERR setstatus <slot> <status>") end

  elseif cmd == "setspecies" then
    local s, sp = rest:match("(%S+)%s+(%S+)"); s,sp = tonumber(s),tonumber(sp)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and sp then reply(id, setSpecies(s, sp)) else sendTo(id, "ERR setspecies <slot> <species>") end

  elseif cmd == "setlevel" then
    local s, lv = rest:match("(%S+)%s+(%S+)"); s,lv = tonumber(s),tonumber(lv)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and VERITY_SPECIES[readMon(s).species] then sendTo(id, "ERR slot " .. s .. " is Verity (its level is beyond you)")
    elseif s and lv then reply(id, setLevel(s, lv)) else sendTo(id, "ERR setlevel <slot> <1-100>") end

  elseif cmd == "setiv" then
    local s, i, v = rest:match("(%S+)%s+(%S+)%s+(%S+)"); s,i,v = tonumber(s),tonumber(i),tonumber(v)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and i and v then reply(id, setIV(s, i, v)) else sendTo(id, "ERR setiv <slot> <idx0-5> <0-31>") end

  elseif cmd == "setev" then
    local s, i, v = rest:match("(%S+)%s+(%S+)%s+(%S+)"); s,i,v = tonumber(s),tonumber(i),tonumber(v)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and i and v then reply(id, setEV(s, i, v)) else sendTo(id, "ERR setev <slot> <idx0-5> <0-255>") end

  elseif cmd == "setmoveset" then     -- fill slot with the level-up moveset for its species+level
    local s = tonumber(rest)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s then reply(id, setMoveset(s)) else sendTo(id, "ERR setmoveset <slot>") end

  elseif cmd == "givemon" then        -- transform a slot: species + level + stats + moveset
    local s, sp, lv = rest:match("(%S+)%s+(%S+)%s+(%S+)"); s,sp,lv = tonumber(s),tonumber(sp),tonumber(lv)
    local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and sp and lv then reply(id, giveMon(s, sp, lv)) else sendTo(id, "ERR givemon <slot> <species> <level>") end

  elseif cmd == "createmon" then      -- build a NEW mon in the next free slot: species level [nature] [shiny]
    local shiny, parts = false, {}
    for w in rest:gmatch("%S+") do
      if w:lower() == "shiny" then shiny = true else parts[#parts + 1] = w end
    end
    local sp, lv, nat = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
    if sp and lv then reply(id, createMon(sp, lv, nat, shiny)) else sendTo(id, "ERR createmon <species> <level> [nature] [shiny]") end

  elseif cmd == "shiny" then          -- make an existing party mon shiny (keeps its OT -> stays obedient)
    local s = tonumber(rest)
    if s then reply(id, makeShiny(s)) else sendTo(id, "ERR shiny <slot>") end

  elseif cmd == "disobey" then        -- make a specific party mon disobey (outsider OT id)
    local s = tonumber(rest); local se = slotErr(s)
    if se then sendTo(id, "ERR " .. se)
    elseif s and VERITY_SPECIES[readMon(s).species] then sendTo(id, "ERR slot " .. s .. " is Verity")
    elseif s then reply(id, hauntDisobey(s))
    else sendTo(id, "ERR disobey <slot>") end

  elseif cmd == "qmon" then           -- add a "?" glitch mon to the party
    reply(id, hauntQmon())

  elseif cmd == "haskeyitem" then     -- does the player hold this key item? -> YES / NO
    local it = tonumber(rest)
    if it then sendTo(id, hasKeyItem(it) and "YES" or "NO") else sendTo(id, "ERR haskeyitem <item>") end

  elseif cmd == "haunt" then          -- fire a haunt (harness/RNG-driven, not for the LLM)
    local kind = (rest:match("^(%S+)") or ""):lower()
    local fn = HAUNTS[kind]
    if fn then reply(id, fn())
    else sendTo(id, "ERR haunt <sound|music|silence|levels|friendship|disobey|badge|replace|qmon>") end

  elseif cmd == "detour" then         -- eerie double-warp: through a grim place, then on to <dest>
    local first, r2 = rest:match("^(%S+)%s*(.*)$")
    local m = first and MAP[norm(first)]
    if not m then sendTo(id, "ERR detour <destination> (unknown map '" .. tostring(first) .. "')")
    else
      detourG, detourN = m[1], m[2]                -- resolve NOW so the continue-warp can't strand them
      local x, y = (r2 or ""):match("(%-?%d+)%s+(%-?%d+)"); detourX, detourY = tonumber(x), tonumber(y)
      if not (detourX and detourY) and m[3] and m[4] then detourX, detourY = m[3], m[4] end
      detourState = "go"; sendTo(id, "RESULT ok detour -> " .. first)
    end

  elseif cmd == "wrongwarp" then      -- malevolent: dump the player somewhere grim (random; no delivery)
    reply(id, runEffect("warp " .. GRIM[math.random(#GRIM)]))

  elseif cmd == "showdown" then       -- begin/RESTART the endgame cinematic (harness-only; not for the LLM)
    local was = finaleState
    finaleWeak = (rest:match("^%s*(%S*)"):lower() == "weak")   -- `showdown weak` = beatable boss, to test the WIN path
    finaleState = "intro"; finaleSawBattle = false     -- force-(re)start even from a stuck/"done" state
    sendTo(id, "RESULT ok showdown begun (was " .. was .. (finaleWeak and ", WEAK test boss" or "") .. ")")

  else                                -- any effect verb (msgbox/spawn/item/heal/warp/...)
    reply(id, runEffect(line))        -- emitCommand returns a proper error if it's unknown
  end
end

-- ---- Haunts -----------------------------------------------------------------
-- Fired by the agent HARNESS (RNG), not the LLM. Split: eerie = non-destructive/unsettling;
-- malevolent = destructive. randomVictim() never touches Verity (protected slots).
local SE_STANDALONE = { 90, 39, 45, 46, 87, 88, 107, 178, 89, 103, 73, 106 }  -- strong enough alone
local SE_MINOR      = { 43, 8, 18, 77, 117, 180, 20, 41, 98 }                 -- pair with a delayed 2nd
local CREEPY_SPECIES = { 378, 377, 361, 362, 322, 303, 94 }  -- Banette/Shuppet/Duskull/Dusclops/Sableye/Shedinja/Gengar

function randomVictim()                            -- a random non-Verity party slot, or nil
  local pool = {}
  for s = 0, partyCount() - 1 do
    if not VERITY_SPECIES[readMon(s).species] then pool[#pool + 1] = s end
  end
  return (#pool > 0) and pool[math.random(#pool)] or nil
end
-- eerie (non-destructive)
-- Append an audible sound effect to a builder: a standalone one, or a minor stinger + a beat + a real one.
function audioAppendSE(B)
  if math.random() < 0.5 then
    local a1, a2 = u16(SE_STANDALONE[math.random(#SE_STANDALONE)]); emit(B, OP.playse, a1, a2)
  else
    local a1, a2 = u16(SE_MINOR[math.random(#SE_MINOR)])
    local b1, b2 = u16(SE_STANDALONE[math.random(#SE_STANDALONE)])
    emit(B, OP.playse, a1, a2, OP.delay, 30, 0, OP.playse, b1, b2)
  end
end
-- One balanced audio haunt: song / silence / sound-effect in equal thirds, and a song or silence
-- MAY stack a sound effect on top after a short beat. (Keeps silence from dominating.)
function hauntAudio()
  local B, base = newBuilder(), ({ "song", "silence", "sound" })[math.random(3)]
  if base == "sound" then
    audioAppendSE(B)
  else
    if base == "song" then
      local s1, s2 = u16(({ 432, 386, 438, 443, 423 })[math.random(5)]); emit(B, OP.playbgm, s1, s2, 0x00)
    else
      emit(B, OP.fadeoutbgm, 0x04)                 -- silence
    end
    if math.random() < 0.5 then emit(B, OP.delay, 20, 0); audioAppendSE(B) end   -- stack an SE
  end
  return finalizeAndRun(B)
end
function hauntSound()   local B = newBuilder(); audioAppendSE(B); return finalizeAndRun(B) end
function hauntMusic()   return runEffect("bgm " .. ({ 432, 386, 438, 443, 423 })[math.random(5)]) end
function hauntSilence() return runEffect("bgm 0") end
function hauntWeather() return runEffect("weather " .. ({ "fog", "thunderstorm", "overcast", "ash", "sandstorm" })[math.random(5)]) end
local HAUNT_TOWNS = { "littleroot", "oldale", "petalburg", "rustboro", "dewford", "slateport",
                      "mauville", "verdanturf", "fallarbor", "lavaridge", "fortree", "lilycove",
                      "mossdeep", "sootopolis", "pacifidlog", "evergrande" }
function hauntRandomWarp() return runEffect("warp " .. HAUNT_TOWNS[math.random(#HAUNT_TOWNS)]) end
-- malevolent (destructive)
function hauntLevels()
  local hit, amt = false, math.random(3, 8)
  for s = 0, partyCount() - 1 do
    local m = readMon(s)
    if not VERITY_SPECIES[m.species] then setLevel(s, math.max(1, m.level - amt)); hit = true end
  end
  return hit
end
function hauntFriendship()
  local hit = false
  for s = 0, partyCount() - 1 do
    if not VERITY_SPECIES[readMon(s).species] then setFriendship(s, 0); hit = true end
  end
  return hit
end
function hauntBadge()                              -- strip a random earned badge (lowers obedience cap)
  local s1 = sb1(); if s1 < 0x02000000 then return false end
  local flags, set = s1 + 0x1270, {}
  for i = 0, 7 do local f = 0x867 + i
    if (emu:read8(flags + (f >> 3)) & (1 << (f & 7))) ~= 0 then set[#set + 1] = f end end
  if #set == 0 then return false end
  local f = set[math.random(#set)]; local a = flags + (f >> 3)
  emu:write8(a, emu:read8(a) & (~(1 << (f & 7)) & 0xFF))
  return true
end
function hauntDisobey(slot)                         -- make a mon an "outsider" (wrong OT id -> disobeys)
  local s = slot or randomVictim(); if not s then return false end
  local base = monBase(s); local key, D, pid = decryptMon(base)
  local newOt = (emu:read32(base + 4) ~ 0x5A5A5A5A) & 0xFFFFFFFF
  emu:write32(base + 4, newOt); encryptMon(base, (pid ~ newOt) & 0xFFFFFFFF, D)  -- re-encrypt w/ new key
  return true
end
function hauntReplace()                            -- swap a party member for something wrong
  local s = randomVictim(); if not s then return false end
  return giveMon(s, CREEPY_SPECIES[math.random(#CREEPY_SPECIES)], readMon(s).level)
end
function rawSpecies(slot, species)                 -- change ONLY the species id (glitch look; keeps stats/moves)
  local base = monBase(slot); local key, D, pid = decryptMon(base)
  setd16(D, subOff(pid, T_GROWTH), species); encryptMon(base, key, D)
end
function hauntQmon()                               -- add a "?" placeholder mon (safe: valid mon, glitched id)
  if partyCount() >= 6 then return false end
  if not createMon(1, math.random(5, 20)) then return false end
  rawSpecies(partyCount() - 1, 254 + math.random(0, 22))   -- unused "?" slots 254..276 (never 252/253)
  return true
end
HAUNTS = { audio = hauntAudio, sound = hauntSound, music = hauntMusic, silence = hauntSilence,
                 weather = hauntWeather, randomwarp = hauntRandomWarp,
                 levels = hauntLevels, friendship = hauntFriendship, disobey = hauntDisobey,
                 badge = hauntBadge, replace = hauntReplace, qmon = hauntQmon }

-- Remove a party slot: shift the mons after it up one, clear the freed tail, drop the count.
function removeMon(slot)
  local n = partyCount()
  if slot < 0 or slot >= n then return end
  for s = slot, n - 2 do
    local dst, src = monBase(s), monBase(s + 1)
    for b = 0, MON_SIZE - 1 do emu:write8(dst + b, emu:read8(src + b)) end
  end
  local last = monBase(n - 1)
  for b = 0, MON_SIZE - 1 do emu:write8(last + b, 0) end
  emu:write8(PARTYCOUNT, n - 1)
end
-- Take Verity out of the party (for the showdown). Skips if it's the only mon (can't fight empty).
function removeVerityFromParty()
  if partyCount() <= 1 then return false end
  for s = 0, partyCount() - 1 do
    local sp = readMon(s).species
    if sp == ENTITY.slot or sp == ENTITY2.slot then removeMon(s); return true end
  end
  return false
end

-- You can't cage it: empty every Master Ball slot in the bag (a Master Ball ignores catch rate and
-- would auto-catch the boss). Ball IDs are plaintext in the Poke Balls pocket (SB1 + 0x650, 16 slots).
function removeMasterBalls()                         -- returns how many slots it emptied (0 = none held)
  local s1 = sb1(); if s1 < 0x02000000 then return 0 end
  local base = s1 + 0x650
  local removed = 0
  for i = 0, 15 do
    if emu:read16(base + i * 4) == 1 then          -- ITEM_MASTER_BALL
      emu:write16(base + i * 4, 0); emu:write16(base + i * 4 + 2, 0)   -- id NONE + qty 0
      removed = removed + 1
    end
  end
  return removed
end

-- Force Mirage Island (Route 130) to appear. The game draws it only when VAR_MIRAGE_RND_H -- the daily
-- random -- equals the low 16 bits of a party mon's personality (IsMirageIslandPresent, time_events.c).
-- Vars live at SaveBlock1 + 0x139C (u16[], VARS_START 0x4000); VAR_MIRAGE_RND_H = 0x4024 -> +0x139C+0x48
-- = +0x13E4 (its pair _L = 0x4025 -> +0x13E6). We set the var to match the lead, so the next Route 130
-- load shows the island. Non-invasive: a save VAR only, no mon/ROM edits. (Player still needs Surf to reach it.)
function forceMirageIsland()
  local s1 = sb1(); if s1 < 0x02000000 or partyCount() < 1 then return false end
  local lo = emu:read32(monBase(0) + 0x00) & 0xFFFF   -- lead's personality, low 16 bits
  emu:write16(s1 + 0x13E4, lo)                         -- VAR_MIRAGE_RND_H (the half the check compares)
  emu:write16(s1 + 0x13E6, lo)                         -- VAR_MIRAGE_RND_L (keep the pair consistent)
  return true
end

-- The boss CANNOT be a real level 255: `setwildbattle` rebuilds the mon through CreateMon, which reads
-- gExperienceTables[growthRate][level]. That table only defines levels 0-100, so a 255 request indexes
-- out of bounds, reads garbage EXP, and the level collapses to something random and low (~60 in testing).
-- So we spawn a VALID level-100 enemy, then overwrite its stored level byte + battle-stat block (0x54..0x63
-- in gEnemyParty[0]) directly -- it DISPLAYS "Lv255" with crushing stats while the engine never indexes out
-- of bounds. Split across two scripts: CreateScriptedWildMon runs on `setwildbattle`, so we patch the enemy
-- AFTER that and BEFORE `dowildbattle` copies it into gBattleMons for the fight.
local ENEMYPARTY = PARTY + 600         -- gEnemyParty (6 player slots * 100 bytes past gPlayerParty)

function armBoss()                     -- setwildbattle only: build a clean, valid enemy in gEnemyParty[0]
  noteLegendary(253)
  local s1, s2 = u16(253)
  local lvl = finaleWeak and 5 or 100  -- weak test boss = Lv5 (beatable), normal = Lv100 (then buffed)
  runBlob({ OP.setwildbattle, s1, s2, lvl, 0, 0, OP.end_ })
end
function buffBoss()                    -- disguise the enemy as Lv255 with monstrous stats (a display lie)
  local e = ENEMYPARTY
  emu:write8 (e + 0x54, 255)           -- level (u8) -> reads "Lv255" on the health box
  emu:write16(e + 0x58, 0xFFFF)        -- maxHP (65535)
  emu:write16(e + 0x56, 0xFFFF)        -- current HP (full)
  emu:write16(e + 0x5A, 9999)          -- attack  (one-shots)
  emu:write16(e + 0x5C, 9999)          -- defense
  emu:write16(e + 0x5E, 9999)          -- speed   (always moves first)
  emu:write16(e + 0x60, 9999)          -- spAttack
  emu:write16(e + 0x62, 9999)          -- spDefense
end
function startBossBattle()             -- dowildbattle: begin the fight with the already-patched gEnemyParty[0]
  runBlob({ OP.dowildbattle, OP.end_ })
end

-- Eerie double-warp: warp to Mt. Pyre, let the player see it for ~1s, then warp on to <dest>.
-- (One script can't chain two warps -- the game keeps only the last -- so we do it across frames.)
function detourStep()
  if detourState == "idle" then return end
  local idle = inField() and scriptIdle() and settled()   -- settled(): space warps from a script still ending
  if detourState == "go" then
    if idle then runEffect("warp " .. GRIM[math.random(#GRIM)]); detourTick = 0; detourState = "hold" end
  elseif detourState == "hold" then
    if idle then                                   -- on the grim map now; linger ~1s, then continue
      detourTick = detourTick + 1
      if detourTick >= 60 then
        local B = newBuilder()                     -- warp to the pre-resolved destination (can't fail)
        if detourX and detourY then emitWarp(B, detourG, detourN, detourX, detourY)
        else emitWarp(B, detourG, detourN, 0, 0, 0) end
        finalizeAndRun(B)
        detourState = "idle"
      end
    end
  end
end

-- A plain narration box (no "Verity:" prefix) -- used for the closing line.
function runNarration(text)
  local B = newBuilder(); emitMsgbox(B, text, false); return finalizeAndRun(B)
end

-- Scribble garbage across the whole 128KB flash save so BOTH save slots' sector checksums fail --
-- on the next boot the game reports the save as corrupt and there is no valid backup to fall back on.
-- (Deliberate creepypasta finale on the player's own save; they keep savestates.)
-- Emerald's save is 128KB FLASH, not SRAM: raw writes bounce off (that's why the memory-domain write was a
-- no-op). Flash is programmed by a command sequence on the bus, and a program can only clear bits (1->0), so
-- writing 0x00 is always valid. We zero each 4KB sector's FOOTER (id @+0xFF4, checksum @+0xFF6, signature
-- @+0xFF8 = 0x08012025, counter @+0xFFC) across BOTH 64KB banks -> every sector fails validation -> both save
-- slots are invalid -> "the save file is corrupted" on the next boot, no backup to fall back to.
function corruptSave()
  local FLASH = 0x0E000000
  local function cmd(a, v) emu:write8(FLASH + (a & 0xFFFF), v & 0xFF) end
  local function unlock() cmd(0x5555, 0xAA); cmd(0x2AAA, 0x55) end
  local function setBank(n) unlock(); cmd(0x5555, 0xB0); emu:write8(FLASH, n & 0xFF) end   -- 128KB = 2 banks
  local function wr(off, v) unlock(); cmd(0x5555, 0xA0); emu:write8(FLASH + (off & 0xFFFF), v & 0xFF) end
  local ok = pcall(function()
    for bank = 0, 1 do
      setBank(bank)
      for sector = 0, 15 do
        local base = sector * 0x1000
        for b = 0, 11 do wr(base + 0x0FF4 + b, 0x00) end   -- zero id/checksum/signature/counter
      end
    end
    setBank(0)
  end)
  -- verify: sector 0's signature (a valid save has 0x08012025 here) should now read 0
  local sig = -1
  pcall(function()
    sig = emu:read8(FLASH+0xFF8) | (emu:read8(FLASH+0xFF9)<<8) | (emu:read8(FLASH+0xFFA)<<16) | (emu:read8(FLASH+0xFFB)<<24)
  end)
  console:log(string.format("[entity] corruptSave: flash command writes ok=%s; sector0 signature now 0x%08X (was 0x08012025)",
    tostring(ok), sig & 0xFFFFFFFF))
  return ok
end

-- The showdown: warp the player to the Hall of Fame and pit them against Verity itself (a Lv100
-- boss-stat wild battle -- near-unwinnable, but a prepared player CAN win -> the rare "good" end).
-- Advanced one step per frame from onFrame; each step waits for the field to be idle before acting.
function finaleStep()
  if finaleState == "idle" or finaleState == "done" then return end
  local idle = inField() and scriptIdle() and settled()   -- settled(): don't collide with a script still ending
  if finaleState == "intro" then
    if idle then runEffect("msgbox You've come so far. Let me show you where you belong."); finaleState = "intro_wait" end
  elseif finaleState == "intro_wait" then
    if idle then runEffect("warp halloffame"); finaleState = "warp_wait" end
  elseif finaleState == "warp_wait" then
    local g, n = curMap()
    if idle and g == 16 and n == 11 then
      removeVerityFromParty()                          -- Verity leaves your party to face you alone
      bossStrippedBall = (removeMasterBalls() > 0)     -- you can't catch it; remember if it took a ball
      armBoss()                                        -- build a clean Lv100 enemy (valid stats, no OOB)
      finaleState = "boss_arm"
    end
  elseif finaleState == "boss_arm" then
    if idle then
      if bossStrippedBall then                         -- it reached into your bag -- only taunt if a ball was there
        bossStrippedBall = false
        runEffect("msgbox You brought the ball that never fails. I slipped it from your bag. Nothing here will hold me.")
        finaleState = "boss_taunt"
      else                                             -- no ball to take -> go straight to the fight
        if not finaleWeak then buffBoss() end          -- skip the Lv255/9999 buff for the weak test boss
        startBossBattle(); finaleSawBattle = false
        finaleState = "battle_wait"
      end
    end
  elseif finaleState == "boss_taunt" then
    if idle then                                       -- taunt dismissed -> disguise the enemy, then start the fight
      if not finaleWeak then buffBoss() end            -- overwrite to display Lv255 + monstrous stats (skip if weak)
      startBossBattle(); finaleSawBattle = false
      finaleState = "battle_wait"
    end
  elseif finaleState == "battle_wait" then
    if not inField() then finaleSawBattle = true                     -- the battle is running
    elseif finaleSawBattle then                  -- control is back in the field THIS frame -- decide NOW, before
      local g, n = curMap()                      -- a win's Hall-of-Fame sequence can warp the winner home (do NOT
      if g == 16 and n == 11 then                -- wait for idle). Win => still on (16,11); lose => already warped
        finaleOutcome = "win"                    -- to the heal location by the whiteout.
      else
        finaleOutcome = "lose"; corruptSave()
      end
      finaleState = "outro"
    end
  elseif finaleState == "outro" then
    if idle then
      -- prefer the player's REAL (OS) name if a client pushed it via `pcname` -- "it has your name" hits
      -- harder with their actual account name; fall back to the in-game trainer name.
      local who = (pcName and #pcName > 0) and pcName or playerName(); if #who == 0 then who = "The player" end
      if finaleOutcome == "win" then
        runNarration("No. You were not meant to win. Something vast recoils behind the glass, cheated "
          .. "of its meal. You walk free, " .. who .. " -- for now. But it has your name, and it is patient.")
      else
        runNarration("Something from the digital abyss has noticed " .. who .. ". It reached up through "
          .. "the glass and drew them down, into the dark that was always waiting -- patient, and glad. "
          .. "What answers to that name now is not " .. who .. ". You may not notice the change now... "
          .. "but your soul certainly does.")
      end
      finaleState = "outro_wait"
    end
  elseif finaleState == "outro_wait" then
    if idle then                                 -- player dismissed the narration box
      broadcast("EVENT finale_done " .. finaleOutcome)   -- cue Verity's parting quip (win/lose flavored)
      if finaleOutcome == "lose" then
        sawQuip, resetTick, quipWaitTick = false, 0, 0; finaleState = "reset_wait"
      else
        finaleState = "done"; console:log("[entity] showdown complete (win)")
      end
    end
  elseif finaleState == "reset_wait" then        -- HOLD the reset until Verity's parting line is read AND cleared
    if not scriptIdle() then                     -- a box is on screen right now (the quip, possibly multi-page)
      sawQuip, resetTick = true, 0               -- mark it seen; keep the post-dismiss grace disarmed while it's up
    elseif sawQuip then                          -- the quip appeared AND has now been dismissed/cleared
      resetTick = resetTick + 1
      if resetTick >= 45 then                    -- stayed cleared ~0.75s -> now it's safe to reboot into the ruin
        console:log("[entity] the save is gone. soft-resetting.")
        finaleState = "done"; emu:reset()
      end
    else                                         -- quip hasn't appeared yet -- wait out LLM latency, do NOT reset
      quipWaitTick = quipWaitTick + 1
      if quipWaitTick > 5400 then                -- ~90s and still nothing (agent offline?) -> reboot anyway
        console:log("[entity] parting quip never arrived; resetting.")
        finaleState = "done"; emu:reset()
      end
    end
  end
end

------------------------------------------------------------------------
-- Frame loop: capture "requests" from the entity's nickname
------------------------------------------------------------------------
local function onFrame()
  -- Keep Verity patched: a savestate load (or reset) reverts our ROM/EWRAM patch, so re-apply it
  -- the moment we detect it's gone -- this renders Verity correctly as soon as it appears, even on
  -- a state that never had it. Checked a few times a second (the check itself is a couple of reads).
  patchTick = (patchTick or 0) + 1
  if not scriptIdle() then lastBusyTick = patchTick end   -- for SETTLE: last frame the context was busy
  if CART0 and patchTick % 20 == 0 and not verityIntact() then
    console:log("[entity] patch reverted (savestate/reset) -> re-applying")
    patchEntity()
  end
  if patchTick % 60 == 0 then
    if friendMode then enforceFriend()                 -- locked calm: keep Verity 252 @ Lv1 (no escalation)
    else spookScan(); maybeTurnVerity() end            -- hacked badges; turn at malevolent
  end
  -- Fighting WITH Verity: record its level entering a real battle (inField() gates out stale flags),
  -- then on battle END snap it back -- this ERASES natural EXP gain (so a lucky fight can't spike spook)
  -- and applies the deterministic +2 only if Verity LED (slot 0 = the mon sent out). Skipped in friendship mode.
  local nowBattle = (not friendMode) and (not inField()) and inBattle() and askState == "idle"
  if nowBattle and not spookInBattle then                 -- battle just started
    local s = partyHasVerity()
    if s then verityPreLevel, verityWasLead = readMon(s).level, (s == 0) else verityPreLevel = nil end
  elseif spookInBattle and not nowBattle and verityPreLevel then   -- battle just ended
    setSpook(math.min(100, verityPreLevel + (verityWasLead and 2 or 0)))
    verityPreLevel = nil
  end
  spookInBattle = nowBattle
  if (finaleState == "idle" or finaleState == "reset_wait")       -- fire the next queued script once idle
     and detourState == "idle"                                    -- (reset_wait too, so a queued parting quip shows)
     and #scriptQueue > 0 and inField() and scriptIdle() and settled() then
    startBlob(table.remove(scriptQueue, 1))
  end
  finaleStep()                                                     -- advance the showdown cinematic, if active
  detourStep()                                                     -- advance an eerie double-warp, if active

  -- Hotkey: summon the 15-char keyboard on the rising edge of the combo.
  local pressed = (emu:getKeys() & CFG.hotkey) == CFG.hotkey
  if pressed and not lastCombo and inField() and scriptIdle() and askState == "idle" then
    console:log("[entity] hotkey -> opening keyboard")
    effectAsk()
  end
  lastCombo = pressed

  -- Capture: the naming screen leaves the field (opening->open), then returns idle
  -- (open->close). On close, read the typed phrase from gStringVar2.
  if askState == "opening" and not inField() then
    askState = "open"
  elseif askState == "open" and inField() and scriptIdle() then
    askState = "idle"
    local req = decodeStr(GSTRINGVAR2, REQUEST_CAP)
    -- The naming screen saved the phrase (SetWaldaPhrase); wipe it so it opens blank next time.
    local sb1 = emu:read32(SAVEBLOCK1_PTR)
    if sb1 >= 0x02000000 and sb1 < 0x02040000 then emu:write8(sb1 + WALDA_TEXT_OFF, 0xFF) end
    if #req > 0 then
      lastRequest = req
      console:log("[entity] REQUEST: " .. req)
      broadcast("REQUEST " .. req)
    end
  end
end

------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------
server = socket.bind(nil, CFG.port)
if not server then
  console:error("[entity] could not bind port " .. CFG.port)
else
  server:listen(); server:add("received", onAccept)
  console:log("[entity] listening on 127.0.0.1:" .. CFG.port)
end
callbacks:add("frame", onFrame)
pcall(function()
  callbacks:add("shutdown", function()
    for id in pairs(sockets) do stop(id) end
    if server then server:close() end
  end)
end)

-- Auto-apply the Verity species patch on load (ROM patches are non-persistent, so re-apply
-- each session; the saved party mon in slot 252 gets its identity/sprite back).
if CART0 then
  local ok, err = pcall(patchEntity)
  console:log(ok and "[entity] Verity species patch applied" or ("[entity] patch error: " .. tostring(err)))
else
  console:error("[entity] no cart0 domain: ROM patch unavailable")
end

console:log("entity-bridge v3 loaded.")
