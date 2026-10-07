.pragma library

// ---------------------------------------------------------------------------
// razer_ctl.py status
// ---------------------------------------------------------------------------

function parseStatus(rawText) {
  var result = { daemon: false, error: "no-output", devices: [], stale: [], healing: false, pointer: null }
  if (!rawText || typeof rawText !== "string") return result
  try {
    var data = JSON.parse(rawText.trim())
    result.daemon = Boolean(data.daemon)
    result.error = data.error || ""
    result.devices = Array.isArray(data.devices) ? data.devices : []
    result.stale = Array.isArray(data.stale) ? data.stale : []
    result.healing = Boolean(data.healing)
    result.pointer = data.pointer || null
  } catch (e) {
    console.warn("Open Razer: failed to parse status:", e)
  }
  return result
}

function firstOfKind(devices, kind) {
  for (var i = 0; i < devices.length; i++)
    if (devices[i].kind === kind) return devices[i]
  return null
}

function findDevice(devices, serial) {
  for (var i = 0; i < devices.length; i++)
    if (devices[i].serial === serial) return devices[i]
  return null
}

// Friendlier names for devices, keyed by the name OpenRazer reports.
var displayNames = {
  "Razer Blade 17 Pro (Mid 2021)": "Razer 17 Pro",
  "Razer Basilisk V3 X HyperSpeed": "Basilisk V3 X"
}

function displayName(d) {
  if (!d) return ""
  return displayNames[d.name] || d.name
}

function kindIcon(kind) {
  if (kind === "keyboard") return "󰌌"
  if (kind === "mouse") return "󰍽"
  if (kind === "fans") return "󰈐"
  return "󰓃"
}

function kindLabel(kind) {
  if (kind === "keyboard") return "Laptop"
  if (kind === "mouse") return "Mouse"
  if (kind === "fans") return "Fans"
  return "Device"
}

function tabOptions() {
  return [
    { value: "keyboard", label: "Laptop", icon: kindIcon("keyboard") },
    { value: "mouse", label: "Mouse", icon: kindIcon("mouse") },
    { value: "fans", label: "Fans", icon: kindIcon("fans") }
  ]
}

function batteryIcon(level, charging) {
  if (charging) return "󰂄"
  if (level === null || level === undefined) return "󰂑"
  var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  return icons[Math.max(0, Math.min(10, Math.round(level / 10)))]
}

var effectLabels = {
  static: "Static",
  breathing: "Breathe",
  spectrum: "Spectrum",
  wave: "Wave",
  reactive: "Reactive",
  starlight: "Starlight",
  off: "Off"
}

// ButtonGroup is a single Row, so split effects across two rows to fit the panel.
function effectRows(effects) {
  var opts = (effects || []).map(function(e) { return { value: e, label: effectLabels[e] || e } })
  if (opts.length <= 4) return [opts]
  return [opts.slice(0, 4), opts.slice(4)]
}

function usesColor(effect) {
  return effect === "static" || effect === "breathing" || effect === "reactive" || effect === "starlight"
}

function pollOptions(rates) {
  return (rates || []).map(function(hz) {
    return { value: String(hz), label: hz >= 1000 ? (hz / 1000) + "K" : String(hz) }
  })
}

function pollLabel(hz) {
  if (!hz) return ""
  return hz >= 1000 ? (hz / 1000) + " kHz" : hz + " Hz"
}

function deviceSummary(d) {
  if (!d) return ""
  var parts = []
  if (d.dpi) parts.push(d.dpi + " DPI")
  if (d.pollRate) parts.push(pollLabel(d.pollRate))
  if (d.battery !== null && d.battery !== undefined) parts.push(d.battery + "%" + (d.charging ? " charging" : ""))
  if (parts.length === 0 && d.brightness !== null && d.brightness !== undefined) parts.push("Brightness " + d.brightness + "%")
  if (d.effect) parts.push(effectLabels[d.effect] || d.effect)
  return parts.join(" • ")
}

function errorTitle(err) {
  if (err === "not-installed") return "OpenRazer not installed"
  if (err === "daemon-not-running") return "OpenRazer daemon not running"
  return "No Razer devices found"
}

function errorDetail(err) {
  if (err === "not-installed") return "Install openrazer-daemon, openrazer-driver-dkms and python-openrazer"
  if (err === "daemon-not-running") return "Start it with: systemctl --user enable --now openrazer-daemon"
  return "Mouse must use the HyperSpeed USB dongle — OpenRazer can't see Bluetooth devices"
}

function accelOptions() {
  return [
    { value: "adaptive", label: "Adaptive" },
    { value: "flat", label: "Flat" }
  ]
}

function sensitivityLabel(v) {
  var n = Math.round(v * 100) / 100
  if (n === 0) return "Default"
  return (n > 0 ? "+" : "") + n.toFixed(2)
}

