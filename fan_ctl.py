#!/usr/bin/env python3
"""
Open Razer fan and power control for Razer Blade laptops.

Talks to the razer-control-revived daemon (userspace HID driver for the Blade's
embedded controller) through its `razer-cli`, reads temperatures from hwmon and
nvidia-smi, and runs the temperature curve as a small user service.

  fan_ctl.py status                        JSON: fan RPM, temps, mode, curve, power profile, backend state
  fan_ctl.py set-mode auto|manual|curve
  fan_ctl.py set-manual <duty 0-100>       fan duty as a percentage of the EC's RPM range
  fan_ctl.py set-curve 40:30,55:40,65:60,75:80,85:100
  fan_ctl.py set-source cpu|gpu|max        which temperature drives the curve
  fan_ctl.py set-power <0-4> [cpu 0-3] [gpu 0-2]   0 Balanced, 1 Gaming, 2 Creator, 3 Silent, 4 Custom
  fan_ctl.py apply                         push the configured mode to the EC once
  fan_ctl.py serve                         run the curve loop (used by the systemd user service)
  fan_ctl.py install-service               create + enable the open-razer-fan user service
  fan_ctl.py uninstall-service

Modes: `auto` hands fan control back to the EC. `manual` pins one duty. `curve`
needs the service running: every few seconds it maps the chosen temperature
through the curve and writes the matching RPM. If the service stops while in
curve mode it hands control back to the EC on the way out.
"""

import argparse
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "open-razer")
CONFIG_FILE = os.path.join(CONFIG_DIR, "fans.json")
RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "open-razer")
STATUS_FILE = os.path.join(RUNTIME_DIR, "fan-status.json")
SOCKET = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "razercontrol-socket")
SERVICE_NAME = "open-razer-fan.service"
SERVICE_FILE = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                            "systemd", "user", SERVICE_NAME)

DEFAULT_CONFIG = {
    "mode": "auto",
    "manualDuty": 50,
    "curve": [[40, 30], [55, 40], [65, 60], [75, 80], [85, 100]],
    "source": "cpu",
    "interval": 3,
}

# EC fan range fallback when laptops.json can't be found. The daemon clamps
# anyway, so a wrong guess only affects what "100%" means in the UI.
FAN_RANGE_FALLBACK = [3500, 5000]
RPM_STEP = 50          # resolution we write at
RPM_DEADBAND = 100     # don't chase the curve for changes smaller than this

POWER_MODES = ["Balanced", "Gaming", "Creator", "Silent", "Custom"]
CPU_BOOST = ["Low", "Medium", "High", "Boost"]
GPU_BOOST = ["Low", "Medium", "High"]


def emit(obj):
    print(json.dumps(obj))


def safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        if isinstance(data, dict):
            cfg.update(data)
    except Exception:
        pass
    cfg["curve"] = normalise_curve(cfg.get("curve"))
    cfg["manualDuty"] = clamp(int(cfg.get("manualDuty", 50)), 0, 100)
    if cfg.get("mode") not in ("auto", "manual", "curve"):
        cfg["mode"] = "auto"
    if cfg.get("source") not in ("cpu", "gpu", "max"):
        cfg["source"] = "cpu"
    cfg["interval"] = clamp(int(cfg.get("interval", 3)), 2, 30)
    return cfg


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CONFIG_FILE)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def normalise_curve(points):
    out = []
    for p in points or []:
        try:
            t, d = int(p[0]), int(p[1])
        except Exception:
            continue
        out.append([clamp(t, 20, 100), clamp(d, 0, 100)])
    out.sort(key=lambda p: p[0])
    # Duty must never fall as temperature rises.
    for i in range(1, len(out)):
        out[i][1] = max(out[i][1], out[i - 1][1])
    return out or [list(p) for p in DEFAULT_CONFIG["curve"]]


def parse_curve(text):
    points = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        t, d = part.split(":")
        points.append([int(t), int(d)])
    return normalise_curve(points)


