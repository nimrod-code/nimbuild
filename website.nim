## This is the SCGI Website and the hub.
import 
  sockets, asyncio, json, strutils, os, scgi, strtabs, times, streams, parsecfg,
  htmlgen, algorithm, tables
import types, db, htmlhelp

import jester

const
  websiteURL = "http://build.nimrod-code.org"

type
  HPlatformStatus = seq[tuple[platform: string, status: TStatus]]
  
  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket ## Hub server socket. All modules connect to this.
    req: TRequest
    modules: seq[TModule]
    database: TDb
    platforms: HPlatformStatus
    password: string ## The password that foreign modules need to be accepted.
    bindAddr: string
    bindPort: int
    scgiPort: int
    redisPort: int

  TModuleStatus = enum
    MSConnecting, ## Module connected, but has not sent the greeting.
    MSConnected ## Module is ready to do work.

  TModule = object
    name: string
    sock: PAsyncSocket ## Client socket
    status: TModuleStatus
    platform: string
    lastPong: float
    pinged: bool # whether we are waiting for a pong from the module.
    ping: float # in seconds
    ip: string # IP address this module is connecting from
    delegID: PDelegate

proc parseConfig(state: PState, path: string) =
  var f = newFileStream(path, fmRead)
  if f != nil:
    var p: TCfgParser
    open(p, f, path)
    var count = 0
    while True:
      var n = next(p)
      case n.kind
      of cfgEof:
        break
      of cfgSectionStart:
        raise newException(EInvalidValue, "Unknown section: " & n.section)
      of cfgKeyValuePair, cfgOption:
        case normalize(n.key)
        of "bindaddr":
          state.bindAddr = n.value
          inc(count)
        of "bindport":
          state.bindPort = parseInt(n.value)
          inc(count)
        of "scgiport":
          state.scgiPort = parseInt(n.value)
          inc(count)
        of "redisport":
          state.redisPort = parseInt(n.value)
          inc(count)
        of "password":
          state.password = n.value
          inc(count)
      of cfgError:
        raise newException(EInvalidValue, "Configuration parse error: " & n.msg)
    if count < 5:
      quit("Not all settings have been specified in the .ini file", quitFailure)
    close(p)
  else:
    quit("Cannot open configuration file: " & path, quitFailure)

proc handleAccept(s: PAsyncSocket, state: PState)
proc open(configPath: string): PState =
  var cres: PState
  new(cres)
  parseConfig(cres, configPath)
  cres.dispatcher = newDispatcher()

  cres.sock = AsyncSocket()
  cres.sock.bindAddr(TPort(cres.bindPort), cres.bindAddr)
  cres.sock.listen()
  cres.sock.handleAccept = proc (s: PAsyncSocket) = handleAccept(s, cres)
  cres.modules = @[]
  cres.platforms = @[]
  
  cres.dispatcher.register(cres.sock)
  
  cres.dispatcher.register(port = TPort(cres.scgiPort), http = true) # TODO: HTTP config.
  
  # Connect to the database
  try:
    cres.database = db.open("localhost", TPort(cres.redisPort))
  except EOS:
    quit("Couldn't connect to redis: " & OSErrorMsg())

  result = cres

# Modules

proc contains(modules: seq[TModule], name: string): bool =
  for i in items(modules):
    if i.name == name: return true
  
  return false

proc contains(platforms: HPlatformStatus,
              p: string): bool =
  for platform, s in items(platforms):
    if platform == p:
      return True

proc handleModuleMsg(s: PAsyncSocket, arg: PObject)
proc addModule(state: PState, client: PAsyncSocket, IPAddr: string) =
  var module: TModule
  module.sock = client
  module.ip = IPAddr
  module.lastPong = epochTime()
  module.pinged = false
  module.status = MSConnecting
  echo(IPAddr, " connected.")

  # Add this module to the dispatcher.
  client.handleRead = proc (s:PAsyncSocket) = handleModuleMsg(s, state)
  module.delegID = state.dispatcher.register(client)

  state.modules.add(module)

