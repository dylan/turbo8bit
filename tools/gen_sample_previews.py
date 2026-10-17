"""Record an animated preview of every BASIC sample on the emulator itself.

Each sample runs on a fresh C64Machine inside py_mini_racer, loaded the way
the BASIC page loads it, and the VIC-II frame buffer is captured every few
frames. Samples that wait for the user get a short scripted session. The
sample gallery shows the results:

    web/static/basic/previews/<id>.webp        animated
    web/static/basic/previews/<id>-still.webp  last frame, for reduced motion

Run with `dd.ps1 gen`, or `python tools/gen_sample_previews.py [id ...]`.
Needs the development packages (py_mini_racer, Pillow).
"""

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tests.test_utils import (  # noqa: E402  (needs ROOT on sys.path)
    JS_STATIC_DIR,
    create_c64_context,
    load_js_modules,
)

BASIC_DIR = ROOT / "web" / "static" / "basic"
OUT_DIR = BASIC_DIR / "previews"
WIDTH, HEIGHT = 384, 272
BOOT_FRAMES = 150
CAPTURE_EVERY = 3
# A change of border or background colour flashes most of the picture, so
# previews show at most one every 334ms: under three flashes a second, as
# WCAG 2.3.1 asks of content that plays by itself.
MIN_FLASH_GAP_MS = 334
FRAME_MS = 20
DEFAULT_FRAMES = 300
# Palette indices travel from JavaScript as text, offset to stay printable.
INDEX_OFFSET = 65
FROM_TEXT = bytes.maketrans(
    bytes(range(INDEX_OFFSET, INDEX_OFFSET + 16)), bytes(range(16))
)

RECORDER_JS = r"""
var previewIndex = new Map(PALETTE.map((rgb, index) => [rgb, index]));
var recorder = null;

function startRecorder() {
    const machine = new C64Machine({ audioEnabled: false });
    for (let i = 0; i < BOOT_FRAMES; i++) machine.runFrame();
    recorder = { machine, keys: [], wait: 0 };
}

function loadSample(source, direct) {
    if (direct) return;
    recorder.machine.loadProgram(new BASICTokenizer().tokenize(source).bytes);
}

// Typing goes through the KERNAL keyboard buffer at a steady pace.
function typeKeys(text) {
    for (const ch of text) recorder.keys.push(ch.charCodeAt(0));
}

function tick() {
    const machine = recorder.machine;
    if (recorder.keys.length && --recorder.wait <= 0 && machine.ram[0xC6] < 10) {
        machine.addKey(recorder.keys.shift());
        recorder.wait = 2;
    }
    machine.runFrame();
    return recorder.keys.length;
}

function frameText() {
    const pixels = recorder.machine.vic.frameBuffer;
    const codes = new Uint8Array(pixels.length);
    for (let i = 0; i < pixels.length; i++) {
        codes[i] = INDEX_OFFSET + (previewIndex.get(pixels[i] & 0xFFFFFF) ?? 0);
    }
    const parts = [];
    for (let i = 0; i < codes.length; i += 8192) {
        parts.push(String.fromCharCode.apply(null, codes.subarray(i, i + 8192)));
    }
    return parts.join('');
}

function waitingForInput() {
    const activity = basicActivity(recorder.machine);
    return activity.mode === 'program' && activity.waiting && recorder.keys.length === 0;
}

// Border and background colour, which flash the most of the picture.
function screenColours() {
    const machine = recorder.machine;
    return `${machine.peekIO(0xD020) & 15},${machine.peekIO(0xD021) & 15}`;
}

function variable(name) {
    const found = readVariables(recorder.machine).variables.find(v => v.name === name);
    return found ? found.value : null;
}
"""


class Recorder:
    def __init__(self, ctx):
        self.ctx = ctx

    def type(self, text):
        self.ctx.eval(f"typeKeys({json.dumps(text)})")

    def joystick(self, port, **state):
        self.ctx.eval(f"recorder.machine.setJoystick({port}, {json.dumps(state)})")

    def peek(self, address):
        return self.ctx.eval(f"recorder.machine.peek({address})")

    def waiting_for_input(self):
        return self.ctx.eval("waitingForInput()")

    def variable(self, name):
        return self.ctx.eval(f"variable({json.dumps(name)})")


def type_at(*steps):
    """Type each text at its frame number."""

    def script(rec, frame):
        for at, text in steps:
            if frame == at:
                rec.type(text)

    return script


def guess_the_number():
    """Play a binary search, reading the secret from the program's variable N."""
    bounds = {"low": 1, "high": 100, "next": 0}

    def script(rec, frame):
        if frame < bounds["next"] or not rec.waiting_for_input():
            return
        secret = rec.variable("N")
        guess = (bounds["low"] + bounds["high"]) // 2
        if guess < secret:
            bounds["low"] = guess + 1
        elif guess > secret:
            bounds["high"] = guess - 1
        rec.type(f"{guess}\r")
        bounds["next"] = frame + 50

    return script


