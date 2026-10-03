# nginx-edge-gateway

Единый Nginx в **Docker Desktop на Windows 192.168.0.107**. Он выбирает внутреннее приложение по домену и транспорту. Первое приложение — Helmglass, публичный адрес `https://helmg.ru`.

```text
domain → DNS → public IP → router → NAT TCP 80/443/3478/5349 + UDP 3478 → Windows
       → опубликованные порты Nginx в Docker Desktop
       → HTTP server_name / stream listener → internal Nginx → application
```

Приложения остаются самостоятельными. Gateway не устанавливает их, не управляет пользователями и не переносит к себе авторизацию Helmglass.

## Состав

- `nginx/nginx.conf`: общие HTTP и stream-настройки.
- `nginx/stream.d/`: TCP/UDP-входы приложений, включая TURN Helmglass.
- `nginx/conf.d/`: активные hostname, каждый в своём файле; `00-default.conf` отклоняет неизвестные имена.
- `nginx/snippets/`: заголовки proxy, WebSocket, TLS, общие security headers.
- `sites/examples/`: **неактивные** примеры HTTP, WebSocket, проверяемого HTTPS backend.
- `sites/site.conf.template`: шаблон `add-site.sh`.
- `sites/sites.example.yaml`: декларативная документация; автоматический YAML-генератор пока не реализован.
- `deploy/`: Compose, параметры local/dev, закреплённые образы.
- `scripts/`: управление, сертификаты, автоматическое продление и деплой — все `.sh`.

## Windows, Docker и IP клиента

Контейнер Nginx публикует на Windows `.107` HTTP(S) TCP/80 и TCP/443, TURN TCP/3478 и UDP/3478, TURN TLS TCP/5349. Dev использует эти порты; local — `127.0.0.1:28080/28443`, `127.0.0.1:23478` для TURN TCP/UDP и `127.0.0.1:25349` для TURN TLS.

TLS для HTTPS и TURN завершается на этом gateway с теми же централизованно продлеваемыми сертификатами `helmg.ru`. TCP/3478 и TLS/5349 направляются на `helmglass-edge:5349` с PROXY protocol v1; внутренний Nginx передаёт этот заголовок вместе с потоком в доверенный PROXY-listener coturn. UDP/3478 направляется на `helmglass-edge:3478`; ассоциация сохраняется между allocation, refresh и channel data, таймаут бездействия — 10 минут. Лимиты «один запрос/ответ» не применяются. Gateway выбирает транспорт и приложение, внутренний Nginx владеет маршрутом к компоненту. Relay-порты gateway не публикует; внутренний медиапуть и ограничения relay определяет Helmglass.

Docker Desktop может подменять адрес входящего TCP-соединения. Значение `$remote_addr` в access log и `X-Real-IP` — **адрес, видимый контейнеру**, а не гарантированно исходный IP посетителя. Gateway не доверяет присланным посетителем IP-заголовкам: `X-Real-IP` и `X-Forwarded-For` заменяются на `$remote_addr`, `Forwarded` удаляется. `Host` передаётся через `$host`, `X-Forwarded-Proto` через `$scheme`.

Helmglass доверяет заголовкам только от gateway `172.30.242.2` в выделенной сети `nginx-edge-helmglass`; его внутренний HTTP edge — `helmglass-edge:8080`, адрес `172.30.242.3`. Приложение само управляет авторизацией и маршрутами.

Таймауты: connect 5 s, read/send 60 s, WebSocket read 75 s. Для долгих WebSocket-сессий нужен heartbeat чаще 75 s. Общий лимит тела 20 MiB; увеличивать адресно для приложения, которому это требуется. CSP и HSTS задаются адресно владельцем приложения.

Буфер заголовков ответа upstream — 16 KiB, чтобы увеличенные cookie Keycloak при повторном OAuth-входе не вызывали `502`. Этот предел действует и при `proxy_buffering off`; для маршрутов с буферизацией тела заданы 4 буфера по 16 KiB и `proxy_busy_buffers_size 32k`. Ограничение необходимо соблюдать на каждом прокси между приложением и браузером.

## DNS и роутер

DNS работает отдельно от Nginx. Например:

```text
helmg.ru          A 109.195.28.33
app1.example.com  A PUBLIC_IP
app2.example.com  A PUBLIC_IP
api.example.com   A PUBLIC_IP
```

Все HTTP(S)-имена могут указывать на один IP: backend выбирается после соединения по `server_name`, HTTPS использует SNI. Дополнительные TCP/UDP-транспорты требуют соответствующих портов и NAT-правил.

Для публичного HTTP(S) и TURN на роутере нужны:

