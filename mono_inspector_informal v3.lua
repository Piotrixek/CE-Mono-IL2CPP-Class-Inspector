
local monoFuncsLoaded = false
if type(mono_findClass) ~= "function" then -- check a key func
  local autorunPath = getAutorunPath()
  local pathsep = package.config:sub(1,1) -- get os path separator ('\' or '/')
  local monoScriptPath = autorunPath .. 'monoscript.lua'
  print("tryna load monoscript.lua from: " .. monoScriptPath)
  local f = io.open(monoScriptPath, "r")
  if f then
    f:close()
    local ok, err = pcall(require, "monoscript")
    if not ok then
       error("ERR loading monoscript.lua: " .. tostring(err) .. "\nmake sure its in ur ce autorun folder n has no errors")
    else
       -- check again after require
       if type(mono_findClass) == "function" and type(LaunchMonoDataCollector) == "function" then
           print("monoscript.lua loaded ok")
           monoFuncsLoaded = true
       else
           error("ERR: monoscript.lua loaded but key funcs like mono_findClass or LaunchMonoDataCollector r missin")
       end
    end
  else
    error("ERR: monoscript.lua not found at: " .. monoScriptPath .. "\nPlease ensure its in ur ce autorun folder")
  end
else
  -- already loaded assume funcs exist
  print("monoscript.lua seems loaded already")
  if type(mono_findClass) == "function" and type(LaunchMonoDataCollector) == "function" then
      monoFuncsLoaded = true
  else
      print("WARN: monoscript.lua was loaded but key funcs seem missin now")
      monoFuncsLoaded = false -- force recheck or error out below
  end
end

-- stop script if stuff aint available
if not monoFuncsLoaded then
    showMessage("Essential Mono functions not found. Cannot run inspector.")
    return -- stop script
end


-- robust mono activation/reconnection
local function tryconnect(maxretries)
    maxretries = maxretries or 3 -- default 3 tries
    local retries = 0
    if getOpenedProcessID() == 0 then print("no process open"); return false end

    local pipeok = monopipe ~= nil and type(monopipe) == 'userdata' and pcall(function() return monopipe.Connected end) and mono_AttachedProcess == getOpenedProcessID()

    while not pipeok and retries < maxretries do
        if retries > 0 then
            print(string.format("mono connection lost/bad retryin (%d/%d)...", retries, maxretries))
            sleep(500 + retries * 250)
        else
             print("checkin mono connection...")
        end

        local ok, launchResult = pcall(LaunchMonoDataCollector)
        if not ok or launchResult == 0 then
            print("LaunchMonoDataCollector failed attempt " .. (retries+1) .. ". err: " .. tostring(launchResult))
        else
             print("LaunchMonoDataCollector called ok")
        end
        sleep(400)
        retries = retries + 1
        pipeok = monopipe ~= nil and type(monopipe) == 'userdata' and pcall(function() return monopipe.Connected end) and mono_AttachedProcess == getOpenedProcessID()
    end

    if not pipeok then
        if retries >= maxretries then showMessage("failed ta connect mono after " .. maxretries .. " tries") end
        return false
    end
    -- print("mono connection ok") -- less console spam
    return true
end

-- mapping mono types to ce structure types
local ceVarTypeMap = {
    [vtByte] = "Byte", [vtWord] = "2 Bytes", [vtDword] = "4 Bytes", [vtQword] = "8 Bytes",
    [vtSingle] = "Float", [vtDouble] = "Double", [vtString] = "String",
    [vtPointer] = targetIs64Bit() and "8 Bytes" or "4 Bytes",
    ["Default"] = "4 Bytes" -- fallback
}
-- mapping mono types to ce var types (for invoke dialog AND writing values)
local monoVtMap = {
    [MONO_TYPE_BOOLEAN]=vtByte, [MONO_TYPE_CHAR]=vtUnicodeString, [MONO_TYPE_I1]=vtByte, [MONO_TYPE_U1]=vtByte,
    [MONO_TYPE_I2]=vtWord, [MONO_TYPE_U2]=vtWord, [MONO_TYPE_I4]=vtDword, [MONO_TYPE_U4]=vtDword,
    [MONO_TYPE_I8]=vtQword, [MONO_TYPE_U8]=vtQword, [MONO_TYPE_R4]=vtSingle, [MONO_TYPE_R8]=vtDouble,
    [MONO_TYPE_STRING]=vtString, -- pointer to string obj needs special handling
    [MONO_TYPE_PTR]=vtPointer, [MONO_TYPE_BYREF]=vtPointer, [MONO_TYPE_CLASS]=vtPointer,
    [MONO_TYPE_FNPTR]=vtPointer, [MONO_TYPE_GENERICINST]=vtPointer, [MONO_TYPE_ARRAY]=vtPointer,
    [MONO_TYPE_SZARRAY]=vtPointer, [MONO_TYPE_OBJECT]=vtPointer,
    -- default
    ["Default"] = vtPointer
}

-- get ce type string
local function getCEVarTypeStr(monoType)
    local vt = monoTypeToVartypeLookup[monoType] or vtDword
    return ceVarTypeMap[vt] or ceVarTypeMap["Default"]
end

-- read value based on ce vartype string n address
local function readCEValue(ceTypeStr, addr)
    if addr == nil or addr == 0 then return "?" end
    local ok, val
    if ceTypeStr == "Byte" then ok, val = pcall(readByte, addr)
    elseif ceTypeStr == "2 Bytes" then ok, val = pcall(readSmallInteger, addr)
    elseif ceTypeStr == "4 Bytes" then ok, val = pcall(readInteger, addr)
    elseif ceTypeStr == "8 Bytes" then ok, val = pcall(readQword, addr)
    elseif ceTypeStr == "Float" then ok, val = pcall(readFloat, addr)
    elseif ceTypeStr == "Double" then ok, val = pcall(readDouble, addr)
    elseif ceTypeStr == "String" then
        local okPtr, strObjAddr = pcall(readPointer, addr)
        if okPtr and strObjAddr and strObjAddr ~= 0 then
            local okStr, strVal = pcall(mono_string_readString, strObjAddr)
            if okStr and strVal ~= nil then return '"' .. strVal:gsub('"', '\\"') .. '"' else return "(err str)" end -- escape quotes
        else return "(nullptr)" end
    else -- default to pointer read
        ok, val = pcall(readPointer, addr)
        if ok and val ~= nil then val = string.format("0x%X", val) else val = "?" end
    end
    if not ok then return "(read err)" end
    if val == nil then return "?" end
    return tostring(val)
end

-- Write value based on CE VarType and address
local function writeCEValue(ceVarType, addr, newValueStr)
    if addr == nil or addr == 0 then print("err: invalid address for write"); return false end
    local val = nil
    local ok = true

    -- try ta parse the input string based on type
    if ceVarType == vtByte then val = tonumber(newValueStr) ; if val then ok = pcall(writeByte, addr, val) else ok = false end
    elseif ceVarType == vtWord then val = tonumber(newValueStr) ; if val then ok = pcall(writeSmallInteger, addr, val) else ok = false end
    elseif ceVarType == vtDword then val = tonumber(newValueStr) ; if val then ok = pcall(writeInteger, addr, val) else ok = false end
    elseif ceVarType == vtQword then val = tonumber(newValueStr) ; if val then ok = pcall(writeQword, addr, val) else ok = false end
    elseif ceVarType == vtSingle then val = tonumber(newValueStr) ; if val then ok = pcall(writeFloat, addr, val) else ok = false end
    elseif ceVarType == vtDouble then val = tonumber(newValueStr) ; if val then ok = pcall(writeDouble, addr, val) else ok = false end
    elseif ceVarType == vtPointer then val = getAddressSafe(newValueStr) or tonumber(newValueStr); if val then ok = pcall(writePointer, addr, val) else ok = false end
    elseif ceVarType == vtString then
        print("warn: writing strings directly aint supported yet")
        ok = false ; val = false -- prevent nil error check below
    else
        print("warn: unsupported type for writing: " .. ceVarType)
        ok = false ; val = false
    end

    if val == nil and ok then print("err: couldnt parse new value '" .. newValueStr .. "' for type " .. ceVarType); return false end
    if not ok then print("err: failed ta write value " .. tostring(val) .. " ta addr 0x" .. string.format("%X", addr)); return false end

    print("wrote value " .. tostring(val) .. " ta addr 0x" .. string.format("%X", addr))
    return true
end


-- get field access modifier string from flags
local function getfieldmod(flags)
    if type(flags) ~= 'number' then return "unknown_access" end
    local access = (flags & FIELD_ATTRIBUTE_FIELD_ACCESS_MASK)
    if access == FIELD_ATTRIBUTE_PUBLIC then return "public"
    elseif access == FIELD_ATTRIBUTE_PRIVATE then return "private"
    elseif access == FIELD_ATTRIBUTE_FAMILY then return "protected"
    elseif access == FIELD_ATTRIBUTE_ASSEMBLY then return "internal"
    elseif access == FIELD_ATTRIBUTE_FAM_AND_ASSEM then return "private protected"
    elseif access == FIELD_ATTRIBUTE_FAM_OR_ASSEM then return "protected internal"
    else return "compiler_controlled"
    end
end

-- get method access modifier string from flags
local function getmethodmod(flags)
    if type(flags) ~= 'number' then return "unknown_access" end
    local access = (flags & METHOD_ATTRIBUTE_MEMBER_ACCESS_MASK)
    if access == METHOD_ATTRIBUTE_PUBLIC then return "public"
    elseif access == METHOD_ATTRIBUTE_PRIVATE then return "private"
    elseif access == METHOD_ATTRIBUTE_FAMILY then return "protected"
    elseif access == METHOD_ATTRIBUTE_ASSEMBLY then return "internal"
    elseif access == METHOD_ATTRIBUTE_FAM_AND_ASSEM then return "private protected"
    elseif access == METHOD_ATTRIBUTE_FAM_OR_ASSEM then return "protected internal"
    else return "compiler_controlled"
    end
end

-- format method signature nicely
local function fmtsig(methodaddr)
    if monopipe == nil then return "(pipe disconnected)" end
    local ok, sig, paramnames, returntype = pcall(mono_method_getSignature, methodaddr)
    if not ok or monopipe == nil then print("err gettin method sig or pipe lost: " .. tostring(sig)); return "(err gettin signature)" end
    if sig == nil then sig = "" end

    local paramsformatted = {}
    local paramtypes = {}
    if sig ~= '' then
        for typename in string.gmatch(sig, '([^,]+(%b<>)?)') do table.insert(paramtypes, typename:trim()) end
    end
    paramnames = paramnames or {}
    local count = math.max(#paramtypes, #paramnames)
    for i = 1, count do
        local pname = paramnames[i] or ("param" .. i)
        local ptype = paramtypes[i] or "?"
        table.insert(paramsformatted, ptype .. " " .. pname)
    end
    return "(" .. table.concat(paramsformatted, ", ") .. ") : " .. (returntype or "void")
end

-- split full class name into namespace n base name
local function parsename(fullname)
    local namespace, classname = "", fullname
    local lastdot = nil
    for i = #fullname, 1, -1 do
        if fullname:sub(i,i) == '.' then
             if i == 1 or fullname:sub(i-1, i-1) ~= '+' then lastdot = i; break end
        end
    end
    if lastdot then namespace = fullname:sub(1, lastdot - 1); classname = fullname:sub(lastdot + 1) end
    return namespace, classname
end

-- store last results including statics now
local lastResults = {
    className = "", classAddr = 0, parentName = nil,
    instanceFields = {}, staticFields = {}, methods = {}
}
-- store current instance address for editing
local currentInstanceAddr = 0
-- store class vtable for static editing (if applicable)
local currentClassVTable = 0

-- main inspection func - modified ta display compiled method addr if possible
local function lookupclass(classnameinput)
    if not inspectorform or not inspectorform.Visible or not inspectorform.outputlist then print("inspector form not available abortin inspection"); return end
    local outputlist = inspectorform.outputlist

    lastResults = { className = "", classAddr = 0, parentName = nil, instanceFields = {}, staticFields = {}, methods = {} } -- clear last results
    currentInstanceAddr = 0 -- clear instance addr on new inspect
    currentClassVTable = 0 -- clear vtable

    local function logmsg(msg, tag, data) -- log ta listview now add tag n optional data
        if inspectorform and inspectorform.Visible and inspectorform.outputlist then
            synchronize(function()
                -- check form still exists inside sync block
                if inspectorform and inspectorform.outputlist then
                    local item = inspectorform.outputlist.Items.Add()
                    item.Caption = msg -- put msg in first column
                    -- store type info and any extra data needed (like field/method details)
                    item.Data = { type = tag or "info", details = data }
                end
            end)
        else print("debug (logmsg): form closed msg not added:", msg) end
    end

    -- clear listview before start n disable write buttons
    synchronize(function()
        if inspectorform and inspectorform.outputlist then
            inspectorform.outputlist.Items.Clear()
            inspectorform.writevalsbtn.Enabled = false
            inspectorform.writeStaticBtn.Enabled = false -- disable new static btn too
        end
    end)

    logmsg("checkin mono connection...")
    if not tryconnect() then return end

    logmsg("inspectin class: " .. classnameinput .. "...")
    logmsg("tryna global search...")

    local classaddr = nil
    local ok, result = pcall(mono_findClass, nil, classnameinput)
    if not ok or monopipe == nil then logmsg("err durin global search or pipe lost: " .. tostring(result), "error"); if not tryconnect() then return end
    elseif result ~= 0 then classaddr = result end

    if classaddr == nil then -- targeted search if global failed
      logmsg("global search failed targetin Assembly-CSharp.dll...", "info")
      if not tryconnect() then return end
      local csharpimg = nil
      local okEnum, assemblies = pcall(mono_enumAssemblies)
      if not okEnum or monopipe == nil or assemblies == nil then logmsg("failed ta enum assemblies or pipe lost err: " .. tostring(assemblies), "error"); if not tryconnect() then return end
      else
          for i = 1, #assemblies do
            if monopipe == nil then logmsg("pipe lost durin assembly loop", "error"); break end
            local okImg, img = pcall(mono_getImageFromAssembly, assemblies[i])
            if not okImg or monopipe == nil then logmsg("err gettin image or pipe lost: " .. tostring(img), "error"); break end
            if img and img ~= 0 then
              local okName, imgname = pcall(mono_image_get_name, img)
              if not okName or monopipe == nil then logmsg("err gettin image name or pipe lost: " .. tostring(imgname), "error"); break end
              if imgname and imgname:lower() == "assembly-csharp.dll" then csharpimg = img; logmsg("found Assembly-CSharp.dll image handle", "info"); break end
            end
          end
      end
      if csharpimg then
        if not tryconnect() then return end
        local ns, cn = parsename(classnameinput)
        logmsg(string.format("searchin within image for namespace: '%s' class: '%s'", ns, cn), "info")
        local okTarget, targetaddr = pcall(mono_image_findClass, csharpimg, ns, cn)
        if not okTarget or monopipe == nil then logmsg("err durin targeted search or pipe lost: " .. tostring(targetaddr), "error"); if not tryconnect() then return end
        elseif targetaddr ~= 0 then classaddr = targetaddr end
        if classaddr == nil and ns ~= "" then
           logmsg(string.format("also tryin within image usin empty namespace for class: '%s'", classnameinput), "info")
           okTarget, targetaddr = pcall(mono_image_findClass, csharpimg, "", classnameinput)
           if not okTarget or monopipe == nil then logmsg("err durin targeted search (empty ns) or pipe lost: " .. tostring(targetaddr), "error"); if not tryconnect() then return end
           elseif targetaddr ~= 0 then classaddr = targetaddr end
        end
        if classaddr == nil then logmsg("targeted search within Assembly-CSharp.dll also failed", "info") end
      else logmsg("couldnt find Assembly-CSharp.dll image loaded", "info") end
    end

    if classaddr == nil or classaddr == 0 then
      logmsg("------------------------------", "separator")
      logmsg("err class couldnt be found: " .. classnameinput, "error")
      logmsg("tips: check name/namespace/case use mono dissector (ctrl+alt+m)", "info")
      lastResults = { className = classnameinput .. " (Not Found)", classAddr = 0, instanceFields={}, staticFields = {}, methods = {} }
      return
    end

    if not tryconnect() then return end
    local fullname = classnameinput
    local okName, nameresult = pcall(mono_class_getFullName, classaddr, true, MONO_TYPE_NAME_FORMAT_REFLECTION)
    if not okName or monopipe == nil then logmsg("err gettin full name or pipe lost: " .. tostring(nameresult), "error"); fullname = fullname .. " (err)" else fullname = nameresult or fullname end

    -- get parent info
    local parentAddr = nil
    local parentName = nil
    local okParent, pAddr = pcall(mono_class_getParent, classaddr)
    if okParent and pAddr and pAddr ~= 0 then
        parentAddr = pAddr
        local okPName, pNameRes = pcall(mono_class_getFullName, parentAddr, true, MONO_TYPE_NAME_FORMAT_REFLECTION)
        if okPName and pNameRes then parentName = pNameRes else parentName = string.format("0x%X (err name)", parentAddr) end
        lastResults.parentName = parentName -- store parent name
    end

    -- get vtable for static fields (needed for mono non-il2cpp)
    local okVTable, vtable = pcall(mono_class_getVTable, nil, classaddr)
    if okVTable and vtable and vtable ~= 0 then
        currentClassVTable = vtable
        print("got vtable for static fields: 0x" .. string.format("%X", vtable))
    else
        currentClassVTable = 0 -- might be il2cpp or error
        print("couldnt get vtable maybe il2cpp?")
    end

    -- log class info ta listview header area
    synchronize(function()
        if inspectorform and inspectorform.outputlist then
            local item = inspectorform.outputlist.Items.Add(); item.Caption = "Class:"; item.SubItems.Add(fullname); item.Data = { type="header" }
            item = inspectorform.outputlist.Items.Add(); item.Caption = "Address:"; item.SubItems.Add(string.format("0x%X", classaddr)); item.Data = { type="header" }
            if parentName then
                item = inspectorform.outputlist.Items.Add(); item.Caption = "Parent:"; item.SubItems.Add(parentName); item.Data = { type="header_parent", parentAddr=parentAddr } -- store addr too
            end
            item = inspectorform.outputlist.Items.Add(); item.Caption = "--------------------"; item.Data = { type="separator" }
        end
    end)

    lastResults.className = fullname
    lastResults.classAddr = classaddr

    -- === fields ===
    synchronize(function() if inspectorform and inspectorform.outputlist then local i=inspectorform.outputlist.Items.Add(); i.Caption = "--- Fields ---"; i.Data={type="separator"} end end)
    if not tryconnect() then return end
    local fields = nil
    local okFields, fieldsresult = pcall(mono_class_enumFields, classaddr, true)
    if not okFields or monopipe == nil then logmsg("err enumeratin fields or pipe lost: " .. tostring(fieldsresult), "error")
    else fields = fieldsresult end

    if fields and #fields > 0 then
      local sortok = pcall(table.sort, fields, function(a,b)
          local flags_a = a and a.flags or 0; local flags_b = b and b.flags or 0
          local offset_a = a and a.offset or -1; local offset_b = b and b.offset or -1
          local static_a = (flags_a & FIELD_ATTRIBUTE_STATIC) ~= 0; local static_b = (flags_b & FIELD_ATTRIBUTE_STATIC) ~= 0
          if static_a ~= static_b then return static_a end; return offset_a < offset_b
      end)
      if not sortok then logmsg("warn: couldnt sort fields", "info") end

      for i, field in ipairs(fields) do
          if monopipe == nil then logmsg("pipe lost durin field loop", "error"); break end
          if i % 50 == 0 and not tryconnect() then break end

          local fieldflags = field and field.flags or 0
          local modstrs = {}
          table.insert(modstrs, getfieldmod(fieldflags))
          local isstatic = (fieldflags & FIELD_ATTRIBUTE_STATIC) ~= 0
          if isstatic then table.insert(modstrs, "static") end
          if (fieldflags & FIELD_ATTRIBUTE_LITERAL) ~= 0 then table.insert(modstrs, "const") end
          if (fieldflags & FIELD_ATTRIBUTE_INIT_ONLY) ~= 0 then table.insert(modstrs, "readonly") end

          local fieldtype = field.typename or (monoTypeToCStringLookup and monoTypeToCStringLookup[field.monotype]) or "?"
          local fieldname = field.name or "UnnamedField"
          local offsetstr = isstatic and "(static)" or string.format("0x%X", field.offset or -1)

          -- store field details
          local fieldData = { name = fieldname, type = fieldtype, modifiers = modstrs,
                              offset = isstatic and nil or (field.offset or -1), isStatic = isstatic,
                              addr = classaddr, monoType = field.monotype,
                              fieldPtr = field.field } -- store field handle/ptr too
          if isstatic then
              table.insert(lastResults.staticFields, fieldData)
          else
              table.insert(lastResults.instanceFields, fieldData) -- renamed from fields
          end

          -- add ta listview
          synchronize(function()
              if inspectorform and inspectorform.outputlist then
                  local item = inspectorform.outputlist.Items.Add()
                  item.Caption = isstatic and "Static Field" or "Instance Field" -- type col
                  item.SubItems.Add(string.format("%s %s %s", table.concat(modstrs, " "), fieldtype, fieldname)) -- details col
                  item.SubItems.Add(offsetstr) -- offset col
                  item.Data = { type = "field", details = fieldData } -- store data w/ item AND type tag
              end
          end)
      end
    else logmsg("  (no fields found or err occurred)", "info") end
    synchronize(function() if inspectorform and inspectorform.outputlist then local i=inspectorform.outputlist.Items.Add(); i.Caption="--------------------"; i.Data={type="separator"} end end)

    -- === methods ===
    synchronize(function() if inspectorform and inspectorform.outputlist then local i=inspectorform.outputlist.Items.Add(); i.Caption = "--- Methods ---"; i.Data={type="separator"} end end)
    if not tryconnect() then return end
    local methods = nil
    local okMethods, methodsresult = pcall(mono_class_enumMethods, classaddr, true)
     if not okMethods or monopipe == nil then logmsg("err enumeratin methods or pipe lost: " .. tostring(methodsresult), "error")
    else methods = methodsresult end

    if methods and #methods > 0 then
      for i, method in ipairs(methods) do
          if monopipe == nil then logmsg("pipe lost durin method loop", "error"); break end
          if i % 50 == 0 and not tryconnect() then break end

          local methodflags = method and method.flags or 0
          local modstrs = {}
          table.insert(modstrs, getmethodmod(methodflags))
          local isstatic = (methodflags & METHOD_ATTRIBUTE_STATIC) ~= 0
          if isstatic then table.insert(modstrs, "static") end
          if (methodflags & METHOD_ATTRIBUTE_VIRTUAL) ~= 0 then table.insert(modstrs, "virtual") end
          if (methodflags & METHOD_ATTRIBUTE_ABSTRACT) ~= 0 then table.insert(modstrs, "abstract") end
          if (methodflags & METHOD_ATTRIBUTE_FINAL) ~= 0 then table.insert(modstrs, "final") end

          local methodname = method.name or "UnnamedMethod"
          local signature = fmtsig(method.method) -- has pcall inside
          local fullmethodstring = methodname .. signature

          -- store method details only if methodPtr is valid
          local methodData = nil
          local compiledAddr = 0 -- default if not compiled or error
          -- *** FIX: Clearer address display ***
            -- *** FIX: Better address display logic for Mono/IL2CPP ***
            local addrDisplayStr = string.format("0x%X (handle)", method.method or 0) -- default ta handle
            local compiledAddr = 0
            if methodData and methodData.methodPtr then -- only try if we have a valid ptr
                if monopipe and monopipe.IL2CPP then
                    -- IL2CPP: try reading pointer at handle address
                    local okRead, nativeAddr = pcall(readPointer, methodData.methodPtr)
                    if okRead and nativeAddr and nativeAddr ~= 0 then
                        compiledAddr = nativeAddr
                        addrDisplayStr = string.format("0x%X (native IL2CPP)", compiledAddr)
                        methodData.compiledAddr = compiledAddr -- store it
                    else
                        print("warn: couldnt read IL2CPP func ptr @"..string.format("0x%X", methodData.methodPtr))
                        addrDisplayStr = string.format("0x%X (IL2CPP handle)", method.method or 0)
                    end
                else
                    -- Mono non-IL2CPP: try compiling
                    local okCompile, cAddr = pcall(mono_compile_method, methodData.methodPtr)
                    if okCompile and cAddr and cAddr ~= 0 then
                        compiledAddr = cAddr
                        addrDisplayStr = string.format("0x%X (native Mono)", compiledAddr) -- show native addr
                        methodData.compiledAddr = compiledAddr -- update stored data
                    elseif not okCompile then
                        print("err compiling method "..methodname..": "..tostring(cAddr))
                        addrDisplayStr = string.format("0x%X (err compile)", method.method or 0)
                    -- else keep handle display if compile returns 0
                    end
                end
            end
    
            synchronize(function()
                if inspectorform and inspectorform.outputlist then
                    local item = inspectorform.outputlist.Items.Add()
                    item.Caption = "Method" -- type col
                    item.SubItems.Add(table.concat(modstrs, " ") .. " " .. fullmethodstring) -- details col
                    item.SubItems.Add(addrDisplayStr) -- show compiled addr or handle/error
                    item.Data = { type = "method", details = methodData } -- store data (or nil) w/ item AND type tag
                end
            end)
      end
    else logmsg("  (no methods found or err occurred)", "info") end
    synchronize(function() if inspectorform and inspectorform.outputlist then local i=inspectorform.outputlist.Items.Add(); i.Caption="--------------------"; i.Data={type="separator"} end end)
    logmsg("inspection complete", "info")

    -- enable static field button if statics exist
    synchronize(function()
        if inspectorform and inspectorform.showStaticBtn then
            inspectorform.showStaticBtn.Enabled = (#lastResults.staticFields > 0)
        end
    end)
end

-- === value display func (now adds editable items) ===
local function displayvalues(instanceAddrStr)
    if not inspectorform or not inspectorform.Visible or not inspectorform.outputlist then return end
    local outputlist = inspectorform.outputlist
    local instanceAddr = getAddressSafe(instanceAddrStr)

    -- clear previous values first
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local i = inspectorform.outputlist.Items.Count - 1
        while i >= 0 do
            local item = inspectorform.outputlist.Items[i]
            if item and item.Exists and item.Data and (item.Data.type == "editable_field" or item.Data.type == "values_header" or item.Data.type == "value_separator") then
                item.Delete()
            end
            i = i - 1
        end
    end)


    if not instanceAddr or instanceAddr == 0 then
        local item = outputlist.Items.Add(); item.Caption = "err: invalid instance address entered"; item.Data = {type="error"}
        return
    end
    if #lastResults.instanceFields == 0 then
        local item = outputlist.Items.Add(); item.Caption = "no instance fields found for class " .. lastResults.className .. " cant show values"; item.Data = {type="info"}
        return
    end

    currentInstanceAddr = instanceAddr -- store for write func

    --  header for values section
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local item = inspectorform.outputlist.Items.Add(); item.Caption = "Value Separator"; item.SubItems.Add("--------------------"); item.Data={type="separator"}
        item = inspectorform.outputlist.Items.Add(); item.Caption = "Values Header"; item.SubItems.Add(string.format("editable values for instance @ 0x%X:", instanceAddr)); item.Data={type="header"}
        item.SubItems.Add("(edit col 4 -> write)") -- hint
    end)


    -- add editable items for each instance field
    for _, field in ipairs(lastResults.instanceFields) do
        if field.offset and field.offset >= 0 then
            local fieldAddr = instanceAddr + field.offset
            local ceTypeStr = getCEVarTypeStr(field.monoType)
            local valueStr = readCEValue(ceTypeStr, fieldAddr)
            local ceVarType = monoVtMap[field.monoType] or monoVtMap["Default"]

            synchronize(function()
                if not inspectorform or not inspectorform.outputlist then return end
                local item = outputlist.Items.Add()
                item.Caption = "Editable Field" -- type col
                item.SubItems.Add(string.format("%s %s", field.type, field.name)) -- col 2: name/type
                item.SubItems.Add(valueStr) -- col 3: current val
                item.SubItems.Add(valueStr) -- col 4: new val (initially same as current)
                -- store necessary data for writing
                item.Data = {
                    type = "editable_field", -- specific type tag
                    isStatic = false,
                    fieldName = field.name,
                    offset = field.offset,
                    ceVarType = ceVarType,
                    fieldPtr = field.fieldPtr -- store field handle too
                }
            end)
        end
    end
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local item = inspectorform.outputlist.Items.Add(); item.Caption = "Value Separator"; item.SubItems.Add("--------------------"); item.Data={type="separator"}
        -- enable write button
        if inspectorform.writevalsbtn then inspectorform.writevalsbtn.Enabled = true end
    end)

