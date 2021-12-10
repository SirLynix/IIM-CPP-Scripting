--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      OpportunityLiu
-- @file        getinfo.lua
--

-- imports
import("core.base.option")
import("core.base.semver")
import("core.base.hashset")
import("core.project.config")
import("core.project.project")
import("core.platform.platform")
import("core.tool.compiler")
import("core.tool.linker")
import("core.cache.memcache")
import("core.cache.localcache")
import("lib.detect.find_tool")
import("private.action.run.make_runenvs")
import("private.action.require.install", {alias = "install_requires"})
import("actions.config.configheader", {alias = "generate_configheader", rootdir = os.programdir()})
import("actions.config.configfiles", {alias = "generate_configfiles", rootdir = os.programdir()})

-- escape special chars in msbuild file
function _escape(str)
    if not str then
        return nil
    end

    local map =
    {
         ["%"] = "%25" -- Referencing metadata
    ,    ["$"] = "%24" -- Referencing properties
    ,    ["@"] = "%40" -- Referencing item lists
    ,    ["'"] = "%27" -- Conditions and other expressions
    ,    [";"] = "%3B" -- List separator
    ,    ["?"] = "%3F" -- Wildcard character for file names in Include and Exclude attributes
    ,    ["*"] = "%2A" -- Wildcard character for use in file names in Include and Exclude attributes
    -- html entities
    ,    ["\""] = "&quot;"
    ,    ["<"] = "&lt;"
    ,    [">"] = "&gt;"
    ,    ["&"] = "&amp;"
    }

    return (string.gsub(str, "[%%%$@';%?%*\"<>&]", function (c) return assert(map[c]) end))
end

function _vs_arch(arch)
    if arch == 'x86' or arch == 'i386' then return "Win32" end
    if arch == 'x86_64' then return "x64" end
    if arch:startswith('arm64') then return "ARM64" end
    if arch:startswith('arm') then return "ARM" end
    return arch
end

function _make_dirs(dir)
    if dir == nil then
        return ""
    end
    if type(dir) == "string" then
        dir = path.translate(dir)
        if dir == "" then
            return ""
        end
        if path.is_absolute(dir) then
            if dir:startswith(project.directory()) then
                return path.join("$(XmakeProjectDir)", _escape(path.relative(dir, project.directory())))
            end
            return _escape(dir)
        end
        return path.join("$(XmakeProjectDir)", _escape(dir))
    end
    local r = {}
    for k, v in ipairs(dir) do
        r[k] = _make_dirs(v)
    end
    r = table.unique(r)
    return path.joinenv(r)
end

function _make_arrs(arr)
    if arr == nil then
        return ""
    end
    if type(arr) == "string" then
        return _escape(arr)
    end
    local r = {}
    for k, v in ipairs(arr) do
        r[k] = _make_arrs(v)
    end
    r = table.unique(r)
    return table.concat(r, ";")
end

-- get values from target
function _get_values_from_target(target, name)
    local values = table.wrap(target:get(name))
    table.join2(values, target:get_from_opts(name))
    table.join2(values, target:get_from_pkgs(name))
    table.join2(values, target:get_from_deps(name, {interface = true}))
    return table.unique(values)
end

