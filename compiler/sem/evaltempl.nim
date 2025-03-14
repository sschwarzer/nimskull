#
#
#           The Nim Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Template evaluation engine. Now hygienic.

import
  ast/[
    ast,
    astalgo,
    lineinfos,
    idents,
    renderer,
    reports
  ],
  front/[
    options,
    msgs
  ]

type
  TemplCtx = object
    owner, genSymOwner: PSym
    instLines: bool   ## use the instantiation lines numbers
    isDeclarative: bool
    mapping: TIdTable ## every gensym'ed symbol needs to be mapped to some
                      ## new symbol
    config: ConfigRef
    ic: IdentCache
    instID: int
    idgen: IdGenerator

proc copyNode(ctx: TemplCtx, a, b: PNode): PNode =
  result = copyNode(a)
  if ctx.instLines: result.info = b.info

proc evalTemplateAux(templ, actual: PNode, c: var TemplCtx, result: PNode) =
  template handleParam(param) =
    let x = param
    if x.kind == nkArgList:
      for y in items(x): result.add(y)
    else:
      result.add copyTree(x)

  case templ.kind
  of nkSym:
    var s = templ.sym
    if (s.owner == nil and s.kind == skParam) or s.owner == c.owner:
      if s.kind == skParam and {sfGenSym, sfTemplateParam} * s.flags == {sfTemplateParam}:
        handleParam actual[s.position]
      elif (s.owner != nil) and (s.kind == skGenericParam or
           s.kind == skType and s.typ != nil and s.typ.kind == tyGenericParam):
        handleParam actual[s.owner.typ.len + s.position - 1]
      else:
        internalAssert(c.config, sfGenSym in s.flags or s.kind == skType, "")
        var x = PSym(idTableGet(c.mapping, s))
        if x == nil:
          x = copySym(s, nextSymId(c.idgen))
          # sem'check needs to set the owner properly later, see bug #9476
          x.owner = nil # c.genSymOwner
          #if x.kind == skParam and x.owner.kind == skModule:
          #  internalAssert c.config, false
          idTablePut(c.mapping, s, x)
        if sfGenSym in s.flags:
          result.add newIdentNode(getIdent(c.ic, x.name.s & "`gensym" & $c.instID),
            if c.instLines: actual.info else: templ.info)
        else:
          result.add newSymNode(x, if c.instLines: actual.info else: templ.info)
    else:
      result.add copyNode(c, templ, actual)
  of nkNone..nkIdent, nkType..nkNilLit: # atom
    result.add copyNode(c, templ, actual)
  of nkCommentStmt:
    # for the documentation generator we don't keep documentation comments
    # in the AST that would confuse it (bug #9432), but only if we are not in a
    # "declarative" context (bug #9235).
    if c.isDeclarative:
      var res = copyNode(c, templ, actual)
      for i in 0..<templ.len:
        evalTemplateAux(templ[i], actual, c, res)
      result.add res
    else:
      result.add newNodeI(nkEmpty, templ.info)
  else:
    var isDeclarative = false
    if templ.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkIteratorDef,
                      nkMacroDef, nkTemplateDef, nkConverterDef, nkTypeSection,
                      nkVarSection, nkLetSection, nkConstSection} and
        not c.isDeclarative:
      c.isDeclarative = true
      isDeclarative = true
    if (not c.isDeclarative) and templ.kind in nkCallKinds and isRunnableExamples(templ[0]):
      # fixes bug #16993, bug #18054
      discard
    else:
      var res = copyNode(c, templ, actual)
      for i in 0..<templ.len:
        evalTemplateAux(templ[i], actual, c, res)
      result.add res
    if isDeclarative: c.isDeclarative = false

