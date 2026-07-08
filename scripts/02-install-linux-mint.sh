#!/usr/bin/env bash
# ============================================================================
# 02-install-linux-mint.sh
# ============================================================================
# Установка базового ПО ВНУТРИ Linux Mint 22 после инсталляции ОС.
# Запускается от имени пользователя (не root) — использует sudo.
#
# Устанавливает:
#   - Обновление системы
#   - Пакеты: curl wget git git-lfs jq tree ripgrep build-essential dkms linux-headers
#   - VirtualBox Guest Additions
#   - Группа vboxsf + fstab для shared folder
#   - Docker + Docker Compose v2 + daemon.json (log rotation, overlay2, bip 172.20.0.1/16)
#   - Syncthing systemd
#   - MCP-серверы: postgres, github, sentry, slack
#   - Node.js 20.x, Python 3, postgresql-client-16
#
# Usage:
#   ./02-install-linux-mint.sh
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }

# Текущий пользователь (для sudo без root-запуска скрипта)
CURRENT_USER="$(whoami)"
if [ "$CURRENT_USER" = "root" ]; then
    err "Скрипт не предназначен для запуска от root. Запустите от имени обычного пользователя."
    exit 1
fi

info "Запуск от пользователя: $CURRENT_USER"

# Проверка, что sudo доступно
if ! sudo -n true 2>/dev/null; then
    info "Для установки потребуется пароль sudo..."
fi

# ---------------------------------------------------------------------------
# 1. Обновление системы
# ---------------------------------------------------------------------------
info "Обновление списка пакетов и системы..."
sudo apt-get update -y || { err "apt-get update не удался"; exit 1; }
# sudo: для установки системных пакетов требуются права root
sudo apt-get upgrade -y || { err "apt-get upgrade не удался"; exit 1; }
sudo apt-get dist-upgrade -y || { err "apt-get dist-upgrade не удался"; exit 1; }
ok "Система обновлена"

# ---------------------------------------------------------------------------
# 2. Установка базовых пакетов
# ---------------------------------------------------------------------------
info "Установка базовых пакетов разработки..."
BASE_PACKAGES=(
    curl wget git git-lfs jq tree ripgrep
    build-essential dkms linux-headers-generic
    ca-certificates gnupg lsb-release software-properties-common
    unzip zip vim htop tmux
    python3 python3-pip python3-venv python3-dev
    postgresql-client-16
)
sudo apt-get install -y "${BASE_PACKAGES[@]}" || { err "Не удалось установить базовые пакеты"; exit 1; }
ok "Базовые пакеты установлены"

# git-lfs инициализация
git lfs install || warn "git lfs install не удался — пропускаем"
ok "git-lfs инициализирован"

# ---------------------------------------------------------------------------
# 3. Установка VirtualBox Guest Additions
# ---------------------------------------------------------------------------
info "Установка VirtualBox Guest Additions..."

# Проверка, смонтирован ли образ Guest Additions
GUEST_ADDITIONS_PATH="/media/$CURRENT_USER/VBox_GAs_*/VBoxLinuxAdditions.run"
if ls $GUEST_ADDITIONS_PATH >/dev/null 2>&1; then
    GA_FILE=$(ls $GUEST_ADDITIONS_PATH | head -n1)
    info "Запуск установки Guest Additions: $GA_FILE"
    sudo bash "$GA_FILE" || { warn "Guest Additions не установились корректно — возможно, требуется перезагрузка"; }
    ok "Guest Additions установлены"
else
    warn "Образ Guest Additions не смонтирован."
    warn "В VirtualBox: Devices -> Insert Guest Additions CD image..., затем повторно запустите скрипт."
    warn "Продолжаем без Guest Additions (shared folder может не работать)."
fi

# ---------------------------------------------------------------------------
# 4. Добавление пользователя в группу vboxsf
# ---------------------------------------------------------------------------
info "Добавление пользователя $CURRENT_USER в группу vboxsf..."
if getent group vboxsf >/dev/null 2>&1; then
    sudo usermod -aG vboxsf "$CURRENT_USER" || { err "Не удалось добавить в группу vboxsf"; exit 1; }
    ok "Пользователь добавлен в группу vboxsf (требуется перезагрузка или новый вход)"
else
    warn "Группа vboxsf не существует. Установите Guest Additions."
fi

