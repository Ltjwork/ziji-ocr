"""单字墨迹校验：识别文字的字形骨架与墨迹骨架做拓扑+形状重叠比对。

思路（指纹式 minutiae 比对的汉字版）：墨迹和识别字渲染出的楷体字形
各自归一化到同一画布后细化成单像素骨架——粗细、毛笔风格、断笔缝隙
等书写性差异在骨架层被抹平，剩下的笔画中轴拓扑（洞数、端点、交叉
点）与位置才是稳定的比对特征。三层打分：

  L0 拓扑计数——洞/连通块/端点/T 形分叉/十字交叉各量比对，抓
     "昌→日"类结构级错误（洞数直接差 2）；无洞开放字的端点/分叉极端
     差异也纳入硬失败；
  L1 特征点位置匹配——端点+分叉点先做指纹式对齐（类型化点对霍夫投
     票平移 + 旋转/等比缩放网格），再做类型化最近邻匹配，抓"未→末"
     类拓扑同构、仅比例不同的错误；全封闭字（口/日/田）骨架上既无端
     点也无分叉，改用骨架均匀采样点集做同款对齐+半径内点率兜底；
  L2 骨架形状距离——对齐后的双向 Chamfer 距离兜底综合分；
  L3 learned 比对层（可选）——自训 siamese 模型（verify_training）对
     墨迹/字形取嵌入余弦；默认非对称救回（模型强烈认同才更难标红，
     只救不罚），对称加权保留为标定开关。模型未训练时整层自动缺席。

比对前的预处理（"输入脏"是误报的第一来源）：
  - 裁切门禁——邻字渗墨按连通域剔除、笔画被字框切断直接跳过（宁可
    不校验不误报）、按墨迹包围盒紧致化保证与字形侧同一中心化口径；
  - 笔宽归一——墨迹因墨渗比楷体字模粗时按距离变换收细到字形笔宽
    （带丢笔画守卫，只收不加粗），从源头减少假洞/假分叉。
判定阈值带按识别置信度平移（conf 高要求更强的结构证据才标红）。

纯 CPU（numpy/cv2/PIL），不走 GPU 识别门；Zhang-Suen 细化为 numpy
手写实现，不引 scikit-image，避免动用户 conda 环境。刻本页同字重复
率高，字形骨架按字缓存。

阈值与权重为本机合成样本初值，真实书页回测（char_verify 的
verify_chars_batch 对已确认标注页统计误报/命中）后标定。
"""
# 本文件是门面（facade）：实现已按职责拆分到 char_skeleton, char_glyph，此处 re-export 保持既有 import 面不变。
import base64
import json
import math
import os
import time
import unicodedata
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from segmenter import _imread, _text_mask_for_refinement
import registry_io
from char_skeleton import (CANVAS, CHAMFER_NORM, HARD_FAIL_DIFF, HARD_FAIL_RATIO, MATCH_FULL, MATCH_RADIUS, REL_TOL, SAMPLE_FULL, SAMPLE_RADIUS, SAMPLE_TARGET, TOPO_TOL, TOPO_WEIGHT, W_MATCH, W_SHAPE, W_TOPO, _normalize, _prepare, _skeleton, _topology, _minutiae, _stroke_width)



MISMATCH_SCORE = 0.62      # 0.62/0.80 为对齐+同伴互证上线后的回测再标


SUSPECT_SCORE = 0.80       # 定（原 0.55/0.75）：霍夫对齐与笔宽收细把正


# --- 置信度融合（阶段 A5） ------------------------------------------------
# conf 高（识别器确信）→ 要求更强的结构证据才标红（阈值带整体下移）；
# conf 低 → 更容易标红（阈值带上移）。硬失败不受影响（结构证据压倒一切）。
CONF_HIGH = 0.95


CONF_LOW = 0.50


CONF_SHIFT = 0.03         # 阈值带平移幅度（回测扫描标定）


