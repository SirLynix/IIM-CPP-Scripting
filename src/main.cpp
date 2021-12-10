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

		sol::protected_function initFunc = state["Init"];
		initFunc();
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

	sf::CircleShape circle(50.f);
	circle.setOrigin(25.f, 25.f);

	sol::state state;
	state.open_libraries();

	state["DrawCircle"] = [&](int x, int y)
	{
		circle.setPosition(x, y);
		window.draw(circle);
	};

	state["IsKeyPressed"] = [&](const std::string& keyName)
	{
		if (keyName == "up")
			return sf::Keyboard::isKeyPressed(sf::Keyboard::Up);
	};

	state["SetWindowTitle"] = [&](const std::string& title)
	{
		window.setTitle(title);
	};

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

		sol::protected_function onFrameFunc = state["OnFrame"];
		onFrameFunc(elapsedTime);

		window.display();
	}
}
