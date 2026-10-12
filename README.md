# errjump.ranma

A plugin for [ranma](https://github.com/masshirodev/ranma), the terminal tiling window manager: vim's quickfix list for any pane. The compiler errors in a pane's screen and scrollback, picked from or walked one by one, open in an editor at their line.

## Install

With [hako](https://github.com/masshirodev/hako.ranma), in `~/.config/ranma/lua/plugins/errjump.lua`:

```lua
return { "masshirodev/errjump.ranma" }
```

Or by hand, as ranma loads any package under `pack/*/start/`:

```sh
git clone https://github.com/masshirodev/errjump.ranma ~/.config/ranma/pack/plugins/start/errjump.ranma
```

Needs: `sh` and `awk` (the files are checked and read by one background process, never from the bind), and an editor.

## What it does

```text
leader Q is a folder (+errors):
  Q q    the list: the focused pane's errors, the latest run first, each
         with its message and the source lines around it. On it:
           enter  open it in the editor     y  copy file:line:col
           s      show it in the pane       r  scan again
  Q n    the next error of the last list, opened in the editor (with no
         list yet, the focused pane is read first)
  Q p    the previous one
:errjump [list|next|prev] in the palette does the same, and so does
ranma.emit("errjump", "next") from a bind of your own. The last list is
kept until the configuration reloads; Q q reads the pane again.

It reads rustc and clippy (`--> src/x.rs:12:5`, under its `error[E…]:`),
tsc (`src/a.ts(12,5): error TS…` and `src/a.ts:12:5 - error`), eslint (the
file's line, then `12:5  error  msg  rule`), svelte-check (`/x.svelte:12:5`
then `Error: …`, and its machine output), go (`./x.go:12:5: …`), python
tracebacks (`File "x.py", line 12`) and anything else printing
`path:line:col: message`. A relative path is taken from the pane's
directory, or the nearest of its parents that has it (cargo and go print
paths from the workspace's root); a path that names no file is dropped.
Runs are told apart by the lines that start or end one (`Compiling …`,
`error: could not compile`, `Found 2 errors`, `Traceback …`); an error
printed again by a later run is listed once, in the later run.

The editor is errjump.editor, else $VISUAL, else $EDITOR, else nvim, run as
`EDITOR +LINE FILE` in a new pane (or a float, errjump.open). vim and nvim
get the column too, as do hx (`FILE:LINE:COL`) and kak (`+LINE:COL`).
While the vim or nvim errjump opened still runs, the next error opens in
it instead of a new pane (errjump.reuse); a buffer with changes is hidden,
not lost.
Options (settings panel, "errjump" group): errjump.editor, errjump.open,
errjump.reuse, errjump.max, errjump.context, errjump.extra.

errjump.extra adds formats of your own: regexes (copy mode's syntax; `(?m)`
is on, and a line's end is ` *$`), separated by " ;; ", each matching where
a location is printed. The location is read from the match as
`path:line[:col]`, `path(line,col)`, `"path", line N` or `path line N`;
the message is the rest of the line, or the next line when nothing
follows. A regex that does not parse is named on the list's status and
left out.

ranma's plugin API: https://github.com/masshirodev/ranma/blob/main/doc/CONFIG.md ("Pane handles",
"Screens", "Timers and processes").
```

## Binds and commands

| Keys | |
| --- | --- |
| `leader Q` | The `+errors` folder, listed under `plugins` in the which-key hint. |
| `leader Q q` | The list of the focused pane's errors. |
| `leader Q n` | The next error, opened in the editor. |
| `leader Q p` | The previous error. |
| `:errjump [list\|next\|prev]` | The same from the palette (`leader :`). |

On the list: `enter` opens the selected error, `y` copies `file:line:col`, `s` shows it in the pane in copy mode, `r` reads the pane again, `o` opens these options.

To put them on other keys, unbind the folder in `init.lua` (which takes its keys with it) and emit the plugin's event from your own binds:

```lua
ranma.unbind("shift+q")
ranma.bind("z", { folder = "errors", group = "plugins" })
ranma.bind("z z", function() ranma.emit("errjump", "list") end, { desc = "list" })
ranma.bind("z n", function() ranma.emit("errjump", "next") end, { desc = "next error" })
ranma.bind("z p", function() ranma.emit("errjump", "prev") end, { desc = "previous error" })
```

## Options

In ranma's settings panel under `errjump`, or with hako's `opts` (`{ "masshirodev/errjump.ranma", opts = { ... } }`), or `ranma.set { errjump = { ... } }`.

| Option | Default | |
| --- | --- | --- |
| `errjump.editor` | `""` | What an error opens in, given `+LINE` and the file. Empty: `$VISUAL`, else `$EDITOR`, else `nvim`. |
| `errjump.open` | `"pane"` | `pane`: a new pane placed by the layout. `float`: a float at 80% of the workspace. |
| `errjump.reuse` | `true` | While the vim or nvim errjump opened still runs, open the next error in it. |
| `errjump.max` | `200` | The most locations read from a pane, newest first. |
| `errjump.context` | `2` | Source lines shown above and below the error's line. |
| `errjump.extra` | `""` | Regexes of your own, separated by ` ;; `, each matching a printed location. |

A format of your own, for a tool that prints `ERROR at src/x.c line 12: ...`:

```lua
ranma.set { errjump = { extra = [[ERROR at \S+ line \d+]] } }
```

## License

MIT or Apache-2.0, as ranma.
