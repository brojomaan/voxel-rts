"""Writes the prototype's test models as real MagicaVoxel .vox files, plus the palette.

Placeholder art so the reader and destruction can be tested before hand-made models
exist; replace them with MagicaVoxel work whenever. Run from the repo root:
    python3 Tools/make_test_vox.py
Writes each model twice: normal detail (1/16 voxels) and double detail ("_hi", 1/32
voxels, the half-res pixel view). Shapes scale up; surface patterns (tread, seams,
grilles, glints) stay one voxel wide, so the _hi models get genuinely finer detail.

Team colour: the four magenta shades are reserved. The game swaps them for the owning
team's colour, so one model serves every team.
MagicaVoxel axes: x = right, y = forward (the barrel points +y), z = up.
"""
import random
import struct
import zlib

# The shared palette, in palette order (colour index = position + 1).
PALETTE = {
    "team1": "FF00FF", "team2": "CC00CC", "team3": "990099", "team4": "660066",
    "concrete1": "E3DCCB", "concrete2": "BDB4A0", "concrete3": "958C7A",
    "concrete4": "6B6457", "concrete5": "45403A",
    "metal1": "C9CED6", "metal2": "8F98A6", "metal3": "5E6675", "metal4": "3A404B",
    "metal5": "22262E",
    "hazard": "F2C230", "rust": "D9822B", "warning": "B23A2E",
    "glass1": "9FD8FF", "glass2": "4F7FA8", "glass3": "2C4A66", "lamp": "FFF2A8",
    "grass1": "7FA05A", "grass2": "5C7D3F", "grass3": "3F5A2D",
    "dirt1": "A68A5B", "dirt2": "7A6440", "sand": "C8B27E",
    "dark": "1A1A1E",
}
NAMES = list(PALETTE)


def idx(name):
    return NAMES.index(name) + 1


def rgb(hex_rgb):
    return tuple(int(hex_rgb[i:i + 2], 16) for i in (0, 2, 4))


class Model:
    def __init__(self, sx, sy, sz):
        self.size = (sx, sy, sz)
        self.voxels = {}

    def set(self, x, y, z, name):
        sx, sy, sz = self.size
        if 0 <= x < sx and 0 <= y < sy and 0 <= z < sz:
            self.voxels[(x, y, z)] = idx(name)

    def box(self, x0, x1, y0, y1, z0, z1, name):
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                for z in range(z0, z1 + 1):
                    self.set(x, y, z, name)

    def save(self, path):
        def chunk(cid, content, children=b""):
            return cid + struct.pack("<ii", len(content), len(children)) + content + children

        size = chunk(b"SIZE", struct.pack("<iii", *self.size))
        data = struct.pack("<i", len(self.voxels)) + b"".join(
            struct.pack("<BBBB", x, y, z, c) for (x, y, z), c in self.voxels.items())
        pal = b"".join(struct.pack("<BBBB", *rgb(PALETTE[n]), 255) for n in NAMES)
        pal += b"\x00\x00\x00\xff" * (256 - len(NAMES))
        main = chunk(b"MAIN", b"", size + chunk(b"XYZI", data) + chunk(b"RGBA", pal))
        with open(path, "wb") as f:
            f.write(b"VOX " + struct.pack("<i", 150) + main)
        print(f"{path}: {self.size}, {len(self.voxels)} voxels")


