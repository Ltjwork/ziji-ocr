# -*- coding: utf-8 -*-
"""清理域路由：诊断产物（崩溃转储/日志）的查询与手动清理。"""
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import cleanup_service
from api_base import app  # noqa: F401  (路由注册)


class CleanupRunRequest(BaseModel):
    # 要执行的目标：crash_dumps（删转储）/ old_logs（删 .old）/
    # active_logs（清空当前日志内容）。空 = 全部。
    targets: list[str] = []
    # 删转储时保留最新 N 份（排查进行中可留现场）。
    keep_last_dump: int = 0


@app.get("/cleanup/status")
def cleanup_status():
    """清理面板数据：各目标文件清单、字节量、自动策略配置。"""
    return cleanup_service.scan_status()


@app.post("/cleanup/run")
def cleanup_run(req: CleanupRunRequest):
    """手动清理。删除大转储在 NTFS 上只是元数据操作，秒级完成。"""
    valid = {"crash_dumps", "old_logs", "active_logs"}
    targets = set(req.targets or valid)
    unknown = targets - valid
    if unknown:
        raise HTTPException(status_code=400, detail=f"未知清理目标: {sorted(unknown)}")
    results: dict = {}
    freed = 0
    if "crash_dumps" in targets:
        r = cleanup_service.delete_dumps(keep_last=max(0, req.keep_last_dump))
        results["crash_dumps"] = r
        freed += r["freed"]
    if "old_logs" in targets:
        r = cleanup_service.delete_old_logs()
        results["old_logs"] = r
        freed += r["freed"]
    if "active_logs" in targets:
        r = cleanup_service.truncate_logs()
        results["active_logs"] = r
        freed += r["freed"]
    return {"results": results, "freed_bytes": freed}
