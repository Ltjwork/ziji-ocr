# 墨迹对齐改进方案：基于特征点匹配的开发计划

> **最后更新**: 2026-10-11  
> **状态**: ✅ 已批准，等待实施  
> **负责人**: AI Assistant

---

## 📋 项目概述

**目标**：用基于特征点匹配 + RANSAC 的鲁棒对齐方案替代现有的投影互相关方法，解决列距回声峰误判、版式适应性差、参数敏感等核心问题。

**核心优势**：
- ✅ **抗周期性干扰**：特征点离散分布，无列距回声峰误判
- ✅ **版式适应性强**：支持不规整版式、批注、缺字页
- ✅ **参数鲁棒**：RANSAC自适应，跨书籍通用
- ✅ **可诊断性强**：可视化匹配点对，失败原因一目了然
- ✅ **零破坏性集成**：保留旧方案作为fallback，接口完全兼容

---

## 🎯 技术方案对比

| 维度 | 旧方案（投影互相关） | 新方案（特征点+RANSAC） |
|------|---------------------|------------------------|
| **抗周期性干扰** | ❌ 列距回声峰误判严重 | ✅ 特征点离散，无周期假峰 |
| **版式适应性** | ⚠️ 需要行列整齐的规整版式 | ✅ 支持不规整版式、批注、缺字 |
| **参数敏感度** | ❌ 高通窗口/置信度需手动调 | ✅ RANSAC自适应，参数通用 |
| **失败诊断** | ⚠️ 只有"置信度低" | ✅ 可视化匹配点对 |
| **计算复杂度** | O(n·m·maxShift²) | O(k²)，k<<n·m |
| **鲁棒性** | ⚠️ 纸面定位失败即崩 | ✅ RANSAC抗50%外点 |

---

## 📐 架构设计

### 数据流管线

```
原图(RGBA) 
  ↓
[1] 纸面定位 + Otsu二值化墨迹 (复用现有 ink_align.dart)
  ↓
[2] 墨迹形态学特征提取
  │  • 连通域质心 (Phase 1: MVP核心)
  │  • Harris角点 (Phase 2: 增强精度)
  │  • 界栏交叉点 (Phase 2+: 针对有行格古籍)
  ↓
[3] 局部描述子构建
  │  • 8方向墨迹密度直方图 (Phase 1)
  │  • 64维网格密度 + 主方向对齐 (Phase 2)
  ↓
[4] 特征匹配
  │  • 暴力最近邻 + Lowe's距离比测试
  │  • 交叉验证过滤误匹配
  ↓
[5] RANSAC仿射变换估计
  │  • 随机采样3点估计变换
  │  • 统计内点（误差<5px），迭代1000次
  │  • 返回最优变换 + 置信度
  ↓
[6] 最小二乘精细优化
  │  • 用全部内点重拟合，提升精度
```

### 核心数据结构

```dart
/// 单个特征点
class InkFeaturePoint {
  final Offset position;        // 工作画布坐标
  final double response;        // 特征强度（质心=面积，角点=响应值）
  final Float64List descriptor; // 描述子（Phase1: 8维，Phase2: 64维）
  final FeatureType type;       // centroid/corner/junction
}

/// 单页特征集
class InkPageFeatures {
  final List<InkFeaturePoint> points;  // 300-800个特征点
  final Offset paperCenter;            // 纸面中心（先验信息）
  final int extractionTimeMs;
}

/// RANSAC对齐结果
class RansacAlignResult {
  final AffineTransform2D transform;   // 估计的仿射变换
  final List<FeatureMatch> inliers;    // 内点集
  final int totalMatches;
  final double confidence;             // 内点比例
  final bool aligned;
  final String reason;                 // 失败原因
}
```

---

## 🗓️ 开发计划（渐进式4个Phase）

### **Phase 1: 最小可行原型 (MVP) - 3工作日**

**目标**：用最简单的特征（连通域质心）+ 最简单描述子（8方向密度）跑通完整流程，验证RANSAC效果。

#### Day 1: 特征提取模块 (6小时)

**创建 `lib/services/feature_points.dart`**

- [ ] **连通域分析** `_findConnectedComponents()`
  - 输入：二值化墨迹 `Uint8List`（从现有Otsu来）
  - 算法：两遍扫描法（first pass标记，second pass合并）
  - 过滤：保留面积200-5000像素的块
  - 输出：每个连通域的质心坐标（重心）

