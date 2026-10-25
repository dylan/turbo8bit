import { createHidGamepadDecoder, isGamepadCollection } from './gamepad-hid-reports.js';

export class HidGamepadInput {
    constructor(onChange = () => {}) {
        this.onChange = onChange;
        this.connected = false;
        this.ready = false;
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

    connect() {
        if (this._connecting) return this._connecting;
        if (this.connected) return Promise.resolve(true);
        const pending = this._connect(++this._generation);
        this._connecting = pending;
        const clearPending = () => {
            if (this._connecting === pending) this._connecting = null;
        };
        pending.then(clearPending, clearPending);
        return pending;
    }

    async _connect(generation) {
        const hid = globalThis.navigator?.hid;
        if (!hid || typeof hid.requestDevice !== 'function') {
            throw new Error('This browser does not support WebHID. Use the Gamepad API or a browser with WebHID support.');
        }
        let devices;
        try {
            devices = await hid.requestDevice({ filters: [{ usagePage: 0x01, usage: 0x04 }, { usagePage: 0x01, usage: 0x05 }] });
        } catch (error) {
            if (generation !== this._generation || error.name === 'NotFoundError') return false;
            throw error;
        }
        if (generation !== this._generation) return false;
        const candidates = devices.filter(candidate => candidate.collections.some(isGamepadCollection));
        if (!candidates.length) return false;
        let device, decoder;
        for (const candidate of candidates) {
            decoder = createHidGamepadDecoder(candidate);
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
                id: `${device.productName || 'Controller'} (WebHID)`,
                connected: true,
                mapping: '',
                axes: [0, 0],
                buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 }))
            };
            this.connected = true;
            this.ready = false;
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
        if (this._decoder(reportId, data, this.gamepad) && !this.ready) {
            this.ready = true;
            this.onChange();
        }
    }
}