-- make target info
function _make_targetinfo(mode, arch, target)

    -- init target info
    local targetinfo =
    {
        mode = mode
    ,   arch = arch
    ,   plat = config.get("plat")
    ,   vsarch = _vs_arch(arch)
    ,   sdkver = config.get("vs_sdkver")
    }

    -- write only if not default
    -- use target:get("xxx") rather than target:xxx()

    -- save target kind
    targetinfo.kind          = target:kind()

    -- is default?
    targetinfo.default       = tostring(target:is_default())

    -- save target file
    targetinfo.basename      = _escape(target:get("basename"))
    targetinfo.filename      = _escape(target:get("filename"))

    -- save dirs
    targetinfo.targetdir     = _make_dirs(target:get("targetdir"))
    targetinfo.buildir       = _make_dirs(config.get("buildir"))
    targetinfo.rundir        = _make_dirs(target:get("rundir"))
    targetinfo.configdir     = _make_dirs(os.getenv("XMAKE_CONFIGDIR"))
    targetinfo.configfiledir = _make_dirs(target:get("configdir"))
    targetinfo.includedirs   = _make_dirs(table.join(_get_values_from_target(target, "includedirs") or {}, _get_values_from_target(target, "sysincludedirs")))
    targetinfo.linkdirs      = _make_dirs(_get_values_from_target(target, "linkdirs"))
    targetinfo.sourcedirs    = _make_dirs(_get_values_from_target(target, "values.project.vsxmake.sourcedirs"))
    targetinfo.pcheaderfile  = target:pcheaderfile("cxx") or target:pcheaderfile("c")

    -- save defines
    targetinfo.defines       = _make_arrs(_get_values_from_target(target, "defines"))

    -- save languages
    targetinfo.languages     = _make_arrs(_get_values_from_target(target, "languages"))
    if targetinfo.languages then
        -- fix c++17 to cxx17 for Xmake.props
        targetinfo.languages = targetinfo.languages:replace("c++", "cxx", {plain = true})
    end

    -- save subsystem
    local linkflags = linker.linkflags(target:kind(), target:sourcekinds(), {target = target})
    for _, linkflag in ipairs(linkflags) do
        if linkflag:lower():find("[%-/]subsystem:windows") then
            targetinfo.subsystem = "windows"
        end
    end
    if not targetinfo.subsystem then
        targetinfo.subsystem = "console"
    end

    -- save runenvs
    local runenvs = {}
    local addrunenvs, setrunenvs = make_runenvs(target)
    for k, v in pairs(target:pkgenvs()) do
        addrunenvs = addrunenvs or {}
        addrunenvs[k] = table.join(table.wrap(addrunenvs[k]), path.splitenv(v))
    end
    for _, dep in ipairs(target:orderdeps()) do
        for k, v in pairs(dep:pkgenvs()) do
            addrunenvs = addrunenvs or {}
            addrunenvs[k] = table.join(table.wrap(addrunenvs[k]), path.splitenv(v))
        end
    end
    for k, v in pairs(addrunenvs) do
        if k:upper() == "PATH" then
            runenvs[k] = format("%s;$([System.Environment]::GetEnvironmentVariable('%s'))", _make_dirs(v), k)
        else
            runenvs[k] = format("%s;$([System.Environment]::GetEnvironmentVariable('%s'))", path.joinenv(v), k)
        end
    end
    for k, v in pairs(setrunenvs) do
        if #v == 1 then
            v = v[1]
            if path.is_absolute(v) and v:startswith(project.directory()) then
                runenvs[k] = _make_dirs(v)
            else
                runenvs[k] = v[1]
            end
        else
            runenvs[k] = path.joinenv(v)
        end
    end
    local runenvstr = {}
    for k, v in pairs(runenvs) do
        table.insert(runenvstr, k .. "=" .. v)
    end
    targetinfo.runenvs = table.concat(runenvstr, "\n")

    -- use mfc? save the mfc runtime kind
    if target:rule("win.sdk.mfc.shared_app") or target:rule("win.sdk.mfc.shared") then
        targetinfo.mfckind = "Dynamic"
    elseif target:rule("win.sdk.mfc.static_app") or target:rule("win.sdk.mfc.static") then
        targetinfo.mfckind = "Static"
    end

    -- use cuda? save the cuda runtime version
    if target:rule("cuda") then
        local nvcc = find_tool("nvcc", { version = true })
        local ver = semver.new(nvcc.version)
        targetinfo.cudaver = ver:major() .. "." .. ver:minor()
    end

    -- ok
    return targetinfo
end

function _make_vsinfo_modes()
    local vsinfo_modes = {}
    local modes = option.get("modes")
    if modes then
        if not modes:find("\"") then
            modes = modes:gsub(",", path.envsep())
        end
        for _, mode in ipairs(path.splitenv(modes)) do
            table.insert(vsinfo_modes, mode:trim())
        end
    else
        vsinfo_modes = project.modes()
    end
    if not vsinfo_modes or #vsinfo_modes == 0 then
        vsinfo_modes = { config.mode() }
    end
    return vsinfo_modes
end

