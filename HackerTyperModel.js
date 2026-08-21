.pragma library

function clamp(value, minimum, maximum) {
  var n = Number(value)
  if (!isFinite(n)) n = minimum
  return Math.max(minimum, Math.min(maximum, n))
}

function advance(index, amount, length) {
  var size = Math.max(0, Number(length) || 0)
  var step = Math.max(1, Number(amount) || 1)
  return clamp((Number(index) || 0) + step, 0, size)
}

function retreat(index, amount, length) {
  var size = Math.max(0, Number(length) || 0)
  var step = Math.max(1, Number(amount) || 1)
  return clamp((Number(index) || 0) - step, 0, size)
}

function parsePayload(raw) {
  try {
    var value = JSON.parse(String(raw || "{}"))
    return value && typeof value === "object" ? value : {}
  } catch (e) {
    return {}
  }
}

function prepareSource(raw) {
  var text = String(raw || "").replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n")
  var lines = text.split("\n")
  var prepared = []

  for (var i = 0; i < lines.length; i++) {
    var trimmed = lines[i].replace(/^\s+|\s+$/g, "")
    if (/^(?:\/\/|#|--)\s*SPDX-License-Identifier:/.test(trimmed)) continue
    if (/^(?:\/\/|#|--) ::/.test(trimmed)) continue
    prepared.push(lines[i])
  }

  while (prepared.length > 0 && prepared[0].replace(/^\s+|\s+$/g, "").length === 0)
    prepared.shift()
  return prepared.join("\n")
}

function preview(raw, lineCount, characterLimit) {
  var text = String(raw || "")
  var lines = text.split("\n")
  var count = Math.max(1, Number(lineCount) || 1)
  var limit = Math.max(1, Number(characterLimit) || 1)
  var out = lines.slice(0, count).join("\n").trim()
  if (out.length > limit) out = out.substr(0, Math.max(1, limit - 1)).trimEnd() + "…"
  return out
}

function sourceById(sources, id) {
  var list = Array.isArray(sources) ? sources : []
  var requested = String(id || "")
  for (var i = 0; i < list.length; i++) {
    if (String(list[i].id || "") === requested) return list[i]
  }
  return list.length > 0 ? list[0] : null
}
