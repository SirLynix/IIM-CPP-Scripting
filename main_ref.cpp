#include <SFML/Graphics.hpp>
#include <SFML/Window.hpp>
#include <SFML/System.hpp>
#include <sol/sol.hpp>
#include <iostream>

namespace sol
{
	template<typename T>
	struct lua_type_of<sf::Vector2<T>> : std::integral_constant<sol::type, sol::type::table> {};

	template<typename T>
	sf::Vector2<T> sol_lua_get(sol::types<sf::Vector2<T>>, lua_State* L, int index, sol::stack::record& tracking)
	{
		int absoluteIndex = lua_absindex(L, index);

		sol::table vecTable = sol::stack::get<sol::table>(L, absoluteIndex);

		sf::Vector2<T> vec;
		vec.x = vecTable.get_or("x", T(0));
		vec.y = vecTable.get_or("y", T(0));

		tracking.use(1);

		return vec;
	}

	template<typename T>
	int sol_lua_push(sol::types<sf::Vector2<T>>, lua_State* L, const sf::Vector2<T>& vec)
	{
		lua_createtable(L, 0, 2);

		sol::stack_table vecTable(L);
		vecTable["x"] = vec.x;
		vecTable["y"] = vec.y;

		return 1;
	}
}

int main()
{
	sf::RenderWindow window(sf::VideoMode(1280, 720), "SFML Project");
	window.setVerticalSyncEnabled(true);

	sf::Clock clock;

	sol::state state;
	state.open_libraries();

	state.new_usertype<sf::RenderWindow>("Window"
		"new", sol::no_constructor,
		"GetSize", &sf::RenderWindow::getSize);

	state["Window"] = &window;

	while (window.isOpen())
	{
		sf::Event event;
		while (window.pollEvent(event))
		{
			switch (event.type)
			{
				case sf::Event::Closed:
					window.close();
					break;

				case sf::Event::KeyPressed:
				{
					if (event.key.code == sf::Keyboard::F5)
					{
						auto result = state.safe_script_file("game.lua");
						if (!result.valid())
						{
							std::string err = result;
							std::cerr << "failed to load game.lua: " << err << std::endl;
						}
					}

					break;
				}

				default:
					break;
			}
		}

		float elapsedTime = clock.restart().asSeconds();

		window.clear();

		window.display();
	}
}
