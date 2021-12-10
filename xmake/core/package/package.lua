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
-- See the License for the specific package governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        package.lua
--

-- define module
local package   = {}
local _instance = {}

-- load modules
local os             = require("base/os")
local io             = require("base/io")
local path           = require("base/path")
local utils          = require("base/utils")
local table          = require("base/table")
local global         = require("base/global")
local semver         = require("base/semver")
local option         = require("base/option")
local hashset        = require("base/hashset")
local scopeinfo      = require("base/scopeinfo")
local interpreter    = require("base/interpreter")
local memcache       = require("cache/memcache")
local toolchain      = require("tool/toolchain")
local sandbox        = require("sandbox/sandbox")
local config         = require("project/config")
local policy         = require("project/policy")
local platform       = require("platform/platform")
local platform_menu  = require("platform/menu")
local language       = require("language/language")
local language_menu  = require("language/menu")
local sandbox        = require("sandbox/sandbox")
local sandbox_os     = require("sandbox/modules/os")
local sandbox_module = require("sandbox/modules/import/core/sandbox/module")

-- new an instance
function _instance.new(name, info, opt)
    opt = opt or {}
    local instance = table.inherit(_instance)
    instance._NAME      = name
    instance._INFO      = info
    instance._REPO      = opt.repo
    instance._SCRIPTDIR = opt.scriptdir and path.absolute(opt.scriptdir)
    return instance
end

-- get the package name
function _instance:name()
    return self._NAME
end

-- get the type: package
function _instance:type()
    return "package"
end

-- get the package configure
function _instance:get(name)

    -- get it from info first
    local value = self._INFO:get(name)
    if value ~= nil then
        return value
    end
end

-- set the value to the package info
function _instance:set(name, ...)
    self._INFO:apival_set(name, ...)
end

-- add the value to the package info
function _instance:add(name, ...)
    self._INFO:apival_add(name, ...)
end

-- get the extra configuration
function _instance:extraconf(name, item, key)
    return self._INFO:extraconf(name, item, key)
end

-- set the extra configuration
function _instance:extraconf_set(name, item, key, value)
    return self._INFO:extraconf_set(name, item, key, value)
end

-- get the package license
function _instance:license()
    return self:get("license")
end

-- get the package description
function _instance:description()
    return self:get("description")
end

-- get the platform of package
function _instance:plat()
    -- @note we uses os.host() instead of them for the binary package
    if self:is_binary() then
        return os.subhost()
    end
    local requireinfo = self:requireinfo()
    if requireinfo and requireinfo.plat then
        return requireinfo.plat
    end
    return package.targetplat()
end

-- get the architecture of package
function _instance:arch()
    -- @note we uses os.arch() instead of them for the binary package
    if self:is_binary() then
        return os.subarch()
    end
    return self:targetarch()
end

-- get the target os
function _instance:targetos()
    local requireinfo = self:requireinfo()
    if requireinfo and requireinfo.targetos then
        return requireinfo.targetos
    end
    return config.get("target_os") or platform.os()
end

-- get the target architecture
function _instance:targetarch()
    local requireinfo = self:requireinfo()
    if requireinfo and requireinfo.arch then
        return requireinfo.arch
    end
    return package.targetarch()
end

-- get the build mode
function _instance:mode()
    return self:is_debug() and "debug" or "release"
end

-- get the repository of this package
function _instance:repo()
    return self._REPO
end

-- the current platform is belong to the given platforms?
function _instance:is_plat(...)
    local plat = self:plat()
    for _, v in ipairs(table.join(...)) do
        if v and plat == v then
            return true
        end
    end
end

-- the current architecture is belong to the given architectures?
function _instance:is_arch(...)
    local arch = self:arch()
    for _, v in ipairs(table.join(...)) do
        if v and arch:find("^" .. v:gsub("%-", "%%-") .. "$") then
            return true
        end
    end
end

-- the current platform is belong to the given target os?
function _instance:is_targetos(...)
    local targetos = self:targetos()
    for _, v in ipairs(table.join(...)) do
        if v and targetos == v then
            return true
        end
    end
end

-- the current architecture is belong to the given target architectures?
function _instance:is_targetarch(...)
    local targetarch = self:targetarch()
    for _, v in ipairs(table.join(...)) do
        if v and targetarch:find("^" .. v:gsub("%-", "%%-") .. "$") then
            return true
        end
    end
end

-- get the package alias
function _instance:alias()
    local requireinfo = self:requireinfo()
    if requireinfo then
        return requireinfo.alias
    end
end

-- get external package sources, e.g. pkgconfig::xxx, system::xxx, conan::xxx
-- we can use it to improve self:fetch() for find_package
function _instance:extsources()
    return self:get("extsources")
end

-- get urls
function _instance:urls()
    return self._URLS or table.wrap(self:get("urls"))
end

-- get urls
function _instance:urls_set(urls)
    self._URLS = urls
end

-- get the alias of url, @note need raw url
function _instance:url_alias(url)
    return self:extraconf("urls", url, "alias")
end

-- get the version filter of url, @note need raw url
function _instance:url_version(url)
    return self:extraconf("urls", url, "version")
end

-- get the excludes list of url for the archive extractor, @note need raw url
function _instance:url_excludes(url)
    return self:extraconf("urls", url, "excludes")
end

-- set artifacts info
function _instance:artifacts_set(artifacts_info)
    local versions = self:get("versions")
    if versions then
        -- we switch to urls of the precompiled artifacts
        self:urls_set(table.wrap(artifacts_info.urls))
        versions[self:version_str()] = artifacts_info.sha256
        self:set("install", function (package)
            sandbox_module.import("lib.detect.find_path")
            local rootdir = find_path("manifest.txt", path.join(os.curdir(), "*", "*", "*"))
            if not rootdir then
                os.raise("package(%s): manifest.txt not found when installing artifacts!", package:displayname())
            end
            os.cp(path.join(rootdir, "*"), package:installdir())
            local manifest = package:manifest_load()
            if not manifest then
                os.raise("package(%s): load manifest.txt failed when installing artifacts!", package:displayname())
            end
            if manifest.vars then
                for k, v in pairs(manifest.vars) do
                    package:set(k, v)
                end
            end
            if manifest.envs then
                local envs = self:envs()
                for k, v in pairs(manifest.envs) do
                    envs[k] = v
                end
            end
        end)
        self._IS_PRECOMPILED = true
    end
end

-- is this package built?
function _instance:is_built()
    return not self._IS_PRECOMPILED
end

