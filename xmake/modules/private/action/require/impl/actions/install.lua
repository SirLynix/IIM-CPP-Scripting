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
-- @author      ruki
-- @file        install.lua
--

-- imports
import("core.base.option")
import("core.base.tty")
import("core.project.target")
import("lib.detect.find_file")
import("private.action.require.impl.actions.test")
import("private.action.require.impl.actions.patch_sources")
import("private.action.require.impl.actions.download_resources")
import("private.action.require.impl.utils.filter")

-- patch pkgconfig if not exists
function _patch_pkgconfig(package)

    -- only binary? need not pkgconfig
    if not package:is_library() then
        return
    end

    -- get lib/pkgconfig/*.pc file
    local pkgconfigdir = path.join(package:installdir(), "lib", "pkgconfig")
    local pcfile = os.isdir(pkgconfigdir) and find_file("*.pc", pkgconfigdir) or nil
    if pcfile then
        return
    end

    -- trace
    pcfile = path.join(pkgconfigdir, package:name() .. ".pc")
    vprint("patching %s ..", pcfile)

    -- fetch package
    local fetchinfo = package:fetch_linkdeps()
    if not fetchinfo then
        return
    end

    -- get libs
    local libs = ""
    for _, linkdir in ipairs(fetchinfo.linkdirs) do
        libs = libs .. " -L" .. linkdir
    end
    libs = libs .. " -L${libdir}"
    for _, link in ipairs(fetchinfo.links) do
        libs = libs .. " -l" .. link
    end
    for _, link in ipairs(fetchinfo.syslinks) do
        libs = libs .. " -l" .. link
    end

    -- cflags
    local cflags = ""
    for _, includedir in ipairs(fetchinfo.includedirs) do
        cflags = cflags .. " -I" .. includedir
    end
    cflags = cflags .. " -I${includedir}"

    -- patch a *.pc file
    local file = io.open(pcfile, 'w')
    if file then
        file:print("prefix=%s", package:installdir())
        file:print("exec_prefix=${prefix}")
        file:print("libdir=${exec_prefix}/lib")
        file:print("includedir=${prefix}/include")
        file:print("")
        file:print("Name: %s", package:name())
        file:print("Description: %s", package:description())
        file:print("Version: %s", package:version_str())
        file:print("Libs: %s", libs)
        file:print("Libs.private: ")
        file:print("Cflags: %s", cflags)
        file:close()
    end
end

-- fix paths for the precompiled package
-- @see https://github.com/xmake-io/xmake/issues/1671
function _fix_paths_for_precompiled_package(package)
    local filepaths = {path.join(package:installdir(), "**.cmake|include/**")}
    for _, filepath in ipairs(filepaths) do
        for _, file in ipairs(os.files(filepath)) do
            io.gsub(file, "(\"(.-)\")", function(_, value)
                if value:find(package:buildhash(), 1, true) and value:find(package:name(), 1, true) then
                    local result
                    local splitinfo = value:split(package:buildhash(), {plain = true})
                    if #splitinfo == 2 then
                        result = path.join(package:installdir(), splitinfo[2])
                    elseif #splitinfo == 1 then
                        result = package:installdir()
                    end
                    if result then
                        result = result:gsub("\\", "/")
                        vprint("fix path: %s in %s", result, path.filename(file))
                        return "\"" .. result .. "\""
                    end
                end
            end)
        end
    end
end

-- check package toolchains
function _check_package_toolchains(package)
    for _, toolchain_inst in pairs(package:toolchains()) do
        if not toolchain_inst:check() then
            raise("toolchain(\"%s\"): not found!", toolchain_inst:name())
        end
    end
end

-- install the given package
function main(package)

    -- get working directory of this package
    local workdir = package:cachedir()

    -- lock this package
    package:lock()

    -- enter the working directory
    local oldir = nil
    local sourcedir = package:sourcedir()
    if sourcedir then
        oldir = os.cd(sourcedir)
    elseif #package:urls() > 0 then
        -- only one root directory? skip it
        local filedirs = os.filedirs(path.join(workdir, "source", "*"))
        if #filedirs == 1 and os.isdir(filedirs[1]) then
            oldir = os.cd(filedirs[1])
        else
            oldir = os.cd(path.join(workdir, "source"))
        end
    end
    if not oldir then
        os.mkdir(workdir)
        oldir = os.cd(workdir)
    end

    -- init tipname
    local tipname = package:name()
    if package:version_str() then
        tipname = tipname .. "-" .. package:version_str()
    end

    -- install it
    local oldenvs = os.getenvs()
    try
    {
        function ()

            -- install the third-party package directly, e.g. brew::pcre2/libpcre2-8, conan::OpenSSL/1.0.2n@conan/stable
            local installed_now = false
            local script = package:script("install")
            if package:is_thirdparty() then
                if script ~= nil then
                    filter.call(script, package)
                end
            else

                -- build and install package to the install directory
                if option.get("force") or not package:manifest_load() then

                    -- clean install directory first
                    os.tryrm(package:installdir())

                    -- download package resources
                    download_resources(package)

                    -- patch source codes of package
                    patch_sources(package)

                    -- enter the environments of all package dependencies
                    for _, dep in ipairs(package:orderdeps()) do
                        dep:envs_enter()
                    end

                    -- check package toolchains
                    _check_package_toolchains(package)

                    -- do install
                    if script ~= nil then
                        filter.call(script, package, {oldenvs = oldenvs})
                    end

                    -- leave the environments of all package dependencies
                    os.setenvs(oldenvs)

                    -- save the package info to the manifest file
                    package:manifest_save()
                    installed_now = true
                end
            end

            -- enter the package environments
            for _, dep in ipairs(package:orderdeps()) do
                dep:envs_enter()
            end
            package:envs_enter()

            -- fetch package and force to flush the cache
            local fetchinfo = package:fetch({force = true})
            if option.get("verbose") or option.get("diagnosis") then
                print(fetchinfo)
            end
            assert(fetchinfo, "fetch %s failed!", tipname)

            -- this package is installed now
            if installed_now then

                -- fix paths for the precompiled package
                if package:is_plat("windows") and not package:is_built() and not package:is_system() then
                    _fix_paths_for_precompiled_package(package)
                end

                -- patch pkg-config files for package
                _patch_pkgconfig(package)

                -- test it
                test(package)
            end

            -- leave the package environments
            os.setenvs(oldenvs)

            -- trace
            tty.erase_line_to_start().cr()
            cprint("${yellow}  => ${clear}install %s %s .. ${color.success}${text.success}", package:displayname(), package:version_str() or "")
        end,

        catch
        {
            function (errors)

                -- show or save the last errors
                local errorfile = path.join(package:installdir("logs"), "install.txt")
                if errors then
                    if (option.get("verbose") or option.get("diagnosis")) then
                        cprint("${dim color.error}error: ${clear}%s", errors)
                    else
                        io.writefile(errorfile, errors .. "\n")
                    end
                end

                -- trace
                tty.erase_line_to_start().cr()
                cprint("${yellow}  => ${clear}install %s %s .. ${color.failure}${text.failure}", package:displayname(), package:version_str() or "")

                -- leave the package environments
                os.setenvs(oldenvs)

                -- copy the invalid package directory to cache
                local installdir = package:installdir()
                if os.isdir(installdir) then
                    local installdir_failed = path.join(package:cachedir(), "installdir.failed")
                    os.tryrm(installdir_failed)
                    if not os.isdir(installdir_failed) then
                        os.cp(installdir, installdir_failed)
                    end
                    errorfile = path.join(installdir_failed, "logs", "install.txt")
                end
                os.tryrm(installdir)

                -- failed
                if not package:requireinfo().optional then
                    if os.isfile(errorfile) then
                        if errors then
                            print("")
                            for idx, line in ipairs(errors:split("\n")) do
                                print(line)
                                if idx > 16 then
                                    break
                                end
                            end
                        end
                        cprint("if you want to get more verbose errors, please see:")
                        cprint("  -> ${bright}%s", errorfile)
                    end
                    raise("install failed!")
                end
            end
        }
    }

    -- clean the empty package directory
    local installdir = package:installdir()
    if os.emptydir(installdir) then
        os.tryrm(installdir)
    end

    -- unlock this package
    package:unlock()

    -- leave source codes directory
    os.cd(oldir)
end
