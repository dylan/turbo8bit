"""VIC register-view, glyph selection, and sprite occupancy regressions."""

import pytest

from tests.test_utils import create_c64_context, eval_json


@pytest.fixture(scope="module")
def vic_context():
    ctx = create_c64_context()
    ctx.eval(
        """
        function regressionVideoMachine() {
            const m = new C64Machine({audioEnabled: false});
            // YSCROLL=3, as the KERNAL sets it, puts row 0 at raster 51.
            m.write(0xD011, 0x1B);
            m.write(0xD016, 8);
            m.write(0xD018, 0x18);
            m.write(0xD020, 2);
            m.write(0xD021, 0);
            m.write(0x0400, 1);
            m.write(0xD800, 1);
            return m;
        }

        function regressionSprite(m, sprite, color) {
            m.write(0xD000 + sprite * 2, 24);
            m.write(0xD001 + sprite * 2, 50);
            m.write(0x07F8 + sprite, 0xC0 + sprite);
            for (let row = 0; row < 21; row++) {
                m.write(0x3000 + sprite * 64 + row * 3, 0x80);
            }
            m.write(0xD027 + sprite, color);
        }
        """
    )
    return ctx


@pytest.mark.parametrize("vic_bank", [0, 2])
@pytest.mark.parametrize(
    "renderer,multicolor",
    [
        ("renderScanlineStandardCharacter", False),
        ("renderScanlineMulticolorCharacter", False),
        ("renderScanlineMulticolorCharacter", True),
        ("renderScanlineExtendedBackground", False),
    ],
)
def test_character_rom_half_is_selected(vic_context, vic_bank, renderer, multicolor):
    result = eval_json(
        vic_context,
        f"""(() => {{
            const m = regressionVideoMachine();
            m.write(0xDD00, {3 - vic_bank});
            m.write({vic_bank * 0x4000 + 0x0400}, 1);
            m.write(0xD018, 0x16);
            m.write(0xD800, {9 if multicolor else 1});
            m.write(0xD022, 2);
            m.write(0xD023, 3);
            const r = m.vic.renderer;
            const addresses = r.getMemoryAddresses(m);
            let differences = 0;
            for (let y = 0; y < 8; y++) {{
                m.vic.frameBuffer.fill(PALETTE[0]);
                r.{renderer}(m.vic.frameBuffer, m, 36 + y, 0, y, addresses, 0);
                for (let x = 0; x < 8; x++) {{
                    const glyph = rom_chars[0x800 + 8 + y];
                    const color = {str(multicolor).lower()}
                        ? [0, 2, 3, 1][(glyph >> (6 - (x >> 1) * 2)) & 3]
                        : ((glyph & (0x80 >> x)) ? 1 : 0);
                    const expected = PALETTE[color];
                    if (m.vic.frameBuffer[(36 + y) * 384 + 32 + x] !== expected) {{
                        differences++;
                    }}
                }}
            }}
            return {{differences, useCharROM: addresses.useCharROM}};
        }})()""",
    )
    assert result["useCharROM"]
    assert result["differences"] == 0


@pytest.mark.parametrize("multicolor", [False, True])
def test_sprites_are_not_graphics_for_collision_or_priority(vic_context, multicolor):
    result = eval_json(
        vic_context,
        """(multicolor => {
            const m = regressionVideoMachine();
            m.write(0xD015, 3);
            m.write(0xD01B, 1);
            m.write(0xD01C, multicolor ? 3 : 0);
            regressionSprite(m, 0, 1);
            regressionSprite(m, 1, 2);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            const collisions = [m.peek(0xD01E), m.peek(0xD01F)];
            const pixel = m.vic.frameBuffer[36 * 384 + 32];
            const consumed = [m.read(0xD01E), m.read(0xD01F)];
            return {
                collisions, pixel, expectedPixel: PALETTE[1], consumed,
                cleared: [m.peek(0xD01E), m.peek(0xD01F)]
            };
        })("""
        + str(multicolor).lower()
        + ")",
    )
    assert result["collisions"] == [3, 0]
    assert result["pixel"] == result["expectedPixel"]
    assert result["consumed"] == [3, 0]
    assert result["cleared"] == [0, 0]


