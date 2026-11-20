# -*- coding: utf-8 -*-
"""Собирает файл-обновление для Supabase: только то, что поменялось после указанной версии.

Запуск из корня репозитория:
  python online/build_update.py <коммит-с-которого> <итоговый.sql> [promo.sql]

Берёт из online/economy.sql только новые таблицы/колонки и изменённые функции,
добавляет весь каталог (он безопасно перезаписывается) и заново раздаёт права.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
base, out = sys.argv[1], sys.argv[2]
promo = open(sys.argv[3], encoding="utf-8").read() if len(sys.argv) > 3 else ""

new = open(os.path.join(ROOT, "online", "economy.sql"), encoding="utf-8").read()
old = subprocess.run(["git", "-C", ROOT, "show", f"{base}:online/economy.sql"], capture_output=True, text=True, check=True).stdout


def funcs(sql):
    """имя функции → её полный текст (create or replace function … end $$; или … $$;)"""
    res = {}
    for m in re.finditer(r"create or replace function public\.(\w+)\(.*?\$\$;\n", sql, re.S):
        res[m.group(1)] = m.group(0)
    return res


fo, fn = funcs(old), funcs(new)
changed = [name for name in fn if fo.get(name) != fn[name]]

# новые таблицы и колонки (все DDL у нас идемпотентные: if not exists)
ddl = []
for m in re.finditer(r"(create table if not exists public\.\w+ \([^;]*\);\n|alter table public\.\w+ (?:add|drop) [^\n]*;\n|create (?:unique )?index if not exists [^\n]*;\n)", new, re.S):
    if m.group(0) not in old:
        ddl.append(m.group(0))
new_tables = re.findall(r"create table if not exists public\.(\w+)", "".join(ddl))

# блок, который закрывает таблицы и раздаёт права (запускаем заново, чтобы новые функции не были открыты всем)
grants = new[new.index("-- доступ: сайт может вызывать только api_*"):]
grants = "-- ======================================================================\n" + grants

parts = [
    f"-- Депость: обновление сервера (только изменения после версии {base}). Можно запускать повторно.\n",
    "-- новые таблицы и колонки\n" + "".join(ddl),
]
if new_tables:
    parts.append("do $$ declare t text; begin\n  foreach t in array array[" + ",".join(f"'{t}'" for t in new_tables) + "] loop\n"
                 "    execute format('alter table public.%I enable row level security', t);\n"
                 "    execute format('revoke all on public.%I from anon, authenticated', t);\n  end loop;\nend $$;\n")
parts.append("-- изменённые и новые функции: " + ", ".join(changed) + "\n" + "\n".join(fn[n] for n in changed))
parts.append(open(os.path.join(ROOT, "online", "catalog.sql"), encoding="utf-8").read())
if promo:
    parts.append(promo)
parts.append(grants)
open(out, "w", encoding="utf-8").write("\n".join(parts))
print("функций:", len(changed), changed, "| новых таблиц/колонок:", len(ddl))
