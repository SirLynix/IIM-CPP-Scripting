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
-- @file        pcheader.lua
--

-- imports
import("core.language.language")
import("object")

-- add batch jobs to build the precompiled header file
function main(target, langkind, opt)
    local pcheaderfile = target:pcheaderfile(langkind)
    if pcheaderfile then
        local sourcefile = pcheaderfile
        local objectfile = target:pcoutputfile(langkind)
        local dependfile = target:dependfile(objectfile)
        local sourcekind = language.langkinds()[langkind]
        local sourcebatch = {sourcekind = sourcekind, sourcefiles = {sourcefile}, objectfiles = {objectfile}, dependfiles = {dependfile}}
        object.build(target, sourcebatch, opt)
    end
end