def tank(s):
    """s = detail scale (1 or 2). Shape sizes are in base units times s."""
    m = Model(20 * s, 38 * s, 18 * s)

    def B(x0, x1, y0, y1, z0, z1, name):  # box in base units
        m.box(x0 * s, (x1 + 1) * s - 1, y0 * s, (y1 + 1) * s - 1, z0 * s, (z1 + 1) * s - 1, name)

    # Tracks: rounded ends, tread lines one voxel apart (finer at s=2), road wheels.
    for x0, x1 in ((0, 3), (16, 19)):
        for y in range(2 * s, 30 * s):
            for z in range(0, 5 * s):
                if y // s in (2, 29) and z // s in (0, 4):
                    continue
                tread = z in (0, 5 * s - 1) and y % 3 == 0
                for x in range(x0 * s, (x1 + 1) * s):
                    m.set(x, y, z, "metal4" if tread else "dark")
        outer = 0 if x0 == 0 else 20 * s - 1
        for wy in range(4, 29, 5):
            cy, cz = wy * s + s / 2, 2 * s + s / 2
            r = 0.6 * s if s > 1 else 0.5
            for y in range(int(cy - r - 1), int(cy + r + 2)):
                for z in range(int(cz - r - 1), int(cz + r + 2)):
                    d = ((y + 0.5 - cy) ** 2 + (z + 0.5 - cz) ** 2) ** 0.5
                    if d <= r:
                        m.set(outer, y, z, "metal2" if d < r * 0.45 else "metal3")

    # Hull: team colour, sloped glacis, rear deck, seam line and rivets at s=2.
    for x in range(3 * s, 17 * s):
        for y in range(1 * s, 31 * s):
            ly = (y + 0.5) / s
            top_units = 9.0
            if ly >= 27:
                top_units = 9.0 - (ly - 26.5)
            if ly < 3:
                top_units = 8.0
            top = int(top_units * s) - 1
            for z in range(3 * s, top + 1):
                name = "team1" if z == top else "team2"
                if s > 1 and z == 6 * s and x in (3 * s, 17 * s - 1):
                    name = "team4"  # seam along the sides
                m.set(x, y, z, name)
            if s > 1 and x in (3 * s + 1, 17 * s - 2) and y % 4 == 0 and top_units == 9.0:
                m.set(x, y, top, "metal2")  # rivets
    for x in range(6 * s, 14 * s):  # engine grille
        if x % 2 == 0:
            for y in range(2 * s, 7 * s):
                m.set(x, y, 8 * s - 1, "dark")

    # Turret with chamfered corners, hatch, and (s=2) periscope, antenna, roundel.
    for x in range(5 * s, 15 * s):
        for y in range(10 * s, 22 * s):
            if x // s in (5, 14) and y // s in (10, 21):
                continue
            for z in range(9 * s, 14 * s):
                m.set(x, y, z, "team1" if z == 14 * s - 1 else "team2")
    B(8, 10, 12, 14, 13, 13, "team4")
    if s > 1:
        m.box(8 * s + 1, 11 * s - 2, 12 * s + 1, 15 * s - 2, 14 * s - 1, 14 * s - 1, "metal3")  # hatch lid
        m.box(12 * s, 12 * s + 1, 18 * s, 18 * s + 1, 14 * s, 14 * s + 1, "metal2")  # periscope
        for z in range(14 * s, 14 * s + 10):
            m.set(13 * s, 11 * s, z, "metal4")  # antenna
        m.set(13 * s, 11 * s, 14 * s + 10, "warning")
        for side in (5 * s, 15 * s - 1):  # roundel on both turret sides
            for y in range(14 * s, 18 * s):
                for z in range(10 * s, 13 * s + 1):
                    d = abs(y - 16 * s + 0.5) + abs(z - 11.5 * s)
                    if d <= 3:
                        m.set(side, y, z, "concrete1" if d > 1 else "warning")

    # Mantlet, barrel (rounded at s=2), muzzle brake with slots.
    B(8, 11, 22, 23, 10, 12, "metal4")
    for y in range(24 * s, 38 * s):
        for x in range(9 * s, 11 * s):
            for z in range(11 * s, 13 * s):
                corner = s > 1 and x in (9 * s, 11 * s - 1) and z in (11 * s, 13 * s - 1)
                if not corner:
                    m.set(x, y, z, "metal3")
    B(8, 11, 35, 37, 10, 13, "metal4")
    B(9, 10, 35, 37, 11, 12, "dark")
    if s > 1:
        for y in range(35 * s, 38 * s):
            if y % 3 == 0:
                for z in range(10 * s + 1, 14 * s - 1):
                    m.set(8 * s, y, z, "dark")
                    m.set(12 * s - 1, y, z, "dark")
    return m


