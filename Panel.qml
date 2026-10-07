import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root

  moduleName: "dan.open-razer"
  ipcTarget: "dan.open-razer"
  manageIpc: false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string razerScript: pluginDir + "/razer_ctl.py"
  readonly property string fanScript: pluginDir + "/fan_ctl.py"
  readonly property string setupScript: pluginDir + "/scripts/setup-fan-backend.sh"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Settings
  readonly property bool showBatteryInBar: setting("showBatteryInBar", true) !== false
  readonly property bool showFanInBar: setting("showFanInBar", false) === true
  readonly property bool onlyWhenConnected: setting("onlyWhenConnected", false) === true

  // State from razer_ctl.py
  property bool daemonUp: false
  property string daemonError: ""
  property var devices: []
  property var stale: []
  property bool healing: false
  property var pointer: null
  property bool isPolling: false
  property double lastUserActionTime: 0

  // State from fan_ctl.py
  property var fan: Model.parseFanStatus("")
  property bool fanLoaded: false

  // Which tab the panel shows: keyboard (laptop), mouse or fans.
  property string tab: "keyboard"

  readonly property var keyboard: Model.firstOfKind(root.devices, "keyboard")
  readonly property var mouse: Model.firstOfKind(root.devices, "mouse")
  readonly property var selected: root.tab === "fans" ? null : Model.firstOfKind(root.devices, root.tab)
  readonly property bool hasDevices: root.devices.length > 0
  readonly property bool fanReady: root.fan.backend === "ok"

  // Optimistic copies of the selected device's values, so controls respond instantly.
  property string curEffect: ""
  property string curColor: "#00FF00"
  property int curBrightness: 0
  property int curDpi: 0
  property int curStage: 0
  property int curPollRate: 0
  property bool curLogo: false
  property real curSensitivity: 0
  property string curAccel: "adaptive"

  // Optimistic fan state
  property string curMode: "auto"
  property int curManual: 50
  property string curSource: "cpu"
  property int curPower: 0
  property int curCpuBoost: 1
  property int curGpuBoost: 0

  // Curve editing: a local copy that only goes to the EC on "Apply curve".
  property var curveEdit: []
  property bool curveDirty: false

  // DPI stage editing
  property bool editStages: false
  property var stageEdit: []

  function syncFromSelected() {
    var d = root.selected
    if (!d) return
    root.curEffect = d.effect || ""
    root.curColor = d.color || "#00FF00"
    root.curBrightness = d.brightness || 0
    root.curDpi = d.dpi || 0
    root.curStage = d.activeStage || 0
    root.curPollRate = d.pollRate || 0
    root.curLogo = Boolean(d.logo)
    if (!root.editStages) root.stageEdit = (d.dpiStages || []).slice()
  }

  function syncPointer() {
    if (!root.pointer) return
    root.curSensitivity = Number(root.pointer.sensitivity) || 0
    root.curAccel = root.pointer.accel || "adaptive"
  }

  function syncFromFan() {
    var f = root.fan
    root.curMode = f.mode || "auto"
    root.curManual = f.manualDuty !== undefined ? f.manualDuty : 50
    root.curSource = f.source || "cpu"
    if (f.power) {
      root.curPower = f.power.mode !== null ? f.power.mode : 0
      if (f.power.cpu !== null && f.power.cpu !== undefined) root.curCpuBoost = f.power.cpu
      if (f.power.gpu !== null && f.power.gpu !== undefined) root.curGpuBoost = f.power.gpu
    }
    if (!root.curveDirty) root.curveEdit = Model.cloneCurve(f.curve)
  }

  onSelectedChanged: syncFromSelected()
  onTabChanged: { root.editStages = false; syncFromSelected() }

  visible: !onlyWhenConnected || hasDevices
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  function open() {
    if (root.onlyWhenConnected && !root.hasDevices) return
    root.controller.show()
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  function refresh() {
    if (!pollProc.running) {
      root.isPolling = true
      pollProc.running = true
    }
    refreshFan()
  }

  function refreshFan() {
    if (!fanProc.running) fanProc.running = true
  }

  function run(args) {
    root.lastUserActionTime = Date.now()
    Quickshell.execDetached([root.razerScript].concat(args))
    settleTimer.restart()
  }

  function runFan(args) {
    root.lastUserActionTime = Date.now()
    Quickshell.execDetached([root.fanScript].concat(args))
    fanSettleTimer.restart()
  }

  function target(dev) {
    return dev || (root.selected ? root.selected.serial : "keyboard")
  }

  // --- Chroma -------------------------------------------------------------

  function applyEffect(eff, color, dev) {
    if (!dev || (root.selected && dev === root.selected.serial)) {
      root.curEffect = eff
      if (color) root.curColor = color
    }
    run(["set-effect", target(dev), eff, "--color", color || root.curColor])
  }

  function applyBrightness(val, dev) {
    val = Math.max(0, Math.min(100, Math.round(val)))
    if (!dev || (root.selected && dev === root.selected.serial)) root.curBrightness = val
    run(["set-brightness", target(dev), String(val)])
  }

  function applyLogo(on) {
    root.curLogo = on
    run(["set-logo", target("keyboard"), on ? "on" : "off"])
  }

  // --- Mouse --------------------------------------------------------------

  function applyDpi(val) {
    root.curDpi = Math.round(val)
    run(["set-dpi", target("mouse"), String(root.curDpi)])
  }

  function applyStage(idx) {
    var m = root.mouse
    root.curStage = idx
    if (m && m.dpiStages && m.dpiStages.length >= idx) root.curDpi = m.dpiStages[idx - 1]
    run(["set-stage", target("mouse"), String(idx)])
  }

  function setStageValue(i, val) {
    var a = root.stageEdit.slice()
    a[i] = Math.max(100, Math.round(val))
    root.stageEdit = a
  }

  function saveStages() {
    run(["set-stages", target("mouse"), root.stageEdit.join(",")])
    root.editStages = false
  }

  function applyPollRate(hz) {
    root.curPollRate = parseInt(hz)
    run(["set-poll-rate", target("mouse"), String(root.curPollRate)])
  }

  function applyIdle(seconds) {
    run(["set-idle", target("mouse"), String(seconds)])
  }

  function applySensitivity(v) {
    root.curSensitivity = Math.round(v * 20) / 20
    run(["pointer-set", "--sensitivity", String(root.curSensitivity)])
  }

  function applyAccel(profile) {
    root.curAccel = profile
    run(["pointer-set", "--accel", profile])
  }

  // --- Fans ---------------------------------------------------------------

  function ensureFanService() {
    if (root.fan.service !== "active") runFan(["install-service"])
  }

  function applyMode(mode) {
    root.curMode = mode
    if (mode === "curve") ensureFanService()
    runFan(["set-mode", mode])
  }

  function applyManual(duty) {
    root.curManual = Math.round(duty)
    runFan(["set-manual", String(root.curManual)])
  }

  function setCurveTemp(i, t) {
    var a = Model.cloneCurve(root.curveEdit)
    a[i][0] = Math.max(20, Math.min(100, Math.round(t)))
    root.curveEdit = a
    root.curveDirty = true
  }

  function setCurveDuty(i, d) {
    var a = Model.cloneCurve(root.curveEdit)
    a[i][1] = Math.max(0, Math.min(100, Math.round(d)))
    root.curveEdit = a
    root.curveDirty = true
  }

  function applyCurve() {
    ensureFanService()
    root.curMode = "curve"
    root.curveDirty = false
    runFan(["set-curve", Model.curveToArg(root.curveEdit), "--switch"])
  }

  function applySource(src) {
    root.curSource = src
    runFan(["set-source", src])
  }

  function applyPower(mode, cpu, gpu) {
    root.curPower = mode
    if (cpu !== undefined) root.curCpuBoost = cpu
    if (gpu !== undefined) root.curGpuBoost = gpu
    runFan(["set-power", String(root.curPower), String(root.curCpuBoost), String(root.curGpuBoost)])
  }

  function startDaemon() {
    Quickshell.execDetached(["systemctl", "--user", "enable", "--now", "openrazer-daemon.service"])
    settleTimer.restart()
  }

  function rescanDevices() {
    run(["heal"])
  }

  function setupFanBackend() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", root.setupScript])
  }

  // Re-read the hardware shortly after a change settles.
  Timer {
    id: settleTimer
    interval: 2500
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: fanSettleTimer
    interval: 1500
    repeat: false
    onTriggered: root.refreshFan()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function tab(name: string): void { root.tab = name; root.open() }
    function effect(device: string, name: string): void { root.applyEffect(name, "", device) }
    function color(device: string, hex: string): void {
      var d = Model.firstOfKind(root.devices, device) || Model.findDevice(root.devices, device)
      var eff = d && Model.usesColor(d.effect) ? d.effect : "static"
      root.applyEffect(eff, hex, device)
    }
    function brightness(device: string, val: string): void { root.applyBrightness(parseInt(val), device) }
    function dpi(val: string): void { root.applyDpi(parseInt(val)) }
    function stage(val: string): void { root.applyStage(parseInt(val)) }
    function poll(val: string): void { root.applyPollRate(parseInt(val)) }
    function pointer(sensitivity: string): void { root.applySensitivity(parseFloat(sensitivity)) }
    function fanMode(mode: string): void { root.applyMode(mode) }
    function fanDuty(val: string): void { root.applyManual(parseInt(val)) }
    function power(mode: string): void { root.applyPower(parseInt(mode)) }
  }

  Process {
    id: pollProc
    command: [root.razerScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isPolling = false
        var s = Model.parseStatus(text)
        root.daemonUp = s.daemon
        root.daemonError = s.error
        root.devices = s.devices
        root.stale = s.stale
        root.healing = s.healing
        root.pointer = s.pointer
        if (s.healing) healTimer.restart()
        if (Date.now() - root.lastUserActionTime > 2000) {
          root.syncFromSelected()
          root.syncPointer()
        }
      }
    }
    onExited: function(code) { root.isPolling = false }
  }

  Process {
    id: fanProc
    command: [root.fanScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.fan = Model.parseFanStatus(text)
        root.fanLoaded = true
        if (Date.now() - root.lastUserActionTime > 2000) root.syncFromFan()
      }
    }
  }

  // After the daemon restarts to pick up a re-plugged device, poll again soon.
  Timer {
    id: healTimer
    interval: 6000
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Background poll kept slow on purpose: every status read sends ~10 commands to the
    // wireless mouse dongle, and that traffic through the dock's VIA hub was wedging the
    // hub and dropping the DisplayLink monitors (see displaylink-watchdog). 2026-10-07
    interval: panel.open ? 3000 : 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Fan status is cheap (unix socket + hwmon), so it can run more often.
    interval: panel.open ? 4000 : 60000
    running: panel.open || root.showFanInBar
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFan()
  }

  Component.onCompleted: {
    // Hyprland forgets runtime device settings on reload; re-apply the saved pointer config.
    Quickshell.execDetached([root.razerScript, "pointer-apply"])
  }

  // ---------------------------------------------------------------------------
  // Reusable bits
  // ---------------------------------------------------------------------------

  // Equal-width segmented control (tabs, modes, profiles).
  component Segments: RowLayout {
    id: seg
    property var options: []
    property string value: ""
    signal changed(string value)
    spacing: Style.space(6)

    Repeater {
      model: seg.options
      Rectangle {
        id: chip
        required property var modelData
        required property int index
        Layout.fillWidth: true
        implicitHeight: Style.space(32)
        radius: Style.space(6)
        readonly property bool isActive: seg.value === String(modelData.value)
        color: isActive
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : (chipMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                                     : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03))
        border.color: isActive ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        border.width: isActive ? 1.5 : 1

        Row {
          anchors.centerIn: parent
          spacing: Style.space(6)
          Text {
            visible: Boolean(chip.modelData.icon)
            text: chip.modelData.icon || ""
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: chip.isActive ? Color.accent : root.foreground
          }
          Text {
            text: chip.modelData.label
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: chip.isActive
            color: chip.isActive ? Color.accent : root.foreground
          }
        }

        MouseArea {
          id: chipMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: seg.changed(String(chip.modelData.value))
        }
      }
    }
  }

  // "SECTION TITLE ........ value" header row.
  component SectionRow: RowLayout {
    property string title: ""
    property string valueText: ""
    PanelSectionHeader {
      text: title
      foreground: root.foreground
    }
    Item { Layout.fillWidth: true; height: 1 }
    Text {
      visible: valueText !== ""
      text: valueText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      color: Color.accent
    }
  }

  component Hint: Text {
    wrapMode: Text.WordWrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    color: Qt.darker(root.foreground, 1.4)
  }

  component Swatches: RowLayout {
    spacing: Style.space(6)
    Repeater {
      model: [String(Color.accent), "#00FF00", "#00FFFF", "#0066FF", "#9900FF", "#FF0000", "#FF6600", "#FFFF00", "#FFFFFF"]
      Rectangle {
        id: swatch
        required property var modelData
        required property int index
        Layout.fillWidth: true
        implicitHeight: Style.space(26)
        radius: Style.space(4)
        readonly property string hex: String(modelData).substring(0, 7).toUpperCase()
        readonly property bool isSelected: root.curColor.toUpperCase() === hex

        color: hex
        border.color: isSelected ? root.foreground : Qt.rgba(0, 0, 0, 0.45)
        border.width: isSelected ? 2 : 1

        Text {
          anchors.centerIn: parent
          visible: swatch.index === 0
          text: "󰏘"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Color.background
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.applyEffect(root.curEffect, swatch.hex)
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Status bar button
  // ---------------------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: root.visible
    readonly property bool showBattery: root.showBatteryInBar && root.mouse && root.mouse.battery !== null && !vertical
    readonly property bool showFan: root.showFanInBar && root.fanReady && root.fan.rpm !== null && !vertical
    readonly property string readout: (showBattery ? (root.mouse.battery + "%") : "")
          + (showFan ? ((showBattery ? "  " : "") + "󰈐 " + root.fan.rpm + " " + Model.fmtTemp(root.fan.temps.cpu)) : "")
    readonly property color logoColor: root.bar ? root.bar.barForeground : root.foreground
    text: readout === "" ? "" : " "   // keeps hasVisualContent true for the hit-test
    slotSize: Style.bar.iconSlot * (1.0 + (showBattery ? 1.1 : 0) + (showFan ? 2.6 : 0))
    tooltipText: {
      var lines = root.devices.map(function(d) {
        return Model.displayName(d) + (Model.deviceSummary(d) ? " — " + Model.deviceSummary(d) : "")
      })
      if (lines.length === 0) lines.push(Model.errorTitle(root.daemonError))
      if (root.fanReady) lines.push("Fans — " + Model.fanSummary(root.fan) + " · " + Model.fanDetail(root.fan))
      return lines.join("\n")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }

    // Razer logo in place of a glyph, with the optional battery / fan readout beside it.
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Item {
            readonly property real size: Style.bar.iconCanvas
            width: size
            height: size
            anchors.verticalCenter: parent.verticalCenter
            Shape {
              // Scale the logo's viewBox into the icon canvas, keeping aspect.
              readonly property real logoScale: parent.size / Math.max(Model.razerLogo.width, Model.razerLogo.height)
              x: -Model.razerLogo.x * logoScale + (parent.size - Model.razerLogo.width * logoScale) / 2
              y: -Model.razerLogo.y * logoScale + (parent.size - Model.razerLogo.height * logoScale) / 2
              width: Model.razerLogo.width
              height: Model.razerLogo.height
              scale: logoScale
              transformOrigin: Item.TopLeft
              preferredRendererType: Shape.CurveRenderer
              // ShapePath isn't an Item, so a Repeater can't emit them: one per path.
              ShapePath { fillColor: button.logoColor; strokeWidth: -1; PathSvg { path: Model.razerLogo.paths[0] || "" } }
              ShapePath { fillColor: button.logoColor; strokeWidth: -1; PathSvg { path: Model.razerLogo.paths[1] || "" } }
              ShapePath { fillColor: button.logoColor; strokeWidth: -1; PathSvg { path: Model.razerLogo.paths[2] || "" } }
            }
          }

          Text {
            visible: button.readout !== ""
            text: button.readout
            anchors.verticalCenter: parent.verticalCenter
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            color: button.logoColor
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Panel
  // ---------------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(1400))

    onOpenChanged: if (open) {
      root.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(14)

          // ---- Hero ----------------------------------------------------------
          PanelHero {
            width: parent.width
            title: {
              if (root.tab === "fans") return Model.fanBackendTitle(root.fan.backend)
              if (root.selected) return Model.displayName(root.selected)
              if (root.tab === "mouse" && root.daemonUp) return root.healing || root.stale.length > 0 ? "Reconnecting mouse…" : "Mouse not found"
              return Model.errorTitle(root.daemonError)
            }
            meta: {
              if (root.tab === "fans") return root.fanReady ? Model.fanSummary(root.fan) : (root.fan.laptop || "Razer Blade")
              if (root.selected) return Model.deviceSummary(root.selected)
              if (root.tab === "mouse" && root.daemonUp) return root.stale.length > 0 ? "Restarting OpenRazer so it picks the mouse up again" : Model.errorDetail("")
              return Model.errorDetail(root.daemonError)
            }
            detail: {
              if (root.tab === "fans") return Model.fanDetail(root.fan)
              if (root.selected && root.selected.battery !== null)
                return Model.batteryIcon(root.selected.battery, root.selected.charging) + " " + root.selected.battery + "% battery" + (root.selected.charging ? ", charging" : "")
              return root.selected ? "OpenRazer" : ""
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: (root.tab === "fans" ? root.fanReady : root.selected !== null) ? 1.0 : 0.4

            iconComponent: Component {
              Text {
                text: Model.kindIcon(root.tab === "fans" ? "fans" : (root.selected ? root.selected.kind : root.tab))
                color: {
                  if (root.tab === "fans") return root.foreground
                  return (root.selected && root.curEffect !== "off" && root.curBrightness > 0) ? root.curColor : Qt.darker(root.foreground, 1.5)
                }
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Item {
                width: Style.space(26)
                height: Style.space(26)
                Text {
                  anchors.centerIn: parent
                  text: "󰑐"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: refreshArea.containsMouse ? Color.accent : Qt.darker(root.foreground, 1.4)
                  rotation: root.isPolling ? 360 : 0
                  Behavior on rotation { NumberAnimation { duration: 600 } }
                }
                MouseArea {
                  id: refreshArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refresh()
                }
              }
            }
          }

          // ---- Tabs ----------------------------------------------------------
          Segments {
            width: parent.width
            options: Model.tabOptions()
            value: root.tab
            onChanged: function(v) { root.tab = v }
          }

          // Daemon installed but stopped: offer to start it
          Button {
            visible: root.tab !== "fans" && root.daemonError === "daemon-not-running"
            text: "Start OpenRazer daemon"
            iconText: "󰐊"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.startDaemon()
          }

          // Device missing on this tab: let the user force a rescan
          Button {
            visible: root.tab !== "fans" && root.daemonUp && root.selected === null
            text: root.healing ? "Restarting OpenRazer…" : "Rescan devices"
            iconText: "󰑐"
            bordered: true
            enabled: !root.healing
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.rescanDevices()
          }

          PanelSeparator {
            width: parent.width
            visible: root.tab === "fans" || root.selected !== null
            foreground: root.foreground
          }

          // =====================================================================
          // MOUSE: sensitivity
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "mouse" && root.selected !== null && root.selected.dpi !== null

            SectionRow {
              width: parent.width
              title: "SENSITIVITY (DPI)"
              valueText: root.curDpi + " DPI" + (root.curStage > 0 && root.selected && root.selected.dpiStages.length > 0 ? "  (stage " + root.curStage + "/" + root.selected.dpiStages.length + ")" : "")
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              visible: root.selected !== null && root.selected.dpiStages.length > 0 && !root.editStages

              Repeater {
                model: root.selected ? root.selected.dpiStages : []
                Rectangle {
                  id: stageBtn
                  required property var modelData
                  required property int index
                  Layout.fillWidth: true
                  implicitHeight: Style.space(32)
                  radius: Style.space(6)
                  readonly property int stageIdx: index + 1
                  readonly property bool isActive: root.curStage === stageIdx

                  color: isActive ? Style.selectedFillFor(root.foreground, Color.accent) : (stageMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03))
                  border.color: isActive ? Color.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  border.width: isActive ? 1.5 : 1

                  Text {
                    anchors.centerIn: parent
                    text: stageBtn.modelData
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: stageBtn.isActive
                    color: stageBtn.isActive ? Color.accent : root.foreground
                  }

                  MouseArea {
                    id: stageMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.applyStage(stageBtn.stageIdx)
                  }
                }
              }
            }

            // Stage editor: one number field per stage
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              visible: root.editStages

              Repeater {
                model: root.stageEdit.length
                NumberField {
                  required property int index
                  Layout.fillWidth: true
                  fieldWidth: Style.space(60)
                  from: 100
                  to: root.selected && root.selected.maxDpi ? root.selected.maxDpi : 18000
                  stepSize: 50
                  value: root.stageEdit[index] || 100
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onModified: function(v) { root.setStageValue(index, v) }
                }
              }
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 100
              maximum: root.selected && root.selected.maxDpi ? root.selected.maxDpi : 18000
              step: 50
              integer: true
              value: root.curDpi
              onMoved: function(v) { root.curDpi = Math.round(v) }
              onReleased: function(v) { root.applyDpi(v) }
            }

            RowLayout {
              width: parent.width
              visible: root.selected !== null && root.selected.dpiStages.length > 0
              Hint {
                Layout.fillWidth: true
                text: root.editStages ? "Set a DPI for each stage, then save" : "Tap a stage to switch, or drag for a one-off DPI"
              }
              Button {
                visible: root.editStages
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: { root.editStages = false; root.syncFromSelected() }
              }
              Button {
                text: root.editStages ? "Save stages" : "Edit stages"
                iconText: root.editStages ? "󰆓" : "󰏫"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: {
                  if (root.editStages) root.saveStages()
                  else { root.stageEdit = (root.selected.dpiStages || []).slice(); root.editStages = true }
                }
              }
            }
          }

          // =====================================================================
          // MOUSE: polling rate
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "mouse" && root.selected !== null && root.selected.pollRate !== null

            SectionRow {
              width: parent.width
              title: "POLLING RATE"
              valueText: Model.pollLabel(root.curPollRate)
            }

            ButtonGroup {
              options: Model.pollOptions(root.selected ? root.selected.pollRates : [])
              value: String(root.curPollRate)
              fontFamily: root.fontFamily
              foreground: root.foreground
              onChanged: function(val) { root.applyPollRate(val) }
            }
          }

          // =====================================================================
          // MOUSE: pointer (Hyprland)
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "mouse" && root.selected !== null

            SectionRow {
              width: parent.width
              title: "POINTER SPEED"
              valueText: Model.sensitivityLabel(root.curSensitivity)
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: -1
              maximum: 1
              step: 0.05
              value: root.curSensitivity
              onMoved: function(v) { root.curSensitivity = Math.round(v * 20) / 20 }
              onReleased: function(v) { root.applySensitivity(v) }
            }

            RowLayout {
              width: parent.width
              PanelSectionHeader {
                text: "ACCELERATION"
                foreground: root.foreground
              }
              Item { Layout.fillWidth: true; height: 1 }
              ButtonGroup {
                options: Model.accelOptions()
                value: root.curAccel
                fontFamily: root.fontFamily
                foreground: root.foreground
                onChanged: function(val) { root.applyAccel(val) }
              }
            }

            Hint {
              width: parent.width
              text: root.pointer && root.pointer.targets && root.pointer.targets.length > 0
                ? "Applied in Hyprland to the Razer mouse only; the touchpad keeps its own settings"
                : "Hyprland hasn't registered the mouse as an input device yet"
            }
          }

          // =====================================================================
          // MOUSE: battery and sleep
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "mouse" && root.selected !== null && root.selected.idleTime !== null

            SectionRow {
              width: parent.width
              title: "SLEEP AFTER IDLE"
              valueText: root.selected && root.selected.idleTime ? Math.round(root.selected.idleTime / 60) + " min" : ""
            }

            ButtonGroup {
              options: [
                { value: "60", label: "1 min" },
                { value: "300", label: "5 min" },
                { value: "600", label: "10 min" },
                { value: "900", label: "15 min" }
              ]
              value: root.selected ? String(root.selected.idleTime) : ""
              fontFamily: root.fontFamily
              foreground: root.foreground
              onChanged: function(val) { root.applyIdle(parseInt(val)) }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.tab === "mouse" && root.selected !== null
            foreground: root.foreground
          }

          // =====================================================================
          // Chroma lighting (laptop keyboard, or the mouse's lit zone)
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab !== "fans" && root.selected !== null && root.selected.effects.length > 0

            SectionRow {
              width: parent.width
              title: root.selected && root.selected.zone === "scroll_wheel" ? "CHROMA LIGHTING (SCROLL WHEEL)" : "CHROMA LIGHTING"
              valueText: root.selected && root.selected.brightness !== null ? root.curBrightness + "%" : ""
            }

            PanelSlider {
              width: parent.width
              visible: root.selected !== null && root.selected.brightness !== null
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.curBrightness
              onMoved: function(v) { root.curBrightness = Math.round(v) }
              onReleased: function(v) { root.applyBrightness(v) }
            }

            Repeater {
              model: Model.effectRows(root.selected ? root.selected.effects : [])
              ButtonGroup {
                required property var modelData
                options: modelData
                value: root.curEffect
                fontFamily: root.fontFamily
                foreground: root.foreground
                onChanged: function(val) { root.applyEffect(val, root.curColor) }
              }
            }

            // Colour swatches — the first one follows the current Omarchy theme accent
            Swatches {
              width: parent.width
              visible: Model.usesColor(root.curEffect)
            }

            // Laptop lid logo
            RowLayout {
              width: parent.width
              visible: root.selected !== null && root.selected.logo !== null
              Text {
                text: "Lid logo"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
              }
              Item { Layout.fillWidth: true; height: 1 }
              ToggleSwitch {
                checked: root.curLogo
                foreground: root.foreground
                onToggled: root.applyLogo(!root.curLogo)
              }
            }
          }

          // =====================================================================
          // FANS: backend missing
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanLoaded && !root.fanReady

            Hint {
              width: parent.width
              text: root.fan.backend === "no-daemon"
                ? "razer-cli is installed but the razercontrol daemon isn't running. Start it with: systemctl --user start razercontrol"
                : "Fan control uses the razer-control-revived daemon (userspace driver for the Blade's embedded controller). The setup script builds it, installs it as a user service and enables the curve service."
            }

            Button {
              text: root.fan.backend === "no-daemon" ? "Start razercontrol daemon" : "Set up fan control"
              iconText: "󰐊"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: {
                if (root.fan.backend === "no-daemon")
                  Quickshell.execDetached(["systemctl", "--user", "start", "razercontrol.service"])
                else
                  root.setupFanBackend()
                fanSettleTimer.restart()
              }
            }
          }

          // =====================================================================
          // FANS: sensor (which temperature drives the curve)
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanReady

            SectionRow {
              width: parent.width
              title: "SENSOR"
              valueText: "CPU " + Model.fmtTemp(root.fan.temps.cpu) + (root.fan.temps.gpu !== null ? "  ·  GPU " + Model.fmtTemp(root.fan.temps.gpu) : "")
            }

            ButtonGroup {
              options: Model.sourceOptions(root.fan.temps)
              value: root.curSource
              fontFamily: root.fontFamily
              foreground: root.foreground
              onChanged: function(val) { root.applySource(val) }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.tab === "fans" && root.fanReady
            foreground: root.foreground
          }

          // =====================================================================
          // FANS: mode
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanReady

            SectionRow {
              width: parent.width
              title: "MODE"
            }

            Segments {
              width: parent.width
              options: Model.modeOptions()
              value: root.curMode
              onChanged: function(v) { root.applyMode(v) }
            }

            Hint {
              width: parent.width
              visible: root.curMode === "curve" && root.fan.service !== "active"
              text: "The curve service isn't running, so the fan stays at its last setting. Switching to Curve starts it."
            }
          }

          // =====================================================================
          // FANS: manual duty
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanReady

            SectionRow {
              width: parent.width
              title: "MANUAL DUTY"
              valueText: root.curManual + "%  ·  " + Model.dutyToRpm(root.curManual, root.fan.fanRange) + " RPM"
            }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.curManual
              opacity: root.curMode === "manual" ? 1.0 : 0.6
              onMoved: function(v) { root.curManual = Math.round(v) }
              onReleased: function(v) { root.applyManual(v) }
            }

            Hint {
              width: parent.width
              text: root.curMode === "manual"
                ? "0% is the EC's minimum (" + root.fan.fanRange[0] + " RPM), 100% its maximum (" + root.fan.fanRange[1] + " RPM)"
                : "Only used in Manual mode"
            }
          }

          // =====================================================================
          // FANS: temperature curve
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanReady

            SectionRow {
              width: parent.width
              title: "TEMPERATURE CURVE"
              valueText: Model.curveSummary(root.curveEdit)
            }

            Hint {
              width: parent.width
              text: {
                var duty = Model.curveDuty(root.curveEdit, root.fan.temp)
                if (duty === null) return "Waiting for a temperature reading"
                return "Now at " + Model.fmtTemp(root.fan.temp) + " this curve runs the fan at " + Math.round(duty) + "% (" + Model.dutyToRpm(duty, root.fan.fanRange) + " RPM)"
              }
            }

            Repeater {
              model: root.curveEdit.length
              RowLayout {
                id: curveRow
                required property int index
                width: parent.width
                spacing: Style.space(8)

                NumberField {
                  Layout.preferredWidth: Style.space(72)
                  fieldWidth: Style.space(72)
                  from: 20
                  to: 100
                  stepSize: 1
                  value: root.curveEdit[curveRow.index] ? root.curveEdit[curveRow.index][0] : 40
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onModified: function(v) { root.setCurveTemp(curveRow.index, v) }
                }

                Text {
                  text: "°C"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: Qt.darker(root.foreground, 1.4)
                }

                PanelSlider {
                  Layout.fillWidth: true
                  bar: root.bar
                  minimum: 0
                  maximum: 100
                  step: 5
                  integer: true
                  value: root.curveEdit[curveRow.index] ? root.curveEdit[curveRow.index][1] : 0
                  onMoved: function(v) { root.setCurveDuty(curveRow.index, v) }
                  onReleased: function(v) { root.setCurveDuty(curveRow.index, v) }
                }

                Text {
                  Layout.preferredWidth: Style.space(36)
                  horizontalAlignment: Text.AlignRight
                  text: (root.curveEdit[curveRow.index] ? root.curveEdit[curveRow.index][1] : 0) + "%"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.foreground
                }
              }
            }

            Hint {
              width: parent.width
              text: "Set fan speed for each temperature; drag the sliders"
            }

            Button {
              width: parent.width
              text: root.curveDirty ? "Apply curve" : (root.curMode === "curve" ? "Curve active" : "Use this curve")
              iconText: root.curveDirty ? "󰄬" : (root.curMode === "curve" ? "󰈐" : "󰐊")
              bordered: true
              selected: !root.curveDirty && root.curMode === "curve"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.applyCurve()
            }

          }

          PanelSeparator {
            width: parent.width
            visible: root.tab === "fans" && root.fanReady
            foreground: root.foreground
          }

          // =====================================================================
          // FANS: power profile
          // =====================================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "fans" && root.fanReady && root.fan.power !== null

            SectionRow {
              width: parent.width
              title: "POWER PROFILE" + (root.fan.ac ? " (PLUGGED IN)" : " (ON BATTERY)")
              valueText: Model.powerModes[root.curPower] || ""
            }

            Segments {
              width: parent.width
              options: Model.powerOptions()
              value: String(root.curPower)
              onChanged: function(v) { root.applyPower(parseInt(v)) }
            }

            RowLayout {
              width: parent.width
              visible: root.curPower === 4
              PanelSectionHeader { text: "CPU"; foreground: root.foreground }
              ButtonGroup {
                options: Model.boostOptions(Model.cpuBoost)
                value: String(root.curCpuBoost)
                fontFamily: root.fontFamily
                foreground: root.foreground
                onChanged: function(val) { root.applyPower(4, parseInt(val), undefined) }
              }
            }

            RowLayout {
              width: parent.width
              visible: root.curPower === 4
              PanelSectionHeader { text: "GPU"; foreground: root.foreground }
              ButtonGroup {
                options: Model.boostOptions(Model.gpuBoost)
                value: String(root.curGpuBoost)
                fontFamily: root.fontFamily
                foreground: root.foreground
                onChanged: function(val) { root.applyPower(4, undefined, parseInt(val)) }
              }
            }

            Hint {
              width: parent.width
              text: "Silent caps the fans and clocks; Gaming and Creator raise the power limits. Profiles are stored separately for mains and battery."
            }
          }
        }
      }
    }
  }
}