end

-- *** NEW: Static value display func ***
local function displayStaticValues()
    if not inspectorform or not inspectorform.Visible or not inspectorform.outputlist then return end
    local outputlist = inspectorform.outputlist

    -- clear previous static values first
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local i = inspectorform.outputlist.Items.Count - 1
        while i >= 0 do
            local item = inspectorform.outputlist.Items[i]
            if item and item.Exists and item.Data and (item.Data.type == "editable_static_field" or item.Data.type == "static_header" or item.Data.type == "static_separator") then
                item.Delete()
            end
            i = i - 1
        end
    end)

    if #lastResults.staticFields == 0 then
        local item = outputlist.Items.Add(); item.Caption = "no static fields found for class " .. lastResults.className; item.Data = {type="info"}
        return
    end

    --  header for static values section
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local item = inspectorform.outputlist.Items.Add(); item.Caption = "Static Separator"; item.SubItems.Add("--- Static Fields ---"); item.Data={type="separator"}
        item = inspectorform.outputlist.Items.Add(); item.Caption = "Static Header"; item.SubItems.Add("editable static values for class"); item.Data={type="header"}
        item.SubItems.Add("(edit col 4 -> write)") -- hint
    end)

    --  editable items for each static field
    for _, field in ipairs(lastResults.staticFields) do
        if not tryconnect() then break end -- check connection before each read
        local valueStr = "?"
        local okVal, valResult = pcall(getStaticFieldValue, field) --  helper func
        if okVal then valueStr = tostring(valResult or "?") else print("err gettin static val for "..field.name..": "..tostring(valResult)) end

        local ceVarType = monoVtMap[field.monoType] or monoVtMap["Default"]

        synchronize(function()
            if not inspectorform or not inspectorform.outputlist then return end
            local item = outputlist.Items.Add()
            item.Caption = "Editable Static" -- type col
            item.SubItems.Add(string.format("%s %s", field.type, field.name)) -- col 2: name/type
            item.SubItems.Add(valueStr) -- col 3: current val
            item.SubItems.Add(valueStr) -- col 4: new val (initially same as current)
            -- store necessary data for writing
            item.Data = {
                type = "editable_static_field", -- specific type tag
                isStatic = true,
                fieldName = field.name,
                fieldPtr = field.fieldPtr, -- store field handle
                ceVarType = ceVarType
            }
        end)
    end
    synchronize(function()
        if not inspectorform or not inspectorform.outputlist then return end
        local item = inspectorform.outputlist.Items.Add(); item.Caption = "Static Separator"; item.SubItems.Add("--------------------"); item.Data={type="separator"}
        -- enable static write button
        if inspectorform.writeStaticBtn then inspectorform.writeStaticBtn.Enabled = true end
    end)
