"""The games on the Games page: each assembles, and plays on a real C64."""

import json

import pytest

from tests.test_utils import STATIC_DIR, create_c64_context, load_js_modules

GAMES_DIR = STATIC_DIR / "games"
GAMES = json.loads((GAMES_DIR / "index.json").read_text(encoding="utf-8"))["examples"]
# The page tells players a saved game starts with SYS 2064.
GAME_START = 2064


def test_the_library_lists_every_game_file():
    listed = sorted(game["file"] for game in GAMES)
    assert listed == sorted(path.name for path in GAMES_DIR.glob("*.asm"))
    assert len({game["id"] for game in GAMES}) == len(GAMES)


@pytest.fixture(scope="module")
def c64():
    ctx = create_c64_context()
    load_js_modules(ctx, ["assembler.js"])
    ctx.eval(
        """
        const READY = [18, 5, 1, 4, 25, 46];
        function atReady(machine) {
            for (let a = 0x400; a < 0x7e8 - READY.length; a++) {
                if (READY.every((code, i) => machine.peek(a + i) === code)) return true;
            }
            return false;
        }

        // Boot, enter the game as the lab does (like SYS, with I clear),
        // leave it on its title screen, then press fire to start a game.
        function playGame(source) {
            const result = new Assembler().assemble(source);
            if (!result.success) {
                return { errors: result.errors.map(e => `${e.lineNum}: ${e.message}`) };
            }
            const machine = new C64Machine({ audioEnabled: false });
            for (let frame = 0; frame < 300 && !atReady(machine); frame++) machine.runFrame();
            const cpu = machine.cpu;
            const inRom = pc => (pc >= 0xA000 && pc < 0xC000) || pc >= 0xE000;
            for (let n = 20000; (cpu.P & 4) && inRom(cpu.PC) && n > 0; n--) cpu.step();
            cpu.P &= ~(4 | 8);
            machine.loadCode(result.bytes, result.startAddress);
            cpu.PC = result.startAddress;

            const end = result.startAddress + result.bytes.length;
            const ownsIrq = () => {
                const vector = machine.peek(0x314) | (machine.peek(0x315) << 8);
                return vector >= result.startAddress && vector < end;
            };
            const screen = () => Array.from({ length: 1000 }, (_, i) => machine.peek(0x400 + i));
            const run = frames => {
                for (let i = 0; i < frames && !cpu.halted; i++) machine.runFrame();
            };

            run(100);
            const title = screen();
            const titleOwnsIrq = ownsIrq();
            machine.setJoystickButton(2, 'fire', true);
            run(5);
            machine.setJoystickButton(2, 'fire', false);
            run(150);
            const playing = screen();
            return {
                errors: [],
                start: result.startAddress,
                halted: cpu.halted,
                titleOwnsIrq,
                playingOwnsIrq: ownsIrq(),
                screenChanged: playing.some((code, i) => code !== title[i])
            };
        }
        """
    )
    return ctx


@pytest.mark.parametrize("game", GAMES, ids=[game["id"] for game in GAMES])
def test_game_assembles_and_plays(c64, game):
    source = (GAMES_DIR / game["file"]).read_text(encoding="utf-8")
    result = json.loads(c64.eval(f"JSON.stringify(playGame({json.dumps(source)}))"))
    assert result["errors"] == []
    assert result["start"] == GAME_START
    assert not result["halted"]
    # Each game runs from its own raster interrupt, title screen included...
    assert result["titleOwnsIrq"]
    # ...and fire starts a game that is still running.
    assert result["screenChanged"]
    assert result["playingOwnsIrq"]
