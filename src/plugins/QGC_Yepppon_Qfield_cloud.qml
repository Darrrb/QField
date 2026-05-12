// qmllint /disable
import QtQuick
import QtQuick.Controls

import QtMultimedia
import org.qfield
import org.qgis
import Theme

import "qrc:/qml" as QFieldItems
Item {
  id: root

  // ---------- Plugin Info ----------
  readonly property string pluginName: "Terrex Geofence Alarm"
  readonly property string pluginVersion: "1.0.5"

  // ---------- Settings ----------
  property int repeatSeconds: 3   // default (Breach) alarms repeat every N seconds while breaching
  property int warningRepeatSeconds: 10  // WARNING alarms repeat less frequently than breach
  property int infoRepeatSeconds: 60  // INFO alarms repeat less frequently
  property int rotationDegrees: 5  // For rotating map canvas clockwise and counterclockwise

  // Debug overlay (small panel)
  property bool debugOverlayEnabled: false

  // Big breach overlay (full screen)
  property bool breachOverlayEnabled: true

  // If acknowledged, overlay hides but alarm continues until breach ends
  property bool breachAcknowledged: false

  // ---------- UI Constants ----------
  // Z-index layering
  readonly property int zIndexBase: 100000
  readonly property int zIndexOverlay: 200000

  // Color palette
  readonly property color colorActive: "#d32f2f"
  readonly property color colorInactive: "#424242"
  readonly property color colorWarning: "#ff9800"
  readonly property color colorInfo: "#4caf50"
  readonly property color colorBreach: "#ff0000"

  // Spacing and layout
  readonly property int buttonMargin: 12
  readonly property int buttonSpacing: 10
  readonly property int buttonTopOffset: 100

  function toast(msg, kind) {
    iface.mainWindow().displayToast(msg, kind ? kind : "")
  }

  function onSyncPressed() {
    root.toast("Sync pressed")
  }

  function onSavePressed() {
    root.toast("Save pressed")
  }

  function rotateClockwise() {
    if (mapCanvas && mapCanvas.mapSettings) {
      mapCanvas.mapSettings.rotation += root.rotationDegrees
      root.toast("Rotated " + root.rotationDegrees + "° clockwise")
    }
  }

  function rotateCounterClockwise() {
    if (mapCanvas && mapCanvas.mapSettings) {
      mapCanvas.mapSettings.rotation -= root.rotationDegrees
      root.toast("Rotated " + root.rotationDegrees + "° counter-clockwise")
    }
  }

  // ---------- Audio ----------
  SoundEffect {
    id: trespassSound
    source: Qt.resolvedUrl("assets/geofence_breach.wav")
    volume: 0.9
  }

  SoundEffect {
    id: warningSound
    source: Qt.resolvedUrl("assets/geofence_warning.wav")
    volume: 0.9
  }

  SoundEffect {
    id: infoSound
    source: Qt.resolvedUrl("assets/geofence_info.wav")
    volume: 0.9
  }

  // ---------- QField refs ----------
  property var positionSource: null
  property var mapCanvas: null

  // ---------- State ----------
  property bool breaching: false
  property string breachAreaName: ""
  property string alarmType: ""
  property bool alarmTestMenuVisible: false
  property bool debugModeEnabled: false  // Hidden debug mode
  property int downgradeConfirmChecks: 2
  property string pendingDowngradeAreaName: ""
  property string pendingDowngradeType: ""
  property int pendingDowngradeHits: 0
  readonly property string alarmTypeNormalized: normalizeAlarmType(alarmType)
  readonly property bool isBreachType: alarmTypeNormalized === "BREACH"
  readonly property bool isWarningType: alarmTypeNormalized === "WARNING"
  readonly property bool isInfoType: alarmTypeNormalized === "INFO"

  function normalizeAlarmType(value) {
    if (value === undefined || value === null) return "BREACH"
    var t = String(value).trim().toUpperCase()
    if (t === "") return "BREACH"
    return t
  }

  // Expected format from layer display expression: "Name|AlarmType"
  function parseAreaData(rawValue) {
    var name = rawValue ? String(rawValue) : ""
    var type = ""
    var idx = name.indexOf("|")
    if (idx !== -1) {
      type = name.slice(idx + 1).trim()
      name = name.slice(0, idx).trim()
    }
    return { areaName: name, alarmType: type }
  }

  function alarmSoundFor(type) {
    var t = normalizeAlarmType(type)
    if (t === "WARNING") return warningSound
    if (t === "INFO") return infoSound
    return trespassSound
  }

  function alarmBorderColorFor(type) {
    var t = normalizeAlarmType(type)
    if (t === "WARNING") return root.colorWarning
    if (t === "INFO") return root.colorInfo
    return root.colorBreach
  }

  function alarmSeverityFor(type) {
    var t = normalizeAlarmType(type)
    if (t === "BREACH") return 3
    if (t === "WARNING") return 2
    if (t === "INFO") return 1
    return 3
  }

  function clearPendingDowngrade() {
    root.pendingDowngradeAreaName = ""
    root.pendingDowngradeType = ""
    root.pendingDowngradeHits = 0
  }

  function shouldUpdateActiveAlarm(areaName, type) {
    if (!root.breaching) return true

    var nextType = normalizeAlarmType(type)
    var currentType = normalizeAlarmType(root.alarmType)
    var currentSeverity = root.alarmSeverityFor(currentType)
    var nextSeverity = root.alarmSeverityFor(nextType)
    var nextAreaName = String(areaName)
    var currentAreaName = String(root.breachAreaName)
    var areaChanged = nextAreaName !== currentAreaName
    var typeChanged = nextType !== currentType

    // Escalate immediately.
    if (nextSeverity > currentSeverity) {
      root.clearPendingDowngrade()
      return true
    }

    // Same severity: keep state in sync without any debounce.
    if (nextSeverity === currentSeverity) {
      root.clearPendingDowngrade()
      return areaChanged || typeChanged
    }

    // Downgrade only after repeated consistent lower-severity readings.
    if (!areaChanged && !typeChanged) return false

    if (root.pendingDowngradeAreaName === nextAreaName && root.pendingDowngradeType === nextType) {
      root.pendingDowngradeHits += 1
    } else {
      root.pendingDowngradeAreaName = nextAreaName
      root.pendingDowngradeType = nextType
      root.pendingDowngradeHits = 1
    }

    if (root.pendingDowngradeHits >= root.downgradeConfirmChecks) {
      root.clearPendingDowngrade()
      return true
    }

    return false
  }

  function checkAndHandleTrespass() {
    const isTrespassMode = (gf.behavior === Geofencer.AlertWhenInsideGeofencedArea)
    if (isTrespassMode && gf.isWithin) {
      const data = root.parseAreaData(gf.isWithinAreaName)
      if (root.shouldUpdateActiveAlarm(data.areaName, data.alarmType)) {
        root.startBreach(data.areaName, data.alarmType)
      }
    } else {
      root.stopBreach()
    }
  }

  Timer {
    id: repeatTimer
    interval: root.repeatSeconds * 1000
    running: false
    repeat: true
    onTriggered: {
      if (root.breaching) {
        var snd = root.alarmSoundFor(root.alarmType)
        if (snd) snd.play()
      } else {
        running = false
      }
    }
  }

  function startBreach(areaName, type) {
    root.clearPendingDowngrade()
    root.breaching = true
    root.breachAreaName = areaName
    root.alarmType = type ? String(type) : ""
    root.breachAcknowledged = false

    // Set interval based on alarm type
    if (root.isInfoType) {
      repeatTimer.interval = root.infoRepeatSeconds * 1000
    } else if (root.isWarningType) {
      repeatTimer.interval = root.warningRepeatSeconds * 1000
    } else {
      repeatTimer.interval = root.repeatSeconds * 1000
    }

    // Immediate beep on trespass
    var snd = root.alarmSoundFor(root.alarmType)
    if (snd) snd.play()

    // Then keep beeping every N seconds
    repeatTimer.start()
  }

  function stopBreach() {
    root.clearPendingDowngrade()
    root.breaching = false
    root.breachAreaName = ""
    root.alarmType = ""
    root.breachAcknowledged = false
    repeatTimer.stop()
  }

  function runAlarmTest(type) {
    var t = normalizeAlarmType(type)
    root.startBreach("Manual alarm test", t)
    root.toast("Testing " + t + " alarm")
  }

  // ---------- Geofencer ----------
  Geofencer {
    id: gf
    position: positionSource ? positionSource.projectedPosition : undefined
    positionCrs: mapCanvas ? mapCanvas.mapSettings.destinationCrs : undefined

    // Match QField's "trespassed into" semantics:
    // behavior == AlertWhenInsideGeofencedArea AND isWithin == true
    onIsWithinChanged: root.checkAndHandleTrespass()
    onPositionChanged: root.checkAndHandleTrespass()
    onBehaviorChanged: root.checkAndHandleTrespass()
    onActiveChanged: { if (!gf.active) root.stopBreach() }
  }

  // ============================================================
  // BIG BREACH OVERLAY (covers most of the screen)
  // ============================================================
  Rectangle {
    id: breachOverlay
    visible: root.breachOverlayEnabled && root.breaching
    z: root.zIndexOverlay
    color: (root.isBreachType && !root.breachAcknowledged) ? "#000000" : "transparent"

    // base fill (semi transparent)
    opacity: (root.isBreachType && !root.breachAcknowledged) ? 0.55 : 1.0

    // Gentle pulsing background to grab attention
    SequentialAnimation on opacity {
      running: breachOverlay.visible && root.isBreachType
      loops: Animation.Infinite
      NumberAnimation { to: 0.45; duration: 450 }
      NumberAnimation { to: 0.65; duration: 450 }
    }

    // Big flashing border
    Rectangle {
      id: border
      anchors.fill: parent
      color: "transparent"
      border.width: 18
      border.color: root.alarmBorderColorFor(root.alarmType)
      z: root.zIndexOverlay + 1

      // Flash the border opacity
      SequentialAnimation on opacity {
        running: breachOverlay.visible
        loops: Animation.Infinite
        NumberAnimation {
          to: root.isBreachType ? 0.15 : 0.6
          duration: root.isBreachType ? 300 : 1000
        }
        NumberAnimation {
          to: 1.0
          duration: root.isBreachType ? 300 : 1000
        }
      }
    }

    // Block interaction behind overlay
    MouseArea {
      anchors.fill: parent
      enabled: root.isBreachType && !root.breachAcknowledged
      onClicked: {} // swallow taps
    }

    Column {
      visible: root.isBreachType && !root.breachAcknowledged
      anchors.centerIn: parent
      spacing: 14
      width: Math.min(parent.width * 0.9, 900)

      Text {
        text: root.isBreachType && root.breachAcknowledged
              ? "⚠️ BREACH ACKNOWLEDGED ⚠️"
              : ("⚠️ GEOFENCE " + root.alarmTypeNormalized + " ⚠️")
        font.pixelSize: 34
        horizontalAlignment: Text.AlignHCenter
        width: parent.width
      }

      Text {
        text: (root.breachAreaName && root.breachAreaName !== "")
              ? ("Trespassed into:\n“" + root.breachAreaName + "”")
              : "You are in a restricted area"
        font.pixelSize: 22
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        width: parent.width
      }

      Text {
        text: root.isBreachType
          ? (root.breachAcknowledged
             ? "Alarm will continue until you exit the area."
             : "Leave the area immediately.")
          : (root.isWarningType
             ? "Proceed with caution."
             : "Information only.")
        font.pixelSize: 20
        horizontalAlignment: Text.AlignHCenter
        width: parent.width
      }
    }
  }

  // Acknowledge button (outside overlay to avoid opacity inheritance)
  Rectangle {
    id: ackButton
    visible: root.breachOverlayEnabled && root.breaching && root.isBreachType && !root.breachAcknowledged
    z: root.zIndexOverlay + 5
    width: 260
    height: 56
    radius: 14
    color: "#d32f2f"
    border.width: 3
    border.color: "#ffffff"

    Text {
      anchors.centerIn: parent
      text: "Acknowledge"
      font.pixelSize: 18
      color: "white"
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.breachAcknowledged = true
        root.toast("Breach acknowledged (alarm will continue until zone exited)")
      }
    }
  }

  // Small non-blocking status shown after acknowledging while still breaching
  Rectangle {
    id: acknowledgedBadge
    visible: root.breaching && root.breachAcknowledged && root.isBreachType
    z: root.zIndexOverlay + 10
    radius: 10
    opacity: 0.92
    width: Math.min(520, parent ? parent.width * 0.9 : 520)
    height: 66
    border.width: 2
    border.color: "#ffffff"

    Text {
      anchors.fill: parent
      anchors.margins: 10
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      wrapMode: Text.Wrap
      font.pixelSize: 18
      text: (root.breachAreaName && root.breachAreaName !== "")
            ? ("Breach acknowledged: still inside “" + root.breachAreaName + "”")
            : "Breach acknowledged: still inside restricted area"
    }
  }

  // ============================================================
  // DEBUG PANEL (small)
  // ============================================================
  Rectangle {
    id: panel
    visible: root.debugOverlayEnabled
    width: 760
    height: 160
    radius: 12
    opacity: 0.9
    z: root.zIndexBase

    Text {
      anchors.fill: parent
      anchors.margins: 12
      font.pixelSize: 14
      wrapMode: Text.Wrap
      text:
        root.pluginName + " v" + root.pluginVersion + "\n" +
        "active=" + gf.active +
        " behavior=" + gf.behavior +
        " areasLayerSet=" + (gf.areasLayer !== null) + "\n" +
        "within=" + gf.isWithin +
        " breaching=" + root.breaching +
        " alarmType=" + root.alarmTypeNormalized +
        " acknowledged=" + root.breachAcknowledged +
        " interval=" + root.repeatSeconds + "s\n" +
        "area='" + root.breachAreaName + "'"
    }
  }

  // ============================================================
  // TOOLBAR BUTTONS
  // ============================================================
  QfToolButtonDrawer {
    id: terrexToolbar
    bgcolor: Theme.darkGray
    iconSource: Qt.resolvedUrl("assets/terrex_icon.svg")
    round: true

    QfToolButton {
      id: alarmTestButton
      bgcolor: root.alarmTestMenuVisible ? root.colorActive : root.colorInactive
      iconColor: "white"
      text: "🧪"
      width: 38
      height: 38
      round: true
      font.pixelSize: 16
      padding: 0

      onClicked: {
        root.alarmTestMenuVisible = !root.alarmTestMenuVisible
        root.toast("Alarm test menu " + (root.alarmTestMenuVisible ? "ON" : "OFF"))
      }

      onPressAndHold: {
        root.debugModeEnabled = !root.debugModeEnabled
        root.toast("Debug mode " + (root.debugModeEnabled ? "ENABLED" : "DISABLED"), root.debugModeEnabled ? "success" : "")
      }
    }

    QfToolButton {
      id: debugButton
      visible: root.debugModeEnabled
      bgcolor: root.debugOverlayEnabled ? root.colorActive : root.colorInactive
      iconColor: "white"
      text: "🐞"
      width: 38
      height: root.debugModeEnabled ? 38 : 0
      round: true
      font.pixelSize: 18
      padding: 0

      onClicked: {
        root.debugOverlayEnabled = !root.debugOverlayEnabled
        root.toast("Debug panel " + (root.debugOverlayEnabled ? "ON" : "OFF"))
      }
    }

    QfToolButton {
      id: breachButton
      visible: root.debugModeEnabled
      bgcolor: root.breachOverlayEnabled ? root.colorActive : root.colorInactive
      iconColor: "white"
      text: "🚨"
      width: 38
      height: root.debugModeEnabled ? 38 : 0
      round: true
      font.pixelSize: 18
      padding: 0

      onClicked: {
        root.breachOverlayEnabled = !root.breachOverlayEnabled
        root.toast("Breach overlay " + (root.breachOverlayEnabled ? "ON" : "OFF"))
      }
    }

    QfToolButton {
      id: syncButton
      visible: true
      bgcolor: root.colorInactive
      iconColor: "white"
      text: "💾"
      width: 38
      height: 38
      round: true
      font.pixelSize: 15
      padding: 0

      onClicked: {
        var cloudBtn = iface.findItemByObjectName("CloudButton")
        if (cloudBtn) {
          cloudBtn.clicked()
          root.toast("Opening QFieldCloud sync")
        } else {
          root.toast("Cloud button not found", "error")
        }
      }
    }

    QfToolButton {
      id: saveButton
      visible: root.debugModeEnabled
      bgcolor: root.colorInactive
      iconColor: "white"
      text: "🔄"
      width: 38
      height: root.debugModeEnabled ? 38 : 0
      round: true
      font.pixelSize: 15
      padding: 0

      onClicked: root.onSavePressed()
    }

    QfToolButton {
      id: rotateClockwiseButton
      bgcolor: root.colorInactive
      iconColor: "white"
      text: "↩️"
      width: 38
      height: 38
      round: true
      font.pixelSize: 20
      padding: 0

      onClicked: root.rotateClockwise()
    }

    QfToolButton {
      id: rotateCounterClockwiseButton
      bgcolor: root.colorInactive
      iconColor: "white"
      text: "↪️"
      width: 38
      height: 38
      round: true
      font.pixelSize: 20
      padding: 0

      onClicked: root.rotateCounterClockwise()
    }
  }

  Rectangle {
    id: alarmTestMenu
    visible: root.alarmTestMenuVisible
    width: 220
    height: 288
    radius: 10
    opacity: 0.80
    color: "#202020"
    border.width: 2
    border.color: "#ffffff"
    z: root.zIndexOverlay

    Column {
      anchors.fill: parent
      anchors.margins: 10
      spacing: 8

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "Alarm test"
        font.pixelSize: 16
      }

      Rectangle {
        width: parent.width
        height: 38
        radius: 8
        color: root.colorBreach
        Text { anchors.centerIn: parent; text: "Test BREACH"; font.pixelSize: 15 }
        MouseArea {
          anchors.fill: parent
          onClicked: root.runAlarmTest("BREACH")
        }
      }

      Rectangle {
        width: parent.width
        height: 38
        radius: 8
        color: root.colorWarning
        Text { anchors.centerIn: parent; text: "Test WARNING"; font.pixelSize: 15 }
        MouseArea {
          anchors.fill: parent
          onClicked: root.runAlarmTest("WARNING")
        }
      }

      Rectangle {
        width: parent.width
        height: 38
        radius: 8
        color: root.colorInfo
        Text { anchors.centerIn: parent; text: "Test INFO"; font.pixelSize: 15 }
        MouseArea {
          anchors.fill: parent
          onClicked: root.runAlarmTest("INFO")
        }
      }

      Rectangle {
        width: parent.width
        height: 34
        radius: 8
        color: root.colorInactive
        Text { anchors.centerIn: parent; text: "Stop test"; font.pixelSize: 14 }
        MouseArea {
          anchors.fill: parent
          onClicked: {
            root.stopBreach()
            root.toast("Alarm test stopped")
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 34
        radius: 8
        color: "#616161"
        Text { anchors.centerIn: parent; text: "Close Menu"; font.pixelSize: 14 }
        MouseArea {
          anchors.fill: parent
          onClicked: {
            root.stopBreach()
            root.alarmTestMenuVisible = false
            root.toast("Menu closed")
          }
        }
      }
    }
  }

  // ============================================================
  // Wiring / parenting into visible UI
  // ============================================================
  function applySettings(tag) {
    gf.applyProjectSettings(qgisProject)

    // Stop any alarm if not in the right mode / not active / no layer
    if (!gf.active || gf.areasLayer === null) stopBreach()

    // Re-evaluate alarm state after applying settings.
    root.checkAndHandleTrespass()
  }

  Component.onCompleted: {
    toast("✅ " + root.pluginName + " v" + root.pluginVersion + " loaded")

    // Register toolbar with QField
    iface.addItemToPluginsToolbar(terrexToolbar)

    // Parent debug panel
    panel.parent = iface.mainWindow().contentItem
    panel.anchors.left = panel.parent.left
    panel.anchors.bottom = panel.parent.bottom
    panel.anchors.margins = 16

    // Parent breach overlay (full screen)
    breachOverlay.parent = iface.mainWindow().contentItem
    breachOverlay.anchors.fill = breachOverlay.parent

    // Parent acknowledge button (centered below text)
    ackButton.parent = iface.mainWindow().contentItem
    ackButton.anchors.horizontalCenter = ackButton.parent.horizontalCenter
    ackButton.anchors.verticalCenter = ackButton.parent.verticalCenter
    ackButton.anchors.verticalCenterOffset = 120

    // Parent acknowledged badge (top-center)
    acknowledgedBadge.parent = iface.mainWindow().contentItem
    acknowledgedBadge.anchors.horizontalCenter = acknowledgedBadge.parent.horizontalCenter
    acknowledgedBadge.anchors.top = acknowledgedBadge.parent.top
    acknowledgedBadge.anchors.topMargin = 16

    // Parent alarm test menu - center it on screen
    alarmTestMenu.parent = iface.mainWindow().contentItem
    alarmTestMenu.anchors.horizontalCenter = alarmTestMenu.parent.horizontalCenter
    alarmTestMenu.anchors.top = alarmTestMenu.parent.top
    alarmTestMenu.anchors.topMargin = 80

    positionSource = iface.findItemByObjectName("positionSource")
    mapCanvas = iface.findItemByObjectName("mapCanvas")

    if (!positionSource) toast("positionSource NOT FOUND", "error")
    if (!mapCanvas) toast("mapCanvas NOT FOUND", "error")

    applySettings("initial")
    retry.running = true
  }

  Timer {
    id: retry
    interval: 2000
    running: false
    repeat: false
    onTriggered: applySettings("t=2.6s retry")
  }
}