-- get the given dependent package
function _instance:dep(name)
    local deps = self:deps()
    if deps then
        return deps[name]
    end
end

-- get deps
function _instance:deps()
    return self._DEPS
end

-- get order deps
function _instance:orderdeps()
    return self._ORDERDEPS
end

-- get plain deps
function _instance:plaindeps()
    return self._PLAINDEPS
end

-- get link deps
function _instance:linkdeps()
    return self._LINKDEPS
end

-- get parents
function _instance:parents()
    return self._PARENTS
end

-- add parents
function _instance:parents_add(...)
    for _, parent in ipairs({...}) do
        self._PARENTS = self._PARENTS or {}
        self._PARENTS[parent:name()] = parent
    end
end

-- get hash of the source package for the url_alias@version_str
function _instance:sourcehash(url_alias)
    local versions    = self:get("versions")
    local version_str = self:version_str()
    if versions and version_str then
        local sourcehash = nil
        if url_alias then
            sourcehash = versions[url_alias .. ":" ..version_str]
        end
        if not sourcehash then
            sourcehash = versions[version_str]
        end
        if sourcehash then
            sourcehash = sourcehash:lower()
        end
        return sourcehash
    end
end

-- get revision(commit, tag, branch) of the url_alias@version_str, only for git url
function _instance:revision(url_alias)
    local revision = self:sourcehash(url_alias)
    if revision and #revision <= 40 then
        -- it will be sha256 of tar/gz file, not commit number if longer than 40 characters
        return revision
    end
end

-- get the package policy
function _instance:policy(name)
    local policies = self._POLICIES
    if not policies then
        policies = self:get("policy")
        self._POLICIES = policies
        if policies then
            local defined_policies = policy.policies()
            for name, _ in pairs(policies) do
                if not defined_policies[name] then
                    utils.warning("unknown policy(%s), please run `xmake l core.project.policy.policies` if you want to all policies", name)
                end
            end
        end
    end
    return policy.check(name, policies and policies[name])
end

-- get the package kind
--
-- - binary
-- - toolchain (is also binary)
-- - library(default)
--
function _instance:kind()
    local kind = self:get("kind")
    if not kind then
        local requireinfo = self:requireinfo()
        if requireinfo then
            kind = requireinfo.kind
        end
    end
    return kind
end

-- is binary package?
function _instance:is_binary()
    return self:kind() == "binary" or self:kind() == "toolchain"
end

-- is toolchain package?
function _instance:is_toolchain()
    return self:kind() == "toolchain"
end

-- is library package?
function _instance:is_library()
    return self:kind() == nil or self:kind() == "library"
end

-- is header only?
function _instance:is_headeronly()
    return self:is_library() and self:extraconf("kind", "library", "headeronly")
end

-- is top level? user top requires in xmake.lua
function _instance:is_toplevel()
    local requireinfo = self:requireinfo()
    return requireinfo and requireinfo.is_toplevel
end

-- is the system package?
function _instance:is_system()
    return self._is_system
end

-- is the third-party package? e.g. brew::pcre2/libpcre2-8, conan::OpenSSL/1.0.2n@conan/stable
-- we need install and find package by third-party package manager directly
--
function _instance:is_thirdparty()
    return self._is_thirdparty
end

-- is fetch only?
function _instance:is_fetchonly()
    return self:get("fetch") and not self:get("install")
end

-- is optional package?
function _instance:is_optional()
    local requireinfo = self:requireinfo()
    return requireinfo and requireinfo.optional or false
end

-- is private package?
function _instance:is_private()
    local requireinfo = self:requireinfo()
    return requireinfo and requireinfo.private or false
end

-- verify sha256sum and versions?
function _instance:is_verify()
    local requireinfo = self:requireinfo()
    local verify = requireinfo and requireinfo.verify
    if verify == nil then
        verify = true
    end
    return verify
end

-- is debug package?
function _instance:is_debug()
    return self:config("debug")
end

-- is the supported package?
function _instance:is_supported()
    -- attempt to get the install script with the current plat/arch
    return self:script("install") ~= nil
end

-- support parallelize for installation?
function _instance:is_parallelize()
    return self:get("parallelize") ~= false
end

-- is local embed package?
-- we install directly from the local source code instead of downloading it remotely
function _instance:is_embed()
    return self:get("sourcedir") and #self:urls() == 0 and self:script("install")
end

-- is local package?
-- we will use local installdir and cachedir in current project
function _instance:is_local()
    return self:is_embed()
end

-- is debug package? (deprecated)
function _instance:debug()
    return self:is_debug()
end

-- is cross-compilation?
function _instance:is_cross()
    if self:is_plat("windows", "mingw") and os.host() == "windows" then
        -- always false on windows host
        return false
    end
    if not self:is_plat(os.host()) and not self:is_plat(os.subhost()) then
        return true
    end
    if not self:is_arch(os.arch()) and not self:is_arch(os.subarch()) then
        return true
    end
end

-- get the filelock of the whole package directory
function _instance:filelock()
    local filelock = self._FILELOCK
    if filelock == nil then
        filelock = io.openlock(path.join(self:cachedir(), "package.lock"))
        if not filelock then
            os.raise("cannot create filelock for package(%s)!", self:name())
        end
        self._FILELOCK = filelock
    end
    return filelock
end

-- lock the whole package
function _instance:lock(opt)
    if self:filelock():trylock(opt) then
        return true
    else
        utils.cprint("${color.warning}package(%s) is being accessed by other processes, please waiting!", self:name())
    end
    local ok, errors = self:filelock():lock(opt)
    if not ok then
        os.raise(errors)
    end
end

-- unlock the whole package
function _instance:unlock()
    local ok, errors = self:filelock():unlock()
    if not ok then
        os.raise(errors)
    end
end

-- get the source directory
function _instance:sourcedir()
    return self:get("sourcedir")
end

-- get the build directory
function _instance:buildir()
    local buildir = self._BUILDIR
    if not buildir then
        if self:is_local() then
            local name = self:name():lower():gsub("::", "_")
            local rootdir = path.join(config.buildir({absolute = true}), ".packages", name:sub(1, 1):lower(), name, self:version_str())
            buildir = path.join(rootdir, "cache", "build_" .. self:buildhash():sub(1, 8))
        else
            buildir = "build_" .. self:buildhash():sub(1, 8)
        end
        self._BUILDIR = buildir
    end
    return buildir
end

