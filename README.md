# Virtual Scene Switcher for SmartThings

Virtual device for SmartThings that facilitates cycling through scenes with smart buttons, forwards and backwards in circular and linear fashion, as well as pre-setting scenes for a later recall.

## Unique features:
- Minimizes the number of routines needed and simplifies them.
- Keeps track of the currently activated scene.
- Pre-set scene survives hub and driver restarts.
- Supports circular and linear cycling in both directions.
- Recall feature to activate the last active or pre-set scene.
- Actions to switch to next / previous / initial / final scene.

## Notes for End Users

Check out the official post at SmartThings Community with use cases and instructions.

The driver can be installed in the hub directly from the 'mocelet-shared' driver channel at:

- https://bestow-regional.api.smartthings.com/invite/Kr2zNDg0Wr2A

## Credits and implementation details

The work is inspired by [Todd Austin's Counter Utility](https://github.com/toddaustin07/counter_utility) which was the solution I used to track scenes and switch them with smart buttons. It also helped me a lot to understand how virtual devices in SmartThings work. Thanks, Todd!

In a way, this driver is a counter utility specialized in scene switching. It does not need extra routines to handle the cycling and can pre-set the scene number without triggering the associated routine. It can also re-trigger the last active scene, useful to restore the state after turning off the lights. The automation actions are all in the Main component to avoid issues with SmartThings sometimes not displaying certain actions.

## License

The driver is released under the [Apache 2.0 License](LICENSE).