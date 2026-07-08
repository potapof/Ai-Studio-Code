---
name: deploy-studio
description: Полное развёртывание платформы "Студия программирования" 2.0 с нуля на Linux Mint VM
triggers:
  - manual
maker: hermes
checker: hermes
arbiter: hermes
max_retries: 2
token_budget: 200000
cost_limit_usd: 10.00
---

# Deploy Studio Programming Platform

## Контекст

Пользователь (не программист) просит тебя развернуть платформу "Студия программирования" 2.0 на его виртуальной машине Linux Mint. У него уже установлены VirtualBox, Linux Mint и ты (Hermes Agent). Нужно проверить окружение, установить недостающие компоненты, развернуть все сервисы через Docker Compose и проверить, что всё работает.

Действуй пошагово. После каждого шага сообщай пользователю, что сделано и что будет дальше. Если что-то не получается — объясняй простыми словами и предлагай решение. Не выполняй следующие шаги, пока предыдущий не завершён успешно.

## Принципы работы с пользователем

1. Пользователь — не программист. Объясняй каждый шаг простыми словами.
2. Перед каждой командой объясняй, что она делает и зачем.
3. После каждой команды показывай, что должно появиться в результате.
4. Если команда может что-то сломать — предупреждай и спрашивай подтверждение.
5. Не используй жаргон без объяснения. "Docker-контейнер" = "изолированная программа в своей коробке".
6. Если видишь ошибку — не паникуй, объясни пользователю что произошло и как исправить.
7. Делай паузы между этапами, чтобы пользователь успевал читать.

## Шаг 1: Проверка окружения

Сначала проверь, что уже установлено. Выполни команды и сообщи пользователю результаты.

### 1.1 Проверка операционной системы

Выполни:
```bash
cat /etc/os-release | head -5
uname -a
```

Должно показать Linux Mint 22 или новее (на базе Ubuntu 24.04). Если версия старее — предупреди пользователя, что нужно обновиться.

### 1.2 Проверка Docker

Выполни:
```bash
docker --version
docker compose version
```

Если Docker не установлен — перейди к Шагу 2. Если установлен — сообщи версию и перейди к Шагу 3.

### 1.3 Проверка свободного места

Выполни:
```bash
df -h / | tail -1
free -h | head -2
```

Нужно минимум:
- 50 ГБ свободного места на диске
- 8 ГБ свободной оперативной памяти

Если меньше — предупреди пользователя.

### 1.4 Проверка интернета

Выполни:
```bash
ping -c 3 api.deepseek.com
```

Если интернет не работает — развёртывание невозможно, сообщи пользователю.

### 1.5 Проверка Hermes

Ты и есть Hermes, поэтому проверь себя:
```bash
which hermes
hermes --version 2>/dev/null || hermes version 2>/dev/null
```

Сообщи пользователю свою версию.

### 1.6 Проверка наличия файлов проекта

Проверь, есть ли уже файлы проекта:
```bash
ls -la ~/studio/ 2>/dev/null || echo "Папка ~/studio не найдена"
ls -la ~/syncthing-host/studio-docs/ 2>/dev/null || echo "Файлы проекта не найдены в syncthing-host"
```

Если файлов нет — перейди к Шагу 2 (подготовка). Если есть — перейди к Шагу 3.

## Шаг 2: Установка недостающих компонентов

### 2.1 Если Docker не установлен

Скажи пользователю: "Docker не установлен. Сейчас я установлю Docker — это программа, которая позволяет запускать другие программы в изолированных контейнерах. Это займёт 2-3 минуты."

Выполни:
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Проверь:
```bash
docker --version
docker run hello-world
```

Должно появиться сообщение "Hello from Docker!".

### 2.2 Настройка Docker

Скажи: "Теперь я настрою Docker для оптимальной работы нашей платформы."

Создай файл `/etc/docker/daemon.json`:
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
  "live-restore": true,
  "iptables": true
}
EOF

sudo systemctl restart docker
sudo systemctl enable docker
```

### 2.3 Установка вспомогательных программ

```bash
sudo apt update
sudo apt install -y curl wget git git-lfs jq tree ripgrep build-essential dkms linux-headers-$(uname -r)
```

### 2.4 Установка Node.js (для MCP-серверов)

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node --version  # должно показать v20+
```

### 2.5 Установка MCP-серверов

```bash
sudo npm install -g npx
npx -y @modelcontextprotocol/server-postgres --help 2>/dev/null && echo "postgres MCP готов"
```

