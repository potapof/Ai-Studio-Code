# studio-postgres: PostgreSQL 16 + pgvector + Apache AGE
# Multi-stage БЕЗ apt (обходит egress-фильтр к debian-репо):
#   база = pgvector/pgvector:pg16 (bookworm, PG16.14, совпадает с текущими данными; vector нативный)
#   age.so + extension копируются из apache/age:release_PG16_1.5.0 (тоже bookworm, glibc-совместим: age.so требует лишь GLIBC_2.17)
# Проверено: trixie-версия 1.6.0 несовместима (требует GLIBC_2.38), поэтому берём bookworm 1.5.0.
FROM pgvector/pgvector:pg16

COPY --from=apache/age:release_PG16_1.5.0 /usr/lib/postgresql/16/lib/age.so \
     /usr/lib/postgresql/16/lib/age.so
COPY --from=apache/age:release_PG16_1.5.0 /usr/share/postgresql/16/extension/age.control \
     /usr/share/postgresql/16/extension/age.control
COPY --from=apache/age:release_PG16_1.5.0 /usr/share/postgresql/16/extension/age--1.5.0.sql \
     /usr/share/postgresql/16/extension/age--1.5.0.sql
