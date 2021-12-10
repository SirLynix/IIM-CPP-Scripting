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
-- @file        register_packages.lua
--

-- imports
import("core.project.project")

-- register required package environments
-- envs: bin path for *.dll, program ..
function _register_required_package_envs(instance, envs)
    for name, values in pairs(instance:envs()) do
        if name == "PATH" or name == "LD_LIBRARY_PATH" or name == "DYLD_LIBRARY_PATH" then
            for _, value in ipairs(values) do
                envs[name] = envs[name] or {}
                if path.is_absolute(value) then
                    table.insert(envs[name], value)
                else
                    table.insert(envs[name], path.join(instance:installdir(), value))
                end
            end
        else
            envs[name] = envs[name] or {}
            table.join2(envs[name], values)
        end
    end
end

-- register required package libraries
-- libs: includedirs, links, linkdirs ...
function _register_required_package_libs(instance, required_package, is_deps)
    if instance:is_library() then
        local fetchinfo = instance:fetch()
        if fetchinfo then
            fetchinfo.name    = nil
            if is_deps then
                -- we need only reserve license for root package
                --
                -- @note the license compatibility between the root package and
                -- its dependent packages is guaranteed by the root package itself
                --
                fetchinfo.license = nil

                -- we need only some infos for root package
                fetchinfo.version = nil
                fetchinfo.static  = nil
                fetchinfo.shared  = nil
            end
            required_package:add(fetchinfo)
        end
    end
end

-- register the base info of required package
function _register_required_package_base(instance, required_package)
    if not instance:is_system() and not instance:is_thirdparty() then
        required_package:set("__installdir", instance:installdir())
    end
end

-- register the required local package
function _register_required_package(instance, required_package)

    -- disable it if this package is missing
    if not instance:exists() then
        required_package:enable(false)
    else
        -- clear require info first
        required_package:clear()

        -- add packages info with all dependencies
        local envs = {}
        _register_required_package_base(instance, required_package)
        _register_required_package_libs(instance, required_package)
        _register_required_package_envs(instance, envs)
        local linkdeps = instance:linkdeps()
        if linkdeps then
            local total = #linkdeps
            for idx, _ in ipairs(linkdeps) do
                local dep = linkdeps[total + 1 - idx]
                if dep then
                    if instance:is_library() then
                        _register_required_package_libs(dep, required_package, true)
                    end
                end
            end
        end
        for _, dep in ipairs(instance:orderdeps()) do
            if not dep:is_private() then
                _register_required_package_envs(dep, envs)
            end
        end
        if #table.keys(envs) > 0 then
            required_package:add({envs = envs})
        end

        -- enable this require info
        required_package:enable(true)
    end

    -- save this require info and flush the whole cache file
    required_package:save()
end

-- register all required root packages to local cache
function main(packages)
    for _, instance in ipairs(packages) do
        if instance:is_toplevel() then
            local required_packagename = instance:alias() or instance:name()
            local required_package = project.required_package(required_packagename)
            if required_package then
                _register_required_package(instance, required_package)
            end
        end
    end
end

