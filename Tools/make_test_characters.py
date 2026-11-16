"""Writes placeholder infantry at several heights, to choose a character size by eye.

For each height (in voxels at 1/16) it writes a rifleman, a bazooka soldier and a dog,
plus a "_hi" version at twice the voxels for the half-res view. Chunky proportions (big
head, short legs) because that's what reads at this size. Placeholders, not final art.
Run from the repo root:
    python3 Tools/make_test_characters.py
The palette is saved inside each .vox; Art/Voxel/palette.png is left alone.
MagicaVoxel axes: x = right, y = forward (they face +y), z = up.
"""
import struct

PALETTE = {
    "team1": "FF00FF", "team2": "CC00CC", "team3": "990099", "team4": "660066",
    "skin1": "E8B88A", "skin2": "C98F62",
    "olive1": "7C8A52", "olive2": "5C6A3B", "olive3": "434E2B",
    "metal3": "5E6675", "metal4": "3A404B", "dark": "1A1A1E",
    "wood": "8A5A32", "fur1": "B98250", "fur2": "8A5C34", "fur3": "5E3D22",
    "white": "EDE8DC", "pack": "8C7B55",
}
NAMES = list(PALETTE)
HEIGHTS = (12, 16, 20, 24)


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


class Model:
    def __init__(self, sx, sy, sz):
        self.size = (sx, sy, sz)
        self.voxels = {}

    def set(self, x, y, z, name):
        sx, sy, sz = self.size
        if 0 <= x < sx and 0 <= y < sy and 0 <= z < sz:
            self.voxels[(x, y, z)] = NAMES.index(name) + 1

    def box(self, x0, x1, y0, y1, z0, z1, name):
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                for z in range(z0, z1 + 1):
                    self.set(x, y, z, name)

    def save(self, path):
        def chunk(cid, content, children=b""):
            return cid + struct.pack("<ii", len(content), len(children)) + content + children

        data = struct.pack("<i", len(self.voxels)) + b"".join(
            struct.pack("<BBBB", x, y, z, c) for (x, y, z), c in self.voxels.items())
        pal = b"".join(struct.pack("<BBBB", *rgb(PALETTE[n]), 255) for n in NAMES)
        pal += b"\x00\x00\x00\xff" * (256 - len(NAMES))
        main = chunk(b"MAIN", b"", chunk(b"SIZE", struct.pack("<iii", *self.size))
                     + chunk(b"XYZI", data) + chunk(b"RGBA", pal))
        with open(path, "wb") as f:
            f.write(b"VOX " + struct.pack("<i", 150) + main)


