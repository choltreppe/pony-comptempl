import std/[options, sequtils, strutils, parseutils, strformat, paths, files, dirs, cmdline]
import fusion/matching


type
  TokenKind = enum
    tkText, tkExpr
    tkFun="fun", tkFor="for", tkIf="if", tkElseif="elseif", tkElse="else", tkMatch="match"
    tkCase="|", tkEnd="end"

  Token = object
    pos: int
    kind: TokenKind
    val: string

  Branch = tuple
    cond: string
    body: seq[Node]

  NodeKind = enum nkText, nkExpr, nkIf, nkFor, nkMatch
  Node = ref object
    case kind: NodeKind
    of nkText, nkExpr: val: string
    of nkFor:
      forIter: string
      forBody: seq[Node]
    of nkIf:
      ifBranches: seq[Branch]
      ifElseBody: seq[Node]
    of nkMatch:
      matchOn: string
      cases: seq[Branch]
      matchElseBody: Option[seq[Node]]

  Template = object
    funHead: string
    body: seq[Node]

  SyntaxError = ref object of CatchableError
    pos: int


func textToken(pos: int, text: string): Token {.inline.} =
  Token(pos: pos, kind: tkText, val: text)

proc lex(code: string): seq[Token] =
  var i = code.skipWhitespace()

  proc tryParseCtrl: Option[Token] =
    inc i
    if i >= high(code):
      return none(Token)
    var token = Token(pos: i)
    inc i
    case code[token.pos]
    of '{':
      token.kind = tkExpr
      i += code.parseUntil(token.val, "}}", i)
    of '|':
      token.kind = tkCase
      i += code.parseUntil(token.val, "|}", i)
    of '%':
      var s: string
      i += code.parseUntil(s, "%}", i)
      s = strip(s)
      case s
      of "end":  token.kind = tkEnd
      of "else": token.kind = tkElse
      else:
        var keyword: string
        let j = s.parseUntil(keyword, Whitespace) + 1
        try:
          token.kind = parseEnum[TokenKind](keyword)
          token.val = s[j..^1]
        except ValueError:
          raise SyntaxError(pos: i, msg: &"unknown keyword '{keyword}'")
    else:
      return
    
    i += 2
    some(token)

  var tokens: seq[Token]

  var textStart = i
  while i < len(code):
    i += code.skipUntil('{', i)
    let textEnd = i #potentually
    if Some(@token) ?= tryParseCtrl():
      if textStart < textEnd-1:
        tokens &= textToken(textStart, code[textStart ..< textEnd])
      tokens &= token
      textStart = i
      continue
    i = textEnd + 1

  if textStart < high(code):
    tokens &= textToken(textStart, code[textStart..^1])

  tokens


func error(token: Token, msg: string): SyntaxError {.inline.} =
  SyntaxError(pos: token.pos, msg: msg)

proc parse(tokens: seq[Token]): Template =

  if len(tokens) == 0:
    raise SyntaxError(pos: 0, msg: "empty file")
  if tokens[0].kind != tkFun:
    raise tokens[0].error("template file must start with a 'fun' definition")

  var i = 1

  proc parseNodes(stopOn: set[TokenKind] = {}): seq[Node] =
    while i < len(tokens):
      let token = tokens[i]
      inc i

      result.add: 
        case token.kind
        of tkText: Node(kind: nkText, val: token.val)
        of tkExpr: Node(kind: nkExpr, val: token.val)

        of tkFor:
          Node(
            kind: nkFor,
            forIter: token.val,
            forBody: parseNodes()
          )

        of tkIf:
          var node = Node(
            kind: nkIf,
            ifBranches: @[(token.val, parseNodes({tkElseif, tkElse}))]
          )
          while (let token = tokens[i]; token.kind == tkElseif):
            inc i
            node.ifBranches &= (token.val, parseNodes({tkElseif, tkElse}))

          node.ifElseBody = 
            if tokens[i].kind == tkElse:
              inc i
              parseNodes()
            else:
              @[Node(kind: nkText)]
          
          node

        of tkMatch:
          var node = Node(kind: nkMatch, matchOn: token.val)
          if (
            let token = tokens[i];
            token.kind == tkText and
            token.val.allIt(it in Whitespace)
          ):
            inc i
          
          while (let token = tokens[i]; token.kind == tkCase):
            inc i
            node.cases &= (token.val, parseNodes({tkCase, tkElse}))

          if tokens[i].kind == tkElse:
            inc i
            node.matchElseBody = some(parseNodes())

          node

        of tkEnd: return

        else:
          if token.kind in stopOn:
            dec i
            return
          raise token.error(&"unexpected '{token.kind}'")

  Template(funHead: tokens[0].val, body: parseNodes())


proc generate(temp: Template): string =
  
  var code = &"  fun {temp.funHead}: String => "

  var tmpId = 0
  proc tmpVar: string =
    result = "t" & $tmpId
    inc tmpId

  proc generate(nodes: seq[Node]) =

    for i, node in nodes:
      if i > 0:
        code &= " + "

      case node.kind
      of nkText: code &= '"' & node.val.replace("\"", "\\\"").indent(4)[4..^1] & '"'
      of nkExpr: code &= '(' & node.val & ')'

      of nkFor:
        let tmp = tmpVar()
        code &= &"(var {tmp} = \"\"; for {node.forIter} do {tmp} = {tmp} + "
        generate(node.forBody)
        code &= &" end; {tmp}) "

      of nkIf:
        let (cond, body) = node.ifBranches[0]
        code &= &"(if {cond} then "
        generate(body)
        for (cond, body) in node.ifBranches[1..^1]:
          code &= &" elseif {cond} then "
          generate(body)
        code &= " else "
        generate(node.ifElseBody)
        code &= " end)"

      of nkMatch:
        code &= &"(match {node.matchOn} "
        for (cond, body) in node.cases:
          code &= " | " & cond & " => "
          generate(body)
        if Some(@body) ?= node.matchElseBody:
          code &= " else "
          generate(body)
        code &= " end)"

  generate(temp.body)
  code & "\n"


func toPascalCase(s: string): string =
  result = newStringOfCap(len(s))
  result &= s[0].toUpperAscii()
  var i = 1
  while i < len(s):
    let c = s[i]
    if c in {'_', '-'}:
      inc i
      result &= s[i].toUpperAscii()
    else:
      result &= c
    inc i

proc compile(folder: Path) =
  var code = ""

  const preambleFilename = "preamble.pony"
  let preamblePath = folder/Path(preambleFilename)
  if fileExists(preamblePath):
    code &= readFile($preamblePath) & "\n\n"

  code &= "primitive " & folder.lastPathPart().`$`.toPascalCase() & "\n"

  for kind, path in walkDir(folder):
    if kind == pcFile and $path.lastPathPart() != preambleFilename:
      code &= '\n' & generate(readFile($path).lex.parse)

  writeFile($folder.changeFileExt("pony"), code)


when isMainModule:
  if paramCount() != 1:
    quit "Usage:\ncomptempl [TEMPLATE_DIR]\n"
  compile(Path paramStr(1))