# --- char_cls 分数融合（模型化阶段 1） -------------------------------------
# 墨迹校验与自训候选字分类器（char_cls，训练自本书确认字）互相印证：
# 当前文字进分类器 top-3 → 分类器支持该读法，阈值带下移（更难标红）；
# 掉出 top-10 → 分类器也不认可，阈值带上移（更易标红）。模型未训练/
# 未激活时无信号（cls_rank=None），静默退回纯墨迹比对。批量校验复用
# /char_candidates 的推理路径（GPU，YOLO 预测锁内），单字路径由前端
# 把识别时已有的候选排名传入（零新增推理）。
CLS_SHIFT = 0.0           # 融合平移幅度。默认 0（关闭）：第五册 3502 确认


                          # 字 / 609 类的数据密度下分类器只有随机水平
                          # （top5 0.68%），实测融合把误报 +2.3pt、命中仅
                          # +1.0pt——坏交易。确认数据积累后重训 char_cls
                          # （训练页卡片可见 top1/top5 指标）并回测扫描
                          # --cls-shift 再启用
CLS_SUPPORT_RANK = 3      # 排名 <= 此值视为"分类器支持"


CLS_TOP_K = 10            # 分类器取 top-K（也是"掉出"判定的 K）


# --- learned 比对层（模型化阶段 2） -----------------------------------------
# 自训 siamese 比对模型（verify_training 训练、verify_model 定义）作为
# 第四层：墨迹/字形各过同一编码器取 64 维嵌入，余弦映射到 0-1 与三层
# 手工分加权平均。模型未训练/未激活/torch 不可用时本层自动缺席，公式
# 与阈值完全回退到三层手工判定。推理显式 CPU（每字一次小前向，毫秒
# 级），不占 GPU 识别门。
W_PAIR = 0.0              # learned 分的加权权重。默认 0：对称加权实测是


                          # 均坏交易（v2 模型误报 -2.1/命中 -1.7，比值
                          # 1.24 但超门槛）——模型的负向信号与手工三层
                          # 冗余，正向信号（"确实是同一字形"）才是增量。
                          # 改用非对称救回（LEARNED_HIGH/LEARNED_SHIFT，
                          # 见下）；对称加权保留为标定开关（--pair-weight）
LEARNED_HIGH = 0.88       # 比对分 >= 此值：模型强烈认同该读法（回测扫描


                          # 0.80/0.85/0.88 三档，0.88 最优：误报 -1.7pt、
                          # 命中 -0.9pt，唯一同时过"误报降、命中降幅 <=1pt"
                          # 门槛的档位）
LEARNED_SHIFT = 0.02      # ……阈值带下移（更难标红，只救不罚——错读的


                          # 易混字对比对分多落在 0.5-0.7，够不到此线）
_MODELS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "models")


_ACTIVE_PAIR_PATH = os.path.join(_MODELS_DIR, "active_verify_pair.pt")


_pair_model: tuple[str, object] | None = None   # (路径, module) 缓存


_glyph_emb_cache: dict[str, np.ndarray] = {}




def _pair_model_module():
    """惰性加载比对模型（CPU）：注册表 active 路径优先，稳定路径兜底；
    路径变化自动重载；torch 不可用/加载失败按未启用（返回 None）。"""
    global _pair_model
    path = None
    p = (registry_io.load_registry(
             os.path.join(_MODELS_DIR, "registry.json"))
         .get("layers", {}).get("verify_pair") or {}).get("active")
    if p and os.path.exists(p):
        path = p
    if path is None and os.path.exists(_ACTIVE_PAIR_PATH):
        path = _ACTIVE_PAIR_PATH
    if path is None:
        # 散文件全缺（用户机安装形态）：.zjpack 发行包物化文件兜底。
        try:
            import model_store

            packed = model_store.resolve("yolo_verify_pair")
            if packed:
                path = packed
        except Exception:
            pass
    if path is None:
        _pair_model = None
        return None
    if _pair_model is not None and _pair_model[0] == path:
        return _pair_model[1]
    try:
        import torch
        module = torch.load(path, map_location="cpu", weights_only=False)
        module.eval()
        _pair_model = (path, module)
    except Exception:
        _pair_model = None
    return _pair_model[1] if _pair_model else None




def _embed_images(module, imgs: list[np.ndarray]) -> np.ndarray:
    """批量嵌入（CPU；输入为 128 画布二值图 0/255，与训练同口径）。"""
    import torch
    x = np.stack([
        (np.asarray(im, dtype=np.float32) > 0).astype(np.float32)
        for im in imgs])[:, None, :, :]
    with torch.no_grad():
        z = module(torch.from_numpy(x)).numpy()
    return z




