# 页面级 A/B 验证工具

验证"并行识别的结果与单 daemon 串行（旧版行为）逐字节一致"，顺带对比耗时。
在**显存空闲**时运行（并行腿会按硬件再起一池 daemon，与正在跑的识别任务
抢显存）。

```
cd python_service
conda activate paddle            # 或任意能 import psutil/urllib 的环境
python ab_verify/run_ab.py both
python ab_verify/compare_ab.py
```

- **基线腿**：独立服务实例，`OCR_KRAKEN_WORKERS=1` + `KRAKEN_PREP_PIPELINE=0`
  （≡ 旧版单 daemon 串行行为）。
- **并行腿**：独立服务实例，全默认（硬件自动定 daemon 数）。
- 每腿先跑 1 页热身再计时 5 页（当前选取 GujiBT 两本书的页面，可在
  `run_ab.py` 顶部 `PAGES` 改）；结果 JSON 落 `%TEMP%/ocr_ab/<腿名>/`。
- `compare_ab.py`：逐页归一化毫秒时间戳 id 后逐字节比较 + 耗时表；全部
  一致退出码 0。
- `ab_segment_run.py`：单腿驱动器——先跑 1 页热身，再逐页调 `/segment`
  把响应 JSON（去掉 debug 字段）与耗时落盘到各自腿目录；`run_ab.py`
  的两腿循环内部以子进程调用它。
- 服务实例由 `conda run -n paddle` 启动（与 App 生产方式一致；直接用
  env 的 python.exe 启动会因 conda DLL 路径不全卡在 torch 导入）。
- 实例会临时占用下一个可用端口并把 `service_port.txt` 恢复原值，
  不影响正在运行的 App 后端。
