# 特征点对齐算法技术参考

> **用途**: Phase 1-2 实现时的算法细节速查手册  
> **适用**: 纯Dart实现，无第三方库依赖

---

## 1️⃣ 连通域分析（Two-Pass Algorithm）

### 算法原理

找出二值图中所有连通的墨迹区域，计算每个区域的质心作为特征点。

### Dart实现伪代码

```dart
// 输入：二值化墨迹图 binary (1=墨迹, 0=背景)
// 输出：连通域列表，每个域包含像素坐标

class Component {
  List<Offset> pixels = [];
  Offset get centroid {
    if (pixels.isEmpty) return Offset.zero;
    double sumX = 0, sumY = 0;
    for (final p in pixels) {
      sumX += p.dx;
      sumY += p.dy;
    }
    return Offset(sumX / pixels.length, sumY / pixels.length);
  }
  int get area => pixels.length;
}

List<Component> findConnectedComponents(Uint8List binary, int w, int h) {
  // First pass: 标记每个像素的临时标签
  final labels = List.filled(w * h, 0);
  final parent = <int, int>{};  // 并查集
  var nextLabel = 1;
  
  int find(int x) {
    if (parent[x] == x) return x;
    return parent[x] = find(parent[x]!);
  }
  
  void union(int a, int b) {
    final rootA = find(a);
    final rootB = find(b);
    if (rootA != rootB) parent[rootB] = rootA;
  }
  
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (binary[idx] == 0) continue;  // 背景跳过
      
      // 检查左边和上边的邻居
      final left = (x > 0) ? labels[idx - 1] : 0;
      final up = (y > 0) ? labels[idx - w] : 0;
      
      if (left == 0 && up == 0) {
        // 新连通域
        labels[idx] = nextLabel;
        parent[nextLabel] = nextLabel;
        nextLabel++;
      } else if (left != 0 && up == 0) {
        labels[idx] = left;
      } else if (left == 0 && up != 0) {
        labels[idx] = up;
      } else {
        // 合并两个连通域
        labels[idx] = left;
        union(left, up);
      }
    }
  }
  
  // Second pass: 统一标签为根标签，收集像素
  final components = <int, Component>{};
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (labels[idx] == 0) continue;
      final root = find(labels[idx]);
      components.putIfAbsent(root, () => Component());
      components[root]!.pixels.add(Offset(x.toDouble(), y.toDouble()));
    }
  }
  
  // 过滤面积不在[200, 5000]的块
  return components.values
      .where((c) => c.area >= 200 && c.area <= 5000)
      .toList();
}
```

### 参数调优

- **面积阈值下限200**: 过滤噪点和标点符号
- **面积阈值上限5000**: 过滤整页污损或粘连块
- 对于600px宽图，典型文字块面积~500-2000像素

---

## 2️⃣ 8方向描述子（Sector-based Density Histogram）

### 算法原理

在特征点周围40×40窗口，划分8个扇区（45°一个），统计每个扇区的墨迹密度，形成8维描述子。

### Dart实现伪代码

```dart
Float64List computeSimpleDescriptor(
  Uint8List binary,
  int w, int h,
  Offset center,
  {int windowSize = 40}
) {
  final half = windowSize ~/ 2;
  final desc = Float64List(8);  // 8个扇区
  final counts = List.filled(8, 0);
  
  for (var dy = -half; dy < half; dy++) {
    for (var dx = -half; dx < half; dx++) {
      final x = (center.dx + dx).round();
      final y = (center.dy + dy).round();
      if (x < 0 || x >= w || y < 0 || y >= h) continue;
      
      final idx = y * w + x;
      if (binary[idx] == 0) continue;  // 背景
      
      // 计算角度 [0, 2π)
      final angle = math.atan2(dy.toDouble(), dx.toDouble()) + math.pi;
      // 映射到扇区 [0, 7]
      final sector = ((angle / (2 * math.pi)) * 8).floor() % 8;
      counts[sector]++;
    }
  }
  
  // L2归一化
  var sum = 0.0;
  for (var i = 0; i < 8; i++) {
    sum += counts[i] * counts[i];
  }
  final norm = math.sqrt(sum);
  if (norm > 1e-6) {
    for (var i = 0; i < 8; i++) {
      desc[i] = counts[i] / norm;
    }
  }
  
  return desc;
}
```

### 距离度量

```dart
double euclideanDistance(Float64List a, Float64List b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    final diff = a[i] - b[i];
    sum += diff * diff;
  }
  return math.sqrt(sum);
}
```

---

## 3️⃣ 特征匹配（Lowe's Ratio Test + 交叉验证）

### 算法原理