- [ ] **简单描述子** `_computeSimpleDescriptor()`
  - 在质心周围40×40像素窗口
  - 划分8个扇区（45°一个，类极坐标）
  - 统计每扇区墨迹密度
  - 归一化为单位向量（L2范数）

- [ ] **封装API**
  ```dart
  InkPageFeatures extractFeaturePoints({
    required Uint8List rgba,
    required int imgW, imgH,
    required Rect paperBounds,  // 复用现有纸面定位
    FeatureSettings settings = kFeatureDefaults,
  });
  ```

**创建 `test/feature_points_test.dart`**

- [ ] 测试用例1：合成单个20×30文字块，验证质心在中心
- [ ] 测试用例2：合成8列竖排（每列8个字），验证提取~64个质心
- [ ] 测试用例3：验证描述子对旋转45°的响应变化

#### Day 2: 特征匹配 + RANSAC (7小时)

**在 `feature_points.dart` 实现匹配模块**

- [ ] **特征匹配** `_matchFeatures()`
  - 暴力最近邻：每个ref点找page中最近的2个点
  - **Lowe's ratio test**: 保留 dist1/dist2 < 0.75 的匹配
  - **交叉验证**: ref→page 和 page→ref 双向一致才保留

- [ ] **RANSAC估计** `_ransacAffine()`
  ```dart
  // 迭代1000次或提前收敛
  for (iter in 1..1000) {
    sample = matches.randomSample(3);  // 3对点定仿射变换
    transform = estimateAffineFrom3Points(sample);
    inliers = countInliers(transform, allMatches, threshold: 5.0);
    if (inliers.length > best) { best = inliers; bestTransform = transform; }
  }
  ```

- [ ] **精细优化** `_leastSquaresRefine()`
  - 用全部内点做最小二乘拟合
  - 提升变换参数精度

**扩展测试**

- [ ] 测试用例4：合成ref页 + 平移(10, -5)px，验证恢复误差<0.5px
- [ ] 测试用例5：加入50%随机噪声匹配，验证RANSAC仍能收敛
- [ ] 测试用例6：小角度旋转2°，验证仿射估计精度

#### Day 3: 集成到现有管线 (5小时)

**修改 `lib/services/ink_align.dart`**

- [ ] 新增方法枚举
  ```dart
  enum AlignMethod { projection, featureMatching }
  ```

- [ ] 重构主入口为路由
  ```dart
  InkAlignResult computeInkAlignments({
    required Map<int, dynamic> profiles,  // InkPageProfile 或 InkPageFeatures
    AlignMethod method = AlignMethod.featureMatching,
    ...
  }) {
    return method == AlignMethod.projection
        ? _computeByProjection(...)
        : _computeByFeatures(...);
  }
  ```

- [ ] 实现 `_computeByFeatures()`
  - 选参考页（特征点数中位数）
  - 逐页调用 `matchAndAlign()`
  - 平移中位归零（保持整体居中）
  - 计算全局缩放
  - 返回统一的 `InkAlignResult`（复用现有数据结构）

**修改 `lib/pages/book_overlay_page.dart`**

- [ ] 在工具栏添加对齐方法切换按钮
- [ ] `_computeInkAlign()` 根据选择走不同分支
- [ ] 日志区分："[特征点对齐]" vs "[投影对齐]"

**端到端测试**

- [ ] 选取3-5页真实古籍图测试
- [ ] 对比两种方法：对齐成功率、平移误差、耗时
- [ ] 记录性能：特征提取+匹配+RANSAC总耗时

#### Phase 1 验收标准

- ✅ 能从真实古籍页提取300-800个连通域质心
- ✅ RANSAC在50%外点下仍能收敛到正确变换
- ✅ 合成数据平移误差<2px
- ✅ 真实古籍至少3页对齐成功（内点>30%）
- ✅ 性能：600px图特征提取<100ms/页
- ✅ 单元测试覆盖率>80%

---

### **Phase 2: 增强特征与描述子 - 4工作日**

**目标**：加入Harris角点检测，升级描述子为64维网格型，提升匹配精度和鲁棒性。

#### Day 4: Harris角点检测 (6小时)

- [ ] 实现梯度计算 `_computeGradients()`
  - Sobel算子求Ix, Iy
  - 窗口3×3