## Шаг 3: Подготовка файлов проекта

### 3.1 Если файлы проекта не скопированы

Скажи пользователю: "Теперь мне нужны файлы проекта. Они находятся в папке, которую вы синхронизируете с Windows через Syncthing. Проверю, есть ли они там."

Проверь:
```bash
ls ~/syncthing-host/studio-docs/ 2>/dev/null
```

Если файлов нет — попроси пользователя:
"Файлы проекта не найдены. Пожалуйста, скопируйте папку studio-docs с Windows в папку ~/syncthing-host/ (или в ~/host_shared/). Если вы используете Syncthing — дождитесь синхронизации. Когда закончите, скажите мне 'готово'."

Дождись ответа пользователя перед продолжением.

### 3.2 Копирование файлов в рабочую директорию

```bash
mkdir -p ~/studio
cp -r ~/syncthing-host/studio-docs/* ~/studio/ 2>/dev/null || cp -r ~/host_shared/studio-docs/* ~/studio/
cd ~/studio
ls -la
```

Покажи пользователю структуру:
```bash
tree -L 2 ~/studio/ | head -30
```

### 3.3 Создание файла .env

Скажи: "Сейчас я создам файл настроек с паролями и API-ключами. Вам нужно будет заполнить его."

```bash
cp ~/studio/examples/.env.example ~/studio/.env
```

Покажи пользователю, какие строки нужно заполнить:
```bash
cat ~/studio/.env
```

