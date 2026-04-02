#!/system/bin/sh
# uninstall.sh  —  卸载清理脚本
# Copyright (c) 2026 听闻人间十三月
#─────────────────────────────────────────────

MODDIR="/data/adb/modules/file_redirector"

# 终止服务进程
if [ -f "$MODDIR/.service.lock" ]; then
    pid=$(cat "$MODDIR/.service.lock" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    rm -f "$MODDIR/.service.lock"
fi

# 清理运行时文件
rm -f  "$MODDIR/.evt_fifo"
rm -f  "$MODDIR/.dir_classify"
rm -rf "$MODDIR/.file_locks"
