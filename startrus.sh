#!/usr/bin/env bash

# Улучшенный скрипт запуска CS2 Modded Server
# Использование: cd / && curl -s -H "Cache-Control: no-cache" -o "start.sh" "https://raw.githubusercontent.com/kus/cs2-modded-server/master/start.sh" && chmod +x start.sh && bash start.sh

set -euo pipefail  # Строгий режим выполнения

# === ЦВЕТА ДЛЯ ВЫВОДА ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# === ФУНКЦИИ ЛОГИРОВАНИЯ ===
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# === ФУНКЦИЯ ПРОВЕРКИ ОШИБОК ===
check_error() {
    if [ "$?" -ne "0" ]; then
        log_error "$1"
        exit 1
    fi
}

# === ПОЛУЧЕНИЕ МЕТАДАННЫХ (GCP/METADATA) ===
METADATA_URL="${METADATA_URL:-http://metadata.google.internal/computeMetadata/v1/instance/attributes}"

get_metadata() {
    if [ -z "$1" ]; then
        echo ""
        return
    fi
    
    local result=""
    if command -v curl >/dev/null 2>&1; then
        result=$(curl -s --connect-timeout 3 --max-time 5 "$METADATA_URL/$1?alt=text" -H "Metadata-Flavor: Google" 2>/dev/null || echo "")
        
        # Проверка что это не HTML ошибка
        if [[ $result == *"<!DOCTYPE html>"* ]] || [[ $result == *"<html>"* ]]; then
            result=""
        fi
    fi
    
    echo "$result"
}

# === ЗАГРУЗКА ПЕРЕМЕННЫХ ОКРУЖЕНИЯ ===
load_environment_variables() {
    log_step "Загрузка переменных окружения..."
    
    # Попытка получить метаданные (для GCP)
    local meta_rcon_password=$(get_metadata RCON_PASSWORD)
    local meta_api_key=$(get_metadata API_KEY)
    local meta_steam_account=$(get_metadata STEAM_ACCOUNT)
    local meta_mod_branch=$(get_metadata MOD_BRANCH)
    local meta_port=$(get_metadata PORT)
    local meta_tickrate=$(get_metadata TICKRATE)
    local meta_maxplayers=$(get_metadata MAXPLAYERS)
    local meta_lan=$(get_metadata LAN)
    local meta_exec=$(get_metadata EXEC)
    local meta_server_password=$(get_metadata SERVER_PASSWORD)
    local meta_duck_domain=$(get_metadata DUCK_DOMAIN)
    local meta_duck_token=$(get_metadata DUCK_TOKEN)
    local meta_custom_folder=$(get_metadata CUSTOM_FOLDER)
    
    # Установка переменных с приоритетом: env переменные > метаданные > значения по умолчанию
    export RCON_PASSWORD="${RCON_PASSWORD:-${meta_rcon_password:-changeme}}"
    export API_KEY="${API_KEY:-${meta_api_key:-changeme}}"
    export STEAM_ACCOUNT="${STEAM_ACCOUNT:-${meta_steam_account}}"
    export MOD_BRANCH="${MOD_BRANCH:-${meta_mod_branch:-master}}"
    export SERVER_PASSWORD="${SERVER_PASSWORD:-${meta_server_password}}"
    export PORT="${PORT:-${meta_port:-27015}}"
    export TICKRATE="${TICKRATE:-${meta_tickrate:-128}}"
    export MAXPLAYERS="${MAXPLAYERS:-${meta_maxplayers:-32}}"
    export LAN="${LAN:-${meta_lan:-0}}"
    export EXEC="${EXEC:-${meta_exec:-on_boot.cfg}}"
    export DUCK_DOMAIN="${DUCK_DOMAIN:-${meta_duck_domain}}"
    export DUCK_TOKEN="${DUCK_TOKEN:-${meta_duck_token}}"
    export CUSTOM_FOLDER="${CUSTOM_FOLDER:-${meta_custom_folder:-custom_files}}"
    
    # Дополнительные переменные
    export user="steam"
    export BRANCH="${MOD_BRANCH}"
    export CUSTOM_FILES="${CUSTOM_FOLDER}"
    
    log_info "Переменные окружения загружены успешно"
}

# === ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ ===
detect_architecture() {
    if [ -z "${BITS:-}" ]; then
        local architecture=$(uname -m)
        case $architecture in
            *64*) export BITS=64 ;;
            *i386*|*i686*) export BITS=32 ;;
            *) 
                log_error "Неизвестная архитектура: $architecture"
                exit 1
                ;;
        esac
    fi
    log_debug "Архитектура: $BITS бит"
}

# === НАСТРОЙКА IP ===
setup_ip_binding() {
    if [[ -z "${IP:-}" ]]; then
        # По умолчанию привязываем к всем интерфейсам для внешних подключений
        export IP="0.0.0.0"
        IP_ARGS="-ip ${IP}"
        log_info "IP привязка: все интерфейсы (0.0.0.0)"
    else
        IP_ARGS="-ip ${IP}"
        log_info "IP привязка: $IP"
    fi
}

# === ОПРЕДЕЛЕНИЕ ОС ===
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_OS=$NAME
        DISTRO_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        DISTRO_OS=$(lsb_release -si)
        DISTRO_VERSION=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO_OS=$DISTRIB_ID
        DISTRO_VERSION=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        DISTRO_OS=Debian
        DISTRO_VERSION=$(cat /etc/debian_version)
    else
        DISTRO_OS=$(uname -s)
        DISTRO_VERSION=$(uname -r)
    fi
    
    log_info "Операционная система: $DISTRO_OS $DISTRO_VERSION"
}

# === ПРОВЕРКА ТРЕБОВАНИЙ ===
check_requirements() {
    log_step "Проверка требований системы..."
    
    # Проверка root прав
    if [ "$EUID" -ne 0 ]; then
        log_error "Требуются права root. Запустите: sudo su"
        exit 1
    fi

    # Проверка apt-get
    if ! command -v apt-get &> /dev/null; then
        log_error "Дистрибутив не поддерживается (apt-get недоступен). $DISTRO_OS: $DISTRO_VERSION"
        exit 1
    fi

    # Проверка свободного места
    local free_space=$(df / --output=avail -BG | tail -n 1 | tr -d 'G')
    log_info "Свободного места: ${free_space}GB"
    
    if [ "$free_space" -lt 60 ]; then
        log_warn "Мало свободного места! Рекомендуется минимум 60GB"
    fi
    
    log_info "Проверка требований завершена"
}

# === ОБНОВЛЕНИЕ СИСТЕМЫ ===
update_system() {
    log_step "Обновление операционной системы..."
    
    apt-get update -y -q && apt-get upgrade -y -q
    check_error "Ошибка обновления системы"
    
    dpkg --configure -a
    
    log_info "Система обновлена успешно"
}

# === УСТАНОВКА ПАКЕТОВ ===
install_packages() {
    log_step "Установка необходимых пакетов..."
    
    log_info "Добавление архитектуры i386..."
    dpkg --add-architecture i386
    check_error "Не удалось добавить архитектуру i386"

    apt-get update -y -q

    # Универсальный список пакетов с поддержкой современных версий
    local base_packages="dnsutils curl wget screen nano file tar bzip2 gzip unzip hostname bsdmainutils python3 util-linux xz-utils ca-certificates binutils bc jq tmux lib32stdc++6 libsdl2-2.0-0:i386 distro-info steamcmd net-tools execstack prelink"
    
    # Специфичные пакеты для разных версий
    local packages="$base_packages"
    
    if [[ "${DISTRO_OS}" == "Ubuntu" ]]; then
        case "${DISTRO_VERSION}" in
            "16.04"|"18.04"|"20.04")
                packages="${packages//lib32gcc-s1/lib32gcc1} netcat"
                ;;
            "22.04")
                packages="$packages lib32gcc-s1 netcat-traditional"
                ;;
            *)
                packages="$packages lib32gcc-s1 netcat-traditional"
                log_info "$DISTRO_OS $DISTRO_VERSION не полностью поддерживается, используется конфигурация Ubuntu 22.04+"
                ;;
        esac
    elif [[ $DISTRO_OS == Debian* ]]; then
        if [ "${DISTRO_VERSION}" == "10" ]; then
            packages="${packages//lib32gcc-s1/lib32gcc1} netcat-traditional"
        else
            packages="$packages lib32gcc-s1 netcat-traditional"
        fi
    fi

    log_info "Установка пакетов для $DISTRO_OS $DISTRO_VERSION..."
    apt-get install -y -q $packages
    check_error "Ошибка установки пакетов"
    
    log_info "Пакеты установлены успешно"
}