proc findBuilderModule(state: PState, p: string, module: var TModule): bool =
  result = false
  for i in state.modules:
    if i.name == "builder" and i.platform == p:
      module = i
      return true

proc parseGreeting(state: PState, m: var TModule, line: string): bool =
  # { "name": "modulename" }
  var json: PJsonNode
  try:
    json = parseJson(line)
  except EJsonParsingError:
    return False

  if m.ip != "127.0.0.1":
    # Check for password
    var fail = true
    if json.existsKey("pass"):
      if json["pass"].str == state.password:
        fail = false
      else:
        echo("Got incorrect password: ", json["pass"].str)

    if fail: return false
  
  if not (json.existsKey("name") and json.existsKey("platform")): return false
  
  m.name = json["name"].str
  m.platform = json["platform"].str
  
  # Only add this module platform to platforms if it's a `builder`, and
  # if platform doesn't already exist.
  if m.name == "builder":
    if m.platform notin state.platforms:
      state.platforms.add((m.platform, initStatus()))
    else:
      echo("Platform(", m.platform, ") already exists.")
      return False
  
  m.status = MSConnected
  
  return True

proc `[]`*(ps: HPlatformStatus,
           platform: string): TStatus =
  assert(ps.len > 0)
  for p, s in items(ps):
    if p == platform:
      return s
  raise newException(EInvalidValue, platform & " is not a valid platform.")

proc `[]=`*(ps: var HPlatformStatus,
            platform: string, status: TStatus) =
  var index = -1
  var count = 0
  for p, s in items(ps):
    if p == platform:
      index = count
      break
    inc(count)

  if index != -1:
    ps.del(index)
  else:
    raise newException(EInvalidValue, platform & " is not a valid platform.")
  
  ps.add((platform, status))

proc uniqueMName(module: TModule): string =
  result = ""
  case module.status
  of MSConnected:
    result.add module.name
    result.add "-"
    result.add module.platform
    result.add "(" & module.ip & ")"
  of MSConnecting:
    result.add "Unknown (" & module.ip & ")"

proc remove(state: PState, module: TModule) =
  for i in 0..len(state.modules)-1:
    var m = state.modules[i]
    if m.name == module.name and
       m.platform == module.platform and 
       m.ip == module.ip:
      state.dispatcher.unregister(state.modules[i].delegID)
      state.modules[i].sock.close()
      echo(uniqueMName(state.modules[i]), " disconnected.")

      # if module is a builder remove it from platforms.
      if m.name == "builder":
        for p in 0..len(state.platforms)-1:
          if state.platforms[p].platform == m.platform:
            state.platforms.delete(p)
            break

      state.modules.delete(i)
      return

proc setStatus(state: PState, p: string, status: TStatusEnum,
               desc, hash: string) =
  var s = state.platforms[p]
  s.status = status
  s.desc = desc
  s.hash = hash
  echo("setStatus -- ", TStatusEnum(status), " -- ", p)
  state.platforms[p] = s

# TODO: Instead of using assertions provide a function which checks whether the
# key exists and throw an exception if it doesn't.

