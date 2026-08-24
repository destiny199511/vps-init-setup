#!/bin/bash
#==============================================================================
# VPS一键装机 — 科技感流式交互 UI 引擎 (lib/tui.sh)
# 风格: 赛博科技配色 / 高亮选中条 / 原地光标导航 / 零外部依赖
# 特性:
#   - 原地平滑交互 (不全屏清屏，不破坏终端历史)
#   - 键盘 ↑/↓/k/j 方向键平滑高亮选择，支持数字键秒选
#   - 优雅的 Yes/No 切换开关 (←/→/Tab/Space)
#   - 原生支持光标编辑、历史记录与 SSH 公钥安全粘贴
#==============================================================================

# --- 科技感主题色 (256-color) ---
TUI_CYAN='\033[38;5;51m'        # 主色: 亮青
TUI_VIOLET='\033[38;5;141m'     # 辅色: 亮紫
TUI_MAGENTA='\033[38;5;207m'    # 点缀: 品红
TUI_WHITE='\033[1;97m'          # 高亮白
TUI_DIM='\033[38;5;245m'        # 弱化灰
TUI_OK='\033[38;5;48m'          # 成功绿
TUI_WARN='\033[38;5;214m'       # 警告橙
TUI_ERR='\033[38;5;196m'        # 错误红
TUI_BAR='\033[48;5;236m'        # 选中条背景
TUI_RESET='\033[0m'