def reaction_test():
    """Press a key about 300ms after the border turns red."""
    seen = {"red": None, "done": False}

    def script(rec, frame):
        if seen["done"]:
            return
        if seen["red"] is None and rec.peek(0xD020) & 0x0F == 2:
            seen["red"] = frame
        elif seen["red"] is not None and frame == seen["red"] + 15:
            rec.type(" ")
            seen["done"] = True

    return script


def joystick_workout(rec, frame):
    """Push each direction on both ports, then fire."""
    moves = [{"up": True}, {"right": True}, {"down": True}, {"left": True}]
    moves += [{"fire": True}, {}]
    step = frame // 40 - 1
    if frame % 40 == 0 and 0 <= step < len(moves):
        for port in (1, 2):
            rec.joystick(port, **moves[step])


def direct_lines(source):
    """Type a direct-mode sample a line at a time, as the page does."""
    lines = [line for line in source.splitlines() if line.strip()]
    return type_at(
        *[(10 + index * 45, line + "\r") for index, line in enumerate(lines)]
    )


# Samples that need a visitor: (frames to record, script)
SCRIPTS = {
    "inputName": (360, type_at((60, "ADA\r"), (160, "ALAN\r"))),
    "guessNumber": (750, guess_the_number()),
    "reactionTest": (420, reaction_test()),
    "diceRoller": (300, type_at((80, " "), (150, " "), (220, " "))),
    "multiplicationTable": (240, type_at((60, "7\r"))),
    "joystickTester": (300, joystick_workout),
}


def record(ctx, palette, example):
    source = (BASIC_DIR / example["file"]).read_text(encoding="utf-8")
    direct = bool(example.get("direct"))
    frames, script = SCRIPTS.get(example["id"], (DEFAULT_FRAMES, None))
    if direct:
        script = direct_lines(source)
    rec = Recorder(ctx)
    ctx.eval("startRecorder()")
    ctx.eval(f"loadSample({json.dumps(source)}, {json.dumps(direct)})")
    if not direct:
        rec.type("RUN\r")

    step = CAPTURE_EVERY * FRAME_MS
    images = []
    durations = []
    previous = None
    shown_colours = None
    since_flash = MIN_FLASH_GAP_MS
    for frame in range(frames):
        if script:
            script(rec, frame)
        ctx.eval("tick()")
        if frame % CAPTURE_EVERY:
            continue
        since_flash += step
        pixels = ctx.eval("frameText()").encode("latin-1").translate(FROM_TEXT)
        colours = ctx.eval("screenColours()")
        flash = shown_colours is not None and colours != shown_colours
        if pixels == previous or (flash and since_flash < MIN_FLASH_GAP_MS):
            durations[-1] += step
            continue
        if flash:
            since_flash = 0
        previous = pixels
        shown_colours = colours
        image = Image.frombytes("P", (WIDTH, HEIGHT), pixels)
        image.putpalette(palette)
        images.append(image.convert("RGB"))
        durations.append(step)
    return images, durations


def save(example_id, images, durations):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    animated = OUT_DIR / f"{example_id}.webp"
    still = OUT_DIR / f"{example_id}-still.webp"
    # Hold the last frame before the loop starts again.
    durations = durations[:-1] + [max(durations[-1], 1500)]
    images[0].save(
        animated,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        lossless=True,
        method=6,
    )
    images[-1].save(still, lossless=True, method=6)
    return animated.stat().st_size, still.stat().st_size


def main(selected):
    examples = json.loads((BASIC_DIR / "index.json").read_text(encoding="utf-8"))[
        "examples"
    ]
    unknown = set(selected) - {example["id"] for example in examples}
    if unknown:
        raise SystemExit(f"Unknown sample id: {', '.join(sorted(unknown))}")

    ctx = create_c64_context()
    load_js_modules(ctx, ["basic-tokenizer.js"])
    load_js_modules(ctx, ["lab/basic-monitor.js"], JS_STATIC_DIR)
    ctx.eval(
        f"var BOOT_FRAMES = {BOOT_FRAMES}; var INDEX_OFFSET = {INDEX_OFFSET};"
        + RECORDER_JS
    )
    palette = []
    for rgb in json.loads(ctx.eval("JSON.stringify(PALETTE)")):
        palette += [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]

    total = 0
    for example in examples:
        if selected and example["id"] not in selected:
            continue
        images, durations = record(ctx, palette, example)
        animated, still = save(example["id"], images, durations)
        total += animated + still
        print(
            f"{example['id']:22} {len(images):4} frames "
            f"{animated / 1024:7.1f} KB + still {still / 1024:5.1f} KB"
        )
    print(f"Total {total / 1024:.0f} KB in {OUT_DIR.relative_to(ROOT)}")


if __name__ == "__main__":
    main(sys.argv[1:])
