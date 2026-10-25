# Input controls

The BASIC, Assembly and Games labs share an opt-in input dock. Select **Input
controls** in the screen toolbar, then choose a device. Its details distinguish
what the browser detects from whether the emulator is capturing input. Turning
capture on focuses the C64 screen; input releases when the screen loses focus.

## JavaScript API

The emulator handles input independently of the optional dock:

```js
emulator.startGamepadDiscovery(); // Detect without forwarding input.
emulator.setGamepadEnabled(true);
emulator.setMouseEnabled(true);
const state = emulator.getInputState();
const unsubscribe = emulator.onInputChange(state => {
    // state.gamepad: enabled, connection, status, name, transport, ready,
    //                hidAvailable, hidConnected
    // state.mouse: enabled, captured, status
});
unsubscribe();
```

Both devices start disabled. Selecting the Gamepad thumbnail starts discovery
without enabling capture or changing the joystick port. A host can start it
explicitly with `startGamepadDiscovery()`; enabling gamepad input also starts
discovery. Observation continues afterwards, including while capture is off. A connected indicator means the browser exposes a usable
controller; pairing with the computer happens in the operating system.

On browsers with WebHID, a Pro Controller can also connect directly. Invoke
this from a user click so the browser can show its device chooser:

```js
connectButton.addEventListener('click', async () => {
    await emulator.connectGamepadHid();
    // Connection does not enable capture or change the joystick port.
});
// Explicitly close a direct connection when it is no longer wanted:
await emulator.disconnectGamepadHid();
```

The optional adapter requests only Nintendo `057e:2009`. It reads verified
`0x21`/`0x30` input reports and sends no initialization, rumble, calibration or
feature commands. Stick normalization uses a fixed center. An open connection
is not marked active until a supported input report arrives; unverified modes
such as `0x3f` remain unready. The browser's standard Gamepad input takes
priority if both paths expose a controller. Capture and mouse/keyboard sources
remain independent through connection changes and cancellation.

A host can use its own button and switch the overlay on or off:

```js
import { attachInputControls } from './web/static/js/lab/input-controls.js';

const controls = attachInputControls(emulator, {
    frame: document.getElementById('screenFrame'),
    trigger: document.getElementById('myInputButton'),
    enabled: false
});
controls.setEnabled(true);
controls.setOpen(true);
controls.setOpen(false);
controls.setEnabled(false);
controls.destroy();
```

The frame contains a `.screen-stage` with the emulator canvas. Include the
project stylesheet for the dock. Hiding or destroying the dock does not change
which input sources are enabled. This lets a host provide its own controls.
All device status, instructions and accessible feedback live inside the frame,
so they remain available in full screen.

## Devices

A standard browser gamepad uses the selected joystick port, defaulting to port
2. The d-pad or left stick controls direction; any of the four face buttons
fires. Keyboard and gamepad holds combine, so releasing one source preserves
the other. The browser may require a controller button press before exposing
it. Unsupported mappings and unavailable browser access have separate states.

Mouse input emulates a proportional Commodore 1351 on port 1. Movement and left
and right buttons work in programs that support that mouse. It does not turn an
ordinary keyboard or joystick game into a mouse-controlled game. Mouse, gamepad
and keyboard can be enabled together. They may share port 1: their digital
button lines combine, and releasing one source preserves the others. Enabling
the mouse never changes the selected joystick port. The machine models nominal
position counters and buttons; it does not simulate SID analog conversion delay
or electrical noise.

## Design decision

Chosen from the thumbnail exploration: **Dock**. A joined pair of compact icon
thumbnails reveals device details on selection, with an explicit capture
switch. The outside button inherits the parent toolbar's dimensions and style.
The in-frame controls use the supplied gamepad and mouse icons, 36px faces and
44px hit targets. Entrance is 180ms with a 45ms stagger from the right and 24px
travel; exit is 130ms. Only transform and opacity animate. Keyboard activation
and reduced motion are instant.

Rejected: detached tiles separated the device controls visually; persistent
labels used more picture space; the earlier large instruction block overwhelmed
the tiny icons. Device details stay available on selection instead of appearing
as a large initial overlay.