def building(s):
    random.seed(7)
    sx, sy = 48 * s, 40 * s
    wall = 2 * s
    m = Model(sx, sy, 36 * s)

    def B(x0, x1, y0, y1, z0, z1, name):
        m.box(x0 * s, (x1 + 1) * s - 1, y0 * s, (y1 + 1) * s - 1, z0 * s, (z1 + 1) * s - 1, name)

    def in_wall(x, y):
        return x < wall or x >= sx - wall or y < wall or y >= sy - wall

    def outer(x, y):  # outermost layer of the wall
        return x in (0, sx - 1) or y in (0, sy - 1)

    B(0, 47, 0, 39, 0, 1, "concrete4")  # foundation
    for z in range(2 * s, 30 * s):
        for x in range(sx):
            for y in range(sy):
                if in_wall(x, y):
                    name = random.choice(("concrete2", "concrete2", "concrete1", "concrete3"))
                    if s > 1 and outer(x, y) and z % 8 == 0:
                        name = "concrete3"  # panel seams
                    m.set(x, y, z, name)
    B(2, 45, 2, 37, 15, 16, "concrete2")  # first floor slab
    B(0, 47, 0, 39, 28, 29, "concrete3")  # roof
    for x in range(sx):  # parapet
        for y in range(sy):
            if x < s or x >= sx - s or y < s or y >= sy - s:
                m.box(x, x, y, y, 30 * s, 32 * s - 1, "concrete4")

    # Team stripe, with light trim lines at s=2.
    for x in range(sx):
        for y in range(sy):
            if in_wall(x, y):
                for z in range(12 * s, 14 * s):
                    trim = s > 1 and z in (12 * s, 14 * s - 1)
                    m.set(x, y, z, "concrete1" if trim else "team2")

    # Windows: two storeys, every wall. At s=2 they get frames, a mullion and glints.
    def window_cell(u, z, u_len):
        """Window colour at position u along the wall, or None for plain wall."""
        for z0 in (5, 19):
            lz0, lz1 = z0 * s, (z0 + 5) * s - 1
            if not (lz0 <= z <= lz1):
                continue
            if u < 4 * s or u >= u_len - 4 * s:
                return None
            k = (u - 4 * s) % (8 * s)
            if k >= 4 * s:
                return None
            if s > 1:
                if z in (lz0, lz1) or k in (0, 4 * s - 1):
                    return "concrete1"  # frame
                if k in (2 * s - 1, 2 * s):
                    return "metal3"  # mullion
                return "glass1" if (u + z) % 7 == 0 else "glass3"
            return "glass1" if z == lz1 else "glass3"
        return None

    for z in range(2 * s, 30 * s):
        for x in range(sx):
            c = window_cell(x, z, sx)
            if c:
                for y in list(range(wall)) + list(range(sy - wall, sy)):
                    m.set(x, y, z, c)
        for y in range(sy):
            c = window_cell(y, z, sy)
            if c:
                for x in list(range(wall)) + list(range(sx - wall, sx)):
                    m.set(x, y, z, c)

    # Front door (front = +y), with a hazard frame and roller ribs at s=2.
    B(20, 27, 38, 39, 2, 10, "metal3")
    if s > 1:
        for x in range(20 * s, 28 * s):
            for z in range(2 * s, 11 * s):
                if x in (20 * s, 28 * s - 1) or z == 11 * s - 1:
                    m.set(x, sy - 1, z, "hazard" if (x + z) % 4 < 2 else "dark")
                elif z % 3 == 0:
                    m.set(x, sy - 1, z, "metal4")

    # Rooftop unit with a fan and a pipe.
    B(30, 37, 8, 15, 30, 33, "metal2")
    B(32, 35, 10, 13, 33, 33, "metal4")
    if s > 1:
        cx, cy = 34 * s, 12 * s
        for x in range(32 * s, 36 * s):
            for y in range(10 * s, 14 * s):
                if (x - cx) == (y - cy) or (x - cx) == -(y - cy) - 1:
                    m.set(x, y, 34 * s - 1, "metal2")  # fan blades
        m.box(10 * s, 10 * s + 1, 20 * s, 32 * s, 30 * s, 30 * s + 1, "metal3")  # pipe run
        m.set(30 * s, 8 * s, 34 * s, "lamp")
    return m


def write_palette_png(path):
    """256x1 palette for MagicaVoxel: pixel i = colour index i + 1."""
    row = b"\x00"
    for i in range(256):
        r, g, b = rgb(PALETTE[NAMES[i]]) if i < len(NAMES) else (0, 0, 0)
        row += bytes((r, g, b, 255))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 1, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(row)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print(f"{path}: {len(NAMES)} colours")


for s, suffix in ((1, ""), (2, "_hi")):
    tank(s).save(f"Art/Voxel/test_tank{suffix}.vox")
    building(s).save(f"Art/Voxel/test_building{suffix}.vox")
write_palette_png("Art/Voxel/palette.png")
