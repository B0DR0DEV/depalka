# -*- coding: utf-8 -*-
"""Собирает online/catalog.sql (предметы и кейсы), online/install.sql (всё вместе) и packs/index.json.

Запуск из корня репозитория:  python online/build_catalog.py  [promo.sql  итоговый.sql]
Каталог берётся из того же, что видит игра: memes/manifest.json, packs/*/pack.json,
кейсы и скины CS2 из index.html. Потом catalog.sql нужно запустить в Supabase → SQL Editor
(например, после добавления нового пака).
"""
import glob
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
html = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()


def q(s):
    return "'" + str(s).replace("'", "''") + "'"


items, cases = [], []

# мемы из memes/manifest.json
man = json.load(open(os.path.join(ROOT, "memes", "manifest.json"), encoding="utf-8"))
for e in man["items"]:
    items.append(("m:" + e["file"], e["name"], int(e["rarity"]), e.get("set") or "mell"))

# скины CS2 из index.html
cs_list = json.loads(re.search(r"const CSITEMS=(\[\[.*?\]\])\.map", html, re.S).group(1))
for i, (name, r) in enumerate(cs_list):
    items.append((f"cs{i}", name, int(r), "cs"))

# особые предметы
items.append(("gold-karambit", "★ Золотой Karambit | Депость", 4, "special"))
items.append(("sub-badge", "📢 Подписчик Депости", 3, "special"))

# кейсы из index.html
case_block = re.search(r"const CASES=\[(.*?)\n\];", html, re.S).group(1)
for line in case_block.strip().splitlines():
    m = re.search(r"id:'([^']+)',name:'([^']+)',price:(\d+),w:\[([\d,]+)\]", line)
    if not m:
        continue
    mult = re.search(r"mult:([\d.]+)", line)
    st = re.search(r"set:'([^']+)'", line)
    perk = re.search(r"perk:'([^']+)'", line)
    cases.append((m.group(1), m.group(2), int(m.group(3)), [int(x) for x in m.group(4).split(",")],
                  float(mult.group(1)) if mult else 1, st.group(1) if st else "mell", perk.group(1) if perk else None))

# паки из packs/*/pack.json
for pj in sorted(glob.glob(os.path.join(ROOT, "packs", "*", "pack.json"))):
    pk = json.load(open(pj, encoding="utf-8"))
    pid = re.sub(r"[^a-zA-Z0-9_-]", "", str(pk["id"]))[:32]
    for x in pk["items"]:
        items.append((f"pk:{pid}:{x['file']}", str(x.get("name") or x["file"])[:40], max(0, min(4, int(x.get("rarity", 0)))), "pk:" + pid))
    w = pk.get("weights") if isinstance(pk.get("weights"), list) and len(pk.get("weights")) == 5 else [45, 30, 15, 7, 3]
    cases.append(("pk-" + pid, str(pk.get("name") or pid)[:30], max(0, int(pk.get("price") or 0)), [int(v) for v in w],
                  float(pk.get("mult") or 1), "pk:" + pid, None))

# список паков для игры (игра сама грузит все паки из этого списка)
pack_ids = [os.path.basename(os.path.dirname(pj)) for pj in sorted(glob.glob(os.path.join(ROOT, "packs", "*", "pack.json")))]
json.dump({"packs": pack_ids}, open(os.path.join(ROOT, "packs", "index.json"), "w", encoding="utf-8"), ensure_ascii=False)

out = ["-- Каталог Депости: предметы и кейсы. Сгенерировано build_catalog.py. Можно запускать повторно.",
       "insert into public.catalog_items(id, name, rarity, set) values"]
out.append(",\n".join(f"  ({q(i)}, {q(n)}, {r}, {q(s)})" for i, n, r, s in items))
out.append("on conflict (id) do update set name = excluded.name, rarity = excluded.rarity, set = excluded.set;")
out.append("update public.catalog_cases set active = false;")
out.append("insert into public.catalog_cases(id, name, price, weights, mult, set, perk, active) values")
out.append(",\n".join(f"  ({q(i)}, {q(n)}, {p}, array{w}, {m}, {q(s)}, {q(pk) if pk else 'null'}, true)" for i, n, p, w, m, s, pk in cases))
out.append("on conflict (id) do update set name = excluded.name, price = excluded.price, weights = excluded.weights, mult = excluded.mult, set = excluded.set, perk = excluded.perk, active = true;")
catalog = "\n".join(out) + "\n"
open(os.path.join(ROOT, "online", "catalog.sql"), "w", encoding="utf-8").write(catalog)

econ = open(os.path.join(ROOT, "online", "economy.sql"), encoding="utf-8").read()
open(os.path.join(ROOT, "online", "install.sql"), "w", encoding="utf-8").write(econ + "\n\n" + catalog)
# полный файл для Supabase вместе с промокодами (промокоды лежат отдельно и в репозиторий не попадают)
import sys
if len(sys.argv) == 3:
    promo = open(sys.argv[1], encoding="utf-8").read()
    open(sys.argv[2], "w", encoding="utf-8").write(econ + "\n\n" + catalog + "\n" + promo)
print(f"предметов: {len(items)}, кейсов: {len(cases)}, паков: {len(pack_ids)}")