@pytest.mark.parametrize("multicolor", [False, True])
def test_foreground_still_collides_when_its_color_matches_background(
    vic_context, multicolor
):
    result = eval_json(
        vic_context,
        """(multicolor => {
            const m = regressionVideoMachine();
            m.write(0x2008, 0x80);
            m.write(0xD800, 0);
            m.write(0xD015, 1);
            m.write(0xD01B, 1);
            m.write(0xD01C, multicolor ? 1 : 0);
            regressionSprite(m, 0, 1);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            const first = [m.peek(0xD01F), m.vic.frameBuffer[36 * 384 + 32]];
            m.read(0xD01F);
            m.write(0x2008, 0);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            return {
                first, expectedBackground: PALETTE[0],
                next: [m.peek(0xD01F), m.vic.frameBuffer[36 * 384 + 32]],
                expectedSprite: PALETTE[1]
            };
        })("""
        + str(multicolor).lower()
        + ")",
    )
    assert result["first"] == [1, result["expectedBackground"]]
    assert result["next"] == [0, result["expectedSprite"]]


@pytest.mark.parametrize("bitmap", [False, True])
@pytest.mark.parametrize("bits", [0, 1, 2, 3])
def test_multicolor_foreground_uses_pixel_bits_not_palette(vic_context, bitmap, bits):
    # 01 has a distinct color; 10/11 share the background RGB value.
    result = eval_json(
        vic_context,
        f"""(() => {{
            const m = regressionVideoMachine();
            m.write(0xD011, {0x3B if bitmap else 0x1B});
            m.write(0xD016, 0x18);
            m.write(0xD022, 2);
            m.write(0xD023, 0);
            m.write(0xD800, {0 if bitmap else 8});
            m.write(0x0400, {0x20 if bitmap else 1});
            m.write({0x2000 if bitmap else 0x2008}, {bits << 6});
            m.write(0xD015, 1);
            m.write(0xD01B, 1);
            regressionSprite(m, 0, 1);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            return {{
                collisions: m.peek(0xD01F),
                pixel: m.vic.frameBuffer[36 * 384 + 32],
                expectedPixel: PALETTE[{0 if bits & 2 else 1}]
            }};
        }})()""",
    )
    assert result["collisions"] == (1 if bits & 2 else 0)
    assert result["pixel"] == result["expectedPixel"]


@pytest.mark.parametrize("bits", [0, 1, 2, 3])
@pytest.mark.parametrize("pixel_in_pair", [0, 1])
def test_hires_cells_in_multicolor_mode_keep_paired_priority(
    vic_context, bits, pixel_in_pair
):
    # MCM controls priority even when color RAM selects a hires character.
    # Christian Bauer, VIC-Article.txt, sections 3.7.3.2 and 3.8.2.
    graphics_color = 2 if bits & (2 >> pixel_in_pair) else 0
    expected_color = graphics_color if bits & 2 else 1
    result = eval_json(
        vic_context,
        f"""(() => {{
            const m = regressionVideoMachine();
            m.write(0xD016, 0x18);
            m.write(0xD800, 2);
            m.write(0x2008, {bits << 6});
            m.write(0xD015, 1);
            m.write(0xD01B, 1);
            regressionSprite(m, 0, 1);
            for (let row = 0; row < 21; row++) {{
                m.write(0x3000 + row * 3, {0x80 >> pixel_in_pair});
            }}
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            return {{
                collisions: m.peek(0xD01F),
                pixel: m.vic.frameBuffer[36 * 384 + 32 + {pixel_in_pair}],
                expectedPixel: PALETTE[{expected_color}]
            }};
        }})()""",
    )
    assert result["collisions"] == (1 if bits & 2 else 0)
    assert result["pixel"] == result["expectedPixel"]