end

-- === write changed values func ===
local function writeChangedValues()
    if not inspectorform or not inspectorform.Visible or not inspectorform.outputlist then return end
    if currentInstanceAddr == 0 then showMessage("no instance address set pls use 'show vals' first"); return end

    local changesMade = 0
    local errors = 0
    print("tryna write changed instance values for 0x" .. string.format("%X", currentInstanceAddr))

    for i = 0, inspectorform.outputlist.Items.Count - 1 do
        local item = inspectorform.outputlist.Items[i]
        -- check if its an editable field item n has data n is NOT static
        if item.Caption == "Editable Field" and type(item.Data) == 'table' and item.Data.offset and not item.Data.isStatic then
            local currentValStr = item.SubItems[1] -- col 3 (index 1)
            local newValStr = item.SubItems[2] -- col 4 (index 2)

            if newValStr ~= currentValStr then
                print(string.format("  change detected for %s: '%s' -> '%s'", item.Data.fieldName, currentValStr, newValStr))
                local fieldAddr = currentInstanceAddr + item.Data.offset
                local okWrite = writeCEValue(item.Data.ceVarType, fieldAddr, newValStr)
                if okWrite then
                    changesMade = changesMade + 1
                    synchronize(function() if item.Exists then item.SubItems[1] = newValStr end end)
                else
                    errors = errors + 1
                end
            end
        end
    end

    if errors > 0 then showMessage(string.format("wrote %d instance values with %d errors check console", changesMade, errors))
    elseif changesMade > 0 then showMessage(string.format("wrote %d instance values successfully", changesMade))
    else showMessage("no instance value changes detected ta write") end
