#!/bin/bash
#==============================================================================
# VPS一键装机 — 现代卡片式 TUI 交互引擎 (lib/tui.sh)
# 风格: 智能电视 (Smart TV) 菜单 / Pad 应用 / BIOS 风格沉浸式面板
# 特性: 方向键导航、鼠标点击、卡片高亮、左右分栏预览、安全降级
#==============================================================================

# 终端能力检测与标志
TUI_ENABLED=false
TUI_MOUSE_ACTIVE=false
TUI_ALT_SCREEN=false

# 检查当前环境是否支持完整 TUI
tui_is_supported() {
    # 必须标准输入和标准输出都是终端，且非禁用
    if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
        return 1
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 1
    fi
    if [ "${TERM:-}" = "dumb" ] || [ "${NO_COLOR:-}" = "1" ]; then
        return 1
    fi
    if command -v tput >/dev/null 2>&1; then
        local cols
        cols=$(tput cols 2>/dev/null || true)
        if [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -lt 60 ]; then
            return 1
        fi
    fi
    return 0
}

# 初始化 TUI 环境（进入备用屏幕、启用鼠标、隐藏光标）
tui_enter() {
    if ! tui_is_supported; then
        return 0
    fi
    TUI_ENABLED=true
    
    # 切换到备用屏幕缓冲区，保存原始屏幕内容
    printf '\e[?1049h'
    TUI_ALT_SCREEN=true
    
    # 启用鼠标追踪 (SGR 1006 模式 + 正常点击 1000)
    printf '\e[?1000h\e[?1006h'
    TUI_MOUSE_ACTIVE=true
    
    # 隐藏光标
    printf '\e[?25l'
    
    # 设置退出陷阱，保证任何情况下终端正常复原
    trap tui_leave EXIT INT TERM
}

# 退出 TUI 环境（恢复屏幕、禁用鼠标、显示光标）
tui_leave() {
    if [ "$TUI_MOUSE_ACTIVE" = "true" ]; then
        printf '\e[?1000l\e[?1006l'
        TUI_MOUSE_ACTIVE=false
    fi
    if [ "$TUI_ALT_SCREEN" = "true" ]; then
        printf '\e[?25h'
        printf '\e[?1049l'
        TUI_ALT_SCREEN=false
    fi
    printf '\e[?25h'
    stty echo icanon 2>/dev/null || true
    TUI_ENABLED=false
}

# 获取终端尺寸
tui_get_size() {
    local lines cols
    if command -v tput >/dev/null 2>&1; then
        lines=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
    else
        lines=24
        cols=80
    fi
    [ "$lines" -lt 15 ] && lines=15
    [ "$cols" -lt 60 ] && cols=80
    echo "$lines $cols"
}