proc evalTemplateArgs(n: PNode, s: PSym; conf: ConfigRef; fromHlo: bool): PNode =
  # if the template has zero arguments, it can be called without ``()``
  # `n` is then a nkSym or something similar
  var totalParams = case n.kind
    of nkCallKinds: n.len-1
    else: 0

  var
    # XXX: Since immediate templates are not subject to the
    # standard sigmatching algorithm, they will have a number
    # of deficiencies when it comes to generic params:
    # Type dependencies between the parameters won't be honoured
    # and the bound generic symbols won't be resolvable within
    # their bodies. We could try to fix this, but it may be
    # wiser to just deprecate immediate templates and macros
    # now that we have working untyped parameters.
    genericParams = if fromHlo: 0
                    else: s.ast[genericParamsPos].len
    expectedRegularParams = s.typ.len-1
    givenRegularParams = totalParams - genericParams
  if givenRegularParams < 0: givenRegularParams = 0

  if totalParams > expectedRegularParams + genericParams:
    globalReport(conf, n.info, reportAst(rsemWrongNumberOfArguments, n))

  if totalParams < genericParams:
    globalReport(conf, n.info, reportAst(
      rsemMissingGenericParamsForTemplate, n, sym = s))

  result = newNodeI(nkArgList, n.info)
  for i in 1..givenRegularParams:
    result.add n[i]

  # handle parameters with default values, which were
  # not supplied by the user
  for i in givenRegularParams+1..expectedRegularParams:
    let default = s.typ.n[i].sym.ast
    if default.isNil or default.kind == nkEmpty:
      localReport(conf, n, reportSem rsemWrongNumberOfArguments)
      result.add newNodeI(nkEmpty, n.info)
    else:
      result.add default.copyTree

  # add any generic parameters
  for i in 1..genericParams:
    result.add n[givenRegularParams + i]

# to prevent endless recursion in template instantiation
const evalTemplateLimit* = 1000

proc wrapInComesFrom*(info: TLineInfo; sym: PSym; res: PNode): PNode =
  when true:
    result = res
    result.info = info
    if result.kind in {nkStmtList, nkStmtListExpr} and result.len > 0:
      result.lastSon.info = info
    when false:
      # this hack is required to
      var x = result
      while x.kind == nkStmtListExpr: x = x.lastSon
      if x.kind in nkCallKinds:
        for i in 1..<x.len:
          if x[i].kind in nkCallKinds:
            x[i].info = info
  else:
    result = newNodeI(nkStmtListExpr, info)
    var d = newNodeI(nkComesFrom, info)
    d.add newSymNode(sym, info)
    result.add d
    result.add res
    result.typ = res.typ

proc evalTemplate*(n: PNode, tmpl, genSymOwner: PSym;
                   conf: ConfigRef;
                   ic: IdentCache; instID: ref int;
                   idgen: IdGenerator;
                   fromHlo=false): PNode =
  inc(conf.evalTemplateCounter)
  if conf.evalTemplateCounter > evalTemplateLimit:
    globalReport(conf, n.info, SemReport(
      kind: rsemTemplateInstantiationTooNested))

    result = n

  # replace each param by the corresponding node:
  var args = evalTemplateArgs(n, tmpl, conf, fromHlo)
  var ctx: TemplCtx
  ctx.owner = tmpl
  ctx.genSymOwner = genSymOwner
  ctx.config = conf
  ctx.ic = ic
  initIdTable(ctx.mapping)
  ctx.instID = instID[]
  ctx.idgen = idgen

  let body = tmpl.ast[bodyPos]
  #echo "instantion of ", renderTree(body, {renderIds})
  if isAtom(body):
    result = newNodeI(nkPar, body.info)
    evalTemplateAux(body, args, ctx, result)
    if result.len == 1:
      result = result[0]

    else:
      localReport(conf, result.info, reportAst(
        rsemIllformedAst, result,
        str = "Expected single subnode, but found " & $result.len))

  else:
    result = copyNode(body)
    ctx.instLines = sfCallsite in tmpl.flags
    if ctx.instLines:
      result.info = n.info
    for i in 0..<body.safeLen:
      evalTemplateAux(body[i], args, ctx, result)
  result.flags.incl nfFromTemplate
  result = wrapInComesFrom(n.info, tmpl, result)
  #if ctx.debugActive:
  #  echo "instantion of ", renderTree(result, {renderIds})
  dec(conf.evalTemplateCounter)
  # The instID must be unique for every template instantiation, so we increment it here
  inc instID[]