end

-- *** NEW: write changed STATIC values func ***
local function writeChangedStaticValues()
    if not inspectorform or not inspectorform.Visible or not inspectorform.outputlist then return end
    if currentClassVTable == 0 and monopipe and not monopipe.IL2CPP then
        showMessage("cant write static fields no vtable found (maybe il2cpp or error?)")
        return
    end

    local changesMade = 0
    local errors = 0
    print("tryna write changed static values for class " .. lastResults.className)

    for i = 0, inspectorform.outputlist.Items.Count - 1 do
        local item = inspectorform.outputlist.Items[i]
        -- check if its an editable STATIC field item n has data
        if item.Caption == "Editable Static" and type(item.Data) == 'table' and item.Data.isStatic then
            local currentValStr = item.SubItems[1] -- col 3 (index 1)
            local newValStr = item.SubItems[2] -- col 4 (index 2)

            if newValStr ~= currentValStr then
                print(string.format("  static change detected for %s: '%s' -> '%s'", item.Data.fieldName, currentValStr, newValStr))

                -- convert new value string ta number/qword based on type
                local ceType = item.Data.ceVarType
                local valToWrite = nil
                local okParse = true
                if ceType == vtByte or ceType == vtWord or ceType == vtDword or ceType == vtQword then
                    valToWrite = tonumber(newValStr)
                elseif ceType == vtSingle then
                    local f = tonumber(newValStr)
                    if f then valToWrite = byteTableToDword(floatToByteTable(f)) end -- need dword for qword func
                elseif ceType == vtDouble then
                    local d = tonumber(newValStr)
                    if d then valToWrite = byteTableToQword(doubleToByteTable(d)) end
                elseif ceType == vtPointer then
                    valToWrite = getAddressSafe(newValStr) or tonumber(newValStr)
                elseif ceType == vtString then
                    print("warn: writing static strings not supported yet")
                    okParse = false
                else
                    print("warn: unsupported static type for writing: " .. ceType)
                    okParse = false
                end

                if valToWrite == nil then print("err: couldnt parse static value '"..newValStr.."'"); okParse = false end

                if okParse then
                    if not tryconnect() then errors = errors + 1; break end
                    --  mono_setStaticFieldValue (needs pcall)
                    local okWriteStatic = pcall(mono_setStaticFieldValue, currentClassVTable, item.Data.fieldPtr, valToWrite)
                    if okWriteStatic then
                        changesMade = changesMade + 1
                        synchronize(function() if item.Exists then item.SubItems[1] = newValStr end end)
                    else
                        print("err writing static field "..item.Data.fieldName)
                        errors = errors + 1
                    end
                else
                    errors = errors + 1
                end
            end
        end
    end

    if errors > 0 then showMessage(string.format("wrote %d static values with %d errors check console", changesMade, errors))
    elseif changesMade > 0 then showMessage(string.format("wrote %d static values successfully", changesMade))
    else showMessage("no static value changes detected ta write") end
end

-- mapping mono types to signed/unsigned for ShowAsSigned guess
local isSignedMonoType = {
    [MONO_TYPE_I1]=true, [MONO_TYPE_I2]=true, [MONO_TYPE_I4]=true, [MONO_TYPE_I8]=true,
    [MONO_TYPE_R4]=true, [MONO_TYPE_R8]=true, -- floats/doubles are signed
    -- others default to false/0
}

