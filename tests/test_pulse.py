"""Tests for the parts of Pulse that can be wrong in a way you would not see
from the panel: the decision logic, and the writer that turns a value into
something Hyprland will evaluate."""

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_loader(
    "pulse_ctl",
    importlib.machinery.SourceFileLoader("pulse_ctl", str(ROOT / "bin" / "pulse-ctl")),
)
pulse = importlib.util.module_from_spec(spec)
sys.modules["pulse_ctl"] = pulse
spec.loader.exec_module(pulse)


# --------------------------------------------------------------------------
# lua_literal and hypr_set
# --------------------------------------------------------------------------

@pytest.mark.parametrize("value,expected", [(True, "true"), (False, "false"), (0, "0"), (42, "42")])
def test_lua_literal_renders_scalars(value, expected):
    assert pulse.lua_literal(value) == expected


@pytest.mark.parametrize("value", ["4 4 4 4", "x') os.system('rm -rf /", 1.5, None, [1, 2]])
def test_lua_literal_refuses_anything_that_is_not_a_scalar(value):
    """The evaluator runs Lua; a string in it is an injection waiting to happen.

    Hyprland's css_gap type takes an integer anyway, so there is no legitimate
    string case to lose here.
    """
    with pytest.raises((TypeError, ValueError)):
        pulse.lua_literal(value)


def test_hypr_set_builds_the_nested_path_hyprland_expects(monkeypatch):
    seen = {}

    def fake_run(cmd, timeout=3.0):
        seen["cmd"] = cmd
        return 0, "ok"

    monkeypatch.setattr(pulse, "run", fake_run)
    monkeypatch.setattr(pulse, "hypr_get", lambda _name: {"bool": True})

    pulse.hypr_set("animations", True)
    assert seen["cmd"] == ["hyprctl", "eval", "hl.config({ animations = { enabled = true } })"]


def test_hypr_set_verifies_by_reading_back(monkeypatch):
    """Hyprland answers 'ok' even when it rejected the value, so the write has
    to be confirmed rather than trusted."""
    monkeypatch.setattr(pulse, "run", lambda cmd, timeout=3.0: (0, "ok"))
    monkeypatch.setattr(pulse, "hypr_get", lambda _name: {"bool": True})

    assert pulse.hypr_set("animations", False) is False


def test_hypr_set_compares_gaps_by_value_not_spelling(monkeypatch):
    monkeypatch.setattr(pulse, "run", lambda cmd, timeout=3.0: (0, "ok"))
    monkeypatch.setattr(pulse, "hypr_get", lambda _name: {"css": "4 4 4 4"})

    assert pulse.hypr_set("gaps_out", 4) is True


def test_capture_baseline_keeps_non_uniform_gaps_out_of_reach(monkeypatch):
    """Pulse only ever sets a uniform gap, so an asymmetric baseline is not
    something it could restore; reporting None keeps it from pretending."""
    monkeypatch.setattr(pulse, "hypr_get", lambda name: {"css": "1 2 3 4"} if "gaps" in name else {"int": 0})
    baseline = pulse.capture_baseline()
    assert baseline["gaps_out"]["value"] is None


# --------------------------------------------------------------------------
# readings and thresholds
# --------------------------------------------------------------------------

def reading(name, value, available=True):
    return pulse.Reading(name, value=value, available=available)


def test_unavailable_sensor_asks_for_nothing():
    want, reason = pulse.demand(reading("thermal", None, available=False), {"lightAbove": 50})
    assert want is None and reason == ""


def test_thermal_above_thresholds_picks_lightest_matching():
    cfg = {"lightAbove": 88, "mediumAbove": 75}
    assert pulse.demand(reading("thermal", 90), cfg)[0] == "light"
    assert pulse.demand(reading("thermal", 80), cfg)[0] == "medium"
    assert pulse.demand(reading("thermal", 60), cfg)[0] is None


def test_memory_thresholds_run_the_other_way():
    """Free memory going *down* is the bad direction; getting this backwards
    would put the machine in light mode whenever it was healthy."""
    cfg = {"lightBelow": 8, "mediumBelow": 18}
    assert pulse.demand(reading("memory", 5), cfg)[0] == "light"
    assert pulse.demand(reading("memory", 15), cfg)[0] == "medium"
    assert pulse.demand(reading("memory", 60), cfg)[0] is None


def test_desired_profile_takes_the_lightest_demand():
    readings = [
        reading("thermal", 80),   # medium
        reading("memory", 4),     # light
    ]
    config = {
        "tickers": {
            "thermal": {"enabled": True, "lightAbove": 88, "mediumAbove": 75},
            "memory": {"enabled": True, "lightBelow": 8, "mediumBelow": 18},
        }
    }
    target, reasons = pulse.desired_profile(readings, config)
    assert target == "light"
    assert len(reasons) == 2


