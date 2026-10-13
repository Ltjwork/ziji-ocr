"""Ink-constrained geometry shared by automatic and regional segmentation."""
from copy import deepcopy

import cv2
import numpy as np


def rect_of(item):
    return tuple(int(item.get(k, 0)) for k in ('x', 'y', 'w', 'h'))


def overlap(a, b):
    x, y = max(a[0], b[0]), max(a[1], b[1])
    return max(0, min(a[0]+a[2], b[0]+b[2])-x) * max(0, min(a[1]+a[3], b[1]+b[3])-y)


def meaningful_overlap(a, b, orientation='vertical'):
    """Whether overlap can steal ink from a neighbouring recognition line.

    A one-to-three pixel safety margin is harmless: character ownership is
    decided from ink/centre overlap and trimming it would cut edge strokes.
    Count only a substantial cross-axis intrusion (or a near-duplicate) in
    layout diagnostics and repair decisions.
    """
    area = overlap(a, b)
    if area <= 0:
        return False
    if orientation == 'horizontal':
        cross_a, cross_b = a[3], b[3]
        cross = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    else:
        cross_a, cross_b = a[2], b[2]
        cross = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    if cross < 0.25 * max(1, min(cross_a, cross_b)):
        return False
    fraction = area / max(1, min(a[2] * a[3], b[2] * b[3]))
    return fraction >= 0.12 or cross >= 0.25 * max(1, min(cross_a, cross_b))


def ink_rect(rect, mask, *, char=False):
    """Inspect adjacent 3px but retain only components touching the input."""
    ih, iw = mask.shape
    x, y, w, h = rect
    if w <= 0 or h <= 0:
        return None, 0
    pad = max(1, min(3, round(min(iw, ih) / 1800)))
    x1, y1 = max(0, x-3), max(0, y-3)
    x2, y2 = min(iw, x+w+3), min(ih, y+h+3)
    if x2 <= x1 or y2 <= y1:
        return None, 0
    roi = mask[y1:y2, x1:x2]
    _, labels, stats, _ = cv2.connectedComponentsWithStats(roi, 8)
    keep = np.zeros_like(roi)
    noise = 0
    min_area = max(3, min(20, round(min(w, h)**2 * .003)))
    for index, (cx, cy, cw, ch, area) in enumerate(stats[1:], 1):
        # Protect dots and short horizontal strokes, reject long thin borders.
        ruling = max(cw, ch) > max(60, min(w, h)*3) and min(cw, ch) <= 3
        bounds = (x1+int(cx), y1+int(cy), int(cw), int(ch))
        if area < min_area or ruling or not overlap(rect, bounds):
            noise += 1
            continue
        keep[labels == index] = 255
    ys, xs = np.nonzero(keep)
    if not len(xs):
        return None, noise
    left, top = max(0, x1+int(xs.min())-pad), max(0, y1+int(ys.min())-pad)
    right, bottom = min(iw, x1+int(xs.max())+1+pad), min(ih, y1+int(ys.max())+1+pad)
    return (left, top, right-left, bottom-top), noise


def _put(item, rect):
    item.update(zip(('x', 'y', 'w', 'h'), rect))


