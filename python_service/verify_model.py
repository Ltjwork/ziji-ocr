# -*- coding: utf-8 -*-
"""墨迹比对模型（siamese 双塔）的网络定义：训练（train_worker）与推理
（char_verify）共用本模块——torch.save(整个模型) 的 pickle 依赖类定义
可导入，两侧必须同一文件。

输入：单通道 128×128 二值图（墨=1.0，char_verify._prepare 的归一化
口径）；输出：L2 归一化的 64 维嵌入，两塔共享权重，相似度 = 余弦。
纯 CPU 推理时整页 batched forward 毫秒级。"""

import torch
import torch.nn as nn

CANVAS = 128
EMBED_DIM = 64


class PairEncoder(nn.Module):
    """1×128×128 二值图 → 64 维 L2 归一化嵌入。"""

    def __init__(self, embed_dim: int = EMBED_DIM):
        super().__init__()

        def block(cin: int, cout: int) -> nn.Sequential:
            return nn.Sequential(
                nn.Conv2d(cin, cout, 3, padding=1),
                nn.BatchNorm2d(cout),
                nn.ReLU(inplace=True),
                nn.MaxPool2d(2),
            )

        self.net = nn.Sequential(
            block(1, 32),      # 64×64
            block(32, 64),     # 32×32
            block(64, 128),    # 16×16
            block(128, 128),   # 8×8
            nn.AdaptiveAvgPool2d(1),
            nn.Flatten(),
            nn.Linear(128, embed_dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return nn.functional.normalize(self.net(x), dim=1)