```text
PUBLIC_IP:80  → 192.168.0.107:80  TCP
PUBLIC_IP:443 → 192.168.0.107:443 TCP
PUBLIC_IP:3478 → 192.168.0.107:3478 TCP/UDP
PUBLIC_IP:5349 → 192.168.0.107:5349 TCP
```

На TP-Link `192.168.0.1` ранее подтверждены правила HTTP(S) 80/443; доступность новых TURN-портов из внешней сети проверяется отдельно. DHCP reservation `.107` сохраняется. Не трогать остальные игровые правила. Docker API `2375` не добавлять в NAT; разрешать его только доверенным администраторам LAN. Он даёт полный контроль Docker.

Для `helmg.ru` используется A `109.195.28.33`, TTL 600. MX/TXT/NS сохраняются; `www`, wildcard и AAAA автоматически не добавляются. Роутер использует динамическое получение WAN IP: при изменении публичного адреса потребуется DDNS или обновление A-записи через API DNS-провайдера. Результат DNS-переключения проверять публичным resolver, не только панелью Timeweb. Домен должен быть зарегистрирован и делегирован на DNS-серверы провайдера; запись в панели сама по себе не обеспечивает публичное разрешение.

## Подготовка и первый запуск

Нужны Docker Desktop с Linux containers, Docker Compose v2, Git и Git Bash. На Linux `.sh` работают непосредственно. Команды выполняются из checkout; `EDGE_ENV=dev` выбирает `.107`, `local` — текущий Docker context. Явный `DOCKER_HOST` имеет приоритет. Для `tcp://192.168.0.107:2375` TLS отключён. Параметры стенда находятся в `deploy/.env.local` и `.env.dev`, общие версии — `deploy/images.env`.

```sh
export EDGE_ENV=dev
sh scripts/install.sh
sh scripts/bootstrap-config.sh
sh scripts/start.sh
sh scripts/status.sh
```

`install.sh` создаёт Docker volumes/сети и загружает образы. Bootstrap-конфигурация обслуживает HTTP-01 для `helmg.ru`, возвращает 503 для приложения, отклоняет TLS. Она нужна до первого сертификата; применять её поверх работающей версии запрещено. Перед `start.sh` порты стенда должны быть свободны.

Windows Firewall меняется только явно. Для отсутствующих разрешений HTTP(S)/TURN администратор `.107` выполняет соответствующие команды в PowerShell:

```powershell
New-NetFirewallRule -Name NginxEdgePublic -DisplayName "Nginx Edge HTTP HTTPS" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,443
New-NetFirewallRule -Name NginxEdgeTurnTcp -DisplayName "Nginx Edge TURN TCP TLS" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3478,5349
New-NetFirewallRule -Name NginxEdgeTurnUdp -DisplayName "Nginx Edge TURN UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 3478
```

Docker Desktop должен автоматически запускаться при входе выделенного Windows-пользователя. Его запуск до входа в Windows этот проект не обеспечивает. Контейнеры используют `unless-stopped`; восстановление после перезагрузки Windows проверяется отдельно.

## Сертификаты и первый публичный запуск

Приватные ключи, сертификаты и ACME account хранятся в persistent volume `nginx-edge-dev-certificates`. Gateway владеет отдельным ACME webroot `nginx-edge-dev-acme`; приложение не выпускает и не продлевает публичные сертификаты.

1. Настроить публичную A-запись `helmg.ru` на `109.195.28.33` и проверить её публичным resolver.
2. Подключить Helmglass edge к сети `nginx-edge-helmglass` как `helmglass-edge:8080`. В проекте Helmglass задать `PUBLIC_URL=https://helmg.ru`, `PUBLIC_HOST=helmg.ru`, `PUBLIC_PORT=443`; согласованно обновить Keycloak/OAuth2 Proxy, redirect URI, issuer/audience и MCP metadata.
3. После освобождения 80/443 запустить bootstrap gateway. Проверить снаружи HTTP-01 через собственный ACME volume.
4. Выпустить сертификат с действующим контактным email (последний аргумент можно опустить, тогда ACME account создаётся без email):

   ```sh
   EDGE_ENV=dev sh scripts/certificates.sh issue helmg.ru admin@example.com
   ```

5. Деплоить проверенный commit gateway и проверить доверенный HTTPS, redirect, вход через Keycloak и приложение. Смена issuer может потребовать повторного входа.

