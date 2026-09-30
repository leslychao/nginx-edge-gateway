# nginx-edge-gateway

Единый Nginx в **Docker Desktop на Windows 192.168.0.107**. Он выбирает внутреннее приложение по домену. Первое приложение — Helmglass, публичный адрес `https://helmg.ru`.

```text
domain → DNS → public IP → router → NAT TCP 80/443 → Windows
       → GOST (исходный IP в PROXY protocol) → Nginx в Docker Desktop
       → server_name → proxy_pass → LAN application
```

Приложения остаются самостоятельными. Gateway не устанавливает их, не управляет пользователями и не переносит к себе авторизацию Helmglass.

## Состав

- `nginx/nginx.conf`: общие настройки, `include conf.d/*.conf;`.
- `nginx/conf.d/`: активные hostname, каждый в своём файле; `00-default.conf` отклоняет неизвестные имена.
- `nginx/snippets/`: заголовки proxy, WebSocket, TLS, общие security headers.
- `sites/examples/`: **неактивные** примеры HTTP, WebSocket, проверяемого HTTPS backend.
- `sites/site.conf.template`: шаблон `add-site.sh`.
- `sites/sites.example.yaml`: декларативная документация; автоматический YAML-генератор пока не реализован.
- `deploy/`: Compose, параметры local/dev, закреплённые образы и GOST.
- `scripts/`: управление, сертификаты, деплой и отдельный Windows bootstrap — все `.sh`.

## Windows, Docker и исходный IP

Docker Desktop при публикации портов может заменять адрес клиента. Поэтому GOST 3.3.0 работает **службой Windows**, принимает обычный TCP и добавляет PROXY v1 при передаче в контейнер:

| Вход Windows | Единственный адрес назначения |
|---|---|
| `0.0.0.0:80` | `127.0.0.1:18080` → Nginx `80` |
| `0.0.0.0:443` | `127.0.0.1:18443` → Nginx `443` |

