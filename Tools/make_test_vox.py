"""Writes the prototype's test models as real MagicaVoxel .vox files.

Placeholder art so the reader and destruction can be tested before hand-made models
exist; replace them with MagicaVoxel work whenever. Run from the repo root:
    python3 Tools/make_test_vox.py
MagicaVoxel axes: x = right, y = forward (the barrel points +y), z = up.
"""
import random
import struct

random.seed(7)


class Model:
    def __init__(self, sx, sy, sz):
        self.size = (sx, sy, sz)
        self.voxels = {}
        self.palette = []

    def colour(self, hex_rgb):
        """Palette index (1-based) for a colour, adding it if new."""
        rgb = tuple(int(hex_rgb[i:i + 2], 16) for i in (0, 2, 4))
        if rgb not in self.palette:
            self.palette.append(rgb)
        return self.palette.index(rgb) + 1

    def box(self, x0, x1, y0, y1, z0, z1, c):
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                for z in range(z0, z1 + 1):
                    self.set(x, y, z, c)

    def set(self, x, y, z, c):
        sx, sy, sz = self.size
        if 0 <= x < sx and 0 <= y < sy and 0 <= z < sz:
            self.voxels[(x, y, z)] = c

    def clear(self, x, y, z):
        self.voxels.pop((x, y, z), None)

    def save(self, path):
        def chunk(cid, content, children=b""):
            return cid + struct.pack("<ii", len(content), len(children)) + content + children

        size = chunk(b"SIZE", struct.pack("<iii", *self.size))
        data = struct.pack("<i", len(self.voxels)) + b"".join(
            struct.pack("<BBBB", x, y, z, c) for (x, y, z), c in self.voxels.items())
        xyzi = chunk(b"XYZI", data)
        pal = b"".join(struct.pack("<BBBB", r, g, b, 255) for r, g, b in self.palette)
        pal += b"\x00\x00\x00\xff" * (256 - len(self.palette))
        rgba = chunk(b"RGBA", pal)
        main = chunk(b"MAIN", b"", size + xyzi + rgba)
        with open(path, "wb") as f:
            f.write(b"VOX " + struct.pack("<i", 150) + main)
        print(f"{path}: {len(self.voxels)} voxels, {len(self.palette)} colours")


def tank(team, team_light, team_dark):
    m = Model(20, 38, 14)
    track = m.colour("2f2f33")
    tread = m.colour("4a4a50")
    hub = m.colour("6b6b70")
    body = m.colour(team)
    light = m.colour(team_light)
    dark = m.colour(team_dark)
    steel = m.colour("5c5f66")
    steel_dark = m.colour("3c3e44")
    grille = m.colour("26262a")

    # Tracks, with rounded ends and tread lines.
    for x0, x1 in ((0, 3), (16, 19)):
        for y in range(2, 30):
            for z in range(0, 5):
                end = y in (2, 29)
                if end and z in (0, 4):
                    continue
                for x in range(x0, x1 + 1):
                    m.set(x, y, z, tread if (y % 3 == 0 and z in (0, 4)) else track)
        for y in range(4, 29, 5):
            outer = x0 if x0 == 0 else x1
            m.set(outer, y, 2, hub)

    # Hull with a sloped front and a rear deck.
    for x in range(3, 17):
        for y in range(1, 31):
            top = 8
            if y >= 27:
                top = 8 - (y - 26)
            if y <= 2:
                top = 7
            for z in range(3, top + 1):
                m.set(x, y, z, light if z == top else body)
    for x in range(6, 14, 2):
        for y in range(2, 7):
            m.set(x, y, 8, grille)

    # Turret, chamfered corners, with a hatch.
    for x in range(5, 15):
        for y in range(10, 22):
            if x in (5, 14) and y in (10, 21):
                continue
            for z in range(9, 14):
                m.set(x, y, z, light if z == 13 else body)
    m.box(8, 10, 12, 14, 13, 13, dark)

    # Mantlet, barrel and muzzle brake.
    m.box(8, 11, 22, 23, 10, 12, steel_dark)
    m.box(9, 10, 24, 37, 11, 12, steel)
    m.box(8, 11, 35, 37, 10, 13, steel_dark)
    m.box(9, 10, 35, 37, 11, 12, grille)
    return m


def building(team):
    m = Model(48, 40, 32)
    concrete = [m.colour(c) for c in ("b9b3a7", "b1ab9f", "c2bcb0")]
    base = m.colour("8a857c")
    roof = m.colour("7d7a74")
    glass = m.colour("36485e")
    glass_lit = m.colour("4d6a8a")
    door = m.colour("4a3b2c")
    stripe = m.colour(team)
    unit = m.colour("9a9a9e")
    vent = m.colour("5a5a5e")

    def wall_colour():
        return random.choice(concrete)

    sx, sy = 48, 40
    m.box(0, sx - 1, 0, sy - 1, 0, 1, base)  # foundation
    for z in range(2, 30):
        for x in range(sx):
            for y in range(sy):
                edge = x < 2 or x >= sx - 2 or y < 2 or y >= sy - 2
                if edge:
                    m.set(x, y, z, wall_colour())
    for z in (15, 16):  # first floor slab
        m.box(2, sx - 3, 2, sy - 3, z, z, concrete[1])
    m.box(0, sx - 1, 0, sy - 1, 28, 29, roof)  # roof slab
    for x in range(sx):  # parapet
        for y in range(sy):
            if x == 0 or x == sx - 1 or y == 0 or y == sy - 1:
                m.box(x, x, y, y, 30, 31, base)

    # Team stripe round the building.
    for x in range(sx):
        for y in range(sy):
            if x < 2 or x >= sx - 2 or y < 2 or y >= sy - 2:
                m.box(x, x, y, y, 12, 13, stripe)

    # Windows on every wall, two storeys.
    for z0 in (5, 19):
        for z in range(z0, z0 + 5):
            for x in range(4, sx - 4):
                if (x - 4) % 8 < 4:
                    c = glass_lit if (z == z0 + 4) else glass
                    for y in (0, 1, sy - 2, sy - 1):
                        m.set(x, y, z, c)
            for y in range(4, sy - 4):
                if (y - 4) % 8 < 4:
                    c = glass_lit if (z == z0 + 4) else glass
                    for x in (0, 1, sx - 2, sx - 1):
                        m.set(x, y, z, c)

    # Front door (front = +y).
    m.box(20, 27, sy - 2, sy - 1, 2, 10, door)

    # Rooftop unit.
    m.box(30, 37, 8, 15, 30, 33, unit)
    m.box(32, 35, 10, 13, 33, 33, vent)
    return m


tank("3d6fd1", "5b8be3", "2b4f9a").save("Art/Voxel/test_tank_blue.vox")
tank("c8402f", "de5f4c", "8f2c20").save("Art/Voxel/test_tank_red.vox")
building("3d6fd1").save("Art/Voxel/test_building.vox")
