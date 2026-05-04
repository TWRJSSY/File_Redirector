#!/system/bin/sh
# watchdog.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 看门狗：定期检测主服务存活，死亡时自动拉起


MODDIR="${MODDIR:-/data/adb/modules/file_redirector}"
. "$MODDIR/scripts/common.sh"

WATCH_INTERVAL=1800

# ── 校验主服务进程身份（防 PID 复用）──
_is_our_service() {
    _pid="$1"
    [ -z "$_pid" ] && return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
    # cmdline 为空（权限问题或内核线程）时保守处理：进程存在即认为是我们的服务
    [ -z "$_cmd" ] && return 0
    case "$_cmd" in
        *service.sh*|*file_redirector*) return 0 ;;
    esac
    return 1
}

# ── 检查并拉起主服务 ──
_check_and_revive() {
    _pid=$(cat "$LOCK_FILE" 2>/dev/null)
    _is_our_service "$_pid" && return 0

    # 二次确认，排除启动瞬间竞争
    sleep 3
    _pid=$(cat "$LOCK_FILE" 2>/dev/null)
    _is_our_service "$_pid" && return 0

    rm -rf "${LOCK_FILE}.d" 2>/dev/null
    log_msg "WARN" "SYS" "watchdog：主服务已停止，尝试拉起"
    sh "$MODDIR/service.sh" 2>>"$LOG_FILE" &
    sleep 10
}

log_msg "INFO" "SYS" "watchdog 启动：PID=$$"
echo -1000 > "/proc/$$/oom_score_adj" 2>/dev/null || true

while true; do
    _check_and_revive
    sleep "$WATCH_INTERVAL" &
    wait $! 2>/dev/null || true
done
