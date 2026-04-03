#!/system/bin/sh
# customize.sh  —  听闻人间十三月
# "远处烟雨下的漓江每次都是匆匆而过"
#─────────────────────────────────────────────

MOD_ID="file_redirector"
INSTALLED="/data/adb/modules/$MOD_ID"
VER=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)

# 判断是否升级
if [ -f "$INSTALLED/service.sh" ] || [ -f "$INSTALLED/redirect.rules" ]; then
    MODE="升级"
else
    MODE="安装"
fi

echo
echo "========================================="
echo "        ${MODE}模块: 文件重定向 ${VER}"
echo "========================================="
echo

#─────────────────────────────────────────────
# 保留用户设置和规则（升级时）
if [ "$MODE" = "升级" ]; then
    echo "[*] 保留用户设置和规则..."

    # 保留 service.sh 设置
    if [ -f "$INSTALLED/service.sh" ]; then
        for key in STARTUP_SCAN SCAN_AND_CLEAR CLEAR_EMPTY_PARENTS MEDIA_WAIT LOG_KEEP_DAYS; do
            val=$(grep "^${key}=" "$INSTALLED/service.sh" | cut -d= -f2)
            [ -n "$val" ] && sed -i "s/^${key}=.*/${key}=${val}/" "$MODPATH/service.sh"
        done
    fi

    # 保留 WebUI 主题
    [ -f "$INSTALLED/.webui_theme" ] && cp "$INSTALLED/.webui_theme" "$MODPATH/.webui_theme"

    # 合并用户规则
    if [ -f "$INSTALLED/redirect.rules" ]; then
        has_rule=0
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            has_rule=1; break
        done < "$INSTALLED/redirect.rules"

        if [ "$has_rule" -eq 1 ]; then
            unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
            NEW="$MODPATH/redirect.rules"
            OUT="$MODPATH/redirect.rules.merged"

            # 写入新模板头部（含分隔标记行本身）
            sed -n '1,/^# 下面填写路径/p' "$NEW" > "$OUT"

            # 追加旧文件分隔标记行之后的用户规则
            sed -n '/^# 下面填写路径/,$ { /^# 下面填写路径/d; p }' \
                "$INSTALLED/redirect.rules" >> "$OUT"

            mv "$OUT" "$MODPATH/redirect.rules"
        else
            unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
        fi
    else
        unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
    fi

    echo "已保留旧设置"
else
    # 初次安装直接解压默认规则
    unzip -o "$ZIPFILE" redirect.rules -d "$MODPATH" >&2
    echo "默认规则已解压"
fi

#─────────────────────────────────────────────
# 设置权限
echo "[*] 设置文件权限..."
set_perm "$MODPATH/service.sh"     root root 0755
set_perm "$MODPATH/uninstall.sh"   root root 0755
set_perm "$MODPATH/redirect.rules" root root 0644
[ -f "$MODPATH/tools/inotifywait" ] && set_perm "$MODPATH/tools/inotifywait" root root 0755
for so in "$MODPATH/tools/"*.so; do
    [ -f "$so" ] && set_perm "$so" root root 0644
done
echo "设置完成！"

#清理框架默认过滤外的不必要文件
rm -f "$MODPATH/LICENSE"
rm -f "$MODPATH/changelog.md"

#─────────────────────────────────────────────
echo
echo "========================================="
echo "        模块${MODE}完成 🎉"
echo "========================================="
echo