proc parseMessage(state: PState, mIndex: int, line: string) =
  var json = parseJson(line)
  var m = state.modules[mIndex]
  if json.existsKey("status"):
    # { "status": -1, desc: "...", platform: "...", hash: "123456",
    #   "" }
    assert(json.existsKey("hash"))
    var hash = json["hash"].str

    # TODO: Clean this up?
    case TStatusEnum(json["status"].num)
    of sBuildFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildFailure, json["desc"].str, hash)
      state.database.updateProperty(hash, m.platform, "buildResult",
                                    $int(bFail))
      state.database.updateProperty(hash, m.platform, "failReason",
                                    json["desc"].str)
      # This implies that the tests failed too. If we leave this as unknown,
      # the website will show the 'progress.gif' image, which we don't want.
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tFail))
    of sBuildInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sBuildInProgress, json["desc"].str, hash)
    of sBuildSuccess:
      state.setStatus(m.platform, sBuildSuccess, "", hash)
      state.database.updateProperty(hash, m.platform, "buildResult",
                                    $int(bSuccess))
    of sTestFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sTestFailure, json["desc"].str, hash)
      
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tFail))
      state.database.updateProperty(hash, m.platform,
          "failReason", state.platforms[m.platform].desc)
    of sTestInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sTestInProgress, json["desc"].str, hash)
    of sTestSuccess:
      assert(json.existsKey("total"))
      assert(json.existsKey("passed"))
      assert(json.existsKey("skipped"))
      assert(json.existsKey("failed"))
      state.setStatus(m.platform, sTestSuccess, "", hash)
      state.database.updateProperty(hash, m.platform,
          "testResult", $int(tSuccess))
      state.database.updateProperty(hash, m.platform,
          "total", json["total"].str)
      state.database.updateProperty(hash, m.platform,
          "passed", json["passed"].str)
      state.database.updateProperty(hash, m.platform,
          "skipped", json["skipped"].str)
      state.database.updateProperty(hash, m.platform,
          "failed", json["failed"].str)
    of sDocGenFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sDocGenFailure, json["desc"].str, hash)
    of sDocGenInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sDocGenInProgress, json["desc"].str, hash)
    of sDocGenSuccess:
      state.setStatus(m.platform, sDocGenSuccess, "", hash)
    of sCSrcGenFailure:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sCSrcGenFailure, json["desc"].str, hash)
    of sCSrcGenInProgress:
      assert(json.existsKey("desc"))
      state.setStatus(m.platform, sCSrcGenInProgress, json["desc"].str, hash)
    of sCSrcGenSuccess:
      state.setStatus(m.platform, sCSrcGenSuccess, "", hash)
      state.database.updateProperty(hash, m.platform, "csources", "t")
    of sUnknown:
      assert(false)
  elif json.existsKey("payload"):
    # { "payload": { .. } }
    # Check if this is the Nimrod repo.
    if "araq/nimrod" in json["payload"]["repository"]["url"].str.toLower():
      # Check if the commit exists.
      if not state.database.commitExists(json["payload"]["after"].str):
        # Get the branch.
        let branch = json["payload"]["ref"].str[11 .. -1]
        var commits = json["payload"]["commits"]
        var latestCommit = commits[commits.len-1]
        # Add commit to database
        state.database.addCommit(json["payload"]["after"].str,
            latestCommit["message"].str,
            latestCommit["author"]["username"].str,
            branch)

        # Send this message to the "builder" modules
        for module in items(state.modules):
          if module.name == "builder":
            state.database.addPlatform(json["payload"]["after"].str,
                module.platform)
           
            # Add "rebuild" flag.
            json["rebuild"] = newJBool(false)
            
            module.sock.send($json & "\c\L")

                
      else:
        echo("Commit already exists. Not rebuilding.")
    else:
      echo("Repo is not Nimrod. Got: " & 
            json["payload"]["repository"]["url"].str)
    
    # Send this message to the "irc" module.
    if "irc" in state.modules:
      for module in items(state.modules):
        if module.name == "irc":
          module.sock.send($json & "\c\L")

  elif json.existsKey("rebuild"):
    # { "rebuild": "hash" }
    var hash = json["rebuild"].str
    var reply = newJObject()
    if state.database.commitExists(hash, true):
      # You can only rebuild the newest commit. (For now, TODO?)
      var fullHash = state.database.expandHash(hash)
      if state.database.isNewest(hash):
        var success = false
        for module in items(state.modules):
          if module.name == "builder":
            var jobj = newJObject()
            jobj["payload"] = newJObject()
            jobj["payload"]["after"] = newJString(fullHash)
            jobj["rebuild"] = newJBool(true)
           
            if not state.database.platformExists(fullHash, module.platform):
              state.database.addPlatform(fullHash, module.platform)
            
            module.sock.send($jobj & "\c\L")
            success = true
        
        if success:
          reply["success"] = newJNull()
        else:
          reply["fail"] = newJString("No builders available.")
      else:
        reply["fail"] = newJString("Given commit is not newest.")
    else:
      reply["fail"] = newJString("Commit could not be found")
    
    m.sock.send($reply & "\c\L")

  elif json.existsKey("latestCommit"):
    var commit = state.database.getNewest()
    var reply = newJObject()
    reply["payload"] = newJObject()
    reply["payload"]["after"] = newJString(commit)
    reply["rebuild"] = newJBool(true)
    m.sock.send($reply & "\c\L")
    if not state.database.platformExists(commit, m.platform):
      state.database.addPlatform(commit, m.platform)

  elif json.existsKey("pong"):
    # Module received PING and replied with PONG.
    state.modules[mIndex].pinged = false
    state.modules[mIndex].ping = epochTime() - json["pong"].str.parseFloat()
    state.modules[mIndex].lastPong = epochTime()

  elif json.existsKey("ping"):
    # Module thinks it's disconnected! Reply quickly!
    json["pong"] = json["ping"]
    json.delete("ping")
    m.sock.send($json & "\c\L")

  elif json.existsKey("do"):
    # { "do": "command to do (Info to get)" }
    if json["do"].str == "redisinfo":
      # This command asks the website for redis connection info.
      # { "redisinfo": { "port": ..., "password" } }
      var jobj = newJObject()
      jobj["redisinfo"] = newJObject()
      jobj["redisinfo"]["port"] = newJInt(state.redisPort)
      m.sock.send($jobj & "\c\L")
    else:
      echo("[Fatal] Can't understand message from " & m.name & ": ",
           line)
      assert(false)

  else:
    echo("[Fatal] Can't understand message from " & m.name & ": ",
         line)
    assert(false)

