const JOYSTICK_ACTIONS = new Set(['up', 'down', 'left', 'right', 'fire']);

export function mapGamepadToJoystick(pad, { deadZone = 0.4 } = {}) {
    if (!Number.isFinite(deadZone) || deadZone < 0 || deadZone >= 1) {
        throw new RangeError('The gamepad dead zone must be between 0 (inclusive) and 1 (exclusive).');
    }
    const buttons = new Set();
    const held = index => pad.buttons[index]?.pressed;
    const x = pad.axes[0] ?? 0, y = pad.axes[1] ?? 0;
    if (x < -deadZone || held(14)) buttons.add('left');
    if (x > deadZone || held(15)) buttons.add('right');
    if (y < -deadZone || held(12)) buttons.add('up');
    if (y > deadZone || held(13)) buttons.add('down');
    if ([0, 1, 2, 3].some(held)) buttons.add('fire');
    return buttons;
}

export function readGamepadMapping(pad, transport, mapper) {
    const mapped = mapper ? mapper(pad, { transport })
        : transport === 'hid' || pad.mapping === 'standard' ? mapGamepadToJoystick(pad) : null;
    if (mapped === null) return null;
    if (!mapped || typeof mapped === 'string' || typeof mapped[Symbol.iterator] !== 'function') {
        throw new TypeError('A gamepad mapper must return an iterable of joystick actions, or null to skip a device.');
    }
    // Copy mutable mapper output so a later packet cannot alter our held state.
    const buttons = new Set(mapped);
    for (const button of buttons) {
        if (!JOYSTICK_ACTIONS.has(button)) throw new TypeError(`Unknown joystick action: ${String(button)}`);
    }
    return buttons;
}
