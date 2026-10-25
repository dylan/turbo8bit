# Input controls

The BASIC, Assembly and Games labs share an opt-in input dock. Select **Input
controls** in the screen toolbar, then choose a device. Its details distinguish
what the browser detects from whether the emulator is capturing input. Gamepad
capture starts automatically when a controller connects. Connecting from the dock
returns focus to the C64 screen unless you have moved to another control. Input
releases when the screen loses focus. You can turn capture off at any time.
Mouse capture starts off.

## JavaScript API

The emulator handles input independently of the optional dock:

```js
emulator.startGamepadDiscovery(); // Capture starts when a controller connects.
emulator.setMouseEnabled(true);
const state = emulator.getInputState();
const unsubscribe = emulator.onInputChange(state => {
    // state.gamepad: enabled, autoCapture, connection, status, name, transport, ready,
    //                hidAvailable, hidConnected, mapping, error
    // state.mouse: enabled, captured, status
});
unsubscribe();
```

Selecting the Gamepad thumbnail starts discovery. A supported connection enables
capture and uses the selected joystick port, defaulting to port 2. HID input still
waits for a supported report before forwarding anything. Screen focus, page focus,
visibility and execution gates apply even when capture is enabled.

Turning capture off with `setGamepadEnabled(false)` also turns off automatic
capture, so polling, reconnecting or receiving the first HID report cannot undo
that choice. Use `setGamepadEnabled(true)` to turn it back on, or
`setGamepadAutoCapture(true)` to restore automatic capture on connection.

Hosts that want observation without capture can configure it at construction:

```js
const emulator = new C64Emulator('screen', { gamepadAutoCapture: false });
emulator.startGamepadDiscovery();
```

`setGamepadAutoCapture(false)` changes the policy for future automatic starts;
use `setGamepadEnabled(false)` to stop capture that is already on. Discovery
continues with capture off. No Gamepad API calls run before discovery or capture
is requested. A connected indicator means the browser exposes a usable
controller; pairing with the computer happens in the operating system.

### Controller bindings

The default mapping uses standard browser controllers and normalized HID input.
A host can replace the mapping through JavaScript, independently of the dock. The mapper runs synchronously on fresh snapshots, including while capture
is off, and returns pressed C64 actions: `up`, `down`, `left`, `right`, `fire`.
Return an empty array or set for neutral input, or `null` to skip a device. The
first accepted native controller takes priority over a direct HID connection.
The callback receives the complete snapshot and `{ transport: 'gamepad' | 'hid' }`.

For a different dead zone while keeping the default layout:

```js
import { mapGamepadToJoystick } from './web/static/js/emulator/gamepad-mapping.js';

emulator.setGamepadMapper((pad, { transport }) => {
    if (transport === 'gamepad' && pad.mapping !== 'standard') return null;
    return mapGamepadToJoystick(pad, { deadZone: 0.2 });
});
```

For example, a horizontal game could select browser controller index 1 and use
its second stick and button 7, including a nonstandard layout:

```js
emulator.setGamepadMapper((pad, { transport }) => {
    if (transport !== 'gamepad' || pad.index !== 1) return null;
    const actions = [];
    if (pad.axes[2] < -0.25) actions.push('left');
    if (pad.axes[2] > 0.25) actions.push('right');
    if (pad.buttons[7]?.pressed) actions.push('fire');
    return actions;
});

emulator.setGamepadMapper(null); // Restore automatic standard bindings.
```

Changing the mapper recomputes held actions immediately. Returned sets are copied,
so reusing a mutable set cannot leave old buttons held. Changing bindings does
not start discovery. Once discovery is active, newly accepted controllers follow
the current capture policy. `state.gamepad.mapping` is `default` or `custom`;
the dock uses matching instructions. Invalid output or a thrown mapper error
releases gamepad holds, preserves other sources, and exposes `state.gamepad.error`.
The mapper can be corrected while the emulator runs.

Generic HID snapshots also retain extra absolute axes in `pad.hid.axes`, keyed
by full HID usage (for example `0x10033` for Rx), and numbered buttons in
`pad.hid.buttons` (for example `7`). These do not collide with the normalized
d-pad button positions. Unreported controls are absent; a custom mapper can
skip the device until its needed controls arrive. Native snapshots keep their
browser-provided `axes`, `buttons`, `index`, `id` and `mapping`.

### Direct HID connections

On browsers with WebHID, **Connect controller** offers a direct connection if
automatic detection fails. Invoke this from a user click so the browser can
show its gamepad and joystick chooser:

