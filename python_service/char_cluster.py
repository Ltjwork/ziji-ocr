"""单字墨迹聚类：按笔画形态把字块分组，供前端统一校正。

聚类只看墨迹 mask（与识别文字无关）：每个字框裁切后提 HOG 形状描述
子（64x64、8x8 cell）+ 宽高比惩罚，组成距离矩阵后用 complete linkage
层次聚类按距离阈值切组。特征组合与默认阈值在本机真实书页上校准
（560 字页：68% 组组内文字完全一致，其中相当一部分"不一致"其实是
OCR 本身读错、恰是本功能要批量修正的对象）。纯 CPU（numpy/scipy），
不占 GPU 识别门，一页千余字耗时百毫秒量级。

全书批量（cluster_chars_batch）：先逐页做与单页完全相同的 complete
linkage 聚类，把每页每组（含单字组）压缩成一个原型（组内均值 HOG +
均值宽高比），再跨页把原型按"最近全局组中心且距离 <= 阈值"贪心并入。
距离矩阵只在页内构建（n≈数百），跨页阶段是原型×组中心的小矩阵，
内存随页数线性增长（原型数≈全书字种数），整本书可直接跑。
"""

import time

import cv2
import numpy as np
from scipy.cluster.hierarchy import fcluster, linkage
from scipy.spatial.distance import squareform

from segmenter import _text_mask_for_refinement

FEATURE_SIZE = 64  # HOG 输入边长
W_ASPECT = 0.10  # 宽高比惩罚权重：|log(ar1/ar2)| 截断到 [0,1] 后加权
MAX_ASPECT_DIFF = 1.0

DEFAULT_THRESHOLD = 0.15

# cv2.HOGDescriptor 用关键字构造（位置参数在部分版本上不可靠）
_HOG = cv2.HOGDescriptor(
    _winSize=(FEATURE_SIZE, FEATURE_SIZE),
    _blockSize=(16, 16),
    _blockStride=(8, 8),
    _cellSize=(8, 8),
    _nbins=9,
)


def _to_square(crop: np.ndarray) -> np.ndarray:
    """对称补边成正方形（letterbox）：直接拉到 64x64 会把扁宽/瘦长字
    拉伸变形，宽高比差异交给 aspect 惩罚去度量。"""
    side = max(crop.shape)
    square = np.zeros((side, side), dtype=crop.dtype)
    oy = (side - crop.shape[0]) // 2
    ox = (side - crop.shape[1]) // 2
    square[oy : oy + crop.shape[0], ox : ox + crop.shape[1]] = crop
    return square


def _char_feature(mask: np.ndarray, rect: tuple[int, int, int, int]):
    """从整页墨迹 mask 裁出单字并提 (hog, aspect)；退化字框返回 None。"""
    x, y, w, h = rect
    if w < 2 or h < 2:
        return None
    x1, y1 = max(0, x), max(0, y)
    x2 = min(mask.shape[1], x + w)
    y2 = min(mask.shape[0], y + h)
    crop = mask[y1:y2, x1:x2]
    if crop.size == 0 or min(crop.shape) < 2:
        return None
    small = cv2.resize(
        _to_square(crop), (FEATURE_SIZE, FEATURE_SIZE), interpolation=cv2.INTER_AREA
    )
    desc = _HOG.compute(small.astype(np.uint8)).flatten()
    norm = float(np.linalg.norm(desc))
    if norm < 1e-6:
        return None  # 框内没有墨迹
    return desc / norm, float(w) / float(h)


def _distance_matrix(hogs: np.ndarray, aspects: np.ndarray) -> np.ndarray:
    """全向量化计算 n×n 距离矩阵：HOG 余弦距离 + 宽高比惩罚。"""
    cos_dist = np.clip(1.0 - hogs @ hogs.T, 0.0, 2.0)
    log_diff = np.abs(np.log(aspects)[:, None] - np.log(aspects)[None, :])
    dist = cos_dist + W_ASPECT * np.clip(log_diff, 0.0, MAX_ASPECT_DIFF)
    np.fill_diagonal(dist, 0.0)
    return np.clip(dist, 0.0, None)


