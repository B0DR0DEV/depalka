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
    "channel_id": "@depost_packs",
    "supabase_url": "https://igsgzujaduifeuqvjpmr.supabase.co",
    "supabase_key": "sb_publishable_yfZAX37cHmnx4TB73GDqlg_1M8R-Lyo",
    "sub_secret": "",
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


# ---------- плюшки за подписку на канал ----------
SUB_TEXT = {
    "ok": "🎉 Готово! Плюшки уже в игре: 5 000 монет, мем «📢 Подписчик Депости», кейс «Для своих» "
          "и +50% к бонусу за вход.\n\nВернись в браузер, где играешь, — там всё появится.",
    "already": "Плюшки за подписку на этот аккаунт уже получены 👍",
    "tg_used": "С этого Telegram плюшки уже забирали на другой аккаунт игры. Один Telegram — одни плюшки.",
    "bad_token": "Ссылка устарела. Открой в игре «Подпишись на канал» и нажми кнопку ещё раз.",
}


def check_sub(chat_id, user, token, cfg):
    """Бот должен быть админом канала, иначе Telegram не скажет, подписан ли человек."""
    import re
    if not re.fullmatch(r"sub_[0-9a-f]{8,40}", token):
        return send(chat_id, SUB_TEXT["bad_token"])
    m = api("getChatMember", chat_id=cfg.get("channel_id") or DEFAULT_CONFIG["channel_id"], user_id=user["id"])
    if not m:
        return send(chat_id, "⚠️ Бот не может проверить подписку: его нужно сделать админом канала. Напиши Роме.")
    st = m.get("status")
    if not (st in ("creator", "administrator", "member") or (st == "restricted" and m.get("is_member"))):
        return send(chat_id, "Ты пока не подписан на канал. Подпишись и нажми «Я подписался».",
                    [[{"text": "📢 Подписаться", "url": cfg.get("channel_url") or DEFAULT_CONFIG["channel_url"]}],
                     [{"text": "✅ Я подписался", "callback_data": "sub:" + token}]])
    secret = cfg.get("sub_secret") or ""
    if not secret:
        return send(chat_id, "⚠️ Бот ещё не настроен (нет sub_secret в config.json). Напиши Роме.")
    try:
        res = game_rpc(cfg, "bot_sub_confirm", {"token": token, "tg_id": user["id"]})
    except Exception as e:
        print(f"[!] Плюшки за подписку: {e!r}")
        return send(chat_id, "⚠️ Не получилось связаться с игрой. Попробуй чуть позже.")
    return send(chat_id, SUB_TEXT.get(res.get("status"), "Что-то пошло не так, попробуй ещё раз."))


def game_rpc(cfg, fn, params):
    url = (cfg.get("supabase_url") or DEFAULT_CONFIG["supabase_url"]).rstrip("/") + "/rest/v1/rpc/" + fn
    key = cfg.get("supabase_key") or DEFAULT_CONFIG["supabase_key"]
    body = json.dumps({"p": {"secret": cfg.get("sub_secret") or "", **params}}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={"apikey": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def handle_chat_member(upd, cfg):
    """Человек вышел из канала — игра забирает плюшки за подписку."""
    chat = upd.get("chat", {})
    want = str(cfg.get("channel_id") or DEFAULT_CONFIG["channel_id"]).lstrip("@").lower()
    if str(chat.get("username") or "").lower() != want and str(chat.get("id")) != want:
        return
    nm = upd.get("new_chat_member", {})
    user = nm.get("user", {})
    st = nm.get("status")
    if st in ("creator", "administrator", "member") or (st == "restricted" and nm.get("is_member")):
        return
    if not user.get("id") or user.get("is_bot") or not cfg.get("sub_secret"):
        return
    try:
        res = game_rpc(cfg, "bot_sub_revoke", {"tg_id": user["id"]})
    except Exception as e:
        print(f"[!] Не получилось забрать плюшки: {e!r}")
        return
    if res.get("status") == "revoked":
        send(user["id"], "😢 Ты отписался от канала, поэтому плюшки за подписку забрали: монеты, мем «📢 Подписчик», "
                         "кейс «Для своих» и бонус к ежедневке.\n\nПодпишись снова и нажми в игре «Подпишись на канал», "
                         "чтобы всё вернуть.",
             [[{"text": "📢 Подписаться снова", "url": cfg.get("channel_url") or DEFAULT_CONFIG["channel_url"]}]])


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
    if text.startswith("/start sub_"):
        check_sub(chat_id, user, text[7:].strip(), cfg)
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

    if data.startswith("sub:"):
        check_sub(chat_id, user, data[4:], cfg)
        return
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
                          allowed_updates=["message", "callback_query", "chat_member"]) or []
            for u in updates:
                offset = u["update_id"] + 1
                try:
                    if "message" in u:
                        handle_message(u["message"], cfg, state)
                    elif "callback_query" in u:
                        handle_callback(u["callback_query"], cfg, state)
                    elif "chat_member" in u:
                        handle_chat_member(u["chat_member"], cfg)
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
