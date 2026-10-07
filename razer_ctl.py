#!/usr/bin/env python3
"""
Open Razer: keyboard and mouse control for the Omarchy shell, backed by the
OpenRazer daemon, plus Hyprland pointer settings for the mouse.

  razer_ctl.py status                           JSON status of every Razer device
  razer_ctl.py set-effect <dev> <effect> [--color #RRGGBB]
  razer_ctl.py set-brightness <dev> <0-100>
  razer_ctl.py set-logo <dev> on|off
  razer_ctl.py set-dpi <dev> <dpi>
  razer_ctl.py set-stage <dev> <n>
  razer_ctl.py set-stages <dev> 400,800,1600,3200,6400
  razer_ctl.py set-poll-rate <dev> <hz>
  razer_ctl.py set-idle <dev> <seconds>
  razer_ctl.py set-low-battery <dev> <percent>
  razer_ctl.py pointer-set [--sensitivity -1..1] [--accel flat|adaptive]
  razer_ctl.py pointer-apply                    re-apply saved pointer settings to Hyprland
  razer_ctl.py heal                             restart the OpenRazer daemon so it re-scans devices

<dev> is a device serial, or "keyboard" / "mouse" for the first device of that type.
Effects: static, breathing, spectrum, wave, reactive, starlight, off.

Why "heal": the OpenRazer daemon's udev listener thread dies when a device
disappears between the udev event and the daemon's sysfs lookup (a wireless
dongle re-enumerating through a hub does this a lot). Once that thread is gone
the daemon never sees new devices again. `status` compares the kernel driver's
view in sysfs with the daemon's and restarts the daemon when they disagree.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

try:
    from openrazer.client import DeviceManager, DaemonNotFound
    from openrazer.client import constants as c
except ImportError:
    DeviceManager = None

EFFECTS = ["static", "breathing", "spectrum", "wave", "reactive", "starlight", "off"]

# Single-LED zones a device can expose when it has no main Chroma surface
# (e.g. the Basilisk V3 X only lights its scroll wheel).
ZONE_ATTRS = ["scroll_wheel", "logo", "backlight", "left", "right"]

# Daemon effect names -> the plugin's effect names.
EFFECT_ALIASES = {
    "static": "static",
    "breathSingle": "breathing", "breathDual": "breathing",
    "breathTriple": "breathing", "breathRandom": "breathing", "breathMono": "breathing",
    "spectrum": "spectrum",
    "wave": "wave",
    "reactive": "reactive",
    "starlightSingle": "starlight", "starlightDual": "starlight", "starlightRandom": "starlight",
    "none": "off",
}

SYSFS_DRIVERS = ["razerkbd", "razermouse", "razeraccessory", "razerkraken"]
HEAL_INTERVAL = 120       # seconds between automatic daemon restarts
HEAL_GRACE = 10           # seconds a device may exist in sysfs before we expect the daemon to list it

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "open-razer")
RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "open-razer")
POINTER_FILE = os.path.join(CONFIG_DIR, "pointer.json")
HEAL_FILE = os.path.join(RUNTIME_DIR, "last-heal")

POINTER_DEFAULTS = {"sensitivity": 0.0, "accel": "adaptive"}


def emit(obj):
    print(json.dumps(obj))


def safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


def read_json(path, default):
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(default, dict) and isinstance(data, dict):
            merged = dict(default)
            merged.update(data)
            return merged
        return data
    except Exception:
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def parse_hex(value):
    value = (value or "#00FF00").lstrip("#")
    if len(value) != 6:
        raise ValueError("colour must be #RRGGBB")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def to_hex(raw):
    if not raw or len(raw) < 3:
        return "#00FF00"
    return "#{:02X}{:02X}{:02X}".format(raw[0], raw[1], raw[2])


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")


# ---------------------------------------------------------------------------
# Chroma surfaces
# ---------------------------------------------------------------------------

class Surface:
    """One lightable surface: the device's main Chroma matrix or a single-LED zone."""

    def __init__(self, fx, zone=None):
        self.fx = fx
        self.zone = zone

    def has(self, cap):
        # SingleLed capabilities are prefixed with the LED name (scroll_static, logo_spectrum, ...)
        return self.fx._shas(cap) if self.zone else self.fx.has(cap)

    def effects(self):
        caps = {
            "static": self.has("static"),
            "breathing": self.has("breath_single"),
            "spectrum": self.has("spectrum"),
            "wave": self.has("wave"),
            "reactive": self.has("reactive"),
            "starlight": self.has("starlight_single") or self.has("starlight_random"),
            "off": self.has("none"),
        }
        return [e for e in EFFECTS if caps[e]]

    def apply(self, effect, rgb):
        r, g, b = rgb
        if effect == "static":
            return self.fx.static(r, g, b)
        if effect == "breathing":
            return self.fx.breath_single(r, g, b)
        if effect == "spectrum":
            return self.fx.spectrum()
        if effect == "wave":
            return self.fx.wave(c.WAVE_RIGHT)
        if effect == "reactive":
            return self.fx.reactive(r, g, b, c.REACTIVE_500MS)
        if effect == "starlight":
            if self.has("starlight_single"):
                return self.fx.starlight_single(r, g, b, c.STARLIGHT_NORMAL)
            return self.fx.starlight_random(c.STARLIGHT_NORMAL)
        if effect == "off":
            return self.fx.none()
        raise ValueError("unknown effect: " + effect)


