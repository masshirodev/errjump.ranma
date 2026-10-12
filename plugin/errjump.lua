-- errjump: vim's quickfix list for any pane. The compiler errors in a pane's
-- screen and scrollback, picked from or walked one by one, open in an editor
-- at their line.
--
-- leader Q is a folder (+errors):
--   Q q    the list: the focused pane's errors, the latest run first, each
--          with its message and the source lines around it. On it:
--            enter  open it in the editor     y  copy file:line:col
--            s      show it in the pane       r  scan again
--   Q n    the next error of the last list, opened in the editor (with no
--          list yet, the focused pane is read first)
--   Q p    the previous one
-- :errjump [list|next|prev] in the palette does the same, and so does
-- ranma.emit("errjump", "next") from a bind of your own. The last list is
-- kept until the configuration reloads; Q q reads the pane again.
--
-- It reads rustc and clippy (`--> src/x.rs:12:5`, under its `error[E…]:`),
-- tsc (`src/a.ts(12,5): error TS…` and `src/a.ts:12:5 - error`), eslint (the
-- file's line, then `12:5  error  msg  rule`), svelte-check (`/x.svelte:12:5`
-- then `Error: …`, and its machine output), go (`./x.go:12:5: …`), python
-- tracebacks (`File "x.py", line 12`) and anything else printing
-- `path:line:col: message`. A relative path is taken from the pane's
-- directory, or the nearest of its parents that has it (cargo and go print
-- paths from the workspace's root); a path that names no file is dropped.
-- Runs are told apart by the lines that start or end one (`Compiling …`,
-- `error: could not compile`, `Found 2 errors`, `Traceback …`); an error
-- printed again by a later run is listed once, in the later run.
--
-- The editor is errjump.editor, else $VISUAL, else $EDITOR, else nvim, run as
-- `EDITOR +LINE FILE` in a new pane (or a float, errjump.open). vim and nvim
-- get the column too, as do hx (`FILE:LINE:COL`) and kak (`+LINE:COL`).
-- While the vim or nvim errjump opened still runs, the next error opens in
-- it instead of a new pane (errjump.reuse); a buffer with changes is hidden,
-- not lost.
-- Options (settings panel, "errjump" group): errjump.editor, errjump.open,
-- errjump.reuse, errjump.max, errjump.context, errjump.extra.
--
-- errjump.extra adds formats of your own: regexes (copy mode's syntax; `(?m)`
-- is on, and a line's end is ` *$`), separated by " ;; ", each matching where
-- a location is printed. The location is read from the match as
-- `path:line[:col]`, `path(line,col)`, `"path", line N` or `path line N`;
-- the message is the rest of the line, or the next line when nothing
-- follows. A regex that does not parse is named on the list's status and
-- left out.
--
-- ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pane handles",
-- "Screens", "Timers and processes").

ranma.option("errjump.editor", {
  type = "string", default = "",
  name = "Editor", desc = "What an error opens in, given +LINE and the file. Empty: $VISUAL, else $EDITOR, else nvim.",
})
ranma.option("errjump.open", {
  type = "enum", choices = { "pane", "float" }, default = "pane",
  name = "Open in", desc = "A new pane placed by the layout, or a float at 80% of the workspace.",
})
ranma.option("errjump.reuse", {
  type = "bool", default = true,
  name = "Reuse the editor", desc = "While the vim or nvim errjump opened still runs, open the next error in it.",
})
ranma.option("errjump.max", {
  type = "int", min = 10, max = 1000, step = 10, default = 200, slider = false,
  name = "Most errors", desc = "The most matches one format takes from a pane, newest first.",
})
ranma.option("errjump.context", {
  type = "int", min = 0, max = 8, default = 2,
  name = "Context lines", desc = "Source lines shown above and below the error's line.",
})
ranma.option("errjump.extra", {
  type = "string", default = "",
  name = "Extra formats",
  desc = "Regexes of your own, separated by ' ;; ', each matching a printed location (path:line:col, path(line,col), \"path\", line N).",
})

---------------------------------------------------------------------------
-- Reading a pane

-- A pane's lines, each read once per scan.
local function reader(p)
  local top, bottom = p:range()
  local cache = {}
  return function(n)
    if n < top or n > bottom then return nil end
    local t = cache[n]
    if t == nil then
      t = p:lines(n, n)[1] or ""
      cache[n] = t
    end
    return t
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The part of a line after a match, by character (lines are UTF-8, columns
-- count characters).
local function after(text, col)
  local a = utf8.offset(text, col + 1)
  return a and text:sub(a) or ""
end

-- "error", "warning" or "note", from what a compiler calls it.
local function kind_of(word)
  word = (word or ""):lower()
  if word:find("^warn") then return "warning" end
  if word:find("^note") or word:find("^help") or word:find("^hint") or word:find("^info") then return "note" end
  return "error"
end

-- svelte-check's human output and rustc's panics put the message on the line
-- after the location.
local function message_below(line, at)
  local next_line = line(at + 1)
  if not next_line then return "", nil end
  local word, msg = next_line:match("^%s*(%a+):%s+(.*)$")
  if word then return msg, kind_of(word) end
  return trim(next_line), nil
end

-- A location in any of the shapes a compiler prints one: the path, its line
-- and column (or nil), and how far into `s` it ended.
local function location(s)
  local a, b, path, l = s:find('"([^"]+)", line (%d+)')
  if a then return path, l, nil, b end
  local col
  a, b, path, l, col = s:find("([^%s(]+)%((%d+),(%d+)%)")
  if a then return path, l, col, b end
  a, b, path, l, col = s:find("([^%s:]+):(%d+):(%d+)")
  if a then return path, l, col, b end
  a, b, path, l = s:find("([^%s:]+):(%d+)")
  if a then return path, l, nil, b end
  a, b, path, l = s:find("(%S+) line (%d+)")
  if a then return path, l, nil, b end
end

---------------------------------------------------------------------------
-- The formats: a regex for pane:search (copy mode's syntax: `(?m)` for ^ to
-- mean a line's start, and ` *$` for its end, since a row is searched with
-- the blanks after its text), and a parser for each line it finds, given a
-- reader on the pane, the hit, and its line's text. A parser returns
-- { file, line, col, msg, kind } or nil; `base` is a directory the path is
-- relative to, when the output names one. Tried in order; a line one format
-- took is not looked at by the ones after it.

local FORMATS = {
  {
    name = "rustc",
    search = [[(?m)^\s*-->\s+\S+:\d+:\d+]],
    parse = function(line, h, text)
      local file, l, c = text:match("%-%->%s+(.-):(%d+):(%d+)")
      if not file then return nil end
      -- The `error[E0308]: mismatched types` it belongs to is a few lines up.
      for n = h.line - 1, h.line - 6, -1 do
        local t = line(n)
        if not t then break end
        local word, code, msg = t:match("^(%l+)(%b[]):%s*(.*)$")
        if not word then word, msg = t:match("^(%l+):%s*(.*)$") end
        if word and (word == "error" or word == "warning" or word == "note" or word == "help") then
          if code then msg = msg .. " " .. code end
          return { file = file, line = l, col = c, msg = msg, kind = kind_of(word) }
        end
      end
      return { file = file, line = l, col = c, msg = "", kind = "error" }
    end,
  },
  {
    name = "tsc",
    search = [[\S+\(\d+,\d+\): (error|warning)]],
    parse = function(_, _, text)
      local file, l, c, word, msg = text:match("([^%s(]+)%((%d+),(%d+)%): (%a+)%s*(.*)$")
      if not file then return nil end
      return { file = file, line = l, col = c, msg = msg, kind = kind_of(word) }
    end,
  },
  {
    name = "tsc --pretty",
    search = [[\S+:\d+:\d+ - (error|warning)]],
    parse = function(_, _, text)
      local file, l, c, word, msg = text:match("(%S+):(%d+):(%d+) %- (%a+)%s*(.*)$")
      if not file then return nil end
      return { file = file, line = l, col = c, msg = msg, kind = kind_of(word) }
    end,
  },
  {
    name = "eslint",
    search = [[(?m)^\s+\d+:\d+\s+(error|warning)\s]],
    parse = function(line, h, text)
      local l, c, word, rest = text:match("^%s+(%d+):(%d+)%s+(%a+)%s+(.*)$")
      if not l or (word ~= "error" and word ~= "warning") then return nil end
      local msg, rule = rest:match("^(.-)%s%s+(%S+)$")
      msg = msg and (msg .. " (" .. rule .. ")") or trim(rest)
      -- The file is the last line above that is not indented.
      for n = h.line - 1, h.line - 500, -1 do
        local t = line(n)
        if not t then break end
        if t:find("^%S") then
          return { file = trim(t), line = l, col = c, msg = msg, kind = kind_of(word) }
        end
      end
      return nil
    end,
  },
  {
    name = "svelte-check --output machine",
    search = [[(ERROR|WARNING) "[^"]+" \d+:\d+]],
    parse = function(line, h, text)
      local word, file, l, c, msg = text:match('(%u+) "([^"]+)" (%d+):(%d+) "(.*)"')
      if not word then return nil end
      -- Its paths are from the workspace START names.
      local base
      for n = h.line - 1, h.line - 300, -1 do
        local t = line(n)
        if not t then break end
        base = t:match('START "([^"]+)"')
        if base then break end
      end
      return { file = file, line = l, col = c, msg = msg, kind = kind_of(word), base = base }
    end,
  },
  {
    name = "python",
    search = [[File "[^"]+", line \d+]],
    parse = function(line, h, text)
      local file, l, rest = text:match('File "([^"]+)", line (%d+)(.*)$')
      if not file then return nil end
      local where = rest:match(", in (.+)$")
      -- The exception is the first line below that is not indented.
      local exc, exc_at
      for n = h.line + 1, h.line + 60 do
        local t = line(n)
        if not t then break end
        if t:find("^%S") then
          if not t:find("^Traceback") and not t:find("^During handling") then exc, exc_at = trim(t), n end
          break
        end
      end
      local msg = exc or ""
      if where then msg = msg .. (msg ~= "" and "  " or "") .. "(in " .. where .. ")" end
      -- Innermost frame first: it is where it failed.
      return { file = file, line = l, col = nil, msg = msg, kind = "error", group = exc_at }
    end,
  },
}

-- `path:line[:col]` with a message after it (go, gcc, rustc's panics,
-- svelte-check's human output, and most linters), last, for what the others
-- left. The path must have an extension: that keeps clock times out.
local GENERIC = {
  name = "path:line:col",
  search = [=[[\w.~/+@-]*\.[A-Za-z]\w*:\d+(:\d+)?]=],
}

-- A format of the user's: the location from the match, the message after it.
-- Lines that name a location without being an error of their own.
local NOT_ERRORS = {
  "^%s*:::",                 -- rustc: where something it points at was declared
  "^Found %d+ errors? in",   -- tsc --pretty's summary: "starting at: src/a.ts:5"
}

local function loose(line, h, text)
  for _, pat in ipairs(NOT_ERRORS) do
    if text:find(pat) then return nil end
  end
  local file, l, c = location(h.text)
  if not file then return nil end
  local msg = trim((after(text, h.end_col + 1):gsub("^[%s:%-]+", "")))
  local kind
  if msg == "" then
    msg, kind = message_below(line, h.line)
  else
    local word, rest = msg:match("^(%a+):%s+(.*)$")
    if word and (kind_of(word) ~= "error" or word:lower():find("^err")) then
      msg, kind = rest, kind_of(word)
    end
  end
  return { file = file, line = l, col = c, msg = msg, kind = kind or (text:lower():find("warning") and "warning" or "error") }
end
GENERIC.parse = loose

-- One regex for every format: a search costs about the same however much it
-- asks for, and each one reads the whole scrollback (some 20 ms for 8000
-- lines), so the formats are searched together and told apart in Lua.
local function alternation(list)
  local parts = {}
  for _, re in ipairs(list) do
    parts[#parts + 1] = "(?:" .. re:gsub("^%(%?m%)", "") .. ")"
  end
  return "(?m)" .. table.concat(parts, "|")
end

local function extras()
  local list = {}
  for re in (ranma.get("errjump.extra") .. " ;; "):gmatch("(.-) ;; ") do
    local r = trim(re)
    if r ~= "" then list[#list + 1] = r end
  end
  return list
end

-- Lines that start a run of a compiler or end one, to tell runs apart: one
-- search, and the words that make a line an end.
local RUNS = alternation({
  [[^\s*(Compiling|Checking) \S+ v\d]], [[^Traceback \(most recent]], [[START "]], [[^# \S+ *$]],
  [[^error: could not compile]], [[^warning: .* generated \d+ warnings?]], [[^Found \d+ errors?]],
  [[\d+ problems? \(\d+ errors?]], [[svelte-check found \d+]], [[COMPLETED \d+ FILES]], [[^\s*Finished .* in \d]],
})
local RUN_ENDS = { "could not compile", " generated ", "Found ", " problem", "svelte-check found", "COMPLETED ", "Finished " }

local function boundaries(p)
  local starts, ends = {}, {}
  local ok, hits = pcall(p.search, p, RUNS, { limit = 1000 })
  if not ok then return starts, ends end
  for _, h in ipairs(hits) do
    local is_end = false
    for _, w in ipairs(RUN_ENDS) do
      if h.text:find(w, 1, true) then is_end = true break end
    end
    local into = is_end and ends or starts
    into[#into + 1] = h.line
  end
  table.sort(starts)
  table.sort(ends)
  return starts, ends
end

-- Every error the pane shows, before its files are checked: newest run first,
-- in the order printed within a run. And what was wrong with errjump.extra.
local function scan(p)
  local line = reader(p)
  local res = {}
  for _, f in ipairs(FORMATS) do res[#res + 1] = f.search end
  local extra = extras()
  for _, re in ipairs(extra) do res[#res + 1] = re end
  res[#res + 1] = GENERIC.search
  local bad = {}
  local opts = { limit = ranma.get("errjump.max") }
  local ok, hits = pcall(p.search, p, alternation(res), opts)
  if not ok then
    -- One of the user's regexes does not parse: name it, search without it.
    res = {}
    for _, f in ipairs(FORMATS) do res[#res + 1] = f.search end
    for _, re in ipairs(extra) do
      if pcall(p.search, p, alternation({ re }), { limit = 1 }) then
        res[#res + 1] = re
      else
        bad[#bad + 1] = re
      end
    end
    res[#res + 1] = GENERIC.search
    ok, hits = pcall(p.search, p, alternation(res), opts)
    if not ok then return {}, { tostring(hits) } end
  end

  -- The first location on each line.
  local first = {}
  for _, h in ipairs(hits) do
    local f = first[h.line]
    if not f or h.col < f.col then first[h.line] = h end
  end
  local found = {}
  for _, h in pairs(first) do
    local text = line(h.line) or h.text
    local e
    for _, f in ipairs(FORMATS) do
      local ok2, r = pcall(f.parse, line, h, text)
      if ok2 and r then e = r break end
    end
    if not e then
      local ok2, r = pcall(loose, line, h, text)
      if ok2 then e = r end
    end
    if e and e.file and e.file ~= "" and tonumber(e.line) then
      e.line, e.col, e.at = tonumber(e.line), tonumber(e.col), h.line
      e.msg = trim(e.msg or "")
      found[#found + 1] = e
    end
  end

  local starts, ends = boundaries(p)
  local function count(list, at, inclusive)
    local n = 0
    for _, l in ipairs(list) do
      if l < at or (inclusive and l == at) then n = n + 1 else break end
    end
    return n
  end
  for _, e in ipairs(found) do e.run = count(ends, e.at, false) + count(starts, e.at, true) end
  -- One entry per error, the latest printed; then each run in print order.
  table.sort(found, function(a, b)
    if a.run ~= b.run then return a.run > b.run end
    return a.at > b.at
  end)
  local seen, list = {}, {}
  for _, e in ipairs(found) do
    local key = table.concat({ e.base or "", e.file, e.line, e.col or "", e.msg }, "\0")
    if not seen[key] then
      seen[key] = true
      list[#list + 1] = e
    end
  end
  table.sort(list, function(a, b)
    if a.run ~= b.run then return a.run > b.run end
    local ka, kb = a.group or a.at, b.group or b.at
    if ka ~= kb then return ka < kb end
    return a.at > b.at
  end)
  return list, bad
end

---------------------------------------------------------------------------
-- Checking the files, off the bind's clock

-- For each entry: the file it names, found from the pane's directory or the
-- nearest parent that has it, and the lines around its line. One process
-- for the whole list; nothing is opened from Lua.
local CHECK = [[
cwd=$1; ctx=$2; shift 2
i=0
while [ $# -ge 3 ]; do
  i=$((i + 1)); p=$1; b=$2; l=$3; shift 3
  r=
  case $p in
    /*) [ -f "$p" ] && r=$p ;;
    "~/"*) [ -f "$HOME/${p#"~/"}" ] && r=$HOME/${p#"~/"} ;;
    *) for d in "$b" "$cwd"; do
         k=0
         while [ -n "$d" ] && [ $k -lt 4 ]; do
           if [ -f "$d/$p" ]; then r=$d/$p; break 2; fi
           d=${d%/*}; k=$((k + 1))
         done
       done ;;
  esac
  [ -n "$r" ] || continue
  s=$((l > ctx ? l - ctx : 1)); e=$((l + ctx))
  printf '\036%s\t%s\n' "$i" "$r"
  awk -v a="$s" -v b="$e" 'NR >= a { printf "\037%d\t%s\n", NR, substr($0, 1, 300) } NR >= b { exit }' "$r"
done
]]

local state = {
  list = nil,       -- the last list, as checked
  index = 0,        -- where next and prev are in it
  source = nil,     -- the pane it was read from
  editor = nil,     -- the editor pane errjump opened last
  expect = false,   -- an editor pane is being opened: pane_open names it
  job = nil,        -- the check running now
  screen = nil,
}

local function check(p, list, bad, done)
  local cwd = p:cwd() or os.getenv("HOME") or "/"
  local args = { "sh", "-c", CHECK, "sh", cwd, tostring(ranma.get("errjump.context")) }
  for _, e in ipairs(list) do
    args[#args + 1] = e.file
    args[#args + 1] = e.base or ""
    args[#args + 1] = tostring(e.line)
  end
  if state.job then ranma.kill(state.job) end
  state.job = ranma.spawn(args, {
    timeout = 20,
    on_exit = function(r)
      state.job = nil
      if r.error or r.signal then
        return ranma.toast("errjump: could not check the files: " .. tostring(r.error or ("signal " .. r.signal)), { urgent = true })
      end
      local kept, cur = {}, nil
      for row in (r.stdout or ""):gmatch("[^\n]+") do
        local i, path = row:match("^\30(%d+)\t(.*)$")
        if i then
          cur = list[tonumber(i)]
          cur.path = path:gsub("/%./", "/")
          cur.preview = {}
          kept[#kept + 1] = cur
        else
          local n, text = row:match("^\31(%d+)\t(.*)$")
          if n and cur then cur.preview[#cur.preview + 1] = { n = tonumber(n), text = (text:gsub("\t", "    ")) } end
        end
      end
      done(kept, cwd, bad)
    end,
  })
end

-- The pane to read: the focused one, unless it is the editor errjump opened,
-- then the one the list came from.
local function source_pane()
  local p = ranma.pane()
  if p and state.editor and p.id == state.editor and state.source then
    local s = ranma.pane(state.source)
    if s and s:alive() then return s end
  end
  return p
end

-- Read a pane, check its files, and call done(list, cwd) with what exists.
local function collect(p, done)
  local list, bad = scan(p)
  if #bad > 0 then
    ranma.toast("errjump: bad pattern, skipped: " .. table.concat(bad, ", "), { urgent = true })
  end
  if #list == 0 then return done({}, p:cwd(), bad) end
  check(p, list, bad, done)
end

---------------------------------------------------------------------------
-- Opening an error

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function editor()
  local e = ranma.get("errjump.editor")
  if e == "" then e = os.getenv("VISUAL") or "" end
  if e == "" then e = os.getenv("EDITOR") or "" end
  if e == "" then e = "nvim" end
  return e, (e:match("^%S+") or e):match("[^/]*$")
end

local VIMS = { vim = true, nvim = true, vi = true }

local function command_for(e)
  local cmd, name = editor()
  local col = e.col or 1
  if VIMS[name] then
    return cmd .. " " .. quote(("+call cursor(%d,%d)"):format(e.line, col)) .. " " .. quote(e.path)
  elseif name == "hx" or name == "helix" or name == "kak" then
    if name == "kak" then return cmd .. " +" .. e.line .. ":" .. col .. " " .. quote(e.path) end
    return cmd .. " " .. quote(e.path .. ":" .. e.line .. ":" .. col)
  end
  return cmd .. " +" .. e.line .. " " .. quote(e.path)
end

-- The editor pane errjump opened, if it still runs a vim it can drive.
local function open_editor_pane()
  if not ranma.get("errjump.reuse") or not state.editor then return nil end
  local p = ranma.pane(state.editor)
  if not (p and p:alive()) then return nil end
  local prog = (p:program() or ""):match("[^/]*$")
  return VIMS[prog] and p or nil
end

local function vimstr(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function open(e)
  local p = open_editor_pane()
  if p then
    -- Ctrl+\ Ctrl+N reaches normal mode from any mode, with none of Esc's
    -- waiting to tell it from Alt. A buffer with changes is hidden, not lost.
    local q = vimstr(e.path)
    p:keys("ctrl+\\", "ctrl+n")
    p:send((":if expand('%%:p') !=# %s | exe 'hide edit' fnameescape(%s) | endif | call cursor(%d,%d) | normal! zz\n")
      :format(q, q, e.line, e.col or 1))
    p:focus()
    return
  end
  state.expect = true
  ranma.defer(2000, function() state.expect = false end)
  ranma.action("exec " .. command_for(e))
  if ranma.get("errjump.open") == "float" then ranma.action("float_size 80 80") end
end

ranma.on("pane_open", function(ev)
  if state.expect then
    state.expect = false
    state.editor = ev.pane
  end
end)

---------------------------------------------------------------------------
-- The list

local MARK = { error = { "✗", "urgent" }, warning = { "!", "accent" }, note = { "·", "dim" } }

local HOME = os.getenv("HOME") or ""

local function shown_path(e, cwd)
  if cwd and e.path:sub(1, #cwd + 1) == cwd .. "/" then return e.path:sub(#cwd + 2) end
  if HOME ~= "" and e.path:sub(1, #HOME + 1) == HOME .. "/" then return "~" .. e.path:sub(#HOME + 1) end
  return e.path
end

local function where(e, cwd)
  return shown_path(e, cwd) .. ":" .. e.line .. (e.col and (":" .. e.col) or "")
end

local function totals(list)
  local n = { error = 0, warning = 0, note = 0 }
  for _, e in ipairs(list) do n[e.kind] = n[e.kind] + 1 end
  local parts = {}
  if n.error > 0 then parts[#parts + 1] = n.error .. (n.error == 1 and " error" or " errors") end
  if n.warning > 0 then parts[#parts + 1] = n.warning .. (n.warning == 1 and " warning" or " warnings") end
  if n.note > 0 then parts[#parts + 1] = n.note .. (n.note == 1 and " note" or " notes") end
  return table.concat(parts, " · ")
end

local function preview(e)
  local lines, at = {}, nil
  for i, l in ipairs(e.preview or {}) do
    if l.n == e.line then
      at = i
      local c = math.max((e.col or 1) - 1, 0)
      local a = utf8.offset(l.text, c + 1) or (#l.text + 1)
      local b = utf8.offset(l.text, c + 2) or (#l.text + 1)
      lines[i] = { { l.n .. "  ", "num" }, { l.text:sub(1, a - 1) }, { l.text:sub(a, b - 1), "hit" }, { l.text:sub(b) } }
    else
      lines[i] = { { l.n .. "  ", "num" }, { l.text } }
    end
  end
  return lines, at
end

local function go(i)
  local list = state.list
  if not list or not list[i] then return end
  state.index = i
  local e = list[i]
  ranma.notify(("errjump %d/%d  %s  %s"):format(i, #list, where(e, state.cwd), e.msg))
  open(e)
end

local function close_screen()
  if state.screen then state.screen:close() end
  state.screen = nil
end

local function body_of(list, cwd)
  local body, run, nrun = {}, nil, 0
  local per = {}
  for _, e in ipairs(list) do per[e.run] = (per[e.run] or 0) + 1 end
  for i, e in ipairs(list) do
    if e.run ~= run then
      run, nrun = e.run, nrun + 1
      body[#body + 1] = { "heading", nrun == 1 and "Latest run" or "Earlier run", count = per[e.run] }
    end
    local lines, at = preview(e)
    local detail = {}
    if e.msg ~= "" then detail[#detail + 1] = { "text", e.msg, role = MARK[e.kind][2] == "urgent" and "urgent" or nil, max = 3 } end
    if #lines > 0 then detail[#detail + 1] = { "log", lines = lines, at = at } end
    detail[#detail + 1] = { "facts", { e.kind, where(e, cwd) }, { "", i .. " of " .. #list } }
    body[#body + 1] = {
      "row", id = tostring(i),
      mark = MARK[e.kind],
      name = e.msg ~= "" and e.msg or where(e, cwd),
      note = shown_path(e, cwd),
      value = { e.line .. (e.col and (":" .. e.col) or ""), "dim" },
      detail = detail,
    }
  end
  return body
end

local show

local function row_entry(id)
  return id and state.list and state.list[tonumber(id)]
end

local function screen(list, cwd, bad)
  local s = state.screen
  local def = {
    body = body_of(list, cwd),
    count = totals(list),
    status = #bad > 0 and { "bad pattern: " .. table.concat(bad, ", "), "urgent" } or { "pane " .. state.source, "dim" },
  }
  if s then return s:set(def) end
  def.title = "errjump"
  def.chip = "ERR"
  def.filter = "names"
  def.detail = 2 * ranma.get("errjump.context") + 4
  def.options = true
  def.empty = "no errors"
  def.keys = {
    { "enter", "open", function(id)
      local e = row_entry(id)
      if not e then return end
      close_screen()
      go(tonumber(id))
    end },
    { "y", "copy", function(id)
      local e = row_entry(id)
      if e then
        ranma.copy(where(e))
        ranma.notify("copied " .. where(e))
      end
    end },
    { "s", "show", function(id)
      local e = row_entry(id)
      local p = e and ranma.pane(state.source)
      if p and p:alive() then
        close_screen()
        p:copy_mode(e.at, 0)
      end
    end },
    { "r", "rescan", function() show() end },
  }
  def.card = {
    { "enter", "open it in the editor" },
    { "y", "copy file:line:col" },
    { "s", "show it in the pane, in copy mode" },
    { "r", "read the pane again" },
  }
  def.on_close = function() state.screen = nil end
  state.screen = ranma.screen(def)
end

-- Read the pane again and show the list (or then call `after` with it).
function show(after_fn)
  local p = source_pane()
  if not p then return ranma.notify("errjump: no pane to read") end
  state.source = p.id
  collect(p, function(list, cwd, bad)
    state.list, state.index, state.cwd = list, 0, cwd
    if after_fn then return after_fn(list) end
    if #list == 0 and not state.screen then
      return ranma.notify("errjump: no errors in pane " .. p.id)
    end
    screen(list, cwd, bad)
  end)
end

local function walk(dir)
  local function step(list)
    if #list == 0 then return ranma.notify("errjump: no errors") end
    local i = state.index + dir
    if state.index == 0 then i = dir > 0 and 1 or #list end
    if i < 1 then return ranma.notify("errjump: at the first error") end
    if i > #list then return ranma.notify("errjump: at the last error") end
    go(i)
  end
  if state.list and #state.list > 0 then return step(state.list) end
  show(step)
end

ranma.bind("shift+q", { folder = "errors", group = "plugins" })
ranma.bind("shift+q q", function() show() end, { desc = "list", exit = true })
ranma.bind("shift+q n", function() walk(1) end, { desc = "next error", exit = true })
ranma.bind("shift+q p", function() walk(-1) end, { desc = "previous error", exit = true })

local function run(what)
  what = trim(tostring(what or ""))
  if what == "next" then walk(1)
  elseif what == "prev" then walk(-1)
  elseif what == "" or what == "list" then show()
  else ranma.notify("errjump: list, next or prev") end
end

ranma.command("errjump", run, { desc = "the pane's compiler errors", args = "[list|next|prev]", complete = { "list", "next", "prev" } })

-- For binds of your own: ranma.emit("errjump", "next").
ranma.on("user:errjump", run)
