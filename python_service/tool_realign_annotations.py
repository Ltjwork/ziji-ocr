# -*- coding: utf-8 -*-
"""标注页号归位工具（一次性存量迁移，配合 pageIdForImage 的 stem 化修复）。

背景：pageIdForImage 曾对非 page_NNN 文件名（如 warped/split_page_273.png）
回退用 imageFiles 下标当页号；删页后下标漂移，全书标注文件名与当前页
错配，被 loadAnnotation 的 expectedImagePath 守卫整书丢弃——表现为
「全书识别丢失」（标注文件本身都在盘上，每个标注 JSON 内部记录的
image_path 仍是真实归属）。

Dart 侧已改为 stem 直接作页号；本工具把存量「下标型/旧页号」标注按其
记录的 image_path 归位到新页号（图片文件名 stem）名下，并同步迁移：
  - 字频账本  <data_root>/char_stats/<pid>__<pageId>.json（文件名 + 内容 page 字段）
  - AI 溯源   <project>/ai_trace/<pageId>.json 与 <pageId>/ 图片目录（文件名 + 内容 page_id）
  - 派生缓存 <project>/page_state_cache.json、cluster_cache.json（移入隔离区，触发重建）

同页多份候选（.json/.json.bak/.json.legacy 或历史上重复保存）取
json > bak > legacy、同级取 mtime 最新者；其余与无主文件（对应图片已被
删除/拆分源页等）全部移入项目内隔离目录 _realign_quarantine_<时间戳>/，
不删除任何数据。应用前自动备份 annotations/ 与 project.json、账本 JSON
到 <data_root>/_realign_backup_<pid>_<时间戳>/。

用法：
  python tool_realign_annotations.py                    # 全书库干跑（只报告）
  python tool_realign_annotations.py --apply            # 全书库应用
  python tool_realign_annotations.py 1790460224098 --apply   # 只处理指定项目（可多个）
  python tool_realign_annotations.py --data-root "C:\\Users\\x\\Documents\\GujiBT" ...

请在应用前关闭古籍拆字客户端。干跑不改任何文件。
"""
import argparse
import json
import os
import re
import shutil
import sys
import time

JSON_NAME = re.compile(r'^(?P<stem>.+)\.json$', re.IGNORECASE)


def norm(path: str) -> str:
    """与 Dart _sameImagePath 同口径：绝对路径、统一反斜杠、小写。"""
    return os.path.abspath(path).replace('/', '\\').lower()


def new_page_id(image_path: str, index: int) -> str:
    """与修复后的 Dart pageIdForImage 一致：stem 作页号，空/点开头 stem
    （如 ".png"）回退下标。"""
    stem = os.path.splitext(os.path.basename(image_path))[0]
    if not stem or stem.startswith('.'):
        return 'page_%03d' % index
    return stem


def parse_json(path: str):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


class Quarantine:
    """把文件/目录移入项目内隔离区；干跑时只记录。"""

    def __init__(self, root: str, apply: bool):
        self.root = root
        self.apply = apply
        self.moved = 0

    def _dest(self, src: str) -> str:
        return os.path.join(self.root, os.path.basename(src))

    def add(self, src: str, subdir: str = '') -> None:
        dest_dir = os.path.join(self.root, subdir) if subdir else self.root
        dest = os.path.join(dest_dir, os.path.basename(src))
        i = 2
        while os.path.exists(dest):
            dest = os.path.join(dest_dir, '%s.%d%s' % (
                os.path.splitext(os.path.basename(src))[0], i,
                os.path.splitext(os.path.basename(src))[1]))
            i += 1
        if self.apply:
            os.makedirs(dest_dir, exist_ok=True)
            shutil.move(src, dest)
        self.moved += 1