def surfaces(dev):
    main = Surface(dev.fx)
    if main.effects():
        return [main]
    zones = []
    for attr in ZONE_ATTRS:
        zone = safe(lambda: getattr(dev.fx.misc, attr))
        if zone is not None:
            s = Surface(zone, attr)
            if s.effects():
                zones.append(s)
    return zones


def brightness_targets(dev):
    """Objects exposing a writable .brightness (the device, or its lit zones)."""
    if dev.has("brightness"):
        return [dev]
    return [s.fx for s in surfaces(dev) if s.zone and s.has("brightness")]


def kind_of(dev):
    t = safe(lambda: str(dev.type), "") or ""
    return t if t in ("keyboard", "mouse") else (t or "device")


def describe(dev):
    kind = kind_of(dev)
    info = {
        "serial": str(dev.serial),
        "name": str(dev.name),
        "kind": kind,
        "effects": [],
        "effect": "",
        "color": "#00FF00",
        "brightness": None,
        "zone": "",
        "logo": None,
        "battery": None,
        "charging": False,
        "idleTime": None,
        "lowBattery": None,
        "dpi": None,
        "maxDpi": None,
        "dpiStages": [],
        "activeStage": 0,
        "pollRate": None,
        "pollRates": [],
    }

    surf = surfaces(dev)
    if surf:
        first = surf[0]
        info["effects"] = first.effects()
        info["zone"] = first.zone or ""
        raw = safe(lambda: first.fx.effect, "")
        info["effect"] = EFFECT_ALIASES.get(raw, raw)
        info["color"] = to_hex(safe(lambda: first.fx.colors, b""))

    targets = brightness_targets(dev)
    if targets:
        info["brightness"] = int(round(safe(lambda: targets[0].brightness, 0.0)))

    logo = safe(lambda: dev.fx.misc.logo)
    if logo is not None and dev.has("lighting_logo_active") and surf and not surf[0].zone:
        info["logo"] = bool(safe(lambda: logo.active, False))

    if dev.has("battery"):
        info["battery"] = safe(lambda: int(dev.battery_level))
        info["charging"] = bool(safe(lambda: dev.is_charging, False))
    if dev.has("get_idle_time"):
        info["idleTime"] = safe(lambda: int(dev.get_idle_time()))
    if dev.has("get_low_battery_threshold"):
        info["lowBattery"] = safe(lambda: int(dev.get_low_battery_threshold()))

    if dev.has("dpi"):
        dpi = safe(lambda: dev.dpi)
        info["dpi"] = int(dpi[0]) if dpi else None
        info["maxDpi"] = safe(lambda: int(dev.max_dpi))
    if dev.has("dpi_stages"):
        stages = safe(lambda: dev.dpi_stages)
        if stages:
            info["activeStage"] = int(stages[0])
            info["dpiStages"] = [int(s[0]) for s in stages[1]]
    if dev.has("poll_rate"):
        info["pollRate"] = safe(lambda: int(dev.poll_rate))
        if dev.has("supported_poll_rates"):
            info["pollRates"] = safe(lambda: list(dev.supported_poll_rates), []) or []
        if not info["pollRates"]:
            info["pollRates"] = [125, 500, 1000]

    return info