# === ПОЛУЧЕНИЕ ПУБЛИЧНОГО IP ===
get_public_ip() {
    log_step "Определение публичного IP адреса..."
    
    # Попробуем несколько способов получения IP
    PUBLIC_IP=$(curl -4 --connect-timeout 5 --max-time 10 -s ifconfig.me 2>/dev/null || \
                curl -4 --connect-timeout 5 --max-time 10 -s checkip.amazonaws.com 2>/dev/null || \
                dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || \
                echo "")
    
    if [ -z "$PUBLIC_IP" ]; then
        log_error "Не удалось получить публичный IP адрес"
        exit 1
    fi
    
    log_info "Публичный IP: $PUBLIC_IP"
}

# === ОБНОВЛЕНИЕ DUCKDNS ===
update_duckdns() {
    if [ -n "${DUCK_TOKEN:-}" ] && [ -n "${DUCK_DOMAIN:-}" ]; then
        log_step "Обновление DuckDNS домена: $DUCK_DOMAIN"
        echo url="http://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=$PUBLIC_IP" | curl -k -o /duck.log -K - 2>/dev/null || true
        log_info "DuckDNS обновлен"
    fi
}

# === СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ===
create_user() {
    log_step "Проверка пользователя $user..."
    
    if ! getent passwd ${user} >/dev/null 2>&1; then
        log_info "Создание пользователя $user..."
        addgroup ${user} && \
        adduser --system --home /home/${user} --shell /bin/false --ingroup ${user} ${user} && \
        usermod -a -G tty ${user} && \
        mkdir -m 777 /home/${user}/cs2 && \
        chown -R ${user}:${user} /home/${user}/cs2
        check_error "Не удалось создать пользователя $user"
        log_info "Пользователь $user создан"
    else
        log_info "Пользователь $user уже существует"
    fi
}

# === УСТАНОВКА STEAMCMD ===
setup_steamcmd() {
    log_step "Настройка SteamCMD..."
    
    if [ ! -d "/steamcmd" ]; then
        log_info "Установка SteamCMD..."
        mkdir /steamcmd && cd /steamcmd
        wget -q https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
        tar -xzf steamcmd_linux.tar.gz
        rm steamcmd_linux.tar.gz
        
        # Создание символических ссылок
        mkdir -p /root/.steam/sdk{32,64}/
        ln -sf /steamcmd/linux32/steamclient.so /root/.steam/sdk32/
        ln -sf /steamcmd/linux64/steamclient.so /root/.steam/sdk64/
        log_info "SteamCMD установлен"
    else
        log_info "SteamCMD уже установлен"
    fi

    chown -R ${user}:${user} /steamcmd
}

# === СКАЧИВАНИЕ ВСПОМОГАТЕЛЬНЫХ СКРИПТОВ ===
download_scripts() {
    log_step "Загрузка вспомогательных скриптов..."
    curl -s -H "Cache-Control: no-cache" -o "stop.sh" "https://raw.githubusercontent.com/kus/cs2-modded-server/${BRANCH}/stop.sh" && chmod +x stop.sh
    log_info "Скрипты загружены"
}

# === ОБНОВЛЕНИЕ CS2 ===
update_cs2() {
    log_step "Обновление CS2..."
    
    sudo -u $user /steamcmd/steamcmd.sh \
        +api_logging 1 1 \
        +@sSteamCmdForcePlatformType linux \
        +@sSteamCmdForcePlatformBitness $BITS \
        +force_install_dir /home/${user}/cs2 \
        +login anonymous \
        +app_update 730 validate \
        +quit
    check_error "Ошибка обновления CS2"

    # Дополнительные символические ссылки
    mkdir -p /home/${user}/.steam/sdk{32,64}/
    ln -sf /steamcmd/linux32/steamclient.so /home/${user}/.steam/sdk32/
    ln -sf /steamcmd/linux64/steamclient.so /home/${user}/.steam/sdk64/

    # Исправление для Ubuntu 22.04+
    if [[ "${DISTRO_OS}" == "Ubuntu" ]] && [[ "${DISTRO_VERSION}" > "22" ]]; then
        log_info "Применение исправления для Ubuntu ${DISTRO_VERSION}"
        rm -f /home/${user}/cs2/bin/libgcc_s.so.1
    fi

    chown -R ${user}:${user} /home/${user}/cs2
    log_info "CS2 обновлен успешно"
}

