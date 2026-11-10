// Pure helpers for Pulse. Locale-free, QML-type-free where it can be, so the
// parsing and formatting can be exercised from a plain JS runtime.

function pluginId() {
  return "io.github.USERNAME.pulse"
}

function pluginDir() {
  // Quickshell gives us no __dirname, and the plugin directory is fixed by
  // the manifest id, so building it from HOME is the honest way to find our
  // own files.
  return String(Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + pluginId()
}

function stateDir() {
  var base = String(Quickshell.env("XDG_STATE_HOME") || "")
  if (base === "") base = String(Quickshell.env("HOME") || "") + "/.local/state"
  return base + "/omarchy-pulse"
}

function snapshotPath() {
  return stateDir() + "/snapshot.json"
}

function pythonBinary() {
  return "/usr/bin/python3"
}

// Glyph per profile: one gamepad, drawn at three levels of detail, because
// that is what the widget is about — how much of the machine the frame gets.
//
//   full    solid gamepad         everything the compositor can give is on
//   medium  outlined gamepad      decoration dropped, motion kept
//   light   gamepad switched off  the flat, everything-off step
//   stale   crossed gamepad       the daemon is not running; a frozen
//                                 reading would be a lie, so say so
//
// All three are Material gamepad glyphs confirmed present in
// JetBrainsMono Nerd Font, which the bar reaches through the
// omarchy-font-set alias.
var GLYPH_FULL = "\u{F0296}"    // md-gamepad
var GLYPH_MEDIUM = "\u{F0297}"  // md-gamepad_variant (outlined)
var GLYPH_LIGHT = "\u{F02B5}"   // md-google_controller_off
var GLYPH_STALE = "\u{F00D}"    // nf-fa-times

function profileGlyph(profile, enabled, fresh) {
  if (enabled === false || fresh === false) return GLYPH_STALE
  if (profile === "light") return GLYPH_LIGHT
  if (profile === "medium") return GLYPH_MEDIUM
  return GLYPH_FULL
}

// Tooltip on the bar button. Short: it is read at a glance, not studied.
function barTooltip(profile, temp, enabled, fresh) {
  if (fresh === false) return "Pulse: no data"
  var label = String(profile || "full")
  if (enabled === false) return "Pulse: pinned " + label
  if (typeof temp === "number" && isFinite(temp) && temp >= 0) {
    return "Pulse: " + label + " · " + Math.round(temp) + " °C"
  }
  return "Pulse: " + label
}

function emptyStatus() {
  return {
    applied: "full",
    evaluated: "full",
    configured: "medium",
    enabled: true,
    reasons: [],
    temp: null,
    history: [],
    sensors: {},
    hyprland: false,
    lastChanged: [],
    updated: 0
  }
}

var PROFILES = ["light", "medium", "full"]

function clampProfile(value) {
  var name = String(value || "")
  return PROFILES.indexOf(name) >= 0 ? name : "medium"
}

// The daemon writes every pollInterval; if the file has not moved in a while
// the service is down, and the panel should say so instead of drawing a
// confident temperature from ten minutes ago.
var STALE_SECONDS = 15

function isFresh(status) {
  var updated = Number(status && status.updated)
  if (!isFinite(updated) || updated <= 0) return false
  return (Date.now() / 1000 - updated) < STALE_SECONDS
}

// Parse one snapshot payload. Anything unexpected is reported rather than
// half-trusted, so the panel can say plainly that it does not know.
function parseSnapshot(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "empty snapshot", status: emptyStatus() }

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "unparsable snapshot", status: emptyStatus() }
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { ok: false, error: "unexpected snapshot", status: emptyStatus() }
  }

  var status = emptyStatus()
  status.applied = clampProfile(data.profile)
  status.evaluated = clampProfile(data.evaluated)
  status.configured = clampProfile(data.configured)
  status.enabled = data.enabled !== false
  // Reasons come from our own daemon, but they are still bounded before they
  // reach a text sink: length first, content second.
  status.reasons = Array.isArray(data.reasons)
    ? data.reasons.slice(0, 6).map(function(item) { return String(item).slice(0, 80) })
    : []
  status.temp = typeof data.temp === "number" && isFinite(data.temp) ? data.temp : null
  status.history = Array.isArray(data.history)
    ? data.history.slice(-40).map(Number).filter(function(v) { return isFinite(v) })
    : []
  status.sensors = (data.sensors && typeof data.sensors === "object") ? data.sensors : {}
  status.hyprland = data.hyprland === true
  status.lastChanged = Array.isArray(data.lastChanged) ? data.lastChanged.map(String) : []
  status.updated = Number(data.updated) || 0
  return { ok: true, error: "", status: status }
}

// Rows for the three profile switches, already formatted. Fixed length and
// fixed order, built from local catalogue strings only.
function profileRows(status, fresh, strings) {
  var configured = clampProfile(status && status.configured)

  function row(id, labelKey, hintKey) {
    return {
      id: id,
      label: strings.t(labelKey),
      hint: strings.t(hintKey),
      // The switch shows what the config asks for. The headline shows what
      // the sensors actually got. Keeping them apart is the whole point of
      // the panel: one is a decision, the other is a reading.
      checked: configured === id
    }
  }

  return [
    row("light", "pulse.profile.light", "pulse.hint.light"),
    row("medium", "pulse.profile.medium", "pulse.hint.medium"),
    row("full", "pulse.profile.full", "pulse.hint.full")
  ]
}

// Rows for the sensor block, already formatted. `strings` is the plugin's
// Translations object, so every label and unit goes through the catalogue.
function sensorRows(status, strings) {
  var sensors = (status && status.sensors) || {}

  function formatEntry(entry, unit) {
    if (!entry || entry.available !== true || typeof entry.value !== "number") {
      return strings.t("pulse.sensor.missing")
    }
    if (unit === "%") return Commons.I18n.formatNumber(entry.value, 0) + "%"
    if (unit === "C") return Commons.I18n.formatNumber(entry.value, 0) + " °C"
    return Commons.I18n.formatNumber(entry.value, 2)
  }

  function ok(entry) {
    return !!(entry && entry.available === true && typeof entry.value === "number")
  }

  var thermal = sensors.thermal
  var load = sensors.load
  var memory = sensors.memory

  return [
    { label: strings.t("pulse.sensor.thermal"), value: formatEntry(thermal, "C"), ok: ok(thermal) },
    { label: strings.t("pulse.sensor.load"), value: formatEntry(load, ""), ok: ok(load) },
    { label: strings.t("pulse.sensor.memory"), value: formatEntry(memory, "%"), ok: ok(memory) },
    {
      label: strings.t("pulse.sensor.hyprland"),
      value: status && status.hyprland ? strings.t("pulse.sensor.connected") : strings.t("pulse.sensor.missing"),
      ok: !!(status && status.hyprland)
    }
  ]
}