#!/bin/bash
#==============================================================================
# VPS一键装机 — 现代流式交互 UI 引擎 (lib/tui.sh)
# 风格: 现代极简 CLI / 优雅卡片 / 原地光标导航 / 零外部依赖
# 特性: 
#   - 原地平滑交互 (不全屏清屏，不破坏终端历史)
#   - 键盘 ↑/↓/k/j 方向键平滑高亮选择，支持数字键秒选
#   - 优雅的 Yes/No 切换开关 (←/→/Tab/Space)
#   - 原生支持光标编辑、历史记录与 SSH 公钥安全粘贴
#==============================================================================

# 终端能力检测
tui_is_supported() {
    if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
        return 1
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 1
    fi
    if [ "${TERM:-}" = "dumb" ] || [ "${NO_COLOR:-}" = "1" ]; then
        return 1
    fi
    return 0
}

# 隐藏/显示光标
tui_hide_cursor() { printf '\e[?25l'; }
tui_show_cursor() { printf '\e[?25h'; }

# 读取按键事件 (支持方向键、Tab、Space、Enter、Esc、b、数字等)
tui_get_key() {
    local key="" char seq1 seq2
    stty -icanon -echo min 1 time 0 2>/dev/null || true
    IFS= read -rsn1 char || return 1

    if [ "$char" = $'\e' ]; then
        read -rsn1 -t 0.1 seq1 || { printf 'ESC'; return 0; }
        if [ "$seq1" = "[" ] || [ "$seq1" = "O" ]; then
            read -rsn1 -t 0.1 seq2 || { printf 'ESC'; return 0; }
            case "$seq2" in
                A) key="UP" ;;
                B) key="DOWN" ;;
                C) key="RIGHT" ;;
                D) key="LEFT" ;;
                H) key="HOME" ;;
                F) key="END" ;;
                Z) key="SHIFT_TAB" ;;
                *) key="ESC" ;;
            esac
        else
            key="ESC"
        fi
    elif [ "$char" = "" ] || [ "$char" = $'\n' ] || [ "$char" = $'\r' ]; then
        key="ENTER"
    elif [ "$char" = " " ]; then
        key="SPACE"
    elif [ "$char" = $'\t' ]; then
        key="TAB"
    elif [ "$char" = "k" ] || [ "$char" = "K" ]; then
        key="UP"
    elif [ "$char" = "j" ] || [ "$char" = "J" ]; then
        key="DOWN"
    elif [ "$char" = "h" ] || [ "$char" = "H" ]; then
        key="LEFT"
    elif [ "$char" = "l" ] || [ "$char" = "L" ]; then
        key="RIGHT"
    elif [ "$char" = "b" ] || [ "$char" = "B" ]; then
        key="BACK"
    elif [ "$char" = "q" ] || [ "$char" = "Q" ]; then
        key="QUIT"
    else
        key="$char"
    fi

    printf '%s' "$key"
}

