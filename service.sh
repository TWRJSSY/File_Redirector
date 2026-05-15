#!/system/bin/sh
# service.sh  —  偷偷许下心愿
# “远处烟雨下的漓江每次都是匆匆而过”
#──────────────────────
# 主服务：单实例守护、规则热重载、调度队列、拉起各子脚本

#── 用户配置 ──
#被动扫描：控制所有事件驱动的主动补扫（服务启动、规则变更、监控重建、看门狗目录出现），1=开启，0=关闭
STARTUP_SCAN=1

#媒体库扫描等待秒数：文件移动后等待媒体广播稳定的时间，性能差的机器可适当提升间隔
MEDIA_WAIT=1

#日志保留天数
LOG_KEEP_DAYS=7

#文件写入稳定等待（秒）：搬运前检测文件大小和ctime连续稳定的最长等待时间，下载大文件时可适当调大
FILE_STABLE_WAIT=20

#主循环调度间隔（秒）
DISPATCH_INTERVAL=2
#─────────

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="/data/adb/modules/file_redirector" ;; esac

export MODDIR STARTUP_SCAN MEDIA_WAIT LOG_KEEP_DAYS FILE_STABLE_WAIT DISPATCH_INTERVAL
export RULES_FILE="$MODDIR/redirect.rules"
export LOG_FILE="$MODDIR/redirector.log"
export LOCK_FILE="$MODDIR/.service.pid"
export WATCHDOG_PID_FILE="$MODDIR/.watchdog.pid"
export QUEUE_DIR="$MODDIR/.queue"
export QUEUE_IN="$QUEUE_DIR/incoming.q"
export MAX_LOG_BYTES=524288
VAR_SCRIPTS="$MODDIR/scripts"
VAR_MONITOR="$VAR_SCRIPTS/monitor.sh"
VAR_DISPATCHER="$VAR_SCRIPTS/dispatcher.sh"
export VAR_WORKER_MV="$VAR_SCRIPTS/mv_worker.sh"
export VAR_MEDIA_FIX="$VAR_SCRIPTS/media_fix.sh"
export PARSED_RULES_FILE="$QUEUE_DIR/.parsed_rules"

. "$VAR_SCRIPTS/common.sh"

# ── 单实例保护（flock 文件锁）──
# 使用内核文件锁：进程意外死亡时内核自动释放，无锁残留风险
# LOCK_FD=9 为本进程持有锁的文件描述符，生命周期与进程绑定
check_single_instance() {
    exec 9>"${LOCK_FILE}.lock" || { log_msg "ERROR" "SYS" "无法打开锁文件"; exit 1; }
    if ! flock -n 9 2>/dev/null; then
        _pid=$(cat "$LOCK_FILE" 2>/dev/null)
        log_msg "INFO" "SYS" "实例已运行 PID=${_pid:-?}，退出"
        exit 0
    fi
    printf '%s\n' "$$" > "$LOCK_FILE" || { log_msg "ERROR" "SYS" "无法写PID文件"; exit 1; }
}

# ── 退出清理 ──
do_cleanup() {
    [ "${_CLEANED:-0}" = "1" ] && return
    _CLEANED=1
    _reason="${1:-服务意外停止}"
    log_msg "INFO" "SYS" "服务退出 PID=$$ | 原因: $_reason"
    [ -n "$MONITOR_PID" ]   && kill "$MONITOR_PID"   2>/dev/null
    [ -n "$WATCHDOG_PID" ]  && kill "$WATCHDOG_PID"  2>/dev/null
    pkill -f "$MODDIR/scripts/monitor.sh"    2>/dev/null || true
    pkill -f "$MODDIR/scripts/watchdog.sh"   2>/dev/null || true
    pkill -f "$MODDIR/scripts/dispatcher.sh" 2>/dev/null || true
    pkill -f "$MODDIR/scripts/mv_worker.sh"  2>/dev/null || true
    # 仅当PID文件仍属于本进程时才清理锁，防止覆盖新进程的PID
    _cur=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ "$_cur" = "$$" ]; then
        rm -f "$LOCK_FILE" "${LOCK_FILE}.lock" "$WATCHDOG_PID_FILE" 2>/dev/null
        case "$_reason" in
            运行异常*) _icon="「运行异常🤔」" ;;
            *)         _icon="「未运行😵」"   ;;
        esac
        sed -i "s|^description=.*|description=${_icon} ${_reason}|" \
            "$MODDIR/module.prop" 2>/dev/null || true
    fi
    rm -f "$QUEUE_IN" "$QUEUE_DIR/processing.q" "$QUEUE_DIR/dedup.q" \
          "$QUEUE_DIR/.parsed_rules" 2>/dev/null || true
    exit 0
}
_on_signal() {
    _SHUTDOWN=1
}