def _cohesion(dist: np.ndarray, indices: list[int]) -> float:
    """组内平均两两距离（凝聚度，越小越像）。"""
    if len(indices) < 2:
        return 0.0
    sub = dist[np.ix_(indices, indices)]
    k = len(indices)
    return float(sub.sum()) / 2.0 / (k * (k - 1) / 2.0)


def _collect_features(image_path: str, blocks: list):
    """提一页全部字块的 (hog, aspect) 特征。

    返回 (feats, ids, skipped)：skipped 是无法提特征的字块 id
    （空框/出界/无墨迹）；图像不可读抛 ValueError。
    """
    mask = _text_mask_for_refinement(image_path)
    if mask is None:
        raise ValueError(f"cannot read image or build text mask: {image_path}")
    feats: list = []
    ids: list[str] = []
    skipped: list[str] = []
    for block in blocks:
        feat = _char_feature(mask, (block.x, block.y, block.w, block.h))
        if feat is None:
            skipped.append(block.id)
            continue
        feats.append(feat)
        ids.append(block.id)
    return feats, ids, skipped


def _complete_linkage_groups(feats: list, threshold: float) -> list[list[int]]:
    """complete linkage 层次聚类，返回分组成员下标（含 size==1 的组）。

    complete linkage：组内最远两两距离 <= threshold 才合并，避免
    average/single linkage 把相邻字形链式吸成大杂烩组。
    """
    n = len(feats)
    if n == 0:
        return []
    if n == 1:
        return [[0]]
    hogs = np.stack([f[0] for f in feats])
    aspects = np.array([f[1] for f in feats], dtype=np.float64)
    dist = _distance_matrix(hogs, aspects)
    condensed = squareform((dist + dist.T) / 2.0, checks=False)
    z = linkage(condensed, method="complete")
    labels = fcluster(z, t=threshold, criterion="distance")
    groups: dict[int, list[int]] = {}
    for i, label in enumerate(labels):
        groups.setdefault(int(label), []).append(i)
    return list(groups.values())


def cluster_chars(
    image_path: str,
    blocks: list,
    threshold: float = DEFAULT_THRESHOLD,
    min_cluster_size: int = 2,
) -> dict:
    """对一页字块按墨迹形态聚类。

    blocks 为带 id/x/y/w/h 的对象（main.py 的 Block 模型）。
    返回：
      clusters: [{block_ids, size, cohesion}]，按 size 降序，size >= min_cluster_size
      singletons: 落单字块 id（有效特征但没聚进任何组）
      skipped:   无法提特征的字块 id（空框/出界/无墨迹）
      params:    本次聚类参数与特征版本
    """
    started = time.time()
    threshold = float(min(0.5, max(0.05, threshold)))
    min_cluster_size = max(2, int(min_cluster_size))

    feats, ids, skipped = _collect_features(image_path, blocks)

    clusters_out: list[dict] = []
    singletons: list[str] = []
    if len(feats) >= 2:
        hogs = np.stack([f[0] for f in feats])
        aspects = np.array([f[1] for f in feats], dtype=np.float64)
        dist = _distance_matrix(hogs, aspects)
        for members in _complete_linkage_groups(feats, threshold):
            if len(members) >= min_cluster_size:
                clusters_out.append(
                    {
                        "block_ids": [ids[i] for i in members],
                        "size": len(members),
                        "cohesion": round(_cohesion(dist, members), 4),
                    }
                )
            else:
                singletons.extend(ids[i] for i in members)
        clusters_out.sort(key=lambda c: c["size"], reverse=True)

    return {
        "clusters": clusters_out,
        "singletons": singletons,
        "skipped": skipped,
        "params": {
            "threshold": threshold,
            "min_cluster_size": min_cluster_size,
            "feature": f"hog{FEATURE_SIZE}+aspect",
            "aspect_weight": W_ASPECT,
        },
        "elapsed_ms": round((time.time() - started) * 1000.0, 1),
    }


