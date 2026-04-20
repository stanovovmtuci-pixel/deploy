# deploy-kit

Воспроизводимый деплой инфраструктуры для self-hosted VPN/proxy цепочки
с двумя серверами: **internal** (точка входа клиентов) и **external**
(выход в интернет).

## Что это

Этот репозиторий содержит шаблоны и скрипты для развертывания stack'а
из 3x-ui (Xray Reality + WebSocket), sslh, nginx, AmneziaWG, smart-proxy
demon и веб-панели управления prxy-panel на чистом Ubuntu 22.04 VDS.

Дизайн взят из работающей конфигурации (см. `internal/manifest.json`)
и параметризован через placeholders вида `{{NODE_FQDN}}`, чтобы один
и тот же набор шаблонов мог обслуживать произвольное количество нод.

## Архитектура
client -> internal:443 (sslh) -> nginx (TLS termination)
-> xray Reality (port 10443) ---
+-> awg0 (IPv6 tunnel)
-> xray WS     (port 10444) ---/        |
v
external server -> Cloudflare WARP -> Internet

Internal-сервер мультиплексирует трафик 443 порта по SNI, маскирует
Xray Reality под yandex.ru, и через AmneziaWG-туннель отправляет
основной трафик на external-сервер. Внутри есть smart-proxy daemon,
который для каждого домена решает: пускать direct (через RU-провайдер)
или через тоннель (для обхода блокировок).

## Структура репозитория
deploy-kit/
├── README.md                  -- этот файл
├── internal/                  -- всё для internal-сервера
│   ├── deploy.sh              -- entrypoint
│   ├── manifest.json          -- карта плейсхолдеров
│   ├── lib/                   -- общие функции
│   │   ├── common.sh          -- log/ask/fail
│   │   ├── render.sh          -- подстановка {{VAR}}
│   │   ├── backup.sh          -- бэкапы и откаты
│   │   └── validation.sh      -- DNS/port/OS checks
│   ├── phases/                -- 10 фаз установки
│   │   ├── 00-init.sh
│   │   ├── 01-precheck.sh
│   │   ├── 02-base.sh
│   │   ├── 03-ssl.sh
│   │   ├── 04-awg.sh
│   │   ├── 05-x-ui.sh
│   │   ├── 06-routing.sh
│   │   ├── 07-smart-proxy.sh
│   │   ├── 08-prxy-panel.sh
│   │   └── 09-finalize.sh
│   └── templates/             -- параметризованные конфиги
└── external/                  -- скрипты для external-сервера
└── README.md              -- (будет написано отдельно)

## Требования

### На клиентской машине (вы)

- DNS-запись A/AAAA для `node<N>.<вашего-домена>` указывает на IPv4
  будущего internal-сервера

### На internal-сервере (свежий VDS)

- Ubuntu Server 22.04 LTS, x86_64
- Доступ root по SSH или sudo-пользователь с паролем
- Открытые входящие порты 22, 80, 443
- Минимум 1 GB RAM, 10 GB диска

### На external-сервере (свежий VDS)

- Ubuntu Server 22.04 LTS, x86_64
- IPv6 connectivity (для AWG endpoint)
- AmneziaWG-сервер развёрнут до запуска internal/deploy.sh

## Быстрый старт

```bash
# на новом internal-сервере
git clone https://github.com/stanovovmtuci-pixel/deploy.git
cd deploy/internal
sudo ./deploy.sh
```

Скрипт пошагово опросит необходимые параметры (NODE_ID, базовый домен,
IPv6 external-сервера, root-пароль external-сервера для ssh-обмена
ключами) и развернёт инфраструктуру за ~5-10 минут.

В конце выведет credentials для prxy-panel и 3x-ui, которые **нужно
сохранить немедленно** — они больше не показываются.

## Управление и флаги

```bash
sudo ./deploy.sh                       # полный прогон всех 10 фаз
sudo ./deploy.sh --from-phase 5        # перезапуск с конкретной фазы
sudo ./deploy.sh --rollback PHASE      # откат изменений конкретной фазы
sudo ./deploy.sh --rollback-all        # полный откат всего деплоя
sudo ./deploy.sh --list-backups        # список доступных бэкапов
sudo ./deploy.sh --dry-run             # показать что будет сделано, без изменений
sudo ./deploy.sh --help
```

## Система бэкапов и откатов

Каждая фаза перед изменениями сохраняет снимок затрагиваемых файлов
и системного состояния в `/var/backups/deploy/<RUN_ID>/<phase-id>/`.

При сбое внутри фазы (любая команда возвращает не-ноль) автоматически
запускается rollback: восстанавливаются конфигурационные файлы,
перезапускаются службы из снимка, восстанавливаются iptables-правила.

Бэкапы хранятся **24 часа**, после чего удаляются по cron'у. Это
позволяет откатить только что сделанный деплой, но не накапливает мусор.

### Что НЕ откатывается автоматически

- Установленные apt-пакеты (можно убрать через `apt remove`, но
  системные конфликты могут остаться)
- Выпущенные Let's Encrypt сертификаты (живут на ACME-серверах,
  можно отозвать через `certbot revoke`)
- AWG peer на external-сервере (удаляется отдельной командой через
  `--rollback PHASE=04-awg`)
- DNS-записи (управляются вне этого инструмента)

## Безопасность

- Все секреты (пароли, приватные ключи, UUID) генерируются
  автоматически на каждой ноде, ничего не захардкожено
- prxy-panel пароль показывается ровно один раз в конце деплоя
  и хранится в виде bcrypt-хэша в `/opt/prxy-panel/users.json`
- 3x-ui панель доступна только через nginx + sslh, прямой доступ
  к её порту блокируется UFW
- sshd: запрет root-логина, max-auth 3, fail2ban на 22 порту
- В `internal/phases/00-init.sh` пользователь явно указывает свой
  IP, который будет добавлен в whitelist fail2ban

## Troubleshooting

**Деплой падает на 03-ssl** — проверь, что DNS-запись для NODE_FQDN
указывает на IP сервера и распространилась (`dig node1.example.com`).

**Деплой падает на 04-awg** — проверь, что external-сервер доступен
по ssh с введённым паролем root, и что AmneziaWG там запущен и слушает
указанный порт.

**Не могу зайти в prxy-panel после деплоя** — проверь, что в
`/etc/default/prxy-panel` нет утечки `PRXY_PANEL_INIT_PASSWORD`
(скрипт стирает её после первого старта). Если файл пуст — пароль уже
зашифрован в `/opt/prxy-panel/users.json`. Сменить можно через смену
пароля внутри панели или удалить `users.json` и поднять пароль через
env-var заново.

**Хочу пересоздать всё с нуля** — `sudo ./deploy.sh --rollback-all`,
потом `sudo ./deploy.sh`.

## Лицензия

Proprietary. Use at your own risk. Аutoр не несёт ответственности
за работоспособность, сохранность данных, юридические последствия
использования инструментов обхода ограничений в вашей юрисдикции.