1. **最近邻搜索**: 每个ref特征点在page特征点中找最近和次近的2个
2. **Lowe's ratio test**: 保留 `dist1 / dist2 < 0.75` 的匹配
3. **交叉验证**: ref→page 和 page→ref 双向一致才最终保留

### Dart实现伪代码

```dart
class FeatureMatch {
  final int refIdx;
  final int pageIdx;
  final double distance;
  const FeatureMatch(this.refIdx, this.pageIdx, this.distance);
}

List<FeatureMatch> matchFeatures(
  List<InkFeaturePoint> refPts,
  List<InkFeaturePoint> pagePts,
  {double ratioThreshold = 0.75}
) {
  // Step 1: ref → page 匹配
  final forwardMatches = <FeatureMatch>[];
  for (var i = 0; i < refPts.length; i++) {
    var bestDist = double.infinity;
    var secondBestDist = double.infinity;
    var bestIdx = -1;
    
    for (var j = 0; j < pagePts.length; j++) {
      final dist = euclideanDistance(
        refPts[i].descriptor,
        pagePts[j].descriptor
      );
      if (dist < bestDist) {
        secondBestDist = bestDist;
        bestDist = dist;
        bestIdx = j;
      } else if (dist < secondBestDist) {
        secondBestDist = dist;
      }
    }
    
    // Lowe's ratio test
    if (bestDist < ratioThreshold * secondBestDist && bestIdx >= 0) {
      forwardMatches.add(FeatureMatch(i, bestIdx, bestDist));
    }
  }
  
  // Step 2: page → ref 匹配
  final backwardMap = <int, int>{};  // pageIdx → refIdx
  for (var j = 0; j < pagePts.length; j++) {
    var bestDist = double.infinity;
    var secondBestDist = double.infinity;
    var bestIdx = -1;
    
    for (var i = 0; i < refPts.length; i++) {
      final dist = euclideanDistance(
        pagePts[j].descriptor,
        refPts[i].descriptor
      );
      if (dist < bestDist) {
        secondBestDist = bestDist;
        bestDist = dist;
        bestIdx = i;
      } else if (dist < secondBestDist) {
        secondBestDist = dist;
      }
    }
    
    if (bestDist < ratioThreshold * secondBestDist && bestIdx >= 0) {
      backwardMap[j] = bestIdx;
    }
  }
  
  // Step 3: 交叉验证
  return forwardMatches.where((m) {
    return backwardMap[m.pageIdx] == m.refIdx;
  }).toList();
}
```

### 参数调优

- **ratioThreshold=0.75**: SIFT论文推荐值，可在0.7-0.85之间调整
- 过低→匹配数少但精度高
- 过高→匹配数多但误匹配增加

---

## 4️⃣ RANSAC仿射变换估计

### 算法原理

随机采样最小点集（3对点）估计仿射变换，迭代找到最多内点的模型。

### 仿射变换模型

6参数仿射变换：
```
x' = a·x + b·y + tx
y' = c·x + d·y + ty
```
矩阵形式：`[x'] = [a b tx] [x]`
          `[y']   [c d ty] [y]`
                            [1]

### 3对点估计仿射变换

```dart
// 输入：3对匹配点 (refPt, pagePt)
// 输出：6参数 [a, b, c, d, tx, ty]
Float64List estimateAffineFrom3Points(
  List<(Offset, Offset)> matches
) {
  assert(matches.length == 3);
  
  // 构造线性方程组 Ax = b
  // [x1 y1 1  0  0  0] [a ]   [x1']
  // [0  0  0  x1 y1 1] [b ]   [y1']
  // [x2 y2 1  0  0  0] [tx]   [x2']
  // [0  0  0  x2 y2 1] [c ] = [y2']
  // [x3 y3 1  0  0  0] [d ]   [x3']
  // [0  0  0  x3 y3 1] [ty]   [y3']
  
  final A = Float64List(36);  // 6×6矩阵
  final b = Float64List(6);
  
  for (var i = 0; i < 3; i++) {
    final ref = matches[i].$1;
    final page = matches[i].$2;
    
    // X方程
    A[i * 12 + 0] = ref.dx;
    A[i * 12 + 1] = ref.dy;
    A[i * 12 + 2] = 1;
    b[i * 2] = page.dx;
    
    // Y方程
    A[i * 12 + 9] = ref.dx;
    A[i * 12 + 10] = ref.dy;
    A[i * 12 + 11] = 1;
    b[i * 2 + 1] = page.dy;
  }
  
  // 求解 Ax=b (用高斯消元或SVD)
  return solveLinearSystem(A, b);
}
```

### RANSAC主循环

