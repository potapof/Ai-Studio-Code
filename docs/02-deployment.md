# Развёртывание VirtualBox + Linux Mint

> Содержание: установка VirtualBox 7.2 на Windows 10, создание VM Linux Mint 22, Guest Additions, общие папки, Syncthing, проброс портов, установка Docker. Все команды «копировать-вставить».

## 1. Стратегия развёртывания

«Студия программирования» версии 2.0 использует **гибридную стратегию развёртывания**: критически важные шаги (настройка VirtualBox, Guest Additions, проектирование агентов) выполняются вручную, рутинные технические задачи (установка Docker, клонирование репозиториев) автоматизируются через bash-скрипты. Этот подход обеспечивает баланс между контролем и эффективностью.

Использование AutoClaw или других AI-ассистентов на хосте Windows **категорически не рекомендуется**. Двойная виртуализация (Windows → VirtualBox → Docker) создаёт сложную многоуровневую систему, отладка которой затруднительна. Все операции выполняются внутри гостевой Linux Mint VM, где Docker работает нативно. NocoDB развёрнут как Docker-контейнер и подключается к PostgreSQL через Docker-сеть — никаких хостовых монтирований базы данных, как в версии 1.0 (где `noco.db` лежал в `/home/potapof/ai-studio/data/nocodb/` и вызывал `Permission denied`).

## 2. Подготовка хоста Windows 10 Pro

### 2.1. Системные требования

- **ОС:** Windows 10 Pro 21H2 или новее.
- **RAM:** минимум 32 ГБ (16 ГБ для VM + 16 ГБ для Windows).
- **Диск:** минимум 200 ГБ свободного места.
- **CPU:** поддерживает VT-x/AMD-V (включите в BIOS: `Intel Virtualization Technology` / `SVM Mode`).
- **Сеть:** гигабитный Ethernet (Wi-Fi не рекомендуется).

### 2.2. Включение виртуализации

В BIOS/UEFI материнской платы включите:
- Intel: `Intel Virtualization Technology (VT-x)`, `Intel VT-d`.
- AMD: `SVM Mode`.

Проверьте в Windows:
```powershell
systeminfo | Select-String "Hyper-V"
# Virtualization Enabled In Firmware: Yes
```

Если Hyper-V включён, отключите его (конфликтует с VirtualBox):
```powershell
Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

### 2.3. Установка VirtualBox 7.2 + Extension Pack

Скачайте VirtualBox 7.2.x с https://www.virtualbox.org/wiki/Downloads. Установите с параметрами по умолчанию. Скачайте Extension Pack (тот же сайт) и установите через GUI: File → Preferences → Extensions → добавьте файл.

### 2.4. Рабочая папка на хосте

```powershell
mkdir D:\StudioCode
mkdir D:\StudioCode\configs
mkdir D:\StudioCode\backup
```

В `D:\StudioCode` будут синхронизироваться конфиги и резервные копии через Syncthing. **Никогда не размещайте здесь базы данных** — vboxsf не поддерживает POSIX-блокировки.

## 3. Создание виртуальной машины

### 3.1. Скачивание ISO

Скачайте Linux Mint 22 Cinnamon (64-bit) с https://linuxmint.com/download.php. Размер ~2.8 ГБ.

### 3.2. Создание VM

1. **VirtualBox → New**
2. **Name:** `studio-mint`
3. **Folder:** `D:\VMs\studio-mint`
4. **ISO Image:** путь к `linuxmint-22-cinnamon-64bit.iso`
5. **Type:** Linux, **Version:** Ubuntu (64-bit)
6. **Skip Unattended Installation:** ✅

**Hardware:**
- **Base Memory:** 16384 МБ (16 ГБ; минимум 8 ГБ, оптимум 32 ГБ)
- **Processors:** 4 CPU (минимум 2, оптимум 8)
- **Enable EFI:** ❌

**Hard Disk:**
- 100 ГБ VDI dynamic (минимум 60 ГБ, оптимум 200 ГБ)

**Network:**
- Adapter 1: NAT
- Adapter 2: Host-only Adapter (для доступа к VM из Windows)

### 3.3. Дополнительные настройки

**Settings → System → Processor:**
- Execution Cap: 100%
- ✅ Enable PAE/NX, ✅ Enable VT-x/AMD-V

**Display:**
- Video Memory: 128 МБ
- Graphics Controller: VMSVGA
- ✅ Enable 3D Acceleration

**Network → Adapter 1 (NAT) → Advanced → Port Forwarding:**

| Name | Protocol | Host Port | Guest Port | Subsystem |
|------|----------|-----------|------------|-----------|
| ssh | TCP | 2222 | 22 | SSH из Windows |
| nocodb | TCP | 8080 | 8080 | NocoDB UI |
| portainer | TCP | 9000 | 9000 | Portainer UI |
| syncthing | TCP | 8384 | 8384 | Syncthing UI |
| postgres | TCP | 5432 | 5432 | PostgreSQL (только для разработки) |
| hermes | TCP | 8082 | 8080 | Hermes HTTP API |
| webhook | TCP | 8081 | 8081 | Webhook endpoints |

**Shared Folders:**
- `D:\StudioCode` → Name: `host_shared`, ✅ Make Permanent, ❌ Auto-mount

## 4. Установка Linux Mint 22

Запустите VM, выберите «Install Linux Mint»:

1. **Language:** Russian
2. **Keyboard:** Russian + English (переключение: Win+Space)
3. **Install third-party software:** ✅
4. **Erase disk and install Linux Mint:** ✅ (виртуальный диск!)
5. **Timezone:** Europe/Moscow
6. **User:** `studio`, computer name `studio-mint`, пароль `<надёжный>`

### 4.1. После установки

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git git-lfs jq tree ripgrep build-essential dkms linux-headers-$(uname -r)
sudo reboot
```