def normalize_layout(lines, mask, orientation='vertical', horizontal_dir='rtl', vertical_dir='ttb'):
    """Return normalized copies and deterministic, reviewable repair proposals."""
    from segmenter import drop_duplicate_fragment_lines, split_double_column_lines
    raw = deepcopy(lines)
    repairs, normalized = [], []
    diagnostics = dict(blank_regions=0, noise_components=0, overlaps_before=0, overlaps_after=0)
    diagnostics['overlaps_before'] = sum(
        meaningful_overlap(rect_of(a), rect_of(b), orientation)
        for i, a in enumerate(raw) for b in raw[i+1:])
    for line in raw:
        rect, noise = ink_rect(rect_of(line), mask)
        diagnostics['noise_components'] += noise
        if rect is None:
            diagnostics['blank_regions'] += 1
            repairs.append(dict(target_id=line['id'], action='remove_blank', rects=[],
                                confidence=.99, reason='无结构性墨迹', lines=[]))
            continue
        _put(line, rect)
        normalized.append(line)
    normalized = split_double_column_lines(normalized, mask, orientation, horizontal_dir, vertical_dir, allow_short=True)
    normalized, fragments = drop_duplicate_fragment_lines(normalized, orientation, mask)
    for fragment in fragments:
        repairs.append(dict(
            target_id=fragment['id'], action='dedupe', rects=[], lines=[],
            confidence=.91,
            reason='窄碎片字框与相邻宽列沿阅读轴重复，保留主列完整宽度',
        ))
    for line in normalized:
        bounds = rect_of(line)
        chars = []
        for char in line.get('chars', []):
            rect, _ = ink_rect(rect_of(char), mask, char=True)
            if rect is None:
                continue
            # Split children must never recover the other annotation column.
            if line.get('double_col_split'):
                left, top = max(bounds[0], rect[0]), max(bounds[1], rect[1])
                right = min(bounds[0]+bounds[2], rect[0]+rect[2])
                bottom = min(bounds[1]+bounds[3], rect[1]+rect[3])
                if right <= left or bottom <= top:
                    continue
                rect = left, top, right-left, bottom-top
            _put(char, rect)
            chars.append(char)
        if 'chars' in line:
            line['chars'] = chars
    # Deduplicate coincident detections, keeping the richer OCR hypothesis.
    removed = set()
    for i, a in enumerate(normalized):
        for j in range(i+1, len(normalized)):
            if i in removed or j in removed:
                continue
            b = normalized[j]
            ar, br = rect_of(a), rect_of(b)
            shared = overlap(ar, br)
            if not shared:
                continue
            if shared / max(1, min(ar[2]*ar[3], br[2]*br[3])) > .92:
                quality = lambda l: sum(float(c.get('conf') or .5) for c in l.get('chars', []))
                loser = j if quality(a) >= quality(b) else i
                removed.add(loser)
                old = normalized[loser]
                repairs.append(dict(target_id=old['id'], action='dedupe', rects=[], lines=[],
                                    confidence=.96, reason='删除同列重复检测'))
                continue
            # Partial overlap alone is not an error. Adjacent columns often
            # have generous safety margins and their ink belongs to different
            # character boxes. Never bisect those boxes at an arbitrary
            # midpoint; recognition uses character overlap/center ownership.
    normalized = [l for i, l in enumerate(normalized) if i not in removed]
    original = {l['id']: l for l in lines}
    for parent_id, parent in original.items():
        if any(p['target_id'] == parent_id for p in repairs):
            continue
        children = [l for l in normalized if l['id'] == parent_id or l.get('parent_line_id') == parent_id]
        if not children:
            continue
        old = rect_of(parent)
        new = rect_of(children[0])
        changed_chars = children[0].get('chars') != parent.get('chars')
        if len(children) > 1 or old != new or changed_chars:
            action = 'split_double_column' if len(children) > 1 else (
                'expand' if new[0] < old[0] or new[1] < old[1] or
                new[0]+new[2] > old[0]+old[2] or new[1]+new[3] > old[1]+old[3] else 'tighten')
            repairs.append(dict(target_id=parent_id, action=action,
                                rects=[list(rect_of(l)) for l in children], lines=children,
                                confidence=.92, reason='墨迹约束版面修复'))
    for i, line in enumerate(normalized):
        line.setdefault('orientation', orientation)
        line['line_no'] = i
        for j, char in enumerate(line.get('chars', [])):
            char.update(col=i, order=j, line_id=line['id'])
        if 'chars' in line:
            line['text'] = ''.join(c.get('text', '') for c in line['chars'])
    diagnostics['overlaps_after'] = sum(
        meaningful_overlap(rect_of(a), rect_of(b), orientation)
        for i, a in enumerate(normalized) for b in normalized[i+1:])
    return dict(lines=normalized, repairs=repairs, diagnostics=diagnostics)