```dart
class RansacResult {
  final Float64List transform;  // [a, b, c, d, tx, ty]
  final List<FeatureMatch> inliers;
  final double confidence;
  
  const RansacResult(this.transform, this.inliers, this.confidence);
}

RansacResult ransacAffine(
  List<FeatureMatch> matches,
  List<InkFeaturePoint> refPts,
  List<InkFeaturePoint> pagePts,
  {int maxIterations = 1000, double inlierThreshold = 5.0}
) {
  if (matches.length < 3) {
    return RansacResult(
      Float64List.fromList([1, 0, 0, 1, 0, 0]),  // identity
      [],
      0.0
    );
  }
  
  var bestTransform = Float64List(6);
  var bestInliers = <FeatureMatch>[];
  final rng = math.Random();
  
  for (var iter = 0; iter < maxIterations; iter++) {
    // 随机采样3对点
    final sample = <(Offset, Offset)>[];
    final indices = <int>{};
    while (indices.length < 3) {
      indices.add(rng.nextInt(matches.length));
    }
    for (final i in indices) {
      final m = matches[i];
      sample.add((refPts[m.refIdx].position, pagePts[m.pageIdx].position));
    }
    
    // 估计变换
    final transform = estimateAffineFrom3Points(sample);
    
    // 统计内点
    final inliers = <FeatureMatch>[];
    for (final m in matches) {
      final ref = refPts[m.refIdx].position;
      final page = pagePts[m.pageIdx].position;
      final predicted = applyAffine(transform, ref);
      final error = (predicted - page).distance;
      if (error < inlierThreshold) {
        inliers.add(m);
      }
    }
    
    // 更新最优模型
    if (inliers.length > bestInliers.length) {
      bestInliers = inliers;
      bestTransform = transform;
    }
    
    // 提前终止（99%置信度找到好模型）
    if (inliers.length > matches.length * 0.7) break;
  }
  
  final confidence = bestInliers.length / matches.length;
  return RansacResult(bestTransform, bestInliers, confidence);
}

Offset applyAffine(Float64List t, Offset p) {
  return Offset(
    t[0] * p.dx + t[1] * p.dy + t[4],
    t[2] * p.dx + t[3] * p.dy + t[5]
  );
}
```

### 参数调优

- **maxIterations=1000**: 保证99%概率找到好模型（假设50%内点）
- **inlierThreshold=5.0px**: 根据图像分辨率调整，600px宽用5px合适
- **提前终止条件**: 内点>70%时可提前返回

---

## 5️⃣ 最小二乘精细优化

### 算法原理

用RANSAC找到的全部内点重新拟合仿射变换，比随机3点估计更精确。

### Dart实现伪代码

```dart
Float64List leastSquaresRefine(
  List<FeatureMatch> inliers,
  List<InkFeaturePoint> refPts,
  List<InkFeaturePoint> pagePts
) {
  final n = inliers.length;
  if (n < 3) return Float64List.fromList([1, 0, 0, 1, 0, 0]);
  
  // 构造超定方程组 Ax=b (2n个方程，6个未知数)
  final A = Float64List(n * 12);  // n×6矩阵
  final b = Float64List(n * 2);
  
  for (var i = 0; i < n; i++) {
    final m = inliers[i];
    final ref = refPts[m.refIdx].position;
    final page = pagePts[m.pageIdx].position;
    
    // X方程: a·x + b·y + tx = x'
    A[i * 12 + 0] = ref.dx;
    A[i * 12 + 1] = ref.dy;
    A[i * 12 + 2] = 1;
    b[i * 2] = page.dx;
    
    // Y方程: c·x + d·y + ty = y'
    A[i * 12 + 9] = ref.dx;
    A[i * 12 + 10] = ref.dy;
    A[i * 12 + 11] = 1;
    b[i * 2 + 1] = page.dy;
  }
  
  // 求解最小二乘 (A^T A)x = A^T b
  // 可用QR分解或正规方程
  return solveLeastSquares(A, b);
}
```

### 正规方程实现

```dart
Float64List solveLeastSquares(Float64List A, Float64List b) {
  // 计算 A^T A 和 A^T b
  final AtA = Float64List(36);  // 6×6
  final Atb = Float64List(6);
  
  final rows = b.length ~/ 2;
  for (var i = 0; i < rows; i++) {
    for (var j = 0; j < 6; j++) {
      final aij = A[i * 12 + j];
      Atb[j] += aij * b[i * 2];
      for (var k = 0; k < 6; k++) {
        final aik = A[i * 12 + k];
        AtA[j * 6 + k] += aij * aik;
      }
    }
  }
  
  // 求解 6×6 线性系统（高斯消元或Cholesky分解）
  return solveLinearSystem6x6(AtA, Atb);
}
```

