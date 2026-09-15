import QtQuick
import Quickshell
import Quickshell.Io
import "HackerTyperModel.js" as HackerTyperModel
import "SourceCatalog.js" as SourceCatalog

Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null

  readonly property var sources: SourceCatalog.sources

  property string selectedSourceId: "kernel-like"
  readonly property var selectedSource: HackerTyperModel.sourceById(sources, selectedSourceId)
  readonly property string sourceDir: manifest && manifest.__sourceDir
  ? String(manifest.__sourceDir)
  : Quickshell.env("HOME") + "/.config/omarchy/plugins/codefriendly.hackertyper"
  readonly property string selectedSourcePath: sourceDir && selectedSource
    ? sourceDir + "/" + selectedSource.file
    : ""

  property string sourceText: ""
  property string sourceError: ""

  function selectSource(sourceId) {
    var source = HackerTyperModel.sourceById(sources, sourceId)
    if (!source) return false
    if (selectedSourceId === source.id) return true
    sourceText = ""
    sourceError = ""
    selectedSourceId = source.id
    return true
  }

  function sourcePreview() {
    return HackerTyperModel.preview(sourceText, 5, 360)
  }

  function launch(screenName) {
    if (!shell || !manifest) return false
    var payload = JSON.stringify({
      sourceId: selectedSourceId,
      screenName: String(screenName || "")
    })
    return shell.summon(manifest.id, payload) === true
  }

  function statusObject() {
    return {
      selectedSourceId: selectedSourceId,
      selectedSource: selectedSource ? selectedSource.name : "",
      loaded: sourceText.length > 0,
      preview: sourceText.substr(0, 80),
      error: sourceError
    }
  }

  FileView {
    id: sourceFile
    path: root.selectedSourcePath
    printErrors: false

    onLoaded: {
      root.sourceText = HackerTyperModel.prepareSource(text())
      root.sourceError = ""
    }

    onLoadFailed: function(error) {
      root.sourceText = ""
      root.sourceError = "Could not load " + (root.selectedSource ? root.selectedSource.name : "source")
    }
  }

  IpcHandler {
    target: "codefriendly.hackertyper"

    function launch(sourceId: string, screenName: string): string {
      if (sourceId && !root.selectSource(sourceId)) return "unknown-source"
      return root.launch(screenName) ? "ok" : "unavailable"
    }

    function select(sourceId: string): string {
      return root.selectSource(sourceId) ? "ok" : "unknown-source"
    }

    function status(): string {
      return JSON.stringify(root.statusObject())
    }
  }
}
