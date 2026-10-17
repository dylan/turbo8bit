"""Generate the site logo, favicons and social (Open Graph) image.

The source, raw-images/favicon.png, lives outside web/static so the
full-resolution original is not part of the deployed bundle. It is drawn on
a flat background, which is keyed out here so the artwork can sit on any
colour:

    icons/logo.png            transparent, for the site header
    icons/favicon-<n>.png     square, on the brand colour
    icons/favicon.ico         16, 32 and 48 pixels
    icons/og-image.png        1200x630, the artwork on a C64 screen

The brand colour is the C64's blue: --brand-bg in style.css, which frames
every page, and PALETTE[6] in js/emulator/vic-ii.js.
"""

from pathlib import Path

from PIL import Image, ImageMath, ImageStat

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "raw-images" / "favicon.png"
OUT_DIR = ROOT / "web" / "static" / "icons"

BRAND_BG = (0x35, 0x28, 0x79)  # C64 blue
BRAND_EDGE = (0x6C, 0x5E, 0xB5)  # C64 light blue, the colour of its border

# Distance from the background colour, in RGB units. Closer than NEAR is
# background (the source has a little noise); further than FAR is artwork;
# in between is an anti-aliased edge.
NEAR = 18
FAR = 70

# Twice the 92px the header shows it at, for high-density screens
LOGO_HEIGHT = 184
ICON_SIZES = [16, 32, 48, 180, 192, 256, 512]
# Breathing room around the artwork in the square icons
ICON_MARGIN = 0.06
OG_SIZE = (1200, 630)


def key_out_background(img: Image.Image) -> Image.Image:
    """Return the artwork on a transparent background, cropped to fit.

    An edge pixel is part background and part artwork, so its colour is
    un-mixed as well as made translucent: art = bg + (pixel - bg) / alpha.
    Without that every outline keeps a halo of the old background.
    """
    rgb = img.convert("RGB")
    edge = Image.new("L", rgb.size, 255)
    edge.paste(0, (1, 1, rgb.width - 1, rgb.height - 1))
    bg = ImageStat.Stat(rgb, edge).median
    print(f"Source: {img.size}, background #{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}")

    channels = [band.convert("F") for band in rgb.split()]
    dist = ImageMath.lambda_eval(
        lambda a: (
            (a["r"] - bg[0]) ** 2 + (a["g"] - bg[1]) ** 2 + (a["b"] - bg[2]) ** 2
        )
        ** 0.5,
        r=channels[0],
        g=channels[1],
        b=channels[2],
    )
    alpha = ImageMath.lambda_eval(
        lambda a: a["min"](a["max"]((a["d"] - NEAR) / (FAR - NEAR), 0.0), 1.0),
        d=dist,
    )
    art = [
        ImageMath.lambda_eval(
            lambda a: (a["c"] - base) / a["max"](a["alpha"], 0.01) + base,
            c=channel,
            alpha=alpha,
        ).convert("L")
        for channel, base in zip(channels, bg)
    ]
    mask = ImageMath.lambda_eval(lambda a: a["alpha"] * 255, alpha=alpha).convert("L")
    return Image.merge("RGBA", (*art, mask)).crop(mask.getbbox())


def fit(art: Image.Image, width: int, height: int) -> Image.Image:
    scale = min(width / art.width, height / art.height)
    size = (max(1, round(art.width * scale)), max(1, round(art.height * scale)))
    return art.resize(size, Image.LANCZOS)


def centred(art: Image.Image, canvas: Image.Image, box=None) -> Image.Image:
    """The artwork centred in box, by default the whole canvas."""
    left, top, right, bottom = box or (0, 0, *canvas.size)
    out = canvas.copy()
    out.alpha_composite(
        art,
        (
            left + (right - left - art.width) // 2,
            top + (bottom - top - art.height) // 2,
        ),
    )
    return out.convert("RGB")


def save(img: Image.Image, name: str, **kwargs) -> None:
    path = OUT_DIR / name
    img.save(path, optimize=True, **kwargs)
    print(f"  wrote {path.relative_to(ROOT)}")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    art = key_out_background(Image.open(SRC))

    save(fit(art, LOGO_HEIGHT * 2, LOGO_HEIGHT), "logo.png")

    for size in ICON_SIZES:
        inner = round(size * (1 - 2 * ICON_MARGIN))
        square = Image.new("RGBA", (size, size), BRAND_BG)
        save(centred(fit(art, inner, inner), square), f"favicon-{size}.png")

    square = Image.new("RGBA", (256, 256), BRAND_BG)
    icon = centred(fit(art, 226, 226), square)
    save(icon, "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])

    # The C64's own screen: a light blue border round a blue picture, in the
    # proportions of its 384x272 display.
    w, h = OG_SIZE
    side, top = round(w * 32 / 384), round(h * 36 / 272)
    picture = (side, top, w - side, h - top)
    screen = Image.new("RGBA", OG_SIZE, BRAND_EDGE)
    screen.paste(BRAND_BG, picture)
    art_height = round((picture[3] - picture[1]) * 0.9)
    save(centred(fit(art, w, art_height), screen, picture), "og-image.png")


if __name__ == "__main__":
    main()