#==============================================================================
# 1. 现代原地列表选择菜单 (Inline Interactive Select Menu)
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
        local def_val="${options[$((default_idx - 1))]:-${options[0]}}"
        if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
            printf -v "$__var" '%s' "$def_val"
            return 0
        fi
        echo -e "\n\033[1;36m◆ ${title}\033[0m"
        [ -n "$prompt" ] && echo -e "  \033[2;37m${prompt}\033[0m"
        local idx=1
        for opt in "${options[@]}"; do
            if [ "$idx" -eq "$default_idx" ]; then
                echo -e "  \033[1;36m${idx})\033[0m \033[1;37;48;5;236m ${opt} \033[0m \033[38;5;243m[默认]\033[0m"
            else
                echo -e "  \033[2;37m${idx})\033[0m ${opt}"
            fi
            idx=$((idx + 1))
        done
        echo -e "  \033[2;37mb)\033[0m \033[2;37m返回上一步\033[0m"
        while true; do
            local choice
            # read returns non-zero on EOF (piped stdin exhausted) — treat as cancel
            if ! read -r -p "请选择 [1-$num_options] (默认: $default_idx, 输入 b 返回): " choice; then
                return 2
            fi
            choice="${choice:-$default_idx}"
            [ "$choice" = "b" ] || [ "$choice" = "back" ] && return 2
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$num_options" ]; then
                printf -v "$__var" '%s' "${options[$((choice - 1))]}"
                return 0
            fi
            echo -e "\033[0;31m请输入有效的选项编号 [1-$num_options]\033[0m"
        done
    fi

    local selected_idx=$((default_idx - 1))
    [ "$selected_idx" -lt 0 ] && selected_idx=0
    [ "$selected_idx" -ge "$num_options" ] && selected_idx=$((num_options - 1))

    tui_hide_cursor
    trap 'tui_show_cursor; stty echo icanon 2>/dev/null || true' EXIT INT TERM

    echo ""
    echo -e "  \033[1;36m◆ ${title}\033[0m"
    if [ -n "$prompt" ]; then
        echo -e "    \033[2;37m${prompt}\033[0m"
    fi

    local first_draw=true
    local render_lines=$((num_options + 2))

    while true; do
        if [ "$first_draw" = false ]; then
            printf "\e[%dA" "$render_lines"
        fi
        first_draw=false

        for ((i=0; i<num_options; i++)); do
            local opt="${options[$i]}"
            printf '\e[2K'
            if [ "$i" -eq "$selected_idx" ]; then
                echo -e "    \033[1;36m❯\033[0m \033[1;37;48;5;236m $((i + 1)). ${opt} \033[0m $([ "$((i + 1))" -eq "$default_idx" ] && echo -e "\033[38;5;243m[默认]\033[0m")"
            else
                echo -e "      \033[2;37m$((i + 1)). ${opt}\033[0m"
            fi
        done

        printf '\e[2K'
        echo -e "      \033[2;37mb. 返回上一步\033[0m"
        printf '\e[2K'
        echo -e "    \033[38;5;241m[↑/↓/j/k] 移动   [Enter] 确认   [1-$num_options] 快捷键   [b/Esc] 返回\033[0m"

        local key
        key="$(tui_get_key)"
        case "$key" in
            UP)
                selected_idx=$(( (selected_idx - 1 + num_options) % num_options ))
                ;;
            DOWN)
                selected_idx=$(( (selected_idx + 1) % num_options ))
                ;;
            ENTER|SPACE)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                printf -v "$__var" '%s' "${options[$selected_idx]}"
                echo -e "    \033[1;32m✔ 已选择: \033[1;37m${options[$selected_idx]}\033[0m\n"
                return 0
                ;;
            ESC|BACK|QUIT)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    \033[38;5;243m已取消\033[0m\n"
                return 2
                ;;
            [1-9])
                local direct_idx=$((key - 1))
                if [ "$direct_idx" -lt "$num_options" ]; then
                    selected_idx="$direct_idx"
                    tui_show_cursor
                    stty echo icanon 2>/dev/null || true
                    printf -v "$__var" '%s' "${options[$selected_idx]}"
                    echo -e "    \033[1;32m✔ 已选择: \033[1;37m${options[$selected_idx]}\033[0m\n"
                    return 0
                fi
                ;;
        esac
    done
}