# ── 规则加载 ──
reload_rules() {
    _tmp="$QUEUE_DIR/.reload_tmp"
    parse_rules > "$_tmp" 2>/dev/null
    grep '^VALID|' "$_tmp" | cut -d'|' -f2- > "$PARSED_RULES_FILE"
    _vc=$(grep -c '^VALID|'   "$_tmp" 2>/dev/null | tr -d ' ' | tr -d '\n' || printf '0')
    _ic=$(grep -c '^INVALID|' "$_tmp" 2>/dev/null | tr -d ' ' | tr -d '\n' || printf '0')
    [ "${1:-}" != "silent" ] && log_msg "INFO" "SYS" "规则变更，重新加载：${_vc} 条有效，${_ic} 条无效"
    [ "$_ic" -gt 0 ] && grep '^INVALID|' "$_tmp" | cut -d'|' -f2- | \
        while IFS= read -r _l; do log_msg "WARN" "SYS" "无效规则: $_l"; done
    rm -f "$_tmp"
    printf '%s' "$_vc"
}

# ── 启动监控进程 ──
_start_monitor() {
    if [ -n "$MONITOR_PID" ]; then
        if kill "$MONITOR_PID" 2>/dev/null; then
            log_msg "INFO" "SYS" "清理旧监控进程 PID=$MONITOR_PID"
        fi
    fi
    MONITOR_PID=""
    pkill -f "$MODDIR/scripts/monitor.sh" 2>/dev/null || true
    sh "$VAR_MONITOR" 9>&- 2>>"$LOG_FILE" &
    MONITOR_PID=$!
    log_msg "INFO" "SYS" "监控进程已启动 PID=$MONITOR_PID"
}

