// SPDX-License-Identifier: MIT
// :: This executable source implements Hacker Typer and provides the QML typing sequence.
// :: The source-loading path reads this file as plain text for the typing surface.
// :: THESIS: A Hacker Typer session should feel like a real terminal overtaken by impossible fluency, refusing decorative dashboard chrome.
// :: OWN-WORLD: The active Omarchy terminal palette, Hyprland border and rounding, monospace font, Ghostty-like padding, plain source text, and a block cursor own the experience.
// :: STORY: Choose a source in the bar, launch it, type anything to release code, trigger access states, then leave cleanly with Escape.
// :: FIRST VIEWPORT: A large centered terminal surface leaves the dimmed desktop visible around its theme-native border and corners.
// :: FORM: Category-standard Hacker Typer, deliberately chosen by the user; concept seed d288db6c.
// :: FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "HackerTyperModel.js" as HackerTyperModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  property string targetScreenName: ""
  property int progress: 0
  property int charactersPerKey: 3
  property bool cursorVisible: true
  property int accessCount: 0
  property int deniedCount: 0
  property string accessState: ""

  readonly property string sourceText: service ? service.sourceText : ""
  readonly property string sourceName: service && service.selectedSource ? service.selectedSource.name : "Source"
  readonly property string renderedText: sourceText.substr(0, progress) + (cursorVisible ? "█" : " ")
  readonly property var targetScreen: resolveScreen(targetScreenName)

  function resolveScreen(requestedName) {
    var wanted = String(requestedName || "")
    if (!wanted && Hyprland.focusedMonitor) wanted = String(Hyprland.focusedMonitor.name || "")
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name || "") === wanted) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  function open(payloadJson) {
    var payload = HackerTyperModel.parsePayload(payloadJson)
    if (service && payload.sourceId) service.selectSource(payload.sourceId)
    targetScreenName = String(payload.screenName || "")
    progress = 0
    accessCount = 0
    deniedCount = 0
    accessState = ""
    cursorVisible = true
    opened = true
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      scrollToEnd()
    })
  }

  function close() {
    opened = false
    accessState = ""
  }

  function dismiss() {
    opened = false
    accessState = ""
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "codefriendly.hackertyper")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function scrollToEnd() {
    terminal.contentY = Math.max(0, terminal.contentHeight - terminal.height)
  }

  function wakeCursor() {
    cursorVisible = true
    cursorTimer.restart()
  }

  function setAccessState(nextState) {
    accessState = nextState
    wakeCursor()
  }

  function isModifierOnly(key) {
    return key === Qt.Key_Shift
      || key === Qt.Key_Control
      || key === Qt.Key_Meta
      || key === Qt.Key_AltGr
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (accessState) accessState = ""
      else dismiss()
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Alt) {
      if (!event.isAutoRepeat) {
        accessCount += 1
        if (accessCount >= 3) {
          accessCount = 0
          setAccessState("granted")
        }
      }
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_CapsLock) {
      if (!event.isAutoRepeat) {
        deniedCount += 1
        if (deniedCount >= 3) {
          deniedCount = 0
          setAccessState("denied")
        }
      }
      event.accepted = true
      return
    }

    if (isModifierOnly(event.key)) {
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Backspace)
      progress = HackerTyperModel.retreat(progress, charactersPerKey, sourceText.length)
    else if (sourceText.length > 0)
      progress = HackerTyperModel.advance(progress, charactersPerKey, sourceText.length)

    wakeCursor()
    Qt.callLater(scrollToEnd)
    event.accepted = true
  }

  Timer {
    id: cursorTimer
    interval: 520
    repeat: true
    running: root.opened
    onTriggered: root.cursorVisible = !root.cursorVisible
  }

  PanelWindow {
    id: window
    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; right: true; bottom: true; left: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-hackertyper"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      Rectangle {
        anchors.fill: parent
        color: Color.menu.scrim
      }

      TapHandler {
        onTapped: keyCatcher.forceActiveFocus()
      }

      BorderSurface {
        id: terminalPanel
        width: Math.max(0, Math.min(parent.width - Style.space(40), Math.round(parent.width * 0.88)))
        height: Math.max(0, Math.min(parent.height - Style.space(40), Math.round(parent.height * 0.84)))
        anchors.centerIn: parent
        color: Color.background
        radius: Style.cornerRadius
        borderSpec: Border.hyprlandActiveSpec(Color.accent, Math.max(1, Style.spacing.hairline))
        clip: true

        Flickable {
          id: terminal
          anchors.fill: parent
          anchors.margins: Style.space(14)
          contentWidth: width
          contentHeight: Math.max(height, codeText.implicitHeight)
          clip: true
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds

          Text {
            id: codeText
            width: terminal.width
            text: root.renderedText
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Math.max(Style.font.subtitle, Style.space(13))
            font.kerning: false
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            lineHeight: 1.18
            lineHeightMode: Text.ProportionalHeight
            renderType: Text.NativeRendering

            onImplicitHeightChanged: Qt.callLater(root.scrollToEnd)
          }
        }

        Text {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(14)
          visible: root.progress === 0 && !root.accessState
          text: root.sourceText
            ? "TYPE ANYTHING  ·  ESC TO EXIT"
            : (root.service && root.service.sourceError ? root.service.sourceError : "LOADING SOURCE…")
          color: Util.alpha(Color.foreground, 0.48)
          font.family: Style.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.8
        }

        Rectangle {
          id: accessCard
          visible: root.accessState !== ""
          width: Math.min(parent.width - Style.space(40), Style.space(420))
          height: messageColumn.implicitHeight + Style.space(38)
          anchors.centerIn: parent
          color: Color.background
          radius: Style.cornerRadius
          border.width: Math.max(1, Style.spacing.hairline)
          border.color: root.accessState === "granted" ? Color.accent : Color.urgent

          Column {
            id: messageColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(36)
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              text: root.accessState === "granted" ? "ACCESS GRANTED" : "ACCESS DENIED"
              color: root.accessState === "granted" ? Color.accent : Color.urgent
              font.family: Style.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: "ESC TO DISMISS"
              color: Util.alpha(Color.foreground, 0.58)
              font.family: Style.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.8
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