def _glyph_embedding(ch: str, module) -> np.ndarray | None:
    """字形嵌入按字缓存（刻本页同字重复率高）。"""
    if ch in _glyph_emb_cache:
        return _glyph_emb_cache[ch]
    glyph = _glyph_features(ch)
    if glyph is None:
        return None
    z = _embed_images(module, [glyph[0]])[0]
    _glyph_emb_cache[ch] = z
    if len(_glyph_emb_cache) > 4000:
        _glyph_emb_cache.pop(next(iter(_glyph_emb_cache)))
    return z




def _learned_score(ink_prepared: np.ndarray, ch: str) -> float | None:
    """learned 比对分（0-1）：余弦 (cos+1)/2。模型缺席返回 None。"""
    module = _pair_model_module()
    if module is None:
        return None
    glyph_z = _glyph_embedding(ch, module)
    if glyph_z is None:
        return None
    ink_z = _embed_images(module, [ink_prepared])[0]
    cos = float(np.dot(ink_z, glyph_z))
    return (cos + 1.0) / 2.0


# --- 同伴校验（阶段 C） ----------------------------------------------------
# 同页同文字的墨迹两两比对（刻本同字同雕版，天然消除"楷体字模 vs 刻本
# 风格"的鸿沟）：与同伴不像 → 读错的强信号；与同伴一致但楷体标红 →
# 风格差异，降级处理。人工确认过的字作为组内基准（最强参照）。
PEER_MIN_GROUP = 3        # 组内至少几个同字实例才启用同伴互证


PEER_AGREE = 0.80         # 同字骨架 Chamfer 分 >= 此值算"像"（成簇判定）


PEER_STRONG = 0.88        # >= 此值算"高度一致"（mismatch 降 suspect）


PEER_VERY_STRONG = 0.93   # >= 此值判"同雕版级的雷同"（无锚时也允许降到


                          # ok——刻本同字同雕版，整组都与楷体对不上而彼
                          # 此雷同，就是纯风格鸿沟而非读错）
PEER_RESCUE_FLOOR = 0.50  # 极相似放行的分数下限：错字聚类的字形分通常


                          # 已是灾难级低分（0.2-0.5，结构根本对不上），
                          # 风格鸿沟的正确字分数落在阈值带附近——低于此
                          # 分数的"同伴雷同"不放行（同错互证风险）
# --- 跨页模板互证（模型化阶段 3） ------------------------------------------
# 模板救回门槛刻意比页内同伴（PEER_VERY_STRONG=0.93）更高：易混字对
# （險/臉类）的骨架 Chamfer 也能过 0.93——回测实测 0.93 时误报 -2.8pt
# 但命中 -3.0pt（B 组 159 个错读的 suspect 被跨字"雷同"误救），收紧到
# 近同刻级 0.96 后误报收益保留、误救大幅减少。
TEMPLATE_STRONG = 0.96    # 跨页模板"雷同"判定（Chamfer；嵌入路径用




def _original_char_crop(image_path: str,
                        rect: tuple[int, int, int, int]) -> np.ndarray | None:
    """原始扫描图按字框裁字（窗口与墨迹裁切一致，含 2px 余量），灰度
    原样保留——对照图第一格，显示"识别时看到的那个字"的原貌（含纸
    色深浅、墨色浓淡），与第二格二值化墨迹、第三格楷体印刷字并列。"""
    img = _imread(image_path)
    if img is None:
        return None
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    x, y, w, h = rect
    x1, y1 = max(0, x - 2), max(0, y - 2)
    x2, y2 = min(gray.shape[1], x + w + 2), min(gray.shape[0], y + h + 2)
    crop = gray[y1:y2, x1:x2]
    return crop if crop.size else None