proc handleModuleMsg(s: PAsyncSocket, arg: PObject) =
  var state = PState(arg)
  # Module sent a message to us
  var disconnect: seq[TModule] = @[] # Modules which disconnected
  for i in 0..state.modules.len()-1:
    template m: expr = state.modules[i]
    if m.sock == s:
      var line = ""
      if recvLine(s, line):
        if line == "": 
          disconnect.add(m)
          continue
        case m.status
        of MSConnecting:
          if state.parseGreeting(m, line):
            m.sock.send("{ \"reply\": \"OK\" }\c\L")
            echo(uniqueMName(m), " accepted.")
          else:
            m.sock.send("{ \"reply\": \"FAIL\" }\c\L")
            echo("Rejected ", uniqueMName(m))
            disconnect.add(m)
        of MSConnected: 
          echo("Got line from $1: $2" % [m.name, line])

          # Getting a message is a sign of the module still being alive.
          state.modules[i].lastPong = epochTime()

          state.parseMessage(i, line)
      else:
        echo(OSErrorMsg())
        ## Assume the module disconnected
        #disconnect.add(m)
  
  # Remove disconnected modules
  for m in items(disconnect):
    state.remove(m)

proc handlePings(state: PState) =
  var remove: seq[TModule] = @[] # Modules that have timed out.
  for i in 0..state.modules.len-1:
    template module: expr = state.modules[i]
    var pingEvery = 100.0
    case module.status
    of MSConnected:
      if module.name == "builder":
        #if module.platform.startsWith("windows"): pingEvery = 15000.0
      
        if module.pinged and (epochTime() - module.lastPong) >= 25.0:
          echo(uniqueMName(module),
               " has not replied to PING. Assuming timeout!!!")
          remove.add(module)
          continue

        if (epochTime() - module.lastPong) >= pingEvery:
          var obj = newJObject()
          obj["ping"] = newJString(formatFloat(epochTime()))
          module.sock.send($obj & "\c\L")
          module.lastPong = epochTime() # This is a bit misleading, but I don't
                                        # want to add lastPing
          module.pinged = true
          echo("Pinging ", uniqueMName(module))
    
    of MSConnecting:
      if (epochTime() - module.lastPong) >= 2.0:
        echo(uniqueMName(module), " did not send a greeting.")
        module.sock.send("{ \"reply\": \"FAIL\", \"desc\": \"Took too long\" }\c\L")
        remove.add(module)
  
  # Remove the modules that have timed out.
  for m in items(remove):
    state.remove(m)

