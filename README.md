# Virtual Scene Switcher for SmartThings

Feature-packed companion for smart buttons that facilitates cycling through scenes, forwards and backwards in circular and linear fashion. It is able to cycle automatically and in random order plus has some extra perks to fit other use cases and multiple configuration options.

## Unique features:
- Minimizes the number of routines needed and simplifies them.
- Supports circular and linear cycling in both directions.
- Allows re-activating the current scene.
- Actions to switch to next / previous / initial / final scene.
- Auto-cycling actions to cycle through scenes with start/stop.
- 'Surprise me' and random auto-cycling modes to fight monotony!

## Notes for End Users

Check out the official post at SmartThings Community with use cases and instructions.

The driver can be installed in the hub directly from the 'mocelet-shared' driver channel at:

- https://bestow-regional.api.smartthings.com/invite/Kr2zNDg0Wr2A

## Credits and implementation details

The work is inspired by [Todd Austin's Counter Utility](https://github.com/toddaustin07/counter_utility) which was the solution I used to track scenes and switch them with smart buttons. It also helped me a lot to understand how virtual devices in SmartThings work. Thanks, Todd!

At its core, this driver is a specialised virtual counter with a few twists and scene-oriented design decisions. It does not need extra routines to handle the cycling and can even perform automatic cycling with customizable delay and direction. It can reactivate the current scene to restore the state with a button after turning off the lights. The automation actions are all in the Main component to avoid issues with SmartThings sometimes not displaying certain component actions.

## License

The driver is released under the [Apache 2.0 License](LICENSE).