def test_multicolor_sprite_01_remains_opaque(vic_context):
    result = eval_json(
        vic_context,
        """(() => {
            const m = regressionVideoMachine();
            m.write(0x2008, 0x80);
            m.write(0xD800, 0);
            m.write(0xD015, 1);
            m.write(0xD01C, 1);
            m.write(0xD025, 1);
            regressionSprite(m, 0, 2);
            m.write(0x3000, 0x40);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            return {
                collisions: m.peek(0xD01F),
                pixel: m.vic.frameBuffer[36 * 384 + 32],
                expectedPixel: PALETTE[1]
            };
        })()""",
    )
    assert result["collisions"] == 1
    assert result["pixel"] == result["expectedPixel"]


def test_raster_irq_changes_are_captured_after_each_scanline(vic_context):
    result = eval_json(
        vic_context,
        """(() => {
            const m = regressionVideoMachine();
            m.cyclesPerFrame = 17 * 63;
            m.write(1, 0x35);
            m.loadCode([0x4C, 0x00, 0x02], 0x0200);
            m.loadCode([
                0xEE, 0x20, 0xD0,
                0xEE, 0x12, 0xD0,
                0xA9, 1, 0x8D, 0x19, 0xD0, 0x40
            ], 0x0300);
            m.write(0xFFFE, 0);
            m.write(0xFFFF, 3);
            m.write(0xD020, 1);
            m.write(0xD012, 15);
            m.write(0xD01A, 1);
            m.cpu.PC = 0x0200;
            m.cpu.P = 0x20;
            m.runFrame();
            return {
                colors: [m.vic.frameBuffer[0], m.vic.frameBuffer[384]],
                expected: [PALETTE[2], PALETTE[3]]
            };
        })()""",
    )
    assert result["colors"] == result["expected"]


def render_frame_js():
    return """
        function renderWholeFrame(m) {
            for (let line = 15; line < 15 + 272; line++) {
                m.vic.renderer.renderScanline(m.vic.frameBuffer, m, line);
            }
        }
        function litRows(m, x, color) {
            const rows = [];
            for (let y = 0; y < 272; y++) {
                if (m.vic.frameBuffer[y * 384 + x] === PALETTE[color]) rows.push(y);
            }
            return rows;
        }
    """


@pytest.mark.parametrize(
    "yscroll,expected",
    [
        # Default: row 0 fills the top of the window and row 24 is complete.
        (3, list(range(36, 44)) + list(range(228, 236))),
        # Row 0 starts 3 lines above the window; row 24 ends 3 lines early.
        (0, list(range(36, 41)) + list(range(225, 233))),
        # Row 0 starts 4 lines down; only 4 lines of row 24 fit in the window.
        (7, list(range(40, 48)) + list(range(232, 236))),
    ],
)
def test_text_rows_start_on_their_bad_line(vic_context, yscroll, expected):
    vic_context.eval(render_frame_js())
    rows = eval_json(
        vic_context,
        f"""(() => {{
            const m = regressionVideoMachine();
            m.write(0xD011, 0x18 | {yscroll});
            m.write(0xD018, 0x14);
            m.write(0x0400, 160);
            m.write(0x0400 + 24 * 40, 160);
            m.write(0xD800, 1);
            m.write(0xD800 + 24 * 40, 1);
            renderWholeFrame(m);
            return litRows(m, 32, 1);
        }})()""",
    )
    assert rows == expected


def test_24_row_mode_covers_window_edges_with_border(vic_context):
    vic_context.eval(render_frame_js())
    result = eval_json(
        vic_context,
        """(() => {
            const m = regressionVideoMachine();
            m.write(0xD011, 0x13);
            renderWholeFrame(m);
            return {border: litRows(m, 100, 2), background: litRows(m, 100, 0)};
        })()""",
    )
    assert result["background"] == list(range(40, 232))
    assert 39 in result["border"] and 232 in result["border"]