class _GlobalGroups:
    """跨页全局组的增量合并结构：中心 HOG/aspect + 成员 id + 距中心和。

    中心数组按几何容量增长（避免逐组 vstack 全量拷贝）；chunk 内并入
    用的是进入本 chunk 时的中心快照，chunk 取小值（64）让后续 chunk
    能看到刚并入的更新。
    """

    _CHUNK = 64

    def __init__(self, dim: int):
        self._dim = dim
        self._cap = 1024
        self._hogs = np.zeros((self._cap, dim))
        self._aspects = np.zeros(self._cap)
        self._counts: list[int] = []
        self._dist_sums: list[float] = []
        self._members: list[list[str]] = []
        self.size = 0

    def _ensure_capacity(self, extra: int):
        need = self.size + extra
        if need <= self._cap:
            return
        while self._cap < need:
            self._cap *= 2
        hogs = np.zeros((self._cap, self._dim))
        hogs[: self.size] = self._hogs[: self.size]
        self._hogs = hogs
        aspects = np.zeros(self._cap)
        aspects[: self.size] = self._aspects[: self.size]
        self._aspects = aspects

    def _append(self, hog: np.ndarray, aspect: float, ids: list[str]):
        self._ensure_capacity(1)
        i = self.size
        self._hogs[i] = hog
        self._aspects[i] = aspect
        self._counts.append(len(ids))
        self._dist_sums.append(0.0)
        self._members.append(list(ids))
        self.size += 1

    def _dist_to_centroids(self, hog: np.ndarray, aspect: float) -> np.ndarray:
        """单原型到全部组中心的距离向量（空表返回空数组）。"""
        if self.size == 0:
            return np.zeros(0)
        cos = np.clip(1.0 - self._hogs[: self.size] @ hog, 0.0, 2.0)
        pen = W_ASPECT * np.clip(
            np.abs(np.log(aspect) - np.log(self._aspects[: self.size])),
            0.0,
            MAX_ASPECT_DIFF,
        )
        return np.clip(cos + pen, 0.0, None)

    def _merge_one(
        self,
        hog: np.ndarray,
        aspect: float,
        ids: list[str],
        threshold: float,
    ):
        dist = self._dist_to_centroids(hog, aspect)
        if dist.size == 0 or float(dist.min()) > threshold:
            self._append(hog, aspect, ids)
            return
        g = int(dist.argmin())
        w_old = self._counts[g]
        w_new = len(ids)
        cent = (self._hogs[g] * w_old + hog * w_new) / (w_old + w_new)
        norm = float(np.linalg.norm(cent))
        self._hogs[g] = cent / max(norm, 1e-6)
        self._aspects[g] = (self._aspects[g] * w_old + aspect * w_new) / (
            w_old + w_new
        )
        self._counts[g] = w_old + w_new
        self._dist_sums[g] += float(dist[g]) * w_new
        self._members[g].extend(ids)

    def merge(
        self,
        prototypes: list[tuple[np.ndarray, float, list[str]]],
        threshold: float,
    ):
        """把一批原型并入全局组：最近中心距离 <= threshold 则并入
        （中心按成员数加权更新），否则开新组。

        分块向量化以看到最新中心；空表启动与小块收尾走逐个并入，
        避免首批原型互相不可见而拆出重复组。"""

        for start in range(0, len(prototypes), self._CHUNK):
            chunk = prototypes[start : start + self._CHUNK]
            if self.size == 0 or len(chunk) < 8:
                for hog, aspect, ids in chunk:
                    self._merge_one(hog, aspect, ids, threshold)
                continue
            h = np.stack([p[0] for p in chunk])
            a = np.array([p[1] for p in chunk], dtype=np.float64)
            cents = self._hogs[: self.size]
            cent_a = self._aspects[: self.size]
            cos = np.clip(1.0 - h @ cents.T, 0.0, 2.0)
            pen = W_ASPECT * np.clip(
                np.abs(np.log(a)[:, None] - np.log(cent_a)[None, :]),
                0.0,
                MAX_ASPECT_DIFF,
            )
            dist = np.clip(cos + pen, 0.0, None)
            nearest = dist.argmin(axis=1)
            dmin = dist.min(axis=1)
            for i, (hog, aspect, ids) in enumerate(chunk):
                g = int(nearest[i])
                if dmin[i] > threshold:
                    self._append(hog, aspect, ids)
                    continue
                w_old = self._counts[g]
                w_new = len(ids)
                cent = (self._hogs[g] * w_old + hog * w_new) / (w_old + w_new)
                norm = float(np.linalg.norm(cent))
                self._hogs[g] = cent / max(norm, 1e-6)
                self._aspects[g] = (
                    self._aspects[g] * w_old + aspect * w_new
                ) / (w_old + w_new)
                self._counts[g] = w_old + w_new
                self._dist_sums[g] += float(dmin[i]) * w_new
                self._members[g].extend(ids)

    def result(self, min_cluster_size: int) -> dict:
        clusters: list[dict] = []
        singletons: list[str] = []
        for g in range(self.size):
            ids = self._members[g]
            if len(ids) >= min_cluster_size:
                clusters.append(
                    {
                        "block_ids": ids,
                        "size": len(ids),
                        # 跨页组的凝聚度代理：成员原型到组中心的平均距离
                        #（页内组仍按 complete-linkage 阈值约束，越小越像）。
                        "cohesion": round(self._dist_sums[g] / len(ids), 4),
                    }
                )
            else:
                singletons.extend(ids)
        clusters.sort(key=lambda c: c["size"], reverse=True)
        return {"clusters": clusters, "singletons": singletons}