GOST не принимает PROXY от посетителей, не обрабатывает TLS и не является forward proxy. Опция отправки находится именно в `handler.metadata`, см. [документацию GOST](https://gost.run/en/tutorials/proxy-protocol/). Nginx доверяет PROXY только адресу шлюза выделенной transport-сети, см. [realip module](https://nginx.org/en/docs/http/ngx_http_realip_module.html). Loopback-публикация и Firewall обязательны: прямой доступ посетителя к PROXY listener позволил бы подделать IP. Отдельно проверяйте недоступность `18080/18443` с другой LAN-машины и извне; успешный `nginx -t` этого не доказывает.

`Host` передаётся через `$host`, `X-Real-IP` через восстановленный `$remote_addr`, `X-Forwarded-For` через `$proxy_add_x_forwarded_for`, `X-Forwarded-Proto` через `$scheme`. Клиентская часть XFF остаётся недоверенной: приложение должно доверять только известным proxy справа, а не первому адресу списка. Helmglass получает доверенный X-Real-IP только от gateway `172.30.242.2` в выделенной сети `nginx-edge-helmglass`; его внутренний HTTP edge — `helmglass-edge:8080`.

Таймауты: connect 5 s, read/send 60 s, WebSocket read 75 s. Для долгих WebSocket-сессий нужен heartbeat чаще 75 s. Общий лимит тела 20 MiB; увеличивать адресно для приложения, которому это требуется. CSP и HSTS задаются адресно владельцем приложения.

## DNS и роутер

DNS работает отдельно от Nginx. Например:

```text
helmg.ru          A 109.195.28.33
app1.example.com  A PUBLIC_IP
app2.example.com  A PUBLIC_IP
api.example.com   A PUBLIC_IP
```

Все имена могут указывать на один IP: backend выбирается после соединения по `server_name`, HTTPS использует SNI. Новое приложение не требует нового NAT-правила.

На роутере нужны только:

```text
PUBLIC_IP:80  → 192.168.0.107:80  TCP
PUBLIC_IP:443 → 192.168.0.107:443 TCP
```

На TP-Link `192.168.0.1` эти правила уже обнаружены; DHCP reservation `.107` сохраняется. Не трогать остальные игровые правила. Docker API `2375` не добавлять в NAT; разрешать его только доверенным администраторам LAN. Он даёт полный контроль Docker.

Для `helmg.ru` согласовано заменить **только A** `72.56.117.251` на `109.195.28.33`, TTL 600. MX/TXT/NS сохранить; `www`, wildcard и AAAA не добавлять автоматически. Роутер использует динамическое получение WAN IP: при изменении публичного адреса потребуется DDNS или обновление A-записи через API DNS-провайдера. Результат DNS-переключения проверять публичным resolver, не только панелью Timeweb.

## Подготовка и первый запуск

Нужны Docker Desktop с Linux containers, Docker Compose v2, Git и Git Bash. На Linux `.sh` работают непосредственно. Команды выполняются из checkout; `EDGE_ENV=dev` выбирает `.107`, `local` — текущий Docker context. Явный `DOCKER_HOST` имеет приоритет. Для `tcp://192.168.0.107:2375` TLS отключён. Параметры стенда находятся в `deploy/.env.local` и `.env.dev`, общие версии — `deploy/images.env`.

```sh
export EDGE_ENV=dev
sh scripts/install.sh
sh scripts/bootstrap-config.sh
sh scripts/start.sh
sh scripts/status.sh
```

`install.sh` создаёт только Docker volumes/сети и загружает образы. Bootstrap-конфигурация обслуживает HTTP-01 для `helmg.ru`, возвращает 503 для приложения, отклоняет TLS. Она нужна до первого сертификата; применять её поверх работающей версии запрещено. Пока Windows-служба не переключена, действующий вход Helmglass сохраняется.

**Отдельно на `.107`, в Git Bash от администратора**, из постоянного checkout:

```sh
EDGE_ENV=dev sh scripts/bootstrap-windows.sh install-transport
EDGE_ENV=dev sh scripts/bootstrap-windows.sh firewall
```

Первый шаг проверяет SHA256 официального GOST, защищает каталог `%ProgramData%/nginx-edge-gateway`, создаёт службу `NginxEdgeTransport` под LocalService с recovery restart и запускает её на временных `28080/28443`. Второй явно добавляет Firewall: public 80/443, временные LAN-only 28080/28443, запрет LAN-подключений к 18080/18443. Без этих явных команд Firewall не меняется. Временные порты в NAT не добавлять. После проверки удалить правило `NginxEdgeTest` штатными средствами Firewall.

Docker Desktop должен автоматически запускаться при входе выделенного Windows-пользователя. Его запуск до входа в Windows этот проект не обеспечивает. GOST — автоматическая служба; Docker containers используют `unless-stopped`. Проверка после перезагрузки Windows обязательна отдельно от перезапуска контейнера.

## Сертификаты и перенос Helmglass

Приватные ключи, сертификаты и ACME account находятся в persistent volume `nginx-edge-dev-certificates`; каталог `nginx/certs/` исключён из Git. ACME webroot dev — существующий `ai-tasks-dev_acme-web`, поэтому первый HTTP-01 может обслуживать старый edge Helmglass, пока новый gateway готовится.

Порядок согласованного переключения:

1. Сохранить текущие параметры и версии Helmglass; согласовать окно с владельцем его активного чата.
2. Проверить gateway и GOST на временных портах, IP клиента в access log и backend, закрытость loopback-портов из LAN.
3. Изменить A-запись Timeweb и проверить публичное разрешение на `109.195.28.33`.
4. Получить сертификат (указать действующий контактный email):

   ```sh
   EDGE_ENV=dev sh scripts/certificates.sh issue helmg.ru admin@example.com
   ```

5. В проекте Helmglass применить `PUBLIC_URL=https://helmg.ru`, `PUBLIC_HOST=helmg.ru`, `PUBLIC_PORT=443`; согласованно обновить Keycloak/OAuth2 Proxy, redirect URI, issuer/audience, MCP metadata. Перевести edge на внутренний HTTP `8080` с alias `helmglass-edge`, фиксированным адресом `172.30.242.3` в общей сети. Убрать его публичные 80/443. Авторизация и все application routes остаются у Helmglass.
6. Деплоить проверенный commit gateway; выполнить `bootstrap-windows.sh activate-transport` на `.107` — **только после освобождения 80/443**. Проверить внешний HTTPS и реальный вход через Keycloak; подтверждение только TCP/healthcheck недостаточно.
7. После успешной проверки остановить старое продление IP-сертификата в Helmglass и убрать прежний вход по IP. Зарегистрировать `bootstrap-windows.sh schedule-renewal`: каждые шесть часов, текущий Windows-пользователь, Git Bash и `renew-scheduled.sh` из этого постоянного checkout.

Смена issuer может потребовать повторного входа. При сбое до завершения переноса остановить GOST, вернуть **сохранённые** параметры и port bindings Helmglass, применить старую версию через его штатный deploy. Не удалять старые сертификаты/volumes до приёмки. A-запись возвращать только при необходимости полного DNS-отката.

Продление: `sh scripts/certificates.sh renew`, проверка ACME staging: `sh scripts/certificates.sh dry-run`. Владелец продления один — gateway. Certbot хранит account/renewal state в persistent volume. Изменение сертификата вызывает reload **только после `nginx -t`**; ошибки возвращаются ненулевым exit code. Task Scheduler показывает Last Run Result; успешный manual dry-run не заменяет проверку реального расписания. При обновлении кода/образов обновлять и постоянный Windows-checkout задачи.

Готовый wildcard можно импортировать в cert volume как `live/CERT_NAME/fullchain.pem` и `privkey.pem`, с ограниченными правами. Имя каталога выбирается `--certificate`; соответствие SAN hostname всё равно проверять. Автоматический DNS-01 не реализован.

## Добавление сайта

1. Создать DNS A-record и указать публичный IP.
2. Определить доступный gateway внутренний IP/hostname приложения и порт.
3. Создать файл:

   ```sh
   EDGE_ENV=dev sh scripts/add-site.sh \
     --domain app.example.com --backend 192.168.1.20 --port 8080 \
     --backend-scheme http --websocket false
   ```

4. Для HTTPS frontend сначала получить сертификат через доступный HTTP-01 маршрут, затем повторить с `--force --frontend-https true --certificate app.example.com`. Либо использовать уже существующий подходящий сертификат. Добавление HTTPS генерирует HTTP→HTTPS redirect с исключением ACME.
5. Выполнить `sh scripts/test-config.sh`. Добавление уже выполняет настоящую проверку Nginx; при ошибке восстанавливает прежний файл. `--force` обязателен для перезаписи. Ни один результат add-site не вызывает reload.
6. Проверить и закоммитить изменение, затем запустить **Deploy Docker 107** в IDEA либо `EDGE_ENV=dev sh scripts/deploy.sh`. Скрипт загрузит и применит конфигурацию текущего commit. `sh scripts/reload.sh` повторно загружает **активный release в volume**, а не произвольные изменённые файлы checkout.
7. Проверить сайт из внешней сети и логи `docker logs nginx-edge-dev`. Для повторного ручного применения активной версии использовать `test-config.sh --active`, затем `reload.sh`.

HTTPS upstream:

```sh
EDGE_ENV=dev sh scripts/add-site.sh \
  --domain api.example.com --backend 192.168.1.10 --port 9000 \
  --backend-scheme https --backend-tls-name api.internal.example.com \
  --backend-ca /certificates/internal-ca.pem --websocket false
```

CA должен быть предварительно помещён в certificate volume. Проверка цепочки и имени обязательна; подключение по IP не означает, что TLS SNI тоже должен быть IP. Поддерживаются IPv4 и DNS hostname, IPv6 backend в CLI пока отсутствует. Динамические Docker backend при необходимости задаются в отдельном конфиге через resolver, как в `helmg.ru.conf`.

## Прямой deploy и IDEA Run

Открыть этот репозиторий в IntelliJ IDEA и выбрать **Deploy Docker 107**. Общая конфигурация сохранена в `.run/Deploy Docker 107.run.xml`: Git Bash `C:/Program Files/Git/bin/bash.exe`, рабочий каталог проекта, `scripts/deploy.sh`, `EDGE_ENV=dev`, `DOCKER_HOST=tcp://192.168.0.107:2375`. Требуется встроенный Shell scripts plugin. Вывод и exit code появляются в окне Run. Если Git установлен в другом месте, изменить путь интерпретатора.

Скрипт запускается на машине разработчика и обращается напрямую к Docker HTTP API `.107:2375`, без TLS. Это `.sh`, соединение SSH здесь не используется: на `2375` работает Docker API. GitHub хранит исходники; push не запускает деплой.

```sh
sh scripts/validate.sh
sh tests/integration.sh
# После проверки и commit:
EDGE_ENV=dev sh scripts/deploy.sh
# Необязательный первый аргумент фиксирует ожидаемый HEAD:
EDGE_ENV=dev sh scripts/deploy.sh FULL_COMMIT_SHA
```

Алгоритм deploy: проверить SHA и чистоту checkout → получить общую блокировку → скопировать конфигурацию в immutable `releases/SHA` в Docker volume → проверить с реальными сертификатами, закреплённым образом и рабочей сетью → атомарно переключить `current` → ещё раз `nginx -t` → reload → проверить загруженный SHA, redirect, TLS и маршрут Helmglass. При ошибке после активации возвращается предыдущая версия. Сетевая проверка из namespace контейнера не доказывает доступность из Интернета; внешняя приёмка выполняется отдельно.

Блокировка — атомарно созданный контейнер `nginx-edge-dev-operation-lock`; она общая для deploy, ручного reload, add-site и сертификатов, даже с разных компьютеров. После аварийного завершения клиента lock может остаться. Удалять его вручную **только убедившись, что операции больше нет**; не делать автоматический сброс по таймеру.

## Эксплуатация и откат

```sh
EDGE_ENV=dev sh scripts/status.sh
EDGE_ENV=dev sh scripts/test-config.sh --active
EDGE_ENV=dev sh scripts/reload.sh
EDGE_ENV=dev sh scripts/stop.sh
EDGE_ENV=dev sh scripts/start.sh
EDGE_ENV=dev sh scripts/rollback.sh PREVIOUS_RELEASE_ID
```

Stop сначала отключает restart policy, затем посылает `nginx -s quit` и ждёт graceful shutdown. Start проверяет конфиг и восстанавливает Compose `unless-stopped`.

Access log — JSON в stdout: клиент, hostname, HTTP method/status, upstream, время. URI/query, Cookie, Authorization, Referer не записываются. Error log — stderr уровня `crit`: обычные request-level ошибки Nginx могут содержать OAuth query, поэтому их диагностируют по access status/upstream status. `nginx -t` отдельно выводит ошибки конфигурации. Docker сохраняет до 5 файлов по 10 MiB.

Конфигурации остаются в `nginx-edge-dev-config`, сертификаты в отдельном persistent volume. Держать резервную копию этих volumes в защищённом хранилище. Не делать `down -v`, не публиковать ключи. `rollback.sh` проверяет выбранную версию перед reload; старые releases автоматически не удаляются.

Deploy здесь обновляет конфигурацию. При смене Nginx image digest он останавливается с понятной ошибкой: сначала провести отдельную проверку нового образа и управляемое пересоздание gateway с возможностью вернуть прежний image. Обновление образа не маскируется под reload.

## Проверки

```sh
sh scripts/validate.sh
sh tests/integration.sh
```

Интеграционный тест создаёт отдельные `nginx-edge-local-*` ресурсы, отказывается заменять существующий local gateway, выпускает **временный тестовый CA только в disposable volume**, проверяет разные backend, заголовки, HTTP/HTTPS, проверку CA/имени upstream, WebSocket echo, неизвестный Host/SNI, невалидный reload, graceful stop/start. Рабочие сертификаты и приложение не затрагиваются.

Перед объявлением live-ready отдельно подтвердить: реальные внешние IP в log/backend и устойчивость к поддельным заголовкам; блокировку loopback-портов из LAN; доверенный `https://helmg.ru`; login Keycloak/OAuth2 Proxy и Redis session; API/MCP issuer/URLs; прямой deploy из IDEA; ACME dry-run и Task Scheduler; восстановление после перезагрузки Windows; откат неуспешного deploy. Успех локальных тестов не является отметкой о выполнении этих внешних проверок.
