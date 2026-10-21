
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "lib/Model.js" as Model

// Curated services in the Omarchy bar.
//
// The bar shows one glyph and a warning dot. The panel has three lists:
// pinned services, everything running on this machine, and services found on
// the local network. Pinning writes one line to ~/.config/omarchy/services.conf;
// unpinning comments that line out so re-pinning is one click.
Panel {
  id: root
  moduleName: "io.github.nam.services"
  ipcTarget: "io.github.nam.services"
  manageIpc: false

  property string tab: "pinned"
  property bool showAll: false

  readonly property color fg: Commons.Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.14)
  readonly property color selectedFill: Commons.Color.menu.selectedBackground
  readonly property string fontFamily: Style.font.family

  function toneFor(state) {
    if (state === "active") return Commons.Color.accent
    if (state === "failed") return Commons.Color.urgent
    if (state === "missing") return Qt.rgba(fg.r, fg.g, fg.b, 0.35)
    if (state === "inactive" || state === "unknown") return Commons.Color.muted
    return Commons.Color.muted
  }

  function actionVerbFor(state) {
    if (state === "active") return "stop"
    if (state === "failed") return "restart"
    return "start"
  }

  function rowState(row) {
    var probeKey = row.kind === "network" ? String(row.host) + ":" + row.port : ""
    if (row.state !== undefined) return row.state
    if (row.kind === "network") {
      if (row.pinned && services.probes[probeKey] === true) return "active"
      if (row.pinned && services.probes[probeKey] === false) return "inactive"
      return "unknown"
    }
    if (row.available === false) return "missing"
    return row.active ? "active" : "inactive"
  }

  function togglePin(row) {
    if (!row) return
    if (row.pinned) services.unpin(row.id)
    else services.pin(row.entry)
  }

  function cycleTab(direction) {
    var order = ["pinned", "machine", "network"]
    var index = order.indexOf(tab)
    tab = order[(index + (direction < 0 ? order.length - 1 : 1)) % order.length]
  }

  function switchTab(name) {
    if (tab === name) return
    tab = name
    if (name === "machine") services.refresh()
  }

  readonly property var pinnedRowsData: Model.pinnedRows(services.pinnedEntries, services.context)
  readonly property var machineRowsData: Model.machineRows(
    services.systemUnits, services.userUnits, services.listeners,
    services.entries, showAll, services.docker.containers)
  readonly property var networkRowsData: Model.networkRows(services.network, services.entries)

  readonly property string summaryText: {
    if (services.summary.total === 0) return "Nothing pinned yet"
    var text = services.summary.total + " pinned · " + services.summary.running + " running"
    if (services.summary.issues > 0) text += " · " + services.summary.issues + " to check"
    return text
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      services.refresh()
      if (tab === "network" && services.network.hosts.length === 0 && !services.scanning)
        services.scanNetwork()
    } else {
      services.actionError = ""
      services.actionMessage = ""
    }
  }

  Service {
    id: services
    settings: root.settings
  }

  // The panel owns its IPC surface so pins can be scripted (and tested)
  // without a pointer. Inputs are validated by the same model as the UI.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { services.refresh(); return "ok" }
    function tab(name: string): string { root.switchTab(String(name)); return root.tab }
    function scan(): string { services.scanNetwork(); return services.scanning ? "scanning" : "idle" }
    function pin(entryJson: string): string {
      var entry
      try {
        entry = JSON.parse(entryJson)
      } catch (e) {
        return "invalid json"
      }
      var problem = Model.validateEntry(entry)
      if (problem !== "") return "invalid: " + problem
      services.pin(entry)
      return "pinned"
    }
    function unpin(id: string): string {
      services.unpin(String(id))
      return "unpinned"
    }
    function status(): string {
      return JSON.stringify({
        summary: services.summary,
        pinned: services.pinnedEntries.map(function(entry) { return entry.id }),
        probes: services.probes,
        loading: services.loading,
        error: services.lastError
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    useActiveColor: false
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰒓"
          color: services.summary.issues > 0 ? Commons.Color.urgent
            : (services.summary.running > 0 ? root.barForeground : Qt.darker(root.barForeground, 1.5))
          font.family: root.fontFamily
          font.pixelSize: Style.space(13)
        }
        Rectangle {
          visible: services.summary.issues > 0
          width: Style.space(4)
          height: width
          radius: width / 2
          color: Commons.Color.urgent
          anchors {
            right: parent.right
            top: parent.top
            rightMargin: Style.space(1)
            topMargin: Style.space(1)
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) services.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(Style.space(520), Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.cycleTab(direction) }
      onTextKey: function(text) {
        if (text === "1") root.switchTab("pinned")
        else if (text === "2") root.switchTab("machine")
        else if (text === "3") root.switchTab("network")
        else if (text === "r" || text === "R") services.refresh()
        else if ((text === "s" || text === "S") && root.tab === "network") services.scanNetwork()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // Header ---------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(headerText.implicitHeight, refreshButton.implicitHeight)

            Column {
              id: headerText
              width: parent.width - refreshButton.width - Style.space(10)
              spacing: Style.space(1)

              Text {
                text: "Services"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
              }
              Text {
                text: root.summaryText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              id: refreshButton
              width: Style.space(26)
              height: width
              anchors.right: parent.right
              anchors.top: parent.top
              Rectangle {
                anchors.fill: parent
                radius: Style.space(6)
                color: refreshMouse.containsMouse ? root.selectedFill : "transparent"
              }
              Text {
                anchors.centerIn: parent
                text: services.loading ? "…" : "↻"
                color: refreshMouse.containsMouse ? Commons.Color.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                id: refreshMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: services.refresh()
              }
            }
          }

          // Tabs -----------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(4)

            TabChip {
              label: "Pinned"
              count: services.summary.total
              selected: root.tab === "pinned"
              onClicked: root.switchTab("pinned")
            }
            TabChip {
              label: "This machine"
              selected: root.tab === "machine"
              onClicked: root.switchTab("machine")
            }
            TabChip {
              label: "Network"
              selected: root.tab === "network"
              onClicked: root.switchTab("network")
            }
          }

          // Messages -------------------------------------------------------
          Text {
            visible: services.configErrorText !== ""
            width: parent.width
            text: services.configErrorText
            color: Commons.Color.urgent
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: services.lastError !== ""
            width: parent.width
            text: services.lastError
            color: Commons.Color.urgent
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: services.actionMessage !== "" || services.actionError !== ""
            width: parent.width
            text: services.actionMessage !== "" ? services.actionMessage : services.actionError
            color: services.actionError !== "" ? Commons.Color.urgent : root.dim
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Pinned ---------------------------------------------------------
          Text {
            visible: root.tab === "pinned" && root.pinnedRowsData.length === 0
            width: parent.width
            text: "Nothing pinned yet. Open “This machine” or “Network”, then tap ☆ to pin a service here."
            color: root.dim
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            topPadding: Style.space(6)
            bottomPadding: Style.space(6)
          }

          Repeater {
            model: root.tab === "pinned" ? root.pinnedRowsData : []
            delegate: ServiceRow {
              width: column.width
              title: modelData.title
              subtitle: modelData.subtitle
              serviceState: modelData.state
              stateLabel: modelData.stateLabel
              pinned: true
              showAction: modelData.kind === "unit" || modelData.kind === "container"
              actionVerb: root.actionVerbFor(modelData.state)
              actionEnabled: !services.acting
              onPinClicked: services.unpin(modelData.id)
              onActionClicked: services.runAction(modelData.entry)
            }
          }

          // This machine ---------------------------------------------------
          Row {
            visible: root.tab === "machine"
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: services.summary.total
                ? "Running now · " + root.machineRowsData.length
                : "Running now · " + root.machineRowsData.length
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            TabChip {
              label: root.showAll ? "All units" : "Active only"
              selected: root.showAll
              onClicked: root.showAll = !root.showAll
            }
          }

          Text {
            visible: root.tab === "machine" && !services.dockerAvailable
            width: parent.width
            text: "Containers are not listed: Docker's socket is not accessible to this user."
            color: root.dim
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.tab === "machine" && root.machineRowsData.length === 0
            width: parent.width
            text: services.loading ? "Looking around…" : "No running services found."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.tab === "machine" ? root.machineRowsData : []
            delegate: ServiceRow {
              width: column.width
              title: modelData.title
              subtitle: modelData.subtitle
              serviceState: root.rowState(modelData)
              stateLabel: modelData.scope === "user" ? "user" : (modelData.scope === "local" ? "this computer" : "system")
              pinned: modelData.pinned
              showAction: false
              onPinClicked: root.togglePin(modelData)
            }
          }

          // Network --------------------------------------------------------
          Item {
            visible: root.tab === "network"
            width: parent.width
            implicitHeight: scanButton.implicitHeight

            TabChip {
              id: scanButton
              label: services.scanning ? "Stop scanning" : "Scan network"
              selected: services.scanning
              showCount: false
              onClicked: services.scanNetwork()
            }

            Text {
              visible: services.network.scannedAt > 0 && !services.scanning
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "last scan " + new Date(services.network.scannedAt * 1000).toLocaleTimeString(Qt.locale(), "hh:mm")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.tab === "network"
            width: parent.width
            text: services.scanning
              ? "Looking at neighbours, mDNS, and your tailnet. Only private addresses are probed."
              : "Finds neighbours, mDNS services, and tailnet peers, then checks a short port list. Stays on this machine."
            color: root.dim
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.tab === "network" ? services.network.warnings : []
            delegate: Text {
              width: column.width
              text: "• " + modelData
              color: Commons.Color.urgent
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.tab === "network" && !services.scanning && services.network.hosts.length === 0
            width: parent.width
            text: services.network.scannedAt > 0
              ? "Nothing answered on the private network or tailnet."
              : "No scan yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.tab === "network" ? root.networkRowsData : []
            delegate: ServiceRow {
              width: column.width
              title: modelData.title
              subtitle: modelData.subtitle
              serviceState: root.rowState(modelData)
              stateLabel: ""
              pinned: modelData.pinned
              showAction: false
              onPinClicked: root.togglePin(modelData)
            }
          }

          // Footer ---------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: footer.implicitHeight + Style.space(4)
            Text {
              id: footer
              width: parent.width
              text: "1 2 3 switch · r refresh · s scan · esc close"
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }
    }
  }

  component TabChip: Rectangle {
    id: chip
    property string label: ""
    property int count: -1
    property bool selected: false
    property bool showCount: true
    signal clicked()

    implicitWidth: chipText.implicitWidth + Style.space(18) + (chip.count >= 0 && chip.showCount ? countText.implicitWidth + Style.space(6) : 0)
    implicitHeight: Style.space(26)
    radius: Style.space(6)
    color: chip.selected ? root.selectedFill : (chipMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent")
    border.width: 1
    border.color: chip.selected ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.45) : root.hairline

    Text {
      id: chipText
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(9)
      text: chip.label
      color: chip.selected ? Commons.Color.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: countText
      visible: chip.count >= 0 && chip.showCount
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      text: chip.count
      color: chip.selected ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  component ServiceRow: Rectangle {
    id: row
    property string title: ""
    property string subtitle: ""
    property string serviceState: "unknown"
    property string stateLabel: ""
    property bool pinned: false
    property bool showAction: false
    property string actionVerb: "start"
    property bool actionEnabled: true
    signal pinClicked()
    signal actionClicked()

    width: column.width
    implicitHeight: Math.max(Style.space(44), textColumn.implicitHeight + Style.space(14))
    radius: Style.space(6)
    color: rowHover.containsMouse || pinHover.containsMouse || actionHover.containsMouse
      ? root.selectedFill : "transparent"

    Rectangle {
      id: dot
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.toneFor(row.serviceState)
      anchors {
        left: parent.left
        leftMargin: Style.space(10)
        verticalCenter: parent.verticalCenter
      }
    }

    Column {
      id: textColumn
      spacing: Style.space(1)
      anchors {
        left: dot.right
        leftMargin: Style.space(10)
        right: actions.left
        rightMargin: Style.space(10)
        verticalCenter: parent.verticalCenter
      }

      Text {
        width: parent.width
        text: row.title
        color: root.fg
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        text: row.subtitle + (row.stateLabel !== "" ? " · " + row.stateLabel : "")
        color: root.dim
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: actions
      spacing: Style.space(2)
      anchors {
        right: parent.right
        rightMargin: Style.space(6)
        verticalCenter: parent.verticalCenter
      }

      Text {
        id: actionText
        visible: row.showAction
        text: row.actionVerb
        color: row.actionEnabled
          ? (actionHover.containsMouse ? Commons.Color.accent : root.dim)
          : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        topPadding: Style.space(6)
        bottomPadding: Style.space(6)

        MouseArea {
          id: actionHover
          anchors.fill: parent
          hoverEnabled: true
          enabled: row.actionEnabled
          cursorShape: Qt.PointingHandCursor
          onClicked: row.actionClicked()
        }
      }

      Text {
        id: pinText
        text: row.pinned ? "★" : "☆"
        color: row.pinned
          ? Commons.Color.accent
          : (pinHover.containsMouse ? root.fg : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        leftPadding: Style.space(6)
        rightPadding: Style.space(8)
        topPadding: Style.space(6)
        bottomPadding: Style.space(6)

        MouseArea {
          id: pinHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: row.pinClicked()
        }
      }
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }
  }
}
