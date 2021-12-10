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
-- @file        download.lua
--

-- imports
import("core.base.option")
import("core.base.tty")
import("core.base.hashset")
import("core.project.config")
import("core.package.package", {alias = "core_package"})
import("lib.detect.find_file")
import("lib.detect.find_directory")
import("private.action.require.impl.utils.filter")
import("private.action.require.impl..utils.url_filename")
import("net.http")
import("net.proxy")
import("devel.git")
import("utils.archive")

-- checkout codes from git
function _checkout(package, url, sourcedir, url_alias)

    -- use previous source directory if exists
    local packagedir = path.join(sourcedir, package:name())
    if os.isdir(packagedir) and
        not (option.get("force") and package:branch()) then -- we need disable cache if we force to clone from the given branch

        -- clean the previous build files
        git.clean({repodir = packagedir, force = true, all = true})
        -- reset the previous modified files
        git.reset({repodir = packagedir, hard = true})
        tty.erase_line_to_start().cr()
        return
    end

    -- we can use local package from the search directories directly if network is too slow
    local localdir = find_directory(package:name() .. archive.extension(url), core_package.searchdirs())
    if localdir and os.isdir(localdir) then
        git.clean({repodir = localdir, force = true, all = true})
        git.reset({repodir = localdir, hard = true})
        os.cp(localdir, packagedir)
        tty.erase_line_to_start().cr()
        return
    end

    -- remove temporary directory
    os.rm(sourcedir .. ".tmp")

    -- we need enable longpaths on windows
    local longpaths = package:policy("platform.longpaths")

    -- download package from branches?
    packagedir = path.join(sourcedir .. ".tmp", package:name())
    if package:branch() then

        -- only shadow clone this branch
        git.clone(url, {depth = 1, recursive = true, longpaths = longpaths, branch = package:branch(), outputdir = packagedir})

    -- download package from revision or tag?
    else

        -- clone whole history and tags
        git.clone(url, {longpaths = longpaths, outputdir = packagedir})

        -- attempt to checkout the given version
        local revision = package:revision(url_alias) or package:tag() or package:version_str()
        git.checkout(revision, {repodir = packagedir})

        -- update all submodules
        if os.isfile(path.join(packagedir, ".gitmodules")) then
            git.submodule.update({init = true, recursive = true, longpaths = longpaths, repodir = packagedir})
        end
    end

    -- move to source directory
    os.rm(sourcedir)
    os.mv(sourcedir .. ".tmp", sourcedir)

    -- trace
    tty.erase_line_to_start().cr()
    cprint("${yellow}  => ${clear}clone %s %s .. ${color.success}${text.success}", url, package:version_str())
end

-- download codes from ftp/http/https
function _download(package, url, sourcedir, url_alias, url_excludes)

    -- get package file
    local packagefile = url_filename(url)

    -- get sourcehash from the given url
    --
    -- we need not sourcehash and skip checksum to try download it directly if no version list in package()
    -- @see https://github.com/xmake-io/xmake/issues/930
    -- https://github.com/xmake-io/xmake/issues/1009
    --
    local sourcehash = package:sourcehash(url_alias)
    assert(not package:is_verify() or not package:get("versions") or sourcehash, "cannot get source hash of %s in package(%s)", url, package:name())

    -- the package file have been downloaded?
    local cached = true
    if not os.isfile(packagefile) or sourcehash ~= hash.sha256(packagefile) then

        -- no cached
        cached = false

        -- attempt to remove package file first
        os.tryrm(packagefile)

        -- download or copy package file
        if os.isfile(url) then
            os.cp(url, packagefile)
        else
            local localfile
            local searchnames = {package:name() .. "-" .. package:version_str() .. archive.extension(url),
                                 packagefile}
            for _, searchname in ipairs(searchnames) do
                localfile = find_file(searchname, core_package.searchdirs())
                if localfile then
                    break
                end
            end
            if localfile and os.isfile(localfile) then
                -- we can use local package from the search directories directly if network is too slow
                os.cp(localfile, packagefile)
            else
                http.download(url, packagefile)
            end
        end

        -- check hash
        if sourcehash and sourcehash ~= hash.sha256(packagefile) then
            raise("unmatched checksum!")
        end
    end

    -- extract package file
    os.rm(sourcedir .. ".tmp")
    if archive.extract(packagefile, sourcedir .. ".tmp", {excludes = url_excludes}) then
        -- move to source directory
        os.rm(sourcedir)
        os.mv(sourcedir .. ".tmp", sourcedir)
    else
        -- create an empty source directory if do not extract package file
        os.tryrm(sourcedir)
        os.mkdir(sourcedir)
        raise("cannot extract %s, maybe missing extractor or invalid package file!", packagefile)
    end

    -- save original file path
    package:originfile_set(path.absolute(packagefile))

    -- trace
    tty.erase_line_to_start().cr()
    if not cached then
        cprint("${yellow}  => ${clear}download %s .. ${color.success}${text.success}", url)
    end
