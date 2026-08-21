import QtQuick
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "codefriendly.hackertyper"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var hacker: null
  property int cursorIndex: 0
  property string pendingScreenName: ""

  readonly property var barIdentity: hostWidget || root
  readonly property int launchIndex: 1
  readonly property var languageOptions: {
    var options = []
    var sources = hacker && hacker.sources ? hacker.sources : []
    for (var i = 0; i < sources.length; i++) {
      options.push({ value: sources[i].id, label: sources[i].language })
    }
    return options
  }

  function open() {
    cursorIndex = 0
    controller.show()
  }

  function moveCursor(delta) {
    cursorIndex = Math.max(0, Math.min(launchIndex, cursorIndex + delta))
  }

  function activateCursor() {
    if (!hacker) return
    if (cursorIndex === launchIndex) {
      launchSelected()
      return
    }
    languageDropdown.toggle()
  }

  function screenName() {
    if (bar && bar.screen) return String(bar.screen.name || "")
    if (!anchorItem || !anchorItem.QsWindow) return ""
    var window = anchorItem.QsWindow.window
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function launchSelected() {
    if (!hacker || !hacker.sourceText) return
    pendingScreenName = screenName()
    close()
    launchDelay.restart()
  }

  Connections {
    target: root.hacker
    function onSelectedSourceIdChanged() {
      languageDropdown.value = root.hacker.selectedSourceId
    }
  }

  Timer {
    id: launchDelay
    interval: 120
    repeat: false
    onTriggered: if (root.hacker) root.hacker.launch(root.pendingScreenName)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: languageDropdown.popupOpen

      onMoveRequested: function(dx, dy) {
        if (dy < 0) root.moveCursor(-1)
        else if (dy > 0) root.moveCursor(1)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.moveCursor(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.panelGap

        PanelHero {
          width: parent.width
          title: "Hacker Typer"
          meta: ""
          foreground: root.bar ? root.bar.foreground : Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.fontFamily
          iconComponent: Component {
            Text {
              text: ">_"
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
            }
          }
        }

        Row {
          width: parent.width
          height: languageDropdown.implicitHeight
          spacing: Style.spacing.md

          Text {
            width: parent.width - languageDropdown.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "SELECT LANGUAGE"
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }

          Dropdown {
            id: languageDropdown
            width: Math.min(Style.space(190), parent.width * 0.56)
            value: root.hacker ? root.hacker.selectedSourceId : ""
            options: root.languageOptions
            showLabel: false
            foreground: root.bar ? root.bar.foreground : Color.popups.text
            fontFamily: root.bar ? root.bar.fontFamily : Style.fontFamily
            hasCursor: root.cursorIndex === 0

            onChanged: function(sourceId) {
              if (root.hacker) root.hacker.selectSource(sourceId)
              root.cursorIndex = 0
            }
            onHovered: function(isHovered) {
              if (isHovered) root.cursorIndex = 0
            }
          }
        }

        Button {
          width: parent.width
          text: root.hacker && root.hacker.sourceText ? "Launch" : "Loading source…"
          foreground: Color.accent
          fontFamily: root.bar ? root.bar.fontFamily : Style.fontFamily
          bordered: true
          focusable: true
          enabled: root.hacker && root.hacker.sourceText.length > 0
          active: enabled
          hasCursor: root.cursorIndex === root.launchIndex

          onClicked: {
            root.cursorIndex = root.launchIndex
            root.launchSelected()
          }
        }
      }
    }
  }
}
