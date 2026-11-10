# Pulse

Adaptive performance profiles for [Omarchy](https://omarchy.org). Pulse watches
CPU temperature, load and free memory, and steps the desktop down to a lighter
profile *before* you feel the slowdown — then steps back up when the air clears.

The bar icon is a gamepad drawn at three levels of detail — solid, outlined,
switched off — so the state of the machine reads at a glance next to the clock.

```
         light            medium             full
   blur, motion, gaps   blur + dimming     everything on
      all off              only
```

## What it actually changes

Only Hyprland options, and only ones it can read back and restore exactly:

| Option | Light | Medium | Full |
|---|---|---|---|
| `decoration:blur:enabled` | off | off | as you had it |
| `decoration:dim_inactive` | off | off | as you had it |
| `animations:enabled` | off | as you had it | as you had it |
| `general:gaps_out` | 4 | as you had it | as you had it |
| `decoration:rounding` | 0 | as you had it | as you had it |

The two steps differ in kind rather than degree. Medium drops the expensive
per-pixel decoration and leaves movement alone, so the desktop still feels like
itself. Light removes motion and spacing, which is the step you notice
immediately and the reason it is reserved for actual pressure.

Nothing outside your user session is touched: no sudo, no sysctl, no governor,
no GPU knobs. If you want thermal limits raised at the kernel level, that is a
different tool with a different risk profile.

## Why the logic lives in Python, not QML

A threshold that changes what your desktop looks like belongs somewhere it can
be tested from a shell and reasoned about on its own. So `bin/pulse-ctl` owns
every decision, and `Panel.qml` only draws what the daemon reports:

- the daemon writes a snapshot file once per tick;
- the panel watches that file with `FileView`;
- the widget spawns no process on a timer and costs nothing while closed.

That also means the whole thing works if the shell restarts, and it can be
driven entirely from a terminal if the panel is not to your taste.

## Install

```bash
git clone https://github.com/ShapesV/omarchy-pulse
cd omarchy-pulse
./install.sh
omarchy plugin enable io.github.shapesv.pulse
```

`install.sh` copies the checkout into `~/.config/omarchy/plugins/`, installs the
user unit, and starts the daemon. For hacking on a checkout, `./install.sh
--link` symlinks it instead so edits apply immediately.

Uninstall, restoring the desktop first:

```bash
./install.sh --remove
```

## Commands

Commands never write state. The daemon owns `state.json` and rewrites it every
tick; a command that wrote alongside it would be overwritten within two seconds,
so clicks would appear to do nothing. Instead a command drops a request in
`$XDG_RUNTIME_DIR/omarchy-pulse/request.json` and the daemon carries it out
inside its own loop, on its next tick.

```bash
pulse-ctl status             what it thinks right now
pulse-ctl profile light      pin a profile; adaptation stops
pulse-ctl profile full       back to everything on
pulse-ctl enable on|off      turn adaptation on or off
pulse-ctl stop               release the desktop to its baseline
pulse-ctl tick               one decision cycle, for testing
```

(`pulse-ctl` lives in `bin/` inside the plugin directory; there is no PATH
entry, deliberately — this is not a general-purpose tool.)

The daemon runs as `pulse.service` in your user session:

```bash
systemctl --user status pulse
journalctl --user -u pulse -f
```

It logs one line per profile change and nothing else.

## Configuration

`~/.config/omarchy-pulse/config.json`, created on first change. Absent keys fall
back to `config/default.json`.

```jsonc
{
  "enabled": true,
  "pollInterval": 2.0,
  "hysteresis": 3,        // consecutive ticks before a change is allowed
  "holdSeconds": 20,      // minimum time before stepping back up
  "tickers": {
    "thermal": { "enabled": true, "thresholdPath": "", "lightAbove": 88, "mediumAbove": 75 },
    "load":    { "enabled": true, "lightAbove": 2.0, "mediumAbove": 1.4 },
    "memory":  { "enabled": true, "lightBelow": 8, "mediumBelow": 18 }
  }
}
```

Thresholds are named after the profile they ask for, so there is no comparing a
"light" number against a "medium" number and getting the comparison backwards.
Temperature is °C. Load is normalised per thread, so one threshold set works on
a 4-thread laptop and a 32-thread desktop. Memory thresholds are percentages of
*available* memory, and they are the one place where lower is worse.

`thresholdPath` empty means "find a CPU temperature sensor yourself": Pulse
walks `/sys/class/hwmon` looking for k10temp/coretemp/zenpower, because the
`hwmonN` numbering is probe-order dependent and changes across reboots.

### Tuning the thermal threshold

The defaults are conservative on purpose. On a laptop with an aggressive
cooling curve, 88 °C may never be reached and light mode may never engage —
which is fine, that is the system working. If you want Pulse to react sooner,
lower `lightAbove`; if it thrashes, raise `hysteresis` rather than the
threshold.

## Safety

- The pre-Pulse desktop is captured once, before anything is written, and every
  downgrade is a move *back* to that capture — not to a hardcoded default.
- `stop`, the unit's `ExecStopPost`, and the daemon's own `finally` block all
  restore it. A crash mid-tick leaves at most one option moved for one tick.
- A missing sensor is skipped, never guessed; the panel shows it as
  `unavailable` and the other tickers keep working.
- If the daemon is not running, the panel says so instead of drawing a
  confident temperature from ten minutes ago.

## Tests

```bash
python3 -m pytest tests/ -q
```

The decision logic and the Lua literal writer are covered; the QML is not,
because a headless test of a layer-shell panel is more scaffolding than it is
worth.

## License

MIT