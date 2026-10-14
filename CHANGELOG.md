# 更新日志

## 1.0.0+208

- **修复：看不到整页对照标记/紫色无框字片——标记只在"识别当前页"时写入标注，直读更新后不跟随**（用户实测："上一步制作的单字识别与整页识别对照功能我没看到，我也没看到紫色无框字片"；v207 标点恢复后用户重读了文本视图，但标注里的对照数据仍是直读修复前识别时写入的空/旧值）。三处：
  **① 新端点 `/refresh_full_text_check`**：用文本视图整页直读落盘的行记录（direct_text 侧车）对**已有标注行**重算全文对照——纯 CPU（读侧车 + 行框 IoU 匹配 + 序列对齐，不跑任何模型不重识别），逐行返回 {full_text, full_extras, diff_indices}；行没匹配上/无侧车返回空值（客户端按空覆盖，清掉过期标记）；`FULL_TEXT_CHECK=0` 同样生效。引擎无关（kraken 书只要有直读侧车也能刷新）。
  **② 客户端自动刷新**：文本面板新增 `onReadComplete` 回调（直读文本+行记录落盘后触发）→ 编辑器 `_refreshFullTextMarks`：取当前标注有字行（框+逐字文本）调①，回写 fullText/fullExtras/逐字 fullDiff 并保存，SnackBar 提示"整页对照已按最新直读刷新：N 行"；增强路静默失败（不影响直读本身）。
  **③ python_service.refreshFullTextCheck** 服务方法（60s 超时）。
  实弹 e2e（page_005 真实数据：侧车=用户重读后的带标点行记录，标注行=模拟无标点+错字逐字序列）：22/22 行 **14ms** 全部匹配，**72 个标点落为紫色字片数据、34 个错字精确标橙**（注入的错位 [4,9] 分毫不差）；顺带发现用户侧车已是 v207 修复后的带标点行记录（重读已生效）。测试：后端 RefreshFullTextCheckTests 4 条（extras+diff_indices/未匹配清空/无侧车/总开关），全量 **602 过**（2 存量失败与本次无关）；flutter analyze 零问题。BACKEND_BUILD v151→**v152**（fulltext-auto-refresh，Dart 握手同步）。pubspec 1.0.0+207→1.0.0+208。
  使用：升级重启后**在文本视图对该页重新点一次整页直读**——落盘后自动刷新标注标记并提示；切回标注视图打开单行即可见紫色无框字片（整页有而单字无框的字符，多为标点）与橙色不一致标记。识别当前页重跑（20s+）不再是刷新标记的必要条件。

## 1.0.0+207

- **修复：整页直读（文本视图）VL 不再输出标点——"版面分析"开启后 VL 块变整段段落，逐行合并全部失配**（用户实测："在整页识别的时候 vl 模型为什么识别不出标点了，之前是可以的"）。诊断：侧车数据显示 VL 其实读出了全部标点（2 个整段块共 91 个标点），但 v204 面板暴露的"版面分析"开关被打开后，VL 的 parsing_res_list 块是**整段段落文本**（几十上百字、无逐行 \n），混合直读的合并器按"逐行文本相似度 ≥0.55"设计——整段 vs 单列（~30 字）相似度全落空 → 22 条行全部保留无标点的 PP-OCR 文本，带标点整段掉进零框兜底堆在页尾（用户所见=标点消失）。修复（worker `_vl_merge_texts` 双路径）：
  **① 逐行匹配保留**（无版面模式的逐列输出，历史行为与测试不变）；
  **② 段落切片新增**：逐行对不上的 leftovers 中纯文本长于 max(48, 2×行中位字数) 的按**段落**处理——未占用 PP 行按阅读序粗排（`_order_geo_reading`，竖排列序/列内按方向参数），逐行在段落纯文本里 difflib 定位（覆盖率 ≥0.55），相邻定位之间的标点归属前一行、段首残余并入首行、段尾残余并入末行——标点精确落回各行，不再产生整段零框副本；切片一行没中才走零框兜底（文本不丢）。
  **③ 方向透传**：`/read_page_text` 请求体新增 orientation/horizontal_dir/vertical_dir → worker 段落切片阅读序（旧 worker 忽略）。
  **用户真实失败数据回放**（page_005 侧车：22 条无标点 PP 行 + 2 条 VL 整段 374/183 字，rtl）：新合并器 22/22 行全部换上带标点 VL 文本（88 个标点落回行内）、零框副本 0、页码行保留原文——与"之前可以"时的输出一致，且此后版面分析开/关都能正确产出。
  测试：VlParagraphMergeTests 4 条（切片标点归属/段落外行保留/不可配段落不丢/行级+段落混合）+ ReadPageTextPayloadTests 1 条（方向透传）；既有 4 条合并测试零改动通过（逐行路径行为不变）；后端全量 **598 过**（2 存量失败与本次无关）。BACKEND_BUILD v150→**v151**（vl-para-merge，Dart 握手同步）。pubspec 1.0.0+206→1.0.0+207。
  使用：升级后**在文本视图重新点一次整页直读**即恢复带标点输出（顺带落盘带标点的 line_records，默认识别流程的整页对照参照也随之带标点）。古籍竖排仍推荐版面分析保持关闭（更快；开启现在也能正确切回行）。

## 1.0.0+206

- **新增：det 行版面类型框（页眉/页脚/页码）+ 全文对照参照升级为整页直读行文本**（用户需求：det 检出的页眉/页脚/页码内容应使用对应类型的识别框；单字识别与整页文本不一致处、整页有而单字无框的字符要在单字识别页面用特殊颜色标记展示）。三块：
  **① det 行类型化**：det 定行的页眉/页脚/页码内容不再混作正文行——seg_pipeline 新增 `_type_det_lines`：行中心落在人工已确认门控区（页眉/页脚/页码/眉批）内即该类（门控区已抹像素，此为边缘残留兜底）；无区时几何判定（页顶/页底边带内的短行——25% 版高上限保证主列永不误标；页脚带内 ≤5 字的极短行判页码）。命中行带 `region_label` + `layout_role=annotation`；客户端 `LineBlock.regionLabel` 新字段（JSON 往返），行视图按区域视图同款 `RegionLabel` 配色画框（页眉青/页脚蓝灰/页码绿/眉批黄棕）并在框底标注类型名；单行重识别请求带 `region_label` 原样回盖（`_stamp_region_label`，重识别只换文字不丢类型），双列拆分子行继承。
  **② 全文对照参照 = 文本视图整页直读的行文本**（旧参照是行框裁图逐行二次识别——PP-OCR 系对古籍标点本就盲，紫色无框字片几乎不出现；且与用户在文本视图看到的整页文本对不上）。实现为**零额外推理**：文本视图直读落盘的行记录（`direct_text/<pageId>.meta.json` 新增 `line_records`：逐行框+文本）即参照源——paddle_bridge `attach_page_text_ref` 读侧车挂到适配器，`_apply_full_text_check` 优先按行框 IoU（≥0.3，det 定行后标注行与直读行同源 PP-OCR det、天然高 IoU）匹配行文本做对照：**整页有而单行无框的字符（标点等）→ 紫色无框字片；单字与整页文本不一致 → 深橙标记**（客户端 v203 起已渲染，此前缺高质量参照数据）。侧车缺位/无记录/行未命中 → 静默回退旧逐行参照，识别不受影响。**踩坑记录（决定架构）**：首版做成后端自动页读（按本书模型现读一页），实弹两轮在 9 路 kraken 常驻挤显存的机器上 VL 冷读 300s/900s 预算双双超时、拖垮 /segment（334s/935s），回退链虽正常接管但主路径不可接受——改为读已落盘行记录后同样请求 **20.2s**（含全新后端首建 daemon+det+19 行识别），且参照与用户所见严格同一份。
  **③ API**：`/segment_region` 追加可选 `region_label`（客户端重识别带行类型回盖）；`/segment`/`/segment_lines_in_region`/`/segment_region` 无新增必带字段。
  实弹 e2e（page_005 隔离副本，engine=paddle + VL 书级模型）：侧车 19 行即时挂载（日志"整页参照就绪: 侧车 19 行"），19/19 行对照命中；构造带注入标点/字符的行文本后 extras 精确命中注入字符（紫色字片数据），单字序列错位处逐字标 diff（前两轮实弹 51 字）；底部页码行 `region_label=page_number`。测试：后端 test_paddle_det_lines 重写+新增共 **30 条**（类型化几何/区域归属/拒绝区、IoU 匹配、页读参照 extras+diff/未命中回退、侧车解析/缺位/坏 JSON/退化过滤/总开关、请求缺省值、region_label 回盖），全量 **593 过**（2 存量失败与本次无关；test_zjpack ed25519 出现过一次孤立偶发、单跑即过）；客户端新增 line_region_label 3 条（解析/往返/配色同源），analyze 零问题、test **603 过**（1 存量失败）。BACKEND_BUILD v149→**v150**（det-typed-pagecheck，Dart 握手同步）。pubspec 1.0.0+205→1.0.0+206。
  注意：**要得到整页对照标记，先在文本视图对当前页做一次整页直读**（行记录随直读落盘；旧侧车无 line_records，重读一次即有）；升级后需重新执行"识别当前页"才会得到带类型与整页对照的新数据；类型化行仍保留在识别结果里（视觉与导出按批注类处理）。

## 1.0.0+205

- **新增：engine=paddle 时行框来源切换为 PP-OCR det 文本检测（官网演示同款，单行识别框质量问题治本）**（用户反馈："我在 paddle 官方网站测试同样的页面单行识别准确，文字也准确，现在软件中单行识别到的识别框就有很多问题"——截图可见整列漏检、单个句号成独立行框、列首尾框外扩、夹注小字并进正文列）。此前行框全部来自**自训 YOLO 字框分组**（碎片/粘连/漏检高发）；本次在 `/segment` 与 `/segment_lines_in_region` 两条链路上，engine=paddle 时行框改用 **PP-OCR det**（与官网演示同一检测模型）：
  **① worker**（paddle_worker）：新增 `detect_lines` op——daemon 内懒建 `TextDetection` 单模（检测档位跟随识别档位 `PP-OCRv6_<tier>_rec → _det`，不可用退回 small；与识别模型同进程共存），返回未排序行框；实测 paddleocr 3.7 输出键 `dt_polys(N,4,2)`，解析兼容 det_boxes/rec_boxes/det_polys 多通道。
  **② 桥接**（paddle_bridge）：`detect_page_lines`——池跟随行识别档位（VL 选择自动回退 small），`OCR_PADDLE_DET_LINES=0` 可整体停用（回退 YOLO 行框）。
  **③ 切分管线**（seg_pipeline）：`segment_image_with_metadata` 新增 `line_detector` 注入参数——det 框→行结构（钳制界内/退化丢弃/竖排页上 w>1.3h 的横排落款行放行 horizontal），走统一阅读序重排；**det 失败/空产出静默回退既有 YOLO 链路**（det 是行框增强，不是硬依赖）；下游（逐行像素切字/识别/融合/全文对照）零改动复用。
  **④ 扩张帽**（kraken_bridge）：行框沿阅读轴墨迹外扩的 25% 上限原本只对带 chars 的 YOLO 行生效，改为对全部竖排行生效——det 行（chars 空）同样受帽，栏线链式扩到整页的病态扩张对 det 行也挡住；kraken 链路行为不变（其竖排行恒有 chars）。
  **⑤ 客户端**：识别信息脚注新增 `paddle-det → "PP-OCR 检测定行"`（蓝色），王朝基准页版面标签同款；无请求字段变化（服务端按 engine 自行决策）。
  实弹 e2e（用户 page_005，6034×8534 竖排 17 列）：det 0.7s 检出 **19 行**（17 主列全部紧致 ~207×5500px + 页底横排落款自动判横 + 左缘小列），阅读序右→左正确，逐行像素切字+逐字+拼条识别 570 字框填满、首列文字与直读文本一致，整页 28.9s（含首次起 daemon+模型加载）；后端日志零异常。测试：新增 test_paddle_det_lines **15 条**（det 结果解析/行构建与方向放行/注入与回退/池请求与 kill-switch/engine 分发），后端全量 **578 过**（2 存量失败与本次无关）；flutter analyze 零问题、flutter test **600 过**（1 存量失败）。test_dynasty_bench 的明细泄露断言由裸子串改为字段级（`'"lines"'`，避免被 build 串误伤）。BACKEND_BUILD v148→**v149**（paddle-det-lines，Dart 握手同步）。pubspec 1.0.0+204→1.0.0+205。
  注意：**升级后需对已有页面重新执行"识别当前页"**，存量标注里的旧 YOLO 行框不会被自动替换；kraken 引擎书的行框链路完全不变。

## 1.0.0+204

- **新增：VL 配置面板补齐官网演示同款全参数（Prompt 类型 / 生成参数 / 辅助内容解析）**（用户需求：模型设置缺少 prompt 类型等参数）。API 落点全部查证后实现——**新增参数全部是 predict 级**（随每次直读请求传入，不换池、改动即生效）：
  **① Prompt 类型**（`prompt_label`，仅关闭版面分析时生效）：文本 ocr（默认）/ 公式 formula / 表格 table / 图表 chart / 印章 seal / **文本检测与识别 spotting（逐行点读）**——下拉选择。
  **② 生成参数**：重复抑制强度（repetition_penalty，默认 1.0）/ 识别稳定性（temperature，默认 0.0）/ 结果可信范围（top_p，默认 1.0）/ 图像最小总像素数（min_pixels，默认 147384）/ 图像最大总像素数（max_pixels）。留空=模型默认。**实测注记**：paddlex 本地推理对前三个采样参数会告警"暂不支持、将忽略"（vllm-server 后端才生效）——面板已注明，字段保留（无害）。
  **③ 辅助内容解析**（`markdown_ignore_labels`，7 开关）：页眉/页眉图片/页脚/页脚图片/页码/脚注/旁注文本——默认过滤（模型默认忽略全部 7 类），开启=恢复解析；客户端把开关转换为"仍忽略"清单（全开=空清单，worker 端空清单有效=全恢复）。
  链路：客户端 `ProjectSettings` 新增 12 字段（vlPromptLabel/3 采样/2 像素/7 辅助开关，JSON 往返）+ `vlPredict` 请求体 getter → `/read_page_text.vl_predict` → worker `_vl_predict_kwargs` 白名单归一 → `pipe.predict(**kwargs)`。实弹验证参数到达 predict（日志 `VL predict params: {...}`）。**已知限制**（实测）：spotting 模式在超大整页上可能触发底层原生崩溃（进程直接退出无 Python 栈，paddlex 原生层问题）；默认 ocr 模式不受影响（混合直读的逐行能力由 PP-OCR 几何承担）。官网面板的"跨页表格合并"（多页 PDF 场景）与"段落标题级别识别"（markdown 后处理层）与单页直读无关，未接入。
  测试：客户端 vlPredict 5 条（默认空/透传/辅助开关→忽略清单/全开空清单/JSON 往返+非法归一）；worker kwargs 3 条（白名单与类型/空清单有效/清单过滤），后端全量 **563 过**（2 存量失败）；flutter analyze 零问题、flutter test **600 过**（1 存量失败）。BACKEND_BUILD v147→**v148**（vl-predict-params，Dart 握手同步）。pubspec 1.0.0+203→1.0.0+204。

## 1.0.0+203

- **修复："重新识别当前页"报 type 'Null' is not a subtype of type 'String'（v202 堆栈插桩一击定位）**。堆栈指到 `MainRegion.fromJson` 的 `j['id'] as String`——完整根因链：书的标注里有**已确认的门控区**（页眉/页脚/页码）时，重识别请求携带 gate_regions（日志特征"页眉/页脚/页码门控：N 个排除类区已抹除"）；后端 `GateRegion` 模型**没有 id 字段**（旧注释"id/uid 由 pydantic 忽略，不回传"），门控区作为结果 `main_regions` **原样回显**时条目无 id → 客户端严格转换炸掉。此前复现不出来的原因：测试请求从未带过 gate_regions。修复三处：
  **① 后端 GateRegion 增加 `id` 字段**（透传，客户端发的区域 id 全程在场）；
  **② seg_pipeline 门控区回显前补 id**（缺失时 `mr_gate_NNN`，与 `mr_model_NNN` 命名同族）；
  **③ 客户端 MainRegion/Paragraph.fromJson 的 id 防御**（缺失/null 时按坐标生成确定性回退 id，不再抛 type cast；防御老后端/历史数据）。
  实弹闭环验证：带 2 个无 id 门控区的完整 /segment 请求 → 响应 `main_regions` 带回 `mr_gate_000/001` → 客户端解析测试通过。测试：新增 gate_region_id（客户端回退 id/正常 id/null id + line_ids null 元素过滤）与 gate_resp_parse（真实带门控区响应解析）；后端 GateRegion id 透传 2 条；后端全量 **560 过**（2 存量失败与本次无关）；flutter analyze 零问题、flutter test **594 过**（1 存量失败）。BACKEND_BUILD v146→**v147**（gate-region-id，Dart 握手同步）。pubspec 1.0.0+202→1.0.0+203。

## 1.0.0+202

- **诊断加固：页面识别/载入异常现在把完整 Dart 堆栈落进应用日志**（用户持续遇到 "type 'Null' is not a subtype of type 'String' in type cast"，v146 后端已恢复正常返回仍报）。本轮把该错误的可疑链路逐段实弹验证：真实 `main_text_only` 整页响应（用户完整参数复现）扫 null 干净；完整客户端链（响应解析 → PageAnnotation → inferHierarchy → rebuildBlocks → 存取往返）测试通过；**`ensurePageAnnotation` 全流程决定性测试**（本地假后端回放真实响应 + 真实项目落盘）通过；用户真实 SharedPreferences 的 Ollama 设置扫 null 干净、`OllamaSettings.fromJson` 全字段 null 安全；`Project.fromJson` 方向/模型覆盖解析 null 安全。既有静态审计未再找到可疑强转——**编辑器页面载入的 catch 块加 `StackTrace` 落日志**（`[载入诊断] 页面识别/载入异常：…+堆栈`，后台控制台可见），下次复现即给出精确抛点文件与行号，一击定位。测试：新增 `mto_parse_test`（main_text_only 真实响应全链）与 `ensure_page_annotation_test`（假后端+真流程+落盘断言，响应文件缺失时自动跳过）；flutter analyze 零问题。纯客户端改动，BACKEND_BUILD 不变 v146。pubspec 1.0.0+201→1.0.0+202。

## 1.0.0+201

- **修复：v200 引入的回归——Paddle 首个识别请求 500 `'NoneType' object has no attribute 'shutdown'`**（用户实测 v145 后端日志：切到 VL 模型后首个 `/segment_region` 与整页 `/segment` 均 500，行重识别的 strip 补读也报同一错误）。根因：v200 重写 `ensure_pool` 支持池按（模型+VL 配置）绑定时，把"后台关闭旧池"的线程启动移出了 `if old is not None` 保护——**首次建池**（`_pool=None`，old 即 None）时取 `old.shutdown` 直接 AttributeError，从识别链路上抛成 500。修复：线程启动收回保护内（只在确有旧池时后台关闭）。测试：test_paddle_engine 新增首次建池回归测试（`_pool=None` 时 `ensure_pool` 不抛，36 过）；实弹 e2e（用户完整参数：engine=paddle + VL 模型、干净后端首次建池）——`paddle daemon p1 ready`（VL 行/字识别自动回退 PP-OCRv6_small_rec）、整页识别 313 字/19 行成功无错；后端全量 **559 过**（2 存量失败与本次无关）。BACKEND_BUILD v145→**v146**（pool-firstbuild-fix，Dart 握手同步）。pubspec 1.0.0+200→1.0.0+201。

## 1.0.0+200

- **修复：重新识别当前页 500 "Internal Server Error"（真凶：控制台管道错误炸穿端点）+ 新增：PaddleOCR-VL 解析配置面板（官网演示同款开关）**。两块：
  **① 500 根因（用户后端日志 service_console.log 抓到完整堆栈）**——`api_base._Tee.flush()` 里 `self._original.flush()` 无保护：App 侧 stdout 管道异常（实测 `OSError: [Errno 22] Invalid argument`，如换代时旧后端进程成孤儿、管道对端已死）时，端点里**第一行 print(flush=True) 就炸穿** `/segment` → Starlette 兜底纯文本 "Internal Server Error"，识别根本没开始。修复：_Tee 的 write/flush 对 original 通路全部 try 吞掉（控制台输出丢了无所谓，业务走 HTTP socket 不受管道影响）；curl 直打复现不了的原因即我的管道健康。
  **② VL 解置配置面板**——选 PaddleOCR-VL 模型时（书内引擎对话框）展开"VL 解析配置"面板：文档方向分类/文档矫正/版面检测/图表识别/印章识别/图片块 OCR/合并版面块 7 个官网演示同款开关（默认=历史行为）。书级设置（project.json `settings.vl_*`），随 /read_page_text 的 `vl_config` 透传；后端 `paddle_proc.normalize_vl_config` 白名单归一，**池按（模型+VL配置）共同绑定**（改配置=换池重建，首次直读稍慢），worker 经 `PADDLE_VL_CONFIG` 注入 PaddleOCRVL 构造参数。面板带说明文案（古籍竖排推荐保持版面检测关闭——关闭时 VL 按列输出逐行文本、与行文对照对齐更好；开版面检测按版面块输出，用户可按官网实测自行实验）。
  测试：test_paddle_engine 新增 VL 配置 3 条（默认值=历史行为/白名单与 bool 归一/池签名随配置变化且 None=默认不重建），共 35 过；后端全量 **558 过**（2 存量失败）；flutter analyze 零问题、flutter test 589 过（1 存量失败）。BACKEND_BUILD v144→**v145**（tee-flush-vl-config，Dart 握手同步——Tee 修复在后端进程内，重启自动换新）。pubspec 1.0.0+199→1.0.0+200。

## 1.0.0+199

- **修复：段落反哺 `line_ids` 元素级 null 防御 + 排查"重新识别当前页报 type 'Null' is not a subtype of type 'String'"**（用户实测报错）。排查记录：本机实弹复现（v144 后端 + paddle/VL 回退路径对用户实际页面跑 /segment），真实整页响应喂给客户端解析全链路（LineBlock/MainRegion/Paragraph/CharBlock.fromJson → PageAnnotation → inferHierarchy → rebuildBlocks → 存取往返）**全部通过**（新增 3 个回归测试，带响应文件守卫、无文件环境自动跳过）；全仓扫描识别链路的严格 `as String` 转换——响应中唯一 null 字段（`fallback_reason`/`yolo.error`）均为历史字段且解析处 null 安全。防御性加固：`Paragraph.fromJson` 的 `line_ids` 元素转换 `e as String` → null 安全转换并过滤空值（整页响应 paragraphs 反哺是唯一数据触达型列表元素强转，后端数组含 null 时正是用户所见错误形态）。**未能本地复现**——请用户遇错时贴后台控制台"未捕获 Flutter 异常"的完整多行堆栈（带 package: 行号），一行即可精确定位。测试：flutter analyze 零问题、三个真实响应回归测试过。纯客户端改动，BACKEND_BUILD 不变 v144。pubspec 1.0.0+198→1.0.0+199。

## 1.0.0+198

- **新增：默认识别流程的"全文对照"——VL 单行重识别自动回退 + 每行全文直读与单字识别比对，标点等无框字符与不一致字特殊标记**（用户需求：默认流程加全文识别，全文多出/不一致的字用特殊颜色，无框字符显示在识别栏；及 VL 单行重识别报错修复）。两块：
  **① VL 单行/单字识别不再报错**——`paddle_proc.line_model()` 统一收口：PaddleOCR-VL 仅支持整页直读，行/字识别请求（`PaddleEngineAdapter` 构造处）自动回退 PP-OCRv6_small_rec，客户端保持 VL 选择（直读仍走 VL）。
  **② 全文对照（默认开，`FULL_TEXT_CHECK=0` 关）**——单行/整页识别的每行在融合完成后追加一次**整行全文直读**（新 worker op `read_line`：kraken 单矩形走既有逐行预处理+识别；paddle 行框裁图整体识别，竖排旋转 90/270 进 v5/v6 原生竖排域），与单字识别序列 `difflib` 对齐（`_align_full_text` 纯函数）：全文多出的字符（标点等像素切分天然无框的字符）记 `line.full_extras`（客户端识别栏以**紫色无框字片**展示，竖排接在字片序列尾/几何定位最后字之后，横排同理），与对位全文字符不一致的单字标 `full_diff`（客户端字片**深橙**标记，墨迹校验色优先级更高）。模型新增 `LineBlock.fullText/fullExtras`、`CharBlock.fullDiff`（JSON 只追加字段）。对照是增强路：**池未就绪绝不懒起 daemon**（首版曾致测试套件 465s/误报——已改为就绪检查+静默跳过），任何失败跳过不影响识别主流程。
  测试：新增 `_align_full_text` 3 条（标点 extras/replace 标 diff/空白忽略）+ VL 回退与超时 3 条；后端全量 **555 过**（2 存量失败与本次无关）；flutter analyze 零问题、flutter test 587 过（1 存量失败）。BACKEND_BUILD v143→**v144**（full-text-check，Dart 握手同步）。pubspec 1.0.0+197→1.0.0+198。

## 1.0.0+197

- **修复：VL 直读 300s 超时被杀（"PaddleOCR daemon 响应超时(>300s) 已重启"），文本视图残留旧模型的无标点文本造成"VL 识别不出标点"的误解**（用户实测日志：9 个 kraken daemon（k2–k9）各自占一份 CUDA 显存加载中，`[paddle-worker:p1] 等待 read_page 响应已 300s` 后被 watchdog 杀掉重启，直读 500）。VL 0.9B 首次推理含权重编译，且与 kraken 池共享显存——被挤时退 CPU/排队可达分钟级，300s 默认超时不够。**超时链路整体放宽**：后端 read_page 单请求超时 VL 场景 300s→**900s**（`PADDLE_VL_READ_TIMEOUT` 可覆写；watchdog/心跳跟随同一值），客户端 Dart 超时同步 VL 场景 10→**15 分钟**（必须不短于后端，否则先被客户端掐断）。说明：那次直读实际失败了，面板显示的是旧 small_rec 文本（v195 起状态栏会橙字提示"本书已选 VL-1.6"）——VL 本身读标点没问题（本机实测同一页 86 个标点，与官网演示一致）；显存恢复后重试即成功，模型已热后约 15-25s/页。**使用建议**：VL 与大 kraken 池（9 进程各占一份 CUDA 上下文）同机共挤显存时，可用 `OCR_KRAKEN_WORKERS` 调小 kraken 池或先重试一次（首读被挤超时、二读常已热）。后端全量 pytest 552 过（2 存量失败与本次无关）；flutter analyze 零问题。BACKEND_BUILD v142→**v143**（vl-read-timeout，Dart 握手同步）。pubspec 1.0.0+196→1.0.0+197。

## 1.0.0+196

- **修复：选 PaddleOCR-VL-1.6 整页直读报"Internal Server Error"**（用户实测：直读失败，Dart 端报 FormatException 掩盖真实原因）。三处后端根因 + 一处客户端呈现，全部修完并实测全链路跑通：
  **① `PaddleOCRVLBlock` 对象误当 dict**——真实管线返回的 `parsing_res_list` 元素随取用路径不同而是 dict（json 序列化）或 PaddleOCRVLBlock 对象；v193 的提取代码统一 `.get()` 直接 AttributeError（用户所见 500 的直接原因）。新增 `_vl_block_content` 两条路径都兼容。
  **② 对象属性名是 `content` 不是 `block_content`**——`block_content` 是 JSON 序列化后的字段名，对象直取时叫 `content`；首次兼容只认 `block_content` 导致提取 0 行（静默失败比报错更隐蔽）。两个名字都认。
  **③ VL daemon 的几何管线档位推导崩溃**——VL 模型名没有 `_rec` 后缀，`_get_pipeline()` 拼出 `PaddleOCR-VL-1.6_det` 不存在 → UnknownModelError。VL daemon 固定用 small 档 det+rec 定行框（行文本由 VL 给出，rec 结果丢弃）。
  **④ 客户端错误体解析顺序**——`readPageText` 先 `jsonDecode` 再查状态码，后端未捕获异常时 uvicorn 返回纯文本 "Internal Server Error"，FormatException 把真实状态/响应体盖掉。改为先查状态码、非 JSON 体原样透出"整页直读失败（HTTP 500）：Internal Server Error"。`_vl_result_dict`/`_vl_read_page` 增加 json 通道失败与提取落空的诊断日志（后端控制台可见结果对象形态）。
  **e2e 实测**（用户实际页面 page_005）：行/字 op 明确拒绝 ✓；VL 文本 17 行带标点 ✓；混合直读 22 行、逐行带标点（mark stats 显示 text punct=4/7/…）✓；阅读序正确。后端全量 pytest 552 过（2 存量失败与本次无关）；flutter analyze 零问题。BACKEND_BUILD v141→**v142**（vl-readpage-fix，Dart 握手同步——重启应用自动换新后端）。pubspec 1.0.0+195→1.0.0+196。

## 1.0.0+195

- **修复：文本视图状态栏分不清"本书配置的模型"和"实际读出文本的模型"**（用户反馈：选了 PaddleOCR-VL-1.6，状态栏仍显示"引擎 PaddleOCR（PP-OCRv6_small_rec）"，不知道自己在用什么、看到的文本是谁读的）。两层修复：
  **① 状态栏如实区分两个概念**——直读落盘新增元数据侧车 `<direct_text>/<pageId>.meta.json`（engine/ocr/耗时/行数/时间），状态栏有记录时显示"**文本由 X 识别**"（X = 实际产出该文本的引擎/模型，从后端返回的 `ocr` 字段如 `paddle+PP-OCRv6_small_rec` 解析）；无记录（老文本）维持"引擎 X"（本书配置）。
  **② 改了模型没重读时橙字提醒**——实际产出与本书当前选择不一致（引擎或模型改过、旧文本不会自动重读）时，状态栏追加橙字"⚠ 本书已选 Y，点「重新识别」用新模型重读"。Kraken 的识别模型固定（chat_rec），只比引擎不比模型。
  说明（非 bug 的行为确认）：设置页"AI 辅助设置"里的 Paddle 默认档只影响**新建任务**的初始选择；已建书籍用各自的设置（编辑器「页面操作 → 识别引擎（本书）」里改），改完要点「重新识别」才用新模型读当前页。使用手册同步。
  测试：flutter analyze 零问题、直读存储相关测试过。纯客户端改动，BACKEND_BUILD 不变 v141。pubspec 1.0.0+194→1.0.0+195。

## 1.0.0+194

- **改进：模型选项标题显示真实模型名**（用户反馈：设置页 PaddleOCR 模型卡只显示"极轻量/小模型/中等"这类昵称，看不出用的到底是哪个模型）。`PaddleModelChoice` 新增 `displayLabel`（`模型名 · 昵称`，如 `PP-OCRv6_small_rec · 小模型（蒸馏）20.4MB · 默认`、`PaddleOCR-VL-1.6 · 视觉语言模型 0.9B · 古籍最强`），AI 辅助设置模型卡、书内引擎对话框、任务向导的模型选项标题与下载结果提示统一改用；顺带修正卡片脚注过时的"下载约 4~73MB"（现在 4MB~73MB，VL 档约 1.9GB）。纯客户端改动，BACKEND_BUILD 不变 v141。测试：flutter analyze 零问题、设置页相关测试过。pubspec 1.0.0+193→1.0.0+194。

## 1.0.0+193

- **新增：Paddle 模型选择加入 `PP-OCRv3_mobile_rec`（v3 轻量档）与 `PaddleOCR-VL-1.6`（0.9B 视觉语言模型）的下载与选择**（用户需求）。后端目录（paddle_proc.PP_OCRV6_MODELS 5 档，默认仍 v6_small）、设置页模型卡、任务向导/书内引擎对话框同步。
  **① PP-OCRv3_mobile_rec（9.8MB）**：老一代轻量档（2022），CPU 可跑、精度低于 v5/v6；整页直读不支持竖排（v5 起原生支持），配置要求文案注明"适合横排书籍或引擎对照"。配对检测模型 `PP-OCRv3_mobile_det` 走现有 `tier+"_det"` 逻辑自动成立，行/字识别走现有 TextRecognition 路径零改动。
  **② PaddleOCR-VL-1.6（0.9B，下载约 1.9GB）——古籍直读质变**：实测用户实际页面（page_005）**标点 86 个 vs PP-OCRv6 的 3 个**（此前诊断的"古籍小号标点被整行识别系统性跳过"在 VL 上原生解决），竖排/复杂版式同样更强。约束：仅整页直读（文本视图）可用——行/单字识别 op（recognize/read_boxes/read_strip）被 worker 明确拒绝（中文提示"仅支持整页直读；行/单字识别请选 PP-OCR 系"）；需 NVIDIA 独显（建议 ≥8GB 显存）；CPU 极慢。**直读为混合方案**：VL 只出块级 bbox（无逐行坐标），故用"VL 读文（无版面模式按列分行、带标点）+ PP-OCR det 定行框"，`_vl_merge_texts` 把 VL 分行文本（去标点）与 PP-OCR 行按相似度对齐换装（行框几何准、行文本带标点；对不上的 VL 行贴邻行保文本、PP-OCR 多余行如页码保留原文）。标记 stats 标点诊断对 VL 直读照常输出，可量化对比。
  **③ 环境与缓存健壮性**：VL 管线需要 `paddlex[ocr]` extra（bs4/einops/tokenizers 等 14 个轻量包）——已装进本机 paddleocr 环境、安装脚本 install_paddleocr.bat 同步追加；直读构造 VL 管线时关闭文档朝向/矫正/图表/印章/版面检测旁路（直读只要逐行文本，也省版面模型）。半截缓存自愈：paddlex 对"目录存在但缺 inference.yml"的中断下载不再重下、直接报"无有效模型文件"（实测踩坑：1 月一次失败的 PaddleOCR-VL 下载留空壳目录，另 PP-DocLayoutV2 目录 ACL 损坏连读都拒绝）——`downloaded_models` 改为"带模型配置才算已下载"，`download_model` 先删该模型的半截目录再走全新下载（坏 ACL 目录改名隔离由用户侧处理）。
  测试：test_paddle_engine 29 过（新增 VL 混合对齐 4 条：带标点文本换装/未匹配几何行保留/未匹配 VL 行不丢文本/无几何行零框兜底；目录 5 档含 VL"仅整页直读"文案；下载扫描改半截目录不算）；e2e：真实 VL 输出+真实 PP-OCR 几何走通 `_op_read_page` 全链路（22 行 86 标点、阅读序正确），行/字 op 拒绝路径实测（显存争用环境下 VL 实机推理超时改由桩验证代码路径；首次实测 GPU 推理 15.6s/页）。后端全量 552 过（2 存量失败与本次无关）；flutter analyze 零问题、flutter test 587 过（1 存量失败）。使用手册识别引擎/标点局限节同步。BACKEND_BUILD v140→**v141**（paddle-v3-vl，Dart 握手同步）。pubspec 1.0.0+192→1.0.0+193。

## 1.0.0+192

- **修复：后端控制台被两股日志洪水刷屏（+191 让服务 stdout 实时可见后暴露）**——① uvicorn 访问日志：App 每 3 秒轮询两次 `/process_stats`，每请求一行 `INFO: ... "GET /process_stats" 200 OK` 刷屏；② Windows Proactor 良性断连噪音：每个轮询连接关闭时 `_ProactorBasePipeTransport._call_connection_lost` 对已关闭 socket 再 shutdown 抛 WinError 10022（CPython 已知问题、无害），asyncio 默认处理器整段 traceback（7 行栈）打到 stderr。两股此前一直存在，只是被 conda 缓冲遮住。修复：① `uvicorn.run(access_log=False)`（请求计时 App 客户端侧已自带 `[http]` 日志；500 的 traceback 走错误日志不受影响）；② 自装 asyncio 异常处理器 `_quiet_connection_lost`（api_base，lifespan 里注册到 uvicorn 的事件循环）——只静默"_call_connection_lost + WinError 10022"这一类，其余异常照走默认处理器。端到端复验（conda --no-capture-output 拉起 + 6 次断连轮询 + 直读）：访问日志 0 行、10022 噪音 0 行、`[paddle-worker]` mark stats 标点诊断 20 行照常实时流出。测试：test_kraken_daemon 新增 3 条（良性噪音被吞/其它 WinError 转发/其它回调转发），后端全量 548 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关）；flutter analyze 零问题。BACKEND_BUILD v139→**v140**（console-noise，Dart 握手同步）。pubspec 1.0.0+191→1.0.0+192。

## 1.0.0+191

- **修复：后端服务的 stdout 日志在应用控制台整段不可见（含 worker 透传日志）**（用户实测：v139 后端在跑、直读成功，控制台仍无任何 `[paddle-worker]` 行；对照发现控制台里 `[app]`/`[http]` 全是应用侧日志，服务进程的行一条都没有）。根因：应用用 `conda run -n paddle python main.py` 启动后端，而 **`conda run` 默认捕获子进程 stdout、缓冲到命令结束才整体吐出**（本机实测：Python 立刻打印的 LINE-A 与 3 秒后的 LINE-B 同一时刻才到达管道）——服务全部 stdout（uvicorn 日志、worker 透传的 mark stats 标点诊断等）被扣在 conda 缓冲里，进程不退出就永远看不到。修复：启动命令加 **`--no-capture-output`**（实测 LINE-A 立刻、LINE-B 3 秒后到达，逐行实时）；`run_backend_console.cmd`（独立控制台窗口模式，同样吃这个缓冲）一并加。端到端验证：与 App 同款命令拉起后端 + `POST /read_page_text engine=paddle`，26 条 `[paddle-worker:p1]` 日志（模型加载、page read done、mark stats 逐行明细与整页汇总 `text puncts=3, mark-like blobs≈266, read ratio 1%`）全部实时流出。纯客户端/启动脚本改动（后端 Python 零改动，BACKEND_BUILD 不变 v139）；flutter analyze 零问题。pubspec 1.0.0+190→1.0.0+191。

## 1.0.0+190

- **修复：worker 进程日志（含直读标点诊断 mark stats）在后端控制台不可见**（用户实测：v138 后端已运行、直读成功返回 22 行，但控制台没有任何 `[paddle-worker:...]` 日志）。根因在 `kraken_proc._KrakenDaemon._start()`：spawn worker 时 `stderr=None`（继承父进程句柄），而下方 `_stderr_reader` 透传线程读的是 `proc.stderr`——继承模式下它恒为 **None**，线程首行即 AttributeError 被吞、静默死掉，worker 的全部 tlog 进度日志（模型加载耗时、strip read、page read done、mark stats 标点统计等）从未进入转发管道，与类文档注释"stderr 由读线程收取后 print 透传"的设计相悖（引擎参数化改造时的遗留笔误）。修复：`stderr=subprocess.PIPE` 一行，透传线程随即按设计工作。迷你 worker 实测：启动 1.5 秒内 stderr 日志行即透传打印。测试：后端全量 545 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133）；flutter analyze 零问题。BACKEND_BUILD v138→**v139**（worker-stderr-fwd，Dart 握手同步）。pubspec 1.0.0+189→1.0.0+190。

## 1.0.0+189

- **新增：Paddle 整页直读的标点诊断日志**（用户要求：增加日志分析为什么没识别出标点——实测文本 3 个标点 vs 标注存档约 140 个/页）。`paddle_worker._op_read_page` 在直读完成后对每个 det 行框裁图做连通域统计（cv2），把「文本里读出的标点数 vs 图上检出的**小墨块数**（高度 < 0.6×中位字高的连通域，即疑似被识别模型跳过的古籍小号句读/圈点）」打进后端日志：逐行 `mark stats line N/22: 27 chars, text punct=0, mark-like blobs≈17 (model likely skipped ≈17)`，整页汇总 `mark stats: 22 lines, text puncts=3, mark-like blobs≈266 (19 lines dropping), read ratio 1%`（用户实际页面 page_005 实测输出）。只记日志、不改识别结果；cv2/PIL 缺失或图异常时诊断降级跳过、绝不影响识别路径。测试：test_paddle_engine 新增 3 条（合成竖排列 8 字 + 3 标点检出 3；过小裁图返回 None；标点集合覆盖常见中文标点），后端全量 545 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133）；flutter analyze 零问题。BACKEND_BUILD v137→**v138**（paddle-punct-diag，Dart 握手同步——诊断日志在 worker 内，需换新后端才可见）。使用手册「标点局限」条补诊断日志说明。pubspec 1.0.0+188→1.0.0+189。

## 1.0.0+188

- **改进：「文本」视图行文对照小字改用高亮色 + 查明 Paddle 直读丢标点的原因并由 AI 校对补标点**（用户实测：Paddle 直读通篇几乎无标点；对照小字黑色不显眼）。两项：
  **① Paddle 直读丢标点＝识别模型能力盲区（非 bug，参数不可救）**——实测铁证：该页标注存档（人工校对）含约 140 个标点/页，Paddle 直读仅出 3 个；用标注几何比对发现古籍句读/圈点是**印在字间空隙里的小号符号（约 0.4 字高）**，det 行框其实包住了它们，但 PP-OCRv6 识别模型按现代排版（标点与正文字同高）训练，整行识别时系统性跳过这类小符号。逐一实测排除：加大检测框外扩 `text_det_unclip_ratio` 1.4→2.5 仅 +2 个、提高分辨率/2x 放大无效（rec 按行高归一化后相对大小不变）、三字上下文窗口只救回首尾标点、小符号单独抠图放大反而被读成数字"0/9"。也试做了"连通域抠小符号→紧排重组条识别→按墨迹位置插回"的整页原型：召回可达 ~88/140 但碎片误判产生"，，，"连串、位置 ±1-2 字漂移，精度不可靠，**不采纳**（宁缺毋滥）。应对：AI 校对提示词内置补标点指令——"OCR 文本整行/整页几乎没有标点时按文意用标准中文标点断句补全，已有标点保持原样"（LLM 古文断句是强项，直读流程本就带 AI 校对）；使用手册「整页直读」节新增「标点局限」说明（含"忠实还原印刷标点请走标注管线单字识别"指引）。
  **② 行文对照小字改高亮色**——对照字片文字从黑色改为**按行序轮换的彩虹高亮色**（同一行同色、相邻行异色），与编辑器单字框同一套颜色语义；字片描边同色（原主题色描边移除）。色板 `kCharRainbow`/`charRainbowColor` 从 editor_page 抽出至 `widgets/char_rainbow.dart` 共享（editor_page 与 line_reseg_page 改引共享文件，页面间互相 import 解除）。
  测试：flutter analyze 零问题；flutter test 全量 587 过（tool_export_crowd_tasks 为无头环境存量失败；ink_align_features 旋转容差断言为偶发——单测重跑一次过一次挂，随机噪声临界，与本轮无接触面）；后端零改动（BACKEND_BUILD 不变 v137）。使用手册同步。pubspec 1.0.0+187→1.0.0+188。

## 1.0.0+187

- **修复：点「整页文本（直读）」按钮闪退**（用户实测：`segmented_button.dart` 断言 `selected.length > 0 || emptySelectionAllowed` 不成立、应用异常退出）。v186 把视图分段按钮改为文本模式下传**空选中集**（四个标注分段都不选），但漏了 SegmentedButton 的 `emptySelectionAllowed: true` 参数——Flutter 断言要求空选中必须显式允许。一行补上。测试：flutter analyze 零问题、相关 Dart 测试过（+186 的工具栏改动无其他回归面）。纯客户端改动，BACKEND_BUILD 不变 v137。pubspec 1.0.0+186→1.0.0+187。

## 1.0.0+186

- **修复：切到 PaddleOCR 引擎做行重识别时的两类问题——界面报"RenderFlex overflowed by 11 pixels"红条 + 换模型时请求被卡几十秒**（用户实测 14:48-14:50：先后两次行重识别各耗时 66.9s/37.3s，期间应用两次抛未捕获溢出异常；后端日志还原全程）。后端两处 + 前端一处：
  **① 编辑器工具栏溢出（用户所见"报错"本体）**——v184 给视图 SegmentedButton 加的第 5 个「文本」分段挤爆了工具栏宽度（240px 面板内实测右溢 11px，调试模式渲染为红黑条纹，被当成识别报错）。修复：分段按钮恢复四档（主区/段/行/详细），「文本」视图改为分段下方**整宽独立按钮**（进入后变为「退出文本视图」FilledButton；文本模式下分段不选中）。
  **② 换模型被正在加载的旧 daemon 卡死几十秒（根因）**——`_KrakenDaemon.request()` 全程持锁（首载含模型下载，实测 small 档 ping 62.6s），池重建时 `old.shutdown()` 用 `with self._lock` **无限等锁**：14:49:18 的行重识别想换 small→medium 池，被在载 small 的 daemon 等锁卡到 14:49:54 加载完才放行。修复：`shutdown()` 改**限时拿锁（15s）**，拿不到直接强杀——加载中途被杀无害（该进程不再接客，新成员重新加载）。kraken 激活/重建池路径同样受益。
  **③ paddle 换池的旧池关停放后台线程**——`paddle_proc.ensure_pool` 此前在请求线程里同步 `old.shutdown()`（排空+成员关闭），叠加 ② 最坏可拖几十秒；改后台线程关旧池，换模型立即返回新池等待。
  顺带确认（非 bug，使用提示写进使用手册）：Paddle 首次用某档要下载模型（small 20.4MB 实测 62.6s、medium 73.3MB；已缓存后加载仅 ~5s）；每本书/每次探测切换模型 = 池重建重载，建议先在设置页「PaddleOCR 模型」卡预下载好再用。当日日志里两次行重识别最终都成功返回（34 字，dual-read both×28）。
  测试：后端全量 542 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133 注记）；`import main` 冒烟 OK；flutter analyze 零问题；flutter test 全量 587 过（唯一失败 tool_export_crowd_tasks 为无头环境存量）。BACKEND_BUILD v136→**v137**（paddle-pool-switch，Dart 握手同步，重启应用自动替换旧后端）。使用手册识别引擎节补换模型重建池注记。pubspec 1.0.0+185→1.0.0+186。

## 1.0.0+185

- **修复：「文本」视图行文对照的字片过大、遮住邻列文字且与书页文字没对齐**（用户实测截图：字片约与列等宽，盖住相邻列；字位按整列高度粗放均分，与页面字形错位）。纯客户端改动，三点收敛：
  **① 字号缩小**——竖排对照字号从 0.92×列宽降到 **0.45×列宽**（片宽 1.2×字号），横排从 0.8×行高降到 **0.55×行高**（钳 9~26px）：小字对照，视觉上明确退居书页文字之后。
  **② 不遮正文/邻列**——竖排字片右缘**贴列框左缘**（只占列间空隙，不再伸进列内）；页面最左列左缘越界时收紧贴边（x 钳到 ≥0，不向右侵入本列正文）。
  **③ 逐字对齐书页文字**——新增逐字框数据通道：`_LineRecord.charBoxes`（kraken 直读行本就带 cuts 重建的逐字框，此前丢弃未用），有字框时每个字片**中心对准对应字框中心**（字号仍受"均分列高也挤不下"约束兜底，超长读法自动缩字）；paddle 直读行无逐字框，按列高均分对齐（det 框贴合文字时近似逐字对齐）。字片高度取 min(字位高, 1.3×字号)。
  测试：flutter analyze 零问题；相关 Dart 测试全过（flutter test 全量 587 过，唯一失败 tool_export_crowd_tasks 为无头环境存量，与本次无关）；后端零改动（BACKEND_BUILD 不变 v136）。使用手册行文对照描述同步。pubspec 1.0.0+184→1.0.0+185。

## 1.0.0+184

- **改进：「文本」视图重排为左右分栏——左侧书页栏（保留校对的页图对照）+ 右侧文本栏，书页旁可叠加显示每行识别文本（带开关）**（用户需求：保留书页栏、画面中心对半、书页用现有展示方案但不显示识别框、可在书页文字旁显示该行识别文本并可开关）。纯客户端改动：
  **① 左右分栏**——DirectTextPanel 重构为 `Row` 对半布局：左侧**书页栏**沿用标注画布同款展示方案（`instantiateImageCodec` 解码位图 + `RawImage`、缩放平移、首帧整页适配留 4% 边距、换页/退出释放纹理），**不画任何识别框/标注**；右侧**文本栏**保留原有全部功能（识别本页/重新识别、可编辑文本框、AI 校对、保存/复制、引擎与行数状态行）。
  **② 行文对照叠加（新）**——书页栏顶部「行文对照」开关（默认开）：把 `/read_page_text` 返回的每行识别文本画在书页对应行旁——**竖排行逐字竖排**在列框左侧的列间隙里（字号取 min(列宽×0.92, 行高/字数)，与页面自身版式一致、天然不遮正文；页面最左列越界时退到框内左侧；字位 <6px 的碎片行不画避免糊成噪点），**横排行**整行画在行框下方；每字/整行带半透明白底圆角片 + 主题色描边，页面底纹上可读。文本栏**编辑实时同步**：按行号逐行更新叠加文本（行数一致时；增删过行保持识别原文不做错位同步），同步走 `ValueListenable` 只重画叠加层、不重建面板（文本框每键触发）。
  测试：flutter analyze 零问题；flutter test 全量 587 过（唯一失败 tool_export_crowd_tasks 为无头环境存量，与本次无关）；后端无改动（BACKEND_BUILD 不变 v136）。使用手册「整页直读」节同步分栏与行文对照说明。pubspec 1.0.0+183→1.0.0+184。

## 1.0.0+183

- **修复：「文本」视图整页直读用 Kraken 引擎必失败——"Kraken worker 失败: 'TorchVGSLModel' object has no attribute 'codec'"，且直读文本几乎全空**（用户实测 GujiBT 某书源图 b4715f1c（284×627 竖排 6 列）点「识别本页」即 500）。两处根因与修复：
  **① 分割模型加载方式错误（报错的直接原因）**——`_op_read_page` 用 `kraken.lib.models.load_any` 加载 `chat_seg.mlmodel`，而本环境 kraken 7.1.1 的 `load_any` 只适用于**识别**模型：无条件包 `TorchSeqRecognizer` 并取 `nn.codec`，分割模型没有该属性 → AttributeError。修复：分割模型改用 `TorchVGSLModel.load_model`（`blla.segment` 内部默认模型同款加载方式，已实测 chat_seg 元数据合法：model_type=segmentation、含 class_mapping）；`blla.segment` 参数名纠正为 `model=`（原误写 `load_model=`）、按书方向传 `text_direction`（竖排列旋转后进识别网络，桥接层经 payload 下发）；kraken 7.1 的 `Segmentation` 是 dataclass，取行改 `seg.lines`；blla 弃用告警（kraken 8 移除，替代 `SegmentationTaskModel`）就地抑制并注记。
  **② 整页直喂 rpred 读不出字（修完 ① 后暴露）**——原实现把原始灰度整页 seg 直接交 `rpred.rpred`，CHAT 模型要求"窄轴 ≥100px 定倍 + 逐行局部 nlbin"（`_prepare_line` 既有结论），欠放大未二值化的整页读出 28 行几乎全空（32 字符）。修复重构：**blla 只负责检测**（行框 = boundary 多边形外接矩形），每行交与标注管线完全同款的 `_per_line_pipeline` 逐行预处理路径（裁剪/定倍/nlbin/rpred/cuts，空白行有既有保护）。另发现 blla（chat_seg 与 kraken 默认模型皆同）在竖排小图上把一列拆成**单字级碎片**（实测该页 28 片、片高 15~42px≈单字，放大 2~4 倍不恢复）——新增 `_merge_line_rects_by_band` 带状合并：按列中心贪心聚簇（容差=列宽中位数一半，与 page_text 分列同款启发）取联合框还原整列，交 CHAT 读整列语境。修复中顺带修掉合并函数的聚类基准 bug（误用全局累计均值而非当前簇运行均值，致第二簇起永不合并，实测 27 片只并成 25）。
  真图端到端验证（kraken 环境实跑该源图）：修复前 codec 500；中间版 28 行 32 字符几乎全空；修复后 5 条整列、42 字符，含"詣佛各於弟子衆中歎""名字皆悉踊躍來生我國"等与页面内容吻合的整列读法，RTL 列序正确。残留已知限制：右侧小字注释列与正文列在被 blla 碎片化后可能并成一带（首列读法混入注释字），小图直读质量以 PaddleOCR 全管线为佳（det+rec 原生竖排），Kraken 直读为引擎可选兜底。
  测试：test_page_text 新增 KrakenBandMergeTests 5 条（竖排碎片并整列、相邻列不并、**簇均值回归**（防全局均值 bug 复发）、横排按 y 并行带、单框/空透传）；后端全量 542 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133 注记）；`import main` 冒烟 OK；flutter analyze 零问题（Dart 仅同步握手串）。BACKEND_BUILD v135→**v136**（direct-read-kraken，worker 代码修复需重启后端生效，Dart 握手同步后应用会自动替换旧后端）。pubspec 1.0.0+182→1.0.0+183。

## 1.0.0+182

- **新功能：① 应用内更新日志——本版本更新内容就地可看、一键复制 GitHub 发布说明**（用户需求）。「AI 辅助设置 → 说明 → 更新日志」新入口：按版本分节展示项目根 `CHANGELOG.md`（第一条即当前版本，带「本版本」徽标，默认展开），每节可单独复制，页顶「复制本版本 / 全部」一键取 markdown——上传 GitHub 时直接贴进 Release 发布说明。实现：`changelog_service.dart`（`## ` 分节解析纯函数 + 路径探测：python_service 上级（开发=仓库根 / 安装版=安装目录）→ exe 同级 → exe 上级；CRLF/首尾空行兼容、节内空行保留）+ `changelog_page.dart`（ExpansionTile 列表 + 复制反馈）；安装脚本把 CHANGELOG.md 放进安装目录（`skipifsourcedoesntexist`），找不到时页面降级提示。
- **新功能：② 整页直读「文本」视图——Paddle/Kraken + AI 校对，不拆主区/段落/单行/单字**（用户需求：直接显示该页识别内容的文本框，书籍校对界面可切换）。四部分：
  **① 后端直读**——新端点 `POST /read_page_text`（`engine`/`paddle_model`/方向参数 → `{text, lines, engine, ocr, elapsed_s}`，`_gated_recognition` 保护）。Paddle：`paddle_worker.py` 新 op `read_page`，懒建 det+rec 完整管线（检测模型跟随识别档位 `PP-OCRv6_<tier>_det`，首次自动下载；PP-OCRv5 起原生支持竖排检测+识别，页面不旋转），`rec_boxes` 优先/`rec_polys` 外接框兜底。Kraken：`kraken_worker.py` 新 op `read_page`，blla 分行（`chat_seg.mlmodel` 首次直读懒加载常驻）+ rpred 读字，boundary 多边形外接框。两引擎都返回**未排序**行列表，阅读序由新模块 `page_text.py` 统一重排：竖排按 x 中心**贪心聚列**（容差半个列宽中位数，容忍检测框列中心抖动、列距不均）→ 列按 rtl/ltr → 列内 y 按 ttb/btt；横排聚行同理；btt/rtl 行内文本反向——纯函数可测。两引擎共用同一排序/拼接，行为一致。
  **② 编辑器「文本」视图**——右侧视图切换加「文本」档（主区/段/行/详细/文本）：主体换成 `DirectTextPanel`——「识别本页/重新识别」（本书当前引擎）→ 可编辑整页文本框 →「AI 校对」→「保存/复制」；识别结果即时落盘、编辑手动保存；翻页按 pageId 换 key 自动换内容。不依赖本页已有标注（未识别过的页也能直读）。落盘 `<书目录>/direct_text/<pageId>.txt`（原子写，与页标注 JSON 完全解耦：重识别/标注保存互不影响，也不进训练数据/导出）。
  **③ AI 校对**——`OllamaService.proofreadPageText`：优先视觉模型带整页原图（页图读不出退化为纯文本），prompt 按古籍校对口径（异体字/繁体保持原样、无把握不改、不增删行、行数与输入一致），JSON 输出解析含 ``` 围栏剥离，失败不丢 OCR 原文；结果预览对话框（可选中复制）后自行「采用（替换文本框）」；走「AI 辅助设置」的推理来源/限流/追踪（10 分钟超时、按 2 token/字预算钳 8192）。
  **④ 客户端**——`PythonService.readPageText`（10 分钟超时，首载检测模型提示）；BACKEND_BUILD v134→**v135**（direct-text，Dart 握手同步）。
  测试：新增 `test_page_text.py` 10 条（竖排 rtl/ltr 列序与列内序、列抖动不拆列、相邻列不并列、btt 行内反向与列内倒序、横排行序/行内序/行抖动、空输入、逐行拼接）；新增 `changelog_and_direct_text_test.dart` 7 条（CHANGELOG 分节/CRLF/空行/GitHub 格式、DirectTextStore 往返/覆盖/空文本落盘/分页隔离）；后端全量 537 过、`import main` 冒烟 OK（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133 注记）；flutter analyze 零问题、flutter test 587 过（唯一失败 tool_export_crowd_tasks 为无头环境存量）。文档：README（新版首页结构）功能特性补双引擎与文本视图一句；详细说明写入 `docs/使用手册.md`（新增「整页直读」「更新日志」两节，识别引擎节为 v180/v181 迁移内容）。pubspec 1.0.0+181→1.0.0+182。

## 1.0.0+181

- **新功能：设置页「PaddleOCR 模型」卡——模型说明、逐档下载与默认档选择**（用户需求：设置界面中添加 paddle 的模型下载和说明，并且可选择使用哪个模型）。三部分：
  **① 后端**——`/paddle/status` 响应新增 `downloaded`（已下载模型名清单）：`paddle_proc.downloaded_models()` 纯磁盘扫描官方缓存（`<缓存根>/official_models/<模型名>/` 非空目录，缓存根候选 `PADDLE_PDX_CACHE_HOME` 环境覆写 > `~/.paddlex` > `~/.paddleocr`），不起 daemon、环境未装也能回答哪些档已就位。新端点 `POST /paddle/download`：`download_model()` 用**一次性临时 daemon** 加载指定模型（首载自动下载到官方缓存）后即关——与 `/paddle/probe` 的区别是 probe 会把池重绑到该模型（切走正在用的档位），download 不影响现有池，专为设置页逐档预下载；已下载时等价一次加载自检（数秒），返回 `was_cached` 供 UI 区分"下载完成/自检通过"。
  **② 设置页（AI 辅助设置，识别进程数卡之后）**——新卡：环境状态行（就绪/未装给安装指引/后端未连降级提示）+ 三档模型列表（每档 ListTile：标题=档名与体积、副标题=电脑配置要求说明、行尾=已下载 ✓ 或「下载」按钮（逐档独立转圈态，完成后 SnackBar 回报设备与耗时并刷新状态）、点选行即设**默认档**）+ 尾注（默认档只影响新建任务初始选择，每本书在编辑器「识别引擎（本书）」单独覆盖）。默认档落 `OllamaSettings.paddleModel`（SharedPreferences `ollama_settings_v1` 追加 `paddle_model` 字段，未知/历史脏值归一默认小档，与后端 `normalize_model` 同口径）；新建任务页的 Paddle 档位预填此全局默认（用户已手动改过则不覆盖，与 AI 整行开关同款快照语义）。
  **③ 客户端 API**——`PythonService.paddleDownload(model)`（超时 15 分钟）；设置页进页后台拉一次 `/paddle/status`（失败静默降级）。
  测试：test_paddle_engine 新增 4 条（official_models 目录扫描：非空目录算已下载/空目录不算；缓存根候选含环境覆写与默认 home；download_model 用临时 daemon ping 后即关且不碰池、spawn 参数与 was_cached 语义；未知名归一默认）；新增 ollama_settings_paddle_test 4 条（默认值/fromJson 读回与脏值归一/toJson 往返/copyWith 保持与归一）；后端全量 527 过（test_seg_layout/test_layout_analysis 2 条存量失败与本次无关，见 v132/v133 注记）；`import main` 冒烟 OK；flutter analyze 零问题。BACKEND_BUILD 不变 v134（新增端点向后兼容，旧客户端不调用）。README「识别引擎」节补设置页卡与 `/paddle/download`。pubspec 1.0.0+180→1.0.0+181。

## 1.0.0+180

- **新功能：接入 PaddleOCR（PP-OCRv6）作为可选识别引擎——每本书可选 Kraken 或 Paddle，Paddle 可选模型档位（默认 PP-OCRv6_small_rec 20.4MB 蒸馏小模型）**（用户需求）。识别引擎只负责"读字"：版面/行/字框仍由自训 YOLO + 像素切分器给出，两路读法对齐融合管线完全复用。四部分：
  **① 后端引擎接入（完全镜像 kraken 的"独立 conda 环境 + 常驻 worker 子进程 + 单行 JSON 协议"隔离模式）**——新环境 `paddleocr`（`install_paddleocr.bat`：GPU 默认 cu126 轮子（官方 paddle 包源），`PADDLE_PADDLE=cpu` 装 CPU 版；应用内环境准备页也有「安装 PaddleOCR 引擎」卡）。新文件：`paddle_worker.py`（daemon：`TextRecognition(model_name=...)` 加载，cuda→cpu 回退；**不做 nlbin 二值化**（PP-OCR 期望原始灰度）；三个识别 op——横排行直读 / `read_boxes` 单字框批量直读 / `read_strip` 竖排整行"字框裁剪→等高拼横条"读）；`paddle_proc.py`（`_KrakenDaemon/_DaemonPool` 参数化复用 + 模型清单与归一 + 按模型绑定的懒建池：不预热、默认 1 成员、`OCR_PADDLE_WORKERS` 覆写钳 1..4、换模型自动关池重建）；`paddle_bridge.py`（`PaddleEngineAdapter`：横排直读/竖排无域跳过/strip 补读/均分条带兜底 `paddle-even-strips`；整行读法文本按阅读轴均分合成 kchars 几何仅供对齐与兜底）。kraken_worker 协议里 kraken 专属 env（`KRAKEN_WORKER_ID/KRAKEN_REC_MODEL`）从 `_start` 挪到 `_spawn_daemon` 构造处注入，daemon/池消息按引擎标签化（kraken 文案逐字不变），池重试判定从文案匹配改为 `WorkerFailure` 类型（RuntimeError 子类）。
  **② 关键工程决策：PP-OCR 识别模型只有横排域**（竖排行直接旋转会把直立字形放倒、读出乱码）——竖排整行序列读法由 `read_strip` 用"逐字裁剪拼横条"实现（拼条内字形全部直立、落在模型分布内），与逐字读法构成互相独立的第二路，融合/标点拆分/噪声过滤/错位重建全复用；**横排反而增强**：Paddle 横排整行可直读（CHAT 无横排域，Kraken 时代横排只有逐字读法）。
  **③ kraken_bridge 引擎适配器缝（kraken 链路零差异是硬门槛）**——`apply_kraken_recognition`/`kraken_segment_line` 提出引擎无关核心 `apply_recognition`/`segment_line_core`（原函数名与签名保留为薄包装），引擎触点集中到 adapter（整行读法与横/竖可达性、逐框读法、兜底字框来源、char.source/ocr 标记、池规模）；`_fuse_line_chars` 的硬编码 source 参数化、`_pair_boxes_with_seq` 的错位重读走 adapter。竖排 Paddle 管线顺序为"先切分(n=0)→strip 序列补读→逐字读→融合"（Kraken 是"先读法定字数→切分"），在 `_line_task` 内按 adapter 策略分支。
  **④ API 与客户端**——请求模型只追加字段：`/segment`、`/segment_region`、`/segment_lines_in_region`、`/recognize_char` 加 `engine`（默认 `kraken`，老客户端行为不变）与 `paddle_model`；响应 `recognition_engine`/`ocr` 如实回显（如 `paddle+PP-OCRv6_small_rec`）。新路由 `/paddle/models|status|probe|pool/resize`（probe 即"下载/测试模型"按钮后端：建池+ping，首载含官方源下载，宽超时 900s）。模型清单三档带**配置要求文案**（tiny 4.4MB CPU 即可 / small 20.4MB 默认·CPU 可跑入门独显流畅 / medium 73.3MB 建议 ≥4GB 显存独显），客户端 `engine_settings_section.dart` 与后端 `paddle_proc.PP_OCRV6_MODELS` 互为镜像（字段基线在后端，只追加不改名）。选择位置：**每本书**——新建任务页「识别引擎」卡片 + 编辑器「页面操作 → 识别引擎（本书）」随时切换（写 `project.json` 的 `settings.engine/paddle_model`，`ProjectSettings.engine` 恢复真实读写并新增 `paddleModel`，下次识别生效、已确认标注不受影响；引擎为书级设置，不做页级覆盖）；编辑器单字重识别带书级引擎。`SetupSnapshot` 新增 `paddle` 状态（PaddleEnvStatus）但 **ready 门槛不变**（Kraken 仍必装，Paddle 可选——选它的书识别时后端报带安装指引的错误）。
  测试：新增 `test_paddle_engine.py` 18 条（模型清单/归一、合成 kchars 竖横排、适配器能力标记与 worker 请求构造（横排直读/read_boxes 边距/read_strip 拼条请求）、请求字段默认值=kraken、/segment 与 /recognize_char 的 engine 分发断言 kraken 调用面不变）；kraken 链路回归 test_kraken_fusion/daemon/pool_control/worker_empty/seg_kraken_cuts/seg_lines/region_gate 115 全过（零差异）；后端全量 522 过（test_dynasty_bench 1 条因新握手串含 "engine" 子串误伤脆弱断言，已改为按字段检查——历史摘要仍不含 per-case engine/ai_assist，语义不变；test_seg_layout/test_layout_analysis 2 条为 v92/v132/v133 已注记的存量基线失败，与本次无关）；`import main` 冒烟 OK（BACKEND_BUILD v133→v134 `paddle-engine`，Dart 握手同步，旧后端自动重启）；flutter analyze 零问题。README 新增「识别引擎」节 + 首次安装可选步骤；install.bat 过时的"PaddleOCR 已移除"注释更新。pubspec 1.0.0+179→1.0.0+180。

## 1.0.0+179

- **修复：主区快设「按主区拆分」整页必失败——"Kraken worker 失败: Image is empty"**（用户实测 GujiBT 某书 page_008 连续重试两次同错，拆分任务带失败页结束）。根因与修复：
  **① 根因：整批识别路径（per_line=False）的 nlbin 没有空白保护**——Kraken 的 nlbin 对**均匀图像**（灰度 max==min，全白/全黑）抛 `KrakenInputException('Image is empty')`。逐行识别早有同口径容错（`_prepare_line_safe`：空白行裁剪按空行返回哨兵），但逐字框批量补读（`_recognize_char_boxes` → `recognize_lines(per_line=False)`）在 worker 里走整批模式：本批全部字框的**包围盒一次裁剪、统一放大、一次 nlbin**（kraken_worker._recognize），这一处 nlbin 未加保护。触发形态：某"行"的全部字框都无墨——tighten 保留的**无墨空位槽**（空格条带，日志实测"框#31 原因=格内无墨迹归属"）或纯白页边里检出的假行（page_008 实测四周有 400~689px 纯白边带）——包围盒裁剪全白 → nlbin 抛错 → daemon 返回 error → 端点 500 → Dart 抛 `segment_lines_in_region failed` → 整页标记失败（客户端拆分队列本身有逐页容错，不崩 app，但该页每次必失败卡断点）。
  **② 修复（kraken_worker._recognize 整批路径）**——包围盒均匀 ⇒ 包内每个框都均匀（都无墨），整批按空行返回（复用 `_is_empty_image_error` + `_empty_line_result`，与逐行模式同口径）：text 空、conf 0、字块空，框坐标经 off_x/off_y 还原回全图坐标；非空白判错（CUDA/模型错误）仍原样上抛走崩溃上报路径。一条空白行不再拖垮整个请求。
  测试：新增 test_kraken_worker_empty 2 条（假 kraken 模块注入：均匀裁剪整批返回空行且坐标还原全图系；CUDA 类错误原样上抛），回归 test_seg_core/test_seg_kraken_cuts/test_seg_punct/test_line_ink/test_region_ink/test_kraken_fusion/test_kraken_daemon/test_seg_lines 全过（test_seg_layout 的 `drop_duplicate_fragment_lines` 存量失败一条，已验证还原本次改动后依然失败——纯函数断言，与本次无关，v132 条目已注记）；后端 `import` 冒烟 OK；**真实环境端到端验证**：kraken env + 真实 page_008.png 白边内两行假行，修复前形态的请求现在打 `[skip-empty] batch crop uniform` 并返回 2 条空行（坐标正确），不再抛错。纯后端改动 + Dart 侧仅同步握手串。BACKEND_BUILD v132→v133（batch-empty-guard，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+178→1.0.0+179。

## 1.0.0+178

- **修复：叠加「墨迹对齐」列距回声峰把页挪错一整列（用户日志实测：532/534 两页一致地把参考页 533 反向挪了 ~135px，叠加错位恰好一整列）**。三部分：
  **① 病灶定位（依赖 +177 的页内日志）**——日志显示 532/534 相对参考页 533 的原始平移一致落在 ~(−135,+20)，中位归零把这个一致错误转嫁给参考页（533 被挪 +134.5px 往右）；截图确认错位量恰为一整列宽度。机制：竖排页的列结构强周期，互相关在"错开一列"处出现**回声峰**，同版式不同内容的页真峰只略占优甚至被反超，纯 argmax 撞上回声就把两页挪错一整列（两页独立犯同样的错——同一本书列距相同）。
  **② 纸心先验锚定（ink_align.dart）**——文字相对纸面是刚性印刷，两页**纸面中心的差值就是真实平移的物理先验**。`InkPageProfile` 新增 `paperCenter`（纸面矩形中心映射到工作画布；纸面定位失败退化为 contain 中心，先验趋 0 仍成立）。`_bestShift` 增加 [expectedD]：全局峰落在先验 ±[priorRadius]（40 工作像素，刻意小于典型列距）窗口外时**默认不采信**，改取窗口内最优峰；仅当窗口内塌方（< [escapeFloor] 0.15）而全局峰够强（≥ [escapeMin] 0.45）才逃逸采信全局峰——兜住"纸面定位失效 + 真实大偏移"场景。y 轴（行距回声）同规则。置信度取所选峰的相关系数，后续阈值判定不变。
  **③ 日志补纸心差**——逐页日志行增加"纸心差 (dx,dy)"（先验值），与实际平移并列，下次粘贴即可对照先验与结果是否一致。
  测试：新增"列距回声峰反超真峰时不锁整列"（手工构造剖面：page 列高 = ref 列高错位一列的复制，回声峰确定性反超真峰；已验证临时禁用先验锚定该测试立即失败——错位 −110px 整列，恢复后取真峰 ≈0，回归测试确实抓住实测病灶）；既有 10 条全过；flutter analyze 零问题；flutter test 全量 552 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+177→1.0.0+178。

## 1.0.0+177

- **新功能：叠加页「对齐日志」——墨迹对齐逐页诊断就地可看、一键复制**（用户需求：排查"看着没对齐"时直接把日志粘出来对照，不用截图猜）。三部分：
  **① 双写日志（book_overlay_page.dart）**——`_logAlign` 把对齐日志同时写进页内列表（上限 400 行滚动淘汰）与后端应用日志，两处同一份文本。每次合成记一条参数头（时间 · 模式 · 分析 n/N 页 · 耗时 ms · maxShift/阈值/高通窗口——看日志即知构建配置）+ 汇总（参考页/对齐数/低置信数/整体缩放）+ **逐页全量**明细：对齐页带"旋转 x.xx°，平移 (dx,dy)px，置信 cx/cy"，未对齐页带原因与双轴置信度，不可分析页（墨迹不足/二值化失败）单独标注。
  **② 状态行日志入口**——「墨迹对齐」开关右侧新增日志图标按钮，弹窗内等宽字号展示、SelectableText 全选手选复制。
  **③ 弹窗操作**——「复制全部」（Clipboard + SnackBar 回报行数，弹窗保持打开便于继续手选）与「清空」（StatefulBuilder 内联刷新）；空日志时两按钮置灰并提示"先合成一次"。
  测试：纯 UI/日志改动，算法零变化；flutter analyze 零问题；flutter test 全量 551 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+176→1.0.0+177。

## 1.0.0+176

- **修复：叠加「墨迹对齐」置信度判据误拒——竖排文字的周期次峰把可对齐页判成"低置信"，平移整页不施加**（用户实测 +175 后按页码位置判断仍明显未对齐；水平基本对齐、垂直差大半行，旋转却生效）。两部分：
  **① 根因：显著性判据撞上文字周期性**——原置信度 = 主峰对死区外次峰的显著性。竖排书的列/行是强周期结构，互相关在 ±一个列距/行距处**必然**出现接近主峰的次峰；版式相同、内容不同的相邻页主峰只靠包络撑着、对次峰优势很小，显著性被压到阈值下 → 整页判低置信 → 不偏移（合成测试里该值仅 0.246，贴着旧阈值 0.20 过线，真实页内容不同只会更低）。这正是"旋转生效（角度不走该判据）、平移恒不动"的完整解释。
  **② 判据重做：投影高通 + 峰值相关系数（ink_align.dart）**——直接用峰值 r 会放进假相关（文字带包络让任何两页"正文都在同区域"就有 0.4+ 的相关，噪声页也过阈——已用测试证实），所以先把投影**高通**（√计数 − √滑动均值，窗口 21 工作像素：大于界栏线宽、小于列距/行距）压掉低频包络，只留列位/行距细结构再 Pearson。置信度 = 高通后峰值 r（clamp 0~1），阈值 x 0.30 / y 0.22（实测标定：行格版式相邻页 cx≈0.99/cy≈0.99 且平移整数精确找回；无行格随机行相位页 cy≈0.26 仍放行；噪声页与版式无关页 <0.1 拒绝）。亚像素插值与边界判定不变。顺带：**页码屏蔽带从"画布底部 7%"改为"纸面底部 6%"**（contain 留边时全局比例切不准真实页码区）。
  测试：ink_align_test 新增"同版式不同内容的页仍可对齐（相邻页场景）"（行格生成器：列位/行距相同、每格着墨随机，平移 (10,−5) 精确找回，兼作阈值标定用例；随机行相位变体实测 cx≈0.99/cy≈0.26）；既有 9 条全过（含扫描背景零偏移锚死回归——高通后噪声页由"包络假相关放行"回归为正确拒绝）；flutter analyze 零问题；flutter test 全量 551 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+175→1.0.0+176。

## 1.0.0+175

- **修复：叠加「墨迹对齐」平移不生效（旋转生效但上下左右偏移不动）**（用户实测反馈 +174 后旋转有改善、平移没对上）。根因与修复：
  **① 根因：扫描背景把互相关锚死在零偏移**——原实现墨迹提取不限区域，扫描周边的深色背景/书脊阴影贴着**画面边框**每页同位：角度估计照常（这些边缘随页面一起倾斜，锐度扫描仍能拉正），但投影互相关的质量被背景支配、相关峰恒在 0 偏移处——正是"旋转对齐、平移恒 0"的假对齐。合成单测全是满幅白底页，暴露不了该形态。
  **② 纸面定位门控（ink_align.dart）**——新增 `_paperBounds`：亮度 92 分位定纸白，行/列"近纸白（纸白−25）占比 ≥35%"的首末行/列围成纸面矩形（采样估计，覆盖面 <30% 按整幅兜底——全幅白底扫描本无需门控）；墨迹只在纸面内提取（内缩 1.5% 排除页缘阴影/装订暗边），Otsu 也改在纸内做（干净的纸/墨双峰，不再被背景第三峰拉偏阈值）。
  **③ 投影 √ 加权 + 搜索半径放宽**——互相关前对投影计数开根号：版框长直线/边栏这类巨峰计数远高于普通文字列，原值相关被它们支配，√ 压缩动态范围后文字结构主导；平移搜索半径 60→80 工作像素（=160 画布像素）。
  **④ 逐页诊断日志**——`[叠加·墨迹对齐]` 在汇总行后最多列 8 页明细：对齐页带实际旋转角与平移量（px），未对齐页带原因与双轴置信度，真实书页上排查"看着没对齐"以此为准。
  测试：新增 test/ink_align_test 1 条（**扫描背景不把配准锚死在零偏移**：中灰背景+白纸页整体平移 (12,−7)，断言找回 (−24,14)；已验证临时关闭纸面门控该测试立即失败、恢复后通过——回归测试确实抓住旧缺陷形态）；既有 8 条全过；flutter analyze 零问题；flutter test 全量 550 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+174→1.0.0+175。

## 1.0.0+174

- **新功能：叠加「墨迹对齐」——指定页叠加/全书叠加合成前按各页墨迹投影互相配准（平移 + 小角度旋转），叠加文字重合、页码错位不再拉偏**（用户需求：叠加校对/统一设置时各页扫描存在平移与角度差，叠加后文字错位看不清版式是否一致；页码每页文字不同、位置有别）。四部分：
  **① 算法库（flutter_app/lib/services/ink_align.dart 新文件，纯 Dart 无后端参与）**——`analyzeInkPage`：解码图 → Otsu 全局阈值二值墨迹（近单峰/墨迹占比>45% 判不可分析）→ 像素映射到工作画布（叠加画布 1/2 宽，600px）→ **旋转扫描估计页面偏转角**（行/列投影归一化锐度 Σh²/T² 最大的角度 = 文本轴拉正角；粗扫 ±5° 步 0.5° + 细扫 ±0.4° 步 0.04°，墨迹点超 5 万按步长均匀抽样控耗时；**底部 7% 条带不进统计**——页码是配准噪声不是特征）→ 在拉正角下重建去旋转 x/y 投影直方图。`computeInkAlignments`：墨迹量中位数的页当参考（避开章首/缺字页），逐页与参考做投影 **Pearson 互相关**（搜索 ±60 工作像素、亚像素抛物线插值、重叠≥55% 才计分），**相关峰对死区外次峰的显著性 = 置信度**；角度差>6°/平移到搜索边界/置信度不足（x<0.20 或 y<0.16，竖排行结构弱于列故略宽）判为不可对齐、不偏移（与旧版摆放一致）。全部对齐后平移中位归零（合成整体居中不随参考页选择漂移）；按最大偏转角算**全局统一缩放**（旋转后包围盒收回画布内，clamp ≥0.85，所有页含未对齐页一致施加——统一后缩放不破坏配准）。`OverlayInkTransform` 把"绕画布中心旋转 α + 平移 t + 全局缩放 S"封装成可逆仿射（正向点/矩形、逆向点/矩形、Canvas.transform 列主序矩阵），**矩形映射取四角包围盒：写回宁可稍大不裁字**。
  **② 合成管线接入（book_overlay_page.dart）**——`_recompose` 在画页循环前增加"分析墨迹"阶段（与画页循环同一跳过口径：已确认页不参与；每页解码到 600 宽取 RGBA 后立即释放，进度两阶段计数"分析墨迹 n/2N → 合成叠加图"）；画页按各页变换 `save → transform → drawImageRect → restore`，**并集虚线同样过正向变换**（用户看到的参考是配准后坐标系的并集）。AppBar 下新增「墨迹对齐」开关 + 状态行（参考第几页 · 对齐 n/m 页 · 低置信 k 页未偏移 · 整体缩 N%，有低置信页时转橙），两种模式（指定页叠加/全书叠加）共用管线故都显示；默认开，关闭即回旧 contain 口径。
  **③ 写回坐标口径（对齐的灵魂）**——`_canvasRectToPage` 增加变换参数：统一设置与全书批量应用两条写回循环逐页取**与画页同一套变换做逆映射**（画布上对齐后画的框，换算回各页像素仍然准确；带角度的页取四角逆映射包围盒，识别区完整覆盖其真实斜置文本块）。`OverlayInkTransform` 由画页与写回共用，杜绝"显示对齐、写回偏移"。
  **④ 踩坑与防御**——Otsu 类间方差漏乘 wF 项会把阈值推到近 255（整页判成墨迹触发防污损拦截）；"≤ 阈值属墨"语义（双峰贴档时阈值正好落在墨迹灰度上，`<` 会整页排空）；**棋盘式（quincunx）行内抽样与旋转后的整数光栅在 0° 产生莫尔纹假峰毁掉角度扫描**——墨迹提取改全像素扫描（600px 仅几毫秒）。中途放弃/失败退回恒等变换（与旧口径一致），`[叠加·墨迹对齐]` 日志记录参考页与对齐统计。
  测试：新增 test/ink_align_test 8 条（端正页角度≈0/整体旋转 2° 拉正角≈−2°/互相关找回已知平移含中位归零不破坏相对配准/旋转+平移组合/底部页码带墨迹不干扰/空白页不可分析且两页缺一不配准/无结构噪声页不强行对齐且原因非空/OverlayInkTransform 正逆点往返·矩阵一致·AABB 外扩后逆映射包含原框）；flutter analyze 零问题；flutter test 全量 549 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+173→1.0.0+174。

## 1.0.0+173

- **新功能：主区快设「指定页叠加统一设置」——范围页叠一张图统一设各类版面区，设置后一律退回未确认**（用户需求：一段页面版式一致时不想逐页画框，也不信任适配的比例映射；批量设置后**不要自动确认**，由用户分页查看后自己确认；后续追加：叠加里也要有主区/页眉/页脚/页码等**识别框的类别划分切换**、**清除所有未确认页面中所有识别框**、网格 **Ctrl/Shift 多选页直接进叠加**；实测反馈：**清框闪退修复**）。六部分：
  **① 全书叠加页增加「统一设置」模式（book_overlay_page.dart）**——`BookOverlayPage` 新增可选参数 `quickApplyRange`（0 基含两端）与 `quickSavePage`（逐页写入回调）：叠加窗口就是**整个指定页范围**（用户选多少页就叠多少页，无窗口滑杆、无 100 页窗口上限，只留透明度可调；应用与预览同范围，不存在"预览窗口 ≠ 应用目标"）。进页即扫范围页状态（`quickApplyTargetsFrom` 纯函数供单测）：校对完成的页（整页绿框 isFullyConfirmed/玫红框 boxesReviewed/旧版 reviewed）与「确认无正文」的页恒跳过（与「按参考页适配」同一保护口径），**无标注页入目标**（统一设置正是给没设过的页补版面区），原主区已确认（绿色角标）页数单独统计；确认弹窗**先取回扫描结果再构建**、按钮可用性与文案直接由数据驱动（坑：放进 FutureBuilder 时其完成只重建自己子树，外层 actions 读到的捕获变量永远 null，按钮会恒灰不可点），弹窗交代已画类别与统计并写明"只写框不识别、应用后写了正文的页一律退回未确认、回主区快设逐页查看后自己确认"；写入循环逐页防御性复查（扫描与应用之间刚变成校对完成/确认无正文的页跳过）、各类别画布矩形按各页实际尺寸 contain 换算、经 `quickSavePage` 落盘，进度框可停止，结束弹汇总 SnackBar 并记 `[主区快设·统一设置]` 日志，有写入即弹出范围页回网格逐页核对；全无写入时对话框说明原因。编辑器原「全书叠加」入口零变化（拖新框=正文区整框替换，无类别栏、无键盘绑定）。
  **② 叠加画布类别化（与单页快设编辑器同一套语义）**——草稿模型从单矩形改为 `Map<label, List<Rect>>` + 当前类别/当前框：AppBar 底部新增**类别快切栏**（7 类 ChoiceChip，色点+名+数字键提示，快捷键 **1~7/小键盘** 切换、**Del** 删当前框，底栏加「删除当前框」按钮），**每类可画多个框**（左右页脚/多段页眉各框一块）；画布上各类别按 `RegionLabel.color` 细线+类别名标签区分，当前框橙色可拖动/调角/单击选中、点空白取消选择、点其它框直接切换并拖动；误触（纯点击/过小拖拽/指针被打断）按画前快照回滚。画笔改按类别绘制（`_draftsEquals` 触发重画），`_draftRect` 保留为正文类单矩形口径（全书叠加模式复用）。
  **③ 多类别写入与退回未确认**——`quickApplyPayloadFrom` 纯函数把草稿收敛为逐页载荷：正文类有框时整组带入（多主区页支持），**只画页眉/页脚等类别时正文传 null = 不动主区**（统一设置不提供"删光各页正文区"的语义），退化框（<2 画布像素）丢弃、过滤后空的类别剔除；网格 `_saveRegion` 的 `unconfirmRegions` 相应只在**本次写了正文区**（mainRects 非 null）时清正文主区确认（`BookRegionApply.clearMainRegionConfirmed`），只设页眉等类别时正文确认保留。主区快设底部栏「指定页叠加」入口（与其余批量互斥锁定），页表两个来源：**网格 Ctrl/Shift 多选的页直接进画布**（跳过范围对话框）——格子单击分发修饰键（Ctrl 选中/取消、Shift 从锚点沿可见页表连选，「隐藏已确认」过滤掉的页不进选区；选中格子蓝色边框 + 左下"✓ 已选"角标，图例行显示"已选 N 页 · 点击清除"，按住修饰键的拖拽不画主区），**写入成功返回网格后自动清空该批选择**（中途停止/一笔未写则保留便于原样重试），叠加页参数相应从连续范围泛化为**页表** `quickPages`（0 基升序、可离散：合成循环/扫描/弹窗/日志全按页表，状态行显示"叠加第 a~b 页中的 n 页（离散）"）；未选页时弹范围对话框（起止输入自动钳制 1~N、反写自动纠正，展开成连续页表）。逐页保存复用 batch 模式（网格内存态随写随同步，返回后无需重读），返回后 SnackBar 提醒逐页查看、核对后「保存并下一页」自己确认。底栏改**两行结构**（状态行 + 按钮行横向可滚）：批量入口增多后单行 Row 在 800 逻辑宽（widget 测试面）溢出 27px，quick_editor_multibox 11 条连带失败——改后宽窄窗口都不溢出（+172 条目记录的该"既有失败"与本条 `book_overlay_quick_apply` 编译失败均为本功能在途状态所致，随本条修复转绿）。
  **④ `BookRegionApply.clearMainRegionConfirmed`**——退回未确认的本体：只清**正文主区**（词表外 label 归一正文同口径）的 boxConfirmed 并返回条数；页眉/页脚等其它类别确认原样保留；幂等（再清返回 0）。
  **⑤ 主区快设「清除未确认页框」**——底部栏新按钮（与其余批量互斥锁定，破坏性操作弹窗确认并交代将被清空的页数）：适配/统一设置批量写框试错后一键清空重来。目标页判定 `shouldClearUnconfirmedBoxes`（纯函数供单测）：有框（版面区/行/字/段落/表格任一非空）、**无绿色"已确认"角标**（主区未确认；「确认无正文」的页同样算已认可）且**非校对完成**（绿框/玫红框/旧版 reviewed）——人工认可过的框不被批量清除；主区未确认的页即使个别页眉框被确认过也整页清（用户要求的"所有识别框"页级粒度）。逐页盘上防御性复查后清空版面区/行/字/段落/表格框并落盘（draftSaved 一并归零，页回到与从未设置过的页同状态），网格内存态/角标随清随刷；这些页从未进过 region_det 训练集，无需回账导出。
  **⑥ 修复：清除未确认页识别框闪退（Cannot clear an unmodifiable list）**——根因：`PageAnnotation.fromJson` 对 `main_regions`/`paragraphs`/`tables` **缺键**时兜底 `const []`（不可变），此类页（如只有行框、JSON 没有 main_regions 键的拆分产物）一进清框循环 `.clear()` 就抛 UnsupportedError 整页中断；同雷 `Paragraph.fromJson` 的 `line_ids`——主区/段级联的 `lineIds.removeWhere` 在缺键段落上同样会炸（模型里 271 行注释早已写明"可增长空列表（不能用 const []）"的纪律，此两处违反）。修复：两处 fromJson 缺键兜底全部改为可增长空列表（`<T>[]`；`SplitInfo` 的两个列表全仓只读不 mutate，不动）；清框循环本身改**级联赋值新列表**（对任何不可变来源免疫，不只修 const 一种）。
  测试：新增 test/book_overlay_quick_apply_test 7 条（quickApplyTargetsFrom：保护口径与无标注页入目标/已确认页计入退回/**页表外不看（离散多选口径）**/页表全部不可设时目标为空；quickApplyPayloadFrom：正文+页眉双类别/只画页眉时正文 null 不动主区/退化框丢弃与空类别剔除），test/clear_unconfirmed_boxes_test 6 条（未确认有框清/仅行框或表格也清/绿色角标不清/校对完成三种不清/确认无正文不清/无标注无框不清），test/page_annotation_mutability_test 3 条（fromJson lines 分支与旧版 blocks-only 分支缺键列表可增长、Paragraph 缺 line_ids 可增长），book_region_apply_test 新增 clearMainRegionConfirmed 3 条（只清正文/幂等/与 applyRegionsOnly 链路配合）；flutter analyze 零问题；flutter test 全量 541 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v132。pubspec 1.0.0+172→1.0.0+173。

## 1.0.0+172

- **新功能：外部模型 API 多供应商配置**（用户需求：外部模型支持配置多家供应商，每家可配多个模型，并可选用「哪家供应商的哪个模型」）。六部分：
  **① 数据模型（ollama_service.dart）**——新增 `ExternalApiProvider`（id/name/baseUrl/apiKey/models：稳定 id 供槽位绑定引用、改名不变；models 为该供应商配好的模型名列表）与 `ExternalEndpoint`（一次调用解析出的 地址+密钥+模型，传输层只依赖它）。`OllamaSettings` 新增 extProviders/activeExtProviderId/extVisionProviderId/extTextProviderId；旧 `ext_base_url`/`ext_api_key` 平铺字段从存储降级为兼容读 getter（取激活供应商）。**旧配置自动迁移**：fromJson 无 ext_providers 且平铺地址非空 → 生成第一家供应商（地址命中预设用预设名、否则「自定义供应商」，两个模型名入列），激活与槽位指针归一——老用户升级零操作；toJson 继续写平铺字段（=激活供应商）回滚旧版也不丢配置。
  **② 传输层按槽位解析端点**——`_chatBody` 外部分支经 `resolveEndpointForModel(model)`（模型名精确匹配视觉/文本槽 → 各回各家；未知名视觉槽优先兜底）解析端点传 `_chatExternal`；`resolveVisionEndpoint`/`resolveTextEndpoint` 绑定空/失效回退激活供应商（与旧单供应商行为无缝）。模型列表/连接测试新增按供应商的 `listModelsOfProvider`/`checkConnectionOfProvider`。槽位写回 `withVisionModel`/`withTextModel` 增加可选 extProviderId。
  **③ 设置页供应商管理**——外部连接卡重构：供应商下拉（切换即同步输入框+重测连接）+「新增」（默认名立即可改）/「删除」（确认提示；绑定它的视觉/文本槽位一并清空防悬空）；当前供应商的名称/预设/地址/密钥内联即改即存；新增**模型列表管理**（已配模型 chips 可删 + 「测试连接」拉取列表勾选添加 + 手动输入添加兜底——部分网关无 /models）。
  **④ 设置页模型选择二维化**——「模型选择」卡外部模式从两个自由文本框改为 **供应商下拉 × 模型下拉** 两个槽位（视觉/文本各自独立），模型选项=绑定供应商的模型列表；换供应商自动落到其首个模型，原模型仍在列表则保留。
  **⑤ 对比页多供应商**——`ModelRef` 扩展三字段 (provider, extPid, name)（本地 extPid 恒空、modelKeyOf 本地键格式不变）；外部组**逐供应商并行拉取**（各家独立容错，一家失败不拖累别家，错误按「供应商名：原因」聚合）；勾选行外部条目附灰字供应商名；注入 runner 时槽位绑定 (extPid, model) 各回各家；`CompareRunResult`/`CompareModelRow` 带 extPid，聚合键「来源|供应商|模型」区分同名模型。
  **⑥ 测试**——新增 5 条（平铺迁移+预设命名/多供应商 round-trip 保真/双供应商端点解析+按名解析+兜底/槽位回退链四种/null 形态）；`ModelRef` 字面量全量补 extPid；ai_stress_test_test 改多供应商构造。flutter analyze 零问题（本四个文件）；flutter test 全量 511 过——ollama_service/ollama_compare/ai_stress/ai_line_repair/ai_concurrency 等 AI 相关测试全过；既有失败 quick_editor_multibox（book_region_grid_page RenderFlex 溢出）/tool_export_crowd_tasks（无头工具环境依赖）/book_overlay_quick_apply（book_overlay_page.dart 预存编译错误）均与本次无关（未触碰文件，region_split_resume 单跑全过）。pubspec 1.0.0+171→1.0.0+172。

## 1.0.0+171

- **改进：按参考页适配 v2（真实判空 + 不自动确认）与新功能「取消确认」/「全书改回未保存」**（用户反馈：v170 只是把参考页的框原样拷贝，没有判断目标页真有没有这个页眉/页脚/页码；适配后不该自动确认；对话框 UI 不够好；另要两个"退回未确认"的能力）。五个部分：
  **① 后端 `/region_ink`（api_recognize.py）**——给定页面图+矩形列表，逐框返回核心区结构性墨迹占比（复用 `/line_ink` 的 `_structural_ink`/`_core_ink` 连通域过滤：界格线与噪点不算墨迹，空白带 ≈0、真页眉行 0.1+）；坏图整批 ok=false。测试 test_region_ink 5 条（真框高/空白带近零/界格线不计/坏图/上限 400）。
  **② 适配 v2（book_region_reference_apply.dart 重写）**——非正文类框（页眉/页脚/页码等）复制到每页前**逐页墨迹判空**：低于阈值 0.02 的框视为"该页没有这个页眉/页脚"不落（检测失败保守保留，宁可多落人工删）；**删掉"适配后视为已确认"，结果一律待确认候选**；范围新增**指定页范围**（起始~结束页号，钳制在 1~N，自动纠正反写）；对话框重排（参考页/复制类别/适配范围三段式小标题 + 范围单选带实时页数副标题 + 判空开关 + 底部两行说明），`ReferenceApply.targetsFor` 增加 rangeFirst/rangeLast 参数（测试 +1 条）。
  **③ 主区快设「取消确认」**——底部栏新按钮：指定页范围把已确认页整段退回未确认（清全部版面区框 boxConfirmed 与「确认无正文」标记，框本身保留、退出拆分队列；reviewed/boxesReviewed 校对类页面状态不动——那是④的职责）。
  **④ 编辑器单字校对视图「全书改回未保存」**——详细（单字）视图"全页操作"区新按钮：全书遍历，reviewed（确认并保存/绿框）的页 `resetToProposed()`（识别框、文字、几何全保留，只清确认标记），当前页内存态同步、状态标记按盘上重建、校对进度与训练就绪卡刷新；进度框可停止。
  **⑤ 训练数据撤销回账（train_export.py）**——新增 `_prune_stale_pages`：manifest 已登记、但该页标注已不再产出样本的页（确认被撤销后），每次导出时**删除样本文件（detect 层 train/val 的 `<书>_<页>.jpg/.txt` 与旧扩展名、char_cls 层 purge 类目录）并回退 manifest 记账**，统计（instances/pages/每类分布）随之下降；判定与写入共用 page_labels/char_cls_page_items/region_eligible_pages 同一套语义；书里已删除的页与书库外的书仍保留旧数据（"删书不影响"口径不变）。③④操作结束后 Dart 侧显式触发一次 `/train/export`（自动调度器对"全无确认标记"的页不会调度，必须显式导出）。测试 test_train_prune 4 条（detect 双层清理+统计回退/部分撤销/删页保留/char_cls 清理/全书 region_det 确认清空时也清）。
  测试：pytest 新增 9 条全过（test_region_ink 5 + test_train_prune 4），回归 test_train_export/test_region_prelabel/test_region_gate/test_line_ink 51 过（后端全量另见 test_seg_layout/test_layout_analysis 两条**存量**失败——`drop_duplicate_fragment_lines` 纯函数断言，本次未触碰该模块，历版只跑目标子集未暴露）；`flutter analyze` 零问题；flutter test 518 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。BACKEND_BUILD v131→v132（region-ink-prune，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+170→1.0.0+171。

## 1.0.0+170

- **新功能：主区快设「按参考页适配」——用一页设定完的版面区对齐全书**（用户需求：同一本书逐页重复画正文/页眉/页脚/页码太累；顺带按用户要求删掉单页快设编辑器切换类别时反复出现的操作提示卡）。三部分：
  **① 批量适配（`book_region_reference_apply.dart` 新文件）**——主区快设底部栏新增「按参考页适配」入口（与「自动加候选框」/「按主区拆分」互斥锁定）：选一页画过版面区的页做参考（下拉列出各页类别框数，默认选第一条主区已确认的页），勾选要复制的类别（默认该页全部类别）、范围（仅未确认页（默认）/全部页面）与「适配后视为已确认」。参考页矩形**读盘取最新**（不用网格快照），按参考页与目标页的实际像素尺寸各轴线性映射（分辨率/摆正后的尺寸差异被吸收；尺寸未知按同尺寸恒等），逐页整组替换目标页所选类别框；进度框可随时停止，结束弹汇总 SnackBar 并记日志。适配只写框、绝不触发识别。
  **② 逐页保存复用 `_saveRegion`（batch 模式）**——`_saveRegion` 签名扩展：`mainRects` 可传 **null = 完全不动主区**（只复制页眉/页脚等类别时用；空列表仍是"本页无正文区"删主区语义，防止误删目标页正文），新增 `batch` 参数（成功不写逐页日志、失败不弹 SnackBar，由批量循环汇总）并返回 bool 供循环计成功/失败页；确认语义同步收紧——主区未动（null）时只确认本次复制的类别。既有调用方（缩略图画框、单页编辑器）行为不变。
  **③ 目标页保护（`ReferenceApply.targetsFor`，与拆分/预标注同一口径）**——参考页本身、校对完成的页（整页绿框/玫红框/旧版 reviewed）与「确认无正文」的页（扉页/插图）任何范围下恒跳过；勾选「适配后视为已确认」的页直接满足「按主区拆分」的主区已确认门槛，region_det 训练数据照常"确认即入账"。
  另：单页快设编辑器画布底部的"按住左键拖拽，画出当前类别区域（同类可画多个…）"提示卡删除（操作已熟练后切换类别时反复出现碍事；网格页头部说明行保留）。
  测试：新增 `test/reference_apply_test` 6 条（targetsFor 两种范围的保护口径、参考页无需已确认、mapRect 等比/宽高异比/同尺寸与未知尺寸恒等）；`flutter analyze` 零问题；flutter test 517 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v131。pubspec 1.0.0+169→1.0.0+170。

## 1.0.0+169

- **新功能：模型发版打包 .zjpack——手动把「当前启用中」的模型打成签名发行包**（用户需求：训练后不想手工转格式，但也不要自动打包——中间会有弃用的实验模型）。模型管理页「数据与模型位置」面板新增**「打包发版」按钮**：输入包版本号（预填当天日期）→ 把各层 YOLO（有启用打启用 run，无启用打基线，弃用 run 永不进包）＋墨迹比对模型＋Kraken 识别模型打成 Ed25519 签名的单个 `models_release.zjpack` → 结果清单（各条目来源 run/大小/整包 sha256）可一键复制进更新日志。四个部分：
  **① 容器与签名（零第三方依赖）**——`zjpack.py` 定义格式基准：12B 文件头（magic/版本/标志/索引长）+ JSON 索引（条目名/kind/sha256/偏移）+ 原始载荷（不压缩，权重高熵压不动）+ 64B Ed25519 签名（覆盖内容摘要）。签名用内置的公有领域纯 Python 实现 `ed25519.py`（RFC 8032 向量校验过）——conda 3.10 环境不引入 cryptography，用户机零新增安装负担。私钥在 `release_keys/zjpack_ed25519`（`tool_pack_models.py --init-key` 生成，仅管理员机），公钥常量内嵌 `model_store.py`。
  **② 加载器 `model_store.py`**——pack 是发布时刻的冻结快照，优先级永远垫底：env 覆写 > 注册表激活/散文件 > pack。验签 + 逐条目 sha256 + 按需物化到包同目录 `.model_cache/<包sha8>/`（换包即弃旧缓存）；任何问题（缺失/坏签名/条目损坏）只记日志按"无 pack"降级，绝不抛异常打断识别。接线三处：`resolve_model_path` 散文件候选后兜底；Kraken 父进程解析模型路径经 `KRAKEN_REC_MODEL` env 传给 worker（worker 不 import model_store，kraken 子进程保持轻依赖），`ensure_models` 下载兜底只在散文件与 pack 都没有时触发；`char_verify` 比对模型注册表 > 稳定副本 > pack。
  **③ 打包端点与工具**——`POST /models/pack`（api_pack.py，pack_release 端点/CLI 共用；超时 10 分钟）；`tool_pack_models.py` CLI（--init-key / --version）。来源溯源在注册表 runs 里反查 run_dir（ultralytics 的 best 嵌套在 run/train/weights/ 下，直接取父目录只会得到 'weights'）。
  **④ 安装器收口**——ocr_setup.iss：散装模型全部排除出安装包（新增 `*.pt`——顺带修复此前根目录 5 个 yolov8*.pt 漏进用户机的问题、`kraken_models`、`release_keys`、`.model_cache`、`verify_templates` 逐项目模板、`*.zjpack.tmp`），pack 单列 Source（skipifsourcedoesntexist，未打包也能出测试安装包）；build_installer.bat 编译前检查 pack 缺失并警告（不自动打包）。
  测试：pytest 新增 17 条全过（test_zjpack：RFC 8032 三向量 + 往返/篡改载荷/篡改索引/错钥/截断；test_model_store：物化/缓存/无包/坏包静默降级/换包重载；test_api_pack：伪造 service 目录端到端打包→验签读回对账、来源溯源、缺私钥与空目录报错），回归 test_model_registry/kraken_daemon/char_verify 共 68 过；`flutter analyze` 零问题；实机冒烟：CLI 首次打包 136.8MB（char_det 87.7MB←run_20261002_024657、char_cls 基线 5.6MB、verify_pair 1.0MB、chat_rec 42.5MB），加载器验签物化两入口通过。BACKEND_BUILD v130→v131（zjpack-release，Dart 握手同步，旧后端自动重启；与 +168 注记的 v129 zjpack 在途线即本条，已合流）。pubspec 1.0.0+168→1.0.0+169。

## 1.0.0+168

- **新功能：AI 画框测试页（实验）**（用户需求：让 AI 看图后直接判断"从哪个像素到哪个像素是一个字"并画出识别框，测试单纯 AI 画框的裸水平）。首页顶栏「AI 画框测试」进入：选任意图片 → 后端生成带网格刻度的降采样素材图 → 视觉模型直接输出每字坐标框 → **原样叠加到原图（0.15×–12× 缩放平移、点选看坐标、框上编号即 AI 给的阅读顺序）**。与生产链路刻意相反：**零几何精修、不写任何标注、不进训练数据**——生产里"像素归几何"的那一半被拿掉，专门测 VLM 裸定位到底行不行。五个部分：
  **① 后端 `/page_prelabel_image` 加 `grid_div` 参数**（默认 8 不变，钳 4~32；字框级实验用 16 格锚点）——网格线、归一化刻度标签与返回的 `grid` 字段全部跟随，现有版面预标注调用零变化。
  **② `OllamaService.charBoxesFromImage`**（仿 prelabelPageLayout）——prompt 告知素材图尺寸与每格像素数，按阅读顺序输出每字一框；两种坐标口径可切：**素材图像素**（x1/y1/x2/y2，测裸像素定位）与**归一化 0~1**（x/y/w/h，对照网格刻度口径）。整页几百字输出量大：num_predict 8192、超时放宽 10 分钟（`_chat`/`_chatBody`/`_chatExternal` 新增可选 timeout 参数，默认 120 秒不变）。解析器容围栏/字符串数值/角点颠倒互换/越界钳制/退化框丢弃，**截断打捞**：JSON 未闭合时从 "chars" 数组逐个捡已闭合对象（花括号配对扫描，字符串感知）、丢弃残尾并标记 truncated——页面橙色横幅提示"已打捞 N 框"，截断本身即实验数据。
  **③ 编排层 `ai_char_boxes.dart`**（仿 ai_page_prelabel）——素材图（regions 空、gridDiv 可调）→ VLM → 坐标换算回原图像素（像素口径 ÷scale、归一化 ×原图尺寸）；`PythonService.pagePrelabelImage` 返回值升级为 `PagePrelabelMaterial`（base64+画布/原图尺寸+scale，供换算），旧调用方同步。
  **④ 测试页 `ai_box_test_page.dart`**——顶栏：选图（file_picker 记住上次目录）、坐标口径/网格密度切换、「让 AI 画框」（跑动中禁切参数并提示"整页可能要数分钟"）；视觉模型未选时黄条预警。画布仿朝代基准详情页（InteractiveViewer+点选命中取面积更小框）；面板：字框数/耗时/模型/口径统计、截断横幅、模型原始 JSON 展开、实验说明卡。AI 调用走 `_chat` 统一入口，自动继承双通道（本地 Ollama/外部 API）、限流与传输层降级重试。
  **⑤ 素材图网格密度**——8/16 两档（版面区 8 格沿用，字框级 16 格每格约 72~96px 仍稀疏——刻意如此：网格只是锚点参考，格子越密刻度数字越糊，这也是实验观察的一部分）。
  **⑥ 崩溃排查与渲染加固（+169 期间补，随下一版出）**——用户报「外部 API 一测试应用就消失」：日志定位同一会话 5 次尝试中，3 次网关快速报错（37~70 秒）后存活、2 次在响应到达前后无痕消失（无 WER/无事件日志/无 Dart 异常）。**第二轮排查（用户小图 445×601 仍消失）**：无头复现（test/tool_ai_box_repro_test，真实外部配置同图直跑）**成功拿到 32 框有效响应、进程不死**；真实应用（直跑 debug exe）依次验证 网关报错 / 即时成功渲染 / 65 秒延迟成功渲染 / flutter run 附加成功渲染——**全部存活，未复现消失**；唯一一次自然退出为退出码 0（=窗口被关闭，非崩溃）。据此加固与埋点：painter 序号徽章 >300 框不再绘制（TextPainter 逐框布局是单帧主要成本，canvas.drawRect 本身便宜）、画笔复用；原始 JSON 改手动开关惰性构建 + 超 2 万字符截断显示；关键节点（AI 返回/失败/paint 起止）改 **writeCrashLineSync 同步落盘**（异步日志链在进程死亡时丢最后一行，会制造"在途死亡"假象）；新增环境变量诊断钩子 `OCR_AI_BOX_AUTOTEST=<图片路径>`（main.dart，服务就绪后自动进测试页并执行一次，用于直跑 exe 拿退出码）。**另确认测试失败主因：该外部网关（Cloudflare 中转）对慢任务约 2~2.5 分钟即回 HTTP 524 源站超时**——外部中转测整页不可行属预期实验结论。若再遇消失：app_console.log 最后一条 [AI画框]/[crash] 同步行即死亡阶段（若 paint 已结束仍消失 → 环境级窗口关闭；嫌疑：13:45 AdGuard 更新后系统重启被推迟未执行、Process Lasso/DisplayFusion 等——建议先重启机器再试）。
  **⑦ 管线对比 + 计时（+169 期间补，随下一版出）**——测试页新增「YOLO+AI 管线」按钮：同一张图跑当前生产管线（YOLO 切字 + Kraken 识别 + 可选 AI 整行裁决 + 阅读顺序重排，阅读方向按古籍竖排右→左），与「让 AI 画框」**并排显示各自识别一页的耗时**（面板顶部对比卡：方案/耗时/产出三列表格 + 分段小字"纯 AI=素材图+模型、管线=识别+AI 裁决" + 管线 engine/回退原因/AI 裁决状态 + 双方都有时给数量差）；画布双色叠加（绿=AI 框带序号、蓝=管线字框、紫=管线行框，顶栏三个开关分别显隐）。三个部分：
  **① 提取共享管线运行器 `single_page_pipeline.dart`**——把朝代基准 `_recognizeCase` 的编排（409/失联/失败三段忙等待、inferHierarchy、AI 裁决模型选择 vision→text 兜底、rebuildBlocks、阅读顺序重排）原样抽出，新增分段计时（segmentMs/aiAssistMs/totalMs）与 [管线] 阶段日志 + 同步标记；朝代基准改为调用它（payload 与 duration_ms 语义零变化，纯提取）。
  **② AI 侧计时补全**——AiCharBoxesResult 新增 materialMs（素材图生成）与 totalMs（素材图+模型，对比公平口径；原 elapsedMs 为纯 VLM 保留）。
  **③ 「含 AI 裁决」开关**——默认按生产门控初始化（enableLineAssist + 已选模型），跑动中锁定；诊断钩子 `OCR_AI_BOX_AUTOTEST_PIPELINE=1` 让 autotest 在 AI 画框后自动跑管线（强制关 AI 裁决，不依赖外部网关，供无头冒烟）。
  测试：新增 test/ai_char_boxes_test 10 条（双口径解析/围栏容忍/截断打捞含字符串花括号陷阱/角点互换/越界钳制/退化框/画布命中）；`flutter analyze` 零问题；flutter test 521 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）；后端冒烟：grid_div 默认 8 行为不变、16 格画布同尺寸仅网格更密、`import main` OK。BACKEND_BUILD v129→v130（ai-box-test；注：v129 zjpack 为另一条在途工作线的 Python 侧预置，其 Dart 侧尚未跟上——本条 v130 已含其代码，两线合流后以此为准）。pubspec 1.0.0+167→1.0.0+168。

## 1.0.0+167

- **新功能：行图修饰键速操作——Alt 单击拆框、Shift 单击删框**（用户需求：校对单字时按住 Alt 点击识别框拆分成上下两半，按住 Shift 单击字框删除）。三部分：
  **① InteractiveLineCrop**（编辑器行卡片与"行内重切"页共用）onPointerDown 最前面拦截修饰键：Shift/Alt 按住时命中字框（严格框内命中，与拖动同口径）即消费——Shift 走新增 onCharDeleted 回调删除；Alt 沿阅读轴对半拆（竖排上下两半、横排左右两半）。点空白不吞事件，照常走画新框流程；操作后不启动任何拖拽手势。
  **② 拆分实现**——几何纯逻辑进 annotation_hit_geometry.splitRectHalf（前半取整除 floor、后半拿余量，两段之和恒等于原长不漂移；轴向长度不足 2×5px 拆不出两个最小框，返回 null——此时仅选中该字提示并记日志）。数据流复用既有回调：原框就地改成前半（onCharUpdated → 几何变化入队 Kraken 重识别），后半作为新字框走 onCharAdded（编辑器 _addBlock 按阅读序插到原框之后并自动识别；行内重切页 _apply 按几何重排，追加到草稿尾也能归位）。手势日志新增「Alt 拆分」一条。
  **③ 删除接线**——编辑器行卡片把既有 onCharDeleted（快捷候选浮层的删除链路 _deleteBlockById）透传给行图；行内重切页新增 _deleteCharById（Shift 单击与「删除」按钮共用，删的是当前选中字时同步清选中）。
  测试：annotation_hit_geometry_test 新增 splitRectHalf 2 条（竖排奇数长度两半之和恒等且贴合无缝、横排左右拆与轴向太薄返回 null）；`flutter analyze` 零问题；flutter test 501 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v127。pubspec 1.0.0+166→1.0.0+167。

## 1.0.0+166

- **新功能：行图字框缩放 Ctrl 联动相邻字框**（用户需求：校对单字时按住 Ctrl 拖一个字框的顶点，相邻字框的贴合边跟随移动——如拖"其"的下顶点，"气"的上顶点跟随平移；但**保持两框原有间距**，不对齐到同一位置）。两部分：
  **① 纯逻辑进 annotation_hit_geometry**——`linkedNeighborIndex` 选邻框（竖排拖底边→联动下方邻框顶边、拖顶边→联动上方邻框底边；横排 topRight/bottomRight 两柄都动右边→联动右侧邻框左边；按框中心坐标判同侧（框轻微交叠不误选），再取贴合边最近者；行首/行尾字无同侧邻框返回 null）＋`linkedNeighborRect` 算跟随（邻框只动贴合边、对边钉死；位移相对按下快照取值且只取整一次，防反复取整漂移——纪律同 resizeTopRightRect 固定边；钳最小尺寸 5px、贴合边不出页面顶；位移取整后为 0 返回 null）。
  **② InteractiveLineCrop 缩放手势接入**（编辑器详细视图行卡片与墨迹归类的"行内重切"页共用同一部件，两处同时生效）——每个指针事件实时检测 Ctrl：按住即联动、中途松开立即停止跟随；邻框与被拖框一样本地实时预览（彩虹框跟随指针移动），松手时两框一并提交、各自按几何变化入队 Kraken 重识别（与单框缩放同链路）；手势日志新增「行卡片 Ctrl 联动提交」一条便于诊断。
  测试：annotation_hit_geometry_test 新增「Ctrl 联动」组 5 条（竖排拖底边/拖顶边跟随并验证间距保持、横排拖右边跟随、跟随边钳制与无位移返回 null、邻框选取含同侧重叠不误选与行首行尾无邻框）；`flutter analyze` 零问题；flutter test 499 过（唯一失败 tool_export_crowd_tasks 为无头工具环境依赖，与本次无关）。纯 Dart 改动，BACKEND_BUILD 不变 v127。pubspec 1.0.0+165→1.0.0+166。

## 1.0.0+165

- **新功能：导入显示逐页进度 + 先落盘可断点续跑**（用户需求：导入显示处理到第几页；先上传书籍再处理，断开后能继续）。三部分：
  **① 后端 `/pdf_to_images` 任务化**（api_page）——POST 立即返回 `{task_id, total}`（后台线程逐页渲染），新增 `GET /pdf_to_images/status?task_id=` 轮询 `{status, current, total, images, error}`；请求新增 `skip_existing`：跳过输出目录已完成的 `page_NNN.png`（**断点续跑核心**，命名与页号确定性对应）；每页先写 `page_NNN.part.png` 再原子改名（中途退出的半截文件不会被判成已完成页，任务启动时清理残留 .part）；某页渲染失败任务置 failed 带页号，已成功页留盘、续跑自动只重试失败页。任务表内存态、完成保留 1 小时。
  **② 导入三段式**（task_setup_page + 新 services/book_import.dart）——复制源文件 → **先写 project.json**（`import_pending=true`，书立即出现在书库）→ 后台转图（按钮实时显示"正在转换 PDF 第 N/M 页…"）。中途退出应用书不丢：书卡片显示"导入未完成"+「继续导入」按钮，点一下从断点续完（完成后按创建时保存的 autoRecognize 决定是否自动入识别队列；摆正/拆分不自动跑，完成后手动进行）。导入页与续跑共用 BookImport.convertPdf。
  **③ 守卫**——Project 新增 `import_pending` 字段（旧数据缺键读 false）；`RecognitionQueue.enqueue` 拒绝 importPending 的书（防空页书被 _processBook 静默标成识别完成）；编辑入口拦截并提示点「继续导入」；书卡片对 importPending 只提供「继续导入」+删除（摆正/识别/重跑对无页图书无意义）。
  测试：新增 test_pdf_convert 4 条（fitz 现场造 PDF：全量转换/跳过已完成页（mtime 指纹验证未重渲染）/空文件与 .part 半截文件不算完成/未知任务 404）；`flutter analyze` 零问题；flutter test 494 过（tool_export_crowd_tasks 依旧是无头工具环境依赖，与本次无关）。BACKEND_BUILD v127→v128（pdf-import-resume，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+164→1.0.0+165。

## 1.0.0+164

- **改进：导入默认值调整为古籍常用配置 + 导入中断残留自动清理**（用户需求：默认只识别正文/从右到左、不默认跨页拆分；反馈"加书时经常软件退出"）。三个部分：
  **① 导入默认值**（task_setup_page）——识别范围默认"只识别正文"（原"识别全部"）、横排方向默认"从右到左"（rtl，竖排古籍的列序；原"从左到右"）、"导入后先跨页拆分"默认**关**（原开；大多数导入是单页扫描，直接进摆正/识别，需要拆跨页再手动勾）。
  **② 孤儿项目目录自动清理**（storage 新增 purgeOrphanProjectDirs，书库加载时调用）——导入在复制/转图阶段应用退出时目录已建但 project.json 未写，从此不出现在书列表却永久占盘；用户书库已累积 **9 个孤儿目录约 11GB**。清理边界：目录名为纯数字（项目 ID 规则）+ 无 project.json + 1 小时未动（进行中的导入不误伤），char_stats/_realign_backups 等非数字名目录不碰；清理动作进应用日志（"已清理 N 个导入中断留下的残留目录，释放 XMB"）。
  **③ 导入进行中显示已耗时**——大 PDF 转图要数分钟，按钮此前只转圈像卡死；现在显示"正在处理 PDF（已 Ns，大文件需数分钟）…"。
  **加书退出排查结论（供后续追查）**：用户日志（app_console.log）显示两次导入都死在 PDF 转图等待阶段（后端心跳正常、转图在后端侧继续完成），应用无 Windows 崩溃转储、无 WER 事件记录、Dart 层未捕获异常处理（已落盘 main.dart）也无记录——退出发生在原生层且是"干净退出"，非 Dart 异常、非后端问题。已知嫌疑：第三方进程管理工具（本机装有 Process Lasso）按规则结束进程，或用户在长时间无进度反馈时主动关闭（③的耗时显示正是针对后者）。下次退出时 app_console.log 的最后一条心跳时间即死亡时刻，可据此核对系统事件查看器与进程管理工具日志。
  测试：`flutter analyze` 零问题（纯 Dart 改动，BACKEND_BUILD 不变 v127）。pubspec 1.0.0+163→1.0.0+164。

## 1.0.0+163

- **新功能：识别进程数可视可控 + 进程数压力测试**（用户需求：①首页"并行 x/y 路"改名避免与 AI 并行度混淆；②设置里可指定识别进程数；③识别进程也加入压力测试）。背景：该数字是 Kraken 整行识别引擎的 daemon 进程池（首页此前标"并行"，与设置里的 AI 并行度完全是两套机制——后者只管 AI 裁决的行请求数）。三个部分：
  **① 首页改名**——"并行 x/y 路"→"识别进程 x/y 路"（home_page，含注释说明两套机制的区别）。
  **② 设置页"识别进程数"卡片**（AI 辅助设置页，AI 并行度卡之后）——自动（按硬件，默认）/手动 1..12 步进；手动值经 `OCR_KRAKEN_WORKERS` 环境变量在后端启动时生效（`_startBackend` 两条启动路径都透传）；新增「应用并重建进程池」按钮立即生效（走新端点 `POST /kraken/pool/resize`：识别进行中 409 拒绝，重建=排空旧池+逐个加载模型起齐新池，返回实际规模与决策理由）。设置存 OllamaSettings blob 新字段 `kraken_workers`（null=自动；copyWith 用哨兵区分"不改"与"改回自动"）。
  **③ 进程数压测**——后端新增 `POST /kraken/probe`（单行识别探针：书库自选样本图/客户端指定，中心行框走完整行识别链路，不占识别闸门）；Flutter 侧复用 AI 压测爬坡引擎（`AiStressTester.run` 新增 `prepareLevel`/`levelLabel`/`warmupFailHint` 三个可选钩子，AI 压测不传、行为零变化）：每档先把池重建到 k 个（模型加载是主要耗时），再同时发 k 路探针，判据同 AI 压测（最长耗时 ≤ 单条基准×3+15s、显存看门狗 95%、总预算 15 分钟、hardCap=12）；新 `KrakenStressCache`（prefs `kraken_stress_v1`，30 天新鲜期）；测完池自动恢复原设置，结果可一键"应用为手动 N 个"并立即重建。新 `kraken_stress_test.dart`。
  后端配套：`kraken_proc` 新增 `pool_busy()`（在途数，resize 守卫）与 `resize_pool()`（env 覆盖→shutdown→懒建→等就绪，超时返回实际规模）；`_DaemonPool` 增加 `busy` 属性与决策记录（decided/decision_why）。
  **压测预热预检（用户实测反馈：预热失败被伪装成"实测 1 个进程"）**——爬坡前先预检（单行探针连续 3 次、间隔 10s，容忍后端冷启动/模型加载中的瞬时失败），全部失败返回 maxStable=0 并带上最后一次的**真实报错**（此前探针异常被吞、只显示笼统提示且钳到 1 个伪装成实测值）；设置页对 maxStable=0 走"测试未能开始"弹窗——不缓存、不更新"上次压测"、不给"应用"。语义说明：对比测试的"模型加载失败回落基线"不适用于压测——引擎不可用就没有可测的东西，正确行为是报清原因而不是给保底值。
  **样本图改由客户端提供（用户实测反馈：书库有很多书仍报"没有可用的页图样本"）**——后端原 `_sample_library_image` 无参调用 `all_book_dirs()`（该函数需要书库路径参数）必然抛异常被吞；书库路径只有客户端知道，改为设置页压测前从书库选最近一本有图的书的第一张页图传给探针（`KrakenProbeRequest.image_path` 改必填，后端只校验存在性），书库无图时客户端直接提示"先导入至少一本书"。
  测试：新增 test_kraken_pool_control 5 条（env 写入/清除/钳制/超时报实际/busy 透传/行框构造），kraken 三套件 43 过；`flutter analyze` 零问题；flutter test 493 过（唯一失败 tool_export_crowd_tasks_test 是无头联调工具非测试，依赖本机书库 crowdtest1 项目，与本次无关）。BACKEND_BUILD v126→v127（kraken-pool-control，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+162→1.0.0+163。

## 1.0.0+162

- **新功能：导出素材自动处理 + 统一 JPG**（用户需求：导出训练数据时把素材处理好、用 JPG 存）。两个部分：
  **① 检测层整页素材**（新 `write_detect_image`，按书整写与页级增量两条路径共用）——入库时长边超过 2560 的图先降采样（INTER_AREA）再存 JPG（q95）；YOLO 标注是归一化坐标，缩放不影响标签；已是合规尺寸的 JPG 原文件直接复用不二次有损压缩；解码失败退回原样拷贝（保留源扩展名）。同页重写时清掉其他扩展名旧文件（`.png/.jpeg/.bmp/.tif/...`），防 PNG 时代换格式后同一页双样本。
  **② char_cls 单字裁剪**——PNG 改 JPG（q95），按书整写/增量裁剪/metadata_<书>.json 路径三处同步；增量重写某页前先按 `<书>_<页>_` 前缀跨 train/val 全类目录清旧样本（顺带修了行内序号变化留旧文件的存量问题）。
  存量数据不强制迁移：旧 PNG 样本留在原处照常参与训练（混合格式 ultralytics 均支持），某页下次因标注变化/force 重写时自动换成 JPG 并清旧文件。
  测试：test_train_export 新增「大图降采样存 JPG 且长边=2560」「同页重写清理旧 .png」「char_cls 裁剪 JPG + metadata 路径 + 页 purge」三条，16 过；test_training_service 30 过、test_verify_training 4 过；`flutter analyze` 不涉及（纯后端）。BACKEND_BUILD v125→v126（export-jpg，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+161→1.0.0+162。

## 1.0.0+161

- **改进：对比测试画布只画被测层的框**（用户反馈：测正文区检测时，正文/行/字框全部叠在一起，看不清区域框的差异；其他层同理）。`model_compare_page` 左右并排与滑动叠加两种视图的画笔都按测试模式下过滤绘制层级：正文区检测只画正文区框（紫粗）、段落检测只画段框、行检测只画行框、单字检测只画字框；层未知时全画兜底。面板标题下的计数行仍显示全部层级数量（文字不占画面）。纯 Dart 改动，BACKEND_BUILD 不变（v125）。pubspec 1.0.0+160→1.0.0+161。

## 1.0.0+160

- **修复：模型对比测试页一选 region_det 模型就断言崩溃**（用户实测：AssertionError，DropdownButton 的"value 必须唯一匹配一个 item"断言）。根因是注册表 region_det 的同一 run 被登记了**两条**（训练进行中磁盘对账 reconcile 先补了一条无 metrics 的占位条目，训练完成 `_register_run` 又盲 append 一条完整记录）——两条的 best 路径相同，对比页模型下拉出现两个相同 value 的项，一选中（或切到该层默认选中最近 run）即触发断言。三处修复：
  **① 注册按 run_dir 替换**（train_tasks._register_run）——完成登记先移除同 run_dir 旧条目再 append，杜绝双条产生。
  **② 对账顺带修复存量双条**（train_registry.reconcile_disk_runs）——每层按归一化 run_dir 合并重复条目，保留有训练结果（metrics/epochs）的一条，其次 started 更新的；现有已污染的注册表在下次 list_models 时自动修复。
  **③ 客户端防崩兜底**（model_compare_page._loadRuns）——runs 按 run_dir 去重取最后一条，旧后端/异常注册表数据也不再崩。
  测试：test_model_registry 新增「双条合并、保留有训练结果的一条、best 无重复」回归，并把原「大小写去重」断言从 Set 比对（会掩盖列表内双条）强化为 runs 数量=1；全部通过（conda paddle 环境）；`flutter analyze` 零问题。BACKEND_BUILD v124→v125（registry-dedupe，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+159→1.0.0+160。
  另：明确「同一 run 不同轮数互比」用法——模型B 下拉的空置提示与报错文案不再说"没有第二个已训练模型"，改为引导选与模型A相同的 run 后用轮数A/B 换轮互比（该层只训练过一次也可比）。

## 1.0.0+159

- **新功能：模型管理与对比测试可选第几轮的模型**（用户需求：训练每 10 轮存的中间检查点此前只能在训练页曲线里启用，对比测试只能选 run 的 best.pt）。三个部分：
  **① 对比测试页轮数下拉**（model_compare_page）——模型A/B 各新增「轮数」下拉：选项来自 `/train/curve` 的检查点清单（best（验证最优）/ last（最后一轮）/ 第 N 轮，项内带该轮主指标——detect 层 mAP50-95、classify 层 top1，与曲线弹窗同口径——以及 ≥100MB 检查点的体积提示，中间轮含优化器状态、加载较慢）；选中路径直接作为 `test_model_path` 传给 `/segment` 与 `/char_cls/evaluate`（两接口本就收任意 .pt 路径，后端零改动）；切换 run/层时默认回 best（与旧版行为一致），检查点拉取失败时下拉隐藏、仍测 best；面板标题/角标随选择显示 `run·第N轮`。
  **② 模型管理页「曲线·选轮」入口**（model_manage_page）——每个 run 行新增曲线按钮，复用训练曲线弹窗（单 run）：按逐轮指标挑检查点直接启用为全局；层卡「全局」行改显启用来源（run 目录 · best/第 N 轮），替代原先无信息量的 `active_<层>.pt` 文件名。
  **③ 启用溯源修正**（train_registry.list_models 新增 `active_source` 透出）——曲线弹窗与对比页 run 下拉的"当前启用"标记此前永远不亮（传入的是稳定副本路径，与检查点路径永不相等），训练页/模型管理页/对比页现在统一用 active_source 溯源比对，旧注册表无该字段时回退旧值。
  测试：`test_model_registry.py` 全过（conda paddle 环境）；`flutter analyze` 零问题。BACKEND_BUILD v123→v124（epoch-picker，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+158→1.0.0+159。

## 1.0.0+158

- **修复：栏线/版框残带被检测成"文字列"时整行切出 538 个 4px 微框、行图上全是识别框**（用户实测：region=(383,0,126,2163) 全页高、整行读法 0 字，diag 显示 slot_h=4.01、粘连块期望 140/283/115）。三道连环失效，三处修复（seg_chars.py）：
  **① 单字高参考加下限**——`sane_heights` 只收高度 ≥ max(10, 字宽/3) 的非粘连组件：栏线带行里唯一非粘连组件是 4px 高的扁残条（靠宽度过了面积门），中位数被拉到 4，粘连块局部期望随之爆到 ch/4=140、格长 4px。无合格参考时退回字宽。
  **② 实心带不按期望细切**——y 投影只得 1 段且**段内行墨量均匀**（min > 0.65×median，无浅谷）的是实心带（栏线/版框残带），按一个结构元素出框；按期望网格细切只会造出成百个微框。段内有浅谷的（字距留白被 merge_close_runs 并段的真·多字粘连）照旧走网格兜底恢复——回归测试锁定。
  **③ 整行数量不匹配的"期望荒谬"守卫**——期望字数对区域高荒谬（槽高 < max(6, 字宽/8)）时保留连通域框，不再等分微格：上一轮已切出 537 个微框的行带着旧字数进诊断/重识别时，等分只会再造一批（诊断日志里 app 传入 537 的来源）。
  修复后该行产出 1 个贴住整条墨迹的带框（4px 残条被 _tight_rect 高度下限自然丢弃）——一眼可见"不是文字"，可整行删除；不再有 538 框叠图。
  测试：test_seg_core 新增「栏线带行不切微框（1 个带框、高 ≥400）」「荒谬期望保留连通域框」「真·粘连多字（有浅谷）仍走网格恢复」三条，26 过；后端切分 4 套件 125 过；`flutter analyze` 零问题。BACKEND_BUILD v122→v123（ruling-strip-guard，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+157→1.0.0+158。

## 1.0.0+157

- **新功能：编辑器字视图（单字校对，右栏卡片缩放下方）新增「全页重新切割」与「全页重新识别单字」两个全页操作**（用户需求：在单字校对页面中加入这两个功能）。两个部分：
  **① 全页重新切割**——对本页每行推倒重拆字框+识别，逐行走既有级联队列（`_queueResplitLine`，与单行「重新切割本列」同链路：排队数胶囊可见、409 自动重试、行卡片转圈逐行显示、共享列带的小字注分段不外扩）。**用户成果行跳过**（手工行框或字框已全部确认，与区域级联 isUserPinnedLine 同口径）——整页批量不能悄悄洗掉校对成果；入口有确认对话框（列明处理行数与跳过行数）。AI 检查识别框进行中不接受批量。
  **② 全页重新识别单字**——对本页每行保留字框几何、只重读框内文字（`_queueLineCascade`，与单行「重新识别本行单字」同链路 strict 语义）；没有字框的行跳过，直接入队无需确认（不动几何）。
  批量入口在队列非空/执行中时禁用（重复点击会把每行入队两遍，同键只替换还没开始跑的那份）。另：本轮曾按误解把同功能加到墨迹校验调试页，已整体回退（该页维持"开始识别并校验"单一入口）。
  测试：`flutter analyze` 零问题；paragraph_cluster + quick_editor_multibox 24 条过。纯 Dart 改动，BACKEND_BUILD 不变（v122）。pubspec 1.0.0+156→1.0.0+157。

## 1.0.0+156

- **修复（+155 的补充）：洇墨粘连段的切开位置仍用原始 cut，行尾格界漂移在粘连路径上没被上一轮校正覆盖**（用户回传诊断：`粘连段切分: run=(1483,2138) 跨格边界 [1564,1659,1762,1856,1948,2066]`——末两格分界 2066 vs 相邻格距 95/103/94/92，1948→2066=118、末格仅 72，按 ~93-95 字距推真实字界 ~2043，cut 漂低 ~23px；日志中无"行尾部件重归"条目，证明漂移伤害发生在**切开时刻**而非 run 归属时刻）。+155 的短部件重归只能在"独立 run 归属"层面挪段，而洇墨粘连段（无纯白缝）在切开时就按原始 cut 分段——切歪已成型，归属校正无从介入。修复：
  **① 粘连段分界贴谷（kraken_boxes._tighten_boxes_to_ink 的粘连切分分支）**——切开位置从"原始 cut"改为"cut 附近 ±0.35×格长窗口内**墨迹最少的行**"：粘连处没有纯白缝，最少墨行就是字与字的连接处（笔画最细的地方，实测 1~3px vs 正常行墨 20~40px）。窗口内墨迹均匀（实心合成块，无谷）时不介入——argmin 在均匀区间里是任意的，不能让噪声移动分界（既有粘连切分测试用实心块锁定该行为不变）；贴谷后强制严格递增防窗口重叠吸到一起；切分日志打印 `分界贴谷 [cut->谷]` 便于诊断。
  测试：test_seg_lines 新增「洇墨窄桥粘连两字 + 漂移 cut（真实字界 ~101、cut 125）→ 贴谷切到桥处：上格不被拉高、下格收回完整字」「实心均匀粘连段保持原始 cut（回归保护）」两条；test_seg_lines 38 过、后端切分 4 套件 122 过（會并段/横画豁免/标点/巨框/短部件重归等既有锁定行为零回归）；`flutter analyze` 零问题。BACKEND_BUILD v121→v122（stuck-valley-split，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+155→1.0.0+156。

## 1.0.0+155

- **修复：每行最后两个字的识别框高频错位——倒数第二字框偏高、末字框只剩半截**（用户反馈：末两字的框几乎都是倒数第二个高、最后一个矮，末字半截被逐框读法读成『丨』）。根因在 cuts 条带框收紧（`_tighten_boxes_to_ink`）的**格界来源**：kraken 的格界取自"相邻字符**中心线**的中点、首尾格借行框边缘"（kraken_worker._record_to_line），行尾字符（干/才类部件留白字形、句读小字）的中心估计偏移时，末两格的分界整体漂进末字上半部；收紧按"run 中心落在哪格就归哪格"，末字顶部短部件的中心落在了漂移分界之上 → 划给倒数第二格（框偏高），末格只剩主体下半截（框矮）。此前像素切分（连通域）可信时不用 cuts 路径，但该书页面连通域数与读法数常不匹配 → 网格兜底 → 弃用 → 落到 cuts+收紧，于是每行行尾都暴露在格界漂移下。修复：
  **① 行尾格界漂移校正：短部件重归（kraken_boxes._tighten_boxes_to_ink）**——run 归属后新增一遍相邻格校正：贴界短部件（高度 < 0.55×中位格长）在"两侧墨迹跨度都向中位格长收敛"（代价改善 ≥0.15×格长）且接收侧跨度 ≤1.4×格长时，并回正确一侧。只在一格虚胖、一格不足的漂移形态下介入：正常行（每格一个整字）两侧已接近格长、无可挪段，行为不变；會/需类整字部件两半高度接近半格以上且正确归属时挪动只会更差/超上限，不受影响（既有测试全绿锁定）。行首方向的漂移同机制覆盖（上移分支）。
  测试：test_seg_lines 新增「行尾格界漂移：末字留白字形的顶部短部件并回末格（倒数第二框回本字、末框收回完整字形）」「正常行不受校正影响」两条；tighten 全组 36 过（會并段/横画豁免/粘连切分/标点/巨框等既有锁定行为无回归）；test_seg_lines+test_seg_kraken_cuts+test_seg_core+test_seg_punct 120 过；`flutter analyze` 零问题。BACKEND_BUILD v120→v121（tighten-end-boundary，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+154→1.0.0+155。

## 1.0.0+154

- **修复：新段识别进行中再画一个新段，前一个段框被顶替消失**（用户反馈：新的段落画完正在识别，再画一个新的段落框会顶替之前的段落框，而不是新加了一个识别框）。根因：`_addParagraph` 画完新段后按中心点认领行，认领清理 `removeWhere(op.lineIds.isEmpty)` 对**本来就空**的段也成立——刚画完的新段区内还没有行框（或行还没被自己的段级联识别回来），lineIds 为空，画**任何一个**新段都会把它顺带删掉；它排队中的段级联随后因 ownerDeleted 作废，段就永远消失了（+152 修的是回包合并路径的洗段，这条入口路径的洗段漏了）。修复：认领清理只移除"被本次认领掏空"（原本有成员、全被新段抢走——重叠抢行时最后修改者胜，既有语义保留）的旧段，本来就空的段不动。顺带把认领逻辑下沉为 `PageAnnotation.addParagraphClaiming`（与 removeParagraphWithLines 同层，可测）。
  测试：paragraph_cluster_test 新增「连画两个新段不顶替（空段等级联补行不被认领清理删掉）」「新段抢走旧段全部行→旧段移除；部分抢行则保留」两条，13 条全过；全量 Dart 493 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）；`flutter analyze` 零问题。纯 Dart 改动，BACKEND_BUILD 不变（v120）。pubspec 1.0.0+153→1.0.0+154。

## 1.0.0+153

- **修复：行框改尺寸后的自动重识别走错链路——裁切框差、文字不准，还得手动再点一次「重新识别本行单字」**（用户反馈：单行界面里改了单行尺寸后，单字区域的裁切好像用的不是重新切割本行这个功能，裁出来的框很差，改过的单字也不准）。根因：行框缩放手势结束的级联（`_handleGeometryEditEnd` 的 `_lineGeomDirty` 分支）走的是 `_queueLineCascade` → `_rerecognizeLineChars`——「重新识别本行单字」的**保留框几何、只重填文字**路径。而行框缩放时 `_updateLine` 把旧字框按新旧尺寸比例**拉伸**过了：拉伸框与新版心墨迹错位（行框放大盖住更多字时更是一个字都对不上），拿错位的框逐框读字，框差字也差。修复两处：
  **① 尺寸变化 → 推倒重拆（与「重新切割本列」同链路）**——`_handleGeometryEditEnd` 行分支改调 `_queueResplitLine`：丢弃被拉伸的旧字框，后端完整自动拆字（连通域/网格切分、标点拆分合并）+ OCR，字框与文字一次到位，不再需要手动补一次重识别。`_updateLine` 的注释同步对齐（"手势结束后重新拆字"此前名不副实）。纯移动（≤2px 微调）仍不触发。
  **② 手势新框即识别范围（不外扩）**——`_queueResplitLine`/`_resplitLineChars` 新增 `expand` 覆盖参数，缩放手势触发的重拆传 false：用户刚亲手给出的新框就是识别范围的权威意图，再走"外扩到整列墨迹"会把刻意收窄的框撑回去、框外字也跟着回来（重切结果对 manual 行框的保留与新框自相矛盾——框被还原成手势几何而字框是外扩范围切出的，字框伸出行图外）。按钮入口维持原判定（共享列带不外扩、独占列带外扩到整列墨迹）。
  测试：paragraph_cluster / quick_editor_multibox / manual_recognize 27 条全过；全量 Dart 491 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红；另一轮全量出现的 2 红——straighten_batch/ollama_compare 为并发时序抖动，复跑不重现）；`flutter analyze` 零问题。纯 Dart 改动，BACKEND_BUILD 不变（v120）。pubspec 1.0.0+152→1.0.0+153。

## 1.0.0+152

- **修复：删除段落不连带删除其下的行与单字识别框＋识别进行中新画的段框会被回包洗掉消失**（用户反馈：①删除了段落，对应段落下方的单行和单字识别框没有跟随删除；②在添加段落识别框的时候如果有正在识别的进程，会导致新添加的识别框消失）。三个部分：
  **① 删段级联删除成员行与单字（models 新增 PageAnnotation.removeParagraphWithLines + editor_page._deleteSelectedParagraph）**——原实现只把段从 paragraphs 里移除，成员行全部留下（paragraphId 指向死段的孤儿行，画布上仍在、导出里仍算内容）。新方法按 lineIds 与 paragraphId 双口径取并集删行（lineIds 可能滞后于行拖移后的实际归属），其它段 lineIds 里指向这批死行的历史引用一并清理，返回删除行数；编辑器删段调用它并按"选中行/字是否仍在行列表"清理选择、rebuildBlocks、落盘。与「清除本页段落」同口径。
  **② 手动空段钉住保留（models.rebuildParagraphs + editor_page._rerecognizeParagraph）**——"新画的段消失"的根因：新段保存后要等自己的段级联去识别补行，这期间它是空段（区内还没有行框，或刚认领的行被并发识别的"删旧插新"替换、lineIds 被清空）；而并发识别的回包合并会走 rebuildParagraphs 的 `removeWhere(manual && lineIds.isEmpty)`（区域级联）或 _rerecognizeParagraph 的掏空段清理（段级联），把空段直接删掉——随后新段自己的级联因 ownerDeleted 判定作废，段就永远消失了。修复对齐"manual=用户成果"的钉住哲学（与手工行 isUserPinnedLine、手动主区同款）：rebuildParagraphs 不再移除空手动段（自动段照常重建/清空，含 lines.isEmpty 时只清自动段）；_rerecognizeParagraph 的掏空段清理豁免手动段。空段框由用户在段面板删除。
  **③ 修 v150 遗留的测试基线红（quick_editor_multibox 整批 pending Timer 误报）**——v150 的确认自动导出（TrainExportScheduler）在 ProjectStorage.saveAnnotation 咽喉点排 10 秒防抖定时器，widget 测试的 FakeAsync 区收尾校验无 pending Timer——任何保存过确认标注的用例都误报"A Timer is still pending"（8 条，且 tearDown/addTearDown 时机均晚于该校验，清理来不及）。给调度器加 `@visibleForTesting debugDisabled` 短路开关（true 时 schedule 不排定时器），快设测试 setUp 置 true。
  测试：paragraph_cluster_test 改写「认领后为空的手动段被移除」为保留语义（旧行为正是洗掉新段的元凶）＋新增「页面无行时手动段保留、自动段清空」「removeParagraphWithLines 删段连带成员行与行内单字」（lineIds/paragraphId 双口径、死引用清理、他段不受影响）共 11 条全过；quick_editor_multibox 11 条全过（修复前 8 红）；全量 Dart 491 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）；`flutter analyze` 零问题。纯 Dart 改动，BACKEND_BUILD 不变（v120）。pubspec 1.0.0+151→1.0.0+152。

## 1.0.0+151

- **修复：小字注释分段单行重切/重识别被外扩吞成整列、两字段图上叠满整列识别框＋行级重识别队列的转圈/排队指示三处错乱**（用户反馈：①拆分竖列小字注释单行后，本该两字的行按整列文字识别，两字图片上叠加大量识别框（diag：rect=(885,198,67,183) 被外扩成 (885,0,67,2131)，13 框全叠在段图上）；②连点多行的「重新识别本行单字/重新切割本列」后没有等待转圈、看不到排队几项；③点「重新切割本列」的转圈错位显示在「重新识别本行单字」图标上）。三个部分：
  **① 小字注分段禁止行框外扩（python_service + flutter_app 协议新增 expand 开关）**——根因：单行重识别链路（segment_region → kraken_segment_rect → _expand_line_rect_for_reading → expand_line_rect_to_neighbor_ink）把行框沿阅读轴外扩到"连续墨迹"两端，而夹注小字列的墨迹本身整列连续（字距远小于 0.85×列宽的截停阈），两字分段行框被一路外扩到整页高、切出整列字框。外扩对"唯一行独占列带"仍然正确（行=整列），对"多行共享列带"（小字注分段）则是灾难——app 侧新增 `lineSharesColumnBand`（同方向、跨轴范围重叠 > 较窄行 50% 即共享），编辑器三入口（`_rerecognizeLineChars`/`_resplitLineChars`/`_processNewLine`）与行内重切页按判定传 `expand: false`；后端 `SegmentRegionRequest` 新增 `expand`（缺省 true 兼容旧链路），`kraken_segment_rect` 不外扩并透传单行子链路（修复了单列分支漏传导致子链路二次外扩的隐患）。配套硬化：`expand_line_rect_to_neighbor_ink` 的跨轴窗口从"行框 ±pad"收紧为"原框内自有墨迹范围"——邻列笔画不再经 pad 缝隙喂入外扩链条。
  **② 重新切割本列改走级联队列（editor_page.dart）**——原实现直发后端：连点多行并发触发 GPU 识别门互撞（无 409 重试）、自行 set `_processingLineId` 与队列指示器互相覆盖。现与行重识别同队列（`_queueResplitLine`，key 同为 `line:<id>`：重识别排队时改点重切只保留最新意图，in-flight 结果按 gen 作废），任务体加 isStale 作废检查；AI 检查识别框进行中的入队拒绝保护自动生效。
  **③ 队列指示器重做：入队不清执行中转圈＋排队数可见＋转圈落位到动作按钮**——根因三处：`_enqueueCascade` 的刷新不带活动任务（把正在执行行的 `_processingLineId` 清成 null，即"没有等待转圈"）；行级任务执行中胶囊不显示（看不到排队几项）；转圈只有行级布尔、三个动作按钮共用（重切的圈显示到重识别图标上）。修复：新增 `_cascadeActive` 跟踪执行中任务，`_refreshCascadeIndicator()` 无参化，行级任务执行中且 pending>0 时胶囊显示「识别排队中（N 项）」；`_CascadeTask` 新增 `lineAction`（rerecognize/resplit），`_processingLineAction` 贯通到 `_LineCard._headerRow`——转圈按动作显示在对应按钮（resplit→剪刀、ai-check→魔法棒、null/旧路径→刷新图标兜底）；直发路径（AI 检查本行）改用 `_begin/_endDirectLineProcessing`（'ai-check'）+ try/finally（顺带修复提前 return 泄漏转圈的旧洞），队列刷新不再清掉直发占用。
  测试：Python 新增「expand=False 保持段框几何且只切出段内两字 / 缺省 expand=True 同输入外扩到整列（对照证明开关生效）」（test_seg_kraken_cuts，合成字宽须 <60px——实心块达 60px 会被 _remove_ruling_lines 当版框横线整块扣掉）与「邻列经窄缝不链入外扩」（test_seg_lines）；test_seg_lines/test_seg_kraken_cuts 65 条全过，test_seg_core/test_seg_punct 38 条过，1 红为既有无关基线（seg_layout 的 drop_duplicate_fragment 用例，2026-09-30 备份 baseline_unittest.log 已红）；`flutter analyze` 零问题。BACKEND_BUILD v119→v120（segment-expand-flag，Dart 握手同步，旧后端自动重启——expand 字段需要新后端才会生效）。pubspec 1.0.0+150→1.0.0+151。

## 1.0.0+150

- **修复：确认识别框后训练数据统计不增长（例：新锓希夷陈先生紫微斗数全书正文区一直是 9 条，实际已确认 282 页）＋页眉页脚只作版面标注**（用户反馈三点：①确认识别框不增加统计；②主区快设确认过的正文区应进统计；③页眉页脚不参与段落/行/单字框识别，只作为标注训练模型用）。根因：统计口径是 manifest（已导出数据），而**增量导出只在打开训练页/手动导出/发起训练时触发**——编辑器"确认并保存"后只是重新拉了一次 stats（数字永远是旧账），主区快设的确认更是什么都不触发；识别侧的区域门控只认 region_det **模型**的输出，模型没训出来（样本不足 30）时整页识别无门控，页眉页脚的行/字照常产出并混进内容层训练数据（实测该书 284 页的行/字/段侵入了页眉/页脚/页码区）。四个部分：
  **① 确认即自动增量导出（flutter_app 新 services/train_auto_export.dart）**——`TrainExportScheduler`：确认类保存触发防抖 10 秒的后台 `/train/export`（单飞 + 进行中再确认排一次收尾重跑；失败只记日志，训练页打开时的自动导出仍是兜底）。挂接点与字频账本同款：`ProjectStorage.saveAnnotation` 咽喉点判定 `reviewed || boxesReviewed || 任一版面区 boxConfirmed`（主区快设只确认区域不置页面级标记，故必须看区域位）后调度；草稿保存被该判定短路，整本识别/按主区拆分的逐页机写盘显式传 `machineWrite: true` 抑制调度（批量任务数秒一页连跑数小时，不抑制会反复全库扫描空转）。导出完成广播 `onExportDone`，编辑器订阅它刷新右侧训练数据卡的全局累计数（"全部书籍累计"入账后即跳数）。后端 train_export.py 加导出互斥锁（自动导出与训练页手动导出并发时 manifest 读改写会互相丢账）。
  **② 页眉页脚只进 region_det（python_service/train_datasets.py）**——新增 `confirmed_excluded_regions`（已确认的页眉/页脚/页码/图/表区，proposed 候选不挡数据）：`page_labels` 的 char_det/line_det/paragraph_det（含按行推断段落的回退路径）与 `char_cls_page_items` 一律排除"框中心落在区内"的行/字/段落；region_det 层照常收录全部已确认区（页眉页脚正是它的类别样本）。增量导出按 digest 自动重写受影响的旧页（实测该书 7 页 char_det 因页眉排除被重写）。
  **③ Dart 侧同口径计数**——`PageAnnotation.confirmedExcludedRects/centerInConfirmedExcluded/confirmedGateRegions`（与 Python 侧互指注释、同一协议两半）；`PageCounters.of`（本书进度）与编辑器当前页训练数据卡的段落/行/字计数同步排除；`page_state_cache.json` 升 v3 强制重算一次（旧缓存口径不同）。
  **④ 识别门控认人工已确认区（seg_pipeline/api_segment）**——`/segment` 与 `/segment_lines_in_region` 新增 `gate_regions` 请求字段：Dart 重识别（ensurePageAnnotation force 路径）与本区级联（BookRegionApply.cascadeRegion）带上本页已确认版面区；后端有人工区时**优先于 region_det 模型预检**——直接作门控输入并作为结果的 main_regions 原样带回（不跑第二遍 region_det，确认身份不因重识别丢失）。region_det 模型未训出时，主区快设确认过的页眉/页脚同样在字检测前被抹除。
  数据修复（对既有书库跑一次增量导出即自动补齐，无需迁移）：region_det 9 条 → **698 页/1827 条**（main_text 691、header 632、page_number 483、footer 8、figure 3、table 9），char_det 9190 → 13926，line_det 356 → 408，paragraph_det → 114。
  测试：test_train_export.py 新增 ConfirmedExcludedRegionFilterTests 5 条（内容层排除/region_det 照收、proposed 不挡、段落推断排除、导出端到端入账数）；全文件 13 过；train/training_service/region_gate/train_paths 相关 90 过 + 1 红为既有无关基线（seg_layout 的 drop_duplicate_fragment 环境依赖用例，本次未触碰该模块）；`flutter analyze` 零问题。BACKEND_BUILD v118→v119（confirm-export-gate，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+149→1.0.0+150。

## 1.0.0+149

- **新功能：鼠标手势新增对勾形状（✓，token "CK"）**（用户需求：手势最好能支持各种形状，现在想加对勾却加不了）。加不了的根因：手势识别是"四方向序列（L/R/U/D 主导轴量化）+ 整圈圆特检"两套机制，对勾画出来（短斜下 + 长斜上）会被量化成既有 token（"DU"/"RU" 等），往 GestureCatalog 目录里加条目根本无法区分——必须像圆检测一样走轨迹几何特检。两个部分：
  **① 对勾几何特检（services/mouse_gesture.dart）**——新增 `_detectCheckmark()`（照 `_detectCircle` 同款模式），`finish()` 识别顺序改为圆 → 对勾 → 方向序列（顺带把圆分支与兜底分支重复的清理语句收敛为一处）。判定门（阈值与圆检测同量级，单测锁定）：点数 ≥8 且整体宽 ≥36px（防点击级乱画）；顶点（最低点）比起点/终点各低 ≥12px；起终点分居顶点左右两侧各 ≥10px——正反画法都认，V 形（无长尾）也算；两笔均倾角约 14°–76°（水平/垂直分量互相占比 ≥0.25，轴对齐 L 形（→↑ 等）保持原方向序列语义不被吃掉）；两笔各长 ≥24px 且大体笔直（段内点到弦最大垂距 ≤0.15×弦长——下半圆弧的垂距占比约 0.21，画圆画欠了的 C 形不会误判成对勾，W/M/Z 的弯折同理被排除）。`GestureCatalog.gestures` 注册 `'CK': '✓（对勾）'`，`parseMappings` 与录制面板校验自动生效；三个使用页面（编辑/摆正/快设）纯查表分发零改动；默认映射不动（用户在设置页录制绑定，老用户存档零影响）。
  **② 设置页字形与文案（pages/gesture_settings_page.dart）**——录制结果"标准像" `_GestureGlyph` 的特殊字形表加入 'CK'→'✓'（此前逐字符箭头映射会把 C、K 两个字母原样漏出）；用法卡、录制面板提示、无效输入报错三处文案补"对勾（✓，正反画法都认）"。
  测试：mouse_gesture_test.dart 新增「对勾识别（CK）」组 8 条——标准对勾/镜像对勾/V 形 → 'CK'（标准对勾的方向量化恰为 "DU"，正是与既有目录冲突、必须走几何特检的实证）；轴对齐 L 仍是 'RU' 不被对勾吃掉；Z 形/W 形/纯斜线/太小的对勾/下半圆弧不误判；圆优先级回归（整圈仍 'CW'）；目录与持久化断言（'CK' 可绑定）。`flutter analyze` 零问题；全量 Dart 489 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，单独跑即红，历史基线；quick_editor_multibox 单独跑 11 条全过）。纯 Dart 改动，BACKEND_BUILD 不变（v118）。pubspec 1.0.0+148→1.0.0+149。

## 1.0.0+148

- **拼接面板三项改进（用户反馈：①选择上一页时顺序应反过来或可控制；②自动对齐好像没任何变化；③预览窗太小看不清）**。三个部分：
  **① 拼接顺序可控（谁上谁下/谁左谁右）**——面板新增「上下顺序/左右顺序」切换（本页在上/拼入页在上，左右拼对应"在左"），默认按书序智能推断：**拼入页在书序上靠前（上一页）时自动作为前段**（读序自然，正是用户反馈的场景）；手动切换后记住选择（换拼入页不重置）。实现为前端换序（后端 image_a 恒为前段），落账语义不变（结果仍覆写本页矫正图、拼入页删除）。拼入页下拉同步标注「· 上一页」，面板头行标注两页各自的前段/后段与输入画面（矫正图/原图）。
  **② 自动对齐改梯度域相关（修"看不出变化"）**——根因：对齐用的是接缝带墨迹列投影的皮尔逊相关，而**原始投影被文本块的大包络主导**——整版文字的两条接缝带在任何错位下都"高度相似"，相关峰不显著（置信不足门限直接回落 offset=0），切开关自然看不出任何变化。修复：相关计算改为**梯度域为主（0.7 权重）+ 包络为辅（0.3）**——投影差分突出文字列/竖线的边界，错位才产生显著峰；置信门限提为常量 _ALIGN_CONF_GATE=0.35（混合分口径）。周期性文字列在 ±列距 处存在等价峰（投影法固有），包络项辅助挑真峰，残余歧义靠手动错位兜底。
  **③ 面板改全屏布局（左大预览/右控制面板）**——原来是 640px 对话框里嵌小预览，接缝细节看不清。重构为全屏：**左侧预览占满主要画面**（InteractiveViewer 可缩放 8 倍细看接缝），右侧 400px 固定面板（拼入页/方向/顺序/开关/微调滑条纵向排列可滚动，底部常驻「拼接判定」摘要块与确认按钮）；预览分辨率上限 1400→2600px，大预览缩放不糊。
  测试：Python 新增「整版竖排文字列错位恢复」（宽墨列+间隙+加宽列打破周期性，B 左移 24px 自动恢复 offset=+24±4 且缝两侧墨迹质心对齐——旧实现的原始投影相关在该场景峰不显著），9 条全过；Dart 端到端补顺序断言（默认「本页在上」与「拼入页在上」切换件均在；默认下一页拼入时请求 image_a=本页不变），2 条全过；flutter analyze 零问题。BACKEND_BUILD v117→v118（stitch-order-align，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+147→1.0.0+148。

## 1.0.0+147

- **校对摆正两项新功能：Ctrl+滚轮按当前形状整体缩放裁切框；多页智能拼接（连续表格/图片跨页拼成一页，可上下拼/左右拼 + 微调）**（用户需求：①按住 ctrl 然后使用滚轮，可以调节整个框按照现在的形状放大或缩小；②加入多页拼接的功能，可以配置是上下拼还是左右拼，并且不只是把两页包括空白区域的图片拼成一页，而是智能的把两页的内容拼接成正常的好像一页的内容，例如两页中连续的表格或连续的图片，增加一些调节功能能让两页拼的更准）。四个部分：
  **① Ctrl+滚轮整体缩框（pages/straighten_page.dart + models/page_quad.dart）**——绕质心等比缩放四角（新增 `PageQuad.scaled`，形状严格不变）：放大受图像边界约束（按各角点方向算出本趟允许的最大系数，到边即止，不做破坏形状的逐点钳制），缩小保底角点距质心 ≥12px；一格滚轮（±120px）≈ ±6%（微调档：初版 15.5%/格，用户反馈变化太强改为约 6%/格），触控板小步平滑。实现上有个绕不开的坑：**InteractiveViewer 的滚轮处理在监听器里直接改矩阵、不进 PointerSignalResolver 仲裁，外层拦不住**——开着它 Ctrl+滚轮会"缩框+缩视图"双动。因此画布 IV 关闭内置缩放手势（scaleEnabled:false），滚轮全部由本页处理：普通滚轮复刻 IV 的"指针下场景点不动"缩放（exp(-dy/200)，与默认 scaleFactor 一致，widget 测试断言缩放系数精确吻合），Ctrl+滚轮缩框。顺带底栏重构为**左簇（工具/开关/徽标/提示）可横向滚动 + 右簇（拼接/删除/确认）常显**——会话模式加"拼接"按钮后底栏自然宽度超窄窗口（右侧预览面板挤占后 ~700px）必溢出（widget 测试实测 800px 窗口溢出 133px）。
  **② 拼接算法（python_service 新 page_stitch.py + api_page.py 的 /stitch_pages）**——三步而不是整图首尾相接：**裁空白**（Otsu 墨迹掩码行投影找上页内容末行/下页内容首行，各留 max(6px, 0.8%) 纸边余量，缝两侧同为纸白、硬拼缝不可见）；**内容对齐**（接缝带列投影的皮尔逊相关峰恢复横向错位——连续表格的竖线靠它跨缝对齐，搜索范围 ±8% 宽，相关 <0.45 不动宁可不错位；行投影相关 ≥0.80 识别重复扫描重叠并抵扣高度，窗口独立取两页短边 20%）；**接缝融合**（重叠带内逐行线性淡入，无重叠时硬拼）。底色取两图边界的纸色中位数。direction v/h 互为转置；手动 overlap/offset 优先于自动（仍安全钳制）。trace 返回裁切量/错位/重叠/置信度供面板展示。
  **③ 拼接面板（pages/stitch_dialog.dart，新文件）与会话链路**——批量摆正会话底栏新增「拼接」：选拼入页（默认下一页，标注"已确认"与"原图/矫正图"）、方向（上下/左右）、自动裁空白/自动对齐开关、手动重叠/手动错位滑条（关=自动）、接缝羽化宽度；参数变化 500ms 防抖自动刷新预览（base64 小图），trace 摘要一行展示自动判定值与置信度。确认后 /stitch_pages 写盘覆写当前页矫正图 → 宿主落账（`mergePages`）：当前页记 merged/confirmed/useWarped，拼入页走既有删除链路（文件/标注/列表/状态），编辑器翻下一页或退出。**合成页语义**：merged 页的"修改"直接编辑拼接结果图（源图已不含全部内容，quad 与源不再对应），且不参与增强设置变更的自动重做（重做会用源图拉平覆盖拼接结果）。
  **④ 测试注入口（services/python_service.dart）**——新增 `debugHttpClient`（@visibleForTesting）：_post/_get 优先走注入 client。widget 测试的 FakeAsync 区里真实 socket 永不完成（测试框架还会把 HttpClient 全局拦截成 400），MockClient 同步回放让整条 HTTP 链路确定性走完（IO 类仍靠 tester.runAsync 放行）。
  测试：Python 新增 test_page_stitch.py 8 条（竖/横拼裁空白且缝两侧紧邻内容、跨缝竖线自动错位恢复（offset=+20±4、缝上下墨迹质心对齐）、手动重叠/错位优先且高度=裁后和−重叠、复拍重叠自动识别≥40px、空页不裁不抛信号低不错位、羽化带逐行线性混合的精确像素断言、端点 preview b64/写盘/缺 out_path 400）；Dart page_quad_test 新增 scaled 3 条（等比+方向不变/显式中心/自交性不变）；straighten_page_test 新增滚轮 3 条（Ctrl 放大系数 1.0618（≈6%/格）精确吻合且视图不动、缩小档系数吻合+连续放大钳到图边并贴边、普通滚轮视图 ×0.5488 框不动）；straighten_batch_page_test 新增端到端 1 条（假后端：自动处理→修改→拼接面板默认参数→确认→列表剩 1 页/拼入页文件删除/状态记 merged+confirmed+use_warped/编辑器自动退出）。`flutter analyze` 零问题；全量 Dart 481 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）；Python 页面域 48 过。BACKEND_BUILD v116→v117（page-stitch，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+146→1.0.0+147。

## 1.0.0+146

- **新功能：校对摆正页接入鼠标中键手势——画整圈旋转页面（圈向即旋向），L 形（←↓）确认并下一页**（用户需求：校对摆正也加入手势功能，画圆圈是旋转页面，L 形状是确认并下一页）。三个部分：
  **① 手势配置第三套映射（services/mouse_gesture.dart）**——`GestureSettings` 新增 `straighten`（校对摆正页手势 → 动作，独立于快设/校对两套），动作目录 `straightenActions`：顺时针旋转 90°（rotateCw）/ 逆时针旋转 90°（rotateCcw）/ 确认并下一页（confirmNext）。默认映射：←↓（L 形）=确认并下一页、↻（顺时针圆）=顺时针旋转 90°、↺（逆时针圆）=逆时针旋转 90°。持久化沿用同一 JSON 键（mouse_gesture_settings_v1）：straighten 键晚于该格式加入，**老数据整键缺失与空表一并回退默认**（不回退则老用户进页无手势可用）。
  **② 校对摆正页接入（pages/straighten_page.dart）**——照书籍校对页同款模式：页面顶层 Stack 挂 Listener 整窗中键感应（画布/预览面板/底栏上拖动均识别）+ IgnorePointer 橙色轨迹层（松手即消失）；动作分发走既有链路（`_rotate` 自带 _rotatingBusy 守卫与取消回退记账 _netTurns、`_confirmAndNext` 自带 _busy/裁切框合法性守卫），载页/应用中乱画不会触发半成品操作。中键与画布天然无冲突：Flutter 拖动识别器默认 allowedButtonsFilter 只认左键，中键拖动不会误拖裁切点/分隔条；右键平移、左键拖点、滚轮缩放不变。独立模式（无宿主）没有"下一页"，confirmNext 落到「确认摆正」同链路（确认即退出）。
  **③ 手势设置页新增分区（pages/gesture_settings_page.dart）**——「校对摆正（裁切框调整）」映射卡照既有动作视角（动作行 + 已绑手势 chips + 录制/清除 + 松手即存）；`_recordGesture` 的 editorScope 布尔参数升级为 `_GestureScope` 三值枚举（quick/editor/straighten），映射表/动作目录/落库三处以 switch 收敛；感应范围说明同步（校对、摆正为整个窗口）。
  测试：mouse_gesture_test.dart 持久化组补 straighten 断言与新用例「straighten 键整键缺失回退默认」（老数据迁移，旧实现 straighten 为空表必红）；straighten_page_test / straighten_batch_page_test 补 SharedPreferences mock（进页 initState 加载手势配置触达 prefs，缺 mock 时 MissingPluginException 5 条红）。`flutter analyze` 零问题；手势相关 26 条、摆正相关 7 条全过；全量 Dart 472 过 + 2 红（tool_export_crowd_tasks 既有环境依赖基线红；quick_editor_multibox +145 新用例在全量并发下超时未完成、单独跑 11 条全过，与本次改动无关）。纯 Dart 改动，BACKEND_BUILD 不变（v116）。pubspec 1.0.0+145→1.0.0+146。

## 1.0.0+145

- **修复：校对页改过的主区形状进主区快设后被旧形状替代（两功能同步为"最后修改者胜"）**（用户反馈：在校对页改变了主区的形状，再进主区快设，修改没有跟随进去，反而被快设中原先的形状替代）。根因不在"进快设前没落盘"——`_openBookRegionGrid` 本就有 `_cancelPendingSave + await _flushSave` 临时落盘；真正的洞是**主区快设网格与单页快设编辑器全部基于网格 push 时的内存快照工作，动作时刻从不重读盘**：校对页改主区形状会触发级联重识别（`_queueRegionCascade`，后端秒级返回后 `await _save()` 再过 800ms 防抖才落盘）——这个 flush 完全可能发生在网格快照建立**之后**；此后快设里的任何写盘（单页编辑器「确认并下一页」、缩略图拖拽保存）都以旧快照为基线**整文件落盘**，把盘上更新的主区形状连同级联带回的行/字数据一起盖回旧态。修复三处，口径统一为**动作时刻以盘为准**：① 单页快设编辑器 `_loadPage`（进页/每次翻页）直接 `loadAnnotation` 读盘构建草稿基线与确认状态（不再吃 `regionRectsFor`/`extraRegionsFor` 快照回调，两回调与网格侧 `_regionRectsAt`/`_extraRegionsAt` 一并删除；`regionConfirmedFor` 保留供"跳到下一个未确认页"的前瞻导航用）；② 网格 `_saveRegion`（单页编辑器保存与缩略图拖拽共用咽喉）合并基线改为读盘——本次保存是用户最新动作，落盘 = 新盘态 ⊕ 本次改框，外部写进盘的行/字/表格不再被洗掉；③ 网格 `_editPage` 点格子进编辑器前先重读该页盘上标注刷新快照（格子显示与前瞻导航同刻新鲜）。反方向（快设改完回校对页）沿用既有闭环：网格任何落盘置 `_diskTouched`，返回时编辑器重读盘。
  测试：quick_editor_multibox_test 新增 2 条真实链路用例——「网格会话期间外部改的主区形状（模拟级联 flush 后落盘），进单页编辑器直接确认后盘上仍是新形状且带确认标记」（旧实现确认会把旧形状连确认标记写回盘，必红）；「外部写盘带回的行数据在快设确认后保留」（旧实现整文件旧快照落盘行全丢，必红）。写入侧用同步文件 API（真实异步 IO 在 testWidgets 的 FakeAsync 区永不完成，+141 已踩过）。`flutter analyze` 零问题；纯 Dart 改动，BACKEND_BUILD 不变（v116）。pubspec 1.0.0+144→1.0.0+145。

## 1.0.0+144

- **改进：主区快设确认的版面区全量进入 region_det 训练数据（原"整本识别完成才导出 + 每书一次性抽 8 页"两道门槛移除）**（用户需求：主区快设中所有确认过的主区区域、页眉页脚等识别框都进入训练数据统计，都可以用来训练模型）。核实结论：标签口径本就收全类（`page_labels` 对 region_det 收所有 `box_confirmed` 的 main_regions，主区快设「确认并下一页」打的 boxConfirmed 任意类别都算），但增量导出链路（训练页「生成数据集」走的 `/train/export`）有两道门槛把大部分确认成果挡在外面——① **书级门槛**：`sample_region_pages` 要求 `recognition_status == completed`，只走过主区快设、没跑整本识别的书 region_det 一页都不导；② **抽样门槛**：即使完成，每书首次导出时确定性随机抽 8 页（REGION_SAMPLE_PAGES）并永久固定，其余页确认的版面区永远进不了数据集。修复：两道门槛全部移除——凡有已确认版面区的页**全量**进入 region_det，与整本识别完成解耦（版面区是纯几何成果，确认语义只看 box_confirmed）；导出与统计（scan_pending/待导徽标）共用新裁决 `train_manifest.region_eligible_pages`，永不漂移；页级增量 + digest 语义不变（只写新增/变化的页）。抽样时代的 `region_sampled` 清单记录已无读取方，留在旧 manifest 文件里无害不清理；此前被抽样挡掉的页在下次导出自动补齐。删死码：`REGION_SAMPLE_PAGES`/`is_region_sampled`/`record_region_sample`/`sample_region_pages`/`region_sampled_pages`/`book_is_completed`/`_allowed_region_pages_readonly` 与报告里无人消费的 `new_books` 字段。
  测试：test_train_export 的 RegionSamplingTests 重写为 RegionExportTests 3 条（12 页确认全量导出且书未完成也导、首导后新确认的页增量补上——旧一次性抽样语义下必红、无确认版面区的页不产生 region_det 样本）；test_training_service 一条断言按新语义改（书未完成 region_det 也计 1——正是本次需求的行为）。训练相关 49 条全过。训练页提示文案与 README 训练数据说明同步（"需整本识别完成后一次性抽样导出"→"主区快设/编辑器确认过的框全部计入，无需整本识别完成"）。BACKEND_BUILD v115→v116（region-export-all，Dart 握手同步）。pubspec 1.0.0+143→1.0.0+144。

## 1.0.0+143

- **改进：自动加页眉/页脚候选框支持竖排书页（原规则只认横排条带，竖排页眉页脚全靠碰运气）+ 真实扫描噪声治理**（用户反馈：自动识别页眉页脚，识别出来的都是横向的框，竖排的不行）。两个部分：
  **① 竖排对称检测路径（后端 region_prelabel.py）**——原规则按**行投影**聚"顶/底条带 vs 正文"，竖排书几乎每行都有墨、整页聚成一整条，规则整页空转；天头书眉列即使碰巧兜住也会被并成一个横向大框（用户所见"识别的都是横向的"）。新增按**列投影**的对称路径（`_x_bands` 列带 × 行簇切分，与横排"y 带 × x 簇"同构）覆盖四类竖排元素：**天头/地脚竖排短列**（书耳题名、眉批列、叶码列——逐列出框不并大框，行簇允许 5% 页高越界松弛）、**边栏短列**（边栏外竖排书名，左右 15% 边条内、簇高 ≤0.5×正文簇高，按纵向位置归 header/footer/margin_note）、**版心短列**（题名/叶码，中心在页面中线或跨页扫描的 1/4、3/4 线 ±8% 内，只报有把握的：上半→header、下半→footer、像页码的→page_number）、**跨页同位佐证**（`_cross_page_hits` 泛化为双轴：竖排列比归一化 x，横排带比归一化 y）。横排页整段文字聚成一条宽带、行簇切不开，新路径自然空转不误报（既有横排测试全绿锁定）；两路建议按交集/小框面积 >NEAR_DUP_IOU 去重留置信高的。
  **② 真实扫描噪声治理（调试中实测暴露）**——用仓库五张真实样张逐张核对（明清刻本/宋元刻本边角裁剪图人工确认：页缘全是装订阴影、纸边卷曲、摄影背景、水渍霉斑，非文字），加了四道门：**页缘清零**（四边 2.5% 边距内墨迹清零，坐标系不动——真实扫描的顶/底缘噪声曾让两条路径各报过整页假候选，旧代码在干净刻本页上也报过 6 个假眉批）、**尺寸门**（候选框高 ≥1.2% 页高、宽 ≥0.4% 页宽，下限 10/8px——版框残线/纸边碎屑都是细条）、**填充率门**（竖排候选框墨迹密度 ≥8%——扫描碎屑常 <5%）、**纸边暗带判据**（顶/底行簇横贯 ≥60% 页宽且是连续暗带或 ≥5 游程碎屑散布 → 整簇不报；单个"列"游程宽 ≤1/4 页宽；横排路径新增"带底紧贴纸边（<5% 页高）不报"）。治理后五张样张：干净写经/明清刻本 **0 候选**（旧版报 6 假眉批）、宋元刻本只剩 1 个真书耳（治理前噪声最高 92 个/页）、先秦/汉魏样张各 1~2 个合理候选。
  测试：test_region_prelabel.py 新增 VerticalPageTests 6 条（书眉列/叶码列在正文列正上下方逐列出框且去重不重复、天头两列小字不并横向大框、边栏中部竖列、版心题名+叶码、竖排列跨页同位重复加权 ≥0.7、纯正文竖排页零误报），21 条全过（含横排回归与端点级测试）。真实样张端到端冒烟见上。BACKEND_BUILD v114→v115（prelabel-vertical，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+142→1.0.0+143。

## 1.0.0+142

- **修复：环境检测页「进入 OCR」按钮点击后的加载圈与按钮同色、看不出在加载**（用户反馈：刚打开应用点「进入 OCR」，按钮上的那个加载圆圈动画因为和按钮同色看不到）。根因：按钮是 `FilledButton` 且显式指定背景 `colorScheme.primary`，而加载中替换火箭图标的 `CircularProgressIndicator` 未指定颜色，Material 3 下其默认色恰为 `colorScheme.primary`——指示器与按钮底色完全相同，starting 期间视觉上毫无变化。修复：该指示器显式 `valueColor` 取 `colorScheme.onPrimary`（主题前景色，随主题自动适配），与深色按钮底形成对比。同页「重新检测」与卡片操作按钮里的加载圈都在 `OutlinedButton` 透明底上，默认 primary 色可见，不涉及。`flutter analyze` 零问题。纯 Dart 改动，BACKEND_BUILD 不变（v114）。pubspec 1.0.0+141→1.0.0+142。

## 1.0.0+141

- **主区快设单页编辑器两项交互改进（用户需求：①「确认并下一页」跳到下一个还没确认过的页面；②选中框底色不改橙色，保持自身类别色，只有顶点和边标橙）**：
  **① 确认翻页跳过已确认页**——`_saveAndNext` 的落点从"顺序下一页"（`_goNext`）改为 `_goNextUnconfirmed`：确认保存后沿书向后找第一个**尚未确认**的页（确认口径与网格"已确认"角标同一回调 `regionConfirmedFor`：有正文主区全部 boxConfirmed / 无正文页确认过 noMainTextConfirmed），已确认的页直接跳过——逐页过全书不再在已确认页上反复停留；身后没有未确认页时退出编辑器回网格。按钮文案随真实落点联动（`_hasUnconfirmedAhead`）：身后还有未确认页显示「确认并下一页」，全确认过（含最后一页）显示「确认并返回」，不再出现"按钮说下一页、点了却退出"的错位。「跳过此页」按钮与 nextPage 中键手势保持顺序翻页不变；快捷键 Enter 不变。
  **② 选中框底色保持类别色**——快设画笔（`_RegionEditorPainter`）当前框的填充从 orange 10% 改为**自身类别色 8%**（与非当前框同一份填充，选中不换底色）；选中态只由橙色边线（描边 2×unit）+ 4 角点 / 4 边中点橙色手柄方块表达。类别归属在选中态下依然一眼可辨（此前选中页眉框时整片底色变橙，类别信息丢失）。画笔/当前框/chip 相关注释同步改写。
  测试：quick_editor_multibox_test 新增 2 条——「确认并下一页跳到下一个未确认页」（三页书预置第 2 页已确认：第 1 页确认后直达第 3 页且第 2 页不出现、第 3 页按钮变「确认并返回」、确认后退出回网格且第 1/3 页落盘——旧实现顺序翻到第 2 页必红）；「当前框底色保持类别色」（从树中取出私有画笔实例、用录制型画布重放绘制：类别色填充恰 1 次、橙色填充恰 8 个手柄、橙色描边恰 1 条边线——旧实现 orange 10% 底色必红；颜色断言一律按 `toARGB32()` 比较，Paint 内部 float32 存分量，精确 == 不可靠）。顺带修掉新测试自身的两处坑：testWidgets 体跑在 FakeAsync 区，真实异步 IO（createTemp/writeAsBytes）永不完成会挂满 10 分钟超时——文件准备改同步 API、标注写入包 runAsync。`flutter analyze` 零问题；全量 Dart 471 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v114）。pubspec 1.0.0+140→1.0.0+141。

## 1.0.0+140

- **修复：按主区拆分任务运行中退出应用后断点停留在旧页集，「继续拆分剩余 N 页」把已拆分过的页也计入**（用户反馈：主区快设把拆分任务加入队列后退出界面，再回来识别进度没有被保存，仍显示之前的「继续拆分剩余 xx 页」，数字还是没分析过的那些页数）。根因：断点文件 `region_split_progress.json` 只在任务**停止/失败时**写入、**全部完成时**清除，任务启动与运行期间从不更新——「继续拆分」入队跑起来之后一旦退出应用（关窗/崩溃/断电），盘上留下的还是上一轮的旧断点（或首轮任务则根本没有断点文件），重启后主区快设/首页卡片都按旧页集显示与续跑，运行期间已拆分完成的页被重复计入、重复识别。修复：断点文件随任务生命周期**实时维护**——① `_processRegionSplit` 启动即写本次目标页全集（即时作废旧断点与旧 AI 开关）；② 每收账一页就把断点收窄为「失败页∪在途∪未派发」（失败页此后仍由收尾再写一次，语义不变）；③ 全部完成清除（既有行为）。逐页串行 await 写盘避免并发乱序覆盖；一页一次的原子小 JSON 写相对秒级识别开销可忽略。停止/失败/任意时点退出应用，盘上都是「尚未完成的页」，任何入口的「继续拆分」都从真实剩余续跑。README 悬浮窗一节的断点语义描述同步更新。
  测试：新增 `region_split_resume_test.dart` 2 条——假识别后端（按 image_path 分流：挂起页手动放行 500/200、其余秒回空行集）构造确定性时序：**运行中**断言一页完成后断点已收窄为剩余页且失败页留在断点里（旧实现运行中盘上无断点文件，必红）；任务开跑即断言旧断点 [7,8] 被本次全集 [0] 覆盖、全部完成后断点清除（旧实现盘上仍是 [7,8]，必红）。`flutter analyze` 零问题；全量 Dart 469 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v114）。pubspec 1.0.0+139→1.0.0+140。

## 1.0.0+139

- **修复：主区快设「自动加页眉/页脚候选框」点击后逐页全部报错、一页都加不上 + 新增范围选项（仅未确认页/全部页面）**（用户反馈：点了自动加候选框，进度框里失败页数一路涨、没有任何页加上候选；并希望加之前能选是所有页都加还是只给未确认的页加）。两个部分：
  **① 根因修复（后端）**——`api_region.py` 里端点处理函数 `def region_prelabel(...)` 与顶部 `import region_prelabel` **模块同名**：def 把模块级全局名从模块对象重绑成函数对象，处理函数体内 `region_prelabel.suggest_regions(...)` 按调用期全局查找拿到的是**函数自身**而非模块，`AttributeError: 'function' object has no attribute 'suggest_regions'` → 每页请求 500 → Dart 端逐页 catch 记失败（"第 N 页自动加候选框失败：Exception: region_prelabel failed: …"）。该端点自 v97 上线起 HTTP 层就从未通过（主区快设全书批量与编辑器单页「预标注版面区」同伤）；既有测试只测 `region_prelabel.py` 纯函数、从不走路由，所以全绿漏检。修复：处理函数改名 `region_prelabel_endpoint`（路由路径 `/region_prelabel` 不变，客户端零改动；`main.py` 门面 re-export 同步），api_region 顶部加注释说明"处理函数名不得与模块同名"防复发，并补 **HTTP 层回归测试**（TestClient 直打 `/region_prelabel`：建议返回 200 且含 header、缺页 400——旧代码下首条即 500 必红）。BACKEND_BUILD v113→v114（prelabel-endpoint，Dart 握手同步，正在跑的旧后端自动重启拿新代码）。
  **② 范围选项（客户端）**——点击按钮先弹范围对话框再开跑：**仅未确认的页面**（默认；跳过带绿色"已确认"角标的页——主区全部 boxConfirmed 或「确认无正文」的页，与「隐藏已确认」开关同一判定口径，无标注文件的页视为未确认照加）/ **全部页面**（旧行为）。单选项实时显示各自页数（"跳过已确认的页（M 页）/ 包含已确认的页（N 页）"），选择持久化（`region_grid_prelabel_unconfirmed_only`，下次进来保持上次的选择，与「隐藏已确认」同模式）；进度框与结束日志标注本次范围。目标页计算抽为纯函数 `BookRegionGridPage.prelabelTargetsFrom`（与 `splitTargetsFrom` 同模式，加载中返回空并在此时提示"页面标注还在加载"），"已确认"判定抽为 `pageRegionConfirmed` 供角标/目标页/纯函数三处共用。
  测试：python_service/test_region_prelabel.py 新增端点级 2 条（15 条全过）；region_split_targets_test 新增范围选项组 3 条（仅未确认跳过已确认/确认无正文页但保留未确认与无标注页、全部页面不筛、加载中恒空）。`flutter analyze` 零问题（RadioListTile 走 RadioGroup 新 API，与全书叠加对话框同写法）。pubspec 1.0.0+138→1.0.0+139。

## 1.0.0+138

- **改进：校对摆正页拖边中点手柄支持 Shift 法线锁定**（用户需求：拖四条边上的移动点时按住 Shift，可沿垂直于该边的方向平移/上下移动，方便只推边不歪框）。实现：`PageQuad.withEdgeDrag` 新增 `lockToNormal` 参数——按住 Shift 时把指针位移**投影到该边的单位法线向量**（法线取自按下瞬间的快照边，拖动期间约束方向不随边移动漂移），该边两个角点按投影后的位移共同平移（整条边保持与原边平行地沿法线"上下"移动，沿边方向的分量被丢弃）；退化边（两角重合）安全退回自由平移。摆正页 `_onPanUpdate` 每帧实时读 `HardwareKeyboard.instance.isShiftPressed` 传入——**拖动中途按/放 Shift 即时切换约束**，无需先松手；不按 Shift 行为与旧版完全一致（自由平移）。边线本体抓取（落在边线附近即拖该边）与边中点手柄走同一 `withEdgeDrag` 路径，同样享受 Shift 锁定；角点拖动不受影响。侧栏提示文案同步补"拖边时按住 Shift 可沿垂直于该边的方向平移"。
  测试：page_quad_test 新增"边中点拖拽 Shift 法线锁定"组 3 条（水平边位移只保留垂直分量、斜边 45° 位移投影到法线且整条边保持平行+位移与边向量点积为 0、退化边退回自由平移不抛异常）。`flutter analyze` 零问题；全量 Dart 464 过 + 1 红为既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变。pubspec 1.0.0+137→1.0.0+138。

## 1.0.0+137

- **修复：主区快设拖右侧/下部边中点手柄，整条边先跳去与对边重叠**（用户实测：拖四条边的右、下中点调节点时边不跟随指针，先跳到对面那条边上，要松手重新点按才能继续调）。根因：拖边的按下锚点对所有边统一取"指针 − 框左上"，而拖边更新公式是"新边坐标 = 指针 − 锚点"——左边/上边的边坐标原点恰好就是左上（left/top），两两相消正确；**右边/下边的边坐标原点是 right/bottom，锚点却仍按左上折算**：首帧 right = left+Δ 被钳到 left+20、bottom = top+Δ 被钳到 top+20——整条边瞬间贴到对边（最小 20px 间距），之后的拖动都在推一条已经塌掉的边。修复：新增 `_edgeAnchor`，锚点按**被拖那条边自身**的坐标取（右边相对 right、下边相对 bottom，只取该轴分量），指针到边的抓取偏移全程保持、边原地跟随；左/上边行为不变。编辑器页（editor_page）没有拖边手势，不受影响。
  测试：quick_editor_multibox_test 新增"拖右侧/下部边中点手柄原地跟随扩展"用例（画 200×250 屏幕像素框 → 右中点右拖 40、下中点下拖 40 → 落盘断言 w>40 且 h>45——实测修复后 46×56；旧锚点下两边都被钳到 ~20，必红）。`flutter analyze` 零问题；全量 Dart 461 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变。pubspec 1.0.0+136→1.0.0+137。

## 1.0.0+136

- **改进：主区快设编辑器三项交互升级——右侧区域统计、底部快速选框 bar、点空白取消选择**（用户需求：显示当前页各类区域数量；底部 bar 快速选中某个框；点击空白取消选中当前框）。四个部分：
  **① 右侧统计面板**——画布右上角"本页区域"面板：按类别列出已画框数（正文 ×2、页眉 ×1、图片 ×3……只列已画的类，当前类别的名字与计数标橙、与画布"当前框橙色"同语义），空页显示"暂无区域框"；IgnorePointer 纯展示不挡画框手势。
  **② 底部快速选框 bar**——操作栏上方新增横滚 chip 条，把本页每个框列成一颗 chip（类别色点 + 类名 + 带圈序号"正文 ①/②"——带圈序号与顶部类别栏的"正文 1"快捷键提示明确区分），点击即选中为当前框（橙色 + 角点），多框页不用在画布上来回找；无框时显示引导文案。chip 随画/删实时增减。
  **③ 点空白取消选择（含单击框选中）**——编辑器引入"未选中"态（当前框下标 -1）：**单击画布空白取消选中**（画布只剩类别色细线、无橙色框），**单击某个框即选中它**（与拖拽点框切换同一套命中规则）。实现走 GestureDetector.onTapUp——纯点击（无位移）不会触发 pan（识别器未过 slop 即出局），原先只挂在 pan 路径上的取消逻辑对真实点击无效；未选中时「删除当前框」按钮/Del 均为空操作。顺带修复：画布底部"按住左键拖拽"提示卡此前会挡住底部的起笔（Card 未穿透指针，页脚位置画框起笔被它吃掉），加 IgnorePointer。
  **④ 边界防护**——`_activeIndex = -1` 未选中态在 `_activeDraft` 读写与画笔取框三处都要按 `>= 0` 判界（首版 `-1 < length` 为真直接 `list[-1]` 崩溃，widget 测试抓出）。
  测试：quick_editor_multibox_test 新增 3 条（统计面板与 chip bar 实时反映各类框数并随删除同步；点 chip 选中指定框后删除的是该框而非当前框；点空白后删除按钮 onPressed 为 null 且点击空操作、两框保留落盘）。`flutter analyze` 零问题；全量 Dart 460 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变。pubspec 1.0.0+135→1.0.0+136。

## 1.0.0+135

- **修复：校对摆正页旋转几次后页面图被拉伸/裁切且转不回去**（用户反馈：①旋转按钮转几次后页面图被拉伸；②旋转后页面像被裁切、怎么转都无法恢复原状，"原图"页签看到的也不对）。根因在摆正页独有的**内存旋转显示图** `_rotateImageMemory`：输出光栅尺寸写成了随方向取值 `toImage(cw ? h : w, cw ? w : h)`，而 90° 旋转无论方向，translate/rotate 后的内容都落在宽高互换的 h×w 区域——逆时针时光栅仍是 w×h，已转向的内容右/下缘被裁掉、余出空白带（"被裁切"）；显示位图只随顺时针换轴、画布盒 `_fullW/_fullH` 却随后端每次换轴（/transform_page 的 cv2.rotate 精确换轴），两边换轴奇偶失配后 **BoxFit.fill 把宽高比已错的位图硬拉进新盒**（"拉伸"），且会话内无论再怎么转都回不到一致（"无法恢复"）——旋转序列里逆时针次数为奇数即锁死。修复：输出光栅恒为 (h, w)；函数提为顶层 `rotateImageMemory`（原私有方法不可测）。配套两处：**① `_rotate` 盘转向后立即记账 `_netTurns` 并 `FileImage.evict()`**——此前记账在显示步骤成功之后（显示步骤若失败，取消回退会少转一步、文件留在旋转方向），且不失效文件缓存导致"原图"页签走 Flutter 旧缓存显示旋转前的图（`_confirm`/`_undoTurns` 本就 evict，`_rotate` 漏了）；**② 旋转后补 `_schedulePreviewRefresh()`**（此前旋转后右侧矫正预览停留旧框效果图，直到下一次拖拽才更新）。盘上文件链路核实无损（imdecode→cv2.rotate→PNG 编码，纯像素置换不裁内容），取消回退仍逐次转回；旧 bug 期间在画面被裁状态下拖框确认过的**矫正输出图**需重新摆正，源图本身未损。
  测试：straighten_page_test 新增"旋转显示位图：两方向输出宽高互换且角点落位正确"回归（四象限异色位图真实光栅化：CW/CCW 输出尺寸 + 象限落位、竖幅源 CCW、CW×4 与 CW→CCW 往返复原——旧实现逆时针分支必红）；摆正渲染/批量与 page_quad 既有用例全过。后端盘上链路同轮实证清白并加回归锁定：python_service/test_transform_page.py（混合旋转逐步 + CW×4 与 cv2.rotate 参考链逐位对账，2 条过——旋转不裁盘上文件；用户所见"原图被裁"系旧 bug 期间在被裁画面上拖框确认、dewarp 按设计原地覆盖 warped 文件所致，受损页经批量摆正可从真实源图重做，编辑器单页重摆不可恢复）。`flutter analyze` 零问题；全量 Dart 459 过 + 2 红均与本次无关（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红；quick_editor_multibox「点击画布空白取消选择」为偶发红，单跑可复现、系 book_region_grid 画笔越界，待另修）。改动为 Dart 修复 + Python 新增测试（后端代码不动），BACKEND_BUILD 不变（v113）。pubspec 1.0.0+134→1.0.0+135。

## 1.0.0+134

- **修复：ReadingOrderCalculator 竖排分支无视方向参数（列序/列内序硬编码右→左、上→下）+ 基准详情页显示阅读顺序**（用户复查发现：doc 注释声称"列序可由 horizontalDir 反转"，实现里竖排分支根本没用这两个参数；并要求点开图片放大时显示当前文本的阅读顺序）。两个部分：
  **① 竖排方向参数真正生效**——`_reorderVertical`：列聚类初始排序随 horizontalDir（rtl=右→左 / ltr=左→右）、列内行序随 verticalDir（ttb=上→下 / btt=下→上）、依附小注的侧序随 horizontalDir（rtl 右注先读——旧实现 x 升序=左注先读，对古籍双行夹注是潜在错序，一并修正）；模块 doc 注释重写为与实现一致（旧的"→ 不对"半截自我更正注释清除）。对 rtl/ttb 的常规古籍**零行为变化**（全量 Dart 456 过验证导出/编辑器链路无回归）；竖排 ltr/btt 书籍此前会被硬翻回 rtl/ttb，现在尊重设置。横排分支不动。
  **② 详情页阅读顺序可视化**——顶栏新增「阅读顺序」开关（默认开）：行号徽标（深底白字圆角标，选中行红底）按拼文阅读顺序标在各行框左上角，与右侧「识别文字」列表编号一一对应（点列表行高亮图中该行已既有）；图上看序、文上对号，读向（右起左行还是左起、自上而下还是自下而上）一眼可核。
  测试：新增 `reading_order_test.dart` 6 条（竖排 rtl/ltr 列序、btt 列内倒序、readingOrder 序号一致性、小注侧序随 horizontalDir 双向、横排分支不回归）。`flutter analyze` 零问题；全量 Dart 456 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v113）。pubspec 1.0.0+133→1.0.0+134。

## 1.0.0+133

- **修复：朝代基准测试两处与正常书籍识别管线的残余偏差**（用户复查要求：核对是否完全使用正常书籍识别流程）。逐行比对 `ensurePageAnnotation`（整本识别单页管线）与 `DynastyBenchPage._recognizeCase` 后修复：
  **① AI 门控语义对齐**——整本识别的 AI 门控只看项目级 `project.aiRecognitionAssist`（建项目时从全局设置带入，识别时不复查全局开关）；基准页此前多设了一道"全局 enableLineAssist"门控，"全局关但项目开"场景下正常书会跑 AI 而基准会跳过。现改为：本页「AI 整行裁决」勾选 = 项目开关的等价物，唯一残余门控是"已选视觉/文本模型"（与 `applyAiLineAssistToLines` 内部一致）；ai_assist.status 枚举收敛为 applied/skipped-no-model/skipped-toggle（早期 skipped-settings 值按未知值展示，运行记录向后兼容）。
  **② 队列重试语义对齐**——正常识别经 `_recognizePageWithRetry`（409 忙等待 60×5s、后端失联等待 36×5s、真实失败重试 1 次）；基准页此前遇到忙/失联直接记失败。现按同款常数实现（等待期间进度条显示"识别服务忙（N/60）等待重试"），整本识别在跑时基准可排队等完不打断。
  **核对确认一致的其余环节**：/segment（版面+Kraken）→ inferHierarchy（参数逐个相同）→ applyAiLineAssistToLines（同一函数、enabled:true、行级并发 interactive:false）→ rebuildBlocks → ReadingOrderCalculator 重排；模型用当前启用集（不套 per-project modelOverrides——基准本就测当前 active 模型）。**有意保留的差异**：不落盘标注（基准不是书，不写书库）、不写 ai_trace 溯源（无项目目录可写）、pageId 用样张 id（仅持久化身份，无识别影响）。
  测试：`flutter analyze` 零问题；基准相关 Dart 7 条与 `test_dynasty_bench.py` 9 条全过。纯 Dart 改动，BACKEND_BUILD 不变（v113）。pubspec 1.0.0+132→1.0.0+133。

## 1.0.0+132

- **修复：按主区拆分的多主区页不再重复收跨区域边界行**（用户复查要求：核查"按主区拆分"是否完全走正常书籍识别流程时定位）。全面核对结论：**识别管线本体与整本识别完全同链路**——后端 `/segment_lines_in_region` 先跑与 `/segment` 完全相同的整页版面+Kraken 识别（同一批次、同一放大倍数，api_segment 注释明示"保证区域重识别与整页重识别对同一行产出一致"）再按区域过滤；模型同源（`/segment` 请求里的 `model_overrides` 字段后端 `_MODEL_OVERRIDES` 本就只声明未消费，两条链路此刻等价）；AI 整行裁决同一个 `applyAiLineAssistToLines`、开关同源（项目旗标与拆分队列都来自 enableLineAssist）；段落聚类同一个 `_clusterLinesIntoParagraphs` 核心（拆分走 rebuildParagraphs 保留手工段，整页走 inferHierarchy 全新聚类，语义差异是级联保护用户成果的既有设计）。发现的唯一真问题：后端区域过滤按"行中心**或任一字中心**在区内→整行保留"（seg_layout.filter_result_to_region，注释明说跨边界列会重复、留给编辑器去重）——单区域时代旧行会被替换/修剪自然消重，**一页多主区（+128 未裁开双页）逐块级联时，中心在左区、字跨中缝的边界行会被右区批次原样再带回一次**，而 `spliceRegionLines` 只对"用户钉住行"去重，机器行同位置会插两条。修复：去重基准从"仅钉住行"扩为"本批替换后仍留在页面上的全部行"（钉住手工行 + 中心不在本区的机器行）——中心落在已保留行框内的新行即同一物理行不插第二条；单区域级联的边界列与编辑器行级联的同类重复一并消掉。
  测试：book_region_apply_test 新增"多主区逐块级联：跨区域边界行不被后一个区域重复插入"（左/右双主区两次 splice，右区批次带回同位置边界行，断言只保留一份、右区自己的行正常插入——旧"仅钉住行去重"逻辑下必红）；既有 19 条 splice/降级/每类多条用例全过（钉住行去重语义由保留行集合自然覆盖）。`flutter analyze` 零问题；全量 Dart 450 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变。pubspec 1.0.0+131→1.0.0+132。

## 1.0.0+131

- **修复：朝代基准测试改走正常书籍识别管线，并把"实际用了哪条管线"记进运行记录**（用户反馈：测试没有用正常管线、没用 AI 校对、是否用了自训 YOLO 模型也不知道）。四个部分：
  **① 管线对齐**——`DynastyBenchPage._recognizeCase` 从"裸 /segment + 重排"改为与整本识别 `ensurePageAnnotation` 同步序：/segment（版面+Kraken）→ `inferHierarchy`（段落/类型层级，阅读顺序的小注依附依赖它）→（可选）`applyAiLineAssistToLines` AI 整行三步辅助（读行→逐字对应→诊断修复，与整本识别共用同一函数）→ `rebuildBlocks` → `ReadingOrderCalculator` 重排。运行条新增「AI 整行裁决」开关（默认开；仍受全局 AI 开关与所选模型约束，跳过原因分级记录：skipped-settings/skipped-no-model/skipped-toggle）。
  **② 管线元信息回调**——`PythonService.segmentWithSettings` 新增可选 `onSegmentMeta`（engine/ocr/converter/fallback_reason/yolo 诊断），此前这些只写应用日志就丢弃；零破坏（不改返回类型，既有调用方不受影响）。
  **③ 元信息存档与展示**——评测提交项携带 engine/fallback_reason/converter/yolo/ai_assist（后端 `BenchPredItem` 新增同名可选字段原样存档）；样张卡新增管线信息行：`版面 hier（自训 YOLO）`/`版面 opencv（回退：原因）`、YOLO 字模是否加载、AI 状态（已应用含模型名 / 全局未启用 / 未选模型 / 本页关闭）。engine 取值：hier=自训 YOLO 层级模型生效，opencv=回退投影切分（fallback_reason 给原因）。旧记录无这些字段时整行隐藏。
  **④ 端到端实测**（run_20261006_215058，v113 后端）：五张样张全部 `engine=hier、fallback=null、yolo initialized=true`——**自训 YOLO 模型全程生效**；含 inferHierarchy 后指标与此前逐字一致（管线确定性）。测试沙箱读不到应用 AI 设置（SharedPreferences 插件不可用），AI 按 skipped 记录；真实应用内按全局设置执行。
  测试：`test_dynasty_bench.py` 新增管线元信息透传 1 条（9 条全过：engine/ai_assist 存档、落盘、历史摘要不携带）。`flutter analyze` 零问题。BACKEND_BUILD v112→v113（bench-pipeline，请求模型新增管线元信息字段，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+130→1.0.0+131。

## 1.0.0+130

- **修复：主区快设编辑器滚轮缩放一滚就"放到最大"且缩不回去**（用户实测反馈：不管怎么滚页面都会放到最大）。根因：快设编辑器的 `_zoomAt` 用 `T(focal)·S(δ)·T(−scene)` 从恒等式**整体重建**变换矩阵——新矩阵的线性缩放恰好就是单档倍率 0.9/1.1 本身，旧的整页适配缩放被整个丢掉。古籍扫描页分辨率高（适配缩放常在 0.1~0.3），滚一下就从"整页可见"跳到约 1 倍（画面撑满视口＝看起来放到最大），再向下滚也只是卡在 0.9/1.1 之间往返，永远回不到适配视图。修复：增量**复合在旧矩阵上**（在页面坐标系里绕光标焦点缩放后仍走旧变换，`clone` 后右乘 T(scene)·S(δ)·T(−scene)）——与编辑器页（editor_page）滚轮缩放同一套写法，焦点下的页面点缩放前后不动。全书叠加/跨页拆分/摆正页只有整页适配矩阵、无滚轮缩放，不受影响。
  测试：quick_editor_multibox_test 新增"滚轮缩放双向生效且保留初始适配缩放"用例（真实编辑器链路：读画布 Transform 的 x/y 轴缩放，向下滚两档 ×0.9、再向上滚三档 ×1.1，断言缩放按倍率连续变化且可超过适配档——旧实现下首滚即跳成 0.9、断言必红）。`flutter analyze` 零问题；全量 Dart 449 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v112）。pubspec 1.0.0+129→1.0.0+130。

## 1.0.0+129

- **改进：朝代基准测试支持人工查看效果（详情页：原图缩放 + 字框叠加 + 基准/识别文字对照）**（用户需求：测试过可以点击图片放大查看，并显示基准释文、识别出的文字与单字字框等信息，用来人工查看效果）。四个部分：
  **① 字框明细随运行记录存档**——`DynastyBenchPage._recognizeCase` 识别时把重排后的行框/字框（含逐字 text/conf/type）一并放进评测提交项，后端 `BenchPredItem` 新增 `lines` 字段原样存档进 run 记录（格式基准声明在 `dynasty_bench._case_report`：Dart 产消、Python 只存档不解释；历史摘要 `list_runs` 不携带明细保持轻量）。记录体积 ~10KB → ~275KB（含 ~1100 字框）。
  **② 详情页 `dynasty_bench_detail_page.dart`**——样张卡图片可点击进入：`InteractiveViewer`（0.15×–12× 缩放平移）承载原图 + `CustomPaint` 字框叠加（正文蓝/批注橙/忽略灰/选中红，放大到字框显示宽 ≥15px 时在框顶标注识别字），点选单字在底栏显示文字/置信度/类型/行列号/框坐标；顶栏可切换字框/行框显示。右侧面板：「识别文字」逐行列表（点行高亮图中该行全部字框）与「基准释文」逐列/简对照。无字框数据的旧记录自动降级为纯图查看 + 基准释文。
  **③ 命中判定 `hitTestChar` 顶层纯函数**——图像像素坐标 → {lineIndex, charIndex}，重叠框取面积更小者、边界含入、零宽/缺字段框跳过；抽出为纯函数便于单测。
  **④ 开页恢复上次运行**——`DynastyBenchPage._load` 载入样张后从 `runs/` 恢复最近一次运行记录（含指标与字框明细），重开应用即可直接查看上次效果；恢复失败静默（下次运行覆盖）。
  测试：`test_dynasty_bench.py` 新增 1 条（lines 透传存档 + 落盘往返 + 历史摘要不含明细，8 条全过）；新增 `dynasty_bench_detail_test.dart` 4 条命中判定用例（含边界/重叠取小/非法框）。`flutter analyze` 零问题。端到端重跑（run_20261006_213234，v112 后端）：五张样张全部带字框明细（合计 96+76+481+307+145 字框），指标与首跑逐字一致（管线确定性）。BACKEND_BUILD v111→v112（bench-detail，请求模型新增 lines，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+128→1.0.0+129。

## 1.0.0+128

- **改进：主区快设每类支持多个框（图片可多张、页脚/正文左右各一）**（用户需求：区块快设不应每类只能设一个——未裁开的书一页有左右两页正文、页脚左右各一条、插图页可能多张图）。五个部分：
  **① 编辑器多框草稿**——单页快设编辑器草稿从"每类一条矩形"改为 `Map<String, List<Rect>>`（label → 矩形列表，含 main_text）：空白处拖拽**新增**一条（不再覆盖已画的框），点任意框（其它类别或同类其它框）切换为"当前框"（橙色 + 角点，拖动/调角只作用于它），切类别回到该类第一个框；「清除××框」按钮改为「删除当前框」（只删当前框，同类其它框保留；Del 键/中键手势同动作），原"本页原有 N 个框、保存将合并为一个"的提示随合并语义一并移除；画笔按"当前框橙色带手柄、其余框类别色细线 + 类别名标签"逐框绘制。
  **② 落盘整组替换**——`BookRegionApply` 新增 `applyRegionsOnly`（主区整组）与 `replaceLabeledRegions`（任意类整组，替代原"每类一条"的 `replaceLabeledRegion`）：按位置对应保留 id/uid/status/boxConfirmed（训练身份不因改框丢失），前 N 条就地替换几何、多余删除、不足新建 proposed（该类原本无框时主区插最前、其余类追加到尾，否则接在该类最后一条存活框之后）；共用本体 `_replaceLabelRegionSet` 的插入锚点在就地替换**前**取位（替换同位换对象，事后 indexOf 旧对象会得 -1——首版实现实测踩中，新框插到了表头）。主区页面级降级（reviewed/boxesReviewed → 只确认主区）对多框按位快照继承 boxConfirmed；空列表删除该类全部。
  **③ 拆分队列逐主区级联**——「按主区拆分」从"只认首个 main_text"改为对一页**全部** main_text 主区逐块识别：新增 `BookRegionApply.cascadeRegion`（只对指定矩形级联重识别 + splice 合并，不改动区域几何），拆分队列逐块调用——每块只替换合并自己的行，不会把别的主区洗掉（`applyRegionWithCascade` = applyRegionOnly + cascadeRegion，全书叠加页行为不变）；多主区页右页不再被忽略。
  **④ 确认口径收紧**——快设网格"已确认"角标与拆分目标（`splitTargetsFrom`）从"首个主区 boxConfirmed"改为"**全部**主区 boxConfirmed"（多主区页一条没确认过就不算整页已确认），「保存并下一页」给本次落盘的全部主区与所设类别框打确认标记；网格缩略图直接拖拽仍只画主区（拖一个框 = 该页主区整组收敛为这一条，多主区进单页编辑器设）。日志文案区分单框/多框（"主区 N 处（各框坐标）"）。
  **⑤ 全书叠加页语义修正**——叠加"只改框"/级联应用的 `applyRegionOnly` 委托整组替换：对多主区页从"只换第一个、其余遗留"（原实现的行为，多主区时代下不再成立）改为"画的框就是该页主区的全部"。
  测试：book_region_apply_test 重写每类多条组（左右双页脚两条保留 + 第三条插该类末尾、多主区整组替换/补新/删多余/幂等、无主区整组插最前、多主区降级按位继承）＋ region_split_targets_test 新增多主区"全部确认才入队"用例；**新增 `quick_editor_multibox_test.dart`** 真实链路 widget 测试（真实 PNG 网格 → 点格子进编辑器 → 同类拖两个框 + 切页眉画一个 → 确认落盘 JSON 校验 2 正文 + 1 页眉全带 box_confirmed；「删除当前框」只删最后画的框）。`flutter analyze` 零问题；全量 Dart 444 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红；顺手删除上个版本遗留的自述"跑完即删"的一次性脚本 `_dynasty_bench_e2e_tmp.dart`，其引用的 debugSetServiceBase 已不存在、analyze 报错）。纯 Dart 改动，Python 侧区域过滤本就按列表处理（REGION_BODY_LABELS），BACKEND_BUILD 不变（v111）。pubspec 1.0.0+127→1.0.0+128。

## 1.0.0+127

- **新功能：朝代基准测试（先秦→明清五时期古籍样张 × 当前识别管线的固定回归口径）**（用户需求：把各时期古本样张放进测试界面，附应识别文字，跑当前书籍识别管线对比并显示各时期识别率，测试数据落盘供下次对比）。五个部分：
  **① 固定测试集 `test_images/periods/`**——五个时期各一张古籍原件书影（郭店楚简《老子》甲组 / 马王堆帛书《老子》乙本 / 北魏写经《摩诃衍经》卷廿五 / 南宋黄善夫刻《史记》卷二 / 《永乐大典》嘉靖副本卷10110-10112），出处与 OCR 测试要点见该目录 README；`gt/*.json` 为基准释文（unit=简/列，附阅读方向、置信度与释文来源；郭店/马王堆/史记对齐公开整理释文，写经/大典为两轮视觉转写互校）。
  **② 后端评测域 `dynasty_bench.py` + `api_bench.py`**——识别执行留在 Flutter 端（与整本识别同链路），后端收拼好文字的评测请求：归一（剥空白与标点，标点集合复用 recog_eval 口径）→ `recog_eval.align_errors` 对齐出替换/漏/多与混淆对 TOP → micro（字数加权）/macro（样张等权）双口径准确率 → 落盘 `runs/run_<时间戳>.json`（含 BACKEND_BUILD、Kraken/YOLO 各层模型指纹）。识别失败的样张记录 error 但不计入聚合（不把故障当 0 分）。路由：`GET /bench/dynasty/cases`、`POST /bench/dynasty/eval`、`GET /bench/dynasty/runs`。
  **③ 测试界面 `dynasty_bench_page.dart`（首页「朝代基准」入口）**——按年代排列的样张卡（书影缩略图 + 书目信息 + 可展开基准释文 + 置信度标注）；「运行测试」逐张走 `PythonService.segmentWithSettings`（设置按各样张 reading_order）+ `ReadingOrderCalculator` 重排拼预测文本，进度条实时显示当前样张；顶部聚合指标条（整体准确率/CER、跨时期平均、基准字数、用时、失败数），单卡显示替换/漏/多/错字 TOP/耗时。「历史对比」任选两次运行出逐时期准确率对照与 Δ（百分点，绿升红降，失败与 0 分区分显示）。
  **④ 基准目录解析 `dynasty_bench_store.dart`**——默认自动探测仓库内 `test_images/periods`（可执行文件与工作目录向上逐级，标记文件 `gt/01_xianqin.json`），探测不到时页面引导手选并记入 SharedPreferences（目录失效自动回退探测）。
  **⑤ 跨语言分工互指**——识别执行/阅读顺序/文字拼接在 Dart（复用 ReadingOrderCalculator，与编辑器导出同源），指标计算/历史落盘在 Python（与消融评测同源）；run 记录 JSON 字段基准声明在 dynasty_bench.py 模块注释（Dart 只读不写）。
  测试：新增 `test_dynasty_bench.py` 7 条（归一剥标点空白、基准载入排序拼接、指标与落盘回读、失败样张不计聚合、未知样张拒绝、空历史）与 `dynasty_bench_store_test.dart` 3 条（非基准目录拒收、合法目录记住且 resolve 优先、目录失效回退）。`flutter analyze` 零问题。BACKEND_BUILD v110→v111（dynasty-bench，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+126→1.0.0+127。
  端到端首跑基线（run_20261006_210035，本机 4090，整轮 48.8s）：先秦楚简 acc −36.9%（CER 1.37）、帛书 −16.6%（版面仅检出 4/19 列，漏 353）、北魏写经 **+63.8%**（CHAT 模型可读写经体，混淆 TOP 無→无×14 暴露繁简输出问题）、宋刻《史记》+17.2%（多 119 = 小字注文混读）、大典 −60.5%（含药图与横层铺排的特殊版式）；整体 micro 13.8% / macro −6.6%。GT 制作过程中更正两处初判：马王堆图版实为**乙本**（甲本德经开篇顶部残损、本图版首列自顶完整，书风八分隶）；北魏《摩诃衍经》经 CBETA 比对即**《大智度论》卷 25**（敦煌写本惯用此题名）。

## 1.0.0+126

- **改进：AI 并行度面板与压测的四项联动改版**（用户需求：压测按钮只在手动档可见、智能档固定砍到 6 条、手动上限固定 32、爬坡看手填值——都不合理）。四个部分：
  **① 压测入口面板级**——「测试并行数」按钮从手动档行内移到 AI 并行度卡片常驻（四种模式都能测），「上次压测」信息并入按钮同一行；手动档行内改显"上限 N 条（按显存估计，压测后放宽 / 上次结果已过期）"提示。
  **② 智能档直接用实测值**——`resolveAiPermits` 智能档从 `min(实测, 6)` 改为直接采用新鲜压测结果（v2 压测已是真实负载口径＋排队串行判据，实测值即真实上限，无需再保守折半）；未压测仍按显存启发，交互通道预留（后台最多 N-1）不变。
  **③ 手动上限跟实测走**——新增纯函数 `manualPermitCap`（新鲜压测＝实测上限；未测＝显存启发，与智能档同一把尺）：设置页手动步进的加号到上限即停，`resolveAiPermits` 手动档钳制也走它（两处永远一致）；压测完成后手填值若超新上限就地收紧。
  **④ 压测自动爬坡**——`AiStressTester.run` 移除 `targetParallel` 参数：不再看手填值，从 1 条自动逐档爬到测出真实上限为止（失败/超时/排队串行/护栏即停，绝对上限 32 只作安全边界）。
  测试：ai_concurrency 重写手动档断言（未测按启发 2/6、压测后 10、manualPermitCap 同尺）＋智能新鲜压测断言 6→10；ai_stress_test 移除全部 targetParallel 传参（用例名改为"自动爬坡到失败档即停"）。`flutter analyze` 零问题；全量 Dart 433 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v110）。pubspec 1.0.0+125→1.0.0+126。

## 1.0.0+125

- **改进：AI 并行数压测改为真实形态探针 + 排队串行判据**（用户追问"测出的数能否代表真实并发解析书籍"——旧探针是纯文本极小请求（无图、8~16 token），测不出视觉编码耗时与显存占用，且"排队轮完也算过"，实测值系统性偏乐观）。三个部分：
  **① 真实形态探针**——把 analyzeLine 的整行三步分析 prompt 抽成 `_lineAnalysisPrompt`（与真实行裁决逐字同款），新增 `OllamaService.lineStressProbe`：1 张合成行图 + 3 张字图（dart:ui 白底黑字渲染一次、全档复用，像素量级贴近真实裁图）、输出上限 256（真实链路 1024+ 的约 1/4 控制单条时长）、走 `_chatBody` 同一条通道（本地 /api/chat 或环回外部 /chat/completions，**不过 AiRequestLimiter**——探针不能被待校准的限流器卡住），单条 120 秒超时；成功返回耗时、失败返回 null。
  **② 爬坡判定升级**——探针签名 `Future<bool>` → `Future<Duration?>`；开测前先发 1 条预热（模型加载不计档、不当基准）；每档 k 条全部成功且**最长耗时 ≤ 单条基准 ×3 + 15 秒**才算过——判据识破服务端排队串行（真并发下 k 条几乎同时完成，串行队列里最后一条近似 ×k；Ollama 未设 OLLAMA_NUM_PARALLEL 时常见），失败原因单独写明"被服务端排队串行（单条 X 秒 → 并发最长 Y 秒）"。总时长预算 3 → 10 分钟（真实请求更慢），护栏（显存 95% 看门狗/取消/绝对上限 32）不变；旧的极小探针（localOllama/externalOpenAi）删除。
  **③ 缓存 v2**——压测结果 SharedPreferences key `ai_stress_test_v1` → `v2`：新口径（真实负载 + 排队判据）与旧口径不可比，旧结果作废强制重测。
  测试：ai_stress_test_test 重写（预热失败/并发 1 条失败/恒定耗时不触发排队判据；**新增排队串行判据用例**：基准 0.2s、k=3 档每条 16s > 0.2×3+15 → 上限取 2）；真实形态探针两个本机端口用例（本地 /api/chat：4 张图 + num_predict 256 + format json + 真实 prompt 口径；外部环回 /chat/completions：多模态分片 ×4 + Bearer + max_tokens 256；5xx → null）。顺手把 ai_concurrency 一条全量并发负载下偶发的时序用例改为有界轮询（断言强度不变，消 5ms 调度竞态——它连续两轮污染全量验证）。`flutter analyze` 零问题；全量 Dart 433 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v110）。pubspec 1.0.0+124→1.0.0+125。

## 1.0.0+124

- **改进：AI 并行数压测支持"实为本机服务"的外部模型 API**（用户需求：外部 API 常配的是 one-api/LiteLLM/llama.cpp server 等本地网关，如 `http://127.0.0.1:9094/v1`，并发瓶颈在本机、限流器同样管它，却测不了）。三个部分：
  **① 环回判定 `OllamaService.isLoopbackBaseUrl`**——纯函数：地址按既有归一逻辑解析后看 host，localhost / 127.0.0.0/8（整段）/ ::1 / 0.0.0.0 判本机；解析失败保守判非环回（不放开压测）；局域网段（192.168.x / 10.x）**不算**——那是另一台机器，本机显存看门狗对它没有意义。顺带把 `_externalUri` 公开为 `externalUri`（探针复用地址归一），删除冗余的 `externalEndpointForTest` 包装、测试改用公开函数。
  **② OpenAI 兼容探针 `AiStressProbe.externalOpenAi`**——极小 chat/completions 请求（temperature 0 / max_tokens 16 / 60 秒超时 / 带 Bearer），200 即通过；爬坡判定、显存看门狗（环回服务与本机 Ollama 同卡，照常有效）、结果缓存 30 天与一键应用全部复用既有链路，零新状态。
  **③ 设置页入口分流**——「测试并行数」在外部 API 环回地址时正常进测试流程（按来源选探针）；云端地址保留原提示（并发由服务商限速控制）并补充"本机地址可正常测试"指引；"并发 1 条都失败"提示从"确认 Ollama"改为"确认推理服务（Ollama/外部 API）"。
  测试：新增环回判定 2 条（127 段/localhost/::1/0.0.0.0/缺协议/完整端点为真；云端/局域网/空/乱地址为假）+ 外部探针 1 条（本机真实 HttpServer 验证 POST /v1/chat/completions、Bearer 头、请求体含模型名，端口关闭后 false 不抛异常）；地址归一既有用例改用公开 externalUri。`flutter analyze` 零问题；全量 Dart 430 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红；另 ai_concurrency 一条时序用例在全量并发负载下偶发，单独跑稳定通过，与本次改动无代码路径交集）。纯 Dart 改动，BACKEND_BUILD 不变（v110）。pubspec 1.0.0+123→1.0.0+124。

## 1.0.0+123

- **改进：主区快设在拆分任务进行中点返回，直接退回书库**（用户需求：现在弹「后台拆分任务进行中：返回校对页会与后台写盘互相覆盖……」把人拦在快设页里，应该直接回书库等任务完成，不需要这个提示）。两个部分：
  **① 返回导航**——快设页 PopScope 在任务进行中不再弹提示拦截，改为 `popUntil(isFirst)` 连同校对页一起退回书库（栈：书库→校对页→快设页）：任务继续在后台跑，书库卡片可见进度；任务未运行时行为不变（带 `_diskTouched` 返回校对页重读当前页）。
  **② 校对页 dispose 落盘避让**——EditorPage.dispose 原本无条件 `_flushSave()`；任务中直接退栈会走到这里，旧内存标注可能覆盖后台刚写完的这页。新增 `RecognitionQueue.isRegionSplitActive(projectId)`（排队/运行/正在停止且 kind=region_split 才算进行中，快设页 `_splitJobActive` 收敛到同一实现），dispose 时任务进行中则跳过落盘——当前页标注在进快设页前已 flush、任务期间编辑器不可再进入，内容不会变，跳过零损失。
  测试：新增 `test/region_split_status_test.dart`（无任务/出队移除/整本识别任务都不算拆分进行中；入队后 pending 窗口内算；死端口 + 压缩重试，后台任务亚秒排空）。`flutter analyze` 零问题；全量 Dart 427 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Dart 改动，BACKEND_BUILD 不变（v110）。pubspec 1.0.0+122→1.0.0+123。

## 1.0.0+122

- **修复：单字切分不再产出"一个点"伪字框（第二次根因：残缺版框横线）**（用户需求：重切后"人"字下方仍有 9px 高伪字框 `(1061,2122,96,9)`）。根因（page_281 实测定位）：页面底部版框横线残缺段横穿整页（行墨占比仅 20-67%，够不到任何整行清理阈值——`_remove_ruling_lines` 形态学开核 336px 抓不住碎段、`_zero_edge_filler_bands` 只清"从页边连续 ≥85% 暗"的带），行框扩展把它捞进列尾后：连通域路径把它当独立组件（面积超 min_area）、punct-split 把它当"横向占满字宽的横画类字"（一/乙保护逻辑）拆出独立小框——正是日志里 24≠23 数量不符与 9px 框的来源。修复：
  **① `seg_imaging._is_cross_column_band`**——横贯型墨带判别（与既有窄条型 `_is_edge_ruling_fragment` 互补）：沿阅读轴极扁（≤0.2×字高）+ 原始墨迹横向跨度 ≥85% 列宽 + **墨迹越出列界延伸进列间纸白缝**（两侧 3px 边条墨密度 ≥0.3；实测版框带 0.71+/正常字行 0.05）。字内横画与一/乙类横画字停在列界内，不满足第三条，不受影响。
  **② 三处产框路径统一接入**——`seg_chars` 连通域组件过滤（丢弃后 23=期望，组件路径重新被采纳、不再弃用改 cuts）、`seg_refine.split_punct_merged_boxes` 拆片过滤（人+版框带拆开后只留人字框）、`kraken_boxes._tighten_boxes_to_ink` 格过滤（防"整格都是版框带"被横画收紧保下）。
  实测复现（page_281 该行）：版框带 `(1061,2123,96,6)` 被丢弃，23 框高度全部 71-110px，末框即"人"的正常框 (1059,2018,94,92)。
  测试：`test_seg_core.py` 新增 3 条（版框带不成框且不顶翻期望校验；54px 宽『一』不误杀；punct-split 拆片丢带只留人字框）。切分相关 149 用例全过（+1 条与本次无关的存量失败维持 deselected：`drop_duplicate_fragment_lines` 碎片/主行宽比 51% 超 40% 阈值，改动前即红）；`flutter analyze` 零问题。BACKEND_BUILD v109→v110（band-filter，Dart 握手同步，旧后端自动重启），pubspec 1.0.0+121→1.0.0+122。

## 1.0.0+121

- **改进：正确识别率无数据时显示提示行而不是整行消失**（用户实测截图反馈：书库卡片上看不到 +119 的青色正确识别率行）。截图里那本书已确认的 3 页全部是升级前确认的——没有"原始识别文字"基线、不在统计口径内，total=0 时 +119 把整行隐藏，用户以为功能没做。现在改为：**有已校对页但一笔都没进统计时，显示灰色提示行**"正确识别率：暂无数据（升级前确认的页没有修改记录基线，重新识别并确认后开始累计）"，悬停说明累计方法；有数据后自动换成青色比率行。
  测试：`flutter analyze` 零问题；全量 Dart 426 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+120→1.0.0+121。

## 1.0.0+120

- **修复：单字切分不再产出"一个点"的伪字框**（用户需求：单字识别框里混有特别小的框，如"人"字框在该行只剩一个点，根本看不到）。根因：粘连块走 Y 轴投影细切时，笔画交叠常把投影 runs 合并成一段（日志 `projection mismatch: got=1 expected=N`），随后盲等分把切线落进字间空隙，槽内只剩邻字笔画的尾巴，`_tight_rect` 一收紧就缩成 10~27px 的碎片框。两个部分：
  **① 投影数量不符的兜底从盲等分改为版面网格**——`seg_chars.py` `_split_chars_by_y_projection` 数量不符时改调 `_split_by_layout_grid`（优先在字间纯白区间中心下刀、退投影谷值），切线贴着真实字距走，不再固定等高硬切。
  **② 槽位碎片守卫 `_slot_tight_rect`**——等分与网格路径收紧字框时，若槽内墨迹高度不足槽高的 30%（只剩邻字笔画尾巴），退回整槽框：槽框几何与槽位对齐、可见可选中，识别对不齐交给下游序列-框对齐消化；连通域主路径（真实墨迹组件，含句读点等合法小字）不受影响。
  测试：`test_seg_core.py` 新增 2 条（粘连块投影合并→网格兜底无碎片框且每字中心恰好命中一框；等分槽内只剩笔画尾巴→退回整槽）。切分相关 146 用例全过；`test_seg_layout.py` 1 条存量失败与本次无关（`drop_duplicate_fragment_lines` 碎片/主行宽比 51% 超 40% 阈值被跳过，改动前即红）。BACKEND_BUILD v108→v109（Dart 握手同步，旧后端自动重启），pubspec 1.0.0+119→1.0.0+120。

## 1.0.0+119

- **新功能：每本书的正确识别率统计**（用户需求：统计这本书有多少字在识别后被重新修改并确认过，最终看到正确识别率）。三个部分：
  **① 字级基线**——`CharBlock` 新增 `origText`（识别产出时的原始 OCR 文字）：后端识别响应的三处解析点（`/segment`、`/segment_region`、`/segment_lines_in_region`）统一打基线（新字设为当前 text）；此后人工改字、AI 改写、行文本编辑都不碰它；单字重识别的读法是新机器基线（`_recognizeCharBlock` 落字时同步重置）。落盘规则：非空即写 `orig_text`（**没改过的也写**——重载后才能区分"没改过"与"没有基线"）；人工新画字框无基线不写。copyWith 随行。
  **② 账本与聚合**——char_stats 账本条目新增 `accuracy` 字段（reviewed 页记账时同步算 `countAccuracy`：total=已确认且 origText 非空的字数，fixed=其中 trim 后 text != origText 的字数），防抖缓存比对含 accuracy；新增 `bookAccuracy(dataRoot, projectId)` 按书聚合与 `BookAccuracy.rate`。记账/撤账/对账规则复用既有字频链路（重识别撤账后重新确认再计入）。
  **③ 展示**——书库卡片状态区新增一行（青色）："正确识别率 XX.X% · 已确认识别 N 字，其中修正 M 字"，悬停说明口径（人工新框与升级前旧页无基线不计入——旧书重新识别并重新确认后才开始累计）。
  测试：新增 `test/char_accuracy_test.dart` 3 条（origText 序列化往返含"未修改也落盘/copyWith 随行"、countAccuracy 分母与修正判定、rate 计算）。`flutter analyze` 零问题；全量 Dart 426 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+118→1.0.0+119。

## 1.0.0+118

- **改进：按主区拆分排除「框已确认」（玫红框）页 + 主区调整触发页面状态降级为"只确认主区"**（用户需求：框已确认的页不进拆分数量；确认并保存（绿框）或框已确认（玫红框）的页主区被调整后，状态应改为只确认了主区）。两个部分：
  **① 拆分目标口径收紧**——`splitTargetsFrom` 与后台任务 `splitOne` 的防御跳过都改为"整页绿框（isFullyConfirmed，确认并保存）**或**玫红框（boxesReviewed，确认识别框）都不入队"：两种页面级确认都是建立在当前识别结果上的成果，不该被批量重拆洗掉。确认弹窗文案同步。
  **② 主区调整 → 页面状态降级**——`BookRegionApply.applyRegionOnly`（主区快设改框/全书叠加/编辑器主区级联的公共入口）：主区几何**实际变化**（按落盘整数口径比较，幂等保存不触发）且页面处于 reviewed 或 boxesReviewed 时，调用 `resetToProposed` 把页面级确认状态整体回退（几何/文字/候选全保留，行/段/字状态一并回 proposed——旧主区上的框确认不再作数），并把主区自身的 boxConfirmed 身份继承恢复——落点即"只确认了主区"：网格仍显示绿色"已确认"角标、页面边框回落（后续保存为橘黄草稿态），且因不再页面级确认，主区调整后自动重新满足拆分目标口径、可进队重拆。
  测试：`region_split_targets_test.dart` 增玫红框排除用例（绿框/玫红框全书 → 空队列）；`book_region_apply_test.dart` 新增降级组 4 条（reviewed 页降级/boxesReviewed 页降级/几何未变不降级/未确认页不走降级路径），既有"保留 id/uid/status"用例（ann 未 reviewed）不受影响。`flutter analyze` 零问题；全量 Dart 423 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+117→1.0.0+118。

## 1.0.0+117

- **改进：按主区拆分批量识别在未开 AI 时也真并行——拆分窗口放宽到 4 页，后端识别门升为四槽**（用户需求：主区拆分后识别，没有 AI 加入也应该并行拆分）。排查结论：前端拆分队列本就是双页滑动窗口、客户端 HTTP 无串行化、后端 `/segment_lines_in_region` 也走并发门——但门是**双槽**，无 AI 时两页在途已是上限，且第 3 页立刻 409。改动：
  **① 后端识别门 2→4 槽**（`api_base.py` `_RECOGNITION_SLOTS=4`，BACKEND_BUILD v107→v108，Dart 侧握手同步、旧后端自动重启）：整书识别队列仍 2 页在途（客户端窗口未变），拆分无 AI 时可 4 页在途——多页的 YOLO 版面检测（主进程）与 Kraken 识别（daemon 池内按行并行）跨页重叠，GPU 实际并发由 daemon 池成员数（按硬件决策）自然约束，门只限"同时在途的请求数"；独占模式（模型对比/基线评测）的排空与释放改为按槽位数循环，不再硬编码两次。超出槽位的请求仍然立刻 409，客户端忙等逻辑沿用。
  **② 拆分任务窗口自适应**（`recognition_queue.dart` `_processRegionSplit`）：`aiEnabled ? 2 : 4`——开 AI 时保持 2 页（Ollama 行级并发已在填 GPU，窗口再大反而互相挤），无 AI 时 4 页在途把 OCR 阶段跑满。
  测试：后端 `import api_base` 冒烟通过（无 Python 测试断言旧的双槽行为）；`flutter analyze` 零问题；全量 Dart 419 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+116→1.0.0+117。

## 1.0.0+116

- **新功能：按主区拆分进后台队列（识别监控可控制/断点续跑/统一关机）+ AI 行级并行（四档并行度 + 压力测试）**（用户需求：拆分任务显示在识别监控队列、退出主区快设仍运行、队列任务可取消/删除、受全部识别完成后关机控制；AI 队列数量在设置里可调——智能/最大效能/低显存/手动，手动带可行性压力测试）。两个部分：
  **① 拆分任务队列化**——RecognitionQueue 从"整本识别队列"任务化为双类型队列（`recognize`/`region_split`，一本书同时最多一个任务）：新增 `enqueueRegionSplit`，`_processRegionSplit` 承接原网格页的双页滑动窗口流水线（OCR→AI→落盘、按页序收账、停止后在途页落盘为断点、409 忙等 30×2s、keepAwake、整页绿框跳过防御）。进度快照增加 kind/jobPages/remainingPages；停止/失败把剩余页写入 `region_split_progress.json` 断点。主区快设瘦身为启动/观察面板：确认后入队**留在本界面**——任务页锁定（画框/单页编辑器/预标注全禁）并标「队列中/已处理」角标，处理完的页实时重读标注刷新格子，底部条显示"后台拆分中 X/Y · 预计还需…"并可一键停止/打开悬浮窗；**返回键守卫**：任务进行中拦截返回校对页（后台写盘会与编辑器互相覆盖）；有断点时按钮变「继续拆分剩余 N 页」（快照剩余页或断点文件，按当前口径过滤），全量入口保留。识别监控悬浮窗：运行中任务显示类型标签 + **停止按钮**，新增**任务列表**（排队任务每行可删除）；首页卡片适配拆分状态文案并提供「继续按主区拆分」；编辑器入口拦截天然覆盖（progress 非失败态不许进）。关机统一：拆分任务与整本识别共用 `shutdownWhenIdle`（悬浮窗/首页同一开关），主区快设确认框里的勾选直接绑它，删除 +112 的本地关机预约。
  **② AI 行级并行**——`applyAiLineAssistToLines` 由串行 for 改为按限流器后台许可数的 worker 池（共享行号游标；整本识别与按主区拆分同时受益）。新 `ai_concurrency.dart`：`AiRequestLimiter` 全局信号量挂到 `_chat`（所有 AI 请求的统一闸门，设置读不出来时回退保守 2 条绝不挡请求），交互类（编辑器手动单字/单行）插队优先；许可解析纯函数四档（低显存恒 2；手动钳 1~32；智能＝新鲜压测(≤30 天同模型)保守取 ≤6 否则按显存启发 2/3/4/6/8，且总数 ≥3 时给交互留 1 条通道；最大效能＝压测实测值，没测过 8）。OllamaSettings 新增 `aiParallelMode`/`aiParallelManual`（旧 JSON 缺键回退智能/3）。新 `ai_stress_test.dart`：阶梯爬坡压测（k=1→min(32,目标)，每档 k 个 60 秒超时的小请求全成才算过；失败档即停；显存占用 ≥95%（后端 /process_stats）或超 3 分钟自动中止；可取消；绝不按目标值满额发起），结果缓存 30 天。设置页新增「AI 并行度」卡片：四档 SegmentedButton + 档位说明 + 手动 1~32 步进 + 「测试并行数」按钮（进度框可取消，结果弹窗"实测可稳定并行 N 条"可一键应用为手动值）+ 上次压测记录展示（过期/换模型提示重测）。
  测试：新增 `test/ai_concurrency_test.dart`（四档解析/钳制/压测新鲜度/交互通道预留/设置往返/限流器插队行为）与 `test/ai_stress_test_test.dart`（爬坡判 6 条即停/全过钳 32/1 条都失败/显存看门狗/取消/时长预算，全用假探针不发真实请求）；悬浮窗空闲文案断言同步。`flutter analyze` 零问题；全量 Dart 419 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+115→1.0.0+116。

## 1.0.0+115

- **修复：「确认识别框」的页在缩略图上与「临时保存」一样都显示橘黄框**（用户需求：两种状态要有不同的标识和存储状态）。数据模型里 `boxesReviewed`（确认识别框）与 `draftSaved`（临时保存）本是两个独立落盘字段（`boxes_reviewed`/`draft_saved`），但页状态分类（`PageStateMarkers`）只有"已确认/临时保存/有框未确认"三档、没有框已确认这一档——确认过框的页因之前编辑/翻页已置 draftSaved，重载后全部落进橘黄档，与普通临时保存无法区分。改动：
  **① 新增第四档"框已确认"（玫红框 pink.shade600，`PageStateMarkers.boxesReviewedColor` 统一取色，初版用 teal 与已确认的绿过近、按用户反馈换玫红）**——`PageStateMarkers` 新增 `boxesReviewedPages` 集合，分类与边框色插入"已确认（绿）之后、临时保存（橘黄）之前"：确认过框的页即使之后再改文字触发草稿写盘，也保持玫红框（剩余工作是文字校对），不降级回橘黄；编辑器缩略图条、全书网格总览、主区快设网格三处图例同步加"框已确认"。
  **② 编辑器全流程同步新集合**——「确认识别框」保存后立即转玫红框（原来只把页从紫框移除、悬空成灰框）；「确认并保存」、重识别、删页索引平移、墨迹归类部分确认等全部标记增删点补齐；防抖临时写盘不再把玫红框页拉回橘黄。
  **③ 页状态缓存（PageStateCache）**——state 编码新增 4=确认识别框（优先于 2=临时保存），缓存版本 v1→v2：旧缓存把这类页记成 2，升版强制全书页状态重算一次，橘黄误标随之消失（纯派生缓存，重建无成本）。
  测试：`test/unconfirmed_boxes_test.dart` 新增分类口径用例（框确认/仅草稿/确认后又草稿三页分落玫红框与橘黄）；`test/book_cache_test.dart` 新增 state 4 缓存往返用例（含指纹命中路径）。`flutter analyze` 零问题（本改动文件）；相关 3 个测试文件 34 用例全过。pubspec 1.0.0+114→1.0.0+115。

## 1.0.0+114

- **改进：主区快设批量拆分改双页滑动窗口并行 + 「完成后关机」开关移入进度框可实时改**（用户需求：关机开关应该在拆分进度界面；拆分没像整本识别那样用已有的并行多线程处理页面）。两个部分：
  **① 双页流水线**——此前拆分逐页串行（OCR → AI → 落盘 → 下一页）。现采用与整本识别队列（RecognitionQueue）同一设计：**双页滑动窗口**，后端识别门双槽允许两页并发，页 N 的 AI 整行裁决（Ollama）与页 N+1 的 OCR（后端）重叠执行；结果仍严格按页序收账（进度、失败、网格刷新、断点语义与串行一致），点「停止」只是不再发新页、在途两页跑完落盘为断点。配套：409 忙等预算从 6×0.7s 提到 30×2s（双槽被本批占满后 409 只剩编辑器手动识别等外部占用，一页可达数十秒）；批量期间请求系统保持唤醒（SystemAwake，防挂机睡眠中断，与识别队列同款），跑完释放；每页进度文案独立记录，进度框显示最早在途页的阶段（含"等待识别服务（第 N 次）"）。
  **② 关机开关进进度框**——确认弹窗里的勾选只是初值，拆分进度框内新增实时开关「识别完成后关机」（副标题注明 30 秒倒计时可 shutdown /a 取消），跑动中随时开/关，选择持久化；结束时按最新状态决定是否预约关机（用户点「停止」仍然不关）。
  测试：并行流水线与关机预约均为异步页面/系统调用流，按用户场景人工回归；`flutter analyze` 零问题；全量 Dart 404 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+113→1.0.0+114。

## 1.0.0+113

- **改进：校对界面画布上的分区编号标签放大并加强底色**（用户需求：各分区的编号字体大一些、加背景色看得清楚）。画布编号标签（`_drawLabel`，主区/段落/行三个视图共用，含冲突"!"警示）此前是 13px 白字 + 85% 半透明方底——画布缩小或底图文字密集时容易看不清。现改为 **17px 加粗白字 + 95% 不透明圆角底 + 白色描边**（描边把标签与同色框线/底图分隔开），内边距略加大；"!"警示随新标签宽度把右上角偏移从 -14 调到 -20 保持贴角。
  测试：`flutter analyze` 零问题；全量 Dart 404 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+112→1.0.0+113。

## 1.0.0+112

- **新功能：主区快设批量拆分接入 AI 整行裁决 + 「识别完成后关机」**（用户需求：主区快设的重新拆分识别没用 AI 校对？再加识别后关机）。两个部分：
  **① AI 整行裁决接入**——此前主区快设批量拆分走 `applyRegionWithCascade`（`/segment_lines_in_region` + 行合并重建），链路上确实**没有**整页识别那套 AI 逐行三步辅助（读行→逐字对应→切分诊断/局部修复）。现在每页级联完成后按同一口径补跑 `applyAiLineAssistToLines`（与整页识别/整本识别同一份实现，含"开了开关但没选模型→保留 OCR"守卫与 ai_trace 溯源）：批量口径取 AI 辅助设置的**「全书整行裁决」开关**（enableLineAssist，与整本识别一致；"本页/本行"手动开关不触发批量），确认弹窗与进度框明确显示 AI 开/关，AI 逐行进度实时更新当前页标签，局部修复替换字块后重建扁平列表再落盘。
  **② 识别完成后关机**——确认弹窗新增勾选项「识别完成后关机（30 秒倒计时，可在命令行 shutdown /a 取消）」，选择持久化（下次默认沿用）；进度框红字提示。跑完后 `shutdown /s /t 30` 预约关机并 SnackBar/日志告知取消方式；用户主动点「停止」不关机（人在电脑前）；仅 Windows 生效，其余平台记日志跳过；异步预约后重验 mounted 再收尾。
  测试：AI 裁决与关机预约都在异步页面/系统调用流里，按用户场景人工回归；`flutter analyze` 零问题；全量 Dart 404 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+111→1.0.0+112。

## 1.0.0+111

- **改进：主区快设拆分目标改为"主区已确认且非整页绿框"，按钮更名「拆分主区已确认的 N 页」**（用户需求：右上角显示"已确认"角标的页要能重新拆分识别；整圈绿框的页不进入）。+110 的口径是"未确认页"（isFullyConfirmed 为假全部入队），与网格视觉状态对不上：用户按角标/边框理解页面状态。现口径（`splitTargetsFrom` 重写）：**首个正文主区 boxConfirmed**（即网格绿色"已确认"角标，主区快设「确认并下一页」的成果）且**非 isFullyConfirmed**（整圈绿框＝编辑器「确认并保存」过的校对成果，保护不动）的页入队——主区只画未确认的页不拆（主区还没被认可），无正文主区的页（扉页/插图）恒不入队；已拆分过的页按当前主区重新识别、可重复执行；手工行/字框已确认的行不被覆盖的保护不变。确认弹窗与底栏状态文案同步（"N 页主区已确认，可拆分识别"）。`modified`（本次已改）不再参与目标计算，仅保留网格"已改"角标展示。
  测试：`test/region_split_targets_test.dart` 重写为 3 条口径用例（角标页含已拆分者入队／整页绿框与未确认主区不入队／加载中不出半截队列／全书整页绿框空队列）。`flutter analyze` 零问题；全量 Dart 404 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+110→1.0.0+111。

## 1.0.0+110

- **改进：主区快设「按主区拆分」改为未确认页语义，按钮更名「按主区拆分未确认的 N 页」**（用户需求：所有未确认过的页面都根据主区重新拆分识别）。此前目标只有两类：本次改过主区的页（会话内存态）＋从未识别的页（+107 回退队列）——**拆分过一遍但还没「确认并保存」的页两个口径都进不去**，改了主区想重拆没有入口。现口径（`splitTargetsFrom` 重写为全书扫描）：画了正文主区且未确认（isFullyConfirmed 为假）的页**全部**入队，已拆分过的未确认页会按当前主区重新识别、可重复执行；已「确认并保存」且本次未改主区的页不动（校对成果保护）；本次改过主区的页无论确认与否都重拆（主区变了旧识别不作数）；无正文主区的页（扉页/插图）恒不入队。确认弹窗与底栏状态文案同步（"N 页未确认，可按主区拆分识别"；已确认行/手工行不被覆盖的保护不变）。
  测试：`test/region_split_targets_test.dart` 重写为 4 条新口径用例（未确认页含已拆分者全入队／已确认页仅本次改过才入队／加载中不出半截队列／全书已确认则空队列）；`flutter analyze` 零问题；全量 Dart 405 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+109→1.0.0+110。

## 1.0.0+109

- **改进：校对界面书页缩略图列表的滚动条常驻显示且加粗**（用户需求：右侧页面缩略图处要常驻显示滑动条，并且不要太细）。桌面端默认滚动条悬停才现身、平时隐形且偏细，几百页的书靠鼠标滚轮一格格找页很费劲。改动：[AttachedScrollbar]（项目原有的 Scrollbar 防崩包装）增加可选 `thumbVisibility`/`thickness`/`radius` 透传；校对编辑器缩略图列表接入 `thumbVisibility: true, thickness: 10, radius: 5`，并在列表右侧留 12px 专属滑道（纵向列表的横向 padding 不进滚动范围，`_scrollThumbsToCurrent` 的行高定位不受影响），滑块不遮缩略图。其余四处 AttachedScrollbar 调用点不传新参数、行为不变。
  测试：`flutter analyze` 零问题；全量 Dart 405 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+108→1.0.0+109。

## 1.0.0+108

- **修复：主区快设里改小的主区，一进校对界面就变回全页框（且被落盘）**（用户实测截图：快设里设好版心内主区+页眉小框，返回校对界面主区框撑满整页、四边只剩 1~3%——正是"外接全页内容再钳回页边"的形状）。两处叠加的根因：
  **① 载入时的几何修复做错了方向**——`_applyAnnotationClamp`（页面载入/图像解码完成后执行）除了钳回页面边界，还调 `ensureHierarchyContainment`（段扩到含行、主区扩到含段，**只扩不缩**；段落按 mainRegionId/相交兜底/orElse 塞进第一个正文宿主）。而主区快设/全书叠加的 `applyRegionOnly` 是"只改框"语义：换主区几何、行段原样保留等按主区拆分时清理——这两个设计正面冲突：页上还留着识别期的全页行段时，用户刚缩小的主区一被载入就被旧段落撑回全页并立即 `_save()` 落盘。修复：载入时只做页面边界钳制；包含关系扩容只在识别/级联重建之后执行（行重识别/AI 修复/重切等 5 处调用点不变，那时行框是新建几何、容器滞后，扩容才正确）。
  **② 从主区快设返回校对编辑器不重读盘**——`_openBookRegionGrid` 只在返回值为 true（此前唯一来源：批量拆分全部成功）时才重扫状态标记并重载当前页。只改主区没拆分就返回时，编辑器仍持有改前的内存标注：显示旧全页框，翻页冲刷还会把旧框写回盘，把快设的修改整个覆盖掉。修复：网格页新增 `_diskTouched`（改框保存/自动加候选框/拆分/摆正任何落盘动作都置位），返回键经 PopScope 统一 `pop(_diskTouched)`，编辑器据此重读。
  两处修复配合 +107 的"拆分成功自动退出回退队列"后，完整闭环：改小主区 → 返回校对立即看到小框 → 按主区拆分清理区外旧行段。测试：两处均为异步页面流（编辑器整页依赖后端），按用户实测路径回归；`flutter analyze` 零问题；全量 Dart 405 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+107→1.0.0+108。

## 1.0.0+107

- **修复：全书摆正重框后「按主区拆分」永远置灰 + 拆分目标增加"已画主区未识别"回退队列**（用户实测：500 多页全部重新摆正并重画确认主区后，拆分按钮仍是灰的）。两个问题：
  **① 摆正页返回网格时被无条件踢出拆分队列**——单页编辑器里的每次保存都经网格的 _saveRegion 把页加入"本次已改"队列，但从编辑器返回网格时 _editPage 对本轮摆正过的页统一执行 _modified.remove（摆正本来只需要清内存里的旧标注/缩略缓存/尺寸，不该把队列一起清掉）。修复：按盘上现状回填——逐页重读标注文件，有正文主区的页留在队列（图片已换、必须重识别），没有的出队；顺带修复摆正页返回网格后丢"已确认"角标/状态边框的问题（内存标注被清后此前不回读）。
  **② 拆分目标只认会话内存态**——"本次已改"每次进页面从空开始，主区快设分几次做完、中途退出重进（或被①踢出）后队列为空，盘上几百页画好主区从未识别也无处可拆（「开始整本识别」又把"有标注文件"当已完成跳过，帮不上忙）。修复：目标页计算提为纯函数 `BookRegionGridPage.splitTargetsFrom`：有"已改"页时只拆它们（原语义与失败重试不变）；一个都没有时回退扫全书"有正文主区且无行无段落（从未识别）"的页，底栏状态与按钮文案随之显示"N 页已画主区、尚未识别 / 按主区拆分这 N 页"，确认弹窗说明目标来源。拆分成功会写入行/段落，页自动离开回退队列，不会反复重拆。
- **修复：书籍校对打开摆正过的页，主区被旧尺寸钳小并落盘**（用户实测：摆正后在主区快设里画好的主区，一到书籍校对界面尺寸就变了，看起来是被原先的主区外观带偏）。根因不在标注数据，而在编辑器的"几何修复"时机：`_loadPage` 载入已有标注的分支不清零 `_canvasImageSize` 就调 `_applyAnnotationClamp`——此时画布尺寸还是上一页（或本页摆正前）的图片尺寸，`clampAllToImage` 把刚载入的主区/段/行/字全部钳到旧尺寸内并立即 `_save()` 落盘；等真实图片解码完成再按新尺寸钳一遍也救不回来（钳制只裁不扩）。摆正必然换尺寸，所以摆正页必现；快速翻页尺寸悬殊的页也可能中招。两个入口同修：
  **① 换页重置**——`_loadPage` 开头的换页状态重置块里把 `_canvasImageSize` 归零（识别分支原有的同款重置合并到这里），载入分支的钳制改为空操作，等 `onImageReady` 拿到本页真实尺寸后再钳，从此钳制永远用对尺寸。
  **② 竞态守卫**——画布 `_loadImageSize` 异步解码期间又翻了页时，旧图尺寸的晚到回调直接丢弃（顺手 `img.dispose()` 防纹理泄漏），不再把上一页尺寸当本页尺寸回调出去。
- **改进：主区快设「规则预标注」更名「自动加页眉/页脚候选框」并补一句功能说明**（用户需求：改成更容易看懂这个功能是干什么的）。原名"规则预标注"是开发视角术语，用户看不出它会做什么。更名覆盖该功能全部界面文案：底栏按钮、进度框标题、完成/停止 SnackBar、后台日志；进度框顶部新增一行灰字说明"按规则给页眉/页脚/页码/眉批/表格生成候选框，不覆盖已有框，结果需逐页确认"。仅改文案，逻辑零改动（仍逐页调 /region_prelabel、只填空、proposed 待确认、不触发识别）；编辑器主区视图的单页「预标注版面区」按钮名不动。README 两处措辞同步。
  测试：新增 `test/region_split_targets_test.dart` 4 条（回退队列筛选/已改页优先且排序/加载中不出半截队列/全书已识别则空队列）；摆正回填与钳制时机修复都在异步页面流里，靠本次用户实测路径回归。`flutter analyze` 零问题；全量 Dart 405 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+106→1.0.0+107。

## 1.0.0+106

- **改进：「本页没有正文区」确认框增加"本书不再显示"选项**（用户需求：删除正文只使用其他框的时候会弹出「本页没有正文区」窗口，增加一个选项，本书不再显示该提醒）。+102 的无正文页确认弹窗（防忘画/类别没切对的误触）在逐页过无正文书（扉页/插图/眉批页为主）时会每页打扰一次。现在对话框内新增勾选项「**本书不再显示此提醒（无正文页直接确认）**」：勾选并确认后按书记住（SharedPreferences 按项目目录名独立存储，只影响本书，其它书照常提示），本书内此后无正文页点「确认并下一页」直接保存翻页、不再弹窗；本次会话内立即生效。误勾影响可控：无正文页照常显示绿色已确认角标、可重新进编辑器画正文再确认（标记自动清）；提醒的关闭状态在后台日志留有记录。
  测试：`flutter analyze` 零问题；全量 Dart 401 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+105→1.0.0+106。

## 1.0.0+105

- **修复：后端进程中途退出后，界面只剩一句英文"预览失败: ClientException … errno = 1225"，且应用不重启就再也连不上后端**（2026-10-06 实测：凌晨 2:26 后端控制台窗口被关/系统注销，uvicorn 停在优雅关停中途；应用未重启，摆正页预览 `POST /dewarp_page` 撞上已无监听的 1754 端口，SnackBar 直接显示裸的英文 SocketException——本机 winnat 保留了 1054-1753 整段，后端从 1288 探测避让到 1754 属正常行为）。修复分三层：
  **① 交互请求统一出口 + 中文异常**——PythonService 新增 `_post`/`_get`（经 `_guardConnect`）：连接级失败（连接被拒/中断，即后端不在）统一转为 `BackendUnavailableException`，message 是可指导行动的中文（"正在自动重启后端（约需半分钟），完成后请重试本操作"），原始英文异常进后台日志。它**继承 http.ClientException**——识别队列按 ClientException 识别「后端不可达」的长等待分支（+99 引入）零改动继续生效。全部 55 处交互类调用（识别/摆正/导入/表格/校验/聚类/训练/导出等）走统一出口；轮询与探测类 6 处（/health、/process_stats、/kraken/data、/train/log、/train/preflight、/recognition_eval/set）保持原样——用户有意关掉后端时不应被 2 秒一次的后台轮询反复拉活，恢复留给下一次真正的交互操作。
  **② 单飞自动重启**——第一个撞上死端口的交互请求触发一次后端自动重启（复用 start 全流程：端口文件跟随/旧版清理/控制台窗口），进行中的并发请求快速失败为中文提示；2 分钟冷却防止后端反复崩时被无限拉起；应用启动进行中（`_starting`）不并发拉第二个进程；测试环境（`_logServiceDir` 为 null）只转异常不拉进程。应用使用中后端被关后无需重启应用，等半分钟自动恢复。
  **③ start 拆壳**——start 变为薄包装（置 `_starting` 标记 + 调 `_startBackend`），横幅日志支持 `startupLabel`（应用启动/后端自动重启），自动重启在后台日志里可辨。
  测试：新增 `test/backend_down_guard_test.dart`（死端口上 dewarp_page 转中文异常 + 保持 ClientException 类型兼容）；`flutter analyze` 零问题；全量 Dart 401 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+104→1.0.0+105。

## 1.0.0+104

- **修复：+103 品牌更名后用户设置"丢失"（鼠标手势设置完没有被保存等）**（用户实测反馈：鼠标手势设置完没有被保存）。根因不在保存链路（录制即存的单测与实际偏好文件均证实手势当时已成功落盘），而在 **Windows 上 SharedPreferences 的存储路径跟随 exe 版本信息**（`%APPDATA%\CompanyName\ProductName\shared_preferences.json`，由 Runner.rc 元数据决定）：+103 把 ProductName 从模板默认 `flutter_app` 改成「字迹」后，新版读写全新的空目录 `com.example\字迹\`，用户更名前的全部设置（鼠标手势定制映射、Ollama 模型配置、导图导出选项、悬浮窗位置等 8 个键）被整体留在旧目录 `com.example\flutter_app\`——设置页重新打开显示默认值，看起来就是"没保存"。
  **修复：启动时一次性偏好迁移**（新 `services/prefs_migration.dart`，main() 在 runApp 前 await）：读旧目录 `shared_preferences.json`，把当前存储**缺失**的键按原类型（bool/int/double/String/StringList）补入，**已存在的键不覆盖**（更名后新产生的值优先，如用户已重新拖过的悬浮窗位置）；文件键 `flutter.` 前缀剥离、非前缀键跳过；迁移完成（含旧文件不存在/损坏）置 `legacy_prefs_migrated_v1` 标志不再扫盘，中途异常不置标志下次启动重试，任何失败静默放行绝不挡启动。仅 Windows 生效（其余平台路径不随 exe 元数据变，无此问题）。
  验证：除单测外，本机旧目录实际数据（手势 DR=确认并下一页、DR=确认并保存、CCW=确认识别框等）迁入后设置页正常显示。测试：新增 `test/prefs_migration_test.dart` 4 条（缺失键迁入+前缀剥离+已存在键不覆盖+非前缀键跳过、标志置位后旧文件再变也不迁、无旧文件置标志不扫盘、损坏 JSON 置标志不迁不抛）；`flutter analyze` 零问题；全量 Dart 400 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+103→1.0.0+104。

## 1.0.0+103

- **品牌更名：「古籍拆字工具」→「字迹」（ZiJi）**，与「命迹」构成"迹"系列软件；同时更换应用图标（黑金字迹书法图标，与命迹同风格）。改动范围：
  **① 用户可见名称全部更新**——窗口标题（main.cpp，为此在 runner CMakeLists 加 `/utf-8` 编译选项，否则 MSVC 按 GBK 解析 UTF-8 源码标题会乱码）、exe 元数据（Runner.rc 的 FileDescription/ProductName/InternalName，任务管理器与文件属性显示「字迹」）、MaterialApp 标题、首页 AppBar、整本识别结束的关机提示语、pubspec 描述。
  **② 可执行文件名 flutter_app.exe（模板默认值）→ ziji.exe**（windows/CMakeLists.txt 的 BINARY_NAME）；README 运行路径、`diag_enable_crash_dumps.cmd` 的 WER 注册进程名同步更新（曾以管理员运行过该脚本的用户需重跑一次，新的 ziji.exe 才有崩溃转储注册）。
  **③ 安装器同步**——应用名「字迹」、输出包名 `ziji_setup_<版本>.exe`、全新安装目录 `{localappdata}\Programs\ZiJi`（同 AppId 升级安装会沿用旧 GujiBT 目录，均可用）；`ocr_setup.iss` 补 UTF-8 BOM（原文件无 BOM，ISCC 6 会按 ANSI 解析导致中文乱码）。
  **④ 不变项**——书库数据目录仍为 `文档\GujiBT`（8+ 处代码引用，改名会使既有书籍数据失联）、Dart 包名 `gujichazi`、安装 AppId（保证升级连续）、`flutter_app/` 源码目录名。
  图标由 2880×2880 源图逐级降采样生成 16–256px 七档 `app_icon.ico`，窗口图标、exe 图标、安装器图标（SetupIconFile 同源）三处一次替换。pubspec 1.0.0+102→1.0.0+103。

## 1.0.0+102

- **新功能：无正文区的页面（扉页/插图/空白页）也可以确认保存**（用户需求：有的页面没有正文区，这种页面也应该可以被保存）。三个部分：
  **① 页面级标记（PageAnnotation.noMainTextConfirmed）**——"用户确认本页无正文区"的持久化标记：旧 JSON 无键回退 false、false 不写键（旧文件零扰动）；重新画了正文主区后自动清除。快设网格的"已确认"判定扩展：有正文主区看其 boxConfirmed，无正文页看该标记——无正文页确认后同样显示绿色角标、可被「隐藏已确认」过滤。
  **② 「确认并下一页」支持无正文**——正文框为空时不再拦截（原提示"先拖出正文区矩形"），改为弹一次确认"按无正文页保存并翻页？"（防忘画/类别没切对的误触；已画的页眉/页脚框仍照常保存）。落盘：删除已有正文主区 + 置无正文确认；无正文页**不进「按主区拆分」的"已改"队列**（没有可拆的主区），拆分循环对无正文页防御性跳过（历史"已改"残留不算失败）。
  **③ 无正文页的空标注文件随标记落盘**——PageAnnotation 原本"空标注不落盘"的守卫不在快设保存路径上，无正文页会留下带标记的标注文件：整本识别把它当"该页已完成"跳过——对无正文页正是预期行为。
  测试：新增 `test/no_main_text_confirmed_test.dart` 3 条（旧 JSON 回退、两个 fromJson 分支的往返、与既有字段互不干扰）；`flutter analyze` 零问题；全量 Dart 396 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+101→1.0.0+102。

## 1.0.0+101

- **新功能：主区快设内置「校对摆正」+「隐藏已确认」开关状态持久化**（用户需求：把校对摆正功能也放到主区快设中，页面歪了也需要重新摆正；隐藏已确认按钮的状态保存，下次进去还是上次的状态）。三个部分：
  **① 快设单页编辑器内置校对摆正**——AppBar 新增摆正按钮（与编辑器同款）：打开同一套 StraightenPage（8 可拖裁切点 + 透视/弯边拉平 + 去色/锐化）；该页已有框时先确认"摆正后本页框会清空待重框"。摆正完成后：清本页标注文件、warped/ 输出替换本页文件（原图保留）并落盘 project、当前页重载重适配。摆正输出路径规则（原地覆盖/带后缀防覆盖他页）从编辑器私有方法提取为共享函数 `straightenOutPath`（page_quad.dart，单一实现）。
  **② 网格页联动刷新**——单页编辑器 pop 时带回本次摆正过的页集合：网格清掉这些页的内存标注与"已改"标记、失效缩略缓存（PageThumbCache 新增 evict——缓存按页号键、不比对文件路径，不清会一直显示摆正前的旧图）、重探页面尺寸（摆正后宽高可能变化，格子画框的坐标基准）。
  **③ 「隐藏已确认」开关持久化**——快设网格（主区框确认口径）与编辑器左侧缩略图（页校对确认口径）两处同名开关状态各自独立持久化到 SharedPreferences，进入页面时恢复上次的选择（两处"确认"语义不同，不共用键）。
  测试：`flutter analyze` 零问题；全量 Dart 393 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+100→1.0.0+101。

## 1.0.0+100

- **改进：主区快设 Del 删除当前框 + 点击空白/页外不再清掉刚画的框**（用户需求：增加按 Del 键删除这个区的功能；画完的区点击画面外不要取消刚画的框，点击画面外只是取消选择）。两个部分：
  **① Del 删除当前类别框**——快捷键绑定到既有的「清除××框」动作（与底部按钮、中键手势同一链路），底部操作说明同步。当前无框时无操作。
  **② 误触不再清框**——此前的根因：空白/页面外按下即进入画框分支并**立刻覆盖**当前类别的草稿，松手时误触判定（纯点击/小于 8 屏幕像素）把框**置空**——等于点一下空白就把刚画好的框删掉了。修复：按下时记住画之前的草稿，误触时**恢复**（只有真正拖出足够大的框才替换旧框）；指针被系统打断（窗口失焦等）的取消路径同样恢复，不留半截框。点击空白/页外此后对已有框零影响（框保留，等价于"只是取消选择"）。
  测试：`flutter analyze` 零问题；全量 Dart 393 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+99→1.0.0+100。

## 1.0.0+99

- **新功能：圆手势——画一个整圈（↻ 顺时针 / ↺ 逆时针）也能触发动作**（用户需求：手势中我想画一个圆，但是现在不支持）。手势体系新增两个圆手势（CW/CCW），与方向序列并存：
  **① 识别（MouseGestureTracker.finish 优先检测圆）**——几何判定：轨迹绕质心累计转角 ≥ 约 306°（画得欠一点或绕过一圈都认）、首尾大致闭合（间距 ≤ max(1.4×半径, 40px)）、平均半径 ≥15 屏幕像素（点击级乱画不算）；方向由转角符号决定（屏幕坐标 y 轴向下，转角增加 = 顺时针）。来回直线转角相互抵消、C 形半圆不足一圈，均不会误判。识别优先级高于方向序列，两页（快设/校对）运行时与录制面板自动通用。
  **② 目录与配置**——手势目录加「↻（顺时针圆）/↺（逆时针圆）」，录制面板直接画圈即录即存，识别结果显示为 ↻/↺ 大字；映射持久化/容错/换绑规则与方向手势一致。默认映射不含圆（按需自配）。说明文案（设置页用法卡、录制面板）同步。
  测试：`mouse_gesture_test.dart` 新增 6 条（顺/逆时针整圈、欠 330° 与绕过一圈、C 形半圆不误判、小圈不判、来回直线转角抵消不误判、目录含圆且 JSON 往返可绑定）；`flutter analyze` 零问题；全量 Dart 393 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+98→1.0.0+99。

## 1.0.0+98

- **修复：画手势时轨迹只显示起点一个点、不显示完整形状**（用户实测反馈：录制面板里画的时候只显示了一个点）。根因在 `GestureTrailPainter.shouldRepaint`：轨迹层拿到的是 `tracker.trail` 的**同一个活 List 引用**（增量追加），新旧 painter 实例比较 `length`/`last` 时读的是同一份数据，恒判"没变化"——首帧画出起点圆点后再也不重绘。三处轨迹层（录制面板、快设页、校对页）同源受影响。修复：shouldRepaint 无条件返回 true（轨迹是一条折线，无条件重绘代价可忽略；活引用无法靠比较判断，注释说明防复发）。测试：`mouse_gesture_test.dart` 新增回归（同一活引用下 shouldRepaint 必须为 true）与空轨迹/单点 paint 不抛异常；`flutter analyze` 零问题；全量 Dart 387 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+97→1.0.0+98。

## 1.0.0+97

- **改进：手势设置改为"画出来"——录制面板显示当前动作，中键直接画即录即存**（用户需求：手势设置能不能打开一个面板显示当前要设置的动作是什么，然后直接用鼠标中键画出这个手势）。设置页从"手势→动作下拉挑选"重构为**动作视角**：每个动作一行（动作名 + 已绑定的手势 chips + 录制/清除按钮）；点「录制」弹出面板——标题下方大字显示当前要设置的动作名（如"确认并下一页"），在面板绘制区**按住中键拖动直接画出手势**，松手即识别即保存（面板停留，可再画一次覆盖或点「完成」），识别结果显示为箭头大字（如"←↓"+『←↓（L 形）』）便于核对。细节：
  **① 松手即保存走页面级最新映射**——录制面板的保存回调由设置页 State 持有最新映射执行（卡片是无状态快照，对话框期间连续覆盖录制若基于旧快照会丢前一次结果）；手势已被同页其它动作绑定时自动换绑并 SnackBar 提示"已从「xx」改绑到「yy」"（一个手势只触发一个动作，一个动作可绑多个手势）。
  **② 无效输入面板内嵌红字提示**——纯点击（位移不足）提示"未识别出方向"、超过两段提示"手势最多两段，请重画"（与手势目录一致，最多两段如 ←↓）；不用 SnackBar（embedded 设置页可能没有 Scaffold 祖先，showSnackBar 会断言崩溃——测试实测揪出）。
  测试：新增 `test/gesture_settings_record_test.dart` 3 条 widget 测试（模拟鼠标中键拖动：L 形识别落库并显示结果、纯点击不保存停留重画态、三段被拒）；`flutter analyze` 零问题；全量 Dart 385 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+96→1.0.0+97。

## 1.0.0+96

- **新功能：鼠标中键手势——主区快设与书籍校对通用，可在设置页配置映射**（用户需求：给主区快设和正常书籍校对都加入鼠标手势功能并可配置，手势用鼠标中间，如画 L 确认并下一页；书籍识别中的临时保存、确认识别框、确认并保存等都可作为手势项）。四个部分：
  **① 手势引擎与配置（新 services/mouse_gesture.dart）**——按住中键拖出方向序列：四方向（←/→/↑/↓），单段位移 ≥12 屏幕像素按主导轴归向、连续同向合并、序列上限 4 段，位移太小视为中键点击不触发；拖动中窗口叠加橙色轨迹（松手即消失，IgnorePointer 不挡交互）。`GestureSettings` 照 OllamaSettings 模式持久化（SharedPreferences 单 JSON 串，开关 + 两页各自映射，目录外的旧手势/动作自动剔除、空映射回退默认）。默认映射（完整默认，可改删增）：快设 ←↓（L 形）=确认并下一页、←/→=上下一页；校对 ←↓=确认并保存、↓=临时保存、↓→=确认识别框、←/→=翻页。
  **② 设置页（新 pages/gesture_settings_page.dart）**——设置整合页新增「鼠标手势」标签（首页设置按钮直达）：总开关、用法说明、两页各自的映射列表（手势箭头 + 动作名 + 删除）与「添加映射」（手势/动作两个下拉），改动即时落盘。
  **③ 两页挂载**——快设页：页面级 Listener 增中键分支（与右键平移互斥）+ 轨迹层 + 动作分发（确认并下一页/上下页/恢复原区/清除当前类框，后两者从底部栏闭包提取为共用方法）；校对页：页面级 Listener（原仅抢焦点）扩展中键采集，**整窗口感应**（画布/面板/缩略图上拖动均识别——画布对中键本来就丢弃，与左键画框、右键平移、滚轮缩放零冲突），动作分发到确认并保存/临时保存/确认识别框/上下翻页。
  **④ 手势动作触发与按钮完全同一链路**（_saveAndNext/_saveCurrentPage/_saveDraftPage/_saveBoxesOnlyPage/_switchPage），确认标记、临时保存链、翻页冲刷等语义一致。
  测试：新增 `test/mouse_gesture_test.dart` 14 条（方向识别 7：水平/垂直/斜线主导轴/L 形连续同向合并/纯点击/往返序列/段数上限/复用；配置 7：默认值/JSON 往返/无效项剔除/空表回退/copyWith/load-save 往返/损坏 JSON 回默认）；`flutter analyze` 零问题；全量 Dart 382 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+95→1.0.0+96。

## 1.0.0+95

- **修复：主区快设书页图片拉伸错乱（+93 去掉 InteractiveViewer 时 OverflowBox 少了四个边界参数）**（用户实测截图反馈：书页图片显示有问题——上半显示、下方大片空白、框手柄错位游离）。+93 用 `OverflowBox` 替代 InteractiveViewer 的 `constrained:false` 时只传了 `alignment`：**四个 min/max 边界全为 null 的 OverflowBox 不改变约束，是空操作**——页面子树被视口的 tight 约束强制成视口大小，画布 CustomPaint 的尺寸变成视口，painter 把整页图拉伸绘制后再叠加"整页适配"变换，视觉即截图中的错乱（对照 InteractiveViewer 源码 1131-1138 行，其 constrained:false 等价物必须带全 `minWidth:0, minHeight:0, maxWidth:∞, maxHeight:∞` 四个参数）。修复：补齐四参数，页面子树恢复 1:1 自身尺寸。顺手修复次生问题：滚轮 Listener 默认 `deferToChild` 只覆盖页面本身，页面外空白处滚轮缩放失灵——补 `HitTestBehavior.opaque`。测试：`quick_editor_outside_drag_test.dart` 新增布局回归断言（页面子树布局尺寸必须等于页面原始尺寸、手势层铺满视口）+ 滚轮测试改在页外位置验证（opaque 生效）；`flutter analyze` 零问题；全量 Dart 368 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+94→1.0.0+95。

## 1.0.0+94

- **改进：主区快设的识别框吸附参考摆正页方案——角点 100 屏幕像素大范围吸附 + 拖整边，且只对当前选择的框生效**（用户需求：吸附可以参考摆正页面中那些框顶点的吸附方案；页面中有正文、页眉页脚等多个框时，只对当前选择的框进行大范围吸附）。两个部分：
  **① 角点吸附对齐摆正页**——命中半径从 28 提到 **100 屏幕像素**（摆正页角点视觉 13px/命中 100px 的"抓取不需要精确对点"口径；快设视觉手柄 26px），取最近的角；拖动锚点（按下点相对角心的偏移）保持圆心与鼠标对齐不突跳。保留小框保护：吸附半径不超过框短边的 40%（下限 12 屏幕像素）——页眉/页码这类矮框的吸附圈不越过框中心，点框内仍然是移动。
  **② 新增边线抓取（摆正页同款）+ 吸附只认当前框**——落在当前类别框任一边线 ±28 屏幕像素内即拖**整条边**（该边两角一起动、单边平移，调页眉下边界/页脚上边界不再需要精确抓角）：边跟随指针（减按下锚点不突跳）、对边沿用按下快照、minSize=20 防倒置、钳回页面范围；四边都近时取最近的一条。角点/边线两级命中**只作用于当前类别的框**——正文、页眉、页脚等多框并存时其它框完全不参与吸附（点它们的框内仍是"切换类别+移动"），不会在相邻框边缘误抓。视觉：四边中点新增小块提示整边可拖。
  测试：`flutter analyze` 零问题；全量 Dart 367 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+93→1.0.0+94。

## 1.0.0+93

- **修复：主区快设页面外拖动画框实际收不到手势（+91 的改法有两处结构错误，页面内也被殃及）**（用户实测反馈：页面外拖动并没有生成识别框）。+91 把画框手势层移到 InteractiveViewer 外层并关闭其拖拽手势，但 widget 测试复现出两个问题：
  **① InteractiveViewer 的手势识别器仍在竞技场**——即使 `panEnabled/scaleEnabled` 全关，其内部的 scale 识别器仍随命中路径先加入手势竞技场（更深处先入场），默认裁决时获胜，外层画框手势一条都收不到（页面内外皆然）；② **手势层被 child 撑不出视口大小**——GestureDetector 的命中范围随 child 渲染尺寸，Transform 的渲染尺寸=页面尺寸，手势层整体缩成页面大小，页外空白收不到事件（原 InteractiveViewer 的 `constrained:false` 兼职承担了铺满视口与保持页面 1:1 两件事，去掉它后两件都得自己做）。
  修复：**彻底移除 InteractiveViewer**，画布结构改为 `GestureDetector（画框）→ Listener（滚轮）→ SizedBox.expand（手势层铺满整个视口）→ ClipRect → OverflowBox（左上对齐、无界约束，页面子树保持 1:1 自身尺寸）→ Transform（矩阵由 TransformationController 驱动，AnimatedBuilder 重建）`；滚轮缩放自实现 `_zoomAt`（以光标为焦点，光标指向的页面点缩放前后不动，方向/范围与 InteractiveViewer 默认一致：向下滚 0.9 缩小、0.05~8 倍）。画框手势从此独享竞技场。
  测试：新增 `test/quick_editor_outside_drag_test.dart` 3 条结构回归（页面外空白按下拖动收到 start/update/end、页面内不回归、滚轮事件到达不与画框冲突）——正是这组测试把上面两个结构问题钉死的；`flutter analyze` 零问题；全量 Dart 367 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+92→1.0.0+93。

## 1.0.0+92

- **改进：主区快设角点吸附范围翻倍——离角点 28 屏幕像素内都能抓到**（用户反馈：现在顶点和鼠标之间的识别吸附范围还是太小了）。+90 接入的命中区是 28×28 屏幕像素方形（实际可达距离约 14~20px），本次改为**圆形吸附圈：角点圆心 28 屏幕像素半径内按下即抓住**（可达距离翻倍，低缩放下随缩放反向放大到页面坐标的更大范围），多角重叠仍取最近的角。两个保护：吸附半径上限为框短边的 40%（页眉/页码这类矮框的两角吸附圈不越过框中心——点框内仍然是移动而不是误抓角），下限 12 屏幕像素保证极小框也抓得到角。视觉手柄方块从 22 略放大到 26（最小 12 屏幕像素），与更大的吸附圈匹配。测试：`flutter analyze` 零问题；全量 Dart 364 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。pubspec 1.0.0+91→1.0.0+92。

## 1.0.0+91

- **改进：主区快设可从页面外起笔画框——手势层覆盖整个视口，框的范围仍限制在页面内**（用户需求：在页面外拖动也能画出识别框只是识别框的范围要限制在页面中）。此前快设编辑器的手势 GestureDetector 挂在 InteractiveViewer 内部的页面尺寸 SizedBox 上：缩小视图后页面四周的空白区收不到左键手势，想从页边外一笔拉出贴边框做不到。两处改动：
  **① 手势层移到视口级**——GestureDetector 移出 InteractiveViewer 包住整个视口（页面外空白也能按下画框/拖角/拖动），回调坐标经当前变换的逆矩阵映射回页面像素（`_toImage`），移动位移按当前缩放折算（`delta / viewScale`）；起点/终点一律 `_clampToCanvas` 钳回页面范围——页面外起笔时自动贴到最近的页面边缘，画出的框始终在页面内。同时给 InteractiveViewer 补 `scaleEnabled: false`：拖拽手势全归外层画框（避免手势竞技），滚轮缩放走框架独立的指针信号通道（`onPointerSignal`，已核对 SDK 源码确认不受 scaleEnabled 影响）照常可用。
  **② 角点锚点语义保持**——上一版引入的"按下点相对角点偏移"锚点基于页面坐标，逆变换后依然成立（按下与拖动同经 `_toImage`），页外起拖角点同样圆心对齐鼠标。
  测试：`flutter analyze` 零问题；全量 Dart 364 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Flutter 侧改动。pubspec 1.0.0+90→1.0.0+91。

## 1.0.0+90

- **改进：主区快设的角点拖动与编辑器正文区同一套手感——圆心对齐鼠标、命中范围翻倍**（用户需求：在主区快设中调节识别框也要和正常正文区中调节识别框一样，调节顶点的圆心和鼠标位置能对齐，并且能大范围的识别鼠标拖动）。此前快设编辑器自写了一套角点命中/拖动：命中半径仅 14 屏幕像素且按固定角序判定（低缩放下多角命中区重叠时容易抓错角）、拖动直接把角点设为指针位置（点击命中区内偏内一点开始拖，角点瞬间跳到鼠标处——圆心与鼠标错位、框角突跳）。本次整体接入编辑器画布与行卡片共用的 [AnnotationHitGeometry] 几何服务（单一实现）：
  **① 命中**——`hitResizeHandle`：28 屏幕像素命中区（随缩放反向放大，整页低缩放下图像坐标命中范围翻倍以上）+ 24 屏幕像素最小兜底，多角重叠取**最近的角**（不按枚举顺序误抓）。
  **② 拖动锚点**——按下时记录指针相对角点圆心的偏移（`_resizePointerOffset`），拖动中角点 = 指针 − 偏移：点击命中区内任意点开始拖，手柄圆心与鼠标保持对齐、无突跳；配合按下时的矩形快照（对边沿用原值）防连续事件的取整漂移，minSize=20 防拖成倒置/零框，结果再钳回页面范围。
  **③ 手柄视觉**——6px 小圆点改为编辑器同款橙色**方块**（22 图像像素、最小 10 屏幕像素、随缩放反向放大），视觉大小与命中区匹配，"点到的地方就是能拖的地方"。
  测试：`flutter analyze` 零问题；全量 Dart 364 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）；锚点几何（resizeRect/pointerOffset）沿用 annotation_hit_geometry_test 既有覆盖。纯 Flutter 侧改动。pubspec 1.0.0+89→1.0.0+90。

## 1.0.0+89

- **新功能：主区快设「确认并下一页」——保存即确认主区框，网格绿色角标 + 隐藏已确认开关**（用户需求：在批量主区块设置界面中点击保存并下一页，就相当于确认了主区块的分割块，在网格视图中会显示成已确认，并且添加一个开关隐藏已确认的页面）。三个部分：
  **① 确认语义落盘（复用 boxConfirmed，零新状态）**——单页快设编辑器「保存并下一页」改名为「确认并下一页」（Enter 同义，最后一页为「确认并返回」）：把主区与本次设置的页眉/页脚等类别框打上既有的 `MainRegion.boxConfirmed`（与编辑器「确认识别框」同字段同口径，天然持久化，不引入新状态文件）；标题栏即时显示"已确认"。确认范围只含主区 + 本次触碰的类别——预标注留下的候选框不强行代确认。「跳过此页」不确认；网格缩略图上直接拖拽画主区是快画（未经人工核对）也不确认。「未改动不落盘」判断从编辑器移到数据侧：几何未变但尚未确认的页，点「确认并下一页」会落盘确认标记（此前编辑器比对矩形相同就整体跳过，确认永远打不上）；几何/类别/确认全无变化则不写盘不标"已改"。拆分与级联链路（applyRegionOnly/replaceLabeledRegion）保留 boxConfirmed，确认状态在后续识别/改框中不丢。
  **② 网格显示与开关**——主区已确认的页右上角显示绿色「已确认」角标（与右下蓝色「已改」错开并存：改了几何待拆分 vs 框已核对；拆分成功后"已改"出队只余"已确认"）；图例行新增 FilterChip「隐藏已确认」：开启后确认页从网格隐去只剩待设页（与编辑器左侧缩略图同思路），全部确认时给空态引导；图例补"角标：主区已确认"防与页校对状态的绿框混淆（边框颜色仍是页校对三态，确认走角标）。
  **③ 顺手说明**——快设底部引导文案更新为「保存只记框，不识别；『保存并下一页』= 确认该页框」。
  测试：`flutter analyze` 零问题；全量 Dart 364 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Flutter 侧改动，Python 后端与 BACKEND_BUILD 不动。pubspec 1.0.0+88→1.0.0+89。

## 1.0.0+88

- **新功能：主区快设支持页眉/页脚等版面区设置 + 快捷键 1~7 切类别**（用户需求：在主区快设中增加对页眉页脚等设置，并且同样可使用快捷键）。四个部分：
  **① 单页快设编辑器多类别草稿**——快捷键 1~7（主数字与小键盘都认）与 AppBar 下新增的类别快切栏（色点 + 名 + 数字，与编辑器主区视图同词表同配色）切换「当前类别」，正文/页眉/页脚/页码/眉批/图片/表格每类一条草稿：当前类别橙色带角点手柄（快设"进行中"的既有草稿视觉），其余类别按 RegionLabel 配色细线 + 类别名小标签同时显示（屏幕恒定大小）；**点任意已有类别框内即切换为当前类并直接拖动**，不必回敲数字键。底部栏「重画」升级为「清除页眉框/清除正文框…」（按当前类别），「恢复原区」恢复主区与全部类别初始状态；多框合并提示从仅主区泛化到所有类别（同类多框保存合并为一条，与"只认首个"同口径）。
  **② 保存语义**——「保存并下一页」落盘主区 + 各类别框：已有同类框**保留首个的 id/uid/确认状态**只换几何（训练身份不因改框丢失），多余同类框合并删除，无同类框新建 proposed；「清除本类」落盘为删除该类已有框；没画过/没动的类别一律不碰（规则/AI 预标注的成果安全）。抽为 `BookRegionApply.replaceLabeledRegion` / `removeLabeledRegions` 共享服务（与 applyRegionOnly 同居一处，规则单一实现）。网格缩略图同步升级：正文主区仍紫粗线，页眉/页脚等按类别配色细线——哪些页补设了版面区一眼可见；网格上直接拖拽仍只画主区（类别设置进单页编辑器）。
  **③ 顺手修复：主区改框不再洗掉页眉/页脚框（既有隐患）**——`applyRegionOnly` 此前 `clear()` 整个 mainRegions 再放回单个主区：快设保存、全书叠加"只改框"、批量拆分都会把该页已有的页眉/页脚/眉批等非正文区**全部清掉**（+83 预标注、编辑器手画的成果均难幸免），与本次需求直接冲突。改为只替换首个 main_text 区域（无主区时新建插到最前），其它版面区原样保留；快设与批量拆分取主区的口径同步从 `mainRegions.first` 收紧为"首个 main_text 区域"（页眉框排在列表前面时不再被误当主区拆分）。
  **④ 细节**——翻页后当前类别自动回到正文（主区是快设主线，页眉/页脚等顺手补设）；保存提示与底部操作说明随类别动态更新；`Enter/←/→/Esc` 既有快捷键不变。
  测试：`book_region_apply_test.dart` 新增 5 条（applyRegionOnly 保留非正文区 ×2、replaceLabeledRegion 替换合并身份保留/新建与未改动判定、removeLabeledRegions 全删与幂等）；`flutter analyze` 零问题；全量 Dart 364 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Flutter 侧改动，Python 后端与 BACKEND_BUILD 不动。pubspec 1.0.0+87→1.0.0+88。

## 1.0.0+87

- **修复：主区识别中编辑/画框时程序异常退出（setState after dispose）**（用户反馈：识别主区的过程中重新编辑主区、画了页眉页脚等框后程序崩溃退出，错误为 setState() called after dispose）。取证与修复四个部分：
  **① 崩溃取证**——app_console.log 尾部重建时间线：19:21:03~19:21:14 用户连续三次入队主区级联（每次拖拽主区重新入队），期间画新框（写盘 bytes +97B），19:21:14 第三次任务回包（后端 200 OK 已送达）后前端进程死亡（后端日志随即出现 connection_lost，19:21:15 最后一次轮询）；app_console.log 无崩溃栈、Windows 事件日志无原生崩溃——异步日志链在进程死亡时丢失尾部，崩溃为 Dart 层未捕获异常。
  **② 根因修复：悬浮状态胶囊结构恒定化（+85 引入的回归）**——+85 的 `_canvasStatusOverlay` 在胶囊为空时直接返回 child、非空时才包 Stack：级联任务开始/结束时 `_areaProcessing` 翻转导致画布区树结构在"裸 child ↔ Stack"间切换，每次切换整个画布子树（`_AnnotationCanvas` 的 State：已解码页面图像、变换矩阵、进行中的拖拽手势）被 dispose 全量重建——识别期间反复入队时画布状态反复清零，处于拖拽/画框手势中的旧 State 被销毁后再收到指针回调即 setState after dispose 崩溃（与"识别中编辑主区、画框后崩溃"的时间线吻合）。修复：Stack 结构恒定（child 永远是第一个子项，`StackFit.expand` 撑满），胶囊只是追加/移除后面的 Positioned 叶子，级联状态变化不再 dispose 任何子树。
  **③ 顺手修复两类资源泄漏与四处 async setState 无 mounted 隐患**——`_AnnotationCanvasState` 补 dispose（TransformationController 从不释放）与换图时旧 `ui.Image` native 纹理释放，`_DetailCardListState` 同样补 dispose/换图释放（此前翻百页累积泄漏）；编辑器四处"await 后 setState 无 mounted"补检查（预标注版面区回包、AI 整页预标注回包与设置加载后、单页摆正保存后 `_imageRevision++`——用户点按钮后立刻退出编辑器时均为 setState after dispose 崩点）。
  **④ 崩溃日志同步落盘（下次不再丢栈）**——新增 `PythonService.writeCrashLineSync`：main.dart 的两个异常处理器（FlutterError.onError / PlatformDispatcher.onError）在常规异步日志之外，把未捕获异常的完整栈**同步**写进 app_console.log（[crash] 前缀，writeAsStringSync+flush）——异步 future 链在进程死亡时丢尾部正是本次拿不到崩溃栈的原因；服务目录未解析时退回 debugPrint。
  测试：`flutter analyze` 零问题；全量 Dart 359 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，历史基线即红）。纯 Flutter 侧改动，Python 后端与 BACKEND_BUILD 不动。pubspec 1.0.0+86→1.0.0+87。

## 1.0.0+86

- **修复：整行读法为空的行"推倒重切"永远拆不开——空读法占位字符不再把切分期望字数钉死为 1**（用户需求：一条超长竖排列（589,0,120,2183，约 17~21 字）怎么重新拆分都是整列 1 个字框）。两个部分：
  **① 根因修复（kraken_bridge.kraken_segment_line）**——死循环机制：整行 Kraken 读法返回空（0 字、无 cuts）→"孤立标点列"兜底合成 1 个覆盖整行的占位字符 → n=1 → 像素切分器的数量校验把连通域实际拆出的整列字框（该行实测 21 框）判为不匹配 → 网格兜底 `n<=1` 直接返回整行一框 → 兜底框不可信被弃用、cuts 又为空 → 只剩占位条带整行一框；编辑器里这行从此 1 字，下次重切/诊断再传 1，永远拆不开。修复：空读法合成的占位字符只作管线占位、不代表"本行 1 字"的真实读法——切分期望字数按未知（split_n=0 纯连通域路径、不做数量校验）走，与整页识别路径对空读法行（n_expected=len(kchars)=0）和横排（无序列读法）的既有处理对齐；调用方显式传入 expected_char_count（AI 框检查推算的真实字数）时仍优先。字数由逐框读法补齐（融合层空序列降级为逐框正文，横排同款既有路径）。
  **② 切字诊断同源复跑（api_segment.debug_char_split）**——诊断的字框来源决策此前只在整行读法非空时复跑；空读法行直接落到"网格条带近似"，诊断结论（整行一框）会与修复后的真实链路（n=0 纯连通域出全部字框）相反。现在竖排探测成功即复跑：读法为空同样按 n_real=0 复跑——components 成功即展示像素切分框；仍走兜底时明确标注"整行占位条带收紧模拟"（真实链路空读法无 cuts 可用时的实际退化形态），不再以网格条带冒充。
  测试：test_seg_kraken_cuts 30 条全过（含"空读法+行框内有墨迹"的孤立标点列用例——行为不变，仍合成占位、字框贴墨迹、逐框读法读出句号）；test_seg_core/test_seg_lines/test_seg_punct/test_seg_layout 114 过 + 1 条既有基线失败（drop_duplicate_fragment_lines 家族，+84 已记录 2026-09-30 基线即红，本次以纯 mask 输入独立重现复核确认与本次改动无关）；test_kraken_fusion/test_line_thumbnails 25 过。BACKEND_BUILD v106→v107（empty-read-split，Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+85→1.0.0+86。

## 1.0.0+85

- **修复：识别提示不再顶动书页 + 识别中编辑/新画识别框不再被洗回原样**（用户需求：① 正文/段落/单行/单字识别时上方突然出现的"正在识别中"不要影响下方书页显示，现在会画面跳动一下；② 识别过程中重新编辑段落、新加段落框、编辑单行、新加单行框，不要因重新识别重置回编辑前状态，识别中重新编辑了就按新编辑重新识别）。两个部分：
  **① 识别/AI 检查横幅改为悬浮状态胶囊（消除画面跳动）**——此前"主区/段级联重识别"与"AI 检查识别框"横幅作为画布区 Column 的条件子项插在书页上方，出现/收回的瞬间画布高度变化、下方书页跟着上下跳动（+79⑩ 已把单字识别改静默规避，本次把主区/段/行/排队全部场景一并根治）。新增 `_canvasStatusOverlay`：画布区整体包一层 Stack，状态条改为浮在画布顶部的圆角胶囊（转圈 + 任务名/排队数 + 阴影描边），不占布局空间，出现/消失书页纹丝不动；识别胶囊 `IgnorePointer` 不挡画布手势（可继续拖拽/缩放），AI 检查胶囊保留"取消剩余"按钮（仅胶囊本体可点）；排序模式横幅（固定高度约 36px）同时存在时胶囊自动下移避开。排序/Excalidraw 等用户主动进入的模式横幅仍在文档流内不动。
  **② 识别中的并发编辑保护（编辑不丢、按最新状态重识别）**——级联队列的同目标作废机制（gen + isStale，再次拖拽同框即作废旧任务、按最新几何重新入队）此前已覆盖"同一框的重复调整"，本次补齐跨目标的四个丢失路径：
  **（a）新画行框在识别中被区域/段级联洗掉**——手画行占位框（manual=false 且无字框）不满足"用户成果行"钉住条件，若此刻有正在执行的主区/段级联回包合并，`spliceRegionLines` 会把它当旧机器行删掉，行框凭空消失（其拆字任务回包后 indexOf 也找不到占位行，结果整包丢弃）。修复：`_addLine` 给手画占位行标 `manual: true`（手画几何即用户成果），级联合并钉住保留，占位行自己的拆字识别随后正常回填。
  **（b）识别期间行对象被替换导致结果丢弃/落错**——行识别在途时用户拖动该行（纯移动不触发重新入队），`_updateLine` 会把列表里的行换成同 id 新实例；`_rerecognizeLineChars`/`_resplitLineChars`/`_processNewLine` 回包后按旧实例 `indexOf` 找不到 → 识别结果整包丢弃（表现为"识别完没反应"）。修复：三处统一改为"实例匹配失败按 id 兜底重定位当前实例"，结果落到最新几何/归属上（手工行框保留、段落归属、manual 标记均从当前实例取值）；选中行的恢复从对象相等改为按 id 比较（避免面板留在已删除的死实例上）；新行识别回包不再抢占用户已改选的其它行。
  **（c）行替换后段落成员表孤儿化**——行重识别/重切/新行回包都是"删旧行插新行"（行 id 变化），但 `paragraph.lineIds` 仍指向已删除的旧行 id（段落合并/导出读到孤儿 id，只有下一次区域级联 rebuildParagraphs 才自愈）。修复：新增 `_swapLineIdInParagraphs`，三处回包合同时把段落成员表里的旧行 id 原位换成新行 id；新行识别回包同步把占位行期间段级联已认领的段落归属带到新行上。
  **（d）识别期间删除目标主区/段后旧任务照常合并**——`_replaceLinesInRect` 新增 `ownerDeleted` 检查：主区/段在识别在途时被删除，回包结果整包作废（否则不仅按旧矩形"删旧插新"，主区级联的"区外残留清理"还会把全页行一起洗掉；段级联则给已删除的死段落重新认领行）。
  测试：`flutter analyze` 零问题；纯 Flutter 编辑器侧改动，Python 后端与 BACKEND_BUILD 不动。pubspec 1.0.0+84→1.0.0+85。

## 1.0.0+84

- **新功能：标记图片与表格 + 表格识别——格线网格还原、单元格逐字识别、横竖版书页同一路径**（用户需求：OCR 项目增加标记图片和表格的功能，针对表格进行表格识别，横版和竖版中都可能会出现表格）。八个部分：
  **① 版面区词表追加 figure/table（id=5/6，只追加不重排）+ 区域门控扩展（train_data.py / models.dart 两侧同步）**——插图/表格与页眉页脚同走 `build_body_gated_image` 抹底色门控：表格格线与插图墨迹此前会被 char_det 误切成"字"，标记后整区在字检测前抹除；人工确认的 figure/table 框自动进入 region_det 训练集（词表即协议，训练管线零改动），积累够了即可训出自动检测。冲突审计拆出 `REGION_CONFLICT_LABELS`（仍限 header/footer/page_number）——图/表出现在正文区内部是正常版面，不再参与重叠冲突提示。编辑器配色：图片棕 0xFF6D4C41、表格玫红 0xFFAD1457（预标注素材图 REGION_OVERLAY_COLORS 同色系对应）；AI 整页预标注的 VLM 提示词同步七类词表（figure=插图/版画、table=有格线网格结构的表格）。
  **② 格线检测与网格构建（新 python_service/table_grid.py）**——`detect_table_grid(图片, 矩形)`：OTSU 墨迹（极性自检）→ 形态学开运算提横/竖线（核长 = 页面长边 2%，夹 [15,80]）→ 闭运算桥接印刷断线（≤8px）→ 窗口内投影聚类行列分割线（覆盖 ≥25% 挡文字条带，厚 >12px 的墨块丢弃）→ 行列交叉成格，**相邻单元公共边界线段覆盖率 <50% 判无线 → union-find 合并单元格**（row_span/col_span）；内容矩形按线宽向内收缩避免格线墨迹混入识别。`detect_tables_in_page`：线段连通域（横竖交叉 + 平行近距双线/同线两半连通）聚簇出候选，**rows≥2 且 cols≥2 门槛挡掉古籍两大误报源**——正文界行结构（N 条横线 + 版框两竖线 = cols=1）与纯版框（1×1）。手动路径（用户框了就是表格）不施加该门槛，但 1×1（纯外框）拒绝并提示"无线表格暂不支持"。格线检测横竖对称，与页面阅读方向无关；斜页先走 /dewarp_page 摆正。
  **③ 单元格文字识别（新 python_service/table_recognize.py）**——格内切字用**去栏线墨迹 mask 的直接连通域**（make_kraken_char_splitter 是为单列行设计的，整格当一条行会按格高估字尺寸、膨胀粘字，不适用）；字框中心入格过滤、碎块（<6% 中位面积）与细长线残余（长宽比 >6）丢弃。**格内方向自动判定**：瘦高格竖排、扁格横排、方形格跟随页面方向（表头/备注格常与正文反向）；格内多列/多行按中位字宽聚列（行）排阅读序（竖排列序 = horizontal_dir，横排行内序 = horizontal_dir）。全表字框合成一批走 `_recognize_char_boxes` 一次 daemon 请求（与编辑器单字框补读同路径，同批统一放大倍数，40 格一次往返）；daemon 不可用时几何照常返回、文字空 + reason 提示重试。
  **④ API 与预标注（新 python_service/api_table.py，main.py 挂载）**——`POST /detect_tables`（整页候选，供预标注）；`POST /recognize_table`（手动区域，挂 `_gated_recognition` 并发门，422=格线不足带 reason）。region_prelabel 规则预标注接入：格线网格结构作为 label=table、confidence=0.8 的候选插入（格线检测失败不拖垮页眉/页脚规则）。BACKEND_BUILD v105→v106（Dart 握手同步，旧后端自动重启）。
  **⑤ 前端模型（新 flutter_app/lib/models/table_block.dart + PageAnnotation.tables）**——TableAnnotation{外框/rows/cols/h_lines/v_lines/cells/region_uid/status} + TableCellBlock{row/col/span/几何/text/orientation/chars 逐字证据/conf}，PageAnnotation 挂 tables 字段（旧标注读侧缺省空、无表格不写键，零迁移）；「确认并保存」级联确认表格与全部单元格；页面旋转/镜像 `transform` 与 transformGeometry 同逐点映射——**90° 旋转行列转置**（cell 的 row/col/span 换算、h_lines↔v_lines 互换重排）、flip 行/列镜像；跨页拆分表格按中心点整体归属（不劈成两个残表）。
  **⑥ 编辑器入口**——快捷键 1~5 扩到 **1~7**（按 RegionLabel 词表长度驱动，digit8/9 越界守卫），「新框类别」快切栏与类别下拉经词表自动扩展；选中 table 类主区时面板出现「识别表格」按钮（首次识别 → 结果落 PageAnnotation.tables → 直达校对页；已有结果则显示「打开表格校对」；regionUid 匹配优先、失效后按几何归属）。
  **⑦ 表格校对页（新 flutter_app/lib/pages/table_review_page.dart）**——Stack 绝对定位按几何列宽比例摆真实网格（**合并格双向 span 真跨**，Flutter Table widget 不支持 colspan/rowspan 故弃用）；每格 = 原图缩略（drawImageRect 一次解码 + 格线示意线，判断 span 正确性）+ 识别文字 + 确认状态底色；点击选中后底部详情栏放大校对（改字自动回落 proposed）、确认本格；**竖排版面默认按阅读序列从右往左摆（表头在右），一键切回几何序**；菜单：重新识别（覆盖文字保留 uid 溯源）、全部确认、导出 Markdown/TSV（剪贴板 + 存文件，合并格内容只写起点格）。返回编辑器自动临时保存。
  **⑧ 顺手修复：墨迹二值化 OTSU 退化兜底（seg_imaging._binarize_ink 抽取为公共入口）**——极端不均衡双峰（黑底白线页，线占比 ~1%）会让 OTSU 阈值退化到端点：此前全页当墨（翻转也救不回），行投影全满切分全乱；现按亮度分位数重切（暗页取亮侧 1%，阈值取分位值与极值中点保证切在两峰之间）。_text_mask_for_refinement 改调公共入口（去栏线行为不变），table_grid 同源复用。
  测试：Python 新增 `test_table_grid.py` 12 条（规则网格/合并格 col_span=2/断线桥接/纯版框 1×1 拒绝/纯文字拒绝/黑底白线极性/横版宽扁 4×8/竖版窄高 12×3/整页检测——年表命中且界行区不误报、纯字块零候选、缺图容错）+ `test_table_recognize.py` 8 条（格方向判定 4、格内阅读序——竖排 rtl 右列先/ltr+btt、横排 ltr/rtl 行内序、识别编排——mock Kraken 全格两字按阅读序、daemon 失败几何保真、无格线报 reason）；Dart 新增 `table_block_test.dart` 9 条（JSON 往返含合并格与字框证据、fromRecognition snake_case 解析、旧标注无 tables 缺省空且不写键、rotate_cw 行列转置+span 互换+h/v 线互换、flip_h 列镜像、Markdown/TSV 导出含 rtl 列反转）+ region_multiclass 词表断言更新。`flutter analyze` 零问题；全量 Dart 358 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，+80 基线即红）；Python 全量分批 417 过 + 2 条基线既有失败（drop_duplicate_fragment_lines 家族与 analyze_layout 窄列 dedupe，2026-09-30 基线即红，本次以"纯 mask 输入独立重现 + 输入图上 _binarize_ink 输出与旧实现逐位一致"双重复核确认与本次改动无关）+ test_char_verify 与 test_excalidraw 同进程跑触发的既有 torch/mkl 崩溃（分批跑各自全绿，同样与本次无关）。pubspec 1.0.0+83→1.0.0+84。

## 1.0.0+83

- **修复：删页后"全书识别丢失"——页号一律以图片文件名为准 + 存量错位标注一次性归位（数据已救回）**。事故机制：跨页拆分/摆正输出的图片文件名（`warped/split_page_273.png`）不匹配 `page_NNN` 形式时，`pageIdForImage` 回退按 imageFiles **下标**命名标注文件（`page_003.json`…）；全书识别完成后删掉前面的页，后续所有页下标前移、标注文件名却停在旧下标，加载时 `loadAnnotation` 的 expectedImagePath 防串页守卫发现标注记录的图片 ≠ 当前下标的图片，整书标注被逐页丢弃（应用日志连续 513 条「丢弃错配标注」）——识别数据其实全在盘上，只是文件名与页序错位。三个部分：
  **① 根因修复（models.dart `pageIdForImage`）**——任意文件名 stem 直接作页号（`split_page_273.png` → `split_page_273`），页号与下标彻底解耦：删页/插页/重排后各页仍指向自己的标注文件；`page_NNN` 文件名行为不变（健康书籍零影响）。空 stem 或点开头文件名（`.png`）兜底回下标页号。断点续识（savedAnnotationIndices）、书页缓存、字频账本、AI 溯源、拆分/摆正等全部调用点经由同一函数自动生效；`splitOutputStartIndex` 过时注释同步修正。
  **② 存量数据归位工具（python_service/tool_realign_annotations.py，可复跑、幂等）**——按每个标注 JSON 内记录的真实 `image_path` 把下标型/错位标注归位到新页号名下；同页多份候选（.json/.bak/.legacy）取最新者，其余连同无主文件（图片已删除/拆分源页等）移入项目内 `_realign_quarantine_<时间戳>/` 隔离区，不删任何数据；应用前自动备份 `annotations/` 与 `project.json` 到数据根 `_realign_backup_<项目>_<时间戳>/`；同步迁移字频账本（`char_stats/<项目>__<页号>.json` 文件名+内容）与 AI 溯源（`ai_trace/` JSON+图片目录）；现役功能性 `.bak`（现名仍是某现存页页号且内容确属该页）保留不隔离；stem 重复的书自动跳过防互相覆盖；完全健康的书零触碰。默认干跑，`--apply` 应用、`--verify` 校验。
  **③ 本机书库实际执行结果**——新锓希夷陈先生紫微斗数全书（明南阳堂刊本，517 页）：516 页识别全部救回（唯一例外 split_page_282 在历次保存中从未留下标注，需单页重识别）；紫云论斗数曜赋性第五册顺带治愈——此前仅 96/354 页可读（旧版删页错位迁移遗留的 .bak/.legacy 正主），归位后 354/354 全绿；其余书零触碰或本就对齐。字频账本与 AI 溯源已随迁，`--verify` 全库校验通过且复跑干跑零动作（幂等）。
  **④ 复查修复：归位备份目录导致首页每本书显示两张卡片**——首版归位工具把自动备份建在书库数据根一级（`_realign_backup_<项目>_<时间戳>/`），备份内的 project.json 副本被首页 `loadAll` 当成书，6 本书全部显示重影。三件收尾：既有 6 个备份目录已移入 `GujiBT\_realign_backups\` 子目录（数据根一级不再有 project.json 副本）；工具默认备份路径改为 `_realign_backups/<项目>_<时间戳>/`；`loadAll` 增加防御——下划线开头的书库内部目录一律跳过，今后任何内部目录带 project.json 副本都不会再变成书卡片。
  测试：新增 `test/page_id_test.dart` 7 条（任意 stem 作页号、page_NNN 不变、同图页号与下标解耦、空/点开头 stem 兜底、删页后 pageIdAt 不漂移事故回归、stem 页号存取往返、错配守卫仍拒绝串页）+ `test/storage_load_all_test.dart` 1 条（loadAll 跳过下划线内部目录）；`flutter analyze` 零问题；全量 Dart 351 过 + 1 条既有环境依赖用例（tool_export_crowd_tasks 需本机 crowdtest1 项目，+80 基线即红，与本次无关）。纯 Dart 侧 + 独立 Python 工具改动，识别后端与 BACKEND_BUILD 不动。pubspec 1.0.0+82→1.0.0+83。

## 1.0.0+82

- **改进：文字汇总页网格/列表双视图，默认网格**（用户需求：不需要纯列表形式，增加可切换的网格式显示，网格框里显示该字的出现次数，默认网格）。AppBar 新增视图切换按钮（当前为网格时显示列表图标、反之亦然）：**网格视图（默认）**一格一字——字 26px 居中、次数 11px 等宽数字在下，格宽随窗口自适应（maxCrossAxisExtent 92px、正方形格），悬停提示无声调拼音与完整次数；**列表视图**保留原有 大字格+拼音+占比条+「N 次」 行式。GridView.builder 懒构建，万字号账本滚动如常；与列表一样不包 Scrollbar（桌面端默认 ScrollBehavior 自动加滚动条，见 +81 ④ 的回归记录）。空态提示抽为两视图共用的 `_buildEmptyEntries`。测试：挂载冒烟用例更新为——默认网格渲染字格 → 点切换按钮出现列表行尾「N 次」→ 拼音筛选仍命中。`flutter analyze` 零问题；char_stats 12 条全绿。pubspec 1.0.0+81→1.0.0+82。

## 1.0.0+81

- **新功能：文字汇总——全部校对确认页面的全局字频统计**（用户需求：显示所有校对确认过的书籍中出现过什么字、次数是多少；书在校对后删除不影响统计；已确认页重新识别时把该页确认过的文字从统计中移出）。五个部分：
  **① 全局账本（新 `services/char_stats.dart`，数据根目录下 `char_stats/`）**——按"项目 × 页"一页一记（`<projectId>__<pageId>.json`，projectId=项目目录名毫秒时间戳），内容为该页已确认文字的字频表；放在书籍目录之外，**删除整本书（整目录删除）天然不影响统计**（校对成果历史累计保留，用户确认口径）；打开汇总页时全量聚合求和，账本即唯一真相、无冗余总计文件可失步。统计口径（用户确认）：正文与批注都计入（与墨迹模板仅 main_text 的口径有意不同），排除 ignore 块与空文字，确认判定兼容 status/confirmed 两种标记，多字 text 逐字符计数；以 lines.chars 为准（blocks 扁平表重切割后可能短暂滞后）。
  **② 存储层咽喉点挂钩（storage.dart）**——`saveAnnotation` 尾部 fire-and-forget 调 `CharStatsService.syncPage`：**任何** reviewed=true 的保存（编辑器确认并保存、墨迹归类组确认、众包回填、跨页拆分投影……13 处分散调用全部自动覆盖）记账/覆盖同页账目（幂等，重复确认不重复计数；内存缓存比对字频无变化则跳过写盘，纯几何编辑的防抖保存流不打扰账本）；reviewed=false 的覆盖保存（单页重新识别走 `ensurePageAnnotation(force)` 覆盖写）撤账。`clearAllAnnotations`（全书重新识别）尾部调 `removeProject` 整书撤账。写盘复用原子写并新公开静默版 `writeJsonAtomicQuiet`（省逐写诊断日志防刷屏）；Windows 杀毒/索引器瞬时锁 rename（errno 32，编辑器写链已知问题）加 3 次×60ms 退避重试；失败只记应用日志绝不影响标注保存主流程。
  **③ 删页与页面集变化对账**——编辑器删页（`_confirmDeletePage`）与批量摆正删页（`_deletePage`）删标注文件后调 `removePage`（用户确认口径：删页即撤账，统计=当前存续页合计）；跨页拆分三处 `reconcileProject`（账本中不属于当前 imageFiles 推导页号的条目删除）：拆分落定撤源跨页账（半页账由保存钩子自动建立——`croppedTo` 原样保留 reviewed，不对账会双倍计数）、失败/取消清本轮已写出的半页孤儿账、恢复拆分前清输出页账并按盘上源页标注 `syncPageFromDisk` 重建源页账。
  **④ 统计页（新 `pages/char_stats_page.dart`，首页顶栏「文字汇总」入口）**——汇总卡（收录书籍数含已删除书、已确认页数、字种数、总字次）+ 按字/拼音筛选（lpinyin 无声调拼音懒加载缓存）+ 次数/拼音/Unicode 三种排序 + 字频列表（大字格 + 拼音 + 相对最大次数占比条 + 等宽数字次数），三态加载/错误重试/空态引导。字频列表为裸 ListView：Windows 桌面端默认 ScrollBehavior 自动加滚动条；显式 `Scrollbar` 包裹且不传 controller 时会去拿没有任何 ScrollPosition 挂载的 PrimaryScrollController（桌面端 ListView 不自动挂载），首帧绘制即抛 "has no ScrollPosition attached" 直接退出（用户实测反馈，已去除）。
  **⑤ 存量回填 + 顺手修复两处既有编译错误**——首页 `_init` 迁移后调 `backfillOnce`：升级后首次启动把现有书籍全部 reviewed 页一次性计入（`char_stats/.backfilled` 标记防重跑，只认 imageFiles 现存页带图片守卫、拆分源页孤儿文件不计入，失败不写标记下次重试）。修复工作副本既有编译错误：`editor_page._loadPageStateMarkers` 与 `home_page._refreshProofreadCounts` 两处仍按二元记录解构 `PageStateCache.load`（该函数已重构为返回 `PageStateSummary`，editor_page:470 已是新用法），按新 API 改取 `.markers` / `.reviewedCount`。
  **⑥ 复查修复：账本写/删竞态（在途记账写复活已删账目）**——syncPage 是 saveAnnotation 尾部的 fire-and-forget，removePage 此前直接删文件不与在途写协调：「确认并保存 → 立刻删页/整页重识别」时删除先执行（此时记账写甚至还没入队），在途写的 rename 把刚删的账目**复活**，该页文字从此永久多计。修复三件：syncPage 改为**按账目条目串行的在途任务链**（_syncInFlight，同条目记账/撤账有序）；removePage 先等该条目在途任务与排队中的原子写（storage 新公开 awaitPendingWrite）落定再删；removeProject/reconcileProject 先等全部在途记账任务与写（drainPendingWrites）再扫描删除。A/B 验证：禁用等待逻辑后回归测试 3/3 稳定复现复活，启用后通过。测试补 1 条复活竞态回归（确认保存后不 drain 直接删页，账本不得残留）。
  **⑦ 顺手加固 book_cache_test 的 Windows 时序偶发**（+81 全量跑出的 3 条 flaky）——tearDown 改重试删除（fire-and-forget 账本钩子与删除枚举竞态）；「指纹未变只 stat」用例的 mtime 恢复改为**从缓存文件读记录值 + setLastModified 后轮询确认 stat 生效**（Windows 元数据刷新偶发滞后）。3 连跑全绿。
  测试：新增 `test/char_stats_test.dart` 11 条（统计口径 2：ignore/未确认/空文字排除与批注计入、多字 text 逐字符；生命周期 7：确认保存记账汇总、重复确认幂等覆盖、重识别覆盖写撤账、删页撤账、全书重识别撤账别书保留、删除整本书账目保留、拆分页集对账；回填 1：reviewed 入账未确认不入账 + marker 防重跑；统计页挂载冒烟 1：真实 IO 用 runAsync 窗口分批等待（同 book_split_page_test 模式），渲染字频列表并验证拼音筛选，锁住 Scrollbar 无挂载位置首帧退出的回归）。`flutter analyze` 零问题；全量 Dart 344 过（book_cache_test 3 条时序偶发已随 ⑦ 加固复绿） + 4 条与本次无关的失败（backend_unreachable_retry 连接本机后端被拒、tool_export_crowd_tasks 需本机项目、book_cache_test 3 条 Windows mtime 时序 flaky——已用"禁用账本钩子 A/B 对照结果逐位一致 + 单跑复绿"复核确认均与本次改动无关，+80 基线即有环境依赖失败）。纯 Flutter 侧改动，Python 后端与 BACKEND_BUILD 不动。pubspec 1.0.0+80→1.0.0+81。

## 1.0.0+80

- **新功能：编辑器校对进度常显 + 缩略图「隐藏已确认」开关**（用户需求：书籍校对界面右下角 BAR 显示当前还有多少页没确认、已确认页数占比；并提供隐藏已确认页面的功能开关）。两个部分：
  **① 底部翻页栏右下角校对进度**——`_buildPageNavBar` 原「上一页 / 第 X/Y 页 / 下一页」居中布局的右侧 Spacer 后追加常显统计「未确认 N 页 · 已确认 X/Y（P%）」：口径与首页书卡片一致（`PageStateMarkers.savedPages`，即「确认并保存」过的绿框页；确认/重识别/重置流程本就随 setState 增删集合，翻页或确认后即时刷新）；删除页后旧页号可能残留集合，按当前页数钳界只统计现存页；全部确认后数字转绿色。
  **② 左侧缩略图列表「隐藏已确认」开关**——列表头部（图例下方）新增紧凑开关：开启后绿框页从列表隐去、只列待校对的页，校对后期不必在数百个绿框里找剩余工作。当前页恒显示（「确认并保存」后本页立即变绿也不会从列表消失）；`_scrollThumbsToCurrent` 随之改为先换算当前页在可见列表中的行号再定位（开关切换后自动把当前页滚回可见位置）；开关不持久化（每次进编辑器默认关闭）；翻页按钮仍按真实页序 ±1。
  测试：`flutter analyze` 零问题；全量 Dart 327 过 + 1 条既有环境依赖用例（需本机 crowdtest1 项目，2026-09-30 基线即红）。pubspec 1.0.0+79→1.0.0+80。

## 1.0.0+79

- **新功能：墨迹归类的特殊字标记——存疑字先跳过、全书识别完成后集中校对**（用户需求：归类时把"可能裁分有问题/暂时无法识别"的字做标记，等全书都识别完再对这些字校对；同时补齐组内选择的反选，并增加隐藏标记字功能）。四个部分：
  **① 数据模型（CharBlock.marked）**——新增 `marked` 布尔字段并持久化到页标注 JSON（`marked: true`，仅打标时写入，旧文件零扰动；Python 侧整页读 JSON 按需取字段，新字段天然容错）。语义独立于确认状态（status）：打标/撤标不改变文字、几何与确认口径，不影响训练数据判定。
  **② 归类页交互（单页版/全书版同套）**——组底部新增「标记（N）」按钮：把点选/框选选中的字打特殊字标记，选中字已全部标记时自动变为「取消标记（N）」（toggle 语义）；单字修改对话框新增「标记为特殊字」开关，单独改字时可顺手打/撤。标记字缩略格左上角显示深橙小旗角标，组头部显示深橙旗 N 徽标（组内标记计数），工具栏统计行显示当前范围特殊字总数。组头部选择按钮补齐为**选择全组 / 反选 / 取消选择**三件套（反选对当前显示的字取补集，与全选同一口径，含已确认隐藏/标记筛选后的可见集合）。
  **③ 标记筛选（隐藏标记 / 只看标记，互斥 FilterChip）**——「隐藏标记」把已标记字从组里隐去，正常归类不受存疑字干扰（选区自动剪掉被隐藏成员）；「只看标记」只显示标记字——**全书识别完成后在全书版打开它，整本书存疑字按字形聚组集中筛出，改字/确认/行内重切照常可用，校对完成取消标记**。两者互斥（同开等于什么都没有），与「只看待处理组」「显示已确认」自由组合；范围内无标记字时给出引导提示。
  **④ 编辑器联动**——单页版打标经 `onBlocksMarkUpdated` 回调走编辑器统一的 copyWith 替换 + 防抖保存通道（`_updateBlocksMarkById`，与文字快改同管线）；全书版直接写活字块并按页防抖落盘（与文本编辑同通道）。详细视图字 chip 左上角加深橙点角标（与右上角 amber 两路分歧点区分）；字属性面板新增「特殊字标记」开关行，可在编辑器里直接打/撤标。
  **⑤ 全书版「定位到所在页」**（用户反馈：全书版找不到定位 UI）——字格页号旁新增定位按钮（组内经框选路由层命中、未归组单字直点），单字修改对话框新增「定位到所在页」按钮：冲刷未落盘编辑后带着定位请求退栈，编辑器跳到目标页（不同页走 `_switchPage` 含临时保存链路；同页且被全书版改过则先从盘重载），切详细视图选中该字并闪烁 10 秒（与单页版定位同一体验，`_focusCharInDetail` 抽取共用）。退栈结果从 `Set<int>` 升级为 `BookClassifyResult`（修改页集合 + 可选定位请求），单页版转发全书版结果给编辑器。
  **⑥ 双击行内重切兜底修复**（用户反馈：双击文字跳转报错）——`_openLineReseg` 找行此前只按字块**实例**匹配（`line.chars.contains(m.block)`），分组持有的实例在任何路径被换代（copyWith 替换/标注重建）后就找不到行，双击直接弹「找不到该字所在的行」红色提示；现在实例匹配失败后按**块 id** 兜底找行（字块 id 稳定即身份）。另给行内重切页的行图裁切区加退化防护：行框贴齐图像边缘被钳成 0 宽/高时裁切区至少 1×1，避免坐标换算除以 0 产生 NaN。
  **⑦ 「重新识别本行」严格保留人工字框**（用户需求：重新识别本行单字不改字框尺寸，按设置决定是否 AI 辅助）——后端 /segment_region 的旧行为：传入字框数与整行读法字数不一致（或框形似均分合成框）时整批弃用人工框走自动重切（用户实测 23 个手工框被 1 个 cuts 框替换、字 23→1）。新增 `strict_char_boxes` 请求参数：true 时无条件保留传入框只重填文字、并跳过字框↔序列错位重建；编辑器「重新识别本行单字」与行内重切页「识别填字（保留当前框）」都走 strict（两条链路的 AI 辅助本就按 `enableManualLineAssist` 开关，未动）。全页识别等其他调用方不传 strict，对齐校验行为不变。
  **⑧ 详细视图字框几何变更自动重识别**（用户需求：改尺寸/移动位置应与新画字框行为一致）——详细视图行卡片手势提交此前只走 `_updateBlock` 更新几何（`_charGeomDirty` 脏标记在详细视图无人消费，主画布的 `onGeometryEditEnd` 没接到这条链路），识别不刷新；新接 `_updateBlockFromLineCard` 包装器：几何变化时按主画布同口径入队该字框重识别（`_queueCharCascade(preserveUserText: false)`，与新画框的自动识别同体验），并清掉脏标记避免画布手势结束二次触发。
  **⑨ 快捷候选条加「标记特殊字」**（用户需求：详细界面单字选择处也能标记）——轻点字 chip 弹出的快捷候选条底部新增标记切换按钮（未标记「标记特殊字」/已标记「取消标记」，深橙小旗图标，与「删除识别框」同行左右分置）。标记状态为浮层本地镜像，**关闭浮层时与文字一起经 onCharUpdated 统一提交**：一是与"输入过程不实时写回"的既有契约一致，二是避免标记先提交替换字块实例后、文字提交仍抓着旧实例被静默丢弃的竞态；只翻转标记不改文字同样提交（走 _updateBlockFromLineCard，几何无变化不触发重识别）。
  **⑩ 单字识别不再弹顶部蓝色横幅**（用户反馈：每次单字识别弹出的"单字识别中（后台进行，可继续编辑）"蓝色条会把整个界面顶下去产生跳动）——根因：横幅是 `_areaProcessing` 条件插入在工具栏下方的 Column 里，出现/收起各挤一次布局，且级联队列里单字识别任务（新画框/调整框/移动框的自动重识别，⑧ 之后每次拖拽都会触发）也走这条横幅。修复：级联任务新增 `silent` 标记，单字识别入队即静默——不弹横幅、排队数也不计入（单字秒级完成，选中字的属性面板本就有内联"识别中…"指示，文字识别完原地更新）；主区/段级联这类长任务（几十秒）仍保留横幅，AI 检查识别框横幅（带取消按钮）不动。
  **⑪ 书籍与墨迹归类打开加速：两级书目录缓存**（用户需求：每次打开都要等很久；实测 520 页书每次打开全书墨迹归类都要重跑 142 秒后端聚类，编辑器/首页每次都逐页解析整本标注 JSON）——新 `services/book_cache.dart`，两个缓存同纪律：按内容指纹失效、损坏即重建、纯派生数据随时可删。**① 页状态缓存 `PageStateCache`**（`page_state_cache.json`）：按「标注文件 mtime+size+图片路径」缓存每页的页状态（绿/橘黄/紫框）、reviewed、各层训练计数；指纹命中的页只 stat 不解析。编辑器页状态标记、书进度卡（`_refreshBookProgress` 原来整本并发读）、首页校对计数（原 `countReviewedAnnotations` 整本解析，方法已删）三条链路共用一份缓存；同一书目录的在途加载共享（并发首载只解析一遍）；进度卡当前页仍以内存标注覆盖（防抖未落盘的修改立即反映）。**② 聚类缓存 `ClusterCache`**（`cluster_cache.json`，最多 6 条）：按「页范围+阈值+每页几何摘要（图片 mtime/size+字块 id/几何）」缓存全书墨迹归类的分组结果，命中免后端分钟级重算——文字/确认/特殊字标记不参与墨迹形态聚类，改字不失效；行内重切/调框/换图改变摘要自然重算，含失败页的结果不缓存。
  测试：新增 `book_cache_test.dart` 5 条（指纹命中只 stat 不解析——同字节长度同 mtime 的垃圾内容不再重读 / 保存后状态计数重算 / 换图路径失效 / 聚类摘要改字稳定几何敏感 / store-lookup 往返+阈值摘要未命中+条目封顶）+ `char_marked_field_test.dart` 4 条（旧 JSON 无键回退 false / 序列化往返 / 未标记不写键 / copyWith 只翻转标记不动文字状态）。`flutter analyze` 零问题；全量 Dart 327 过 + 1 条既有环境依赖用例（需本机 crowdtest1 项目，2026-09-30 基线即红）；Python 新增 strict 模式测试 2 条（框数与读法不一致保留人工框 + 均分形框保留，附非 strict 对照断言），全量 338 过、除 2 条基线既有失败（双栏去重相关，2026-09-30 基线）外全绿。BACKEND_BUILD v104→v105（Dart 握手同步，旧后端自动重启）。pubspec 1.0.0+77→1.0.0+79（+78 为上一条已记条目）。

## 1.0.0+78

- **修复：双行小字夹注的两处整页拆分缺陷——末字被缝隙墨迹截断落进正文行（与正文行框重叠）、每侧仅两字的短注整页不拆**（用户实测 1790460224098 第 287 页：第 4 列「刼空傷使|在內合斷」左列只剩 在內合，斷 的字框被就近分进下方正文行、正文行框上沿压住注释行（与 7 号重叠）；第 10 列「即天|姚星」四字短注整页识别不拆、按单列读成交错乱串）。两处修复（seg_doublecol.py）：
  **① 缝隙段边界外扩（`_extend_note_segment_edges`）**——段边界取自缝隙列的空白跑，末字（斷/使类密字）笔画跨进缝隙带会把跑提前截断（实测 287 页左列斷 y459..537、空白跑 496 就断）。外扩只认"已经压在边界上"的侧带墨迹段、每步只推进到最近一个跨界段端点、逐步重验，三重守卫任一不过即停在原边界：缝隙带墨迹占比 ≤0.35（只对 ≥0.25×字高窗口生效，边界 2~5px 蹭墨在小窗占比噪声极大——426 页末字 1521..1605 曾因此漏补）且最长连续跨缝墨迹 ≤0.35×字高（通栏正文一笔横穿整条缝隙，实测 70px 连续；夹注末字最多蹭 11px）；跨界每侧墨宽 ≤0.8×上段通栏墨宽（通栏字占满整条、夹注字只占半条）；单步 ≤1.2×字高。287 页实测：段 175..496→175..537，斷 归位左注释行（4 字 在內合斷）、正文行框自 553 起不再与注释行重叠。
  **② 两行小注段长双尺度放行（`_two_char_note_span`）**——全页 3×根字高的段长门槛按正文字号设，每侧仅两字的短注整段只有 ~2.9×根字高（实测 287 页 222/77.5、夹具 129/45），候选阶段被静默丢弃。放行按段内小字自己的尺度：段长 ≥2.2×段内两侧字符带高中位且 ≥1.7×根字高——切穿正文部首缝的假段两侧是同号大字（实测 1.0~1.6×）两条都过不了，碎笔画假段由 ⑧ 整字块判据拦截。第 10 列即天|姚星现按 阅读序 上段→右（即天）→左（姚星）→下段 拆成 4 行。
  测试：更新 `test_two_tier_short_note_fixture`（整页与单行识别对短注给出同一拆分，旧断言"整页宁可漏拆"随用户需求翻转）+ 新增 `test_page287_truncated_note_edge_and_two_char_note`（夹具 guji1790_287_col4_long_note.png / col10_short_note.png 为原页两列裁片，锁住段外扩边界与短注拆分）。回归：全书 89 页抽样 1002 条带新旧代码 A/B——零拆分丢失、7 处新拆分与 10 处边界修正逐一核实均为真实夹注（夹具 xingnan 断点 287→308 补全斷/使；367/380/663/613 等边界抽查两簇子列结构确认）。BACKEND_BUILD v103→v104（Dart 握手同步，旧后端自动重启）。全量 Python 测试除 2 条基线既有失败（双栏去重相关 drop_duplicate_fragment_lines 家族，2026-09-30 基线即红；本次已用"还原旧行为"猴子补丁复核确认与本次改动无关、该函数未触碰）外全绿。

## 1.0.0+77

- **重构：训练数据管线——生成与训练分离、页级增量导出到可配置统一目录（清单随数据跨机迁移）、删书不影响数据与统计、完成书一次性抽样、模型管理增强（删除/路径配置/打开文件夹）、修复"训练完看不到曲线"**。六个部分：
  **① 路径可配置（后端新模块 train_paths.py + GET/POST /train/paths）**——数据集根目录与训练模型根目录改为 train_paths.json 配置（机器本地、热生效不重启），缺省保持历史位置（datasets/、models/trained/）；DATASETS_ROOT/TRAINED_ROOT 动态化（模块属性保留为测试覆盖缝，_isolate_datasets_root 兼容）；收敛 4 处重复的 SERVICE_DIR 定义到 registry_io。
  **② 页级增量导出 + 跨机清单（新模块 train_manifest.py / train_export.py + POST /train/export）**——统一数据集目录下 manifest.json 与数据同住：**拷整个数据集文件夹到另一台电脑，统计与"哪些页已导出/哪些书已抽样"记录随行**。增量语义：只写新增/内容有变化的页（digest 摘要判定，同页覆盖重写），标注清空的页保留旧文件（不影响旧数据），**书籍任务从书库删除不影响清单、样本文件与统计**——统计口径 = 已导出数据（/train/stats 各层 instances/readiness/每类分布改用 manifest，新增 pending 字段 = 书库已确认未导出的页数；书库清空也能出统计）；数据集目录缺失时 /train/start 自动增量导出兜底。首次升级自动把 datasets/_global/_meta.json 存量转为 manifest 基线，旧统计不丢。标签语义收敛为唯一实现 page_labels（按书整写与增量导出共用），顺手修复存量 bug：**确认过的段落此前按"行列表"迭代直接崩溃**（真实标注确认段落后必触发，旧测试只走推断路径未暴露）。
  **③ region_det 完成书一次性抽样**——识别完成（recognition_status=completed）的书只在首次导出时确定性随机抽 8 页（REGION_SAMPLE_PAGES 可调，seed 随书 id 可复现）进 region_det，此后永久固定该页集合（之后新增确认区域页不进、force 重导用同批页）；未完成的书暂不导 region_det（其他四层不受影响，照常页级增量）。
  **④ 训练曲线修复**——真因：注册表只在训练成功时登记且 _monitor 的注册异常会把成功训练吞成 failed（磁盘曾留 342MB 孤儿 run）、服务重启后内存任务表清空、客户端空 run 列表静默无反应。修复：list_models 磁盘扫描对账（trained_root 下有 results.csv 的 run 自动补登记、幂等、大小写不敏感去重）+ runs 全量返回（原只给最近 10 条）+ _register_run 异常不再影响训练状态 + 客户端空列表改 SnackBar 提示、run 去重按小写路径、「打开模型目录」放宽到任意历史 run。
  **⑤ 模型管理增强**——新端点 POST /models/delete_run（删 run 目录+注册表条目；启用中的先自动停用，activate 新增 active_source 溯源字段；路径钳制在训练根内拒绝越界）与 GET /models/run_size。模型管理页新增：每个 run 的删除按钮（确认框显示磁盘占用）、顶部「数据与模型位置」面板——数据集目录/训练模型目录可配置可打开、应用模型目录（models/）直达打开、附"数据集文件夹可整体拷到另一台电脑"提示。
  **⑥ 训练页拆分按钮 + 自动增量导出**——「生成数据集并训练」拆为「生成数据集」（增量导出，按钮显示"X 页待导"徽标；旁附强制重导小按钮带确认框）与「开始训练」（直接用已导出数据）；**打开训练页自动检查 pending 并后台导出新增**（Snack 报数，每次进入只做一次）；Kraken/墨迹比对卡片保持原样。Python 新增测试 23 条（路径配置 5、增量导出/抽样/删书保留/清单跨机迁移 8、注册表对账与删除/active 保护/越界拒绝 5、统计口径切换回归——test_training_service 全绿）；flutter analyze 零问题。BACKEND_BUILD v102→v103。

## 1.0.0+76

- **新功能：识别监控悬浮窗——全书识别期间的全局进度 / 队列 / 关机 / 整机资源监控**（用户需求：整本识别挂机时在任何界面都能看到当前书的进度、还有几本在排队、可设置全部跑完后自动关机，并实时看到系统 CPU/内存/显存占用与曲线；选择常驻显示模式）。四个部分：
  **① 后端整机统计（api_base.py）**——`/process_stats` 新增 `system` 块（整机口径，任务管理器视角）：`psutil.cpu_percent(interval=0.25)`（同步端点本就跑线程池，不挡事件循环）+ `virtual_memory`（used = total − available，与任务管理器"已使用"一致）+ nvidia-smi 整卡三值（利用率/已用显存/总显存，取第 0 卡，与既有整卡显存兜底同口径；无 N 卡或查询失败各值 null，客户端显示"不可用"）；与进程树统计同享 1.5s TTL 缓存。跨语言格式基准声明在 `_system_stats` docstring（只追加字段不改名，与 region 词表同一纪律），Dart 侧 `SystemStats.fromJson` 镜像解析。BACKEND_BUILD v101→v102（Dart 握手同步，旧后端自动重启）。
  **② 前端数据层**——python_service.dart 新增 `SystemStats` 解析（缺块/缺 GPU 字段/非 Map 负载均容错，旧后端时为 null）；新 `services/system_monitor.dart` 单例 ChangeNotifier（与 RecognitionQueue 同模式）：2 秒轮询（略大于后端 1.5s TTL，每次轮询都触发新采样，曲线无平台期），CPU%/内存%/显存%/GPU% 四条 90 点（约 3 分钟）滚动历史，超界钳 0~100，无 N 卡时对应曲线保持为空（空 = 不可用，与 0% 占用区分）；`fetch` 静态注入缝（同 busyRetryLimit 模式）供测试替换。
  **③ 悬浮窗（新 `widgets/floating_monitor_window.dart`，挂 MaterialApp.builder 的全局 Stack 顶层）**——位于 Navigator 之上，任何页面/对话框/编辑器浮层之上可见。常驻显示（首次默认显示，位置/可见性/折叠态记入 SharedPreferences，拖动屏幕内钳制）；标题栏拖动、可折叠成 56px 圆形进度徽标（显示当前书百分比，点击展开）、可关闭（首页 AppBar 新增 monitor_heart 开关按钮再打开）。内容三块：当前书进度（书名/第 X/共 Y 页/百分比/预计剩余/正在停止态）+ 等待队列数（RecognitionQueue 新增 queuedProjects getter）；「全部识别完成后关机」开关 + 倒计时秒数 + 一键取消（复用队列既有 shutdownWhenIdle/cancelScheduledShutdown 状态源，与首页卡片开关联动；补齐原倒计时横幅只在首页可见的缺口——在编辑器里也能看到并取消）；整机 CPU/内存/显存/GPU 四行当前值 + 迷你折线（新 widgets/sparkline.dart 自绘 CustomPainter，无第三方图表依赖），后端未运行/版本过旧显示不可用及原因。SystemMonitor 随窗口显示/隐藏启停（唯一消费者）。
  **④ 首页不动**——既有 3 秒进程树轮询与统计条照旧；后端 TTL 缓存把两路请求去重成至多每 1.5s 一次真实采样。
  **⑤ 启动崩溃修复（首版实测反馈）**——窗口在 Navigator 之外，子树没有现成的 Overlay/Material 祖源：IconButton 的 tooltip 包 Tooltip，悬停气泡要插最近 Overlay（指针落在悬浮窗上即抛 "No Overlay widget found" 启动退出），IconButton/Switch 也断言 Material 祖源。修复：Positioned 子级挂 `_LocalOverlayHost`（本地 `Overlay`，entry `canSizeOverlay: true`——本 SDK 中 Positioned 只给 left/top 时子约束无界，Overlay 无法自决定尺寸；clipBehavior: none 允许气泡画出窗口边界；didUpdateWidget 里 markNeedsBuild 传导子树变化，OverlayEntry 不随外围 rebuild 自动重建）+ `Material(type: transparency)`。
  测试：Dart 新增 12 条（system 块解析容错 4 条 + SystemMonitor 历史追加/裁剪/钳制/无卡空曲线/失败保持/启停幂等 6 条 + 悬浮窗挂载冒烟 2 条——builder Stack 无 Overlay 祖源环境下渲染/鼠标悬停弹气泡不崩、隐藏时不参与渲染与命中，锁住启动崩溃回归）；Python 新增 6 条（nvidia-smi 输出解析/畸形行跳过/异常吞吐/任务管理器口径/无 psutil 为 None/端点携带 system 块）。`flutter analyze` 零问题；全量 Dart 323 过 + 1 条既有环境依赖用例（需本机 crowdtest1 项目）；Python 全量 376 过、除 2 条基线既有失败（双栏去重相关，2026-09-30 基线日志）外全绿。pubspec 版本 1.0.0+72→1.0.0+76（一并补齐此前落后 CHANGELOG 的 +73~+75）。

## 1.0.0+75

- **修复：整页识别的行框墨迹扩展上限误拒——检测少框几个字的列整列底部丢失，字框落在行框外（"没有画进单行识别框"）**（用户实测：l_011 列（生的年、月、日、時…）底部的「（註一），再」在单行识别框范围外、但单字详细里存在）。根因链：YOLO 检测的行框 (966,113,53,1706) 偏短——列的实际墨迹到 y2117，`expand_line_rect_to_neighbor_ink` 正确扩到 (65,2052)（+346px），但 `apply_kraken_recognition` 整页路径的扩展上限 `max(32, 20%×行高)=341px` 以 **5px 之差**拒绝了扩展（日志"expansion 346px exceeds 341px; keep YOLO box"）→ 整页只用短框识别（33 字，列底字全丢）；后续 AI 修复的单行路径（`_expand_line_rect_for_reading` 无此上限）扩展后补回 39 个字框，但合回只换字框不同步行框——最终字在行框外，编辑器渲染为"不在单行识别框内"。修复：整页扩展上限 20%→**25%**（kraken_bridge.py，1706px 列底漏 5 字的 +346px=20.3% 现被接受；该上限防的病态案例——栏线链把行框拉到整页高度（>100% 增长）——仍远超上限被挡，`expand_line_rect_to_neighbor_ink` 的尘点地板防线不变）。实页验证：l_011 扩展接受（growth 346 ≤ 426），扩展框切分 40 框、列底（（註一），再 至 y2120）全覆盖；整页响应的行框即为扩展框，字框不再越界。注：单行重识别合回不同步行框为 Dart 端既有行为（原位替换哲学），整页路径修复后行框源头即为全高，不再产生越界字框；如仍遇到手画短行框的场景需同步行框，属后续 Dart 侧独立改进。BACKEND_BUILD v100→v101（Dart 握手同步，旧后端自动重启）。全量测试 370 过、除 2 条基线既有失败（双栏去重相关）外全绿。

## 1.0.0+74

- **修复：单行重识别"漏字"——错位检测误弃良性差额框（标点全部失去字框）+ 數类部件碎块併回 + offset-fix 重建的文本错挂**（用户实测：「生的年、月、日、時，…」行重识别后 、/， 标点字框全部消失；前版 v99 的良性差额把含标点的 40 框交给融合层后，`_detect_pairing_offset` 在"框数(40)≠序列字数(38)"时逐位对照天然差一格，把几何正确的像素框误判成整体错位 → 整批弃用、cuts 重建——该重建路径没有标点拆分，标点框全部丢失）。三处修复（kraken_bridge.py/seg_refine.py）：① **错位检测加"框数=序列字数"门槛**——检测器的设计前提就是框数恰好等于字数（行首混入行外组件/行尾并字补数）；框数更多时（标点/碎块框）标点位无序列字、crop[i]==seq[i-1] 天然成立，不检测；② **offset-fix 重建后重新对齐**——重建框列表过滤了空序列项、收紧还可能删格，build() 按新框索引旧 aligned 列表会整体错一位（每框挂邻字的序列文本），改为重建后按中心重新对齐并同步 seq_texts；③ **部件碎块併回（寬+窄分支新例外）**——本书字距最小实测 3~4px（將/實/際 几乎相贴），与部件缝同量级、缝宽判据失效：宽段是"有分量的部件"（0.45~0.75×中位——整字高的宽段必是字、不足 0.45 的是『一』类细笔画）且非实心横带、窄段是碎尾（≤0.35×中位）、合计 ≤1.1×中位时併回一个字框（实测『數』=上部 29px+攵脚 11px、缝 2px）。用户约束不变：整字+紧贴标点不命中（宽段达整字高）、窄标点框绘制路径未动，既有『一』+标点分离测试保持绿。诊断过程修正一项误判：单框逐一验证证明逐框读法与 kraken cuts 一直是准确对齐的（會=578-626、問=633-679、這=684-729 各自整框整读），v73 报告的"融合配对错位"实为字形定位标注错误。实页验证：l_011（expected=34 用户同参数调用）39 框、、/， 标点框全数保留、无漏字；l_013 數 框 (1138,478,45,82) 读『數』正确、會/問/這 各自正确；l_010（含【註二】夹注）40 框无零尺寸、无重叠框（截图所见"叠字"为前端渲染小框/候选，后端无叠框数据）。已知残留：數 下方 11px 攵脚碎尾仍自成小框（与修复前行为一致，非回归）、小标点 crop 逐框读为 八/月/日（模型对极小 crop 的识别局限，属读法质量非切分）。BACKEND_BUILD v99→v100（Dart 握手同步，旧后端自动重启）。新增 Python 测试 2 条（數类碎块併回/错位检测门槛防误弃），全量 370 过、除 2 条基线既有失败（双栏去重相关）外全绿。

## 1.0.0+73

- **修复：「數？會」被切碎——會类"内部留白整字"不再被拦腰切开、？/句读点框归位（三处判据加固 + debug 黄框保真）**（用户实测：某列「斗數？會問…」中 數/？/會 全部拆错——會 被切成人字头+身两框、身部单独读成「日」候选，？ 框带进邻字）。根因链：整行读法漏读小标点（35 字 vs 连通域 38 组件）→ 数量校验全有全无、整行弃用连通域框改用 kraken cuts 条带；cuts 格界与字形错位，會 的 1~4px 部件缝使头/身两段墨迹按"中心归格"分落相邻两格；后续「字+标点」拆分的"单字部件留白"护栏只护"两段都半字高"（需=雨+而），26/45 类不对称部件拆分漏放。修复四件（seg_refine.py/kraken_boxes.py/seg_chars.py/api_segment.py）：① **宽段窄缝护栏（拆分+合并两处）**——所有段都达字宽（≥主字段 65%）、相邻缝 ≤0.15×中位字高、合计 ≤1.5×中位字高时判单字部件留白不拆/併回，不再要求两段都半字高；② **实心横带判据**（`_run_is_solid_band`：行墨迹延展均匀 + 行墨量达最大延展 60%）——字与紧贴的『一』（实测间隔仅 2~6px，与部件缝同量级）是均匀实墨、會 的人字头上窄下宽/日田身部行墨量仅两竖笔，缝宽之外再加形状判据，『一』照常独立成框不受影响；③ **收紧张归格前自适应窄缝并段**（`_tighten_boxes_to_ink`）——阈值取本行 run 间缝中位数的 35%（钳 2px~0.12×格长）：部件缝（1~2px）远小于典型字距（紧排書实测 4~7px→只并 2px 以下，疏排版同理自适应），會 的头身并成一段按中心归同一格整字成框；实心横带不参与并段（一/三行为不变），窄标点并进字框后仍由「字+标点」拆分独立成框（用户约束：标点识别框绘制不受影响——窄标点宽度不足 65% 字宽，不命中任何新护栏）；④ **良性数量差额保留连通域框**（`_split_chars_in_region`/splitter 契约放宽）——框数只多不少、多出的全是标点/部件碎块尺寸（高 <0.6×字高）、正常字高框不多于期望、无粘连细切时保留连通域框（下游序列-框对齐本就 difflib 容忍插入/删除），不再整行弃用；正常字高框多出（如 ？ 达整字高的批注）仍走兜底。另 **debug_char_split 黄框保真**：兜底行的黄框改用真实链路复跑（recognize_lines 单行取真实 cuts 与真实期望字数 n=len(kchars)，先收紧后标点拆分，与线上同序），并写明"app 传入期望 vs 整行读法"的分歧日志——此前用"网格条带+app 期望"模拟，同一行可与线上结论相反（本例模拟里會完整、线上會切碎，39 vs 35 的期望分歧正是误导来源）；响应新增 sim_source 字段（pixel-split/kraken-cuts/grid-strips），cuts 不可用或横排回退网格条带模拟。实页验证：该列最终框 會=(1140,684,45,46) 整字、？=(1137,576,49,53) 整框、數/問/題 乾净无邻字出血（修复前 會 被切两框+日 候选）。BACKEND_BUILD v98→v99（Dart 握手同步，旧后端自动重启）。新增 Python 测试 6 条（會类不对称部件不拆/碎框併回/紧贴窄标点仍拆出/窄缝并段歸同格/实心横带不并段/良性差额保留连通域框），全量除 2 条基线既有失败（双栏去重相关，2026-09-30 基线日志）外通过。

## 1.0.0+72

- **改进：区域门控——只有正文区域进行段落/行/单字划分与识别，页眉页脚等止步于版面区检测**（用户规则：训练与标注仍覆盖正文+页眉页脚等全部区域类型，识别模型也学习所有确认过的行；但识别管线里页眉页脚不再走后续识别）。实现：整页识别时 region_det 先行检测版面区，页眉/页脚/页码区在字检测之前就被抹成页面底色（生成临时门控图作为检测源，白底/黑底页按边框像素中值取底色，几何坐标系不变），这些区域不再产出任何行/字/段落，后续 Kraken 行识别自然读不到；区域框本身仍随识别结果原样输出，供编辑器标注、确认与训练（region_det 五类与 Kraken 确认行的训练链路不变）。眉批（margin_note）按既有"标记不删除"哲学保留在管线内，照常识别并打夹注标。工程细节：① 预置区域复用——管线先行检测出的 main_regions 直接注入结果，`_augment_with_model_hierarchy` 不再对同一页跑第二遍 region_det；② region_det 不可用或当页没有排除类区时不生成门控图，退回整页识别（无安全边界不强切，与 `_filter_layout`"只识别正文"事后过滤的安全网并存）；③ opencv 投影回退路径同样走门控图；④ 识别完成即删临时图。`/segment` 与 `/segment_lines_in_region`（区域重识别）共用同一管线，语义一致——对页眉区域做区域重识别不会再产出文字行。BACKEND_BUILD v97→v98（Dart 握手同步，旧后端自动重启）。新增 Python 测试 9 条（门控图掩码与底色取值/无排除类区与 rejected 区不门控/深底页取深底色/预置区域跳过重复推理/cls→label 映射优先级），全量除 2 条基线既有失败（双栏去重相关，2026-09-30 基线日志）外通过。

## 1.0.0+71

- **改进：校对页新增标题栏下方工具栏——页面操作直达 + 新框类别快切（快捷键 1~5）**（用户需求：旋转/镜像等高频页面操作从「页面」菜单里翻出来横排展示；「新框类别」从右侧面板上移）。三处：
  ① **工具栏（仅标注视图显示，高 42px 可横向滚动）**——左侧四个高频页面操作按钮：顺时针/逆时针旋转 90°、左右镜像、上下镜像（加载中或无标注时禁用，行为与「页面」菜单完全同源，标注几何同步变换）；进入主区视图后右侧追加「新框类别」五个类别快切芯片（色点 + 中文名 + 快捷键序号，选中态高亮，tooltip 说明生效范围）。
  ② **快捷键 1~5**——主数字与小键盘都认，仅主区视图且非排序模式生效，切换后新画的框即带该类别；与工具栏芯片、画布新框、属性面板下拉同一状态。文本输入框聚焦时事件到不了页面级 KeyboardListener，不会误吞数字输入。
  ③ **右侧面板去重**——原「新框类别」下拉与图例移除（芯片自带色点即图例），预标注按钮保留；主区视图空态提示语补快捷键说明。
  类别框归属**主区（正文区）视图**而非段落视图：类别框与 main_text 同层（region_det 输出的版面区级），段落是区内下一级结构（行⊆段⊆主区）；段落视图已有自己的类型轴（body/annotation 小注段），下游训练取样/正文过滤/级联修剪/导出全部挂在 main_regions[].label 上。`flutter analyze` 零问题，相关测试 21 条通过。

## 1.0.0+70

- **新功能：版面区检测多类化（正文/页眉/页脚/页码/眉批）+ 规则/AI 预标注 + 多类互证**（目的：把正文区画得更准——region_det 从单类 main_text 扩为五类互证，页眉页脚页码不再混进正文）。五个部分：
  **① region_det 五类与训练链路（后端）**——类别词表 `main_text`(id=0 恒定)/`header`/`footer`/`page_number`/`margin_note`，Dart `RegionLabel` 与 Python `LAYER_INFO` 同序互指（跨语言协议：只追加不重排，重排会让旧标注/旧模型类别 id 静默错标）。训练数据生成按 `main_regions[].label` 映射类别 id（旧标注无 label 缺省 main_text，历史书样本不失效；词表外 label 跳过并计数）；**数据集缓存按类集指纹自动失效**——`_meta.json` 条目里的 classes 列表与当前词表不符即重建，避免旧单类 data.yaml 遇到新类别 id 越界毁训练；训练 run 条目记录本次 names 快照（注册表可区分单类/多类模型）；`/train/stats` 新增 region_det 每类实例分布。
  **② 推理与过滤语义（后端）**——`_augment_with_model_hierarchy` 用 **checkpoint 自带 names** 映射 cls→label（旧单类模型天然兼容），score 落到区域 `confidence`；`_filter_layout`（只识别正文）的包含边界只认 main_text+margin_note：页眉/页脚/页码区里的行/字被过滤（此前任何区域都算正文边界、页眉照常输出），眉批区行保留并打 `layout_role='annotation'`、字打 `type='annotation'`（与双行夹注同一"标记不删除"哲学）；`_enforce_hierarchy_containment` 宿主区只认 main_text（行/段不再被钳进页眉页脚框）；region 的 status 归一到四态合同（原 setdefault 会让旧导出状态透传）；**多类互证**：main_text 区与排除类区重叠（交集占排除类框 ≥30%）时结果带 `region_conflicts`（只标记不裁决，all_text 模式也报）。
  **③ 新端点（后端，新模块 region_prelabel.py + api_region.py）**——`POST /region_prelabel`：规则 + 跨页一致性预标注（顶/底条带墨迹聚行、孤立短列、页码文字模式、相邻页同归一化 y 同文重复加权、天头小字多列疑似眉批；与已有区域重叠的建议丢弃=只填空；服务端只读不写标注）；`POST /region_refine`：任意来源粗框的几何安全层（钳回图内、词表校验、墨迹收紧复用 ink_rect、同类近重复去除、逐项丢弃原因）；`POST /page_prelabel_image`：VLM 整页素材图（降采样≤1536 + 1/8 网格归一化坐标刻度 + 已有区域半透明底色）。BACKEND_BUILD v96→v97。
  **④ 编辑器多类标注（客户端）**——主区视图：属性面板类别下拉（五类中文名）、「新框类别」选择器（拖拽新框带该类别）、按类别配色与图例；级联修剪（`spliceRegionLines`）与段落认领（`ensureHierarchyContainment`）的正文边界/宿主只认 main_text+margin_note（页眉页脚页码区不再保住其中的行、段落不再被页眉区收容撑大）；YoloExporter region 层按词表映射 classId（原写死单类）；`/segment` 响应的 `region_conflicts` 解析为运行时诊断（不落盘），冲突区域画红警示描边 + 属性面板警示条。
  **⑤ 预标注入口（客户端）**——主区视图「预标注版面区」：调 /region_prelabel，建议落为 proposed 区域（按类别配色），主区快设页新增「规则预标注」全书批量（逐页建议+保存+进度框+可停止）；「AI 整页预标注」（新 `ai_page_prelabel.dart`，仿整行三步裁决先例；设置页新增开关默认关）：素材图 → 视觉模型判定五类区域（归一化粗框，提示词说明网格刻度/已有底色区域不重标/不确定宁可不报）→ /region_refine 墨迹几何精修（语义归模型、像素归几何）→ proposed 落地，与已有区域重叠跳过，结果报告弹窗含模型/耗时/精修丢弃原因，全程互斥防并发。
  测试：Python 新增 17 条（label→cls 映射与 data.yaml 类名、类集指纹缓存重建、每类分布、排除类过滤、眉批保留打标、冲突检出、层级宿主、_augment 多类映射与 checkpoint names 优先、预标注规则/跨页/只填空/眉批、精修钳制收紧/空框/词表外/近重复、素材图降采样网格），全量除 2 条基线既有失败（2026-09-30 基线日志已记录的双栏去重相关）外通过；Dart 新增 9 条（词表顺序与归一、宿主/排除类互斥覆盖、预标注解析围栏/钳制/退化框/答非所问、header 区不保护行、margin_note 区保护行、段落不被页眉区收容），全量 311 过 + 1 条既有环境依赖用例（需本机 crowdtest1 项目）。

## 1.0.0+69

- **修复：AI 校对/修框不理解阅读方向、编号乱序、修复后出现大量重叠框**（用户实测：古籍横排从右到左/竖排方向未告知 AI，段落与短行编号顺序不对；单行识别时重复出现大量重叠的单行识别框）。四处根因同修：
  ① **AI 提示词补齐阅读方向**——`analyzeLine`（三步裁决）与 `diagnoseLineBox`（框检查）新增 `horizontalDir`（ltr/rtl）/`verticalDir`（ttb/btt）参数，prompt 明确写出「横排（行内阅读顺序：从右到左）/竖排（列内阅读顺序：从上到下）」，读行、逐字对应、框序号方位判断全部有据；此前框检查硬编码「从左到右/从上到下」，rtl/btt 的书等于给模型指错方向。编辑器与对比页从项目按页设置传入。
  ② **尾段重摆矩形按方向计算**——`tailRectOf` 此前硬编码「横排=anchor 左边→行右、竖排=anchor 顶→行底」，rtl 横排/btt 竖排会裁到行首/邻列，合并回来即大面积重叠框；现按方向取「anchor → 行末尾」（rtl 在左边、btt 在上边）。
  ③ **叠框守卫**——`shouldAdopt` 新增「新字框两两显著重叠（交集占较小框 >30%）拒绝采纳」，尾段修复另加「后端返回多行（疑似并排子列/邻列）不自动合并」：重摆区域选错/结构复杂的产出（质量分再高）一律挡在采纳外，溯源里写明原因。
  ④ **编号与叠加框严格同序**——`diagnosisCharsOf`（给 AI 的逐字编号）与行条图叠加框（`_thumbOf`、对比页框诊断）都先按 `order` 排序再 1 基连续编号：手工编辑过的行 order 乱序/跳号时，此前文字编号与图上框编号对不上（短行尤其明显），AI 报 pos 指错框。
  新增测试 5 条（rtl/btt 尾段矩形、安全边距小交集不算大面积互叠算、乱序 order 重编号、互叠新框拒绝采纳），Dart 全量 302 条通过（环境依赖的识字任务包联调用例除外）。

## 1.0.0+68

- **修复：整行三步裁决报「Unsupported operation: Cannot add to an unmodifiable list」**（用户实测）。根因：`CharBlock.fromJson` 对没有 candidates 字段的字块兜底用了 `const []`（不可变列表），新版候选并入改为原地 `add`（旧整行裁决是整列表替换、从不触发）；任何无候选的字块一行内必崩、该行回退 OCR。修复两处：① 反序列化兜底改为可增长空列表；② `applyDecisionToLine` 的候选并入改为**整列表替换**（对任何来源的不可变列表都安全）。回归测试 +1（const [] 候选列表下并入候选不崩溃且字/候选/保底齐全）。
- **新功能：整行 AI 辅助升级为「三步裁决 + YOLO 局部修复闭环 + 全流程溯源」**（用户设计：先把整行图发给 AI 读出应有文字，再用单字图逐字对应出候选与文字/标点判断，再诊断字框是否切半并联动修复，全过程完全详细可溯源）。三部分：
  **① 三步裁决引擎（替换旧 `decideLineText`）**——每行一次调用同时发送**干净整行裁图**（不再叠加橙框、不再提供当前行 OCR 文本，模型必须自己从图里读）+ **按阅读序的单字裁图**（`/char_thumbnails` 白底 224px、上限 40 张、任一张裁切失败整体退化为仅行图模式保证图序与框序不错位），prompt 三步引导：读行 → 逐字对应（2~4 候选 + 文字/标点判断）→ 裁切边界诊断（char_clipped/char_merged/char_extra_ink 白名单）。文本写回沿用固定 0.80 阈值、字框数量、序号连续、line_text=拼接四道门禁（不达标走 line_text rune 回退）；**AI 候选与切分标记属 advisory：不受文本门禁限制照写**——候选带 `ai` 标记并入 `CharBlock.candidates`（快捷候选条紫色角标），切分问题写入新字段 `aiBoxIssue`/`aiBoxNote`。本地与外部 API 传输层都支持多图（Ollama `images` 数组 / OpenAI content 多 `image_url` 分片），`OllamaTrace` 记录全部图像。
  **② YOLO 局部修复闭环（新 `ai_line_repair.dart`）**——AI 标记切分问题或读出字数多于框数（漏字信号、取首个文字分歧位）时，取**问题框前一框的起始边到行末尾**的尾段矩形交 `/segment_region` 重识别（不是整行重摆；粘连/漏字按旧框数+1 带期望字数），新框合并回整行（前段框原样保留、order 重排、新字块换唯一 id），复用 `lineScore`+`shouldAdopt` 质量分裁决（提升才采纳、内容守恒），采纳后 AI 复核一次（stage=reverify，不再二次修复，每行最多修一次）；用户校准行（manual/已确认）跳过。识别流程内自动触发；编辑器行卡片新增「按 AI 标记局部修复」按钮可手动触发（续写进同一条溯源时间线）；字框被手工拖动/缩放即清除其标记。
  **③ 全流程溯源（新 `ai_trace.dart` + 编辑器「AI 溯源」面板）**——每行每阶段（三步分析/局部修复/AI 复核）记录：AI 看到的所有图（落盘 `{projectDir}/ai_trace/{pageId}/`）、完整 prompt、思维链、原始返回、解析判定、门槛逐项 ✓/✗、逐字写入 diff、修复详情（触发/尾段矩形/后端新框/前后质量分/采纳结论）。每页**只保留最后一次识别运行**（先清后写）；编辑器顶栏新增「AI 溯源」入口按行分组回看；AI 模型对比页的「整行裁决」任务改跑**完整新闭环**（同口径、指标取端到端最终文字）、「AI 过程」对话框升级为逐阶段多图画廊渲染（新共享组件 `AiTraceEntryView`）。设置页新增「记录 AI 思维链」开关（默认开，识别路径也带思维链进溯源；关闭省 token）。
  后端 Python 零改动。字框画布新增深橙右下三角标记 aiBoxIssue。新增测试 22 条（解析器围栏/候选/裁切问题/回退、修复触发判定、尾段矩形横竖排、写回门禁 advisory 语义、实质相同判定、溯源持久化往返/续写/内存模式），Dart 全量 297 条通过（1 条环境依赖的识字任务包联调用例除外，需本机存在 crowdtest1 项目数据）。

## 1.0.0+67

- **修复：AI 行条图的目标字标注把字盖住**（用户实测：「要识别的地方被橙色框包围、中间写了个 1，根本看不到原先这里应该是什么字」）。根因：`/line_thumbnails` 的字框标注是 2px 橙色描边 + 框内左上角 14px 白底序号块——目标字框偏小时（标点小框/异常窄框，低分辨率书尤甚）描边近实心、白块比字还大，整个字形被盖掉。修复为"标注三原则"：① **框内改 25% 半透明橙色高亮**——任何字框尺寸都透得出字形，绝不实心遮字，淡橙底对 VLM 反而更醒目；② 橙色描边维持 2px（原图尺度画完再缩）；③ **序号白块移到框外**（竖排行在框左侧、横排行在框上方；贴裁图边缘放不下才退回框内左上角），不再压框内字形——识别框诊断的多框序号同样受益。同步：单字辅助与识别框诊断的提示词措辞更新（说明高亮为半透明、序号位置）；`BACKEND_BUILD` v95→v96（Dart 同步 `_expectedBackendBuild`，旧后端自动重启生效）。后端回归测试 +1（框内黑字混色后仍暗、序号白块在框外比框内更亮），行条图相关 11 条通过；Dart 全量 278 条通过。

## 1.0.0+66

- **修复：AI 模型对比页展开结果行时崩溃退出**（用户实测："The Scrollbar's ScrollController has no ScrollPosition attached / A Scrollbar cannot be painted without a ScrollPosition"）。根因：右栏结果行展开后的 trace 面板（深色终端风文字日志）裸用 `Scrollbar(child: SingleChildScrollView(…))` 没传 controller——Scrollbar paint 时没有任何 ScrollPosition 可挂（Windows 桌面也没有 PrimaryScrollController 兜底），一帧直接抛异常崩掉整页。这是全项目最后一处裸 Scrollbar（其余日志面板早已用防崩组件 `AttachedScrollbar`，其注释描述的正是同一崩溃）。修复：新增 `_TracePanelView`（StatefulWidget 持有 ScrollController）+ `AttachedScrollbar`（controller 未挂载的帧裸渲染列表、挂载后自动带滚动条），trace 文字顺带从 Text 换成 SelectableText（日志可直接选中复制，与「AI 过程」对话框一致）。全量 278 条测试通过。

## 1.0.0+65

- **修复：AI 辅助识别的行条图清晰度过低**（用户实测：单字辅助发送的整行图明显糊于书页原图）。根因：`/line_thumbnails` 服务端把长边硬钳在 **768px**，而竖排行条纵横比悬殊——一列 20~40 字的长行被压进 768px 长边后**每个字只剩 30~40px**（书页原图单字通常 100px+），对比页此前传的 1024 也一样被钳到 768。修复：① 服务端上限 768 → **2048**（下限 128 不变，只缩不放），`BACKEND_BUILD` v94→v95（Dart 同步 `_expectedBackendBuild`，旧后端自动重启生效）；② 各调用点成对提档、正式与对比页保持同口径：**单字辅助**（编辑器 + 对比页）768 → **1536**（目标字约 76px+，橙框标注不变）；**整行裁决**（正式整本/本页/本行重识别 + 对比页）1024（实际被钳 768）→ **1536**；**识别框诊断维持 640**（看的是框布局对齐，不需要字级清晰度，与正式「AI 检查识别框」一致）。副作用可控：1536 行条 PNG 约数百 KB，外部 API 模式上传体积与视觉 token 相应增加、推理稍慢——换单字清晰度值得。后端测试 +2（9999 超限请求被钳 2048、1536 档不再被钳）共 10 条通过；Dart 全量 278 条通过。

## 1.0.0+64

- **改进：「AI 模型对比」四个任务与正式书籍识别完全同口径**（用户要求）。逐项比对四个 AI 功能的正式路径与对比页实现后修正两处残余差异：① **识别框诊断**的行条图尺寸——正式「AI 检查识别框」（AiBoxReviewer）用 `/line_thumbnails` 默认长边 640，对比页此前用 768，已对齐 640（图上橙框数量与密度一致，避免分辨率差异影响模型判断）；② **整行裁决**的字框叠加顺序——正式整本识别（applyAiLineAssistToLines）先把行内字按阅读序（order）排序再叠加橙框（手工编辑过的标注 order 可能乱序），对比页此前按标注原序，已对齐排序。其余口径经比对已一致：单字辅助=整行图（单橙框标目标字，长边 768）+ 前后 12 字上下文 + 当前 OCR 读法（+62 已对齐）；整行裁决=行条图（全字框、长边 1024）+ 逐字信息 + 邻行 ±32 字上下文；标点辅助=纯上下文；诊断的逐字参数同用 diagnosisCharsOf（order 1 基、conf 缺省 0.5、沿轴相对尺寸）。「记录思考过程」开关说明补充口径声明：正式识别不带思维链，该开关仅用于对比观测，评测成绩仍与正式同口径。全量 278 条测试通过。

## 1.0.0+63

- **新功能：「AI 模型对比」新增「AI 过程」视图——完整看到模型看到什么、读到什么、想了什么、答了什么**（用户请求）。此前对比结果只有文字版日志（prompt + 原始返回），看不到发给模型的图像与模型的思考过程。现在：① 三处入口（对照面板「AI 过程」小按钮、右栏结果行的展开按钮、批量汇总逐条明细的「过程」链接）都打开同一个「AI 过程」对话框，分五段完整呈现一次调用——**模型看到的图像**（trace 里实际发送的 base64 图，非统一预览图；点开可放大至 8 倍；模型不支持图像自动去图时附说明"下面这张模型实际没看到"）、**模型读到的文字**（提示词全文）、**模型思考过程**（思维链，见②）、**模型原始返回**、**解析后的决定**（按任务结构化：候选=字/分数/理由+基准命中高亮；整行=输出/置信/差异率/逐字理由；诊断=line_ok/问题列表中文标签+位置+说明；失败=错误详情）；② 任务卡新增「记录模型思考过程」开关（默认关）：开启后请求思维链——本地 Ollama 走 `think:true`（非思考型模型 400 自动关掉重试，仅损失思维链不影响结论；num_predict 补 2048 token 余量），外部 API 兼容各家口径解析 `reasoning_content`（GLM/DeepSeek-R1/Kimi）与 `reasoning.summary`（OpenAI o 系兼容层），同样补 max_tokens 余量防思维链挤占正文；推理型模型开启后明显变慢、更耗 token；③ 文字版 trace 面板同步插入"模型思考过程"段，图像提示改为引导到「AI 过程」看大图；单字辅助的统一预览行图文案修正（实际发送的是带橙框标注版）。新增测试 5 条（reasoning_content / reasoning.summary / reasoning 字符串三种思维链口径、非法 JSON 双空、think 拒绝签名识别），对比+服务 82 条通过。

## 1.0.0+62

- **改进：「AI 模型对比」的单字辅助识别任务与编辑器完全同口径**（用户请求）。上一版（+60）把编辑器的单字辅助识别改成"整行裁图（橙框标出目标字）+ 行内文字上下文"后，对比页的单字辅助任务仍是纯上下文校对路径——评测的是功能的子集，结论可能偏离模型在真实功能上的表现。现在对比页 `charAssist` 同样发送**整行条图（boxes 只传目标字框，即单橙框标注）+ 行内前后 12 字上下文 + 当前 OCR 读法**，与编辑器轻点字框的「AI 辅助识别」输入完全一致：① 裁图失败退化为纯上下文（编辑器同款降级）；② 纯文本模型收到图由服务层自动去图按上下文重试（trace.imageDropped 留痕），评测结论对齐真实功能，代价是文本模型组批量评测每条样本多一次注定 400 的请求、稍慢；③ 对比页模型组说明文案同步（"图像任务必须视觉模型；单字辅助同口径带行图，标点辅助纯上下文"）。测试更新：原"文本组不带图"用例改为"裁图失败退化为纯上下文"语义，新增带图路径守门用例（裁图成功时 trace 附图、prompt 为整行+橙框口径、行内上下文仍在、imageDropped=false），对比相关 78 条全部通过。

## 1.0.0+61

- **新功能：「对比测试」页支持模型与模型互比**（用户请求）。此前模型训练整合页的「对比测试」只能"所选模型 vs 基线（不用任何自训模型）"，想比较两次训练的 run / 中间检查点谁更好，只能逐个启用后再试，看不到并排差异。现在顶部新增「对比」切换：**与基线** / **与另一模型**——选后者出现"模型B"下拉（列出该层全部已训练 run，默认选与模型A 不同的最近一次；与模型A 相同的项置灰提示）。要点：① 模型B 侧识别走既有的 `test_layer + test_model_path` 覆写接口（只覆写被测层、其余层照常），**后端零改动**；② 五个检测层的左右对比/滑动叠加/相似度统计（字框匹配、IoU、文字相似度）全部通用，两侧标题、滑动叠加角标、相似度文案按"模型A（run 名）/模型B（run 名）"动态显示；③ 单字候选分类评测同样支持模型 vs 模型（模型B 侧 `use_models=true + test_model_path`），指标表头与逐字明细的两侧列名动态；④ "两侧完全一致"提示按互比场景给出针对性原因（两侧都没过置信度阈值回退同一管线/预测恰好相同）；⑤ 识别消融（recog_eval）为固定三档设计，不参与模型互比，该模式下隐藏对比切换；模型B 未选（该层只有一个 run）时给出明确指引。README 补「对比测试」小节。

## 1.0.0+60

- **改进：单字辅助识别改为发整行裁图（橙框标出目标字）+ 行内文字上下文**（用户请求）。此前编辑器轻点字框的「AI 辅助识别」只发该字框单独裁出的小图（长边 160px）——模型看不到整行版式与邻字，遇到切框稍偏、字形孤立时缺参照。现在改发该字所在**行的整条裁图**（复用整行裁决/识别框诊断同款 `/line_thumbnails`，长边 768，保持纵横比），并在图上用**橙色方框标出目标字**（与识别框诊断同款橙框+白底序号画法），AI 同时拿到：整行字形版式 + 行内前后各 12 字的文字上下文 + 该字 OCR 初步结果，prompt 明确"以框内字形为准，不要被 OCR 初步结果带偏"。要点：① 裁图失败（后端不可用/行框无效）仍自动退化为纯上下文猜测（无图分支 prompt 保留）；② 标点辅助（按上下文推荐句读）本就不带图，不受影响；③ 「AI 模型对比」页的单字辅助任务保持纯上下文校对口径（该任务测文本模型，带图反而全部走 400 降级）；④ 设置页功能开关说明同步。新增 prompt 守门测试 2 条（带图=整行+橙框口径、无图=纯上下文口径且上下文不丢），全量 273 条通过。

## 1.0.0+59

- **新功能：「AI 模型对比」支持本地与外部模型混选同场对比**（用户请求）。此前对比页只拉当前推理来源（本地 Ollama 或外部 API 之一）的模型列表，想比"本地小模型 vs 外部大模型"得来回切来源分两次跑，结果也没法并排。现在对比页两个来源**并行拉取模型列表**（一边连不上/未配置只降级为该组的提示条，不影响另一边照常对比），图像/文本两组里本地（蓝标「本地」）与外部（青标「外部」）模型**可同时勾选混跑**。实现要点：① 引入带来源的模型标识 `ModelRef`（provider+模型名 record）——勾选、批量编排、结果聚合、程序判断徽章全部以它为键，两来源**同名模型不会混进同一行统计**；② runner 逐模型切换所属传输层（`settings.copyWith(provider).withVisionModel(name)`），编排把同来源同模型的调用排在一起连续跑（减少本地 Ollama 反复换载）；③ 执行进度、对照面板、单对象结果行、批量明细、排名表全部显示「本地·模型名 / 外部·模型名」带来源展示名；④ 默认勾选两来源各自的当前视觉/文本模型，开箱即是"本地 vs 外部"；外部未配置时模型组显示配置引导。新增混跑单测 5 条（ModelRef 相等性与展示名、外部来源未配置地址的可读错误且 provider 落账、本地来源不受外部空配置影响、同名不同来源不混聚合、混跑执行顺序），对比相关 75 条全部通过。

## 1.0.0+58

- **新功能：AI 辅助支持接入外部模型 API**（用户请求）。此前 AI 辅助（单字辅助识别、标点辅助识别、整行裁决、识别框诊断）只能走本地 Ollama，没有独立显卡或想要更强视觉模型的用户用不上。「AI 辅助设置」顶部新增推理来源切换（分段按钮）：**本地 Ollama** / **外部模型 API**（OpenAI Chat Completions 兼容协议，覆盖智谱 GLM、DeepSeek、Kimi、通义千问、SiliconFlow、OpenAI 及任意自建兼容网关）。要点：① 外部模式配置 = 服务商预设（选预设自动填地址）+ API Key（密钥框可显隐）+ 视觉/文本模型名，「测试连接并获取模型」走 `GET /v1/models` 拉列表直接下拉选，也支持手填（服务商上新模型不必等列表）；② 传输层在 `OllamaService._chat` 按 provider 分支，图像按 OpenAI 多模态分片（data URL）发送，JSON 输出用 `response_format: json_object`（网关不支持时自动去掉重试），纯文本模型收到图像报 400 时自动去图按纯上下文重试（trace.imageDropped 留痕，与本地路径同款降级）；401/404/429 映射为中文排查提示并提取 `error.message`；③ 地址归一容错：粘贴到 `/v1` 一级或完整 `/chat/completions` 端点、带尾斜杠、缺 https 协议都能归一；④ 两套来源各存一份完整配置（本地 baseUrl/模型名与外部地址/密钥/模型名互不覆盖），编辑器、整本识别 AI 裁决、「AI 模型对比」页全部按当前来源取模型（对比页模型注入改为按 provider 写对应槽位），AI 整行裁决日志加记 provider；⑤ 本地专属 UI（模型安装卡、一键安装 Ollama、端口抢回）仅本地模式显示，说明卡补充外部模式注意事项（**视觉类辅助会把裁出的字图/行图上传给所选服务商**，密钥只存本机）。新增单测 15 条（配置 round-trip/active 槽位切换、地址归一、请求体分片格式、choices 解析——测试当场抓到少解一层 `message` 的 bug、/models 解析、错误映射、降级签名），全量 266 条通过（识字任务包导出工具测试因本机缺 crowdtest1 项目环境性失败，与本次无关）。

## 1.0.0+57

- **修复：整书识别报"Kraken worker 失败: CUDA error: an illegal memory access was encountered"后反复失败**（用户实测书籍识别中断，重试也失败）。illegal memory access / device-side assert 是**粘性 CUDA 错误**——worker 进程的 CUDA 上下文一旦损坏，此后所有 CUDA 调用都返回同一错误，只有重启进程才能恢复；而 `_KrakenDaemon.request` 收到 ok=False 只抛异常不杀进程，坏 daemon 被放回空闲池，后续页面（与"重新识别"重试）继续撞在它身上，直到整个后端重启。三层修复：① `kraken_proc` 识别致命 CUDA 错误（标记：`CUDA error`/`illegal memory access`/`cudaErrorIllegalAddress`/`device-side assert`；显存 OOM 是瞬态错误、显式排除避免无谓重启）→ 立即杀掉坏 daemon（下次请求惰性重启新进程）；② `_DaemonPool.request` 对致命 CUDA 错误**在重启后的新进程上重试一次**，当前页不因单次 CUDA 崩溃整页失败，重试仍失败才上抛（不无限重试）；③ `kraken_worker` 自带同款判定，命中致命错误在写回错误响应后自行退出（与服务端互为双保险，坏上下文绝不再接客）。顺带补可诊断性：worker 失败响应里的 `traceback` 此前被丢弃、后端日志只剩 App 弹窗级别的单行错误，现在完整落盘进 service_console.log（尾部 1600 字符）。`BACKEND_BUILD` v93→v94（Dart 同步，旧后端自动重启生效）。新增 Python 测试 4 条（致命 CUDA 错误杀进程且下次请求恢复、池重试一次后恢复、重试仍失败正常上抛、瞬态 OOM 不杀不重试）；daemon/融合/分割相关 61 条通过。

## 1.0.0+56

- **移除启动自动续跑：进入软件不再自动开始书籍识别**（用户需求）。原行为：首页首次加载调 `resumePending`，把所有未完成且 autoRecognize 的书自动排进识别队列——上次被关闭软件打断的书一打开应用就自己跑起来。现移除该调用（连同队列的 `resumePending` 方法与首页 `_resumed` 字段，不留死代码）：**识别只由用户手动开始/继续**——中断的书在卡片上显示进度（"待识别"），点播放键即从断点续跑（已有标注的页自动跳过），语义与停止/继续按钮闭环。编辑器内浏览无标注页时的按需识别不受影响（那是看页所需）；`autoRecognize` 字段保留（首页状态文案与"创建后手动开始"流程仍在用）。manual_recognize 测试同步改写（原 resumePending 用例改为"enqueue 只入队指定书、不波及其它书"）。flutter analyze 无告警；Dart 全量 250 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+55

- **修复「停止识别点击没反应」**（用户实测反馈）。根因是反馈缺失而非功能失效：停止在页边界生效——正在识别的页要等后端识别完成（一页可达分钟级），期间界面毫无变化，用户感知即"没反应"。修复：① `RecognitionProgress` 新增 `stopping` 瞬态——点击停止**立即**把快照翻成 stopping，书卡显示橙色"正在停止 · 等当前页（第 N 页）识别完成即停，已识别 N/M 页保留"，停止按钮同时隐藏防重复点击；页边界退出后自动翻"已暂停"；点击时另弹 SnackBar 说明"等当前页识别完成即停（一页可达分钟级）"。② 修掉重启自动续跑陷阱：`_abortExit` 把书翻回 `autoRecognize=false`——用户主动停下的书，重启后 `resumePending` 不再自动续跑（旧版停完一重启就自己又跑起来，同样像"没停住"）；点「继续识别」时 enqueue 会翻回 true，续跑语义不变。flutter analyze 无告警；Dart 全量 250 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+54

- **书库识别增加停止按钮，停止后可一键继续识别**（用户需求）。此前整本识别一旦开始只能等它跑完或杀进程；「批量摆正」的暂停走的是 remove()——书在磁盘上滞留 recognizing 状态、首页无"已暂停"反馈。① `RecognitionQueue.pause(projectId)`：**正在识别的书**标记中止——当前页（含在途预取页）完成后在页边界退出，退出前把书状态落盘回 pending（重启不卡在 recognizing）并留 `paused` 进度快照；**还在排队的书**立即出队并直接给 paused 快照。已识别页即断点（标注文件在），继续 = 普通 enqueue 按"已有标注跳过"从断点续跑。停掉的是队列最后一本书时自动撤销"识别完成后关机"计划（用户主动停下，不该被关机打断）。② 首页书卡：识别中/排队中显示停止按钮（stop_circle，tooltip 区分"当前页完成后停住/取消排队"）；已暂停的书显示橙色"已暂停 · 已识别 N/M 页，点右侧按钮继续识别"+ 进度条保留 + 实心播放键「继续识别」。③ 「批量摆正」进入时的暂停从 remove() 换成 pause()——修掉磁盘滞留 recognizing 状态的旧问题，摆正回来卡片直接显示已暂停可继续。说明：pause 的页边界语义依赖真实识别流程，无离线注入点，本轮以 analyze + 全量回归（250 条通过）+ 手动验证覆盖，未新增单测。flutter analyze 无告警。

## 1.0.0+53

- **模型训练新增「训练曲线」与「中间存档」检查点**（用户需求：训练时可查看训练数据曲线、设置中间过程保存模型——按曲线挑合适的版本启用，也能看出当前训练是否过拟合）。① **中间存档**：/train/start 新增 `save_period`（train_worker 加 `--save-period`），ultralytics 每 N 轮向 weights/ 写独立 `epoch{N}.pt`，done.json 登记 checkpoints 清单；训练页每层卡片 epochs 旁新增「中间存档」选择（不存档/每 5/10/20/30 轮，默认每 10 轮）。② **后端 GET /train/curve**（`train_tasks.training_curve`）：按 run_dir 解析 results.csv——detect/classify 在 run/train/（ultralytics 写）、siamese 在 run 根目录（worker 自写），kind 按列名区分；返回逐 epoch 全部指标/损失列 + 检查点清单（epoch 检查点按轮数升序在前、best/last 收尾，双塔 run 根目录的 best.pt 也纳入）；run_dir 同时支持进行中任务与注册表历史 run（内存任务表重启即清，磁盘产物一直在）；损坏单元格解析为 null 不断表。③ **训练曲线弹窗**（新 `pages/training_curve_dialog.dart` + 新 `widgets/line_chart.dart` 自绘折线图，零三方依赖）：指标/训练损失/验证损失分组 Tab（按 kind 配列，未知格式回落"数值列"一组），悬停/点按出竖线并在图下显示该轮各序列取值，图例点按隐藏/恢复序列（至少留一条）；训练进行中每 4 秒自动轮询看曲线实时生长，多 run 下拉切换（当前/最近任务 + 注册表历史 run，按 run_dir 去重、新→旧）。**过拟合提示**：主指标（detect=mAP50-95 / classify=top1 / siamese=val AUC）峰值轮 vs 最新轮——峰值后 ≥8 轮且回落 >3% 橙字提示"疑似过拟合，可在下方检查点选峰值附近一版启用"；平台期 ≥8 轮灰字提示"已收敛，继续加轮数收益有限"；否则绿字"指标仍在提升"。④ **按曲线挑模型启用**：弹窗下方检查点列表逐行带该轮主指标与体积，「启用」把该 epoch{N}.pt 直接激活为该层当前模型（复用 /models/activate 收任意 .pt 路径的既有语义：复制稳定路径 + reset_custom_models；双塔按 run 目录走 /verify/train/activate），当前启用的检查点行内标记。五层卡片底部与墨迹比对卡片各加「训练曲线」入口。新增 Python 测试 5 条（detect 曲线解析与检查点排序、损坏单元格容错、siamese run 级 CSV 与根目录 best、缺 run_dir 报错、list_checkpoints 忽略杂散文件）与图表组件 widget 测试 3 条（图例开闭保底一条可见、点按定位取值、空序列不炸）；后端 30 条全过，/train/curve 用 TestClient 实测历史 siamese run 返回 200。flutter analyze 无告警；Dart 全量 250 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+52

- **「全书重新识别」语义完善：整书重置回"新加入"状态再从头识别**（用户澄清需求：所有书页重置成未确认未保存、识别框全部重来、AI 辅助照常参与、进书默认第一页，就像新加入一本书）。+51 版的实现是"绕过跳页全量重跑、逐页覆盖旧标注"，存在两处偏差：崩溃重启后续跑会因旧标注文件仍在而退化回"跳过已识别页"；编辑器仍打开上一次浏览的页。重构为 `RecognitionQueue.enqueueReRecognize`：**先删除全部页标注文件**（新 `ProjectStorage.clearAllAnnotations`，整目录移除、单文件占用时逐个兜底删除）——书就此回到新书状态，断点机制（"无标注文件即待识别"）天然从头跑全部页，任何时点崩溃重启续跑都是全量；同步重置 `recognizedPages=0`、`lastPageIndex=0`（再次进入书籍默认第一页）、状态 pending，AI 整行裁决按项目设置照常逐页参与（逐页覆盖的提议/确认状态由识别流程自然产生）。确认对话框文案改为逐条列明（全部页现有标注删除不可恢复 / 从第一页跑完全部页 / 进书默认第一页），SnackBar 提示"已重置为新书状态"。新增单测改为临时目录实测（两个标注文件入临时书目录 → enqueueReRecognize 后标注目录整个移除、计数与上次页号归零、入队跑完出队、守卫不残留）。顺带修复并行改动遗留的 `training_curve_dialog.dart` 4 处编译错误（命名字段记录被按位置访问 `g.$1`/`group.$2` → `g.label`/`group.cols`）与 2 条 lint（函数声明偏好、多余字符串插值括号）。flutter analyze 无告警；Dart 全量 247 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+51

- **书库列表新增「全书重新识别」按钮**（用户需求）。此前书卡只有「开始整本识别」——按"标注文件存在即跳过"断点续跑，识别过/校对过的页永不重做；想整书重来（如调整摆正/识别方向后）只能逐页手动重识别。新增：① `RecognitionQueue.enqueue` 加 `reRecognizeAll` 参数——绕过"已完成书不入队"守卫并同步重置状态计数（status=pending、recognizedPages=0），处理时**无视断点**全部页进待识别队列（识别结果逐页覆盖旧标注文件）；一次性标记用完即清（书出队/被移除时清除，下次普通识别恢复跳页语义）。② 书卡 trailing 区新按钮（Icons.restart_alt，识别中/排队/失败重试的书不显示——那些状态走播放键），点击先弹强确认对话框：明示"共 N 页全部重新识别、逐页覆盖现有标注——包括已「确认并保存」的页，识别框/校对文字/确认状态都会重来且不可恢复"，并指引"只想续识别剩余页用开始整本识别"；确认后走与整本识别相同的 AI 整行裁决设置同步逻辑并入队，SnackBar 与后端日志报"全部 N 页重跑，覆盖已有标注"。新增 1 条单测（已完成书普通 enqueue 空操作 / reRecognizeAll 绕过守卫并重置计数 / 一次性标记不残留），manual_recognize 5 条全过；flutter analyze 无告警；Dart 全量 247 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+50

- **编辑器顶栏按钮整合：18 个控件收敛为 10 个，移除废弃的一次性迁移工具**（用户需求：书籍校对界面上方的按钮整合，无用功能清除；按用户要求「临时保存」按钮保留）。此前顶栏挤着 18 个控件：标题区 6 个（旋转×2/镜像×2/校对摆正/删除页）+ actions 12 个（视图切换/全书总览/全书叠加/主区快设/墨迹归类/墨迹校验/AI 检查/重新识别/临时保存/确认识别框/确认并保存/更多菜单/导出），且校对摆正与确认识别框共用 `crop_free` 图标。现归组为：**标题区** = 书名 + 校对摆正（高频直达）+「页面」菜单（旋转/镜像×4、本页识别方向、框选导出 Excalidraw、删除该页共 7 项，删除项红字）；**actions** = 标注/后台切换 +「全书」菜单（全书总览/全书叠加/主区快设/跨页拆分/墨迹归类全书版/开始整本识别共 6 项）+ 墨迹归类本页 + 墨迹校验 + AI 检查识别框 + 重新识别当前页 + **临时保存（保留，dirty 变实心逻辑不变）** + 确认识别框（图标换 `done_all_outlined` 消除撞车）+ 确认并保存 + 导出。原「更多操作」more_vert 菜单撤销：6 项中 5 项分流进「页面」/「全书」菜单（说明文字保留），**「本书重置为未确认」移除**——自述"清理被旧版翻页自动确认的数据"的一次性迁移工具，唯一调用点即该菜单；连带删除 `_confirmResetBook`/`_resetBookToProposed` 两方法（约 70 行）与已无引用的 `PythonService.verifyTemplatesClear` 包装（后端端点保留；`PageAnnotation.resetToProposed` 尚有测试引用故保留）。所有功能仅归组不消失（除移除项）。flutter analyze 无告警；Dart 全量 246 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+49

- **模型下载支持多选批量 + 并发数设置**（用户需求：OCR AI 辅助模型的下载支持一次选择多个模型下载，可以设置有多少个模型同时下载）。此前拉取管理器是严格单任务——一个模型下载中时其余安装按钮全部禁用。① **`OllamaPullManager` 重写为多任务队列**：新 `OllamaPullTask`（每任务的 phase/进度/字节/速度/状态/错误与 progressText）；`start` 入队（同一模型在队/下载中被忽略、已结束可重入队并替换旧记录），返回的 Future 在该任务到达终态时完成（保持旧 await 语义）；并发额度 1~4（`concurrency` 持久化 `ollama_pull_concurrency`，`setConcurrency` 运行中调整即时放行排队任务），`_pump` 在任务结束/入队/调并发时补位；按模型 `cancel`（下载中关连接、排队中直接移除）与 `cancelAll`；持久化升级 v2 列表（`ollama_active_pulls_v2`，记录排队/下载/失败中的任务），`restore` 读 v2 列表恢复多条 interrupted 并**兼容读取 v1 单任务记录**，同时读回并发数；日志在多任务并行时每行带 `[模型名]` 前缀（单任务保持原格式）。② **设置页「模型安装」卡改造**：推荐行加勾选框（多选），分组标题上方新增批量条——「已选 N 个 · 下载所选 · 清空 · 同时下载 [1~4]」；推荐行按钮不再全局禁用：该模型下载中显示自己的进度条+取消、排队中显示"排队中"+取消排队、失败显示重试、空闲显示安装/重新拉取；自定义安装输入框随时可入队；中断/失败提示条支持多条（多于一条时提供「全部继续/全部忽略」）；下载中的任务逐条显示状态条（模型 · 状态 · 百分比速度 · 取消）；安装成功的收尾（SnackBar/刷新列表/空槽自动选型）改为按成功集合逐模型处理。新增/重写 9 条单测（成功清除持久化、失败保留、v2 多条恢复 + v1 兼容 + 二次空操作、按模型 dismiss/dismissAll、并发 2 同时拉 2 第 3 排队 + 完成即放行 + 运行中调高并发即时放行、并发钳制 1..4 与持久化读回、按模型取消两态、重复入队忽略与结束后重入队、startAll 批量入队含持久化全部），全部通过；flutter analyze 无告警；Dart 全量 246 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+48

- **首页顶部入口整合：8 个图标按钮归并为 3 个带文字入口，各进一个按 tag 区分功能区的整合页**（用户需求 + 按 mingji-design-taste skill 的通用审美纪律美化）。此前首页 AppBar 挤着 8 个纯图标按钮（模型训练 / 模型对比测试 / 模型使用管理 / 切分调试 / 墨迹校验调试 / 导入命迹识字共识 / AI 辅助设置 / 后端控制台），可读性差。现归并为 **模型训练 / 设置 / 调试** 三个 `TextButton.icon`（图标+文字，间距 8）：① **「模型训练」**（新 `pages/hub_page.dart`）tag = 训练（TrainingPage）· 对比测试（ModelComparePage）；② **「设置」** tag = 模型管理（ModelManagePage）· AI 辅助（OllamaSettingsPage，其内「AI 模型对比」入口不变）；③ **「调试」** tag = 切分调试（DebugPage）· 墨迹校验（CharVerifyDebugPage）· 共识导入（CrowdImportPage，rootDir 由调试页按首页同口径提供），后端控制台菜单（terminal PopupMenu）迁到调试页右上角。**HubPage 容器**：AppBar + TabBar + **IndexedStack 保活**——训练/对比/调试页都有"进行中"状态（训练任务、对比结果、调试图），TabBarView 切远页销毁 State 会全部丢失，故用 TabController 监听 index 切 IndexedStack 显示层；TabBar 配色全走主题 token（label=primary、未选中 onSurface@70%、分隔线 onSurface@10%，无硬编码颜色）。**七个功能页加 `embedded` 参数**（最小侵入：build 里 embedded 时返回裸 body 不包 Scaffold，独立打开行为完全兼容）：TrainingPage/OllamaSettingsPage 的 loading 与空态两分支都处理；ModelManagePage 的 refresh 按钮嵌入时移入「配置对象」行末尾；DebugPage/CharVerifyDebugPage 的 AppBar.bottom 可视化/日志切换条嵌入时移到正文顶部（Column 包 IndexedStack）；首页删除 7 个页面直连 import 换 hub_page。**美化纪律**（skill 通用部分，保留 indigo 不引入命迹黑金）：三把锁——一屏一套调色板（primary 唯一强调色、语义色维持既有绿/红/橙节奏）、一套圆角（沿用 4/6/8/12）、一套字体；间距全 4 倍数；层级用透明度节奏；AI 痕迹清单逐条过（无渐变/pills/玻璃拟态）；动效仅切标签微反馈。flutter analyze 无告警；Dart 全量 243 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+47

- **修复识别运行中日志面板的 Scrollbar 断言崩溃**（用户实测：识别时应用在 Scrollbar 绘制处异常退出，报 "The Scrollbar's ScrollController has no ScrollPosition attached"）。根因：`Scrollbar.paint` 对传入的 `controller` 有 `hasClients` 硬断言——识别等后台任务运行时，日志面板随导航/重建把列表从树上卸掉而 Scrollbar 还在绘制一帧（或 controller 尚未 attach 的首帧），断言直接抛错崩掉整页。修复：新增 `widgets/attached_scrollbar.dart`（`AttachedScrollbar`）——利用 ScrollController 的 attach/detach 会触发 notifyListeners 的特性，`hasClients` 为 false 时先裸渲染列表（不带滚动条），attach 后自动带上；滚动期间 builder 虽每帧执行但 child 是同一 widget 实例，Flutter 直接复用子树无实际开销。三处带 controller 的 Scrollbar 全部换用（设置页 `_miniLogPanel` 拉取/安装日志、环境准备页 `_LogPanel` 安装日志、端口抢回面板日志）；对比页 trace 面板的 Scrollbar 无 controller（桌面端走通知驱动，不触发该断言）不动。后端控制台面板本就有 `hasClients` 守卫不动。flutter analyze 无告警；Dart 全量 243 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+46

- **单字辅助识别支持各类标点候选**（用户需求：加入对各种标点的识别）。此前 `suggestChar` 被硬性限定为单个汉字——prompt 写明"每个 text 必须是单个汉字"、解析白名单 `_cjkChars` 只含 CJK 汉字区、兜底提取器也只抓汉字，模型即使返回括号也会被三层逐一过滤。现改为：① prompt 放宽为"判断这是什么字或标点""每个 text 必须是单个汉字或单个标点符号（句读、括号、书名号、引号等成对标点的一半）"；② 新增合并白名单 `_cjkAndPunctChars`（汉字 + 标点全集），解析与兜底都用它——括号 `（）()【】[]`、书名号 `《》〈〉`、引号 `「」『』`、句读等都能进候选；③ 新增专用兜底提取器 `_extractCjkOrPunct`：通用提取的引号包裹位刻意排除了括号字符（只服务汉字，「（」抽不到），合并集版允许包裹位为标点（只排除空白，非白名单字符仍被字符集检查剔除），引号抽不到再按出现顺序裸抽。**路由不变**：编辑器里标点样小框仍自动走标点辅助，大字框走单字辅助（现在也能给括号候选），整行裁决本就允许标点；设置页「单字辅助识别」开关说明同步加"（汉字或标点：句读、括号、书名号、引号等）"。测试入口 `parseSuggestionsForTest` 增加 `cjkAndPunct` 参数，新增 3 条单测（合并白名单汉字与各类括号候选都保留/字母丢弃、兜底引号包标点、旧白名单仍拒标点），ollama_service 24 条全过；flutter analyze 无告警；Dart 全量 243 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+45

- **「AI 模型对比」面板改为窄竖卡并排 + 所有任务面板都带所选行条图**（用户需求：对比卡片像校对单字卡片那样窄竖卡两个并排做模型对比；只显示所选那一竖行的图片，不显示完整页面）。① **窄竖卡**：竖版书各模型面板从"均分左栏宽"改为**固定 132px 窄卡**横向并排（行图 56px + 竖排单列字格，与校对单字卡片同宽级），超出横向滚动，几个模型就几张窄卡挨着排；横版书面板保持整行堆叠。② **所有面板带行图**：行条图不再取自任务 trace（文本组的单字/标点任务不裁图、面板无图），改为运行完成后**统一拉一次所选行的干净条图**（/line_thumbnails 无橙框版，与校对卡片的行图同观感），单字辅助、标点辅助、整行裁决、识别框诊断四类面板统一"行图在左 + 对照内容在右"；拉取失败回退 trace 图。面板正文布局抽为 `_panelWithImage`（content 参数化：字格列 / 候选列表），竖排字格单列抽 `_cellColumn`。flutter analyze 无告警；ollama_compare 30 条测试通过；Dart 全量 240 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+44

- **「AI 模型对比」两个增强：竖排面板单列不换列 + 人工基准参考判定**（用户需求：所有文字竖着显示不换行；加一个手填这行正确文字的功能，程序判断以手填内容为参考比较哪个模型优秀）。① **竖排单列**：去掉按图高分列的逻辑，每个模型面板的文字就是**一列竖排**——所有字格从上往下排到底（行多长列多长，面板随之变高，对比视图纵向滚动），行图（窄高竖条）仍在左侧；横排书面板保持图上文下。② **人工基准**：任务卡新增「人工基准（可选）」输入框——填入这一行的正确文字后运行对比：整行裁决的基准 = 手填内容（差异率、可采纳判定、"⭐最优 = 与人工基准差异最小"全以它为准）；单字/标点辅助按位取手填内容对应位置的字符为基准（手填比行短时越界位回落到字块当前文本）；框诊断无文字基准不受影响。对比视图顶栏显示绿色「人工基准」徽章（悬停看手填内容），程序判断措辞区分"与人工基准差异最小"（不再重复"基准已人工确认"注）。新增 3 条单测（整行人工基准参考与标记、单字按位映射与越界回落、verdictFor 人工基准措辞与差异率），ollama_compare 30 条全过；flutter analyze 无告警；Dart 全量 240 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+43

- **「AI 模型对比」竖排面板按古籍换列方向从右往左读**（用户反馈：分了列但仍"不是竖列显示"——此前各列从左往右排，句首"生的年月"在最左列，按古籍习惯从右往左读就成乱序）。竖排对照列序取反：**句首列在最右**，读满一列往左换列（与竖排古籍版式一致）；框诊断面板的字格列同序。列距 padding 改列左侧，防止读向缺口歧义。flutter analyze 无告警；ollama_compare 28 条测试通过。

## 1.0.0+42

- **修复「AI 模型对比」竖排面板字格布局：竖排书的识别文字真正按列从上往下显示**（用户反馈：竖列书识别出的文字应竖列显示，与校对单字卡片一致；实测截图里改动字被拉成整列高的橙条、正常字横铺一行）。根因：竖排分支用 `Wrap(direction: vertical)` 包字格，而字格是"带 `alignment` 的无边高 Container"——Wrap 给子组件的松高度约束下，`alignment` 会让容器**膨胀到整列高**（装饰透明的格子隐形、带橙框的改动字变成显眼的高条），每列装不下第二个格子，所有格子横向一字排开。修复：① 字格改为**固定尺寸**（对照格 26×32、诊断格 26×30）——SizedBox 外壳先钳住尺寸，内部 `alignment` 只在格内居中，不再受松约束影响；② 弃用 Wrap，**手动按列分块**：每列字数 = 行图高度 ÷ 字格高（与图同高的读法），`Column` 逐列从上往下排、列间横向并排（读满一列换下一列，观感与编辑器校对单字卡片一致）；列数超出面板宽时横向滚动兜底，不挤压字格。识别框诊断面板同结构（本行字格竖排、问题位红框）。flutter analyze 无告警；ollama_compare 28 条测试通过。

## 1.0.0+41

- **「AI 模型对比」面板改为编辑器单字模式卡片样式：竖版书每个模型卡片"行图在左、竖排对照文字在右"同高并排**（用户反馈：竖列形式的书应竖着显示，和书籍校对单字模式的卡片一样——先是这一列的图片，然后是识别出的文字）。① **面板内嵌行图**：此前原行图在整个对比视图顶部共享展示一次，面板里只有文字；现改为每个模型卡片内嵌行条输入图（即发给模型的那条裁图，含橙框叠加），与编辑器 `_LineCard` 竖排卡片同构——竖排行 = 行图（窄高竖条）在左 + 竖排对照文字在右、与图同高、字满一列自动向右换列（如竖排书换列）；横排行 = 行图（宽矮条）在上 + 横排文字在下。整行裁决面板 = 逐字对照字格（橙底改动/角标原字/悬停理由不变）；识别框诊断面板 = 本行字格竖排、该模型报问题的位置红框标出，说明行列出问题类型@字位。② **行条图解码缓存**：base64 解码一次存 `Uint8List`（避免逐 build 重复解码），ImageStream 探测自然尺寸作"图左文右同高"布局依据（高钳 160~1600px）。③ 面板 ≤3 个时均分左栏宽度，>3 个时横向滚动、固定 168px 宽防挤成条；顶部共享大图移除，顶栏文案注明"图左文右/图上文下"。④ 任务卡说明同步。flutter analyze 无告警；Dart 全量 238 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+40

- **「AI 模型对比」重做为图形化对照工作台：左侧并排竖栏/横栏直观对比各模型对选中行的识别效果，模型选择拆分图像/文本两组**（用户需求：选好书/页/行点「对比选中对象」后，左侧变成多栏对照——栏数随模型数、竖栏/横栏随书版向，展示原行图、各模型识别后的文字、程序判断谁更好；对比模型处分图像模型与文本模型，图像模型只看图（整行裁决/框诊断），文本模型做纯文字校对（单字/标点））。① **模型分组**：「对比模型」卡拆两组 checkbox——图像模型（整行裁决 · 识别框诊断，带图）与文本模型（单字辅助 · 标点辅助，纯上下文），同一模型可同时进两组；默认勾选当前设置的视觉/文本模型。从分组上就不会把纯文本模型推去接图（此前 400 multimodal 的根源），单字辅助在文本组下不再裁字图（省一次后端请求，prompt 走"无图像仅凭上下文"分支）。`CompareTask` 新增 `needsVisionModel`，`runBatch` 改收 `visionModels`/`textModels` 两列表，执行计划=图像任务×图像模型 + 文本任务×文本模型，同模型任务连续跑。② **左侧图形化对照视图**：跑完「对比选中对象」左栏自动切换（重跑先回浏览态），顶栏「返回浏览」随时切回；版向随目标行——竖排书各模型为**并排竖栏**（字沿阅读轴上下排、超出向右换列，Wrap vertical），横排书为**堆叠横栏**（字左右排换行）；顶部展示原行图（发给模型的行条输入），其下按任务分节：每节一条紫色「程序判断」横幅 + 各模型面板（最优面板绿框高亮）。整行裁决面板 = 逐字对照字格（复用上版的橙底改动/角标原字/悬停理由，字格组件 `_diffCellWidget` 抽公共，右栏明细同步复用）；框诊断面板 = 本行字格逐个排开、该模型报问题的位置红框标出（悬停看类型与说明）；单字/标点面板 = 候选排名列表（命中基准的候选绿色）。③ **程序判断 verdictFor**（每任务给出结论一句话 + 每模型徽章）：整行裁决 = 可采纳（conf≥0.80）中与当前文本差异最小者为 ⭐最优（基准人工确认时注明更可信）；单字/标点 = 基准字在候选第 1 位者 ⭐最优、否则 ✓第N/未命中/无基准，全员未命中时明说；框诊断无基准 = 按"与多数模型结论一致"（问题签名=类型@位置集合）判 ✓与多数一致/少数意见，无多数时明示请结合行图人工判断——所有结论都写明依据，不声明绝对正确。④ 右栏保留明细卡（prompt/原始返回/逐字对照）与批量统计、管线协作卡不变。新增 4 条单测（整行最优判定含"差异 0 但不可采纳不夺冠"、全部不可采纳无最优、候选第 1/第 N/全员未命中三态、诊断多数一致/少数/无多数），ollama_compare 28 条全过；flutter analyze 无告警；Dart 全量 238 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+39

- **修复「AI 模型对比」两处实测问题：纯文本模型跑视觉任务报 400 整单失败；行级对比看不清各模型到底改了哪些字**（用户实测反馈）。① **400 multimodal 自动去图重试**：用户用文本模型（如 Gemma）跑单字辅助/整行裁决/框诊断时，Ollama 整单拒绝并报 `Multimodal data provided, but model does not support multimodal requests.`（实测报文还被上游再包了一层 JSON）。修复：`_chat` 识别该 400 签名后**去掉图像按纯上下文重试一次**——文本模型兜底路径（如未配视觉模型时的整行裁决）仍然可用且能出结果；`OllamaTrace` 新增 `imageDropped` 标记，对比页在结果行显示灰色「无图」徽章、候选/对照条注明"模型不支持图像，仅按上下文"，用户能明确看出该模型没看字图。签名判定含双层 JSON 包裹场景，开 `noMultimodalForTest` 测试口。该重试同时惠及生产路径（编辑器里文本模型兜底整行裁决不再因拒图直接失败）。② **整行裁决改为逐字对照视图**：此前每任务展示一张行条裁图（竖排行条是细长条，3 个任务各一张被用户看成"三遍同样的书页"），且看不出模型改了哪个字。现改为：行条图缩小为 56px 佐证小图（标注"本行裁条，非整页"），主体是每个模型一行**逐字对照条**——模型输出侧逐字排开，改动字橙底高亮、角标小字显示被替换的原字（删除线）、新增字标"＋"、删除位显示"∅"；`decideLineText` 返回的 items 与基准等长且序号连续时按位对照并支持**悬停看模型逐字理由**（Tooltip），否则自动退化为编辑距离对齐（新 `lineDiffCells`/`LineDiffCell`/`changedCountOf`，DP 回溯偏好 匹配>修改>新增>删除）；对照条下方汇总"N 处改动 · conf · 可采纳"。③ 识别框诊断的问题序号映射为具体字（如"切字不全@3「祿」"，用运行时的目标行字快照 `_singleLineChars`）。新增 5 条单测（items 按位对照带理由、序号不连续退化对齐、替换/新增/删除/一致四情形、multimodal 双层 JSON 签名识别、普通错误不误判），ollama_compare 24 条全过；flutter analyze 无告警；Dart 全量 234 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+38

- **AI 辅助设置新增「AI 模型对比」工作台：在真实古籍页上对多个 Ollama 模型做四功能 A/B 对比，可看每次调用的 prompt/原始返回，并展示 AI 与 YOLO/OpenCV/Kraken 的管线协作**（用户需求：想实测 Gemma 等候选模型在单字辅助识别、整行裁决、识别框诊断、标点辅助上的表现，并看清这些模型在后台怎样工作、怎样配合 YOLO/OpenCV）。入口在 AI 辅助设置新增「模型对比测试」卡（与 YOLO 自训模型的「模型对比测试」页相互独立，命名避开冲突），新页面 `pages/ollama_compare_page.dart` 左右两栏：**左栏书籍浏览**——项目下拉 + 页码 chips（点击浏览、勾选框控制批量范围、全选/清空快捷键）+ 主区/段落/行/单字四级视图切换（SegmentedButton，与编辑器同语义，画布 InteractiveViewer 平移缩放 + CustomPaint 画当前层级框、点击点选、选中红高亮、行/段/主区带编号），底部选中信息条显示行字数/文本预览/单字 conf 与确认状态；选中主区/段落时批量范围自动收窄为该范围内的行。**右栏对比面板**——① 模型多选卡（/api/tags 已安装模型 checkbox，默认勾选当前视觉+文本模型，标注"当前视觉/当前文本"角色，提示纯文本模型跑视觉任务=验证整行裁决兜底路径）；② 任务卡（四任务 checkbox + 「对比选中对象」/「批量：N 页」按钮 + 进度条 + 取消）；③ 单对象结果区（每任务一节：展示发给模型的字图/行条图/橙框诊断图——即管线 ①②③ 的产物，每模型一行显示解析结果 + 命中徽章（✓第N/差异%/问题数）+ 耗时，可展开暗色 monospace 面板看完整 prompt 与模型原始返回）；④ 批量统计区（每任务排名卡：候选类 top1/top3 命中率、整行可采纳率+平均差异率、诊断完成率+line_ok 率，⭐标注第一名，逐条明细可展开）；⑤ 管线协作卡（五阶段流程图：① 页面预处理 OpenCV/PyMuPDF → ② 版面与字框检测 自训 YOLO char_det+OpenCV 投影兜底 → ③ 文字识别 Kraken CHAT 双路融合 → ④ AI 辅助 Ollama（紫色高亮"本页对比在这里发生"）→ ⑤ 人工校对编辑器，每卡引擎徽章配色；附「生成整页切分调试图」按钮（既有 /segment?debug=true，确认后重跑分割，展示绿行框/蓝字框叠加图与二值化 mask 图）+ 内嵌后端控制台面板看实时 [diag:yolo]/[line-rec] 日志）。**新文件 `services/ollama_compare.dart`**：四任务枚举（前三个走视觉槽、标点走文本槽，A/B 用 settings.copyWith 注入被测模型）；上下文组装纯函数与编辑器/整行裁决路径同口径（行内 ±12 字窗口、标点样判定=文本为标点或跨度<中位×0.65、整行 current 归一化+邻行 ±32 字）；批量抽样（整行裁决全量行；单字辅助抽 conf<0.80 低置信字 ≤12/页——AI 辅助的目标场景；标点抽标点样字 ≤12/页；框诊断均匀铺开抽行 ≤8/页）；指标（自实现 levenshtein、字符差异率、top1/top3 命中排名、eligible 率、line_ok 率、问题类型分布）；运行器仿 AiBoxReviewer 的 lambda 注入模式（裁图可 fake、单测不依赖真实服务），**外层循环按模型分组**（同模型连续跑，减少 Ollama 反复换载），每次调用间检查取消标志、结果增量回传；聚合排名按任务主指标（候选类 top3 命中、整行 eligible 率、诊断完成率）降序、同分按平均耗时。**`services/ollama_service.dart` 增量**：新 `OllamaTrace` 类（实际使用模型（含整行裁决 vision→text 回退后的真名）/完整 prompt/附带图像/原始返回/耗时），四个辅助函数加可选 `trace` 参数——prompt 在请求前填（失败也能看到发了什么）、rawContent 在 _chat 成功后填，现有调用方零改动。**基准口径**：单字/标点/整行的命中与差异均以行内当前文本（OCR+人工校对现状）为基准，人工确认过的样本单独打 ✓，页面明示"命中/一致不代表绝对正确"。项目下拉用 ValueKey 修复异步加载后 initialValue 不刷新的 Flutter 已知行为。新增 19 条单测（12 字窗口截断与边界、标点样三口径、整行 current 归一化/±32 截断/before 顺序、低置信与标点抽样、诊断行均匀抽样含首尾、levenshtein/差异率/命中排名、聚合排名三任务口径、运行器注入 fake + 不可达端口离线复现错误路径、批量跨模型串行顺序与取消立即生效），全部通过；flutter analyze 无告警；Dart 全量 229 条通过（tool_export_crowd_tasks 既有环境性失败）。

## 1.0.0+37

- **AI 辅助设置的模型括号说明改为与模型在软件中的实际分工一致**。「模型选择」卡与「模型安装」推荐区的两组标签，原来写的是"视觉模型（单字图像辅助识别）/ 文本模型（标点上下文辅助）"，只覆盖了早期功能——视觉模型实际还承担整行裁决（全本识别/本页本行重识别时优先用它看字图）和「AI 检查识别框」的视觉诊断，只写"单字图像辅助识别"会让人以为框检查、整本识别 AI 与它无关。改为：视觉模型（单字辅助识别 · 整行裁决 · 识别框诊断）、文本模型（标点辅助识别 · 整行裁决兜底），与「功能开关」卡的开关名一一对应，"整行裁决兜底"也如实说明未配视觉模型时整行裁决会回退到文本模型（`decideLineText` 现行为）。视觉模型下拉的示例名同步对齐推荐目录（qwen3.5-vl → qwen3.5、qwen3-vl、minicpm-v，llava 不在目录中移除）；`OllamaSettings.visionModel/textModel` 字段注释与页面类注释同步改写，顺带修正"空 = 自动取第一个可用模型"的过时说法（实际是相关功能提示先去「AI 辅助设置」选择，安装模型后仅自动补上刚装的模型）。纯文案与注释修改，无逻辑改动；flutter analyze 无新增告警。

## 1.0.0+36

- **AI 辅助设置新增「抢回端口」：一键修复"Ollama 明明在运行却总提示无法连接"的 Windows 保留端口问题**（用户实测：Ollama 托盘正常、应用报"无法连接 …errno = 1225 远程计算机拒绝网络连接"，`server.log` 刷屏 `bind: An attempt was made to access a socket in a way forbidden by its access permissions`）。根因：Hyper-V/WSL 的 winnat 服务每次开机随机保留一批 TCP 端口段（`netsh interface ipv4 show excludedportrange protocol=tcp` 可查），本次开机保留段 11335–11434 恰好整段盖住 Ollama 默认端口 11434，服务端 bind 被系统直接拒绝——托盘反复拉起服务端也绑不上，端口上无人监听，客户端连接自然被拒；重启 Ollama 无效，且保留段随开机随机、换机器换端口都可能复发。修复：① 新文件 `services/ollama_port_reclaim.dart`——端口体检（`ServerSocket` 试绑 127.0.0.1:端口，判可绑定与失败错误码：10013=被系统保留/10048=被占用）+ 解析 netsh 保留区间输出（识别 * 管理员登记段）；一键抢回走提权 PowerShell（复用项目 `-EncodedCommand` base64 UTF-16LE 模式，`Start-Process -Verb RunAs -Wait` 弹 UAC），管理员执行 `net stop winnat` → `netsh int ipv4 add excludedportrange protocol=tcp startport=<端口> numberofports=1`（登记为应用保留，此后每次开机 winnat 都不再抢占该端口）→ `net start winnat`；提权窗口拿不到 stdout，命令输出重定向临时日志文件执行完读回展示，按日志尾 done 哨兵判完成，UAC 取消/未跑完给明确提示。② 新文件 `widgets/ollama_port_reclaim_panel.dart`——服务连接卡内新增面板（仅 Windows、仅连接失败时出现）：体检三态文案（可绑定=问题在 Ollama 本身 / 被系统保留并显示端口段=可抢回 / 被占用=查占用程序），「抢回端口」按钮 + 确认对话框（说明 winnat 短暂重启、Docker/WSL 网络瞬断几秒），执行日志面板（深色终端风、可复制、可重新检测）；抢回成功后自动等 3 秒并重试「测试连接」最多 3 轮（Ollama 检测到端口释放会自动重绑），连上即恢复绿色连接状态。③ 帮助卡补充该症状与入口说明。新增 12 条单测（端口提取含无协议/无端口/空地址、netsh 中文输出解析含 * 段与区间边界、体检三态分类与应用保留免重复抢回），全部通过；flutter analyze 无新增告警；Dart 全量 210 条通过（tool_export_crowd_tasks 既有环境性失败）。

- **修复：单字识别/行重识别出现"识别框重叠、一个字叠十几个碎框"（用户实测禄字叠 18 层）**。根因是两层叠加：① `expand_line_rect_to_neighbor_ink`（行框沿阅读轴扩到墨迹）用"任一像素即墨迹"判定，扫描纸面的尘点（每行 1~6px 散点，实测空白区 96% 的"墨迹行"只有 1~8px）不断重置空白计数，把 11 字的行框（高 1009px）一路拉到整页高（2132px）；② 下游 `_split_giant_box_by_runs`（巨框按白隙逐段拆）按"长度≥4 或 墨迹≥6px"留段，空白大框里的尘点段全部成框——实测一块空白拆出 25 个碎条框（6~12px 宽），Kraken 又把空白读成一串「·」，全部碎框叠在同一位置，编辑器字卡列按几何定位渲染成层叠卡片。修复：① 扩行的墨迹判定改为按行墨迹量设灰尘下限——以行内墨迹行的中位数为基准取 20%（钳在 5..10px），尘点行不再算墨迹，扩行在空白处被 gap_limit 自然截停（实测该行扩后停在 1014px，恰为真实墨迹末端）；② 巨框拆分按"最强段平均每行墨迹的 1/4（下限 6px）"剔除尘点段，实测 25 段 → 1 段真实墨迹；全部段都是尘点量级时整框不拆（原框保留，交给下游墨迹校验兜底）。真页回放验证：同一行框（府相同來會命宮全家食祿）修复前 28 框（含 ~16 个空白碎框），修复后 11 框全部为真实字、正文完整正确。`BACKEND_BUILD` v92→v93（Dart 同步，旧后端自动重启）。新增 Python 测试 3 条（尘点链不拉行框、巨框尘点段不成框、纯尘点巨框不拆）；分割相关 97 条通过，其余仅 test_seg_layout/test_layout_analysis 各 1 条既有基线失败（与本次无关，见今日基线日志）。

## 1.0.0+35

- **改进：训练数据全局共享——主区/段落/单行/单字检测、单字候选分类、单字识别（Kraken）、墨迹比对的数据集不再按书隔离**（用户反馈：这些训练数据本应是整个软件通用的，而不是单独某本书使用的，数据应该在哪个书籍项目中都能看到）。此前唯一的全局化不对称：模型产物（`models/trained/`）、注册表（`registry.json`）、激活模型（`active_*.pt`）都是全局的，但数据集按 `datasets/<书籍ID>/<层>/` 分书存放——A 书训练积累的样本，切到 B 书训练页看不到也用不上；书删了数据集变孤儿（实测 `datasets/1788535005532` 的书已不在书库里）；重命名书目录即"丢失"归属。改为**全局合并式数据集**：① 所有书籍的样本合并写入 `datasets/_global/<层>/`，样本文件名带 `<书籍ID>_` 前缀区分归属；对某本书重新生成只清除并重写该书前缀的文件，其他书的贡献原样保留（char_cls 的 classes.txt/metadata 按书分文件后汇总，verify_pair 的 manifest 按书数据块 `_books/<书籍ID>.json` 合并重建）。② 统计与取数始终聚合整个书库（`/train/stats` 传单本书 = 传库根，看到同一份累计数据与准备进度）；训练启动的数据集缺失时按全库自动生成。③ 旧按书数据集在首次访问统计/生成时自动迁移进全局目录（文件加前缀拷贝，data.yaml/classes.txt/manifest 重建），原目录移入 `datasets/_legacy/` 保留备份不删除；孤儿数据集（书已删）同样并入，其样本继续可用。④ Kraken 确认行导出目录全局化（`kraken_training/datasets/_global/`）；顺带修复 `/kraken/export` 把单个路径字符串当书籍目录列表迭代（按字符拆路径，永远报"确认行太少"）的死 bug，现按全库书籍导出。⑤ 训练页文案改为全局累计口径（"训练数据全局共享 · 全部书籍累计 N 页标注"，来源下拉改为"提取来源"只决定重新生成哪些书）。⑥ **编辑器右侧"训练数据"进度卡改为全局累计口径**（用户实测反馈："第五册单行训练数据 170，其他书显示 0"——该面板此前显示的是**本书本地实时计数**，与数据集全局化无关的另一处按书口径）：进度条与档位数字（实例/目标、字类）改用 `/train/stats` readiness 里后端聚合的全书库累计数，任何书里看到的数量一致；标题下新增"全部书籍累计 N · 本书 M"说明行（本地计数保留即时反馈，确认后立即变化）；「确认并保存」后同步刷新全局计数；训练服务未连接时明确标注"本书 N（训练服务未连接）"走本地兜底。train/val 划分仍按页 8:2 且页不跨集（每本书独立确定性划分后并入全局）；val 为空的兜底改为看全局目录（多书合并后通常已有 val 样本，比旧版按书挪页少动数据）。`BACKEND_BUILD` v91→v92（Dart 同步）。新增 Python 测试 5 条（单本书/另一本书/库根三种入口统计与数据集路径完全一致、两书生成合并且重新生成一书不动另一书、dataset_dir 全局同路径并按全库自动生成、旧按书数据集迁移含幂等、verify_pair 两书导出合并 manifest 且重导一书不动他书）；训练/比对/分割相关 110 条通过（test_seg_layout 与 test_layout_analysis 各 1 条失败为今日基线既有，与本次无关）；Dart 全量 198 条通过（tool_export_crowd_tasks 既有环境性失败）；flutter analyze 无新增告警。注意：安装版应用运行的是**安装包内自带**的 python_service 副本（应用按 exe 祖先链查找 python_service 目录），需重新打包安装（installer/ocr_setup.iss 会把新后端打进包）后全局化才在安装版生效；开发运行（flutter run）直接用源码目录的后端。

## 1.0.0+34

- **修复：AI 检查识别框对"空白竖行/幽灵框"完全失明——新增墨迹实测判空（/line_ink）+ 空框直接删除**（用户实测反馈三："第三第四竖行上没有任何文字，还互相重叠，这都没检查出来吗？"）。用用户实际页面（page_076 → split_page_345.png）定位根因：那些空框是**检测器把版心空白带/界格带误检成的行**，框上"读到的字"全是邻列渗墨的识别噪声——几何规则被噪声字骗过（字数/行长比正常）、视觉模型看单行裁图判断不可靠（实测对空白条说"没问题"）、重摆则原样复检，三档全放行。且旧扫描对 `chars.isEmpty` 的行**整行跳过**。修复分三层：① **后端新增 `POST /line_ink`**：批量行墨迹测量——逐字框**核心区**（内缩 15%，避开邻列渗入的边缘笔画）做**结构性墨迹**统计（Otsu 二值化后按连通域剔除界格/版框长线[绝对细 ≤10px，相对细度在高瘦行级裁剪里会把文字块误判成横线——实测教训]与 <40px² 噪点，只留笔画），返回每行墨迹中位数与空字数；Otsu 在纯色图上退化为 0 阈值的坑（实心墨字/印章被测成零墨迹）用固定阈值兜底。**实测校准：真文字行墨迹中位 0.23~0.47，空白带幽灵行 ≈0.000**，判空阈值 0.08 留足余量；用户页面 17 条真实行零误报。② **扫描接入墨迹**（`scanSuspects` 增 `inkByLineId` 参数，编辑器扫描前一次批量测量）：墨迹判空的行 → 新可疑类型"空框"，**修复动作 = 直接删除**（纯前端，不调后端不调视觉模型）；幽灵行不再作为邻行的重叠伴生（删除即消除重叠，邻行无需触发注定"维持原切分"的重跑）；`chars.isEmpty` 的行仅在墨迹佐证下才报（防误删待识别行）；**过半字框无墨迹**（≥50%）→ 几何重摆且期望字数按非空字数下推、内容守恒下限同步下推（`shouldAdopt` 增 `minNewCount`——诚实修复会删掉空白字框，默认"新字数 ≥ 旧一半"的闸会拒掉它）；测量失败/退化数据一律退回纯几何规则，绝不据坏数据删行。③ **单行入口墨迹预检 + 撤销修复**：行卡片「AI 检查本行」先测墨迹，空框直接删不再让 VLM 判；报告"撤销全部修改"对删除型修复按行号序插回原行（此前 newLines 为空时找不到插入点会静默跳过——被删的行撤销不回来）；伴生行被先行处理时记 stale"重叠/重复的对方行已被处理"而非空跑；删除后页面行列表为空时选中行置 null（防 clamp 越界）。`BACKEND_BUILD` v85→v86（Dart 同步，应用重启自动替换旧后端）。新增测试：Dart 9 条（空框判空/无字块行两态/manual 空框保护/幽灵不作为重叠伴生/过半空白期望字数与内容下限/未过半不报/退化测量不误报/blankInk 删除不调后端/内容下推后诚实修复可采纳）+ Python 5 条（真行高墨迹 vs 空白行≈0/界格线被剔除/无 chars 按行框测/坏图 ok=false 不中断/空列表）；ai 相关 60 条、Dart 全量 192 条（tool_export_crowd_tasks 既有环境性失败）、Python 238 条（test_page_dewarp 缺 pytest 既有）全部通过；flutter analyze 无新增告警。

- **修复：AI 检查识别框"修复 12 但画面毫无变化"——原样复检被当修复 + 同列重复行重摆救不了**（用户实测反馈二）。用实际数据（page_076 修复前后 JSON 逐行对比 + 应用日志）定位两个问题：① 后端 `/segment_region` 在几乎相同输入上重跑同一条切分链路，12 个"修复"里 11 个返回**与原框完全相同的几何/字数/文本**（唯一变化一行 x 坐标 22px）——裁决按"质量分不暴跌"放行，报告记为"修复"，但画面当然没变；② 该页真正的重叠对是**同列重复检测**（行2/行3：两条 19px 窄条各 190 字互相重叠 74%；行16/17：两条框各 23 字盖同一列）——同一条文字列被检测器输出成两条行，并集重摆只会让后端再检出同样的框，永远修不掉。三处修复：① **实质变化检查**：重摆结果与原行"实质相同"（行数一致、矩形差 ≤2px、字数与整行文本一致）→ 如实报告"重摆复检结果与原框相同（后端维持原切分），保持原样"，不再计入修复数；② **同列重复检测与删除动作**：重叠对交/较小方面积 ≥0.5 且字数相同（±1）或文本一致 → 判定为重复行，修复动作 = **删除质量分较差的一条**（纯前端操作不调后端，保留好的一条），伴生行一并移除；③ 报告的修复数与实际合回数对齐（原 fixed 计数取自结果状态，apply 失败时会出现"报告说修了但没合回"的口径不一）。新增 4 条单测（重复检测触发/低重叠不算重复、删除动作不调后端且保留优者、原样复检记 kept），ai 相关 51 条测试全过、flutter analyze 无新增告警。另注：排查中发现用户机器上有 2026-09-25 的旧版应用实例与新应用同时打开同一项目（旧实例随后把旧内存态写回 page_043/037），多实例并发写同一标注目录会互相覆盖，建议只保留一个实例运行。

- **修复：AI 检查识别框"修复 0"——裁决闸门过严把所有几何修复拒掉 + 退化结果无人拦**（用户实测反馈：页面上重叠框/一列拆两行/框没包住字全都没修，报告说没问题）。用实际标注数据核查：扫描正常（该页报出 20 个可疑行，A 档重摆也都执行了），卡死在裁决——① "两路分歧率不得劣化"硬闸误伤：重摆后的诚实重读常带更多 conflict/box_multi 标记，即使整体更好也被拒（应用日志 `[AI框检查] 可疑 20 行：修复 0` 实锤）；② 后端偶发退化结果（`segment_region ok lines=1 chars=1`，20 字的行重摆回来只剩 1 个字）原合理性检查拦不住。三处修复：① **裁决按档位区分**——A 档（几何修复）的收益是几何本身（重叠消除/字数恢复），质量分只要不暴跌（> 旧分 −0.05）即采纳；B 档（VLM 诊断重摆）保持净提升门槛（+0.03）；删除分歧硬闸（其惩罚已计入 lineScore，单设硬闸只会双重惩罚诚实重读）。② **内容守恒闸**（两档共用）：新字数 ≥ 旧字数一半且 ≤ 旧字数×2+4，挡住"1 个字吞掉整行"与过度粉碎。③ **窄行扫描规则**：行厚（竖排行宽）< 0.65×页面中位行厚（页面 ≥4 行才判定，防中位数不稳）→ B 档可疑"行宽异常窄（疑一列被拆两行）"，交视觉模型看图确认是否并回——刻意不自动并：古籍夹注本来就是窄列，VLM 有上下文才能区分"拆错了"与"真双列"（用户标注实测多页存在 22~74px 的真窄行）。配套：检查期间行被其他修复替换不再静默消失（新增 stale 状态入报告"已更新跳过"，原重叠伴生行被修复后其自身条目直接消失会显得"少查了"）；诊断裁图 maxSide 640→768（更长行更可读）；诊断 prompt 增加"三类明显问题必须报告"（字大半露框外/行框只盖半列/一框两个完整字形），避免 VLM 因"能读出字"放过明显结构问题。新增/改写 6 条单测（分歧恶化仍采纳/一字吞行拒绝/过度粉碎拒绝/A 档容差边界/窄行规则触发/少行页面不判窄），ai 相关 48 条测试全过、flutter analyze 无新增告警。

- **修复：AI 诊断遇 Ollama 推理进程崩溃（500 wsarecv）只报原始错误**（用户反馈：AI 检查本行时报 `Ollama 返回 500: an error was encountered while running the model: ... wsarecv: An existing connection was forcibly closed`）。该错误是 Ollama 的模型 runner 子进程在推理中途中断（Windows 上典型于显存/内存不足被杀、显卡驱动超时重置，个别模型触发 flash attention 崩溃），多为偶发且 Ollama 会在下次请求自动重启 runner。两层改进：① `_chat` 收到该签名（500 + running the model / forcibly closed / wsarecv）先**等 2 秒自动重试一次**再判失败（单字辅助/标点辅助/框检查诊断全部受益）；② 重试仍失败时把原始 500 翻译成可操作提示——"模型推理中断，常见原因：显存/内存不足、显卡驱动重置；建议换更小的视觉模型（AI 辅助设置 → 模型安装）/重启 Ollama/更新驱动"，附原始错误片段。签名判定函数 `isRunnerCrashForTest` 开测试口，新增 2 条单测（签名识别 + 普通 500/404/200 不误判），ollama 相关 18 条测试全过、flutter analyze 无新增告警。

- **AI 辅助识别框检查：两档修复（几何直修 + 视觉模型诊断）→ 后端重摆 → 置信度裁决**（用户需求："让 AI 检查识别框放的准不准，给出可行方案（该拆两行/单字多识别了一部分等），自动返回给识别模型重新摆放，提高准确率"）。此前修识别框只能靠人眼逐行排查或整页重跑；现在闭环自动化：**可疑扫描（本地免费）→ 按可疑类型分档修复 → 复用后端既有算子推倒重摆 → 前后识别置信度裁决（提升才采纳，不应用即回滚）→ 报告（可整体撤销）**。① **可疑扫描**（新文件 `services/ai_box_review.dart`，纯函数）分两档：**A 档几何**（行框重叠/异常高字框[行中位×1.18+5px，与后端标点拆分同口径]/字数与行长比超 [0.7,1.35]）可直接修、不依赖 Ollama；**B 档语义**（存在 conf<0.55 的字/conflict·box_multi·none 占比>30%/墨迹校验 mismatch·suspect）需视觉模型诊断。**保护行一律跳过**（manual 行、字框全 boxConfirmed 的行、含任何已确认字的行——重摆会重置确认状态，绝不洗掉用户成果）；重叠伴生行只取非保护行做并集重跑。② **VLM 诊断**（`OllamaService.diagnoseLineBox`）：新后端端点 `POST /line_thumbnails` 按行框裁图（上下文外扩 15% 钳回图内、**保持纵横比**、长边缩到 ≤768，可选叠加当前字框橙框+1 基序号——VLM 直观看到框与字形的偏差），连同逐字信息（序号/字/conf/相对尺寸）交视觉模型，**只从固定菜单选问题类型不出坐标**：merge_two_lines（并排双列应拆行）/char_merged（一框两字）/char_clipped（切边）/char_extra_ink（多包墨迹）/missing_chars（漏字）；type 白名单校验、pos 钳到 [1,N]、围栏/废话容错解析（`parseDiagnosisForTest` 开测试口）。③ **重摆执行**：全部复用既有算子——`/segment_region` 不带 charBoxes 的推倒重摆链路（行级双列拆分阈值本就比整页宽 1.2×，重叠行取两行并集矩形重跑）；新增可选参数 `expected_char_count` 透传到像素切分器做数量校验（几何推算 = 行长÷中位字高或现字数+高框数；VLM 推算按 issue 类型映射：两字同框/漏字 → +1，切边/多包 → 保持现字数），Kraken 序列漏读/粘读时切分器有了可信目标；带 char_boxes 时参数忽略（保框重填不受影响）。`BACKEND_BUILD` v83→v84，Dart `_expectedBackendBuild` 同步。④ **裁决**（防"更整齐但更错"）：`lineScore` = mean conf − 0.15×分歧率 − 0.10×低分率 − 0.10×高框率 + 0.10×两路一致率；采纳需同时满足 分数提升 >0.03、`sanityOk`（每行有字/结果内行框不重叠/字数不超物理上限）、**两路分歧率不劣化**（缓解同引擎自评自修的虚高）。⑤ **编辑器集成**：顶栏「AI 检查识别框」按钮（确认对话框列可疑行数量与档位 → 逐行执行，顶部紫色横幅显示进度可取消剩余；单次 VLM 诊断上限 12 行防失控，超出列跳过；与整本识别队列互斥，检查期间级联重识别任务拒绝入队）；行卡片「AI 检查本行」按钮（显式单行诊断，保护行先弹警告）；报告对话框逐行列明 修复/保持（含前后分）/无问题/失败/受保护/跳过，**「撤销全部修改」**一键还原（持有旧行快照）；被修行卡片标「AI」徽章（运行期，不落盘）；修复行走既有原位替换合回（reid + proposed 状态 + 保留段落归属，1→N 行拆分支持），不标 manual（用户照常确认后自然进训练集——AI 调整→人工确认→训练反哺闭环）。⑥ **设置**：AI 辅助设置功能开关卡新增「识别框检查」（默认关，`enable_box_assist` 向后兼容；副文案注明几何修复无需 Ollama、AI 诊断需视觉模型）。新增 40 条测试（Dart 32：`test/ai_box_review_test.dart` 27 条——扫描规则/保护行跳过/并集伴生/质量分/合理性/裁决边界[margin/分歧闸/退化结果]/A 档期望字数透传/B 档 VLM 映射与不可用降级，`ollama_service_test.dart` 增 5 条诊断解析；Python 8：`test_line_thumbnails.py`——纵横比/max_side 缩放/pad 钳制/框叠加改变输出/坏项 None 不中断/超量 400/expected_char_count 透传[带/不带 char_boxes]），全部通过；flutter analyze 无新增告警，Dart 全量 173 条通过（tool_export_crowd_tasks 既有环境性失败），Python 全量 232 条中 231 过（test_page_dewarp 缺 pytest 为既有环境性失败）。

## 1.0.0+33

- **AI 辅助设置新增「模型安装」卡：硬件感知的模型推荐 + 界面内一键拉取 Ollama 模型**（用户需求）。此前装模型只能去命令行敲 `ollama pull`，且不知道哪档模型适合自己的机器；现在设置页内即可完成选型与安装。① **硬件探测**（新文件 `services/hardware_info.dart`）：`nvidia-smi --query-gpu=name,memory.total` 取显卡名与显存（多卡取显存最大的一张，超时/失败视为无 N 卡按 CPU 推理评估），内存走 PowerShell `Get-CimInstance Win32_ComputerSystem`（失败回退 wmic，新版 Win11 已移除 wmic），核数取 `Platform.numberOfProcessors`；结果进程级缓存，卡片标题右侧显示摘要（如 "NVIDIA GeForce RTX 4070 · 12 GB 显存 · 32 GB 内存"）并可手动重测。② **推荐目录**（新文件 `services/ollama_model_catalog.dart`，体积为 2026-09 实测 ollama.com 默认量化档）：视觉组 minicpm-v4.6:1b（1.6GB，CPU 兜底）/ glm-ocr:latest（2.2GB，OCR 专用）/ qwen3-vl:2b（1.9GB）/ qwen3.5:4b（3.4GB）/ qwen3-vl:4b（3.3GB）/ qwen3.5:9b（6.6GB，12GB+ 显存质量首选）/ qwen3.5:27b（17GB，24GB+ 显存），文本组 qwen3:1.7b/4b/8b（1.4/2.5/5.2GB）。推荐逻辑纯函数：显存需求 ≈ 体积 + 1.5GB 运行开销，显存 ≥ 需求×1.15 → 流畅、≥ 需求 → 可用、≥ 0.8×需求 → 吃紧；无独显或显存带不动时按 CPU 兜底（体积 ≤3.5GB 且内存 ≥ 体积×2.5+2 → "CPU 可跑"，否则"超出配置 · 不推荐"）。列表先视觉后文本、同组适配好的在前，每组最优打 ⭐，卡片顶部横幅给出"根据本机配置推荐"；已安装模型（按 base 名匹配，兼容 :latest 别名）显示绿色 ✓，按钮变「重新拉取」用于更新。③ **一键拉取**：走 Ollama HTTP `POST /api/pull` 流式接口（`OllamaService.pullModel` + `OllamaPullProgress` 聚合器——各模型层的 completed 按 digest 分别记最大值再求和，多层下载进度不回跳），行内进度条显示百分比/已下载/总量/速度（0.8s 采样指数平滑），可随时取消（关闭连接即中止，已下载层保留为缓存下次续传）；进度与状态行同步写入卡片底部可折叠的深色终端风日志区（每秒节流防刷屏，可一键复制）。自定义安装输入框接受纯模型名（如 `qwen3.5:4b`）或直接粘贴完整 `ollama pull xxx` 命令（正则抠名 + 字符白名单校验），远程仓库路径（hf.co/...）合法。同一时间只允许一个拉取任务，其余安装按钮禁用。安装成功自动刷新模型列表，若视觉/文本槽位为空则自动选上刚装的模型（装完即用）。④ **一键安装 Ollama**（连接失败时出现在服务连接卡内）：`SetupService.installOllamaApp` 仿现有 PowerShell 安装器模式跑 `winget install --id Ollama.Ollama -e --silent`（base64 -EncodedCommand，winget 输出经 ForEach-Object 转发），失败（winget 不存在 exit 2 等）提示手动下载并给「打开下载页」按钮（explorer.exe 拉起默认浏览器）。⑤ 帮助卡与「模型列表为空」提示文案同步改为引导页内安装。新增 14 条单测（各硬件档位推荐/排序、模型名解析、NDJSON 聚合不回跳/错误行/超量夹取），flutter analyze 无新增告警（仅剩 debug_page 既有 info 与 tool_export_crowd_tasks 既有环境性失败）。

- **「模型安装」卡补充：推荐目录标注发布时间 + 已安装模型一键删除**（用户需求）。① **发布时间**：目录条目新增发布月份字段（YYYY-MM，按官方发布/ollama.com 模型库收录时间，月份粒度）——qwen3 系 2025-04、qwen3-vl 系 2025-10、glm-ocr 2026-02、qwen3.5 系 2026-02、minicpm-v4.6 2026-06；推荐行副标题改为 "说明 · 2026-02 发布 · 约 6.6 GB"，选型时可直接参考新旧。② **删除已安装模型**：`OllamaService.listModels` 升级为返回 `OllamaInstalledModel`（name + sizeBytes + modifiedAt，/api/tags 全量字段，设置页下拉与已安装徽章改从 names 派生），新增 `deleteModel`（DELETE /api/delete，等价 ollama rm，非 200 转可读异常）；安装卡在拉取状态与日志区之间新增「已安装模型（N）」区——每行显示模型名、磁盘占用（如 "磁盘占用 6.55 GB · 2026-05-12 更新"）与红色删除按钮，删除走确认对话框（列明释放体积；若该模型正被选为视觉/文本模型，提示"删除后会自动清空该选择"，成功后确实清空对应槽位并 SnackBar 报告释放量），删除后自动刷新列表；`_deletingModel` 单飞防并发（删除中所有删除按钮禁用），该模型正在拉取时同样禁删。新增 1 条目录发布月份守门测试（YYYY-MM 格式 + 年份/月份取值范围），ollama 相关 24 条测试全过、flutter analyze 无新增告警。

- **修复：拉取进度/日志离开设置页即丢失（下载被连带中止）+ 应用重启后支持续传**（用户反馈）。原实现把拉取任务的状态与 HTTP client 全部挂在设置页 State 上，页面一退出 dispose 就关闭连接——不只是看不到进度，下载本身也被中止了。重构为**全局单例 `OllamaPullManager`**（`services/ollama_pull_manager.dart`，ChangeNotifier，仿 RecognitionQueue 的全局进度广播模式）：进度聚合、速度采样、日志缓冲（400 行环形）、阶段状态机（idle/pulling/interrupted/succeeded/failed/cancelled）全部收敛到管理器，页面只订阅渲染（addListener → setState），**离开设置页下载继续，返回即见进度与日志**；dispose 只解除订阅、绝不碰 client。**续传**分两层：① 同次运行内下载中断（网络断开抛 OllamaException/ClientException）自动落 `failed` 态，设置页出现红色横幅「X 安装失败：…」带【重试】【忽略】；② 任务开始时把 {model, base_url} 写入 SharedPreferences（key `ollama_active_pull_v1`，成功/用户取消时清除、失败保留），应用重启后 `restore()` 把记录恢复为 `interrupted` 态，设置页显示橙色横幅「上次下载 X 未完成」，点【继续下载】重新发起 /api/pull——Ollama 服务端对已完成的层与半截 blob 原生断点续传，进度条会直接跳到已下载位置继续。失败重试与重启续传共用同一条横幅；【忽略】清记录清日志（`dismiss`）。拉取流执行入口留 `pullRunner` 静态注入点供测试替换。新增 6 条管理器单测（成功清除记录/失败保留记录/restore 恢复与幂等/dismiss 清理/空任务 cancel 空操作/拉取中状态与持久化时序），ollama 相关 30 条测试全过、flutter analyze 无新增告警。

## 1.0.0+32

- **修复单行识别把普通文字列拆成两行（连续墨迹被切穿）**：根因是切穿单个左右结构字的部件缝——两条相邻字的部件缝对齐后，"部件缝+部件碎片"在几何上与"两行小注"同构，放宽档（短注拆分）在现代排版书上整列误拆（page_059 实测 28 种画框触发）。按"宁可漏拆、不可误拆"收口三处：① **段长下限**：放宽档 1.2×→**2.5×字距**（两行小注实测 2.9× 仍拆；假缝段实测仅 1.0~1.6×；更短的假段与真短注几何不可分，漏拆可由行内重切/手画两框补救）；② **缝宽下限** 0.07×→0.09×字距且地板 2→3px（真注两列分开排实测 0.10~0.14×；部件缝是发丝级 2~3px，int 截断曾让 2px 缝过关，改 round）；③ **两侧子列各需 ≥2 个整字级字块**（高 ≥0.45×上段字距；假缝两侧是同一字的部件碎片 9~17px，真注两侧是完整小字）。头部字高基准改**字距**（相邻字带起点中位差；最高/中位字带被竖向粘连膨胀 2~3 倍，现代列连续墨迹下把"夹注字小于正文"判据打穿）。验证：page_059 全部 28 种触发框归零、木刻书/命理书扫样 421 行仅命盘页 1 处（同构结构）、两处真注夹具 4/4 保持、237 条测试全过；端到端实测原触发框全部返回 1 行且文字正确、木刻媼短注仍按先右后左拆 4 行。

- **修复"整行读法正确、正文却整行乱码"的融合误判**：字框来自不可信来源（kraken cuts 条带框/网格兜底槽位框，与真实字形可整体错半格）且两路读法低吻合时，旧策略判"疑似序列错位→正文取逐框读法"——但 cuts 框的逐框读法读的恰是错位切片（实测木刻大字列 seq='夾月夾日誰能遇夾昌夾曲立貴兮'完全正确、crop='夾夾災㤙日能遇…'整行乱码，旧策略正文采用乱码）。两层修复：① `line_alignment_primary` 新增 `boxes_trusted`——不可信框上低吻合的分歧更可能源于框错位，信整行序列；② `_fuse_line_chars` 在不可信框 + 框数=序列字数时**按位置配对**（cuts 框按序列切位构造，框 i ↔ 序列字 i 是构造性对应；文字对齐在逐框乱码时配不上位，落空位回退乱码 crop，产出"前半乱码后半正确"的混搭）。像素切分/用户手画框（与字形锚定）不受影响。同环境 A/B 实测：大字列 乱码→完全正确，另 3 行改善、2 行小退；237 条测试全过。build 号 v84→v85（并行改动后需重启后端拿全量修复）。

- **行/段/主区包含关系按"扩容器"修复（不裁内容框）+ 澄清大字拆分来源**：① 新增 `PageAnnotation.ensureHierarchyContainment`（**只扩不缩**）——段落框扩到包含其成员行、主区框扩到包含各段落（按 mainRegionId 归属，缺省取相交主区），行框几何永不被裁；编辑器载入标注时先做包含修复再钳图片范围，行重识别/推倒重切替换行后同步扩容器。此前识别重建行后段落/主区还是旧几何，行伸出段外、段伸出主区外（用户所见）。② 关于"大字连续墨迹被拆成两行"：当前代码在两页大字列上实测 21 种画框（整列/半列/跨列/偏移/不同高宽）全部返回 1 行——该拆分来自仍在运行的旧 v81 后端（载着第一版检测器），v82 build 号使应用下次启动自动替换。

- **画布上识别框不得画出/拖出页面图片**：画布手势全线钳回图片范围——① 画新框（区/段/行/字）松手时矩形钳回图片；② 拖拽预览的指针位置钳在图片内（实时反馈不越界）；③ 区/段/行/字的**移动**按原宽高钳左上角（框比图片还宽时钳到 0）；④ 四个**缩放**分支的缩放结果钳回图片范围。此前只有左上角 max(0,·) 保护，右/下方向可以随意拖出页面（配合上条的载入钳制与后端出口钳制，形成三层完整保证）。另：`ollama_pull_manager` 补缺失的 `dart:collection` 导入（另一工作线的半成品导致 flutter test 编译失败）。

- **框叠加一眼可见 + 底部编号条快速选框**（用户需求）：① **同层框重叠区域红色高亮**——主区/段落/行三个视图里，同层识别框两两求交（O(n²)，每页框数量级代价可忽略），相交 ≥1px 的重叠区域画醒目红色半透明填充（0.38），叠加块直接盖在书页上，切分错误或手工拖拽越界一眼可辨；贴边相接（零交集）不算叠加，画布 showIndex 的编号与框颜色语义不变。已用渲染预览验证：两个交叠行框的公共区域呈红色竖带，独立框不受影响。② **翻页栏上方新增识别框编号条**——按当前视图层级列出本页全部框的编号按钮（与画布 showIndex 标注同序同号：正文区视图列主区、段落视图列段落、行框视图列行；单字视图与后台控制台不显示，本页该层无框也不显示）。点编号即选中该框（其余层级选中清空，当前选中编号橙色高亮），并把画布**按当前缩放平移到该框中心**（`_AnnotationCanvas` 新增 `focusRect/focusSeq` 定位参数，build 内按视口中心换算平移，不改缩放比例、不与"翻页保留缩放"冲突；同框重复点击也重新居中）。编号条**水平居中显示**（去掉左侧层级标签，编号总宽超出条宽时自然变为横向滚动）。flutter analyze 无新增告警，126 条测试通过（唯一新增失败为并行会话开发中的 ollama_model_catalog 测试，另 tool_export_crowd_tasks 为既有环境性失败，均与本改动无关）。

- **主区/段落框同样钳回图片范围**：区域检测模型可能预测出图外的框（实测 page_345 主区框 0,0,1342,2157、图片实际 1298×2074，编辑器里紫框画出页面外）。`_clamp_result_to_image` 的收口范围从行框/字框扩展到 `main_regions` 与 `paragraphs`。注意：后端是长驻进程，修复需重启应用（后端随之重启）后才生效。

- **识别框层级包含：单行识别框不超出所属段落，段落识别框不超出所属主区**（用户规则，OCR 拆分时强制嵌套）。检测/标点墨迹外扩的行框常伸出主区几个像素，段落框取成员行外接矩形后随之越界；自训段落模型的段框是独立预测，成员行框也可能伸出段框。两处收敛：① **后端** `segmenter._enforce_hierarchy_containment`（`_augment_with_model_hierarchy` 末尾统一调用）——行框中心落在某主区内则钳进该主区（中心在区外的版面边缘小注行不动）；模型段落框先扩到包住全部成员行框、中心落在某主区内则钳进该主区并回填 `main_region_id`、随后与钳后段落仍有 ≥1px 交集的成员行框钳进段落（完全在段落框外的成员行不动，防误裁）；诊断 trace 新增 `[diag:hierarchy]` 汇总行。② **前端** `PageAnnotation._buildParagraph`（自动段落唯一出口，inferHierarchy/rebuildParagraphs 共用）——段落框（成员行外接矩形）钳进包含其中心的主区，伸出主区的成员行框随之钳进段落框，三层框严格嵌套；段落中心在所有主区外（边缘小字段）不钳制。无主区/无段落的数据（大多数页）不受影响，自动主区本就取全体行外接矩形、钳制为零操作。验证：后端新增 5 条单测（行钳进主区/区外不动/段落扩成员再钳主区/无主区扩成员/跨区成员行截边），Python 223 条通过（test_page_dewarp 为环境缺 pytest 的既有导入失败，与本改动无关）；前端新增 2 条段落层级测试，flutter 113 条测试通过、analyze 无新增告警。

- **识别框一律不超出书页图片范围，裁切/摆正产生的纯黑填充带不再算内容墨迹**：① `_text_mask_for_refinement` 与 opencv 兜底切分的墨迹 mask 新增**四边填充带剔除**——校对摆正/跨页拆分产出的书页图裁切范围内常含原图外的纯黑填充（实测矫正图四边暗像素占比 12%~100%），OTSU 会把纯黑当墨迹，行条带/行框随之伸进裁切掉的区域；现自每边向内把"暗像素占比 ≥0.85"的连续行/列清零（最多深入 25%），暗背景页（整页暗占比 ≥0.5，阴文/夜间模式）不走此逻辑、仍由极性翻转处理。mask 是条带投影、行框、字切分、行框外扩共用的唯一墨迹来源，一处剔除全链路生效。② 收口保证：整页识别（`segment_image_with_metadata`）与单行识别（`kraken_segment_rect`）的行框与字框在返回前统一**钳回图片范围**（x/y ≥0、x+w ≤图宽、y+h ≤图高），无论上游几何如何计算都不会越界。Python 222 条测试全过（新增 4 条：填充带剔除/暗底页跳过/带填充带的 mask/结果钳制），60 页扫样回归无变化。

- **主区/段落/单行识别框在配色书页上更清晰**（用户反馈：一些配色的书页上框线看不清）。三处改动：① 框线改为**白衬底 + 全彩实线**两遍描边——彩色细线在深色或近似色（泛黄、青灰、红棕等）书页上会融进背景，先铺一圈半透明白衬底再叠彩色线，任何底色上都有清晰分界；② 线宽加**屏幕像素下限**——此前描边宽度是固定图像像素，整页适配的缩小视图里会细成亚像素发丝线（这是"看不清"的另一主因），现在缩小视图里框线至少保持约 2 屏幕像素，放大视图行为不变；③ 叠加色块透明度 0.06 → **0.12**（选中/待定序 0.22），整个识别框在书页上呈现明显的同色覆盖层，描边全彩不透明。淡灰参照线（区/段视图下的行框、行视图下的字框）同样获得白衬底与线宽下限，配色彩页上参照可见。已用泛黄/青灰/深棕/红棕四种底色的渲染预览验证新旧对比效果。

- **修复行识别框互相重叠（单行/段落识别同一列出现多个交叠框、字被劈到两行）**：三类根源各自修掉。① 行框几何来自"条带内字框并集"，检测器偶发横跨两列的宽字框按中心归入本条带后，并集会吃进邻列墨迹——相邻行的框因此成对重叠（实测 page_076 四对重复行 + 跨双列行皆源于此）；条带分组时把字框**裁剪到所属条带 ±15%**，行框回到单列宽度，识别链路随后按行框重切字框不受影响。② 双列夹注拆分器在"跨双列宽框"上误触发会把两条正文列跺成碎块（同页 yolo_l_005 被跺成 6 块与邻列行框交叠）：新增行内上限**条带宽 ≤2.0×上段字高**（真夹注实测 0.97~1.65 倍、跨双列框 ≥2.2 倍，预筛保持 3×全带字高杀页缘噪声/表格条带——注文占多数的条带 med_h 被小字拉低，用 med_h 会误杀真夹注）。③ 为 line_det 自训模型启用的场景新增**重叠行框解析**：同列重复框（互相覆盖 ≥0.7）合并、宽框吞邻列（一侧被覆盖 ≥0.8）裁窄、部分重叠在重叠带中点裁开，分组前先把模型框解析成互不重叠的框。实测 model 管线重识别 page_345：30 行 10 对重叠 → 24 行 0 重叠（opencv 基线 19 行 0 重叠）；60 页扫样 1102 行仅命盘/万年历特殊版面 20 处触发（结构与夹注同型）。Python 218 条测试全过，flutter analyze 无新增告警。

- 修复**编辑器翻页后缩放比例被重置回整页适配**的问题（用户反馈：逐页放大校对时，翻到下一页就得重新放大）。识别画布换图（翻页/旋转/镜像）前先抓当前缩放比例，新图载入后按同一比例居中呈现——翻页不再打断缩放状态；平移位置不保留（新页从居中开始，避免上一页角落的取景惯性带进新页）。比例超限（滚轮缩放同款 0.05~8.0 钳制）与页面尺寸变化（旋转后宽高互换）都能正确处理。初始矩阵逻辑提取为纯函数 `canvasInitialMatrix`（page_quad.dart，与 `matrixXyScale` 同处），新增 6 条单测（适配/居中/沿用放大、缩小/钳制/尺寸变化）；flutter analyze 无新增告警，111 条测试通过（唯一失败仍为既有环境性测试）。

- 新增 **AI 辅助识别（Ollama）**：把本地大模型接入单字与标点校对。首页工具栏新增「AI 辅助设置」（smart_toy 图标）——配置 Ollama 服务地址（默认 http://localhost:11434，可一键"测试连接并获取模型"）、选择视觉模型（单字图像辅助）与文本模型（标点上下文辅助），并可分别开关两个辅助功能；修改即自动保存。编辑器里轻点字块后的快捷候选条底部新增紫色「AI 辅助识别」按钮：普通字把字框缩略图（后端 `/char_thumbnails` 裁切、白底 letterbox PNG base64）+ 行内前后文交给视觉模型，返回 3~5 个候选字；标点小框（文本为标点或框跨度 < 0.65×行中位字高，与后端标点判定同口径）显示「AI 标点辅助（按上下文）」，把前后文交给文本模型按文意推荐句读。AI 候选合并进候选列表置顶显示（紫色描边 + AI 角标，简短理由悬停可见，去重后不覆盖 OCR 候选），点选行为与普通候选一致，AI 结果只作建议不自动改字。新增 `services/ollama_service.dart`：Ollama `/api/tags`、`/api/version`、`/api/chat`（stream:false、think:false 关思维链、temperature 0.2）封装，配置存 SharedPreferences（`ollama_settings_v1`）；响应解析容忍 ```json 围栏/前后废话/纯文本，解析不出时引号优先（「X」）再裸序抽取候选字，非法字符过滤、去重、解析失败给出含原始输出的可读报错；连接失败统一转中文排查指引（未启动/地址不对/模型未 pull 分别提示）。单文件改动：`editor_page.dart` 快捷候选浮层传入行内上下文与标点判定（`_LineCard._quickEditChar` 计算），`home_page.dart` 加设置入口；新增 9 条解析守门测试。flutter analyze 无新增告警，新增测试全过；后端无改动。

- **单行识别与整页识别支持拆分"并排双列"夹注行**（竖排正文缩行后旁注小字/双行小字夹注）：这类版式通栏正文段下方并排两条窄列（如"清顯至三公"下并排"次之丙戌人主困 | 甲癸人合恪丁巳人"），此前整条一个行框，行内切字把两条子列的字按 y 序交错输出、整行读法直接读空。`segmenter` 新增 `_double_column_sub_rects` 行框内双列结构检测，七条判据缺一不可（全部来自真实页误报教训）：① 缝隙沿阅读轴持续 ≥3 个字高（**两层策略**：两行小注如"姚即|星天"与正文部首缝在纯几何上不可靠区分——同字号假缝靠⑦排除、短段真注靠放宽段长捕捉会互相打架，故整页自动识别保持严格不拆短注，`/segment_region` 单行识别传 `allow_short` 放宽到 ≥1.2×字高，用户明确指向该行时短注也拆，误拆当场可见可撤）；② 段内两侧各 ≥2 个**字身块**（块高 ≥0.25×字高、块内最宽行墨 ≥0.35×侧宽——夹注小字块又宽又高；部首缝侧影是细笔画条或整段只有一块，"羊陀七殺"的陀、"北斗加臨"的斗加实测均凑不满两块）；③ **通栏桥接**——缝隙上方 2 字高窗内"缝隙带+左侧+右侧同时有墨"的跨缝行 ≥0.35×字高（正文列自然竖缝整条贯通、上方无跨缝墨迹，仅此一条即压掉全部正文误报）；④ 两侧墨宽各 ≥0.42×通栏墨宽（真夹注 0.49~0.65，部首缝对齐假缝 0.37）；⑤ 缝宽 ≥0.07×字高（真夹注 0.10，部首缝 0.06）；⑥ 条带宽 ≤3×全带字高且 ≤2.5×上段字高（页缘噪声/表格格子条带是字高的 5~20 倍）；⑦ 两侧字符带高 75 分位 ≤0.75×上段最高字带（夹注字必须小于正文，现代印刷页"搭配合，始"部首缝假缝比值 0.94 被此条排除）。命中时按阅读序拆为 [通栏上段, 右子列, 左子列, 下段通栏]（夹注可在列中段），**子列永不递归**（防"双列里再拆双列"），上/下段可续拆嵌套。整页识别（yolo-char / opencv）与 `/segment_region` 单行识别（新包装 `kraken_segment_rect`：外扩→检测→逐子框走原单行链路，响应新增 `lines` 列表、保留 `line` 字段兼容）均接入；`_apply_sort_and_renumber` 改重叠带聚类排序，保证拆分行在区域重识别重排序后仍保持阅读序，普通非重叠列结果不变；字框按**就近归属**分配到拆分行（跨子列粘连旧框中心落在缝隙上也不会丢字）；拆分行打 `double_col_split` 标记，区域墨迹扩展与识别前行框外扩一律跳过（防上段通栏框外扩又吃进双列段）。Flutter 端 `segmentRegion` 返回 `List<LineBlock>`：编辑器新画行/行重识别/推倒重切支持一拆多（拆分不再沿用旧整条几何），行内重切页提示"应用后拆为 N 行"并把其余行插回页面行表。验证：两页样张（木刻夹注页 + 现代竖排页）——木刻页"刑傷+刼空傷/在內合斷"列整页即拆 4 行、Kraken 读出"刑傷/天哭喪門流年…"，"媼+姚即|星天"列单行重识别拆 4 行（先"即天"后"姚星"，即"即天姚星"），现代页整页/单行均零误拆；5 本书 17 页 277 行仅 1 处触发即该真夹注；扩样 60 页 1102 行仅命盘/万年历特殊版面有零星触发（大字+双行小注结构，方向正确）。Python 218 条测试全过（含真实样张夹具 2 张与 11 条新用例），flutter analyze 无新增告警。

- 修复**后端不可达（连接被拒）时整本书 6 秒即被判识别失败、且失败无任何日志**的问题（用户实测报错：`ClientException with SocketException: 远程计算机拒绝网络连接`——后端未就绪/正在重启/控制台窗口被关闭时，队列把这类连接级失败与真实页失败共用「重试 2 次、间隔 2s」的预算，约 6 秒就放弃整本书；且该路径发生在 HTTP 状态码之前，应用日志一行不留，事后无法定位发生在哪个会话）。两处改动：① `recognition_queue` 把 `http.ClientException` 识别为「后端不可达」，走独立的 36 次 × 5s = 3 分钟长等待预算（远长于后端冷启动的 20-40s，与 409 忙等的 5 分钟同级），超预算后书卡给出可指导行动的中文指引（「后端服务不可达…检查后端控制台窗口是否被关闭；重启应用会自动拉起后端，再点重新识别即从断点续跑」）替代裸英文异常；重试预算与间隔从 const 改为静态可注入（同 keepAwakeHook 的测试缝）。② `python_service` 对 /segment 的连接级失败记一条 `[py:http] POST /segment 连接失败（后端未就绪或中断）` 应用日志再上抛，此类事件从此可追溯；另加测试专用基地址覆写入口 `debugSetServiceBase`。新增守门员测试：对一个已关闭的本地端口发真实请求（与生产同型的连接被拒），断言走独立预算重试、超限后书卡为中文指引而非裸异常（测试输出即完整复现用户所见报错）。flutter 测试 97 条中 96 通过（`tool_export_crowd_tasks_test` 仍为依赖本机 crowdtest1 测试项目的环境性失败，与本次改动无关），analyze 无新增告警；后端无改动（v81 不变）。

## 1.0.0+31

- 修复**整书识别在显存打满后停摆、后端控制台无输出**的问题（本机 24GB 卡实测：daemon 池按空载占用自动开 8 路，跑起来后每个引擎进程显存棘轮式涨到 1.6~3.4GB、合计约 21.5GB，加上系统占用整卡打满只剩 ~600MB——WDDM 转用共享内存换页，GPU 利用率 100% 但单页耗时从 5s 恶化到 17.5s→33.9s→43s 直至分钟级，3 个在途识别请求静默挂起 10 分钟零进展，faulthandler 全线程栈证实卡在「等 daemon 响应」与「等线程池结果」两处，无任何崩溃）。五处改动：① **daemon 池容量按峰值预算**（`daemon_sizing`）——显存预留从 max(1.5GB, 15%) 提到 max(1.5GB, 25%)，单 daemon 占用改为「空载实测 × 负载系数 2」的峰值估计再进预算（测不到时空载按 1.5GB 下限兜底）：本机从自动 8 路降为 6 路，决策日志同步改为「单 daemon 峰值估 …（空载实测 … × 负载系数2）」口径；`OCR_KRAKEN_WORKERS` 手动覆盖不变。② **每请求归还显存**（`kraken_worker`）——每次识别请求结束（成败都算）后 `torch.cuda.empty_cache()`（仅 CUDA）：caching allocator 只增不减是 daemon 显存棘轮上涨的直接原因，释放后单引擎稳态回到「上下文+模型+单请求峰值」，代价是下个请求重新 cudaMalloc（毫秒级，相对百毫秒~秒级推理可忽略）。③ **等待期心跳日志**（`kraken_bridge`）——等 daemon 响应每 30s、等空闲 daemon 每 15s 打一条进度（含在途/成员数），显存吃紧时的长等待不再表现为「后端卡死无输出假死」。④ **worker 进度日志接入日志文件**——daemon 的 stderr 改由桥接读线程收取后原样透传进服务 stdout（_Tee 同步落盘 service_console.log 并保持控制台输出）：此前 stderr 直接继承原生控制台句柄，service_console.log 与应用内日志跟随窗口都看不到逐行识别进度，排障时少了最关键的一段。⑤ **单请求超时 900s → 300s**——正常识别 0.1~45s，300s 已覆盖 ~7 倍显存劣化，且短于 App 端 10 分钟整页超时：到点杀 daemon 重启、请求按失败上抛让客户端重试继续推进（此前一次卡死请求要干磨 15 分钟，比客户端耐心还长，重试只会在 409 上干等）。后端版本号 v80 → v81（Dart 侧同步，重启自动替换旧后端）；后端测试 267 条全过（`test_daemon_sizing` 22 条按「峰值估 = 空载实测 × 负载系数 2、预留 25%」新口径更新预算算式与决策日志断言；`test_excalidraw` 18 条在服务实际运行环境 paddle env 下全过——base env 跑会在 numpy MKL svd 处硬崩，与本改动无关的既有环境问题）。

## 1.0.0+30

- **移除批量摆正网格底部的消息条（用户反馈：删除后弹出「已永久删除第 899 页」会盖住最下排卡片的删除/修改按钮，影响连续操作）**。移除两处：① 删除成功后的「已永久删除第 N 页」——卡片从网格消失即是最直接的反馈，删除详情本就落应用日志；② 批量趟结束时的「N 页自动摆正失败」——失败卡片有红色「需手动」角标、应用日志有本趟汇总，消息条是纯冗余。保留两处点击被拦截时的即时提示（「该页正在后台处理，请稍候再修改/删除」——点了没反馈会像按钮坏了）。flutter analyze 无新增告警；后端无改动。

## 1.0.0+29

- **修复裁切框拖拽点/框线随书页分辨率缩小（分辨率越高点越小，高分辨率书页上直接缩没）**。用户实测反馈后用像素扫描量化确认：827px 页圆点 ≈20px、1654px 页 ≈3px、3307px/6600px 页检测不到。根因不是画笔——`_StraightenPainter` 一直有 `unit = 1/viewScale` 的屏幕尺寸补偿，而是 **`_viewScale` 从第一天起就恒返回 1.0**：视图矩阵用 `scaleByDouble(s, s, 1, 1)` 只缩 x/y（z 恒为 1），而 `Matrix4.getMaxScaleOnAxis()` 取三轴缩放的最大值，z 轴的 1 永远是最大——屏幕尺寸补偿与"按屏幕像素"的命中半径换算全部失效，实际画的都是图像像素尺寸，页面越大（适配缩放越小）点越小。两层修复：① 新增共享助手 `matrixXyScale()`（page_quad.dart，取 x/y 两轴列向量长度的较大者，带旋转仍正确），替换 4 个视图（校对摆正/跨页拆分/区域标注/全书叠加）的 `_viewScale` 与编辑器的 `_screenScale`、滚轮缩放 `_zoomAt`（顺带修复编辑器滚轮缩放增量被当绝对缩放的隐患）；② fit/缩放/平移只改 TransformationController（Listenable），不触发页面 rebuild，画笔要靠新增的 `AnimatedBuilder(animation: _transform)` 才能在变换后拿到实时 viewScale 重绘。新增"控制点屏幕尺寸不随页面分辨率缩小"回归测试（827px 与 2400px 两页圆点游程都必须 ≥10px 且基本一致，修复前大页仅 ~7px 失败）+ 全尺寸测试的 TL 橙色扫描窗口随新几何加宽。同一诊断轮还发现并确证了 fit 缩放值本身读取正确的证据链（矩阵赋值/回读探针）。flutter analyze 无新增告警，96 条测试 95 条通过（唯一失败仍为既有环境性测试）；后端无改动。

## 1.0.0+28

- **修复校对摆正"页面显示缩水成小图+一圈黑边、实际裁切却正常"（用户定位：显示的是缩略图，分辨率不够的部分填了黑色）**。根因在校对摆正画布的底图组件：`RawImage` 只给了 `width/height`（全尺寸文件大小）没给 `fit`，而 Flutter 的 `paintImage` 对缺省 fit 走 **BoxFit.scaleDown**——位图按 `_decodeWidth=1600` 降采样解码后小于盒子时**不放大、按原尺寸居中**，盒子其余区域什么都没画，透出深色底就是那圈"黑边"；而裁切框、命中与输出坐标全部按全尺寸文件计算，文件本身完好，所以"移框裁出来的是正常书页"。页面文件越大（远超 1600px）缩水越狠（用户截图 ≈25%），1654px 的普通 200DPI 页只显示 ~27px 细边不易察觉。修复：底图 `RawImage` 显式 `fit: BoxFit.fill`（识别编辑器同款组件一直带此参数，校对摆正抄渲染路径时漏掉了；位图与文件同源同比例，fill 恰好铺满、无拉伸）。新增大页渲染防回归测试（2400×3400 页面，画布四边采样必须为纸面亮色且 alpha=255——已验证去掉 fit 即失败）；诊断日志：`/pdf_to_images` 逐页记录 MediaBox/CropBox（不一致时标注"注意渲染范围"）/页面旋转/渲染像素尺寸与最大近黑暗块（≥1% 记录、≥30% 出 ⚠ 独立行，定位"导入黑边/黑底"来源），`detect_page_quad` trace 新增 `source_dark_region`（最大暗色块占比/位置/亮度，≥5% 时判定文案追加提示），检测日志弹窗与一行摘要同步展示——后续再遇"黑边被当成纸"可直接看日志定位。后端版本号 v79 → v80（Dart 侧同步）；新增 `dark_region_stats`/`pixmap_rgb_array`/trace 暗块断言 5 条，后端 267 条全过（excalidraw 单独跑，既有全套崩溃与本改动无关）；flutter analyze 无新增告警，95 条测试 94 条通过（唯一失败仍为既有环境性测试）。

## 1.0.0+27

- **批量摆正按机器配置并行处理多页（原先一次只处理一页）**：处理循环改为 worker 池——并行数在每趟开始时向后端新端点 `GET /deskew_sizing` 要一次硬件决策（`daemon_sizing.decide_dewarp_workers`：物理核留 1 核给系统得 CPU 上限；可用内存 × 60% ÷ 每 worker 约 384MB（200DPI 页拉平的读入原图 + 输出图 + remap 浮点坐标图 ×2 + PNG 编码缓冲的峰值估计）得内存上限；再与硬上限 6 取小；环境变量 `OCR_DEWARP_WORKERS` 可直接覆盖钳制 1..6），"为什么是 N" 的决策理由随批量启动日志进应用日志。能真并行的依据：`/detect_page_quad` 与 `/dewarp_page` 是纯 CPU OpenCV（大运算释放 GIL）的 FastAPI 同步端点（自动进线程池），前端并行发请求即真并行——本机 16 核/49GB 空闲内存实测决策并行 6。并发安全：`straighten_state.json` 落盘改串行化队列（`_saveQueue` 链式写入，tmp→rename 原子替换不再被并发写坏）；「停止」不再派发新页、进行中的页处理完即停；取页时双重校验——已删除的悬空计划跳过、排队期间被「修改」会话解决的页不再重做；失败仍只标记单页不阻塞其他 worker。进度行从"当前页"改为"已完成/总数 · 并行 N · 正在处理 第 x、y、z 页（等 M 页）"，进度条按完成数推进；每页完成即刷新网格并落盘，断点续作、逐页确认/删除、去色/锐化重做等语义全部不变。后端版本号 v78 → v79（Dart 侧 `_expectedBackendBuild` 同步）；新增 `decide_dewarp_workers` 表驱动单测 8 条（环境变量覆盖/钳制/坏值回退/CPU 上限/单核机/硬上限/内存受限/预算比例），后端 262 条全过（`test_excalidraw` 在全套连跑时的进程崩溃为既有环境问题：剔除该文件 244 条全过、其单独 18 条全过，去掉本轮新测试同样复现，与本改动无关）；flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

## 1.0.0+26

- **控制点抓取再次放宽 + 空白处按下自动吸附**（用户反馈左上角仍难拖）：命中半径翻倍——角点 52 → **100 屏幕像素**（视觉圆点 13px 的约 8 倍）、边中点 42 → **80px**、边线抓取 ±14 → **±28px**。另加**最近吸附兜底**：在画布任意位置按下左键（不在任何命中区内）也会自动吸附到最近的角点开始拖动——不再存在"点了没反应"的死角；空白拖动从无效操作变为有效操作。flutter analyze 无新增告警，校对摆正相关 19 条测试全过。

- **校对摆正的控制点抓取范围大幅放宽 + 支持直接抓边线**（用户反馈：要对得非常准才能拖动）。命中优先级：① **角点**命中半径 36 → **52 屏幕像素**（视觉圆点 13px，命中区约 4 倍于视觉）；② **边中点** 30 → **42px**；③ 新增**边线本体抓取**——鼠标落在任意边的线体 ±14px 内即视为拖动该边（两个角一起平移），不必精确点到边中点圆点；全部按屏幕像素换算，视图缩放越小命中区（图像坐标）越大。flutter analyze 无新增告警，校对摆正相关 19 条测试全过。

- **修复网格删除书页"点了没反应"**：「完成」之后本书页面列表存的是矫正图路径（warped\…），网格删除用**源路径**在列表中定位——查不到（-1）静默走了"刷新计划"分支，页面没删也没提示。定位改为**源路径/矫正图路径双查找**（网格删除与会话删除共用 `_imageFileIndexOf`），两处都能正确命中；顺带修正删除时识别标注的页号推导——从源文件 stem 取（稳定标识），不再从可能已换成矫正图的当前文件推导（stem 变了会漏删/错删标注文件）。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **预览自动刷新 + 预览窗占比可拖**：① 矫正预览面板**随调整自动更新**——拖动裁切框（角点/边中点）、切换去色/锐化、重新检测、重置全图后约 0.5 秒自动出图（防抖触发，拖拽停止才计算，不疯狂请求）；并发请求按代数丢弃过期响应（连续调整只显示最新一帧），不再需要手动点刷新。② 画布与预览面板之间新增**拖拽分隔条**（左右箭头光标），横向拖动调整预览窗占比（240-720px），画布区域自适应。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **修复删除书页异常退出 + 批量摆正连续编辑会话（确认/删除自动翻页）+ 修改界面右侧常驻预览**：① **删除崩溃根因**：网格删除用 `plan.index` 定位页面，但「完成」把页面文件换成矫正图路径后，计划按源路径为键、按 `imageFiles[index]` 重索引失效——索引越界直接 `RangeError` 异常退出。修复：删除定位改用 `imageFiles.indexOf(源路径)`（越界即刷新计划返回），删除后**全量重建计划**（`_rebuildPlans`：按新页面列表重读状态文件重排，不再手工改索引）。② **修改界面（校对摆正页）新增会话模式**：批量页「修改」进入时传入会话宿主，底栏变为「**确认并下一页**」（写出矫正文件 + 标记确认 + **自动载入下一页**，无需反复退出重进）与「**删除**」（红色确认弹窗 → 永久删除本页 → 自动翻到下一页）；最后一页处理完自动关闭回网格。③ **右侧常驻预览面板**：编辑界面改为左右分栏——左侧裁切画布、右侧 380px「矫正预览」面板（矫正图/原图切换 + ↻ 按当前框刷新预览，InteractiveViewer 缩放细看），不再需要单独点开预览对话框；独立模式（编辑器入口）同样获得该面板。批量页宿主负责记账（确认标记、缩略图作废、状态落盘）。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **自动批量摆正转为后台运行，不再阻塞前台操作（用户指定）**：去掉模态进度对话框，处理在后台逐页进行，网格全程可操作——修改其他页、预览、确认/取消确认、删除、切换使用矫正图、去色/锐化开关都可在处理进行中使用。顶部新增**内嵌进度条**（细进度 + "后台处理中 N/M · 当前页" + 「停止」按钮，停止在当前页处理完后停下，进度已逐页落盘）；每张卡片的状态角标（处理中…/未处理/已矫正/需手动）实时反映。并发保护：**正在后台处理的那一页**临时禁用其「修改/删除」（SnackBar 提示稍候），其余页不受影响；删除的页自动从后台待办中跳过（悬空计划跳过校验）；趟内切换去色/锐化对后续页生效，趟末自动补跑设置不一致的页（失败页不自动重试，避免死循环）；「完成」与退出在后台运行中也随时可用——进度已逐页落盘，退出后后台循环在当前页处理完即停，剩余页下次进入续作。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **修复"框看着对、裁出来四边少一截"（真实 page_266 定位）+ 断点续作的算法版本自愈**。用户截图的框包住整页，产物却四边内缩。取证链：状态里的框（79%×84%）≠ 用户所见框（全页）→ 该页是**低对比封面**（棕褐书皮 vs 灰底反差低），墨迹掩码只抓到深色题名框/标签，**墨迹包围盒切进了书体**；且 v77 的渍块过滤（大而实心剔除）把书缘黑带、边框线也当渍剔了，框永远缩在书内。修复：**深墨扩展**——墨迹框与强墨掩码（C=50，淡渍暗度 30-41 达不到）的成规模组件（面积 ≥0.02% 图幅或最长边 ≥1.5%）包围盒取并集：书缘黑带/边框线包回来，淡渍不在强墨掩码里不受影响，白边裁切不回归（三种场景实测分离清晰：切书体页环带含 6.1 万强墨像素、白边页/淡渍页为 0）。**断点续作自愈**：状态按"检测算法版本"戳记（`detect_algo`），版本过期的页自动重新检测——旧版算法检测的偏小框不会永远沿用（该书 531 页抽样 14 页，1 页需重检 76%→100%，其余一致）；手动修改的框视为当前版本。检测日志新增「深墨扩展」行。后端测试 31 条全过（全部行为不回归），flutter analyze 无新增告警、94 条测试 93 条通过。

- **批量摆正升级为可断点续作的常驻功能 + 逐页确认/删除**：① **书籍列表卡片新增「批量摆正」入口**（crop_free 图标，随时可进）——本书在识别中/排队时先弹窗确认暂停识别（摆正要改写页面文件不能并行；稍后重新开始识别即可，已完成页自动跳过）。② **断点续作**：处理状态持久化到 `straighten_state.json`（每页的裁切框、needs_warp 判定、增强设置、确认标记、使用矫正图选择；每页处理完即原子落盘），重进只补未处理/设置不一致的页，已处理页原样保留；状态按**源文件路径**为键（矫正图输出路径由源文件相对路径推导、与页序无关，删页不漂移；「完成」换上的矫正图按 out_path 反查回源）。③ **网格卡片新增「确认」与「删除」**：确认＝本页摆正结果检查通过（可取消确认）；删除＝**永久删除**该页图片、矫正图与识别标注并从本书移除（红色确认弹窗，不可恢复），删除后其余页序自动前移、状态与进度保留。④ **已确认页默认隐藏**，顶部「隐藏已确认」开关控制显示（含已确认计数），全部确认完时空态提示。去色/锐化开关、检测日志等原有能力不变。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **三个批量摆正体验修复**：① **裁切框不再超出图片**（上一版为保贴边文字允许出界 ±20%，导致控制点跑到图外拖拽困难）——墨迹框恢复夹回图像边界；有效墨迹口径实测切墨 0.0-0.1%（出界处本无有效内容），框内控制点全部可拖拽。② **去色/锐化开关切换后自动用新设置重做全部页面**（此前只对之后手动「修改」的页生效）：重跑沿用已存的裁切框与判定（不重新检测），缩略图缓存整体作废并逐页 evict FileImage；原先"无需摆正"的页在开启任一增强时也产出增强副本（框≈整图、仅增强），两项增强全关时回到用原图。③ 单页「修改」沿用批量页当前的开关状态进摆正页（原有逻辑，配合②全链路一致）。后端版本号 v77 → v78（墨迹框夹取恢复图内）；后端测试 31 条全过，flutter 94 条中 93 条通过（唯一失败仍为既有环境性测试），analyze 无新增告警。

- **新建图书任务接入完整导入流水线：跨页拆分 → 批量摆正 → 识别（用户指定顺序）**。「识别方式」卡片新增「导入后先跨页拆分」开关（默认开，与批量摆正组成三步流水线，卡片顶部注明执行顺序），创建任务后先进入**跨页拆分页**（编辑器同款交互：拖中缝线、选页序、确认应用；无跨页书直接返回即跳过），再进入**批量摆正**，最后才入队识别。「创建后手动开始识别」默认值改为**开**——流水线走完后由用户手动开始整本识别（开关仍可关掉恢复自动）。配套：`BookSplitPage` 新增 `enqueueRecognitionAfter` 参数（默认 true 保持编辑器原行为），流水线传 false——拆分应用后不再立即入队识别（原实现在拆分结束时无条件 enqueue，会抢在批量摆正前开始识别、基于未摆正的页面列表），识别改由流水线末尾按手动/自动设置统一入队。flutter analyze 无新增告警，94 条测试 93 条通过（唯一失败仍为既有环境性测试）。

- **深色渍也按形状剔除 + 含墨校验改强墨口径 95%（用户反馈：v76 又把该裁的渍算进来了，并要求补充日志）**。本轮在真实页上量化定位了三件事：① 该渍是**深色渍**（含 ≥50 暗度像素，强档掩码自身就延伸到 90% 高）——对比度阈值对它无效，改用**结构判据**：墨迹有效掩码三重过滤（强墨 ±9px 邻域全保留＝贴深笔画的淡字不丢；**大而实心的连通块（凸包填充率 >0.75 且面积 >0.5% 图幅）无论深浅判为渍剔除**；无强核小组件须距深墨 ≤25px）；② page_001 曾切字 11.8% 复盘：纸框恰好切掉 9.7% 的**强墨**，从"全墨迹 90% 含墨"阈值下溜过——含墨校验改为**强墨口径 + 95% 阈值**（真纸边外强墨应≈0，纸边 8px 内伪墨迹带仍豁免）；③ 墨迹框**不再夹回图像边界**（旋转 bbox 的角在图外时夹取会切掉贴边文字角落，允许出界 ≤20%，拉平后出界区填白）。检测日志新增**墨迹保留率、剔除渍块数/像素、整页淡墨回退**三行（掩码过滤过程透明化，便于继续按日志调参）。真实页验证：当前项目四页渍不撑框（高 73-95%）且切墨 ≤1.4%，老项目抽查有效墨迹口径切墨 0.0%。后端版本号 v76 → v77（Dart 侧同步）；后端测试 31 条全过，flutter 94 条中 93 条通过，analyze 无新增告警。

- **修复上一版"强档掩码裁掉同页淡字"（真实 page_001 定位：11.8% 敏感墨迹被切）**：直接用强档（C=50）裸掩码定框/校验有两个误伤——① 与深笔画同页混排的**淡字**（暗度 30-50）被整体丢掉；② 含墨校验对框外淡字隐形，切字的纸边框照常通过。改为**有效墨迹**：敏感掩码按连通组件过滤，凡 9px 内有强墨核的组件**整个保留**（真实页实测保留 96-99% 敏感墨迹——淡字与深笔画天然相邻），孤立纯淡渍（附近无任何深墨的页边污渍）仍被忽略；整页淡墨（有效墨损失过半）退回敏感掩码。定框与含墨校验都改用有效墨迹；角度扫描保持敏感档。真实页验证：page_001 切字 11.8% → **0.0%**，四页全部 ≤0.1%，孤立淡渍忽略不回归。后端版本号 v75 → v76（Dart 侧同步）；后端测试 31 条全过（新增强弱字同列混排不裁、孤立淡渍仍忽略的回归），flutter analyze 无新增告警。

- **页边淡渍不再撑大橙框（用户指定：淡墨渍可通过调高对比度/亮度去掉，智能边框应忽略它们）**。实测对比度数据分离明确：页边淡渍/扫描阴影的暗度中位仅 30-41，真字笔画 91-106——据此把墨迹掩码拆成双档强度（自适应阈值 C，即"比局部背景暗多少"）：**敏感档 C=15** 用于对齐测量与覆盖率（淡笔也有信号），**强档 C=50** 用于定框范围与含墨校验（淡渍被忽略、真字不受影响）。整页淡墨的书（强档丢墨超六成）自动回退敏感档定框，不丢内容。真实页效果：page_000 框高 98%→72%、page_002 99%→73%（底部淡渍区不再撑框），页眉页码等真实边缘内容（page_003 95%）不受影响。后端版本号 v74 → v75（Dart 侧同步）；后端测试 30 条全过（新增淡渍忽略、整页淡墨回退两条回归），flutter analyze 无新增告警。

- **修复"表格块冒充纸边、漏裁表格外文字"（真实 page_001.png 定位）**：检测日志显示"纸边面积占比 38.8% vs 墨迹框 89.3%"——墨迹延伸到"纸"外，物理上不可能（字一定印在纸上），实为页内高填充表格块冒充纸边（38.8% 过了 35% 面积门槛），且残余判据框内自洽（框外文字不参与校验）拦不住。新增决定性过滤：**真纸边候选必须包含 ≥90% 的"远处"墨迹**（离候选框 8px 以外的框外墨迹；纸边外侧自适应阈值产生的窄伪墨迹带属边缘效应，膨胀 8px 豁免——不豁免会误伤照片页真纸边）。表格块（实测含墨 88%）被拒后回退墨迹框，包住全部内容。检测日志的纸边分析同步新增"含墨比例"字段。真实页验证：page_001 框宽 38.8%→97%（表格+文字全包），page_000/002/003 与老项目抽查页均正常。后端版本号 v73 → v74（Dart 侧同步）；后端测试 28 条全过（新增表格块回归测试），flutter analyze 无新增告警。

- **白底页的智能边框改为"只包内容区"（用户指定：橙色框要包裹到有内容的区域，裁掉页面其他白色区域）**：此前白底 PDF/渲染页（纸边与背景无反差）走"纸边贴满全图"兜底 → 整框不动、判无需摆正，白边全部保留。现在**纸边候选≈整图四角（无真边界信号）时直接采用墨迹框**——包裹内容块（含 3% 余量）并裁掉周围空白，同时按墨迹主方向转正。实测 page_000：框宽 94%/高 98%（与用户手绘期望 89% 宽一致，高度多保留的页眉页码是有墨迹的真实内容，可用边中点拖拽收紧）。有真实纸边的照片页不受影响（仍按纸边/墨迹一致性判定）。判定文案与检测日志同步（"纸边无信号（页边与背景无反差，贴满全图）：按墨迹行列包裹内容区并裁掉周围空白"）。后端版本号 v72 → v73（Dart 侧同步）；后端测试 23 条全过（密排文字回归测试改为断言墨迹框包裹行为），flutter analyze 无新增告警。

- **修复"白底 PDF 页被框成窄条"（检测日志+真实页面定位）**：用户反馈 page_000 检测错误的日志显示"纸边面积占比 23.2%"异常（真整页应 ~90%）。在真实页面复现定位：该页 88.6% 像素为最亮档（纸边与背景无反差），轮廓法的暗色极性通道里 **15×15 闭运算把密排竖排文字熔成 ~23% 的实心色块**，填充率 97.9%，恰好通过"纸"的全部过滤条件（最小面积 20%）——把熔成块的墨迹当成了纸；且一致性判据自我印证（按墨迹块拉正墨迹残余恒 0°），采用了窄条框裁掉大半页。修复：`_MIN_PAGE_AREA_RATIO` 20% → **35%**（真页面在照片里是主体；墨迹块 23% 被拒，深色页测试 47% 仍通过）。修复后该页回到整图、文字残余 −0.5°（≤1.2°）如实判"无需摆正"；全书 4 页实测 3 页贴满跳过、1 页真实纸边正常摆正。后端版本号 v71 → v72（Dart 侧同步）；后端测试 23 条全过（新增密排文字不被当成纸的回归测试）。

- **每页检测日志：智能边框的判定过程全透明（帮助判断哪些页要手动调整）**。`/detect_page_quad` 返回完整 `trace`：墨迹分析（覆盖率、文字方向竖排/横排、主方向角、**倾斜置信比**=最优角得分/0°得分（≈1 说明本来就把得正）、墨迹框面积占比）、纸边分析（面积占比、填充率、纸边倾角、是否≈整图四角）、**一致性判据**（按纸边拉正后墨迹残余角 + 1.2° 阈值）、扫描参数（±12°/0.5°）与中文判定原因（例："按纸边拉正后墨迹残余 3.0°（>1.2°）：文字与纸边方向不一致，改按墨迹行列对齐（主方向角 3.0°）"）。前端两处展示：① 摆正页底栏新增「检测日志」按钮（receipt_long 图标，检测后可用）弹窗逐项展示判定依据（**弹窗文本可鼠标划选复制，另有一键「复制全部」按钮**——纯文本含文件名与全部判定行，方便整段发出来调参），尾部提示可手动修正；② 批量自动处理与单页检测各写一条一行摘要到应用日志（`[批量摆正·检测] 第 N 页：墨迹覆盖 7.6%·竖排·主方向 3°，纸边拉正残余 3° → …`），后台日志页可查。后端版本号 v70 → v71（Dart 侧同步）；后端测试 26 条全过（新增 trace 内容与端点透传断言），flutter 94 条中 93 条通过，analyze 无新增告警。

- **智能点位改为"按墨迹行列对齐"（用户第二次纠正检测目标：不要贴纸边、要对齐主要墨迹的横竖）**。此前的检测对齐纸边，但实拍页纸边与文字方向常差 2-3°（透视/装订偏差），矫正后文字仍是斜的。新主路径 `_quad_from_ink`：自适应阈值取墨迹（抗阴影渐变）→ **投影清晰度扫描**找文本主方向（横排扫行投影、竖排转置后同法，±12° 步进 0.5°，取 Σ投影² 峰值）→ 旋正后取墨迹包围盒外扩 3% 余量 → 旋回得到贴合墨迹行列的四边形（200DPI 整页实测 0.17s，合成歪 3° 页检出 3.02°）。**纸边与墨迹的一致性判据**：不用"直接比较角度"（透视页文字列倾角本来就 −2.5°→+4° 渐变，直接比会被误导），而是**按纸边单应把墨迹拉正后扫残余倾角**——残余 ≤1.2° 视为一致，用纸边框（保留页边距）；更大则文字与纸边真不一致，改用墨迹对齐框。无墨迹信号（空页）退回纸边/内缩全图；旧的墨迹投影法（不辨方向的包围盒）被墨迹对齐法完全覆盖，已删除。检测方式角标新增「已按墨迹行列对齐检测」。后端版本号 v69 → v70（Dart 侧同步）；合成文字改为密排竖排（旧网格太稀锁不准角度）、旋转文本层的 warpAffine 填充改白（默认黑色填充会被当成墨迹污染包围盒——测试数据 bug）；后端测试 21+4 条全过（新增：文字歪 3° 纸边端正→按墨迹对齐、横排行歪 4°→转置路径对齐），flutter 94 条中 93 条通过，analyze 无新增告警。

- **重写智能裁切点检测：点位贴着纸边走（用户反馈此前检测出的斜框完全不对）**。旧轮廓法（Canny + approxPolyDP）在灰底扫描页上不稳定，检测出与纸边无关的斜切框。新算法：① 亮度 Otsu 把"纸 vs 背景"分开，**两种极性都试**（纸通常比背景亮也可能更暗）；② 页面色块经 minAreaRect 求主方向后，把轮廓点旋正、按对角极值取**轮廓上的真实角点**——同时贴合纸的旋转与透视（梯形页的"缺角"不外扩，这是 minAreaRect 直接取框会犯的错）；③ 填充率过滤枝杈色块，≈整图四角的色块视为无页面边界信号（干净渲染/PDF 页），仅在无真页面候选时兜底返回整图。配套调整"无需摆正"判定：贴边容差回调至对角线 **1%**——干净贴满全图的页（偏差≈0）如实跳过，而真实拍摄/扫描页哪怕 1-2° 的倾斜（偏差 2-4%）也判定拉正，正对应用户"点位贴着纸边、把页面转正"的预期。墨迹投影法降级为轮廓法无信号时的回退（打桩测试覆盖）。后端版本号 v68 → v69（Dart 侧同步，重启自动替换旧后端）；后端测试 19 → 23 条（含近满幅 2° 倾斜页贴合检测、反极性暗页、投影回退打桩、梯形角点不外扩等新断言）全部通过；flutter 测试 94 条中 93 条通过，analyze 无新增告警。

- **修复"确认摆正后再点修改，显示的是修改前的点位"**：摆正页确认后此前只 `pop(true)`，用户调整后的最终裁切框没有传回调用方，批量页 `plan.quad` 仍存自动检测的初值——再次进入「修改」就回到调整前的框。现在摆正页确认后 **pop 实际应用的 PageQuad**（取消 pop(null)）：批量页存为该页当前框，再次「修改」从调整后的点位继续微调；编辑器单页入口同步适配返回类型（`push<PageQuad>`）。
- **修复"手动调整后矫正图看起来和原图一样"（两层原因一起修）**：① **批量页缩略图旧缓存**——手动修改会覆盖同一路径的 warped 文件，但缩略图 LRU 按路径命中、State 不重建，编辑回来显示的一直是自动处理时的旧图；现在修改完成后作废该路径缓存并推进 stamp（卡片以新 key 强制重建缩略图重新解码），同时 evict 全局 FileImage 缓存让预览对话框也拿到新图。② **假"已矫正"副本**——PDF 渲染页天然贴满全图，自动检测给出的框≈整图边界，拉平=恒等变换，输出和原图一样却被标成"已矫正"；`quad_needs_warp` 的贴边判定容差从对角线 1.5% 放宽到 **3%**，这种框如实判"无需摆正"（批量页标记"无需摆正"、默认用原图），想调整的用户点「修改」手动拖框，结果现在能如实显示。后端版本号 v67 → v68（Dart 侧同步，重启自动替换旧后端）；后端测试 17 条全过（含 2% 内缩近恒等框判跳过、明显偏转框判拉平的新断言），flutter 测试 94 条中 93 条通过，analyze 无新增告警。
- **校对摆正交互按用户反馈重构：去掉贝塞尔弯边，改为纯直边四边形 + 更大拖拽点**。新交互模型：① **4 个角点**（加大到 26px 直径，橙色双环白芯）自由拖动改变框形状；② **4 个边中点**（20px 直径）拖动时**该条边的两个角顶点共同平移**（整条边跟随移动），按下瞬间的指针位置与四角快照作位移基准，拖动零跳变；③ 命中区加大且**角点优先命中**（角 36px、边 30px 屏幕像素半径，随缩放反向放大）。`PageQuad` 模型随之简化：删除全部弯边（midOffsets/贝塞尔控制点/Coons 取点），只保留 4 角直边 + 双线性网格取点 + 自交检测 + 旋转映射；序列化不再传 edge_mids（后端永远走精确单应路径；后端弯边/Coons 能力保留备用）。测试同步重写：边拖共同平移（对边不动、边向量保持）、角拖只动一角、四边 edgeMid 位置、CW/CCW 旋转、蝴蝶形自交、直边双线性取点、JSON 往返（断言不含弯边字段）。
- **修复校对摆正页"全黑屏"（布局级根因，前一轮修的是表面）并改裁切框配色**：用"真实尺寸整页（1654×2339）+ 真实窗口大小（1900×1054）+ 全屏像素采样"的渲染测试完整复现了用户截图——**底部工具栏的 Row 在 Scaffold 的无高度约束测量下把整个窗口高吃掉（实测量得 1900×1054），body 被挤成 0 高**，画布从未上屏；且首次 fit 撞上 0 高视口算出退化缩放后再也不补，用户看到的就是纯深色 + 一条竖直分隔线 + 悬在屏幕中央的工具栏按钮。三处修复：① **底栏定高**（内容 SizedBox 锁 44px）——Scaffold 按底栏量得高度分配剩余空间，定高后 body 恢复正常（测试实测底栏回到 60px、body 938px）；② **fit 自动补跑**——LayoutBuilder 帧末只要视口有效且用户未缩放过就重新适配整页（退化视口的帧跳过，不再一次性卡死在 0 缩放）；③ **底图改 RawImage 组件**（合成器直传，编辑器同款渲染路径）——不走画布 drawImageRect，规避大图纹理在本机画布路径上画不出的风险。像素级验证：修复后全屏采样中心像素 = 纸面本色（238），底栏/画布布局位置全部正确。裁切框配色同批调整：白框在白纸上不可见 → **深色衬底 5.5px + 橙色实线 2.5px 双层描边**，网格参考线改深色，控制点橙色 + 黑色发丝圈，放大镜白圈加衬底。测试新增/升级 `straighten_page_test.dart` 3 条（真实尺寸整页全屏采样、小图像素采样、坏图显式报错）；另位图解码失败时一律显式显示红色错误说明（带底层原因）并释放位图，不再渲染只有深色底的黑画布。
- **修复删除图书项目时应用异常退出**（ConcurrentModificationError，存量 bug 与摆正功能无关）：首页 `_refreshProofreadCounts` 在 `for (final proj in projects)` 循环体内 `await` 逐本书读校对计数（大书库可达数秒），迭代的是与 `_projects` 同一的列表对象；期间删除项目执行 `_projects.remove` 让循环恢复后的 `moveNext` 抛并发修改异常，而该函数是 `unawaited` 调用、异常无人接，桌面端整个应用直接退出。修复为迭代列表快照（`List.of(projects)`）。同批加固删除路径：① `_init` 加代数守卫——删除触发的并发重载只让最后一次结果落地，顺带修掉"先读盘的那次重载把刚删除的书复活成僵尸卡片"的竞态，删除完成后主动重读一次盘；② 项目目录删除失败（文件被占用等）改为 SnackBar 提示并保留列表条目，不再带着未捕获异常退出。
- 新增**校对摆正**（仿白描）：书页照片的智能裁切点检测 + 可拖拽微调 + 透视/弯边拉平 + 去色/锐化。核心交互与白描一致——大图上深色遮罩 + 白色裁切四边形 + **8 个可拖拽控制点（4 角 + 4 边中点）** + 网格参考线，**拖拽时显示放大镜**（4× 局部放大 + 橙色十字准星 + 连线），右键拖动平移、滚轮缩放；裁切框自交时确认按钮禁用并红色警示。**边中点沿边法线拖动使该边弯曲（二次贝塞尔）**，专治装订弯曲的书页：拉平时四边全直走严格单应（warpPerspective），任一边弯曲走 Coons patch 双向插值网格重采样（cv2.remap），装订卷曲页得以"摊平"。三个入口/流程：① **新建任务后自动进入批量摆正**（任务设置新增开关，默认开）——逐页智能检测 + 拉平输出到 `warped/page_NNN.png`（**sources 原图始终保留**），阻塞式进度对话框可停止，完成后结果网格逐页预览（原图/矫正图切换对比）、效果不好的页点「修改」进单页微调（基于原图重做、覆盖同页号输出），按页选择「使用矫正图/使用原图」后才落到页面列表，**识别入队在摆正完成之后**；页面已平直贴满（检测偏差 <1.5% 且无弯边）的页自动跳过不重采样，干净扫描零代价；② 编辑器标题栏新增摆正按钮（旋转/镜像按钮旁），当前文件已是 warped 输出时原地覆盖、否则 `warped/<源名>_st.png`（重名加后缀防跨页覆盖）；③ 已识别页摆正前确认弹窗，**确认后清空该页标注并提示重新识别**（透视拉平后字框无法可靠投影）。工具栏其余动作：旋转 90°（就地转源图 + 点位同步换算，**取消时自动转回保证零副作用**）、重新智能检测、重置全图、网格开关、**预览**（preview 模式回传 base64 小图先看效果再确认）。后端新增纯 CPU 端点 `/detect_page_quad`（轮廓法 Canny+Otsu → 墨迹投影法 → 内缩全图三级回退，返回 TL,TR,BR,BL 四点与 needs_warp 跳过判定）与 `/dewarp_page`（单应/Coons 拉平 + 去色[灰度+2%~98% 分位对比度拉伸] + 锐化[unsharp mask]，preview 返回 base64、否则写 out_path 新文件），算法在新模块 `python_service/page_dewarp.py`；Dart 侧新模型 `models/page_quad.dart`（贝塞尔/Coons 几何与后端逐点一致，含旋转映射、法向弯边、自交检测、序列化）。后端版本号 v66 → v67（Dart 侧同步，重启自动替换旧后端）；后端测试新增 `test_page_dewarp.py` 17 条全过（合成照片角点精度、投影/默认回退、needs_warp 判定、单应/Coons/恒等、去色锐化、端点写盘/预览/中文路径/坏输入），flutter 测试 90 条中 89 条通过（新增 page_quad 15 条：默认内缩、法向偏移与四边符号约定、法向投影约束、edge_mids 序列化、CW/CCW 互逆与四次回原、蝴蝶形自交、直边 Coons 退化双线性、JSON 往返；另新增批量摆正页回归 1 条——首版曾因 initState 内同步 showDialog 触发 `dependOnInheritedWidgetOfExactType(_LocalizationsScope)` 崩掉新建任务流程，已改为 postFrameCallback 后启动并有测试锁定；`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次无关），analyze 无新增告警。

## 1.0.0+25

- 全书墨迹归类新增**行内重切**：碰到因切字边框拆分不正确而显示有问题的字时，**双击该字格**（或在单字修改对话框点「行内重切」）直接打开它所在行的**行内重切页**——新页面 `pages/line_reseg_page.dart` 按该行的排版方向以**竖排/横排卡片**展示行图与行内单字识别区（与编辑器单字识别行卡片同风格）。重划分手段：① 行图上**拖角调整字框、拖动移动、空白处拖动画新框**、点字框或字卡选中后删除（复用编辑器行卡片的交互层——`_InteractiveLineCrop` 公开为 `InteractiveLineCrop` 供两处共用）；②「重新切分（推倒重拆+识别）」对该行走完整自动拆字+OCR 链路（与编辑器"重新切割该列"同链路 segment_region）；③「识别填字（保留当前框）」保持框几何只重新填字。**确认状态规则**：几何被改动过的字（调整/移动/新画/重切/重填）一律重置为待确认（proposed）——此前确认过的字因选取已变化必须重新确认；几何未动的字原样保留（应用时直接沿用原字块实例，零漂移），整行有改动时行状态同步回退并标记 manual（级联重建保留，手工行框不被外扩覆盖）。实现要点：页面图按最长边 2200 降采样解码（与墨迹校验调试页同口径，单次解码用完即释放），草稿坐标全部工作在解码图像空间、应用时按比例换算回页面像素；「应用修改」把草稿写回书页持有的同一行实例（按阅读方向重排 order、重拼行文本），全书归类页随后重建页内字块索引、**剪掉分组/单字里被替换或删除的旧字块**（点「重新归类」后重新聚组），未落盘编辑照常防抖落盘；有未应用改动时返回需二次确认。单字修改对话框同步新增「行内重切」按钮（未归组单字的入口）。本次为 Flutter 端改动，后端版本不变（v66）；flutter analyze 无新增告警，flutter 测试 74 条中 73 条通过（`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次无关）。

- 墨迹归类（单页版与全书版）的组内选择与确认交互重构：**点选 + 框选 + 只确认所选 + 已确认默认隐藏**。① 组内文字支持**点选**（单击缩略格选中/再点取消，蓝色加粗边框）与**框选**（按住拖出橡皮筋选择框，与框相交的格子实时高亮，松手并入选区；起点落在已选中格子上时本次框选为**减选**模式），组头部新增「全选/清除选择」按钮——原右上角小勾选框取消，改字入口移到格子右上角的铅笔角标（Tooltip「修改此字」），定位按钮不变。②「确认本组」改为**「确认所选（N）」**：只确认当前选中的字（未选择时按钮禁用；空文字与已确认的字自动跳过并在提示里注明），套用按钮同步改为只作用于所选。③ **已确认的字默认从组里隐藏**（组头显示「可见/总数」并在有隐藏时挂绿色 ✓N 徽标），工具栏新增**「显示已确认」开关**回显（绿色态）；隐藏口径与「只看待处理组」、空态提示联动（全部确认完时提示打开开关查看）。实现要点：框选依赖新公共组件 `widgets/band_select_surface.dart`——格网长在 ListView 里，鼠标拖动时外层滚动的认领阈值（竖直方向 1 逻辑像素）小于任何框选需要的移动距离，常规 Pan 手势在竖直方向永远抢不过列表滚动，因此用 `ImmediateMultiDragGestureRecognizer`（allowedButtonsFilter 限定主键）在**按下瞬间**赢下 gesture arena，点选（移动 <6px，抬指时按命中位置路由：先角标/定位小按钮后格子本体）与框选（实时 ValueNotifier 重绘橡皮筋、命中集合变化才 setState）都自行判定；代价是格子区域按住拖动不再滚动列表（滚轮与头部/边距拖动不受影响），组卡片 key 改用稳定 id（全书版组新增 id 字段）保证成员隐藏后选区/输入框/展开态不重置。本次为 Flutter 端改动，后端版本不变（v66）；flutter analyze 无新增告警，flutter 测试 74 条中 73 条通过（`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次无关）。

## 1.0.0+24

- 墨迹校验**模型化**：自训比对模型（siamese）作为校验第四层上线，char_cls 分类器融合与全书跨页模板库整套设施就位；每一路都经同一快照受控回测定去留。真实效果（第五册受控矩阵，同快照 A 组 1929 字/B 组 1989 字）：已确认字误报率 27.4% → **25.7%**（-1.7pt）、识别错字命中率 82.1% → 81.2%（-0.9pt，门槛内）；明刻本跨书 95.3%（第五册训练的模型全局启用**不伤其他书**）。三块改动：① **墨迹比对模型（verify_pair）**：训练页新增专属卡片（数据就绪门槛=确认字数、导出并训练、激活/停用、AUC 指标）——用你确认过的字导出"墨迹↔字形"图对（正样本=确认字、硬负样本=改过首选的真实错读 + 字形库内易混字挖掘，训练=推理同一条裁字管线），子进程训练双塔网络（128px 二值图 → 64 维嵌入余弦，在线增强只作用墨迹侧）。推理纯 CPU、按字缓存字形嵌入，未训练/未激活时整层自动缺席。**非对称救回**：比对分 ≥0.88（模型强烈认同）才把阈值带下移（更难标红，只救不罚——错读的易混字对比对分多落在 0.5-0.7 够不到线）；对称加权（--pair-weight）保留为标定开关，实测是坏交易已默认 0。首版训练教训（已修）：易混挖掘不设上限时 76% 负样本落在 0.85-0.92 相似度、3% 是 ：/：、人/入 级近孪生对（128px 二值图上不可分=标签噪声），val AUC 卡 0.67；负样本上限 0.90 + 增强收敛（±3°/±2px/十字单像素核）后 **AUC 0.81**。② **char_cls 分类器融合（默认关闭）**：批量校验可取自训候选分类器的 top-K 排名联动阈值带（进 top-3 更难标红/掉出 top-10 更易标红），字不在分类器词表视为无信号（不冤枉生僻字）。实测第五册 3502 确认字/609 类（5.7 样本每类）训练出的分类器只有随机水平（top5 0.68%），融合把误报 +2.3pt、命中仅 +1.0pt——坏交易，CLS_SHIFT 默认 0（完全不触发推理，端点保持纯 CPU）；确认数据积累后在训练页重训、回测 --cls-shift 扫描再启用。③ **全书跨页模板库**：「确认并保存」后自动把该页确认字的墨迹模板（128 画布+骨架+可选嵌入）增量并入 `python_service/verify_templates/<书>.npz`（原子写，每字至多 4 个实例），批量校验时对有模板的字取"与本书已确认同字的最大相似度"参与判定（与本书模板不像 → 升 mismatch；近同刻级雷同 ≥0.96 → 风格降级；硬失败红线不变）——同伴互证从页内扩展到全书，「本书重置为未确认」同步清空。留一页口径回测：救回线 0.93 时误报 -2.8 但命中 -3.0（險/臉类易混字的跨字骨架也能过 0.93，159 个错读被误救），收紧到 0.96 后误报 -0.5/命中 -1.0，随模板库密度增长预期继续向好。「墨迹对照」对话框新增「比对分」与「本书模板」行。**顺手修掉两个既有 bug**：char_cls 数据集在"页级已确认但行/字未确认"的书上 val 集恒空导致训练必败（划分现只对真正产出样本的页计算；96 页页级全确认、仅 14 页有确认字时旧逻辑 val=0 直接 torchvision 报错）；确认字含 Windows 非法文件名字符（实测 / : \）当类目录名崩溃（类名转义 _uXXXX、推理侧对称还原）。回测工具新增 --templates（留一页模板口径）、--cls-shift/--pair-weight/--learned-high/--tpl-strong（各融合层标定扫描）。后端版本号 v65 → v66（Dart 侧同步，重启自动替换旧后端）；后端测试 203 条全过（新增 verify_training/verify_templates 3 条：易混挖掘口径、确认字迭代、模板读写与相似度），flutter 测试 74 条中 73 条通过（tool_export_crowd_tasks_test 仍为本机环境性失败，与本次无关），analyze 无新增告警。

## 1.0.0+23

- 新增**墨迹归类·全书版**：把指定页范围（或整本书）的正文字块按墨迹形态**跨页**聚类——同一字形在全书各页的实例聚成一组（典型如常用字/常见误识字在几十页上反复出现），整组统一改一次字全书生效。入口两处：单页墨迹归类页右上角书本图标（auto_stories）、编辑器「更多操作 → 墨迹归类（全书版）」。设置页可输入起始页/结束页（快捷：整本书/从当前页到末页/当前页前后 10 页），逐页载入标注（带进度）后一次调后端 `/char_clusters_batch` 聚类（前端把块 id 加「页号|」前缀保证跨页唯一，p_b0001 每页都有）。跨页聚类算法：逐页提 HOG+宽高比特征并做与单页完全相同的 complete-linkage 聚类，每页每组（含单字组）压缩成一个原型（均值 HOG+均值宽高比），再跨页按「最近全局组中心且距离 ≤ 阈值」贪心并入——距离矩阵只在页内构建（n≈数百），跨页是原型×组中心的小矩阵，内存随页数线性增长（原型数≈全书字种数），整本书可直接跑（修掉了首批原型互相不可见拆出重复组的问题：空表启动与小块收尾走逐个并入）；某页失败只记入 failed_pages 顶部横幅提示，不中断整批。全书版 UI 与单页版同构（严格↔宽松阈值滑杆、只看待处理组、组内多数文字分布、候选字快选、勾选套用、单字弹窗），另有三处大书适配：大组默认折叠显示前 60 字（展开全部再拉缩略图）、未归组单字（全书只出现一次的字形，批量校正没有杠杆）默认折叠展开也只出前 300 个、字图缩略图按需经新端点 `/char_thumbnails` 裁取（白底 letterbox 正方形 base64 PNG，组滚动到可见时批量拉取，**不整页解码大图**——200DPI 页面整本解码会撑爆内存；后端按连续同页请求缓存解码图）。返回编辑器时带回被修改的页号集合，刷新全书状态标记、当前页在集合中时从盘重载（全书版直接写盘，编辑器内存标注已过期）；未落盘编辑先冲刷再退栈（PopScope 拦截 + 防重入）。
- 墨迹归类**每组新增「确认本组」按钮**（单页版与全书版一致）：组内非空文字全部置为已确认并立即落盘，效果与编辑器「确认并保存」相同——文字/边框转绿色确认态（与编辑器行内确认字同口径），按钮变绿色「已确认」徽标；空文字不参与确认（确认空字会污染训练数据），提示后点缩略图补字。新增 `PageAnnotation.confirmCharsById`：字块置 confirmed 后**级联**——行内全部字都已确认的行升级为已确认，全书所有行都已确认时再级联段落、正文区并置 reviewed（整页绿框、计入首页校对进度与训练数据，与「确认并保存」完全同口径）；部分确认的页保持原状态按临时保存落盘（橘黄框）。单页版的确认经编辑器回调实现（此前防抖中的文本编辑随同一次写盘生效，确认后刷新标记与全书进度）；单页版确认状态不依赖可能被编辑器替换的 CharBlock 实例（文本镜像之外新增确认 id 集合，与既有 `_texts` 同思路）。后端版本号 v64 → v65（Dart 侧同步，重启自动替换旧后端）；后端测试 214 条全过，另新增可直跑冒烟脚本 `test_char_cluster_batch.py`（合成两页图验证：同形字跨页应聚成一组、单页接口无回归、全局组几何容量增长），flutter 测试 74 条中 73 条通过（`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次无关），analyze 无新增告警。

## 1.0.0+22

- 墨迹校验升级为「对齐式特征点比对 + 同字同伴互证」，并按新分数分布重标阈值。真实书页回测（同一书库四本书、同一工具重跑）：已确认字误报率 36.6% → 34.6%，识别错字命中率 80.9% → 81.5%（第五册）、85.7% → 84.4%（第四册）、96.6% → 95.6%（明刻本）；改完字再校验的页面还有确认锚兜底。改动分五块：① **比对前先做指纹式对齐**——类型化特征点对（端点↔端点、分叉↔分叉）经霍夫投票求平移，恒等对齐解释力不足时再搜旋转 ±6°、等比缩放 0.92-1.08 网格取最优；等比缩放不改变字内比例，"未/末"仍可区分（既有边界测试守门）。歪斜扫描与整体比例偏差不再系统性拉低分数，L2 形状分与对照图第④格重叠都在对齐后的几何上呈现（此前只有"分叉质心平移 ±4px"）。② **墨迹预处理补两刀**：笔画宽度归一——刻本墨渗让墨迹比楷体字模粗，粗笔画粘连产生假洞/假分叉（回测归因的 A 组误报主因），现在按距离变换把墨迹收细到字形笔宽（带"细笔画被吃/真实笔画消失即回退"双守卫，只收不加粗）；邻字渗墨按连通域剔除（只保留与字框内部相交的连通域）+ 按墨迹包围盒紧裁后 letterbox（与字形侧同一中心化口径）。曾实现"笔画贴裁切边即跳过校验"的门禁，回测否决后移除——密集刻本 69% 的字笔画顶端自然冒出字框 2-3px，任何贴边判据都会把整页字误跳掉。③ **全封闭字（口/日/田）的 L1 位置层不再整层缺失**：骨架均匀采样点集做同款"对齐+半径内点率"兜底，所有字的分数同权重可比（此前封闭字跳层后权重重归一，分数跨字不可比）。④ **整页批量校验新增同字同伴互证**（刻本同字同雕版，天然消除"楷体字模 vs 刻本风格"的鸿沟）：同页同文字的墨迹骨架两两比对——与同伴"同雕版级雷同"（相似度 ≥0.93 且字形分未到灾难级 0.5 以下）但楷体标红 → 判纯风格差异放行；与同伴都不像而其余同伴仍成簇 → 少数派升级提示；人工确认过的字作为组内基准（与锚不像直接判不符，与锚一致降级）。红线：拓扑硬失败永不因同伴结论翻转（防"同字整组读错互相背书"漏检）。「墨迹对照」对话框新增「同字同伴」信息行（本页同字数、与最像同伴的相似度、调整原因）。⑤ **判定阈值带与识别置信度联动**（识别很确信 conf≥0.95 的字要求更强的结构证据才标红、低置信 ≤0.5 的更容易标红；端点新增 conf 透传），阈值随新分数分布再标定 0.55/0.75 → 0.62/0.80（对齐+收细把正确字分数整体抬高，阈值带上移才保持两侧分离度）。回测工具同步升级：改走整页批量接口（与编辑器「校验本页」同一链路，同伴互证被真实测到），新增 --with-status（衡量确认锚收益）、--dump（A 组误报/B 组漏网样本的四联对照图批量导出）、--mismatch/--suspect/--peer-vs（标定扫描）。消融归因记录：端点/分叉硬失败扩展在 4700+ 错字样本上零触发，已移除；笔宽归一单措施 -2.9pt 误报；同伴互证的同错互证残余使第四册命中 -1.3pt（该书样本页几乎每字都被改过首选、无确认锚可用，生产中确认后再校验时锚会兜住）。已知边界不变："未→末"类拓扑同构、横长比例差仅 15% 的字对仍由人工兜底。后端版本号 v63 → v64（Dart 侧同步，重启自动替换旧后端）；后端测试全过（char_verify 12 → 28 条：新增对齐不变性、封闭字采样兜底、笔宽守卫、渗墨剔除、置信度阈值带、同伴互证规则与硬失败红线），flutter 测试 74 条中 73 条通过（tool_export_crowd_tasks_test 仍为本机环境性失败，与本次无关），analyze 无新增告警。

## 1.0.0+21

- 墨迹校验判定改为**特征点（指纹式 minutiae）主导**，不再让"字形重叠"主导打分；同时**大幅改善墨迹骨架质量**。背景：1.0.0+19 的回测调优曾把三层权重调成"骨架形状重叠 0.5 主导"（当时误报最低），但那是"重叠式"判定——手写/刻本与楷体字形**风格**对不上时形状层拉低总分，与"看结构特征、不看书写风格"的设计相悖；且用户在调试页墨迹对照图上发现骨架与原字差异大（"一"的骨架是波浪曲线而非直线）——细化是迭代腐蚀，墨迹笔画边缘的锯齿/粗糙（墨渗、扫描噪声、刻印波动）会被完整"剥"进骨架，骨架成了"边缘轮廓的复刻"而非笔画中轴。三处改动：① 权重回调为拓扑计数 0.4 + 特征点位置 0.4 + 骨架形状仅 0.2 兜底；② 特征点匹配升级为**类型化匹配**——端点只与端点配、分叉只与分叉配（此前两类混在一个点集里按最近邻配，端点"碰巧"配到分叉上是假匹配，会把结构不同的字虚高成高分），分类型各自算双向最近邻匹配率后按各类型点数加权平均；并加**匹配率归一化**（原始匹配率达 0.75 即视为满匹配）：手写/刻本风格下同类型特征点的匹配率天然只有 0.6-0.8（笔画位置的**风格性**偏移），而识别错字的同类型匹配率在 0-0.4，归一化后风格偏移不再掉分、错字仍然低分。匹配半径维持 7px（放到 9px 会把"未/末"这类横长比例差异也吸进半径、区分度归零；风格噪声由归一化吸收而不是放大半径）。③ **墨迹预处理改为"保结构的边缘平滑"**（闭运算粘断笔 → 膨胀+中值滤波+腐蚀还原：先把细笔画临时膨胀到 3px 以上、中值只平滑边缘锯齿不删笔画、再腐蚀回原粗细——中途曾用形态学开运算，它把"會"字田框内部竖线这类 2px 细笔画整个腐蚀掉、实测每字丢前景 7-10%，骨架直接缺笔画，对照图上"四"退化成一根横线即此，已废弃），毛刺剪枝长度 4px → 8px；**校验画布 96px → 128px**（96px 下刻本细笔画只剩 1-2px 宽，清洗/细化的数值噪声直接吃掉笔画结构；128px 让细笔画留在 3px 以上，匹配半径/剪枝/凝聚半径等参数随画布等比重标定）；**墨迹对照图升级为四联对照（1024×256）**：① 原图裁字——原始扫描图按字框裁切的灰度原貌（识别时看到的那个字，纸色墨色原样保留）；② 墨迹侧（浅灰=二值化墨迹笔画 + 蓝=骨架）；③ 印刷字侧（淡红=楷体字形笔画 + 红=骨架）；④ 整体重叠（绿=两骨架接近处）——四格同一裁切窗口与 letterbox 几何，可逐格对照"原图 → 二值墨迹 → 骨架 → 与印刷字重叠"；**特征点（L1 位置层的实际比对依据）以空心圆圈标在②③④格上**——小圈=端点、大圈=分叉簇质心，蓝圈属墨迹侧、红圈属印刷字侧，两侧特征点的数量与位置对应关系（类型化匹配的对象）一眼可见；对话框随图加宽至 1064。真实书页回测（同一书库四本书、同一工具重跑）：识别错误命中率 81%-97%（骨架保真让错字的结构差异暴露更充分，较骨架丢笔画版本 +2 个百分点），已确认字误报率 36.6%（骨架保真的结构性代价：刻本细笔画与楷体粗笔画的风格差异也更完整地进入比对；其中硬标红 mismatch 由拓扑层驱动、不受平滑策略影响。曾用开运算把误报压到 30.5%，代价是细笔画丢失、骨架失真，已弃用——保真优先）；已知边界："未→末"这类拓扑完全同构、横长比例差仅 15% 的字对落在风格容错与比例信号的重叠区（"末→未"方向仍可区分），由人工兜底。墨迹校验调试页叠加图的对位与拉伸问题同批修复（AspectRatio 锁定原图宽高比 + 字框坐标按显示尺寸换算，此前画布声明页面像素尺寸被父级宽度约束水平压扁、字框坐标系与显示尺寸不一致而错位）；并**修复调试页反复换图测试导致的应用无痕崩溃**（日志确诊：15:03 前端消失、Dart 全局异常钩子零记录、后端进程存活、faulthandler 无致命错误——引擎级 OOM 特征）：调试页每选一张图就全尺寸解码页面位图（桌面 PDF 提取页常见 4000×6000 ≈ 96MB/张），换图时旧位图从不释放，"反复测试"场景内存线性涨满。修复为解码时按最长边等比降采样（ImageDescriptor 先读原始宽高再 instantiateCodec；上限经两轮收紧至 2200px——首轮 3000px 后用户复测仍遇一次无痕退出，结合当时系统事件（同机 Autodesk 程序 c0000005 崩溃、代理服务崩溃、Windows 更新失败）与 flutter_app 无任何 WER 崩溃记录，判定为 GPU/系统层冲突（应用与 8 路识别池同时满载显存），继续缩小应用侧 GPU 纹理足迹至约 29MB/张）、替换与退出页面时显式 dispose 旧位图、叠加画布加 RepaintBoundary（缩放/平移只重绘叠加层，不再整页每帧栅格化）。再次复现（flutter run 调试会话 "Lost connection to device"，死点精确定位在 /verify_chars_batch ok 返回后的结果渲染帧）后又加两道防线：**字块网格分批渲染**（首次只构建 120 个字块，其余点「显示全部」展开——488 个字块 Wrap 与叠加图重建挤同一帧是 debug 模式 JIT 下的高发崩溃点）；**结果渲染前后打点**（"结果已接收/已写入状态/已渲染"三条 app 日志，下次再崩可精确定位死点）；`diag_enable_crash_dumps.cmd` 补注册 **flutter_windows.exe**（flutter run 调试模式的进程名不是 flutter_app.exe，此前转储从未覆盖调试会话，右键管理员运行一次即生效）。后端版本号 v57 → v63（Dart 侧同步，重启自动替换旧后端；v59–v62 为中间态未单独发布）；后端测试 197 条全过（`test_char_verify` 12 条含调整后的未/末边界断言），flutter 测试 74 条中 73 条通过（`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次无关），analyze 无新增告警。

## 1.0.0+20

- **整书识别提速约 2.5 倍（本机实测：同一书库连续识别，单页中位 23.8s → 9.4s、p90 36.5s → 15.0s，272 页零识别错误）**，识别结果与提速前逐字节一致（行/字的识别请求内容与处理路径完全不变，只改调度）。三层并行一起上线：① **Kraken 识别引擎多进程并行池**——以前全书识别只养一个识别引擎进程"一行一行排队读"，CPU、显存、GPU 都大量闲置；现在按硬件自动决定同时养几个引擎（看 CPU 物理核数、显存总量/空闲、单个引擎实测占用，标准预留策略：显存至少留 max(1.5GB, 15%)、CPU 留 1 核、上限 8，本机 24GB 显存/16 核自动开 8 路），环境变量 `OCR_KRAKEN_WORKERS` 可手动指定（1~12）。首页资源条新增"并行 N/M 路"（就绪数/计划数）。② **进程内流水线**——页内"字框切分（CPU）"与"逐字识别（GPU）"原本交替空等，现在按行组成任务链并行执行，且每个引擎进程内部"裁剪/放大/二值化（CPU）"与"推理（GPU）"也重叠起来（后者可 `KRAKEN_PREP_PIPELINE=0` 关闭）。③ **页间流水线**——第 N 页识别期间预发第 N+1 页的请求（App 端 2 页滑动窗口，结果仍严格按页序落盘；后端识别门从"只允许 1 个请求"放宽为 2 槽，第 3 个仍立刻 409 忙等，编辑器手动操作不受影响）。配套改动：调试日志按请求隔离（两个识别请求在途时互不串日志）；模型对比/基线评测（会临时切换全局模型）自动走独占模式，与常规识别互斥避免模型状态互踩；YOLO 版面检测加锁串行（每页仅 ~0.3s 不是瓶颈）；首页 409 提示语义同步。并行数等决策理由都会写进后台日志（如"显存总量 24.0GB、单 daemon 实测 1500MB、预留 3.6GB；CPU 物理核 16 → 8"）。后端版本号 v56 → v57（Dart 侧同步，重启自动替换旧后端）；后端测试 175 → 197 条全过（新增并行决策表驱动 14 条、daemon 池并发/崩溃缩容/排空关闭 6 条、**并行≡串行逐字节等价守门员 2 条**——同一页双路径跑识别结果归一化时间戳后必须完全一致；`test_char_verify` 3 条为改造前已存在的旧失败，与本次无关），flutter 测试 74 条中 73 条通过（`tool_export_crowd_tasks_test` 仍为本机环境性失败，与本次改动无关），analyze 无新增告警。附 `python_service/ab_verify/` 页面级 A/B 工具（基线/并行两腿起独立服务实例对比识别结果与耗时），显存空闲时可随时复验。

# 更新日志

## 1.0.0+19

- 新增**墨迹校验调试页**（首页工具栏「墨迹校验调试」按钮，fact_check 图标，位于切分调试旁）：上传一张页面图片即可完整测试校验效果——**不建项目、不落盘标注**，自动走整页识别（切字+读字）→ 批量墨迹校验 → 结果三视图：① 统计条（不匹配/存疑/匹配/跳过各多少字）；② 页面原图叠加字框按等级着色（红=不匹配、琥珀=存疑、绿=匹配、灰=跳过），支持 8 倍缩放细看；③ 逐字结果网格（每字显示文字、等级色、分数），点击任一字弹出「墨迹对照」对话框（墨迹骨架蓝/识别字楷体字形骨架红/重叠绿的叠加图 + 三层分数 + 拓扑差异明细 + 重新校验）。识别方向三段开关（识别范围/横排方向/竖排方向）与切分调试页同款；后台日志页同样可查。墨迹对照对话框与校验标记色提取为公共组件（`widgets/char_verify_common.dart`），编辑器与调试页共用同一口径。
- 新增**墨迹校验**：识别文字与原字墨迹做重叠比对——把识别出的字用楷体渲染成字形、与扫描墨迹各自细化成单像素骨架后比"笔画的走线与拓扑"（洞数/端点/交叉点计数 + 特征点位置匹配 + 骨架形状距离三层加权打分，指纹式 minutiae 思路），笔画粗细、毛笔风格、断笔缝隙等书写性差异在骨架层被抹平。识别与墨迹结构不符的字在编辑器三处同步标红（画布红虚线框+角标、行卡片文字标红/琥珀、属性面板校验分行），且**自动转为待复核**（needs_review），人工只需看标红的字；已确认/已拒绝的字不受影响。三个入口：① 工具栏新按钮「墨迹校验」（fact_check 图标）一键校验本页全部正文有字块，完成后提示"X 个不匹配、Y 个存疑"；② 单字识别落字后自动异步校验（失败静默不打扰识别）；③ 属性面板新增「墨迹对照」对话框——墨迹骨架（蓝）与识别字字形骨架（红）的叠加图（重叠处显绿）+ 三层分数 + 拓扑差异明细表（洞数/端点/分叉/十字/连通块 墨迹 vs 字形逐项对照）+「重新校验」，改字后可手动刷新。后端新增纯 CPU 端点 `/verify_char` 与 `/verify_chars_batch`（不走 GPU 识别门、与识别任务不互斥，整页数百字约 1-3 秒）；对照字形用随包分发的 LXGW WenKai 楷体（OFL 开源约 24.7MB，装进 python_service/resources/fonts，繁体缺字自动经 OpenCC 转简回退，仍缺则跳过该字）；标点/符号/拉丁字母/多字/空墨迹一律跳过不计分。算法细节：Zhang-Suen 细化为 numpy 手写（不新增 scikit-image 依赖，不动用户 conda 环境）；拓扑分类用跳变数（crossing number）而非邻居计数（否则细化在对角笔画上产生的锯齿会被误判成大量伪分叉）；假洞过滤（刻本墨渗粘连与楷体书法连笔产生的几十像素小洞对称填掉，两侧洞数才可比）；容差随拓扑量比例放宽（复杂字如"觀"洞基数 10+，差 2-3 只是书法波动，简单字差 2 就是"昌→日"级结构错误，硬失败只看洞数/连通块且要求差占比 ≥50%）；特征点匹配前做分叉质心对齐（平移钳制 ±3px，扫描偏移与笔画比例差异分开）。**真实书页回测**（本机书库四本书抽样：紫云斗数两册现代铅印本 + 明南阳堂刊本紫微斗数全书刻本，工具 `python_service/tool_verify_backtest.py` 可随时重跑）：人工改过字的识别错误（B 组，以被否决的识别首选校验）命中率 77%-97%；已人工确认的字（A 组，仅现代铅印本有样本）误报率 30%——即七成确认字免检、识别错字近九成会被标出；标红的语义是"建议人工复核"而非"判定识别错误"，刻本场景（与楷体字形同源）误报应低于现代铅印样本，后续版本可按书选字形库继续压误报。后端版本号 v55 → v56（Dart 侧同步，重启自动替换旧后端）；后端测试 163 → 175 条全过（新增 char_verify 12 条：日/昌/田/目拓扑计数、同字自比对、昌→日双向硬拦截、田/昌同洞数靠连通块区分、未/末同拓扑分差、断笔/噪点扰动鲁棒、跳过逻辑、批量接口、端点冒烟），flutter 测试 70 → 74 条中 73 条通过（新增校验字段序列化往返/旧数据回退 4 条；`tool_export_crowd_tasks_test` 仍为依赖本机 crowdtest1 测试项目的环境性失败，与本次改动无关），analyze 无新增告警。

## 1.0.0+18

- 新建识别任务新增**「创建后手动开始识别」**选项：勾选后新书不自动排队识别——先进书籍里查看和整理页面（旋转/镜像、删页、跨页拆分、手画框、单页识别都可用），再手动开始整本识别。入口两处：首页书卡片的播放按钮（识别失败的书为重试按钮，兼作"跳过已有页继续识别"）与编辑器「更多操作」的「开始整本识别」（启动后退出编辑器回书库看进度，识别中书库照旧拦截再次进入，避免后台逐页写盘与页内编辑互相踩）。配套四处机制改动：① `Project` 新增持久化字段 `auto_recognize`（旧数据缺键读回 true）——手动书不进识别队列、**重启也不被 resumePending 自动续跑**；一经 enqueue（手动开始/拆分后自动识别等任何入口）即翻回 true，此后断点续跑照旧（翻回后有 3 条测试锁定）。② **手动模式的书打开无标注页不再自动跑识别**（此前 `_loadPage` 对无标注页一律"首次打开即整页识别"，浏览即识别会让手动模式名存实亡），改为以空标注进入编辑。③ **空标注不再落盘**：标注文件的存在是整本识别「该页已完成」的跳过标记，手动书里只翻看过的页、只旋转/镜像过的页（`dispose` 冲刷、切页冲刷、变换保存三条路径都加了 `_annotationWorthPersisting` 守卫：有内容/确认过/曾落盘才写）不生成标注文件，整本识别不会把它们误当已完成——旋转过的页由整本识别按新方向直接识别；手动画过框、确认过的页照常落盘并在整本识别中保留跳过。④ 首页进书门槛从"未识别完一律拦截"放宽为**只在识别进行中拦截**：未开始/识别失败的书都可进入查看和编辑（失败书卡片文案与点击行为同步调整，重试改到右侧按钮）；顺带修掉已完成书籍卡片渲染空进度条的小瑕疵（进度条改为仅有进度时显示）。本次为 Flutter 端改动，后端版本不变（v55）；flutter analyze 无新增告警，flutter 测试 70 条中 69 条通过（新增手动标记序列化/续跑跳过/入队翻回与空标注判定 3 条；`tool_export_crowd_tasks_test` 仍为依赖本机 crowdtest1 测试项目的环境性失败，与本次改动无关）。

## 1.0.0+17

- 新增**识别期间阻止系统自动待机**：挂机跑整本书时，电源计划的空闲睡眠一到点会把任务中断（页间落盘、409 忙等、模型预热等间隙累积的空闲也可能触发），现在识别队列整个处理期间调用 Windows `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`（dart:ffi 直调 kernel32，新增 `services/system_awake.dart`）请求系统保持唤醒——传统 S3 与现代待机均适用。范围刻意收窄：只要求「系统保持唤醒」、**不锁定显示器**，挂机时屏幕照常按电源计划熄灭省电；被阻止的只是空闲计时器触发的自动待机，用户手动点「睡眠」仍正常生效。队列跑空（成功、失败或异常退出）立即在 `finally` 中释放，恢复电源计划管理，与「识别完成后关机」衔接：干活时不睡、干完关机。首页资源占用条右侧在识别进行中显示「识别中 · 已阻止系统自动待机」提示。请求/释放走 `RecognitionQueue.keepAwakeHook` 注入点（生产为 SystemAwake FFI 实现），非 Windows 平台与调用失败均为空操作；手动在系统层执行过 `powercfg /requestsoverride` 等强覆盖时以系统为准。本次为 Flutter 端改动，后端版本不变（v55）；flutter analyze 无新增告警，flutter 测试 66 条中 65 条通过（新增识别中保持唤醒请求与跑空后成对释放 1 条；`tool_export_crowd_tasks_test` 仍为依赖本机 crowdtest1 测试项目的环境性失败，与本次改动无关）。

## 1.0.0+16

- 新增**「识别完成后关机」**：适合睡前挂机跑整本识别——识别过程中可随时设置，跑完全部排队的书后电脑自动关机。刻意**不放进新建识别任务页**（新建时往往还没想好要不要挂机），入口放在首页识别卡片的进度条下方：识别中/排队/失败待重试的卡片上出现「识别完成后关机」小开关，随时勾选或取消（关机是队列级选项，任一张卡片上设置都作用于整个队列，所有相关卡片状态同步）。实现要点：① 触发点在识别队列 `_drain` 队列彻底跑空处（`RecognitionQueue._scheduleShutdownIfArmed`）——多本书依次排队时中途不会关机；调用 Windows `shutdown /s /t 60` 安排一次带 60 秒缓冲的系统关机，同时首页顶部出现倒计时横幅（1 秒粒度倒计时 +「取消关机」按钮，取消即执行 `shutdown /a` 撤销），横幅会注明是否有识别失败的书（识别失败的书保留快照等待手动重试，队列已无进展时同样关机，避免整夜空转）；② 关机倒计时期间若又排队了新书（例如点「重试」），自动撤销已计划的关机继续干活；③ 开关与设置均为**内存态、一次性**——触发或取消后自动复位，App 重启后不保留（避免第二天开机用电脑时被残留设置突然关机）；单页/局部识别不走整本队列，不受影响也不会误触发关机；④ 关机命令失败（非 Windows/权限等）时横幅改为显示失败原因与「知道了」，不影响识别流程。本次为 Flutter 端改动，后端版本不变（v55）；flutter analyze 无新增告警，flutter 测试 63 条通过（`tool_export_crowd_tasks_test` 为依赖本机 crowdtest1 测试项目的联调工具，环境缺该项目而失败，与本次改动无关）。

## 1.0.0+15

- 修复日志跟随器 **O(n²) 洪峰缺陷**（排查"识别（分析）阶段应用无痕消失"的关键发现）：`_drainServiceLogLines` 旧实现逐行 `_svcLogTailBuf.indexOf(10)` + `removeRange(0, ·)`，对整段缓冲是平方级——识别 page_002 时后端 `[diag:split]` 逐字诊断喷出 **627 行/秒**的日志洪峰（时间戳显示应用恰在该秒与上一条 15s 心跳之间消失，且重启后同一页正常通过），UI isolate 被 memmove/GC 压死（`backend_console_panel` 注释记载的"Failed to post message to main thread"同类事故在跟随器这层并未设防）。改为：倒序定位最后一个完整换行 → 整段一次 `utf8.decode` + 一次 `split('\n')` → 单次 `removeRange`，总代价 O(n)；另加 8MB 缓冲上限兜底（洪峰超过实时处理能力时丢弃并打 `[follower]` 标记，完整日志已落盘 service_console.log）。同日排查确认：本次识别崩溃**只有应用进程死亡**（后端存活且持续正常服务），与导入阶段两端同死不是同一事件；崩溃无 WER/事件日志/Dart 未捕获异常任何痕迹（疑似外部终止或引擎级崩溃），新增 `diag_enable_crash_dumps.cmd`（右键以管理员运行一次，自动提权）为 flutter_app.exe 与 python.exe 开启 WER LocalDumps——下次再无痕消失时 `ocr\crash_dumps` 会留下完整转储可直接定位死因。flutter 测试 64 条通过，analyze 无新增告警。

## 1.0.0+14

- 新增**大 PDF 导入崩溃诊断日志**（排查"导入 800+MB PDF 时软件无提示崩溃退出"——日志显示该 PDF 三次导入中前两次应用与后端进程同时消失，转换停在中间页且无任何 traceback）：① 后端启动挂钩 `faulthandler`（原生层 access violation/abort 当场把全线程 Python 栈落盘 `logs/faulthandler.log`，专抓"无 traceback 硬崩溃"）+ `dump_traceback_later` 每分钟全线程栈留痕（区分"卡死在某次调用"与"被外部终止"），并记录内存总量/可用量/CPU 数；② `/pdf_to_images` 逐页记录渲染/落盘耗时、进程 RSS、系统可用内存，失败页打印页号 + traceback，`doc` 改 `finally` 关闭；③ 后端 `_Tee` 落盘行统一加 `[YYYY-MM-DD HH:MM:SS]` 时间戳（管道输出不变），uvicorn 访问日志/业务 print 从此可与应用端日志精确对齐（此前服务日志无时间戳，崩溃时刻只能靠猜），应用端跟随器解析时间戳并直接作为日志条目时间（旧版无戳行兼容）；④ 应用端 `pdfToImages` 加 15s 等待心跳并采样 `ProcessInfo.currentRss`（大 PDF 转换可持续数分钟，区分崩溃发生在前端还是后端进程）；⑤ `main.dart` 挂 `FlutterError.onError`/`PlatformDispatcher.instance.onError` 全局钩子，未捕获 Dart/异步异常落 `app_console.log`（证实/排除"闪退=Dart 层异常"）；⑥ 新建任务页在选完文件、复制完成（记文件大小与耗时）、转图完成、入队四个节点记日志。后端版本号 v54 → v55（Dart 侧同步，应用重启会自动替换旧后端使新诊断生效）；后端 `py_compile` 通过，flutter 测试 64 条通过，analyze 无新增告警。

## 1.0.0+13

- 新增**跨页拆分**：左右两个书页合扫成一张图的 PDF/图片（跨页扫描），整书一键拆成单页——编辑器「更多操作」菜单新增「跨页拆分（左右页拆开）」。拆页设置页把窗口内所有页**半透明叠加**成一张图（与全书叠加同一套客户端合成，扫描偏移与贯穿全书的黑色中缝竖带一目了然），拖动橙色中缝线选定位置（点击画布跳线、±1/±10px 微调、右键平移滚轮缩放），并可设**先左后右**（现代图书）/**先右后左**（古籍竖排）决定每张跨页拆出的两页在全书页列表中的先后；确认后逐张调后端新接口 `/split_page`（按中缝比例取整像素下刀，imencode+tofile 中文路径安全）切图。已识别页的标注按中缝**裁剪投影**到两个新页（行/段按矩形中心归属、字块随所属行走避免同一列拆到两页、正文区跨缝时两侧各保留相交部分、几何平移收界、确认状态与 uid 原样保留，`PageAnnotation.croppedTo`）；无标注的页拆分后自动排队整本识别（有标注的页按盘上文件视为已识别跳过）。**拆分可逆**：源页图片与标注文件原地保留成孤儿不被改写，拆分记录存 project.json `split_info`（`SplitInfo`，源页列表/中缝/顺序/输出页号）——拆分页可「恢复拆分前」（原样还原页面列表、清理输出页），也可重拆（叠加与拆分重新基于拆分前原始页面；输出页号由 `splitOutputStartIndex` 推导避开所有输入页号，重拆原位覆盖，弹窗明示会覆盖拆分页此后的修改）。拆分/恢复前把本书从识别队列摘除，避免队列并发改写页面列表与标注。后端版本号 v53 → v54（Dart 侧同步）；后端全量测试 159 → 163 条通过（新增 `/split_page` 4 条：中缝取整与两侧尺寸、单侧输出、非法比例与缺图 400、中文路径真实落盘），flutter 测试 47 → 64 条通过（新增拆页纯函数 16 条：起始页号推导、SplitPlan 左右交错、croppedTo 归属/收界/平移/区段规则/确认状态、SplitInfo 序列化与旧数据兼容，另加拆页设置页真实小图合成冒烟 1 条），analyze 无新增告警。

## 1.0.0+12

- 识字众包流程改用**未确认字**：导出页新增「识字任务包（未确认字，供命迹众包）」，导出 `crowd_tasks/`（含 zip）——只为**尚未确认且未拒绝**的正文单字生成字图与候选（条目带 `for_task: true`），行结构保留全部正文字（已确认字 `for_task: false`、不出图）以便服务器端整书文本重建；页面只需划定过正文主区即可导出（不再要求主区已确认），且不再拷贝整页图与行图，整书导出更快更小（也不再创建空的 pages/lines 目录）。原「正文识字数据包」（只含已确认字，作训练快照/阅读导出）保持不变。配套调整「导入命迹识字共识」：共识文字写回后标记为 `needs_review` 待复核状态（不再自动置为已确认），导出后才人工确认过的字不会被覆盖，新增「已确认跳过」统计；复核仍在编辑器完成，照常「确认并保存」即入训练数据。服务器端同步支持 `for_task` 过滤。
- 识字类导出新增**页码范围**：导出页勾选识字数据包/识字任务包时出现「起始页/结束页」输入（1 基、含首尾，留空结束页=到最后一页），只导出指定页，便于小规模测试与分批分发；配套无头导出工具 `test/tool_export_crowd_tasks_test.dart`（`flutter test` 直接跑导出，用于联调）。
- 修复 `/crop` 在 **Windows 中文路径**下静默丢图：OpenCV 的 `cv2.imwrite` 遇到非 ASCII 输出目录（如「识字」）会静默失败但仍返回成功计数，导致导出目录只有空文件夹、zip 里没有字图。改为 `imencode + ndarray.tofile`（与读取侧 `_imread` 的 `np.fromfile` 对称），写失败时明确报 500。后端版本号 v52 → v53（Dart 侧同步）。
- 修复识字任务包**丢失已保存候选字**：导出时现场 char_cls 候选会无条件覆盖条目候选，分类器未训练时把识别阶段两路分歧保存的真实备选读法（约 17% 的字）抹成空。改为合并保存候选与现场候选（按文本去重、现场优先、过滤单个 ASCII 字母噪声、按分数降序取前 10）。
- 识字任务包候选 **A+B 双轨**：每题强制补足候选——char_cls/保存备选优先，不足 10 个时以机器当前读法兜底补位（排在末位，A+B 同时存在），实测本包 2763 题中 2760 题有候选（400 题多候选、2360 题仅机器读法、3 题原文异常走手写）。App 端会随机打散选项顺序，避免「机器读法固定排末位」被当成规律。

## 1.0.0+11

- 新增**导入命迹识字共识**：首页「导入命迹识字共识」入口（书卷图标），选择命迹管理后台从识字任务批次导出的「共识快照 JSON」，自动按 OCR 项目 ID 匹配书库项目（匹配不到时手动选择），把众包确认后的终字按 `char_uid`（稳定几何哈希，导出时的块 ID 兜底）写回对应页标注的字块——更新文字并标记为已确认，几何与「确认识别框」状态不动，行文本同步重拼，写回走既有原子写（.tmp/.bak）。页标注修订号与导出时不一致时照常写回但逐页警告（UID 匹配仍可靠）；完成后给出报告（共识条目/写回命中/文字被修正/未匹配/缺页/修订号不一致）与逐页日志。闭环说明：OCR 导出「正文识字数据包」→ 命迹 App 用户答题 → 后台按答案分布确认 → 导出快照 → 本功能写回，众包结果回流为训练数据。本次为 Flutter 端改动，后端版本不变（v52）；flutter analyze 无新增告警。

## 1.0.0+10

- 「模型对比测试」新增**识别消融**模式（测试模式选「识别消融（行文字 A/B/C）」），回答"最终识别准确率里，训练的模型和链路里的代码各贡献了多少"：从书库里**人工完全确认过的行**均匀抽样并冻结成评测集（跨训练轮次可比；书库新增校对数据后勾选"重建评测集"可重新抽样），同一批行、同一个当前启用的 Kraken 模型跑三档——**A 裸模型·整行读法**（确认行框直喂整行识别，不过任何切分/修正代码，即模型的"纯血"能力）、**B 像素切分+逐框读法**（纯连通域切框后逐框识别，无标点拆分/错位修复/融合仲裁）、**C 全链路（现状）**。结果页给出每档的字准确率、CER、替换/漏字/多字/**标点错误数**与耗时，**A−B = 切分+逐框喂法的贡献，B−C = 修正代码的贡献**（负数即代码在帮倒忙），附"错字 TOP"（gt→pred 计数，标点混淆一眼可见）与逐行明细（GT 与三档读文对照、按 CER 着色）；每次评测结果自动留档。评测行数可选 50/100/200/300，评测期间识别服务过程日志照常回显。后端版本号 v51 → v52（Dart 侧同步）；后端全量测试 146 → 159 条通过（新增识别消融 13 条：差异对齐与指标纯函数、评测集冻结抽样与确定性复现、三档调用形态——A 不切分直喂/B 纯连通域 n=0/C 走单行全链路——与指标聚合），flutter 测试 46 条通过，analyze 无新增告警。

## 1.0.0+9

- 修复训练页从首页进入（默认数据源「全部书籍（汇总）」）时点「生成数据集并训练」立即报错 `train/datasets failed: {"detail":"project not found"}`、而"训练前检测"却全绿的问题：后端 `/train/datasets` 与 `/train/start` 的入口校验只认"单本书目录"（目录下必须有 project.json），而统计（/train/stats）与预检（/train/preflight）走的是另一套取数逻辑——书库根目录（汇总全部书籍）也接受，于是检测/统计一切正常、真正启动时却被入口挡下。入口校验改为与取数同一语义（`training_service.has_books`：单本书目录或书库根目录都放行；空目录/不存在的路径仍报 project not found），并新增 4 条回归测试锁定该口径（单本书放行、书库根放行且统计可汇总、空书库拒绝、不存在路径拒绝）。后端版本号 v50 → v51（Dart 侧同步）；后端全量测试 142 → 146 条通过，flutter 测试 46 条通过，analyze 无新增告警。

## 1.0.0+8

- 「确认识别框」从"只确认字框几何"扩展为**确认本页全部识别框几何**（正文区/段落/行/字框），并让四层检测训练统计全部认这批框——此前只有字框（char_det）计入，正文区/段落/行的框即使确认过也不进统计，出现"确认过的页数远大于正文区训练数据"的账面差。Flutter 侧 `MainRegion`/`Paragraph`/`LineBlock` 新增 `boxConfirmed` 字段（镜像 `CharBlock` 的既有设计，序列化键 `box_confirmed`，旧数据缺键读回 false）：`markBoxesConfirmed` 统一置位，`markAllConfirmed` 蕴含置位，`resetToProposed` 清除，区域/段拖拽缩放的重建构造补带该字段。后端 `training_service` 新增 `_box_confirmed` 判定（`_is_confirmed` 或 `box_confirmed`），`dataset_stats` 与 `generate_datasets` 的 line_det/paragraph_det/region_det 标签与统计、char_det 既有口径统一改走该判定；段落缺标注时按 box_confirmed 行推断。**文字类门槛刻意不变**：char_cls 与 Kraken 行导出仍要求 status 完全确认——确认识别框只认可几何，未校对文字不会漏进 OCR/分类训练（kraken `_confirmed_lines` 不读该标记，新增 3 条统计口径测试锁定：box_confirmed 计入四检测层且不进 char_cls、proposed 不计、完全确认原样计入）。编辑器进度卡（全书 `_refreshBookProgress` 与本页 `_LayerProgress` 的区/段/行三层）与训练页同口径更新；确认识别框的 tooltip/提示文案同步说明。**旧数据迁移**：旧版确认过的页没有 per-entity 标记，已对书库中 `boxes_reviewed=true` 的 5 页（1789591116071 的 page_037–040、043）按新语义回填 `box_confirmed`（原文件备份 `.bak_boxconfirm_mig`）——实测该书 region_det 10 → 15、line_det 91 → 164、paragraph_det 37 → 62，char_det/char_cls 不变。后端版本号 v49 → v50（Dart 侧同步）；后端全量测试 139 → 142 条通过，flutter 测试 37 → 41 条通过，analyze 无新增告警。

## 1.0.0+7

- 编辑器缩略图新增**"识别未确认"紫框标识**：批量识别完成但从未以任何方式确认的书页（有识别框、`reviewed`/`boxes_reviewed`/`draft_saved` 全为 false），缩略图边框显示紫色并在左侧图例新增"识别未确认"项——此前这批页与"从未识别"的页同为灰框、无法区分，整书里有多少页识别结果在等确认只能逐页翻看。判定口径为 `PageAnnotation.hasUnconfirmedBoxes`（新模型 getter，附 7 条测试：机器识别页判定、确认并保存/确认识别框/临时保存后不算、空标注与无字空行不算、重置为未确认后恢复）。状态流转：翻页/编辑防抖/页面变换的临时保存冲刷会把紫框页转为橘黄框（临时保存）；「确认识别框」「确认并保存」移出紫框（分别并入橘黄框既有行为/绿框）；重新识别产出全新标注后恢复紫框；删除页时三个状态集合同步平移；「本书重置为未确认」后按新口径重新标记有识别框的页（确认弹窗文案同步说明）。打开书籍时的状态扫描（`_loadSavedPageMarkers` 更名 `_loadPageStateMarkers`）复用既有逐页读盘循环，无额外 IO。本次为 Flutter 端改动，后端版本不变（v49）；flutter 测试 30 → 37 条全部通过，analyze 无新增告警。

## 1.0.0+6

- 修复横排模式下新画的单字框全部插到行最前面：新字按阅读序插入（`_insertCharInReadingOrder`）的 rtl 判定读的是**整书** `horizontal_dir`，而不是本页生效方向——整书列序"从右到左"的竖排古籍里按页覆盖成横排（从左到右）的命盘图页，插入逻辑误按 rtl 判读：行尾（右侧）新画的字被当成"排在所有字之前"，无论画在哪都插到下标 0。判读改用 `_pageSettings.horizontalDir`（按页覆盖优先），插入落点逻辑抽为纯函数 `readingOrderInsertIndex`（annotation_hit_geometry）并新增 3 条回归测试（ltr 行尾/行中/行首、rtl 归位、整书 rtl + 本页 ltr 覆盖不误判）。同类误用一并修正：单字识别请求（`_recognizeCharBlock`）、主区重识别后的段落重建（`rebuildParagraphs`）、层级推断（`inferHierarchy`）的横排/竖排方向全部改用本页生效设置；手工新建行（画布拖新行、字框落行外时的兜底建行）补上 `orientation: _pageOrientation`（默认竖排会让横排页的新行在识别回包前按竖排判读/布局）。本次为 Flutter 端改动，后端版本不变（v49）；flutter 测试 27 → 30 条全部通过，analyze 无新增告警。

## 1.0.0+5

- 「本页识别方向」设置升级为**三项可按页覆盖**：排版方向（跟随整书/横排/竖排）之外，新增**横排方向**（从左到右/从右到左——横排时为文字阅读顺序，竖排时为列的阅读顺序，传统古籍从右到左）与**竖排方向**（从上到下/从下到上——竖排时列内文字顺序），与整书设置界面（新建任务页）同一套字段与文案；每项都可单独「跟随整书」（副标题显示整书当前值）。保存后仍走原机制：强制重新识别本页、现有标注被替换。按页覆盖的存储从"pageId→横竖排字符串"升级为"pageId→{排版方向?, 横排方向?, 竖排方向?}"（旧数据自动兼容读取，project.json 键名不变）；`settingsAt` 合成三项后，本页的整页/单行/区域/单字识别、段落推断与后台整本识别全部按页生效（后端接口本就接受 per-request 的 horizontal_dir/vertical_dir，无需改动）。本次为 Flutter 端改动，后端版本不变（v49）；新增 6 条模型层测试（旧格式兼容/非法值忽略/序列化/合成与整书隔离/JSON 往返），flutter analyze 无新增告警。

## 1.0.0+4

- 修复横排单字识别"一个字都不对"（候选全是 ○/口/加/草 这类形近残件）：根因是 CHAT 识别模型**只有竖排域**——kraken 对竖排行会先把条带旋转 90°（字形躺倒）再进网络，模型学的是躺倒字形；v45 把横排切到 Kraken 同链路后，横排行以 `horizontal-lr` 直喂，**直立字形**完全在模型分布外，逐字读法全错（实测横排标题"斗數命盤基本賦性"8 字全错、置信度仅 0.11~0.50；同一批字框改按竖排喂 8 字全对、置信度 0.88~0.9998）。两处修复：① **逐字读法一律按竖排（vertical-rl/lr）当"单字列"喂**——单字框内没有阅读方向，行方向只影响外扩边距取向；横排的正文与候选随之全部救活（编辑器手画/调整单字框的即时识别同样生效）。② **横排跳过整行序列读法**——整行横排无论直喂还是旋转后按竖排喂（横/竖 × 顺/逆时针组合实测）读出的都是乱码、连字数都对不上，且乱码字数会反过来污染像素切分的数量校验（连通域数≠乱码字数 → 网格兜底 → 落回乱码 cuts 框）；跳过后字框由像素切分独立给出（切分器支持期望字数未知 → 纯连通域路径），融合层按既有空序列降级（agree=box），顺带省一半识别耗时。端到端实测同一标题行修复后 8/8 全对（conf 0.93~0.9999）。
- 修复贴边行框整行读空：kraken worker 的行 boundary 沿阅读轴外扩 2px，行框贴到图像边缘（页顶 y<2 / 页左 x<2，或右/下缘贴齐）时多边形越界，extract_polygons 直接报 "outside of image bounds"、该行识别为空（本机横排整行实验一度全部空结果即此因）。外扩与行框自身边缘统一收进图像界内。
- 横排回归测试 3 → 8 条（新增：逐字读法按竖排喂、单行/整页跳过整行序列且正文取框内读法、期望字数未知的纯连通域切分、贴边行 boundary 收界），后端全量 139 条通过；flutter analyze 无新增告警。后端版本号 v48 → v49（Dart 侧同步）。

## 1.0.0+3

- Excalidraw 工作台新增**文字校对面板**（"文字"页签）：逐文字元素列出识别文本（单字/整行标注 + 置信度，低置信红色标记、"仅看低置信"筛选），直接在输入框里改字——改动原地写入场景 text 元素（含宽度重估），保存的 .excalidraw 即为校对后的版本；预览画布同步重绘。后端 stats 新增 text_meta（与场景 text 元素同序的 kind/conf 元数据）。
- 工作台新增**手画文字识别框**：预览工具条切到"画文字框"模式后在图上拖拽框出要按文字处理的区域（格内注释、旋转文字、双行小注等编辑器行数据没盖住的墨迹，此前会被当成图形曲线导出）——框内已有识别字则直接沿用，空框由后端按框单独跑分割 + 识别（LRU 缓存，调整其它参数不重跑）；框内墨迹同时从图形掩膜抠除。文字框（青色）在预览上可见、可一键清除。
- 工作台新增**识别过程查看面板**（"识别过程"页签）：后端按需返回四阶段过程图（① 墨迹掩膜与文字抠除——红=图形墨迹、绿=字框、青=手画文字框；② 直线层与格面还原——蓝=格线、绿=宫格矩形；③ 全部图形元素分类；④ 叠加文字元素框），大区域自动减半采样控制体积；首次打开页签自动附带生成。
- 工作台新增**专用日志**（"日志"页签）：本次生成的完整管线日志（掩膜墨迹占比/极性、抠字框与文字框数、实心块与箭头候选数、直线层分段数与自动线宽、格面还原数与墙消耗、剩余墨迹分类、箭头匹配率），可一键复制；同时照常汇入应用后台日志。
- 文字来源新增**"纯图形"**选项：不含任何文字（配合手画文字框只导出指定文字）。
- 手画文字框可能触发按框识别 → 该情形保守占用 GPU 识别串行门（无文字框且注入数据时仍即时）。回归测试 15 → 18 条（新增：文字框按文字处理并出 text_meta、框内已有字不重识别、过程图返回），后端全量 132 条通过；flutter analyze 无新增告警。后端版本号 v47 → v48（Dart 侧同步）。

- 「框选导出 Excalidraw」重做为**导出工作台**（v2，解决命盘图导出成散乱碎片的问题）：框选区域后弹出"预览 + 调参"对话框——左侧画布叠加渲染检测出的场景元素（扫描底图可开关、透明度可调、可缩放，调试着色模式按元素类型着色），右侧设置面板分组陈列全部导出参数，改参数自动防抖重新生成，满意再保存。统计栏显示矩形/圆/线/曲线/箭头/字数与**墨迹覆盖率**（元素 ∪ 字框覆盖的墨迹比例，导出保真度一眼可见）。设置持久化（记住上次选择）。
  - **文字来源改为默认注入编辑器当前校对数据**（旧版在选区内重跑识别——命盘格内文字被分割切成乱行、读出乱序错字（■/"如状所"），校对成果被丢弃）：注入路径后端不跑识别、不占 GPU 门，调参迭代秒级；仍可选"区域重识别"（后端按 图像+区域+识别参数 LRU 缓存，调图形参数不重复跑 Kraken）。
  - **图形检测重做为分层管线**（旧版对"字框抠洞后的墨迹"直接跑轮廓 + 霍夫，垃圾字框抠烂掩膜后字形墨迹漏进图形层变成随机曲线、格线被越界字框抠掉）：① 实心块预检（墨迹填满轮廓内部才算实心，方框的"洞"不会误判）→ 小块贴线端为箭头候选、大块为填充矩形；② 长核形态学开运算抽横/竖笔画（不受文字/圆弧穿越影响）+ 曲率校验拒绝圆弧碎片 + 共线聚类合并印刷断线 + 平行双线合并（古籍双栏线→单线）+ 端点向交叉线吸附；③ **格面还原**：V 对 × 相邻共同 H 围成的空腔 → 矩形——网格 → 宫格矩形（墙被格面并集覆盖时不再单独出线，无双绘）、独立框 → 一个矩形、T 形交接不吞长线；④ 剩余墨迹只扣"已接受线段"本身（交叉圆轮廓保持完整 → 椭圆可检，v1 已知限制"交叉笔画变折线"修复）→ 细四边形中心线 / 椭圆（张角覆盖拒绝断弧）/ Zhang-Suen 细化 + 最长路径成曲线折线（纯 numpy 实现，补上漏掉的 A(p)=1 连通性判据）；⑤ 霍夫兜底改用并查集共线合并（虚线短划在笔画厚度内抖动也能整线合并）+ 沿线间隙结构判虚线（≥2 个 ≥3px 空档 → dashed）。
  - **新增能力**：箭头识别（实心凸块贴线端外侧 → 线元素 endArrowhead，虚线短划/线中段墨块不误配）、彩色笔画识别（元素 bbox 内 HSV 饱和度采样 ≥30% → 映射 Excalidraw 调色板最近色，还原彩印标注如紫框；可选纯黑/自定义色）、可选嵌入扫描底图（锁定底层，便于对照补绘）、按类型分组（图形/文字各一组，整组选中改样式）。
  - **设置项全集**：文字（来源/字置信度阈值过滤乱码）；图形检测（矩形/圆/直线/曲线/箭头五个独立开关、最小图形尺寸、直线最短长度、曲线抽稀容差、端点吸附、双线合并）；样式（简洁 architect/手绘 sketch/粗糙、线宽自动实测或 1/2/4、颜色模式、标准/手写字体、画布缩放 0.5-2×）；输出（嵌底图+透明度、分组）。
  - 回归测试 5 → 15 条（新增：网格→宫格、关矩形检测保留格线、实心块→填充矩形、箭头、虚线、取色与纯黑模式、底图嵌入、注入数据不触发重识别、置信度过滤、覆盖率），全部通过；flutter analyze 无新增告警。后端版本号 v46 → v47（Dart 侧同步）。

## 1.0.0+2

- 新增「框选导出 Excalidraw」：编辑器右上角"更多操作"菜单新增入口——在页面画布上拖拽框选一个含图形与文字的区域（命盘图、示意图、表格等），自动生成 .excalidraw 图形文件（Obsidian 的 Excalidraw 插件或 excalidraw.com 可直接打开、继续编辑）：方框与表格格线 → 矩形（整张表格网会转成"外框 + 每格一个矩形"），圆 → 椭圆，横/竖/斜线 → 直线（共线段自动合并），格内文字 → 文本元素（竖排逐字按字框位置堆叠、横排整行合并，字号按字高换算）。生成时区域内会重新跑一遍文字识别保证文字最新；已识别文字的字框不参与图形检测（字形不会被误当成图形）；元素位置与原图像素 1:1（区域左上角为画布原点）。已知限制：相互交叉的笔画（如被格线穿过的圆）会作为整体轮廓转成折线，而不是拆出完美的圆/直线——交叉图形建议框小一点分次导出再拼合。新增 5 条后端回归测试（矩形/圆/线检测、文字抠 mask、竖横排文字元素、区域偏移与缩放、场景字段完整性），后端全量 119 条测试通过。后端版本号 v45 → v46（Dart 侧同步）。

- 横排的切字与识别整体换回古籍识别引擎（Kraken），不再使用 Paddle：此前横排是"整行文字用 Paddle 读 + 字框按行宽均分"的简化链路（跳过像素切字、逐字复读和标点拆分，文字候选只能按位置对应整行序列）；现在横排与竖排完全同链路——字框按墨迹连通域紧致切分（贴字形、不再出现跨整行的均分框），每个字框单独再识别一遍与整行读法互相印证融合（两路不一致的字互相进入候选，标点/漏字导致的整体错位可被检出纠正），"字+标点"同框的后检拆分同样生效。误切兜底与错位检测也一并覆盖横排。附带：重识别时传回的历史错位框（有框中心落在行框外）自动弃用并按墨迹重建。注：后端 conda 环境名仍叫 "paddle"，只是环境名不含实际引擎含义。横排回归测试改写为像素切分链路（共 3 条），后端全量 114 条测试通过。后端版本号 v44 → v45（Dart 侧同步）。

- 修复横排行"识别框和文字候选错一位 + 出现极窄识别框"：横排行的字框是按行框宽度均分的槽位，单行重识别时后端会把行框沿阅读轴向两侧外扩到邻近墨迹——行框左端外扩约一个字宽时，整排槽位跟着右移一格（每个字的框都框在下一个字上），编辑器再把手调过的行框还原成用户画的几何后，首字的槽位框就落到了行图外、只剩左缘一条窄竖条（实测横排标题行"斗數命盤"：选"斗"高亮的是图外窄条，画在"斗"上的框对应的候选是"數"）。修复：横排行单行重识别/重新切割不再外扩行框，槽位始终铺在编辑器传入的行框上，与行图、读法逐字对齐（竖排字框贴墨迹、不随行框端点平移，外扩保持不变）。附带护栏：编辑器"重识别本行"传回的历史错位字框（有框落在行框外、宽度明显偏离均分槽位）不再按"保留人工框"原样收下，自动改用引擎均分框重建——已经错位的行直接点"重新识别本行"即可复原，无需先删框。新增三条回归测试（横排行框不被外扩/错位框被弃用重建/正常手调框不误伤），后端全量 114 条测试通过。后端版本号 v43 → v44（Dart 侧同步）。

- 编辑器新增书页级操作（位于标题栏中间区域的书名旁，居中一排五个按钮）：① 旋转（顺时针 90°）/旋转（逆时针 90°）/左右镜像/上下镜像——后端新增 /transform_page 用 cv2 就地改写 PNG（支持中文路径），编辑器端 PageAnnotation.transformGeometry 按同一像素映射同步变换页框/段框/行框/字框（90° 旋转互换行的 orientation），此前已校对的文字与框变换后仍然对齐；页面方向变化后建议重新识别本页。画布与行卡片通过 imageRevision 感知"路径未变但图像已改"（缩略图 FileImage 缓存同步失效）。② 删除该页（红色按钮，确认框）——删除页面图片（仅项目目录内的，连同 _dbg_ 诊断图；外部引用只移出列表）与整页标注（.json/.bak），其后各页标注按索引前移一位（注解按页序号命名），project.json 页列表/进度计数同步更新，已保存/临时保存页集合平移，编辑器停在原位置（现为原下一页）；删空整本书自动退出编辑器。新增两侧映射一致性测试（Python：cv2 像素映射 ↔ 换算公式四种操作逐点核对；Dart：transformGeometry 五条用例含连续四次旋转回原位），后端端点含中文+空格路径冒烟。后端版本号 v42 → v43（Dart 侧同步）。

- 全量审计各层训练数据统计口径（Flutter 进度卡 ↔ 后端 /training/stats ↔ 数据集构建器，382 页真实标注逐层核对：char_det 4992 / line 96 / paragraph 39 / region 10 / char_cls 2625、字类 565，两侧完全一致，正文区统计无误）：修复一处潜在不一致——char_cls 数据集构建器只查字状态、不查所属行状态，部分编辑状态下（字被单独确认而行仍 proposed）训练集会比统计多进字；构建器补上行确认门槛，与统计口径及编辑器规则一致（当前数据下两者恰好相同，无行为回退）。确认：main_regions 为空的 30 页是未在编辑器打开过的机读书页（打开后自动推断层级），非统计丢失；paragraph 后端的"确认段落为空时按确认行推断"兜底与 Flutter 显式确认计数在当前数据下相同。后端版本号 v41 → v42（Dart 侧同步）。

- 修复「确认识别框」后训练数据进度不动：① 保存后未触发全书进度重算（_refreshBookProgress 只挂在翻页/完全确认上），现已与完全确认同样立即刷新；② 单字视图进度卡的 char_det 计数只数 status==confirmed 的字块，box_confirmed 没算进去——char_det 现按"完全确认 ∪ 只确认字框"计数（char_cls 仍只认完全确认）。各层进度对「确认识别框」的正确行为：char_det（单字检测）增加；正文区/段落/单行/char_cls 不变（这些层的确认状态仍是 proposed，需「确认并保存」才计入——字框几何确认不等于行/段/区几何确认）。本次仅 Flutter 端改动，后端版本不变（v41）。

- 段末标点独占一列不再丢：整页/段落识别时句号列自动成行并入段落，无需手画框。行检测（OpenCV 兜底分列与投影条带两处）各加一道"标点尾列补捞"——地板阈值（x_proj>2）再切一遍，补捞与存活列不重叠、条带内墨迹"少而小"的条带：≤3 个面积 ≥8 的连通块、每个都只有标点大小（高宽 ≤ 版高的 1/45）、整体跨度 ≤4 个标点高（散落半页的孤立点不算），正常文字列墨迹量/组件数远超此限不会误捞。标点列内的 y 切分同步放宽（低阈值/最小段长/紧致下限都是按正文行标定的，照用会把 8~15px 的句号行整个滤掉），投影条带路径的空条带行框改按面积 ≥8 的连通块取范围（带内散落噪点不撑大行框）。前端段落聚类补一条规则：标点尾列（≤2 个字块、高 ≤2.2 字高）跟随上一段——短列断段规则原本会把它切成自成一"段"。端到端实测 page_039：分列新增 (263,159,15,16) 单字行（句号列），正文/夹注列原样；新增三条回归测试（句号列成行/噪点不撑大行框/散落标记列不误捞）。配合 v40 的空读法行兜底，识别文字可能直接读出句号。后端版本号 v40 → v41（Dart 侧同步）。

- 修复整列只有一个标点时单行识别报"Kraken 对该行识别结果为空"：孤立小墨迹（。，、）的行识别输出空文本，kraken_segment_line 此前对空结果一律报错（防模型失败清空原行的保护），人工为"只有一个句号的列"画的识别框永远建不起来。现在先查行框内是否确有墨迹：有 → 合成一个覆盖行框的占位字符走正常管线（n=1 的像素切分槽位框不可信被弃用 → cuts 条带框收紧到墨迹成贴字形框，逐框识别再试一次读法，正文可能直接读出标点，读不出则留空由用户补字）；无墨迹（误画空框/模型失败）仍报错、编辑器保留原行数据。新增两条回归测试（有墨迹建贴字形框并读出句号 / 无墨迹仍报错）。后端版本号 v39 → v40（Dart 侧同步）。

- 编辑器新增两项校对辅助：① 行内异常高字框醒目红标：高度超过本行中位字高 18% 且至少高出 5px 的字框（与后端标点拆分复查阈值同口径——"字+标点同框/两字粘连/单字部件未并"这类需要人工复查的高框）在页面画布（3px 纯红描边，色值 0xFFFF1744，区别于彩虹红）与行卡片（裁切图 2.4px 红描边、字块列表 2px 红边框）统一红色提示；同框判定按 lineId 分组取中位、行内不足 3 框不判定。② 「确认识别框」（工具栏虚线框图标，位于"临时保存"与"确认并保存"之间）：只确认本页字框几何——新增 CharBlock.boxConfirmed / PageAnnotation.boxesReviewed（JSON 字段 box_confirmed / boxes_reviewed），char_det 检测训练（后端训练服务与编辑器训练统计）读这些框，char_cls 分类训练、校对进度、绿框门槛仍按「确认并保存」的完全确认口径不受影响；「确认并保存」蕴含字框确认，「本书重置为未确认」一并清除。适合"框都校完了、字还没逐个过候选"的中间状态：先固化切分成果。注意：手动 YOLO 导出（导出页）仍要求整页完全确认，box_confirmed 只进训练服务链路。后端版本号 v38 → v39。

- 修复『需』仍被切成两框（v37 的补充：真实识别链路的另一半机制）。v37 只堵了"高框被拆"路径（诊断模拟所见）；真实链路里 Kraken cuts 本身就把『需』=雨+而 各切一格（行读法把它读成"重焉"两个字）、收紧后得到两个**矮**框，行内合并本应把两半并回一个字框，但"横画类字保护"（任一框宽度 ≥65% 中位字高即跳过合并，为防『一，』误并而设）把两个**全宽**的需半框也挡在了合并之外。修复（_merge_adjacent_punct_fragments）：宽度保护由"任一宽即跳过"改为"一宽一窄才跳过"——两框都占满字宽、都只有半字高（≤0.7×中位）、紧挨或重叠、合计 ≤1.1×中位字高时判为单字上下部件被切开，并回一个字框；两个独立的横画字（间距 >15% 中位）与『一，』（宽+窄）均不受影响。端到端实测（page_038 该列现有字框全集）：(905,666,31,18)+(905,681,31,21) → (905,666,31,36)，同列另一同形态字形同样并回，42 框 → 40 框、「一」等其余框原样；新增 cuts 半框并回/一，保持分离/独立横画字不并三条回归测试。后端版本号 v37 → v38（Dart 侧同步）。

- 修复『需』被切成上下两个识别框、各读成一个别的字（实测「需求」读成「重焉求」）：『需』=雨+而，两部件在本印本里不相连、中间有横向留白，字框略高于同行中位（≥1.18×）触发"字+标点/两字粘连"复查时，框内恰好两段**都是字宽**的墨迹（雨段、而段）被当作两个粘连字拆成上下两半。新增单字部件留白判别（_PUNCT_SPLIT_GLYPH_SPAN/_GLYPH_RUN_MAX）：恰好两段墨迹、两段都达字宽（≥主字段墨迹宽 65%）、**都只有半字高**（<0.7×中位字高）且合计 <1.5×中位字高 → 判为单字部件留白不拆并写明原因。真正的两字粘连至少一段是整字高（粗『一』+字并框主段 31≈0.78×字高）或合计 ≈2×字高（工/作并框 70px），均不受影响——既有"两字粘连拆开/粗『一』独立成框/『一』+标点拆分"用例全部保持通过。附带：切字诊断的条带收紧模拟改用标点拆分**前**的框（与真实链路"先收紧、后拆分"同序），消除拆分碎片被模拟成"无墨迹归属→保留条带"的误导性 [diag:wide-box] 日志。后端版本号 v36 → v37（Dart 侧同步）。

- 修复区域/单行重识别后夹注列"识别框画不全"（框外字连字框都没有）：夹注小字列的检测行框常只盖住中段——夹注字距可大于列宽，行框外扩的 0.85×列宽空白容限被字距空白挡停（实测註四列墨迹 y129..1553、行框只到 y618，顶部"註四：風，《詩經》《國風》。騷，《"约 15 字留在框外且字块层完全未检出）；区域重识别整行替换后这些字没有任何字框。修复：用户画的区域框即行归属意图——/segment_lines_in_region 在检测之后、识别之前把与区域相交的行沿自身列带扩到区域内墨迹（segmenter.extend_lines_to_region_ink，只扩不缩、墨迹以区域阅读轴边界为限、行带不变不吃邻列，决策写 [diag:region-extend] 日志并绿色高亮）。端到端实测该列：行框 (268,662,27,261) → (268,127,27,1428)，切字 33 → 48，顶部段新增 16 个字框；区域外的行原样。后端版本号 v35 → v36（Dart 侧 _expectedBackendBuild 同步）。

- 切字过程诊断的切分日志补全"识别框为什么是这个形状"的链路（定位『一』框宽问题实测：该行像素切分数量不符走网格兜底 → 识别改用 kraken cuts 条带框（宽恒=行宽）→ 逐格收紧，此前的诊断只到切分为止，后半段黑箱）。新增四类信息：① [diag:box-src] 每行字框来源决策（连通域紧致框 / 弃用兜底改用 cuts 条带框）；② 兜底行模拟识别链路的条带收紧（把切分框沿行宽展开成条带、跑同一个 _tighten_boxes_to_ink），黄框画进切分过程图并标注框号，模拟框数随响应返回（tighten_sim_count），弹窗信息区新增"识别框模拟"说明行；③ _tighten_boxes_to_ink 逐格决策日志——保留条带写明原因（无墨迹归属 / 疑似噪点，含墨迹尺寸与噪声阈值），横画豁免收紧单独成行（条带框 → 贴墨迹框 + 判据数值），行级汇总（格数/收紧/保留/行墨宽跨度/噪点宽度阈值），真实识别（/segment、/segment_region）的 debug_trace 同步获得这些行；④ [diag:wide-box] 宽框体检：比同行中位宽 30% 以上的框量出框内墨迹（含"矮而宽=横画类字"判别）并写明成因。切分日志面板着色同步：保留条带/宽框/弃用兜底橙色、横画收紧绿色；图例补"黄=识别框模拟"。端到端实测 page_038 该列：日志直接给出"框#30 条带 43×26 → 横画收紧 30×3（墨迹 3px 高、宽 30 ≥ 行墨宽 65%=27）"，标点空位格则以 [diag:wide-box] 标注为未收紧条带框。

- 修复『一』的字框比同行其他字宽一截（宽度为整列行宽、高度正常）：Kraken cuts 条带框收紧（_tighten_boxes_to_ink）时，"墨迹高 <6px 疑似噪点"的保护只看高度——横画类字（一/二/〇…）墨迹天然只有 2~5px 高、横向却占满大半行墨宽，被当噪点跳过收紧，原样保留恒为行宽的 cuts 条带框（日志实测 page_038 该列：『一』框宽 43px vs 同行中位 29px，其墨迹实为 30×3 的横画，宽度与邻字墨迹相同）。收紧守卫补上宽度判别（与标点拆分/紧挨合并已有的口径一致）：墨迹宽度达行墨宽 65% 时即使很矮也照常收紧，又矮又窄的仍按噪点保留条带框。端到端实测：修复后该行字框宽度中位 29、最大 31，『一』收紧为 30×3 贴墨迹框；新增横画收紧与窄墨点保留两条回归测试。后端版本号 v34 → v35。

- 修复『一』的框仍然很大（日志实测：粗笔画『一』墨迹高 23、主字段高 31，超过标点段 62% 上限，被"疑似多字粘连"保护逻辑误拒、整框 59px 保留）：横向已占满字宽的段（横画类字）是字而非标点/粘连——不再按标点高度上限拒绝，独立成框（高度仍须在正常字高范围内，真正的异常高段照旧拒绝）。附带行为统一：超高框里是两个整字时现在也正确拆成两框（此前保守不拆）。

- 修复『一』字的识别框明显比其他字大很多（一框包住"一+紧挨标点"）：上一轮的紧挨标点合并按"框高远小于本行中位字高"判定标点，而『一/乙/二』这类横画字墨迹同样很矮、又常与标点紧邻，被误当成标点合并进大框。判别信号补上横向墨迹宽度——横画类字占满整列宽、标点（。，；）紧凑窄小：拆分分组与行内合并都改为"横向宽度 ≥ 主字段墨迹宽（或中位字高）的 65% 视为字、独立成框不参与标点合并"；『一，』同框正确拆成三个框，『；』合并行为不受影响。

- 单字竖列（行卡片）新增"重新切割本列"功能（剪刀图标，位于"重新识别本行"旁）：丢弃该列现有字框几何与文字，对行框做全新拆字 + OCR——走完整自动链路（行框外扩到整列墨迹、连通域/网格切分、标点拆分与紧挨合并、两路读法融合），整行替换并保留段落归属与阅读序。与"重新识别本行"（保留既有字框、只重新填字）互补：整列切分错乱时推倒重切，个别字调框后重读用原按钮。处理中显示转圈并防重复触发，完成后提示切割字数。

- 修复『；』被拆成两个识别框（上圆点一框、下钩一框）：分号/冒号等标点本身由分离墨迹组成，"字+标点"同框拆分时各段独立成框、行内已有的紧挨小框也无人合并。两处修复：① 拆分时紧挨的非主墨迹段（间距 ≤ 主字段高的 20%）合并成一块——『字；』拆成"字"+"；"两框而非三框，字本身永远独立；② 新增行内后检合并：两个都远小于本行中位字高（≤0.62×）且沿阅读轴间距 ≤15% 中位字高的相邻框合并为一个贴墨迹框（同一标点的部件间距远小于两个独立标点的间距，。，不会被误并），合并后仍不超过一个字高。

- 修复后端控制台窗口报 "'…自动加引号，cmd' is not recognized" 并执行乱码命令的问题：批处理里的中文注释被 cmd 按错误编码（GBK/UTF-8 混淆）解析，注释残片被当成命令执行。两个批处理（run_backend_console.cmd / open_console_viewer.cmd）改为纯 ASCII（文件头注明原因），中文信息由后端自身输出（chcp 65001 下正常显示）。端到端实测：start 拉起批处理 → 控制台窗口打开 → 后端监听 1288、日志落盘，taskkill /T 清理无残留。

- 启动页（"进入 OCR"按钮下方）新增"在独立控制台窗口运行后端"开关：控制是否以 ComfyUI 式独立控制台运行（实时显示启动、端口与识别日志；关闭则后台静默运行，日志仍落盘且可在主页工具栏查看）。设置与主页工具栏的开关联动，落盘 app_ui_settings.json，重启应用生效。

- 后端控制台改为 ComfyUI 式：后端进程直接运行在独立控制台窗口中，从进程诞生起原生实时打印全部输出（conda 启动、端口选择、模型加载、uvicorn 访问日志、识别全程与诊断日志）；后端退出/崩溃后窗口保留现场（提示 + 按键关闭），关闭窗口即停止后端（Ctrl+C 走 uvicorn 优雅退出）。此前"管道启动 + PowerShell tail 副窗口"方案失败的双重根因（实测定位）：① Dart 对含空格参数自动加引号，cmd 的引号剥离规则遇到 &&/> 等元字符失效，复合命令整串被当文件名执行——窗口开了命令却立刻失败；② start 的标题不含空格时不加引号，会被当作命令本身。现改为 start 只调裸批处理文件（run_backend_console.cmd / open_console_viewer.cmd，标题/编码/环境变量在批处理内设置，已实测 exitCode=0 且正常执行）。应用端新增 service_console.log 跟随器（后端 tee 落盘、stderr 行带前缀），内置控制台面板、启动失败诊断（末 15 行改读日志文件尾部）、模型对比页过程日志全部照常；停止改为按端口 taskkill（窗口模式无进程句柄）。主页工具栏可切换"在独立控制台窗口运行后端"（默认开，重启生效；关闭则回到无窗口管道模式）。

- 新增独立 CMD 后台日志窗口：应用侧日志（[app] 启动过程与端口跟随、[http] 进入 OCR/识别的每个请求、[trace] 后端诊断、手势日志）落盘 python_service/logs/app_console.log，后端 stdout/stderr（端口选择、模型加载、uvicorn 访问日志、识别全程与诊断日志，含会话头"服务启动 时间 build pid"）tee 到 logs/service_console.log；独立 CMD 窗口用 PowerShell Get-Content -Wait 同时实时滚动两个文件，启动时自动打开（主页工具栏终端图标可手动开关，设置落盘 app_ui_settings.json）。后端起不来、进不去 OCR 时完整启动过程与端口信息均可在此窗口直接查看，两个日志文件也可整份发回排查。

- 服务基准端口由 8765 改为 1288：8765 落在 winnat 端口保留段的常见区间（实测本机连续多日被保留段覆盖，两次整段吃掉 500 个候选端口），1288 远离这些常见保留段（当前保留段最小从 2823 起）。仍保留逐级避让（1288-1787）与系统分配兜底；后端版本号同步升级（v34），打开应用会自动替换运行中的旧版服务。

- 修复"no available port in 8765-9264"导致软件无法进入 OCR：Windows 的 Hyper-V/WSL/Docker（winnat）开机随机保留大段 TCP 端口（netsh interface ipv4 show excludedportrange 可查），实测本机 8672-9371 六段连排被保留，把服务自 8765 起的 500 个候选端口全部覆盖——bind 报权限不允许（非被监听，netstat 查不到），启动直接退出。修复：固定段整段不可绑时让系统分配空闲端口（bind(0)），实际端口照常写入 service_port.txt，Flutter 端既有逻辑按文件跟随；日志会提示保留段排查命令。不重启系统的应急办法（管理员）：net stop winnat && net start winnat 重摇保留段后重开应用。

- 修复行卡片拖拽字框右上角顶点时"其他顶点跟着偏移、框越调越大"（手势日志实测定位：拖右上角期间固定底边从 487 下移到 546）：右上角缩放分支此前对顶边和高度各自独立取整，显示比例把指针坐标映射到半整数（0.5）时两处同时四舍五入进位，y+h 每个指针事件 +1px 且只增不减——一次 2 秒的拖拽累计下移 59px；拖得短的框漂移小、看似正常，长拖才暴露，故只有"个别字框"出现。修复为固定边（左边/底边）直接沿用整数原值、只对拖动边做一次取整（与页面画布 resizeRect 的锚定原则一致），并抽取为 AnnotationHitGeometry.resizeTopRightRect 加半像素指针流回归测试（200 事件底边零漂移）。本次为 Flutter 端改动。

- 单字框拖拽/缩放加入手势诊断日志（后台控制台 [app] 通道）：行卡片与页面画布各自记录手势开始（字块 id/order、lineId 及其与所在行卡片的匹配情况、字框与行框矩形、手柄）与结束（原矩形→终矩形、提交与否）；字块几何更新若未命中标注列表（画布持有的字块实例已被重识别/重建替换，改动被静默丢弃——"个别字框拖不动"的头号嫌疑）按 id 节流打出红色错误。复现问题后把 [手势] 开头的日志行发回即可定位。

- 修复详细视图（行卡片）里拖拽单字框右上/右下顶点时"其他顶点不跟手、框调不动尺寸"：字框的彩虹矩形绘制用了实时拖拽预览（_resizing 替换），但橙色选中框与两个缩放手柄的绘制源仍是 widget.selected——几何只在松手时提交，拖拽期间手柄一直钉在旧位置，视觉上框在动、顶点不动/错位。选中框与手柄改为同样的实时预览替换（移动手势同步修复）。页面画布无此问题（其几何逐帧提交）。本次为 Flutter 端改动，识别服务无变化。

- 修复区域/段落重识别后"文字照不全"：区域过滤（filter_result_to_region）此前把行内"中心落在区域矩形外"的字直接裁掉——行被外扩成整列后，用户的段落框只盖住列的一部分时，区域外的字全部消失。改为保留整行（行是完整的阅读单元，保留条件仍是行中心或任一字中心在区域内，只是不再裁字）；跨段落边界的列可能与区域外旧行短暂并存重复内容，可见可删，优于静默丢字。结合上一条（行框几何跟随外扩），单行/段落重识别后行框、字框与识别内容三者一致且照全。

- 行框几何同步为外扩后的实际识别范围：行框外扩（识别与切字用扩后的整列框）此前仍按检测原值返回行框，编辑器里出现"框只裁了一小段、字框却铺满整列、日志读出全部文字"的视觉割裂。现在整页识别与单行重识别的行框都更新为外扩后的范围（扩不动时即原值），行框、字框与识别内容三者一致。

- 修复边栏竖排网址/边注列被切成"一框包住整列"的问题（实测 1165px 列出现 867px 单框，日志完整还原成因）：该列像素切分与期望字数不符（11 vs 9）→ 网格兜底被弃用 → 改用 Kraken cuts 重建 → Kraken 对竖排拉丁字的切分退化成少数大格 → 条带收紧把格内全部墨迹段吸进同一框；超高框拆分又因"墨迹段数 7 不在 2..3（主字段+至多两段标点）"拒绝处理。现在达到本行中位字高 2.5 倍的巨框改为按墨迹白色空隙逐段拆开（段与段之间的纯白区间是字/拉丁字符的天然分界），不受结构约束——实测该 867px 巨框拆成 7 段，全部回到正常尺寸。同时把行框外扩接入整页识别（/segment）：此前仅单行重识别外扩，整页检测的行框取自检测字框的包围盒，检测漏字的列（註五双行小注）整段行文仍留在框外少读 4 字；现整页识别与切字同样使用外扩后的行框，行框几何仍保持检测原值。

- 切字过程加入完整日志：/debug_char_split 采集切分链路逐行决策（行框外扩→连通域分块→碎片合并→数量校验兜底→标点拆分），标点拆分的每个"未拆"分支都写明原因（墨迹段数不在 2..3、主墨迹段高不像正常字、单段墨迹且无细腰、疑似多字粘连、拆后只剩一框等）；诊断弹窗新增日志面板（警告行橙色、成功行绿色，可一键复制），并落盘为 <页名>_dbg_trace_<时间戳>.txt 便于整份分享；kraken_bridge 的识别决策日志（行框外扩、标点拆分、错位检测、两路融合）同步汇入 /segment、/segment_region 返回的 debug_trace——真实识别与诊断弹窗的失败都可追溯。实测用户页最左列的日志直接给出"切分不对"的根因：52 个连通域 vs 期望 21 字、主墨迹段高 25~28 不像正常字（参考高 60）——该列是双行小注（两行半高小字交错），单列拆分模型不适配，需后续按双行小注单独支持。

- 修复"切字过程"诊断弹窗只显示第一次打开的那一行的切分图片的问题：诊断图文件名固定（每次覆盖写入），而 Flutter 的图片缓存按路径钉住旧图——换行重开永远显示第一张。现在文件名带时间戳（新路径即新图），写入前自动清理本页旧诊断图，弹窗同时新增二值化极性（正常/已翻转）、行框外扩（传入行框 vs 外扩后行框）、标点拆分数等链路信息，图例补充绿粗=外扩后行框、绿细=传入行框、紫=被拆分的同框框。

- 修复单行识别"识别不全"的主案例（实测页最左列连续墨迹 1421px、行框只盖住中段 581px，仅识别出 21/25 字）：行框沿阅读轴的外扩此前带"单侧至多约 1.2 字高"的保守上限，只够捞回一两个字；而"白色区间超过约 0.85 字高即停"的规则本身已能界定本行墨迹连续段的真实边界（行末空白/段首缩进/缺字空位远大于字距），上限删除后外扩自然扩到整列（该页实测 581→1421，且其余本就完整/独立的小注列不误扩）。外扩阈值同步从 0.75 放宽到 0.85 字高，给密排小字列的字距留足余量。

- 修复单行重识别"识别不全"与白字黑底页整页失效两类问题（在"切字过程"诊断中定位：整页二值化墨迹在暗底/反色页上极性会反转；偏短行框把行首尾字切在框外）：① 整页二值化墨迹加极性自检——正常文字页"墨"永远是少数（含栏线通常不到三成），白字黑底（阴文页/暗底扫描/夜间模式截图）时 OTSU 会把"墨"切到背景一侧、文字反而成了"白"；墨占比过半即翻转掩码，转为识别白色文字。② 单行重识别的行框沿阅读轴外扩到紧邻墨迹——人工画/调过的行框偏短时行首尾字整字落在框外，识别与切分都看不到；外扩沿轴逐行找墨迹，遇到超过约 3/4 个字高的纯白区间即停（白色区间的高度正是字距的直接量度：字与字之间只有小空隙，行末空白远大于它），单侧至多扩约 1.2 个字高；竖排行框横向不越列、横排行框纵向不越行，不会吃进相邻行；识别与切分都用扩后框，行框几何仍返回传入原值。③ 数量校验的网格均分兜底改为优先在"纯白区间"（整行几乎无墨的连续段）中心下刀——墨迹残缺/笔画稀疏时投影谷值可能落在字内留白上、把一个字拦腰切开，纯白区间才是字与字的真实分界；找不到纯白段仍退回投影谷值。"切字过程"诊断（/debug_char_split）同样先外扩再切分，诊断所见即识别所得。本次为识别服务（python_service）改动，Flutter 端无变化。

- 标点同框拆分补两处漏洞（实测「如」「因」「者」与逗号同框、「又」上下各带一个标点三形同框仍然出现）：① 行重识别会把该行当前字框原样传回后端"保留框几何、仅重新填字"，上一轮自动切分留下的"字+标点"合并框被当作人工几何原样保留、随一次次重识别代代相传——这是漏拆的主通道。现在传入的既有字框同样做超高后检拆分：保留的是人工校对成果，不保留机器的合并错误；框内只有一个字形的框拆无可拆、几何纹丝不动。② 判定收紧并迭代：超高阈值从中位字高的 28% 收到 18%（下限 8px 收到 5px，原阈值漏掉贴得紧的小标点），标点段高度上限改为相对框内主字段本身判定（刻本标点再大也不到半个字，两个整字粘连则彼此相当、天然分开），并做多轮拆分（至多 3 轮）——一行同框框偏多时中位基线会被它们抬高、边缘同框框第一轮够不到，拆掉最高的几个框后基线回落到真实字高，下一轮自然捞出。

- 修复经常把文字和上方/下方标点画进同一个识别框的问题。新增行内超高字框的后检拆分：以本行中位字高为基线（取中位数而非平均数——同框污染框本身会拉高平均值，中位数对单个离群值免疫），凡沿阅读轴高出中位字高 28% 且至少 8px 的字框，回看框内墨迹沿阅读轴的分布——恰好一段"正常字高"的主墨迹（0.65~1.35 倍中位字高）之外还贴着至多两段"标点高"的小墨迹段（≤0.62 倍且 ≥4px），即判定为标点入框，按墨迹段拆成独立字框：字框回到正常高度，标点框贴标点墨迹；标点与主字墨迹相连没有空档时，改找"墨迹细腰"（行墨迹量骤减到主字行中位数 35% 以下的窄行）作为分界。小段接近整字高（疑似两个整字粘连）或主段不像正常字时不拆，交回原有逻辑，避免误伤。同框的两个源头同步修复：连通域切分的碎片合并此前会把紧贴整字的短小组件（正是标点）并进字框——现在并入后组高不超过一个字高的 1.1 倍才并，"三"这类笔画分离的字不受影响；Kraken cuts 条带框收紧时按中心归属把标点墨迹段吸进相邻字格产生的超高框，由新后检统一兜住。拆分在逐框识别之前执行，拆出的标点框有自己的框内读法（正文/候选两路融合自然对齐）；行首拆出标点后字框数比整行序列多一，会被错位检测逐位对照误判为 -1 错位而弃用拆分框重建 cuts——刚拆过标点的行跳过错位重建（拆分框已锚定真实墨迹段）。人工画/人工调过的字框几何权威，永不自动拆分。本次为识别服务（python_service）改动，Flutter 端无变化。

## 1.0.0+1

- 修复点字快改浮层"打开后原字全选"实际不生效的问题：浮层打开后键盘焦点其实一直留在页面上（点字那一下的鼠标按下会先把焦点收回页面，这是 Delete/Esc 快捷键依赖的机制，而浮层自带的"自动聚焦"在这种局面下会被系统直接忽略），输入框从未真正拿到焦点——原字不高亮、直接打字也进不去，必须再点一下输入框才行。现在浮层打开后会明确把焦点交给输入框，原字立即呈选中状态，直接打字（或打拼音选字）即可整体替换，与修改单字弹窗行为一致。

- 修改单字弹窗打开时自动全选输入框里的原字：直接打字（或打拼音选字）即可整体替换，不用先手动删掉旧字再输入——与点字快改框的行为一致。

- 修复墨迹归类里点开单字改字时，用拼音输入法打到第二个字母就被打断、没法继续打字的问题：改字框限定了最多两个字符，Windows 上这个限制会把输入法正在打的拼音串也当场截断（拼音还没选字就超了两个字母），输入法组合被打断后就像"卡住打不了字"。现在拼音组合期间不截断，选字上屏后再截到两个字符，拼音打满整句也能正常选字。本次为 Flutter 端改动，识别服务无变化。

- 修复墨迹归类里点开单字改字时，用拼音输入法打到第二个字母就被打断、没法继续打字的问题：改字框限定了最多两个字符，Windows 上这个限制会把输入法正在打的拼音串也当场截断（拼音还没选字就超了两个字母），输入法组合被打断后就像"卡住打不了字"。现在拼音组合期间不截断，选字上屏后再截到两个字符，拼音打满整句也能正常选字。本次为 Flutter 端改动，识别服务无变化。

- 修复翻页时崩溃退出（"Looking up a deactivated widget's ancestor is unsafe"）：详细视图每个字块的呼吸闪烁高亮组件 _LocateFlash 把 AnimationController 声明为 late final，从未高亮过的字块（绝大多数）在 build 期间从不触碰该字段；翻页拆行卡片树时 dispose() 里的 _controller.dispose() 反而成了对该字段的第一次访问，当场才惰性构造 AnimationController(vsync: this)，其内部经 TickerMode.getNotifier(context) 对已处于 unmount 的元素做 InheritedWidget 祖先查找，断言直接抛错——每页数百个字块同时被拆，批量触发导致应用异常退出。现在控制器在 initState 中立即创建（此时元素处于 active，祖先查找合法），dispose 只释放已创建的实例。实机（382 页书籍、详细视图）连续/快速翻页 60+ 次验证：修复前同样的操作在日志中反复出现该异常，修复后 0 次。

- 修复翻页时偶发崩溃退出（"Looking up a deactivated widget's ancestor is unsafe"）：详细视图行卡片的自动定位滚动（墨迹归类「定位」后把目标行滚到视口上部的 Scrollable.ensureVisible）持有的行 id 在翻页后残留，而翻页会让行卡片树经历多轮拆建（换图清空 GlobalKey → 标注替换 → 图片解码完成后重建），残留 id 在这个窗口里对已停用的元素做祖先查找即崩。现在换页时同步清除定位目标行与闪烁字块（它们只属于设置它们的那一页），且定位滚动在元素停用窗口里直接放弃本次滚动（自动滚动只是辅助交互，不得崩溃应用）。翻页与「定位」功能均恢复正常。

- 保存功能拆分为「确认并保存」与「临时保存」两种方式，修复"只是翻到某页、或只改了一部分（甚至没改）就被当成训练数据"的问题：此前翻页时无论本页有没有改过都会自动执行一次"保存并全部确认"（与保存按钮同口径），浏览过的页即被视为已校对，页内所有识别框和文字状态随之进入训练/校对统计——翻一遍书整本都被计入训练数据。现在编辑器顶栏有两个保存按钮：「临时保存」（软盘图标，有未保存修改时实心）只把当前修改写盘防丢失，不确认任何识别框和文字、不置 reviewed，因此不计入训练数据集、不计入首页"已校对"页数，缩略图也不显示绿框——适合只是看了看这页、或改了一部分还没校完的场景；「确认并保存」（圆圈对勾图标）确认本页全部识别框与识别文字，固化为训练标注（绿框、计入校对进度），行为与原保存按钮一致。翻页与退出编辑器改为自动做一次临时保存（只落盘、不确认），防抖的编辑自动保存同样只落盘不置 reviewed；首页"已校对 X/Y 页"、缩略图绿框、整页清空后空页的已确认判定、训练数据集生成全部只认「确认并保存」，临时保存的页重新打开后照常继续编辑。缩略图边框改为三态：当前页蓝色、已确认页绿色、临时保存过但尚未确认的页橘黄色——新增持久化 draft_saved 标记区分"人工临时保存过"与"仅自动识别、从未打开"（翻页防丢失写盘、编辑防抖落盘、退出编辑器、点「临时保存」按钮都会置位；从未人工保存过的页保持灰框），翻过一遍书后哪些页只是看了看、哪些页已校完一眼可辨；「确认并保存」后橘黄转绿，「重新识别」与「本书重置为未确认」则清除标记回灰框。同步堵上两个漏确认状态的训练数据出口：导出页的 YOLO 四层数据集此前对所有有标注的页全量导出，现改为只导出「确认并保存」过的整页（isFullyConfirmed 整页门槛——检测数据集若只导部分框，图内未标注目标会成为假负样本），未确认页跳过并在日志汇总提示；CRNN 行序列导出改为只导已确认的行（每条样本"行裁剪图+文本"自包含，逐行过滤无漏标问题），日志提示每页跳过的未确认行数；「阅读顺序 JSON」属版面信息仍全量导出。另在编辑器「更多操作」（⋮）菜单新增「本书重置为未确认」：确认框显示总页数后把全书标注状态一次性回到 proposed、reviewed 清零（识别框几何、文字、候选全部保留，不丢任何编辑内容），绿框/校对进度/训练统计归零——用于清理此前被旧版"翻页自动确认"误标为已确认的页，重置后重新逐页「确认并保存」即可。本次为 Flutter 端改动，识别服务无变化。

- 新增「墨迹归类」：把本页字块按墨迹形态（笔画长相）自动聚类分组，在一块界面上按组统一改字或逐字单独改字——同一本书里同一个字反复被读错（如十几个"的"被读成 试/致/扵 各种字）、逐个点开改太慢，现在按"长得像"归成一组一次改完。入口在编辑器顶栏新图标（hub），打开全屏页：每组一张卡片，展示组内所有字的原图缩略图（按字框坐标从整页图裁切，图下方以 16 号字标注当前文字）、组内当前文字分布（如 `的×5 試 致 扵 竹`）与凝聚度（组内平均相似距离）；组内识别文字与多数不一致的字（多半是 OCR 读错、正是要改的对象）在缩略图下方以橙色加粗高亮，与多数一致的黑字、空字的红字一眼区分；组内每个字带勾选框（默认全选），输入一个字点「套用到勾选」即整组统一；卡片下方给出组内成员候选字汇总快选（按字求和分数排序、带拼音，点一下直接整组套用）；点单个缩略图弹出单独改字框（该字自己的候选+输入框）；每个缩略图下方还有定位按钮（十字准星小图标）：点一下返回编辑器并自动切到详细（单字识别）视图、选中该字、把它所在的行卡片滚动到视口上部，且该字在行图字框、字 chip、整行文字字轨三处以红橙交替的呼吸闪烁框高亮约 10 秒（竖排长行里一眼锁定是哪个字；期间不遮挡行图的拖框/缩放交互），右侧属性面板同步选中，拿不准的字可结合整行上下文核对后再回来改。修改即时写回编辑器并自动保存（走与点字快改完全相同的通道，自动重拼行文本），只改文字、不动确认状态；字框几何不变，不触发重识别。空字块（识别为空）照常参与聚类，正好整组补字。顶部有严格/宽松滑杆（调完自动重新归类，整页只要几十毫秒）和「只看待处理组」筛选（默认开：只显示含空字或未确认字的组，全部已确认且文字一致的组不占用注意力）。列表末尾有「未归组单字」卡片：本页没有墨迹相近同伴的字也全部展示出来（同样受筛选开关控制），点缩略图即可单独修改，整页每个字都能在这个界面里处理到。聚类特征为 HOG 形状描述子+宽高比惩罚（与服务端切字共用的整页二值化墨迹 mask，纯 CPU 不占 GPU、不与识别抢资源互不 409），complete-linkage 层次聚类防止相邻字形被链式吸成大杂烩组；阈值与特征在真实书页上校准（560 字页 → 110 组 / 80ms，约七成组组内文字完全一致，且抽查显示不少"不一致"恰是 OCR 读错本身——正是这个功能要批量修正的对象，如 `考×8`、`有×8`、`鉞×6` 组全部干净）。归组只看墨迹不看识别文字，本页内进行（不跨页），批注字块暂不纳入。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 点字弹出的快捷候选格里给每个候选字加了读音（带声调拼音，蓝色小字显示在字和百分比之间）：古籍校正挑候选时常靠读音确认（两个形近字读音不同时一眼定案），此前只能靠字形比对。拼音来自内置离线词典（lpinyin，繁体字直接支持，如 為→wèi、鬥→dòu、擇→zé），多音字取最常见读法；查不到读音的生僻字/异体字不显示读音行。

- 行卡片列1（行图裁切）里选中的单字框新增右上角缩放点位：此前只有右下角一个点，拖它只能拉宽高，想收紧吃进上一字的框上沿得整体挪框再拉下沿，两步还丢精度。现在右上角点位拖动时固定底边与左边、顶边与右边跟随指针，一步收紧上沿；两角命中区重叠（屏幕上框很矮）时取更近的角。主画布上选中的单字框本来就支持四角缩放，不受影响。

- 自动单字识别的准确率大幅提升（实测 21 行人工确认文本：最终正文字符准确率 0.67 → 0.90），根因是你观察到的"手画单字框识别很准、自动识别不准"：手画框周围自然带一圈留白，而自动切分的字框紧贴墨迹——同一个字，紧致框逐字读法准确率只有 0.59，外扩约 15% 边距后 0.86（与手画框水平相当）。更糟的是此前两路吻合率低的行（恰是最难的行）会把正文切到框内读法这个最差来源上，整行正文被拖垮（最差 0.17）。现在逐字识别阶段先给自动字框外扩 ~15% 边距再读（只影响读法，字框几何不变；外扩范围限制在本行字框包围盒外扩 6px 内，不吃邻列），框内读法与整行读法吻合率上升，正文稳定取语境更准的整行读法，分歧候选也来自高质量读法。编辑器手画的单字框仍按原框直读（自带边距、几何权威）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 整页识别的字框质量提升到与"重新识别本行单字"完全相同：此前整页识别对整页做一次二值化、放大倍数由全页最窄的行统一决定，而单行重识别只裁剪本行附近做局部二值化、倍数按本行宽度定——同一条行两条路径喂给识别模型的图并不相同，行级读法会差出字数（实测某页同一条行 38 字 vs 40 字），字数不同则切分重建的字框整体不同，这就是"整页重识别后点重新识别本行单字、字框还能更准"的根因。现在整页识别的行级识别改为逐行独立处理（每行独立裁剪+定倍+局部二值化后识别），逐字识别阶段也改为按行分组请求，与单行重识别的处理路径逐环节一致；实测同一页三条行（含此前不一致的一条）整页路径与单行重识别产出的字框逐像素一致（40/40、37/37、40/40）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 整行识别与逐字识别改为逐字对齐协作，分歧位置直接可见：此前两路读法按位置一一配对——整行序列只要多读/漏读一个字（句读标点、漏识别），后面所有字的正文与候选就整体错挂到邻字上；两路大面积不合时更是整行二选一（整行优先或逐字优先），逐字层面的分歧信息全部丢弃。现在先用顺序对齐（容忍中间插字/漏字）把每个字框配到正确的整行序列字上再融合：正文优先取对齐序列字（语境读法更准），序列没读出的位置由该字框的框内读法补上，"位置对应的序列字"（错位时就是邻字）不再参与正文；既有的整行优先判定、叠字复读翻转等行为保持不变。每个字新增两路合作状态 agree（两路一致/两路分歧/仅整行/仅单字/单字多读）与置信度 conf：编辑器字块 chip 右上角与第三列字轨左缘对"两路分歧"字标琥珀色标记，右侧属性面板显示两路状态与置信度；点开分歧字，另一路的读法就在候选末位，直接点选即可裁决（挂候选带护栏：行内需至少有两个两路一致的锚点字，整行完全不合的疑似错位局面仍不挂候选，避免重现"候选=邻字"）。已保存的旧页面数据没有这些标记，对受影响的行重新识别（或整页重识别）即可带上。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复把大字标题（如"基本賦性"）圈进主区并重识别后，行、自然段、单字三层都不出现这一行的问题：行划分按整页墨迹投影切列时，用一个按正文列校准的墨迹浓度门槛来压边框噪声——大字标题的笔画比正文列稀疏得多（墨迹只有正文列的三分之一），整列被这个门槛压掉，行根本没被切出来，后面段落/单字自然无从谈起；手动把它加进自然段也无效（段落重识别走的同一条路）。现在在主门槛之外用更宽松的门槛补切一遍，把与任何正文列不重叠的稀疏列（标题、边栏小字）补回来——正文列之间不受影响（实测多页行数不回归，标题行重识别后正常出字"基本賦性"四字）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。
- 修复点开单字后快捷候选经常"不是这个字的候选"（显示邻字或形近的部件字）的问题：识别时会顺手把"框内单独读出的字"和"整行读出的字"不一致的那些挂为候选，实测（整页抽查）这些框内读法几乎全是错的——有的把邻字读进来（候选变成上一个/下一个字）、有的只读到字的局部（"出"被读成"山"、"需"被读成"雨"），正确率接近零。现已停用这条挂候选的路径：识别保存的候选不再混入这类噪声，点字弹出的候选改由你训练的候选字分类器按当前字框即时给出（更准）。同时修了一个相关的框几何问题：兜底重建的字框按"整段墨迹"收紧，高字、紧贴下一字的标点不再被格边界切成半个字——此前半个字的框也是误读的来源之一，且拿去训练同样有害。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。
- 兜底识别产生的"等宽字框"收紧为贴字框：像素切分正常时字框本来就是贴着字画的，但当切分与读法对不上、改用整行识别的字符切分位置重建字框时，之前每个框的宽度都取整列宽——句号、小注这类小字两侧留白很大，拿这种框导出训练标注会把检测模型的框"教松"。现在重建后在每格范围内把框收到墨迹的紧致包围盒（不越格，框与文字的对应关系不变），导出训练数据的框贴住字形；格内没墨迹或只有噪点时保留原框。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。已保存的旧宽框不会自动收紧，对受影响的行点"重新识别本行单字"或整页重识别即可。
- 修复手动添加识字框（如给句号补框）后第三列（整行文字字轨）把新字排到整列最上面的问题：上次"新字按位置插入"的修复里，比较方向写反了——实际效果变成"插到第一个位于新字上方的字前面"，新字画在列尾（句号的典型位置）时第一个位于它上方的就是列首，于是新字总是跑到最顶上。现已按真正的阅读顺序插入（竖排从上到下、横排从左到右或从右到左），列2（几何对位）与列3 位置一致，三列联动与自动识别填字不受影响。
- 修复单字模式里"点开一个字，候选里却是上一个字/下一个字"（如昌的候选是文、陰的候选是昌）再次出现的问题：上次的错位检测要靠"每个字框的读法与整行读法逐位吻合"来判断，但错位严重时框内读法本身被邻字带偏、误读太多，吻合率达不到检测门槛，错位漏检。这次修掉错位的两个源头：①多字粘连块拆分时误把"整行剩余字数"当作该块的期望字数（一百来像素的小块被等分出三十多个微格，污染整行切分），改为按块高和本行字高局部估算；②切字组件数与整行读法字数对不上时的网格兜底框是合成槽位，会并字/跳字、与真实字形整体错一格——现在凡是走了兜底切分，一律弃用这批槽位框，改用整行识别自带的字符切分位置重建字框（与读法天然对齐）。另外，两路读法大面积不一致（疑似错位）时不再把整行读法逐位挂为候选——那种局面下整行读法属于邻位，挂上就是"候选=邻字"，留空由编辑器显示当前文字兜底；两路对齐可信时的互挂候选不受影响。实测此前的重灾区行（一册书约 1.5 万字中招）重识别后正文与候选全部对位，正常行的像素切分路径无回归。识别服务版本号已升级，重新打开应用会自动替换旧服务进程；已保存的错位候选不会自动消失，对受影响的行点"重新识别本行单字"即可纠正。

- 修复调整识别框后画布"卡死"、必须等后台识别跑完才能继续编辑的问题：上次修复移除了画布工具层"识别中禁用编辑"的旧开关，但画布按下事件的入口处还残留三处拦截——只要后台识别队列里有任务在跑（包括改单字框触发的单字识别），行视图/主区视图/段视图里所有点击、拖动、缩放、画新框都会被静默吞掉，界面上横幅明明写着"后台进行，可继续编辑"，实际却要等识别（后端忙时还会 409 重试，每次隔 2 秒、最多 10 次）全部结束才恢复操作。现已移除这三处残留拦截，识别期间编辑真正不被阻塞。同时补齐了并发编辑的保护：识别结果回来时不再抢占当前选中的框（按 id 取最新对象），正在拖拽/缩放的行即使恰好在那一刻被后台识别替换也能按 id 接续上手势，未受影响的行在区域重识别后保持选中，手势结束仍能正确触发重识别。
- 行划分改为层级顺序（主区>段落>行>单字）：此前（未启用行检测模型时）行由单字检测框按 X 聚合而成——行质量完全受制于字检测召回（90.6%），漏字导致断行/缺行。现在行这一层先按**整页墨迹 X 轴投影**切出行（列）条带（与字检测解耦；启用行检测模型时仍优先用模型行框），字检测框随后按中心归入行、只提供行内字几何；完全没有字落入的条带照样成行（行框取条带内墨迹范围）。真实书页实测：目录页因字检测漏检断开的行合并为完整列，正文页 10-11 条完整列，界欄/边框残留的细墨迹条带（7-8px）被最小列宽阈值过滤不再成噪声行。engine/model_version 标记为 "hier"。整页二值化墨迹 mask 增加 (路径,mtime) 缓存（此前一次识别重复计算 3-4 次）。
- 侧边"本页拆分"信息卡改为六行并显示模型名：行划分方式 + 正文区检测/段落检测/单行检测/单字检测/单字识别五层各自的实际状态与模型文件名——自训层显示"自训 active_xx.pt · 训练日期 · 召回率"，未启用层显示"未启用（规则+手工）"，char_det 未启用时显示内置默认模型名，单字识别显示 Kraken 引擎模型（chat_rec.mlmodel，区分官方版/微调版）。/models 接口相应增加 default（各层内置模型路径）、active_started（激活的训练 run 时间）与 kraken_rec（识别引擎模型状态）字段，并修复旧注册表 active 稳定副本路径与训练 run 路径不一致导致指标/时间取不到的问题。

- 修复重识别进行中无法继续编辑的问题：画布的编辑手势（改主区/段落尺寸、画新行框）此前被"识别中"状态直接禁用，段重识别要等几十秒才能再操作。后台任务队列上线后这层禁用已移除——重识别期间可继续拖动/缩放/画框，新改动会以最新几何重新入队。侧边栏"本页拆分"信息卡从左侧缩略图栏移到右侧属性面板底部，并改为逐层如实分列：行划分方式（自训单字检测成行 / OpenCV 投影兜底 / 未识别）+ 正文区/段落/单行/单字四个检测层各自的激活状态（自训附召回/mAP 指标、内置默认、未启用（规则+手工）、已失效），只启用了单字检测时其余三层明确显示"未启用（规则+手工）"，不会再被读成全部启用自训模型。

- 修改识别框（主区/段/行/单字）触发的重识别改为后台任务队列，不再阻塞编辑操作：此前识别进行中再改框会弹"正在识别中，请稍候再试"并丢弃本次修改的级联。现在：改框后重识别一律入队后台执行，可继续画框/拖动/缩放/翻页；**同一目标**（同一主区/段/行/单字）在等待中再次修改会替换排队任务（以最新几何为准），正在执行的任务结果会被作废、新任务随后立即接替——等效"停止旧分析、用新框尺寸重新分析"；**不同目标**的任务按提交顺序排队依次执行（横幅显示"后台进行，可继续编辑"及后排队列数，行任务对应行卡片转圈）。后端忙碌（409，如整页批量识别进行中）自动重试（最多 10 次、每次隔 2 秒），不再直接报错。行视图新画行框同样入队。作废的任务静默丢弃结果，不会覆盖用户后续修改；识别期间删除的框/翻页仍按原保护逻辑跳过回填。

- 书籍编辑页左侧缩略图侧边栏底部新增"本页拆分"信息卡：显示当前页识别使用的拆分方式（自训单字检测成行 / OpenCV 投影兜底 / 未识别，取自该页识别结果的 model_version）与当前激活的 char_det 单字检测模型（自训模型附训练指标：召回率、mAP50；未启用自训时显示内置默认模型）。此前拆分用的是哪个模型只能翻后端日志，排查"行划分不如以前准"时无从对照。

- 修复应用启动时 Python 后端无法绑定 8765 端口（Errno 13"以一种访问权限不允许的方式做了一个访问套接字的尝试"）导致一直转圈、最终提示误导性"请先运行 install.bat"的问题：根因是 Windows 的 Hyper-V/WSL/Docker（winnat）会在开机时随机保留大段端口（本机 8482-9181 整段被保留，8765 在内），保留段内任何程序都无法监听，与安装无关。现在服务启动时从 8765 起连续探测 500 个候选端口（bind 预检，跳过被保留/被占用端口），把实际端口写入 python_service\service_port.txt；Flutter 端启动与轮询健康检查都会跟随端口文件，旧版服务检测、端口占用清理也改用实际端口。启动超时的报错信息现在会附带后端 stderr 的最后 15 行输出（此前只显示与真实原因无关的通用提示），绑定被拒时给出端口保留区的排查指引（netsh interface ipv4 show excludedportrange protocol=tcp / net stop winnat）。本机实测自动避让选中 9182 并正常监听。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复 install.bat / install_kraken.bat 在中文 Windows 上运行报一堆"'xxx' 不是内部或外部命令"的问题：两个脚此前是 UTF-8 中文注释 + LF 换行，cmd 按 GBK 解析时把 rem/set 行切碎成乱码命令（CONDA_EXE_PATH 等变量也随之丢失）。现已改为纯 ASCII 注释 + CRLF 换行，从根上消除编码风险。同时修复两个实际逻辑 bug：① install.bat 的 CUDA 检测块内用 %VAR%（整块解析时展开为空），导致"Could not detect CUDA Version"无条件必现——块内改用延迟展开 !VAR!；② CUDA 版本正则只认旧驱动的 "CUDA Version: 12.6" 表头，新驱动（如 616.92）表头是 "CUDA UMD Version: 13.4" 永远匹配不到——正则改为兼容两种格式。已在本机（RTX 4090D / 驱动 616.92）实测：正确检出 CUDA 13.4 并选择 cu130 源。

- 修复单字模式新画字框后第三列（整行文字字轨）不把新字排到对应位置的问题：新框识别出的字此前一律追加到行内末尾——列2（与行图几何对位）显示正常，但列3 按行内顺序排列，新字落在行末。现在新字按几何阅读序插入（竖排按中心 Y 上→下、横排按中心 X，ltr 左→右 / rtl 右→左），插入后重排 order 与行文字，三列位置一致；自动识别填字、候选挂载不受影响。

- 新增"切字过程诊断"：详细视图每行卡片标题栏新增望远镜按钮（/debug_char_split），一键生成并展示该行的切分中间过程图——整页二值化墨迹图（切分器"眼中"的图）+ 行内切分过程叠加图（绿=行框、橙=连通域块、红=被面积过滤丢弃的墨点、蓝=最终字框含序号），并标注本行走过的切分路径（连通域正常切分 / 数量不符→网格均分兜底 / 等分兜底）、连通域块数、丢弃墨点数、粘连投影细切处数、期望与实际字框数；图片可用系统看图工具打开缩放。此前这些中间产物只存在于 [diag:split] 文字日志里，肉眼对照图片分析"识别框是怎么判定的"非常困难（如墨点为何成框、粘连为何错切）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修改正文区（主区/段）框后触发的区域重识别与整页重识别结果不一致、文字再次错乱的问题：区域识别此前"先按区域过滤行、再对过滤后的行批次做 Kraken 识别"，而识别的放大倍数按批次内最窄行宽自适应——区域内行集合与整页不同时放大倍数和二值化随之改变，同一行的逐框读法与正文来源判定（序列/框内）在两条链路间漂移，叠加目录页等"一列多段、段间有空隙"的版面（像素切分框跨空隙粘连）后正文时对时错。现在 /segment_lines_in_region 与 /segment 完全同构：整页分行→整页批次识别（同一放大倍数）→再按区域过滤行/字，两条链路对同一行的产出逐字一致（已用真实书页本地对比验证 diff=0）。区域重识别耗时与整页识别相同（不再因区域小而变快）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复"每个字的候选恰好是上一字"（如昌的候选是文、陰的候选是昌）的字框错位根因：像素切分字框在行首混入行外组件、行尾并字补数时，框数恰好等于整行读法的字数但整体偏了一格——逐框识别读到的就是上一字的墨迹，序列读法与字框双双错开。现在两条识别路径（整页、单行重识别）都会做错位检测：逐框读法与整行序列呈 ±1 格错位吻合（过半吻合且显著高于 0 偏移）时，弃用这批偏移框，改用 Kraken 自身字符切分位置重建字框并重新逐框识别，字框几何、框内读法、序列三方重新对齐；检测与重建都会在后端控制台输出 [line-rec] 日志（pairing offset=±1）。错位检测带保守门槛（≥2 个可比对、≥50% 吻合、比 0 偏移高 ≥30%），正常对齐、偶发误读、真叠字文本均不触发（已用用例验证）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程；对受影响的行点"重新识别本行单字"即可纠正已保存的偏移框。

- 修复行卡片"重新识别本行单字"后叠字式复读依旧的问题：单行重识别走的是独立的 kraken_segment_line 路径，此前"序列复读 + 框内读法不同 → 以框内读法为正文"的修复只加在整页识别（apply_kraken_recognition）里，单行路径漏了；现已两条路径一致。同时为两条路径加入逐字决策日志：后端控制台里每行识别都会输出 [line-rec] 一条——整行序列读法(seq)、各字框框内读法(crop)、最终正文(final) 的逐字对照（· 表示空），字框来源（user/pixel-split/kraken-cuts）与触发的复读翻转（#序号 seq→crop）单列。据此可直接分辨三类问题：seq 复读（seq 串里重复而 crop 正确）、字框错位（crop 串整体偏移一格，如"昌"位 crop 读成前一字"文"）、模型两路同错。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复单字候选分类"正确字不在候选里、候选被邻字主导"的问题（如"為"被识别成前一字"星"，候选只有 量/星 等）：候选分类器（char_cls）的推理裁剪 padding 此前按整页尺寸 //200 计算（3000px 页四边外扩 15px），而训练数据只用 //400（约 7px）——密排竖排里推理裁剪吃进上下邻字笔画，分类自然偏向邻字。现在推理与训练严格同公式（//400），并在两侧加了必须同步的注释。另修复整行序列读法的"叠字式复读"误读：序列把某位置读成与前一字相同、而该字框的框内读法给出不同字时（如 …星、星… 而框内读"為"），以框内读法为正文、序列字降为候选；框内读法为空或与序列一致时不干预，真正的叠字不受影响。识别服务版本号已升级，重新打开应用会自动替换旧服务进程（已保存的旧候选不回填，重新识别或调整字框后生效）。

- 详细视图竖排行卡片的右侧两列文字重构：此前两列按固定行高逐字堆叠，而图中字框有真实的大小与间距（小注小字、漏字空隙、大小不一），一列三十来个字累计下来右侧文字相对图像漂移数百像素，越往下越对不上，校对困难。现在两列分工：**列2（字符 chips）与行图同高、每个字的单元中心锚定在其字框真实中心**（校对对位面，与图中字框逐字同位）；**列3（整行文字）按行内顺序排成等高字轨**（阅读面，紧凑无空行）。行高、字号、列宽都以"标准字单元"（本行全部字框高度的中位数，即正文典型字高）为基准：字号全列统一不逐字缩放，极小字框（标点、残框，如逗号位被识别成"金"）在列2 抬到 0.55 倍标准行高的下限保证可读可点，异常大字压到 1.15 倍上限；两列宽度收窄到约一个字位宽（随字号缩放，上限 1.4 倍标准单元），三列宽度接近、格位方正紧凑。"字号"按钮退化为填充系数（调字号不再破坏对齐，整体放大请用"卡片缩放"）。交互：列2 chips 轻点改字、拖拽改序（拖拽时有跟随指针的橙色插入指示线，几何锁定下明确显示落点）；列3 字轨轻点选中（三列联动高亮）、上下拖拽改变字序（被拖字实时吸附到落点槽位预览，松手提交，顺序变化即刻可见）。

- 修复详细视图画单字识别框时框的位置偏离鼠标按下点的问题：此前按下点即使落在字框外，只要距某个已有框 3 像素以内就会被判定为"抓到该框"并拖动它，框角带着抓取偏移跟随光标，看起来就像画框偏移；字框间隙只有几个像素，在间隙里画新框几乎必然触发。现在只有真正按在框内才拖动，按下框附近则从按下点精确开始画新框；轻点仍可选中邻近的框，拖动即转为画框。

- 修复详细视图（单字模式）里用鼠标画识别框时，框的起点位置偏离鼠标位置的问题：卡片列表的可滚动手势会把画框拖拽同时识别成"滚动列表"，列表在光标下移动导致画框起点漂移、画出的框尺寸也随滚动量错乱。现在在行裁剪图上拖拽时手势由画框区域接管，拖拽期间列表不再滚动（滚轮滚动不受影响）；拖动、缩放已有字框同样受益。

- 单字快速识别从约 5 秒提速到约 0.1 秒（百倍级）：识别 daemon 此前对整页大图做放大和二值化再识别其中一小块，现在只裁剪请求行框的包围盒（加边距）处理；实测同一字框识别结果更准（排除了周围墨迹的语境干扰）。画新框或拖动/缩放已有框后的自动识别因此能做到即时返回，修改框内文字会立即按新几何改正是编辑反馈不明显、识别又慢又偶发不准的直接后果。
- 单字快速识别增加可见反馈与失败提示：识别进行中右侧属性面板"OCR 内容"处显示转圈与"识别中…"，识别失败（服务忙碌/异常）弹出明确错误提示，不再静默无反应。识别服务版本号已升级，重新打开应用会自动替换旧服务进程（daemon 随服务重启加载新代码）。

- 修复全部可训练模型的数据目标没有按训练轮数进阶的问题：此前只有最新一次训练被计入，且旧训练记录没有登记所用基础模型，单字检测 n 档等实际训练过的档位被错误归档到默认档位，导致"练完了目标却不变"。现在每次成功训练的档位从训练日志（base=yolov8n.pt 等）精确恢复并计入该档已训轮数，下一轮目标随之递增（如 n 第 2 轮 600、第 3 轮 900）。里程碑在数据要求并列时优先同一个档位连续进化（n 练完继续指向 n 下一轮），五个可训练层全部适用。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 编辑器右侧的训练数据进度卡按模型档位分条显示：n/s/m/l 每个档位一条进度条（实例数/目标数、已训档位标注第几轮），下一个训练里程碑的档位用旗帜高亮、已达标的档位显示绿色对勾；单字分类的档位行同时显示字类覆盖进度。实例数仍为本地实时计数，确认数据后立即变化；识别服务不可用时回退到旧的单条进度条样式。

- 修复选中识别框后按 Delete 键删除时而失灵的问题：键盘快捷键依赖页面持有焦点，此前焦点被按钮点击或单字编辑浮层带走后 Delete/Esc 会静默失效。现在任意点击（画布/缩略图/面板/按钮）都会把键盘焦点收回页面，选中框 → 按 Delete 删除、按 Esc 取消选中恢复稳定可用；单字编辑输入框打开期间 Delete 仍正常编辑文字，不会误删识别框。

- 训练数据进度条的目标自动进阶：每个模型档位的数据要求按该档已成功训练的轮数递增（第 2 轮需要 2 倍确认样本，与 Kraken"每代 +100 行"同理——同一批数据反复重训没有增益）；进度条默认跟随系统算出的「下一个里程碑」（所有未达标目标中要求最低的档位，同价时优先没训练过的更高档），某档训练完成后默认目标自动移向下一轮或更高档位。手动选择其他档位时显示该档下一轮的要求，并提示下一个建议目标。单字分类的字类覆盖要求不随轮数放大（受书籍实际用字上限约束）。
- 新增 yolov8l（L 档）基础模型：五个训练层均可选 n/s/m/l 四档，L 档建议数据量为 M 档的 2 倍（单字检测 3600、单字分类 6000 样本 480 字类等），首次训练自动下载权重（与 M 档相同机制）。注册表现在会记录每次训练使用的基础模型，旧记录按各层历史默认档位归档。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 单字模式下画新框、拖动或缩放已有框，松手后立即用 Kraken 按新框重新识别填字，并挂上候选字：正文取 Kraken 框内读法，自训单字分类器（char_cls）的 top-K 追加为候选；调整过的框旧文字若与新读法不同会进候选列表，可一键改回。识别期间手动改过字的框不会被机器读法覆盖。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- PaddleOCR 全部移除，识别链路完全由 Kraken 承担：版面/行/字框由 YOLO 自训模型（启用时）或 OpenCV 投影切分给出，全部文字识别走 Kraken 引擎。此前"修改正文框后整页单字变问号"的根源是这条重识别路径的文字仍依赖 Paddle 补齐，Paddle 初始化失败（cudnn DLL 版本冲突）后文字全部为空；现在编辑正文框触发的重识别也接入了 Kraken。相关的安装、环境检测、候选字合并、能力上报等 Paddle 残留一并清除（requirements、install.bat、环境准备页、安装脚本、约 1200 行识别代码），历史可行性研究脚本 kraken_feasibility 已删除。conda 环境沿用历史名称 "paddle" 以免老用户环境失效（仅是名称，不再装任何 paddle 包）。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复 Kraken 微调卡片在"全部书籍（汇总）"模式下显示 0 条确认行的问题：定位书籍库根目录时无条件取了传入目录的父目录，汇总模式传入的库根本身的父目录是 Documents（不含任何书籍），导致统计和训练启动的数据门槛检查都拿到 0 行。现在单本书目录和库根目录两种入参都能定位到同一库根，统计口径一致。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 修复模型训练页"全部书籍（汇总）"模式下五个训练层级全部显示 0 数据、没有数据进度条的问题：汇总统计在多书重构后引用了未定义的变量（统计和数据集生成两处），接口直接报错；此前只有 Kraken 卡片因走独立统计而正常显示进度。现在汇总模式正确统计全部书籍的已确认标注，段落推断也按每本书各自设置的阅读方向（rtl/ltr）计算。识别服务版本号已升级，重新打开应用会自动替换旧服务进程。

- 功能入口重新布局：模型训练、模型对比测试、模型使用管理的入口从书籍编辑界面移到了首页（选择识别哪本书的界面）顶部；模型训练页改为进入后再选择训练数据来源，支持"全部书籍（汇总）"或单本书籍，各层级的标注实例、目标差距、历史训练次数都会按所选范围统计。

- Kraken 微调新增数据需求进度条和轮数选择：数据需求随微调代数自动增加（第 1 代需 100 行确认行，每多微调一代 +100 行），不足时明确显示还差多少行；微调进行中显示训练进度条（按 ketos 日志解析的轮次进度）；训练轮数可在 10/20/30/50/100 中选择。

- Kraken 微调新增数据需求进度条和轮数选择：数据需求随微调代数自动增加（第 1 代需 100 行确认行，每多微调一代 +100 行），不足时明确显示还差多少行；微调进行中显示训练进度条（按 ketos 日志解析的轮次进度）；训练轮数可在 10/20/30/50/100 中选择。数据需求代数只统计真正产出过模型的训练（失败的尝试不算），数据统计范围汇总全部书籍的确认行。

- Kraken 微调卡片新增日志显示：微调过程中 ketos 的实时输出会直接显示在卡片内（保留最近几行），训练数据不足等原因导致的启动失败也会明确提示；导出数据失败时不再留下卡死的"进行中"任务，「停止」按钮可随时清理。

- 修复左侧缩略图页码溢出显示黄黑警告条的问题（页码文字渲染高度比预留空间多 2 像素导致）。

- 新增 Kraken 识别模型微调功能（模型训练页新增卡片）：与五个 YOLO 层并列的第六种训练——用你确认过的"行图 + 行文字"微调 Kraken 主识别引擎，直接提升整行识别的文字准确率。支持导出训练数据、启动/停止微调、查看完整日志；微调产出的模型可在"模型使用管理"中一键启用或恢复官方底座。识别服务版本号同步升级，应用启动时会自动替换旧版本服务进程。

- 功能入口重新布局：模型训练、模型对比测试、模型使用管理的入口从书籍编辑界面移到了首页（选择识别哪本书的界面）顶部；模型训练页改为进入后再选择要训练的书籍，模型对比测试同样支持在页内选择书籍。书籍编辑界面不再显示模型训练入口。

- 修复单字候选分类对比评测点击无反应的问题：评测失败原先被静默忽略（例如识别服务版本较旧没有该评测接口时），现在会显示明确的失败原因；评测过程也会每 10 个字在识别过程日志中报告一次进度。

- 模型对比测试新增单字候选分类的命中率评测：选择该测试模式后，以页面上已确认的文字为标准答案，分别统计「使用所选模型」和「基线」的 Top1/Top3/Top5/Top10 命中率与平均排名，并列出逐字排名明细——此前该层用切分框对比完全看不出区别。

- 新增「模型使用管理」页面（模型训练页右上角和环境准备页训练组件卡片均可进入）：集中查看五个识别层级（正文区/段落/行/单字检测/单字候选分类）各自当前启用的模型，可启用任意一次训练（不再只能启用最新一次）；支持按项目单独配置各层使用的模型（覆盖全局设置，配置保存在该项目内）。

- 训练产出的目录名改为带日期时间（如 run_20260918_034512），每次训练独立保存、永不覆盖旧模型。

- 修复清空识别框的页面丢失"已保存"绿框标记的问题：整页清空并保存过的页，重新打开书籍后缩略图不再丢失绿色边框。

- 左侧缩略图列表现在会自动滚动定位：进入书籍或翻页（上一页/下一页）时，当前页的缩略图会自动滚动到侧边栏可见位置，382 页的大书里不用再手动翻找。

- 模型对比测试页底部新增「识别过程日志」面板：实时显示每次识别的模型加载、切分引擎选择等关键过程（如"char_det: 使用自训模型 xxx.pt"、"engine selected: yolo-char"），一眼确认模型到底有没有被用上；支持选中复制和一键复制。

- 模型对比测试新增相似度提示：当两侧结果完全一致时会明确提示"所选模型在这一页没有产生变化"及可能原因（模型预测未过阈值/候选分类不改主文字/页面过于简单），避免误以为对比功能失效。

- 模型对比测试新增「滑动叠加」查看方式：两侧结果合成到同一张图上，按住鼠标拖动中间竖线即可左右切换查看模型结果和基线结果，逐区域找出差异；并新增相似度统计（两侧字框数量、匹配对数、平均 IoU、识别文字相似度），差异大小一眼量化。

- 模型对比测试升级：新增「测试模式」选择（单字检测/单字候选分类/行检测/段落检测/正文区检测）和「模型」下拉框（该层历史上训练出的每个模型，标注轮数、mAP50 指标与是否当前启用），可以直接测试任意一次训练产物而不只是当前启用的模型；对比图同时绘制正文区/段落/行/字四类框，并显示每侧的识别文字。

- 新增「模型对比测试」：模型训练页右上角新入口，选一页图片后自动分别用「当前启用的模型」和「不使用自训模型的基线管线」各识别一次，左右并排显示行框、字框切分结果与统计（字框数/行数/耗时），直观评估训练出的模型效果。

- 训练环境升级为 CUDA 版 PyTorch，并在模型训练页新增训练设备选择器（自动/GPU/CPU）：默认"自动"会在显卡空闲时用 GPU 训练（速度比 CPU 快几十倍），也可强制指定 CPU。选 GPU 但环境不支持时会给出一眼能看懂的中文错误。

- 环境准备页新增「安装 CUDA 训练组件」：训练组件卡片会显示训练用 PyTorch 的版本和 GPU 可用性，检测到只有 CPU 版 torch（训练很慢）时提供一键安装 CUDA 版（约 2.5 GB，按所选 CUDA 运行时自动匹配下载源），装完自动验证 GPU 可用性。

- 模型训练页新增「训练前检测」：一键逐项检查训练环境（PyTorch/Ultralytics/是否 CUDA）和各层数据集完整性（用训练启动时的同一套官方校验），✗ 项直接给出原因，先看清能不能练再点训练。

- 修复单字检测训练必然失败的问题：生成的数据集目录结构和配置文件里声明的路径不一致（配置指向不存在的 images\val 目录），ultralytics 直接报"images not found"。现在配置与实际目录对齐，并实测通过官方校验；验证集为空时自动把一页挪入验证集（有效页面不足两个时给出明确的中文提示）。识别服务版本号同步升级，旧服务进程会在应用启动时被自动识别并重启，不再出现"改了代码却一直跑旧进程"的情况。

- 模型训练页每个模型卡片下方新增文件夹快捷入口：「打开数据集文件夹」在生成过数据集后可点击直达；训练成功后出现「打开模型目录」，一键打开本次训练产出的模型文件夹。

- 「清除本页识别框」不再弹确认框，点击后直接清除（仍只影响当前页）。

- 训练日志可以复制、可以看完整内容了：日志台里的文字可直接用鼠标选中复制，右上角新增「复制」（复制当前显示的日志）和「完整日志」（打开完整日志窗口，支持滚动翻看全部内容、一键复制全部）——此前只能看到最后 30 行且无法复制。

- 修复单字就地编辑与中文输入法冲突的问题：此前边打字边把拼音中间态（如"d"）当成最终文字写入，导致确认时文字变成拼音字母且后续输入丢失；现在改为编辑结束时（点空白处、按回车或点候选）一次性提交最终文字。点开字框时原文字自动全选，直接输入即可整体替换，不用先手动删除。

- 翻页即确认：点上一页/下一页（或点缩略图）离开当前页时，即使没有改过任何内容也会自动保存并把本页所有识别框和文字标记为"已确认"，浏览过的页随之计入校对和训练统计，该页在缩略图上也会显示绿框。

- 「清除本页识别框」变成长驻功能：右侧面板按当前视图常驻显示清空按钮（单字框/行框/段落/正文区），不用先点击选中某个识别框；点击后需在确认弹窗里再确认一次，防止误触。

- 编辑器整个界面底部新增固定的翻页栏：上一页/下一页按钮 + 当前页码指示（如"第 3 / 382 页"），标注和后台视图下都常驻显示，翻页不用再去左侧缩略图里找。

- 点选单字的改字方式更顺手了：点击字框后，字框位置直接变成可输入的文字框（输入即时生效），正下方同时浮出候选字，点哪个候选立即应用；按回车或点空白处结束编辑，不再弹窗选择后按确定。

- 新增 Windows 安装包（installer 目录运行 build_installer.bat 一键制作）：双击安装、自动创建开始菜单/桌面快捷方式、自带 VC++ 运行库和 Kraken 识别模型，装完即可离线识别，首次运行按引导自动准备 Python 识别环境。

- 识别中的书籍现在会显示预计完成时间：根据最近几页的实际识别速度估算"预计还需多久、大约几点完成"，速度变化时估算会自动跟着更新。

- 书列表页顶部新增识别服务资源占用显示：实时展示识别功能占用的 CPU、内存、显存（每 3 秒刷新）。CPU 按占全机算力的百分比显示，与任务管理器口径一致。

- 环境检测新增对 PDF 组件（PyMuPDF）的真实导入检查：此前只查"包装没装"，有一种"显示已安装但实际已损坏（DLL 加载失败）"的情况查不出来，直到添加 PDF 书籍报错才会暴露。现在环境准备页的「识别服务环境」卡片会直接显示 PDF 组件是否导入正常，损坏时给出"修复 PDF 组件"按钮。

- 「修复 PDF 组件」改为强制重装：此前检测到损坏后点修复，安装器看到"已安装"会直接跳过，修不了问题；现在会强制重新下载安装，修复后立即重新校验导入。

- 添加 PDF 书籍失败时的报错更友好：不再显示整段英文 JSON，而是显示中文原因和解决办法（去环境准备页修复 PDF 组件后重试）。

- 新书添加后自动整本识别：不用再逐页手动打开识别，添加完成后软件会在后台把每一页依次识别一遍。书列表的每一本书下方新增进度条，实时显示正在识别第几页、还剩多少页、剩余百分之多少。

- 整本识别到 100% 之前不能进入编辑：识别没完成时点击书籍会提示"识别完成后才能进入编辑"，完成后点击即可正常打开。

- 一次添加了多本书也不用等：多本书会按添加的先后顺序排队，一本识别完自动开始下一本，列表里能看到每本书排在第几位。

- 中途关闭软件不怕丢进度：识别到一半退出软件，下次打开会自动从没识别到的第一页继续，已经识别过的页不会重复识别。

- 书籍列表新增校对进度：识别完成的书会显示"已校对 X/Y 页、剩余多少页（剩余百分比）"。在编辑器里人工保存过的页才算已校对，机器自动识别的不算。

- 修复环境检测的两个 bug：包版本探测脚本经过命令行转发时被换行截断导致检测为空（改为写临时脚本文件执行）；探测结果为空时会触发"修改只读数据"异常把整个检测判为失败（已修复）。修复后识别服务环境和 Kraken 引擎卡片可正常显示已安装的组件版本。

- 修复环境准备页面闪退：安装日志的滚动条缺少滚动控制器，在桌面端触发框架断言导致应用异常退出，现已修复。

- 环境检测全程日志：检测的每个步骤（conda 候选尝试、执行耗时、失败原因、各环境探针结果、最终汇总）都会实时写入安装日志面板，检测不到时能直接看到卡在哪一步。

- 修复"安装 Miniconda 成功后仍提示未找到"：新安装的 conda 首次运行可能需要数秒预热，此前检测超时太短会把"慢"误判成"未安装"；同时补充了对 CONDA_EXE 环境变量、ProgramData 及自定义安装位置（如 Anaconda 装在非用户目录）的识别。安装脚本现在会校验安装结果，不再出现假成功提示。

- 识别速度大幅提升：Kraken 识别引擎改为常驻运行，模型只在启动时加载一次（此前每页识别要重复加载两次，独占显卡环境下每次约 50 秒）；服务启动时还会自动在后台预热。实测整页识别从约 2 分钟降到半分钟左右（剩余时间以版面检测为主）。
- 只保留 Kraken 一种识别引擎：新建任务不再选择引擎，所有书统一使用 Kraken 混合识别；旧的 PaddleOCR 引擎选项移除，历史书籍自动按 Kraken 处理（旧页面需重新识别生效）。
- 运行环境准备页面重做：按"基础环境 / 识别服务环境 / Kraken 识别引擎 / 训练组件"分组卡片展示，顶部有就绪状态与"进入 OCR"按钮，安装按钮只在缺失时出现；新增 Kraken 引擎一键安装和识别服务环境一键安装（原 4 个分步按钮合并）。
- 环境检查提速：从十几个逐条串行检测（15–60 秒）改为 4 个并行检测（约 5 秒），并缓存上次结果，进入页面立即显示、后台刷新。

- 识别质量与字框对应两全：每行会自动比较"逐框识别"与"整行识别"的读法吻合度——吻合良好时正文采用整行识别的结果（语境识别更准，恢复到以前的识别质量），框内读法存为候选；吻合度差（行内有标点或漏字导致错位）时正文改用框内识别，保证框和文字对应。两种引擎同一策略。

- 逐框识别升级为混合模式：字框里的文字仍以框内识别为准；当它与整行连续识别的读法不一致时，整行读法会自动存为该字的候选——点开编辑弹窗就能看到并一键改回，两种识别的优点都不丢。

- 修复"识别框很准但框里的文字对不上"：此前文字来自整行识别后按顺序铺到各框，行内一有标点或错漏字，后面所有框的文字都会错位一格。现在 Paddle 和 Kraken 两种引擎都改为对每个字框单独识别框内的内容（Kraken 在整行识别定字数和字框后，增加一轮逐框识别），框里是什么字就显示什么字；个别框识别为空时回退整行序列的字。行卡片最右侧的整行文字列恢复黑色显示（不再跟随彩虹色），字框与中间字列表的彩虹对应保持不变。

- 识别过程全程可见：重新识别当前页时，后台日志现在会实时显示进行到哪一步——版面检测耗时、Kraken 启动/二值化/模型加载、每识别完一行报一行（第几行、多少字、置信度、耗时）；应用侧每 15 秒报一次"已等待多久"。实测发现转圈的主因：显卡被其他程序占用时，版面检测约 18 秒、Kraken 模型加载约 41 秒（识别本身不到 1 秒），此前这段时间没有任何日志，看起来像卡死。

- 修复上一版引入的问题：识别请求全部返回 422 参数错误（后端内部改动导致接口参数解析错误），现在接口恢复正常，已实测通过。

- 修复"重新识别当前页一直转圈、没有任何提示"的问题：整页/单行/区域识别请求此前没有超时上限，显卡被其他程序（游戏等）占满时识别会变得极慢，界面就永远等着。现在识别请求最多等 10 分钟（单行 5 分钟），超时会明确提示"显卡被占用导致变慢，请稍后重试"。后端同时改为同一时间只跑一个识别任务，重复点击会立即提示"已有识别任务进行中"，完成时在日志里显示耗时。

- 修复反复无法进入 OCR 的问题：旧的后端进程偶尔卡在加载/识别中、来不及响应健康检查，应用以为端口空闲就启动新进程，结果因端口被占（10048）退出。现在启动前会先探测端口，发现被无响应的进程占用会自动关闭它再启动。后端日志的中文乱码也一并修复（统一按 UTF-8 输出和读取）。

- 单字框与文字彩虹配色：同一行内每个单字识别框用不同颜色填充，行卡片里的字列表和整行文字也用对应颜色显示，一眼看清每个框画得多大、对应哪个字；标注大图的单字视图同样配色。已确认的字原来用绿框表示，现改为框角上的小绿点；选中仍是橙色高亮。

- Kraken 引擎的单字框与 Paddle 引擎统一：识别出的文字不变，字框改为按页面墨迹自动切分（与 Paddle 引擎同一套算法），不再出现贯穿整列、明显大于字形的条带框，标题列、字距不均的行也能贴合每个字。整页识别与单行重识别均生效；手动画过/调整过的字框仍优先保留，行框保持原值；图像分析失败时自动回退原有切分方式。需重启 python 服务生效。

- 单行重识别不再把"等跨度合成字框"当作用户手画框保留：此前编辑器字框与识别字数一致时一律回填文字、保留旧几何，导致数据修复产生的均排框（以及历史上自动均分的框）永远均等大小、不贴字形。现在检测到所有字框跨度完全相等（手画几乎不可能）时，改用 Kraken 按字符真实切分位置重建的字框（实测 l_011 高度呈 40/32/36/36/38… 自然参差）；带自然参差的手画/手调框仍原样保留、只回填文字。
- 修复"kraken 的单字识别框非常小"：行框被拖大/调小时字框只随行平移、不随行缩放，行框从 36×143 调到 94×325 后字框仍挤在左上角原尺寸区域，重识别因数量一致回填旧几何而一直保留。现在 _updateLine 对字框做与行相同的等比缩放；已把示例书标题行 l_008 的 4 个字框重排到 94×81（备份 .pre_repair2）。验证：放大后的标题行（列宽 94px>90px 阈值）CHAT 可正确识别"作者簡介"，逐字置信度 0.999。
- 修复"拆字识别后行识别框变小"：根因是 python 服务进程自 21:31 一直运行、未加载 21:40/21:55 写入的行框保持与字框重建修复，旧代码把行框替换成半尺寸字框的并集。已重启服务加载修复，并修复了已被旧代码写坏的数据：kraken 引擎书籍（1789565505499）page_000/002/004 共 19 行的字框被按 2 倍缩小错位，已沿阅读轴在行框内均匀重排（文字保留，原文件备份为 *.pre_repair）。编辑器需切页重载（不要在旧内存状态上继续保存）。
- Kraken 单行重识别失败时（CHAT 对该行识别为空，如大字标题；或 kraken 环境异常）自动回退 paddle 单行识别；回退结果以汉字为主才采用，否则返回明确错误并在编辑器保留原行数据（避免 "1/1/1" 类噪声覆盖已校正的文字）。
- 修复 Kraken 单行重识别后行框变化、行卡片裁切图被放大畸变的问题：行框现在始终保持原值，不再被字框并集替换；识别放大倍数按最窄行自适应（保证放大后列宽≥100px，修复窄标题列识别为空）；单行识别结果为空时（如行框未框全的大字标题）直接报错并在编辑器保留原行数据，不再清空。
- 新增书籍级识别引擎选项：新建识别任务时可选择 PaddleOCR 或 Kraken 古籍模型（存入项目设置，逐书生效）。Kraken 采用可行性报告确定的混合架构——版面与行检测沿用现有 Paddle 流水线，单字识别文本与字框用 CHAT 古籍识别模型（字符来源标记为 kraken+chat_rec）；字框由 Kraken 逐字符切分位置沿列重建（列宽单元框，位置经标注字框逐字校验）。整页识别与单行重识别均支持，行重识别时编辑器字框数量与识别字数一致则保留用户所画的框、仅回填文本。Kraken 运行于独立 conda 环境（kraken_bridge 子进程调起，缺失时返回带安装指引的错误），识别模型缺失时自动下载；现有 Paddle 链路行为不变。
- 新增 Kraken 古籍 OCR 可行性测试工具（不改动现有 Paddle 链路）：`install_kraken.bat` 创建独立 kraken conda 环境（GPU torch），`kraken_feasibility.py --download-models` 下载 CHAT 古籍分割/识别模型，`kraken_feasibility.py [书目录]` 对已标注页跑"自分割"与"标注列框+Kraken 识别"两种模式并生成对比报告。结论：CHAT 识别模型在标注列框上近乎完美（标题页 100% 一致、正文页 0.93 且差异主要是标点映射为"○"），但其分割模型不适合本书版式（欠分割），集成应采用"现有行分割 + Kraken 识别"的混合架构。
- 编辑器右侧属性栏不再随选中整体跳动：各分区训练进度固定显示在属性面板上方，选中/取消选中时只有下方属性区切换；属性面板内容可滚动，高过窗口时不再被裁掉。
- 修正训练进度标签错位并补齐单字区域进度：单字区域现在同时显示"单字识别"（char_det）与"单字候选分类"（char_cls）两层进度，此前 char_cls 被误标为"单字识别"且真正的单字识别进度从未显示。
- 编辑文字弹窗的候选区固定高度：打开弹窗与候选加载完成时尺寸一致，不再上下跳动。
- 修复整列识别文本按位分配与字框错位的问题（框在"或"上、文字却是"學"）：分配后对每个字框按框内像素做带置信度的校验识别，不一致且置信度足够高时以框内识别为准，整页识别与单行识别均生效。
- 在行裁切图上画新识别框后立即按框住的区域识别填字，不再默认显示"?"；识别期间删除或手动编辑过则不覆盖。
- 修复行裁切图上单字框命中范围与鼠标位置不一致的问题：命中容差从 12px 收紧到 3px、缩放手柄命中区从 24×24 收紧到 12×12，字框间隙不再被命中区盖住，画新框不会再误拖到相邻字框。
- 修复行裁切图上选中字框右下角缩放手柄难点的问题：手柄命中区改为角点居中的 16×16 并在普通命中测试之前优先判定（角点外侧、以及被相邻字框盖住的半边也能拖动缩放），手柄本身从 6×6 加大到 8×8 并加白描边更醒目。
- 消除行裁切图上绘制与命中的坐标偏移：外层边框容器不再给画布强加会内缩 2px 的显式尺寸（BoxDecoration 会按边框内缩 child，导致命中换算与绘制换算随位置偏差 2~4px），画布精确尺寸改由内部 SizedBox 保证；缩放手柄改为以框角点为中心绘制，可见方块中心即实际可拖顶点，不再差对角 4px。
- 行重识别按钮的加载状态改为按行独立显示，点击后只有该行按钮转圈；重识别请求带上该行当前字框（含手画/调整过的框），后端跳过自动拆字、仅对这些框重新 OCR 并保留框几何，行内无字框时才退回自动拆字，速度也更快。
- 大幅改善详细视图中拖动单字识别框的流畅度：行裁切图加独立重绘边界（RepaintBoundary）避免整页卡片每帧重栅格化；标注保存改为防抖合并写盘（拖拽期间不再逐帧写盘并刷新全书进度，翻页/显式保存/退出时立即落盘）。
- 详细视图行裁切图支持在空白处按住拖动直接手画新的单字识别框，画框后点本行“重新识别”即可自动填字。
- 详细视图第二列字块支持按住直接上下拖拽改变字在行内的位置（如把"？"拖到逗号上方），轻点不动仍是打开编辑弹窗，按住半秒后拖动同样有效；行文本与导出顺序同步更新。
- 三列（行图/字块/整行文字）统一为固定行高单元格，逐行严格水平对齐；默认字号从 30 提升到 40（上限 72），字号加减控件继续可用。
- 单字编辑弹窗不再把 Paddle 对古汉字退化出的英文字母猜测（m/g/s 一类）显示为候选，当前文字仍保留在输入框中可手动确认。
- 修复缩小页面后四角拖拽点难点击和角点外侧无法拖动的问题，调整大小时保留鼠标落点，不再突然跳动。
- 改善单字框的选择容差，并同步改善详细行视图中的单字选择和缩放。
- 训练页新增数据准备进度和剩余标注数量，按 n / s / m 模型调整所需数据量；单字分类支持三个模型规模。
- 修复从左上角或左下角缩放正文区时对侧右边界逐步漂移，缩放期间固定 pointer-down 时的对侧边界。
- 编辑器各分区属性面板持续显示对应模型的确认数据进度；无选中框时也显示当前分区进度，并显示 n / s / m 目标。
- 增加正文区、自然段、单行和单字的本页清除操作，按层级清除下游识别框并保留上游结果。
- 新增自然段后自动调用段内分行、拆字识别，并清理被替换旧行在其它段落中的历史引用。
- 自然段视图的“点击排序”现在按段框记录和保存顺序，不再跳转到行视图；行视图仍按行排序。
- 修复切换页面时空或损坏标注 JSON 触发 FormatException 的问题；切页加载加入异步请求代次校验，避免旧页面结果覆盖当前页面。
- OCR 服务收到空响应时改为返回明确错误，避免空响应直接进入 JSON 解码。
- 自然段内重新识别行时改为在原图统一识别后按段框筛选，避免裁剪段图导致行框尺寸随段宽缩放而失真。
- 修正大字号可读标题被误判为界栏线的问题；像“作者简介”这类标题会保留并参与自然段推断。
- 针对竖排下方标点扩展行框高度，横排末尾标点相应扩展宽度；自然段和单行识别均生效。
- 详细单字视图改为按字框逐项渲染，选中框会高亮对应文字；空文本显示占位符，避免框与文字数量看起来不一致。
- 候选字支持最多 10 个并显示置信度，合并分类模型与多次 OCR 结果；已有识别文字始终作为候选兜底。
- 增加当前页显式保存：保存时统一确认主区、自然段、行和单字，移除逐项确认按钮；翻页前会自动保存当前修改。
- 缩略图用蓝色表示当前页、绿色表示已保存页，并持久化每本书最后停留的页面，重新进入时自动恢复。
- 训练进度改为汇总整本书各页的已确认标注，翻页后不再归零；单字分类统计仅计入父行已确认且确实为单字符的样本。
- 单字详细视图的每行增加“重新识别本行单字”按钮，可仅重新切分并识别当前行。