# HTML Generation

proc joinUrl(u, u2: string): string =
  if u.endswith("/"):
    return u & u2
  else: return u & "/" & u2

proc getUrl(c: TCommit, p: TPlatform): tuple[weburl, logurl: string] =
  var weburl = joinUrl(websiteUrl, "commits/$2/$1/" %
                                     [c.hash[0..11], p.platform])
  var logurl = joinUrl(weburl, "log.txt")
  return (weburl, logurl)

proc isBuilding(platforms: HPlatformStatus, p: string, c: TCommit): bool =
  if p in platforms:
    return platforms[p].hash == c.hash
  return false

proc genPlatformResult(c: TCommit, p: TPlatform, platforms: HPlatformStatus,
                       req: TRequest): string =
  result = ""
  case p.buildResult
  of bUnknown:
    # Check whether this platform is currently building this commit.
    if isBuilding(platforms, p.platform, c):
        result.add("<img src=\"$1\"/>" %
                   [req.makeUri("static/images/progress.gif", absolute = false)])
  of bFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of bSuccess: result.add("ok")
  result.add(" ")
  case p.testResult
  of tUnknown:
    if isBuilding(platforms, p.platform, c):
        result.add("<img src=\"$1\"/>" %
                 [req.makeUri("static/images/progress.gif", absolute = false)])
  of tFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add("<a href=\"$1\" class=\"fail\">fail</a>" % [logurl])
  of tSuccess:
    var (weburl, logurl) = getUrl(c, p)
    var testresultsURL = joinUrl(weburl, "testresults.html")
    var percentage = float(p.passed) / float(p.total - p.skipped) * 100.0
    result.add("<a href=\"$1\" class=\"success\">" % [testresultsURL] &
               formatFloat(percentage, precision=4) & "%</a>")

proc genBuildResult(state: PState, c: TCommit, p: TPlatform): string =
  result = ""
  case p.buildResult
  of bUnknown:
    # Check whether this platform is currently building this commit.
    if isBuilding(state.platforms, p.platform, c):
      result.add(htmlgen.`div`(class = "half indivUnknown", 
                   img(alt = "Building", 
                       src = state.req.makeUri("public/images/progress.gif",
                           absolute = false))
                 ))
    else:
      result.add(htmlgen.`div`(class = "half indivUnknown", 
                 htmlgen.p("Unknown")))
  of bFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add(htmlgen.`div`(class = "half indivFailure", 
                 a(href = logurl, class = "fail", "Fail")
               ))
  of bSuccess:
    result.add(htmlgen.`div`(class = "half indivSuccess", "OK"))
  
proc genTestResult(state: PState, c: TCommit, p: TPlatform): string =
  result = ""
  case p.testResult
  of tUnknown:
    if isBuilding(state.platforms, p.platform, c):
      result.add(htmlgen.`div`(class = "half indivUnknown", 
                   img(alt = "Building",
                       src = state.req.makeUri("public/images/progress.gif",
                           absolute = false))
                 ))
    else:
      result.add(htmlgen.`div`(class = "half indivUnknown", 
                 htmlgen.p("Unknown")))
  of tFail:
    var (weburl, logurl) = getUrl(c, p)
    result.add(htmlgen.`div`(class = "half indivFailure", 
                 a(href = logurl, class = "fail", "Fail")
               ))
  of tSuccess:
    var (weburl, logurl) = getUrl(c, p)
    var testresultsURL = joinUrl(weburl, "testresults.html")
    result.add(htmlgen.`div`(class = "half indivSuccess", 
                 a(href = testResultsURL, class = "success", 
                   $(p.passed) & "/" & $(p.total-p.skipped))
               ))