```js
connectButton.addEventListener('click', async () => {
    await emulator.connectGamepadHid();
    // Capture starts automatically; an explicit Off choice is respected.
});
// Explicitly close a direct connection when it is no longer wanted:
await emulator.disconnectGamepadHid();
```

The chooser filters by HID gamepad and joystick usages, without a vendor or
product restriction. The read-only adapter interprets the controller's report
descriptor: absolute X/Y axes, four- or eight-way hats, digital d-pad usages and
the first four HID buttons. Those buttons fire; HID usages do not identify their
physical face positions. Packed fields, signed values and controls split across
report IDs are supported. Reports flatten nested collections once, preserve
padding and update only their own controls.

Unsupported descriptors fail with an inline explanation before opening a device.
This includes vendor-only formats without a verified profile, array or relative
controls, and report IDs shared across top-level collections where field offsets
are ambiguous. Compatibility decoding applies only to verified report formats;
other proprietary formats need a host-supplied decoder. Built-in stick decoding
uses fixed centers and sends no initialization, rumble, calibration or feature
commands.

An open connection shows **Waiting for input** until supported reports for all
mapped controls arrive. Native standard Gamepad input takes priority if both
paths expose a controller. Capture and mouse/keyboard sources remain independent
through connection changes and cancellation. Direct HID is optional; availability
depends on the browser, operating system and the device's readable input format.

A host can supply `filters` and `createDecoder` for a verified device format:

```js
await emulator.connectGamepadHid({
    filters: controllerFilters,
    createDecoder: createControllerDecoder
});
```

`filters` is a nonempty array of native WebHID filters. Omitting it keeps the
gamepad/joystick chooser. Custom filters allow a host to target vendor collections
when it has a verified decoder. No chooser opens before an explicit connection.
`createDecoder(info)` receives only `vendorId`, `productId`, `productName` and
`collections`, with no device open/output methods. It returns `null` for an
unsupported interface, or a synchronous `(reportId, data, pad) => boolean`.
The report ID is separate from its `DataView`. The decoder updates the neutral
snapshot's axes and `{ pressed, value }` buttons, and returns `true` when usable
input is available. Axes must be finite within `[-1, 1]`; button values are
`[0, 1]` with boolean `pressed` fields. Decoder failures release gamepad input and
show an error; a later valid report can recover. Other input sources keep working.

Hosts can compose their factory with the exported `createHidGamepadDecoder`
from `gamepad-hid-reports.js` for built-in descriptors/profiles. The first connection
attempt owns its options until it finishes; disconnect before choosing different
options. Successful connections follow the capture policy; cancellation and
failure preserve the current capture settings.

### Dock content and visibility

A host can use its own button and switch the overlay on or off:

```js
import { attachInputControls } from './web/static/js/lab/input-controls.js';

const controls = attachInputControls(emulator, {
    frame: document.getElementById('screenFrame'),
    trigger: document.getElementById('myInputButton'),
    enabled: false,
    devices: ['gamepad']
});
controls.setEnabled(true);
controls.setOpen(true);
controls.setOpen(false);
controls.setDevices(['mouse', 'gamepad']); // Both devices, in this order.
controls.setDevices([]); // Hide all controls without disabling input.
controls.setEnabled(false);
controls.destroy();
```

`devices` defaults to `['gamepad', 'mouse']`; `setDevices` changes the visible
controls and their order. Removing a focused device restores focus to another
visible device or the canvas. Empty lists hide the trigger and dock. Hiding a
source does not disable it. A host using `attachScreenTools` can pass the same
options as `inputControls: { devices: ['gamepad'] }` and use its returned
`inputControls` handle.

The optional `connectGamepad` callback replaces the dock's connect action. For
example, `connectGamepad: () => emulator.connectGamepadHid({ createDecoder })`
uses the host's decoder with the same native chooser, pending state, error
feedback and focus restoration. Invoke the connection synchronously inside the
callback to preserve the browser's user activation.

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
thumbnails reveals device details on selection, with a capture
switch. Controllers start capture on connection by default. The outside button inherits the parent toolbar's dimensions and style.
The in-frame controls use the supplied gamepad and mouse icons, 36px faces and
44px hit targets. Entrance is 180ms with a 45ms stagger from the right and 24px
travel; exit is 130ms. Only transform and opacity animate. Keyboard activation
and reduced motion are instant.

Rejected: detached tiles separated the device controls visually; persistent
labels used more picture space; the earlier large instruction block overwhelmed
the tiny icons. Device details stay available on selection instead of appearing
as a large initial overlay.

Report layouts follow the [WebHID dictionaries](https://hid.spec.whatwg.org/#hidcollectioninfo-dictionary)
and [USB HID usage tables](https://www.usb.org/sites/default/files/hut1_21_0.pdf).
