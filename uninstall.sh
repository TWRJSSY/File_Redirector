#!/system/bin/sh
# uninstall.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过” 
#                  
#─────────────────────────────────────────────

MODDIR="/data/adb/modules/file_redirector"

# 终止服务进程
if [ -f "$MODDIR/.service.lock" ]; then
    pid=$(cat "$MODDIR/.service.lock" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    rm -f "$MODDIR/.service.lock"
fi