### 4.2. Установка Guest Additions

```bash
# Через меню VirtualBox: Devices → Insert Guest Additions CD image
sudo mkdir -p /media/cdrom
sudo mount /dev/cdrom /media/cdrom
cd /media/cdrom
sudo ./VBoxLinuxAdditions.run
sudo reboot
```

### 4.3. Группа vboxsf

```bash
sudo usermod -aG vboxsf $(whoami)
exit  # перезайти
groups | grep vboxsf  # проверить
```

### 4.4. Монтирование общей папки

```bash
mkdir -p ~/host_shared
sudo mount -t vboxsf -o uid=$(id -u),gid=$(id -g) host_shared ~/host_shared

# Автоматическое монтирование
echo "host_shared /home/studio/host_shared vboxsf defaults,uid=$(id -u),gid=$(id -g),nofail 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

### 4.5. Критическое правило

**Общая папка — канал доставки, не рабочая среда.** vboxsf не реализует POSIX-блокировки.

- ✅ МОЖНО: конфиги YAML, скрипты, документация, резервные копии.
- ❌ НЕЛЬЗЯ: базы данных (NocoDB, PostgreSQL, SQLite), рабочие каталоги агентов, `.git`.

## 5. Установка Syncthing

Syncthing — P2P-синхронизация через TLS. Надёжнее, чем прямое редактирование в vboxsf.

### 5.1. На хосте Windows

Скачайте Syncthing с https://syncthing.net/downloads/, распакуйте в `C:\Tools\Syncthing\`. Настройте автозапуск через Task Scheduler:

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Tools\Syncthing\syncthing.exe" -Argument "--no-browser"
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "Syncthing" -Action $action -Trigger $trigger -RunLevel Highest
```

### 5.2. На госте Linux Mint

```bash
sudo mkdir -p /etc/apt/keyrings
curl -L -o /etc/apt/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | sudo tee /etc/apt/sources.list.d/syncthing.list

sudo apt update
sudo apt install -y syncthing
systemctl --user enable syncthing.service
systemctl --user start syncthing.service
```

### 5.3. Настройка синхронизации