-- === structure generation func ===
local function generateCEStructure()
    if #lastResults.instanceFields == 0 then -- check instance fields now
        showMessage("no instance fields found ta generate structure from")
        return
    end
    local classNameSafe = lastResults.className:gsub("[^a-zA-Z0-9_]", "_")
    if classNameSafe == "" then classNameSafe = "UnnamedClass" end
    local structureXML = {
        '<?xml version="1.0" encoding="utf-8"?>',
        '<CheatTable>',
        '  <CheatEntries>'
    }
    local entryID = 0
    local hasInstanceFields = false

    -- add cheat entries for instance fields
    for _, field in ipairs(lastResults.instanceFields) do -- use instanceFields
        -- offset check already done when populating lastResults
        local ceVarType = monoVtMap[field.monoType] or monoVtMap["Default"]
        local ceTypeStr = getCEVarTypeStr(field.monoType)
        local fieldNameSafe = field.name:gsub("[^a-zA-Z0-9_]", "_")
        if fieldNameSafe == "" then fieldNameSafe = "UnnamedField_Offset_" .. string.format("%X", field.offset) end
        local description = ('"%s (%s)"'):format(fieldNameSafe:gsub("&", "&amp;"):gsub('"', "&quot;"), field.type:gsub("&", "&amp;"):gsub('"', "&quot;"))
        local showAsSigned = (isSignedMonoType[field.monoType] == true) and "1" or "0"

        table.insert(structureXML, '    <CheatEntry>')
        table.insert(structureXML, '      <ID>' .. entryID .. '</ID>')
        table.insert(structureXML, '      <Description>' .. description .. '</Description>')
        table.insert(structureXML, '      <ShowAsSigned>'.. showAsSigned ..'</ShowAsSigned>')
        if ceVarType == vtString or ceVarType == vtUnicodeString then
             table.insert(structureXML, '      <VariableType>Unicode String</VariableType>')
             table.insert(structureXML, '      <Length>255</Length>')
             table.insert(structureXML, '      <Unicode>1</Unicode>')
             table.insert(structureXML, '      <CodePage>0</CodePage>')
             table.insert(structureXML, '      <ZeroTerminate>1</ZeroTerminate>')
        else
             table.insert(structureXML, '      <VariableType>'.. ceTypeStr .. '</VariableType>')
        end
        table.insert(structureXML, '      <Address>' .. classNameSafe .. "+" .. string.format("%X", field.offset) .. '</Address>')
        table.insert(structureXML, '    </CheatEntry>')
        entryID = entryID + 1
        hasInstanceFields = true
    end
    if not hasInstanceFields then table.insert(structureXML, '    ') end

    table.insert(structureXML, '  </CheatEntries>')
    table.insert(structureXML, '  <UserdefinedSymbols/>')
    table.insert(structureXML, '  <Structures>')
    table.insert(structureXML, '    <Structure Name="' .. classNameSafe .. '" AutoFill="1" AutoCreate="1" DefaultHex="0" EnableStructureDissection="1" IsClass="1">')
    hasFields = false -- reset flag
    for _, field in ipairs(lastResults.instanceFields) do
        local ceVarType = monoVtMap[field.monoType] or monoVtMap["Default"]
        local ceTypeStr = getCEVarTypeStr(field.monoType)
        local fieldNameSafe = field.name:gsub("[^a-zA-Z0-9_]", "_")
        if fieldNameSafe == "" then fieldNameSafe = "UnnamedField_Offset_" .. string.format("%X", field.offset) end
        local bytesize = ceTypeStr:match("%d+") or (ceTypeStr == "Float" and 4) or (ceTypeStr == "Double" and 8) or (ceTypeStr == "String" and 255) or 4
        local isUnicode = (ceVarType == vtUnicodeString or ceVarType == vtString)
        local isPtr = (ceVarType == vtPointer)
        table.insert(structureXML, string.format('      <Element Offset="%X" Vartype="%d" Bytesize="%d"%s%s Description="%s"/>',
            field.offset, ceVarType, bytesize,
            isUnicode and ' AllowOffsets="1" DisplayMethod="1"' or '',
            isPtr and ' DisplayMethod="1"' or '',
            fieldNameSafe .. " (" .. field.type:gsub("&", "&amp;"):gsub('"', "&quot;") .. ")"
            ))
        hasFields = true
    end
    if not hasFields then table.insert(structureXML, '      ') end
    table.insert(structureXML, '    </Structure>')
    table.insert(structureXML, '  </Structures>')
    table.insert(structureXML, '  <LuaScript/>')
    table.insert(structureXML, '</CheatTable>')

    local output = table.concat(structureXML, "\n")
    local structForm = createForm(true); structForm.Caption = "Generated Cheat Table XML: " .. classNameSafe; structForm.Width = 600; structForm.Height = 500
    local memo = createMemo(structForm); memo.Align = alClient; memo.ScrollBars = ssBoth; memo.Lines.Text = output
    -- *** FIX: Use writeToClipboard ***
    local btnCopy = createButton(structForm); btnCopy.Caption = "Copy to Clipboard"; btnCopy.Align = alBottom; btnCopy.OnClick = function() writeToClipboard(output) end
    structForm.show()
end