# ── 主流程 ──
main() {
    _SHUTDOWN=0; _CLEANED=0; MONITOR_PID="" WATCHDOG_PID=""
    trap _on_signal INT TERM HUP
    check_single_instance

    # 保护自身不被 OOM killer 杀掉
    echo -1000 > "/proc/$$/oom_score_adj" 2>/dev/null || true

    sed -i 's|^description=.*|description=「运行中😋」 远处烟雨下的漓江每次都是匆匆而过|' \
        "$MODDIR/module.prop" 2>/dev/null || true

    wait_for_storage
    [ "$_SHUTDOWN" = "1" ] && do_cleanup

    # 按天清理日志（超过 LOG_KEEP_DAYS 天则清空）
    clean_old_log

    [ -f "$RULES_FILE" ] || { log_msg "ERROR" "SYS" "规则文件不存在: $RULES_FILE"; do_cleanup "运行异常：规则文件缺失"; }

    # 检查 inotifywait
    INOTIFYWAIT_BIN="$MODDIR/tools/inotifywait"
    export INOTIFYWAIT_BIN
    if [ ! -x "$INOTIFYWAIT_BIN" ]; then
        do_cleanup "运行异常：inotifywait缺失"
    fi

    # 预检动态库
    mkdir -p "$QUEUE_DIR"
    _err="$QUEUE_DIR/.inotify_precheck"
    LD_LIBRARY_PATH="$MODDIR/tools${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$INOTIFYWAIT_BIN" --help >/dev/null 2>"$_err" || true
    if grep -q 'not found' "$_err" 2>/dev/null || grep -q 'cannot open' "$_err" 2>/dev/null; then
        log_msg "ERROR" "SYS" "inotifywait 动态库加载失败"
        rm -f "$_err"
        do_cleanup "运行异常：动态库加载失败"
    fi
    rm -f "$_err"

    # 计算 worker 上限（根据 CPU 核心数自动分配，上限16，下限2）
    _ncpu=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '4')
    _w=$(( _ncpu > 16 ? 16 : ( _ncpu < 2 ? 2 : _ncpu ) ))
    export RESOLVED_MAX_WORKERS="$_w"

    rm -rf "$QUEUE_DIR"; mkdir -p "$QUEUE_DIR"; : > "$QUEUE_IN"
    _valid_count=$(reload_rules silent)
    log_msg "INFO" "SYS" "服务启动 PID=$$ | Worker上限: ${_w} | 规则: ${_valid_count} 条有效"

    # 启动扫描：将规则源目录下已有文件入队
    if [ "$STARTUP_SCAN" = "1" ] && [ "$_valid_count" -gt 0 ] 2>/dev/null; then
        log_msg "INFO" "SCAN" "服务启动，触发被动扫描..."
        cut -d'|' -f1 "$PARSED_RULES_FILE" | sort -u | while IFS= read -r _d; do
            [ -d "$_d" ] && find "$_d" -type f 2>/dev/null | while IFS= read -r _f; do
                is_tmp_file "$(basename "$_f")" || printf '%s\n' "$_f"
            done >> "$QUEUE_IN"
        done
        if [ -s "$QUEUE_IN" ]; then
            sh "$VAR_DISPATCHER" 2>>"$LOG_FILE"
        fi
        log_msg "INFO" "SCAN" "被动扫描入队完成"
    fi

    _rules_mtime=$(stat -c '%Y' "$RULES_FILE" 2>/dev/null || printf '0')
    _start_monitor

    # ── 启动看门狗 ──
    if pkill -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null; then
        log_msg "INFO" "SYS" "清理旧看门狗实例"
    else
        log_msg "INFO" "SYS" "无旧看门狗实例"
    fi
    sh "$MODDIR/scripts/watchdog.sh" 9>&- 2>>"$LOG_FILE" &
    WATCHDOG_PID=$!
    printf '%s\n' "$WATCHDOG_PID" > "$WATCHDOG_PID_FILE" 2>/dev/null || true
    log_msg "INFO" "SYS" "看门狗已启动 PID=$WATCHDOG_PID"

    while true; do
        [ "$_SHUTDOWN" = "1" ] && do_cleanup
        [ -f "$MODDIR/disable" ] && do_cleanup "模块已在ROOT框架中被禁用"

        # 规则文件变更则热重载
        _cur_mtime=$(stat -c '%Y' "$RULES_FILE" 2>/dev/null || printf '0')
        if [ "$_cur_mtime" != "$_rules_mtime" ]; then
            _rules_mtime="$_cur_mtime"
            reload_rules
            _start_monitor
            # 读取 STARTUP_SCAN：被动扫描总开关，规则变更后触发一次全量扫描
            if [ "$STARTUP_SCAN" = "1" ]; then
                log_msg "INFO" "SCAN" "规则变更，触发被动扫描..."
                cut -d'|' -f1 "$PARSED_RULES_FILE" | sort -u | while IFS= read -r _d; do
                    [ -d "$_d" ] && find "$_d" -type f 2>/dev/null | while IFS= read -r _f; do
                        is_tmp_file "$(basename "$_f")" || printf '%s\n' "$_f"
                    done >> "$QUEUE_IN"
                done
            fi
        fi

        # 主动扫描：检测触发文件，存在则全量扫描入队（不受 STARTUP_SCAN 约束）
        if [ -f "$MODDIR/.rescan_trigger" ]; then
            rm -f "$MODDIR/.rescan_trigger"
            log_msg "INFO" "SCAN" "主动扫描触发..."
            cut -d'|' -f1 "$PARSED_RULES_FILE" | sort -u | while IFS= read -r _d; do
                [ -d "$_d" ] && find "$_d" -type f 2>/dev/null | while IFS= read -r _f; do
                    is_tmp_file "$(basename "$_f")" || printf '%s\n' "$_f"
                done >> "$QUEUE_IN"
            done
            log_msg "INFO" "SCAN" "主动扫描入队完成"
        fi

        # 监控进程存活检查
        if [ -n "$MONITOR_PID" ] && ! kill -0 "$MONITOR_PID" 2>/dev/null; then
            log_msg "WARN" "SYS" "监控进程退出，重启"
            _start_monitor
        fi

        [ -s "$QUEUE_IN" ] && sh "$VAR_DISPATCHER" 2>>"$LOG_FILE"

        rotate_log
        sleep "$DISPATCH_INTERVAL" &
        _sleep_pid=$!
        wait "$_sleep_pid" 2>/dev/null || true
    done
}

main "$@"
