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
  if (kind === "keyboard") return "Lighting"
  if (kind === "mouse") return "Mouse"
  if (kind === "fans") return "Fans"
  return "Device"
}

function tabOptions() {
  return [
    { value: "keyboard", label: "Lighting", icon: "󰌌" },
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

// Razer logo supplied by the user (~/Downloads/RazerLogo.svg), drawn with
// QtQuick.Shapes in the bar so it takes the theme colour instead of Razer green.
var razerLogo = {
  x: 0, y: 0, width: 768, height: 774,
  paths: ["M767.102 13.2736L755.432 10.6793L761.408 0L752.557 9.70693L733.288 17.9888C731.578 16.1527 728.69 14.8967 724.236 15.9997C712.459 18.9367 712.115 12.6581 699.035 17.4228C696.354 18.4106 697.256 16.1334 688.799 18.9232C682.919 20.8512 678.951 30.7002 675.02 31.544C637.072 39.667 652.105 72.0393 657.348 78.4471C663.855 86.4215 658.448 89.1528 655.562 86.2865C651.062 81.7822 645.49 74.4007 634.796 63.8674C598.152 27.7176 529.891 64.4713 545.326 121.09C559.871 174.414 617.702 226.879 641.881 251.516C663.757 273.807 701.773 334.739 652.204 357.201C635.354 364.847 620.896 365.432 608.584 362.321C625.878 334.117 624.878 298.457 604.447 277.215C576.32 247.995 555.66 264.166 555.66 264.166C588.39 264.141 629.498 305.572 595.625 349.96C594.268 351.736 592.815 353.436 591.272 355.052C576.766 346.46 566.338 333.826 559.262 326.848C556.122 323.737 527.46 287.206 491.834 287.987C494.955 250.074 467.533 211.532 429.932 190.863C425.01 188.172 419.844 185.954 414.502 184.241C410.819 155.897 396.886 123.894 353.544 111.686C287.52 93.0905 259.403 142.314 248.88 171.356C239.865 196.218 215.708 307.763 211.642 325.83C207.781 343.057 183.628 373.938 160.486 355.072C142.635 340.539 153.875 308.021 156.58 295.503C159.488 282.039 147.54 265.556 131.058 268.04C111.308 271.011 107.608 289.157 105.343 295.002C100.565 307.318 89.4152 301.23 87.172 299.761C83.7893 297.575 81.5526 287.707 76.1673 284.635C68.436 280.223 68.881 282.63 66.4443 281.145C54.5843 273.846 52.9746 279.92 42.0291 274.714C38.6161 273.085 35.9151 273.245 33.926 274.162C33.2604 274.591 32.8128 275.037 32.1852 275.612L14.9276 264.663L7.73712 253.69L12.1745 264.787L0 265.88L12.9996 267.711L30.0404 278.516C29.1703 281.074 29.5022 284.574 33.4534 287.944C42.678 295.82 37.7872 299.75 49.2852 307.615C51.646 309.219 49.2646 309.807 56.4564 315.053C61.4442 318.708 71.7634 316.201 74.7499 318.919C103.44 345.033 121.016 313.972 123.171 305.968C125.857 296.041 131.241 298.844 130.588 302.851C129.53 309.137 126.783 317.958 124.444 332.786C116.378 383.646 186.019 417.746 223.067 372.224C257.938 329.355 266.937 251.782 272.885 217.787C278.296 187.023 305.691 120.627 352.799 147.85C368.828 157.101 377.709 168.517 382.359 180.327C349.347 182.686 320.94 204.277 315.576 233.271C308.201 273.125 333.374 280.511 333.374 280.511C314.278 253.917 324.055 196.382 379.86 198.067C382.093 198.139 384.32 198.331 386.532 198.64C387.989 215.431 383.797 231.271 382.248 241.071C381.562 245.288 369.475 286.83 387.707 315.338C353.529 329.389 331.091 369.352 328.056 411.008C327.634 416.776 327.799 422.369 328.442 427.779C304.208 442.955 280.938 468.957 287.899 513.434C298.496 581.2 354.948 586.255 385.745 583.725C412.082 581.564 523.567 557.051 541.669 553.232C558.949 549.574 597.079 558.669 589.585 587.556C583.791 609.836 549.55 613.17 537.062 615.913C523.581 618.878 513.597 636.616 522.723 650.56C533.661 667.274 551.691 663.077 557.932 662.713C571.144 661.938 570.234 674.605 569.835 677.258C569.253 681.25 561.222 687.392 560.67 693.543C559.878 702.407 561.884 701.005 561.544 703.836C559.839 717.667 566.034 716.575 565.853 728.714C565.801 732.387 567.012 734.736 568.602 736.163L568.659 736.1L569.129 736.6L569.594 736.958V736.977C570.063 737.285 570.573 737.526 571.11 737.693L567.763 760.874L560.7 771.952L569.02 763.339L575.015 774.007L571.357 761.391L574.739 737.98C577.302 737.57 580.108 735.74 581.456 731.001C584.775 719.332 590.385 722.145 592.735 708.418C593.224 705.607 594.727 707.527 596.519 698.806C597.779 692.748 591.197 684.406 592.41 680.57C604.194 643.589 568.632 640.567 560.476 641.926C550.328 643.622 550.623 637.565 554.555 636.501C560.708 634.821 569.865 633.648 584.316 629.61C633.906 615.727 635.898 538.236 579.092 523.522C525.572 509.677 451.311 533.825 417.94 542.572C387.723 550.483 315.955 553.239 321.077 499.061C322.809 480.637 329.474 467.803 338.28 458.666C354.182 487.671 385.643 504.502 414.226 497.299C453.562 487.416 449.775 461.453 449.775 461.453C433.544 489.868 377.19 504.98 355.458 453.543C354.601 451.481 353.848 449.378 353.201 447.242C367.87 438.911 384.003 436.135 393.574 433.459C397.925 432.252 445.756 425.237 461.805 392.159C491.053 413.231 535.566 412.488 572.323 394.853C577.542 392.366 582.316 389.428 586.696 386.194C611.892 399.688 646.03 406.979 681.18 378.863C734.74 336.002 711.088 284.498 693.606 259.022C678.639 237.229 602.025 152.638 589.687 138.821C577.971 125.631 566.899 88.037 595.707 80.1976C617.913 74.1538 637.821 102.226 646.415 111.72C655.675 121.927 676.015 121.804 683.606 106.954C692.688 89.1598 680.078 75.5866 676.66 70.3511C669.43 59.2796 680.868 53.7849 683.368 52.7939C687.114 51.3251 696.44 55.2531 702.06 52.6589C710.157 48.9469 707.946 47.9006 710.566 46.7899C723.415 41.3943 719.4 36.5595 730.005 30.6906C732.931 29.0726 734.401 27.1163 734.992 25.2056L734.885 24.8339C735.354 23.1863 735.3 22.0551 735.062 21.1605L753.99 13.033L767.102 13.2736ZM414.611 222.425C414.974 218.888 415.299 214.752 415.499 210.183C433.721 222.62 446.927 242.718 453.107 261.26C462.045 288.207 452.134 307.17 441.383 308.395C405.632 312.489 411.862 249.993 414.611 222.425ZM363.104 411.788C359.739 412.947 355.839 414.356 351.585 416.087C355.318 394.344 368.09 373.961 382.382 360.623C403.14 341.264 424.507 342.377 430.106 351.644C448.709 382.428 389.295 402.793 363.104 411.788ZM501.589 372.707C474.467 364.313 464.835 345.194 470.084 335.743C487.568 304.29 534.762 345.739 555.581 364.027C558.247 366.377 561.407 369.064 565.027 371.881C544.299 379.45 520.251 378.501 501.589 372.707Z"]
}