-- === method invocation dialog n func ===
local function showInvokeDialog(methodData)
    -- *** FIX: Check if methodData is a table and has methodPtr ***
    if type(methodData) ~= 'table' or not methodData.methodPtr then
        print("err: invalid method data for invoke (not a table or missing ptr). data:", methodData)
        showMessage("err: invalid method data selected")
        return
    end
    if not tryconnect() then return end -- need connection ta get params

    local okParams, paramsInfo = pcall(mono_method_get_parameters, methodData.methodPtr)
    if not okParams or monopipe == nil or not paramsInfo then
        showMessage("err gettin method parameters: " .. tostring(paramsInfo))
        return
    end

    -- create dialog form
    local invokeForm = createForm(true)
    invokeForm.Caption = "Invoke: " .. (methodData.name or "Unknown Method") -- Use name safely
    invokeForm.Width = 400
    invokeForm.Height = 150 + (#paramsInfo.parameters * 55) + (methodData.isStatic and 0 or 55)
    invokeForm.Position = poScreenCenter

    local currentY = 10
    local paramEdits = {} -- store edit boxes
    local instanceEdit = nil

    -- instance addr input if needed
    if not methodData.isStatic then
        local lbl = createLabel(invokeForm)
        lbl.Caption = "Instance Addr (Hex):"
        lbl.Left = 10; lbl.Top = currentY
        instanceEdit = createEdit(invokeForm)
        instanceEdit.Left = 10; instanceEdit.Top = currentY + 20; instanceEdit.Width = invokeForm.Width - 30
        -- default instance from main form only if inspectorform exists
        instanceEdit.Text = (inspectorform and inspectorform.instanceInput.Text) or "0"
        table.insert(paramEdits, { isInstance = true, edit = instanceEdit }) -- mark it
        currentY = currentY + 55
    end

    -- parameter inputs
    for i, param in ipairs(paramsInfo.parameters) do
        local lbl = createLabel(invokeForm)
        local ceType = monoVtMap[param.type] or monoVtMap["Default"]
        local typeStr = getCEVarTypeStr(param.type)
        lbl.Caption = string.format("Param %d: %s (%s)", i, param.name or "?", typeStr)
        lbl.Left = 10; lbl.Top = currentY
        local edt = createEdit(invokeForm)
        edt.Left = 10; edt.Top = currentY + 20; edt.Width = invokeForm.Width - 30
        edt.Text = "0" -- default val
        table.insert(paramEdits, { name = param.name, type = ceType, edit = edt })
        currentY = currentY + 55
    end

    -- ok n cancel buttons
    local btnPanel = createPanel(invokeForm)
    btnPanel.Align = alBottom; btnPanel.Height = 40; btnPanel.BevelOuter = bvNone
    local btnOk = createButton(btnPanel)
    btnOk.Caption = "Invoke"
    btnOk.ModalResult = mrOk
    btnOk.Left = invokeForm.Width - 180; btnOk.Top = 5
    local btnCancel = createButton(btnPanel)
    btnCancel.Caption = "Cancel"
    btnCancel.ModalResult = mrCancel
    btnCancel.Left = invokeForm.Width - 90; btnCancel.Top = 5

    -- show n process result
    if invokeForm.ShowModal() == mrOk then
        local args = {}
        local instanceAddr = 0 -- default for static
        local errParsing = false

        for _, pEditInfo in ipairs(paramEdits) do
            local valStr = pEditInfo.edit.Text:trim()
            local val = nil
            local okParse = true

            if pEditInfo.isInstance then
                instanceAddr = getAddressSafe(valStr) or tonumber(valStr) or 0 -- try hex/dec
                if instanceAddr == 0 and valStr ~= "0" and valStr ~= "" then -- Allow 0/empty but warn on other failed parses
                   print("warn: couldnt parse instance addr: " .. valStr); okParse = false; errParsing = true
                end
            else
                local ceType = pEditInfo.type
                if ceType == vtString then
                    if not tryconnect() then errParsing = true; break end
                    local okStr, monoStrAddr = pcall(mono_new_string, nil, valStr) -- use default domain
                    if not okStr or monopipe == nil or not monoStrAddr then
                        print("err creatin mono string for '" .. valStr .. "': " .. tostring(monoStrAddr))
                        okParse = false; errParsing = true
                    else
                        val = monoStrAddr
                    end
                elseif ceType == vtByte or ceType == vtWord or ceType == vtDword or ceType == vtQword then
                    val = tonumber(valStr)
                elseif ceType == vtSingle or ceType == vtDouble then
                    val = tonumber(valStr)
                elseif ceType == vtPointer then
                    val = getAddressSafe(valStr) or tonumber(valStr)
                else
                    val = getAddressSafe(valStr) or tonumber(valStr)
                end

                if val == nil then print("warn: couldnt parse param '" .. (pEditInfo.name or "?") .. "': " .. valStr); okParse = false; errParsing = true end

                if okParse then
                    table.insert(args, { type = ceType, value = val })
                else
                    errParsing = true; break
                end
            end
        end -- end for paramEdits

        if not errParsing then
            print(string.format("invokin %s.%s (instance: 0x%X) w/ %d args...", lastResults.className, methodData.name, instanceAddr, #args))
            if not tryconnect() then return end -- final check

            local okInvoke, result = pcall(mono_invoke_method, nil, methodData.methodPtr, instanceAddr, args) -- use default domain

            if not okInvoke or monopipe == nil then
                print("!! invoke failed: " .. tostring(result))
                showMessage("invoke failed: " .. tostring(result))
            else
                local resultStr = "?"
                if type(result) == 'number' then resultStr = string.format("0x%X (%d)", result, result)
                elseif type(result) == 'string' then resultStr = '"' .. result .. '"'
                elseif result == nil then resultStr = "nil / void"
                else resultStr = tostring(result) end

                print(">> invoke result: " .. resultStr)
                showMessage("invoke result: " .. resultStr)
            end
        else
            showMessage("err parsing parameters check console")
        end
    end -- end if mrOk
end


-- === helper ta trigger invoke dialog ===
local function triggerInvoke(item)
    if not item then print("triggerInvoke: no item selected"); return end
    -- *** FIX: Check item.Data is table AND item.Data.details is table AND methodPtr exists ***
    if item.Caption == "Method" and type(item.Data) == 'table' and type(item.Data.details) == 'table' and item.Data.details.methodPtr then
        showInvokeDialog(item.Data.details) -- pass the *details* table
    else
        print("selected item aint a method or has no valid data")
        -- showMessage("selected item aint a method or has no valid data") -- maybe dont show msg just print
    end
end

-- === method invocation dialog n func (SetBounds n var name fixed) ===
local function showManualInvokeDialog(prefillData)
    -- prefillData is the item.Data.details table from the selected listview item or nil

    if not tryconnect() then return end -- need connection ta get params

    -- try ta get params even if prefillData is nil (for manual entry)
    local methodPtr = nil
    local methodIsStatic = false -- assume instance unless prefill says otherwise
    if type(prefillData) == 'table' and prefillData.methodPtr then
        methodPtr = prefillData.methodPtr
        methodIsStatic = prefillData.isStatic or false
    end

    local paramsInfo = nil
    local okParams = true
    local paramErr = "unknown err"

    if methodPtr then
        okParams, paramsInfo = pcall(mono_method_get_parameters, methodPtr)
        if not okParams or monopipe == nil then
            paramErr = tostring(paramsInfo)
            paramsInfo = nil
        elseif not paramsInfo then
             paramErr = "mono_method_get_parameters returned nil"

        end
    else

        paramsInfo = { parameters = {} }
        print("no prefill method data cant auto-get params")
    end

    if not paramsInfo then
        showMessage("err gettin method parameters: " .. paramErr .. "\nu gotta enter params manually if needed")
        paramsInfo = { parameters = {} }
    end



    local invokeForm = createForm(true)
    invokeForm.Caption = "Manual Method Invoker"
    invokeForm.Width = 450

    invokeForm.Position = poScreenCenter

    local currentY = 10
    local paramEdits = {}
    local controlRefs = {}


    local lblClass = createLabel(invokeForm); lblClass.Caption = "Class Name (e.g. Namespace.Class):";
    lblClass.Left = 10; lblClass.Top = currentY; lblClass.Width = 400; lblClass.Height = 15; controlRefs.lblClass = lblClass
    currentY = currentY + 20
    local edtClass = createEdit(invokeForm);
    edtClass.Left = 10; edtClass.Top = currentY; edtClass.Width = invokeForm.Width - 30; edtClass.Height = 25; controlRefs.edtClass = edtClass
    currentY = currentY + 35


    local lblMethod = createLabel(invokeForm); lblMethod.Caption = "Method Name:";
    lblMethod.Left = 10; lblMethod.Top = currentY; lblMethod.Width = 400; lblMethod.Height = 15; controlRefs.lblMethod = lblMethod
    currentY = currentY + 20
    local edtMethod = createEdit(invokeForm);
    edtMethod.Left = 10; edtMethod.Top = currentY; edtMethod.Width = invokeForm.Width - 30; edtMethod.Height = 25; controlRefs.edtMethod = edtMethod
    currentY = currentY + 35


    local lblInstance = createLabel(invokeForm); lblInstance.Caption = "Instance Addr (Hex 0x... or Dec):";
    lblInstance.Left = 10; lblInstance.Top = currentY; lblInstance.Width = 400; lblInstance.Height = 15; controlRefs.lblInstance = lblInstance
    currentY = currentY + 20
    local edtInstance = createEdit(invokeForm);
    edtInstance.Left = 10; edtInstance.Top = currentY; edtInstance.Width = 150; edtInstance.Height = 25; edtInstance.Text = "0"; controlRefs.edtInstance = edtInstance
    local chkStatic = createCheckBox(invokeForm); chkStatic.Caption = "Static Method";
    chkStatic.Left = 170; chkStatic.Top = currentY + 3; chkStatic.Width = 150; chkStatic.Height = 20; controlRefs.chkStatic = chkStatic
    chkStatic.OnChange = function(sender) edtInstance.Enabled = not sender.Checked end
    currentY = currentY + 35


    local lblParams = createLabel(invokeForm); lblParams.Caption = "Parameters (comma-separated: \"str\", 123, 0xAddr, 1.5):";
    lblParams.Left = 10; lblParams.Top = currentY; lblParams.Width = 400; lblParams.Height = 15; controlRefs.lblParams = lblParams
    currentY = currentY + 20

    local edtParams = createEdit(invokeForm);
    edtParams.Left = 10; edtParams.Top = currentY; edtParams.Width = invokeForm.Width - 30; edtParams.Height = 25; controlRefs.edtParams = edtParams
    currentY = currentY + 35


    local lblCount = createLabel(invokeForm); lblCount.Caption = "Invoke Count:";
    lblCount.Left = 10; lblCount.Top = currentY; lblCount.Width = 100; lblCount.Height = 15; controlRefs.lblCount = lblCount
    currentY = currentY + 20

    local edtCount = createEdit(invokeForm);
    edtCount.Left = 10; edtCount.Top = currentY; edtCount.Width = 80; edtCount.Height = 25; edtCount.Text = "1"; controlRefs.edtCount = edtCount
    currentY = currentY + 45


    if type(prefillData) == 'table' then
        edtClass.Text = lastResults.className or ""
        edtMethod.Text = prefillData.name or ""
        chkStatic.Checked = prefillData.isStatic or false
        edtInstance.Enabled = not chkStatic.Checked
        if paramsInfo and #paramsInfo.parameters > 0 then
            local prefillParamStr = {}
            for i, p in ipairs(paramsInfo.parameters) do
                local typeStr = getCEVarTypeStr(p.type)
                table.insert(prefillParamStr, string.format("%s %s=?", typeStr, p.name or "param"..i))
            end
            edtParams.Text = table.concat(prefillParamStr, ", ")
            edtParams.Hint = "Enter actual values separated by commas"
        else
             edtParams.Hint = "Enter values separated by commas (e.g. \"hello\", 100)"
        end
    else
        edtClass.Hint = "Namespace.ClassName"
        edtMethod.Hint = "MethodName"
        edtInstance.Hint = "0xInstanceAddress"
        edtParams.Hint = "e.g. \"hello\", 100, 0xAddress, true"
    end


    invokeForm.Height = currentY + 50


    local btnPanel = createPanel(invokeForm)
    btnPanel.Align = alBottom; btnPanel.Height = 40; btnPanel.BevelOuter = bvNone; controlRefs.btnPanel = btnPanel
    local btnDoInvoke = createButton(btnPanel)
    btnDoInvoke.Caption = "Invoke"
    btnDoInvoke.ModalResult = mrOk
    btnDoInvoke.Left = invokeForm.Width - 180; btnDoInvoke.Top = 5; controlRefs.btnDoInvoke = btnDoInvoke
    local btnCancel = createButton(btnPanel)
    btnCancel.Caption = "Cancel"
    btnCancel.ModalResult = mrCancel
    btnCancel.Left = invokeForm.Width - 90; btnCancel.Top = 5; controlRefs.btnCancel = btnCancel


    btnDoInvoke.OnClick = function()
        local className = edtClass.Text:trim()
        local methodName = edtMethod.Text:trim()
        local instanceAddrStr = edtInstance.Text:trim()
        local paramStr = edtParams.Text:trim()
        local invokeCount = tonumber(edtCount.Text) or 1
        local isStatic = chkStatic.Checked

        if className == "" or methodName == "" then showMessage("need class n method name"); return end
        if not isStatic and instanceAddrStr == "" then showMessage("need instance addr for non-static method"); return end

        print(string.format("attempt invoke: class='%s' method='%s' static=%s instance='%s' params='%s' count=%d",
            className, methodName, tostring(isStatic), instanceAddrStr, paramStr, invokeCount))

        if not tryconnect() then return end


        local okClass, classAddr = pcall(mono_findClass, nil, className)
        if not okClass or not classAddr or classAddr == 0 then showMessage("cant find class: " .. className .. "\nerr: " .. tostring(classAddr)); return end

        local okMethod, methodPtr = pcall(mono_class_findMethod, classAddr, methodName)
        if not okMethod or not methodPtr or methodPtr == 0 then showMessage("cant find method: " .. methodName .. " in class " .. className .. "\nerr: " .. tostring(methodPtr)); return end


        local okFlags, flags = pcall(mono_method_get_flags, methodPtr, nil)
        local actualStatic = (okFlags and (flags & METHOD_ATTRIBUTE_STATIC) ~= 0)
        if isStatic ~= actualStatic then
            local s = isStatic and "static" or "instance"
            local as = actualStatic and "static" or "instance"
            showMessage(string.format("WARN: u marked method as %s but it looks like its actually %s proceedin anyway...", s, as))
        end


        local instanceAddr = 0
        if not isStatic then
            instanceAddr = getAddressSafe(instanceAddrStr) or tonumber(instanceAddrStr) or 0
            if instanceAddr == 0 and instanceAddrStr ~= "0" and instanceAddrStr ~= "" then
                showMessage("cant parse instance addr: " .. instanceAddrStr); return
            end
        end


        local args = {}
        local errParsing = false
        if paramStr ~= "" then
            for valStr in string.gmatch(paramStr, "([^,]+)") do
                valStr = valStr:trim()
                local val = nil
                local ceType = vtUnknown

                if valStr:lower() == "true" then val = 1; ceType = vtByte
                elseif valStr:lower() == "false" then val = 0; ceType = vtByte
                elseif valStr:sub(1,2) == '0x' then val = getAddressSafe(valStr); ceType = vtPointer
                elseif valStr:sub(1,1) == '"' and valStr:sub(-1) == '"' then val = valStr:sub(2, -2); ceType = vtString
                elseif tonumber(valStr) then
                    val = tonumber(valStr)
                    if valStr:find('.') then ceType = vtDouble else ceType = vtQword end
                else val = getAddressSafe(valStr); if val then ceType = vtPointer else ceType = vtString; val = valStr end
                end

                if val == nil and ceType ~= vtString then print("warn: couldnt parse param value: " .. valStr); errParsing = true; break end

                if ceType == vtString then
                    if not tryconnect() then errParsing = true; break end
                    local okStr, monoStrAddr = pcall(mono_new_string, nil, val)
                    if not okStr or monopipe == nil or not monoStrAddr then print("err creatin mono string for '" .. val .. "': " .. tostring(monoStrAddr)); errParsing = true; break
                    else val = monoStrAddr; ceType = vtPointer end
                end
                table.insert(args, { type = ceType, value = val })
            end
        end

        if errParsing then showMessage("err parsing parameters check console"); return end


        print(string.format("invokin %s.%s (instance: 0x%X) %d times w/ %d args...", className, methodName, instanceAddr, invokeCount, #args))
        local results = {}
        local invokeErrors = 0
        for i = 1, invokeCount do
            if not tryconnect() then showMessage("pipe lost durin invoke loop"); break end
            local okInvoke, result = pcall(mono_invoke_method, nil, methodPtr, instanceAddr, args)
            if not okInvoke or monopipe == nil then
                print(string.format("!! invoke #%d failed: %s", i, tostring(result)))
                table.insert(results, "err: " .. tostring(result))
                invokeErrors = invokeErrors + 1
            else
                local resultStr = "?"
                if type(result) == 'number' then resultStr = string.format("0x%X (%d)", result, result)
                elseif type(result) == 'string' then resultStr = '"' .. result .. '"'
                elseif result == nil then resultStr = "nil / void"
                else resultStr = tostring(result) end
                print(string.format(">> invoke #%d result: %s", i, resultStr))
                table.insert(results, resultStr)
            end
            if invokeErrors > 5 then print("too many errors abortin loop"); break end
            sleep(10)
        end
        showMessage(string.format("invoke finished. %d calls %d errors.\nresults:\n%s", invokeCount, invokeErrors, table.concat(results, "\n")))

    end

    manualInvokeForm.show()
end


if inspectorform and inspectorform.Visible then pcall(inspectorform.destroy); inspectorform = nil end
if inspectorform then inspectorform = nil end

inspectorform = createForm(true)
inspectorform.Caption = 'mono/il2cpp class inspector (informal v6.7 - final fixes)'
inspectorform.Width = 950
inspectorform.Height = 700
inspectorform.Position = poScreenCenter


local toppanel = createPanel(inspectorform); toppanel.Align = alTop; toppanel.Height = 70; toppanel.BevelOuter = bvNone
local classlabel = createLabel(toppanel); classlabel.Caption = 'class name:';
classlabel.Left = 10; classlabel.Top = 5; classlabel.Width = 80; classlabel.Height = 25;
local classinput = createEdit(toppanel);
classinput.Left = 10; classinput.Top = 35; classinput.Width = 250; classinput.Height = 25;
classinput.Text = 'AvatarMotor'
local filterInput = createEdit(toppanel); filterInput.Hint = "filter results...";
filterInput.Left = classinput.Left + classinput.Width + 10; filterInput.Top = 35; filterInput.Width = 120; filterInput.Height = 25;
local filterBtn = createButton(toppanel); filterBtn.Caption = "Filter";
filterBtn.Left = filterInput.Left + filterInput.Width + 5; filterBtn.Top = 33; filterBtn.Width = 60; filterBtn.Height = 27;
local lookupbtn = createButton(toppanel); lookupbtn.Caption = 'Inspect';
lookupbtn.Left = filterBtn.Left + filterBtn.Width + 10; lookupbtn.Top = 33; lookupbtn.Width = 80; lookupbtn.Height = 27;
local instanceLabel = createLabel(toppanel); instanceLabel.Caption = "instance addr:";
instanceLabel.Left = lookupbtn.Left + lookupbtn.Width + 15; instanceLabel.Top = 5; instanceLabel.Width = 100; instanceLabel.Height = 25;
local instanceInput = createEdit(toppanel);
instanceInput.Left = instanceLabel.Left; instanceInput.Top = 35; instanceInput.Width = 120; instanceInput.Height = 25;
instanceInput.Text = "0"
local showvalsbtn = createButton(toppanel); showvalsbtn.Caption = "Show Vals";
showvalsbtn.Left = instanceInput.Left + instanceInput.Width + 10; showvalsbtn.Top = 33; showvalsbtn.Width = 80; showvalsbtn.Height = 27;
local showStaticBtn = createButton(toppanel); showStaticBtn.Caption = "Show Statics";
showStaticBtn.Left = showvalsbtn.Left + showvalsbtn.Width + 10; showStaticBtn.Top = 33; showStaticBtn.Width = 100; showStaticBtn.Height = 27;
showStaticBtn.Enabled = false

local invokeFormBtn = createButton(toppanel); invokeFormBtn.Caption = "Invoke...";
invokeFormBtn.Left = showStaticBtn.Left + showStaticBtn.Width + 10; invokeFormBtn.Top = 33; invokeFormBtn.Width = 90; invokeFormBtn.Height = 27;


local outputlist = createListView(inspectorform)
outputlist.Align = alClient
outputlist.ViewStyle = vsReport
outputlist.ReadOnly = false
outputlist.GridLines = true
outputlist.RowSelect = true
outputlist.HideSelection = false
outputlist.Columns.Add().Caption = "Item Type" ; outputlist.Columns.Add().Caption = "Details"; outputlist.Columns.Add().Caption = "Offset/Addr/CurVal"; outputlist.Columns.Add().Caption = "New Value"
outputlist.Columns[0].Width = 100; outputlist.Columns[1].Width = 400; outputlist.Columns[2].Width = 150; outputlist.Columns[3].Width = 150

outputlist.OnDblClick = function(sender)
    local item = sender.Selected
    if not item or not item.Exists then return end

    local itemData = item.Data
    if not itemData then return end


    if itemData.type == "method" then

        if inspectorform and inspectorform.invokeFormBtn then
            inspectorform.invokeFormBtn.OnClick(inspectorform.invokeFormBtn)
        end
    elseif itemData.type == "editable_field" or itemData.type == "editable_static_field" then
        item.EditCaption(3)
    elseif itemData.type == "field" then

        local sub1 = item.SubItems.Count > 0 and (item.SubItems[0] or "") or ""
        local sub2 = item.SubItems.Count > 1 and (item.SubItems[1] or "") or ""
        local line = string.format("%s | %s | %s", item.Caption or "", sub1, sub2)
        writeToClipboard(line)
        print("copied field info ta clipboard")
    end

end
outputlist.OnEditing = function(sender, item, col, allowedit)
    if item and item.Exists and item.Data and (item.Data.type == "editable_field" or item.Data.type == "editable_static_field") and col == 3 then
        return true
    else
        return false
    end
end

-- context menu for listview
local listPopup = createPopupMenu(inspectorform)
local miCopyLine = createMenuItem(listPopup); miCopyLine.Caption = "Copy Selected Line"
local miCopyDetails = createMenuItem(listPopup); miCopyDetails.Caption = "Copy Details"
local miCopyAddress = createMenuItem(listPopup); miCopyAddress.Caption = "Copy Offset/Address"
local miSep1 = createMenuItem(listPopup); miSep1.Caption = "-"
local miInvokePopup = createMenuItem(listPopup); miInvokePopup.Caption = "Invoke Method..."
local miShowNative = createMenuItem(listPopup); miShowNative.Caption = "Show Native Code"
outputlist.PopupMenu = listPopup

-- bottom panel
local bottompanel = createPanel(inspectorform); bottompanel.Align = alBottom; bottompanel.Height = 40; bottompanel.BevelOuter = bvNone
local copyallbtn = createButton(bottompanel); copyallbtn.Caption = "Copy All Output";
copyallbtn.Left = 10; copyallbtn.Top = 5; copyallbtn.Width = 150; copyallbtn.Height = 30;
local genstructbtn = createButton(bottompanel); genstructbtn.Caption = "Generate CE Structure";
genstructbtn.Left = 170; genstructbtn.Top = 5; genstructbtn.Width = 180; genstructbtn.Height = 30;
local writevalsbtn = createButton(bottompanel); writevalsbtn.Caption = "Write Instance Values";
writevalsbtn.Left = genstructbtn.Left + genstructbtn.Width + 10; writevalsbtn.Top = 5; writevalsbtn.Width = 180; writevalsbtn.Height = 30;
writevalsbtn.Enabled = false
local writeStaticBtn = createButton(bottompanel); writeStaticBtn.Caption = "Write Static Values";
writeStaticBtn.Left = writevalsbtn.Left + writevalsbtn.Width + 10; writeStaticBtn.Top = 5; writeStaticBtn.Width = 180; writeStaticBtn.Height = 30;
writeStaticBtn.Enabled = false

-- store controls
inspectorform.classinput = classinput
inspectorform.outputlist = outputlist
inspectorform.lookupbtn = lookupbtn
inspectorform.instanceInput = instanceInput
inspectorform.showvalsbtn = showvalsbtn
inspectorform.showStaticBtn = showStaticBtn
inspectorform.invokeFormBtn = invokeFormBtn
inspectorform.copyallbtn = copyallbtn
inspectorform.genstructbtn = genstructbtn
inspectorform.writevalsbtn = writevalsbtn
inspectorform.writeStaticBtn = writeStaticBtn
inspectorform.filterInput = filterInput
inspectorform.filterBtn = filterBtn
inspectorform.listPopup = listPopup
inspectorform.miCopyLine = miCopyLine
inspectorform.miCopyDetails = miCopyDetails
inspectorform.miCopyAddress = miCopyAddress
inspectorform.miInvokePopup = miInvokePopup
inspectorform.miShowNative = miShowNative


lookupbtn.OnClick = function(sender)
  if not inspectorform or not inspectorform.Visible then return end
  local classname = inspectorform.classinput.Text:trim()
  if classname == "" then showMessage("pls enter a class name"); return end
  if not sender.Enabled then return end
  sender.Enabled = false; inspectorform.classinput.Enabled = false; inspectorform.showvalsbtn.Enabled = false; inspectorform.writevalsbtn.Enabled = false; inspectorform.writeStaticBtn.Enabled = false; inspectorform.showStaticBtn.Enabled = false; inspectorform.invokeFormBtn.Enabled = false -- disable invoke form btn too

  local inspectthread = createThread(function(thread)
      thread.synchronize(function() if inspectorform and inspectorform.Visible then inspectorform.outputlist.Items.Clear() end end)
      lookupclass(classname)
      thread.synchronize(function()
          if inspectorform and inspectorform.Visible then
             if pcall(function() sender.Enabled=true end) then end
             if pcall(function() inspectorform.classinput.Enabled=true end) then end
             if pcall(function() inspectorform.showvalsbtn.Enabled=true end) then end
             if pcall(function() inspectorform.invokeFormBtn.Enabled=true end) then end

          end
      end)
  end)
  inspectthread.FreeOnTerminate = true
end

showvalsbtn.OnClick = function(sender)
    if not inspectorform or not inspectorform.Visible then return end
    local addrStr = inspectorform.instanceInput.Text:trim()
    displayvalues(addrStr)
end

showStaticBtn.OnClick = function(sender)
    if not inspectorform or not inspectorform.Visible then return end
    displayStaticValues()
end

invokeFormBtn.OnClick = function(sender)
    if not inspectorform or not inspectorform.Visible then return end
    local item = inspectorform.outputlist.Selected
    local prefill = nil

    if item and type(item.Data) == 'table' and item.Data.type == "method" and type(item.Data.details) == 'table' and item.Data.details.methodPtr then
        prefill = item.Data.details
    end
    showManualInvokeDialog(prefill)
end

writevalsbtn.OnClick = function(sender)
    if not inspectorform or not inspectorform.Visible then return end
    writeChangedValues()
end

writeStaticBtn.OnClick = function(sender)
    if not inspectorform or not inspectorform.Visible then return end
    writeChangedStaticValues()
end

copyallbtn.OnClick = function()
    if inspectorform and inspectorform.outputlist then
        local sl = createStringlist()
        for i=0, inspectorform.outputlist.Items.Count-1 do
            local item = inspectorform.outputlist.Items[i]
            local cap = item.Caption or ""
            local sub1 = item.SubItems.Count > 0 and (item.SubItems[0] or "") or ""
            local sub2 = item.SubItems.Count > 1 and (item.SubItems[1] or "") or ""
            local sub3 = item.SubItems.Count > 2 and (item.SubItems[2] or "") or ""
            sl.Add(string.format("%s | %s | %s | %s", cap, sub1, sub2, sub3))
        end
        writeToClipboard(sl.Text)
        sl.destroy()
        print("listview output copied ta clipboard")
    end
end

genstructbtn.OnClick = function() generateCEStructure() end


listPopup.OnPopup = function(sender)
    local item = outputlist.Selected
    local itemData = item and item.Data or nil
    local isMethod = (itemData ~= nil and itemData.type == "method" and type(itemData.details) == 'table' and itemData.details.methodPtr)
    local isField = (itemData ~= nil and itemData.type == "field")
    local isEditable = (itemData ~= nil and (itemData.type == "editable_field" or itemData.type == "editable_static_field"))

    miCopyLine.Enabled = (item ~= nil)
    miCopyDetails.Enabled = (item ~= nil)
    miCopyAddress.Enabled = (item ~= nil and item.SubItems.Count > 1)

    miInvokePopup.Enabled = isMethod
    miShowNative.Enabled = isMethod

end

miCopyLine.OnClick = function(sender)
    local item = outputlist.Selected
    if item then
        local cap = item.Caption or ""
        local sub1 = item.SubItems.Count > 0 and (item.SubItems[0] or "") or ""
        local sub2 = item.SubItems.Count > 1 and (item.SubItems[1] or "") or ""
        local sub3 = item.SubItems.Count > 2 and (item.SubItems[2] or "") or ""
        local line = string.format("%s | %s | %s | %s", cap, sub1, sub2, sub3)
        writeToClipboard(line)
    end
end

miCopyDetails.OnClick = function(sender)
    local item = outputlist.Selected
    if item and item.SubItems.Count > 0 then writeToClipboard(item.SubItems[0] or "") end
end

miCopyAddress.OnClick = function(sender)
    local item = outputlist.Selected
    if item and item.SubItems.Count > 1 then writeToClipboard(item.SubItems[1] or "") end
end


miInvokePopup.OnClick = function(sender)
    local item = outputlist.Selected
    triggerInvoke(item)
end

miShowNative.OnClick = function(sender)
    local item = outputlist.Selected
    if item and item.Data and item.Data.type == "method" and item.Data.details then
        local methodData = item.Data.details
        print("tryna show native code for " .. methodData.name)
        if not tryconnect() then return end

        local compiledAddr = methodData.compiledAddr
        if not compiledAddr or compiledAddr == 0 then

             local ok, cAddr = pcall(mono_compile_method, methodData.methodPtr)
             if ok and cAddr and cAddr ~= 0 then compiledAddr = cAddr else compiledAddr = nil end
        end

        if compiledAddr and compiledAddr ~= 0 then
            print("native code @ 0x" .. string.format("%X", compiledAddr))
            local mv = getMemoryViewForm()
            mv.DisassemblerView.SelectedAddress = compiledAddr
            mv.show()
        else
            print("failed ta compile method or get address")
            showMessage("failed ta compile method or get address")
        end
    end
end



classinput.OnKeyDown = function(sender, key, shift)
  if inspectorform and inspectorform.lookupbtn and inspectorform.lookupbtn.Enabled and key == VK_RETURN then
    pcall(inspectorform.lookupbtn.OnClick, inspectorform.lookupbtn); return true
  end
  return false
end

inspectorform.OnClose = function(sender) print("enhanced class inspector form closin"); inspectorform = nil; return caFree end


local menuItem = createMenuItem(MainForm.Menu)
menuItem.Caption = "Unity Inspector"
menuItem.OnClick = inspectorform.show()
MainForm.Menu.Items.insert(MainForm.Menu.Items.Count - 1, menuItem)

print("enhanced class inspector script loaded enter a class name n click inspect")