def soldier(h, kind):
    """A soldier h voxels tall. kind = "rifle" or "bazooka"."""
    head = max(4, round(h * 0.42))            # the head is a cube this big
    legs = max(2, round(h * 0.24))
    torso = h - head - legs
    bw = max(3, round(head * 0.8))            # body width
    bd = max(2, round(head * 0.55))           # body depth
    arm = max(1, round(h / 12))
    sx, sy = head + 2 * arm + 8, head + 14
    m = Model(sx, sy, h + arm + 2)
    cx, cy = sx // 2, sy // 2 - 2
    bx0, by0 = cx - bw // 2, cy - bd // 2
    bx1, by1 = bx0 + bw - 1, by0 + bd - 1
    shoulder = legs + torso - 1

    # Legs and boots.
    lw = max(1, (bw - 1) // 2)
    boot = max(1, legs // 3)
    for x0 in (bx0, bx1 - lw + 1):
        m.box(x0, x0 + lw - 1, by0, by1, 0, legs - 1, "olive2")
        m.box(x0, x0 + lw - 1, by0, by1 + (1 if h >= 16 else 0), 0, boot - 1, "dark")

    # Torso, belt, chest pocket line.
    m.box(bx0, bx1, by0, by1, legs, shoulder, "olive1")
    m.box(bx0, bx1, by0, by1, legs, legs, "olive3")
    if kind == "bazooka":
        m.box(bx0, bx1, by0 - max(1, arm), by0 - 1, legs + 1, shoulder, "pack")  # backpack

    # Head: skin, with a team-colour helmet over the top and back.
    hx0, hy0 = cx - head // 2, cy - head // 2
    hx1, hy1, hz0, hz1 = hx0 + head - 1, hy0 + head - 1, shoulder + 1, shoulder + head
    m.box(hx0, hx1, hy0, hy1, hz0, hz1, "skin1")
    m.box(hx0, hx1, hy0, hy1, hz0, hz0, "skin2")                      # chin shadow
    # The camera looks down at 45 degrees, so the helmet is kept shallow and set back:
    # otherwise all you see of a soldier is helmet.
    cap = max(1, round(head * 0.3))
    m.box(hx0, hx1, hy0, hy1 - max(1, head // 4), hz1 - cap + 1, hz1, "team1")
    m.box(hx0, hx1, hy0, hy0 + max(0, head // 3 - 1), hz0 + 1, hz1, "team2")   # back of helmet
    # Eyes, big for the size of the face.
    eye_z = hz1 - cap - max(0, head // 6)
    e = max(1, head // 5)
    es = max(1, head // 4)
    for ex in (hx0 + e, hx1 - e - es + 1):
        m.box(ex, ex + es - 1, hy1, hy1, eye_z - es + 1, eye_z, "dark")

    # Arms and hands.
    arm_len = max(2, torso)
    for side, ax in ((-1, bx0 - arm), (1, bx1 + 1)):
        raised = kind == "bazooka" and side == 1
        if raised:
            m.box(ax, ax + arm - 1, by0, by1 + arm, shoulder - arm + 1, shoulder, "olive1")
            m.box(ax, ax + arm - 1, by1 + arm, by1 + arm, shoulder - arm + 1, shoulder, "skin1")
        else:
            m.box(ax, ax + arm - 1, by0, by1, shoulder - arm_len + 1, shoulder, "olive2")
            m.box(ax, ax + arm - 1, by0, by1, shoulder - arm_len + 1, shoulder - arm_len + arm, "skin1")

    gx = bx1 + 1
    if kind == "rifle":
        # Held at the hip, pointing forward and a touch up.
        gz = shoulder - arm_len + arm + 1
        length = head + 3
        for i in range(length):
            z = gz + i // 4
            m.box(gx, gx + arm - 1, by0 - 1 + i, by0 - 1 + i, z, z, "wood" if i < 2 else "metal4")
        m.set(gx, by0 - 1 + length, gz + (length - 1) // 4, "dark")
    else:
        # Tube on the shoulder, sticking out front and back.
        t = max(1, round(h / 9))
        tz = shoulder + 1
        y0, y1 = hy0 - max(2, head // 2), hy1 + max(3, head // 2 + 1)
        m.box(gx, gx + t - 1, y0, y1, tz, tz + t - 1, "metal3")
        m.box(gx, gx + t - 1, y1, y1, tz, tz + t - 1, "dark")
        m.box(gx, gx + t - 1, y0, y0, tz, tz + t - 1, "metal4")
        m.box(gx, gx + t - 1, y1 - 1 - t, y1 - 2, tz, tz + t - 1, "white")   # band near the muzzle
    return m


def dog(h):
    """A dog to go with a soldier h voxels tall."""
    tall = max(4, round(h * 0.42))            # to the top of its back
    leg = max(2, round(tall * 0.45))
    length = max(6, round(h * 0.62))
    wide = max(2, round(h * 0.2))
    head = max(3, round(h * 0.28))
    sx, sy = wide + 6, length + head + 8
    m = Model(sx, sy, tall + head + 3)
    x0 = sx // 2 - wide // 2
    x1 = x0 + wide - 1
    y0 = 3
    y1 = y0 + length - 1
    lw = max(1, wide // 3)
    ld = max(1, length // 6)

    for lx in (x0, x1 - lw + 1):
        for ly in (y0, y1 - ld + 1):
            m.box(lx, lx + lw - 1, ly, ly + ld - 1, 0, leg - 1, "fur2")
            m.box(lx, lx + lw - 1, ly, ly + ld - 1, 0, 0, "fur3")
    m.box(x0, x1, y0, y1, leg, tall - 1, "fur1")
    m.box(x0, x1, y0, y1, tall - 1, tall - 1, "fur2")                 # darker back
    # Tail, up.
    tl = max(2, tall // 2)
    for i in range(tl):
        m.box(x0 + wide // 2 - (0 if wide < 3 else 0), x0 + wide // 2, y0 - 1 - i // 2, y0 - 1 - i // 2, tall - 1 + i, tall - 1 + i, "fur2")
    # Collar in team colour, then the head, held up and forward.
    hz0 = tall - max(1, head // 3)
    hy0 = y1 - max(0, head // 4)
    hx0 = sx // 2 - head // 2
    hx1 = hx0 + head - 1
    m.box(x0, x1, y1 - max(1, ld) + 1, y1, leg + 1, tall, "team1")
    m.box(hx0, hx1, hy0, hy0 + head - 1, hz0, hz0 + head - 1, "fur1")
    # Snout, nose, eyes, ears.
    sn = max(1, head // 2)
    m.box(hx0 + (head - sn) // 2, hx0 + (head - sn) // 2 + sn - 1, hy0 + head, hy0 + head + sn - 1, hz0, hz0 + sn - 1, "fur2")
    m.box(hx0 + (head - sn) // 2, hx0 + (head - sn) // 2 + sn - 1, hy0 + head + sn - 1, hy0 + head + sn - 1, hz0 + sn - 1, hz0 + sn - 1, "dark")
    es = max(1, head // 5)
    for ex in (hx0, hx1 - es + 1):
        m.box(ex, ex + es - 1, hy0 + head - 1, hy0 + head - 1, hz0 + head - 1 - es - max(0, head // 5), hz0 + head - 2 - max(0, head // 5) + (es - 1), "dark")
        m.box(ex, ex + es - 1, hy0 + es, hy0 + 2 * es, hz0 + head, hz0 + head + es, "fur3")   # ears
    return m


for h in HEIGHTS:
    for scale, suffix in ((1, ""), (2, "_hi")):
        soldier(h * scale, "rifle").save(f"Art/Voxel/Lineup/rifleman_{h}{suffix}.vox")
        soldier(h * scale, "bazooka").save(f"Art/Voxel/Lineup/bazooka_{h}{suffix}.vox")
        dog(h * scale).save(f"Art/Voxel/Lineup/dog_{h}{suffix}.vox")
print("wrote", len(HEIGHTS) * 6, "models to Art/Voxel/Lineup/")
