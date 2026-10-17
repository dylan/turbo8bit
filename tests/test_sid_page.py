"""Exercise the SID page controller with controllable fetch/audio promises."""

import re

import pytest

from tests.test_utils import PROJECT_ROOT, create_mini_racer_context, load_js_file


@pytest.fixture
def sid_page():
    ctx = create_mini_racer_context()
    ctx.eval(
        """
        function element(classes = []) {
            const values = new Set(classes);
            return {
                children: [], textContent: '', style: {}, dataset: {},
                disabled: false, listeners: {},
                classList: {
                    add(value) { values.add(value); },
                    remove(value) { values.delete(value); },
                    contains(value) { return values.has(value); },
                    toggle(value, enabled) {
                        if (enabled) values.add(value);
                        else values.delete(value);
                    }
                },
                setAttribute(name, value) { this[name] = value; },
                addEventListener(name, callback) { this.listeners[name] = callback; },
                appendChild(child) { this.children.push(child); },
                replaceChildren() { this.children = []; }
            };
        }
        var elements = new Map();
        var songs = [
            element(['sid-btn', 'active']),
            element(['sid-btn']),
            element(['sid-btn'])
        ];
        songs.forEach((song, index) => { song.dataset.url = '/song' + index + '.sid'; });
        var selector = element();
        var ready;
        var document = {
            getElementById(id) {
                if (!elements.has(id)) elements.set(id, element());
                return elements.get(id);
            },
            createElement() { return element(); },
            querySelector(selectorText) {
                if (selectorText === '.sid-btn.active') {
                    return songs.find(song => song.classList.contains('active'));
                }
                if (selectorText === '.sid-selector-horizontal') return selector;
                return null;
            },
            querySelectorAll(selectorText) {
                if (selectorText === '.sid-btn') return songs;
                return [...songs, ...this.getElementById('track-selector').children];
            },
            addEventListener(name, callback) {
                if (name === 'DOMContentLoaded') ready = callback;
            }
        };
        var requestAnimationFrame = () => 1;
        var cancelAnimationFrame = () => {};
        var setTimeout = () => 1;
        var loads = [];
        var playerInstance;
        var SIDPlayer = class {
            constructor() {
                playerInstance = this;
                this.playCalls = 0;
                this.stopCalls = 0;
                this.state = {
                    name: '', author: '', released: '', currentSong: 1,
                    totalSongs: 1, elapsedTime: 0, frameCount: 0,
                    voices: [], registers: []
                };
            }
            load(url) {
                return new Promise((resolve, reject) => {
                    loads.push({
                        url, reject,
                        resolve: () => { this.state.name = url; resolve(); }
                    });
                });
            }
            getState() { return this.state; }
            play() {
                this.playCalls++;
                if (this.failPlayback) return Promise.reject(new Error('Audio unavailable'));
                if (this.deferPlayback) {
                    return new Promise((resolve, reject) => {
                        this.pendingPlayback = { resolve, reject };
                    });
                }
                return Promise.resolve();
            }
            stop() {
                this.stopCalls++;
                if (this.pendingPlayback) {
                    const error = new Error('Playback cancelled');
                    error.name = 'AbortError';
                    this.pendingPlayback.reject(error);
                    this.pendingPlayback = null;
                }
            }
            changeTrack(index) {
                if (this.failTrackChange) throw new Error('Track unavailable');
                this.stop();
                this.state.currentSong = index + 1;
            }
        };
        function chooseSong(index) {
            return selector.listeners.click({ target: songs[index] });
        }
        """
    )
    template = load_js_file(PROJECT_ROOT / "web" / "templates" / "sid.html")
    script = re.search(r"<script>\s*(.*?)</script>", template, re.DOTALL)
    assert script is not None
    ctx.eval(script.group(1))
    ctx.eval("ready();")
    return ctx


def test_playback_is_disabled_until_a_song_has_loaded(sid_page):
    ctx = sid_page
    assert ctx.eval("document.getElementById('btn-play').disabled")
    assert ctx.eval("document.getElementById('btn-restart').disabled")
    ctx.eval("loads[0].resolve();")
    assert not ctx.eval("document.getElementById('btn-play').disabled")


