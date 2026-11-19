# Бот на Cloudflare Workers (бесплатно, без VPN)

Бот работает на серверах Cloudflare за границей, поэтому блокировки Telegram в России ему не мешают. Не нужен ни комп, ни Orange Pi, ни VPN. Бесплатного тарифа хватает с огромным запасом.

Тебе понадобятся:
- токен бота из **@BotFather**;
- файл **`worker-with-codes.js`**, который прислал Claude (это `worker.js` с уже вставленными промокодами). На GitHub его не загружай.

## Шаги

1. **Регистрация.** Зайди на dash.cloudflare.com, зарегистрируйся по почте и подтверди её.
2. **Создай Worker.** В меню слева открой **Workers & Pages** (может называться **Compute**), нажми **Create** → **Start with Hello World** → имя `depost-bot` → **Deploy**.
3. **Вставь код.** Нажми **Edit code**, удали всё в редакторе, вставь содержимое `worker-with-codes.js` и нажми **Deploy**.
4. **Создай хранилище.** В меню слева: **Storage & Databases** → **KV** → **Create** → имя `depost` → **Create**.
5. **Подключи хранилище к боту.** Открой свой Worker `depost-bot` → **Settings** → **Bindings** → **Add** → **KV namespace**. Variable name: `DB`, namespace: `depost`. Сохрани.
6. **Добавь токен.** Там же: **Settings** → **Variables and Secrets** → **Add**. Type: **Secret**, Name: `BOT_TOKEN`, Value: токен бота. Сохрани и нажми **Deploy**, если попросит.
7. **Подключи Telegram.** Открой в браузере адрес своего Worker'а с `/setup` на конце, например `https://depost-bot.твой-ник.workers.dev/setup`. Должно появиться «✅ Готово!».
8. **Стань админом.** Напиши своему боту `/iamadmin`.

Если адрес `…workers.dev` у тебя не открывается, открой `/setup` один раз через VPN. После этого VPN больше не нужен: Telegram общается с Cloudflare напрямую.

## Как поменять цены и тексты

Открой Worker → **Edit code**. В самом верху блок `CONFIG`: тексты, цены, текст про оплату. Поменяй и нажми **Deploy**.

## Если закончились коды

Бот напишет тебе об этом. Попроси Claude сделать новые коды и вставь их в блок `CODES` в коде Worker'а.
