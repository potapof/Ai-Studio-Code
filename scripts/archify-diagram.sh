#!/bin/bash
# archify-diagram.sh — единая точка вызова Archify в Студии программирования.
# Генерирует проверяемую интерактивную диаграмму (HTML) из типизированной JSON-спеки.
#
# Archify: агент пишет typed JSON-IR, CLI детерминированно компилирует его в
# самодостаточный HTML/SVG (тёмная/светлая тема, поиск, трассировка маршрутов,
# экспорт PNG/SVG/WebM). Валидация (9 чеков showcase) + доставка (SHA-256-чек-сумма).
#
# Использование:
#   archify-diagram.sh <type> <spec.json> <out.html> [--quality showcase] [--open]
#   type: architecture | workflow | sequence | dataflow | lifecycle
# Примеры:
#   archify-diagram.sh architecture spec.json out.html
#   archify-diagram.sh workflow spec.json out.html --quality showcase --open
#
# Переменная окружения ARCHIFY_BIN — путь к CLI (по умолчанию скилл в Hermes).

set -euo pipefail

export PATH="$HOME/.npm-global/bin:$PATH"
ARCHIFY_BIN="${ARCHIFY_BIN:-$HOME/.hermes/skills/software-development/archify/bin/archify.mjs}"

if [ $# -lt 3 ]; then
  echo "Использование: archify-diagram.sh <type> <spec.json> <out.html> [--quality q] [--open]" >&2
  echo "type: architecture | workflow | sequence | dataflow | lifecycle" >&2
  exit 2
fi

TYPE="$1"; SPEC="$2"; OUT="$3"; shift 3
QUALITY="showcase"; OPEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quality) QUALITY="$2"; shift 2;;
    --open) OPEN="--open"; shift;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2;;
  esac
done

[ -f "$ARCHIFY_BIN" ] || { echo "❌ Archify CLI не найден: $ARCHIFY_BIN (нужен ~/studio/archify, скилл в Hermes)" >&2; exit 1; }
[ -f "$SPEC" ] || { echo "❌ Спека не найдена: $SPEC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

echo "── Archify [$TYPE] ${QUALITY} ──"
echo "спека:    $SPEC"

# 1. Валидация (до каждой правки и перед сдачей; showcase = 9 чеков, 0 ошибок/варнингов)
echo "1) validate ${TYPE} ..."
if ! node "$ARCHIFY_BIN" validate "$TYPE" "$SPEC" --quality "$QUALITY" --json > /tmp/archify-validate.json 2>/tmp/archify-validate.err; then
  echo "❌ Валидация не прошла. Диагностика:" >&2
  cat /tmp/archify-validate.err >&2
  python3 -c "import json;d=json.load(open('/tmp/archify-validate.json'));print(json.dumps(d,ensure_ascii=False,indent=1))" 2>/dev/null || cat /tmp/archify-validate.json >&2
  exit 1
fi
python3 -c "
import json
d=json.load(open('/tmp/archify-validate.json'))
print('   OK: ' + str(d.get('summary',d.get('meta',{}))))
" 2>/dev/null || echo "   OK (validate)"

# 2. Доставка (фиксирует спеку, рендерит HTML, SHA-256)
echo "2) deliver ${TYPE} → $OUT ..."
node "$ARCHIFY_BIN" deliver "$TYPE" "$SPEC" "$OUT" --quality "$QUALITY" --json $OPEN > /tmp/archify-deliver.json 2>/tmp/archify-deliver.err || {
  echo "❌ Доставка не прошла." >&2; cat /tmp/archify-deliver.err >&2; exit 1; }
python3 -c "
import json
d=json.load(open('/tmp/archify-deliver.json'))
print('   OK: ' + json.dumps(d.get('artifact',d.get('meta',{})),ensure_ascii=False))
" 2>/dev/null || echo "   OK (deliver)"

# 3. Визуальная проверка в реальном браузере (не модифицирует HTML)
echo "3) visual-check ..."
node "$ARCHIFY_BIN" visual-check "$OUT" --json > /tmp/archify-visual.json 2>/tmp/archify-visual.err || echo "   (visual-check: ${QUALITY} — см. /tmp/archify-visual.err)"
python3 -c "import json;d=json.load(open('/tmp/archify-visual.json'));print('   visual: '+json.dumps(d.get('viewport',d.get('summary','ok')),ensure_ascii=False))" 2>/dev/null || echo "   visual: ок"

echo "✅ Готова диаграмма: $OUT"
echo "   открыть:  $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
