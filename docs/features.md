# Laban features

This document lists all the features of Laban. Many features have no menu
item and no setting. This document shows how to use them.

To open the settings, select **Laban → Settings** or push ⌘,.

## Sessions

- Your shells continue to run when Laban quits, crashes, or updates. A daemon
  keeps them. When you open Laban again, your tabs, processes, and scrollback
  come back.
- A restart of the Mac stops the shells.
- To restart Laban, select **Laban → Restart Laban** (⌥⌘R). Your shells
  continue to run.
- Laban finds Claude Code and Codex sessions in your tabs. When Laban opens
  again, it resumes them:
  - If the agent ran when Laban quit, Laban runs `claude --resume <id>` or
    `codex resume <id>`. When the agent stops, you get a shell.
  - If the agent had stopped, Laban types the resume command at the prompt.
    Push Return to run it.
- To disable the restore of tabs, clear **Restore tabs on launch** (Settings
  → Terminal).
- To set when Laban asks before it closes a tab, use **Ask before closing**
  (Settings → Terminal).

## Tabs

| Action | Shortcut |
| --- | --- |
| New tab | ⌘T |
| Close tab | ⌘W |
| Go to tab 1 to 8 | ⌘1 to ⌘8 |
| Go to the last tab | ⌘9 |
| Next tab | ⌃Tab, ⇧⌘], or ⌥⌘→ (when the tab has no split) |
| Previous tab | ⌃⇧Tab, ⇧⌘[, or ⌥⌘← (when the tab has no split) |
| Show or hide the sidebar | ⌃⌘S |

- A new tab or split opens in the directory of the active tab.
- The sidebar shows the directory, the git branch, and the command of each
  tab.
- To change the order of tabs, drag a row in the sidebar.
- To close a tab from the sidebar, move the pointer on the row and click ×.
- Move the pointer on a tab in the sidebar to see a live preview of it. This
  feature needs the Slug Glyph renderer and **Sidebar hover preview**
  (Settings → Rendering).
- Hold ⌃ and push Tab more than one time to step through the tabs. Laban
  goes to the tab when you release ⌃. This also works with ⌥⌘→. This feature
  needs the hover preview.
- The sidebar shows an error marker when a command fails.
- The sidebar shows a progress bar when a program sends OSC 9;4 progress.
- A program can set a colored dot and a status text in the sidebar with
  OSC 21337. An "awaiting" status makes the tab pulse.

## Split panes

| Action | Shortcut |
| --- | --- |
| Split right | ⌘D |
| Split down | ⇧⌘D |
| Next or previous pane | ⌥⌘] or ⌥⌘[ |
| Pane on the left or right | ⌥⌘← or ⌥⌘→ |
| Pane above or below | ⌥⌘↑ or ⌥⌘↓ |
| Zoom one pane | ⇧⌘Return |
| Make all panes equal | ⌃⌘= |
| Move a divider | ⌃⌘ and an arrow key |

- To make all panes equal, you can also double-click a divider.
- To cancel a divider drag, push Esc.
- Click a pane to make it active.
- Scroll on a pane that is not active to scroll it. The active pane does not
  change.
- All these commands are in the **Pane** menu.

## Keyboard

- ⌘← moves the cursor to the start of the line. ⌘→ moves it to the end.
  ⌘⌫ deletes to the start of the line. Laban sends ⌃A, ⌃E, and ⌃U.
- ⌘+, ⌘=, and ⌘− change the text size. ⌘0 sets the default size.
- **Option as Meta** (Settings → Terminal) makes ⌥ work as Meta for Emacs and
  shell key bindings. It is off by default, so ⌥ types the characters of your
  keyboard layout.
- Native text input works. Pinyin and other input methods show their usual
  candidate window.

## Mouse and trackpad

- ⌘-click a link to open it in your browser. This works for OSC 8 links and
  for http and https addresses in the text. The pointer changes to a hand
  when you hold ⌘.
- Double-click selects a word. Triple-click selects a line. Paths and URLs
  stay in one word.
- ⇧-click extends the selection.
- When a program uses the mouse (for example vim or tmux), Laban sends the
  clicks to the program. Hold ⇧ to select text in Laban.
- Drag a selection past the edge to scroll.
- Pinch, or scroll with ⌘ held, to change the text size.
- Hold ⇧ and scroll to scroll the Laban scrollback in a full-screen program.
- In `less` and `man`, the scroll wheel sends the arrow keys.
- To preview a file with Quick Look, select its path and push ⌘Y. You can
  also tap with three fingers or force click on the path. Laban finds
  relative paths from the current directory of the shell. A git commit hash
  shows the commit.

## Find

- Push ⌘F to find text in the session.
- Push Return for the next match and ⇧Return for the previous match.
- Push Esc to close the find bar.

## Paste, drop, and clipboard

- ⌘V with an image on the clipboard:
  - In an `ssh` session, Laban uploads the image to the remote host and
    pastes its path. Laban asks you one time for each host. Claude Code or
    Codex on a server can then read your screenshot.
  - In a local session, Laban sends ⌃V. Claude Code and other local programs
    then read the image from the clipboard.
  - If the clipboard has text and an image, Laban pastes the text.
- A program that uses Kitty paste events (OSC 5522) gets the clipboard in the
  terminal stream. This also works over SSH.
- Laban removes escape and control characters from all pastes.
- Laban asks before it pastes a very large text. Laban also asks before it
  pastes many lines into a program that cannot accept them safely.
- Drop files on a tab to type their paths. Laban adds quotes when necessary.
- Drop an image from a browser or Photos to save it to a file and type its
  path. Laban deletes these files after 7 days.
- A program can copy text to the Mac clipboard with OSC 52, also over SSH.
  Laban shows a message when this occurs.

## Export

- Push ⌘E to save the last 10 seconds of the tab as an asciinema cast.
- Select **File → Export Recent…** for 5, 30, or 60 seconds.

## Notifications

- Laban shows a macOS notification when a tab needs your action, when a task
  completes, or when a program rings the bell.
- Programs can send notifications with OSC 9, OSC 777, or OSC 99.
- Laban does not show a notification for the tab that you look at.
- Click a notification to go to its tab.
- To select the notifications that you get, use Settings → Notifications.
  You can also turn on a sound and send a test notification.

## Shell integration

- Laban adds shell integration to zsh, bash, and fish. You do not change your
  dotfiles.
- When a command completes, Laban resets a terminal that the command left in
  a bad state. For example, Laban turns off mouse reporting and leaves the
  alternate screen.
- Laban sets `TERM=xterm-256color`, `COLORTERM=truecolor`, and
  `TERM_PROGRAM=Laban`.
- To open a new tab with `ssh` or `telnet`, open an `ssh://` or `telnet://`
  link. For example: `open ssh://host`.

## Text and Unicode

- Laban draws text from the font outlines on the GPU. Text stays sharp when
  you zoom.
- Ligatures are on by default. To disable them, clear **Font ligatures**
  (Settings → Rendering).
- Laban adds a CJK font (PingFang, Noto CJK, or Sarasa) to JetBrains Mono.
  To select a different font, use **CJK font** (Settings → Appearance).
- Emoji use the correct width when a program turns on mode 2027. To change
  this, use **Unicode width** (Settings → Terminal).
- To show right-to-left text in reading order, select **Right-to-left text
  in reading order** (Settings → Rendering).
- Programs can show images with the Kitty graphics protocol.

## Appearance

- Select one theme for light mode and one for dark mode. Laban follows the
  system appearance.
- To add a theme, select **Import Theme…** and select a
  `.laban-theme.json` file. The dialog opens on examples: Catppuccin,
  Dracula, Gruvbox, Nord, Rosé Pine, Selenized, and Terminal Basic.
- Set the background opacity and blur, or add a background image (Settings →
  Appearance). **Preset** has ready-made values, for example Frosted.
- Set the font, the cursor shape, and the cursor blink (Settings →
  Appearance).
- Set the renderer, the emoji style, and the text weight (Settings →
  Rendering). The default renderer is Slug Glyph.

## Agents and the `laban` CLI

- The `laban` CLI is in `Laban.app/Contents/MacOS`. To add it to your PATH,
  run `laban install-cli`.
- An agent can read the screen or the scrollback of a session, take a
  screenshot, scroll, and wait for a prompt. Laban asks you before each
  read.
- With `laban propose`, an agent suggests a command. You accept or reject it
  in Laban. The CLI does not type into your session.
- `laban context --json` gives the session identity, the shell state, and the
  last lines of output.
- `laban completions zsh` prints shell completions. Bash and fish are also
  available.
- `laban --help` shows all the commands.
- To turn the agent control server on or off, use Settings → Terminal or
  **Debug → Disable Agent Control Server**. To revoke approvals, use Settings
  → Agent.
- The control server uses a local Unix socket. Laban does not open a TCP
  port. For more data, see
  [controlling-agent-control-plane.md](process/controlling-agent-control-plane.md)
  and the [threat model](process/control-plane-threat-model.md).

## Diagnostics and updates

- **Help → Diagnostics…** shows the state of Laban.
- **Help → Reveal Log Folder in Finder** opens the log folder.
- **Debug → Send Diagnostics…** collects the data for a bug report.
- **Debug → Start PTY Capture** (⇧⌘R) records the terminal output for a
  rendering problem.
- Laban updates automatically. To stop this, clear **Automatically check for
  updates** (Settings → Terminal). See [update-checks.md](release/update-checks.md).

The decisions behind each feature are in [`adr/`](adr/).