1. На хосте (http://localhost:8384): Add Device → введите Device ID гостя.
2. На госте (http://localhost:8384): скопируйте Device ID (Actions → Show ID), подтвердите добавление хоста.
3. Поделитесь папкой `D:\StudioCode` (Folder ID: `studio-code`) с устройством гостя.
4. На госте примите папку → сохраните в `~/syncthing-host`.
5. Тип синхронизации: Send Only на хосте, Receive Only на госте (или двунаправленная).

## 6. Установка Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker --version  # Docker 24+
docker run hello-world
```

### 6.1. Настройка daemon.json

```bash
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "userland-proxy": false,
  "dns": ["1.1.1.1", "8.8.8.8"],
  "bip": "172.20.0.1/16",
  "default-address-pools": [
    {"base": "172.20.0.0/16", "size": 24}
  ],
  "live-restore": true,
  "iptables": true,
  "ip6tables": true
}
EOF

sudo systemctl restart docker
sudo systemctl enable docker
```

### 6.2. Docker Compose v2

```bash
sudo apt install -y docker-compose-plugin
docker compose version  # v2.20+
```

### 6.3. Вспомогательные инструменты

```bash
sudo apt install -y git-lfs jq tree ripgrep httpie
git lfs install

# Node.js для MCP-серверов
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g npx

# Python для MCP-серверов
sudo apt install -y python3-pip python3-venv
pip install --user mcp-server-sentry mcp-server-slack

# Apache AGE утилиты
sudo apt install -y postgresql-client-16
```

## 7. Клонирование репозитория

```bash
mkdir -p ~/studio
cd ~/studio
git clone <your-repo-url> .
# Или: cp -r ~/syncthing-host/studio-docs/* .

cp examples/.env.example .env
nano .env  # заполнить секреты
chmod 600 .env
echo ".env" >> .gitignore
```

### 7.1. Ключевые переменные .env

```env
# PostgreSQL
POSTGRES_DB=hermes_brain
POSTGRES_USER=nocodb_user
POSTGRES_PASSWORD=<openssl rand -base64 24>

# NocoDB
NC_AUTH_JWT_SECRET=<openssl rand -hex 32>

# LLM API
DEEPSEEK_API_KEY=sk-deepseek-...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...

# GitHub
GITHUB_TOKEN=ghp_...  # PAT с правами repo, workflow
GITHUB_WEBHOOK_SECRET=<openssl rand -hex 20>

# Stack Overflow for Agents (OAuth 2.1 — токен получается через браузер)
SOA_CLIENT_ID=<из https://stackapps.com/apps>

# Slack (опционально)
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL_ID=C...

# Sentry (опционально)
SENTRY_DSN=https://...@sentry.io/...

TZ=Europe/Moscow
```

## 8. Запуск Docker Compose стека

```bash
cd ~/studio
docker compose up -d
docker compose ps  # все Up

# Проверка
curl http://localhost:8080/api/v1/health  # NocoDB
docker exec nocodb-postgres-db pg_isready  # PostgreSQL
```

## 9. Инициализация конвергентной БД

После первого запуска нужно установить расширения PostgreSQL:

```bash
# Установка pgvector (обычно уже установлен в образе pgvector/pgvector:pg16)
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Установка Apache AGE
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS age;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "LOAD 'age';"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SET search_path = ag_catalog, \"\$user\", public;"

# Создание графа зависимостей кода
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c \
  "SELECT ag_catalog.create_graph('code_graph');"

# Выполнить SQL-схему
for sql in examples/sql/*.sql; do
  echo "Executing $sql..."
  docker exec -i nocodb-postgres-db psql -U nocodb_user -d hermes_brain < "$sql"
done
```

## 10. Подключение MCP-серверов к Hermes

```bash
# postgres MCP — прямой доступ к мозгу
hermes mcp add hermes-brain --transport stdio -- \
  npx -y @modelcontextprotocol/server-postgres \
  "postgresql://nocodb_user:${POSTGRES_PASSWORD}@nocodb-postgres-db:5432/hermes_brain"

# SOA MCP — внешние проверенные знания
hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com
# При первом вызове откроется браузер для OAuth 2.1

# GitHub MCP — PR, issues, CI/CD
hermes mcp add github --transport stdio -- \
  npx -y @modelcontextprotocol/server-github \
  --env GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}

# Slack MCP — уведомления
hermes mcp add slack --transport stdio -- \
  python -m mcp_server_slack \
  --env SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}

# Проверка подключений
hermes mcp list
hermes mcp test hermes-brain
hermes mcp test stackoverflow
```

## 11. Автозапуск

```bash
sudo systemctl enable docker
```

Для автозапуска VM при загрузке Windows (опционально):

```powershell
$action = New-ScheduledTaskAction -Execute "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" -Argument "startvm studio-mint --type headless"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "StartStudioVM" -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM"
```

## 12. Что дальше

- **Docker Compose стек** — [docs/03-docker-stack.md](03-docker-stack.md)
- **Конвергентная база данных** — [docs/04-convergent-database.md](04-convergent-database.md)
- **Эталонный API/MCP референс** — [docs/06-api-mcp-reference.md](06-api-mcp-reference.md)