def _crop_ink(mask: np.ndarray, rect: tuple[int, int, int, int]):
    """整页墨迹 mask 裁单字（+2px 余量）→ (crop|None, skip原因|None)。

    两步净化：
    1. 邻字渗墨剔除——裁切图里只保留与"字框内部"相交的连通域；密集
       列里邻字墨迹距字框 <2px 很常见，整块落在字框外的渗墨直接删掉；
    2. 紧致化——按墨迹包围盒紧裁后再 letterbox，与字形侧（_render_glyph
       紧裁）的中心化口径一致，消除检测框松紧带来的位置噪声。"""
    x, y, w, h = rect
    if w < 2 or h < 2:
        return None, "empty_ink"
    x1, y1 = max(0, x - 2), max(0, y - 2)
    x2, y2 = min(mask.shape[1], x + w + 2), min(mask.shape[0], y + h + 2)
    crop = mask[y1:y2, x1:x2].copy()
    if crop.size == 0 or cv2.countNonZero(crop) < NOISE_AREA_MIN:
        return None, "empty_ink"
    # 字框内部（裁切图坐标）＝ rect 与裁切窗的交
    ix1, iy1 = x - x1, y - y1
    ix2 = min(ix1 + w, crop.shape[1])
    iy2 = min(iy1 + h, crop.shape[0])
    if ix2 > ix1 and iy2 > iy1:
        n, labels, stats, _ = cv2.connectedComponentsWithStats(
            (crop > 0).astype(np.uint8), connectivity=8)
        keep = np.zeros(n, dtype=bool)
        keep[0] = True
        inner = np.zeros(crop.shape, dtype=bool)
        inner[iy1:iy2, ix1:ix2] = True
        for i in range(1, n):
            if ((labels == i) & inner).any():
                keep[i] = True
        crop[~keep[labels]] = 0
    if cv2.countNonZero(crop) < NOISE_AREA_MIN:
        return None, "empty_ink"
    ys, xs = np.nonzero(crop)
    crop = crop[ys.min(): ys.max() + 1, xs.min(): xs.max() + 1]
    return crop, None




def _skippable(text: str) -> str | None:
    """跳过原因：空/多字文本、标点符号（刻本句读点常被切半，拓扑无
    对照意义）、拉丁字母（字形库是中文楷体，与原书拉丁字形无可比
    性）、缺字体、墨迹为空都在此收口，统一返回 skipped。"""
    t = (text or "").strip()
    if not t:
        return "empty_text"
    if len(t) != 1:
        return "not_single_char"
    category = unicodedata.category(t[0])
    if category.startswith(("P", "S", "Z", "C")):
        return "punct_or_symbol"
    if category in ("Ll", "Lu", "Lt"):
        return "latin_letter"
    return None




def _level_thresholds(conf: float | None,
                      cls_rank: int | None = None) -> tuple[float, float]:
    """按识别置信度与 char_cls 候选排名平移判定阈值带。

    conf 高 → 要求更强的结构证据才标红（阈值带下移），conf 低 → 更容易
    标红（阈值带上移）。cls_rank 为当前文字在自训候选字分类器 top-K 里
    的 1 基排名（0=掉出 top-K，None=无信号/模型未启用）：进 top-3 →
    分类器支持该读法（下移），掉出 top-10 → 分类器也不认可（上移）。
    硬失败不受影响。"""
    shift = 0.0
    if conf is not None:
        if conf >= CONF_HIGH:
            shift = -CONF_SHIFT
        elif conf <= CONF_LOW:
            shift = CONF_SHIFT
    if cls_rank is not None:
        if 0 < cls_rank <= CLS_SUPPORT_RANK:
            shift -= CLS_SHIFT
        elif cls_rank == 0:
            shift += CLS_SHIFT
    return MISMATCH_SCORE + shift, SUSPECT_SCORE + shift




def _char_cls_enabled() -> bool:
    """自训候选字分类器是否已训练并激活（惰性探测，失败按未启用）。"""
    try:
        import segmenter
        with segmenter._YOLO_PREDICT_LOCK:
            return segmenter._get_custom_model("char_cls") is not None
    except Exception:
        return False




def _char_cls_ranks(image_path: str, blocks: list) -> dict[str, int]:
    """整页字块的 char_cls 候选排名：id → 1 基排名（0=掉出 top-K）。

    复用 /char_candidates 的推理路径（同一 padding 公式与 YOLO 预测
    锁）；模型未启用/任何失败返回空 dict（无信号，融合自动退化为纯
    墨迹比对）。当前文字不在分类器词表（确认数据少的生僻字）同样无
    信号——不能把"分类器没学过这个字"当成"分类器不认可"来惩罚。"""
    try:
        import segmenter
        img = segmenter._imread(image_path)
        if img is None:
            return {}
        with segmenter._YOLO_PREDICT_LOCK:
            model = segmenter._get_custom_model("char_cls")
        if model is None:
            return {}
        raw_names = model.names
        vocab = {
            segmenter._cls_name_to_char(n)
            for n in (raw_names.values() if isinstance(raw_names, dict)
                      else raw_names)
        }
        ranks: dict[str, int] = {}
        for b in blocks:
            text = (b.text or "").strip()
            if len(text) != 1 or text not in vocab:
                continue
            cands = segmenter.get_char_candidates(
                image_path, (b.x, b.y, b.w, b.h),
                top_k=CLS_TOP_K, image=img)
            if not cands:
                continue
            rank = 0
            for i, c in enumerate(cands, 1):
                if c.get("text") == text:
                    rank = i
                    break
            ranks[b.id] = rank
        return ranks
    except Exception:
        return {}




