import std/[options, sequtils, strutils, parseutils, strformat, tables, paths, files, dirs, cmdline]
import fusion/matching


type
  TokenKind = enum
    tkText, tkExpr
    tkFun="fun", tkExtends="extends", tkBlock="block"
    tkFor="for", tkIf="if", tkElseif="elseif", tkElse="else", tkMatch="match"
    tkCase="|", tkEnd="end"

  Token = object
    pos: int
    kind: TokenKind
    val: string

  Branch = tuple
    cond: string
    body: seq[Node]

  NodeKind = enum nkText, nkExpr, nkIf, nkFor, nkMatch, nkBlock
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
    of nkBlock:
      blockName: string
      blockBody: seq[Node]

  Template = object
    funHead: Option[string]
    case isExtending: bool
    of true:
      extends: string
      extendsDefPos: int
      blocks: Table[string, seq[Node]]
    of false:
      body: seq[Node]

  CompileError = ref object of CatchableError
    filename: string
    pos: int


func textToken(pos: int, text: string): Token {.inline.} =
  Token(pos: pos, kind: tkText, val: text)

proc lex(code, filename: string): seq[Token] =
  var i = code.skipWhitespace()

  template error(posDef: int, msgDef: string) =
    raise CompileError(filename: filename, pos: posDef, msg: msgDef)

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
          token.val = s[j..^1].strip()
          case token.kind
          of tkEnd, tkElse:
            error(j, &"unexpected '{token.val}' after '{keyword}'")
          of tkText, tkExpr, tkCase:
            error(j, &"unexpected '{s}'")
          else:
            discard
        except ValueError:
          error(i, &"unknown keyword '{keyword}'")
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
      if textStart < textEnd:
        tokens &= textToken(textStart, code[textStart ..< textEnd])
      tokens &= token
      textStart = i
      continue
    i = textEnd + 1

  if textStart < high(code):
    tokens &= textToken(textStart, code[textStart..^1])

  tokens


proc parse(
  tokens: seq[Token],
  filename: string,
  isPartial = false
): Template =

  var i = 0

  if len(tokens) == 0:
    raise CompileError(filename: filename, pos: 0, msg: "empty file")

  template error(token: Token, msgDef: string) =
    raise CompileError(filename: filename, pos: token.pos, msg: msgDef)
  
  # get funtion head
  let funHead =block:
    let token = tokens[0]
    if token.kind == tkFun:
      if isPartial:
        token.error("partial templates should have no 'fun' declaration")
      inc i
      some(token.val)
    elif isPartial:
      none(string)
    else:
      token.error(
        &"non-partial template file must start with a 'fun' declaration. If '{filename}' should be partial name it '_{filename}'")

  # get extends
  result = 
    if len(tokens) > i and (let token = tokens[i]; token.kind == tkExtends):
      inc i
      Template(isExtending: true, extends: token.val, extendsDefPos: token.pos)
    elif (
      len(tokens) > i+1 and
      (let token = tokens[i+1]; token.kind == tkExtends and
      tokens[i].kind == tkText and tokens[1].val.allIt(it in Whitespace))
    ):
      i += 2
      Template(isExtending: true, extends: token.val, extendsDefPos: token.pos)
    else:
      Template(isExtending: false)

  result.funHead = funHead

  proc parseNodes(stopOn: set[TokenKind] = {}, needsClosingEnd=true): seq[Node] =
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

        of tkBlock:
          Node(kind: nkBlock, blockName: token.val, blockBody: parseNodes())

        of tkEnd:
          if not needsClosingEnd:
            token.error("unexpected 'end'")
          return

        else:
          if token.kind in stopOn:
            dec i
            return
          token.error(&"unexpected '{token.kind}'")

    if needsClosingEnd:
      raise CompileError(
        filename: filename, pos: -1,
        msg: "unexpected end of file. forgot a closing 'end' ?"
      ) #todo correct `pos`

  if not result.isExtending:
    result.body = parseNodes(needsClosingEnd=false)

  else:
    while i < len(tokens):
      let token = tokens[i]
      inc i
      case token.kind
      of tkBlock:
        if token.val in result.blocks:
          token.error(&"double definition of block '{token.val}'")
        result.blocks[token.val] = parseNodes()

      of tkText:
        if not token.val.allIt(it in Whitespace):
          token.error("extending templates should only contain block definitions")
      else:
        token.error(&"unexpected '{token.kind}'")

  assert i >= high(tokens)


func replaceBlocks(templ: Template, blocks: Table[string, seq[Node]]): Template =
  proc replaceBlocks(nodes: seq[Node]): seq[Node] =
    result = @[]
    for node in nodes:
      case node.kind
      of nkText, nkExpr: result &= node
      of nkBlock:
        if node.blockName in blocks:
          result &= blocks[node.blockName]
        else:
          result &= Node(
            kind: nkBlock,
            blockName: node.blockName,
            blockBody: replaceBlocks(node.blockBody)
          )
      of nkFor:
        result &= Node(
          kind: nkFor,
          forIter: node.forIter,
          forBody: replaceBlocks(node.forBody)
        )
      of nkIf:
        result &= Node(
          kind: nkIf,
          ifElseBody: replaceBlocks(node.ifElseBody),
          ifBranches: node.ifBranches.mapIt((it.cond, replaceBlocks(it.body)))
        )
      of nkMatch:
        result &= Node(
          kind: nkMatch,
          matchOn: node.matchOn,
          matchElseBody: node.matchElseBody.map(replaceBlocks),
          cases: node.cases.mapIt((it.cond, replaceBlocks(it.body)))
        )

  assert not templ.isExtending
  Template(isExtending: false, body: replaceBlocks(templ.body))

proc expandExtension(
  filename: string,
  templ: var Template,
  ctx: var Table[string, Template]
) =
  if templ.isExtending:
    if templ.extends notin ctx:
      raise CompileError(
        filename: filename, pos: templ.extendsDefPos,
        msg: &"'{templ.extends}' not found"
      )
    expandExtension(templ.extends, ctx[templ.extends], ctx)
    let funHead = templ.funHead
    templ = replaceBlocks(ctx[templ.extends], templ.blocks)
    templ.funHead = funHead


proc generate(temp: Template): string =
  
  assert temp.funHead.isSome
  var code = &"  fun {temp.funHead.get}: String => "

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

      of nkBlock:
        generate(node.blockBody)

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

  try:
    const preambleFilename = "preamble.pony"
    let preamblePath = folder/Path(preambleFilename)
    if fileExists(preamblePath):
      code &= readFile($preamblePath) & "\n\n"

    var templs: Table[string, Template]
    for kind, path in walkDir(folder):
      let filename = $path.lastPathPart()
      if kind == pcFile and filename != preambleFilename:
        templs[filename] =
          readFile($path)
          .lex(filename)
          .parse(filename, isPartial=filename.startsWith("_"))

    for filename, templ in templs.mpairs:
      expandExtension(filename, templ, templs)

    code &= "primitive " & folder.lastPathPart().`$`.toPascalCase() & "\n"
    for templ in templs.values:
      if templ.funHead.isSome:
        code &= '\n' & generate(templ)

  except CompileError as e:
    quit &"{e.filename}({e.pos}) {e.msg}"
      
  writeFile($folder.changeFileExt("pony"), code)


when isMainModule:
  if paramCount() != 1:
    quit "Usage:\ncomptempl [TEMPLATE_DIR]\n"
  compile(Path paramStr(1))