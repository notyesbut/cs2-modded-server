#!/usr/bin/env bash

# Улучшенный скрипт установки CS2 Modded Server
# Использование: cd / && curl -s -H "Cache-Control: no-cache" -o "install.sh" "https://raw.githubusercontent.com/kus/cs2-modded-server/master/install.sh" && chmod +x install.sh && bash install.sh

set -euo pipefail  # Строгий режим выполнения

# === ЦВЕТА ДЛЯ ВЫВОДА ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# === ПРОВЕРКА ОШИБОК ===
check_error() {
    if [ "$?" -ne "0" ]; then
        log_error "$1"
        exit 1
    fi
}

# === ПЕРЕМЕННЫЕ ===
user="steam"
BRANCH="${MOD_BRANCH:-master}"
CUSTOM_FILES="${CUSTOM_FOLDER:-custom_files}"

# Значения по умолчанию для переменных окружения
export RCON_PASSWORD="${RCON_PASSWORD:-changeme}"
export API_KEY="${API_KEY:-changeme}"
export STEAM_ACCOUNT="${STEAM_ACCOUNT:-}"
export SERVER_PASSWORD="${SERVER_PASSWORD:-}"
export PORT="${PORT:-27015}"
export TICKRATE="${TICKRATE:-128}"
export MAXPLAYERS="${MAXPLAYERS:-32}"
export LAN="${LAN:-0}"
export EXEC="${EXEC:-on_boot.cfg}"

# === ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ ===
if [ -z "${BITS:-}" ]; then
    architecture=$(uname -m)
    case $architecture in
        *64*) export BITS=64 ;;
        *i386*|*i686*) export BITS=32 ;;
        *) 
            log_error "Неизвестная архитектура: $architecture"
            exit 1
            ;;
    esac
fi

# === НАСТРОЙКА IP ===
if [[ -z "${IP:-}" ]]; then
    IP_ARGS=""
    log_info "IP не задан, сервер будет слушать на всех интерфейсах (0.0.0.0)"
else
    IP_ARGS="-ip ${IP}"
    log_info "Сервер будет привязан к IP: $IP"
fi

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
}

# === ПРОВЕРКА ТРЕБОВАНИЙ ===
check_requirements() {
    # Проверка root прав
    if [ "$EUID" -ne 0 ]; then
        log_error "Пожалуйста, запустите скрипт от имени root (sudo su)"
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
        read -p "Продолжить? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# === УСТАНОВКА ПАКЕТОВ ===
install_packages() {
    log_info "Обновление системы..."
    apt-get update -y -q && apt-get upgrade -y -q
    check_error "Ошибка обновления системы"

    dpkg --configure -a

    log_info "Добавление архитектуры i386..."
    dpkg --add-architecture i386
    check_error "Не удалось добавить архитектуру i386"

    log_info "Установка необходимых пакетов для $DISTRO_OS: $DISTRO_VERSION..."
    apt-get update -y -q

    # Универсальный список пакетов для современных систем
    local packages="dnsutils curl wget screen nano file tar bzip2 gzip unzip hostname bsdmainutils python3 util-linux xz-utils ca-certificates binutils bc jq tmux netcat-traditional lib32stdc++6 libsdl2-2.0-0:i386 distro-info lib32gcc-s1 steamcmd net-tools execstack"

    # Особые случаи для старых версий
    if [[ "${DISTRO_OS}" == "Ubuntu" ]]; then
        case "${DISTRO_VERSION}" in
            "16.04"|"18.04"|"20.04")
                packages="${packages//lib32gcc-s1/lib32gcc1}"
                packages="${packages//netcat-traditional/netcat}"
                ;;
        esac
    elif [[ $DISTRO_OS == Debian* ]]; then
        if [ "${DISTRO_VERSION}" == "10" ]; then
            packages="${packages//lib32gcc-s1/lib32gcc1}"
        fi
    fi

    apt-get install -y -q $packages
    check_error "Ошибка установки пакетов"
}

# === ПОЛУЧЕНИЕ ПУБЛИЧНОГО IP ===
get_public_ip() {
    log_info "Получение публичного IP адреса..."
    PUBLIC_IP=$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || curl -s ifconfig.me 2>/dev/null || curl -s checkip.amazonaws.com 2>/dev/null)
    
    if [ -z "$PUBLIC_IP" ]; then
        log_error "Не удалось получить публичный IP адрес"
        exit 1
    fi
    
    log_info "Публичный IP: $PUBLIC_IP"
}

# === ОБНОВЛЕНИЕ DUCKDNS ===
update_duckdns() {
    if [ ! -z "${DUCK_TOKEN:-}" ] && [ ! -z "${DUCK_DOMAIN:-}" ]; then
        log_info "Обновление DuckDNS домена: $DUCK_DOMAIN"
        echo url="http://www.duckdns.org/update?domains=$DUCK_DOMAIN&token=$DUCK_TOKEN&ip=$PUBLIC_IP" | curl -k -o /duck.log -K -
    fi
}

# === СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ===
create_user() {
    log_info "Проверка пользователя $user..."
    
    if ! getent passwd ${user} >/dev/null 2>&1; then
        log_info "Создание пользователя $user..."
        addgroup ${user} && \
        adduser --system --home /home/${user} --shell /bin/false --ingroup ${user} ${user} && \
        usermod -a -G tty ${user} && \
        mkdir -m 777 /home/${user}/cs2 && \
        chown -R ${user}:${user} /home/${user}/cs2
        check_error "Не удалось создать пользователя $user"
    else
        log_info "Пользователь $user уже существует"
    fi
}

# === УСТАНОВКА STEAMCMD ===
install_steamcmd() {
    log_info "Проверка SteamCMD..."
    
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
    else
        log_info "SteamCMD уже установлен"
    fi

    chown -R ${user}:${user} /steamcmd
}

# === ЗАГРУЗКА CS2 ===
download_cs2() {
    log_info "Загрузка/обновление CS2..."
    
    sudo -u $user /steamcmd/steamcmd.sh \
        +api_logging 1 1 \
        +@sSteamCmdForcePlatformType linux \
        +@sSteamCmdForcePlatformBitness $BITS \
        +force_install_dir /home/${user}/cs2 \
        +login anonymous \
        +app_update 730 validate \
        +quit
    check_error "Ошибка загрузки CS2"

    # Дополнительные символические ссылки
    mkdir -p /home/${user}/.steam/sdk{32,64}/
    ln -sf /steamcmd/linux32/steamclient.so /home/${user}/.steam/sdk32/
    ln -sf /steamcmd/linux64/steamclient.so /home/${user}/.steam/sdk64/

    # Исправление для Ubuntu 22.04+
    if [[ "${DISTRO_OS}" == "Ubuntu" ]] && [[ "${DISTRO_VERSION}" > "22" ]]; then
        log_info "Применение исправления для Ubuntu ${DISTRO_VERSION}"
        rm -f /home/${user}/cs2/bin/libgcc_s.so.1
    fi
}

# === УСТАНОВКА МОДОВ ===
install_mods() {
    cd /home/${user}
    
    log_info "Очистка старых файлов модов..."
    rm -rf /home/${user}/cs2/game/csgo/addons
    rm -rf /home/${user}/cs2/game/csgo/cfg/settings

    log_info "Загрузка файлов модов (ветка: $BRANCH)..."
    wget --quiet https://github.com/kus/cs2-modded-server/archive/${BRANCH}.zip -O ${BRANCH}.zip
    check_error "Ошибка загрузки файлов модов"
    
    unzip -o -qq ${BRANCH}.zip
    check_error "Ошибка распаковки модов"

    log_info "Установка файлов модов..."
    # Удаление примера кастомных файлов и копирование нового
    rm -rf /home/${user}/cs2/custom_files_example/
    cp -R cs2-modded-server-${BRANCH}/custom_files_example/ /home/${user}/cs2/custom_files_example/
    
    # Копирование игровых файлов
    cp -R cs2-modded-server-${BRANCH}/game/csgo/ /home/${user}/cs2/game/
    
    # Копирование или создание кастомных файлов
    if [ ! -d "/home/${user}/cs2/custom_files/" ]; then
        cp -R cs2-modded-server-${BRANCH}/custom_files/ /home/${user}/cs2/custom_files/
    else
        cp -RT cs2-modded-server-${BRANCH}/custom_files/ /home/${user}/cs2/custom_files/
    fi

    log_info "Применение кастомных файлов из ${CUSTOM_FILES}..."
    if [ -d "/home/${user}/cs2/${CUSTOM_FILES}/" ]; then
        cp -RT /home/${user}/cs2/${CUSTOM_FILES}/ /home/${user}/cs2/game/csgo/
    fi

    # Исправление проблемы с CounterStrikeSharp
    log_info "Исправление проблемы с исполняемым стеком для CounterStrikeSharp..."
    if command -v execstack >/dev/null 2>&1; then
        execstack -s /home/${user}/cs2/game/csgo/addons/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so 2>/dev/null || log_warn "Не удалось установить флаг исполняемого стека"
    fi

    chown -R ${user}:${user} /home/${user}/cs2
    
    # Очистка
    rm -rf /home/${user}/cs2-modded-server-${BRANCH} /home/${user}/${BRANCH}.zip
}

# === ПАТЧ GAMEINFO.GI ===
patch_gameinfo() {
    cd /home/${user}/cs2
    
    local file="game/csgo/gameinfo.gi"
    local pattern="Game_LowViolence[[:space:]]*csgo_lv // Perfect World content override"
    local line_to_add="\t\t\tGame\tcsgo/addons/metamod"
    local regex_to_check="^[[:space:]]*Game[[:space:]]*csgo/addons/metamod"

    if grep -qE "$regex_to_check" "$file"; then
        log_info "$file уже пропатчен для Metamod"
    else
        log_info "Патчинг $file для Metamod..."
        awk -v pattern="$pattern" -v lineToAdd="$line_to_add" '{
            print $0;
            if ($0 ~ pattern) {
                print lineToAdd;
            }
        }' "$file" > tmp_file && mv tmp_file "$file"
        log_info "$file успешно пропатчен для Metamod"
    fi
}