function _make_vsinfo_archs()
    local vsinfo_archs = {}
    local archs = option.get("archs")
    if archs then
        if not archs:find("\"") then
            archs = archs:gsub(",", path.envsep())
        end
        for _, arch in ipairs(path.splitenv(archs)) do
            table.insert(vsinfo_archs, arch:trim())
        end
    else
        -- we use it first if global set_arch("xx") is setted in xmake.lua
        vsinfo_archs = project.get("target.arch")
        if not vsinfo_archs then
            -- for set_allowedarchs()
            local allowed_archs = project.allowed_archs(config.plat())
            if allowed_archs then
                vsinfo_archs = allowed_archs:to_array()
            end
        end
        if not vsinfo_archs then
            vsinfo_archs = platform.archs()
        end
    end
    if not vsinfo_archs or #vsinfo_archs == 0 then
        vsinfo_archs = { config.arch() }
    end
    return vsinfo_archs
end

function _make_vsinfo_groups()
    local groups = {}
    local group_deps = {}
    for targetname, target in pairs(project.targets()) do
        if not target:is_phony() then
            local group_path = target:get("group")
            if group_path then
                local group_name = path.filename(group_path)
                local group_names = path.split(group_path)
                for idx, name in ipairs(group_names) do
                    local group = groups["group." .. name] or {}
                    group.group = name
                    group.group_id = hash.uuid4(name)
                    if idx > 1 then
                        group_deps["group_dep." .. name] = {current_id = group.group_id, parent_id = hash.uuid4(group_names[idx - 1])}
                    end
                    groups["group." .. name] = group
                end
                group_deps["group_dep.target." .. targetname] = {current_id = hash.uuid4(targetname), parent_id = groups["group." .. group_name].group_id}
            end
        end
    end
    return groups, group_deps
end

-- config target
function _config_target(target)
    for _, rule in ipairs(target:orderules()) do
        local on_config = rule:script("config")
        if on_config then
            on_config(target)
        end
    end
    local on_config = target:script("config")
    if on_config then
        on_config(target)
    end
end

-- config targets
function _config_targets()
    for _, target in ipairs(project.ordertargets()) do
        if target:is_enabled() then
            _config_target(target)
        end
    end
end

