# dms-meeting-pill

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar pill
showing the next upcoming calendar event — countdown, truncated title,
urgency color, and one-click join via the event's virtual-room URL.

Reads `~/.local/share/morgen-fetch/upcoming-events.json` produced by
[`morgen-fetch`](https://github.com/joshsymonds/nix-config/tree/main/pkgs/morgen-fetch).
Updates instantly when morgen-fetch writes a new snapshot (FileView with
`watchChanges`).

## What it looks like

Vertical bar (default DMS), 3 stacked rows:

```
🗓       ← event_upcoming icon, tinted by urgency
Stand…  ← title truncated to 5 chars + ellipsis
12m     ← countdown to next event
```

**Urgency coloring** (applied to icon + text):

- Normal (`>15 min` away): `Theme.widgetText` / `Theme.widgetIcon`
- Warning (`5–15 min`): `Theme.warning` (yellow)
- Error (`<5 min` or happening): `Theme.error` (red)

**Click**: if the next event has a virtual-room URL (Morgen extracts
Zoom/Meet links from event descriptions), clicking the pill invokes
`xdg-open` on it. If there's no URL, the click is a no-op.

Countdown formatting:

- `<1m` — under a minute
- `12m` — under an hour, in minutes
- `2h` — under a day, in hours
- `2d` — more than a day
- `now` — start time has passed (currently happening)

Horizontal bar:

```
🗓  12m: Standup
```

## Install

### Imperative (any DMS install)

```bash
git clone https://github.com/joshsymonds/dms-meeting-pill \
  ~/.config/DankMaterialShell/plugins/meetingPill
dms ipc call plugins reload meetingPill
```

Make sure `morgen-fetch` (or another tool producing
`~/.local/share/morgen-fetch/upcoming-events.json` in the same schema)
is running. `xdg-open` must be on `$PATH` for click-to-join to work.

### Nix flake (NixOS via the DMS home-manager module)

```nix
# flake.nix
inputs.dms-meeting-pill.url = "github:joshsymonds/dms-meeting-pill";

# home-manager
programs.dank-material-shell.plugins.meetingPill = {
  src = inputs.dms-meeting-pill.packages.${pkgs.system}.default;
  settings = {
    # intervalMs = 60000;  # default — khal poll cadence
    # lookahead = "48h";    # default — how far ahead to scan
  };
};

# And make sure khal is installed + configured. DMS's
# `enableCalendarEvents = true` already pulls khal in if you use that
# toggle.
```

## Settings

All optional.

| Key | Default | Description |
|---|---|---|
| `maxTitleChars` | `5` | Title truncation budget in the vertical pill. `5` + `…` = 6 chars; fits inside DMS's default 36px pill width at `Theme.fontSizeSmall`. Bump if you have a wider bar. |

## How it works

The plugin watches `~/.local/share/morgen-fetch/upcoming-events.json` via
`FileView { watchChanges: true }`. On each load (and on each subsequent
file change), it parses the array, finds the first event whose `start`
is in the future, and updates `nextTitle` / `nextStart` / `nextUrl` /
`haveData` properties that the QML pill content binds against.

A 1-second `Timer` updates a `countdownNow` property used by the
countdown formatter AND by the urgency-color binding, so the displayed
minute ticks down and the color escalates through warning → error as
the meeting approaches.

The click handler is wired through `PluginComponent.pillClickAction`
(BasePill's built-in click signal) — no custom MouseArea.

## License

MIT — see [LICENSE](./LICENSE).