def curve_duty(curve, temp):
    """Linear interpolation across the curve, clamped at both ends."""
    if temp is None or not curve:
        return None
    if temp <= curve[0][0]:
        return curve[0][1]
    if temp >= curve[-1][0]:
        return curve[-1][1]
    for (t0, d0), (t1, d1) in zip(curve, curve[1:]):
        if t0 <= temp <= t1:
            if t1 == t0:
                return d1
            return d0 + (d1 - d0) * (temp - t0) / float(t1 - t0)
    return curve[-1][1]


def duty_to_rpm(duty, fan_range):
    lo, hi = fan_range
    rpm = lo + (hi - lo) * clamp(float(duty), 0.0, 100.0) / 100.0
    return int(round(rpm / RPM_STEP) * RPM_STEP)


def rpm_to_duty(rpm, fan_range):
    lo, hi = fan_range
    if hi <= lo:
        return 0
    return int(round(clamp((rpm - lo) * 100.0 / (hi - lo), 0, 100)))


# ---------------------------------------------------------------------------
# razer-cli
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


def backend_state():
    if not razer_cli():
        return "no-cli"
    if not os.path.exists(SOCKET):
        return "no-daemon"
    return "ok"


def cli(*args, timeout=5):
    """Run razer-cli and return its last meaningful stdout line (it prints debug 'RES:' lines first)."""
    exe = razer_cli()
    if not exe:
        return None
    try:
        res = subprocess.run([exe] + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    lines = [l.strip() for l in res.stdout.splitlines() if l.strip() and not l.startswith("RES:")]
    if res.returncode != 0 and not lines:
        return None
    return lines[-1] if lines else ""


def ac_state():
    for path in glob.glob("/sys/class/power_supply/AC*/online") + glob.glob("/sys/class/power_supply/ADP*/online"):
        try:
            return open(path).read().strip() == "1"
        except OSError:
            pass
    return True


def state_word():
    return "ac" if ac_state() else "bat"


def read_fan_setting(state):
    """Configured RPM (0 = auto), or None when unknown."""
    out = cli("read", "fan", state)
    if out is None:
        return None
    if "Auto" in out:
        return 0
    m = re.search(r"(\d+)\s*RPM", out)
    return int(m.group(1)) if m else None


def read_fan_rpm():
    out = cli("read", "fan-rpm")
    if out is None:
        return None
    m = re.search(r"-?\d+", out)
    if not m:
        return None
    rpm = int(m.group(0))
    return rpm if rpm >= 0 else None


def read_power(state):
    exe = razer_cli()
    if not exe:
        return None
    try:
        res = subprocess.run([exe, "read", "power", state], capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    info = {"mode": None, "modeName": "", "cpu": None, "gpu": None}
    for line in res.stdout.splitlines():
        m = re.search(r"Current power setting:\s*(\w+)", line)
        if m and m.group(1) in POWER_MODES:
            info["mode"] = POWER_MODES.index(m.group(1))
            info["modeName"] = m.group(1)
        m = re.search(r"Current CPU setting:\s*(\w+)", line)
        if m and m.group(1) in CPU_BOOST:
            info["cpu"] = CPU_BOOST.index(m.group(1))
        m = re.search(r"Current GPU setting:\s*(\w+)", line)
        if m and m.group(1) in GPU_BOOST:
            info["gpu"] = GPU_BOOST.index(m.group(1))
    return info if info["mode"] is not None else None


def write_fan(rpm, states=("ac", "bat")):
    ok = True
    for st in states:
        out = cli("write", "fan", st, int(rpm))
        ok = ok and out is not None
    return ok


# ---------------------------------------------------------------------------
# Laptop identity and fan range
# ---------------------------------------------------------------------------

def laptop_pid():
    for path in glob.glob("/sys/bus/hid/devices/0003:1532:*"):
        pid = os.path.basename(path).split(":")[2].split(".")[0].upper()
        # Blade control interfaces live in the keyboard-ish 02xx range; mice are 00xx.
        if pid.startswith("02") or pid.startswith("01"):
            return pid
    return None


def laptops_file():
    for candidate in (
        os.environ.get("RAZER_DEVICE_FILE"),
        os.path.expanduser("~/.local/share/open-razer/laptops.json"),
        "/usr/share/razercontrol/laptops.json",
    ):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def laptop_info():
    pid = laptop_pid()
    info = {"pid": pid, "name": "Razer Blade", "fanRange": list(FAN_RANGE_FALLBACK), "features": []}
    path = laptops_file()
    if not path or not pid:
        return info
    try:
        for entry in json.load(open(path)):
            if str(entry.get("pid", "")).upper() == pid:
                info["name"] = entry.get("name", info["name"])
                fan = entry.get("fan")
                if isinstance(fan, list) and len(fan) == 2 and fan[1] > fan[0]:
                    info["fanRange"] = [int(fan[0]), int(fan[1])]
                info["features"] = list(entry.get("features", []))
                break
    except Exception:
        pass
    return info


# ---------------------------------------------------------------------------
# Temperatures
# ---------------------------------------------------------------------------

def hwmon_by_name():
    found = {}
    for path in glob.glob("/sys/class/hwmon/hwmon*"):
        name = safe(lambda: open(os.path.join(path, "name")).read().strip(), "")
        if name:
            found.setdefault(name, path)
    return found


def read_temp(path):
    try:
        return int(open(path).read().strip()) / 1000.0
    except Exception:
        return None


def cpu_temp():
    mons = hwmon_by_name()
    for name in ("coretemp", "k10temp", "zenpower", "acpitz"):
        if name in mons:
            # temp1 is "Package id 0" on Intel and "Tctl" on AMD; fall back to the hottest core.
            temps = [read_temp(p) for p in sorted(glob.glob(os.path.join(mons[name], "temp*_input")))]
            temps = [t for t in temps if t is not None]
            if temps:
                return temps[0] if name != "acpitz" else max(temps)
    return None


def gpu_runtime_active():
    for dev in glob.glob("/sys/bus/pci/devices/*"):
        vendor = safe(lambda: open(os.path.join(dev, "vendor")).read().strip(), "")
        cls = safe(lambda: open(os.path.join(dev, "class")).read().strip(), "")
        if vendor == "0x10de" and cls.startswith("0x03"):
            status = safe(lambda: open(os.path.join(dev, "power", "runtime_status")).read().strip(), "active")
            return status == "active"
    return False


def gpu_temp():
    """NVIDIA temperature, only while the GPU is awake: polling nvidia-smi would otherwise keep it powered on."""
    if not shutil.which("nvidia-smi") or not gpu_runtime_active():
        return None
    out = safe(lambda: subprocess.run(
        ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
        capture_output=True, text=True, timeout=3).stdout, "")
    m = re.search(r"\d+", out or "")
    return float(m.group(0)) if m else None


def temperatures():
    cpu = cpu_temp()
    gpu = gpu_temp()
    both = [t for t in (cpu, gpu) if t is not None]
    return {"cpu": cpu, "gpu": gpu, "max": max(both) if both else None}


def source_temp(temps, source):
    t = temps.get(source)
    if t is None:
        t = temps.get("cpu") if temps.get("cpu") is not None else temps.get("max")
    return t


# ---------------------------------------------------------------------------
# Target computation
# ---------------------------------------------------------------------------

def target_rpm(cfg, temps, fan_range):
    """RPM the EC should be told to run (0 = auto), plus the duty it corresponds to."""
    if cfg["mode"] == "manual":
        duty = cfg["manualDuty"]
        return duty_to_rpm(duty, fan_range), duty
    if cfg["mode"] == "curve":
        duty = curve_duty(cfg["curve"], source_temp(temps, cfg["source"]))
        if duty is None:
            return 0, None
        return duty_to_rpm(duty, fan_range), int(round(duty))
    return 0, None


def service_state():
    if not os.path.exists(SERVICE_FILE):
        return "missing"
    out = safe(lambda: subprocess.run(["systemctl", "--user", "is-active", SERVICE_NAME],
                                      capture_output=True, text=True, timeout=5).stdout.strip(), "")
    return out or "inactive"


def build_status(cfg=None):
    cfg = cfg or load_config()
    backend = backend_state()
    laptop = laptop_info()
    temps = temperatures()
    st = state_word()
    status = {
        "backend": backend,
        "cli": razer_cli(),
        "laptop": laptop["name"],
        "pid": laptop["pid"],
        "fanRange": laptop["fanRange"],
        "ac": st == "ac",
        "temps": temps,
        "temp": source_temp(temps, cfg["source"]),
        "mode": cfg["mode"],
        "manualDuty": cfg["manualDuty"],
        "curve": cfg["curve"],
        "source": cfg["source"],
        "interval": cfg["interval"],
        "service": service_state(),
        "rpm": None,
        "setting": None,
        "settingDuty": None,
        "targetRpm": None,
        "targetDuty": None,
        "power": None,
    }
    rpm, duty = target_rpm(cfg, temps, laptop["fanRange"])
    status["targetRpm"] = rpm
    status["targetDuty"] = duty
    if backend == "ok":
        status["rpm"] = read_fan_rpm()
        status["setting"] = read_fan_setting(st)
        if status["setting"]:
            status["settingDuty"] = rpm_to_duty(status["setting"], laptop["fanRange"])
        status["power"] = read_power(st)
    return status


def write_status_file(status):
    try:
        os.makedirs(RUNTIME_DIR, exist_ok=True)
        tmp = STATUS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(status, f)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_status(_args):
    emit(build_status())


def apply_once(cfg, fan_range=None, last=None):
    """Push the configured mode to the EC. Returns the RPM written (or None if nothing changed)."""
    fan_range = fan_range or laptop_info()["fanRange"]
    rpm, _duty = target_rpm(cfg, temperatures(), fan_range)
    if cfg["mode"] == "curve" and last is not None and abs(rpm - last) < RPM_DEADBAND:
        return None
    current = read_fan_setting(state_word())
    if current == rpm and last is not None:
        return None
    write_fan(rpm)
    return rpm


def require_backend():
    state = backend_state()
    if state != "ok":
        raise SystemExit("fan backend unavailable: " + state)


def cmd_set_mode(args):
    cfg = load_config()
    cfg["mode"] = args.mode
    save_config(cfg)
    require_backend()
    apply_once(cfg)
    emit({"mode": cfg["mode"]})


def cmd_set_manual(args):
    cfg = load_config()
    cfg["manualDuty"] = clamp(int(args.duty), 0, 100)
    if args.switch:
        cfg["mode"] = "manual"
    save_config(cfg)
    if cfg["mode"] == "manual":
        require_backend()
        apply_once(cfg)
    emit({"mode": cfg["mode"], "manualDuty": cfg["manualDuty"]})


def cmd_set_curve(args):
    cfg = load_config()
    cfg["curve"] = parse_curve(args.curve)
    if args.switch:
        cfg["mode"] = "curve"
    save_config(cfg)
    if cfg["mode"] == "curve":
        require_backend()
        apply_once(cfg)
    emit({"mode": cfg["mode"], "curve": cfg["curve"]})


def cmd_set_source(args):
    cfg = load_config()
    cfg["source"] = args.source
    save_config(cfg)
    emit({"source": cfg["source"]})


def cmd_set_power(args):
    require_backend()
    st = state_word()
    cmd = ["write", "power", st, clamp(int(args.mode), 0, 4)]
    if int(args.mode) == 4:
        cmd += [clamp(int(args.cpu if args.cpu is not None else 1), 0, 3),
                clamp(int(args.gpu if args.gpu is not None else 0), 0, 2)]
    else:
        cmd += [0, 0]
    cli(*cmd)
    emit({"power": read_power(st)})


def cmd_apply(_args):
    require_backend()
    cfg = load_config()
    emit({"mode": cfg["mode"], "rpm": apply_once(cfg)})


def cmd_serve(_args):
    stop = {"flag": False}

    def on_signal(_sig, _frame):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    last_rpm = None
    last_mode = None
    last_mtime = None
    fan_range = laptop_info()["fanRange"]
    while not stop["flag"]:
        cfg = load_config()
        mtime = safe(lambda: os.stat(CONFIG_FILE).st_mtime)
        config_changed = mtime != last_mtime or cfg["mode"] != last_mode
        last_mtime, last_mode = mtime, cfg["mode"]

        if backend_state() == "ok":
            temps = temperatures()
            rpm, _duty = target_rpm(cfg, temps, fan_range)
            current = read_fan_setting(state_word())
            drifted = current is not None and current != rpm
            if cfg["mode"] == "curve":
                moved = last_rpm is None or abs(rpm - last_rpm) >= RPM_DEADBAND
                if config_changed or moved or (drifted and last_rpm is not None and current != last_rpm):
                    if write_fan(rpm):
                        last_rpm = rpm
            else:
                # auto / manual: only act when the config changed or something else moved the EC.
                if config_changed or drifted:
                    if write_fan(rpm):
                        last_rpm = rpm
            status = build_status(cfg)
            write_status_file(status)
        else:
            write_status_file(build_status(cfg))
            last_rpm = None

        for _ in range(cfg["interval"] * 10):
            if stop["flag"]:
                break
            time.sleep(0.1)

    # Nobody is driving the curve any more: hand the fans back to the EC.
    cfg = load_config()
    if cfg["mode"] == "curve" and backend_state() == "ok":
        write_fan(0)


def cmd_install_service(_args):
    script = os.path.abspath(__file__)
    python = shutil.which("python3") or "/usr/bin/python3"
    unit = """[Unit]
Description=Open Razer fan curve controller
After=razercontrol.service
Wants=razercontrol.service

[Service]
Type=simple
ExecStart="{python}" "{script}" serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
""".format(python=python, script=script)
    os.makedirs(os.path.dirname(SERVICE_FILE), exist_ok=True)
    with open(SERVICE_FILE, "w") as f:
        f.write(unit)
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "--user", "enable", "--now", SERVICE_NAME], check=False)
    emit({"service": service_state(), "unit": SERVICE_FILE})