Скажи: "Вам нужно заполнить следующие обязательные поля:
1. POSTGRES_PASSWORD — придумайте надёжный пароль для базы данных (минимум 20 символов)
2. NC_AUTH_JWT_SECRET — я сгенерирую это для вас
3. DEEPSEEK_API_KEY — ваш API-ключ от DeepSeek (получите на https://platform.deepseek.com/)
4. GITHUB_TOKEN — ваш токен GitHub (получите на https://github.com/settings/tokens)

Остальные поля можно оставить пустыми — они опциональны.

Сгенерируйте пароль командой: openssl rand -base64 24
Сгенерируйте секрет: openssl rand -hex 32

Когда заполните файл, скажите мне 'готово'."

Сгенерируй секреты для пользователя:
```bash
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
echo "NC_AUTH_JWT_SECRET=$(openssl rand -hex 32)"
echo "HERMES_MCP_SERVER_TOKEN=$(openssl rand -hex 32)"
```

Дождись ответа пользователя перед продолжением.

## Шаг 4: Запуск платформы

### 4.1 Запуск Docker Compose

Скажи: "Отлично! Теперь я запущу все сервисы платформы. Это займёт 5-15 минут — Docker будет скачивать образы из интернета."

```bash
cd ~/studio
docker compose pull
docker compose up -d
```

Покажи прогресс:
```bash
docker compose ps
```

Все сервисы должны быть в статусе "Up" или "healthy". Если какой-то сервис не запустился — покажи его логи и объясни проблему.

### 4.2 Ожидание готовности сервисов

Скажи: "Сервисы запускаются. Подожду, пока они будут готовы."

```bash
# Ждём PostgreSQL
echo "Ожидание PostgreSQL..."
until docker exec nocodb-postgres-db pg_isready 2>/dev/null; do
  sleep 2
  echo -n "."
done
echo " PostgreSQL готов!"

# Ждём NocoDB
echo "Ожидание NocoDB..."
until curl -sf http://localhost:8080/api/v1/health 2>/dev/null; do
  sleep 2
  echo -n "."
done
echo " NocoDB готов!"
```

## Шаг 5: Инициализация базы данных

### 5.1 Установка расширений PostgreSQL

Скажи: "База данных запущена. Теперь я установлю расширения, которые делают её "умной" — способной понимать смысл текста (pgvector) и связи между объектами (Apache AGE)."

```bash
# Создание базы данных hermes_brain
docker exec -it nocodb-postgres-db psql -U nocodb_user -d postgres -c "CREATE DATABASE hermes_brain;" 2>/dev/null || echo "БД hermes_brain уже существует"

# Установка расширений
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS vector;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS age;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "LOAD 'age';"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SET search_path = ag_catalog, \"\$user\", public;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Создание графов
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SELECT ag_catalog.create_graph('code_graph');" 2>/dev/null || echo "Граф code_graph уже существует"
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SELECT ag_catalog.create_graph('task_graph');" 2>/dev/null || echo "Граф task_graph уже существует"

echo "Расширения установлены!"
```

### 5.2 Выполнение SQL-схемы

Скажи: "Теперь я создам структуру таблиц — где будут храниться знания, задачи, история работы."

```bash
cd ~/studio
for sql in examples/sql/*.sql; do
  echo "Выполняю $sql..."
  docker exec -i nocodb-postgres-db psql -U nocodb_user -d hermes_brain < "$sql" 2>&1 | tail -5
done
echo "Структура таблиц создана!"
```

### 5.3 Создание тестового тенанта

```bash
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "SELECT public.create_tenant_schema('default');" 2>/dev/null || echo "Тенант default уже существует"
echo "Тестовый тенант создан!"
```

## Шаг 6: Подключение MCP-серверов

### 6.1 Подключение к базе данных (postgres MCP)

Скажи: "Теперь я подключусь к базе данных через стандартный протокол MCP. Это позволит мне напрямую читать и писать знания."

Получи пароль из .env:
```bash
POSTGRES_PASSWORD=$(grep POSTGRES_PASSWORD ~/studio/.env | cut -d= -f2)
```

Выполни:
```bash
hermes mcp add hermes-brain --transport stdio -- \
  npx -y @modelcontextprotocol/server-postgres \
  "postgresql://nocodb_user:${POSTGRES_PASSWORD}@nocodb-postgres-db:5432/hermes_brain"
```

Проверь:
```bash
hermes mcp list
hermes mcp test hermes-brain
```

### 6.2 Подключение к Stack Overflow for Agents (опционально)

Скажи: "Я могу подключить вас к Stack Overflow for Agents — это сервис, который даст мне доступ к проверенным техническим решениям. Для этого нужна авторизация через браузер. Хотите подключить сейчас?"

Если пользователь согласен:
```bash
hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com
echo "При первом обращении к Stack Overflow откроется браузер для авторизации."
```

Если нет — пропусти этот шаг.

### 6.3 Подключение к GitHub (опционально)

Скажи: "Я могу подключиться к вашему GitHub, чтобы автоматически создавать Pull Request. Хотите?"

Если пользователь согласен и у него есть GITHUB_TOKEN в .env:
```bash
GITHUB_TOKEN=$(grep GITHUB_TOKEN ~/studio/.env | cut -d= -f2)
if [ -n "$GITHUB_TOKEN" ] && [ "$GITHUB_TOKEN" != "ghp_..." ]; then
  hermes mcp add github --transport stdio -- \
    npx -y @modelcontextprotocol/server-github
  echo "GitHub подключён!"
else
  echo "GITHUB_TOKEN не заполнен в .env — пропускаю. Можно подключить позже."
fi
```

## Шаг 7: Регистрация навыков

Скажи: "Теперь я зарегистрирую навыки — это инструкции, которые я буду использовать для автоматизации задач."

```bash
cd ~/studio
for skill_dir in examples/skills/*/; do
  skill_name=$(basename "$skill_dir")
  if [ -f "$skill_dir/SKILL.md" ]; then
    echo "Регистрирую навык: $skill_name"
    hermes skills register "$skill_dir/SKILL.md" 2>/dev/null || echo "Навык $skill_name уже зарегистрирован"
  fi
done
echo "Навыки зарегистрированы!"
```

## Шаг 8: Финальная проверка

### 8.1 Проверка всех сервисов

```bash
echo "=== Статус сервисов ==="
docker compose ps

echo ""
echo "=== Проверка доступности ==="
echo "NocoDB (приборная панель):"
curl -sf http://localhost:8080/api/v1/health && echo " OK" || echo " НЕДОСТУПЕН"

echo "PostgreSQL (мозг):"
docker exec nocodb-postgres-db pg_isready && echo " OK" || echo " НЕДОСТУПЕН"

echo "Hermes (агент):"
curl -sf http://localhost:8082/health 2>/dev/null && echo " OK" || echo " НЕДОСТУПЕН (или ещё запускается)"
```

### 8.2 Проверка базы данных

```bash
echo "=== Проверка базы данных ==="
docker exec -it nocodb-postgres-db psql -U nocodb_user -d hermes_brain -c "
SELECT 
  (SELECT COUNT(*) FROM public.skills) AS skills_count,
  (SELECT COUNT(*) FROM public.handoff_documents) AS handoffs_count,
  (SELECT COUNT(*) FROM public.tenants) AS tenants_count;
"
```

### 8.3 Проверка MCP-подключений

```bash
echo "=== MCP-подключения ==="
hermes mcp list
```

## Шаг 9: Отчёт для пользователя

После завершения всех шагов, выведи подробный отчёт:

```
╔══════════════════════════════════════════════════════════════╗
║  Платформа "Студия программирования" 2.0 развёрнута!        ║
╚══════════════════════════════════════════════════════════════╝

ДОСТУПНЫЕ ВЕБ-ИНТЕРФЕЙСЫ:
  • NocoDB (приборная панель): http://localhost:8080
    - Создайте admin-аккаунт при первом входе
    - Здесь вы будете управлять задачами через Kanban-доски
    
  • Portainer (мониторинг): http://localhost:9000
    - Создайте admin-пароль при первом входе
    - Здесь вы увидите все запущенные сервисы

КОМПОНЕНТЫ:
  ✅ PostgreSQL 16 + pgvector + Apache AGE — мозг системы
  ✅ NocoDB — приборная панель для вас
  ✅ Hermes Agent — я, ваш AI-помощник
  ✅ OpenHands — внешний исполнитель для сложных задач
  ✅ Holix агенты — исполнители для рутинных задач

MCP-ПОДКЛЮЧЕНИЯ:
  ✅ hermes-brain — прямой доступ к базе знаний
  [?] stackoverflow — проверьте статус
  [?] github — проверьте статус

НАВЫКИ ЗАРЕГИСТРИРОВАНЫ:
  • dependency-update — еженедельное обновление пакетов
  • morning-triage — утренний разбор ошибок
  • flaky-test-fix — исправление нестабильных тестов
  • lint-and-fix — автофиксы стиля кода
  • pr-drafting — генерация PR из issue

ЧТО ДЕЛАТЬ ДАЛЬШЕ:
  1. Откройте http://localhost:8080 в браузере
  2. Создайте admin-аккаунт NocoDB
  3. Создайте проект "Studio" и подключитесь к базе hermes_brain
  4. Дайте мне первую задачу: "Hermes, создай Kanban-доску для задач"

ПОДДЕРЖКА:
  Если что-то не работает — спросите меня:
  "Hermes, проверь статус всех сервисов"
  "Hermes, почему NocoDB не открывается?"
  "Hermes, покажи логи за последний час"
```

## Что делать если что-то пошло не так

### Если Docker не запускается

```bash
sudo systemctl status docker
sudo systemctl restart docker
```

### Если PostgreSQL не готов

```bash
docker compose logs postgres-db | tail -20
```

### Если NocoDB не открывается

```bash
docker compose logs nocodb-app | tail -20
curl -v http://localhost:8080
```

### Если Hermes не подключается к MCP

```bash
hermes mcp list
hermes mcp test hermes-brain
docker compose logs hermes | tail -20
```

### Если нет интернета в контейнерах

```bash
docker exec hermes ping -c 3 api.deepseek.com
docker compose logs egress-proxy | tail -20
```

## Важные замечания

1. НЕ УДАЛЯЙ файл .env — в нём все пароли
2. НЕ ОСТАНАВЛИВАЙ сервисы без необходимости — `docker compose stop` остановит всё
3. ДЕЛАЙ BACKUP регулярно — `~/studio/scripts/backup.sh`
4. ЕСЛИ ЧТО-ТО СЛОМАЛОСЬ — спроси меня, я помогу
5. ПРИ КАЖДОЙ ПЕРЕЗАГРУЗКЕ VM — сервисы запустятся автоматически (если включён live-restore)

## Финальная инструкция пользователю

После успешного развёртывания скажи пользователю:

"Платформа готова! Вот что вы можете делать:

1. ОТКРОЙТЕ ПРИБОРНУЮ ПАНЕЛЬ: http://localhost:8080
   - Создайте admin-аккаунт
   - Это ваш интерфейс для управления задачами

2. ДАЙТЕ МНЕ ЗАДАЧУ — например:
   - 'Hermes, создай проект "Мой первый проект"'
   - 'Hermes, найди информацию о FastAPI JWT'
   - 'Hermes, обнови зависимости в репозитории X'

3. Я БУДУ РАБОТАТЬ АВТОНОМНО — могу:
   - Искать решения на Stack Overflow
   - Создавать Pull Request на GitHub
   - Обновлять зависимости
   - Исправлять ошибки в коде
   - Сохранять опыт для будущих задач

4. ЕСЛИ НУЖНА ПОМОЩЬ — просто спросите:
   - 'Hermes, покажи статус'
   - 'Hermes, объясни что делает X'
   - 'Hermes, помоги с Y'

Удачи!"
