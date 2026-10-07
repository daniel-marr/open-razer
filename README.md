# Open Razer (`dan.open-razer`)

One Omarchy bar widget for a Razer Blade laptop and a Razer mouse. It grew out
of the `dan.razer-chroma` ("Razer 17 Pro") widget and adds full mouse control
and laptop fan/power control.

The panel has three tabs:

| Tab | What it controls | Backend |
|-----|------------------|---------|
| **Laptop** | Keyboard Chroma effect, colour and brightness, lid logo | OpenRazer |
| **Mouse** | DPI stages (switch and edit), free DPI slider, polling rate, pointer speed and acceleration, sleep-after-idle, scroll-wheel lighting, battery | OpenRazer + Hyprland |
| **Fans** | Auto / manual / temperature-curve fan control, CPU and GPU temperatures, live tachometer, power profile with CPU/GPU boost | razer-control-revived |

Controls only show when the selected device supports them.

## Install

```sh
omarchy plugin add https://github.com/<you>/open-razer.git --enable
# or, from a checkout:
scripts/install.sh
```

`scripts/install.sh` copies the plugin into `~/.config/omarchy/plugins/dan.open-razer`
and, if the old `dan.razer-chroma` widget is in your bar, swaps it in place
(a backup of `shell.json` is kept next to it).

### Keyboard and mouse (OpenRazer)

```sh
sudo pacman -S openrazer-daemon openrazer-driver-dkms python-openrazer
sudo gpasswd -a $USER openrazer         # then reboot
systemctl --user enable --now openrazer-daemon
```

OpenRazer only sees wireless mice through their USB receiver, not over Bluetooth.

**Dropped mouse, self-healing.** The OpenRazer daemon's hot-plug listener thread
dies when a device disappears between the udev event and the daemon's sysfs
lookup, which a HyperSpeed dongle on a hub does regularly. After that the daemon
never notices new devices, so the mouse silently vanishes from the panel while
the kernel driver still has it. `razer_ctl.py status` compares the kernel's view
(`/sys/bus/hid/drivers/razer*/`) with the daemon's and restarts the daemon when
they disagree (at most once every two minutes). The Mouse tab also has a
"Rescan devices" button that forces it.

### Fans and power (razer-control-revived)

Fan control talks to the Blade's embedded controller through the
[razer-control-revived](https://github.com/encomjp/razer-control-revived) daemon,
a userspace HID driver. The setup script installs everything under your home
directory, no sudo needed:

```sh
scripts/setup-fan-backend.sh
```

It builds the daemon and `razer-cli` (needs `rust`; the GTK GUI is skipped),
installs them to `~/.local/share/open-razer/bin`, writes a systemd user unit
`razercontrol.service`, and installs the plugin's own `open-razer-fan.service`,
which runs the temperature curve. The daemon needs write access to the laptop's
`/dev/hidraw*` node; Omarchy's udev rule grants that to the `input` group, so
make sure you're in it (`sudo usermod -aG input $USER`, then log out and in).
If a distro package of razer-control is already installed, the script uses it.

The Fans tab offers to run this script when the backend is missing.

**Modes**

- **Auto**: the EC controls the fans (default).
- **Manual**: pin one duty. 0% is the EC's minimum RPM, 100% its maximum
  (2300–4300 RPM on the Blade 17 Pro Mid 2021; the range comes from
  `laptops.json` per model).
- **Curve**: five temperature → duty points, linearly interpolated, driven by
  the CPU package temperature, the NVIDIA GPU temperature or whichever is
  hotter. `open-razer-fan.service` evaluates it every 3 seconds, writes the
  EC only when the target moves by at least 100 RPM, and hands the fans back
  to the EC if it is stopped while in curve mode.

The GPU temperature is only read while the dGPU is awake (`runtime_status`
active), because polling `nvidia-smi` would otherwise keep it powered on.

Power profiles (Balanced, Gaming, Creator, Silent, Custom with CPU/GPU boost)
are stored per power source by the daemon; the panel shows and edits the one
for the current source.

Keyboard brightness and logo changes made in the Laptop tab are also written
through to the razer-control daemon, so it does not undo them when the power
source changes.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `showBatteryInBar` | false | Mouse battery next to the bar icon |
| `showFanInBar` | false | Fan RPM and CPU temperature next to the bar icon |
| `onlyWhenConnected` | false | Hide the widget when OpenRazer lists no devices |

Pointer speed and acceleration are kept in `~/.config/open-razer/pointer.json`
and re-applied to Hyprland (for the Razer mouse only, via `hl.device`) when the
plugin loads. Fan settings live in `~/.config/open-razer/fans.json`.

## IPC

```sh
omarchy-shell dan.open-razer toggle
omarchy-shell dan.open-razer tab fans              # keyboard | mouse | fans
omarchy-shell dan.open-razer effect keyboard spectrum
omarchy-shell dan.open-razer color mouse "#FF0000"
omarchy-shell dan.open-razer brightness keyboard 60
omarchy-shell dan.open-razer dpi 1600
omarchy-shell dan.open-razer stage 2
omarchy-shell dan.open-razer poll 1000
omarchy-shell dan.open-razer pointer 0.25
omarchy-shell dan.open-razer fanMode curve         # auto | manual | curve
omarchy-shell dan.open-razer fanDuty 70
omarchy-shell dan.open-razer power 1               # 0 Balanced … 4 Custom
```

Both scripts work standalone:

```sh
./razer_ctl.py status
./razer_ctl.py set-stages mouse 400,800,1600,3200,6400
./razer_ctl.py pointer-set --sensitivity 0.2 --accel flat
./fan_ctl.py status
./fan_ctl.py set-curve 40:30,55:40,65:60,75:80,85:100 --switch
./fan_ctl.py set-power 4 2 2
```

## Files

- `Panel.qml` — bar button and panel
- `Model.js` — parsing, labels, curve maths shared with the panel
- `razer_ctl.py` — OpenRazer devices, daemon self-heal, Hyprland pointer settings
- `fan_ctl.py` — fan modes, curve service, temperatures, power profiles
- `scripts/install.sh` — install/update the plugin and put it in the bar
- `scripts/setup-fan-backend.sh` — build and install the fan daemon as user services
