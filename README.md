# Claude Code Usage (Plasma 6 widget + CLI)

Panel widget showing Claude Code token usage and estimated cost, read from the local
session logs in `~/.claude/projects/**/*.jsonl`. No network access and no credentials.

- **Panel:** tokens · ≈cost · time until the current 5-hour block resets (configurable).
- **Popup:** current 5-hour block, Today / 7 days / 30 days totals, daily bar chart,
  top projects and models.
- **Cost** is an API-equivalent estimate. Each model's $/token rate is calibrated from
  Claude Code's own `cost-state` snapshots, so no prices are hard-coded. It is not what
  a Pro/Max subscription bills.

## Install

Download `claude-usage-*.plasmoid` from the
[latest release](https://github.com/xmerik/claude-usage-plasmoid/releases/latest), then:

```bash
kpackagetool6 -t Plasma/Applet -i claude-usage-1.1.plasmoid
systemctl --user restart plasma-plasmashell
```

Then right-click the panel → **Add or Manage Widgets** → **Claude Code Usage**.
To upgrade, use `-u` instead of `-i`. From a clone, pass `package` instead of the file.

Works on any Plasma 6 desktop (Kubuntu, Fedora KDE, KDE neon, Arch, …). If the widget
says it can't run the collector, install Plasma 5 Support (`sudo dnf install
plasma5support` on Fedora, `sudo apt install qml6-module-org-kde-plasma-plasma5support` on Ubuntu).

## Uninstall

```bash
kpackagetool6 -t Plasma/Applet -r local.claudeusage
```

The collector (`package/contents/code/collect.py`) needs only Python 3's standard
library. Run it without flags to see the raw JSON the widget reads. It caches parsed logs in
`~/.cache/claude-usage-plasmoid.json`.

## Remote machines

Right-click → **Configure** → **Remote hosts**, one per line:

```
server:~/.claude
```

The widget runs the collector on the host over SSH (`ssh HOST python3 -I - --rows`, with
the script piped in, so nothing gets installed there). Only per-request token counts and
cost snapshots come back, never transcript text. This needs key-based SSH (BatchMode)
and `python3` on the host. If a host is unreachable, the widget shows its last cached
numbers with a warning.

## Without Plasma: terminal, status line, Windows / WSL

The collector works on its own anywhere Python 3 runs. `--text` prints the same line
as the panel:

```console
$ python3 collect.py --text
20M · $7.75 · ⟳ 2h36
```

`--period block|today|week|month` picks the totals (default `today`), and `--remote`
works as above. A host that can't be reached is flagged as `⚠ name`.

### Claude Code status line

Show it at the bottom of Claude Code itself. Get the script:

```bash
curl -fsSL -o ~/.claude/claude-usage.py https://raw.githubusercontent.com/xmerik/claude-usage-plasmoid/main/package/contents/code/collect.py
```

and add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 -I ~/.claude/claude-usage.py --text"
  }
}
```

The status line refreshes often, so it's best without `--remote` (each host adds
about half a second). Parsed logs are cached, so local-only runs are fast.

### Windows

- **Claude Code inside WSL:** follow the steps above inside WSL. Nothing else is needed.
- **Claude Code on Windows itself:** use the same steps with `python` instead of
  `python3` (Python from python.org or the Microsoft Store). The logs are in
  `%USERPROFILE%\.claude` and are found automatically. `--remote` needs `ssh` on the
  PATH (Windows 10+ includes OpenSSH).
- **Both:** to read the Windows-side logs from WSL, set
  `CLAUDE_CONFIG_DIR=/mnt/c/Users/<you>/.claude`.
