# Claude Code Usage (Plasma 6 widget)

Panel widget showing Claude Code token usage and estimated cost, read from the local
session logs in `~/.claude/projects/**/*.jsonl`. No network access and no credentials.

- **Panel:** tokens · ≈cost · time until the current 5-hour block resets (configurable).
- **Popup:** current 5-hour block, Today / 7 days / 30 days totals, daily bar chart,
  top projects and models.
- **Cost** is an API-equivalent estimate. Each model's $/token rate is calibrated from
  Claude Code's own `cost-state` snapshots, so no prices are hard-coded. It is not what
  a Pro/Max subscription bills.

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

## Install / update

```bash
kpackagetool6 -t Plasma/Applet -i package   # first install
kpackagetool6 -t Plasma/Applet -u package   # after changes
systemctl --user restart plasma-plasmashell # reload the QML
```

Then right-click the panel → **Add or Manage Widgets** → **Claude Code Usage**.

## Uninstall

```bash
kpackagetool6 -t Plasma/Applet -r local.claudeusage
```

The collector (`package/contents/code/collect.py`) needs only Python 3's standard
library. Run it directly to see the raw JSON. It caches parsed logs in
`~/.cache/claude-usage-plasmoid.json`.
