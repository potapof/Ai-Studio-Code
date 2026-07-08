#!/usr/bin/env bash
# ============================================================================
# 03-setup-shared-folder.sh
# ============================================================================
# Настройка shared folder и Syncthing на Linux Mint.
# - Создание ~/host_shared
# - Монтирование vboxsf
# - /etc/fstab с nofail
# - Syncthing systemd user service
# - Папка ~/syncthing-host
# - Вывод Device ID
#
# Usage:
#   ./03-setup-shared-folder.sh
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }

CURRENT_USER="$(whoami)"
if [ "$CURRENT_USER" = "root" ]; then
    err "Скрипт не предназначен для запуска от root. Запустите от имени обычного пользователя."
    exit 1
fi

HOST_SHARED="$HOME/host_shared"
SYNCTHING_HOST="$HOME/syncthing-host"

# ---------------------------------------------------------------------------
# 1. Создание ~/host_shared
# ---------------------------------------------------------------------------
info "Создание папки $HOST_SHARED..."
if [ ! -d "$HOST_SHARED" ]; then
    mkdir -p "$HOST_SHARED" || { err "Не удалось создать $HOST_SHARED"; exit 1; }
    ok "Папка создана: $HOST_SHARED"
else
    info "Папка $HOST_SHARED уже существует"
fi

# ---------------------------------------------------------------------------
# 2. Проверка группы vboxsf
# ---------------------------------------------------------------------------
info "Проверка членства пользователя в группе vboxsf..."
if ! id -nG | grep -qw vboxsf; then
    warn "Пользователь НЕ в группе vboxsf. Shared folder будет недоступен."
    warn "Добавляю пользователя $CURRENT_USER в группу vboxsf..."
    # sudo: для управления группами требуются права root
    sudo usermod -aG vboxsf "$CURRENT_USER" || { err "Не удалось добавить в группу vboxsf"; exit 1; }
    warn "Пользователь добавлен в группу vboxsf. Требуется перезагрузка или 'newgrp vboxsf'."
else
    ok "Пользователь в группе vboxsf"
fi

# ---------------------------------------------------------------------------
# 3. Монтирование vboxsf вручную
# ---------------------------------------------------------------------------
info "Попытка монтирования shared folder..."

# Проверка, есть ли уже смонтированный host_shared
if mountpoint -q "$HOST_SHARED" 2>/dev/null; then
    ok "Shared folder уже смонтирован в $HOST_SHARED"
else
    # Проверка, существует ли device host_shared в системе
    if sudo modinfo vboxsf >/dev/null 2>&1; then
        # sudo: mount требует прав root для vboxsf
        sudo mount -t vboxsf -o uid="$(id -u)",gid="$(id -g)" host_shared "$HOST_SHARED" 2>/dev/null || {
            warn "mount -t vboxsf не удался. Возможно, требуется перезагрузка после установки Guest Additions."
            warn "Продолжаем настройку fstab и Syncthing."
        }
        if mountpoint -q "$HOST_SHARED" 2>/dev/null; then
            ok "Shared folder примонтирован в $HOST_SHARED"
        fi
    else
        warn "Модуль ядра vboxsf не загружен. Установите VirtualBox Guest Additions и перезагрузитесь."
    fi
fi

# ---------------------------------------------------------------------------
# 4. /etc/fstab с nofail
# ---------------------------------------------------------------------------
info "Настройка /etc/fstab..."

FSTAB_ENTRY="host_shared  $HOST_SHARED  vboxsf  defaults,uid=$(id -u),gid=$(id -g),nofail  0  0"

if ! grep -q "host_shared" /etc/fstab 2>/dev/null; then
    # sudo: запись в /etc/fstab требует прав root
    echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab >/dev/null || { err "Не удалось добавить запись в /etc/fstab"; exit 1; }
    ok "Запись добавлена в /etc/fstab: $FSTAB_ENTRY"
else
    info "Запись host_shared уже есть в /etc/fstab"
fi

# Проверка fstab
info "Проверка fstab (mount -a)..."
sudo mount -a 2>/dev/null || warn "mount -a завершился с предупреждениями — проверьте /etc/fstab"

# ---------------------------------------------------------------------------
# 5. Создание папки ~/syncthing-host (для бэкапов и синхронизации с Windows)
# ---------------------------------------------------------------------------
info "Создание папки $SYNCTHING_HOST..."
if [ ! -d "$SYNCTHING_HOST" ]; then
    mkdir -p "$SYNCTHING_HOST" || { err "Не удалось создать $SYNCTHING_HOST"; exit 1; }
    # Создаём подпапки
    mkdir -p "$SYNCTHING_HOST/backup"
    mkdir -p "$SYNCTHING_HOST/audit"
    mkdir -p "$SYNCTHING_HOST/logs"
    ok "Папка создана: $SYNCTHING_HOST (с подпапками backup, audit, logs)"