def _verify_prepared(ink_img: np.ndarray, glyph: tuple,
                     conf: float | None,
                     cls_rank: int | None = None,
                     ch: str | None = None
                     ) -> tuple[dict, np.ndarray]:
    """核心比对（verify_char 的内层，批量同伴校验复用）：三层手工分
    （拓扑/特征点/形状）+ 可选 learned 比对层，返回 (结果字典, 墨迹骨
    架)。调用方保证 ink_img/glyph 已过门禁。"""
    (glyph_prepared, glyph_skel, glyph_topo,
     (glyph_ends, glyph_juncs), glyph_width) = glyph
    ink_prepared = _prepare(ink_img, target_w=glyph_width)
    ink_skel = _skeleton(ink_prepared)
    ink_topo = _topology(ink_skel)
    ink_ends, ink_juncs = _minutiae(ink_skel)

    topo_score, topo_detail = _topo_score(ink_topo, glyph_topo)
    match, align = _match_score(ink_ends, ink_juncs, glyph_ends, glyph_juncs,
                                ink_skel=ink_skel, glyph_skel=glyph_skel)
    glyph_skel_aligned = _warp_skeleton(glyph_skel, align)
    shape = _shape_score(ink_skel, glyph_skel_aligned)
    learned = _learned_score(ink_prepared, ch) if ch else None

    if W_PAIR > 0 and learned is not None:
        if match is None:
            score = (W_TOPO * topo_score + W_SHAPE * shape
                     + W_PAIR * learned) / (W_TOPO + W_SHAPE + W_PAIR)
        else:
            score = (W_TOPO * topo_score + W_MATCH * match
                     + W_SHAPE * shape + W_PAIR * learned) \
                / (W_TOPO + W_MATCH + W_SHAPE + W_PAIR)
    elif match is None:
        score = (W_TOPO * topo_score + W_SHAPE * shape) / (W_TOPO + W_SHAPE)
    else:
        score = (W_TOPO * topo_score + W_MATCH * match
                 + W_SHAPE * shape) / (W_TOPO + W_MATCH + W_SHAPE)

    mismatch_t, suspect_t = _level_thresholds(conf, cls_rank)
    if learned is not None and learned >= LEARNED_HIGH:
        # 非对称救回：模型强烈认同时更难标红（只救不罚，见常量注释）
        mismatch_t -= LEARNED_SHIFT
        suspect_t -= LEARNED_SHIFT
    if topo_detail["hard_fail"] or score < mismatch_t:
        level = "mismatch"
    elif score < suspect_t:
        level = "suspect"
    else:
        level = "ok"

    result = {
        "level": level,
        "score": round(float(score), 4),
        "hard_fail": bool(topo_detail["hard_fail"]),
        "parts": {
            "topology": round(topo_score, 4),
            "match": None if match is None else round(match, 4),
            "shape": round(shape, 4),
            **({"pair": round(learned, 4)} if learned is not None else {}),
        },
        "topology": {"ink": ink_topo, "glyph": glyph_topo,
                     "diffs": topo_detail["diffs"]},
        "alignment": {"rot": round(align[0], 1), "scale": round(align[1], 3),
                      "dx": round(align[2], 1), "dy": round(align[3], 1)},
    }
    if cls_rank is not None:
        result["cls_rank"] = cls_rank
    return result, ink_skel




