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
  if (displayNames[d.name]) return displayNames[d.name]
  // Unknown devices: drop the bracketed year and marketing suffixes OpenRazer includes.
  return String(d.name || "")
    .replace(/\s*\([^)]*\)\s*/g, " ")
    .replace(/\s+(HyperSpeed|HyperPolling)\b/g, "")
    .replace(/\s+/g, " ")
    .trim()
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

// Bar tooltip: four short lines — Lighting, Mouse, Temp, Fans.
function barTooltip(devices, fan, daemonError) {
  var kb = firstOfKind(devices, "keyboard")
  var mouse = firstOfKind(devices, "mouse")
  var lines = []
  if (kb) lines.push("Lighting  " + (kb.effect === "off" ? "Off" : (effectLabels[kb.effect] || kb.effect) + (kb.brightness !== null && kb.brightness !== undefined ? " " + kb.brightness + "%" : "")))
  if (mouse) {
    var mp = []
    if (mouse.battery !== null && mouse.battery !== undefined) mp.push(mouse.battery + "%" + (mouse.charging ? " charging" : ""))
    if (mouse.dpi) mp.push(mouse.dpi + " DPI")
    lines.push("Mouse     " + (mp.length ? mp.join(" · ") : "connected"))
  } else {
    lines.push("Mouse     not found")
  }
  if (!kb && !mouse) lines = [errorTitle(daemonError)]
  if (fan && fan.temps && fan.temps.cpu !== null && fan.temps.cpu !== undefined) {
    var tp = ["CPU " + fmtTemp(fan.temps.cpu)]
    if (fan.temps.gpu !== null && fan.temps.gpu !== undefined) tp.push("GPU " + fmtTemp(fan.temps.gpu))
    lines.push("Temp      " + tp.join(" · "))
  }
  if (fan && fan.backend === "ok") {
    var mode = fan.mode === "auto" ? "Auto" : fan.mode === "manual" ? "Manual" : "Curve"
    lines.push("Fans      " + (fan.rpm !== null && fan.rpm !== undefined ? fan.rpm + " RPM" : "--") + " · " + mode)
  }
  return lines.join("\n")
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
  x: 0, y: 0, width: 769, height: 778,
  paths: ["M767.52 15.2948L755.85 12.7006L761.826 2.02126L752.976 11.7282L733.707 20.01C731.997 18.174 729.108 16.918 724.654 18.0209C712.877 20.9579 712.533 14.6794 699.453 19.4441C696.773 20.4319 697.674 18.1547 689.218 20.9444C683.337 22.8724 679.37 32.7215 675.438 33.5652C637.491 41.6882 652.524 74.0605 657.767 80.4684C664.273 88.4428 658.866 91.174 655.98 88.3077C651.481 83.8035 645.909 76.422 635.214 65.8887C598.57 29.7388 530.309 66.4925 545.745 123.112C560.289 176.435 618.121 228.901 642.3 253.537C664.175 275.828 702.192 336.761 652.623 359.222C635.772 366.869 621.315 367.453 609.003 364.342C626.296 336.139 625.296 300.478 604.866 279.237C576.738 250.016 556.079 266.187 556.079 266.187C588.808 266.162 629.916 307.593 596.043 351.981C594.687 353.757 593.234 355.457 591.69 357.073C577.184 348.481 566.757 335.847 559.68 328.869C556.541 325.758 527.878 289.227 492.253 290.009C495.374 252.095 467.951 213.553 430.351 192.884C425.429 190.193 420.262 187.976 414.921 186.262C411.237 157.919 397.304 125.916 353.962 113.708C287.939 95.1117 259.821 144.335 249.299 173.377C240.283 198.24 216.126 309.785 212.06 327.851C208.2 345.078 184.046 375.959 160.904 357.093C143.054 342.56 154.293 310.042 156.999 297.524C159.906 284.061 147.958 267.577 131.477 270.061C111.726 273.032 108.026 291.178 105.762 297.023C100.983 309.339 89.8336 303.251 87.5905 301.782C84.2078 299.597 81.9711 289.728 76.5858 286.656C68.8544 282.244 69.2995 284.651 66.8628 283.167C55.0027 275.867 53.3931 281.942 42.4475 276.735C39.0346 275.107 36.3336 275.266 34.3445 276.183C33.6789 276.612 33.2313 277.059 32.6036 277.633L15.3461 266.684L8.15558 255.711L12.593 266.808L0.418457 267.901L13.4181 269.732L30.4589 280.538C29.5888 283.095 29.9206 286.596 33.8718 289.965C43.0964 297.841 38.2057 301.771 49.7036 309.637C52.0644 311.24 49.683 311.828 56.8748 317.074C61.8627 320.729 72.1818 318.222 75.1684 320.94C103.859 347.054 121.435 315.993 123.589 307.989C126.275 298.062 131.659 300.865 131.007 304.873C129.949 311.158 127.202 319.979 124.863 334.807C116.797 385.667 186.437 419.767 223.486 374.246C258.356 331.377 267.356 253.803 273.304 219.808C278.714 189.044 306.109 122.648 353.217 149.872C369.246 159.123 378.127 170.538 382.777 182.349C349.766 184.707 321.359 206.298 315.995 235.292C308.62 275.147 333.792 282.533 333.792 282.533C314.697 255.938 324.473 198.403 380.279 200.088C382.511 200.16 384.738 200.352 386.95 200.662C388.407 217.452 384.215 233.292 382.666 243.093C381.98 247.309 369.893 288.851 388.125 317.36C353.947 331.411 331.509 371.373 328.474 413.029C328.052 418.797 328.217 424.39 328.861 429.8C304.627 444.977 281.356 470.978 288.318 515.455C298.914 583.222 355.367 588.276 386.163 585.747C412.501 583.586 523.986 559.073 542.088 555.253C559.367 551.595 597.498 560.691 590.003 589.577C584.21 611.858 549.968 615.191 537.48 617.934C523.999 620.899 514.015 638.638 523.141 652.581C534.079 669.295 552.11 665.098 558.351 664.734C571.562 663.959 570.652 676.626 570.253 679.279C569.671 683.271 561.64 689.413 561.089 695.564C560.296 704.428 562.302 703.026 561.963 705.857C560.258 719.689 566.452 718.596 566.271 730.736C566.22 734.408 567.43 736.758 569.02 738.185L569.078 738.121L569.547 738.621L570.012 738.98V738.998C570.482 739.306 570.992 739.547 571.528 739.714L568.181 762.896L561.118 773.973L569.439 765.36L575.434 776.028L571.775 763.412L575.158 740.001C577.72 739.591 580.527 737.761 581.874 733.023C585.194 721.353 590.804 724.166 593.154 710.439C593.642 707.628 595.145 709.548 596.938 700.827C598.197 694.769 591.615 686.427 592.828 682.591C604.612 645.611 569.05 642.589 560.894 643.947C550.747 645.643 551.042 639.586 554.973 638.522C561.127 636.843 570.284 635.67 584.735 631.632C634.325 617.748 636.316 540.257 579.51 525.543C525.99 511.698 451.73 535.847 418.359 544.593C388.141 552.504 316.374 555.26 321.495 501.083C323.228 482.658 329.892 469.824 338.698 460.688C354.601 489.692 386.062 506.523 414.645 499.32C453.981 489.437 450.193 463.474 450.193 463.474C433.963 491.889 377.609 507.002 355.876 455.564C355.019 453.503 354.266 451.4 353.619 449.263C368.288 440.932 384.421 438.156 393.993 435.481C398.344 434.273 446.174 427.259 462.224 394.18C491.471 415.253 535.985 414.509 572.742 396.874C577.96 394.387 582.734 391.45 587.114 388.215C612.31 401.71 646.448 409 681.598 380.884C735.159 338.024 711.507 286.519 694.025 261.043C679.057 239.25 602.443 154.659 590.106 140.842C578.389 127.652 567.318 90.0583 596.125 82.2189C618.331 76.175 638.24 104.248 646.834 113.741C656.094 123.948 676.433 123.825 684.024 108.976C693.106 91.1811 680.497 77.6079 677.079 72.3724C669.848 61.3008 681.286 55.8062 683.786 54.8152C687.533 53.3463 696.858 57.2744 702.478 54.6801C710.575 50.9681 708.364 49.9218 710.985 48.8112C723.833 43.4156 719.818 38.5808 730.424 32.7119C733.35 31.0938 734.82 29.1375 735.41 27.2269L735.303 26.8552C735.773 25.2075 735.719 24.0763 735.481 23.1818L754.409 15.0543L767.52 15.2948ZM415.029 224.446C415.392 220.909 415.717 216.773 415.917 212.205C434.14 224.641 447.345 244.739 453.526 263.281C462.463 290.229 452.553 309.191 441.802 310.417C406.05 314.51 412.281 252.014 415.029 224.446ZM363.522 413.81C360.158 414.968 356.257 416.377 352.004 418.108C355.736 396.366 368.509 375.983 382.8 362.644C403.558 343.285 424.925 344.399 430.524 353.666C449.127 384.449 389.714 404.815 363.522 413.81ZM502.007 374.728C474.885 366.334 465.253 347.215 470.502 337.764C487.987 306.311 535.181 347.76 555.999 366.048C558.665 368.398 561.825 371.085 565.445 373.902C544.718 381.471 520.669 380.522 502.007 374.728Z"]
}