-- get the cached directory of this package
function _instance:cachedir()
    local cachedir = self._CACHEDIR
    if not cachedir then
        cachedir = self:get("cachedir")
        if not cachedir then
            local name = self:name():lower():gsub("::", "_")
            if self:is_local() then
                cachedir = path.join(config.buildir({absolute = true}), ".packages", name:sub(1, 1):lower(), name, self:version_str(), "cache")
            else
                cachedir = path.join(package.cachedir(), name:sub(1, 1):lower(), name, self:version_str())
            end
        end
        self._CACHEDIR = cachedir
    end
    return cachedir
end

-- get the installed directory of this package
function _instance:installdir(...)
    local installdir = self._INSTALLDIR
    if not installdir then
        installdir = self:get("installdir")
        if not installdir then
            local name = self:name():lower():gsub("::", "_")
            if self:is_local() then
                installdir = path.join(config.buildir({absolute = true}), ".packages", name:sub(1, 1):lower(), name)
            else
                installdir = path.join(package.installdir(), name:sub(1, 1):lower(), name)
            end
            if self:version_str() then
                installdir = path.join(installdir, self:version_str())
            end
            installdir = path.join(installdir, self:buildhash())
        end
        self._INSTALLDIR = installdir
    end
    local dir = path.join(installdir, ...)
    if not os.isdir(dir) then
        os.mkdir(dir)
    end
    return dir
end

-- get the script directory
function _instance:scriptdir()
    return self._SCRIPTDIR
end

-- get the references info of this package
function _instance:references()
    local references_file = path.join(self:installdir(), "references.txt")
    if os.isfile(references_file) then
        local references, errors = io.load(references_file)
        if not references then
            os.raise(errors)
        end
        return references
    end
end

-- get the manifest file of this package
function _instance:manifest_file()
    return path.join(self:installdir(), "manifest.txt")
end

-- load the manifest file of this package
function _instance:manifest_load()
    local manifest = self._MANIFEST
    if not manifest then
        local manifest_file = self:manifest_file()
        if os.isfile(manifest_file) then
            local errors = nil
            manifest, errors = io.load(manifest_file)
            if not manifest then
                os.raise(errors)
            end
            self._MANIFEST = manifest
        end
    end
    return manifest
end

-- save the manifest file of this package
function _instance:manifest_save()

    -- make manifest
    local manifest       = {}
    manifest.name        = self:name()
    manifest.license     = self:license()
    manifest.description = self:description()
    manifest.version     = self:version_str()
    manifest.kind        = self:kind()
    manifest.plat        = self:plat()
    manifest.arch        = self:arch()
    manifest.mode        = self:mode()
    manifest.configs     = self:configs()
    manifest.envs        = self:envs()

    -- save enabled link deps
    if self:linkdeps() then
        manifest.linkdeps = {}
        for _, dep in ipairs(self:linkdeps()) do
            if dep:exists() then
                table.insert(manifest.linkdeps, dep:name())
            end
        end
    end

    -- save variables
    local vars = {}
    local apis = language.apis()
    for _, apiname in ipairs(table.join(apis.values, apis.paths)) do
        if apiname:startswith("package.add_") or apiname:startswith("package.set_")  then
            local name = apiname:sub(13)
            local value = self:get(name)
            if value ~= nil then
                vars[name] = value
            end
        end
    end
    manifest.vars = vars

    -- save repository
    local repo = self:repo()
    if repo then
        manifest.repo        = {}
        manifest.repo.name   = repo:name()
        manifest.repo.url    = repo:url()
        manifest.repo.branch = repo:branch()
        manifest.repo.commit = repo:commit()
    end

    -- save manifest
    local ok, errors = io.save(self:manifest_file(), manifest)
    if not ok then
        os.raise(errors)
    end
end

