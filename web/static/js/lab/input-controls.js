const GAMEPAD_ICON = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="none" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path fill="currentColor" fill-rule="evenodd" clip-rule="evenodd" d="M1 11.667A7.667 7.667 0 0 1 8.667 4h6.666A7.667 7.667 0 0 1 23 11.667v5.243a4.09 4.09 0 0 1-7.748 1.829l-.146-.292A2.62 2.62 0 0 0 12.764 17h-1.528c-.992 0-1.898.56-2.342 1.447l-.145.292A4.09 4.09 0 0 1 1 16.909zM15.982 9.19a1 1 0 0 0-1.964-.382v.001a1 1 0 0 0 1.963.382zM9 9a1 1 0 1 0-2 0v1H6a1 1 0 1 0 0 2h1v1a1 1 0 1 0 2 0v-1h1a1 1 0 1 0 0-2H9zm9.982 3.19a1 1 0 0 0-1.963-.38h0a1 1 0 0 0 1.963.382z"/></svg>`;
const MOUSE_ICON = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="none" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path fill="currentColor" d="M19 14v-4a7 7 0 1 0-14 0v4a7 7 0 1 0 14 0Z" opacity=".28"/><path stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10V8m0 13a7 7 0 0 1-7-7v-4a7 7 0 0 1 14 0v4a7 7 0 0 1-7 7Z"/></svg>`;
const CLOSE_ICON = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" aria-hidden="true" focusable="false"><path d="m6 6 12 12M18 6 6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>`;
let nextControlsId = 0;

function gamepadInfo({ gamepad: pad }) {
    const connected = ['active', 'connected'].includes(pad.connection);
    const connection = connected ? 'Connected'
        : { off: 'Not checked', waiting: 'Waiting for browser', unsupported: 'Unsupported mapping', unavailable: 'Unavailable' }[pad.connection];
    let guidance = 'Focus this page and press a controller face button. Pair it in your computer’s settings if needed. If already paired and still not detected, try USB or another browser.';
    if (connected) guidance = !pad.enabled ? 'This browser can see your controller. Turn capture on when you want to play.'
        : pad.connection === 'active' ? 'D-pad or left stick moves. Any face button fires.' : pad.status;
    else if (pad.connection === 'unsupported') guidance = 'This browser sees the controller, but its button mapping is unsupported. Use another controller or the keyboard.';
    else if (pad.connection === 'unavailable') guidance = 'This browser cannot access a gamepad. You can still use the keyboard.';
    return {
        title: 'Gamepad', subtitle: 'Controller input', connection, name: pad.name, guidance,
        enabled: pad.enabled, active: pad.enabled && pad.connection === 'active',
        footnote: 'Connection and capture are separate. Enabled inputs work together while the C64 screen has focus.'
    };
}

function mouseInfo({ mouse }) {
    return {
        title: '1351 mouse', subtitle: 'Proportional mouse input', connection: 'Port 1', name: '',
        enabled: mouse.enabled, active: mouse.enabled && mouse.captured,
        guidance: !mouse.enabled ? 'Turn capture on, then move over the C64 screen. Left and right clicks work independently.'
            : mouse.captured ? 'Move over the C64 screen. Left and right clicks work independently.' : mouse.status,
        footnote: 'The running C64 program must support a 1351 mouse.'
    };
}

// Showing or hiding these controls never changes the emulator's capture settings.
export function attachInputControls(emulator, { frame, trigger, enabled = true }) {
    const canvas = emulator.canvas;
    const controller = new AbortController();
    const options = { signal: controller.signal };
    const id = `input-controls-${++nextControlsId}`;
    const overlay = document.createElement('div');
    overlay.className = 'input-controls';
    overlay.dataset.open = 'false';
    overlay.dataset.instant = 'true';
    overlay.innerHTML = `
        <div class="input-controls__tray" id="${id}-tray" role="group" aria-label="Input devices" inert aria-hidden="true">
            <button type="button" class="input-controls__device" data-input-device="gamepad" aria-label="Gamepad details" aria-expanded="false" aria-controls="${id}-detail" style="--input-controls-order: 1">
                <span class="input-controls__face"><span class="input-controls__icon" aria-hidden="true">${GAMEPAD_ICON}</span><span class="input-controls__indicator" data-input-indicator="gamepad" aria-hidden="true"></span></span>
            </button>
            <button type="button" class="input-controls__device" data-input-device="mouse" aria-label="1351 mouse details" aria-expanded="false" aria-controls="${id}-detail" style="--input-controls-order: 0">
                <span class="input-controls__face"><span class="input-controls__icon" aria-hidden="true">${MOUSE_ICON}</span><span class="input-controls__indicator" data-input-indicator="mouse" aria-hidden="true"></span></span>
            </button>
        </div>
        <section class="input-controls__detail" id="${id}-detail" role="region" aria-label="Device controls" data-visible="false" inert aria-hidden="true">
            <div class="input-controls__detail-head"><div><h3 data-input-title></h3><p data-input-subtitle></p></div><button type="button" class="input-controls__close" data-input-detail-close aria-label="Close device details">${CLOSE_ICON}</button></div>
            <div class="input-controls__detail-body">
                <div class="input-controls__connection"><span data-input-connection-label>Connection</span><strong data-input-connection></strong></div>
                <p class="input-controls__name" data-input-name hidden></p>
                <div class="input-controls__direct" data-input-hid hidden>
                    <button type="button" class="input-controls__direct-button" data-input-hid-toggle aria-describedby="${id}-hid-help">Connect Pro Controller</button>
                    <p class="input-controls__direct-help" id="${id}-hid-help" data-input-hid-help></p>
                    <p class="input-controls__direct-error" id="${id}-hid-error" data-input-hid-error role="alert" hidden></p>
                </div>
                <button type="button" class="input-controls__capture" role="switch" aria-checked="false" data-input-capture><span>Capture input</span><span class="input-controls__capture-right"><span data-input-capture-label>Off</span><span class="input-controls__switch" aria-hidden="true"></span></span></button>
                <p class="input-controls__guidance" data-input-guidance></p>
                <p class="input-controls__footnote" data-input-footnote></p>
            </div>
        </section>
        <span class="input-controls__sr" id="${id}-feedback" role="status" aria-live="polite" data-input-feedback></span>`;
    frame.querySelector('.screen-stage').append(overlay);
    const tray = overlay.querySelector('.input-controls__tray');
    const detail = overlay.querySelector('.input-controls__detail');
    const detailBody = overlay.querySelector('.input-controls__detail-body');
    const devices = [...overlay.querySelectorAll('[data-input-device]')];
    const capture = overlay.querySelector('[data-input-capture]');
    const direct = overlay.querySelector('[data-input-hid]');
    const directToggle = overlay.querySelector('[data-input-hid-toggle]');
    const directHelp = overlay.querySelector('[data-input-hid-help]');
    const directError = overlay.querySelector('[data-input-hid-error]');
    const feedback = overlay.querySelector('[data-input-feedback]');
    const descriptions = (canvas.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean);
    canvas.setAttribute('aria-describedby', [...descriptions, feedback.id].join(' '));
    trigger.setAttribute('aria-controls', tray.id);
    let available = Boolean(enabled);
    let open = false;
    let selected = null;
    let selectionRevision = 0;
    let destroyed = false;
    let hidPending = null;
    let hidError = '';
    let state = emulator.getInputState();

    function update() {
        overlay.dataset.open = String(open);
        tray.inert = !open;
        tray.setAttribute('aria-hidden', String(!open));
        trigger.hidden = !available;
        trigger.setAttribute('aria-expanded', String(open));
        trigger.title = open ? 'Close input controls' : 'Open input controls';
        const pad = gamepadInfo(state), mouse = mouseInfo(state);
        for (const button of devices) {
            const device = button.dataset.inputDevice;
            const info = device === 'gamepad' ? pad : mouse;
            button.dataset.selected = String(selected === device);
            button.setAttribute('aria-expanded', String(selected === device));
            const captureState = info.active ? 'active' : info.enabled ? 'on' : 'off';
            button.setAttribute('aria-label', `${info.title}. ${info.connection}. Capture ${captureState}. Show controls.`);
            const connection = state.gamepad.connection;
            const indicator = device === 'mouse' ? captureState
                : ['connected', 'active'].includes(connection) ? 'connected'
                : ['unsupported', 'unavailable'].includes(connection) ? 'warning'
                : connection === 'waiting' ? 'waiting' : 'off';
            overlay.querySelector(`[data-input-indicator="${device}"]`).dataset.state = indicator;
        }
        const visible = open && selected !== null;
        detail.dataset.visible = String(visible);
        detail.inert = !visible;
        detail.setAttribute('aria-hidden', String(!visible));
        if (visible) {
            const info = selected === 'gamepad' ? pad : mouse;
            detail.setAttribute('aria-label', `${info.title} controls`);
            overlay.querySelector('[data-input-title]').textContent = info.title;
            overlay.querySelector('[data-input-subtitle]').textContent = info.subtitle;
            overlay.querySelector('[data-input-connection-label]').textContent = selected === 'gamepad' ? 'Browser connection' : 'C64 connection';
            overlay.querySelector('[data-input-connection]').textContent = info.connection;
            const name = overlay.querySelector('[data-input-name]');
            name.textContent = info.name;
            name.hidden = !info.name;
            capture.setAttribute('aria-checked', String(info.enabled));
            capture.setAttribute('aria-label', `Capture ${info.title.toLowerCase()} input`);
            overlay.querySelector('[data-input-capture-label]').textContent = info.active ? 'Active' : info.enabled ? 'On' : 'Off';
            overlay.querySelector('[data-input-guidance]').textContent = info.guidance;
            overlay.querySelector('[data-input-footnote]').textContent = info.footnote;
        }
        const hid = state.gamepad;
        const showDirect = visible && selected === 'gamepad' && hid.hidAvailable
            && (hid.hidConnected || hidPending || ['waiting', 'unsupported', 'unavailable'].includes(hid.connection));
        if (!showDirect && direct.contains(document.activeElement) && visible) capture.focus({ preventScroll: true });
        direct.hidden = !showDirect;
        directToggle.disabled = Boolean(hidPending);
        directToggle.setAttribute('aria-busy', String(Boolean(hidPending)));
        directToggle.textContent = hidPending === 'connect' ? 'Connecting…'
            : hidPending === 'disconnect' ? 'Disconnecting…'
            : hid.hidConnected ? 'Disconnect Pro Controller' : 'Connect Pro Controller';
        directHelp.textContent = hid.hidConnected ? 'A direct connection is open. Capture remains a separate control.'
            : 'Try a direct connection if automatic detection fails. Opens a browser device picker for a Nintendo Switch Pro Controller.';
        directError.textContent = hidError;
        directError.hidden = !hidError;
        directToggle.setAttribute('aria-describedby', `${id}-hid-help${hidError ? ` ${id}-hid-error` : ''}`);
        const message = `Gamepad: ${pad.connection}, capture ${pad.active ? 'active' : pad.enabled ? 'on' : 'off'}. Mouse: ${mouse.connection}, capture ${mouse.active ? 'active' : mouse.enabled ? 'on' : 'off'}.`;
        if (feedback.textContent !== message) feedback.textContent = message;
    }

    function restoreFocus() {
        const fullscreen = document.fullscreenElement;
        const target = fullscreen && !fullscreen.contains(trigger) ? canvas : trigger;
        target.focus({ preventScroll: true });
    }

    function setOpen(value) {
        if (destroyed) return;
        const next = available && Boolean(value);
        if (next === open) return;
        if (!next && overlay.contains(document.activeElement)) restoreFocus();
        open = next;
        selected = null;
        selectionRevision++;
        update();
        if (next) detailBody.scrollTop = 0;
    }

    function setEnabled(value) {
        if (destroyed) return;
        const next = Boolean(value);
        const changed = next !== available;
        if (!next && (overlay.contains(document.activeElement) || document.activeElement === trigger)) {
            canvas.focus({ preventScroll: true });
        }
        available = next;
        trigger.hidden = !available;
        if (changed) setOpen(false);
    }

    trigger.addEventListener('click', event => {
        overlay.dataset.instant = String(event.detail === 0);
        setOpen(!open);
        if (open && event.detail === 0) devices[0].focus({ preventScroll: true });
    }, options);
    for (const button of devices) {
        button.addEventListener('click', event => {
            overlay.dataset.instant = String(event.detail === 0);
            const next = selected === button.dataset.inputDevice ? null : button.dataset.inputDevice;
            const changed = next !== null && next !== selected;
            if (changed && next === 'gamepad') emulator.startGamepadDiscovery();
            selected = next;
            selectionRevision++;
            update();
            if (changed) detailBody.scrollTop = 0;
        }, options);
    }
    tray.addEventListener('keydown', event => {
        if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
        event.preventDefault();
        event.stopPropagation();
        overlay.dataset.instant = 'true';
        const current = devices.indexOf(document.activeElement);
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? 1 : (current + 1) % 2;
        devices[next].focus({ preventScroll: true });
    }, options);
    capture.addEventListener('click', event => {
        overlay.dataset.instant = String(event.detail === 0);
        const device = selected;
        const next = !state[device].enabled;
        if (next) canvas.focus({ preventScroll: true });
        if (device === 'gamepad') emulator.setGamepadEnabled(next);
        else emulator.setMouseEnabled(next);
    }, options);
    directToggle.addEventListener('click', async () => {
        if (hidPending) return;
        const disconnecting = state.gamepad.hidConnected;
        const focusBeforePending = document.activeElement;
        const revision = selectionRevision;
        let restorePendingFocus = overlay.contains(focusBeforePending);
        const trackFocus = event => {
            if (![document.body, document.documentElement, focusBeforePending].includes(event.target)) restorePendingFocus = false;
        };
        document.addEventListener('focusin', trackFocus, options);
        hidPending = disconnecting ? 'disconnect' : 'connect';
        hidError = '';
        update();
        try {
            if (disconnecting) await emulator.disconnectGamepadHid();
            else await emulator.connectGamepadHid();
        } catch (error) {
            if (controller.signal.aborted) return;
            hidError = `${disconnecting ? 'Disconnect' : 'Connection'} failed: ${error.message}`;
        } finally {
            document.removeEventListener('focusin', trackFocus);
            if (!controller.signal.aborted) {
                hidPending = null;
                update();
                if (restorePendingFocus && revision === selectionRevision && available && open && selected === 'gamepad'
                    && [document.body, document.documentElement, focusBeforePending].includes(document.activeElement)) {
                    (direct.hidden ? capture : directToggle).focus({ preventScroll: true });
                }
            }
        }
    }, options);
    overlay.querySelector('[data-input-detail-close]').addEventListener('click', () => {
        devices.find(button => button.dataset.inputDevice === selected).focus({ preventScroll: true });
        selected = null;
        selectionRevision++;
        overlay.dataset.instant = 'true';
        update();
    }, options);
    document.addEventListener('keydown', event => {
        if (event.key !== 'Escape' || !open) return;
        event.preventDefault();
        event.stopPropagation();
        overlay.dataset.instant = 'true';
        restoreFocus();
        setOpen(false);
    }, { signal: controller.signal, capture: true });
    document.addEventListener('fullscreenchange', () => {
        if (document.fullscreenElement !== frame || !available) return;
        overlay.dataset.instant = 'true';
        setOpen(true);
    }, options);
    for (const surface of [tray, detail]) {
        for (const type of ['pointerdown', 'pointerup', 'pointermove']) {
            surface.addEventListener(type, event => event.stopPropagation(), options);
        }
    }
    const unsubscribe = emulator.onInputChange(next => {
        state = next;
        update();
    });
    update();
    return {
        setEnabled,
        setOpen,
        destroy() {
            if (destroyed) return;
            if (overlay.contains(document.activeElement) || document.activeElement === trigger) canvas.focus({ preventScroll: true });
            controller.abort();
            unsubscribe();
            overlay.remove();
            trigger.hidden = true;
            trigger.setAttribute('aria-expanded', 'false');
            trigger.removeAttribute('aria-controls');
            const remaining = (canvas.getAttribute('aria-describedby') || '').split(/\s+/).filter(value => value && value !== feedback.id);
            if (remaining.length) canvas.setAttribute('aria-describedby', remaining.join(' '));
            else canvas.removeAttribute('aria-describedby');
            destroyed = true;
        }
    };
}
