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
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.base.task")
import("core.project.config")
import("core.base.global")
import("core.project.project")
import("core.platform.platform")
import("devel.debugger")
import("private.action.run.make_runenvs")

-- run target
function _do_run_target(target)

    -- only for binary program
    if not target:is_binary() then
        return
    end

    -- get the run directory of target
    local rundir = target:rundir()

    -- get the absolute target file path
    local targetfile = path.absolute(target:targetfile())

    -- enter the run directory
    local oldir = os.cd(rundir)

    -- add run environments
    local addrunenvs, setrunenvs = make_runenvs(target)
    for name, values in pairs(addrunenvs) do
        os.addenv(name, table.unpack(table.wrap(values)))
    end
    for name, value in pairs(setrunenvs) do
        os.setenv(name, table.unpack(table.wrap(value)))
    end

    -- debugging?
    if option.get("debug") then
        debugger.run(targetfile, option.get("arguments"))
    else
        os.execv(targetfile, option.get("arguments"))
    end

    -- restore the previous directory
    os.cd(oldir)
end

-- run target
function _on_run_target(target)

    -- build target with rules
    local done = false
    for _, r in ipairs(target:orderules()) do
        local on_run = r:script("run")
        if on_run then
            on_run(target)
            done = true
        end
    end
    if done then return end

    -- do run
    _do_run_target(target)
end

-- recursively target add env
function _add_target_pkgenvs(target, targets_added)
    if targets_added[target:name()] then
        return
    end
    targets_added[target:name()] = true
    os.addenvs(target:pkgenvs())
    for _, dep in ipairs(target:orderdeps()) do
        _add_target_pkgenvs(dep, targets_added)
    end
end

-- run the given target
function _run(target)

    -- has been disabled?
    if not target:is_enabled() then
        return
    end

    -- enter the environments of the target packages
    local oldenvs = os.getenvs()
    _add_target_pkgenvs(target, {})

    -- the target scripts
    local scripts =
    {
        target:script("run_before")
    ,   function (target)
            for _, r in ipairs(target:orderules()) do
                local before_run = r:script("run_before")
                if before_run then
                    before_run(target)
                end
            end
        end
    ,   target:script("run", _on_run_target)
    ,   function (target)
            for _, r in ipairs(target:orderules()) do
                local after_run = r:script("run_after")
                if after_run then
                    after_run(target)
                end
            end
        end
    ,   target:script("run_after")
    }

    -- run the target scripts
    for i = 1, 5 do
        local script = scripts[i]
        if script ~= nil then
            script(target)
        end
    end

    -- leave the environments of the target packages
    os.setenvs(oldenvs)
end

-- check targets
function _check_targets(targetname)

    -- get targets
    local targets = {}
    if targetname and not targetname:startswith("__") then
        table.insert(targets, project.target(targetname))
    else
        -- install default or all targets
        for _, target in ipairs(project.ordertargets()) do
            if (target:is_default() or option.get("all")) and target:is_binary() then
                table.insert(targets, target)
            end
        end
    end

    -- filter and check targets with builtin-run script
    local targetnames = {}
    for _, target in ipairs(targets) do
        if target:targetfile() and target:is_enabled() and not target:script("run") then
            local targetfile = target:targetfile()
            if targetfile and not os.isfile(targetfile) then
                table.insert(targetnames, target:name())
            end
        end
    end

    -- there are targets that have not yet been built?
    if #targetnames > 0 then
        raise("please run `$xmake [target]` to build the following targets first:\n  -> " .. table.concat(targetnames, '\n  -> '))
    end
end

-- main
function main()

    -- get the target name
    local targetname = option.get("target")

    -- config it first
    task.run("config", {target = targetname, require = "n", verbose = false})

    -- check targets first
    _check_targets(targetname)

    -- enter project directory
    local oldir = os.cd(project.directory())

    -- run the given target?
    if targetname then
        _run(project.target(targetname))
    else
        -- run default or all binary targets
        for _, target in ipairs(project.ordertargets()) do
            if (target:is_default() or option.get("all")) and target:is_binary() then
                _run(target)
            end
        end
    end

    -- leave project directory
    os.cd(oldir)
end

