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
-- @file        find_and_add_packages.lua
--

-- find and add packages to the given target
--
-- e.g.
--
-- @code
-- includes("find_and_add_packages.lua")
-- target("test")
--     set_kind("binary")
--     add_files("src/*.c")
--     find_and_add_packages("brew::pcre2/libpcre2-8", "zlib")
-- @endcode
--
function find_and_add_packages(...)
    for _, name in ipairs({...}) do
        local optname = "__" .. name
        save_scope()
        option(optname)
            before_check(function (option)
                option:add(find_packages(name))
            end)
        option_end()
        restore_scope()
        add_options(optname)
    end
end