-- get the exported environments
function _instance:envs()
    local envs = self._ENVS
    if not envs then
        envs = {}
        if self:is_binary() or self:is_plat("windows", "mingw") then -- bin/*.dll for windows
            envs.PATH = {"bin"}
        end
        -- add LD_LIBRARY_PATH to load *.so directory
        if os.host() ~= "windows" and self:is_plat(os.host()) and self:is_arch(os.arch()) then
            envs.LD_LIBRARY_PATH = {"lib"}
            if os.host() == "macosx" then
                envs.DYLD_LIBRARY_PATH = {"lib"}
            end
        end
        self._ENVS = envs
    end
    return envs
end

-- load the package environments from the manifest
function _instance:envs_load()
    local manifest = self:manifest_load()
    if manifest then
        local envs = self:envs()
        for name, values in pairs(manifest.envs) do
            envs[name] = values
        end
    end
end

-- enter the package environments
function _instance:envs_enter()
    local installdir = self:installdir()
    for name, values in pairs(self:envs()) do
        if name == "PATH" or name == "LD_LIBRARY_PATH" or name == "DYLD_LIBRARY_PATH" then
            for _, value in ipairs(values) do
                if path.is_absolute(value) then
                    os.addenv(name, value)
                else
                    os.addenv(name, path.join(installdir, value))
                end
            end
        else
            os.addenv(name, table.unpack(table.wrap(values)))
        end
    end
end

-- get the given environment variable
function _instance:getenv(name)
    return self:envs()[name]
end

-- set the given environment variable
function _instance:setenv(name, ...)
    self:envs()[name] = {...}
end

-- add the given environment variable
function _instance:addenv(name, ...)
    self:envs()[name] = table.join(self:envs()[name] or {}, ...)
end

-- get the given build environment variable
function _instance:build_getenv(name)
    return self:build_envs(true)[name]
end

-- set the given build environment variable
function _instance:build_setenv(name, ...)
    self:build_envs(true)[name] = table.unwrap({...})
end

-- add the given build environment variable
function _instance:build_addenv(name, ...)
    self:build_envs(true)[name] = table.unwrap(table.join(table.wrap(self:build_envs()[name]), ...))
end

-- get the build environments
function _instance:build_envs(lazy_loading)
    local build_envs = self._BUILD_ENVS
    if build_envs == nil then
        -- lazy loading the given environment value and cache it
        build_envs = {}
        setmetatable(build_envs, { __index = function (tbl, key)
            local value = config.get(key)
            if value == nil then
                value = self:tool(key)
            end
            value = table.unique(table.join(table.wrap(value), table.wrap(self:config(key)), self:toolconfig(key)))
            if #value > 0 then
                value = table.unwrap(value)
                rawset(tbl, key, value)
                return value
            end
            return rawget(tbl, key)
        end})

        -- save build environments
        self._BUILD_ENVS = build_envs
    end

    -- force to load all values if need
    if not lazy_loading then
        for _, opt in ipairs(table.join(language_menu.options("config"), platform_menu.options("config"))) do
            local optname = opt[2]
            if type(optname) == "string" then
                -- we need only index it to force load it's value
                local value = build_envs[optname]
            end
        end
    end
    return build_envs
end

-- get toolchains
function _instance:toolchains()
    local toolchains = self._TOOLCHAINS
    if toolchains == nil then
        local project = package._project()
        for _, name in ipairs(table.wrap(self:config("toolchains"))) do
            local toolchain_opt = project and project.extraconf("target.toolchains", name) or {}
            toolchain_opt.plat = self:plat()
            toolchain_opt.arch = self:arch()
            local toolchain_inst, errors = toolchain.load(name, toolchain_opt)
            if not toolchain_inst and project then
                toolchain_inst = project.toolchain(name, toolchain_opt)
            end
            if not toolchain_inst then
                os.raise(errors)
            end
            toolchains = toolchains or {}
            table.insert(toolchains, toolchain_inst)
        end
        self._TOOLCHAINS = toolchains or false
    end
    return toolchains or nil
end

-- get the program and name of the given tool kind
function _instance:tool(toolkind)
    if self:toolchains() then
        return toolchain.tool(self:toolchains(), toolkind, {cachekey = "package", plat = self:plat(), arch = self:arch()})
    else
        return platform.tool(toolkind, self:plat(), self:arch())
    end
end

-- get tool configuration from the toolchains
function _instance:toolconfig(name)
    if self:toolchains() then
        return toolchain.toolconfig(self:toolchains(), name, {cachekey = "package", plat = self:plat(), arch = self:arch()})
    else
        return platform.toolconfig(name, self:plat(), self:arch())
    end
end

-- has the given tool for the current package?
--
-- e.g.
--
-- if package:has_tool("cc", "clang", "gcc") then
--    ...
-- end
function _instance:has_tool(toolkind, ...)
    local _, toolname = self:tool(toolkind)
    for _, v in ipairs(table.join(...)) do
        if v and toolname:find("^" .. v:gsub("%-", "%%-") .. "$") then
            return true
        end
    end
end

-- get the user private data
function _instance:data(name)
    return self._DATA and self._DATA[name] or nil
end

-- set user private data
function _instance:data_set(name, data)
    self._DATA = self._DATA or {}
    self._DATA[name] = data
end

-- add user private data
function _instance:data_add(name, data)
    self._DATA = self._DATA or {}
    self._DATA[name] = table.unwrap(table.join(self._DATA[name] or {}, data))
end

-- get the downloaded original file
function _instance:originfile()
    return self._ORIGINFILE
end

-- set the downloaded original file
function _instance:originfile_set(filepath)
    self._ORIGINFILE = filepath
end

-- get versions
function _instance:versions()
    if self._VERSIONS == nil then
        local versions = {}
        for version, _ in pairs(table.wrap(self:get("versions"))) do
            -- remove the url alias prefix if exists
            local pos = version:find(':', 1, true)
            if pos then
                version = version:sub(pos + 1, -1)
            end
            table.insert(versions, version)
        end
        self._VERSIONS = table.unique(versions)
    end
    return self._VERSIONS
end

-- get the version
function _instance:version()
    return self._VERSION
end

-- get the version string
function _instance:version_str()
    if self:is_thirdparty() then
        local requireinfo = self:requireinfo()
        if requireinfo then
            return requireinfo.version
        end
    end
    return self._VERSION_STR
end

-- set the version, source: branch, tag, version
function _instance:version_set(version, source)

    -- save the semver version
    local sv = semver.new(version)
    if sv then
        self._VERSION = sv
    end

    -- save branch and tag
    if source == "branch" then
        self._BRANCH = version
    elseif source == "tag" then
        self._TAG = version
    end

    -- save version string
    self._VERSION_STR = version
end

-- get branch version
function _instance:branch()
    return self._BRANCH
end

-- get tag version
function _instance:tag()
    return self._TAG
end

-- is git ref?
function _instance:gitref()
    return self:branch() or self:tag()
end

-- get the require info
function _instance:requireinfo()
    return self._REQUIREINFO
end

-- set the require info
function _instance:requireinfo_set(requireinfo)
    self._REQUIREINFO = requireinfo
end

-- get label
function _instance:label()
    local requireinfo = self:requireinfo()
    return requireinfo and requireinfo.label
end

-- get the display name
function _instance:displayname()
    return self._DISPLAYNAME
end

-- set the display name
function _instance:displayname_set(displayname)
    self._DISPLAYNAME = displayname
end

-- get the given configuration value of package
function _instance:config(name)
    local configs = self:configs()
    if configs then
        return configs[name]
    end
end

-- set configuration value
function _instance:config_set(name, value)
    local configs = self:configs()
    if configs then
        configs[name] = value
    end
end

-- get the configurations of package
function _instance:configs()
    local configs = self._CONFIGS
    if configs == nil then
        local configs_defined = self:get("configs")
        if configs_defined then
            configs = {}
            local requireinfo = self:requireinfo()
            local configs_required = requireinfo and requireinfo.configs or {}
            for _, name in ipairs(table.wrap(configs_defined)) do
                local value = configs_required[name]
                if value == nil then
                    value = self:extraconf("configs", name, "default")
                end
                configs[name] = value
            end
        else
            configs = false
        end
        self._CONFIGS = configs
    end
    return configs and configs or nil
end

-- get the build hash
function _instance:buildhash()
    local buildhash = self._BUILDHASH
    if buildhash == nil then
        local function _get_buildhash(configs, opt)
            opt = opt or {}
            local str = self:plat() .. self:arch()
            local label = self:label()
            if label then
                str = str .. label
            end
            if configs then
                -- since luajit v2.1, the key order of the table is random and undefined.
                -- We cannot directly deserialize the table, so the result may be different each time
                local configs_order = {}
                for k, v in pairs(table.wrap(configs)) do
                    table.insert(configs_order, k .. "=" .. tostring(v))
                end
                table.sort(configs_order)

                -- we need to be compatible with the hash value string for the previous luajit version
                local configs_str = string.serialize(configs_order, true)
                configs_str = configs_str:gsub("\"", "")
                str = str .. configs_str
            end
            if opt.sourcehash ~= false then
                local sourcehashs = hashset.new()
                for _, url in ipairs(self:urls()) do
                    local url_alias = self:url_alias(url)
                    local sourcehash = self:sourcehash(url_alias)
                    if sourcehash then
                        sourcehashs:insert(sourcehash)
                    end
                end
                if not sourcehashs:empty() then
                    local hashs = sourcehashs:to_array()
                    table.sort(hashs)
                    str = str .. "_" .. table.concat(hashs, "_")
                end
            end
            return hash.uuid4(str):gsub('-', ''):lower()
        end
        local function _get_installdir(...)
            local name = self:name():lower():gsub("::", "_")
            local dir = path.join(package.installdir(), name:sub(1, 1):lower(), name)
            if self:version_str() then
                dir = path.join(dir, self:version_str())
            end
            return path.join(dir, ...)
        end

        -- we need to be compatible with the hash value string for the previous xmake version
        -- without builtin pic configuration (< 2.5.1).
        if self:config("pic") then
            local configs = table.copy(self:configs())
            configs.pic = nil
            buildhash = _get_buildhash(configs, {sourcehash = false})
            if not os.isdir(_get_installdir(buildhash)) then
                buildhash = nil
            end
        end

        -- we need to be compatible with the hash value string for the previous xmake version
        -- without sourcehash (< 2.5.2)
        if not buildhash then
            buildhash = _get_buildhash(self:configs(), {sourcehash = false})
            if not os.isdir(_get_installdir(buildhash)) then
                buildhash = nil
            end
        end

        -- get build hash for current version
        if not buildhash then
            buildhash = _get_buildhash(self:configs())
        end
        self._BUILDHASH = buildhash
    end
    return buildhash
end

-- get the group name
function _instance:group()
    local requireinfo = self:requireinfo()
    if requireinfo then
        return requireinfo.group
    end
end

-- get xxx_script
function _instance:script(name, generic)

    -- get script
    local script = self:get(name)
    local result = nil
    if type(script) == "function" then
        result = script
    elseif type(script) == "table" then

        -- get plat and arch
        local plat = self:plat() or ""
        local arch = self:arch() or ""

        -- match pattern
        --
        -- `@linux`
        -- `@linux|x86_64`
        -- `@macosx,linux`
        -- `android@macosx,linux`
        -- `android|armeabi-v7a@macosx,linux`
        -- `android|armeabi-v7a@macosx,linux|x86_64`
        -- `android|armeabi-v7a@linux|x86_64`
        --
        for _pattern, _script in pairs(script) do
            local hosts = {}
            local hosts_spec = false
            _pattern = _pattern:gsub("@(.+)", function (v)
                for _, host in ipairs(v:split(',')) do
                    hosts[host] = true
                    hosts_spec = true
                end
                return ""
            end)
            if not _pattern:startswith("__") and (not hosts_spec or hosts[os.subhost() .. '|' .. os.subarch()] or hosts[os.subhost()])
            and (_pattern:trim() == "" or (plat .. '|' .. arch):find('^' .. _pattern .. '$') or plat:find('^' .. _pattern .. '$')) then
                result = _script
                break
            end
        end

        -- get generic script
        result = result or script["__generic__"] or generic
    end

    -- only generic script
    result = result or generic

    -- imports some modules first
    if result and result ~= generic then
        local scope = getfenv(result)
        if scope then
            for _, modulename in ipairs(table.wrap(self:get("imports"))) do
                scope[sandbox_module.name(modulename)] = sandbox_module.import(modulename, {anonymous = true})
            end
        end
    end
    return result
end

-- do fetch tool
function _instance:_fetch_tool(opt)
    opt = opt or {}
    local fetchinfo
    local on_fetch = self:script("fetch")
    if on_fetch then
        fetchinfo = on_fetch(self, {force = opt.force,
                                    system = opt.system,
                                    require_version = opt.require_version})
        if opt.require_version and opt.require_version:find(".", 1, true) then
            local version = type(fetchinfo) == "table" and fetchinfo.version
            if not (version and (version == opt.require_version or semver.satisfies(version, opt.require_version))) then
                fetchinfo = nil
            end
        end
    end
    if fetchinfo == nil then
        self._find_tool = self._find_tool or sandbox_module.import("lib.detect.find_tool", {anonymous = true})
        if opt.system then
            local fetchnames = {}
            if not self:is_thirdparty() then
                table.join2(fetchnames, self:extsources())
            end
            table.insert(fetchnames, self:name())
            for _, fetchname in ipairs(fetchnames) do
                fetchinfo = self:find_tool(fetchname, opt)
                if fetchinfo then
                    break
                end
            end
        else
            fetchinfo = self:find_tool(self:name(), {require_version = opt.require_version,
                                                     cachekey = "fetch_package_xmake",
                                                     norun = true, -- we need not run it to check for xmake/packages, @see https://github.com/xmake-io/xmake-repo/issues/66
                                                     force = opt.force})

            -- may be toolset, not single tool
            if not fetchinfo then
                fetchinfo = self:manifest_load()
            end
        end
    end
    return fetchinfo or nil
end

-- do fetch library
--
-- @param opt   the options, e.g. {force, system, external, require_version}
--
function _instance:_fetch_library(opt)
    opt = opt or {}
    local fetchinfo
    local on_fetch = self:script("fetch")
    if on_fetch then
        fetchinfo = on_fetch(self, {force = opt.force,
                                    system = opt.system,
                                    external = opt.external,
                                    require_version = opt.require_version})
        if opt.require_version and opt.require_version:find(".", 1, true) then
            local version = fetchinfo and fetchinfo.version
            if not (version and (version == opt.require_version or semver.satisfies(version, opt.require_version))) then
                fetchinfo = nil
            end
        end
        if fetchinfo then
            if opt.external then
                fetchinfo.sysincludedirs = fetchinfo.sysincludedirs or fetchinfo.includedirs
                fetchinfo.includedirs = nil
            else
                fetchinfo.includedirs = fetchinfo.includedirs or fetchinfo.sysincludedirs
                fetchinfo.sysincludedirs = nil
            end
        end
        if fetchinfo and option.get("verbose") then
            local reponame = self:repo() and self:repo():name() or ""
            utils.cprint("checking for %s::%s ... ${color.success}%s %s", reponame, self:name(), self:name(), fetchinfo.version and fetchinfo.version or "")
        end
    end
    if fetchinfo == nil then
        if opt.system then
            local fetchnames = {}
            if not self:is_thirdparty() then
                table.join2(fetchnames, self:extsources())
            end
            table.insert(fetchnames, self:name())
            for _, fetchname in ipairs(fetchnames) do
                fetchinfo = self:find_package(fetchname, opt)
                if fetchinfo then
                    break
                end
            end
        else
            fetchinfo = self:find_package("xmake::" .. self:name(), {
                                           require_version = opt.require_version,
                                           cachekey = "fetch_package_xmake",
                                           external = opt.external,
                                           force = opt.force})
        end
    end
    return fetchinfo or nil
end

-- find tool
function _instance:find_tool(name, opt)
    opt = opt or {}
    self._find_tool = self._find_tool or sandbox_module.import("lib.detect.find_tool", {anonymous = true})
    return self._find_tool(name, {cachekey = opt.cachekey or "fetch_package_system",
                                  installdir = self:installdir(),
                                  version = true, -- we alway check version
                                  require_version = opt.require_version,
                                  norun = opt.norun,
                                  force = opt.force})
end

-- find package
function _instance:find_package(name, opt)
    opt = opt or {}
    self._find_package = self._find_package or sandbox_module.import("lib.detect.find_package", {anonymous = true})
    local system = opt.system
    if system == nil and not name:startswith("xmake::") then
        system = true -- find system package by default
    end
    return self._find_package(name, {
                              force = opt.force,
                              installdir = self:installdir(),
                              version = true, -- we alway check version
                              require_version = opt.require_version,
                              mode = self:mode(),
                              plat = self:plat(),
                              arch = self:arch(),
                              pkgconfigs = self:configs(),
                              buildhash = self:buildhash(), -- for xmake package or 3rd package manager, e.g. go:: ..
                              cachekey = opt.cachekey or "fetch_package_system",
                              external = opt.external,
                              system = system})
end

-- fetch the local package info
--
-- @param opt   the fetch option, e.g. {force = true, external = false}
--
-- @return {packageinfo}, fetchfrom (e.g. xmake/system)
--
function _instance:fetch(opt)

    -- init options
    opt = opt or {}

    -- attempt to get it from cache
    local fetchinfo = self._FETCHINFO
    if not opt.force and opt.external == nil and fetchinfo then
        return fetchinfo
    end

    -- fetch the require version
    local require_ver = opt.version or self:requireinfo().version
    if not self:is_thirdparty() and not require_ver:find('.', 1, true) then
        -- strip branch version only system package
        require_ver = nil
    end

    -- nil: find xmake or system packages
    -- true: only find system package
    -- false: only find xmake packages
    local system = opt.system
    if system == nil then
        system = self:requireinfo().system
    end
    if self:is_thirdparty() then
        -- we need ignore `{system = true/false}` argument if be 3rd package
        -- @see https://github.com/xmake-io/xmake/issues/726
        system = nil
    elseif self:is_cross() then
        -- we need disable system package for cross-compilation
        system = false
    end

    -- use sysincludedirs/-isystem instead of -I?
    local external
    if opt.external ~= nil then
        external = opt.external
    else
        external = self:requireinfo().external
    end
    if external == nil then
        external = true
    end

    -- fetch binary tool?
    fetchinfo = nil
    local is_system = nil
    if self:is_binary() then

        -- only fetch it from the xmake repository first
        if not fetchinfo and system ~= true and not self:is_thirdparty() then
            fetchinfo = self:_fetch_tool({require_version = self:version_str(), force = opt.force})
            if fetchinfo then
                is_system = self._is_system
            end
        end

        -- fetch it from the system directories
        if not fetchinfo and system ~= false then
            fetchinfo = self:_fetch_tool({system = true, require_version = require_ver, force = opt.force})
            if fetchinfo then
                is_system = true
            end
        end
    else

        -- only fetch it from the xmake repository first
        if not fetchinfo and system ~= true and not self:is_thirdparty() then
            fetchinfo = self:_fetch_library({require_version = self:version_str(), external = external, force = opt.force})
            if fetchinfo then
                is_system = self._is_system
            end
        end

        -- fetch it from the system and external package sources
        if not fetchinfo and system ~= false then
            fetchinfo = self:_fetch_library({system = true, require_version = require_ver, external = external, force = opt.force})
            if fetchinfo then
                is_system = true
            end
        end
    end

    -- save to cache
    self._FETCHINFO = fetchinfo

    -- mark as system package?
    if is_system ~= nil then
        self._is_system = is_system
    end
    return fetchinfo
end

-- exists this package?
function _instance:exists()
    return self._FETCHINFO ~= nil
end

-- fetch link info of dependencies
function _instance:fetch_linkdeps()
    local fetchinfo = self:fetch()
    if not fetchinfo then
        return
    end
    fetchinfo = table.copy(fetchinfo) -- avoid the cached fetchinfo be modified
    local linkdeps = self:linkdeps()
    if linkdeps then
        for _, dep in ipairs(linkdeps) do
            local depinfo = dep:fetch()
            if depinfo then
                for name, values in pairs(depinfo) do
                    if name ~= "license" and name ~= "version" then
                        fetchinfo[name] = table.wrap(fetchinfo[name])
                        table.join2(fetchinfo[name], values)
                    end
                end
            end
        end
    end
    if fetchinfo then
        for name, values in pairs(fetchinfo) do
            if name == "links" or name == "syslinks" or name == "frameworks" then
                fetchinfo[name] = table.unwrap(table.reverse_unique(table.wrap(values)))
            else
                fetchinfo[name] = table.unwrap(table.unique(table.wrap(values)))
            end
        end
    end
    return fetchinfo
end

-- get the patches of the current version
function _instance:patches()
    local patches = self._PATCHES
    if patches == nil then
        local patchinfos = self:get("patches")
        if patchinfos then
            local version_str = self:version_str()
            local patchinfo = patchinfos[version_str]
            if patchinfo then
                patches = {}
                patchinfo = table.wrap(patchinfo)
                for idx = 1, #patchinfo, 2 do
                    table.insert(patches , {url = patchinfo[idx], sha256 = patchinfo[idx + 1]})
                end
            else
                -- match semver, e.g add_patches(">=1.0.0", url, sha256)
                for range, patchinfo in pairs(patchinfos) do
                    if semver.satisfies(version_str, range) then
                        patches = patches or {}
                        patchinfo = table.wrap(patchinfo)
                        for idx = 1, #patchinfo, 2 do
                            table.insert(patches , {url = patchinfo[idx], sha256 = patchinfo[idx + 1]})
                        end
                    end
                end
            end
        end
        self._PATCHES = patches or false
    end
    return patches and patches or nil
end

-- get the resources of the current version
function _instance:resources()
    local resources = self._RESOURCES
    if resources == nil then
        local resourceinfos = self:get("resources")
        if resourceinfos then
            local version_str = self:version_str()
            local resourceinfo = resourceinfos[version_str]
            if resourceinfo then
                resources = {}
                resourceinfo = table.wrap(resourceinfo)
                for idx = 1, #resourceinfo, 3 do
                    local name = resourceinfo[idx]
                    resources[name] = {url = resourceinfo[idx + 1], sha256 = resourceinfo[idx + 2]}
                end
            else
                -- match semver, e.g add_resources(">=1.0.0", name, url, sha256)
                for range, resourceinfo in pairs(resourceinfos) do
                    if semver.satisfies(version_str, range) then
                        resources = resources or {}
                        resourceinfo = table.wrap(resourceinfo)
                        for idx = 1, #resourceinfo, 3 do
                            local name = resourceinfo[idx]
                            resources[name] = {url = resourceinfo[idx + 1], sha256 = resourceinfo[idx + 2]}
                        end
                    end
                end
            end
        end
        self._RESOURCES = resources or false
    end
    return resources and resources or nil
end

-- get the the given resource
function _instance:resource(name)
    local resources = self:resources()
    return resources and resources[name] or nil
end

-- get the the given resource file
function _instance:resourcefile(name)
    local resource = self:resource(name)
    if resource and resource.url then
        return path.join(self:cachedir(), "resources", name, (path.filename(resource.url):gsub("%?.+$", "")))
    end
end

-- get the the given resource directory
function _instance:resourcedir(name)
    local resource = self:resource(name)
    if resource and resource.url then
        return path.join(self:cachedir(), "resources", name, (path.filename(resource.url):gsub("%?.+$", "")) .. ".dir")
    end
end

-- generate building configs for has_xxx/check_xxx
function _instance:_generate_build_configs(configs)
    configs = table.join(self:fetch_linkdeps(), configs)
    if self:is_plat("windows") then
        local ld = self:build_getenv("ld")
        local vs_runtime = self:config("vs_runtime")
        if vs_runtime and ld and path.basename(ld:lower()) == "link" then -- for msvc?
            configs.cxflags = table.wrap(configs.cxflags)
            table.insert(configs.cxflags, "/" .. vs_runtime)
            if vs_runtime:startswith("MT") then
                configs.ldflags = table.wrap(configs.ldflags)
                table.insert(configs.ldflags, "-nodefaultlib:msvcrt.lib")
            end
        end
    end
    return configs
end

-- has the given c funcs?
--
-- @param funcs     the funcs
-- @param opt       the argument options, e.g. { includes = ""}
--
-- @return          true or false, errors
--
function _instance:has_cfuncs(funcs, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_cfuncs", {anonymous = true})(funcs, opt)
end

-- has the given c++ funcs?
--
-- @param funcs     the funcs
-- @param opt       the argument options, e.g. {includes = ""}
--
-- @return          true or false, errors
--
function _instance:has_cxxfuncs(funcs, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_cxxfuncs", {anonymous = true})(funcs, opt)
end

-- has the given c types?
--
-- @param types  the types
-- @param opt       the argument options, e.g. { defines = ""}
--
-- @return          true or false, errors
--
function _instance:has_ctypes(types, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_ctypes", {anonymous = true})(types, opt)
end

-- has the given c++ types?
--
-- @param types  the types
-- @param opt       the argument options, e.g. { defines = ""}
--
-- @return          true or false, errors
--
function _instance:has_cxxtypes(types, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_cxxtypes", {anonymous = true})(types, opt)
end

-- has the given c includes?
--
-- @param includes  the includes
-- @param opt       the argument options, e.g. { defines = ""}
--
-- @return          true or false, errors
--
function _instance:has_cincludes(includes, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_cincludes", {anonymous = true})(includes, opt)
end

-- has the given c++ includes?
--
-- @param includes  the includes
-- @param opt       the argument options, e.g. { defines = ""}
--
-- @return          true or false, errors
--
function _instance:has_cxxincludes(includes, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.has_cxxincludes", {anonymous = true})(includes, opt)
end

-- check the given c snippets?
--
-- @param snippets  the snippets
-- @param opt       the argument options, e.g. { includes = ""}
--
-- @return          true or false, errors
--
function _instance:check_csnippets(snippets, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.check_csnippets", {anonymous = true})(snippets, opt)
end

-- check the given c++ snippets?
--
-- @param snippets  the snippets
-- @param opt       the argument options, e.g. { includes = ""}
--
-- @return          true or false, errors
--
function _instance:check_cxxsnippets(snippets, opt)
    opt = opt or {}
    opt.target = self
    opt.configs = self:_generate_build_configs(opt.configs)
    return sandbox_module.import("lib.detect.check_cxxsnippets", {anonymous = true})(snippets, opt)
end

-- the current mode is belong to the given modes?
function package._api_is_mode(interp, ...)
    return config.is_mode(...)
end

-- the current platform is belong to the given platforms?
function package._api_is_plat(interp, ...)
    local plat = package.targetplat()
    for _, v in ipairs(table.join(...)) do
        if v and plat == v then
            return true
        end
    end
end

-- the current platform is belong to the given architectures?
function package._api_is_arch(interp, ...)
    local arch = package.targetarch()
    for _, v in ipairs(table.join(...)) do
        if v and arch:find("^" .. v:gsub("%-", "%%-") .. "$") then
            return true
        end
    end
end

-- the current host is belong to the given hosts?
function package._api_is_host(interp, ...)
    return os.is_host(...)
end

-- the interpreter
function package._interpreter()

    -- the interpreter has been initialized? return it directly
    if package._INTERPRETER then
        return package._INTERPRETER
    end

    -- init interpreter
    local interp = interpreter.new()
    assert(interp)

    -- define apis
    interp:api_define(package.apis())

    -- define apis for language
    interp:api_define(language.apis())

    -- save interpreter
    package._INTERPRETER = interp

    -- ok?
    return interp
end

-- get package memcache
function package._memcache()
    return memcache.cache("core.base.package")
end

-- get project
function package._project()
    local project = package._PROJECT
    if not project then
        if os.isfile(os.projectfile()) then
            project = require("project/project")
        end
    end
    return project
end

-- get global target platform of package
function package.targetplat()
    local plat = package._memcache():get("target_plat")
    if plat == nil then
        if not plat and package._project() then
            local targetplat_root = package._project().get("target.plat")
            if targetplat_root then
                plat = targetplat_root
            end
        end
        if not plat then
            plat = config.get("plat") or os.subhost()
        end
        package._memcache():set("target_plat", plat)
    end
    return plat
end

-- get global target architecture of pacakge
function package.targetarch()
    local arch = package._memcache():get("target_arch")
    if arch == nil then
        if not arch and package._project() then
            local targetarch_root = package._project().get("target.arch")
            if targetarch_root then
                arch = targetarch_root
            end
        end
        if not arch then
            arch = config.get("arch") or os.subarch()
        end
        package._memcache():set("target_arch", arch)
    end
    return arch
end

-- get package apis
function package.apis()

    return
    {
        values =
        {
            -- package.set_xxx
            "package.set_urls"
        ,   "package.set_kind"
        ,   "package.set_plat" -- deprecated
        ,   "package.set_arch" -- deprecated
        ,   "package.set_license"
        ,   "package.set_homepage"
        ,   "package.set_description"
        ,   "package.set_parallelize"
        ,   "package.set_sourcedir"
        ,   "package.set_cachedir"
        ,   "package.set_installdir"
            -- package.add_xxx
        ,   "package.add_deps"
        ,   "package.add_urls"
        ,   "package.add_imports"
        ,   "package.add_configs"
        ,   "package.add_extsources"
        }
    ,   script =
        {
            -- package.on_xxx
            "package.on_load"
        ,   "package.on_fetch"
        ,   "package.on_install"
        ,   "package.on_test"
        }
    ,   keyvalues =
        {
            -- package.set_xxx
            "package.set_policy"
            -- package.add_xxx
        ,   "package.add_patches"
        ,   "package.add_resources"
        }
    ,   dictionary =
        {
            -- package.add_xxx
            "package.add_versions"
        }
    ,   custom =
        {
            -- is_xxx
            { "is_host", package._api_is_host }
        ,   { "is_mode", package._api_is_mode }
        ,   { "is_plat", package._api_is_plat }
        ,   { "is_arch", package._api_is_arch }
        }
    }
end

-- the cache directory
function package.cachedir(opt)
    opt = opt or {}
    local cachedir = package._CACHEDIR
    if not cachedir then
        cachedir = os.getenv("XMAKE_PKG_CACHEDIR") or path.join(global.cachedir(), "packages")
        package._CACHEDIR = cachedir
    end
    if opt.rootonly then
        return cachedir
    end
    return path.join(cachedir, os.date("%y%m"))
end

-- the install directory
function package.installdir()
    local installdir = package._INSTALLDIR
    if not installdir then
        installdir = os.getenv("XMAKE_PKG_INSTALLDIR") or global.get("pkg_installdir") or path.join(global.directory(), "packages")
        package._INSTALLDIR = installdir
    end
    return installdir
end

-- the search directories
function package.searchdirs()
    local searchdirs = global.get("pkg_searchdirs")
    if searchdirs then
        return path.splitenv(searchdirs)
    end
end

-- load the package from the system directories
function package.load_from_system(packagename)

    -- get it directly from cache first
    local instance = package._memcache():get2("packages", packagename)
    if instance then
        return instance
    end

    -- get package info
    local packageinfo = {}
    local is_thirdparty = false
    if packagename:find("::", 1, true) then

        -- get interpreter
        local interp = package._interpreter()

        -- on install script
        local on_install = function (pkg)
            local opt = table.copy(pkg:configs())
            opt.mode            = pkg:is_debug() and "debug" or "release"
            opt.plat            = pkg:plat()
            opt.arch            = pkg:arch()
            opt.require_version = pkg:version_str()
            opt.buildhash       = pkg:buildhash()
            opt.cachedir        = pkg:cachedir()
            opt.installdir      = pkg:installdir()
            import("package.manager.install_package")(pkg:name(), opt)
        end

        -- make sandbox instance with the given script
        instance, errors = sandbox.new(on_install, interp:filter())
        if not instance then
            return nil, errors
        end

        -- save the install script
        packageinfo.install = instance:script()

        -- is third-party package?
        if not packagename:startswith("xmake::") then
            is_thirdparty = true
        end
    end

    -- new an instance
    instance = _instance.new(packagename, scopeinfo.new("package", packageinfo))

    -- mark as system or 3rd package
    instance._is_system = true
    instance._is_thirdparty = is_thirdparty

    if is_thirdparty then
        -- add configurations for the 3rd package
        local install_package = sandbox_module.import("package.manager." .. packagename:split("::")[1]:lower() .. ".install_package", {try = true, anonymous = true})
        if install_package and install_package.configurations then
            for name, conf in pairs(install_package.configurations()) do
                instance:add("configs", name, conf)
            end
        end

        -- disable parallelize for installation
        instance:set("parallelize", false)
    end

    -- save instance to the cache
    package._memcache():set2("packages", instance)
    return instance
end

-- load the package from the project file
function package.load_from_project(packagename, project)

    -- get it directly from cache first
    local instance = package._memcache():get2("packages", packagename)
    if instance then
        return instance
    end

    -- load packages (with cache)
    local packages, errors = project.packages()
    if not packages then
        return nil, errors
    end

    -- get package info
    local packageinfo = packages[packagename]
    if not packageinfo then
        return
    end

    -- new an instance
    instance = _instance.new(packagename, packageinfo)
    package._memcache():set2("packages", instance)
    return instance
end

-- load the package from the package directory or package description file
function package.load_from_repository(packagename, repo, packagedir, packagefile)

    -- get it directly from cache first
    local instance = package._memcache():get2("packages", packagename)
    if instance then
        return instance
    end

    -- load repository first for checking the xmake minimal version
    if repo then
        repo:load()
    end

    -- find the package script path
    local scriptpath = packagefile
    if not packagefile and packagedir then
        scriptpath = path.join(packagedir, "xmake.lua")
    end
    if not scriptpath or not os.isfile(scriptpath) then
        return nil, string.format("package %s not found!", packagename)
    end

    -- get interpreter
    local interp = package._interpreter()

    -- load script
    local ok, errors = interp:load(scriptpath)
    if not ok then
        return nil, errors
    end

    -- load package and disable filter, we will process filter after a while
    local results, errors = interp:make("package", true, false)
    if not results then
        return nil, errors
    end

    -- get package info
    local packageinfo = results[packagename]
    if not packageinfo then
        return nil, string.format("%s: package(%s) not found!", scriptpath, packagename)
    end

    -- new an instance
    instance = _instance.new(packagename, packageinfo, {scriptdir = path.directory(scriptpath), repo = repo})

    -- save instance to the cache
    package._memcache():set2("packages", instance)
    return instance
end

-- return module
return package
