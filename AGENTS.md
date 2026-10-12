# AGENTS.md

errjump.ranma is a ranma plugin in Lua: `plugin/errjump.lua` is all of it, and
its header comment is the reference that `README.md` repeats. ranma's API is
https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md (`ranma --dump-types` prints it as LuaLS annotations).

- Push to `main`.
- A change to what it does changes the header comment and `README.md` in the
  same commit, and an option goes in the README's table.
- A bind gets 200 ms. Each `pane:search` reads the whole scrollback (about
  20 ms for 8000 lines, whatever the regex), so a scan is two searches: every
  format in one alternation, the run boundaries in another. A new format is a
  regex in that alternation and a parser in `FORMATS`, never a search of its
  own. Files are checked and read by one `ranma.spawn`, never from Lua.
- Test a format against real output: produce it with the real tool, in a
  private ranma server (never the default socket), and open the list there.
- Check it loads: `ranma --check-config` lists every plugin and why one failed;
  `ranma lua` runs code in the live server.
  CI (`.github/workflows/ci.yml`) loads it into the latest ranma release on
  every push and fails if it does not.
- `AGENTS.local.md` (gitignored) carries what is true of one checkout on one
  machine. Never commit it.
