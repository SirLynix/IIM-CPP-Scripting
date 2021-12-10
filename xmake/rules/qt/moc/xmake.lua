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
-- @file        xmake.lua
--

rule("qt.moc")
    add_deps("qt.env")
    set_extensions(".h", ".hpp")
    before_buildcmd_file(function (target, batchcmds, sourcefile, opt)

        -- imports
        import("core.tool.compiler")

        -- get moc
        local qt = assert(target:data("qt"), "qt not found!")
        local moc = path.join(qt.bindir, is_host("windows") and "moc.exe" or "moc")
        if not os.isexec(moc) and qt.libexecdir then
            moc = path.join(qt.libexecdir, is_host("windows") and "moc.exe" or "moc")
        end
        assert(moc and os.isexec(moc), "moc not found!")

        -- get c++ source file for moc
        --
        -- add_files("mainwindow.h") -> moc_MainWindow.cpp
        -- add_files("mainwindow.cpp", {rules = "qt.moc"}) -> mainwindow.moc, @see https://github.com/xmake-io/xmake/issues/750
        --
        local basename = path.basename(sourcefile)
        local filename_moc = "moc_" .. basename .. ".cpp"
        if sourcefile:endswith(".cpp") then
            filename_moc = basename .. ".moc"
        end
        local sourcefile_moc = path.join(target:autogendir(), "rules", "qt", "moc", filename_moc)

        -- add objectfile
        local objectfile = target:objectfile(sourcefile_moc)
        table.insert(target:objectfiles(), objectfile)

        -- add commands
        batchcmds:show_progress(opt.progress, "${color.build.object}compiling.qt.moc %s", sourcefile)

        -- generate c++ source file for moc
        local flags = {}
        table.join2(flags, compiler.map_flags("cxx", "define", target:get("defines")))
        table.join2(flags, compiler.map_flags("cxx", "includedir", target:get("includedirs")))
        table.join2(flags, compiler.map_flags("cxx", "includedir", target:get("sysincludedirs"))) -- for now, moc process doesn't support MSVC external includes flags and will fail
        table.join2(flags, compiler.map_flags("cxx", "frameworkdir", target:get("frameworkdirs")))
        batchcmds:mkdir(path.directory(sourcefile_moc))
        batchcmds:vrunv(moc, table.join(flags, sourcefile, "-o", sourcefile_moc))

        -- we need compile this moc_xxx.cpp file if exists Q_PRIVATE_SLOT, @see https://github.com/xmake-io/xmake/issues/750
        local mocdata = io.readfile(sourcefile)
        if mocdata and mocdata:find("Q_PRIVATE_SLOT") or sourcefile_moc:endswith(".moc") then
            -- add includedirs of sourcefile_moc
            target:add("includedirs", path.directory(sourcefile_moc))

            -- remove the object file of sourcefile_moc
            local objectfiles = target:objectfiles()
            for idx, objectfile in ipairs(objectfiles) do
                if objectfile == target:objectfile(sourcefile_moc) then
                    table.remove(objectfiles, idx)
                    break
                end
            end
        else
            -- compile c++ source file for moc
            batchcmds:compile(sourcefile_moc, objectfile)
        end

        -- add deps
        batchcmds:add_depfiles(sourcefile)
        batchcmds:set_depmtime(os.mtime(objectfile))
        batchcmds:set_depcache(target:dependfile(objectfile))
    end)
