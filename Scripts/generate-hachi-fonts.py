"""Generate same-family Hachi faces for native text, which cannot synthesize them.

Resource-authoring dependencies only: fonttools and freetype-py. Neither is an
application dependency. The supplied Regular font is never modified.
"""

import argparse
import ctypes
import math
from pathlib import Path

import freetype
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
FONTS = ROOT / "Vellix" / "Fonts"
SOURCE = FONTS / "HachiMaruPop-Regular.ttf"
# Compared 31, 50, and 62 units against the original Latin outlines at reading sizes.
# 50 keeps the handwritten counters open without the crowding of the heavier candidate.
BOLD_STRENGTH_EM = 1 / 20


def generate(style, bold, italic):
    font = TTFont(SOURCE, recalcTimestamp=False)
    face = freetype.Face(str(SOURCE))
    strength = round(font["head"].unitsPerEm * BOLD_STRENGTH_EM) if bold else 0
    shear = math.tan(math.radians(12)) if italic else 0
    matrix = freetype.Matrix(65536, round(shear * 65536), 0, 65536)
    glyphs = {}

    for index, name in enumerate(font.getGlyphOrder()):
        face.load_glyph(index, freetype.FT_LOAD_NO_SCALE | freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP)
        outline = face.glyph.outline
        if strength and outline.n_points:
            error = freetype.FT_Outline_EmboldenXY(ctypes.byref(outline._FT_Outline), strength, strength)
            if error:
                raise RuntimeError(f"Cannot embolden {name}: {error}")
        if italic and outline.n_points:
            freetype.FT_Outline_Transform(ctypes.byref(outline._FT_Outline), ctypes.byref(matrix))
        pen = TTGlyphPen(None)
        contour_open = False

        def point(vector):
            return (vector.x, vector.y)

        def move_to(vector, _):
            nonlocal contour_open
            if contour_open:
                pen.closePath()
            pen.moveTo(point(vector))
            contour_open = True

        outline.decompose(
            move_to=move_to,
            line_to=lambda vector, _: pen.lineTo(point(vector)),
            conic_to=lambda control, vector, _: pen.qCurveTo(point(control), point(vector)),
            cubic_to=lambda first, second, vector, _: pen.curveTo(point(first), point(second), point(vector)),
        )
        if contour_open:
            pen.closePath()
        glyph = pen.glyph()
        glyph.recalcBounds(font["glyf"])
        glyphs[name] = glyph
        advance, bearing = font["hmtx"].metrics[name]
        font["hmtx"].metrics[name] = (advance + (strength if outline.n_points else 0), getattr(glyph, "xMin", bearing))

    font["glyf"].glyphs = glyphs
    family = "Hachi Maru Pop"
    postscript = "HachiMaruPop-Synthetic" + style.replace(" ", "")
    names = {1: family, 2: style, 3: postscript + (";Penned-2" if bold else ";Penned-1"), 4: family + " " + style,
             6: postscript, 16: family, 17: style, 21: family, 22: style,
             10: "Synthetic companion derived from Hachi Maru Pop Regular for Penned; FreeType outline emboldening and 12-degree oblique. Licensed under SIL OFL 1.1."}
    if bold:
        names[5] = "Version 1.001; Penned synthetic weight revision 2"
        font["head"].fontRevision = 1.001
    for record in font["name"].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    for name_id, value in names.items():
        font["name"].setName(value, name_id, 3, 1, 0x409)
    font["OS/2"].usWeightClass = 700 if bold else 400
    font["OS/2"].fsSelection = (font["OS/2"].fsSelection & ~0x261) | (0x20 if bold else 0) | (1 if italic else 0)
    font["head"].macStyle = (1 if bold else 0) | (2 if italic else 0)
    font["post"].italicAngle = -12 if italic else 0
    font["hhea"].caretSlopeRise = 1000
    font["hhea"].caretSlopeRun = round(shear * 1000)
    font["OS/2"].usWinAscent = max(font["OS/2"].usWinAscent, max(getattr(glyph, "yMax", 0) for glyph in glyphs.values()))
    font["OS/2"].usWinDescent = max(font["OS/2"].usWinDescent, -min(getattr(glyph, "yMin", 0) for glyph in glyphs.values()))
    path = FONTS / (postscript + ".ttf")
    font.save(path)
    print(path.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bold-only", action="store_true", help="Leave the existing Italic face unchanged.")
    args = parser.parse_args()
    generate("Bold", True, False)
    if not args.bold_only:
        generate("Italic", False, True)
    generate("Bold Italic", True, True)