else
    info "Папка $SYNCTHING_HOST уже существует"
    # Проверяем подпапки
    for subdir in backup audit logs; do
        if [ ! -d "$SYNCTHING_HOST/$subdir" ]; then
            mkdir -p "$SYNCTHING_HOST/$subdir"
            info "Создана подпапка: $SYNCTHING_HOST/$subdir"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 6. Syncthing systemd user service
# ---------------------------------------------------------------------------
info "Настройка Syncthing systemd user service..."

if ! command -v syncthing >/dev/null 2>&1; then
    err "Syncthing не установлен. Установите через 02-install-linux-mint.sh."
    exit 1
fi

# Генерация конфигурации Syncthing (первый запуск)
if [ ! -d "$HOME/.config/syncthing" ]; then
    info "Первый запуск Syncthing для генерации конфигурации..."
    syncthing generate --no-default-folder --skip-port-probing 2>/dev/null || {
        warn "syncthing generate не удался. Запускаем с default-конфигом..."
    }
    ok "Конфигурация Syncthing создана в ~/.config/syncthing"
else
    info "Конфигурация Syncthing уже существует"
fi

# Включение linger — чтобы user-сервисы запускались без активной сессии
info "Включение linger для $CURRENT_USER..."
# sudo: loginctl требует прав root
sudo loginctl enable-linger "$CURRENT_USER" || warn "Не удалось включить linger"

# Включение и запуск systemd user service
info "Включение и запуск syncthing.service (user)..."
systemctl --user enable syncthing.service 2>/dev/null || warn "Не удалось включить syncthing.service"
systemctl --user start syncthing.service 2>/dev/null || warn "Не удалось запустить syncthing.service"

# Проверка статуса
sleep 3
if systemctl --user is-active syncthing.service >/dev/null 2>&1; then
    ok "Syncthing systemd user service запущен"
else
    warn "Syncthing service не активен. Проверьте: systemctl --user status syncthing.service"
fi

# Настройка Syncthing на прослушивание только на localhost (безопасность)
SYNCTHING_CONFIG="$HOME/.config/syncthing/config.xml"
if [ -f "$SYNCTHING_CONFIG" ]; then
    info "Настройка Syncthing GUI на 127.0.0.1:8384..."
    # sudo: редактирование конфига Syncthing — обычный файл пользователя, sudo не требуется
    # Используем sed для замены адреса GUI
    if grep -q '<address>127.0.0.1:8384</address>' "$SYNCTHING_CONFIG"; then
        info "GUI уже слушает на 127.0.0.1:8384"
    else
        sed -i 's|<address>0.0.0.0:8384</address>|<address>127.0.0.1:8384</address>|g' "$SYNCTHING_CONFIG" 2>/dev/null || true
        sed -i 's|<address>127.0.0.1:8384</address>|<address>127.0.0.1:8384</address>|g' "$SYNCTHING_CONFIG" 2>/dev/null || true
        # Перезапуск для применения
        systemctl --user restart syncthing.service 2>/dev/null || true
        ok "Syncthing GUI настроен на 127.0.0.1:8384"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Вывод Device ID Syncthing
# ---------------------------------------------------------------------------
info "Получение Device ID Syncthing..."
sleep 2

DEVICE_ID=""
for i in 1 2 3 4 5; do
    DEVICE_ID=$(syncthing --device-id 2>/dev/null || true)
    if [ -n "$DEVICE_ID" ]; then
        break
    fi
    info "Попытка $i: жду запуска Syncthing..."
    sleep 2
done

if [ -n "$DEVICE_ID" ]; then
    ok "Syncthing Device ID:"
    echo ""
    echo "      $DEVICE_ID"
    echo ""
    info "Добавьте этот Device ID в Syncthing на Windows-хосте (http://127.0.0.1:8384)"
    info "Скопируйте ID в буфер обмена: echo '$DEVICE_ID' | xclip -selection clipboard"
else
    warn "Не удалось получить Device ID. Проверьте: syncthing --device-id"
    warn "Возможно, Syncthing ещё запускается. Повторите команду вручную."
fi

# ---------------------------------------------------------------------------
# 8. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Настройка shared folder и Syncthing завершена"
echo "=========================================================="
info "Пути:"
echo "  Shared folder:    $HOST_SHARED"
echo "  Syncthing folder: $SYNCTHING_HOST"
echo "    - backup/   (для бэкапов)"
echo "    - audit/    (для отчётов аудита)"
echo "    - logs/     (для логов)"
echo ""
info "Syncthing:"
echo "  GUI:       http://127.0.0.1:8384"
echo "  Service:   systemctl --user status syncthing.service"
echo "  Конфиг:    $HOME/.config/syncthing/config.xml"
echo ""
info "Следующие шаги:"
echo "  1. На Windows-хосте откройте Syncthing GUI (http://127.0.0.1:8384)"
echo "  2. Добавьте Device ID этой VM в список устройств"
echo "  3. Поделитесь папкой D:\\StudioCode с этой VM"
echo "  4. Запустите 04-install-docker.sh (если ещё не запускали)"
echo "  5. Запустите 05-deploy-stack.sh для запуска стека v2.0"
echo ""

ok "Готово."
exit 0