def _verify_one(mask: np.ndarray, rect: tuple[int, int, int, int],
                text: str, conf: float | None,
                cls_rank: int | None = None
                ) -> tuple[dict, np.ndarray | None, np.ndarray | None]:
    """单字校验核心（含门禁与跳过原因），返回 (结果, 墨迹裁切图, 墨迹
    骨架)——后两者供 debug 叠加与批量同伴互证复用，跳过时为 None。"""
    started = time.time()
    reason = _skippable(text)
    if reason:
        return ({"level": "skipped", "score": None, "reason": reason,
                 "elapsed_ms": 0.0}, None, None)
    ch = text.strip()[:1]
    glyph = _glyph_features(ch)
    if glyph is None:
        return ({"level": "skipped", "score": None,
                 "reason": "glyph_missing", "elapsed_ms": 0.0}, None, None)
    ink_img, reason = _crop_ink(mask, rect)
    if ink_img is None:
        return ({"level": "skipped", "score": None, "reason": reason,
                 "elapsed_ms": 0.0}, None, None)
    result, ink_skel = _verify_prepared(ink_img, glyph, conf, cls_rank, ch)
    result["text"] = ch
    result["elapsed_ms"] = round((time.time() - started) * 1000.0, 1)
    return result, ink_img, ink_skel




def verify_char(image_path: str, rect: tuple[int, int, int, int],
                text: str, mask: np.ndarray | None = None,
                conf: float | None = None, cls_rank: int | None = None,
                debug: bool = False) -> dict:
    """校验单字：墨迹骨架 vs 识别字楷体字形骨架的三层比对。

    返回 level ∈ {ok, suspect, mismatch, skipped}、综合 score 与各层
    分项；conf 为识别置信度、cls_rank 为当前文字在自训候选字分类器
    top-K 的 1 基排名（均可选，用于平移判定阈值带）；debug=True 额外
    返回叠加图 base64。mask 可传入整页墨迹（批量场景复用），None 时
    自行构建。"""
    if mask is None:
        mask = _text_mask_for_refinement(image_path)
        if mask is None:
            return {"level": "skipped", "score": None, "reason": "no_mask",
                    "elapsed_ms": 0.0}
    result, ink_img, ink_skel = _verify_one(mask, rect, text, conf, cls_rank)
    if not debug or ink_img is None or ink_skel is None:
        return result
    glyph = _glyph_features(text.strip()[:1])
    (glyph_prepared, glyph_skel, _topo,
     (glyph_ends, glyph_juncs), glyph_width) = glyph
    ink_prepared = _prepare(ink_img, target_w=glyph_width)
    ink_ends, ink_juncs = _minutiae(ink_skel)
    align = result["alignment"]
    align_t = (align["rot"], align["scale"], align["dx"], align["dy"])

    def aligned_list(pts):
        if not pts:
            return pts
        arr = _apply_similarity(np.asarray(pts, dtype=np.float64),
                                align_t[0], align_t[1],
                                (align_t[2], align_t[3]))
        return [(float(p[0]), float(p[1])) for p in arr]
    result["debug_image_b64"] = _debug_overlay(
        ink_prepared, ink_skel, glyph_prepared, glyph_skel,
        ink_ends, ink_juncs, glyph_ends, glyph_juncs,
        orig_gray=_original_char_crop(image_path, rect),
        glyph_mask_aligned=_warp_skeleton(glyph_prepared, align_t),
        glyph_skel_aligned=_warp_skeleton(glyph_skel, align_t),
        glyph_ends_aligned=aligned_list(glyph_ends),
        glyph_juncs_aligned=aligned_list(glyph_juncs))
    return result




