#!/system/bin/sh
# uninstall.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 卸载脚本：终止所有服务进程、清理锁文件和队列目录


MODDIR="/data/adb/modules/file_redirector"
LOCK_FILE="$MODDIR/.service.pid"

# 终止服务主进程
if [ -f "$LOCK_FILE" ]; then
    _pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        _cmdline=$(cat "/proc/$_pid/cmdline" 2>/dev/null | tr '\0' ' ')
        case "$_cmdline" in
            *file_redirector*|*service.sh*)
                kill "$_pid" 2>/dev/null
                sleep 1
                ;;
        esac
    fi
    rm -f "$LOCK_FILE"
fi

# 清理锁目录（SIGKILL 场景下 do_cleanup 不执行，锁目录可能残留）
rm -rf "${LOCK_FILE}.d" 2>/dev/null || true
rm -f "${MODDIR}/.watchdog.pid" 2>/dev/null || true

# 清理子进程（pkill + fallback）
for _sp in monitor watchdog dispatcher mv_worker media_fix; do
    pkill -f "$MODDIR/scripts/${_sp}.sh" 2>/dev/null || true
done

# 清理队列和锁文件
rm -rf "$MODDIR/.queue" 2>/dev/null || true
