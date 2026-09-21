# sawk.nim -- A Nim AWk interpreter.
# CC BY-NC-SA 4.0 - jean-marc "jihem" quere 2026 (sonaliwan.fr)
#
# Fedora 44: sudo ln -s /usr/lib64/libpcre.so /usr/lib64/libpcre.so.3
# Build:  nim c -d:release sawk.nim
# Run:    ./sawk 'BEGIN{print "hi"}'
#         ./sawk -F: '{print $1}' /etc/passwd
#         ./sawk -f script.awk file1 file2

import std/[os, strutils, tables, math, re, random, osproc, streams, times]

# Values

type
  ValueKind = enum vkNum, vkStr, vkStrnum, vkUninit

  Value = object
    case kind: ValueKind
    of vkNum:
      n: float
    of vkStr, vkStrnum:
      s: string
    of vkUninit:
      discard

proc newNum(f: float): Value = Value(kind: vkNum, n: f)
proc newStr(s: string): Value = Value(kind: vkStr, s: s)
proc uninitV(): Value = Value(kind: vkUninit)

proc looksNumeric(s: string): bool =
  let t = s.strip()
  if t.len == 0: return false
  var i = 0
  let L = t.len
  if t[i] == '+' or t[i] == '-': inc i
  var sawDigit = false
  while i < L and t[i].isDigit:
    inc i
    sawDigit = true
  if i < L and t[i] == '.':
    inc i
    while i < L and t[i].isDigit:
      inc i
      sawDigit = true
  if not sawDigit: return false
  if i < L and (t[i] == 'e' or t[i] == 'E'):
    var j = i + 1
    if j < L and (t[j] == '+' or t[j] == '-'): inc j
    if j >= L or not t[j].isDigit: return false
    inc j
    while j < L and t[j].isDigit: inc j
    i = j
  result = i == L

proc newStrnum(s: string): Value =
  if looksNumeric(s): Value(kind: vkStrnum, s: s) else: Value(kind: vkStr, s: s)

proc parseNumPrefix(s: string): float =
  var i = 0
  let L = s.len
  while i < L and s[i] in {' ', '\t', '\n'}: inc i
  let start = i
  if i < L and (s[i] == '+' or s[i] == '-'): inc i
  var sawDigit = false
  while i < L and s[i].isDigit:
    inc i
    sawDigit = true
  if i < L and s[i] == '.':
    inc i
    while i < L and s[i].isDigit:
      inc i
      sawDigit = true
  if not sawDigit:
    return 0.0
  if i < L and (s[i] == 'e' or s[i] == 'E'):
    var j = i + 1
    if j < L and (s[j] == '+' or s[j] == '-'): inc j
    if j < L and s[j].isDigit:
      inc j
      while j < L and s[j].isDigit: inc j
      i = j
  let numStr = s[start ..< i]
  try:
    result = parseFloat(numStr)
  except ValueError:
    result = 0.0

# forward decl: numToStr uses awkSprintf which is defined later
proc numToStrFmt(n: float, fmt: string): string

proc getGlobalRaw(name: string): string # forward decl (defined after globals table)

proc isIntegralF(n: float): bool =
  if classify(n) in {fcNan, fcInf, fcNegInf}: return false
  result = n == trunc(n) and abs(n) < 1.0e17

proc intStrOf(n: float): string =
  if n == 0.0: "0"
  else: $(int64(n))

proc numToStr(n: float): string =
  if isIntegralF(n): intStrOf(n)
  else: numToStrFmt(n, getGlobalRaw("CONVFMT"))

proc numToOutStr(n: float): string =
  if isIntegralF(n): intStrOf(n)
  else: numToStrFmt(n, getGlobalRaw("OFMT"))

proc toNum(v: Value): float =
  case v.kind
  of vkNum: v.n
  of vkStr, vkStrnum: parseNumPrefix(v.s)
  of vkUninit: 0.0

proc toStr(v: Value): string =
  case v.kind
  of vkStr, vkStrnum: v.s
  of vkNum: numToStr(v.n)
  of vkUninit: ""

proc toOutStr(v: Value): string =
  case v.kind
  of vkStr, vkStrnum: v.s
  of vkNum: numToOutStr(v.n)
  of vkUninit: ""

proc isTrue(v: Value): bool =
  case v.kind
  of vkNum: v.n != 0.0
  of vkStrnum: toNum(v) != 0.0
  of vkStr: v.s.len > 0
  of vkUninit: false

proc isNumericCtx(v: Value): bool = v.kind in {vkNum, vkStrnum, vkUninit}

proc compareVals(a, b: Value): int =
  if isNumericCtx(a) and isNumericCtx(b):
    let x = toNum(a)
    let y = toNum(b)
    if x < y: -1
    elif x > y: 1
    else: 0
  else:
    cmp(toStr(a), toStr(b))

# Lexer

type
  TokKind = enum
    tkNum, tkStr, tkEre, tkName,
    tkBegin, tkEnd, tkFunction, tkIf, tkElse, tkWhile, tkFor, tkDo,
    tkBreak, tkContinue, tkNext, tkNextfile, tkExit, tkReturn, tkDelete, tkIn,
    tkGetline, tkPrint, tkPrintf,
    tkLBrace, tkRBrace, tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkSemi, tkNewline, tkComma,
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent, tkCaret,
    tkAssign, tkAddAssign, tkSubAssign, tkMulAssign, tkDivAssign, tkModAssign, tkPowAssign,
    tkEq, tkNe, tkLt, tkLe, tkGt, tkGe,
    tkMatch, tkNotMatch,
    tkAnd, tkOr, tkNot,
    tkIncr, tkDecr,
    tkDollar, tkQuestion, tkColon,
    tkPipe, tkAppend, tkEOF

  Token = object
    kind: TokKind
    sval: string
    nval: float