# === ПАТЧ GAMEINFO.GI ===
patch_gameinfo() {
    log_step "Патчинг gameinfo.gi для Metamod..."
    
    cd /home/${user}/cs2
    
    local file="game/csgo/gameinfo.gi"
    local pattern="Game_LowViolence[[:space:]]*csgo_lv // Perfect World content override"
    local line_to_add="\t\t\tGame\tcsgo/addons/metamod"
    local regex_to_check="^[[:space:]]*Game[[:space:]]*csgo/addons/metamod"

    if grep -qE "$regex_to_check" "$file"; then
        log_info "$file уже пропатчен для Metamod"
    else
        awk -v pattern="$pattern" -v lineToAdd="$line_to_add" '{
            print $0;
            if ($0 ~ pattern) {
                print lineToAdd;
            }
        }' "$file" > tmp_file && mv tmp_file "$file"
        log_info "$file успешно пропатчен для Metamod"
    fi
}

# === ИСПРАВЛЕНИЕ COUNTERSTRIKESHARP ===
fix_counterstrikesharp() {
    log_step "Исправление CounterStrikeSharp..."
    
    local css_path="/home/steam/cs2/game/csgo/addons/counterstrikesharp/bin/linuxsteamrt64"
    
    if [ -f "$css_path/counterstrikesharp.so" ]; then
        # Попробуем различные способы исправления
        log_info "Применение исправлений для CounterStrikeSharp..."
        
        # Способ 1: execstack
        if command -v execstack >/dev/null 2>&1; then
            execstack -s "$css_path/counterstrikesharp.so" 2>/dev/null || true
            log_debug "Применен execstack"
        fi
        
        # Способ 2: prelink (если доступен)
        if command -v prelink >/dev/null 2>&1; then
            prelink --no-exec-shield "$css_path/counterstrikesharp.so" 2>/dev/null || true
            log_debug "Применен prelink"
        fi
        
        # Способ 3: системные настройки
        echo 0 > /proc/sys/vm/mmap_min_addr 2>/dev/null || true
        
        # Способ 4: права на файл
        chmod 755 "$css_path/counterstrikesharp.so"
        
        log_info "Исправления CounterStrikeSharp применены"
    else
        log_warn "CounterStrikeSharp не найден в $css_path"
    fi
}

# === НАСТРОЙКА ФАЙРВОЛА ===
setup_firewall() {
    log_step "Настройка файрвола..."
    
    # UFW правила
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
        ufw allow ${PORT}/udp >/dev/null 2>&1 || true
        ufw allow 27020/udp >/dev/null 2>&1 || true
        log_debug "UFW правила добавлены"
    fi
    
    # iptables правила
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport 27020 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 27020 -j ACCEPT 2>/dev/null || true
        log_debug "iptables правила добавлены"
    fi
    
    log_info "Файрвол настроен"
}

# === ВАЛИДАЦИЯ КОНФИГУРАЦИИ ===
validate_configuration() {
    log_step "Валидация конфигурации..."
    
    local warnings=0
    
    if [ "$API_KEY" == "changeme" ]; then
        log_warn "API_KEY не установлен! Workshop карты не будут работать"
        ((warnings++))
    fi
    
    if [ -z "$STEAM_ACCOUNT" ]; then
        log_warn "STEAM_ACCOUNT не установлен! Сервер не будет виден в публичном списке"
        ((warnings++))
    fi
    
    if [ "$RCON_PASSWORD" == "changeme" ]; then
        log_warn "RCON_PASSWORD не изменен! Измените его для безопасности"
        ((warnings++))
    fi
    
    # Проверка портов
    if ss -tulpn 2>/dev/null | grep -q ":$PORT "; then
        log_warn "Порт $PORT уже используется! Сервер может не запуститься"
        ((warnings++))
    fi
    
    if [ $warnings -eq 0 ]; then
        log_info "Конфигурация валидна"
    else
        log_warn "Найдено $warnings предупреждений в конфигурации"
    fi
}