---

## 6️⃣ 实用工具函数

### 高斯消元求解线性系统

```dart
Float64List solveLinearSystem6x6(Float64List A, Float64List b) {
  // A是6×6矩阵（行主序），b是6维向量
  final n = 6;
  final aug = Float64List(n * (n + 1));
  
  // 构造增广矩阵 [A|b]
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      aug[i * (n + 1) + j] = A[i * n + j];
    }
    aug[i * (n + 1) + n] = b[i];
  }
  
  // 前向消元
  for (var k = 0; k < n; k++) {
    // 找主元
    var maxRow = k;
    for (var i = k + 1; i < n; i++) {
      if (aug[i * (n + 1) + k].abs() > aug[maxRow * (n + 1) + k].abs()) {
        maxRow = i;
      }
    }
    
    // 交换行
    if (maxRow != k) {
      for (var j = 0; j <= n; j++) {
        final temp = aug[k * (n + 1) + j];
        aug[k * (n + 1) + j] = aug[maxRow * (n + 1) + j];
        aug[maxRow * (n + 1) + j] = temp;
      }
    }
    
    // 消元
    final pivot = aug[k * (n + 1) + k];
    if (pivot.abs() < 1e-10) continue;  // 奇异矩阵
    
    for (var i = k + 1; i < n; i++) {
      final factor = aug[i * (n + 1) + k] / pivot;
      for (var j = k; j <= n; j++) {
        aug[i * (n + 1) + j] -= factor * aug[k * (n + 1) + j];
      }
    }
  }
  
  // 回代
  final x = Float64List(n);
  for (var i = n - 1; i >= 0; i--) {
    var sum = aug[i * (n + 1) + n];
    for (var j = i + 1; j < n; j++) {
      sum -= aug[i * (n + 1) + j] * x[j];
    }
    x[i] = sum / aug[i * (n + 1) + i];
  }
  
  return x;
}
```

### 仿射变换应用与逆变换

```dart
Offset applyAffine(Float64List t, Offset p) {
  // [a b tx] [x]
  // [c d ty] [y]
  return Offset(
    t[0] * p.dx + t[1] * p.dy + t[4],
    t[2] * p.dx + t[3] * p.dy + t[5]
  );
}

Float64List invertAffine(Float64List t) {
  // 计算逆变换
  final a = t[0], b = t[1], c = t[2], d = t[3], tx = t[4], ty = t[5];
  final det = a * d - b * c;
  if (det.abs() < 1e-10) {
    // 奇异矩阵，返回恒等变换
    return Float64List.fromList([1, 0, 0, 1, 0, 0]);
  }
  
  return Float64List.fromList([
    d / det,           // a'
    -b / det,          // b'
    -c / det,          // c'
    a / det,           // d'
    (b * ty - d * tx) / det,  // tx'
    (c * tx - a * ty) / det,  // ty'
  ]);
}
```

---

## 📊 复杂度分析

| 算法模块 | 时间复杂度 | 空间复杂度 | 备注 |
|---------|-----------|-----------|------|
| **连通域分析** | O(w·h) | O(w·h) | 两遍扫描 |
| **8方向描述子** | O(k·r²) | O(k·8) | k=特征点数，r=窗口半径 |
| **特征匹配** | O(k₁·k₂·d) | O(k₁+k₂) | k₁/k₂=两页特征点数，d=描述子维度 |
| **RANSAC** | O(N·k·d) | O(k) | N=迭代次数，k=匹配对数 |
| **最小二乘** | O(k·d²) | O(d²) | d=6（仿射变换参数数） |

---

## 🎯 参数速查表

| 参数 | 默认值 | 含义 | 调优建议 |
|------|-------|------|---------|
| **连通域面积阈值** | [200, 5000] | 保留的文字块面积范围 | 下限控制噪点，上限控制污损 |
| **描述子窗口** | 40×40px | 描述子采样窗口大小 | 相对特征点间距调整 |
| **Ratio test** | 0.75 | Lowe's距离比阈值 | 0.7→高精度，0.85→高召回 |
| **RANSAC迭代** | 1000 | 最大迭代次数 | 保证99%置信度 |
| **内点阈值** | 5.0px | 判定内点的误差阈值 | 600px宽用5px，1200px宽用10px |
| **最小匹配数** | 15对 | 对齐成功最少匹配数 | <15对视为版式差异过大 |
| **最小内点比例** | 30% | 对齐成功最小置信度 | RANSAC收敛判定标准 |

---

**版本**: v1.0  
**最后更新**: 2026-10-11  
**适用阶段**: Phase 1-2 实现