- [ ] 实现Harris响应 `_harrisResponse()`
  - 结构张量 M = [Ix², IxIy; IxIy, Iy²]
  - 响应值 R = det(M) - 0.04·trace(M)²
  - 非极大值抑制（3×3窗口）

- [ ] 提取角点 `_extractCorners()`
  - 阈值：R > mean + 2·std
  - 保留Top 500个最强响应点

- [ ] 测试用例7：合成L型直角块，验证角点被检出

#### Day 5-6: 64维网格描述子 + 旋转不变性 (10小时)

- [ ] 实现增强描述子 `_compute64DDescriptor()`
  - 40×40窗口 → 8×8网格
  - 每格统计墨迹密度（可用积分图加速）
  - 可选：加入4方向梯度直方图
  - 归一化为单位向量

- [ ] 实现主方向对齐（旋转不变）
  - 计算特征点邻域主梯度方向
  - 描述子窗口按主方向旋转

- [ ] 升级匹配算法
  - 余弦相似度替代欧氏距离
  - 自适应ratio test阈值

- [ ] 测试用例8：验证描述子对±10°旋转鲁棒

#### Day 7: 界栏交叉点检测（针对古籍）(6小时)

- [ ] 简化版Hough直线检测 `_detectLines()`
  - 检测长度>100px的线段
  - 方向过滤：接近水平/垂直（±5°）

- [ ] 交叉点提取 `_findJunctions()`
  - 横竖线交点作为特征点
  - 适用于有界栏的古籍版式

- [ ] 自适应特征选择
  - 优先级：交叉点 > 角点 > 质心
  - 混合策略保证空间分布均匀

#### Phase 2 验收标准

- ✅ Harris角点响应值正确（合成验证）
- ✅ 64维描述子对旋转鲁棒（±10°内点率>60%）
- ✅ 界栏古籍能检出交叉点特征
- ✅ 匹配精度提升（内点比例从40%→60%+）
- ✅ 性能：特征提取<150ms/页（含角点检测）

---

### **Phase 3: 可视化与诊断工具 - 2工作日**

**目标**：提供直观的可视化界面，帮助理解对齐过程和诊断失败原因。

#### Day 8: 特征点可视化 (6小时)

- [ ] 在 `book_overlay_page.dart` 添加可视化层
  - `_paintFeaturePoints()`: 绘制特征点
    - 颜色编码：质心=蓝，角点=红，交叉点=绿
    - 点大小映射响应强度
  - `_paintMatches()`: 绘制匹配连线
    - 内点=绿线，外点=红虚线
    - 显示内点比例百分比

- [ ] 添加工具栏控制
  - "显示特征点" / "显示匹配" 开关
  - 状态栏："提取X点，匹配Y对，内点Z个"

#### Day 9: 失败诊断报告 (5小时)

- [ ] 增强日志系统
  ```
  第3页：提取312个特征点（质心205, 角点107）
        与参考页匹配58对，ratio test通过41对
        RANSAC内点32个（78%），变换：旋转1.2°，平移(-8.3, 12.1)px
  ```

- [ ] 失败原因分类
  - "特征点不足"（<100个）
  - "匹配数不足"（<15对）
  - "内点比例过低"（<30%）
  - "内点分布退化"（共线）

- [ ] 导出Markdown诊断报告
  - 统计表格、失败页面清单
  - 可视化截图（可选）

#### Phase 3 验收标准

- ✅ 特征点叠加显示清晰可见
- ✅ 匹配连线直观反映对齐质量
- ✅ 失败页面能快速定位原因
- ✅ 诊断报告包含可操作建议

---

### **Phase 4: 高级优化（可选）- 3工作日**

**目标**：多尺度优化、自适应参数、性能极致优化。

#### Day 10: 多尺度迭代对齐 (6小时)

- [ ] 实现金字塔对齐
  - 300px粗对齐（快速估计）
  - 600px精细对齐（正常精度）
  - 局部800px重采样（亚像素精度）
  - 每层用上层结果初始化

#### Day 11-12: 自适应参数与极致优化 (10小时)

- [ ] 自适应阈值
  - 根据匹配质量动态调ratio test
  - 根据版式自动选特征类型
  - RANSAC迭代次数自适应

- [ ] 性能优化
  - Isolate并行特征提取（4-8页batch）
  - 描述子计算向量化
  - 内存池复用
  - 特征点缓存（页面未变时跳过）

