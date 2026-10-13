# python_service 大扫除·清理方案（待确认）

> 生成日期：2026-09-30。本文档只列清单与方案，**不含任何已执行的改动**。
> 确认后交本地 agent 按「E. 执行指引」分批执行；带 ☐ 的是需要你勾选的决策点（见文末汇总）。
> 所有 `文件:行号` 均已在 2026-09-30 逐一 grep 复核过；执行时行号可能有小幅漂移，以符号名为准。

---

## 0. 范围与原则

- **范围**：`ocr/python_service`（含 16 个 `test_*.py`）。flutter_app、installer、识字数据目录不在本轮扫描范围（规则审计 D 章为验证规则落点做了少量 flutter 侧 grep，不构成对 flutter 代码的改动建议）。
- **只做清理，不加功能**：删除死代码、合并重复逻辑、迁移杂物。任何"顺手改进"都不做。
- **超过 800 行的文件只出拆分方案（C 章），本轮不动代码**。拆分是本地 agent 第三阶段任务。
- **规则审计（D 章）**：以 `ocr/README.md`「标注与训练规则」8 条 + `ab_verify/README.md` 6 条为准，逐条对照代码：代码里不存在的删，留下的补一句"为什么要它"。
- **版本管理**：本项目用 SVN。删除类操作均可从 SVN 历史找回。

### 保留勿删清单（看似可疑、实际存活）

| 项 | 存活证据 |
|---|---|
| `train_worker.py` | `training_service.py:34`（WORKER_PATH）+ :1035-1051、`verify_training.py:324-332` 以子进程按名启动 |
| `kraken_worker.py` | `kraken_bridge.py:27`（WORKER 常量）+ :543 以子进程按名启动；`test_segmenter.py:43` 直接 import |
| `main.py` | flutter 唯一按名调用的脚本：`flutter_app/lib/services/python_service.dart:389,429,434`（`conda run -n paddle python main.py`） |
| `service_port.txt` | `main.py:2950` 写、`python_service.dart:13,468,520` 读、`ab_verify/run_ab.py:23,97` 保护恢复 |
| `app_ui_settings.json` | `python_service.dart:2808,2840` 读写 |
| `open_console_viewer.cmd` | `python_service.dart:2897` 按名调用 |
| `verify_templates/`（空目录） | **不是残留**：`verify_templates.py:24-25` 定义为按书模板库 npz 的存储位置（`verify_templates/<project_id>.npz`），空只是还没写过 |
| `resources/fonts/LXGWWenKai-Regular.ttf` | `char_verify.py` `_FONT_CANDIDATES` 的唯一候选（楷体字形来源，字形校验依赖） |
| `test_fixtures/`（2 张真实书页 PNG） | `test_segmenter.py:2195-2211` 引用（双栏/夹具测试） |
| `install.bat` / `install_kraken.bat` / `run_backend_console.cmd` | `README.md:17`、`python_service.dart:404,510`、`kraken_bridge.py:3,83`、`setup_service.dart:482`、`install.bat:140`（flutter 启动链与环境安装都在用） |
| `datasets/`、`kraken_models/`、`kraken_training/` | 数据/预训练模型目录（56M / 46M / 1.2M），非代码 |
| 根目录 `yolov8s.pt` | 检测训练默认底模：`main.py:411`、`training_service.py:1000`、`train_worker.py:28`、`python_service.dart:2642` |
| 根目录 `yolov8n-cls.pt` | 分类底模，`model_registry.py:14` 的回退路径（`models/` 下无此文件时落到根目录这份） |
| `debug_visualize.py` | 手工调试 CLI（今天仍在用），仅自引用属正常，保留 |
| `ab_verify/` 全套 | A/B 验证工具，README 有记载（D2 节） |
| `logs/`、`.venv/`、`.pytest_cache/`、`__pycache__/`、`test_fixtures/`、`models/`、`datasets/`、`kraken_models/`、`kraken_training/`、`resources/` | 运行时目录/数据 |

---

## A. 死代码清单

> 含 2026-09-30 第二轮补充扫描：对全部业务 .py（含 ab_verify）的顶层函数/类做了系统化零引用普查，零引用符号除下表外再无新增（main.py 路由处理器经装饰器调用，不算死码）。

### A1 死文件（整文件无引用）

| 文件 | 行数 | 证据 | 建议动作 |
|---|---|---|---|
| `.tmp_stats.py` | 6 | 全仓库 0 引用；内容是一次性调试脚本，硬编码本机路径 `E:\Work\Flutter\ocr\page84_v89_http.json`（该文件本身已不存在） | **删除** |
| `paddle_engine.py` | 153 | 全仓库 0 import、0 子进程调用；docstring 自述「**2026-09 已从识别链路移除**……模块保留备用」，恢复点注释在 `kraken_bridge.py:969` | ☐ **D1**：删除（SVN 历史可找回，推荐）／归档到 `tools/archive/` |

### A2 死路由（含级联）

| 位置 | 证据 | 建议动作 |
|---|---|---|
| `main.py:575-583` `@app.get("/capabilities")` | flutter_app 全目录 + installer 无任何 `/capabilities` 调用（flutter 侧经 `python_service.dart` 统一拼 URL，已全文检索） | 删除路由后**级联清理**：① `main.py:27` import 行中的 `get_capabilities`；② `segmenter.py:318-341` `get_capabilities()`（路由删后全仓库 0 引用，测试无引用）。若想留诊断能力可只删路由不删函数——默认全删 |

### A3 零引用函数（全仓库 grep 出现次数 = 1，即仅 def 行）