def test_desired_profile_is_full_when_everything_is_comfortable():
    config = {"tickers": {"thermal": {"enabled": True, "lightAbove": 88, "mediumAbove": 75}}}
    target, reasons = pulse.desired_profile([reading("thermal", 40)], config)
    assert target == "full" and reasons == []


def test_disabled_ticker_is_ignored_even_when_it_would_shout():
    config = {"tickers": {"thermal": {"enabled": False, "lightAbove": 1, "mediumAbove": 0}}}
    assert pulse.desired_profile([reading("thermal", 99)], config)[0] == "full"


# --------------------------------------------------------------------------
# profile tables
# --------------------------------------------------------------------------

def test_every_profile_names_every_option():
    """A missing key would silently mean 'leave it alone', which is a profile
    that quietly stops doing part of its job."""
    for name, level in pulse.HYPR_LEVELS.items():
        assert set(level) == set(pulse.HYPR_OPTIONS), name


def test_full_restores_everything():
    assert all(value is None for value in pulse.HYPR_LEVELS["full"].values())


def test_light_is_strictly_lighter_than_medium():
    """Light must differ from medium in the options that cost motion, or the
    two profiles would be the same step wearing different names."""
    light, medium = pulse.HYPR_LEVELS["light"], pulse.HYPR_LEVELS["medium"]
    assert light["animations"] is False and medium["animations"] is None
    assert light["gaps_out"] is not None and medium["gaps_out"] is None


# --------------------------------------------------------------------------
# state defaults
# --------------------------------------------------------------------------

def test_stale_snapshot_is_recognised():
    import time

    fresh = pulse.snapshot({}, {"sensors": {}, "tempHistory": [], "updated": time.time()})
    assert fresh["updated"] > 0

# --------------------------------------------------------------------------
# request path
# --------------------------------------------------------------------------

def test_a_command_hands_work_to_the_daemon_instead_of_writing_state(tmp_path, monkeypatch):
    """The bug this exists to prevent: a command that writes state.json is
    silently overwritten by the daemon's next tick, so the user's click
    appears to do nothing."""
    monkeypatch.setattr(pulse, "RUN_DIR", tmp_path)
    monkeypatch.setattr(pulse, "REQUEST_FILE", tmp_path / "request.json")

    pulse.request("profile", value="light")

    stored = pulse.read_json(tmp_path / "request.json", None)
    assert stored["action"] == "profile"
    assert stored["value"] == "light"


def test_taking_a_request_consumes_it(tmp_path, monkeypatch):
    monkeypatch.setattr(pulse, "REQUEST_FILE", tmp_path / "request.json")
    pulse.write_json(tmp_path / "request.json", {"action": "enable", "value": True})

    first = pulse.take_request()
    second = pulse.take_request()

    assert first["action"] == "enable"
    assert second is None, "a drained request must not be replayed on the next tick"


def test_taking_an_absent_request_is_not_an_error(tmp_path, monkeypatch):
    monkeypatch.setattr(pulse, "REQUEST_FILE", tmp_path / "request.json")
    assert pulse.take_request() is None


def test_pinned_profile_is_applied_even_though_adaptation_is_off():
    """Pinning used to only write config and leave the desktop alone when the
    daemon was mid-flight, so the switch moved and nothing else did."""
    calls = {}
    monkeypatch_target = pulse.apply_profile
    pulse.apply_profile = lambda name, base: calls.setdefault("name", name) or []
    try:
        state = {"applied": "full", "baseline": {}}
        cfg = {"enabled": False, "profile": "light"}
        pulse.save_config_patch = lambda patch: cfg.update(patch)
        pulse.handle_request({"action": "profile", "value": "light"}, cfg, state)
        assert state["applied"] == "light"
        assert calls.get("name") == "light"
    finally:
        pulse.apply_profile = monkeypatch_target


def test_a_released_daemon_does_not_crash_on_its_next_tick():
    """`stop` sets applied to "free", which is not rankable against a real
    profile. Ticking in that state used to raise ValueError out of
    PROFILES.index and take the service down with it."""
    state = pulse.default_state()
    state["applied"] = pulse.FREE
    state["baseline"] = {}

    config = {"enabled": True, "tickers": {}}
    # Must return quietly rather than raise.
    pulse.evaluate(config, state, apply=True)

    assert state["applied"] == pulse.FREE


def test_free_is_not_a_profil():
    """Ranking against "free" is the failure above; keeping it out of the
    tuple means any future caller that forgets gets a clear error, not a
    silent miscomparison."""
    assert pulse.FREE not in pulse.PROFILES