# ---------------------------------------------------------------------------
# Daemon access and self-healing
# ---------------------------------------------------------------------------

def manager():
    if DeviceManager is None:
        return None, "not-installed"
    try:
        return DeviceManager(), None
    except DaemonNotFound:
        return None, "daemon-not-running"
    except Exception as e:  # dbus errors, etc.
        return None, str(e)


def sysfs_devices():
    """Devices the kernel driver has bound, as the daemon should see them."""
    found = []
    for driver in SYSFS_DRIVERS:
        for path in glob.glob("/sys/bus/hid/drivers/{}/0003:1532:*".format(driver)):
            type_file = os.path.join(path, "device_type")
            if not os.path.exists(type_file):
                continue
            try:
                with open(type_file) as f:
                    name = f.read().strip()
                age = time.time() - os.stat(path).st_mtime
            except OSError:
                continue
            if name:
                found.append({"hid": os.path.basename(path), "name": name, "driver": driver, "age": age})
    return found


def stale_devices(daemon_names):
    """Kernel-bound devices the daemon doesn't list (older than the init grace period)."""
    return [d for d in sysfs_devices() if d["name"] not in daemon_names and d["age"] > HEAL_GRACE]


def last_heal():
    try:
        return float(open(HEAL_FILE).read().strip())
    except Exception:
        return 0.0