# === НАСТРОЙКА ФАЙРВОЛА ===
setup_firewall() {
    log_info "Настройка файрвола..."
    
    # UFW правила
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
        ufw allow ${PORT}/udp >/dev/null 2>&1 || true
        ufw allow 27020/udp >/dev/null 2>&1 || true
        log_info "UFW правила добавлены"
    fi
    
    # iptables правила (на случай если UFW не работает)
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p udp --dport 27020 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 27020 -j ACCEPT 2>/dev/null || true
        log_info "iptables правила добавлены"
    fi
}

# === ВАЛИДАЦИЯ КОНФИГУРАЦИИ ===
validate_config() {
    log_info "Валидация конфигурации..."
    
    if [ "$API_KEY" == "changeme" ]; then
        log_warn "API_KEY не установлен! Workshop карты не будут работать"
    fi
    
    if [ -z "$STEAM_ACCOUNT" ]; then
        log_warn "STEAM_ACCOUNT не установлен! Сервер не будет виден в публичном списке"
    fi
    
    if [ "$RCON_PASSWORD" == "changeme" ]; then
        log_warn "RCON_PASSWORD не изменен! Измените его для безопасности"
    fi
}

# === ЗАГРУЗКА СКРИПТОВ ===
download_scripts() {
    log_info "Загрузка вспомогательных скриптов..."
    curl -s -H "Cache-Control: no-cache" -o "stop.sh" "https://raw.githubusercontent.com/kus/cs2-modded-server/${BRANCH}/stop.sh" && chmod +x stop.sh
    curl -s -H "Cache-Control: no-cache" -o "start.sh" "https://raw.githubusercontent.com/kus/cs2-modded-server/${BRANCH}/start.sh" && chmod +x start.sh
}

# === ЗАПУСК СЕРВЕРА ===
start_server() {
    cd /home/${user}/cs2
    
    log_info "Запуск сервера на $PUBLIC_IP:$PORT"
    log_info "Параметры запуска:"
    log_info "  - Тикрейт: $TICKRATE"
    log_info "  - Максимум игроков: $MAXPLAYERS"
    log_info "  - LAN режим: $LAN"
    log_info "  - IP привязка: ${IP:-все интерфейсы}"
    
    # Вывод команды запуска для отладки
    log_debug "Команда запуска:"
    log_debug "./game/bin/linuxsteamrt64/cs2 -dedicated -console -usercon -autoupdate -tickrate $TICKRATE $IP_ARGS -port $PORT +map de_dust2 +sv_visiblemaxplayers $MAXPLAYERS -authkey $API_KEY +sv_setsteamaccount $STEAM_ACCOUNT +game_type 0 +game_mode 0 +mapgroup mg_active +sv_lan $LAN +sv_password '$SERVER_PASSWORD' +rcon_password '$RCON_PASSWORD' +exec $EXEC"
    
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

# === ФУНКЦИЯ ПОКАЗА ИНФОРМАЦИИ ===
show_server_info() {
    log_info "========================================="
    log_info "         ИНФОРМАЦИЯ О СЕРВЕРЕ"
    log_info "========================================="
    log_info "IP адрес: $PUBLIC_IP"
    log_info "Порт: $PORT"
    log_info "Подключение: connect $PUBLIC_IP:$PORT"
    log_info "RCON пароль: $RCON_PASSWORD"
    log_info "Пароль сервера: ${SERVER_PASSWORD:-не установлен}"
    log_info "========================================="
    log_info "Управление сервером:"
    log_info "  Остановка: cd /home/$user/cs2 && ./stop.sh"
    log_info "  Перезапуск: cd /home/$user/cs2 && ./install.sh"
    log_info "  Логи: cd /home/$user/cs2 && tail -f logs/console.log"
    log_info "========================================="
}

# === ОСНОВНАЯ ФУНКЦИЯ ===
main() {
    log_info "Запуск установки CS2 Modded Server..."
    
    detect_os
    log_info "Операционная система: $DISTRO_OS $DISTRO_VERSION"
    
    check_requirements
    get_public_ip
    update_duckdns
    install_packages
    create_user
    install_steamcmd
    download_cs2
    install_mods
    patch_gameinfo
    setup_firewall
    download_scripts
    validate_config
    
    show_server_info
    start_server
}

# === ОБРАБОТКА СИГНАЛОВ ===
trap 'log_error "Установка прервана пользователем"; exit 1' INT TERM

# === ЗАПУСК ===
main "$@"
