#!/bin/bash
# sync-skills.sh — синхронизация навыков из Git в PostgreSQL
#
# Читает все skills/*/SKILL.md и загружает в hermes_brain.skills.
# Используется при развёртывании на новом ПК и после git pull.
#
# Принцип: Git — источник истины, PostgreSQL — оперативный кэш с RAG-поиском.

SKILLS_DIR="$(cd "$(dirname "$0")/.." && pwd)/skills"
DB_USER="${DB_USER:-nocodb_user}"
DB_NAME="${DB_NAME:-hermes_brain}"

# Маппинг: имя навыка → skill_type + category
declare -A SKILL_TYPE=(
  ["deploy-studio"]="procedural"
  ["morning-triage"]="loop"
  ["pr-drafting"]="handoff"
  ["flaky-test-fix"]="loop"
  ["lint-and-fix"]="loop"
  ["dependency-update"]="loop"
)
declare -A SKILL_CATEGORY=(
  ["deploy-studio"]="devops"
  ["morning-triage"]="devops"
  ["pr-drafting"]="devops"
  ["flaky-test-fix"]="qa"
  ["lint-and-fix"]="qa"
  ["dependency-update"]="devops"
)
DEFAULT_TYPE="procedural"
DEFAULT_CATEGORY="general"

synced=0
errors=0

echo "=== Синхронизация навыков ==="
echo "Источник: $SKILLS_DIR"
echo "База:     $DB_USER@postgres/$DB_NAME"
echo ""

for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  skill_name=$(basename "$(dirname "$skill_md")")
  echo -n "  [$skill_name] "

  # YAML frontmatter между --- и ---
  yaml=$(sed -n '/^---$/,/^---$/p' "$skill_md" | sed '1d;$d')
  description=$(echo "$yaml" | grep '^description:' | head -1 | sed 's/^description:\s*//;s/^"//;s/"$//')
  [ -z "$description" ] && description="$skill_name"

  skill_type="${SKILL_TYPE[$skill_name]:-$DEFAULT_TYPE}"
  category="${SKILL_CATEGORY[$skill_name]:-$DEFAULT_CATEGORY}"

  # Контент (экранируем одинарные кавычки для SQL)
  content=$(sed "s/'/''/g" "$skill_md")
  desc_esc=$(echo "$description" | sed "s/'/''/g")
  name_esc=$(echo "$skill_name" | sed "s/'/''/g")

  # Сначала проверяем — существует ли навык
  exists=$(docker exec nocodb-postgres-db psql -U "$DB_USER" -d "$DB_NAME" -t -A \
    -c "SELECT 1 FROM public.skills WHERE name = '$name_esc';" 2>/dev/null)

  if [ "$exists" = "1" ]; then
    # Обновить существующий
    docker exec nocodb-postgres-db psql -U "$DB_USER" -d "$DB_NAME" -c \
      "UPDATE public.skills SET
         description = '$desc_esc',
         content_markdown = '$content',
         skill_type = '$skill_type',
         category = '$category',
         version = version + 1,
         updated_at = NOW()
       WHERE name = '$name_esc';" >/dev/null 2>&1 || { echo "❌ ошибка"; ((errors++)); continue; }
    ver=$(docker exec nocodb-postgres-db psql -U "$DB_USER" -d "$DB_NAME" -t -A \
      -c "SELECT version FROM public.skills WHERE name = '$name_esc';" 2>/dev/null)
    echo "🔄 обновлён (v$ver)"
  else
    # Добавить новый
    docker exec nocodb-postgres-db psql -U "$DB_USER" -d "$DB_NAME" -c \
      "INSERT INTO public.skills (name, description, content_markdown, skill_type, category, source, status)
       VALUES ('$name_esc', '$desc_esc', '$content', '$skill_type', '$category', 'manual', 'approved');" \
      >/dev/null 2>&1 || { echo "❌ ошибка"; ((errors++)); continue; }
    echo "✅ добавлен (v1)"
  fi
  ((synced++))
done

echo ""
echo "=== Готово: $synced синхронизировано, $errors ошибок ==="