def test_cleared_den_blanks_the_screen_to_border_color(vic_context):
    vic_context.eval(render_frame_js())
    result = eval_json(
        vic_context,
        """(() => {
            const m = regressionVideoMachine();
            m.write(0xD011, 0x0B);
            m.write(0xD015, 1);
            regressionSprite(m, 0, 1);
            renderWholeFrame(m);
            let other = 0;
            for (const pixel of m.vic.frameBuffer) if (pixel !== PALETTE[2]) other++;
            return other;
        })()""",
    )
    assert result == 0


@pytest.mark.parametrize("columns", [40, 38])
@pytest.mark.parametrize("multicolor", [False, True])
def test_scrolled_graphics_stay_inside_the_display_window(
    vic_context, columns, multicolor
):
    # XSCROLL moves column 39 up to 7 pixels right; the border must cover
    # whatever passes the right edge of the 320-pixel window.
    result = eval_json(
        vic_context,
        f"""(() => {{
            const m = regressionVideoMachine();
            m.write(0xD016, {0x08 if columns == 40 else 0x00} | {0x10 if multicolor else 0} | 7);
            m.write(0xD018, 0x14);
            for (const column of [37, 39]) {{
                m.write(0x0400 + column, 160);
                m.write(0xD800 + column, {0x09 if multicolor else 1});
            }}
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            const row = Array.from(m.vic.frameBuffer.slice(36 * 384, 37 * 384));
            return {{
                beyondWindow: row.slice(32 + 320).every(pixel => pixel === PALETTE[2]),
                lastColumnShown: row.slice(32 + 303, 32 + 311).every(pixel => pixel !== PALETTE[0])
            }};
        }})()""",
    )
    assert result == {"beyondWindow": True, "lastColumnShown": True}


def test_sprites_are_hidden_but_still_collide_under_the_side_border(vic_context):
    result = eval_json(
        vic_context,
        """(() => {
            const m = regressionVideoMachine();
            m.write(0xD015, 3);
            regressionSprite(m, 0, 1);
            regressionSprite(m, 1, 1);
            for (let row = 0; row < 21; row++) {
                m.write(0x3000 + row * 3, 0xFF);
                m.write(0x3040 + row * 3, 0xFF);
            }
            m.write(0xD000, 0);
            m.write(0xD002, 4);
            m.vic.renderer.renderScanline(m.vic.frameBuffer, m, 51);
            const row = Array.from(m.vic.frameBuffer.slice(36 * 384, 36 * 384 + 40));
            return {
                border: row.slice(0, 32).every(pixel => pixel === PALETTE[2]),
                spriteCollision: m.peek(0xD01E)
            };
        })()""",
    )
    assert result == {"border": True, "spriteCollision": 3}


def test_unconnected_vic_register_bits_read_as_one(vic_context):
    result = eval_json(
        vic_context,
        """(() => {
            const m = new C64Machine({audioEnabled: false});
            for (let i = 0; i < 150; i++) m.runFrame();
            return {
                border: m.read(0xD020), background: m.read(0xD021),
                mirror: m.read(0xD060), control2: m.read(0xD016) & 0xC0,
                memory: m.read(0xD018) & 0x01, status: m.read(0xD019) & 0x70,
                enable: m.read(0xD01A) & 0xF0, unused: [m.read(0xD02F), m.read(0xD03F)]
            };
        })()""",
    )
    # PEEK(53280) and PEEK(53281) on a real C64 after power-on.
    assert result == {
        "border": 254,
        "background": 246,
        "mirror": 254,
        "control2": 0xC0,
        "memory": 1,
        "status": 0x70,
        "enable": 0xF0,
        "unused": [0xFF, 0xFF],
    }