| 函数 | 位置 | 建议动作 |
|---|---|---|
| `set_model_overrides` | `segmenter.py:188` | 删除 |
| `_rescale_rect` | `segmenter.py:487` | 删除 |
| `_unscale_rect` | `segmenter.py:500` | 删除 |
| `_upscale_mask` | `segmenter.py:514` | 删除 |
| `_estimate_vertical_grid_count_from_mask` | `segmenter.py:712` | 删除 |
| `_refine_rect_with_ink` | `segmenter.py:767` | 删除 |
| `segment_image` | `segmenter.py:3442` | 删除（一行包装：仅 :3443 自引用；对外入口是 `segment_image_with_metadata`） |
| `_rect_overlap_area` | `main.py:1830` | 删除 |
| `_tilt_delta` | `page_dewarp.py:203` | 删除（与 `_quad_tilt`(:188) 相邻的遗留小函数，全仓库无调用） |
| `_escape` | `verify_training.py:155` | 删除（第二轮普查新发现：一行包装 `return ts._safe_class_name(ch)`，全仓库 0 引用） |
| `cosine_sim` | `verify_model.py:45` | 删除（推理侧用 `module.cosine_sim` 的话需保留——执行时先在 `char_verify.py`/`train_worker.py` grep `cosine_sim` 复核一次再删） |

执行时统一规则：删前对该符号名再做一次全仓库 grep（含 flutter_app），计数 =1 才删。

### A4 一次性脚本（有 `__main__`、无 import，但"任务已完结"）

| 文件 | 证据 | 建议动作 |
|---|---|---|
| `tool_train_verify.py`（49 行） | docstring 自述「一次性驱动脚本：为第五册导出……」，硬编码本机路径 `C:\Users\LLLL\...` | ☐ **D2**：删除／归档 `tools/archive/` |
| `tool_train_char_cls.py`（48 行） | 同上（第五册 char_cls 一次性） | ☐ **D2**：同上 |
| `tool_verify_backtest.py`（315 行） | 墨迹校验回测 CLI，可对任何书重跑，非一次性 | 保留 |
| `debug_visualize.py`（约 120 行） | 手工调试可视化，9-30 仍在修改 | 保留 |
| `ab_verify/run_ab.py`、`compare_ab.py`、`ab_segment_run.py` | A/B 验证工具；README 未记载 `ab_segment_run.py`（见 D2 节） | 保留，README 补记 |

### A5 根目录杂物（python_service 根）

| 项 | 大小 | 证据 | 建议动作 |
|---|---|---|---|
| `_smoke_region.png`、`_syn_indent.png` | 约 85 KB | 全仓库 0 引用 | 删除 |
| `ring_top/bottom/left/right.png` | 约 3.2 MB | 全仓库 0 引用（9-27 生成的调试图） | 删除 |
| `logsspawn_test.txt` | 10 B | 0 引用，遗留测试残留 | 删除 |
| `service_console.log` | 6 KB | 运行产物 | 删除，并确认 svn:ignore 覆盖 `*.log` |
| `yolo26n.pt` | 5.5 MB | 全仓库 0 引用（代码/registry.json/训练档位表均无） | ☐ **D5**：删除（推荐） |
| `yolov8n.pt` | 6.5 MB | 代码 0 直接引用；但 `TRAINING_REQUIREMENTS`（`training_service.py:50`）含 yolov8n 档，启动 n 档检测训练时 ultralytics 会找它、缺失则自动下载 | ☐ **D4**：删除（可自动重下）／保留 |
| `verify_templates/`（空目录） | — | 误报修正：是模板库存储目录（见保留清单） | **保留** |
| `models/YOLO OCR.pt` | 约 6 MB | 全仓库（py/dart/registry.json）0 引用；文件名带空格、不在 `model_registry.py` 规范路径内，疑为早期手工训练物 | ☐ **D7**：删除／保留 |
| `models/trained/` 孤儿 run 目录 | **约 342 MB** | registry.json 只登记 5 个 run（char_cls×2、char_det×1、verify_pair×2）；未登记的有：char_det 的 `run_1789669911`、`run_1789672301`（各 **171 MB**，完整训练产物）+ 7 个 1~20 KB 失败残 run + char_cls 3 个 24 KB 残 run | ☐ **D8**：删孤儿 run（释放约 342 MB，保留 registry 登记的 5 个）／保留 |
| `logs/` 运行日志 | **312 MB** | `service_console.log` 178 MB、`app_console.log` 117 MB、`faulthandler.log` 17 MB（运行时追加） | ☐ **D9**：清掉旧日志（保留最近几天）+ svn:ignore `logs/`／仅登记不动 |
| `__pycache__/`、`.pytest_cache/` | 3 MB / 33 KB | 运行缓存 | 建议加入 svn:ignore（若已被版本管理） |

---

## B. 重复逻辑清单

> 合并原则：只收敛实现，不改行为、不改盘上格式。每组独立成一次提交。

### B1 中文路径 `_imread` 复制粘贴（逐字级）

- `segmenter.py:67-70`（权威版）vs `training_service.py:243-248`（同一 docstring 的副本，多一层 try/except）。
- `char_verify.py`、`excalidraw_export.py` 已从 segmenter 导入，唯独 training_service 私藏副本。
- **建议**：`training_service` 改为 `from segmenter import _imread`（或顺势把 `_imread` 提为公共小模块 `imaging.py`，与 B2 一起做）。风险：低。

### B2 `imencode + tofile` 写盘样板散布（复制粘贴级）

- `main.py:689-694` 已有统一助手 `_imwrite_unicode`，但同文件内 **10 处**仍内联同款样板：`main.py:237,263,923,985,1114,1130,1227,1387,1678,1784`（其中 :2262 是 jpg 带质量参数，可给助手加参数或保留内联）。
- 其他文件另有 7 处：`kraken_training.py:196`、`char_verify.py:963`、`training_service.py:622`、`verify_training.py:221`、`excalidraw_export.py:592,1807`。
- **建议**：把助手放公共模块并替换上述调用点（jpg 处给助手加 ext/params 参数）。风险：低（逐点替换，跑全量测试）。