def _peer_verify(results: dict, skeletons: dict, statuses: dict) -> None:
    """同字同伴互证（就地调整 results 的 level，附 peer 明细）。

    规则（红线：拓扑硬失败永不调整——防"同字整组读错互相背书"漏检）：
    - 确认锚：组内有 status=confirmed 的字时以它为基准——与锚不像
      → 升 mismatch；与锚高度一致但楷体标红/存疑 → 风格差异降级；
    - 无锚多数簇：与所有同伴都不像、而其余同伴仍成簇 → 本字是少数派
      → ok 升 suspect；与同伴雷同（>=PEER_VERY_STRONG，同雕版级）→
      非硬失败一律放行 ok；较像（>=PEER_STRONG）→ mismatch 降 suspect。"""
    groups: dict[str, list[str]] = {}
    for bid, r in results.items():
        if (r.get("level") in ("ok", "suspect", "mismatch")
                and bid in skeletons and r.get("text")):
            groups.setdefault(r["text"], []).append(bid)
    for ids in groups.values():
        n = len(ids)
        if n < PEER_MIN_GROUP:
            continue
        sims = {}
        for i in range(n):
            for j in range(i + 1, n):
                sims[(i, j)] = _shape_score(skeletons[ids[i]],
                                            skeletons[ids[j]])
        anchors = [k for k, bid in enumerate(ids)
                   if statuses.get(bid) == "confirmed"]
        for i, bid in enumerate(ids):
            r = results[bid]
            peer_best = max(sims[_pair(i, j)] for j in range(n) if j != i)
            note = {"group": n, "best": round(peer_best, 3), "adjusted": None}
            if not r.get("hard_fail"):
                anchor_best = max(
                    (sims[_pair(i, a)] for a in anchors if a != i),
                    default=None)
                if anchor_best is not None:
                    if anchor_best < PEER_AGREE and r["level"] != "mismatch":
                        r["level"] = "mismatch"
                        note["adjusted"] = "boosted_by_confirmed"
                    elif anchor_best >= PEER_STRONG and r["level"] != "ok":
                        r["level"] = "ok" if r["level"] == "suspect" \
                            else "suspect"
                        note["adjusted"] = "downgraded_style"
                else:
                    agree = sum(1 for j in range(n)
                                if j != i and sims[_pair(i, j)] >= PEER_AGREE)
                    if agree == 0:
                        rest = [j for j in range(n) if j != i]
                        rest_cluster = any(
                            sims[_pair(a, b)] >= PEER_AGREE
                            for a in rest for b in rest if a != b)
                        if rest_cluster and r["level"] == "ok":
                            r["level"] = "suspect"
                            note["adjusted"] = "boosted_minority"
                    elif (peer_best >= PEER_VERY_STRONG
                          and (r.get("score") or 0.0) >= PEER_RESCUE_FLOOR):
                        # 同雕版级雷同 + 字形分没到灾难级：整组与楷体对
                        # 不上而彼此雷同，是风格鸿沟而非读错——放行
                        if r["level"] != "ok":
                            r["level"] = "ok"
                            note["adjusted"] = "downgraded_style"
                    elif peer_best >= PEER_STRONG and r["level"] == "mismatch":
                        r["level"] = "suspect"
                        note["adjusted"] = "downgraded_style"
            r["peer"] = note




def _pair(i: int, j: int) -> tuple[int, int]:
    return (i, j) if i < j else (j, i)




def _template_verify(results: dict, canvases: dict, skeletons: dict,
                     project_dir: str | None) -> None:
    """跨页模板互证（就地调整 level，附 template 明细）。

    与 _peer_verify 同一套红线（硬失败永不调整）与语义：与本书已确认
    同字模板不像 → 升 mismatch；雷同（且有嵌入度量或非灾难字形分）→
    纯风格鸿沟放行。度量阈值随度量走：嵌入余弦用 EMB_*，Chamfer 用
    PEER_*（刻度不同，见 verify_templates）。"""
    if not project_dir:
        return
    import verify_templates as vt
    lib = vt.load(project_dir)
    if not lib:
        return
    use_emb = any("emb" in e for e in lib.values()) \
        and _pair_model_module() is not None
    agree = vt.EMB_AGREE if use_emb else PEER_AGREE
    strong = vt.EMB_STRONG if use_emb else TEMPLATE_STRONG
    for bid, r in results.items():
        ch = r.get("text")
        if (not ch or r.get("level") == "skipped"
                or bid not in canvases or bid not in skeletons):
            continue
        sim = vt.best_similarity(ch, canvases[bid], skeletons[bid], lib)
        if sim is None:
            continue
        best, count = sim
        note = {"count": count, "best": round(best, 3), "adjusted": None}
        if not r.get("hard_fail"):
            floor_ok = use_emb or (r.get("score") or 0.0) >= PEER_RESCUE_FLOOR
            if best < agree and r["level"] != "mismatch":
                r["level"] = "mismatch"
                note["adjusted"] = "boosted_by_template"
            elif (best >= strong and floor_ok and r["level"] != "ok"):
                r["level"] = "ok"
                note["adjusted"] = "downgraded_style"
        r["template"] = note




