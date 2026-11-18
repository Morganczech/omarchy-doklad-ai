import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Talks to doklad.py. Snapshots are read on a timer; actions run one at a time
// with their payload written to the helper's stdin, so no accounting data or
// credentials ever appear in a process command line.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  property bool privacy: false
  property string language: "en"

  // Period shown in the panel. Changing it re-projects cached data without a network call.
  property string horizon: "month"
  property int offset: 0

  property var snapshot: Model.emptySnapshot("loading")
  readonly property string status: snapshot.status
  readonly property bool hasData: snapshot.hasData
  readonly property bool loading: probeProc.running
  readonly property bool busy: actionProc.running
  property string busyAction: ""
  property string busyTag: ""

  signal actionFinished(string tag, var result)

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("doklad.py")).replace(/^file:\/\//, ""))
  readonly property var helperBase: ["/usr/bin/python3", "-I", "-B", helperPath]

  property string _queuedMode: ""
  property string _runningPeriod: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  readonly property int openRefreshSec: intSetting("openRefreshSec", 60, 15, 600)
  readonly property int closedRefreshSec: intSetting("closedRefreshSec", 300, 60, 3600)
  readonly property int turnoverLimit: intSetting("vatLimitCzk", 2000000, 0, 50000000)
  readonly property bool notificationsEnabled: setting("notificationsEnabled", true) !== false

  function modeRank(mode) {
    return mode === "force" ? 3 : (mode === "poll" ? 2 : (mode === "cached" ? 1 : 0))
  }

  // mode: "poll" (use the cache while it is fresh), "force" (always fetch),
  // "cached" (only re-project what is stored; used when the period changes).
  function startSnapshot(mode) {
    if (probeProc.running) {
      if (modeRank(mode) > modeRank(_queuedMode)) _queuedMode = mode
      return
    }
    var interval = panelOpen ? openRefreshSec : closedRefreshSec
    var args = helperBase.concat([
      "snapshot",
      "--horizon", horizon,
      "--offset", String(offset),
      "--max-age", String(Math.max(10, interval - 5)),
      "--limit", String(turnoverLimit),
      "--lang", language
    ])
    if (mode === "force") args.push("--force")
    if (mode === "cached") args.push("--cached")
    if (notificationsEnabled) args.push("--notify")
    if (privacy) args.push("--privacy")
    _runningPeriod = horizon + ":" + offset
    probeProc.command = args
    probeProc.running = true
  }

  function refresh() { startSnapshot("poll") }
  function forceRefresh() { startSnapshot("force") }

  function setPeriod(nextHorizon, nextOffset) {
    var h = Model.HORIZONS.indexOf(nextHorizon) !== -1 ? nextHorizon : "month"
    var o = Math.max(-600, Math.min(0, Math.round(Number(nextOffset) || 0)))
    if (h === horizon && o === offset) return
    horizon = h
    offset = o
    startSnapshot("cached")
  }

  // Returns false when another action is still running.
  function run(name, payload, tag) {
    if (actionProc.running) return false
    busyAction = name
    busyTag = tag || name
    actionProc.payload = JSON.stringify(payload || {})
    actionProc.command = helperBase.concat(["action", name])
    actionProc.running = true
    return true
  }

  Timer {
    interval: (root.panelOpen ? root.openRefreshSec : root.closedRefreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      id: probeStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var parsed = Model.parseSnapshot(probeStdout.text)
      var samePeriod = root._runningPeriod === root.horizon + ":" + root.offset
      var broken = exitCode !== 0 || (parsed.status === "error" && parsed.error === "" && !parsed.hasData)
      if (broken) {
        // The helper crashed or printed nothing usable: keep what is on screen.
        if (!root.snapshot.hasData) {
          var failed = Model.emptySnapshot("error")
          failed.error = "internal"
          root.snapshot = failed
        }
      } else if (samePeriod || !parsed.hasData) {
        root.snapshot = parsed
      }
      var queued = root._queuedMode
      root._queuedMode = ""
      if (queued !== "") root.startSnapshot(queued)
      else if (!samePeriod) root.startSnapshot("cached")
    }
  }

  Process {
    id: actionProc
    property string payload: "{}"
    stdinEnabled: true
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
    }
    onStarted: {
      write(payload + "\n")
      payload = "{}"
    }
    onExited: function(exitCode) {
      var result = Model.parseActionResult(actionStdout.text)
      var tag = root.busyTag
      root.busyAction = ""
      root.busyTag = ""
      if (result.ok && result.refresh === true) root.forceRefresh()
      root.actionFinished(tag, result)
    }
  }
}
