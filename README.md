# 字迹 · ZiJi

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/平台-Windows-blueviolet)]()
[![Flutter](https://img.shields.io/badge/前端-Flutter-02569B)]()
[![Python 3.10](https://img.shields.io/badge/后端-Python%203.10-3776AB)]()

**古籍竖排 OCR · 人工校对 · 模型训练反哺，一体化桌面工具。**

把一整本古籍扫描（PDF / 图片）变成可检索的文本：自动摆正、跨页拆分、版面与行列切分、整行识别，再由人逐级确认——而每一次确认，都在为下一次更准的识别积累训练数据。

> 全程本地：识别、训练、（可选的）AI 辅助都跑在你自己的机器上，书籍数据不出本机。

---

## 因「命迹」而生

字迹是为 [**命迹**](https://metafuyou.com) 而做的。

[命迹](https://metafuyou.com) 是一款国风命理排盘软件。做好命迹需要扎实的古籍文献底座——把命理古籍数字化成可检索、可引用的语料，遍寻没有趁手的竖排古籍 OCR 工具，于是自己动手，越做越重，成了这个独立项目。如今两边互为反哺：字迹产出校对语料与识字众包任务，命迹的用户群体参与识字确认，识别模型随之持续变强。

如果你对传统命理、古籍数字化感兴趣，欢迎了解命迹：

- **命迹官网**：<https://metafuyou.com>
- **交流 QQ 群**：`665088405`（字迹与命迹都在这里交流）

## 功能特性

- **整书流水线**：PDF/图片导入（逐页进度、可断点续跑）→ 摆正/弯曲矫正 → 跨页拆分 → 版面区/段落/行/单字逐级切分 → 整行识别。
- **双识别引擎**：Kraken（CHAT 古籍模型，可微调）为默认；PaddleOCR（PP-OCRv6 三档）按书可选、随时切换，另提供**整页直读「文本」视图**（引擎直接读整页出文本 + AI 校对，不拆标注管线）。
- **人工确认为核心**：识别结果一律视为初稿，正文区、段落、行、单字逐级确认后才进入训练集；全程可追溯（原图哈希、OCR 修订号、模型版本、稳定 UID，重新识别不覆盖旧标注）。
- **五层自训模型闭环**：单字检测 / 单字候选分类 / 行检测 / 段落检测 / 正文区检测（YOLO）——确认即自动增量导出，训练页看曲线、按轮挑检查点启用，模型管理页一键**打包发版**（Ed25519 签名的 `.zjpack`）。
- **Kraken 微调**：整行识别引擎可用自己的校对数据微调，适配不同朝代刊本风格。
- **AI 辅助（可选）**：本地 Ollama / 外部模型 API 双通道——单字候选、标点、整行裁决、识别框诊断、整页版面预标注。
- **墨迹归类**：楷体字形模板比对，易混字标红提醒，全书批量归类复核。
- **朝代基准**：先秦楚简 → 汉魏简帛 → 南北朝写经 → 宋元刻本 → 明清刻本五张固定样张，用同一管线量化各时期字准确率 / CER / 错字 TOP，模型迭代前后一键对比。
- **插件体系（可导入扩展）**：Obsidian 式外挂插件——独立的 `.zjplugin` 功能包运行时导入安装（HTML/JS 编写，软件提供书库读写、后端调用、网络代理等桥 API），后台任务与功能入口随开关启停；开发指南见 [docs/插件开发.md](docs/插件开发.md)。
- **表格与插图标记**、**众包识字任务包**（与命迹的识字任务体系对接）、多种**导出格式**。

完整功能说明见 **[使用手册](docs/使用手册.md)**，逐版本演进见 **[更新日志](CHANGELOG.md)**。

## 安装

到 **Releases** 页下载 Windows 安装包（自带预置识别模型，装完即可离线识别，无需联网、无需配置环境）。

## 从源码运行

```text
① Python 后端（conda，Python 3.10）
   cd python_service
   install.bat          # 创建 paddle 环境：服务依赖 + YOLO
   install_kraken.bat   # Kraken 独立环境：整行识别引擎

② Flutter 桌面端
   cd flutter_app
   flutter pub get
   flutter run -d windows        # 开发运行
   flutter build windows --release
```

应用会自动拉起后端服务并握手版本，无需手动起进程。

**模型从哪来**：仓库不含模型权重——Kraken 识别模型首次识别时自动下载（约 42MB），YOLO 基线在首次训练时由 ultralytics 自动下载；随安装包分发的正式模型包（`.zjpack`，Ed25519 签名，含各层启用中的自训模型）见 Releases。想参与训练反哺，从校对确认开始即可，数据集自动积累在你本机。

**构建安装包**（维护者）：`installer\build_installer.bat`。VC++ 运行库安装器 `VC_redist.x64.exe` 体积大不入库，需从[微软官网](https://aka.ms/vs/17/release/vc_redist.x64.exe)下载后放到 `installer/` 目录。

## 模型与许可（open core）

- **代码**：[AGPL-3.0](LICENSE)。选 AGPL 的现实原因：识别管线依赖 ultralytics（AGPL-3.0）与 PyMuPDF（AGPL-3.0），开源是最干净的合规路径；同时最强传染性也防止闭源分叉。
- **模型**：`.zjpack` 模型包及其条目**不在 AGPL 范围内**，保留所有权利（`all rights reserved`），经签名的发行包随安装包 / Releases 分发，许可条款见包内 manifest 与发布说明。训练数据集同样属于使用者本地，不随仓库分发。

### 第三方组件

| 组件 | 许可 | 用途 |
|---|---|---|
| [ultralytics](https://github.com/ultralytics/ultralytics) YOLO | AGPL-3.0 | 五层检测/分类模型训练与推理 |
| [Kraken](https://github.com/mittagkraken/kraken) | Apache-2.0 | 整行文字识别引擎（独立环境） |
| CHAT 底模（colibrisson/CHAT_models） | 见其仓库 | Kraken 中文底模，自动下载 |
| [LXGW WenKai](https://github.com/lxgw/LxgwWenKai) | SIL OFL 1.1 | 墨迹归类楷体字形（`resources/fonts/`） |
| OpenCC | Apache-2.0 | 繁简转换 |
| PyMuPDF | AGPL-3.0 | PDF 转图 |

## 目录结构

```text
flutter_app/     Flutter 桌面端（书库、编辑器、训练页、模型管理…）
python_service/  Python 后端（FastAPI：切分/识别/训练/打包，Kraken 守护进程）
installer/       Inno Setup 安装包脚本
docs/            使用手册等文档
test_images/     朝代基准固定样张与基准释文（公有域古籍）
```

## 交流与支持

- **QQ 群**：`665088405` —— 使用问题、古籍数字化心得、模型训练交流都在群里
- **命迹官网**：<https://metafuyou.com> —— 本项目为之而生的排盘软件

## 致谢

所有为古籍数字化默默校字的人。