-- make vstudio project
function main(outputdir, vsinfo)

    -- enter project directory
    local oldir = os.cd(project.directory())

    -- init solution directory
    vsinfo.solution_dir = path.absolute(path.join(outputdir, "vsxmake" .. vsinfo.vstudio_version))
    vsinfo.programdir = _make_dirs(xmake.programdir())
    vsinfo.projectdir = project.directory()
    vsinfo.sln_projectfile = path.relative(project.rootfile(), vsinfo.solution_dir)
    local projectfile = path.filename(project.rootfile())
    vsinfo.slnfile = path.filename(project.directory())
    -- write only if not default
    if projectfile ~= "xmake.lua" then
        vsinfo.projectfile = projectfile
        vsinfo.slnfile = path.basename(projectfile)
    end

    vsinfo.xmake_info = format("xmake version %s", xmake.version())
    vsinfo.solution_id = hash.uuid4(project.directory() .. vsinfo.solution_dir)
    vsinfo.vs_version = vsinfo.project_version .. ".0"

    -- init modes
    vsinfo.modes = _make_vsinfo_modes()

    -- init archs
    vsinfo.archs = _make_vsinfo_archs()

    -- init groups
    local groups, group_deps = _make_vsinfo_groups()
    vsinfo.groups            = table.keys(groups)
    vsinfo.group_deps        = table.keys(group_deps)
    vsinfo._groups           = groups
    vsinfo._group_deps       = group_deps

    -- init config flags
    local flags = {}
    for k, v in pairs(localcache.get("config", "options")) do
        if k ~= "plat" and k ~= "mode" and k ~= "arch" and k ~= "clean" and k ~= "buildir" then
            table.insert(flags, "--" .. k .. "=" .. tostring(v))
        end
    end
    vsinfo.configflags = os.args(flags)

    -- load targets
    local targets = {}
    vsinfo._arch_modes = {}
    for _, mode in ipairs(vsinfo.modes) do
        vsinfo._arch_modes[mode] = {}
        for _, arch in ipairs(vsinfo.archs) do
            vsinfo._arch_modes[mode][arch] = { mode = mode, arch = arch }

            -- trace
            print("checking for %s.%s ...", mode, arch)

            -- reload config, project and platform
            -- modify config
            config.set("as", nil, {force = true}) -- force to re-check as for ml/ml64
            config.set("mode", mode, {readonly = true, force = true})
            config.set("arch", arch, {readonly = true, force = true})

            -- clear all options
            for _, opt in ipairs(project.options()) do
                opt:clear()
            end

            -- clear cache
            memcache.clear()
            localcache.clear("config")
            localcache.clear("detect")
            localcache.clear("option")
            localcache.clear("package")
            localcache.clear("toolchain")

            -- check platform
            platform.load(config.plat(), arch):check()

            -- check project options
            project.check()

            -- install and update requires
            install_requires()

            -- config targets
            _config_targets()

            -- update config files
            generate_configfiles()
            generate_configheader()

            -- ensure to enter project directory
            os.cd(project.directory())

            -- save targets
            for targetname, target in pairs(project.targets()) do
                if not target:is_phony() then

                    -- make target with the given mode and arch
                    targets[targetname] = targets[targetname] or {}
                    local _target = targets[targetname]

                    -- init target info
                    _target.target = targetname
                    _target.vcxprojdir = path.join(vsinfo.solution_dir, targetname)
                    _target.target_id = hash.uuid4(targetname)
                    _target.kind = target:kind()
                    _target.scriptdir = path.relative(target:scriptdir(), _target.vcxprojdir)
                    _target.projectdir = path.relative(project.directory(), _target.vcxprojdir)
                    local targetdir = target:get("targetdir")
                    if targetdir then _target.targetdir = path.relative(targetdir, _target.vcxprojdir) end
                    _target._targets = _target._targets or {}
                    _target._targets[mode] = _target._targets[mode] or {}
                    local targetinfo = _make_targetinfo(mode, arch, target)
                    _target._targets[mode][arch] = targetinfo
                    _target.sdkver = targetinfo.sdkver

                    -- save all sourcefiles and headerfiles
                    _target.sourcefiles = table.unique(table.join(_target.sourcefiles or {}, (target:sourcefiles())))
                    _target.headerfiles = table.unique(table.join(_target.headerfiles or {}, (target:headerfiles())))

                    -- save deps
                    _target.deps = table.unique(table.join(_target.deps or {}, table.keys(target:deps()), nil))
                end
            end
        end
    end
    os.cd(oldir)
    for _, target in pairs(targets) do
        target._paths = {}
        local dirs = {}
        local root = project.directory()
        target.sourcefiles = table.imap(target.sourcefiles, function(_, v) return path.relative(v, root) end)
        target.headerfiles = table.imap(target.headerfiles, function(_, v) return path.relative(v, root) end)
        for _, f in ipairs(table.join(target.sourcefiles, target.headerfiles)) do
            local dir = path.directory(f)
            target._paths[f] =
            {
                path = _escape(f),
                dir = _escape(dir)
            }
            while dir ~= "." do
                if not dirs[dir] then
                    dirs[dir] =
                    {
                        dir = _escape(dir),
                        dir_id = hash.uuid4(dir)
                    }
                end
                dir = path.directory(dir)
            end
        end
        target._dirs = dirs
        target.dirs = table.keys(dirs)
        target._deps = {}
        for _, v in ipairs(target.deps) do
            target._deps[v] = targets[v]
        end
    end

    -- we need set startup project for default or binary target
    -- @see https://github.com/xmake-io/xmake/issues/1249
    local targetnames = {}
    for targetname, target in pairs(project.targets()) do
        if not target:is_phony() then
            if target:get("default") == true then
                table.insert(targetnames, 1, targetname)
            elseif target:is_binary() then
                local first_target = targetnames[1] and project.target(targetnames[1])
                if not first_target or first_target:is_default() then
                    table.insert(targetnames, 1, targetname)
                else
                    table.insert(targetnames, targetname)
                end
            else
                table.insert(targetnames, targetname)
            end
        end
    end
    vsinfo.targets = targetnames
    vsinfo._targets = targets
    return vsinfo
end
