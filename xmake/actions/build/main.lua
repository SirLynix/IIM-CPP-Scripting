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
import("core.base.global")
import("core.base.task")
import("core.project.rule")
import("core.project.config")
import("core.project.project")
import("core.platform.platform")
import("core.theme.theme")
import("utils.progress")
import("build")
import("build_files")
import("cleaner")
import("statistics")

-- do build for the third-party buildsystem
function _try_build()

    -- load config
    config.load()

    -- rebuild it? do clean first
    local targetname = option.get("target")
    if option.get("rebuild") then
        task.run("clean", {target = targetname})
    end

    -- get the buildsystem tool
    local configfile = nil
    local tool = nil
    local trybuild = config.get("trybuild")
    local trybuild_detected = nil
    if trybuild then
        tool = import("private.action.trybuild." .. trybuild, {try = true, anonymous = true})
        if tool then
            configfile = tool.detect()
        else
            raise("unknown build tool: %s", trybuild)
        end
    else
        for _, name in ipairs({"autotools", "cmake", "meson", "scons", "bazel", "msbuild", "xcodebuild", "make", "ninja", "ndkbuild"}) do
            tool = import("private.action.trybuild." .. name, {anonymous = true})
            configfile = tool.detect()
            if configfile then
                trybuild_detected = name
                break
            end
        end
    end

    -- try building it
    if configfile and tool and (trybuild or utils.confirm({default = true,
            description = "${bright}" .. path.filename(configfile) .. "${clear} found, try building it or you can run `${bright}xmake f --trybuild=${clear}` to set buildsystem"})) then
        if not trybuild then
            task.run("config", {target = targetname, trybuild = trybuild_detected})
        end
        tool.build()
        return true
    end
end

-- do global project rules
function _do_project_rules(scriptname, opt)
    for _, rulename in ipairs(project.get("target.rules")) do
        local r = project.rule(rulename) or rule.rule(rulename)
        if r and r:kind() == "project" then
            local buildscript = r:script(scriptname)
            if buildscript then
                buildscript(opt)
            end
        end
    end
end

-- main
function main()

    -- try building it using third-party buildsystem if xmake.lua not exists
    if not os.isfile(project.rootfile()) and _try_build() then
        return
    end

    -- post statistics before locking project
    statistics.post()

    -- lock the whole project
    project.lock()

    -- get the target name
    local targetname = option.get("target")

    -- config it first
    task.run("config", {target = targetname}, {disable_dump = true})

    -- enter project directory
    local oldir = os.cd(project.directory())

    -- clean up temporary files once a day
    cleaner.cleanup()

    try
    {
        function ()

            -- do rules before building
            _do_project_rules("build_before")

            -- do build
            local sourcefiles = option.get("files")
            if sourcefiles then
                build_files(targetname, sourcefiles)
            else
                build(targetname)
            end
        end,

        catch
        {
            function (errors)

                -- do rules after building
                _do_project_rules("build_after", {errors = errors})

                -- raise
                if errors then
                    raise(errors)
                elseif targetname then
                    raise("build target: %s failed!", targetname)
                else
                    raise("build target failed!")
                end
            end
        }
    }

    -- do rules after building
    _do_project_rules("build_after")

    -- unlock the whole project
    project.unlock()

    -- leave project directory
    os.cd(oldir)

    -- trace
    progress.show(100, "${color.success}build ok!")
end