def heal(force=False):
    """Restart the OpenRazer daemon so it re-enumerates devices. Rate limited unless forced."""
    if not force and time.time() - last_heal() < HEAL_INTERVAL:
        return False
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    with open(HEAL_FILE, "w") as f:
        f.write(str(time.time()))
    subprocess.Popen(
        ["systemctl", "--user", "restart", "openrazer-daemon.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )
    return True


def find_device(dm, selector):
    devices = list(dm.devices)
    for dev in devices:
        if str(dev.serial) == selector:
            return dev
    for dev in devices:
        if kind_of(dev) == selector:
            return dev
    raise SystemExit("no Razer device matching '{}'".format(selector))


# ---------------------------------------------------------------------------
# razer-control write-through (keeps the laptop EC daemon's idea of keyboard
# brightness/logo in sync so it doesn't undo OpenRazer on the next AC change)
# ---------------------------------------------------------------------------

def razer_cli():
    for candidate in (
        os.environ.get("OPEN_RAZER_CLI"),
        os.path.expanduser("~/.local/share/open-razer/bin/razer-cli"),
        shutil.which("razer-cli"),
        "/usr/bin/razer-cli",
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return None


def razer_cli_write(*args):
    cli = razer_cli()
    sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "razercontrol-socket")
    if not cli or not os.path.exists(sock):
        return
    for state in ("ac", "bat"):
        safe(lambda: subprocess.run([cli, "write", args[0], state] + [str(a) for a in args[1:]],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5))


# ---------------------------------------------------------------------------
# Hyprland pointer settings
# ---------------------------------------------------------------------------

def hypr_mice():
    out = safe(lambda: subprocess.run(["hyprctl", "devices", "-j"], capture_output=True, text=True, timeout=5).stdout, "")
    data = safe(lambda: json.loads(out), {}) or {}
    return [m.get("name", "") for m in data.get("mice", []) if m.get("name")]


def pointer_targets(mouse_names):
    """Hyprland input device names that belong to the Razer mice OpenRazer reports."""
    slugs = [slug(n) for n in mouse_names if n]
    mice = hypr_mice()
    targets = [m for m in mice if any(s and s in m for s in slugs)]
    if not targets:
        targets = [m for m in mice if "razer" in m and "blade" not in m]
    return targets


def pointer_apply(settings, mouse_names):
    targets = pointer_targets(mouse_names)
    sens = max(-1.0, min(1.0, float(settings.get("sensitivity", 0.0))))
    accel = settings.get("accel", "adaptive")
    if accel not in ("flat", "adaptive"):
        accel = "adaptive"
    applied = []
    for name in targets:
        # Device names come from hyprctl, but they still go into a Lua string: allow only the
        # characters Hyprland itself produces for them.
        if not re.fullmatch(r"[A-Za-z0-9._:-]+", name):
            continue
        lua = 'hl.device({ name = "%s", sensitivity = %.3f, accel_profile = "%s" })' % (name, sens, accel)
        res = safe(lambda: subprocess.run(["hyprctl", "eval", lua], capture_output=True, text=True, timeout=5))
        if res is not None and res.returncode == 0:
            applied.append(name)
    return applied


def pointer_state(mouse_names):
    settings = read_json(POINTER_FILE, POINTER_DEFAULTS)
    return {
        "sensitivity": float(settings.get("sensitivity", 0.0)),
        "accel": settings.get("accel", "adaptive"),
        "targets": pointer_targets(mouse_names),
    }


def daemon_mouse_names(dm):
    if dm is None:
        return []
    return [str(d.name) for d in safe(lambda: list(dm.devices), []) if kind_of(d) == "mouse"]


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_status(args):
    dm, err = manager()
    if dm is None:
        emit({"daemon": False, "error": err, "devices": [], "stale": [], "healing": False,
              "pointer": pointer_state([])})
        return
    devices = []
    for dev in safe(lambda: list(dm.devices), []):
        d = safe(lambda: describe(dev))
        if d:
            devices.append(d)
    # Keyboard first, then mice, then anything else.
    order = {"keyboard": 0, "mouse": 1}
    devices.sort(key=lambda d: order.get(d["kind"], 2))

    stale = stale_devices({d["name"] for d in devices})
    healing = bool(stale) and (heal() if not args.no_heal else False)
    emit({
        "daemon": True,
        "error": None,
        "devices": devices,
        "stale": [s["name"] for s in stale],
        "healing": healing,
        "pointer": pointer_state([d["name"] for d in devices if d["kind"] == "mouse"]),
    })


def cmd_heal(_args):
    emit({"restarted": heal(force=True)})


def with_device(fn, needs=None):
    def run(args):
        dm, err = manager()
        if dm is None:
            raise SystemExit("OpenRazer unavailable: " + err)
        dev = find_device(dm, args.device)
        if needs and not dev.has(needs):
            raise SystemExit("{} does not support {}".format(dev.name, needs))
        fn(dev, args)
    return run


def requires(capability):
    return lambda fn: with_device(fn, capability)


@with_device
def cmd_set_effect(dev, args):
    rgb = parse_hex(args.color)
    applied = False
    for s in surfaces(dev):
        if args.effect in s.effects():
            applied = bool(s.apply(args.effect, rgb)) or applied
    if not applied:
        raise SystemExit("effect '{}' not supported by {}".format(args.effect, dev.name))


@with_device
def cmd_set_brightness(dev, args):
    value = float(max(0, min(100, args.value)))
    for target in brightness_targets(dev):
        target.brightness = value
    if kind_of(dev) == "keyboard":
        razer_cli_write("brightness", int(value))


@with_device
def cmd_set_logo(dev, args):
    logo = dev.fx.misc.logo
    if logo is None:
        raise SystemExit("no logo LED on " + dev.name)
    logo.active = args.state == "on"
    razer_cli_write("logo", 1 if args.state == "on" else 0)


@requires("dpi")
def cmd_set_dpi(dev, args):
    top = safe(lambda: int(dev.max_dpi), 20000)
    value = max(100, min(top, int(args.value)))
    dev.dpi = (value, value)


@requires("dpi_stages")
def cmd_set_stage(dev, args):
    active, stages = dev.dpi_stages
    n = max(1, min(len(stages), int(args.value)))
    dev.dpi_stages = (n, stages)
    x, y = stages[n - 1]
    dev.dpi = (int(x), int(y))


@requires("dpi_stages")
def cmd_set_stages(dev, args):
    top = safe(lambda: int(dev.max_dpi), 20000)
    values = []
    for part in args.values.split(","):
        part = part.strip()
        if part:
            values.append(max(100, min(top, int(part))))
    if not 1 <= len(values) <= 5:
        raise SystemExit("give between 1 and 5 DPI stages")
    active, _old = dev.dpi_stages
    active = max(1, min(len(values), int(active)))
    dev.dpi_stages = (active, [(v, v) for v in values])
    dev.dpi = (values[active - 1], values[active - 1])


@requires("poll_rate")
def cmd_set_poll_rate(dev, args):
    dev.poll_rate = int(args.value)


@requires("set_idle_time")
def cmd_set_idle(dev, args):
    dev.set_idle_time(max(60, min(900, int(args.value))))


@requires("set_low_battery_threshold")
def cmd_set_low_battery(dev, args):
    dev.set_low_battery_threshold(max(1, min(100, int(args.value))))


def cmd_pointer_set(args):
    settings = read_json(POINTER_FILE, POINTER_DEFAULTS)
    if args.sensitivity is not None:
        settings["sensitivity"] = max(-1.0, min(1.0, float(args.sensitivity)))
    if args.accel:
        settings["accel"] = args.accel
    write_json(POINTER_FILE, settings)
    dm, _err = manager()
    applied = pointer_apply(settings, daemon_mouse_names(dm))
    emit({"applied": applied, "sensitivity": settings["sensitivity"], "accel": settings["accel"]})


def cmd_pointer_apply(_args):
    settings = read_json(POINTER_FILE, POINTER_DEFAULTS)
    if not os.path.exists(POINTER_FILE):
        emit({"applied": [], "reason": "no saved pointer settings"})
        return
    dm, _err = manager()
    emit({"applied": pointer_apply(settings, daemon_mouse_names(dm))})


def main():
    p = argparse.ArgumentParser(description="Open Razer device control via OpenRazer")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status")
    s.add_argument("--no-heal", action="store_true", help="report stale devices without restarting the daemon")
    s.set_defaults(fn=cmd_status)

    sub.add_parser("heal").set_defaults(fn=cmd_heal)

    s = sub.add_parser("set-effect")
    s.add_argument("device")
    s.add_argument("effect", choices=EFFECTS)
    s.add_argument("--color", default="#00FF00")
    s.set_defaults(fn=cmd_set_effect)

    s = sub.add_parser("set-brightness")
    s.add_argument("device")
    s.add_argument("value", type=int)
    s.set_defaults(fn=cmd_set_brightness)

    s = sub.add_parser("set-logo")
    s.add_argument("device")
    s.add_argument("state", choices=["on", "off"])
    s.set_defaults(fn=cmd_set_logo)

    s = sub.add_parser("set-stages")
    s.add_argument("device")
    s.add_argument("values", help="comma separated DPI values, e.g. 400,800,1600,3200,6400")
    s.set_defaults(fn=cmd_set_stages)

    for name, fn in (("set-dpi", cmd_set_dpi), ("set-stage", cmd_set_stage), ("set-poll-rate", cmd_set_poll_rate),
                     ("set-idle", cmd_set_idle), ("set-low-battery", cmd_set_low_battery)):
        s = sub.add_parser(name)
        s.add_argument("device")
        s.add_argument("value", type=int)
        s.set_defaults(fn=fn)

    s = sub.add_parser("pointer-set")
    s.add_argument("--sensitivity", type=float, default=None)
    s.add_argument("--accel", choices=["flat", "adaptive"], default=None)
    s.set_defaults(fn=cmd_pointer_set)

    sub.add_parser("pointer-apply").set_defaults(fn=cmd_pointer_apply)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
