# dms-meeting-pill

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar pill
showing the countdown to your next upcoming calendar event. Reads
[`khal`](https://github.com/pimutils/khal) on a timer — so it works with any
vdir-format calendar source, including [`vdirsyncer`](https://github.com/pimutils/vdirsyncer),
[`morgen-fetch`](https://github.com/joshsymonds/nix-config/tree/main/pkgs/morgen-fetch),
self-hosted CalDAV, etc.

## What it looks like

Vertical bar (default DMS):

```
🗓       ← event_upcoming (calendar with arrow into it)
12m     ← countdown to next event
```

Countdown formatting:

- `<1m` — under a minute (or already started)
- `12m` — under an hour, displayed in minutes
- `2h` — under a day, displayed in hours
- `2d` — more than a day
- `now` — start time has passed (currently happening)

Horizontal bar:

```
🗓  12m: Standup
```

All-day events (status markers like "PTO", holidays) are skipped — they're
not "meetings" you need a countdown to.

## Install

### Imperative (any DMS install)

```bash
git clone https://github.com/joshsymonds/dms-meeting-pill \
  ~/.config/DankMaterialShell/plugins/meetingPill
dms ipc call plugins reload meetingPill
```

Make sure `khal` is on `$PATH` and configured to read your calendar vdirs.

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
| `intervalMs` | `60000` | khal poll interval in milliseconds. Lower if you want the countdown closer to wall-clock accurate; higher if khal queries feel expensive. |
| `lookahead` | `"48h"` | How far ahead to scan, in any khal-accepted relative duration (`6h`, `2d`, `1w`). Events further out generally aren't actionable glance-data. |

## How it works

Every `intervalMs`:

```
khal list --json title --json start-date --json start-time --notstarted now <lookahead>
```

khal emits one JSON array per day in the range, separated by newlines.
The plugin parses each line, flattens, skips all-day events (empty
`start-time`), sorts by start, and takes the first event whose start is
in the future as "next."

A second 1-second timer reads `Date.now()` into a property the
countdown text depends on, so the displayed minute ticks down between
khal re-fetches without further polling.

## License

MIT — see [LICENSE](./LICENSE).
