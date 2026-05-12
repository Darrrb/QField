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

  // ---------- Settings ----------
  property int repeatSeconds: 5   // default (Breach) alarms repeat every N seconds while breaching
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
    source: Qt.resolvedUrl("geofence_breach.wav")
    volume: 0.9
  }

  SoundEffect {
    id: warningSound
    source: Qt.resolvedUrl("geofence_warning.wav")
    volume: 0.9
  }

  SoundEffect {
    id: infoSound
    source: Qt.resolvedUrl("geofence_info.wav")
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

  function checkAndHandleTrespass() {
    const isTrespassMode = (gf.behavior === Geofencer.AlertWhenInsideGeofencedArea)
    if (isTrespassMode && gf.isWithin) {
      if (!root.breaching) {
        const data = root.parseAreaData(gf.isWithinAreaName)
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

      // Acknowledge button (does NOT stop beeping; it changes messaging)
      Rectangle {
        id: ackButton
        width: 260
        height: 56
        radius: 14
        opacity: 0.95
        border.width: 2
        border.color: "#ffffff"
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.isBreachType

        Text {
          anchors.centerIn: parent
          text: root.breachAcknowledged ? "Acknowledged" : "Acknowledge"
          font.pixelSize: 18
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.isBreachType && !root.breachAcknowledged
          onClicked: {
            root.breachAcknowledged = true
            root.toast("Breach acknowledged (alarm will continue until zone exited)")
          }
        }
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
        "Geofence trespass alarm\n" +
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
  // BUTTONS (middle-left)
  // ============================================================

  // 🧪 toggles alarm test menu
  Rectangle {
    id: alarmTestButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.alarmTestMenuVisible ? root.colorActive : root.colorInactive

    Text { anchors.centerIn: parent; text: "🧪"; font.pixelSize: 16 }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.alarmTestMenuVisible = !root.alarmTestMenuVisible
        root.toast("Alarm test menu " + (root.alarmTestMenuVisible ? "ON" : "OFF"))
      }
    }
  }

  Rectangle {
    id: alarmTestMenu
    visible: root.alarmTestMenuVisible
    width: 220
    height: 230
    radius: 10
    opacity: 0.80
    color: "#202020"
    border.width: 2
    border.color: "#ffffff"
    z: root.zIndexBase + 2

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
    }
  }

  // 🐞 toggles debug panel
  Rectangle {
    id: debugButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.debugOverlayEnabled ? root.colorActive : root.colorInactive

    Text { anchors.centerIn: parent; text: "🐞"; font.pixelSize: 18 }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.debugOverlayEnabled = !root.debugOverlayEnabled
        root.toast("Debug panel " + (root.debugOverlayEnabled ? "ON" : "OFF"))
      }
    }
  }

  // 🚨 toggles BIG breach overlay (feature toggle)
  Rectangle {
    id: breachButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.breachOverlayEnabled ? root.colorActive : root.colorInactive

    Text { anchors.centerIn: parent; text: "🚨"; font.pixelSize: 18 }

    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.breachOverlayEnabled = !root.breachOverlayEnabled
        root.toast("Breach overlay " + (root.breachOverlayEnabled ? "ON" : "OFF"))
      }
    }
  }

  // Sync placeholder button
  Rectangle {
    id: syncButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.colorInactive

    Text {
      anchors.centerIn: parent
      text: "🔄"
      font.pixelSize: 15
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.onSyncPressed()
    }
  }

  // Save placeholder button
  Rectangle {
    id: saveButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.colorInactive

    Text {
      anchors.centerIn: parent
      text: "💾"
      font.pixelSize: 15
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.onSavePressed()
    }
  }

  // Rotate map clockwise button
  Rectangle {
    id: rotateClockwiseButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.colorInactive

    Text {
      anchors.centerIn: parent
      text: "↩️"
      font.pixelSize: 20
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.rotateClockwise()
    }
  }

  // Rotate map counter-clockwise button
  Rectangle {
    id: rotateCounterClockwiseButton
    width: 38
    height: 38
    radius: 19
    z: root.zIndexBase + 1
    opacity: 0.88
    color: root.colorInactive

    Text {
      anchors.centerIn: parent
      text: "↪️"
      font.pixelSize: 20
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.rotateCounterClockwise()
    }
  }

  // Test button for dashboard toolbar
  QFieldItems.QfToolButton {
    id: dashboardTestButton
    iconSource: Theme.getThemeVectorIcon("ic_info_outline_24dp")
    bgcolor: Theme.mainColor
    round: true
    visible: true

    onClicked: {
      root.toast("✅ Dashboard test button clicked!", "success")
    }
  }
  

  // ============================================================
  // Wiring / parenting into visible UI
  // ============================================================
  function applySettings(tag) {
    gf.applyProjectSettings(qgisProject)

    // Stop any alarm if not in the right mode / not active / no layer
    if (!gf.active || gf.areasLayer === null) stopBreach()

    // Re-evaluate breach state after applying settings
    const isTrespassMode = (gf.behavior === Geofencer.AlertWhenInsideGeofencedArea)
    if (gf.active && isTrespassMode && gf.isWithin) {
      if (!root.breaching) {
        const data = root.parseAreaData(gf.isWithinAreaName)
        root.startBreach(data.areaName, data.alarmType)
      }
    }
  }

  Timer {
    interval: 600
    running: true
    repeat: false
    onTriggered: {
      toast("✅ Terrex Geofence trespass alarm loaded")

      // Parent debug panel
      panel.parent = iface.mainWindow().contentItem
      panel.anchors.left = panel.parent.left
      panel.anchors.bottom = panel.parent.bottom
      panel.anchors.margins = 16

      // Parent breach overlay (full screen)
      breachOverlay.parent = iface.mainWindow().contentItem
      breachOverlay.anchors.fill = breachOverlay.parent

      // Parent acknowledged badge (top-center)
      acknowledgedBadge.parent = iface.mainWindow().contentItem
      acknowledgedBadge.anchors.horizontalCenter = acknowledgedBadge.parent.horizontalCenter
      acknowledgedBadge.anchors.top = acknowledgedBadge.parent.top
      acknowledgedBadge.anchors.topMargin = 16

      // Parent buttons (middle-left)
      alarmTestButton.parent = iface.mainWindow().contentItem
      alarmTestButton.anchors.left = alarmTestButton.parent.left
      alarmTestButton.anchors.top = alarmTestButton.parent.top
      alarmTestButton.anchors.leftMargin = root.buttonMargin
      alarmTestButton.anchors.topMargin = root.buttonTopOffset

      alarmTestMenu.parent = iface.mainWindow().contentItem
      alarmTestMenu.anchors.left = alarmTestButton.right
      alarmTestMenu.anchors.leftMargin = root.buttonSpacing
      alarmTestMenu.anchors.verticalCenter = alarmTestButton.verticalCenter

      debugButton.parent = iface.mainWindow().contentItem
      debugButton.anchors.left = debugButton.parent.left
      debugButton.anchors.top = alarmTestButton.bottom
      debugButton.anchors.topMargin = root.buttonSpacing
      debugButton.anchors.leftMargin = root.buttonMargin

      breachButton.parent = iface.mainWindow().contentItem
      breachButton.anchors.left = breachButton.parent.left
      breachButton.anchors.top = debugButton.bottom
      breachButton.anchors.topMargin = root.buttonSpacing
      breachButton.anchors.leftMargin = root.buttonMargin

      syncButton.parent = iface.mainWindow().contentItem
      syncButton.anchors.left = syncButton.parent.left
      syncButton.anchors.top = breachButton.bottom
      syncButton.anchors.topMargin = root.buttonSpacing
      syncButton.anchors.leftMargin = root.buttonMargin

      saveButton.parent = iface.mainWindow().contentItem
      saveButton.anchors.left = saveButton.parent.left
      saveButton.anchors.top = syncButton.bottom
      saveButton.anchors.topMargin = root.buttonSpacing
      saveButton.anchors.leftMargin = root.buttonMargin

      rotateClockwiseButton.parent = iface.mainWindow().contentItem
      rotateClockwiseButton.anchors.left = rotateClockwiseButton.parent.left
      rotateClockwiseButton.anchors.top = saveButton.bottom
      rotateClockwiseButton.anchors.topMargin = root.buttonSpacing
      rotateClockwiseButton.anchors.leftMargin = root.buttonMargin

      rotateCounterClockwiseButton.parent = iface.mainWindow().contentItem
      rotateCounterClockwiseButton.anchors.left = rotateCounterClockwiseButton.parent.left
      rotateCounterClockwiseButton.anchors.top = rotateClockwiseButton.bottom
      rotateCounterClockwiseButton.anchors.topMargin = root.buttonSpacing
      rotateCounterClockwiseButton.anchors.leftMargin = root.buttonMargin

      // Add test button to dashboard actions toolbar
      iface.addItemToDashboardActionsToolbar(dashboardTestButton)
      toast("📍 Dashboard test button added to toolbar", "info")

      positionSource = iface.findItemByObjectName("positionSource")
      mapCanvas = iface.findItemByObjectName("mapCanvas")

      if (!positionSource) toast("positionSource NOT FOUND", "error")
      if (!mapCanvas) toast("mapCanvas NOT FOUND", "error")

      applySettings("t=0.6s")
      retry.running = true
    }
  }

  Timer {
    id: retry
    interval: 2000
    running: false
    repeat: false
    onTriggered: applySettings("t=2.6s retry")
  }
}