def test_failed_song_load_cannot_autoplay_the_previous_song(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval("chooseSong(1);")
    ctx.eval("loads[1].reject(new Error('Offline'));")
    assert ctx.eval("playerInstance.playCalls") == 0
    assert ctx.eval("document.getElementById('btn-play').disabled")
    assert ctx.eval("document.getElementById('song-title').textContent") == "Load Error"
    assert "could not be loaded" in ctx.eval(
        "document.getElementById('player-status').textContent"
    )
    assert not ctx.eval("songs[1].disabled")


def test_song_requests_cannot_overlap(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval("chooseSong(1); chooseSong(2);")
    assert ctx.eval("loads.length") == 2
    ctx.eval("loads[1].resolve();")
    assert ctx.eval("playerInstance.playCalls") == 1
    assert ctx.eval("document.getElementById('song-title').textContent") == "/song1.sid"


def test_failed_playback_restores_controls_and_reports_error(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval("playerInstance.failPlayback = true; chooseSong(1);")
    ctx.eval("loads[1].resolve();")
    assert ctx.eval("document.getElementById('btn-play').textContent") == "\u25b6 PLAY"
    assert not ctx.eval("document.getElementById('btn-play').disabled")
    assert "could not start" in ctx.eval(
        "document.getElementById('player-status').textContent"
    )


def test_retry_after_failed_song_load_can_play(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].reject(new Error('Offline'));")
    ctx.eval("chooseSong(0);")
    ctx.eval("loads[1].resolve();")
    assert ctx.eval("playerInstance.playCalls") == 1
    assert ctx.eval("document.getElementById('player-status').textContent") == ""


def test_pending_playback_can_be_cancelled_without_an_error_banner(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval(
        """
        playerInstance.deferPlayback = true;
        document.getElementById('btn-play').listeners.click();
        """
    )
    assert not ctx.eval("document.getElementById('btn-play').disabled")
    assert ctx.eval("document.getElementById('btn-play').textContent") == "\u25a0 STOP"
    ctx.eval("document.getElementById('btn-play').listeners.click();")
    assert ctx.eval("playerInstance.stopCalls") == 1
    assert ctx.eval("document.getElementById('btn-play').textContent") == "\u25b6 PLAY"
    assert ctx.eval("document.getElementById('player-status').textContent") == ""


def test_restart_resumes_after_change_track_leaves_player_stopped(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval("document.getElementById('btn-play').listeners.click();")
    ctx.eval("document.getElementById('btn-restart').listeners.click();")
    assert ctx.eval("playerInstance.playCalls") == 2
    assert ctx.eval("document.getElementById('btn-play').textContent") == "\u25a0 STOP"


def test_track_selection_while_stopped_does_not_autoplay(sid_page):
    ctx = sid_page
    ctx.eval("playerInstance.state.totalSongs = 2; loads[0].resolve();")
    ctx.eval("document.getElementById('track-selector').children[1].listeners.click();")
    assert ctx.eval("playerInstance.state.currentSong") == 2
    assert ctx.eval("playerInstance.playCalls") == 0


def test_track_change_failure_is_reported_without_stopping_playback(sid_page):
    ctx = sid_page
    ctx.eval("loads[0].resolve();")
    ctx.eval("document.getElementById('btn-play').listeners.click();")
    ctx.eval(
        """
        playerInstance.failTrackChange = true;
        document.getElementById('track-selector').children[0].listeners.click();
        """
    )
    assert ctx.eval("document.getElementById('btn-play').textContent") == "\u25a0 STOP"
    assert "could not" in ctx.eval(
        "document.getElementById('player-status').textContent"
    )


def mix_button(kind, voice):
    return (
        "{ dataset: { voice: '%d' }, closest() { return this; },"
        " classList: { contains: name => name === 'voice-%s' } }" % (voice, kind)
    )


def test_mute_and_solo_silence_voices_in_the_player(sid_page):
    ctx = sid_page
    ctx.eval(
        """
        loads[0].resolve();
        var silenced = [false, false, false];
        playerInstance.setVoiceMuted = (voice, muted) => { silenced[voice] = muted; };
        var mixClick = document.getElementById('voice-visualizer').listeners.click;
        """
    )
    ctx.eval(f"mixClick({{ target: {mix_button('mute', 0)} }});")
    assert ctx.eval("JSON.stringify(silenced)") == "[true,false,false]"
    ctx.eval(f"mixClick({{ target: {mix_button('solo', 2)} }});")
    assert ctx.eval("JSON.stringify(silenced)") == "[true,true,false]"
    # Leaving solo restores the voices that were not muted.
    ctx.eval(f"mixClick({{ target: {mix_button('solo', 2)} }});")
    assert ctx.eval("JSON.stringify(silenced)") == "[true,false,false]"


def test_voice_frequencies_are_named_as_notes(sid_page):
    ctx = sid_page
    ctx.eval(
        """
        const voice = freq => ({
            freq, waveform: 'PULSE', pulseWidth: 2048, envelope: 200, gate: true,
            attack: 0, decay: 0, sustain: 0, release: 0
        });
        // 7493 * 985248 / 2^24 = 440 Hz on a PAL C64; 0 is silent.
        playerInstance.state.voices = [voice(7493), voice(3747), voice(0)];
        playerInstance.state.clockFrequency = 985248;
        loads[0].resolve();
        """
    )
    notes = [
        ctx.eval(f"document.getElementById('note-{v}').textContent") for v in range(3)
    ]
    assert notes == ["A4", "A3", "\u2014"]


def test_own_sid_button_opens_the_file_picker(sid_page):
    # The picker input is hidden, so a focusable button has to open it.
    ctx = sid_page
    ctx.eval(
        """
        var picker = document.getElementById('sid-file');
        picker.click = () => { picker.opened = true; };
        document.getElementById('sid-file-btn').listeners.click();
        """
    )
    assert ctx.eval("picker.opened === true")
