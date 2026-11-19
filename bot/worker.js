// Бот Депости для Cloudflare Workers (бесплатно, без VPN и без своего сервера).
// Инструкция: bot/CLOUDFLARE.md
//
// Нужно в настройках Worker'а:
//   • Secret  BOT_TOKEN — токен из @BotFather
//   • KV-привязка с именем DB — тут бот хранит админа, заявки и выданные коды

// ===== НАСТРОЙКИ =====
const CONFIG = {
  // false — оплата временно выключена: бот показывает донат, но пишет, что оплата не работает.
  // Включить: поставь true и нажми Deploy.
  payments_enabled: false,
  site_url: "https://b0dr0dev.github.io/depalka/",
  channel_url: "https://t.me/depost_packs",
  pay_text: "Переведи деньги Роме (номер спроси у него лично) и нажми «Я оплатил».",
  products: {
    unlimited: { title: "♾️ Безлимит навсегда", price: "30 ₽", about: "Бесплатный кейс без лимита и с ×10." },
    secretcase: { title: "🗝️ Секретный кейс", price: "20 ₽", about: "Скрытый кейс: только тайные и легенды из всех коллекций." },
    secretskin: { title: "🔪 Секретный скин", price: "10 ₽", about: "«★ Золотой Karambit | Депость» сразу в инвентарь." },
  },
};

// ===== ПРОМОКОДЫ =====
// Вставь сюда содержимое codes.txt (секции [unlimited], [secretcase], [secretskin]).
// Код Worker'а виден только тебе в панели Cloudflare. В GitHub эту версию с кодами не загружай.
const CODES = `__CODES__`;

// ===== дальше можно не трогать =====
const parseCodes = () => {
  const out = {}; let sec = null;
  for (let line of CODES.split("\n")) {
    line = line.trim();
    if (!line || line.startsWith("#")) continue;
    const m = line.match(/^\[(.+)\]$/);
    if (m) { sec = m[1]; out[sec] = out[sec] || []; } else if (sec) out[sec].push(line);
  }
  return out;
};
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

async function sha(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function api(env, method, params) {
  const r = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(params),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.ok) console.log(method, j.description);
  return j;
}
const send = (env, chat_id, text, buttons) =>
  api(env, "sendMessage", {
    chat_id, text, parse_mode: "HTML", disable_web_page_preview: true,
    ...(buttons ? { reply_markup: { inline_keyboard: buttons } } : {}),
  });

const kvJson = async (env, key, def) => { try { return JSON.parse((await env.DB.get(key)) || "null") ?? def; } catch { return def; } };
const label = (u) => { const n = esc([u.first_name, u.last_name].filter(Boolean).join(" ")); return u.username ? `${n} (@${esc(u.username)})` : n; };

function menu() {
  const rows = Object.entries(CONFIG.products).map(([k, p]) => [{ text: `${p.title} — ${p.price}`, callback_data: `buy:${k}` }]);
  rows.push([{ text: "🎮 Играть", url: CONFIG.site_url }]);
  if (CONFIG.channel_url) rows.push([{ text: "📦 Паки в канале", url: CONFIG.channel_url }]);
  return rows;
}

async function onMessage(env, msg) {
  const chat = msg.chat.id, user = msg.from || {}, text = (msg.text || "").trim();
  const admin = Number(await env.DB.get("admin")) || 0;
  if (text.startsWith("/iamadmin")) {
    if (admin) return send(env, chat, "Админ уже назначен.");
    await env.DB.put("admin", String(user.id));
    return send(env, chat, "✅ Теперь ты админ. Сюда будут приходить заявки на донат.\nКоманды: /left — сколько кодов осталось.");
  }
  if (text.startsWith("/left") && user.id === admin) {
    const given = await kvJson(env, "given", {}), codes = parseCodes();
    const lines = Object.entries(codes).map(([k, v]) => `${CONFIG.products[k]?.title || k}: ${v.filter((c) => !given[c]).length}`);
    return send(env, chat, "Осталось кодов:\n" + (lines.join("\n") || "коды не вставлены в worker.js"));
  }
  if (text.startsWith("/myid")) return send(env, chat, `Твой id: <code>${user.id}</code>`);
  return send(env, chat, "Это бот <b>Депости</b> 🎰\nТут можно купить донат для игры. Монеты, предметы и донат вывести обратно в деньги нельзя.\n\nВыбирай:", menu());
}

