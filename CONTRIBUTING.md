# Contributing

«Студия программирования» — персональная система одного разработчика, но pull requests, bug reports и feature requests приветствуются.

## Кодекс поведения

Участие в проекте подразумевает уважительное отношение к другим контрибьюторам. Деструктивное поведение не допускается.

## Как сообщить о баге

Перед созданием issue проверьте [existing issues](../../issues). Если уже есть — добавьте комментарий с деталями воспроизведения.

**Шаблон bug report:**

```markdown
**Описание бага**
Краткое описание проблемы.

**Шаги для воспроизведения**
1. Запустите '...'
2. Выполните '...'
3. Увидьте ошибку

**Ожидаемое поведение**
Что должно было произойти.

**Фактическое поведение**
Что произошло.

**Окружение**
- ОС хоста: [Windows 10 Pro 21H2]
- Версия VirtualBox: [7.2.0]
- Версия Linux Mint: [22 Cinnamon]
- Версия PostgreSQL: [16.x]
- Версия Apache AGE: [1.5.0]
- Версия Hermes Agent: [0.16+]
- Версия «Студии»: [2.0.0]

**Логи**
Вставьте соответствующие логи из `docker compose logs <service>` (максимум 50 строк).
Удалите секреты перед публикацией!
```

## Как предложить улучшение

Feature requests приветствуются. Перед созданием issue обсудите идею в [Discussions](../../discussions).

## Процесс разработки

### 1. Fork и clone

```bash
git clone https://github.com/<your-username>/studio-docs.git
cd studio-docs
git remote add upstream https://github.com/<original>/studio-docs.git
```

### 2. Создайте ветку

```bash
git checkout -b feature/my-feature
# или
git checkout -b fix/issue-123
```

### 3. Внесите изменения

Следуйте стилям проекта:
- **Markdown:** Russian для основного текста, English для кода
- **YAML:** 2 пробела для отступов, без tabs
- **Bash:** `#!/usr/bin/env bash`, `set -euo pipefail`, Russian комментарии
- **SQL:** lowercase для ключевых слов, uppercase для имён таблиц

### 4. Протестируйте изменения

```bash
# YAML валидность
for f in examples/configs/*.yaml; do python -c "import yaml; yaml.safe_load(open('$f'))" || echo "INVALID: $f"; done

# JSON валидность
for f in examples/mcp/*.json; do python -m json.tool "$f" > /dev/null || echo "INVALID: $f"; done

# Bash синтаксис
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR: $f"; done

# Проверка на эмодзи (проект не использует их)
grep -rnP '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{1F000}-\x{1F0FF}\x{2B00}-\x{2BFF}]' . \
  --include='*.md' --include='*.yaml' --include='*.json' --include='*.sh' --include='*.py' --include='*.sql'
```

### 5. Сделайте commit

Используйте [Conventional Commits](https://www.conventionalcommits.org/):

```bash
git commit -m "feat: add SOA integration with OAuth 2.1"
git commit -m "fix: correct AGE Cypher syntax in code_graph"
git commit -m "docs: add Firecracker setup guide"
git commit -m "security: enable first-invoke approval for all MCP"
git commit -m "breaking: migrate from NocoDB brain to PostgreSQL+pgvector+AGE"
```

### 6. Push и создайте PR

```bash
git push origin feature/my-feature
```

## Стандарты кода

### SQL (для конвергентной БД)

```sql
-- lowercase для ключевых слов
SELECT id, name, embedding FROM public.skills
WHERE status = 'approved'
  AND tenant_id = 'default'
ORDER BY embedding <=> $1::vector
LIMIT 5;

-- COMMENT для всех таблиц
COMMENT ON TABLE public.skills IS 'Библиотека навыков Hermes Agent';
COMMENT ON COLUMN public.skills.embedding IS 'Вектор 384 dim (all-MiniLM-L6-v2)';

-- Идемпотентность
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS ...;
CREATE INDEX IF NOT EXISTS ...;
```

### Cypher (для Apache AGE)

```sql
-- Использовать разные теги для избежания конфликта $$
SELECT * FROM ag_catalog.cypher('code_graph', $cy$
    MATCH (s:Microservice)-[:DEPENDS_ON]->(l:Library)
    RETURN s.name, l.name
$cy$) AS (service agtype, library agtype);
```

### YAML (для конфигов)

```yaml
# 2 пробела для отступов
mcp_client:
  - name: hermes-brain
    transport: stdio
    first_invoke_approval: true  # важный комментарий
```

## Релизы

Релизы выходят по мере готовности. Каждый релиз:
1. Обновляется `CHANGELOG.md`
2. Создаётся git tag `vX.Y.Z`
3. Создаётся GitHub Release
4. Обновляется `docker-compose.yml` с новыми версиями образов

## Лицензия

Участвуя в проекте, вы соглашаетесь, что ваш вклад будет лицензирован под [MIT License](LICENSE).
