#
#
#           The Nim Compiler
#        (c) Copyright 2018 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## exposes the Nim VM to clients.

import
  std/[
    compilesettings,
    os
  ],
  ast/[
    ast,
    llstream,
    idents,
    reports
  ],
  modules/[
    modules,
    modulegraphs
  ],
  front/[
    condsyms,
    options,
    scriptconfig
  ],
  utils/[
    pathutils
  ],
  sem/[
    passes,
    sem,
    passaux
  ],
  vm/[
    vmdef,
    vm
  ]

type
  Interpreter* = ref object ## Use Nim as an interpreter with this object
    mainModule: PSym
    graph: ModuleGraph
    scriptName: string
    idgen: IdGenerator

iterator exportedSymbols*(i: Interpreter): PSym =
  assert i != nil
  assert i.mainModule != nil, "no main module selected"
  for s in modulegraphs.allSyms(i.graph, i.mainModule):
    yield s

proc selectUniqueSymbol*(i: Interpreter; name: string;
                         symKinds: set[TSymKind] = {skLet, skVar}): PSym =
  ## Can be used to access a unique symbol of ``name`` and
  ## the given ``symKinds`` filter.
  assert i != nil
  assert i.mainModule != nil, "no main module selected"
  let n = getIdent(i.graph.cache, name)
  var it: ModuleIter
  var s = initModuleIter(it, i.graph, i.mainModule, n)
  result = nil
  while s != nil:
    if s.kind in symKinds:
      if result == nil: result = s
      else: return nil # ambiguous
    s = nextModuleIter(it, i.graph)

proc selectRoutine*(i: Interpreter; name: string): PSym =
  ## Selects a declared routine (proc/func/etc) from the main module.
  ## The routine needs to have the export marker ``*``. The only matching
  ## routine is returned and ``nil`` if it is overloaded.
  result = selectUniqueSymbol(i, name, {skTemplate, skMacro, skFunc,
                                        skMethod, skProc, skConverter})

proc callRoutine*(i: Interpreter; routine: PSym; args: openArray[PNode]): PNode =
  assert i != nil
  result = vm.execProc(PCtx i.graph.vm, routine, args)

proc getGlobalValue*(i: Interpreter; letOrVar: PSym): PNode =
  result = vm.getGlobalValue(PCtx i.graph.vm, letOrVar)

proc setGlobalValue*(i: Interpreter; letOrVar: PSym, val: PNode) =
  ## Sets a global value to a given PNode, does not do any type checking.
  vm.setGlobalValue(PCtx i.graph.vm, letOrVar, val)

proc implementRoutine*(i: Interpreter; pkg, module, name: string;
                       impl: proc (a: VmArgs) {.closure, gcsafe.}) =
  assert i != nil
  let vm = PCtx(i.graph.vm)
  vm.registerCallback(pkg & "." & module & "." & name, impl)

proc evalScript*(i: Interpreter; scriptStream: PLLStream = nil) =
  ## This can also be used to *reload* the script.
  assert i != nil
  assert i.mainModule != nil, "no main module selected"
  initStrTables(i.graph, i.mainModule)
  i.mainModule.ast = nil

  let s = if scriptStream != nil: scriptStream
          else: llStreamOpen(findFile(i.graph.config, i.scriptName), fmRead)
  processModule(i.graph, i.mainModule, i.idgen, s)

proc findNimStdLib*(): string =
  ## Tries to find a path to a valid "system.nim" file.
  ## Returns "" on failure.
  try:
    let nimexe = os.findExe("nim")
      # this can't work with choosenim shims, refs https://github.com/dom96/choosenim/issues/189
      # it'd need `nim dump --dump.format:json . | jq -r .libpath`
      # which we should simplify as `nim dump --key:libpath`
    if nimexe.len == 0: return ""
    result = nimexe.splitPath()[0] /../ "lib"
    if not fileExists(result / "system.nim"):
      when defined(unix):
        result = nimexe.expandSymlink.splitPath()[0] /../ "lib"
        if not fileExists(result / "system.nim"): return ""
  except OSError, ValueError:
    return ""

proc findNimStdLibCompileTime*(): string =
  ## Same as `findNimStdLib` but uses source files used at compile time,
  ## and asserts on error.
  result = querySetting(SingleValueSetting.libPath)
  doAssert fileExists(result / "system.nim"), "result:" & result

proc createInterpreter*(
    scriptName:  string,
    searchPaths: openArray[string],
    hook:        ReportHook,
    flags:       TSandboxFlags = {},
    defines:     seq[(string, string)] = @[("nimscript", "true")],
    registerOps: bool = true
  ): Interpreter =

  var conf = newConfigRef(hook)
  var cache = newIdentCache()
  var graph = newModuleGraph(cache, conf)
  connectCallbacks(graph)
  initDefines(conf.symbols)
  for define in defines:
    defineSymbol(conf, define[0], define[1])
  registerPass(graph, semPass)
  registerPass(graph, evalPass)

  for p in searchPaths:
    conf.searchPathsAdd(AbsoluteDir p)
    if conf.libpath.isEmpty: conf.libpath = AbsoluteDir p

  var m = graph.makeModule(scriptName)
  incl(m.flags, sfMainModule)
  var idgen = idGeneratorFromModule(m)
  var vm = newCtx(m, cache, graph, idgen)
  vm.mode = emRepl
  vm.features = flags
  if registerOps:
    vm.registerAdditionalOps() # Required to register parts of stdlib modules
  graph.vm = vm
  graph.compileSystemModule()
  result = Interpreter(mainModule: m, graph: graph, scriptName: scriptName, idgen: idgen)

proc destroyInterpreter*(i: Interpreter) =
  ## destructor.
  discard "currently nothing to do."

proc registerErrorHook*(
    i: Interpreter,
    hook: proc (config: ConfigRef, report: Report): TErrorHandling {.gcsafe.}
  ) =
  i.graph.config.structuredReportHook = hook

proc runRepl*(
    r: TLLRepl;
    searchPaths: openArray[string];
    supportNimscript: bool,
    reportHook: ReportHook
  ) =
  ## deadcode but please don't remove... might be revived
  var conf = newConfigRef(reportHook)

  var cache = newIdentCache()
  var graph = newModuleGraph(cache, conf)

  for p in searchPaths:
    conf.searchPathsAdd(AbsoluteDir p)
    if conf.libpath.isEmpty: conf.libpath = AbsoluteDir p

  conf.cmd = cmdInteractive # see also `setCmd`
  conf.setErrorMaxHighMaybe
  initDefines(conf.symbols)
  defineSymbol(conf, "nimscript")
  if supportNimscript:
    defineSymbol(conf, "nimconfig")

  when hasFFI:
    defineSymbol(graph.config, "nimffi")

  registerPass(graph, verbosePass)
  registerPass(graph, semPass)
  registerPass(graph, evalPass)
  var m = graph.makeStdinModule()
  incl(m.flags, sfMainModule)
  var idgen = idGeneratorFromModule(m)

  if supportNimscript:
    graph.vm = setupVM(m, cache, "stdin", graph, idgen)

  graph.compileSystemModule()
  processModule(graph, m, idgen, llStreamOpenStdIn(r))
