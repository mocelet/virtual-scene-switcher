# Virtual Scene Switcher for SmartThings

Meant as a feature-packed companion for smart buttons to facilitate cycling through scenes, forwards and backwards in circular and linear fashion, it can also add multi-tap capabilities to buttons without them. It is able to cycle automatically and in random order supporting long-spanning time frames, useful to easily build presence simulation routines where random lights will turn on after random times.

## Unique features:
- Local execution on hub, no cloud or servers needed.
- Minimizes the number of routines and simplifies them.
- Supports circular and linear cycling in both directions.
- High-level commands to switch scenes or start auto-cycling.
- 'Surprise Me' and random auto-cycling modes to fight monotony!
- Adds multi-tap support for buttons without that feature!
- Auto-cycle supports long-spanning time frames with optional persistence to restore the cycle after a hub or driver restart.
- Configurable debouncing window that can be used as event suppressor for other devices.
- Preset / Recall mode to schedule light changes during the day and activate them only when pressing a button.

## Notes for End Users

Check out the official post at SmartThings Community with instructions and tutorials like how to build a blinker!

- https://community.smartthings.com/t/edge-virtual-scene-switcher-more-than-a-fun-way-to-cycle-through-scenes/280621

The driver can be installed in the hub directly from the 'mocelet-shared' driver channel at:

- https://bestow-regional.api.smartthings.com/invite/Kr2zNDg0Wr2A

## Credits and implementation details

The work was initially inspired by [Todd Austin's Counter Utility](https://github.com/toddaustin07/counter_utility) which was the solution I used to track scene numbers and switch them with smart buttons. It also helped me a lot to understand how virtual devices in SmartThings work. Thanks, Todd!

At its core, this driver is a specialised virtual counter with a few twists and scene-oriented design decisions. It does not need extra routines to handle the cycling and can even perform automatic cycling with customizable delay and direction. It can reactivate the current scene to restore the state with a button after turning off the lights. The automation actions are all in the Main component to avoid issues with SmartThings sometimes not displaying certain component actions. Added support for long-spanning time frames extends the possible use cases.

## License

The driver is released under the [Apache 2.0 License](LICENSE).