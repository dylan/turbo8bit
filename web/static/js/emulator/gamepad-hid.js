import { createHidGamepadDecoder } from './gamepad-hid-reports.js';

const GAMEPAD_FILTERS = [{ usagePage: 0x01, usage: 0x04 }, { usagePage: 0x01, usage: 0x05 }];

export class HidGamepadInput {
    constructor(onChange = () => {}) {
        this.onChange = onChange;
        this.connected = false;
        this.ready = false;
        this.error = '';
        this.gamepad = null;
        this._device = null;
        this._hid = null;
        this._inputListener = null;
        this._disconnectListener = null;
        this._generation = 0;
        this._connecting = null;
        this._closing = null;
        this._decoder = null;
    }

    connect({ filters = GAMEPAD_FILTERS, createDecoder = createHidGamepadDecoder } = {}) {
        if (!Array.isArray(filters) || !filters.length) throw new TypeError('Provide at least one HID device filter.');
        if (typeof createDecoder !== 'function') throw new TypeError('createDecoder must be a function.');
        if (this._connecting) return this._connecting;
        if (this.connected) return Promise.resolve(true);
        const pending = this._connect(++this._generation, filters, createDecoder);
        this._connecting = pending;
        const clearPending = () => {
            if (this._connecting === pending) this._connecting = null;
        };
        pending.then(clearPending, clearPending);
        return pending;
    }

    async _connect(generation, filters, createDecoder) {
        const hid = globalThis.navigator?.hid;
        if (!hid || typeof hid.requestDevice !== 'function') {
            throw new Error('This browser does not support WebHID. Use the Gamepad API or a browser with WebHID support.');
        }
        let devices;
        try {
            devices = await hid.requestDevice({ filters });
        } catch (error) {
            if (generation !== this._generation || error.name === 'NotFoundError') return false;
            throw error;
        }
        if (generation !== this._generation) return false;
        if (!devices.length) return false;
        let device, decoder;
        for (const candidate of devices) {
            const { vendorId, productId, productName, collections } = candidate;
            decoder = createDecoder({ vendorId, productId, productName, collections });
            if (decoder !== null && typeof decoder !== 'function') {
                throw new TypeError('createDecoder must return a report decoder function, or null for an unsupported device.');
            }
            if (decoder) { device = candidate; break; }
        }
        if (!device) {
            throw new Error('This controller’s input format is unsupported. Try automatic detection, another browser or the keyboard.');
        }
        if (this._closing) await this._closing;
        if (generation !== this._generation) return false;

        this._device = device;
        this._decoder = decoder;
        this._hid = hid;
        this._inputListener = event => {
            if (generation === this._generation && this._device === device && this.connected) {
                this._readReport(event.reportId, event.data);
            }
        };
        this._disconnectListener = event => {
            if (generation === this._generation && event.device === device && this._device === device) {
                void this.disconnect();
            }
        };
        device.addEventListener('inputreport', this._inputListener);
        hid.addEventListener('disconnect', this._disconnectListener);
        try {
            if (!device.opened) await device.open();
            if (generation !== this._generation) {
                await this._closeIfUnclaimed(device);
                return false;
            }
            this.gamepad = {
                id: device.productName || 'Controller',
                connected: true,
                mapping: '',
                axes: [0, 0],
                buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
                hid: { axes: {}, buttons: {} }
            };
            this.connected = true;
            this.ready = false;
            this.error = '';
            this.onChange();
            return true;
        } catch (error) {
            if (generation === this._generation && this._device === device) this._detach();
            await this._closeIfUnclaimed(device);
            if (generation !== this._generation) return false;
            throw new Error(`Could not open the controller: ${error.message || error}`);
        }
    }

    async disconnect() {
        ++this._generation;
        this._connecting = null;
        const device = this._device;
        this._detach();
        const changed = this.connected || this.ready;
        this.connected = false;
        this.ready = false;
        this.error = '';
        this.gamepad = null;
        if (changed) this.onChange();
        if (device) await this._closeIfUnclaimed(device);
    }

    _detach() {
        this._device?.removeEventListener('inputreport', this._inputListener);
        this._hid?.removeEventListener('disconnect', this._disconnectListener);
        this._device = null;
        this._hid = null;
        this._inputListener = null;
        this._disconnectListener = null;
        this._decoder = null;
    }

    async _closeDevice(device) {
        if (!device.opened) return;
        try {
            await device.close();
        } catch {
            // Unplugged devices can reject close; input has already been released.
        }
    }

    async _closeIfUnclaimed(device) {
        if (this._device === device || !device.opened) return;
        const closing = this._closeDevice(device);
        const pending = this._closing ? Promise.all([this._closing, closing]) : closing;
        this._closing = pending;
        await pending;
        if (this._closing === pending) this._closing = null;
    }

    _readReport(reportId, data) {
        const previousReady = this.ready, previousError = this.error;
        try {
            const ready = this._decoder(reportId, data, this.gamepad);
            if (typeof ready !== 'boolean') throw new TypeError('A report decoder must return a boolean readiness value.');
            if (!Array.isArray(this.gamepad.axes) || !Array.isArray(this.gamepad.buttons) ||
                this.gamepad.axes.some(axis => !Number.isFinite(axis) || Math.abs(axis) > 1) ||
                this.gamepad.buttons.some(button => !button || typeof button.pressed !== 'boolean' ||
                    !Number.isFinite(button.value) || button.value < 0 || button.value > 1)) {
                throw new TypeError('A report decoder must supply normalized axes and buttons.');
            }
            this.ready = this.ready || ready;
            this.error = '';
        } catch (error) {
            this.ready = false;
            this.error = `Controller input decoding failed: ${error?.message ?? String(error)}`;
            this.gamepad.axes = [0, 0];
            this.gamepad.buttons = Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }));
            this.gamepad.hid = { axes: {}, buttons: {} };
        }
        if (previousReady !== this.ready || previousError !== this.error) this.onChange();
    }
}
