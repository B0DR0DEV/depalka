# -*- coding: utf-8 -*-
"""
Бот Депости: продаёт донат и выдаёт промокоды.

Как работает:
  1. Друг пишет боту /start и выбирает донат.
  2. Бот пишет, как оплатить (текст из config.json), друг платит и жмёт «Я оплатил».
  3. Тебе (админу) приходит сообщение с кнопками «Выдать» и «Отказать».
  4. Жмёшь «Выдать» — бот отправляет другу следующий свободный промокод
     и ссылку, по которой он сразу активируется в игре.

Нужен только Python 3.9+ (никаких pip install). Запуск: python bot.py
Рядом с bot.py должен лежать codes.txt с промокодами (его нельзя выкладывать на GitHub).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(HERE, "token.txt")
CONFIG_FILE = os.path.join(HERE, "config.json")
STATE_FILE = os.path.join(HERE, "state.json")
CODES_FILE = os.path.join(HERE, "codes.txt")

DEFAULT_CONFIG = {
    "site_url": "https://b0dr0dev.github.io/depalka/",
    "channel_url": "https://t.me/depost_packs",
    "proxy": "",
    "payments_enabled": False,
    "pay_text": "Переведи деньги Роме (номер спроси у него лично) и нажми «Я оплатил».",
    "products": {
        "unlimited": {"title": "♾️ Безлимит навсегда", "price": "30 ₽",
                      "about": "Бесплатный кейс без лимита и с ×10."},
        "secretcase": {"title": "🗝️ Секретный кейс", "price": "20 ₽",
                       "about": "Скрытый кейс: только тайные и легенды из всех коллекций."},
        "secretskin": {"title": "🔪 Секретный скин", "price": "10 ₽",
                       "about": "«★ Золотой Karambit | Депость» сразу в инвентарь."},
    },
}


# ---------- файлы ----------
def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def load_codes():
    """codes.txt: секции [unlimited], [secretcase], [secretskin], по коду в строке."""
    codes, section = {}, None
    try:
        with open(CODES_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1]
                    codes.setdefault(section, [])
                elif section:
                    codes[section].append(line)
    except OSError:
        pass
    return codes


def get_token():
    token = os.environ.get("DEPOST_BOT_TOKEN", "").strip()
    if not token and os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, encoding="utf-8") as f:
            token = f.read().strip()
    if not token:
        print("Вставь токен бота из @BotFather и нажми Enter:")
        token = input("> ").strip()
        with open(TOKEN_FILE, "w", encoding="utf-8") as f:
            f.write(token)
    return token


# ---------- Telegram API ----------
TOKEN = None


def setup_proxy(cfg):
    """Прокси для Telegram (если в России api.telegram.org недоступен).
    Берётся из config.json ("proxy") или переменной HTTPS_PROXY. Нужен HTTP-прокси,
    например http://127.0.0.1:10809 — его даёт VPN-клиент (xray, sing-box)."""
    proxy = (cfg.get("proxy") or os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or "").strip()
    if proxy:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
        urllib.request.install_opener(opener)
        print(f"Telegram через прокси {proxy}")


def api(method, **params):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    data = json.dumps(params).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=70) as r:
            res = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        res = json.loads(e.read().decode("utf-8") or "{}")
    if not res.get("ok"):
        print(f"[!] {method}: {res.get('description')}")
    return res.get("result")


def send(chat_id, text, buttons=None):
    params = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
    if buttons:
        params["reply_markup"] = {"inline_keyboard": buttons}
    return api("sendMessage", **params)


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ---------- логика ----------
def menu(cfg):
    rows = [[{"text": f"{p['title']} — {p['price']}", "callback_data": f"buy:{k}"}]
            for k, p in cfg["products"].items()]
    rows.append([{"text": "🎮 Играть", "url": cfg["site_url"]}])
    if cfg.get("channel_url"):
        rows.append([{"text": "📦 Паки в канале", "url": cfg["channel_url"]}])
    return rows


def user_label(u):
    name = " ".join(x for x in [u.get("first_name"), u.get("last_name")] if x)
    return f"{esc(name)} (@{esc(u['username'])})" if u.get("username") else esc(name)


def handle_message(msg, cfg, state):
    chat_id = msg["chat"]["id"]
    text = (msg.get("text") or "").strip()
    user = msg.get("from", {})
    is_admin = state.get("admin_id") == user.get("id")

    if text.startswith("/iamadmin"):
        if state.get("admin_id"):
            send(chat_id, "Админ уже назначен.")
        else:
            state["admin_id"] = user["id"]
            send(chat_id, "✅ Теперь ты админ. Сюда будут приходить заявки на донат.\n"
                          "Команды: /left — сколько кодов осталось.")
        return
    if text.startswith("/left") and is_admin:
        codes, given = load_codes(), set(state.get("given", {}))
        lines = [f"{cfg['products'].get(k, {}).get('title', k)}: {sum(c not in given for c in v)}"
                 for k, v in codes.items()]
        send(chat_id, "Осталось кодов:\n" + ("\n".join(lines) or "codes.txt не найден"))
        return
    if text.startswith("/myid"):
        send(chat_id, f"Твой id: <code>{user.get('id')}</code>")
        return
    send(chat_id, "Это бот <b>Депости</b> 🎰\nТут можно купить донат для игры. "
                  "Монеты, предметы и донат вывести обратно в деньги нельзя.\n\nВыбирай:",
         menu(cfg))


