# -*- coding: utf-8 -*-
"""test_segmenter 已按被测域拆分（2026-09-30）：

- test_seg_core.py        切分核心几何（SegmenterGeometryTests）
- test_seg_kraken_cuts.py Kraken 字切分器（KrakenCharSplitterTests）
- test_seg_punct.py       标点拆分（PunctSplit / 组件间隙 / 尾列救援）
- test_seg_lines.py       行框与收紧（扩展/边界/收紧/延展/钳回）
- test_seg_layout.py      版面（横排/摆正映射/双栏/层级包含）

本文件保留为入口说明；运行方式不变：unittest/pytest 自动发现。
"""
