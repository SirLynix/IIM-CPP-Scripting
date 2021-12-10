#include <SFML/Graphics.hpp>
#include <SFML/Window.hpp>
#include <SFML/System.hpp>
#include <sol/sol.hpp>
#include <iostream>

bool ReloadScript(sol::state& state)
{
	try
	{
		state.safe_script_file("game.lua");
		return true;
	}
	catch (const std::exception& e)
	{
		std::cout << "an error occurred: " << e.what() << std::endl;
		return false;
	}
}

int main()
{
	sf::RenderWindow window(sf::VideoMode(1280, 720), "SFML Project");
	window.setVerticalSyncEnabled(true);

	sol::state state;
	state.open_libraries();

	ReloadScript(state);
	
	sf::Clock clock;

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
						ReloadScript(state);

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
