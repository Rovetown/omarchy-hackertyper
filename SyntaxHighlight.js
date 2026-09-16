.pragma library

// :: Lightweight, best-effort tokenizer for Hacker Typer's "simple" syntax
// :: highlighting tier. This is NOT a real parser - it is a single regex pass
// :: that classifies text into keyword / string / comment / number / plain
// :: runs, good enough to look convincing at typing speed. It intentionally
// :: does not handle nested comments, triple-quoted strings, heredocs, or
// :: language-specific edge cases - see the "thorough" branch for that.

function buildKeywordSet(words) {
  var set = {}
  for (var i = 0; i < words.length; i++) set[words[i]] = true
  return set
}

function langConfig(keywords, lineComment, blockComment, stringChars, caseInsensitive) {
  return {
    keywords: buildKeywordSet(keywords),
    lineComment: lineComment || null,
    blockComment: blockComment || null,
    stringChars: stringChars || ['"', "'"],
    caseInsensitive: !!caseInsensitive
  }
}

var CLIKE_STRINGS = ['"', "'"]

var LANGUAGES = {
  "C": langConfig(
    ["auto","break","case","char","const","continue","default","do","double",
     "else","enum","extern","float","for","goto","if","int","long","register",
     "return","short","signed","sizeof","static","struct","switch","typedef",
     "union","unsigned","void","volatile","while","include","define","ifdef",
     "ifndef","endif","NULL"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "C++": langConfig(
    ["auto","break","case","char","class","const","constexpr","continue",
     "default","delete","do","double","else","enum","explicit","extern",
     "final","float","for","friend","goto","if","inline","int","long",
     "namespace","new","noexcept","nullptr","operator","override","private",
     "protected","public","register","return","short","signed","sizeof",
     "static","struct","switch","template","this","throw","true","false",
     "try","catch","typedef","typename","union","unsigned","using","virtual",
     "void","volatile","while"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "C#": langConfig(
    ["abstract","async","await","bool","break","case","catch","class",
     "const","continue","default","delegate","do","double","else","enum",
     "event","explicit","extern","false","finally","float","for","foreach",
     "if","implicit","in","int","interface","internal","is","lock","long",
     "namespace","new","null","object","override","params","private",
     "protected","public","readonly","ref","return","sealed","short",
     "static","string","struct","switch","this","throw","true","try",
     "typeof","using","var","virtual","void","while","yield"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "Java": langConfig(
    ["abstract","assert","boolean","break","byte","case","catch","char",
     "class","const","continue","default","do","double","else","enum",
     "extends","final","finally","float","for","if","implements","import",
     "instanceof","int","interface","long","native","new","package",
     "private","protected","public","return","short","static","strictfp",
     "super","switch","synchronized","this","throw","throws","transient",
     "try","void","volatile","while","true","false","null"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "TypeScript": langConfig(
    ["as","async","await","break","case","catch","class","const","continue",
     "default","delete","do","else","enum","export","extends","false",
     "finally","for","from","function","if","implements","import","in",
     "instanceof","interface","let","new","null","of","private","protected",
     "public","readonly","return","static","super","switch","this","throw",
     "true","try","type","typeof","undefined","var","void","while","yield"],
    "//", ["/*", "*/"], ['"', "'", "`"]),

  "Python": langConfig(
    ["and","as","assert","async","await","break","class","continue","def",
     "del","elif","else","except","finally","for","from","global","if",
     "import","in","is","lambda","None","nonlocal","not","or","pass",
     "raise","return","self","True","False","try","while","with","yield"],
    "#", null, CLIKE_STRINGS),

  "Go": langConfig(
    ["break","case","chan","const","continue","default","defer","else",
     "fallthrough","for","func","go","goto","if","import","interface","map",
     "package","range","return","select","struct","switch","type","var",
     "nil","true","false"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "Rust": langConfig(
    ["as","break","const","continue","crate","dyn","else","enum","extern",
     "fn","for","if","impl","in","let","loop","match","mod","move","mut",
     "pub","ref","return","self","Self","static","struct","super","trait",
     "true","false","type","unsafe","use","where","while","None","Some",
     "Ok","Err"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "Ruby": langConfig(
    ["begin","break","case","class","def","do","else","elsif","end","ensure",
     "false","for","if","in","module","next","nil","not","or","raise",
     "redo","rescue","retry","return","self","super","then","true","undef",
     "unless","until","when","while","yield","and"],
    "#", null, CLIKE_STRINGS),

  "PHP": langConfig(
    ["abstract","and","array","as","break","case","catch","class","clone",
     "const","continue","declare","default","do","echo","else","elseif",
     "empty","enddeclare","endfor","endforeach","endif","endswitch",
     "endwhile","extends","final","finally","fn","for","foreach","function",
     "global","goto","if","implements","include","instanceof","insteadof",
     "interface","isset","list","namespace","new","or","print","private",
     "protected","public","require","return","static","switch","throw",
     "trait","try","unset","use","var","while","xor","yield","true","false",
     "null"],
    "//", ["/*", "*/"], CLIKE_STRINGS),

  "Bash": langConfig(
    ["if","then","elif","else","fi","for","while","until","do","done",
     "case","esac","function","return","break","continue","local","export",
     "readonly","declare","in","select","time"],
    "#", null, CLIKE_STRINGS),

  "SQL": langConfig(
    ["select","from","where","join","inner","left","right","outer","on",
     "group","by","order","having","insert","into","values","update","set",
     "delete","create","table","alter","drop","index","primary","key",
     "foreign","references","not","null","default","unique","as","and","or",
     "in","exists","between","like","union","all","distinct","limit","view",
     "case","when","then","else","end"],
    "--", ["/*", "*/"], ["'"], true),

  "Lua": langConfig(
    ["and","break","do","else","elseif","end","false","for","function","if",
     "in","local","nil","not","or","repeat","return","then","true","until",
     "while"],
    "--", null, CLIKE_STRINGS),

  "QML": langConfig(
    ["import","as","property","function","var","let","const","return","if",
     "else","for","while","readonly","signal","alias","true","false","null",
     "id","int","string","bool","real","list","default","required"],
    "//", ["/*", "*/"], ['"', "'"])
}

var FALLBACK = langConfig([], "//", ["/*", "*/"], CLIKE_STRINGS)

function escapeRegExp(ch) {
  return ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function buildScanner(cfg) {
  var parts = []
  if (cfg.blockComment) {
    parts.push(escapeRegExp(cfg.blockComment[0]) + "[\\s\\S]*?(?:" + escapeRegExp(cfg.blockComment[1]) + "|$)")
  }
  if (cfg.lineComment) {
    parts.push(escapeRegExp(cfg.lineComment) + "[^\\n]*")
  }
  for (var i = 0; i < cfg.stringChars.length; i++) {
    var ch = escapeRegExp(cfg.stringChars[i])
    parts.push(ch + "(?:\\\\.|[^\\\\])*?(?:" + ch + "|$)")
  }
  parts.push("\\b\\d+(?:\\.\\d+)?\\b")
  parts.push("[A-Za-z_][A-Za-z0-9_]*")
  return new RegExp(parts.join("|"), "g")
}

var scannerCache = {}

function scannerFor(cacheKey, cfg) {
  if (!scannerCache[cacheKey]) scannerCache[cacheKey] = buildScanner(cfg)
  scannerCache[cacheKey].lastIndex = 0
  return scannerCache[cacheKey]
}

function classify(cfg, match) {
  var first = match.charAt(0)
  if (cfg.blockComment && match.indexOf(cfg.blockComment[0]) === 0) return "comment"
  if (cfg.lineComment && match.indexOf(cfg.lineComment) === 0) return "comment"
  if (cfg.stringChars.indexOf(first) !== -1) return "string"
  if (/^\d/.test(first)) return "number"
  var word = cfg.caseInsensitive ? match.toLowerCase() : match
  if (cfg.keywords[word]) return "keyword"
  return "plain"
}

// tokenize(text, language) -> [{ type: "keyword"|"string"|"comment"|"number"|"plain", text: "..." }, ...]
function tokenize(text, language) {
  var cfg = LANGUAGES[language] || FALLBACK

  var cacheKey = LANGUAGES[language] ? language : "__fallback__"
  var scanner = scannerFor(cacheKey, cfg)
  var tokens = []
  var lastEnd = 0
  var match

  while ((match = scanner.exec(text)) !== null) {
    if (match.index > lastEnd) {
      tokens.push({ type: "plain", text: text.slice(lastEnd, match.index) })
    }
    tokens.push({ type: classify(cfg, match[0]), text: match[0] })
    lastEnd = match.index + match[0].length
    if (match[0].length === 0) scanner.lastIndex++ // safety against zero-width matches
  }

  if (lastEnd < text.length) {
    tokens.push({ type: "plain", text: text.slice(lastEnd) })
  }

  return tokens
}