proc interpretEscapes(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      let c = s[i+1]
      if c == 'n':
        result.add('\n'); i += 2
      elif c == 't':
        result.add('\t'); i += 2
      elif c == 'r':
        result.add('\r'); i += 2
      elif c == '\\':
        result.add('\\'); i += 2
      elif c == '"':
        result.add('"'); i += 2
      elif c == '/':
        result.add('/'); i += 2
      elif c == 'a':
        result.add('\a'); i += 2
      elif c == 'b':
        result.add('\b'); i += 2
      elif c == 'f':
        result.add('\f'); i += 2
      elif c == 'v':
        result.add('\v'); i += 2
      elif c in '0'..'7':
        var j = i + 1
        var numv = 0
        var cnt = 0
        while j < s.len and s[j] in '0'..'7' and cnt < 3:
          numv = numv * 8 + (ord(s[j]) - ord('0'))
          inc j
          inc cnt
        result.add(chr(numv and 0xFF))
        i = j
      else:
        result.add('\\')
        result.add(c)
        i += 2
    else:
      result.add(s[i])
      inc i

proc tokenize(srcIn: string): seq[Token] =
  var src = srcIn.replace("\r\n", "\n")
  src = src.replace("\\\n", "")
  var toks: seq[Token] = @[]
  var i = 0
  let L = src.len
  var parenDepth = 0
  var lastKind = tkNewline

  let keywords = {
    "BEGIN": tkBegin, "END": tkEnd, "function": tkFunction, "func": tkFunction,
    "if": tkIf, "else": tkElse, "while": tkWhile, "for": tkFor, "do": tkDo,
    "break": tkBreak, "continue": tkContinue, "next": tkNext, "nextfile": tkNextfile,
    "exit": tkExit, "return": tkReturn, "delete": tkDelete, "in": tkIn,
    "getline": tkGetline, "print": tkPrint, "printf": tkPrintf
  }.toTable()

  proc addTok(k: TokKind) =
    toks.add(Token(kind: k, sval: "", nval: 0.0))
    lastKind = k

  proc addTokS(k: TokKind, s: string) =
    toks.add(Token(kind: k, sval: s, nval: 0.0))
    lastKind = k

  proc addTokN(k: TokKind, n: float) =
    toks.add(Token(kind: k, sval: "", nval: n))
    lastKind = k

  proc regexAllowedHere(): bool =
    case lastKind
    of tkNum, tkStr, tkEre, tkName, tkRParen, tkRBracket, tkIncr, tkDecr:
      false
    else:
      true

  while i < L:
    let c = src[i]
    if c == ' ' or c == '\t':
      inc i
      continue
    if c == '#':
      while i < L and src[i] != '\n': inc i
      continue
    if c == '\n':
      inc i
      if parenDepth > 0:
        continue
      if lastKind in {tkComma, tkLBrace, tkAnd, tkOr, tkDo, tkElse, tkNewline, tkSemi}:
        continue
      addTok(tkNewline)
      continue
    if c == '"':
      inc i
      var sb = ""
      while i < L and src[i] != '"':
        if src[i] == '\\' and i + 1 < L:
          sb.add(src[i]); sb.add(src[i+1]); i += 2
        else:
          sb.add(src[i]); inc i
      if i < L: inc i
      addTokS(tkStr, interpretEscapes(sb))
      continue
    if c == '/' and regexAllowedHere():
      inc i
      var sb = ""
      var inBracket = false
      while i < L and (src[i] != '/' or inBracket):
        if src[i] == '\\' and i + 1 < L:
          sb.add(src[i]); sb.add(src[i+1]); i += 2
        elif src[i] == '[':
          inBracket = true; sb.add(src[i]); inc i
        elif src[i] == ']':
          inBracket = false; sb.add(src[i]); inc i
        else:
          sb.add(src[i]); inc i
      if i < L: inc i
      addTokS(tkEre, sb)
      continue
    if c.isDigit or (c == '.' and i + 1 < L and src[i+1].isDigit):
      if c == '0' and i + 1 < L and (src[i+1] == 'x' or src[i+1] == 'X'):
        var k3 = i + 2
        while k3 < L and (src[k3].isDigit or src[k3] in {'a'..'f', 'A'..'F'}): inc k3
        let hs = src[(i+2) ..< k3]
        var hv: int
        try: hv = parseHexInt(hs)
        except ValueError: hv = 0
        addTokN(tkNum, hv.float)
        i = k3
        continue
      var j = i
      while j < L and src[j].isDigit: inc j
      if j < L and src[j] == '.':
        inc j
        while j < L and src[j].isDigit: inc j
      if j < L and (src[j] == 'e' or src[j] == 'E'):
        var k2 = j + 1
        if k2 < L and (src[k2] == '+' or src[k2] == '-'): inc k2
        if k2 < L and src[k2].isDigit:
          inc k2
          while k2 < L and src[k2].isDigit: inc k2
          j = k2
      let numStr = src[i ..< j]
      var nv: float
      try: nv = parseFloat(numStr)
      except ValueError: nv = 0.0
      addTokN(tkNum, nv)
      i = j
      continue
    if c.isAlphaAscii or c == '_':
      var j = i
      while j < L and (src[j].isAlphaNumeric or src[j] == '_'): inc j
      let word = src[i ..< j]
      i = j
      if keywords.hasKey(word):
        addTok(keywords[word])
      else:
        addTokS(tkName, word)
      continue
    if c == '=' and i+1 < L and src[i+1] == '=':
      addTok(tkEq); i += 2; continue
    if c == '!' and i+1 < L and src[i+1] == '=':
      addTok(tkNe); i += 2; continue
    if c == '<' and i+1 < L and src[i+1] == '=':
      addTok(tkLe); i += 2; continue
    if c == '>' and i+1 < L and src[i+1] == '=':
      addTok(tkGe); i += 2; continue
    if c == '>' and i+1 < L and src[i+1] == '>':
      addTok(tkAppend); i += 2; continue
    if c == '&' and i+1 < L and src[i+1] == '&':
      addTok(tkAnd); i += 2; continue
    if c == '|' and i+1 < L and src[i+1] == '|':
      addTok(tkOr); i += 2; continue
    if c == '+' and i+1 < L and src[i+1] == '+':
      addTok(tkIncr); i += 2; continue
    if c == '-' and i+1 < L and src[i+1] == '-':
      addTok(tkDecr); i += 2; continue
    if c == '+' and i+1 < L and src[i+1] == '=':
      addTok(tkAddAssign); i += 2; continue
    if c == '-' and i+1 < L and src[i+1] == '=':
      addTok(tkSubAssign); i += 2; continue
    if c == '*' and i+1 < L and src[i+1] == '=':
      addTok(tkMulAssign); i += 2; continue
    if c == '/' and i+1 < L and src[i+1] == '=':
      addTok(tkDivAssign); i += 2; continue
    if c == '%' and i+1 < L and src[i+1] == '=':
      addTok(tkModAssign); i += 2; continue
    if c == '^' and i+1 < L and src[i+1] == '=':
      addTok(tkPowAssign); i += 2; continue
    if c == '*' and i+1 < L and src[i+1] == '*':
      addTok(tkCaret); i += 2; continue
    if c == '!' and i+1 < L and src[i+1] == '~':
      addTok(tkNotMatch); i += 2; continue
    case c
    of '{':
      addTok(tkLBrace); inc i
    of '}':
      addTok(tkRBrace); inc i
    of '(':
      addTok(tkLParen); inc parenDepth; inc i
    of ')':
      addTok(tkRParen)
      if parenDepth > 0: dec parenDepth
      inc i
    of '[':
      addTok(tkLBracket); inc parenDepth; inc i
    of ']':
      addTok(tkRBracket)
      if parenDepth > 0: dec parenDepth
      inc i
    of ';':
      addTok(tkSemi); inc i
    of ',':
      addTok(tkComma); inc i
    of '+':
      addTok(tkPlus); inc i
    of '-':
      addTok(tkMinus); inc i
    of '*':
      addTok(tkStar); inc i
    of '/':
      addTok(tkSlash); inc i
    of '%':
      addTok(tkPercent); inc i
    of '^':
      addTok(tkCaret); inc i
    of '=':
      addTok(tkAssign); inc i
    of '<':
      addTok(tkLt); inc i
    of '>':
      addTok(tkGt); inc i
    of '~':
      addTok(tkMatch); inc i
    of '!':
      addTok(tkNot); inc i
    of '$':
      addTok(tkDollar); inc i
    of '?':
      addTok(tkQuestion); inc i
    of ':':
      addTok(tkColon); inc i
    of '|':
      addTok(tkPipe); inc i
    else:
      inc i
  addTok(tkEOF)
  result = toks

# AST

type
  NodeKind = enum
    nkNum, nkStr, nkRegex, nkVar, nkField, nkArrayIndex, nkExprList,
    nkAssign, nkBinary, nkUnaryMinus, nkUnaryPlus, nkNot,
    nkPreIncr, nkPreDecr, nkPostIncr, nkPostDecr,
    nkAnd, nkOr, nkTernary, nkMatch, nkConcat, nkIn, nkCall, nkGetline

  Node = ref object
    case kind: NodeKind
    of nkNum:
      numVal: float
    of nkStr:
      strVal: string
    of nkRegex:
      reVal: string
    of nkVar:
      varName: string
    of nkField:
      fieldExpr: Node
    of nkArrayIndex:
      arrName: string
      arrIdx: seq[Node]
    of nkExprList:
      listItems: seq[Node]
    of nkAssign:
      asgnOp: string
      asgnTarget: Node
      asgnVal: Node
    of nkBinary:
      binOp: string
      binL, binR: Node
    of nkUnaryMinus, nkUnaryPlus, nkNot:
      uExpr: Node
    of nkPreIncr, nkPreDecr, nkPostIncr, nkPostDecr:
      incrTarget: Node
    of nkAnd, nkOr:
      logL, logR: Node
    of nkTernary:
      ternCond, ternThen, ternElse: Node
    of nkMatch:
      matchNeg: bool
      matchL, matchR: Node
    of nkConcat:
      concatParts: seq[Node]
    of nkIn:
      inIdx: seq[Node]
      inArr: string
    of nkCall:
      callName: string
      callArgs: seq[Node]
    of nkGetline:
      glMode: string
      glVar: Node
      glSrc: Node

  StmtKind = enum
    skExprStmt, skPrint, skPrintf, skIf, skWhile, skDoWhile, skFor, skForIn,
    skBlock, skBreak, skContinue, skNext, skNextfile, skExit, skReturn,
    skDelete, skDeleteAll, skEmpty

  Stmt = ref object
    case kind: StmtKind
    of skExprStmt:
      exprS: Node
    of skPrint, skPrintf:
      printArgs: seq[Node]
      redirOp: string
      redirTarget: Node
    of skIf:
      ifCond: Node
      ifThen: Stmt
      ifElse: Stmt
    of skWhile:
      whileCond: Node
      whileBody: Stmt
    of skDoWhile:
      doCond: Node
      doBody: Stmt
    of skFor:
      forInit: Stmt
      forCond: Node
      forPost: Stmt
      forBody: Stmt
    of skForIn:
      forInVar: string
      forInArr: string
      forInBody: Stmt
    of skBlock:
      blockStmts: seq[Stmt]
    of skExit, skReturn:
      retVal: Node
    of skDelete:
      delName: string
      delIdx: seq[Node]
    of skDeleteAll:
      delAllName: string
    of skBreak, skContinue, skNext, skNextfile, skEmpty:
      discard

  PatternKind = enum pkBegin, pkEnd, pkExpr, pkRange, pkAlways

  Rule = ref object
    pat: PatternKind
    exprPat: Node
    rangeStart, rangeEnd: Node
    rangeActive: bool
    action: Stmt

  FuncDef = object
    name: string
    params: seq[string]
    body: Stmt

  Program = object
    rules: seq[Rule]
    funcs: Table[string, FuncDef]

# Parser (module-level state, single program parsed per process run)

var ptoks: seq[Token]
var ppos: int
var pInPrintArgs: bool

proc pcur(): Token = ptoks[ppos]
proc ppeek(k: int = 1): Token =
  let idx = ppos + k
  if idx < ptoks.len: ptoks[idx] else: ptoks[^1]
proc padvance(): Token =
  result = ptoks[ppos]
  if ppos < ptoks.len - 1: inc ppos
proc pcheck(k: TokKind): bool = pcur().kind == k
proc pmatch(k: TokKind): bool =
  if pcheck(k):
    discard padvance()
    true
  else:
    false
proc pexpect(k: TokKind, msg: string) =
  if not pcheck(k):
    stderr.writeLine("sawk: syntax error near token, expected " & msg)
    quit(2)
  discard padvance()
proc pskipNewlines() =
  while pcur().kind == tkNewline: discard padvance()
proc pskipTerms() =
  while pcur().kind in {tkNewline, tkSemi}: discard padvance()

proc canStartExpr(t: Token): bool =
  t.kind in {tkNum, tkStr, tkEre, tkName, tkDollar, tkNot, tkMinus, tkPlus,
             tkLParen, tkIncr, tkDecr, tkGetline}

# forward declarations
proc parseExpr(): Node
proc parseAssign(): Node
proc parseTernary(): Node
proc parseOr(): Node
proc parseAnd(): Node
proc parseInExpr(): Node
proc parseMatchExpr(): Node
proc parseRelExpr(): Node
proc parsePipeGetline(): Node
proc parseConcat(): Node
proc parseAdditive(): Node
proc parseMultiplicative(): Node
proc parseUnary(): Node
proc parsePower(): Node
proc parsePostfix(): Node
proc parsePrimary(): Node
proc parseLvalueSimple(): Node
proc parseStmt(): Stmt
proc parseStmtListUntil(closers: set[TokKind]): seq[Stmt]
proc parseSimpleStmt(): Stmt

proc isLvalue(n: Node): bool =
  n.kind in {nkVar, nkField, nkArrayIndex}

proc parseExpr(): Node = parseAssign()

proc parseAssign(): Node =
  let left = parseTernary()
  let k = pcur().kind
  var op = ""
  if k == tkAssign: op = "="
  elif k == tkAddAssign: op = "+="
  elif k == tkSubAssign: op = "-="
  elif k == tkMulAssign: op = "*="
  elif k == tkDivAssign: op = "/="
  elif k == tkModAssign: op = "%="
  elif k == tkPowAssign: op = "^="
  if op != "" and isLvalue(left):
    discard padvance()
    let rhs = parseAssign()
    return Node(kind: nkAssign, asgnOp: op, asgnTarget: left, asgnVal: rhs)
  return left

proc parseTernary(): Node =
  let cond = parseOr()
  if pmatch(tkQuestion):
    pskipNewlines()
    let thenE = parseAssign()
    pskipNewlines()
    pexpect(tkColon, "':'")
    pskipNewlines()
    let elseE = parseAssign()
    return Node(kind: nkTernary, ternCond: cond, ternThen: thenE, ternElse: elseE)
  return cond

proc parseOr(): Node =
  var left = parseAnd()
  while pcheck(tkOr):
    discard padvance()
    pskipNewlines()
    let right = parseAnd()
    left = Node(kind: nkOr, logL: left, logR: right)
  return left

proc parseAnd(): Node =
  var left = parseInExpr()
  while pcheck(tkAnd):
    discard padvance()
    pskipNewlines()
    let right = parseInExpr()
    left = Node(kind: nkAnd, logL: left, logR: right)
  return left

proc parseInExpr(): Node =
  var left = parseMatchExpr()
  while pcheck(tkIn):
    discard padvance()
    let arrName = pcur().sval
    pexpect(tkName, "array name after 'in'")
    if left.kind == nkExprList:
      left = Node(kind: nkIn, inIdx: left.listItems, inArr: arrName)
    else:
      left = Node(kind: nkIn, inIdx: @[left], inArr: arrName)
  return left

proc parseMatchExpr(): Node =
  var left = parseRelExpr()
  while pcheck(tkMatch) or pcheck(tkNotMatch):
    let neg = pcur().kind == tkNotMatch
    discard padvance()
    let right = parseRelExpr()
    left = Node(kind: nkMatch, matchNeg: neg, matchL: left, matchR: right)
  return left

proc parseRelExpr(): Node =
  let left = parsePipeGetline()
  if pInPrintArgs and (pcur().kind == tkGt or pcur().kind == tkAppend or pcur().kind == tkPipe):
    return left
  let k = pcur().kind
  var op = ""
  if k == tkLt: op = "<"
  elif k == tkLe: op = "<="
  elif k == tkGt: op = ">"
  elif k == tkGe: op = ">="
  elif k == tkEq: op = "=="
  elif k == tkNe: op = "!="
  if op != "":
    discard padvance()
    let right = parsePipeGetline()
    return Node(kind: nkBinary, binOp: op, binL: left, binR: right)
  return left

proc parsePipeGetline(): Node =
  var left = parseConcat()
  while (not pInPrintArgs) and pcur().kind == tkPipe and ppeek(1).kind == tkGetline:
    discard padvance()
    discard padvance()
    var varNode: Node = nil
    if pcur().kind == tkName or pcur().kind == tkDollar:
      varNode = parseLvalueSimple()
    left = Node(kind: nkGetline, glMode: (if varNode != nil: "varcmd" else: "cmd"),
                glVar: varNode, glSrc: left)
  return left

proc concatStopSet(): set[TokKind] =
  result = {tkNewline, tkSemi, tkEOF, tkRParen, tkRBracket, tkRBrace, tkComma,
            tkLBrace, tkQuestion, tkColon, tkAnd, tkOr, tkIn, tkMatch, tkNotMatch,
            tkLt, tkLe, tkGt, tkGe, tkEq, tkNe,
            tkAssign, tkAddAssign, tkSubAssign, tkMulAssign, tkDivAssign, tkModAssign, tkPowAssign}
  if pInPrintArgs:
    result.incl(tkPipe)

proc parseConcat(): Node =
  var parts = @[parseAdditive()]
  while true:
    let t = pcur()
    if t.kind in concatStopSet(): break
    if not canStartExpr(t): break
    parts.add(parseAdditive())
  if parts.len == 1: return parts[0]
  return Node(kind: nkConcat, concatParts: parts)

proc parseAdditive(): Node =
  var left = parseMultiplicative()
  while pcur().kind == tkPlus or pcur().kind == tkMinus:
    let op = if pcur().kind == tkPlus: "+" else: "-"
    discard padvance()
    let right = parseMultiplicative()
    left = Node(kind: nkBinary, binOp: op, binL: left, binR: right)
  return left

proc parseMultiplicative(): Node =
  var left = parseUnary()
  while pcur().kind in {tkStar, tkSlash, tkPercent}:
    let k = pcur().kind
    let op = if k == tkStar: "*" elif k == tkSlash: "/" else: "%"
    discard padvance()
    let right = parseUnary()
    left = Node(kind: nkBinary, binOp: op, binL: left, binR: right)
  return left

proc parseUnary(): Node =
  if pcur().kind == tkNot:
    discard padvance()
    return Node(kind: nkNot, uExpr: parseUnary())
  if pcur().kind == tkMinus:
    discard padvance()
    return Node(kind: nkUnaryMinus, uExpr: parseUnary())
  if pcur().kind == tkPlus:
    discard padvance()
    return Node(kind: nkUnaryPlus, uExpr: parseUnary())
  if pcur().kind == tkIncr:
    discard padvance()
    return Node(kind: nkPreIncr, incrTarget: parseUnary())
  if pcur().kind == tkDecr:
    discard padvance()
    return Node(kind: nkPreDecr, incrTarget: parseUnary())
  return parsePower()

proc parsePower(): Node =
  let left = parsePostfix()
  if pcur().kind == tkCaret:
    discard padvance()
    let right = parseUnary()
    return Node(kind: nkBinary, binOp: "^", binL: left, binR: right)
  return left

proc parsePostfix(): Node =
  var e = parsePrimary()
  while pcur().kind == tkIncr or pcur().kind == tkDecr:
    if not isLvalue(e): break
    if pcur().kind == tkIncr:
      discard padvance()
      e = Node(kind: nkPostIncr, incrTarget: e)
    else:
      discard padvance()
      e = Node(kind: nkPostDecr, incrTarget: e)
  return e

proc parseLvalueSimple(): Node =
  if pcur().kind == tkDollar:
    discard padvance()
    let operand = parsePrimary()
    return Node(kind: nkField, fieldExpr: operand)
  elif pcur().kind == tkName:
    let name = pcur().sval
    discard padvance()
    if pcur().kind == tkLBracket:
      discard padvance()
      var idx = @[parseExpr()]
      while pmatch(tkComma): idx.add(parseExpr())
      pexpect(tkRBracket, "']'")
      return Node(kind: nkArrayIndex, arrName: name, arrIdx: idx)
    else:
      return Node(kind: nkVar, varName: name)
  else:
    return nil

proc parsePrimary(): Node =
  let t = pcur()
  case t.kind
  of tkNum:
    discard padvance()
    return Node(kind: nkNum, numVal: t.nval)
  of tkStr:
    discard padvance()
    return Node(kind: nkStr, strVal: t.sval)
  of tkEre:
    discard padvance()
    return Node(kind: nkRegex, reVal: t.sval)
  of tkDollar:
    discard padvance()
    let operand = parsePrimary()
    return Node(kind: nkField, fieldExpr: operand)
  of tkLParen:
    discard padvance()
    var list = @[parseExpr()]
    while pmatch(tkComma):
      pskipNewlines()
      list.add(parseExpr())
    pexpect(tkRParen, "')'")
    if list.len > 1:
      return Node(kind: nkExprList, listItems: list)
    return list[0]
  of tkName:
    let name = t.sval
    discard padvance()
    if pcur().kind == tkLBracket:
      discard padvance()
      var idx = @[parseExpr()]
      while pmatch(tkComma): idx.add(parseExpr())
      pexpect(tkRBracket, "']'")
      return Node(kind: nkArrayIndex, arrName: name, arrIdx: idx)
    elif pcur().kind == tkLParen:
      discard padvance()
      var args: seq[Node] = @[]
      if pcur().kind != tkRParen:
        args.add(parseExpr())
        while pmatch(tkComma):
          pskipNewlines()
          args.add(parseExpr())
      pexpect(tkRParen, "')'")
      return Node(kind: nkCall, callName: name, callArgs: args)
    else:
      return Node(kind: nkVar, varName: name)
  of tkGetline:
    discard padvance()
    var varNode: Node = nil
    if pcur().kind == tkName or pcur().kind == tkDollar:
      varNode = parseLvalueSimple()
    if pcur().kind == tkLt:
      discard padvance()
      let fileExpr = parseConcat()
      let mode = if varNode != nil: "varfile" else: "file"
      return Node(kind: nkGetline, glMode: mode, glVar: varNode, glSrc: fileExpr)
    else:
      let mode = if varNode != nil: "var" else: "plain"
      return Node(kind: nkGetline, glMode: mode, glVar: varNode, glSrc: nil)
  of tkNot:
    discard padvance()
    return Node(kind: nkNot, uExpr: parseUnary())
  of tkMinus:
    discard padvance()
    return Node(kind: nkUnaryMinus, uExpr: parseUnary())
  of tkPlus:
    discard padvance()
    return Node(kind: nkUnaryPlus, uExpr: parseUnary())
  of tkIncr:
    discard padvance()
    return Node(kind: nkPreIncr, incrTarget: parseUnary())
  of tkDecr:
    discard padvance()
    return Node(kind: nkPreDecr, incrTarget: parseUnary())
  else:
    stderr.writeLine("sawk: syntax error, unexpected token in expression")
    quit(2)

# Statements

proc parsePrintArgs(): seq[Node] =
  result = @[]
  let saved = pInPrintArgs
  pInPrintArgs = true
  if not (pcur().kind in {tkNewline, tkSemi, tkRBrace, tkEOF, tkGt, tkAppend, tkPipe}):
    let e = parseExpr()
    if e.kind == nkExprList and (pcur().kind in {tkNewline, tkSemi, tkRBrace, tkEOF, tkGt, tkAppend, tkPipe}):
      result = e.listItems
    else:
      result.add(e)
      while pmatch(tkComma):
        pskipNewlines()
        result.add(parseExpr())
  pInPrintArgs = saved

proc parseOptionalRedir(): (string, Node) =
  if pcur().kind == tkGt:
    discard padvance()
    return (">", parseConcat())
  elif pcur().kind == tkAppend:
    discard padvance()
    return (">>", parseConcat())
  elif pcur().kind == tkPipe:
    discard padvance()
    return ("|", parseConcat())
  else:
    return ("", nil)

proc parseSimpleStmt(): Stmt =
  if pcur().kind == tkDelete:
    discard padvance()
    let name = pcur().sval
    pexpect(tkName, "name after delete")
    if pcur().kind == tkLBracket:
      discard padvance()
      var idx = @[parseExpr()]
      while pmatch(tkComma): idx.add(parseExpr())
      pexpect(tkRBracket, "']'")
      return Stmt(kind: skDelete, delName: name, delIdx: idx)
    else:
      return Stmt(kind: skDeleteAll, delAllName: name)
  let e = parseExpr()
  return Stmt(kind: skExprStmt, exprS: e)

proc parseStmt(): Stmt =
  pskipNewlines()
  let t = pcur()
  case t.kind
  of tkLBrace:
    discard padvance()
    let stmts = parseStmtListUntil({tkRBrace})
    pexpect(tkRBrace, "'}'")
    return Stmt(kind: skBlock, blockStmts: stmts)
  of tkIf:
    discard padvance()
    pexpect(tkLParen, "'('")
    let cond = parseExpr()
    pexpect(tkRParen, "')'")
    let thenS = parseStmt()
    let saved = ppos
    pskipTerms()
    if pcur().kind == tkElse:
      discard padvance()
      let elseS = parseStmt()
      return Stmt(kind: skIf, ifCond: cond, ifThen: thenS, ifElse: elseS)
    else:
      ppos = saved
      return Stmt(kind: skIf, ifCond: cond, ifThen: thenS, ifElse: nil)
  of tkWhile:
    discard padvance()
    pexpect(tkLParen, "'('")
    let cond = parseExpr()
    pexpect(tkRParen, "')'")
    let body = parseStmt()
    return Stmt(kind: skWhile, whileCond: cond, whileBody: body)
  of tkDo:
    discard padvance()
    let body = parseStmt()
    pskipTerms()
    pexpect(tkWhile, "'while'")
    pexpect(tkLParen, "'('")
    let cond = parseExpr()
    pexpect(tkRParen, "')'")
    return Stmt(kind: skDoWhile, doCond: cond, doBody: body)
  of tkFor:
    discard padvance()
    pexpect(tkLParen, "'('")
    if pcur().kind == tkName and ppeek(1).kind == tkIn:
      let varName = pcur().sval
      discard padvance()
      discard padvance()
      let arrName = pcur().sval
      pexpect(tkName, "array name")
      pexpect(tkRParen, "')'")
      let body = parseStmt()
      return Stmt(kind: skForIn, forInVar: varName, forInArr: arrName, forInBody: body)
    else:
      var initS: Stmt = nil
      if pcur().kind != tkSemi: initS = parseSimpleStmt()
      pexpect(tkSemi, "';'")
      var condE: Node = nil
      if pcur().kind != tkSemi: condE = parseExpr()
      pexpect(tkSemi, "';'")
      var postS: Stmt = nil
      if pcur().kind != tkRParen: postS = parseSimpleStmt()
      pexpect(tkRParen, "')'")
      let body = parseStmt()
      return Stmt(kind: skFor, forInit: initS, forCond: condE, forPost: postS, forBody: body)
  of tkBreak:
    discard padvance()
    return Stmt(kind: skBreak)
  of tkContinue:
    discard padvance()
    return Stmt(kind: skContinue)
  of tkNext:
    discard padvance()
    return Stmt(kind: skNext)
  of tkNextfile:
    discard padvance()
    return Stmt(kind: skNextfile)
  of tkExit:
    discard padvance()
    var e: Node = nil
    if canStartExpr(pcur()): e = parseExpr()
    return Stmt(kind: skExit, retVal: e)
  of tkReturn:
    discard padvance()
    var e: Node = nil
    if canStartExpr(pcur()): e = parseExpr()
    return Stmt(kind: skReturn, retVal: e)
  of tkDelete:
    return parseSimpleStmt()
  of tkPrint:
    discard padvance()
    let args = parsePrintArgs()
    let (op, target) = parseOptionalRedir()
    return Stmt(kind: skPrint, printArgs: args, redirOp: op, redirTarget: target)
  of tkPrintf:
    discard padvance()
    let args = parsePrintArgs()
    let (op, target) = parseOptionalRedir()
    return Stmt(kind: skPrintf, printArgs: args, redirOp: op, redirTarget: target)
  of tkSemi:
    discard padvance()
    return Stmt(kind: skEmpty)
  else:
    let e = parseExpr()
    return Stmt(kind: skExprStmt, exprS: e)

proc parseStmtListUntil(closers: set[TokKind]): seq[Stmt] =
  result = @[]
  pskipTerms()
  while not (pcur().kind in closers) and pcur().kind != tkEOF:
    let s = parseStmt()
    result.add(s)
    pskipTerms()

proc parseFunctionDef(): FuncDef =
  discard padvance() # function
  let name = pcur().sval
  pexpect(tkName, "function name")
  pexpect(tkLParen, "'('")
  var params: seq[string] = @[]
  if pcur().kind != tkRParen:
    params.add(pcur().sval)
    pexpect(tkName, "parameter name")
    while pmatch(tkComma):
      pskipNewlines()
      params.add(pcur().sval)
      pexpect(tkName, "parameter name")
  pexpect(tkRParen, "')'")
  pskipNewlines()
  let body = parseStmt()
  return FuncDef(name: name, params: params, body: body)

proc parseProgram(toks: seq[Token]): Program =
  ptoks = toks
  ppos = 0
  pInPrintArgs = false
  result.rules = @[]
  result.funcs = initTable[string, FuncDef]()
  pskipTerms()
  while pcur().kind != tkEOF:
    if pcur().kind == tkFunction:
      let fd = parseFunctionDef()
      result.funcs[fd.name] = fd
    elif pcur().kind == tkBegin:
      discard padvance()
      pskipNewlines()
      pexpect(tkLBrace, "'{'")
      let stmts = parseStmtListUntil({tkRBrace})
      pexpect(tkRBrace, "'}'")
      result.rules.add(Rule(pat: pkBegin, action: Stmt(kind: skBlock, blockStmts: stmts)))
    elif pcur().kind == tkEnd:
      discard padvance()
      pskipNewlines()
      pexpect(tkLBrace, "'{'")
      let stmts = parseStmtListUntil({tkRBrace})
      pexpect(tkRBrace, "'}'")
      result.rules.add(Rule(pat: pkEnd, action: Stmt(kind: skBlock, blockStmts: stmts)))
    else:
      var rule = Rule(pat: pkAlways)
      if pcur().kind != tkLBrace:
        let e1 = parseExpr()
        if pmatch(tkComma):
          pskipNewlines()
          let e2 = parseExpr()
          rule.pat = pkRange
          rule.rangeStart = e1
          rule.rangeEnd = e2
        else:
          rule.pat = pkExpr
          rule.exprPat = e1
      if pcur().kind == tkLBrace:
        discard padvance()
        let stmts = parseStmtListUntil({tkRBrace})
        pexpect(tkRBrace, "'}'")
        rule.action = Stmt(kind: skBlock, blockStmts: stmts)
      else:
        rule.action = nil
      result.rules.add(rule)
    pskipTerms()

# Interpreter state

type
  ArrRef = ref Table[string, Value]

  Frame = object
    locals: Table[string, Value]
    arrays: Table[string, ArrRef]

  SrcCache = object
    content: string
    pos: int

  BreakExc = object of CatchableError
  ContinueExc = object of CatchableError
  NextExc = object of CatchableError
  NextfileExc = object of CatchableError
  ExitExc = object of CatchableError
  ReturnExc = object of CatchableError
    val: Value

var globals = initTable[string, Value]()
var globalArrays = initTable[string, ArrRef]()
var frames: seq[Frame] = @[]
var fields: seq[string] = @[""]
var prog: Program
var outFiles = initTable[string, File]()
var outProcs = initTable[string, Process]()
var inFileSrc = initTable[string, SrcCache]()
var inCmdSrc = initTable[string, SrcCache]()

var curContent = ""
var curPos = 0
var argIdx = 1
var anyFileProcessed = false
var stdinFallbackDone = false
var exitCodeVal = 0
var lastSeed = 0.0

proc newArrRef(): ArrRef =
  new(result)
  result[] = initTable[string, Value]()

proc rawSetGlobal(name: string, v: Value) =
  globals[name] = v

proc getGlobalRaw(name: string): string =
  if globals.hasKey(name): toStr(globals[name]) else: ""

proc getVar(name: string): Value =
  if name == "NF":
    return newNum((fields.len - 1).float)
  if frames.len > 0 and frames[^1].locals.hasKey(name):
    return frames[^1].locals[name]
  if globals.hasKey(name):
    return globals[name]
  return uninitV()

proc setNF(n: int)
proc resplitFields()

proc setVar(name: string, v: Value) =
  if name == "NF":
    setNF(int(toNum(v)))
    return
  if frames.len > 0 and frames[^1].locals.hasKey(name):
    frames[^1].locals[name] = v
    return
  globals[name] = v

proc getArrayRef(name: string): ArrRef =
  if frames.len > 0 and frames[^1].arrays.hasKey(name):
    return frames[^1].arrays[name]
  if not globalArrays.hasKey(name):
    globalArrays[name] = newArrRef()
  return globalArrays[name]

proc arrayHasEntries(name: string): bool =
  if frames.len > 0 and frames[^1].arrays.hasKey(name):
    return frames[^1].arrays[name][].len > 0
  if globalArrays.hasKey(name):
    return globalArrays[name][].len > 0
  return false

proc splitByFS(text: string, fs: string): seq[string] =
  if text.len == 0:
    return @[]
  if fs == " ":
    return text.splitWhitespace()
  elif fs.len == 0:
    result = @[]
    for ch in text:
      result.add($ch)
  elif fs.len == 1:
    return text.split(fs[0])
  else:
    try:
      let rx = re(fs)
      return text.split(rx)
    except:
      return @[text]

proc rebuildRecord() =
  let ofs = toStr(getVar("OFS"))
  var parts: seq[string] = @[]
  for i in 1 ..< fields.len:
    parts.add(fields[i])
  fields[0] = parts.join(ofs)

proc resplitFields() =
  let fsVal = toStr(getVar("FS"))
  let text = if fields.len > 0: fields[0] else: ""
  let parts = splitByFS(text, fsVal)
  fields = @[text]
  for p in parts: fields.add(p)

proc setNF(n: int) =
  var newN = n
  if newN < 0: newN = 0
  if newN < fields.len - 1:
    fields.setLen(newN + 1)
  else:
    while fields.len - 1 < newN:
      fields.add("")
  rebuildRecord()

proc setField(i: int, val: string) =
  if i == 0:
    fields[0] = val
    resplitFields()
  elif i > 0:
    if i > fields.len - 1:
      while fields.len - 1 < i:
        fields.add("")
    fields[i] = val
    rebuildRecord()

proc getField(i: int): Value =
  if i == 0:
    return newStrnum(fields[0])
  elif i >= 1 and i <= fields.len - 1:
    return newStrnum(fields[i])
  else:
    return newStr("")

proc buildSubscript(idxNodes: seq[Node], evalFn: proc(n: Node): Value): string =
  let subsep = toStr(getVar("SUBSEP"))
  var parts: seq[string] = @[]
  for nd in idxNodes:
    parts.add(toStr(evalFn(nd)))
  return parts.join(subsep)

# sprintf

proc toBaseStr(n: uint64, base: int): string =
  if n == 0: return "0"
  var x = n
  let digits = "0123456789abcdef"
  var s = ""
  while x > 0:
    s = $digits[int(x mod uint64(base))] & s
    x = x div uint64(base)
  return s

proc padGeneric(s: string, width: int, hasWidth: bool, leftAlign: bool, zeroPad: bool): string =
  if not hasWidth or s.len >= width:
    return s
  if leftAlign:
    return s & repeat(' ', width - s.len)
  elif zeroPad:
    return repeat('0', width - s.len) & s
  else:
    return repeat(' ', width - s.len) & s

proc awkSprintf(fmt: string, vals: seq[Value]): string =
  result = ""
  var vi = 0
  proc nextVal(): Value =
    if vi < vals.len:
      result = vals[vi]
      inc vi
    else:
      result = newStr("")
  var i = 0
  let L = fmt.len
  while i < L:
    let c = fmt[i]
    if c != '%':
      result.add(c)
      inc i
      continue
    inc i
    if i < L and fmt[i] == '%':
      result.add('%')
      inc i
      continue
    var leftAlign = false
    var zeroPad = false
    var plusSign = false
    var spaceSign = false
    var altForm = false
    while i < L and fmt[i] in {'-', '0', '+', ' ', '#'}:
      if fmt[i] == '-': leftAlign = true
      elif fmt[i] == '0': zeroPad = true
      elif fmt[i] == '+': plusSign = true
      elif fmt[i] == ' ': spaceSign = true
      elif fmt[i] == '#': altForm = true
      inc i
    var width = 0
    var hasWidth = false
    while i < L and fmt[i].isDigit:
      hasWidth = true
      width = width * 10 + (ord(fmt[i]) - ord('0'))
      inc i
    var prec = -1
    if i < L and fmt[i] == '.':
      inc i
      prec = 0
      while i < L and fmt[i].isDigit:
        prec = prec * 10 + (ord(fmt[i]) - ord('0'))
        inc i
    if i >= L: break
    let conv = fmt[i]
    inc i
    var piece = ""
    if conv == 'd' or conv == 'i':
      let v = nextVal()
      let n = int64(trunc(toNum(v)))
      var s = $(abs(n))
      if prec >= 0:
        if prec == 0 and n == 0: s = ""
        while s.len < prec: s = "0" & s
      var sign = ""
      if n < 0: sign = "-"
      elif plusSign: sign = "+"
      elif spaceSign: sign = " "
      if hasWidth and zeroPad and not leftAlign and prec < 0:
        let full = sign & s
        let padlen = max(0, width - full.len)
        piece = sign & repeat('0', padlen) & s
      else:
        piece = padGeneric(sign & s, width, hasWidth, leftAlign, false)
    elif conv == 'o':
      let v = nextVal()
      let n = int64(trunc(toNum(v)))
      var s = toBaseStr(cast[uint64](n), 8)
      if altForm and (s.len == 0 or s[0] != '0'): s = "0" & s
      piece = padGeneric(s, width, hasWidth, leftAlign, zeroPad and prec < 0)
    elif conv == 'x' or conv == 'X':
      let v = nextVal()
      let n = int64(trunc(toNum(v)))
      var s = toBaseStr(cast[uint64](n), 16)
      if conv == 'X': s = s.toUpperAscii()
      if altForm and n != 0:
        s = (if conv == 'X': "0X" else: "0x") & s
      piece = padGeneric(s, width, hasWidth, leftAlign, zeroPad and prec < 0)
    elif conv == 'u':
      let v = nextVal()
      let n = int64(trunc(toNum(v)))
      let un: uint64 = cast[uint64](n)
      piece = padGeneric($un, width, hasWidth, leftAlign, zeroPad)
    elif conv == 'c':
      let v = nextVal()
      var s: string
      if v.kind == vkNum:
        let code = int(v.n)
        s = if code >= 0 and code < 256: $chr(code) else: ""
      else:
        let str = toStr(v)
        s = if str.len > 0: $str[0] else: ""
      piece = padGeneric(s, width, hasWidth, leftAlign, false)
    elif conv == 's':
      let v = nextVal()
      var s = toStr(v)
      if prec >= 0 and prec < s.len: s = s[0 ..< prec]
      piece = padGeneric(s, width, hasWidth, leftAlign, false)
    elif conv == 'e' or conv == 'E':
      let v = nextVal()
      let p = if prec >= 0: prec else: 6
      var s = formatFloat(toNum(v), ffScientific, p)
      if conv == 'E': s = s.toUpperAscii()
      if toNum(v) >= 0:
        if plusSign: s = "+" & s
        elif spaceSign: s = " " & s
      piece = padGeneric(s, width, hasWidth, leftAlign, zeroPad)
    elif conv == 'f' or conv == 'F':
      let v = nextVal()
      let p = if prec >= 0: prec else: 6
      var s = formatFloat(toNum(v), ffDecimal, p)
      if toNum(v) >= 0:
        if plusSign: s = "+" & s
        elif spaceSign: s = " " & s
      piece = padGeneric(s, width, hasWidth, leftAlign, zeroPad)
    elif conv == 'g' or conv == 'G':
      let v = nextVal()
      let p0 = if prec >= 0: prec else: 6
      let p = if p0 == 0: 1 else: p0
      var s = formatFloat(toNum(v), ffDefault, p)
      if conv == 'G': s = s.toUpperAscii()
      if toNum(v) >= 0:
        if plusSign: s = "+" & s
        elif spaceSign: s = " " & s
      piece = padGeneric(s, width, hasWidth, leftAlign, zeroPad)
    else:
      piece = "%" & $conv
    result.add(piece)

proc numToStrFmt(n: float, fmt: string): string =
  awkSprintf(fmt, @[newNum(n)])

# Regex

proc doSub(s: string, pat: string, repl: string, doGlobal: bool): (string, int) =
  var rx: Regex
  try:
    rx = re(pat)
  except:
    return (s, 0)
  var res = ""
  var pos = 0
  var count = 0
  while pos <= s.len:
    let bounds = findBounds(s, rx, pos)
    if bounds.first < 0: break
    res.add(s[pos ..< bounds.first])
    let matched = s[bounds.first .. bounds.last]
    var rep = ""
    var i = 0
    while i < repl.len:
      if repl[i] == '\\' and i + 1 < repl.len and (repl[i+1] == '&' or repl[i+1] == '\\'):
        rep.add(repl[i+1]); i += 2
      elif repl[i] == '&':
        rep.add(matched); i += 1
      else:
        rep.add(repl[i]); i += 1
    res.add(rep)
    inc count
    if bounds.last < bounds.first:
      if bounds.first < s.len: res.add(s[bounds.first])
      pos = bounds.first + 1
    else:
      pos = bounds.last + 1
    if not doGlobal: break
  if pos <= s.len:
    res.add(s[pos ..< s.len])
  return (res, count)

proc extractRecord(content: string, pos: var int, rs: string): (bool, string) =
  if pos >= content.len:
    return (false, "")
  if rs.len == 1:
    let idx = content.find(rs[0], pos)
    if idx < 0:
      result = (true, content[pos ..< content.len])
      pos = content.len
    else:
      result = (true, content[pos ..< idx])
      pos = idx + 1
  elif rs.len == 0:
    while pos < content.len and content[pos] == '\n': inc pos
    if pos >= content.len: return (false, "")
    let startP = pos
    let idx = content.find("\n\n", pos)
    if idx < 0:
      result = (true, content[startP ..< content.len])
      pos = content.len
    else:
      result = (true, content[startP ..< idx])
      pos = idx
      while pos < content.len and content[pos] == '\n': inc pos
  else:
    try:
      let rx = re(rs)
      let bounds = findBounds(content, rx, pos)
      if bounds.first < 0:
        result = (true, content[pos ..< content.len])
        pos = content.len
      else:
        result = (true, content[pos ..< bounds.first])
        pos = bounds.last + 1
    except:
      result = (true, content[pos ..< content.len])
      pos = content.len

# Evaluator

proc eval(node: Node): Value
proc exec(s: Stmt)
proc assignTo(node: Node, v: Value)

proc regexPatternOf(n: Node): string =
  if n.kind == nkRegex: n.reVal
  else: toStr(eval(n))

proc applyOpAssign(op: string, cur: Value, rhs: Value): Value =
  let a = toNum(cur)
  let b = toNum(rhs)
  case op
  of "+=": return newNum(a + b)
  of "-=": return newNum(a - b)
  of "*=": return newNum(a * b)
  of "/=": return newNum(a / b)
  of "%=":
    if b == 0: return newNum(0.0)
    return newNum(a - b * trunc(a / b))
  of "^=": return newNum(pow(a, b))
  else: return rhs

proc evalBinArith(op: string, l, r: Value): Value =
  let a = toNum(l)
  let b = toNum(r)
  case op
  of "+": return newNum(a + b)
  of "-": return newNum(a - b)
  of "*": return newNum(a * b)
  of "/": return newNum(a / b)
  of "%":
    if b == 0: return newNum(0.0)
    return newNum(a - b * trunc(a / b))
  of "^": return newNum(pow(a, b))
  else: return newNum(0.0)

proc relSatisfies(op: string, c: int): bool =
  case op
  of "<": c < 0
  of "<=": c <= 0
  of ">": c > 0
  of ">=": c >= 0
  of "==": c == 0
  of "!=": c != 0
  else: false

# getline

proc advanceMainRecord(): (bool, string)

proc doGetlineFile(fname: string, intoVar: Node): Value =
  if not inFileSrc.hasKey(fname):
    var c: SrcCache
    try:
      c.content = if fname == "-": stdin.readAll() else: readFile(fname)
    except:
      return newNum(-1.0)
    c.pos = 0
    inFileSrc[fname] = c
  var cache = inFileSrc[fname]
  let rs = toStr(getVar("RS"))
  var p = cache.pos
  let (ok, rec) = extractRecord(cache.content, p, rs)
  cache.pos = p
  inFileSrc[fname] = cache
  if not ok: return newNum(0.0)
  if intoVar != nil:
    assignTo(intoVar, newStrnum(rec))
  else:
    fields = @[rec]
    resplitFields()
  return newNum(1.0)

proc doGetlineCmd(cmdStr: string, intoVar: Node): Value =
  if not inCmdSrc.hasKey(cmdStr):
    var c: SrcCache
    try:
      c.content = execProcess(cmdStr)
    except:
      c.content = ""
    c.pos = 0
    inCmdSrc[cmdStr] = c
  var cache = inCmdSrc[cmdStr]
  let rs = toStr(getVar("RS"))
  var p = cache.pos
  let (ok, rec) = extractRecord(cache.content, p, rs)
  cache.pos = p
  inCmdSrc[cmdStr] = cache
  if not ok: return newNum(0.0)
  rawSetGlobal("NR", newNum(toNum(getVar("NR")) + 1.0))
  if intoVar != nil:
    assignTo(intoVar, newStrnum(rec))
  else:
    fields = @[rec]
    resplitFields()
  return newNum(1.0)

proc doGetlinePlainLike(updateNF: bool, intoVar: Node): Value =
  let (ok, rec) = advanceMainRecord()
  if not ok: return newNum(0.0)
  rawSetGlobal("NR", newNum(toNum(getVar("NR")) + 1.0))
  rawSetGlobal("FNR", newNum(toNum(getVar("FNR")) + 1.0))
  if intoVar != nil:
    assignTo(intoVar, newStrnum(rec))
  else:
    fields = @[rec]
    resplitFields()
  return newNum(1.0)

# builtin / user function calls

proc callUserFunc(name: string, argNodes: seq[Node]): Value

proc callBuiltin(name: string, args: seq[Node]): Value =
  case name
  of "length":
    if args.len == 0:
      return newNum(fields[0].len.float)
    let a = args[0]
    if a.kind == nkVar and arrayHasEntries(a.varName):
      return newNum(getArrayRef(a.varName)[].len.float)
    return newNum(toStr(eval(a)).len.float)
  of "substr":
    let s = toStr(eval(args[0]))
    let startF = toNum(eval(args[1]))
    var hasLen = args.len >= 3
    var lenF = if hasLen: toNum(eval(args[2])) else: 0.0
    let slen = s.len
    var start = int(round(startF))
    var length: int
    if hasLen:
      length = int(round(lenF))
    else:
      length = 0
    if start < 1:
      if hasLen:
        length += start - 1
      start = 1
    if not hasLen:
      length = slen - start + 1
    if length < 0: length = 0
    if start > slen or length <= 0:
      return newStr("")
    let endPos = min(slen, start + length - 1)
    if start > endPos: return newStr("")
    return newStr(s[(start-1) .. (endPos-1)])
  of "index":
    let s = toStr(eval(args[0]))
    let t = toStr(eval(args[1]))
    let i = s.find(t)
    return newNum(if i < 0: 0.0 else: (i+1).float)
  of "split":
    let s = toStr(eval(args[0]))
    if args[1].kind != nkVar:
      return newNum(0.0)
    let arrName = args[1].varName
    let arr = getArrayRef(arrName)
    arr[].clear()
    var fsStr: string
    if args.len >= 3:
      fsStr = regexPatternOf(args[2])
    else:
      fsStr = toStr(getVar("FS"))
    let parts = splitByFS(s, fsStr)
    for i, p in parts:
      arr[][$(i+1)] = newStrnum(p)
    return newNum(parts.len.float)
  of "sub", "gsub":
    let pat = regexPatternOf(args[0])
    let repl = toStr(eval(args[1]))
    let targetNode = if args.len >= 3: args[2] else: Node(kind: nkField, fieldExpr: Node(kind: nkNum, numVal: 0.0))
    let curStr = toStr(eval(targetNode))
    let (newS, count) = doSub(curStr, pat, repl, name == "gsub")
    if count > 0:
      assignTo(targetNode, newStr(newS))
    return newNum(count.float)
  of "match":
    let s = toStr(eval(args[0]))
    let pat = regexPatternOf(args[1])
    try:
      let rx = re(pat)
      let bounds = findBounds(s, rx, 0)
      if bounds.first < 0:
        rawSetGlobal("RSTART", newNum(0.0))
        rawSetGlobal("RLENGTH", newNum(-1.0))
        return newNum(0.0)
      else:
        rawSetGlobal("RSTART", newNum((bounds.first + 1).float))
        rawSetGlobal("RLENGTH", newNum((bounds.last - bounds.first + 1).float))
        return newNum((bounds.first + 1).float)
    except:
      rawSetGlobal("RSTART", newNum(0.0))
      rawSetGlobal("RLENGTH", newNum(-1.0))
      return newNum(0.0)
  of "sprintf":
    let fmtStr = toStr(eval(args[0]))
    var vals: seq[Value] = @[]
    for i in 1 ..< args.len: vals.add(eval(args[i]))
    return newStr(awkSprintf(fmtStr, vals))
  of "sin": return newNum(sin(toNum(eval(args[0]))))
  of "cos": return newNum(cos(toNum(eval(args[0]))))
  of "atan2": return newNum(arctan2(toNum(eval(args[0])), toNum(eval(args[1]))))
  of "exp": return newNum(exp(toNum(eval(args[0]))))
  of "log": return newNum(ln(toNum(eval(args[0]))))
  of "sqrt": return newNum(sqrt(toNum(eval(args[0]))))
  of "int": return newNum(trunc(toNum(eval(args[0]))))
  of "rand": return newNum(rand(1.0))
  of "srand":
    let prev = lastSeed
    if args.len > 0:
      lastSeed = toNum(eval(args[0]))
    else:
      lastSeed = epochTime()
    randomize(int64(lastSeed))
    return newNum(prev)
  of "tolower": return newStr(toStr(eval(args[0])).toLowerAscii())
  of "toupper": return newStr(toStr(eval(args[0])).toUpperAscii())
  of "system":
    stdout.flushFile()
    let cmdStr = toStr(eval(args[0]))
    let code = execShellCmd(cmdStr)
    return newNum(code.float)
  of "close":
    let nm = toStr(eval(args[0]))
    var found = false
    if outFiles.hasKey(nm):
      outFiles[nm].close()
      outFiles.del(nm)
      found = true
    if outProcs.hasKey(nm):
      let p = outProcs[nm]
      try:
        p.inputStream.close()
      except:
        discard
      discard p.waitForExit()
      p.close()
      outProcs.del(nm)
      found = true
    if inFileSrc.hasKey(nm):
      inFileSrc.del(nm)
      found = true
    if inCmdSrc.hasKey(nm):
      inCmdSrc.del(nm)
      found = true
    return newNum(if found: 0.0 else: -1.0)
  of "fflush":
    if args.len == 0:
      stdout.flushFile()
    else:
      let nm = toStr(eval(args[0]))
      if outFiles.hasKey(nm): outFiles[nm].flushFile()
      if outProcs.hasKey(nm):
        try: outProcs[nm].inputStream.flush()
        except: discard
    return newNum(0.0)
  else:
    return callUserFunc(name, args)

proc eval(node: Node): Value =
  case node.kind
  of nkNum: return newNum(node.numVal)
  of nkStr: return newStr(node.strVal)
  of nkRegex:
    let s = fields[0]
    try:
      return newNum(if s.contains(re(node.reVal)): 1.0 else: 0.0)
    except:
      return newNum(0.0)
  of nkVar: return getVar(node.varName)
  of nkField:
    let idx = int(toNum(eval(node.fieldExpr)))
    return getField(idx)
  of nkArrayIndex:
    let arr = getArrayRef(node.arrName)
    let key = buildSubscript(node.arrIdx, eval)
    if not arr[].hasKey(key):
      arr[][key] = uninitV()
    return arr[][key]
  of nkExprList:
    if node.listItems.len > 0: return eval(node.listItems[^1])
    return uninitV()
  of nkAssign:
    let rhsVal = eval(node.asgnVal)
    var finalVal: Value
    if node.asgnOp == "=":
      finalVal = rhsVal
    else:
      let curVal = eval(node.asgnTarget)
      finalVal = applyOpAssign(node.asgnOp, curVal, rhsVal)
    assignTo(node.asgnTarget, finalVal)
    return finalVal
  of nkBinary:
    let l = eval(node.binL)
    let r = eval(node.binR)
    if node.binOp in ["<", "<=", ">", ">=", "==", "!="]:
      let c = compareVals(l, r)
      return newNum(if relSatisfies(node.binOp, c): 1.0 else: 0.0)
    return evalBinArith(node.binOp, l, r)
  of nkUnaryMinus: return newNum(-toNum(eval(node.uExpr)))
  of nkUnaryPlus: return newNum(toNum(eval(node.uExpr)))
  of nkNot: return newNum(if isTrue(eval(node.uExpr)): 0.0 else: 1.0)
  of nkPreIncr:
    let v = toNum(eval(node.incrTarget)) + 1.0
    assignTo(node.incrTarget, newNum(v))
    return newNum(v)
  of nkPreDecr:
    let v = toNum(eval(node.incrTarget)) - 1.0
    assignTo(node.incrTarget, newNum(v))
    return newNum(v)
  of nkPostIncr:
    let v = toNum(eval(node.incrTarget))
    assignTo(node.incrTarget, newNum(v + 1.0))
    return newNum(v)
  of nkPostDecr:
    let v = toNum(eval(node.incrTarget))
    assignTo(node.incrTarget, newNum(v - 1.0))
    return newNum(v)
  of nkAnd:
    if not isTrue(eval(node.logL)): return newNum(0.0)
    return newNum(if isTrue(eval(node.logR)): 1.0 else: 0.0)
  of nkOr:
    if isTrue(eval(node.logL)): return newNum(1.0)
    return newNum(if isTrue(eval(node.logR)): 1.0 else: 0.0)
  of nkTernary:
    if isTrue(eval(node.ternCond)): return eval(node.ternThen)
    return eval(node.ternElse)
  of nkMatch:
    let s = toStr(eval(node.matchL))
    let pat = regexPatternOf(node.matchR)
    var m = false
    try:
      m = s.contains(re(pat))
    except:
      m = false
    let r = if node.matchNeg: not m else: m
    return newNum(if r: 1.0 else: 0.0)
  of nkConcat:
    var sb = ""
    for p in node.concatParts: sb.add(toStr(eval(p)))
    return newStr(sb)
  of nkIn:
    let arr = getArrayRef(node.inArr)
    let key = buildSubscript(node.inIdx, eval)
    return newNum(if arr[].hasKey(key): 1.0 else: 0.0)
  of nkCall:
    return callBuiltin(node.callName, node.callArgs)
  of nkGetline:
    case node.glMode
    of "plain": return doGetlinePlainLike(true, nil)
    of "var": return doGetlinePlainLike(false, node.glVar)
    of "file": return doGetlineFile(toStr(eval(node.glSrc)), nil)
    of "varfile": return doGetlineFile(toStr(eval(node.glSrc)), node.glVar)
    of "cmd": return doGetlineCmd(toStr(eval(node.glSrc)), nil)
    of "varcmd": return doGetlineCmd(toStr(eval(node.glSrc)), node.glVar)
    else: return newNum(-1.0)

proc assignTo(node: Node, v: Value) =
  case node.kind
  of nkVar:
    setVar(node.varName, v)
  of nkField:
    let idx = int(toNum(eval(node.fieldExpr)))
    setField(idx, toStr(v))
  of nkArrayIndex:
    let arr = getArrayRef(node.arrName)
    let key = buildSubscript(node.arrIdx, eval)
    arr[][key] = v
  else:
    discard

proc callUserFunc(name: string, argNodes: seq[Node]): Value =
  if not prog.funcs.hasKey(name):
    stderr.writeLine("sawk: calling undefined function " & name)
    return uninitV()
  let fd = prog.funcs[name]
  var newFrame: Frame
  newFrame.locals = initTable[string, Value]()
  newFrame.arrays = initTable[string, ArrRef]()
  for idx, pname in fd.params:
    if idx < argNodes.len:
      let argNode = argNodes[idx]
      if argNode.kind == nkVar:
        let vname = argNode.varName
        newFrame.locals[pname] = getVar(vname)
        newFrame.arrays[pname] = getArrayRef(vname)
      else:
        newFrame.locals[pname] = eval(argNode)
        newFrame.arrays[pname] = newArrRef()
    else:
      newFrame.locals[pname] = uninitV()
      newFrame.arrays[pname] = newArrRef()
  frames.add(newFrame)
  var retVal = uninitV()
  try:
    exec(fd.body)
  except ReturnExc as e:
    retVal = e.val
  finally:
    frames.setLen(frames.len - 1)
  return retVal

# Statement execution

proc makeWriter(op: string, targetName: string): proc(s: string) =
  if op == "":
    return proc(s: string) = stdout.write(s)
  elif op == ">" or op == ">>":
    if not outFiles.hasKey(targetName):
      let f = if op == ">": open(targetName, fmWrite) else: open(targetName, fmAppend)
      outFiles[targetName] = f
    let fh = outFiles[targetName]
    return proc(s: string) = fh.write(s)
  elif op == "|":
    if not outProcs.hasKey(targetName):
      let p = startProcess(targetName, options = {poEvalCommand, poParentStreams})
      outProcs[targetName] = p
    let strm = outProcs[targetName].inputStream
    return proc(s: string) = strm.write(s)
  else:
    return proc(s: string) = stdout.write(s)

proc exec(s: Stmt) =
  if s == nil: return
  case s.kind
  of skEmpty: discard
  of skExprStmt: discard eval(s.exprS)
  of skBlock:
    for st in s.blockStmts: exec(st)
  of skIf:
    if isTrue(eval(s.ifCond)): exec(s.ifThen)
    elif s.ifElse != nil: exec(s.ifElse)
  of skWhile:
    while isTrue(eval(s.whileCond)):
      try:
        exec(s.whileBody)
      except BreakExc:
        break
      except ContinueExc:
        discard
  of skDoWhile:
    while true:
      try:
        exec(s.doBody)
      except BreakExc:
        break
      except ContinueExc:
        discard
      if not isTrue(eval(s.doCond)): break
  of skFor:
    if s.forInit != nil: exec(s.forInit)
    while true:
      if s.forCond != nil and not isTrue(eval(s.forCond)): break
      var brk = false
      try:
        exec(s.forBody)
      except BreakExc:
        brk = true
      except ContinueExc:
        discard
      if brk: break
      if s.forPost != nil: exec(s.forPost)
  of skForIn:
    let arr = getArrayRef(s.forInArr)
    var keys: seq[string] = @[]
    for k in arr[].keys: keys.add(k)
    for k in keys:
      setVar(s.forInVar, newStrnum(k))
      try:
        exec(s.forInBody)
      except BreakExc:
        break
      except ContinueExc:
        continue
  of skBreak:
    raise newException(BreakExc, "break")
  of skContinue:
    raise newException(ContinueExc, "continue")
  of skNext:
    raise newException(NextExc, "next")
  of skNextfile:
    raise newException(NextfileExc, "nextfile")
  of skExit:
    if s.retVal != nil: exitCodeVal = int(toNum(eval(s.retVal)))
    raise newException(ExitExc, "exit")
  of skReturn:
    var e = newException(ReturnExc, "return")
    e.val = if s.retVal != nil: eval(s.retVal) else: uninitV()
    raise e
  of skDelete:
    let arr = getArrayRef(s.delName)
    let key = buildSubscript(s.delIdx, eval)
    arr[].del(key)
  of skDeleteAll:
    let arr = getArrayRef(s.delAllName)
    arr[].clear()
  of skPrint:
    let targetName = if s.redirTarget != nil: toStr(eval(s.redirTarget)) else: ""
    let writer = makeWriter(s.redirOp, targetName)
    var outStr: string
    if s.printArgs.len == 0:
      outStr = fields[0]
    else:
      var parts: seq[string] = @[]
      for a in s.printArgs: parts.add(toOutStr(eval(a)))
      outStr = parts.join(toStr(getVar("OFS")))
    writer(outStr)
    writer(toStr(getVar("ORS")))
  of skPrintf:
    let targetName = if s.redirTarget != nil: toStr(eval(s.redirTarget)) else: ""
    let writer = makeWriter(s.redirOp, targetName)
    if s.printArgs.len == 0: return
    let fmtStr = toStr(eval(s.printArgs[0]))
    var vals: seq[Value] = @[]
    for i in 1 ..< s.printArgs.len: vals.add(eval(s.printArgs[i]))
    writer(awkSprintf(fmtStr, vals))

# Input mgmt

proc isAssignmentArg(s: string): bool =
  if s.len == 0: return false
  if not (s[0].isAlphaAscii or s[0] == '_'): return false
  var i = 1
  while i < s.len and (s[i].isAlphaNumeric or s[i] == '_'): inc i
  return i < s.len and s[i] == '='

proc applyAssignmentArg(s: string) =
  let eqIdx = s.find('=')
  let name = s[0 ..< eqIdx]
  let valraw = s[(eqIdx+1) ..< s.len]
  setVar(name, newStrnum(interpretEscapes(valraw)))

proc openNextInputIfNeeded(): bool =
  while true:
    let argc = int(toNum(getVar("ARGC")))
    if argIdx >= argc:
      if not anyFileProcessed and not stdinFallbackDone:
        stdinFallbackDone = true
        anyFileProcessed = true
        curContent = stdin.readAll()
        curPos = 0
        rawSetGlobal("FILENAME", newStr(""))
        rawSetGlobal("FNR", newNum(0.0))
        return true
      return false
    let argvArr = getArrayRef("ARGV")
    let av = if argvArr[].hasKey($argIdx): toStr(argvArr[][$argIdx]) else: ""
    inc argIdx
    if av.len == 0: continue
    if isAssignmentArg(av):
      applyAssignmentArg(av)
      continue
    else:
      anyFileProcessed = true
      try:
        curContent = if av == "-": stdin.readAll() else: readFile(av)
      except:
        stderr.writeLine("sawk: can't open file " & av)
        continue
      curPos = 0
      rawSetGlobal("FILENAME", newStr(av))
      rawSetGlobal("FNR", newNum(0.0))
      return true

proc advanceMainRecord(): (bool, string) =
  while true:
    let rs = toStr(getVar("RS"))
    var p = curPos
    let (ok, rec) = extractRecord(curContent, p, rs)
    curPos = p
    if ok:
      return (true, rec)
    else:
      if not openNextInputIfNeeded():
        return (false, "")

proc execAction(r: Rule) =
  if r.action == nil:
    stdout.write(fields[0])
    stdout.write(toStr(getVar("ORS")))
  else:
    exec(r.action)

proc runRuleAction(r: Rule) =
  case r.pat
  of pkAlways:
    execAction(r)
  of pkExpr:
    if isTrue(eval(r.exprPat)): execAction(r)
  of pkRange:
    if not r.rangeActive:
      if isTrue(eval(r.rangeStart)):
        r.rangeActive = true
        execAction(r)
        if isTrue(eval(r.rangeEnd)):
          r.rangeActive = false
    else:
      execAction(r)
      if isTrue(eval(r.rangeEnd)):
        r.rangeActive = false
  else:
    discard

proc processMainRecord() =
  for r in prog.rules:
    if r.pat == pkBegin or r.pat == pkEnd: continue
    try:
      runRuleAction(r)
    except NextExc:
      return

proc runMainLoop() =
  while true:
    let (ok, rec) = advanceMainRecord()
    if not ok: break
    rawSetGlobal("NR", newNum(toNum(getVar("NR")) + 1.0))
    rawSetGlobal("FNR", newNum(toNum(getVar("FNR")) + 1.0))
    fields = @[rec]
    resplitFields()
    try:
      processMainRecord()
    except NextfileExc:
      curPos = curContent.len
      continue

proc closeAll() =
  for k, f in outFiles.pairs:
    try: f.close()
    except: discard
  for k, p in outProcs.pairs:
    try:
      p.inputStream.close()
      discard p.waitForExit()
      p.close()
    except: discard
  stdout.flushFile()

# Main

proc initSpecialVars() =
  rawSetGlobal("FS", newStr(" "))
  rawSetGlobal("OFS", newStr(" "))
  rawSetGlobal("ORS", newStr("\n"))
  rawSetGlobal("RS", newStr("\n"))
  rawSetGlobal("SUBSEP", newStr("\x1c"))
  rawSetGlobal("CONVFMT", newStr("%.6g"))
  rawSetGlobal("OFMT", newStr("%.6g"))
  rawSetGlobal("NR", newNum(0.0))
  rawSetGlobal("FNR", newNum(0.0))
  rawSetGlobal("FILENAME", newStr(""))
  rawSetGlobal("RSTART", newNum(0.0))
  rawSetGlobal("RLENGTH", newNum(-1.0))
  let envArr = getArrayRef("ENVIRON")
  for k, v in envPairs():
    envArr[][k] = newStrnum(v)

proc main() =
  randomize(0)
  initSpecialVars()
  let allArgs = commandLineParams()
  var fsOverride = ""
  var vAssigns: seq[string] = @[]
  var progFiles: seq[string] = @[]
  var progText = ""
  var haveProgText = false
  var i = 0
  var restArgs: seq[string] = @[]
  while i < allArgs.len:
    let a = allArgs[i]
    if a == "--":
      inc i
      break
    elif a == "-F":
      inc i
      if i < allArgs.len: fsOverride = allArgs[i]
      inc i
    elif a.startsWith("-F"):
      fsOverride = a[2 .. ^1]
      inc i
    elif a == "-v":
      inc i
      if i < allArgs.len: vAssigns.add(allArgs[i])
      inc i
    elif a.startsWith("-v"):
      vAssigns.add(a[2 .. ^1])
      inc i
    elif a == "-f":
      inc i
      if i < allArgs.len: progFiles.add(allArgs[i])
      inc i
    elif a.startsWith("-f"):
      progFiles.add(a[2 .. ^1])
      inc i
    elif a == "-":
      break
    elif a.len > 1 and a[0] == '-' and progFiles.len == 0 and not haveProgText:
      inc i
    else:
      break
  if progFiles.len > 0:
    var texts: seq[string] = @[]
    for pf in progFiles:
      try:
        texts.add(readFile(pf))
      except:
        stderr.writeLine("sawk: can't open program file " & pf)
        quit(2)
    progText = texts.join("\n")
    haveProgText = true
  else:
    if i < allArgs.len:
      progText = allArgs[i]
      haveProgText = true
      inc i
  while i < allArgs.len:
    restArgs.add(allArgs[i])
    inc i
  if not haveProgText:
    stderr.writeLine("                   _    ");
    stderr.writeLine(" _____      ____ _| | __");
    stderr.writeLine("/ __\\ \\ /\\ / / _` | |/ /");
    stderr.writeLine("\\__ \\\\ V  V / (_| |   < https://lipunila.sonaliwan.fr");
    stderr.writeLine("|___/ \\_/\\_/ \\__,_|_|\\_\\1.0.2");
    stderr.writeLine("usage: sawk [-F fs] [-v var=val] 'program' [file ...]")
    stderr.writeLine("       sawk [-F fs] [-v var=val] -f progfile [file ...]")
    quit(2)

  if fsOverride != "":
    var fs = fsOverride
    if fs == "\\t": fs = "\t"
    else: fs = interpretEscapes(fs)
    rawSetGlobal("FS", newStr(fs))

  for va in vAssigns:
    if isAssignmentArg(va):
      applyAssignmentArg(va)

  let argvArr = getArrayRef("ARGV")
  argvArr[]["0"] = newStr("sawk")
  for idx, a in restArgs:
    argvArr[][$(idx+1)] = newStrnum(a)
  rawSetGlobal("ARGC", newNum((restArgs.len + 1).float))

  let toks = tokenize(progText)
  prog = parseProgram(toks)

  var hasNonBegin = false
  for r in prog.rules:
    if r.pat != pkBegin: hasNonBegin = true

  var exited = false
  try:
    for r in prog.rules:
      if r.pat == pkBegin:
        exec(r.action)
  except ExitExc:
    exited = true

  if not exited and hasNonBegin:
    try:
      runMainLoop()
    except ExitExc:
      discard

  var inEnd = true
  try:
    for r in prog.rules:
      if r.pat == pkEnd:
        exec(r.action)
  except ExitExc:
    discard
  discard inEnd

  closeAll()
  quit(exitCodeVal)

main()
