#!/system/bin/sh
# dispatcher.sh  —  听闻人间十三月
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 调度器：消费队列，并发分发文件给 mv_worker 处理


. "$MODDIR/scripts/common.sh"

QUEUE_PROC="$QUEUE_DIR/processing.q"
QUEUE_DEDUP="$QUEUE_DIR/dedup.q"
QUEUE_RETRY="$QUEUE_DIR/retry.q"
DISPATCH_LOCK="$QUEUE_DIR/.dispatch.lock"

# 互斥锁防并发（调度间隔2s，解决启动扫描和主循环重叠）
# 超时判断：重试超过10次（约10s）视为死锁，强制清除
_try=0
_lock_ok=0
while [ "$_try" -lt 30 ]; do
    if mkdir "$DISPATCH_LOCK" 2>/dev/null; then
        _lock_ok=1
        break
    fi
    if [ "$_try" -ge 10 ]; then
        rm -rf "$DISPATCH_LOCK" 2>/dev/null
        log_msg "WARN" "SYS" "dispatcher锁超时，强制清除"
    fi
    _try=$(( _try + 1 ))
    sleep 1
done
[ "$_lock_ok" -eq 1 ] || { log_msg "WARN" "SYS" "dispatcher等锁超时，放弃本轮"; exit 0; }

_exit() { rmdir "$DISPATCH_LOCK" 2>/dev/null || true; exit "${1:-0}"; }

# 原子交换队列文件
mv "$QUEUE_IN" "$QUEUE_PROC" 2>/dev/null || _exit 0
: > "$QUEUE_IN"

# 合并上轮重试
if [ -s "$QUEUE_RETRY" ]; then
    cat "$QUEUE_RETRY" >> "$QUEUE_PROC" 2>/dev/null || true
    rm -f "$QUEUE_RETRY"
fi

[ -s "$QUEUE_PROC" ] || { rm -f "$QUEUE_PROC"; _exit 0; }

sort -u "$QUEUE_PROC" > "$QUEUE_DEDUP" 2>/dev/null
rm -f "$QUEUE_PROC"

[ -s "$QUEUE_DEDUP" ] || { rm -f "$QUEUE_DEDUP"; _exit 0; }

[ -f "$PARSED_RULES_FILE" ] || { log_msg "ERROR" "SYS" "规则文件丢失"; rm -f "$QUEUE_DEDUP"; _exit 1; }

# worker 并发上限
_max="${RESOLVED_MAX_WORKERS:-8}"
# 确保是合法数字
case "$_max" in
    *[!0-9]*|'') _max=8 ;;
esac
[ "$_max" -lt 1 ] && _max=1
[ "$_max" -gt 16 ] && _max=16

_dispatched=0
_running=0

while IFS= read -r _fp; do
    [ -z "$_fp" ] && continue
    [ -f "$_fp" ]  || continue
    _fname=$(basename "$_fp")
    _fdir=$(dirname "$_fp")

    while IFS='|' read -r _rsrc _rpat _rdst; do
        [ "$_fdir" = "$_rsrc" ]       || continue
        filename_matches "$_fname" "$_rpat" || continue

        # 达到并发上限时等待所有子进程完成
        if [ "$_running" -ge "$_max" ]; then
            wait 2>/dev/null || true
            _running=0
        fi

        (
            if ! sh "$VAR_WORKER_MV" "$_fp" "$_rdst" 2>>"$LOG_FILE"; then
                [ -f "$_fp" ] && printf '%s\n' "$_fp" >> "$QUEUE_RETRY" 2>/dev/null || true
            fi
        ) &
        _dispatched=$(( _dispatched + 1 ))
        _running=$(( _running + 1 ))
        break
    done < "$PARSED_RULES_FILE"
done < "$QUEUE_DEDUP"

wait 2>/dev/null || true
rm -f "$QUEUE_DEDUP"

[ "$_dispatched" -gt 0 ] && log_msg "INFO" "SYS" "本轮调度 ${_dispatched} 个文件"

if [ -s "$QUEUE_RETRY" ]; then
    _rc=$(wc -l < "$QUEUE_RETRY" 2>/dev/null | tr -d ' ')
    _rc="${_rc:-0}"
    if [ "$_rc" -gt 100 ] 2>/dev/null; then
        log_msg "WARN" "FILE" "retry积压 ${_rc} 条（超限），已清空"
        : > "$QUEUE_RETRY"
    else
        log_msg "WARN" "FILE" "本轮失败 ${_rc} 个文件，下轮重试"
    fi
fi

_exit 0