# === ПОКАЗ ИНФОРМАЦИИ О СЕРВЕРЕ ===
show_server_info() {
    echo ""
    log_info "========================================="
    log_info "         ИНФОРМАЦИЯ О СЕРВЕРЕ"
    log_info "========================================="
    log_info "IP адрес: $PUBLIC_IP"
    log_info "Порт: $PORT"
    log_info "Подключение: connect $PUBLIC_IP:$PORT"
    log_info "RCON пароль: $RCON_PASSWORD"
    log_info "Пароль сервера: ${SERVER_PASSWORD:-не установлен}"
    log_info "Тикрейт: $TICKRATE"
    log_info "Максимум игроков: $MAXPLAYERS"
    log_info "LAN режим: $LAN"
    log_info "IP привязка: $IP"
    log_info "========================================="
    log_info "Управление сервером:"
    log_info "  Остановка: ./stop.sh"
    log_info "  Перезапуск: ./start.sh"
    log_info "  Логи: tail -f logs/console.log"
    log_info "========================================="
    echo ""
}

# === ЗАПУСК СЕРВЕРА ===
start_server() {
    cd /home/${user}/cs2
    
    log_step "Запуск CS2 сервера..."
    
    # Показ команды запуска для отладки
    if [[ "${DEBUG:-}" == "1" ]]; then
        log_debug "Команда запуска:"
        echo "./game/bin/linuxsteamrt64/cs2 -dedicated -console -usercon -autoupdate -tickrate $TICKRATE $IP_ARGS -port $PORT +map de_dust2 +sv_visiblemaxplayers $MAXPLAYERS -authkey $API_KEY +sv_setsteamaccount $STEAM_ACCOUNT +game_type 0 +game_mode 0 +mapgroup mg_active +sv_lan $LAN +sv_password '$SERVER_PASSWORD' +rcon_password '$RCON_PASSWORD' +exec $EXEC"
    fi
    
    # Запуск сервера
    sudo -u $user ./game/bin/linuxsteamrt64/cs2 \
        -dedicated \
        -console \
        -usercon \
        -autoupdate \
        -tickrate $TICKRATE \
        $IP_ARGS \
        -port $PORT \
        +map de_dust2 \
        +sv_visiblemaxplayers $MAXPLAYERS \
        -authkey $API_KEY \
        +sv_setsteamaccount $STEAM_ACCOUNT \
        +game_type 0 \
        +game_mode 0 \
        +mapgroup mg_active \
        +sv_lan $LAN \
        +sv_password "$SERVER_PASSWORD" \
        +rcon_password "$RCON_PASSWORD" \
        +exec $EXEC
}

# === ФУНКЦИЯ ПРОВЕРКИ ПРОЦЕССОВ ===
check_existing_processes() {
    log_step "Проверка существующих процессов CS2..."
    
    if pgrep -f "cs2.*dedicated" >/dev/null; then
        log_warn "Обнаружен запущенный процесс CS2"
        log_info "Для корректной работы рекомендуется остановить предыдущий сервер:"
        log_info "  pkill -f cs2"
        log_info "  или используйте ./stop.sh"
        
        read -p "Остановить существующие процессы? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            pkill -f cs2 || true
            sleep 3
            log_info "Процессы остановлены"
        fi
    fi
}

# === ОСНОВНАЯ ФУНКЦИЯ ===
main() {
    echo ""
    log_info "=== Запуск CS2 Modded Server ==="
    echo ""
    
    # Переходим в корневую директорию
    cd /
    
    # Выполняем все этапы
    load_environment_variables
    detect_architecture
    setup_ip_binding
    detect_os
    check_requirements
    check_existing_processes
    update_system
    install_packages
    download_scripts
    get_public_ip
    update_duckdns
    create_user
    setup_steamcmd
    update_cs2
    patch_gameinfo
    fix_counterstrikesharp
    setup_firewall
    validate_configuration
    
    show_server_info
    start_server
}

# === ОБРАБОТКА СИГНАЛОВ ===
trap 'log_error "Скрипт прерван пользователем"; exit 1' INT TERM

# === ЗАПУСК ===
main "$@"