### B3 registry.json 读写三处且已漂移（**优先级最高**）

- `training_service.py:1237-1252`（有 makedirs + exists 兜底，直接覆写）
- `verify_training.py:398-412`（**没有** makedirs/exists 兜底——registry.json 被清空/缺失时直接炸；也缺 `setdefault("layers")`）
- `char_verify.py:188-192`（第三处内联只读）
- 全仓库只有 `verify_templates.py:62-76` `_save_atomic` 做了原子写（mkstemp + os.replace）。
- **建议**：registry 读/写/激活收敛到一个模块（可与 C 章 `training_service.py` 拆出的 `train_registry.py` 合并做），写入统一走原子写。风险：**中**——这是训练启用链路的核心状态文件，必须保留现有 JSON 结构不动、只收敛代码路径；改完手动验证 activate → 重启服务 → 仍为 active。

### B4 训练任务 poll 监控循环三处同构（相似非复制）

- `training_service.py:976-995`、`verify_training.py:369-384`、`kraken_training.py:376-382`（poll 2s → 读 done.json/returncode → 登记注册表）。
- **建议**：可抽公共 `_monitor` 帮手；但三处登记动作各不相同，收敛收益有限。风险：中。**可选项，默认不动**，除非 C 章拆分时顺手。

### B5 rect/overlap 数学三套

- `layout_refinement.py:8-19`（rect_of/overlap，在用）vs `segmenter.py:3268-3280`（_rect_of/_set_rect，在用）vs `main.py:1830`（_rect_overlap_area，死码，见 A3）。
- **建议**：删掉 A3 死码即可；两套在用的语义不同（dict rect vs tuple rect），不强合并。风险：低。

### B6 nvidia-smi 探测两套（相似非复制）

- `main.py:443-511` `_nvidia_vram_bytes`（按 pid 汇总显存）vs `daemon_sizing.py:53-100`（CUDA 总量决策）。用途不同，只是同族 subprocess+CSV 解析。
- **建议**：不动（合并收益低）；登记在此仅为避免未来第三套出现。风险：—

### B7 stable_uid 跨语言双实现、格式不同（**同步陷阱，登记不改**）

- Python：`metadata.py:44-62` —— `json.dumps({image,kind,rect,order,parent})` → sha256 前 24 位 → **带 `kind_` 前缀**（如 `char_ab12…`）。
- Dart：`crowd_dataset_exporter.dart:549-560` —— `'sha|kind|x,y,w,h|order'` 字符串 → sha256 前 24 位 → **不带前缀**。
- 两条数据流各自内部自洽（Dart 的 char_uid 只在众包导出/共识写回闭环内匹配；Python 的 uid 只在识别结果/标注身份里使用），但任何"跨端按 uid 比对"的新需求都会踩这个格式差异。`training_service.py:646` 已把 char_uid 当兜底读。
- **建议**：☐ **D3**：本轮只做两件事——在两处实现各加一行注释指认对方的存在与格式差异，并在 `ocr/README.md` 第 156 行附近补一句"char_uid 以识字数据包内格式为准"。**不建议本轮统一格式**（会作废已导出的众包数据包与历史共识快照）。

### B8 FastAPI 入参存在性校验样板 ×20

- `main.py` 内 20 处 `if not os.path.exists(req.image_path): raise HTTPException(400, "image not found")`（:595,679,733,784,853,907,958,1018,1091,1204,1433,1456,1504,1545,1846,2000,2017,2155,2202 等）。
- **建议**：改为 FastAPI 依赖项（`Depends(require_image)`)或 Pydantic validator 收敛。风险：低——错误码与错误文案保持逐字不变（flutter 侧可能按文案分支）。**与 C 章 main.py 拆分一起做最顺**。

### B9 灰度/二值化小函数分散（低优先）

- `COLOR_BGR2GRAY` 10 处、`THRESH_OTSU/adaptiveThreshold` 6 处，散布 5 个文件。
- **建议**：不动（局部两三行，抽象反而降低可读性）。登记仅为知悉。

---

## C. 超 800 行文件拆分方案（只出方案，本轮不动代码）

> 通用策略：**门面模式**——原文件名保留，内部逻辑拆到新模块后由原文件 `import *` / 显式 re-export。这样 `main.py` 的 import、flutter 的子进程启动命令、`verify_training.py:38` 这类跨模块 import 全部零改动。每文件一次提交，拆完全量回归。
> 拆分顺序建议：先小后大，验证流程跑顺再加码：page_dewarp → training_service → excalidraw_export → kraken_bridge → main.py → segmenter.py → test_segmenter.py。

### C1 `page_dewarp.py`（908 行，最小拆）

| 新文件 | 迁入内容（现行号段） | 说明 |
|---|---|---|
| `page_dewarp.py`（保留） | 角点检测与矫正：:61-588（detect_page_quad/_quad_from_* / _order_corners / quad_needs_warp）+ :590-755（_bezier/dewarp_page）+ 死码 _tilt_delta 已由 A3 删除 | 对外入口不变 |
| `page_enhance.py` | :757-908（remove_show_through / enhance_page / dark_region_stats / pixmap_rgb_array） | 成像增强与几何矫正本就是两个职责；main.py 相应路由 import 改指向（仅 python 内部） |

### C2 `training_service.py`（1405 行）