#==============================================================================
# 2. 现代 Yes/No 切换开关 (Modern Inline Toggle Switch)
#==============================================================================
tui_yesno_box() {
    local title="$1"
    local prompt="${2:-$1}"
    local default="${3:-y}"

    local default_idx=0
    case "${default,,}" in
        y|yes|1|t|true) default_idx=0 ;;
        *) default_idx=1 ;;
    esac

    if ! tui_is_supported; then
        local def_char="Y/n"
        [ "$default_idx" -eq 1 ] && def_char="y/N"
        echo -e "\n\033[1;36m◆ ${title}\033[0m"
        [ -n "$prompt" ] && echo -e "  \033[2;37m${prompt}\033[0m"
        while true; do
            local ans
            # read returns non-zero on EOF (piped stdin exhausted) — treat as cancel
            if ! read -r -p "  请选择 [1=是, 2=否, b=返回] (默认: $default_idx): " ans; then
                return 2
            fi
            if [ "$ans" = "b" ] || [ "$ans" = "back" ]; then
                return 2
            fi
            if [ -z "$ans" ]; then
                [ "$default_idx" -eq 0 ] && return 0 || return 1
            fi
            case "$ans" in
                1|[Yy]|[Yy][eE][sS]) return 0 ;;
                2|[Nn]|[Nn][oO]) return 1 ;;
                *) echo -e "\033[0;31m请输入 1(是) 或 2(否)\033[0m" ;;
            esac
        done
    fi

    local selected="$default_idx" # 0: Yes, 1: No

    tui_hide_cursor
    trap 'tui_show_cursor; stty echo icanon 2>/dev/null || true' EXIT INT TERM

    echo ""
    echo -e "  \033[1;36m◆ ${title}\033[0m"
    if [ -n "$prompt" ] && [ "$prompt" != "$title" ]; then
        echo -e "    \033[2;37m${prompt}\033[0m"
    fi

    local first_draw=true
    local render_lines=2

    while true; do
        if [ "$first_draw" = false ]; then
            printf "\e[%dA" "$render_lines"
        fi
        first_draw=false

        printf '\e[2K'
        if [ "$selected" -eq 0 ]; then
            echo -e "    \033[1;32m❯ [ ● 1. 是 / Yes (推荐) ]\033[0m    \033[2;37m[ ○ 2. 否 / No ]\033[0m"
        else
            echo -e "    \033[2;37m[ ○ 1. 是 / Yes ]\033[0m    \033[1;33m❯ [ ● 2. 否 / No ]\033[0m"
        fi

        printf '\e[2K'
        echo -e "    \033[38;5;241m[←/→/Tab/Space] 切换   [Enter] 确认   [y/n/1/2] 直选   [b/Esc] 返回\033[0m"

        local key
        key="$(tui_get_key)"
        case "$key" in
            LEFT|RIGHT|TAB|SPACE|UP|DOWN|h|l|j|k)
                selected=$(( 1 - selected ))
                ;;
            ENTER)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                if [ "$selected" -eq 0 ]; then
                    echo -e "    \033[1;32m✔ 是 (Yes)\033[0m\n"
                    return 0
                else
                    echo -e "    \033[38;5;243m✖ 否 (No)\033[0m\n"
                    return 1
                fi
                ;;
            ESC|BACK|QUIT)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    \033[38;5;243m已取消\033[0m\n"
                return 2
                ;;
            1|[yY])
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    \033[1;32m✔ 是 (Yes)\033[0m\n"
                return 0
                ;;
            2|[nN])
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    \033[38;5;243m✖ 否 (No)\033[0m\n"
                return 1
                ;;
        esac
    done
}

#==============================================================================
# 3. 现代化流式输入框 (Smart Inline Input Prompt)
#==============================================================================
tui_card_input() {
    local __var="$1"
    local title="$2"
    local prompt="$3"
    local default="$4"
    local subtitle="${5:-}"
    local is_password="${6:-false}"

    if ! tui_is_supported; then
        if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
            printf -v "$__var" '%s' "$default"
            return 0
        fi
        local fallback_answer
        if [ "$is_password" = "true" ]; then
            if ! read -rsp "$prompt (输入 b 返回): " fallback_answer; then
                echo ""
                return 2
            fi
            echo ""
        elif ! read -r -p "$prompt [默认: $default] (输入 b 返回): " fallback_answer; then
            return 2
        fi
        if [ "$fallback_answer" = "b" ] || [ "$fallback_answer" = "back" ]; then
            return 2
        fi
        printf -v "$__var" '%s' "${fallback_answer:-$default}"
        return 0
    fi

    echo ""
    echo -e "  \033[1;36m◆ ${title}\033[0m"
    if [ -n "$subtitle" ]; then
        echo -e "    \033[2;37m${subtitle}\033[0m"
    fi

    local answer=""
    local prompt_label="    \033[1;37m${prompt}\033[0m"
    if [ -n "$default" ]; then
        prompt_label+=" \033[38;5;243m[默认: ${default}]\033[0m"
    fi
    prompt_label+=" \033[38;5;241m(输入 b 返回)\033[0m: "

    tui_show_cursor
    stty echo icanon 2>/dev/null || true

    if [ "$is_password" = "true" ]; then
        if ! read -rsp "$(echo -e "$prompt_label")" answer; then
            echo ""
            return 2
        fi
        echo ""
    else
        if ! read -re -p "$(echo -e "$prompt_label")" answer; then
            return 2
        fi
    fi

    if [ "$answer" = "b" ] || [ "$answer" = "back" ]; then
        return 2
    fi

    if [ -z "$answer" ]; then
        answer="$default"
    fi

    printf -v "$__var" '%s' "$answer"
    echo -e "    \033[1;32m✔ 已设置: \033[1;37m$([ "$is_password" = "true" ] && echo "******" || echo "$answer")\033[0m\n"
    return 0
}