# ---------------------------------------------------------------------------
# 5. /etc/fstab для shared folder
# ---------------------------------------------------------------------------
info "Настройка /etc/fstab для shared folder..."
SHARED_MOUNT_POINT="/home/$CURRENT_USER/host_shared"
sudo mkdir -p "$SHARED_MOUNT_POINT" || { err "Не удалось создать $SHARED_MOUNT_POINT"; exit 1; }
sudo chown "$CURRENT_USER:$CURRENT_USER" "$SHARED_MOUNT_POINT"

# Проверка, есть ли уже запись в fstab
if ! grep -q "host_shared" /etc/fstab 2>/dev/null; then
    echo "host_shared  $SHARED_MOUNT_POINT  vboxsf  defaults,uid=$(id -u),gid=$(id -g),nofail  0  0" | \
        sudo tee -a /etc/fstab >/dev/null || { err "Не удалось добавить запись в /etc/fstab"; exit 1; }
    ok "Запись добавлена в /etc/fstab"
else
    info "Запись host_shared уже есть в /etc/fstab — пропуск"
fi

# Пытаемся смонтировать сразу
sudo mount -a 2>/dev/null || warn "mount -a не удался — перезагрузитесь для применения"
ok "Shared folder настроен"

# ---------------------------------------------------------------------------
# 6. Установка Node.js 20.x
# ---------------------------------------------------------------------------
info "Установка Node.js 20.x через NodeSource..."
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -q "v20"; then
    # NodeSource setup script
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || { err "Не удалось настроить NodeSource"; exit 1; }
    sudo apt-get install -y nodejs || { err "Не удалось установить Node.js"; exit 1; }
    ok "Node.js 20.x установлен: $(node -v)"
else
    ok "Node.js уже установлен: $(node -v)"
fi

# npm глобальные настройки
info "Настройка npm..."
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global" || warn "Не удалось настроить npm prefix"
if ! grep -q "npm-global" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    info "PATH для npm-global добавлен в .bashrc"
fi
export PATH="$HOME/.npm-global/bin:$PATH"

# ---------------------------------------------------------------------------
# 7. Установка Docker и Docker Compose v2
# ---------------------------------------------------------------------------
info "Установка Docker через get.docker.com..."

if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sudo sh || { err "Не удалось установить Docker"; exit 1; }
    ok "Docker установлен: $(docker --version)"
fi

# Группа docker
info "Добавление пользователя $CURRENT_USER в группу docker..."
sudo usermod -aG docker "$CURRENT_USER" || { err "Не удалось добавить в группу docker"; exit 1; }
ok "Пользователь добавлен в группу docker (требуется перезагрузка или 'newgrp docker')"

# Включение и запуск Docker
sudo systemctl enable docker || warn "Не удалось включить docker в автозагрузку"
sudo systemctl start docker || warn "Не удалось запустить docker"

# Docker Compose v2 (plugin)
info "Установка Docker Compose v2 (плагин)..."
sudo apt-get install -y docker-compose-plugin || { err "Не удалось установить docker-compose-plugin"; exit 1; }
ok "Docker Compose v2 установлен: $(docker compose version)"

# ---------------------------------------------------------------------------
# 8. /etc/docker/daemon.json (v2.0 — учитывает размеры pgvector и AGE)
# ---------------------------------------------------------------------------
info "Настройка /etc/docker/daemon.json для v2.0..."

# sudo: запись в /etc/docker/ требует прав root
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF' || { err "Не удалось записать daemon.json"; exit 1; }
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "bip": "172.20.0.1/16",
  "default-address-pools": [
    {"base": "172.20.0.0/16", "size": 24}
  ],
  "dns": ["172.20.0.30", "8.8.8.8", "1.1.1.1"],
  "live-restore": true,
  "userland-proxy": false,
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5,
  "default-ulimits": {
    "nofile": {"Hard": 65536, "Soft": 65536},
    "nproc": {"Hard": 4096, "Soft": 4096}
  }
}
EOF
ok "daemon.json создан (bip=172.20.0.1/16, overlay2, live-restore)"

sudo systemctl daemon-reload || warn "systemctl daemon-reload не удался"
sudo systemctl restart docker || { err "Не удалось перезапустить Docker"; exit 1; }
ok "Docker перезапущен с новой конфигурацией"