proc cmpPlatforms(a, b: string): int =
  if a == b: return 0
  var dashes = a.split('-')
  var dashes2 = b.split('-')
  if dashes[0] == dashes2[0]:
    if dashes[1] == dashes2[1]: return system.cmp(a,b)
    case dashes[1]
    of "x86":
      return 1
    of "x86_64":
      if dashes2[1] == "x86": return -1
      else: return 1
    of "ppc64":
      if dashes2[1] == "x86" or dashes2[1] == "x86_64": return -1
      else: return 1
    else:
      return system.cmp(dashes[1], dashes2[1])
  else:
    case dashes[0]
    of "linux":
      return 1
    of "windows":
      if dashes2[0] == "linux": return -1
      else: return 1
    of "macosx":
      if dashes2[0] == "linux" or dashes2[0] == "windows": return -1
      else: return 1
    else:
      if dashes2[0] == "linux" or dashes2[0] == "windows" or 
         dashes2[0] == "macosx": return -1
      else:
        return system.cmp(a, b)

proc findLatestCommit(entries: seq[TEntry], 
                      platform: string, 
                      res: var tuple[entry: TEntry, latest: bool]): bool =
  result = false
  var i = 0
  for c, p in items(entries):
    if platform in p:
      let platf = p[platform]
      if platf.buildResult == bSuccess:
        res = ((c, p), i == 0 and entries[0].c.hash == c.hash)
        return true
      
      i.inc()

proc genDownloadTable(entries: seq[TEntry], platforms: seq[string]): string =
  result = ""
  
  var OSes: seq[string] = @[]
  var CPUs: seq[string] = @[]
  var versions: seq[tuple[ver: string, os: string]] = @[]
  for p in platforms:
    var spl = p.split('-')
    
    if spl.len() > 2:
      if (ver: spl[2], os: spl[0]) notin versions:
        versions.add((spl[2], spl[0]))
    elif spl[0] notin OSes:
      versions.add(("", spl[0]))
    
    if spl[0] notin OSes: OSes.add(spl[0])
    if spl[1] notin CPUs: CPUs.add(spl[1])
  
  var table = htmlhelp.initTable()
  table.addRow()
  table.addRow() # For Versions.
  table[0].addCol("", true)
  table[1].addCol("", true)
  for os in OSes:
    table[0].addCol(os, true) # Add OS.
  for cpuI, cpu in CPUs:
    if cpuI+2 > table.len()-1: table.addRow() 
    table[2+cpuI].addCol(cpu, true)
    
    # Loop through versions.
    var currentVerI = 0
    
    while currentVerI < versions.len():
      var columnAdded = false
      var pName = ""
      if versions[currentVerI].ver != "":
        pName = versions[currentVerI].os & "-" &
               cpu & "-" & versions[currentVerI].ver
      else:
        pName = versions[currentVerI].os & "-" & cpu
      
      if pName in platforms:
        var latestCommit: tuple[entry: TEntry, latest: bool]
        if entries.findLatestCommit(pName, latestCommit):
          var (entry, latest) = latestCommit
          var attrs: seq[tuple[name, content: string]] = @[]
          attrs.add(("class", if latest: "link green" else: "link orange"))
          if pName in entry.p:
            var weburl = joinUrl(websiteUrl, "commits/$2/nimrod_$1.zip" %
                            [entry.c.hash[0..11], entry.p[pName].platform])
            table[2+cpuI].addCol(a(entry.c.hash[0..11], href = weburl), attrs=attrs)
            columnAdded = true

      if not columnAdded:
        # Add an empty column.
        table[2+cpuI].addCol("")
      
      currentVerI.inc()
    
  for v in versions:
    table[1].addCol(v.ver, true)
    if v.ver != "":
      # Add +1 to colspan of OS
      var cols = findCols(table[0], v.os)
      assert cols.len > 0
      if not cols[0].attrs.hasKey("colspan"):
        cols[0].attrs["colspan"] = "1"
      else:
        cols[0].attrs["colspan"] = $(cols[0].attrs["colspan"].parseInt + 1)
  
  result = table.toHtml("id=\"downloads\"")