def handle_callback(cb, cfg, state):
    api("answerCallbackQuery", callback_query_id=cb["id"])
    data = cb.get("data", "")
    user = cb["from"]
    chat_id = cb["message"]["chat"]["id"]
    admin = state.get("admin_id")

    if data.startswith("buy:"):
        k = data[4:]
        p = cfg["products"].get(k)
        if not p:
            return
        if not cfg.get("payments_enabled", False):
            back = [[{"text": "📦 Наш канал", "url": cfg["channel_url"]}]] if cfg.get("channel_url") else []
            send(chat_id, f"<b>{p['title']}</b> — {p['price']}\n{esc(p['about'])}\n\n"
                          "⏳ Оплата временно не работает. Скоро включим, следи за новостями в канале.",
                 back + [[{"text": "← Назад", "callback_data": "menu"}]])
            return
        send(chat_id, f"<b>{p['title']}</b> — {p['price']}\n{esc(p['about'])}\n\n{esc(cfg['pay_text'])}",
             [[{"text": "✅ Я оплатил", "callback_data": f"paid:{k}"}],
              [{"text": "← Назад", "callback_data": "menu"}]])
    elif data == "menu":
        send(chat_id, "Выбирай:", menu(cfg))
    elif data.startswith("paid:"):
        k = data[5:]
        p = cfg["products"].get(k)
        if not p:
            return
        if not cfg.get("payments_enabled", False):
            send(chat_id, "⏳ Оплата временно не работает. Скоро включим.")
            return
        if not admin:
            send(chat_id, "Админ ещё не настроил бота. Напиши Роме напрямую.")
            return
        state["next_id"] = state.get("next_id", 0) + 1
        rid = str(state["next_id"])
        state.setdefault("requests", {})[rid] = {"user_id": user["id"], "chat_id": chat_id,
                                                  "perk": k, "who": user_label(user), "t": int(time.time())}
        send(chat_id, "👍 Заявка отправлена. Как только Рома проверит оплату, бот пришлёт промокод.")
        send(admin, f"💰 Заявка #{rid}\n{user_label(user)} оплатил: <b>{p['title']}</b> — {p['price']}",
             [[{"text": "✅ Выдать", "callback_data": f"give:{rid}"},
               {"text": "❌ Отказать", "callback_data": f"deny:{rid}"}]])
    elif data.startswith(("give:", "deny:")):
        if user["id"] != admin:
            return
        rid = data[5:]
        req = state.get("requests", {}).pop(rid, None)
        if not req:
            send(chat_id, f"Заявка #{rid} уже обработана.")
            return
        p = cfg["products"].get(req["perk"], {"title": req["perk"]})
        if data.startswith("deny:"):
            send(req["chat_id"], f"❌ Оплата за «{p['title']}» не подтвердилась. Напиши Роме, если это ошибка.")
            send(chat_id, f"Заявка #{rid} отклонена.")
            return
        given = state.setdefault("given", {})
        code = next((c for c in load_codes().get(req["perk"], []) if c not in given), None)
        if not code:
            state["requests"][rid] = req
            send(chat_id, f"⚠️ Закончились коды для «{p['title']}». Попроси Claude сделать ещё и положи их в codes.txt.")
            return
        given[code] = {"user_id": req["user_id"], "who": req["who"], "t": int(time.time())}
        link = cfg["site_url"].rstrip("/") + "/?code=" + urllib.parse.quote(code)
        send(req["chat_id"],
             f"🎉 <b>{p['title']}</b>\nТвой промокод: <code>{code}</code>\n\n"
             f"Нажми кнопку ниже, и он активируется сам. Открой ссылку в том же браузере, где играешь. "
             f"Если не сработало, введи код вручную: «Ещё» → «Донат».",
             [[{"text": "🎮 Активировать в игре", "url": link}]])
        send(chat_id, f"✅ Заявка #{rid}: код {code} отправлен {req['who']}.")


def main():
    global TOKEN
    TOKEN = get_token()
    cfg = load_json(CONFIG_FILE, None)
    if not cfg:
        cfg = DEFAULT_CONFIG
        save_json(CONFIG_FILE, cfg)
    state = load_json(STATE_FILE, {})
    setup_proxy(cfg)
    me = api("getMe")
    if not me:
        print("Не получилось подключиться к Telegram. Проверь токен (token.txt) и прокси/VPN.")
        sys.exit(1)
    if not load_codes():
        print("[!] Рядом с bot.py нет codes.txt — бот не сможет выдавать коды.")
    print(f"Бот @{me['username']} запущен. Не закрывай это окно. Остановить: Ctrl+C")
    if not state.get("admin_id"):
        print(f"Чтобы стать админом, напиши боту @{me['username']} команду /iamadmin")
    offset = state.get("offset", 0)
    while True:
        try:
            updates = api("getUpdates", offset=offset, timeout=50,
                          allowed_updates=["message", "callback_query"]) or []
            for u in updates:
                offset = u["update_id"] + 1
                try:
                    if "message" in u:
                        handle_message(u["message"], cfg, state)
                    elif "callback_query" in u:
                        handle_callback(u["callback_query"], cfg, state)
                except Exception as e:  # одна кривая заявка не должна ронять бота
                    print(f"[!] Ошибка в обработке: {e!r}")
                state["offset"] = offset
                save_json(STATE_FILE, state)
        except KeyboardInterrupt:
            print("Бот остановлен.")
            break
        except Exception as e:
            print(f"[!] Нет связи с Telegram ({e!r}), пробую снова через 5 секунд…")
            time.sleep(5)


if __name__ == "__main__":
    main()