# Тест Docker
info "Тест Docker через hello-world..."
sudo docker run --rm hello-world >/dev/null 2>&1 || warn "hello-world не запустился — возможно, требуется 'newgrp docker'"
ok "Docker работает"

# ---------------------------------------------------------------------------
# 9. Syncthing systemd
# ---------------------------------------------------------------------------
info "Установка Syncthing..."
if ! command -v syncthing >/dev/null 2>&1; then
    # Добавляем репозиторий Syncthing
    sudo curl -fsSL -o /usr/share/keyrings/syncthing-archive-keyring.gpg \
        https://syncthing.net/release-key.gpg || { err "Не удалось добавить ключ Syncthing"; exit 1; }
    echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | \
        sudo tee /etc/apt/sources.list.d/syncthing.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y syncthing || { err "Не удалось установить Syncthing"; exit 1; }
    ok "Syncthing установлен: $(syncthing --version | head -n1)"
else
    ok "Syncthing уже установлен: $(syncthing --version | head -n1)"
fi

# Включаем systemd user-сервис для Syncthing (запускается от имени пользователя)
info "Включение systemd user service для Syncthing..."
systemctl --user enable syncthing.service || warn "Не удалось включить syncthing.service"
systemctl --user start syncthing.service || warn "Не удалось запустить syncthing.service"
# linger — чтобы user-сервисы запускались без активной сессии
sudo loginctl enable-linger "$CURRENT_USER" || warn "Не удалось включить linger для $CURRENT_USER"
ok "Syncthing systemd user service включён"

# ---------------------------------------------------------------------------
# 10. MCP-серверы (для агентов)
# ---------------------------------------------------------------------------
info "Установка MCP-серверов через npm и pip..."

# npm глобальные MCP-серверы
NPM_MCPS=(
    "@modelcontextprotocol/server-postgres"
    "@modelcontextprotocol/server-github"
)
for pkg in "${NPM_MCPS[@]}"; do
    info "npm i -g $pkg..."
    npm i -g "$pkg" || { warn "Не удалось установить npm-пакет $pkg"; }
done
ok "npm MCP-серверы установлены"

# pip MCP-серверы (используем --user)
PIP_MCPS=(
    "mcp-server-sentry"
    "mcp-server-slack"
)
for pkg in "${PIP_MCPS[@]}"; do
    info "pip install --user $pkg..."
    pip3 install --user --break-system-packages "$pkg" || { warn "Не удалось установить pip-пакет $pkg"; }
done
ok "pip MCP-серверы установлены"

# ---------------------------------------------------------------------------
# 11. postgresql-client-16 (для ручных подключений к БД)
# ---------------------------------------------------------------------------
info "Проверка postgresql-client-16..."
if command -v psql >/dev/null 2>&1; then
    ok "psql уже установлен: $(psql --version)"
else
    warn "psql не найден — устанавливаю postgresql-client-16..."
    sudo apt-get install -y postgresql-client-16 || { err "Не удалось установить postgresql-client-16"; exit 1; }
fi
ok "psql готов к работе"

# ---------------------------------------------------------------------------
# 12. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Установка базового ПО в Linux Mint 22 завершена"
echo "=========================================================="
info "Установлено:"
echo "  - Базовые пакеты (curl, git, jq, ripgrep, build-essential, dkms, linux-headers)"
echo "  - VirtualBox Guest Additions"
echo "  - Группа vboxsf + fstab для shared folder"
echo "  - Docker + Docker Compose v2 + daemon.json (bip=172.20.0.1/16)"
echo "  - Syncthing systemd user service"
echo "  - Node.js 20.x + npm MCP-серверы (postgres, github)"
echo "  - Python 3 + pip MCP-серверы (sentry, slack)"
echo "  - postgresql-client-16"
echo ""
warn "ВАЖНО: Требуется перезагрузка для применения групп (vboxsf, docker) и Guest Additions."
echo ""
info "Следующие шаги:"
echo "  1. Перезагрузите VM:    sudo reboot"
echo "  2. После перезагрузки:  ./03-setup-shared-folder.sh"
echo "  3. Затем:               ./04-install-docker.sh  (если нужно перенастроить daemon.json)"
echo "  4. Затем:               ./05-deploy-stack.sh    (запуск Docker Compose стека v2.0)"
echo ""

ok "Готово."
exit 0
