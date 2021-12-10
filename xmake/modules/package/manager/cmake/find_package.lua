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
-- @file        find_package.lua
--

-- imports
import("core.base.option")
import("core.project.target")
import("lib.detect.find_tool")

-- find package
function _find_package(cmake, name, opt)

    -- get work directory
    local workdir = os.tmpfile() .. ".dir"
    os.tryrm(workdir)
    os.mkdir(workdir)
    io.writefile(path.join(workdir, "test.cpp"), "")

    -- generate CMakeLists.txt
    local cmakefile = io.open(path.join(workdir, "CMakeLists.txt"), "w")
    if cmake.version then
        cmakefile:print("cmake_minimum_required(VERSION %s)", cmake.version)
    end
    cmakefile:print("project(find_package)")

    -- e.g. OpenCV 4.1.1, Boost COMPONENTS regex system
    local requirestr = name
    if opt.required_version then
        requirestr = requirestr .. " " .. opt.required_version
    end
    if opt.components then
        requirestr = requirestr .. " COMPONENTS"
        for _, component in ipairs(opt.components) do
            requirestr = requirestr .. " " .. component
        end
    end
    if opt.moduledirs then
        for _, moduledir in ipairs(opt.moduledirs) do
            cmakefile:print("add_cmake_modules(%s)", moduledir)
        end
    end
    -- e.g. set(Boost_USE_STATIC_LIB ON)
    if opt.presets then
        for k, v in pairs(opt.presets) do
            if type(v) == "boolean" then
                cmakefile:print("set(%s %s)", k, v and "ON" or "OFF")
            else
                cmakefile:print("set(%s %s)", k, tostring(v))
            end
        end
    end
    cmakefile:print("find_package(%s REQUIRED)", requirestr)
    cmakefile:print("if(%s_FOUND)", name)
    cmakefile:print("   add_executable(%s test.cpp)", name)
    cmakefile:print("   target_include_directories(%s PRIVATE ${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS})",
        name, name, name)
    cmakefile:print("   target_include_directories(%s PRIVATE ${%s_INCLUDE_DIR} ${%s_INCLUDE_DIRS})",
        name, name:upper(), name:upper())
    cmakefile:print("   target_include_directories(%s PRIVATE ${%s_CXX_INCLUDE_DIRS})",
        name, name)
    cmakefile:print("   target_link_libraries(%s ${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS})",
        name, name, name, name)
    cmakefile:print("   target_link_libraries(%s ${%s_LIBRARY} ${%s_LIBRARIES} ${%s_LIBS})",
        name, name:upper(), name:upper(), name:upper())
    cmakefile:print("endif(%s_FOUND)", name)
    cmakefile:close()

    -- run cmake
    try {function() return os.vrunv(cmake.program, {workdir}, {curdir = workdir, envs = opt.envs}) end}

    -- pares defines and includedirs for macosx/linux
    local links
    local linkdirs
    local libfiles
    local defines
    local includedirs
    local flagsfile = path.join(workdir, "CMakeFiles", name .. ".dir", "flags.make")
    if os.isfile(flagsfile) then
        local flagsdata = io.readfile(flagsfile)
        if flagsdata then
            if option.get("diagnosis") then
                vprint(flagsdata)
            end
            for _, line in ipairs(flagsdata:split("\n", {plain = true})) do
                if line:find("CXX_INCLUDES =", 1, true) then
                    local has_include = false
                    local flags = os.argv(line:split("=", {plain = true})[2]:trim())
                    for _, flag in ipairs(flags) do
                        if has_include or (flag:startswith("-I") and #flag > 2) then
                            local includedir = has_include and flag or flag:sub(3)
                            if includedir and os.isdir(includedir) then
                                includedirs = includedirs or {}
                                table.insert(includedirs, includedir)
                            end
                            has_include = false
                        elseif flag == "-isystem" or flag == "-I" then
                            has_include = true
                        end
                    end
                elseif line:find("CXX_DEFINES =", 1, true) then
                    local flags = os.argv(line:split("=", {plain = true})[2]:trim())
                    for _, flag in ipairs(flags) do
                        if flag:startswith("-D") and #flag > 2 then
                            local define = flag:sub(3)
                            if define then
                                defines = defines or {}
                                table.insert(defines, define)
                            end
                        end
                    end
                end
            end
        end
    end

    -- parse links and linkdirs for macosx/linux
    local linkfile = path.join(workdir, "CMakeFiles", name .. ".dir", "link.txt")
    if os.isfile(linkfile) then
        local linkdata = io.readfile(linkfile)
        if linkdata then
            if option.get("diagnosis") then
                vprint(linkdata)
            end
            for _, line in ipairs(os.argv(linkdata)) do
                local is_library = false
                for _, suffix in ipairs({".so", ".dylib", ".dylib", ".tbd", ".lib"}) do
                    if line:find(suffix, 1, true) then
                        is_library = true
                        break
                    end
                end
                if is_library then
                    -- strip library version suffix, e.g. libxxx.so.1.1 -> libxxx.so
                    if line:find(".so", 1, true) then
                        line = line:gsub("lib(.-)%.so%..+$", "lib%1.so")
                    end

                    -- get libfiles
                    if os.isfile(line) then
                        libfiles = libfiles or {}
                        table.insert(libfiles, line)
                    end

                    -- get links and linkdirs
                    local linkdir = path.directory(line)
                    if linkdir ~= "." then
                        linkdirs = linkdirs or {}
                        table.insert(linkdirs, linkdir)
                    end
                    local link = target.linkname(path.filename(line))
                    if link then
                        links = links or {}
                        table.insert(links, link)
                    end
                end
            end
        end
    end

    -- pares includedirs and links/linkdirs for windows
    local vcprojfile = path.join(workdir, name .. ".vcxproj")
    if os.isfile(vcprojfile) then
        local vcprojdata = io.readfile(vcprojfile)
        if vcprojdata then
            for _, line in ipairs(vcprojdata:split("\n", {plain = true})) do
                local values = line:match("<AdditionalIncludeDirectories>(.+);%%%(AdditionalIncludeDirectories%)</AdditionalIncludeDirectories>")
                if values then
                    includedirs = includedirs or {}
                    table.join2(includedirs, path.splitenv(values))
                end

                values = line:match("<AdditionalDependencies>(.+)</AdditionalDependencies>")
                if not values then
                    -- we need also parse libraries from here
                    -- https://github.com/xmake-io/xmake/issues/1822
                    values = line:match("<ImportLibrary>(.+)</ImportLibrary>")
                end
                if values then
                    for _, library in ipairs(path.splitenv(values)) do
                        -- get libfiles
                        if os.isfile(library) then
                            libfiles = libfiles or {}
                            table.insert(libfiles, library)
                        end

                        -- get links and linkdirs
                        local linkdir = path.directory(library)
                        if linkdir ~= "." then
                            linkdirs = linkdirs or {}
                            table.insert(linkdirs, linkdir)
                            local link = target.linkname(path.filename(library))
                            if link then
                                links = links or {}
                                table.insert(links, link)
                            end
                        end
                    end
                end
            end
        end
    end

    -- remove work directory
    os.tryrm(workdir)

    -- get results
    if links or includedirs then
        local results = {}
        results.links       = table.reverse_unique(links)
        results.linkdirs    = table.unique(linkdirs)
        results.defines     = table.unique(defines)
        results.libfiles    = table.unique(libfiles)
        results.includedirs = table.unique(includedirs)
        return results
    end
end

-- find package using the cmake package manager
--
-- e.g.
--
-- find_package("cmake::ZLIB")
-- find_package("cmake::OpenCV", {required_version = "4.1.1"})
-- find_package("cmake::Boost", {components = {"regex", "system"}, presets = {Boost_USE_STATIC_LIB = true}})
-- find_package("cmake::Foo", {moduledirs = "xxx"})
--
-- @param name  the package name
-- @param opt   the options, e.g. {verbose = true, required_version = "1.0",
--                                 components = {"regex", "system"},
--                                 moduledirs = "xxx",
--                                 presets = {Boost_USE_STATIC_LIB = true},
--                                 envs = {CMAKE_PREFIX_PATH = "xxx"})
--
function main(name, opt)
    opt = opt or {}
    local cmake = find_tool("cmake", {version = true})
    if not cmake then
        return
    end
    return _find_package(cmake, name, opt)
end