- [ ] 边界情况处理
  - 空白页/扉页检测（<50点跳过）
  - 版式差异过大检测（<10匹配标记异常）
  - 退化几何检测（内点共线）

#### Phase 4 验收标准

- ✅ 多尺度对齐时间减少30%
- ✅ 自适应参数减少手动调参
- ✅ 极端情况优雅降级

---

## 📊 性能基准目标

| 指标 | Phase 1 (MVP) | Phase 2 (增强) | Phase 4 (优化) |
|------|--------------|---------------|---------------|
| **特征提取** | <100ms/页 | <150ms/页 | <80ms/页 |
| **特征匹配** | <50ms/对 | <50ms/对 | <30ms/对 |
| **RANSAC估计** | <20ms/对 | <20ms/对 | <15ms/对 |
| **总耗时(10页)** | <2秒 | <2.5秒 | <1.5秒 |

---

## 🧪 测试策略

### 单元测试

```dart
// test/feature_points_test.dart
group('连通域提取', () {
  test('单个文字块质心', ...);
  test('8列竖排64个质心', ...);
  test('边界裁切处理', ...);
});

group('RANSAC对齐', () {
  test('平移10px恢复', ...);
  test('旋转2°恢复', ...);
  test('50%外点鲁棒性', ...);
});
```

### 真实数据测试集

准备3类测试图：
1. **规整版式**：行列整齐（验证基础功能）
2. **复杂版式**：批注、缺字、污损（验证鲁棒性）
3. **极端情况**：扉页、插图、倾斜（验证边界处理）

---

## 📁 代码组织

```
ocr/flutter_app/
├── lib/services/
│   ├── ink_align.dart              # 主入口（路由两种方法）
│   ├── feature_points.dart         # Phase 1-2: 特征提取
│   ├── feature_matching.dart       # Phase 1-2: 匹配+RANSAC
│   └── alignment_diagnostics.dart  # Phase 3: 诊断工具
├── lib/models/
│   └── feature_models.dart         # 数据结构定义
└── test/
    ├── feature_points_test.dart
    ├── feature_matching_test.dart
    └── integration/alignment_comparison_test.dart
```

---

## 🚀 里程碑

### Sprint 1: MVP验证 (Week 1, Day 1-3)
- **交付**: 可运行的特征点对齐原型
- **标准**: 至少3页真实图对齐成功
- **Review**: 与投影法对比效果，决定继续

### Sprint 2: 生产就绪 (Week 2, Day 4-7)
- **交付**: 增强特征+描述子，通过10+页测试集
- **标准**: 性能与鲁棒性达标

### Sprint 3: 工具完善 (Week 2-3, Day 8-9)
- **交付**: 可视化诊断工具，用户文档
- **标准**: 可用性测试通过

### Sprint 4: 极致优化 (Week 3, Day 10-12, 可选)
- **交付**: 多尺度优化，性能提升30%+
- **标准**: Benchmark对比达标

---

## ⚠️ 风险与应对

| 风险 | 概率 | 影响 | 应对策略 |
|------|------|------|---------|
| RANSAC收敛慢 | 中 | 中 | 自适应迭代次数，提前终止 |
| 特征点不足 | 低 | 高 | 混合多种特征类型，降级到投影法 |
| 内存占用过高 | 低 | 中 | 特征点数上限，描述子降维 |
| 性能不达标 | 低 | 中 | Isolate并行，缓存优化 |
| 效果不如投影法 | 低 | 高 | 保留双方法切换，针对性改进 |

---

## 📚 参考文献

### 理论基础
- Lowe, D. G. (2004). "Distinctive Image Features from Scale-Invariant Keypoints" (SIFT)
- Fischler & Bolles (1981). "Random Sample Consensus" (RANSAC)
- Harris & Stephens (1988). "A Combined Corner and Edge Detector"

### 工程参考
- OpenCV Feature Detection: https://docs.opencv.org/4.x/d7/d8b/tutorial_py_lucas_kanade.html
- Flutter Image Processing: https://api.flutter.dev/flutter/dart-ui/Image-class.html

---

## ✅ 下一步行动

1. **确认计划** ✅ 已完成
2. **环境准备**：准备3-5页真实古籍测试图集
3. **启动Phase 1 Day 1**：创建 `lib/services/feature_points.dart`，实现连通域提取

---

*文档版本: v1.0*  
*创建日期: 2026-10-11*  
*批准状态: ✅ 已批准*
