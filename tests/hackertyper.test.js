const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.resolve(__dirname, "..")
const modelSource = fs
  .readFileSync(path.join(root, "HackerTyperModel.js"), "utf8")
  .replace(/^\.pragma.*$/gm, "")

const model = {}
vm.createContext(model)
vm.runInContext(modelSource, model)

assert.equal(model.advance(0, 3, 10), 3)
assert.equal(model.advance(9, 3, 10), 10)
assert.equal(model.advance(10, 3, 10), 10)
assert.equal(model.retreat(10, 3, 10), 7)
assert.equal(model.retreat(2, 3, 10), 0)
assert.equal(model.retreat(0, 3, 10), 0)

assert.deepEqual(
  JSON.parse(JSON.stringify(model.parsePayload('{"sourceId":"kernel-like","screenName":"DP-1"}'))),
  { sourceId: "kernel-like", screenName: "DP-1" }
)
assert.deepEqual(JSON.parse(JSON.stringify(model.parsePayload("not-json"))), {})
assert.deepEqual(JSON.parse(JSON.stringify(model.parsePayload("null"))), {})

assert.equal(
  model.prepareSource("# SPDX-License-Identifier: MIT\n# :: hidden one\n# :: hidden two\n# visible\ncode"),
  "# visible\ncode"
)
assert.equal(
  model.prepareSource("// SPDX-License-Identifier: MIT\n// :: hidden\n// visible\nNamespace::member();"),
  "// visible\nNamespace::member();"
)
assert.equal(
  model.prepareSource("-- SPDX-License-Identifier: MIT\n-- :: hidden\n-- visible\nSELECT 1;"),
  "-- visible\nSELECT 1;"
)
assert.equal(
  model.prepareSource("\uFEFF#!/usr/bin/env bash\r\n# SPDX-License-Identifier: MIT\r\n# :: hidden\r\n# visible\r\necho ready\r\n"),
  "#!/usr/bin/env bash\n# visible\necho ready\n"
)
assert.equal(
  model.prepareSource("<?php\n// SPDX-License-Identifier: MIT\n// :: hidden\ndeclare(strict_types=1);"),
  "<?php\ndeclare(strict_types=1);"
)
assert.equal(
  model.prepareSource("\n// :: hidden\n\nimport QtQuick"),
  "import QtQuick"
)
assert.equal(
  model.prepareSource("//  :: normal comment\n#:: normal comment\ncode"),
  "//  :: normal comment\n#:: normal comment\ncode"
)
assert.equal(model.preview("one\ntwo\nthree\nfour", 2, 100), "one\ntwo")
assert.equal(model.preview("abcdefghijklmnopqrstuvwxyz", 2, 10), "abcdefghi…")

const sources = [
  { id: "one", name: "One" },
  { id: "two", name: "Two" }
]
assert.equal(model.sourceById(sources, "two").name, "Two")
assert.equal(model.sourceById(sources, "missing").name, "One")
assert.equal(model.sourceById([], "missing"), null)

const catalogSource = fs
  .readFileSync(path.join(root, "SourceCatalog.js"), "utf8")
  .replace(/^\.pragma.*$/gm, "")
const catalog = {}
vm.createContext(catalog)
vm.runInContext(catalogSource, catalog)

const expectedLanguages = [
  "C", "C++", "C#", "Java", "TypeScript", "Python", "Go", "Rust",
  "Ruby", "PHP", "Bash", "SQL", "Lua", "QML"
]
const catalogSources = JSON.parse(JSON.stringify(catalog.sources))
assert.deepEqual(catalogSources.map(source => source.language), expectedLanguages)
assert.equal(new Set(catalogSources.map(source => source.id)).size, catalogSources.length)
assert.equal(new Set(catalogSources.map(source => source.language)).size, catalogSources.length)

for (const source of catalogSources) {
  assert.ok(source.id && source.name && source.description, "catalog metadata is complete")
  assert.equal(source.license, "MIT")
  assert.match(source.provenance, /^Project(?:-authored MIT source| source)\.$/, "catalog provenance is present")
  assert.ok(fs.existsSync(path.join(root, source.file)), `${source.file} exists`)
  assert.equal(Object.hasOwn(source, "skipLines"), false, `${source.file} uses marker preprocessing`)
}

const qmlSource = catalogSources.find(source => source.language === "QML")
assert.equal(qmlSource.file, "HackerTyper.qml")

const preparedSources = []
for (const source of catalogSources) {
  const raw = fs.readFileSync(path.join(root, source.file), "utf8")
  assert.match(raw, /SPDX-License-Identifier: MIT/, `${source.file} has an SPDX identifier`)
  assert.match(raw, /(?:\/\/|#|--) :: This purpose-written source provides|\/\/ :: This executable source implements/, `${source.file} has hidden source metadata`)

  const displayed = model.prepareSource(raw)
  preparedSources.push(displayed)
  assert.ok(displayed.trim().length > 3000, `${source.file} is substantial after preprocessing`)
  assert.doesNotMatch(displayed, /SPDX-License-Identifier/, `${source.file} hides SPDX metadata`)
  assert.doesNotMatch(displayed, /(?:\/\/|#|--) ::/, `${source.file} hides internal metadata`)
}
assert.ok(model.prepareSource(fs.readFileSync(path.join(root, qmlSource.file), "utf8")).startsWith("import QtQuick"))

const dangerousPatterns = [
  /\bsudo\b/i,
  /\brm\s+-[^\n]*r/i,
  /\b(?:curl|wget)\b[^\n]*\|\s*(?:sh|bash)\b/i,
  /\beval\s*\(/i,
  /\b(?:os\.execute|io\.popen|subprocess|child_process|Runtime\.getRuntime|Process\.Start)\b/i,
  /\b(?:DROP|TRUNCATE)\s+(?:TABLE|SCHEMA|DATABASE)\b/i,
  /\b(?:crontab|authorized_keys)\b/i
]
for (const pattern of dangerousPatterns) {
  for (const source of preparedSources) assert.doesNotMatch(source, pattern)
}

const immersionBreakingTerms = /\b(fictional|synthetic|toy|demo|demonstration|dramatic|display[- ]only|visual typing|imagined|pretend|rehearsal|fake|mock|harmless|simulation|simulated|plan[- ]only|sample text|dry[- ]run|placeholder|theatrical)\b/i
for (const source of preparedSources) assert.doesNotMatch(source, immersionBreakingTerms)

console.log("Hacker Typer model and source catalog tests passed")