proc genTopButtons(platforms: HPlatformStatus, entries: seq[TEntry]): string =
  # Generate buttons for C sources and docs.
  # Find the latest C sources.
  result = ""
  var csourceWeb = ""
  var csourceFound = false
  var csourceLatest = false
  var i = 0
  for c, p in items(entries):
    for platf in p:
      if platf.csources:
        csourceWeb = joinUrl(websiteUrl,
                            "commits/$2/nimrod_$1_csources.zip" %
                            [c.hash[0..11], platf.platform])
        csourceFound = true
        csourceLatest = i == 0
        break
    if csourceFound: break
    i.inc()
        
  # Find out whether latest doc gen succeeded.
  var docgenSuccess = true # By default it succeeded.
  for p, s in items(platforms):
    if s.status == sDocGenFailure:
      docgenSuccess = false
      break
  
  var csourceClass = "right " & (if csourceLatest: "active" else: "warning") &
                     " button"
  var docClass = "left " & (if docgenSuccess: "active" else: "warning") &
                 " button"
  
  var docWeb     = joinUrl(websiteURL, "docs/lib.html")
  
  result.add(a(span("", class = "download") & 
                span("C Sources", class = "platform"),
               class = csourceClass, href = csourceWeb))
  
  result.add(a(span("", class = "book") & 
                span("Documentation", class = "platform"),
               class = docClass, href = docWeb))

proc genCommitUrl(hash: string): string =
  return joinUrl("https://github.com/Araq/Nimrod/commit/", hash)

proc genUserUrl(user: string): string = 
  return joinUrl("https://github.com/", user)

proc genSpecificBranchHTML(state: PState, branch: string,
    info: tuple[c: TCommit, buildInfo: TPlatform]): string =
  let (commit, build) = (info.c, info.buildInfo)
  result = 
    htmlgen.`div`(class = "lastResults",
        htmlgen.`div`(class = "branch " & (if branch == "master": "master" else: ""),
          span(title="Branch tested", branch)
        ),
        state.genBuildResult(commit, build),
        state.genTestResult(commit, build),
        p(a(href = genCommitUrl(commit.hash),commit.hash[0..11]), " by ",
          a(href=genUserUrl(commit.username), commit.username)
         ),
        p(class = "commitMsg", commit.commitMsg),
        p($(commit.date))
      )

proc genSpecificBuilderHTML(state: PState,
    platfName: string): tuple[inProgress: bool, html: string] =
  result = (false, "")
  let imgProgress = "<img alt=\"Busy\" src=\"$#\" style=\"float:right\"/>" %
      [state.req.makeUri("images/progress.gif", absolute = false)]
  var builderModule: TModule
  if findBuilderModule(state, platfName, builderModule):
    result.html = htmlgen.`div`(class = "buildInfo",
        (if state.platforms[platfName].status.isInProgress:
           imgProgress
         else: ""),
        p(state.platforms[platfName].hash[0..11]),
        p($state.platforms[platfName].status),
        p($(int(builderModule.ping / 1000.0)) & "ms")
      )
    result.inProgress =  state.platforms[platfName].status.isInProgress
  else:
    result.html = htmlgen.`div`(class = "buildInfo",
      p("Builder not connected."))