end

-- get sorted urls
function _urls(package)

    -- sort urls from the version source
    local urls = {{}, {}}
    for _, url in ipairs(package:urls()) do
        if git.checkurl(url) then
            table.insert(urls[1], url)
        elseif not package:is_verify() or not package:get("versions") or package:sourcehash(package:url_alias(url)) then
            table.insert(urls[2], url)
        end
    end
    if package:gitref() then
        return table.join(urls[1], urls[2])
    else
        return table.join(urls[2], urls[1])
    end
end

-- download the given package
function main(package)

    -- get working directory of this package
    local workdir = package:cachedir()

    -- ensure the working directory first
    os.mkdir(workdir)

    -- enter the working directory
    local oldir = os.cd(workdir)

    -- lock this package
    package:lock()

    -- get urls
    local urls = _urls(package)
    assert(#urls > 0, "cannot get url of package(%s)", package:name())

    -- download package from urls
    local ok = false
    local urls_failed = {}
    for idx, url in ipairs(urls) do

        -- get url alias
        local url_alias = package:url_alias(url)

        -- get url excludes
        local url_excludes = package:url_excludes(url)

        -- filter url
        url = filter.handle(url, package)

        -- use proxy url?
        if not os.isfile(url) then
            url = proxy.mirror(url) or url
        end

        -- download url
        local allerrors = {}
        ok = try
        {
            function ()

                -- download package
                local sourcedir = "source"
                if git.checkurl(url) then
                    _checkout(package, url, sourcedir, url_alias)
                else
                    _download(package, url, sourcedir, url_alias, url_excludes)
                end
                return true
            end,
            catch
            {
                function (errors)

                    -- show or save the last errors
                    if errors then
                        if (option.get("verbose") or option.get("diagnosis")) then
                            cprint("${dim color.error}error: ${clear}%s", errors)
                        else
                            table.insert(allerrors, errors)
                        end
                    end

                    -- trace
                    tty.erase_line_to_start().cr()
                    if git.checkurl(url) then
                        cprint("${yellow}  => ${clear}clone %s %s .. ${color.failure}${text.failure}", url, package:version_str())
                    else
                        cprint("${yellow}  => ${clear}download %s .. ${color.failure}${text.failure}", url)
                    end
                    table.insert(urls_failed, url)

                    -- failed? break it
                    if idx == #urls and not package:is_optional() then
                        if #urls_failed > 0 then
                            print("")
                            print("we can also download these packages manually:")
                            local searchnames = hashset.new()
                            for _, url_failed in ipairs(urls_failed) do
                                cprint("  ${yellow}- %s", url_failed)
                                searchnames:insert(url_filename(url_failed))
                            end
                            cprint("to the local search directories: ${bright}%s", table.concat(table.wrap(core_package.searchdirs()), path.envsep()))
                            cprint("  ${bright}- %s", table.concat(searchnames:to_array(), ", "))
                            cprint("and we can run `xmake g --pkg_searchdirs=/xxx` to set the search directories.")
                        end
                        if #allerrors then
                            raise(table.concat(allerrors, "\n"))
                        else
                            raise("download failed!")
                        end
                    end
                end
            }
        }

        -- ok? break it
        if ok then break end
    end

    -- unlock this package
    package:unlock()

    -- leave working directory
    os.cd(oldir)
    return ok
end