| 新文件 | 迁入内容 | 说明 |
|---|---|---|
| `train_data.py` | :193-408（_is_confirmed/_box_confirmed/_page_confirmed/_page_split/_imread/_image_size/段落推断/书籍与标注载入） | 「训练数据只认已确认」的判定层 |
| `train_datasets.py` | :409-914（detect/char_cls 数据集写盘、generate_datasets、dataset_stats、缓存 meta） | 数据集生成层 |
| `train_tasks.py` | :916-1235（_Task/_monitor/start/stop/status/training_log） | 任务生命周期层 |
| `train_registry.py` | :1237-1405（_load_registry/_save_registry/_register_run/list_models/activate/deactivate/active_model_path） | 注册表层；**B3 的收敛落点**：verify_training 改为从这里 import |
| `training_service.py`（门面） | re-export 上述符号 | `verify_training.py:38` 与 main.py 懒加载的 import 面不变 |

### C3 `excalidraw_export.py`（1903 行）

| 新文件 | 迁入内容 | 说明 |
|---|---|---|
| `excalidraw_scene.py` | :98-628（settings 归一化/场景构建/元素与文字工厂）+ :1806-1903（png data url / pipeline images） | 场景组装 |
| `excalidraw_graphics.py` | :629-1805（_region_ink_mask 起：hough、格网 lattice、骨架 path、箭头匹配等图形检测算法） | 纯算法、约 1200 行，是本文件膨胀主因 |
| `excalidraw_export.py`（门面） | 对外入口（main.py:862 懒加载的唯一 import 点） | |

### C4 `kraken_bridge.py`（2262 行）

| 新文件 | 迁入内容 | 说明 |
|---|---|---|
| `kraken_proc.py` | :52-105（python 探测/ensure_models）+ :499-948（_KrakenDaemon/_DaemonPool/_spawn/_prewarm/_ensure_pool/pool_size/shutdown） | daemon 进程与池管理 |
| `kraken_boxes.py` | :112-180、:1091-1330、:1803-2055（box 收紧/噪声过滤/pairing/pad/钳回） | 框几何与配对 |
| `kraken_bridge.py`（门面+编排） | recognize_lines/recognize_char/apply_kraken_recognition/_fuse_line_chars 等编排（:950-1090、:1334-1802、:2056+） | main.py 与 kraken_training 的 import 面不变 |

### C5 `main.py`（2957 行，57 条路由按域拆 router）

