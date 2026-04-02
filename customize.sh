# customize.sh — 安装脚本
# Copyright (c) 2026 听闻人间十三月
#─────────────────────────────────────────────

MOD_ID="file_redirector"
INSTALLED="/data/adb/modules/$MOD_ID"
VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)

ui_print ""
ui_print "  文件重定向 ${VER}"
ui_print ""

#─────────────────────────────────────────────
# 解压核心文件 
unzip -o "$ZIPFILE" service.sh uninstall.sh -d "$MODPATH" >&2
unzip -o "$ZIPFILE" "webroot/*" -d "$MODPATH" >&2 2>/dev/null || true
unzip -o "$ZIPFILE" "tools/*"   -d "$MODPATH" >&2 2>/dev/null || true

# 保留用户设置（升级时）
if [ -f "$INSTALLED/service.sh" ]; then
    for key in STARTUP_SCAN SCAN_AND_CLEAR CLEAR_EMPTY_PARENTS MEDIA_WAIT LOG_KEEP_DAYS; do
        val=$(grep "^${key}=" "$INSTALLED/service.sh" | cut -d= -f2)
        [ -n "$val" ] && sed -i "s/^${key}=.*/${key}=${val}/" "$MODPATH/service.sh"
    done
    ui_print "  已保留用户设置"
fi

# 保留 WebUI 主题
[ -f "$INSTALLED/.webui_theme" ] && cp "$INSTALLED/.webui_theme" "$MODPATH/.webui_theme"

# 保留用户规则（升级时）
if [ -f "$INSTALLED/redirect.rules" ]; then
    has_rule=0
    while IFS= read -r line; do
        case "$line" in ''|'#'*|'='*) continue ;; esac
        has_rule=1; break
    done < "$INSTALLED/redirect.rules"

    if [ "$has_rule" -eq 1 ]; then
        # 解压新默认规则（含最新 depth 值）
        unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
        NEW="$MODPATH/redirect.rules"
        OUT="$MODPATH/redirect.rules.merged"

        # 写入头部注释（来自新文件）
        while IFS= read -r line; do
            case "$line" in '['*) break ;; esac
            printf '%s\n' "$line" >> "$OUT"
        done < "$NEW"

        # 逐行处理用户规则，匹配则用新文件的 depth 补全
        while IFS= read -r uline; do
            case "$uline" in ''|'='*) continue ;;
                '##'*) prefix='##'; core="${uline#\#\#}"; core="${core# }" ;;
                '#'*)  continue ;;
                *)     prefix='';   core="$uline" ;;
            esac
            three=$(printf '%s' "$core" | sed 's/^\(\[[^]]*\]+\[[^]]*\]+\[[^]]*\]\).*/\1/')
            new_line=$(grep -F "$three" "$NEW" 2>/dev/null | head -1)
            if [ -n "$new_line" ]; then
                [ -n "$prefix" ] && printf '## %s\n' "$new_line" >> "$OUT" \
                                 || printf '%s\n' "$new_line" >> "$OUT"
            else
                printf '%s\n' "$uline" >> "$OUT"
            fi
        done < "$INSTALLED/redirect.rules"

        mv "$OUT" "$MODPATH/redirect.rules"
        ui_print "  已保留用户规则"
    else
        unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
    fi
else
    unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
fi
#─────────────────────────────────────────────
# 设置权限
set_perm "$MODPATH/service.sh"     root root 0755
set_perm "$MODPATH/uninstall.sh"   root root 0755
set_perm "$MODPATH/redirect.rules" root root 0644
[ -f "$MODPATH/tools/inotifywait" ] && \
    set_perm "$MODPATH/tools/inotifywait" root root 0755
for so in "$MODPATH/tools/"*.so; do
    [ -f "$so" ] && set_perm "$so" root root 0644
done

ui_print ""