def verify_chars_batch(image_path: str, blocks: list,
                       project_dir: str | None = None) -> dict:
    """批量校验 + 同字同伴互证 + 跨页模板互证：blocks 为带 id/x/y/w/h/
    text 的对象（可选 conf/status），project_dir 供模板库定位本书（缺省
    时模板互证自动缺席）。整页 mask 只构建一次；单字异常不中断整批，
    记入 errors。同伴互证详见 _peer_verify，模板互证见 _template_verify。

    char_cls 融合（模型已训练并激活且 CLS_SHIFT>0 时）：先对整页字块批量
    取自训候选字分类器的 top-K 排名（复用 /char_candidates 推理路径，GPU
    + YOLO 预测锁——本端点因此不再严格纯 CPU；单字 /verify_char 仍纯
    CPU），当前文字进 top-3 / 掉出 top-10 平移判定阈值带。CLS_SHIFT=0
    （默认，分类器数据不足期）则完全不触发分类器推理，端点保持纯 CPU。"""
    started = time.time()
    mask = _text_mask_for_refinement(image_path)
    if mask is None:
        raise ValueError(f"cannot read image or build text mask: {image_path}")
    cls_ranks: dict[str, int] = {}
    if CLS_SHIFT > 0 and _char_cls_enabled():
        cls_ranks = _char_cls_ranks(image_path, blocks)
    results: dict[str, dict] = {}
    errors: dict[str, str] = {}
    skeletons: dict[str, np.ndarray] = {}
    canvases: dict[str, np.ndarray] = {}
    statuses: dict[str, str | None] = {}
    for block in blocks:
        try:
            result, ink_img, skel = _verify_one(
                mask, (block.x, block.y, block.w, block.h),
                block.text, getattr(block, "conf", None),
                cls_ranks.get(block.id))
            results[block.id] = result
            if skel is not None:
                skeletons[block.id] = skel
                ch = result.get("text")
                if ink_img is not None and ch:
                    glyph = _glyph_features(ch)
                    if glyph is not None:
                        canvases[block.id] = _prepare(
                            ink_img, target_w=glyph[4])
            statuses[block.id] = getattr(block, "status", None)
        except Exception as exc:
            errors[block.id] = f"{type(exc).__name__}: {exc}"
    _peer_verify(results, skeletons, statuses)
    _template_verify(results, canvases, skeletons, project_dir)
    return {
        "results": results,
        "errors": errors,
        "elapsed_ms": round((time.time() - started) * 1000.0, 1),
    }


from char_skeleton import (  # noqa: E402,F401
    CANVAS,
    BIN_THRESHOLD,
    CLOSE_KERNEL,
    NOISE_AREA_MIN,
    HOLE_FILL_MIN,
    HOLE_FILL_RATIO,
    PRUNE_SPUR_LEN,
    JUNCTION_RADIUS,
    TOPO_TOL,
    REL_TOL,
    HARD_FAIL_DIFF,
    HARD_FAIL_RATIO,
    TOPO_WEIGHT,
    MATCH_RADIUS,
    MATCH_FULL,
    CHAMFER_NORM,
    W_TOPO,
    W_MATCH,
    W_SHAPE,
    STROKE_W_MIN,
    STROKE_W_TOL,
    SHRINK_MAX,
    SHRINK_LOSS_GUARD,
    SAMPLE_TARGET,
    SAMPLE_RADIUS,
    SAMPLE_FULL,
    _normalize,
    _clean,
    _fill_small_holes,
    _thin,
    _thin_step,
    _crossing_number,
    _prune_spurs,
    _junction_clusters,
    _topology,
    _minutiae,
    _stroke_width,
    _shrink_to_width,
    _prepare,
    _skeleton,
    _letterbox_square,
)

from char_glyph import (  # noqa: E402,F401
    ALIGN_PAIR_RADIUS,
    ALIGN_VOTE_BIN,
    ALIGN_ROTATIONS,
    ALIGN_SCALES,
    ALIGN_IDENTITY_BONUS,
    ALIGN_GRID_TRIGGER,
    _FONT_CANDIDATES,
    _font,
    _font_failed,
    _glyph_cache,
    _load_font,
    _simplify_char,
    _render_glyph,
    _glyph_features,
    _topo_score,
    _apply_similarity,
    _debug_overlay,
    _vote_offset,
    _align_glyph_points,
    _warp_skeleton,
    _sample_skeleton,
    _match_score,
    _shape_score,
)