// ---------------------------------------------------------------------------
// fan_ctl.py status
// ---------------------------------------------------------------------------

function parseFanStatus(rawText) {
  var result = {
    backend: "no-output", laptop: "", fanRange: [3500, 5000], ac: true,
    temps: { cpu: null, gpu: null, max: null }, temp: null,
    mode: "auto", manualDuty: 50, curve: [], source: "cpu", service: "missing",
    rpm: null, setting: null, settingDuty: null, targetRpm: null, targetDuty: null, power: null
  }
  if (!rawText || typeof rawText !== "string") return result
  try {
    var data = JSON.parse(rawText.trim())
    for (var k in data) if (data.hasOwnProperty(k)) result[k] = data[k]
    if (!Array.isArray(result.curve)) result.curve = []
    if (!Array.isArray(result.fanRange) || result.fanRange.length !== 2) result.fanRange = [3500, 5000]
  } catch (e) {
    console.warn("Open Razer: failed to parse fan status:", e)
  }
  return result
}

function modeOptions() {
  return [
    { value: "auto", label: "Auto" },
    { value: "manual", label: "Manual" },
    { value: "curve", label: "Curve" }
  ]
}

function sourceOptions(temps) {
  var opts = [{ value: "cpu", label: "CPU" }]
  if (temps && temps.gpu !== null && temps.gpu !== undefined) opts.push({ value: "gpu", label: "GPU" })
  opts.push({ value: "max", label: "Hottest" })
  return opts
}

var powerModes = ["Balanced", "Gaming", "Creator", "Silent", "Custom"]
var cpuBoost = ["Low", "Medium", "High", "Boost"]
var gpuBoost = ["Low", "Medium", "High"]

function powerOptions() {
  return powerModes.map(function(name, i) { return { value: String(i), label: name } })
}

function boostOptions(names) {
  return names.map(function(name, i) { return { value: String(i), label: name } })
}

// Linear interpolation across the curve, clamped at both ends (mirrors fan_ctl.py).
function curveDuty(curve, temp) {
  if (temp === null || temp === undefined || !curve || curve.length === 0) return null
  if (temp <= curve[0][0]) return curve[0][1]
  if (temp >= curve[curve.length - 1][0]) return curve[curve.length - 1][1]
  for (var i = 0; i + 1 < curve.length; i++) {
    var t0 = curve[i][0], d0 = curve[i][1], t1 = curve[i + 1][0], d1 = curve[i + 1][1]
    if (t0 <= temp && temp <= t1) return t1 === t0 ? d1 : d0 + (d1 - d0) * (temp - t0) / (t1 - t0)
  }
  return curve[curve.length - 1][1]
}

function dutyToRpm(duty, range) {
  var lo = range[0], hi = range[1]
  var rpm = lo + (hi - lo) * Math.max(0, Math.min(100, duty)) / 100
  return Math.round(rpm / 50) * 50
}

function fmtTemp(t) {
  if (t === null || t === undefined) return "--°C"
  return Math.round(t) + "°C"
}

function fanSummary(fan) {
  if (!fan || fan.backend !== "ok") return ""
  var parts = []
  parts.push(fan.rpm !== null && fan.rpm !== undefined ? fan.rpm + " RPM" : "-- RPM")
  parts.push(fmtTemp(fan.temp))
  return parts.join(" · ")
}

function fanDetail(fan) {
  if (!fan) return ""
  if (fan.backend === "no-cli") return "Fan backend not set up — run scripts/setup-fan-backend.sh"
  if (fan.backend === "no-daemon") return "razercontrol daemon not running"
  if (fan.mode === "auto") return "EC automatic control"
  if (fan.mode === "manual") return "Manual " + fan.manualDuty + "% · " + dutyToRpm(fan.manualDuty, fan.fanRange) + " RPM"
  var svc = fan.service === "active" ? "" : " · service not running"
  return "Curve " + (fan.targetDuty !== null ? fan.targetDuty + "%" : "--") + " · " + (fan.targetRpm || "--") + " RPM" + svc
}

function curveSummary(curve) {
  return (curve || []).map(function(p) { return p[0] + "°C " + p[1] + "%" }).join("  ·  ")
}

function curveToArg(curve) {
  return (curve || []).map(function(p) { return p[0] + ":" + p[1] }).join(",")
}

function cloneCurve(curve) {
  return (curve || []).map(function(p) { return [p[0], p[1]] })
}

function sameCurve(a, b) {
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++)
    if (a[i][0] !== b[i][0] || a[i][1] !== b[i][1]) return false
  return true
}

function fanBackendTitle(backend) {
  if (backend === "no-cli") return "Fan control not set up"
  if (backend === "no-daemon") return "Fan daemon not running"
  if (backend === "no-output") return "Fans"
  return "Fans"
}