# tui_header: 科技感标题栏 (青紫双色边线 + 菱形标记)
tui_header() {
    local title="$1"
    local subtitle="${2:-}"
    echo ""
    echo -e "  ${TUI_CYAN}╭──────────────────────────────────────────────${TUI_RESET}"
    echo -e "  ${TUI_CYAN}│${TUI_RESET} ${TUI_MAGENTA}◆${TUI_RESET} ${TUI_WHITE}${title}${TUI_RESET}"
    if [ -n "$subtitle" ]; then
        echo -e "  ${TUI_CYAN}│${TUI_RESET} ${TUI_DIM}${subtitle}${TUI_RESET}"
    fi
    echo -e "  ${TUI_VIOLET}╰──────────────────────────────────────────────${TUI_RESET}"
}

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
    # EOF (stdin closed) must surface as a sentinel so callers can cancel
    IFS= read -rsn1 char || { printf 'EOF'; return 0; }

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
        echo -e "\n  ${TUI_CYAN}◆${TUI_RESET} ${TUI_WHITE}${title}${TUI_RESET}"
        [ -n "$prompt" ] && echo -e "    ${TUI_DIM}${prompt}${TUI_RESET}"
        local idx=1
        for opt in "${options[@]}"; do
            if [ "$idx" -eq "$default_idx" ]; then
                echo -e "  ${TUI_CYAN}${idx})${TUI_RESET} ${TUI_BAR} ${TUI_WHITE}${opt} ${TUI_RESET} ${TUI_DIM}[默认]${TUI_RESET}"
            else
                echo -e "  ${TUI_DIM}${idx})${TUI_RESET} ${opt}"
            fi
            idx=$((idx + 1))
        done
        echo -e "  ${TUI_VIOLET}b)${TUI_RESET} ${TUI_DIM}返回上一步${TUI_RESET}"
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
    tui_header "${title}" "${prompt}"

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
                echo -e "    ${TUI_CYAN}▸${TUI_RESET} ${TUI_BAR} ${TUI_WHITE}$((i + 1)). ${opt} ${TUI_RESET} $([ "$((i + 1))" -eq "$default_idx" ] && echo -e "${TUI_DIM}[默认]${TUI_RESET}")"
            else
                echo -e "      ${TUI_DIM}$((i + 1)). ${opt}${TUI_RESET}"
            fi
        done

        printf '\e[2K'
        echo -e "      ${TUI_VIOLET}b.${TUI_RESET} ${TUI_DIM}返回上一步${TUI_RESET}"
        printf '\e[2K'
        echo -e "    ${TUI_CYAN}[↑/↓]${TUI_RESET} ${TUI_DIM}移动${TUI_RESET}  ${TUI_VIOLET}[Enter]${TUI_RESET} ${TUI_DIM}确认${TUI_RESET}  ${TUI_MAGENTA}[1-${num_options}]${TUI_RESET} ${TUI_DIM}秒选${TUI_RESET}  ${TUI_WARN}[b/Esc]${TUI_RESET} ${TUI_DIM}返回${TUI_RESET}"

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
                echo -e "    ${TUI_OK}✔${TUI_RESET} ${TUI_DIM}已选择:${TUI_RESET} ${TUI_WHITE}${options[$selected_idx]}${TUI_RESET}\n"
                return 0
                ;;
            ESC|BACK|QUIT|EOF)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    ${TUI_DIM}已取消${TUI_RESET}\n"
                return 2
                ;;
            [1-9])
                local direct_idx=$((key - 1))
                if [ "$direct_idx" -lt "$num_options" ]; then
                    selected_idx="$direct_idx"
                    tui_show_cursor
                    stty echo icanon 2>/dev/null || true
                    printf -v "$__var" '%s' "${options[$selected_idx]}"
                    echo -e "    ${TUI_OK}✔${TUI_RESET} ${TUI_DIM}已选择:${TUI_RESET} ${TUI_WHITE}${options[$selected_idx]}${TUI_RESET}\n"
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
        if [ "${NON_INTERACTIVE:-false}" = "true" ] || [ "${AUTO_YES:-false}" = "true" ]; then
            [ "$default_idx" -eq 0 ] && return 0 || return 1
        fi
        echo -e "\n  ${TUI_CYAN}◆${TUI_RESET} ${TUI_WHITE}${title}${TUI_RESET}"
        [ -n "$prompt" ] && echo -e "    ${TUI_DIM}${prompt}${TUI_RESET}"
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
    tui_header "${title}" "$([ "$prompt" != "$title" ] && echo "$prompt")"

    local first_draw=true
    local render_lines=2

    while true; do
        if [ "$first_draw" = false ]; then
            printf "\e[%dA" "$render_lines"
        fi
        first_draw=false

        printf '\e[2K'
        if [ "$selected" -eq 0 ]; then
            echo -e "    ${TUI_OK}▸${TUI_RESET} ${TUI_BAR} ${TUI_WHITE} ● 1. 是 / Yes ${TUI_RESET}   ${TUI_DIM}[ ○ 2. 否 / No ]${TUI_RESET}"
        else
            echo -e "    ${TUI_DIM}[ ○ 1. 是 / Yes ]${TUI_RESET}   ${TUI_WARN}▸${TUI_RESET} ${TUI_BAR} ${TUI_WHITE} ● 2. 否 / No ${TUI_RESET}"
        fi

        printf '\e[2K'
        echo -e "    ${TUI_CYAN}[←/→/Tab]${TUI_RESET} ${TUI_DIM}切换${TUI_RESET}  ${TUI_VIOLET}[Enter]${TUI_RESET} ${TUI_DIM}确认${TUI_RESET}  ${TUI_MAGENTA}[y/n]${TUI_RESET} ${TUI_DIM}直选${TUI_RESET}  ${TUI_WARN}[b/Esc]${TUI_RESET} ${TUI_DIM}返回${TUI_RESET}"

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
                    echo -e "    ${TUI_OK}✔${TUI_RESET} ${TUI_WHITE}是 (Yes)${TUI_RESET}\n"
                    return 0
                else
                    echo -e "    ${TUI_WARN}✖${TUI_RESET} ${TUI_DIM}否 (No)${TUI_RESET}\n"
                    return 1
                fi
                ;;
            ESC|BACK|QUIT|EOF)
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    ${TUI_DIM}已取消${TUI_RESET}\n"
                return 2
                ;;
            1|[yY])
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    ${TUI_OK}✔${TUI_RESET} ${TUI_WHITE}是 (Yes)${TUI_RESET}\n"
                return 0
                ;;
            2|[nN])
                tui_show_cursor
                stty echo icanon 2>/dev/null || true
                echo -e "    ${TUI_WARN}✖${TUI_RESET} ${TUI_DIM}否 (No)${TUI_RESET}\n"
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
    tui_header "${title}" "${subtitle}"

    local answer=""
    local prompt_label="    ${TUI_CYAN}▸${TUI_RESET} ${TUI_WHITE}${prompt}${TUI_RESET}"
    if [ -n "$default" ]; then
        prompt_label+=" ${TUI_VIOLET}[默认: ${default}]${TUI_RESET}"
    fi
    prompt_label+=" ${TUI_DIM}(b 返回)${TUI_RESET} ${TUI_CYAN}›${TUI_RESET} "

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
    echo -e "    ${TUI_OK}✔${TUI_RESET} ${TUI_DIM}已设置:${TUI_RESET} ${TUI_WHITE}$([ "$is_password" = "true" ] && echo "******" || echo "$answer")${TUI_RESET}\n"
    return 0
}
