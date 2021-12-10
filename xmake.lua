add_requires("entt", "sfml", "sol2")

-- Configuration des modes debug et release
add_rules("mode.debug", "mode.release")
-- Activation de l'auto-régénération de projet vsxmake à la modification
add_rules("plugin.vsxmake.autoupdate")

set_languages("c++17")

set_rundir(".")
set_targetdir("./bin")

target("Project")
    set_kind("binary")
    add_files("src/main.cpp")
    add_packages("entt", "sfml", "sol2")
