#!/usr/bin/env bash
# ============================================================================
# 04-install-docker.sh
# ============================================================================
# Установка Docker + Docker Compose v2 (v2.0 — учитывает размеры pgvector и AGE).
#
# - Проверка существующей установки
# - Установка через get.docker.com
# - Группа docker
# - /etc/docker/daemon.json с log rotation, overlay2, bip 172.20.0.1/16, DNS, live-restore
# - Перезапуск, hello-world, docker-compose-plugin
#
# Usage:
#   ./04-install-docker.sh
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

# ---------------------------------------------------------------------------
# 1. Проверка существующей установки Docker
# ---------------------------------------------------------------------------
info "Проверка существующей установки Docker..."
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker --version 2>/dev/null || echo "неизвестно")
    ok "Docker уже установлен: $DOCKER_VERSION"
    info "Если нужно переустановить, сначала удалите: sudo apt-get remove docker docker-engine docker.io containerd runc"
    read -r -p "Продолжить установку/обновление? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Установка отменена пользователем."
        exit 0
    fi
else
    info "Docker не установлен. Начинаем установку."
fi

# ---------------------------------------------------------------------------
# 2. Установка Docker через get.docker.com
# ---------------------------------------------------------------------------
info "Установка Docker через официальный скрипт get.docker.com..."

# Удаляем старые версии если есть
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Установка через get.docker.com
# sudo: get.docker.com устанавливает пакеты и требует прав root
curl -fsSL https://get.docker.com | sudo sh || { err "Не удалось установить Docker через get.docker.com"; exit 1; }
ok "Docker установлен: $(docker --version 2>/dev/null || echo 'проверьте docker --version')"

# ---------------------------------------------------------------------------
# 3. Группа docker
# ---------------------------------------------------------------------------
info "Добавление пользователя $CURRENT_USER в группу docker..."
# sudo: для управления группами требуются права root
if ! getent group docker >/dev/null 2>&1; then
    sudo groupadd docker || { err "Не удалось создать группу docker"; exit 1; }
fi
sudo usermod -aG docker "$CURRENT_USER" || { err "Не удалось добавить пользователя в группу docker"; exit 1; }
ok "Пользователь добавлен в группу docker (требуется 'newgrp docker' или перезагрузка)"

# Включение Docker в автозагрузку
sudo systemctl enable docker.service || warn "Не удалось включить docker.service в автозагрузку"
sudo systemctl enable containerd.service || warn "Не удалось включить containerd.service в автозагрузку"
sudo systemctl start docker || { err "Не удалось запустить docker"; exit 1; }
ok "Docker включён в автозагрузку и запущен"

# ---------------------------------------------------------------------------
# 4. /etc/docker/daemon.json для v2.0
# ---------------------------------------------------------------------------
# v2.0: учитываем, что pgvector и AGE могут занимать больше места
# и требуют больше ресурсов — увеличиваем log rotation и ulimits

info "Настройка /etc/docker/daemon.json для v2.0..."
# sudo: запись в /etc/docker/ требует прав root
sudo mkdir -p /etc/docker

# Бэкап старого daemon.json если есть
if [ -f /etc/docker/daemon.json ]; then
    sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d-%H%M%S)"
    info "Создан бэкап старого daemon.json"
fi

# Запись нового daemon.json
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
  },
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF
ok "daemon.json создан (bip=172.20.0.1/16, overlay2, live-restore, ulimits для pgvector/AGE)"

# Перезагрузка конфигурации systemd и Docker
info "Перезапуск Docker с новой конфигурацией..."
sudo systemctl daemon-reload || warn "systemctl daemon-reload не удался"
sudo systemctl restart docker || { err "Не удалось перезапустить Docker после записи daemon.json"; exit 1; }
ok "Docker перезапущен"

# Проверка конфигурации
info "Проверка применения конфигурации..."
DOCKER_INFO=$(docker info 2>/dev/null || true)
if echo "$DOCKER_INFO" | grep -q "Storage Driver: overlay2"; then
    ok "Storage Driver: overlay2"
else
    warn "Storage Driver не overlay2 — проверьте 'docker info'"
fi
if echo "$DOCKER_INFO" | grep -q "172.20.0.1/16"; then
    ok "BIP: 172.20.0.1/16"
else
    warn "BIP не 172.20.0.1/16 — проверьте 'docker info | grep -i bip'"
fi

# ---------------------------------------------------------------------------
# 5. Тест через hello-world
# ---------------------------------------------------------------------------
info "Тест Docker через hello-world..."
# sudo: на случай если пользователь ещё не сделал 'newgrp docker'
if sudo docker run --rm hello-world >/dev/null 2>&1; then
    ok "hello-world запустился успешно"
else
    warn "hello-world не запустился через sudo. Попробуйте 'newgrp docker' или перезагрузку."
fi

# ---------------------------------------------------------------------------
# 6. Установка docker-compose-plugin (Docker Compose v2)
# ---------------------------------------------------------------------------
info "Установка Docker Compose v2 (плагин)..."
if sudo apt-get install -y docker-compose-plugin 2>/dev/null; then
    ok "Docker Compose v2 установлен: $(docker compose version 2>/dev/null || echo 'проверьте docker compose version')"
else
    # Резервный вариант — установка через репозиторий Docker
    warn "Установка через apt не удалась. Пробуем через репозиторий Docker..."
    # sudo: для добавления репозитория требуются права root
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-compose-plugin || { err "Не удалось установить docker-compose-plugin"; exit 1; }
    ok "Docker Compose v2 установлен: $(docker compose version)"
fi

# ---------------------------------------------------------------------------
# 7. Проверка версии и итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Установка Docker + Docker Compose v2 завершена"
echo "=========================================================="
info "Версии:"
echo "  Docker:          $(docker --version 2>/dev/null)"
echo "  Docker Compose:  $(docker compose version 2>/dev/null | head -n1)"
echo "  Docker daemon:   $(sudo docker info 2>/dev/null | grep 'Server Version' || echo 'н/д')"
info "Конфигурация:"
echo "  daemon.json:     /etc/docker/daemon.json"
echo "  Storage driver:  overlay2"
echo "  BIP:             172.20.0.1/16"
echo "  DNS:             172.20.0.30, 8.8.8.8, 1.1.1.1"
echo "  Live restore:    включён"
echo ""
warn "Если 'docker ps' выдаёт 'permission denied', выполните:"
echo "    newgrp docker"
echo "  или перезагрузите VM."
echo ""
info "Следующий шаг:"
echo "  ./05-deploy-stack.sh    (запуск Docker Compose стека v2.0)"
echo ""

ok "Готово."
exit 0