def cmd_uninstall_service(_args):
    subprocess.run(["systemctl", "--user", "disable", "--now", SERVICE_NAME], check=False)
    safe(lambda: os.remove(SERVICE_FILE))
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
    emit({"service": service_state()})


def main():
    p = argparse.ArgumentParser(description="Open Razer fan and power control")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status").set_defaults(fn=cmd_status)

    s = sub.add_parser("set-mode")
    s.add_argument("mode", choices=["auto", "manual", "curve"])
    s.set_defaults(fn=cmd_set_mode)

    s = sub.add_parser("set-manual")
    s.add_argument("duty", type=int)
    s.add_argument("--switch", action="store_true", help="also switch to manual mode")
    s.set_defaults(fn=cmd_set_manual)

    s = sub.add_parser("set-curve")
    s.add_argument("curve", help="temp:duty pairs, e.g. 40:30,55:40,65:60,75:80,85:100")
    s.add_argument("--switch", action="store_true", help="also switch to curve mode")
    s.set_defaults(fn=cmd_set_curve)

    s = sub.add_parser("set-source")
    s.add_argument("source", choices=["cpu", "gpu", "max"])
    s.set_defaults(fn=cmd_set_source)

    s = sub.add_parser("set-power")
    s.add_argument("mode", type=int)
    s.add_argument("cpu", type=int, nargs="?", default=None)
    s.add_argument("gpu", type=int, nargs="?", default=None)
    s.set_defaults(fn=cmd_set_power)

    sub.add_parser("apply").set_defaults(fn=cmd_apply)
    sub.add_parser("serve").set_defaults(fn=cmd_serve)
    sub.add_parser("install-service").set_defaults(fn=cmd_install_service)
    sub.add_parser("uninstall-service").set_defaults(fn=cmd_uninstall_service)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
