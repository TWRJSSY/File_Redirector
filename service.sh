#!/system/bin/sh
# service.sh  —  主服务脚本
# Copyright (c) 2026 听闻人间十三月
#
# 架构：inotifywait 监控 → FIFO → 规则匹配 → mv → MediaStore 通知
#─────────────────────────────────────────────
# 初始化扫描：服务完成初始化后立即对所有监控目录做一次全量扫描
# 0=关闭  1=开启（默认）
STARTUP_SCAN=1

# 空目录清理：移走文件后删除空目录，触发看门狗等待目录重建
# 0=关闭  1=开启（默认）
SCAN_AND_CLEAR=1

# 级联清理空父目录（空目录清理开启时生效，作为其子功能）
# rmdir 遇非空目录自动停止，不会误删有内容的目录
# 0=关闭  1=开启（默认）
CLEAR_EMPTY_PARENTS=1

# MediaStore 索引等待秒数：扫描新路径后等待索引完成再删旧记录
MEDIA_WAIT=3

# 日志保留天数，超时后下次启动自动清空
LOG_KEEP_DAYS=7
# ─────────────────────────────────────────────
# 内部常量
# 动态获取模块目录，兼容 KernelSU/Magisk/APatch 不同安装路径
MODDIR="${0%/*}"
# 兼容直接调用场景的兜底
case "$MODDIR" in /*) ;; *) MODDIR="/data/adb/modules/file_redirector" ;; esac
RULES_FILE="$MODDIR/redirect.rules"
LOG_FILE="$MODDIR/redirector.log"
LOCK_FILE="$MODDIR/.service.lock"
EVT_FIFO="$MODDIR/.evt_fifo"
FILE_LOCK_DIR="$MODDIR/.file_locks"

MAX_LOG_BYTES=524288
DIR_CHECK_INTERVAL=5
TAB="$(printf '\t')"   # 真实制表符，inotifywait --format 分隔符

INOTIFYWAIT_PID=""
WATCHDOG_PID=""
_BATCH_SCAN=0

# ─────────────────────────────────────────────
# 基础工具

log_msg() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
}

rotate_log() {
    [ -f "$LOG_FILE" ] || return
    local sz; sz=$(wc -c < "$LOG_FILE" 2>/dev/null) || return
    [ "$sz" -gt "$MAX_LOG_BYTES" ] || return
    local half=$(( MAX_LOG_BYTES / 2 ))
    tail -c "$half" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && \
        mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
}

file_lock()   { mkdir -p "$FILE_LOCK_DIR" 2>/dev/null; mkdir "$FILE_LOCK_DIR/$(printf '%s' "$1" | tr '/' '%')" 2>/dev/null; }
file_unlock() { rmdir "$FILE_LOCK_DIR/$(printf '%s' "$1" | tr '/' '%')" 2>/dev/null; }

normalize_path() {
    local p="$1"
    # shellcheck disable=SC2086,SC2046
    set -- $p; p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    canon_path "$p"
}

canon_path() {
    local p="${1%/}"
    case "$p" in
        /storage/emulated/0/*)  p="/sdcard/${p#/storage/emulated/0/}" ;;
        /storage/emulated/0)    p="/sdcard" ;;
        /mnt/sdcard/*)          p="/sdcard/${p#/mnt/sdcard/}" ;;
        /mnt/sdcard)            p="/sdcard" ;;
    esac
    printf '%s' "$p"
}

wait_for_storage() {
    local try=0
    while [ "$try" -lt 60 ]; do
        ls /sdcard/ >/dev/null 2>&1 && return 0
        sleep 3; try=$(( try + 1 ))
    done
    log_msg "WARN" "等待存储超时（3 分钟），尝试继续启动，部分功能可能异常"
}

check_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid; pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            [ "$pid" = "$$" ] && return 0   # exec 重载同一进程放行
            kill -0 "$pid" 2>/dev/null && exit 0
        fi
    fi
    printf '%s\n' "$$" > "$LOCK_FILE" || {
        log_msg "ERROR" "无法写入锁文件: $LOCK_FILE"
        exit 1
    }
}

cleanup() {
    log_msg "INFO" "服务退出 PID=$$"
    sed -i 's|^description=.*|description=「未运行😵」 以极低功耗为核心，基于 inotify 事件驱动与 mv 原子操作构建的文件重定向系统。|' "$MODDIR/module.prop"
    [ -n "$WATCHDOG_PID" ]    && kill "$WATCHDOG_PID"    2>/dev/null
    [ -n "$INOTIFYWAIT_PID" ] && kill "$INOTIFYWAIT_PID" 2>/dev/null
    rm -f  "$LOCK_FILE" "$EVT_FIFO"
    rm -rf "$FILE_LOCK_DIR"
    exit 0
}

# ─────────────────────────────────────────────
# 规则解析
# 格式：[监控目录]+[匹配规则]+[目标目录]
# 输出：VALID|src|pattern|dst 或 INVALID|原始行

parse_rules() {
    [ -f "$RULES_FILE" ] || return
    while IFS= read -r raw; do
        local line; line=$(printf '%s' "$raw" | tr -d '\r')
        case "$line" in ''|'#'*|'='*) continue ;; esac

        local src pattern dst rest depth
        src=$(     printf '%s' "$line" | cut -d'[' -f2 | cut -d']' -f1)
        rest=$(    printf '%s' "$line" | cut -d'+' -f2-)
        pattern=$( printf '%s' "$rest" | cut -d'[' -f2 | cut -d']' -f1)
        dst=$(     printf '%s' "$rest" | cut -d'+' -f2- | cut -d'[' -f2 | cut -d']' -f1)

        src=$(normalize_path "$src")
        # __delete__ 为删除模式保留值，跳过路径规范化
        [ "$dst" = "__delete__" ] || dst=$(normalize_path "$dst")
        { [ -z "$src" ] || [ -z "$dst" ]; } && {
            printf 'INVALID|%s\n' "$line"; continue
        }
        depth=$(printf '%s' "$rest" | cut -d'+' -f3- | cut -d'[' -f2 | cut -d']' -f1)
        depth=$(printf '%s' "${depth:-0}" | tr -cd '0-9'); [ -z "$depth" ] && depth=0
        printf 'VALID|%s|%s|%s|%s\n' "$src" "$pattern" "$dst" "$depth"
    done < "$RULES_FILE"
}

filename_matches() {
    [ -z "$2" ] && return 0
    case "$1" in $2) return 0 ;; esac
    return 1
}

# ─────────────────────────────────────────────
# MediaStore 通知
# 扫新路径写入完整元数据 → 等待索引完成 → 删旧记录（两种路径形式都删）

media_notify() {
    local new_path="$1" old_path="$2"
    local new_dir; new_dir=$(dirname "$new_path")

    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file://${new_path}" >/dev/null 2>&1 || true
    am broadcast -a android.intent.action.MEDIA_MOUNTED \
        -d "file://${new_dir}" >/dev/null 2>&1 || true
    sleep "$MEDIA_WAIT"

    # 路径兼容：/sdcard  /storage/emulated/0  /mnt/sdcard
    local _s _e
    case "$old_path" in
        /sdcard/*)             _s="$old_path"; _e="/storage/emulated/0/${old_path#/sdcard/}" ;;
        /storage/emulated/0/*) _e="$old_path"; _s="/sdcard/${old_path#/storage/emulated/0/}" ;;
        *)                     _s="$old_path"; _e="$old_path" ;;
    esac
    content delete --uri content://media/external/files \
        --where "_data='${_s}'" >/dev/null 2>&1 || true
    content delete --uri content://media/external/files \
        --where "_data='${_e}'" >/dev/null 2>&1 || true
    content delete --uri content://media/external/images/media \
        --where "_data='${_s}'" >/dev/null 2>&1 || true
    content delete --uri content://media/external/images/media \
        --where "_data='${_e}'" >/dev/null 2>&1 || true
}
# 批量扫描后统一通知目标目录
media_notify_dirs() {
    local dirs="$1"
    printf '%s
' "$dirs" | sort -u | while IFS= read -r d; do
        [ -z "$d" ] && continue
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://${d}" >/dev/null 2>&1 || true
        am broadcast -a android.intent.action.MEDIA_MOUNTED \
            -d "file://${d}" >/dev/null 2>&1 || true
    done
    sleep "$MEDIA_WAIT"
}
# ─────────────────────────────────────────────
# 从 start_dir 的父目录向上删除空目录，最多 depth 层
_cascade_rmdir() {
    local start_dir="$1" depth="$2" p i
    p=$(dirname "$start_dir"); i=0
    while [ "$i" -lt "$depth" ] && [ -n "$p" ] \
       && [ "$p" != "/" ] && [ "$p" != "/sdcard" ] \
       && [ "$p" != "/storage/emulated/0" ]; do
        rmdir "$p" 2>/dev/null || break
        p=$(dirname "$p"); i=$(( i + 1 ))
    done
}

# ─────────────────────────────────────────────
# 核心重定向
do_redirect() {
    local src_file="$1" dst_dir="$2" rule_depth="${3:-0}"
    [ -f "$src_file" ] || return 0
    local fname; fname=$(basename "$src_file")

    # 删除模式：目标目录为 __delete__ 时直接删除源文件
    if [ "$dst_dir" = "__delete__" ]; then
        if rm "$src_file" 2>/dev/null; then
            log_msg "INFO" "清理: $src_file"
            # 仅删除旧 MediaStore 记录，不广播新路径（文件已删除，无目标）
            local _s _e
            case "$src_file" in
                /sdcard/*)             _s="$src_file"; _e="/storage/emulated/0/${src_file#/sdcard/}" ;;
                /storage/emulated/0/*) _e="$src_file"; _s="/sdcard/${src_file#/storage/emulated/0/}" ;;
                *)                     _s="$src_file"; _e="$src_file" ;;
            esac
            content delete --uri content://media/external/files \
                --where "_data='${_s}'" >/dev/null 2>&1 || true
            content delete --uri content://media/external/files \
                --where "_data='${_e}'" >/dev/null 2>&1 || true
            content delete --uri content://media/external/images/media \
                --where "_data='${_s}'" >/dev/null 2>&1 || true
            content delete --uri content://media/external/images/media \
                --where "_data='${_e}'" >/dev/null 2>&1 || true
        else
            [ -f "$src_file" ] || { log_msg "INFO" "清理: $src_file（已被系统清理）"; return 0; }
            log_msg "WARN" "清理失败: $src_file"
        fi
        return 0
    fi

    if [ ! -d "$dst_dir" ]; then
        mkdir -p "$dst_dir" 2>/dev/null || { log_msg "ERROR" "创建目标目录失败: $dst_dir"; return 1; }
    fi

    local dst_path="$dst_dir/$fname"
    if [ -e "$dst_path" ]; then
        local ts; ts=$(date '+%Y%m%d_%H%M%S')
        case "$fname" in
            *.*) dst_path="$dst_dir/${fname%.*}_${ts}.${fname##*.}" ;;
            *)   dst_path="$dst_dir/${fname}_${ts}" ;;
        esac
    fi

    if mv "$src_file" "$dst_path" 2>/dev/null; then
        # 验证：mv 成功但跨分区时目标可能未实际写入
        if [ ! -f "$dst_path" ]; then
            log_msg "WARN" "mv 返回成功但目标文件不存在，降级 cp+rm: $src_file → $dst_path"
        else
            log_msg "INFO" "mv: $src_file → $dst_path"
            media_notify "$dst_path" "$src_file"
            if [ "$SCAN_AND_CLEAR" = "1" ] && [ "${CLEAR_EMPTY_PARENTS:-0}" = "1" ] && [ "${rule_depth:-0}" -gt 0 ] 2>/dev/null; then
                local _src_dir; _src_dir=$(dirname "$src_file")
                rmdir "$_src_dir" 2>/dev/null && _cascade_rmdir "$_src_dir" "$rule_depth"
            fi
            return 0
        fi
        # mv 目标不存在，继续降级
    fi

    log_msg "INFO" "降级 cp+rm: $src_file → $dst_path"
    sleep 2
    [ -f "$src_file" ] || return 0

    if ! cp "$src_file" "$dst_path" 2>/dev/null; then
        log_msg "ERROR" "cp 失败: $src_file → $dst_path"; return 1
    fi

    local src_sz dst_sz
    src_sz=$(wc -c < "$src_file"  2>/dev/null)
    dst_sz=$(wc -c < "$dst_path" 2>/dev/null)
    if [ "$src_sz" != "$dst_sz" ]; then
        log_msg "ERROR" "校验失败(src=${src_sz}B dst=${dst_sz}B)，已回滚"
        rm -f "$dst_path" 2>/dev/null; return 1
    fi

    local perm; perm=$(stat -c '%a' "$src_file" 2>/dev/null)
    [ -n "$perm" ] && chmod "$perm" "$dst_path" 2>/dev/null || true
    touch -r "$src_file" "$dst_path" 2>/dev/null || true

    media_notify "$dst_path" "$src_file"
    if rm "$src_file" 2>/dev/null; then
        if [ -f "$dst_path" ]; then
            log_msg "INFO" "cp+rm: $src_file → $dst_path"
        else
            log_msg "ERROR" "cp+rm: 目标文件丢失（cp已完成但文件不见）: $dst_path"
            return 1
        fi
        if [ "$SCAN_AND_CLEAR" = "1" ] && [ "${CLEAR_EMPTY_PARENTS:-0}" = "1" ] && [ "${rule_depth:-0}" -gt 0 ] 2>/dev/null; then
            local _src_dir; _src_dir=$(dirname "$src_file")
            rmdir "$_src_dir" 2>/dev/null && _cascade_rmdir "$_src_dir" "$rule_depth"
        fi
    else
        # rm 失败时确认文件是否存在
        if [ ! -f "$src_file" ]; then
            log_msg "INFO" "cp+rm: $src_file → $dst_path（源文件已被系统清理）"
        else
            log_msg "WARN" "源文件删除失败（目标已保留）: $src_file"
        fi
    fi
    return 0
}

# ─────────────────────────────────────────────
# 规则匹配与分发

apply_rules() {
    local filepath="$1" dir="$2" fname="$3" rules="$4" src_dirs="$5"
    case "$fname" in .*) return ;; esac
    [ -f "$filepath" ] || return

    printf '%s\n' "$rules" | while IFS='|' read -r src pattern dst depth; do
        [ "$dir" = "$src" ] || continue
        filename_matches "$fname" "$pattern" || continue

        # __delete__ 为删除模式保留值，排除在防循环检测之外
        [ "$dst" != "__delete__" ] && \
        printf '%s\n' "$src_dirs" | grep -qx "$(canon_path "$dst")" && {
            log_msg "WARN" "防循环跳过: [$dst] 同时是监控源"
            continue
        }

        file_lock "$filepath" || continue
        do_redirect "$filepath" "$dst" "${depth:-0}"
        file_unlock "$filepath"

        [ -f "$filepath" ] || break
    done
}

# ─────────────────────────────────────────────
# 批量扫描
do_batch_scan() {
    local scan_dirs="$1" clean_rules="$2" all_src_dirs="$3"
    local count=0 dst_dirs=""

    _BATCH_SCAN=1
    for d in $scan_dirs; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            [ -f "$f" ] || continue
            local bname; bname=$(basename "$f")
            case "$bname" in .*) continue ;; esac
            apply_rules "$f" "$d" "$bname" "$clean_rules" "$all_src_dirs"
            [ ! -f "$f" ] && count=$(( count + 1 ))
        done
    done
    _BATCH_SCAN=0

    if [ "$count" -gt 0 ]; then
        # 排除删除模式保留值，仅通知真实目录
        dst_dirs=$(printf '%s\n' "$clean_rules" | cut -d'|' -f3 | grep -v '^__delete__$' | sort -u)
        [ -n "$dst_dirs" ] && media_notify_dirs "$dst_dirs"
    fi

    printf '%d' "$count"
}

# ─────────────────────────────────────────────
# 目录看门狗

start_dir_watchdog() {
    local pending_dirs="$1" valid_dirs="$2"
    local watch_pid="$3"
    [ -z "$pending_dirs" ] && [ -z "$valid_dirs" ] && [ -z "$watch_pid" ] && return
    (
        while true; do
            sleep "$DIR_CHECK_INTERVAL"
            if [ -n "$watch_pid" ] && ! kill -0 "$watch_pid" 2>/dev/null; then
                log_msg "WARN" "inotifywait 意外退出，自动重启"
                printf '%s	
' "__WATCHDOG_RESTART__" > "$EVT_FIFO" 2>/dev/null
                break
            fi
            if [ -n "$pending_dirs" ]; then
                if printf '%s
' "$pending_dirs" | while IFS= read -r d; do
                       [ -d "$d" ] && { printf 'found'; break; }
                   done | grep -q 'found'; then
                    log_msg "INFO" "看门狗：目录出现，重启 inotifywait"
                    printf '%s	
' "__WATCHDOG_RESTART__" > "$EVT_FIFO" 2>/dev/null
                    break
                fi
            fi
            if [ -n "$valid_dirs" ]; then
                if printf '%s
' "$valid_dirs" | while IFS= read -r d; do
                       [ ! -d "$d" ] && { printf 'gone'; break; }
                   done | grep -q 'gone'; then
                    printf '%s	
' "__WATCHDOG_RESTART__" > "$EVT_FIFO" 2>/dev/null
                    break
                fi
            fi
        done
    ) &
    WATCHDOG_PID=$!
}

# ─────────────────────────────────────────────
# inotifywait 监控主循环
# inotifywait 后台写 FIFO，9<> 读写模式阻塞读取，写入端无输出时不产生 EOF

monitor_inotifywait() {
    local parsed_rules="$1" inotifywait_bin="$2" is_first_run="${3:-0}"
    local all_src_dirs valid_dirs="" pending_dirs=""

    all_src_dirs=$(printf '%s\n' "$parsed_rules" | grep '^VALID|' | cut -d'|' -f2 | sort -u)

    printf '%s\n' "$all_src_dirs" | while IFS= read -r d; do
        if [ -d "$d" ]; then printf 'valid:%s\n' "$d"
        else printf 'pending:%s\n' "$d"
        fi
    done > "$MODDIR/.dir_classify"

    while IFS= read -r entry; do
        case "$entry" in
            valid:*)   valid_dirs="${valid_dirs} ${entry#valid:}" ;;
            pending:*) pending_dirs="${pending_dirs}${pending_dirs:+
}${entry#pending:}" ;;
        esac
    done < "$MODDIR/.dir_classify"
    rm -f "$MODDIR/.dir_classify"

    [ -n "$pending_dirs" ] && [ "$is_first_run" = "1" ] && \
        log_msg "WARN" "目录不存在，看门狗等待: $(printf '%s\n' "$pending_dirs" | tr '\n' ' ')"

    rm -f "$EVT_FIFO"
    mkfifo "$EVT_FIFO" 2>/dev/null || { log_msg "ERROR" "无法创建 FIFO"; return 1; }

    if [ -z "$valid_dirs" ]; then
        log_msg "WARN" "无可监控目录，等待看门狗..."
        start_dir_watchdog "$pending_dirs" "" ""
        IFS="$TAB" read -r _ _ <&9 9<>"$EVT_FIFO"
        kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""
        rm -f "$EVT_FIFO"; return 1
    fi

    LD_LIBRARY_PATH="$MODDIR/tools${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$inotifywait_bin" -m -q \
        --format "%w${TAB}%f${TAB}%e" \
        -e close_write \
        -e moved_to \
        $valid_dirs \
        > "$EVT_FIFO" 2>/dev/null &
    INOTIFYWAIT_PID=$!

    sleep 1  # 等 inotifywait 建立 watches，避免窗口期漏事件

    local vcount pcount=0
    vcount=$(printf '%s\n' "$valid_dirs" | wc -w)
    [ -n "$pending_dirs" ] && pcount=$(printf '%s\n' "$pending_dirs" | grep -c .)
    if [ "$is_first_run" = "1" ]; then
        [ "$pcount" -gt 0 ] \
            && log_msg "INFO" "监控 ${vcount} 个目录，${pcount} 个目录看门狗等待" \
            || log_msg "INFO" "监控 ${vcount} 个目录"
    fi

    start_dir_watchdog "$pending_dirs" "$valid_dirs" "$INOTIFYWAIT_PID"

    local clean_rules; clean_rules=$(printf '%s\n' "$parsed_rules" | grep '^VALID|' | cut -d'|' -f2-)

    if [ "$is_first_run" = "1" ] && [ "$STARTUP_SCAN" = "1" ] && [ "$SCAN_AND_CLEAR" != "1" ]; then
        local n; n=$(do_batch_scan "$valid_dirs" "$clean_rules" "$all_src_dirs")
        [ "$n" -gt 0 ] && log_msg "INFO" "启动扫描：移走 ${n} 个文件"
    fi

    # 扫描并清空（每次 inotifywait 启动后）
    if [ "$SCAN_AND_CLEAR" = "1" ]; then
        local n; n=$(do_batch_scan "$valid_dirs" "$clean_rules" "$all_src_dirs")
        local cleared=0
        for d in $valid_dirs; do
            local has_file=0
            for f in "$d"/*; do [ -f "$f" ] && { has_file=1; break; }; done
            if [ "$has_file" -eq 0 ] && rmdir "$d" 2>/dev/null; then
                cleared=$(( cleared + 1 ))
                if [ "${CLEAR_EMPTY_PARENTS:-0}" = "1" ]; then
                    local rdepth; rdepth=$(printf '%s\n' "$clean_rules" \
                        | while IFS='|' read -r s p t d_; do
                            [ "$s" = "$d" ] && { printf '%s' "${d_:-0}"; break; }
                          done)
                    [ "${rdepth:-0}" -gt 0 ] 2>/dev/null && _cascade_rmdir "$d" "$rdepth"
                fi
            fi
        done
        if [ "$n" -gt 0 ] || [ "$cleared" -gt 0 ]; then
            local msg="扫描清空："
            [ "$n" -gt 0 ]       && msg="${msg}移走 ${n} 个文件"
            [ "$n" -gt 0 ] && [ "$cleared" -gt 0 ] && msg="${msg}，"
            [ "$cleared" -gt 0 ] && msg="${msg}删除 ${cleared} 个空目录"
            log_msg "INFO" "$msg"
        fi
        if [ "$cleared" -gt 0 ]; then
            kill "$INOTIFYWAIT_PID" 2>/dev/null; INOTIFYWAIT_PID=""
            [ -n "$WATCHDOG_PID" ] && { kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""; }
            rm -f "$EVT_FIFO"; return 1
        fi
    fi

    while IFS="$TAB" read -r raw_dir fname event <&9; do
        [ "$raw_dir" = "__WATCHDOG_RESTART__" ] && break
        [ -z "$fname" ] && continue
        local dir; dir=$(canon_path "${raw_dir%/}")
        apply_rules "${dir}/${fname}" "$dir" "$fname" "$clean_rules" "$all_src_dirs"
        rotate_log
    done 9<>"$EVT_FIFO"

    [ -n "$WATCHDOG_PID" ]    && { kill "$WATCHDOG_PID"    2>/dev/null; WATCHDOG_PID=""; }
    [ -n "$INOTIFYWAIT_PID" ] && { kill "$INOTIFYWAIT_PID" 2>/dev/null; INOTIFYWAIT_PID=""; }
    rm -f "$EVT_FIFO"
    return 1
}

# ─────────────────────────────────────────────
# 主流程

main() {
    check_lock
    trap cleanup INT TERM HUP EXIT

    if [ -f "$LOG_FILE" ]; then
        local log_age; log_age=$(( $(date +%s) - $(stat -c '%Y' "$LOG_FILE" 2>/dev/null || echo 0) ))
        [ "$log_age" -gt $(( LOG_KEEP_DAYS * 86400 )) ] && > "$LOG_FILE"
    fi
    if [ -f "$MODDIR/.reload_flag" ]; then
        rm -f "$MODDIR/.reload_flag"
        log_msg "INFO" "── 热重启 PID=$$  STARTUP_SCAN=$STARTUP_SCAN  SCAN_AND_CLEAR=$SCAN_AND_CLEAR  CLEAR_EMPTY_PARENTS=$CLEAR_EMPTY_PARENTS ──"
    else
        log_msg "INFO" "── 启动 PID=$$  STARTUP_SCAN=$STARTUP_SCAN  SCAN_AND_CLEAR=$SCAN_AND_CLEAR  CLEAR_EMPTY_PARENTS=$CLEAR_EMPTY_PARENTS ──"
    fi
    sed -i 's|^description=.*|description=「启动中😇」 以极低功耗为核心，基于 inotify 事件驱动与 mv 原子操作构建的文件重定向系统。|' "$MODDIR/module.prop"

    wait_for_storage

    [ -f "$RULES_FILE" ] || {
        log_msg "ERROR" "规则文件不存在: $RULES_FILE"
        rm -f "$LOCK_FILE"; exit 1
    }

    rm -rf "$FILE_LOCK_DIR"  # 清理上次崩溃残留的文件锁

    local all_parsed valid_rules invalid_rules valid_count invalid_count
    all_parsed=$(parse_rules)
    valid_rules=$(  printf '%s\n' "$all_parsed" | grep '^VALID|')
    invalid_rules=$(printf '%s\n' "$all_parsed" | grep '^INVALID|')
    valid_count=$(  printf '%s\n' "$valid_rules"   | grep -c '^VALID|'   2>/dev/null || printf '0')
    invalid_count=$(printf '%s\n' "$invalid_rules" | grep -c '^INVALID|' 2>/dev/null || printf '0')
    [ -z "$valid_rules" ]   && valid_count=0
    [ -z "$invalid_rules" ] && invalid_count=0

    log_msg "INFO" "规则 $(( valid_count + invalid_count )) 条（有效 ${valid_count}，无效 ${invalid_count}）"
    if [ "$invalid_count" -gt 0 ]; then
        printf '%s\n' "$invalid_rules" | while IFS='|' read -r _tag line; do
            log_msg "WARN" "无效规则: $line"
        done
    fi
    [ "$valid_count" -eq 0 ] && log_msg "WARN" "暂无有效规则，修改规则文件后热重载生效"

    local inotifywait_bin="$MODDIR/tools/inotifywait"
    [ -x "$inotifywait_bin" ] || {
        log_msg "ERROR" "未找到 inotifywait: $inotifywait_bin"
        while true; do sleep 3600; done
    }

    local _sh_sum; _sh_sum=$(md5sum "$MODDIR/service.sh" 2>/dev/null | cut -d' ' -f1)

    sed -i 's|^description=.*|description=「运行中😋」 以极低功耗为核心，基于 inotify 事件驱动与 mv 原子操作构建的文件重定向系统。|' "$MODDIR/module.prop"
    local _first_run=1
    local _rules_mtime="" all_parsed="" _loop_err=0
    while true; do
        # 检测 KSU 是否已禁用本模块
        if [ -f "$MODDIR/disable" ]; then
            log_msg "INFO" "检测到模块已被禁用，服务停止"
            sed -i 's|^description=.*|description=「未运行😵」 以极低功耗为核心，基于 inotify 事件驱动与 mv 原子操作构建的文件重定向系统。|' "$MODDIR/module.prop"
            cleanup
        fi
        # 主循环崩溃保护：子函数异常不应导致整个服务退出
        _loop_err=0
        local cur_rules_mtime; cur_rules_mtime=$(stat -c '%Y' "$RULES_FILE" 2>/dev/null || echo 0)
        if [ "$cur_rules_mtime" != "$_rules_mtime" ]; then
            all_parsed=$(parse_rules)
            _rules_mtime="$cur_rules_mtime"
        fi
        monitor_inotifywait "$all_parsed" "$inotifywait_bin" "$_first_run" || true
        _first_run=0

        # 看门狗意外崩溃检测（子进程退出后 WATCHDOG_PID 仍有值但进程不存在）
        if [ -n "$WATCHDOG_PID" ] && ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
            log_msg "WARN" "看门狗意外退出，下轮重启时自动恢复"
            WATCHDOG_PID=""
        fi

        local cur_sum; cur_sum=$(md5sum "$MODDIR/service.sh" 2>/dev/null | cut -d' ' -f1)
        if [ "$cur_sum" != "$_sh_sum" ] && [ -n "$cur_sum" ]; then
            log_msg "INFO" "检测到 service.sh 更新，自动热重启..."
            [ -n "$WATCHDOG_PID" ]    && kill "$WATCHDOG_PID"    2>/dev/null
            [ -n "$INOTIFYWAIT_PID" ] && kill "$INOTIFYWAIT_PID" 2>/dev/null
            rm -f "$LOCK_FILE" "$EVT_FIFO"
            touch "$MODDIR/.reload_flag" 2>/dev/null
            trap - EXIT  # exec 成功后进程被替换，不应触发 cleanup
            exec sh "$MODDIR/service.sh" || {
                trap cleanup INT TERM HUP EXIT  # exec 失败，恢复 trap
                log_msg "ERROR" "exec 重载失败，回退到重启模式"
                nohup sh "$MODDIR/service.sh" >/dev/null 2>&1 &
                exit 0
            }
        fi

        sleep 2
    done
}

main "$@"
