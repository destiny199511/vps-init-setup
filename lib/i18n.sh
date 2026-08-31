#!/bin/bash
#==============================================================================
# VPS Setup — 国际化/多语言支持模块 (lib/i18n.sh)
# 支持语言: zh_CN (中文默认), en_US (英文), ja_JP (日文), es_ES (西班牙文)
#==============================================================================

# 当前界面语言 (优先级: VPS_SETUP_LANG > LANG 环境变量 > 默认 zh_CN)
detect_ui_language() {
    if [ -n "${VPS_SETUP_LANG:-}" ]; then
        case "$VPS_SETUP_LANG" in
            en*|EN*) UI_LANG="en" ;;
            ja*|JA*) UI_LANG="ja" ;;
            es*|ES*) UI_LANG="es" ;;
            zh*|ZH*|*) UI_LANG="zh" ;;
        esac
        return 0
    fi

    local sys_lang="${LANG:-zh_CN.UTF-8}"
    case "$sys_lang" in
        en_*|EN_*) UI_LANG="en" ;;
        ja_*|JA_*) UI_LANG="ja" ;;
        es_*|ES_*) UI_LANG="es" ;;
        zh_*|ZH_*|*) UI_LANG="zh" ;;
    esac
}

UI_LANG="zh"
detect_ui_language

declare -g -A I18N_EN
declare -g -A I18N_JA
declare -g -A I18N_ES

# 加载语言包文件
load_locale_data() {
    local script_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local loc_dir="${script_root}/locales"

    if [ -f "${loc_dir}/en.sh" ]; then
        source "${loc_dir}/en.sh"
    fi
    if [ -f "${loc_dir}/ja.sh" ]; then
        source "${loc_dir}/ja.sh"
    fi
    if [ -f "${loc_dir}/es.sh" ]; then
        source "${loc_dir}/es.sh"
    fi
}

# 核心翻译函数 t "中文源文本"
t() {
    local text="$1"
    case "${UI_LANG:-zh}" in
        en)
            if [ -n "${I18N_EN["$text"]+x}" ]; then
                printf '%s' "${I18N_EN["$text"]}"
            else
                printf '%s' "$text"
            fi
            ;;
        ja)
            if [ -n "${I18N_JA["$text"]+x}" ]; then
                printf '%s' "${I18N_JA["$text"]}"
            else
                printf '%s' "$text"
            fi
            ;;
        es)
            if [ -n "${I18N_ES["$text"]+x}" ]; then
                printf '%s' "${I18N_ES["$text"]}"
            else
                printf '%s' "$text"
            fi
            ;;
        zh|*)
            printf '%s' "$text"
            ;;
    esac
}

# 设置界面语言
set_ui_language() {
    local target_lang="$1"
    case "$target_lang" in
        en|en_US|en_US.UTF-8|english|English) UI_LANG="en" ;;
        ja|ja_JP|ja_JP.UTF-8|japanese|Japanese|日本語) UI_LANG="ja" ;;
        es|es_ES|es_ES.UTF-8|spanish|Spanish|Español) UI_LANG="es" ;;
        zh|zh_CN|zh_CN.UTF-8|chinese|Chinese|中文) UI_LANG="zh" ;;
        *) UI_LANG="zh" ;;
    esac
    export VPS_SETUP_LANG="$UI_LANG"
}

# 自动在加载时读取字典
_I18N_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
load_locale_data "${_I18N_LIB_DIR}/.."
