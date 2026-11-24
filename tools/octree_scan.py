#!/usr/bin/env python3
# octree_scan.py <project>/build/geometry/xml/AKEV<name>.xml (needs numpy): every visible quad
# whose front side passes through octree leaves that don't list it (Oni's ray-cast visibility can't
# mark it through those leaves: seen only through them, it isn't drawn). Prints counts, and how many
# such quads have a vertex just off the 1/8 grid. Catwalk's Build snaps rounding drift (TECHNICAL.md).
import sys, xml.etree.ElementTree as ET
import numpy as np
t = ET.parse(sys.argv[1]).getroot()
byid = {e.get('id'): e for e in t}
akot = t.find('AKOT')
ref = lambda tag: byid[akot.find(tag).text.lstrip('#')]
leaves = list(ref('Leafs').find('Nodes'))
gql = [int(e.text) for e in ref('GunkQuad')[0]]
pts = np.array([[float(v) for v in p.text.split()] for p in t.find('PNTA').find('Positions')])
quads = list(t.find('AGQG').find('Quads'))
cell = {}
lists = []
for li, lf in enumerate(leaves):
    enc = int(lf.find('PackedGunkQuadList').text) & 0xffffffff
    start, ln = (enc >> 12) & 0xFFFFF, enc & 0xFFF
    lists.append(set(gql[start:start + ln]))
    d = int(lf.find('PackedPositionAndSize').text) & 0xffffffff
    k = 1 << ((d >> 27) & 0x1F)
    mx, my, mz = ((d >> 18) & 0x1FF) - 255, ((d >> 9) & 0x1FF) - 255, (d & 0x1FF) - 255
    for x in range(mx - k, mx):
        for y in range(my - k, my):
            for z in range(mz - k, mz):
                cell[(x, y, z)] = li
bad, offgrid_bad, offgrid_all, total = [], 0, 0, 0
for qi, q in enumerate(quads):
    fl = q.find('Flags').text or ''
    if 'Invisible' in fl: continue
    idx = [int(e.text) for e in q.find('Points')]
    P = pts[idx]
    n = np.cross(P[1] - P[0], P[2] - P[0]); nn = np.linalg.norm(n)
    if nn == 0: continue
    n /= nn
    total += 1
    og = bool((np.abs(P - np.round(P * 8) / 8) > 1e-6).any())
    offgrid_all += og
    miss = set()
    m = 7
    for u in np.linspace(0.03, 0.97, m):
        for v in np.linspace(0.03, 0.97, m):
            if len(P) == 4: p = P[0] * (1 - u) * (1 - v) + P[1] * u * (1 - v) + P[2] * u * v + P[3] * (1 - u) * v
            else:
                if u + v > 1: continue
                p = P[0] * (1 - u - v) + P[1] * u + P[2] * v
            s = p + n * 0.02
            c = tuple(int(np.floor(s[k] / 16)) for k in range(3))
            li = cell.get(c)
            if li is not None and qi not in lists[li]: miss.add(li)
    if miss:
        bad.append((qi, len(miss), og, fl))
        offgrid_bad += og
print(f"{total} visible quads; {len(bad)} pass through leaves that don't list them on their front side "
      f"({offgrid_bad} of those have a vertex off the 1/8 grid; {offgrid_all} of all quads do)")
for qi, nmiss, og, fl in sorted(bad, key=lambda b: -b[1])[:15]:
    P = pts[[int(e.text) for e in quads[qi].find('Points')]]
    print(f"  quad {qi}: {nmiss} leaves, off-grid {og}, {P.min(0).round(3).tolist()}..{P.max(0).round(3).tolist()} {fl}")