| 新文件 | 迁入内容 | 说明 |
|---|---|---|
| `api_base.py` | :43-211（console log/lifespan/识别并发闸门）+ /health、/process_stats | app 工厂与横切件 |
| `api_page.py` | /transform_page /split_page /detect_page_quad /deskew_sizing /dewarp_page /pdf_to_images | 页面几何域 |
| `api_segment.py` | /segment /crop /segment_region /segment_lines_in_region /debug_char_split | 切分域 |
| `api_recognize.py` | /char_candidates(_batch) /recognize_char /char_clusters(_batch) /char_thumbnails /line_thumbnails /analyze_layout /line_ink /recognition_eval(+set) | 识别与批处理域 |
| `api_verify.py` | /verify_char /verify_chars_batch /verify/train/* /verify/templates/* | 校验域 |
| `api_train.py` | /train/* /models/* /char_cls/evaluate | 训练域 |
| `api_kraken.py` | /kraken/* | Kraken 域 |
| `api_export.py` | /export_excalidraw /export_crnn /pack_lmdb | 导出域 |
| `main.py`（保留） | app 组装 + include_router + uvicorn 启动（:2920 起） | **uvicorn 入口仍是 `main:app`**，flutter 启动命令零变化；请求模型 BaseModel 随各自 router 走；B8 的入参依赖项随本次一起收敛 |

### C6 `segmenter.py`（4491 行，按管线阶段拆）

| 新文件 | 迁入内容（现行号段） | 说明 |
|---|---|---|
| `seg_trace.py` | :32-66（debug trace 设施） | 最底层 |
| `seg_imaging.py` | :67-72（_imread）+ :343-646（runs/merge/界栏剔除/tight_rect/_to_block/mask 极性/钳回） | 通用图像原语（B1/B2 的公共助手落点） |
| `seg_models.py` | :73-341（opencc/torch 预载、YOLO 装载与 override、_predict_detection_layer；get_capabilities 已由 A2 处置） | 模型装载层 |
| `seg_refine.py` | :647-1479（refinement mask、格数估计、标点扩张与拆分系列） | 墨迹精修 |
| `seg_chars.py` | :1480-1985（等分/版面格/kraken splitter/纵投影切字） | 单字切分 |
| `seg_lines.py` | :1987-2679（行装配、纵条带、重叠消解、噪声过滤、YOLO 字归行） | 行装配 |
| `seg_pipeline.py` | :2680-3137（_segment_with_yolo_chars/_segment_with_opencv/_apply_sort_and_renumber）+ :3138-3232（segment_image_with_metadata） | 主管线 |
| `seg_layout.py` | :3233-3600（版面过滤/层级包含/区域操作）+ :3601-4397（双栏体系）+ :4349-4397（segment_lines_in_region） | 版面与双栏 |
| `seg_candidates.py` | :4398-4491（候选字） | |
| `segmenter.py`（门面） | re-export 全部对外符号 | `main.py:24-38` 的批量 import、`metadata.py`、`test_segmenter.py` 的 import 面零改动 |
| 依赖方向 | seg_trace/seg_imaging ← seg_models ← {seg_refine, seg_chars, seg_lines} ← seg_pipeline ← seg_layout/seg_candidates ← segmenter 门面；**禁止反向** | |

### C7 `test_segmenter.py`（2393 行，按被测域对齐拆）

| 新文件 | 迁入测试类 |
|---|---|
| `test_seg_core.py` | SegmenterGeometryTests、KrakenCharSplitterTests |
| `test_seg_punct.py` | PunctSplitTests、PunctTailColumnRescueTests、SplitSingleGlyphComponentGapTests |
| `test_seg_lines.py` | LineRectExpandTests、LineGeometryBoundaryTests、TightenBoxesTests、ExtendLinesToRegionInkTests、EdgeFillerAndClampTests |
| `test_seg_layout.py` | HorizontalLayoutTests、TransformPageMappingTests、DoubleColumnSplitTests、HierarchyContainmentTests |
| `seg_test_helpers.py` | 公共 fixture/造图函数（如各测试共用的合成图生成） |

---

## D. 规则审计

### D1 `ocr/README.md`「标注与训练规则」（README.md:150-159，8 条）

> 审计结论：**8 条全部在代码中成立，没有"代码里不存在的旧规矩"可整条删除**。1 条需改写措辞（第 4 条），其余保留并补"为什么"。

| # | 规则（摘要） | 代码落点（证据） | 结论 | 为什么要它（保留理由） |
|---|---|---|---|---|
| 1 | 保存双轨制：临时保存≠确认 | flutter 编辑器/存储层（`flutter_app/lib/.../editor_page.dart`、`storage.dart`；落点在 flutter 侧，本轮 python_service 范围未逐行验证） | **保留** | 「落盘」与「固化为训练数据」分离，是所有训练出口可信度的总闸；删了它，未校对的 OCR 初稿会直接污染模型 |
| 2 | 所有训练数据出口只认已确认 | `training_service.py:193-226`（_is_confirmed/_box_confirmed/_page_confirmed）；`/export_crnn` 逐行过滤（`main.py:2195` 起）；识字数据包/ YOLO 导出在 flutter 侧同口径 | **保留** | 与第 1 条构成闭环；python 侧 `_page_confirmed` 还兼容无 status 的旧页（:220-223），防止老项目数据一夜之间全部不可训练 |
| 3 | 「本书重置为未确认」功能 | flutter 编辑器「更多操作」菜单（范围外，未逐行验证） | **保留** | 历史上"翻页自动确认"产生过误标数据，这是唯一的整书级纠错入口；删规则=删除该功能的存在依据 |
| 4 | 状态四态枚举；旧版 `confirmed`/`reviewed` 自动兼容 | 四态：`metadata.py:16`（ANNOTATION_STATUSES）、:19-33（normalize_status，`reviewed/accepted/approved`→confirmed）；flutter 侧 `reviewed` 仍是**页级活跃布尔**（`models.dart:676,712,1170`、`storage.dart:310`） | **改写**（不是删除） | 现措辞"旧版字段自动兼容"会误导——`reviewed` 在 flutter 是现役页级标志、在 python 是兼容映射输入，两边语义都真实存在。改写为：『python 侧统一四态契约（metadata.normalize_status 兼容历史词 reviewed/accepted/approved）；flutter 页级另有 reviewed 布尔（页"看过"标志），二者不冲突』 |
| 5 | 识字数据包保留溯源字段 | `metadata.py:116`（legacy_id）、:44-62（stable_uid 即 char_uid 基础）；`training_service.py:646` 读 char_uid 兜底；Dart 侧 `crowd_dataset_exporter.dart:243-245` 写 | **保留** | legacy_id/char_uid 是众包跨系统对账的唯一钥匙（无数据库项目里全靠它做幂等匹配）；丢了字段=历史共识快照全部作废 |
| 6 | train/val 按页划分防泄漏 | `training_service.py:227-236` `_page_split`（docstring 明言 "A page can never straddle train/val"）；`verify_training.py:38-39` 复用同一实现 | **保留** | 同页双集合泄漏会让 val 指标虚高、训练页"假达标"；单一实现（唯此一处）正是防漂移的关键，审计确认没有第二套划分逻辑 |
| 7 | 训练完成只登记、不自动替换 | `training_service.py:1335/1383`（activate/deactivate 人工触发）、`char_verify.py:186-206`（惰性加载当前 active）、`kraken_training.py:426`（activate） | **保留** | 训练指标与真实识别效果不是同一分布；人工闸门保证随时可回退，是 5 类模型共用的安全网 |
| 8 | 众包闭环（导出→命迹后台→共识写回 needs_review→人工复核） | `metadata.py:33`（写回落 needs_review 落地）；实体链路在 flutter：`crowd_dataset_exporter.dart` / `crowd_consensus_importer.dart:163`（按 char_uid 匹配） | **保留** | 这是跨两个系统的数据契约文档（本 README 是唯一记载处）；共识写回强制 needs_review，保证外部答案永远不能未经人工确认直接进训练集 |

**D1 待执行项（属文档改动，随阶段①一起做）：**
1. 改写第 4 条措辞（如上）。
2. 第 5 条补一句：char_uid 在识字数据包内以 Dart 导出格式为准（配合 B7/D3）。

### D2 `python_service/ab_verify/README.md`（6 条操作规则）

> 审计结论：**全部有效保留**。目录、脚本、环境约束与代码一致；发现 1 处缺载。

| # | 规则（摘要） | 代码落点（证据） | 结论 | 为什么要它 |
|---|---|---|---|---|
| 1 | 显存空闲时运行（并行腿另起 daemon 池抢显存） | `run_ab.py` 并行腿全默认 → `daemon_sizing.py` 按硬件定池数 | 保留 | 并行腿与生产识别抢显存会导致 OOM/超时，A/B 耗时数据失真 |
| 2 | 基线腿 `OCR_KRAKEN_WORKERS=1`+`KRAKEN_PREP_PIPELINE=0` ≙ 旧版串行 | `run_ab.py` 环境变量注入 | 保留 | 这是"等价性验证"的对照定义本身，改了就没有基线可言 |
| 3 | 每腿 1 热身 + 5 计时，页在 `run_ab.py` 顶部 PAGES 改 | `run_ab.py` 顶部 PAGES 常量 | 保留 | 首页含模型冷启动，不热身会系统性高估耗时 |
| 4 | `compare_ab.py` 归一化毫秒 id 后逐字节比较，一致退出 0 | `compare_ab.py`（69 行） | 保留 | 这是并行化改造的验收标准（逐字节一致=重构无行为漂移） |
| 5 | 实例必须 `conda run -n paddle` 启动 | `run_ab.py`（与 App 生产启动方式一致，`python_service.dart:429`） | 保留 | 直接用 env python.exe 会因 conda DLL 路径卡在 torch 导入——踩过坑写下的，删了必再踩 |
| 6 | 临时端口 + 结束后恢复 `service_port.txt` | `run_ab.py:23,97-113`（PORT_FILE 保护恢复） | 保留 | 不恢复会让 App 连到已退出的 A/B 实例上 |

**D2 待执行项：**
- README 补记 `ab_segment_run.py`（77 行，实际存在但 README 未提）。☐ **D6**：补记／或经你确认该脚本已废弃则连同删除。

---

## E. 本地 agent 执行指引

> 三阶段，每阶段一批 SVN 提交；任何一步验证不过即停，不带病进入下一步。

### 阶段① 删死码 + 清杂物（低风险）

范围：A1（按 D1 勾选）、A2（含级联）、A3、A4（按 D2 勾选）、A5（按 D4/D5 勾选）、D1/D2 的 README 文档改动。

每个删除动作前对符号名重跑一次全仓库 grep（python_service + flutter_app），确认计数不变再删；A3 的 `cosine_sim` 按表内提示额外复核动态引用。

验证：
```bash
cd python_service
conda run -n paddle python -m pytest -q          # 16 个测试文件全量
conda run -n paddle python -c "import main"      # FastAPI 应用可加载
svn status                                        # 改动面应与 A 章清单一一对应
```

### 阶段② 合并重复逻辑（中风险）

顺序：B1 → B2 → B8（可与 C5 合并做）→ B3（单独提交，重点回归训练链路）。B4/B6/B9 默认不动；B7 只加注释不改格式。

验证（在阶段①命令之外追加）：
```bash
conda run -n paddle python -m pytest -q
# 手工冒烟：起服务，flutter 端跑一次 整页识别 + 训练页生成数据集 + 启用/停用一个模型
```

B3 专项验收：activate 一个模型 → 重启服务 → `/models` 仍显示 active；`models/registry.json` 内容与改前等价（仅路径经过新模块）。

### 阶段③ 大文件拆分（结构性，最后做）

按 C 章顺序逐文件执行：一文件一提交，门面 re-export 保证 import 面零变化。

验证（每文件拆完都跑）：
```bash
conda run -n paddle python -m pytest -q
conda run -n paddle python -c "import main"
# flutter 侧零改动确认：
cd ../flutter_app && flutter analyze
# 手工冒烟：App 正常拉起后端、整页识别一次、Excalidraw 导出一次
```

### 禁止事项

1. 不加任何功能、不做任何"顺手优化"（命名、注释美化也不做）。
2. 不改任何路由路径、请求/响应字段名、错误文案。
3. 不改任何盘上格式：`models/registry.json`、`blocks.json`、npz 模板库、识字数据包结构。
4. 不动「保留勿删清单」与 A/B 清单之外的任何文件。
5. B7 的两种 stable_uid 格式**不统一**（会作废历史众包数据）。

---

## F. 范围外登记（本轮不动，仅备案）

- `ocr/` 根目录调试产物：`page84_*.json` ×7（约 1.3 MB）、`page84_v88_run.log`、`title.png`（52 KB）——`.tmp_stats.py` 引用的 `page84_v89_http.json` 已不存在，说明这批是版本比对调试残留；建议下次大扫除处理。
- `ocr/.pytest_cache/`（9-19 产物）——从 ocr 根误跑 pytest 的缓存，python_service 下那份是正常的；建议随上面一起清。
- `flutter_app/README.md` 仍是 Flutter 模板默认内容，无项目说明。
- `ocr/CHANGELOG.md` 存在 UTF-8/GBK 混显（历史编码问题），阅读工具下乱码。

---

## 决策点汇总（确认时勾选）

| # | 决策 | 选项 | 推荐 |
|---|---|---|---|
| D1 | `paddle_engine.py`（自述已移出链路、保留备用） | ☐ 删除 ☐ 归档 `tools/archive/` | 删除（SVN 可找回，恢复点已注释在 `kraken_bridge.py:969`） |
| D2 | `tool_train_verify.py` / `tool_train_char_cls.py`（第五册一次性脚本，含硬编码本机路径） | ☐ 删除 ☐ 归档 | 删除 |
| D3 | stable_uid 双实现（B7） | ☐ 只加注释+README 补记 ☐ 暂不动 | 加注释（不动格式） |
| D4 | 根目录 `yolov8n.pt`（n 档底模缓存，可自动重下） | ☐ 删除 ☐ 保留 | 保留（6.5 MB 不大，免得下次 n 档训练重新下载） |
| D5 | 根目录 `yolo26n.pt`（全仓库零引用） | ☐ 删除 ☐ 保留 | 删除 |
| D6 | `ab_segment_run.py`（README 未记载） | ☐ README 补记 ☐ 确认废弃后删除 | 补记 |
| D7 | `models/YOLO OCR.pt`（全仓库 0 引用，文件名带空格） | ☐ 删除 ☐ 保留 | 删除 |
| D8 | `models/trained/` 孤儿 run 目录（约 342 MB，registry 未登记） | ☐ 删除孤儿（保留登记的 5 个 run） ☐ 保留 | 删除孤儿（若想保险，可先单独打包备份再删） |
| D9 | `logs/` 312 MB 运行日志 | ☐ 清旧留新 + svn:ignore ☐ 不动 | 清旧留新 |

---

## G. 执行记录（2026-09-30，阶段①②已落地）

> 决策点按推荐值执行：D1/D2/D5/D7 删、D4 留、D3 加注释、D6 补记、D8 删孤儿（先备份）、D9 清旧留新。
> 备份目录：`E:\Work\Flutter\ocr_cleanup_backup_20260930\`（code/ 原代码 15 份、junk/ 死文件与杂物、weights/、models_orphans/ 11 个孤儿 run、基线日志）。确认无误后可整体删除。

### 阶段①（完成）

- **A1**：删 `.tmp_stats.py`、`paddle_engine.py`。
- **A2**：删 `/capabilities` 路由 + `main.py` import 行 + `segmenter.get_capabilities`；级联检查后 `_import_opencc`/`_yolo_diagnostics`/`_preload_torch_for_windows` 仍有多处引用，保留。
- **A3**：删 11 个零引用函数（原清单 10 个 + 普查新增 `verify_training._escape`）。
- **A4**：删 `tool_train_verify.py`、`tool_train_char_cls.py`；`tool_verify_backtest.py`、`debug_visualize.py`、`ab_verify/` 保留。
- **A5**：删调试 PNG×6、`logsspawn_test.txt`、根 `service_console.log`；`yolo26n.pt`、`models/YOLO OCR.pt` 移入备份；`yolov8n.pt` 保留（D4）；`models/trained/` 11 个未登记孤儿 run 移入备份（**models/ 561M→110M**）；`logs/` 三份日志各保留末 2000 行（**312M→606K**）。
- **D 章文档**：`ocr/README.md` 规则 4 改写、规则 5 补 char_uid 格式基准句；`ab_verify/README.md` 补记 `ab_segment_run.py`。

### 阶段②（B1/B2/B3/B7 完成；B4/B6/B9 按计划不动；B8 留给阶段③ C5）

- 新增 `imaging.py`（`imread_unicode`/`imwrite_unicode`，全项目唯一实现，支持 ext/params）。
- **B1**：`segmenter._imread` 委托 imaging；`training_service._imread` 改为容错包装（保留"坏图返回 None"语义，删除复制的 cv2 逻辑）。
- **B2**：收编 9 处写盘样板（`main.py`×7 含删除 `/crop` 内嵌套 `_imwrite_unicode`、`kraken_training`×1、`verify_training`×1）。**4 处有意不并**（行为保真）：`transform_page`/`split_page`/`dewarp_page` 三处 encode 与 write 的 500 错误文案不同且含异常详情，按"错误文案逐字保留"原则不动；`training_service.py` 数据集写盘是"一次编码、多目录落盘"形态，保留。6 处 base64 内存编码本就不属写盘样板。
- **B3**：新增 `registry_io.py`（`load_registry`/`save_registry`，路径参数化 + **原子写** mkstemp+replace）；`training_service`/`verify_training` 改为委托、`char_verify` 内联读改调用；JSON 结构一字未动。
- **B7**：`metadata.stable_uid` 与 `crowd_dataset_exporter.dart` `_stableUid` 加互指注释，README 声明格式基准；**格式未统一**（保护历史众包数据）。

### 验证结果

| 检查 | 基线（改前） | 改后 |
|---|---|---|
| unittest 全量 | 251 例：2 失败 + 1 错误（test_page_dewarp 因环境缺 pytest 无法加载） | **255 例：同样 2 失败，零新增**（page_dewarp 恢复加载并入） |
| test_page_dewarp（pytest） | 38 通过（装 pytest 后补测） | 38 通过 |
| py_compile / import main | — | 11 个改动文件 OK；import OK（60 路由） |
| registry roundtrip | — | 与直接 json 读完全一致（layers: char_cls/char_det/verify_pair） |
| flutter analyze | 1 条存量 info（debug_page.dart，与本次无关） | 同样仅该 1 条 |

存量失败（与本次清理无关，改前改后相同）：`test_layout_analysis.test_narrow_detector_bleed…`、`test_segmenter.DoubleColumnSplitTests.test_duplicate_fragment…`。
为可测试性给 paddle 环境安装了 pytest（`pip uninstall pytest` 可还原）。

### 未做 / 待办

- **阶段③**：C1–C7 八个大文件拆分（门面 re-export 方案见 C 章）——单独一轮执行，一文件一提交；B8（20 处入参校验收敛）随 C5 `main.py` 拆分一起做。
- **待用户**：SVN 提交（本机无 svn CLI，建议 TortoiseSVN：阶段①、②各一提交）；svn:ignore 建议补 `logs/`、`__pycache__/`、`.pytest_cache/`、`*.log`；确认备份目录后自行处置。

---

## H. 执行记录 · 二（2026-09-30，全项目循环：③拆分落地 + flutter 审计 + 复审）

> 循环模式：检查 → 优化 → 复检，直到无可优化项。每步全量测试对比同一条基线（python：255 例/2 存量失败；flutter：198 过/1 环境性失败）。

### 阶段③（python_service 拆分全部落地）

| 原文件 | 拆分结果 | 验证 |
|---|---|---|
| page_dewarp.py 908 | → page_dewarp 747 + **page_enhance** 176 | 38 例绿 |
| training_service.py 1405 | → 门面 109 + train_data 411 / train_datasets 554 / train_tasks 387 / train_registry 223 | 全量基线 |
| excalidraw_export.py 1903 | → 门面 127 + excalidraw_scene 724 / _ink 398 / _lines 488 / _graphics 432 | 全量基线 |
| kraken_bridge.py 2262 | → **kraken_bridge 1256（例外，见下）** + kraken_proc 597 + kraken_boxes 591 | 全量基线 |
| main.py 2957 | → 门面 289 + api_base 412 + api_segment/page/recognize/verify/train/kraken/export 七域（161~698） | 60 路由不变 |
| segmenter.py 4491 | → 门面 176 + seg_trace/models/imaging/refine/chars/lines/pipeline/layout/doublecol/candidates（76~782） | 全量基线 |
| test_segmenter.py 2393 | → 空壳说明 11 + test_seg_core 233 / test_seg_kraken_cuts 757 / test_seg_punct 472 / test_seg_lines 423 / test_seg_layout 715 | 全量基线 |
| char_verify.py 1390（计划遗漏，补拆） | → 770 + char_skeleton 497 + char_glyph 429 | 全量基线 |

- 方法：AST 拆分工具（备份目录 split_tool.py），门面 re-export 保证 import 面/路由/子进程启动零变化；每文件拆前冒烟、拆后全量回归。
- **kraken_bridge.py 保留 1256 行的例外论证**：`_recognize_char_boxes` 被 test_recog_eval patch 且有 4 个调用方横跨识别/融合/行切分三条链——再拆必须重排 patch 拓扑或改写调用方式，属设计变更而非机械清理，按"收益低/风险高登记不动"原则保留。
- 关键修复（拆分中发现的行为保真问题）：`_pool`/`_YOLO_ERROR` 等运行时重绑定的模块全局改经函数存取（`pool_size()`/`record_yolo_error()`），避免 from-import 旧值快照；pipeline↔layout 循环用函数内懒导入断开。
- **测试 patch 目标迁移**（门面陷阱）：excalidraw `_recognize_region`×6 → excalidraw_scene；kraken `_pool`×3 → kraken_proc；segmenter `_char_cls_candidates`/`segment_image_with_metadata` → seg_candidates/seg_pipeline。kraken_bridge.log 与 segmenter._text_mask_for_refinement 保持原样（消费方经函数内 import 走门面属性，patch 仍有效）。
- **B8 不做**（登记）：20 处入参校验收敛会触碰无测试覆盖的 HTTP 错误路径（400/422 语义与文案保真无法验证），收益 20 行，风险不成比例。

### 循环 2（flutter_app 审计 + 零风险清理）

- 基线：analyze 1 条 lint、test 198 过/1 环境性失败（backend_unreachable_retry，网络依赖）。
- **执行**：修 lint（debug_page.dart）；删 2 个零引用方法 `PythonService.krakenActivate/krakenDeactivate`（已被 activateModel/deactivateModel 取代）；移除无用依赖 `cupertino_icons`。结果：**analyze 0 issues**，test 198/1 与基线一致。
- **审计结论（agent 普查）**：0 死文件、0 死类；13 组重复逻辑（多为"已有共享版未复用"：HTTP 样板 28 处、图片解码/PNG 尺寸/画布 fit/文件选择双胞胎、similar_chars 两页约 300 行组件复制）。
- **下轮方案（flutter 循环 2，结构性）**：① 抽 `_postJson`（python_service.dart 3141 行内 28 处样板，收益最大）；② 12 个 >800 行 dart 文件拆分（editor_page 11363 居首），沿用门面/part 策略；③ 复用既有共享版（image_probe/canvasInitialMatrix/storage 原子写）；④ similar_chars 两页组件合并。

### 循环 3（全项目复审：无剩余机械优化项）

- python 零引用普查（含全部新模块）：**零发现**；杂物扫描：零发现（logs/ 为运行目录）。
- `diag_enable_crash_dumps.cmd`：CHANGELOG 有明确用途（WER 崩溃转储），**保留**。
- installer/ocr_setup.iss：不引用已删文件，干净。
- 最终状态：python_service 49 个业务 py + 16 个测试，>800 行仅 kraken_bridge（已论证）；全量 255 例、2 存量失败与循环开始前完全一致。

### 存量失败记录（与清理无关，建议单独排查）

1. `test_layout_analysis.test_narrow_detector_bleed…`、`test_seg_layout.DoubleColumnSplitTests.test_duplicate_fragment…`：改前即红，两处均为"重复碎片行删除"断言，疑似同一回归。
2. flutter `backend_unreachable_retry_test`：本机网络环境性失败。

### 启动事故与修复（2026-09-30 晚，App 启动后端 NameError）

- **现象**：App 拉起后端报 `main.py:55 install_console_log NameError`。
- **根因**：C5 门面把 `if __name__ == "__main__":` 启动块放在文件中部、api_base re-export 在尾部——`import main` 时主块被跳过（测试全绿），真实 `python main.py` 时主块在 re-export 生效前执行。验证协议缺口：只做了 import 冒烟、没做真实启动冒烟。
- **修复**：主块移至文件末尾（re-export 之后）；split_tool 的门面输出顺序同步修正（re-export 永远先于保留块），杜绝同类复发。
- **补验（真实启动冒烟）**：`python main.py` 起服务 → uvicorn 监听 1288 → `GET /health` 返回 `{"status":"ok","build":"line-ink-2026-09-30-v91"}` → `GET /process_stats` 正常（api_base 域）→ `POST /segment` 坏路径返回逐字一致的 `{"detail":"image not found"}`（api_segment 域，错误契约保真）→ 停实例并恢复 service_port.txt。**此后"真实启动冒烟"列入拆分类改动的必备验证**。

### 备份与工具（E:\Work\Flutter\ocr_cleanup_backup_20260930\）

code/（改动前原件 17 份）、junk/、weights/、models_orphans/（342 MB）、ocr_root_junk/、baseline_unittest.log、smoke_check.py、split_tool.py（AST 拆分工具，含门面防重入护栏）与 c1~c8 配置。确认无误后可整体删除。