# 字符串填充与对齐工具
tui_pad_right() {
    local str="$1" len="$2" fill="${3:- }"
    # 去除颜色代码计算可见字符长度
    local clean_str
    clean_str=$(echo -e "$str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local cur_len=${#clean_str}
    local pad_count=$((len - cur_len))
    if [ "$pad_count" -gt 0 ]; then
        local pad=""
        for ((i=0; i<pad_count; i++)); do pad+="$fill"; done
        printf '%b%s' "$str" "$pad"
    else
        printf '%b' "$str"
    fi
}

# 读取单个按键或鼠标事件
# 返回值写入全局变量 TUI_KEY, TUI_MOUSE_X, TUI_MOUSE_Y, TUI_MOUSE_ACTION
tui_read_event() {
    TUI_KEY=""
    TUI_MOUSE_X=0
    TUI_MOUSE_Y=0
    TUI_MOUSE_ACTION=""
    
    local char seq
    # 设置无回显、无缓冲读取
    stty -icanon -echo min 1 time 0 2>/dev/null || true
    IFS= read -rsn1 char || return 1
    
    if [ "$char" = $'\e' ]; then
        # 读取后续转义序列
        read -rsn1 -t 0.2 seq1 || { TUI_KEY="ESC"; return 0; }
        if [ "$seq1" = "[" ] || [ "$seq1" = "O" ]; then
            read -rsn1 -t 0.2 seq2 || { TUI_KEY="ESC"; return 0; }
            case "$seq2" in
                A) TUI_KEY="UP" ;;
                B) TUI_KEY="DOWN" ;;
                C) TUI_KEY="RIGHT" ;;
                D) TUI_KEY="LEFT" ;;
                H) TUI_KEY="HOME" ;;
                F) TUI_KEY="END" ;;
                Z) TUI_KEY="SHIFT_TAB" ;;
                "<")
                    # SGR 1006 鼠标事件: \e[<Btn;X;YM 或 m
                    local mouse_buf="" m_char=""
                    while read -rsn1 -t 0.2 m_char; do
                        if [ "$m_char" = "M" ] || [ "$m_char" = "m" ]; then
                            mouse_buf+="$m_char"
                            break
                        fi
                        mouse_buf+="$m_char"
                    done
                    # 匹配格式: Btn;X;Y[M|m]
                    if [[ "$mouse_buf" =~ ^([0-9]+)\;([0-9]+)\;([0-9]+)([Mm])$ ]]; then
                        local btn="${BASH_REMATCH[1]}"
                        local mx="${BASH_REMATCH[2]}"
                        local my="${BASH_REMATCH[3]}"
                        local action="${BASH_REMATCH[4]}"
                        TUI_MOUSE_X="$mx"
                        TUI_MOUSE_Y="$my"
                        if [ "$action" = "M" ] && [ "$btn" = "0" ]; then
                            TUI_KEY="MOUSE_CLICK"
                        elif [ "$btn" = "64" ]; then
                            TUI_KEY="UP" # 滚轮上
                        elif [ "$btn" = "65" ]; then
                            TUI_KEY="DOWN" # 滚轮下
                        fi
                    fi
                    ;;
                [0-9])
                    # 可能为 PageUp(5~), PageDown(6~), Delete(3~)
                    read -rsn1 -t 0.2 seq3 || true
                    case "$seq2$seq3" in
                        "5~") TUI_KEY="PAGE_UP" ;;
                        "6~") TUI_KEY="PAGE_DOWN" ;;
                        "3~") TUI_KEY="DELETE" ;;
                    esac
                    ;;
            esac
        else
            TUI_KEY="ESC"
        fi
    elif [ "$char" = "" ] || [ "$char" = $'\n' ] || [ "$char" = $'\r' ]; then
        TUI_KEY="ENTER"
    elif [ "$char" = " " ]; then
        TUI_KEY="SPACE"
    elif [ "$char" = $'\t' ]; then
        TUI_KEY="TAB"
    elif [ "$char" = $'\x7f' ] || [ "$char" = $'\x08' ]; then
        TUI_KEY="BACKSPACE"
    else
        TUI_KEY="$char"
    fi
    return 0
}