def scan_annotations(ann_dir: str) -> dict:
    """image_path(规范化) -> [(优先级, mtime, 路径, 内容)]，优先级 json>bak>legacy。"""
    pool = {}
    if not os.path.isdir(ann_dir):
        return pool
    for name in os.listdir(ann_dir):
        path = os.path.join(ann_dir, name)
        if not os.path.isfile(path):
            continue
        if name.endswith('.json'):
            kind = 3
        elif name.lower().endswith('.json.bak'):
            kind = 2
        elif name.lower().endswith('.json.legacy'):
            kind = 1
        else:
            continue
        data = parse_json(path)
        if not isinstance(data, dict):
            continue
        img = data.get('image_path')
        if not isinstance(img, str) or not img.strip():
            continue
        pool.setdefault(norm(img), []).append(
            (kind, os.path.getmtime(path), path, data))
    return pool


def realign_project(project_dir: str, data_root: str, apply: bool) -> dict:
    pid = os.path.basename(project_dir.rstrip('\\/'))
    proj_file = os.path.join(project_dir, 'project.json')
    if not os.path.isfile(proj_file):
        return {'project': pid, 'skipped': '无 project.json'}
    proj = parse_json(proj_file) or {}
    images = proj.get('image_files') or []
    stats = {'project': pid, 'name': proj.get('name', ''), 'pages': len(images),
             'aligned': 0, 'rewritten': 0, 'dups': 0, 'orphans': 0,
             'no_annotation': [], 'ledger_moves': 0, 'ledger_orphans': 0,
             'trace_moves': 0, 'trace_orphans': 0, 'cache_dropped': 0}

    ann_dir = os.path.join(project_dir, 'annotations')
    pool = scan_annotations(ann_dir)
    if not pool and not images:
        return stats

    # 期望页号：规范化 image_path -> (下标, 新页号)
    want = {norm(img): (i, new_page_id(img, i)) for i, img in enumerate(images)}
    # stem 唯一性防护：同书重名 stem 会让归位互相覆盖，直接跳过人工处理。
    stems = [pid for _, pid in want.values()]
    if len(stems) != len(set(stems)):
        return {'project': pid, 'skipped': '⚠ 图片文件名 stem 重复，已跳过，需人工处理'}

    winners = {}   # image_key -> (path, data)；输掉的候选进隔离区
    for key, cands in pool.items():
        cands.sort(key=lambda c: (c[0], c[1]), reverse=True)
        if key in want:
            winners[key] = cands[0]
            stats['dups'] += len(cands) - 1
        else:
            stats['orphans'] += len(cands)

    ts = time.strftime('%Y%m%d_%H%M%S')
    quarantine = Quarantine(os.path.join(project_dir, '_realign_quarantine_%s' % ts), apply)

    # ── 1. 备份（仅应用模式）── 收进 _realign_backups/ 子目录：备份内含
    # project.json，放在数据根一级会被首页 loadAll 当成书显示成重复卡片。
    if apply:
        backup = os.path.join(
            data_root, '_realign_backups', '%s_%s' % (pid, ts))
        os.makedirs(backup, exist_ok=True)
        if os.path.isdir(ann_dir):
            shutil.copytree(ann_dir, os.path.join(backup, 'annotations'),
                            dirs_exist_ok=True)
        shutil.copy2(proj_file, os.path.join(backup, 'project.json'))

    # ── 2. 规划每个标注文件的归宿 ──
    keep_files = set()      # 原名原样保留
    writes = {}             # 目标文件名 -> 内容 dict（重写 page_id）
    for key, (idx, page_id) in want.items():
        win = winners.get(key)
        if win is None:
            stats['no_annotation'].append('%s(%s)' % (page_id, os.path.basename(images[idx])))
            continue
        _, _, path, data = win
        target = os.path.join(ann_dir, page_id + '.json')
        if os.path.normcase(path) == os.path.normcase(target) and data.get('page_id') == page_id:
            stats['aligned'] += 1
            keep_files.add(os.path.normcase(path))
        else:
            new_data = dict(data)
            new_data['page_id'] = page_id
            writes[target] = new_data

    # 旧页号 -> 新页号映射（账本/溯源迁移用）：来自胜者文件的旧 stem。
    old_to_new = {}
    for key, (_, _, path, data) in winners.items():
        if key in want:
            m = JSON_NAME.match(os.path.basename(path))
            if m and not m.group('stem').lower().endswith(('.bak', '.legacy')):
                old_to_new[m.group('stem')] = want[key][1]

    # ── 3. 应用：隔离 → 重写 ──
    # 现名仍是某现存页 pageId 的 .bak，且内容确属该页 → 保留（它是 App
    # 崩溃恢复路径会读的功能性副本，不能当重复候选隔离）。
    stem_to_key = {v[1]: k for k, v in want.items()}
    parsed_of = {}  # 文件名 -> 内容（复用扫描结果，避免重复解析）
    for cands in pool.values():
        for _, _, path, data in cands:
            parsed_of[os.path.basename(path)] = data
    for name in os.listdir(ann_dir):
        path = os.path.join(ann_dir, name)
        if not os.path.isfile(path) or name.startswith('.'):
            continue  # 点文件是迁移/状态标记，原样保留
        if os.path.normcase(path) in keep_files or path in writes:
            continue
        m = re.match(r'^(?P<stem>.+)\.json\.bak$', name, re.IGNORECASE)
        if m:
            data = parsed_of.get(name)
            if data is not None and m.group('stem') in stem_to_key \
                    and norm(data.get('image_path', '')) == stem_to_key[m.group('stem')]:
                continue  # 现役恢复副本：原样保留
        quarantine.add(path)
    if apply:
        for target, data in writes.items():
            with open(target, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
    stats['rewritten'] = len(writes)

    # ── 4. 字频账本 <data_root>/char_stats/<pid>__<old>.json ──
    ledger_dir = os.path.join(data_root, 'char_stats')
    if os.path.isdir(ledger_dir):
        prefix = pid + '__'
        for name in sorted(os.listdir(ledger_dir)):
            if not name.startswith(prefix):
                continue
            path = os.path.join(ledger_dir, name)
            if not os.path.isfile(path):
                continue
            m = re.match(r'^(?P<old>.+?)\.json(\.bak)?$', name[len(prefix):])
            if not m:
                continue
            old = m.group('old')
            if old not in old_to_new:
                quarantine.add(path, 'char_stats')
                stats['ledger_orphans'] += 1
                continue
            new = old_to_new[old]
            if old == new:
                continue  # 本就对齐（健康书籍零触碰）
            new_path = os.path.join(ledger_dir, prefix + new + '.json' + (m.group(2) or ''))
            data = parse_json(path)
            if apply:
                if os.path.exists(new_path):
                    # 撞名：保留 updated 较新者，另一份进隔离区。
                    other = parse_json(new_path)
                    if (data or {}).get('updated', '') < (other or {}).get('updated', ''):
                        quarantine.add(path, 'char_stats')
                        stats['ledger_orphans'] += 1
                        continue
                    quarantine.add(new_path, 'char_stats')
                if isinstance(data, dict):
                    data['page'] = new
                    with open(path, 'w', encoding='utf-8') as f:
                        json.dump(data, f, ensure_ascii=False, indent=2)
                os.replace(path, new_path)
            stats['ledger_moves'] += 1

    # ── 5. AI 溯源 <project>/ai_trace/<old>.json 与 <old>/ ──
    trace_dir = os.path.join(project_dir, 'ai_trace')
    if os.path.isdir(trace_dir):
        for name in sorted(os.listdir(trace_dir)):
            is_file = name.endswith('.json')
            old = name[:-5] if is_file else name
            path = os.path.join(trace_dir, name)
            new = old_to_new.get(old)
            if new is not None and new != old:
                if apply:
                    data = parse_json(path) if is_file else None
                    if isinstance(data, dict) and 'page_id' in data:
                        data['page_id'] = new
                        with open(path, 'w', encoding='utf-8') as f:
                            json.dump(data, f, ensure_ascii=False, indent=2)
                    os.replace(path, os.path.join(trace_dir, new + ('.json' if is_file else '')))
                stats['trace_moves'] += 1
            elif new is None:
                quarantine.add(path, 'ai_trace')
                stats['trace_orphans'] += 1

    # ── 6. 派生缓存：仅在本项目确有归位/隔离动作时移入隔离区触发重建
    # （完全健康的书籍零触碰）。
    if stats['rewritten'] or stats['orphans'] or stats['trace_orphans']:
        for cache in ('page_state_cache.json', 'cluster_cache.json'):
            path = os.path.join(project_dir, cache)
            if os.path.isfile(path):
                quarantine.add(path)
                stats['cache_dropped'] += 1

    stats['quarantined'] = quarantine.moved
    return stats


def verify_project(project_dir: str) -> dict:
    """按新页号口径校验：每页标注文件存在且 image_path 归属正确。"""
    proj = parse_json(os.path.join(project_dir, 'project.json')) or {}
    images = proj.get('image_files') or []
    ok = bad = miss = 0
    for i, img in enumerate(images):
        f = os.path.join(project_dir, 'annotations', new_page_id(img, i) + '.json')
        data = parse_json(f) if os.path.isfile(f) else None
        if data is None:
            miss += 1
        elif norm(data.get('image_path', '')) == norm(img):
            ok += 1
        else:
            bad += 1
    return {'project': os.path.basename(project_dir), 'pages': len(images),
            'ok': ok, 'mismatch': bad, 'missing': miss}


def main() -> int:
    sys.stdout.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser(description='标注页号归位（干跑默认）')
    ap.add_argument('projects', nargs='*', help='项目 id（缺省=书库全部）')
    ap.add_argument('--apply', action='store_true', help='真正应用（默认干跑）')
    ap.add_argument('--data-root', default=os.path.join(
        os.path.expanduser('~'), 'Documents', 'GujiBT'))
    ap.add_argument('--verify', action='store_true',
                    help='只校验不规划（配合 --apply 后复查）')
    args = ap.parse_args()

    root = args.data_root
    # 书库根下的备份/隔离目录不是项目，排除（否则二次运行会"归位"备份，
    # 破坏其作为原始快照的价值）。
    def list_projects():
        return [d for d in os.listdir(root)
                if not d.startswith('_') and d != 'char_stats'
                and os.path.isfile(os.path.join(root, d, 'project.json'))]

    if args.verify:
        for pid in (args.projects or list_projects()):
            print(json.dumps(verify_project(os.path.join(root, pid)),
                             ensure_ascii=False))
        return 0

    ids = args.projects or sorted(list_projects())
    total = {'rewritten': 0, 'no_annotation': 0, 'quarantined': 0}
    for pid in ids:
        stats = realign_project(os.path.join(root, pid), root, args.apply)
        for k in total:
            total[k] += (len(stats.get(k, [])) if k == 'no_annotation'
                         else stats.get(k, 0))
        mode = '应用' if args.apply else '干跑'
        print('[%s] %s %s：页 %s | 已对齐 %s | 待归位 %s | 重复候选 %s | 无主 %s | 无标注 %s | '
              '账本迁移 %s/无主 %s | 溯源迁移 %s/无主 %s | 隔离 %s' % (
                  mode, stats['project'], stats.get('name', '')[:20], stats.get('pages'),
                  stats.get('aligned'), stats.get('rewritten'), stats.get('dups'),
                  stats.get('orphans'), len(stats.get('no_annotation', [])),
                  stats.get('ledger_moves'), stats.get('ledger_orphans'),
                  stats.get('trace_moves'), stats.get('trace_orphans'),
                  stats.get('quarantined', 0)))
        for p in stats.get('no_annotation', [])[:10]:
            print('    无标注页：', p)
    print('── 合计：待归位 %s、无标注 %s、隔离 %s（%s）' % (
        total['rewritten'], total['no_annotation'], total['quarantined'],
        'apply' if args.apply else 'dry-run'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