`start.sh` и успешный deploy запускают контейнер `nginx-edge-dev-renewal`. Он через 30 секунд после старта и затем каждые 6 часов выполняет `certificates.sh renew` из активного release. При ошибке пишет её в Docker logs, становится unhealthy и повторяет попытку через 5 минут. Последний успешный запуск должен быть не старше 7 часов. Контейнер использует закреплённый Docker CLI и сокет Docker Engine; это административный доступ к Docker, поэтому выполнять в нём можно только код доверенного репозитория. Собственных опубликованных портов и сетевого доступа у него нет.

Продление и ручные операции используют одну блокировку. После изменения сертификата reload выполняется только после успешного `nginx -t`. Если reload не прошёл, persistent marker сохраняется и следующая попытка повторяет применение сертификата. Частичная ошибка Certbot остаётся ошибкой даже при успешном применении других продлённых сертификатов.

```sh
EDGE_ENV=dev sh scripts/certificates.sh renew
EDGE_ENV=dev sh scripts/certificates.sh dry-run
docker --host tcp://192.168.0.107:2375 logs nginx-edge-dev-renewal
```

Certbot использует webroot HTTP-01 и собственный renewal state, см. [автоматическое продление Certbot](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates). При работающем Docker Desktop продление не требует запуска скрипта с компьютера разработчика.

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

Алгоритм deploy: проверить SHA и чистоту checkout → получить общую блокировку → скопировать конфигурацию в immutable `releases/SHA` в Docker volume → проверить с реальными сертификатами, закреплённым образом и рабочей сетью → атомарно переключить `current` → применить Compose gateway → проверить загруженный SHA, redirect, TLS и маршрут Helmglass. При неизменном Compose выполняется проверенный reload; изменение опубликованных портов требует пересоздания контейнера с коротким прерыванием соединений. При ошибке после активации восстанавливаются предыдущие Nginx-конфигурация и Compose-манифест, включая порты. Сетевая проверка из namespace контейнера не доказывает доступность из Интернета; внешняя приёмка выполняется отдельно.

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

Stop останавливает renewal, затем отключает restart policy gateway, затем посылает `nginx -s quit` и ждёт graceful shutdown. Start проверяет конфиг и восстанавливает Compose `unless-stopped`.

Access log — JSON в stdout: клиент, hostname, HTTP method/status, upstream, время. URI/query, Cookie, Authorization, Referer не записываются. Error log — stderr уровня `crit`: обычные request-level ошибки Nginx могут содержать OAuth query, поэтому их диагностируют по access status/upstream status. `nginx -t` отдельно выводит ошибки конфигурации. Docker сохраняет до 5 файлов по 10 MiB.

Конфигурации остаются в `nginx-edge-dev-config`, сертификаты в отдельном persistent volume. Держать резервную копию этих volumes в защищённом хранилище. Не делать `down -v`, не публиковать ключи. `rollback.sh` и автоматический откат используют одного владельца восстановления: проверяют выбранную Nginx-конфигурацию, применяют сохранённые в этом release Compose/env, включая опубликованные порты, и подтверждают загруженную revision. Ошибка восстановления явно сообщается; временные файлы и блокировка освобождаются, исходный код ошибки deploy сохраняется. Старые releases автоматически не удаляются.

Deploy обновляет конфигурацию и применяет изменения Compose, включая опубликованные порты. При смене Nginx image digest он останавливается с понятной ошибкой: сначала провести отдельную проверку нового образа и управляемое пересоздание gateway с возможностью вернуть прежний image. Обновление образа не маскируется под reload.

## Проверки

```sh
sh scripts/validate.sh
sh tests/integration.sh
```

Интеграционный тест создаёт отдельные `nginx-edge-local-*` ресурсы, отказывается заменять существующий local gateway, выпускает **временный тестовый CA только в disposable volume**, проверяет разные backend, заголовки, HTTP/HTTPS, передачу redirect с тестовой cookie размером 10 KiB через HTTP/HTTPS upstream и TLS-маршрут Helmglass, проверку CA/имени upstream, WebSocket echo, неизвестный Host/SNI, TURN TCP/TLS с PROXY v1, сохранение UDP-ассоциации и отложенные ответы, невалидный reload, откат изменённого Docker-порта, graceful stop/start. Рабочие сертификаты и приложение не затрагиваются.

Перед объявлением live-ready отдельно подтвердить: устойчивость к поддельным IP-заголовкам и фактически видимый Docker адрес; доверенный `https://helmg.ru`; login Keycloak/OAuth2 Proxy и Redis session; API/MCP issuer/URLs; прямой deploy из IDEA; ACME dry-run и успешный запуск renewal-контейнера; восстановление после перезагрузки Windows; откат неуспешного deploy. Успех локальных тестов не является отметкой о выполнении этих внешних проверок.