def cluster_chars_batch(
    pages: list,
    threshold: float = DEFAULT_THRESHOLD,
    min_cluster_size: int = 2,
) -> dict:
    """全书墨迹归类：逐页提特征 → 页内 complete-linkage 聚类 → 组原型
    跨页贪心并入全局组。

    pages 为 [(image_path, blocks)]（main.py 的请求模型）；块 id 由前端
    保证全局唯一（带页前缀）。某页失败只记入 failed_pages，不中断整批。
    返回格式与 cluster_chars 一致，另附 failed_pages/pages/chars 统计。
    """
    started = time.time()
    threshold = float(min(0.5, max(0.05, threshold)))
    min_cluster_size = max(2, int(min_cluster_size))

    # HOG 描述子维度（64x64/8x8cell/9bin → 1764），从一次空图计算取长度
    hog_dim = len(
        _HOG.compute(np.zeros((FEATURE_SIZE, FEATURE_SIZE), np.uint8)).flatten()
    )
    groups = _GlobalGroups(hog_dim)
    skipped: list[str] = []
    failed_pages: list[dict] = []
    total_chars = 0

    for page_index, page in enumerate(pages):
        try:
            feats, ids, page_skipped = _collect_features(page.image_path, page.blocks)
        except Exception as exc:
            failed_pages.append({"image_path": page.image_path, "error": str(exc)})
            continue
        skipped.extend(page_skipped)
        total_chars += len(page.blocks)
        if not feats:
            continue
        # 页内聚类（含 size==1 组）→ 每组一个原型
        prototypes: list[tuple[np.ndarray, float, list[str]]] = []
        for member_idx in _complete_linkage_groups(feats, threshold):
            hogs = np.stack([feats[i][0] for i in member_idx])
            proto = hogs.mean(axis=0)
            norm = float(np.linalg.norm(proto))
            if norm < 1e-6:
                proto = hogs[0]
            else:
                proto = proto / norm
            aspect = float(np.mean([feats[i][1] for i in member_idx]))
            prototypes.append((proto, aspect, [ids[i] for i in member_idx]))
        groups.merge(prototypes, threshold)
        if (page_index + 1) % 20 == 0:
            print(
                f"[char_clusters_batch] {page_index + 1}/{len(pages)} pages, "
                f"{groups.size} global groups, "
                f"elapsed={time.time() - started:.1f}s",
                flush=True,
            )

    payload = groups.result(min_cluster_size)
    return {
        **payload,
        "skipped": skipped,
        "failed_pages": failed_pages,
        "pages": len(pages),
        "chars": total_chars,
        "params": {
            "threshold": threshold,
            "min_cluster_size": min_cluster_size,
            "feature": f"hog{FEATURE_SIZE}+aspect+proto-merge",
            "aspect_weight": W_ASPECT,
        },
        "elapsed_ms": round((time.time() - started) * 1000.0, 1),
    }