async function onCallback(env, cb) {
  await api(env, "answerCallbackQuery", { callback_query_id: cb.id });
  const data = cb.data || "", user = cb.from, chat = cb.message.chat.id;
  const admin = Number(await env.DB.get("admin")) || 0;

  if (data === "menu") return send(env, chat, "Выбирай:", menu());
  if (data.startsWith("buy:")) {
    const k = data.slice(4), p = CONFIG.products[k]; if (!p) return;
    if (!CONFIG.payments_enabled) return send(env, chat, `<b>${p.title}</b> — ${p.price}\n${esc(p.about)}\n\n⏳ Оплата временно не работает. Скоро включим, следи за новостями в канале.`,
      [...(CONFIG.channel_url ? [[{ text: "📦 Наш канал", url: CONFIG.channel_url }]] : []), [{ text: "← Назад", callback_data: "menu" }]]);
    return send(env, chat, `<b>${p.title}</b> — ${p.price}\n${esc(p.about)}\n\n${esc(CONFIG.pay_text)}`,
      [[{ text: "✅ Я оплатил", callback_data: `paid:${k}` }], [{ text: "← Назад", callback_data: "menu" }]]);
  }
  if (data.startsWith("paid:")) {
    const k = data.slice(5), p = CONFIG.products[k]; if (!p) return;
    if (!CONFIG.payments_enabled) return send(env, chat, "⏳ Оплата временно не работает. Скоро включим.");
    if (!admin) return send(env, chat, "Админ ещё не настроил бота. Напиши Роме напрямую.");
    const rid = String((Number(await env.DB.get("nextid")) || 0) + 1);
    await env.DB.put("nextid", rid);
    await env.DB.put("r:" + rid, JSON.stringify({ chat, perk: k, who: label(user), t: Date.now() }), { expirationTtl: 60 * 60 * 24 * 14 });
    await send(env, chat, "👍 Заявка отправлена. Как только Рома проверит оплату, бот пришлёт промокод.");
    return send(env, admin, `💰 Заявка #${rid}\n${label(user)} оплатил: <b>${p.title}</b> — ${p.price}`,
      [[{ text: "✅ Выдать", callback_data: `give:${rid}` }, { text: "❌ Отказать", callback_data: `deny:${rid}` }]]);
  }
  if (data.startsWith("give:") || data.startsWith("deny:")) {
    if (user.id !== admin) return;
    const rid = data.slice(5), req = await kvJson(env, "r:" + rid, null);
    if (!req) return send(env, chat, `Заявка #${rid} уже обработана.`);
    const p = CONFIG.products[req.perk] || { title: req.perk };
    if (data.startsWith("deny:")) {
      await env.DB.delete("r:" + rid);
      await send(env, req.chat, `❌ Оплата за «${p.title}» не подтвердилась. Напиши Роме, если это ошибка.`);
      return send(env, chat, `Заявка #${rid} отклонена.`);
    }
    const given = await kvJson(env, "given", {});
    const code = (parseCodes()[req.perk] || []).find((c) => !given[c]);
    if (!code) return send(env, chat, `⚠️ Закончились коды для «${p.title}». Попроси Claude сделать ещё и вставь их в worker.js.`);
    given[code] = { who: req.who, t: Date.now() };
    await env.DB.put("given", JSON.stringify(given));
    await env.DB.delete("r:" + rid);
    const link = CONFIG.site_url.replace(/\/$/, "") + "/?code=" + encodeURIComponent(code);
    await send(env, req.chat,
      `🎉 <b>${p.title}</b>\nТвой промокод: <code>${code}</code>\n\nНажми кнопку ниже, и он активируется сам. Открой ссылку в том же браузере, где играешь. Если не сработало, введи код вручную: «Ещё» → «Донат».`,
      [[{ text: "🎮 Активировать в игре", url: link }]]);
    return send(env, chat, `✅ Заявка #${rid}: код ${code} отправлен ${req.who}.`);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!env.BOT_TOKEN) return new Response("Не задан секрет BOT_TOKEN (Settings → Variables and Secrets).", { status: 500 });
    if (!env.DB) return new Response("Не подключено KV-хранилище с именем DB (Settings → Bindings).", { status: 500 });
    const secret = (await sha("depost:" + env.BOT_TOKEN)).slice(0, 48);

    if (url.pathname === "/setup") {
      const r = await api(env, "setWebhook", {
        url: `${url.origin}/webhook`, secret_token: secret,
        allowed_updates: ["message", "callback_query"], drop_pending_updates: true,
      });
      const me = await api(env, "getMe", {});
      return new Response(r.ok ? `✅ Готово! Бот @${me.result?.username} подключён. Напиши ему /iamadmin.` : `❌ Ошибка: ${r.description}`,
        { headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
    if (url.pathname === "/webhook" && request.method === "POST") {
      if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== secret) return new Response("forbidden", { status: 403 });
      const update = await request.json().catch(() => ({}));
      try {
        if (update.message) await onMessage(env, update.message);
        else if (update.callback_query) await onCallback(env, update.callback_query);
      } catch (e) { console.log("error", e && e.stack); }
      return new Response("ok");
    }
    return new Response("Бот Депости работает. Если ещё не подключал Telegram, открой /setup.", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  },
};
