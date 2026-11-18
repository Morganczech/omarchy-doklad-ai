import QtQuick
import Quickshell.Io
import qs.Commons as Commons

// Texts of the plugin. It speaks Czech and Slovak only: Slovak when the shell
// is set to Slovak, Czech for every other language. A text missing from the
// Slovak catalog falls back to the Czech one.
//
// A catalog value is a string, or an object of plural forms
// ({"one": "%1 faktura", "few": "%1 faktury", "other": "%1 faktur"}).
QtObject {
  id: root

  readonly property string language: String(Commons.I18n.language).split("-")[0] === "sk" ? "sk" : "cs"
  readonly property string directory: decodeURIComponent(String(Qt.resolvedUrl("i18n")).replace(/^file:\/\//, ""))

  readonly property var czech: parseCatalog(czechFile.text())
  readonly property var slovak: parseCatalog(slovakFile.text())

  function entry(key) {
    if (root.language === "sk" && root.slovak[key] !== undefined) return root.slovak[key]
    return root.czech[key]
  }

  function t(key) {
    var value = entry(key)
    if (value && typeof value === "object") value = value.other
    return typeof value === "string" && value.length > 0 ? value : key
  }

  // Czech and Slovak share the rule: 1 is "one", 2-4 "few", everything else "other".
  function tn(key, count) {
    var value = entry(key)
    if (value && typeof value === "object") {
      var n = Math.abs(Math.trunc(Number(count) || 0))
      var form = n === 1 ? "one" : (n >= 2 && n <= 4 ? "few" : "other")
      value = typeof value[form] === "string" ? value[form] : value.other
    }
    return typeof value === "string" && value.length > 0 ? value : key
  }

  function parseCatalog(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      return (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      return ({})
    }
  }

  property FileView czechFile: FileView {
    path: root.directory + "/cs.json"
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }

  property FileView slovakFile: FileView {
    path: root.language === "sk" ? root.directory + "/sk.json" : ""
    watchChanges: true
    printErrors: false
    blockLoading: true
    onFileChanged: reload()
  }
}