proc genBuildResults(state: PState, platforms: seq[string], entr: seq[TEntry]): string =
  # Platform name -> [branch, html generated]
  var platformBuilds = initTable[
          string, 
          TTable[string, tuple[c: TCommit, buildInfo: TPlatform]]]()

  for entry in items(entr):
    let (commit, builds) = (entry.c, entry.p)
    for build in builds:
      if isBuilding(state.platforms, build.platform, commit):
        continue # If the builder is currently building it, don't show it here.
      if build.buildResult == bUnknown:
        continue # No point in showing an unknown for both build&test result.
        # So skip it.
      if not platformBuilds.hasKey(build.platform):
        platformBuilds[build.platform] = initTable[
            string,
            tuple[c: TCommit, buildInfo: TPlatform]]()
      let thisBranch = (if isNil(commit.branch): "master" else: commit.branch)
      assert thisBranch != ""
      if platformBuilds[build.platform].hasKey(thisBranch):
        # Already got the latest commit for this branch
        continue
      platformBuilds.mget(build.platform)[thisBranch] = (c: commit, buildInfo: build)

  # platfClass =
  #   If build in progress: blue (Progress)
  #   If master branch failed: red (fail)
  #   If master branch tests not 100%: orange
  #   If master branch fully successful: green.
  
  proc genPlatfBuildRes(state: PState, class, name, 
      branches, builderStatus: string): string =
    result = htmlgen.`div`(class="platfBuildResult " & class,
          htmlgen.`div`(class="header", span(name)),
          branches,
          htmlgen.`div`(class="header", span("Builder status")),
          builderStatus)
  
  result = ""
  for platfName in platforms:
    if not platformBuilds.hasKey(platfName):
      let (inProgress, html) = genSpecificBuilderHTML(state, platfName)
      if inProgress:
        result.add genPlatfBuildRes(state, "platfProgress", platfName, "", html)
        continue
      else:
        continue # No commits were built for this, and nothing is building.
  
    let value = platformBuilds[platfName]
    var branches = ""
    if value.hasKey("master"):
      branches.add(genSpecificBranchHTML(state, "master", value["master"]))
    for branch, info in value:
      if branch == "master": continue
      branches.add(genSpecificBranchHTML(state, branch, info))
    
    let (inProgress, builderHtml) = genSpecificBuilderHTML(state, platfName)
    var platfClass = "platfWarning"
    if inProgress: platfClass = "platfProgress"
    if value.hasKey("master"):
      if value["master"].buildInfo.buildResult == bFail or 
          value["master"].buildInfo.testResult == tFail:
        platfClass = "platfFailure"
      elif value["master"].buildInfo.testResult == tSuccess and
          value["master"].buildInfo.failed == 0:
        platfClass = "platfSuccess"
      else:
        platfClass = "platfWarning"
    else:
      platfClass = "platfWarning" # Just to be explicit.
    
    result.add genPlatfBuildRes(state, platfClass, platfName, branches, builderHtml)
      
include "index.html"
# Jester

proc cleanup(state: PState) =
  echo("^C detected. Cleaning up...")
  for m in items(state.modules):
    # TODO: Send something to the modules to warn them?
    m.sock.close()
  
  jester.close()

proc handleAccept(s: PAsyncSocket, state: PState) =
  # Connection from a module
  var (client, IPAddr) = s.acceptAddr()
  var clientS = @[client.getSocket]
  state.addModule(client, IPAddr)

when isMainModule:
  var configPath = ""
  if paramCount() > 0:
    configPath = paramStr(1)
    echo("Loading config ", configPath, "...")
  else:
    quit("Usage: ./website configPath")

  echo("Started website: built at ", CompileDate, " ", CompileTime)

  var state = website.open(configPath)
  
  get "/":
    state.req = request
    let html = state.genHtml()
    resp html
  
  
  while True:
    doAssert state.dispatcher.poll()
    
    state.handlePings()
    
    state.database.keepAlive()
  