# 渲染顶部 BIOS / Smart TV 统一头部横幅
tui_draw_header() {
    local breadcrumb="${1:-VPS 一键装机 BIOS 控制台}"
    local sys_info
    sys_info="$(detect_os_id 2>/dev/null || uname -s) | $(uname -m 2>/dev/null || true)"
    
    local size lines cols
    read -r lines cols <<< "$(tui_get_size)"
    local w=$((cols - 4))
    [ "$w" -gt 96 ] && w=96
    [ "$w" -lt 56 ] && w=56

    printf '\e[H' # 移动到屏幕原点 (1,1)
    
    # 顶部装饰双线与标题条
    echo -e "\e[1;36m╔$(printf '═%.0s' $(seq 1 $w))╗\e[0m"
    
    # 面包屑与系统信息
    local left_text=" \e[1;37m❖  ${breadcrumb}\e[0m"
    local right_text="\e[2;37m${sys_info}\e[0m "
    
    # 计算中间空格
    local raw_left raw_right
    raw_left=$(echo -e "$left_text" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    raw_right=$(echo -e "$right_text" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local spaces=$((w - ${#raw_left} - ${#raw_right}))
    [ "$spaces" -lt 1 ] && spaces=1
    local space_pad=""
    for ((i=0; i<spaces; i++)); do space_pad+=" "; done
    
    echo -e "\e[1;36m║\e[0m${left_text}${space_pad}${right_text}\e[1;36m║\e[0m"
    echo -e "\e[1;36m╠$(printf '═%.0s' $(seq 1 $w))╣\e[0m"
}

# 渲染底部操作快捷键导航栏
tui_draw_footer() {
    local custom_hint="${1:-}"
    local size lines cols
    read -r lines cols <<< "$(tui_get_size)"
    local w=$((cols - 4))
    [ "$w" -gt 96 ] && w=96
    [ "$w" -lt 56 ] && w=56

    echo -e "\e[1;36m╠$(printf '═%.0s' $(seq 1 $w))╣\e[0m"
    local hint_text=" \e[1;33m[↑/↓]\e[0m 导航   \e[1;33m[Enter]\e[0m 确认   \e[1;33m[Esc/b]\e[0m 返回   \e[1;32m[🖱 鼠标]\e[0m 点击直达"
    [ -n "$custom_hint" ] && hint_text=" $custom_hint"
    
    local raw_hint
    raw_hint=$(echo -e "$hint_text" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local pad_len=$((w - ${#raw_hint}))
    local pad=""
    for ((i=0; i<pad_len; i++)); do pad+=" "; done
    
    echo -e "\e[1;36m║\e[0m${hint_text}${pad}\e[1;36m║\e[0m"
    echo -e "\e[1;36m╚$(printf '═%.0s' $(seq 1 $w))╝\e[0m"
}

#==============================================================================
# 1. 卡片式垂直选择菜单控件 (Smart TV / BIOS 列表选择)
#==============================================================================
tui_menu_select() {
    local __var="$1"
    local title="$2"
    local prompt="$3"
    local default_idx="${4:-1}"
    shift 4
    local options=("$@")
    local num_options=${#options[@]}

    if ! tui_is_supported; then
        # 自动降级为标准命令行提示
        local def_val="${options[$((default_idx - 1))]:-${options[0]}}"
        if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
            printf -v "$__var" '%s' "$def_val"
            return 0
        fi
        echo -e "${CYAN}=== ${title} ===${NC}"
        echo "$prompt"
        local idx=1
        for opt in "${options[@]}"; do
            echo -e "  $idx) $opt $([ "$idx" -eq "$default_idx" ] && echo "[默认]")"
            idx=$((idx + 1))
        done
        echo -e "  b) 返回上一步"
        while true; do
            local choice
            read -r -p "请选择 [1-$num_options] (默认: $default_idx, 输入 b 返回): " choice
            choice="${choice:-$default_idx}"
            [ "$choice" = "b" ] || [ "$choice" = "back" ] && return 2
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$num_options" ]; then
                printf -v "$__var" '%s' "${options[$((choice - 1))]}"
                return 0
            fi
            echo -e "${RED}请输入有效选项编号${NC}"
        done
    fi

    tui_enter
    local selected_idx=$((default_idx - 1))
    [ "$selected_idx" -lt 0 ] && selected_idx=0
    [ "$selected_idx" -ge "$num_options" ] && selected_idx=$((num_options - 1))

    local start_row=5 # 菜单项在屏幕上的起始绝对行号（用于鼠标点击定位）

    while true; do
        local size lines cols
        read -r lines cols <<< "$(tui_get_size)"
        local w=$((cols - 4))
        [ "$w" -gt 96 ] && w=96
        [ "$w" -lt 56 ] && w=56

        # 绘制 Header
        tui_draw_header "$title"
        
        # 绘制提示语
        local prompt_line=" \e[1;37m📌 ${prompt}\e[0m"
        local raw_p
        raw_p=$(echo -e "$prompt_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        local p_pad=$((w - ${#raw_p}))
        local pad=""
        for ((i=0; i<p_pad; i++)); do pad+=" "; done
        echo -e "\e[1;36m║\e[0m${prompt_line}${pad}\e[1;36m║\e[0m"
        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"

        # 绘制选项卡片列表
        for ((i=0; i<num_options; i++)); do
            local opt="${options[$i]}"
            local item_str=""
            local card_w=$((w - 6))
            
            if [ "$i" -eq "$selected_idx" ]; then
                # 高亮聚焦卡片 (Smart TV 选中高光风格)
                local content="  \e[1;30;46m ▶  $(printf "%-2d" $((i + 1))). %-${card_w}s \e[0m"
                printf -v item_str "$content" "$opt"
            else
                # 普通卡片
                local content="     \e[0;37m$(printf "%-2d" $((i + 1))). %-${card_w}s\e[0m "
                printf -v item_str "$content" "$opt"
            fi
            
            local raw_item
            raw_item=$(echo -e "$item_str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
            local it_pad=$((w - ${#raw_item}))
            local ip=""
            for ((k=0; k<it_pad; k++)); do ip+=" "; done
            echo -e "\e[1;36m║\e[0m${item_str}${ip}\e[1;36m║\e[0m"
        done

        # 补齐空行以保持美观固定高度
        local current_rendered=$((5 + num_options))
        local min_content_height=14
        for ((i=current_rendered; i<min_content_height; i++)); do
            echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"
        done

        # 绘制 Footer
        tui_draw_footer " \e[1;33m[↑/↓]\e[0m 选择  \e[1;32m[Enter]\e[0m 确认  \e[1;31m[b/Esc]\e[0m 返回  \e[1;36m[🖱 点击]\e[0m 直达"

        # 读取事件
        tui_read_event
        case "$TUI_KEY" in
            UP)
                selected_idx=$(( (selected_idx - 1 + num_options) % num_options ))
                ;;
            DOWN)
                selected_idx=$(( (selected_idx + 1) % num_options ))
                ;;
            ENTER|SPACE)
                printf -v "$__var" '%s' "${options[$selected_idx]}"
                tui_leave
                return 0
                ;;
            BACK|ESC|QUIT|[bBqQ])
                tui_leave
                return 2
                ;;
            MOUSE_CLICK)
                # 计算点击的行号对应哪个选项
                # start_row 为第 6 行
                local clicked_idx=$((TUI_MOUSE_Y - 6))
                if [ "$clicked_idx" -ge 0 ] && [ "$clicked_idx" -lt "$num_options" ]; then
                    if [ "$clicked_idx" -eq "$selected_idx" ]; then
                        # 再次点击直接确认
                        printf -v "$__var" '%s' "${options[$selected_idx]}"
                        tui_leave
                        return 0
                    else
                        selected_idx="$clicked_idx"
                    fi
                elif [ "$TUI_MOUSE_Y" -ge "$((min_content_height + 1))" ]; then
                    # 点击底部区域尝试退出或确认
                    :
                fi
                ;;
            [1-9])
                local direct_idx=$((TUI_KEY - 1))
                if [ "$direct_idx" -lt "$num_options" ]; then
                    selected_idx="$direct_idx"
                    printf -v "$__var" '%s' "${options[$selected_idx]}"
                    tui_leave
                    return 0
                fi
                ;;
        esac
    done
}

#==============================================================================
# 2. Smart TV 水平双卡片 Yes/No 开关控件
#==============================================================================
tui_yesno_box() {
    local title="$1"
    local prompt="${2:-$1}"
    local default="${3:-y}"
    local subtitle="${4:-}"

    local default_idx=0
    case "${default,,}" in
        y|yes|1|t|true) default_idx=0 ;;
        *) default_idx=1 ;;
    esac

    if ! tui_is_supported; then
        case "$default" in
            [Yy1]|[Yy][eE][sS]|[Tt][Rr][Uu][Ee]) return 0 ;;
            *) return 1 ;;
        esac
    fi

    tui_enter
    local selected="$default_idx" # 0: Yes, 1: No

    while true; do
        local size lines cols
        read -r lines cols <<< "$(tui_get_size)"
        local w=$((cols - 4))
        [ "$w" -gt 96 ] && w=96
        [ "$w" -lt 56 ] && w=56

        tui_draw_header "$title"
        
        # 提示文案
        local prompt_line=" \e[1;37m❓ ${prompt}\e[0m"
        local raw_p
        raw_p=$(echo -e "$prompt_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        local p_pad=$((w - ${#raw_p}))
        local pad=""
        for ((i=0; i<p_pad; i++)); do pad+=" "; done
        echo -e "\e[1;36m║\e[0m${prompt_line}${pad}\e[1;36m║\e[0m"
        
        if [ -n "$subtitle" ]; then
            local sub_line=" \e[2;37m   ${subtitle}\e[0m"
            local raw_sub
            raw_sub=$(echo -e "$sub_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
            local s_pad=$((w - ${#raw_sub}))
            local spad=""
            for ((i=0; i<s_pad; i++)); do spad+=" "; done
            echo -e "\e[1;36m║\e[0m${sub_line}${spad}\e[1;36m║\e[0m"
        else
            echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"
        fi

        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"

        # 渲染双卡片（水平并排 Smart TV 遥控器大按钮卡片）
        local yes_card no_card
        if [ "$selected" -eq 0 ]; then
            yes_card="\e[1;30;42m   ✔  是 / YES (启用推荐)   \e[0m"
            no_card="\e[0;37;40m      ✖  否 / NO (跳过)     \e[0m"
        else
            yes_card="\e[0;37;40m      ✔  是 / YES (启用推荐)   \e[0m"
            no_card="\e[1;30;41m   ✖  否 / NO (跳过)     \e[0m"
        fi

        local buttons_line="      ${yes_card}      ${no_card}"
        local raw_btn
        raw_btn=$(echo -e "$buttons_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        local b_pad=$((w - ${#raw_btn}))
        local bpad=""
        for ((i=0; i<b_pad; i++)); do bpad+=" "; done
        echo -e "\e[1;36m║\e[0m${buttons_line}${bpad}\e[1;36m║\e[0m"

        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"
        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"

        tui_draw_footer " \e[1;33m[←/→/Tab]\e[0m 切换   \e[1;32m[Enter]\e[0m 确认选择   \e[1;31m[b/Esc]\e[0m 返回上一步   \e[1;36m[🖱 点击]\e[0m 按钮"

        tui_read_event
        case "$TUI_KEY" in
            LEFT|RIGHT|TAB|SPACE)
                selected=$(( 1 - selected ))
                ;;
            ENTER)
                tui_leave
                [ "$selected" -eq 0 ] && return 0 || return 1
                ;;
            BACK|ESC|QUIT|[bBqQ])
                tui_leave
                return 2
                ;;
            [yY])
                tui_leave
                return 0
                ;;
            [nN])
                tui_leave
                return 1
                ;;
            MOUSE_CLICK)
                # Y 坐标在按钮行附近 (行号大约为 7~8)
                if [ "$TUI_MOUSE_Y" -ge 6 ] && [ "$TUI_MOUSE_Y" -le 9 ]; then
                    if [ "$TUI_MOUSE_X" -le 35 ]; then
                        selected=0
                    else
                        selected=1
                    fi
                    tui_leave
                    [ "$selected" -eq 0 ] && return 0 || return 1
                fi
                ;;
        esac
    done
}

#==============================================================================
# 3. 卡片式文本与密码输入控件
#==============================================================================
tui_card_input() {
    local __var="$1"
    local title="$2"
    local prompt="$3"
    local default_val="$4"
    local hint_text="${5:-}"
    local is_password="${6:-false}"

    if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
        printf -v "$__var" '%s' "$default_val"
        return 0
    fi

    if ! tui_is_supported; then
        local ans
        if [ "$is_password" = "true" ]; then
            read -rsp "$prompt [留空默认]: " ans
            echo
        else
            read -r -p "$prompt [默认: $default_val] (输入 b 返回): " ans
        fi
        [ "$ans" = "b" ] || [ "$ans" = "back" ] && return 2
        [ -z "$ans" ] && ans="$default_val"
        printf -v "$__var" '%s' "$ans"
        return 0
    fi

    tui_enter
    local input_val=""

    while true; do
        local size lines cols
        read -r lines cols <<< "$(tui_get_size)"
        local w=$((cols - 4))
        [ "$w" -gt 96 ] && w=96
        [ "$w" -lt 56 ] && w=56

        tui_draw_header "$title"

        # 提示文案
        local prompt_line=" \e[1;37m✍  ${prompt}\e[0m"
        local raw_p
        raw_p=$(echo -e "$prompt_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
        local p_pad=$((w - ${#raw_p}))
        local pad=""
        for ((i=0; i<p_pad; i++)); do pad+=" "; done
        echo -e "\e[1;36m║\e[0m${prompt_line}${pad}\e[1;36m║\e[0m"

        # 详细提示
        if [ -n "$hint_text" ]; then
            local h_line=" \e[2;37m   ${hint_text}\e[0m"
            local raw_h
            raw_h=$(echo -e "$h_line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
            local h_pad=$((w - ${#raw_h}))
            local hpad=""
            for ((i=0; i<h_pad; i++)); do hpad+=" "; done
            echo -e "\e[1;36m║\e[0m${h_line}${hpad}\e[1;36m║\e[0m"
        else
            echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"
        fi

        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"

        # 卡片式输入框框体
        local display_val="$input_val"
        if [ "$is_password" = "true" ]; then
            display_val="$(printf '•%.0s' $(seq 1 ${#input_val}))"
        fi
        if [ -z "$display_val" ]; then
            if [ -n "$default_val" ]; then
                display_val="(默认: ${default_val})"
            else
                display_val="(留空)"
            fi
        fi

        local box_w=$((w - 10))
        local visible_val="${display_val}▏"
        if [ "${#visible_val}" -gt "$box_w" ]; then
            visible_val="...${visible_val: -$((box_w - 3))}"
        fi
        printf '\e[1;36m║\e[0m   \e[1;37;44m ⌨  %-*s \e[0m\e[1;36m║\e[0m\n' "$box_w" "$visible_val"

        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"
        echo -e "\e[1;36m║\e[0m$(printf ' %.0s' $(seq 1 $w))\e[1;36m║\e[0m"

        tui_draw_footer " \e[1;32m[直接打字]\e[0m 输入内容   \e[1;32m[Enter]\e[0m 提交确认   \e[1;33m[Backspace]\e[0m 删除   \e[1;31m[Esc]\e[0m 返回"

        tui_read_event
        case "$TUI_KEY" in
            ENTER)
                [ -z "$input_val" ] && input_val="$default_val"
                printf -v "$__var" '%s' "$input_val"
                tui_leave
                return 0
                ;;
            BACKSPACE)
                if [ ${#input_val} -gt 0 ]; then
                    input_val="${input_val%?}"
                fi
                ;;
            ESC|QUIT)
                tui_leave
                return 2
                ;;
            *)
                if [ ${#TUI_KEY} -eq 1 ]; then
                    input_val+="$TUI_KEY"
                fi
                ;;
        esac
    done
}
