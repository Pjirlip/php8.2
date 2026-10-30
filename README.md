# php8.2-apache

> **Branch `fpm`:** dieses Repository baut hier zwei Images statt des mod_php-Images.
> `ghcr.io/pjirlip/php8.2-fpm` (PHP-FPM, `Dockerfile`) und `ghcr.io/pjirlip/php8.2-httpd` (Apache event +
> mod_proxy_fcgi, `Dockerfile.httpd`). Beide laufen als zwei Container in einem Pod, siehe Abschnitt
> "Apache + PHP-FPM". `php8.2:latest` bleibt bis zum Merge unverändert.

## Apache + PHP-FPM

Warum: Mit Apache prefork und mod_php belegt jede Verbindung einen kompletten PHP-Prozess, auch ein
2-ms-JPEG und auch eine Verbindung, die nur im KeepAlive wartet. Hinter Traefik mit HTTP/2 kommen 20 bis 40
Asset-Requests parallel an, ein Pod mit wenigen Workern serialisiert sie, und Apache meldet
`AH00161 server reached MaxRequestWorkers`. Mit event-MPM kostet eine Verbindung einen Thread, PHP-Requests
gehen über FastCGI an den php-fpm-Container, dessen Prozesse nur für PHP gebraucht werden.

| Container | Image | Aufgabe |
|-----------|-------|---------|
| `apache` | `ghcr.io/pjirlip/httpd` (identisch mit `php8.2-httpd`) | Port 80, statische Dateien, `.htaccess`, `/healthz`, proxied `*.php` nach `127.0.0.1:9000` |
| `php-fpm` | `ghcr.io/pjirlip/php8.2-fpm` | PHP 8.2 mit allen Extensions, Composer, msmtp; auch das Image für CronJobs |

Beide Container mounten die Webroot-PVC unter demselben Pfad (`/var/www/html`), Apache read-only. Sie teilen
den Netzwerk-Namespace des Pods, php-fpm lauscht nur auf `127.0.0.1:9000`.

Pool-Dimensionierung im php-fpm-Container (`scripts/entrypoint.sh`), analog zur alten Worker-Formel:

    pm.max_children = floor((limit_MiB - PHP_FPM_BASELINE_MEMORY_MB) / PHP_FPM_CHILD_MEMORY_MB)

Defaults 256 MiB Baseline (OPcache 192 MiB + Master) und 64 MiB pro Child: 1Gi ergibt 12 Children, 2Gi 28.
`PHP_FPM_MAX_CHILDREN` setzt den Wert explizit, `PHP_FPM_PM=ondemand` startet Children erst bei Bedarf
(`PHP_FPM_PROCESS_IDLE_TIMEOUT`), sinnvoll für Sites mit wenig Traffic. `PHP_FPM_REQUEST_TERMINATE_TIMEOUT`
(300 s) beendet Requests, die an NFS oder MySQL hängen; `max_execution_time` zählt nur CPU-Zeit.

Apache-Container: `APACHE_MAX_REQUEST_WORKERS` (150) sind Threads, `APACHE_PROXY_TIMEOUT` (300 s) muss den
längsten PHP-Request überdauern. `/fpm-ping` (Cluster-Netze) und `/fpm-status` (nur Pod-intern) sind die
php-fpm-Probes, `/server-status` das Apache-Scoreboard, alle vom Access-Log ausgenommen.

Docker Compose (Server ohne Kubernetes): beide Container laufen als eigene Services, Apache erreicht php-fpm über
den Service-Namen. Dafür `PHP_FPM_HOST=php-fpm` im Apache-Container sowie `PHP_FPM_LISTEN=0.0.0.0:9000` und ein
leeres `PHP_FPM_ALLOWED_CLIENTS` im php-fpm-Container (Default `127.0.0.1`, passend zum Pod); Port 9000 nur in
einem internen Compose-Netz lassen, nicht veröffentlichen. Ohne Memory-Limit (`mem_limit`) gilt `pm.max_children=10`.

Deployment-Skelett:

```yaml
containers:
  - name: apache
    image: ghcr.io/pjirlip/php8.2-httpd:latest
    ports: [{ containerPort: 80 }]
    env:
      - { name: DOCUMENT_ROOT, value: /var/www/html }
    resources: { requests: { cpu: 20m, memory: 32Mi }, limits: { memory: 256Mi } }
    startupProbe:   { httpGet: { path: /healthz, port: 80 }, periodSeconds: 5, failureThreshold: 24 }
    readinessProbe: { httpGet: { path: /fpm-ping, port: 80 }, periodSeconds: 5, timeoutSeconds: 2, failureThreshold: 2 }
    livenessProbe:  { httpGet: { path: /healthz, port: 80 }, periodSeconds: 10, timeoutSeconds: 3, failureThreshold: 9 }
    lifecycle: { preStop: { exec: { command: ["sh", "-c", "sleep 5"] } } }
    volumeMounts:
      - { name: webroot, mountPath: /var/www/html, readOnly: true }
  - name: php-fpm
    image: ghcr.io/pjirlip/php8.2-fpm:latest
    envFrom: [{ secretRef: { name: example-site-env } }]
    resources: { requests: { cpu: 50m, memory: 256Mi }, limits: { memory: 1Gi } }
    livenessProbe:   # php-fpm listens on 127.0.0.1 only, a tcpSocket probe would use the pod IP
      exec: { command: ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/9000"] }
      periodSeconds: 10
      timeoutSeconds: 3
      failureThreshold: 6
    lifecycle: { preStop: { exec: { command: ["sh", "-c", "sleep 5"] } } }
    volumeMounts:
      - { name: webroot, mountPath: /var/www/html }
      - { name: tmp, mountPath: /tmp }
terminationGracePeriodSeconds: 45
```

Stolperstein: `php_value`/`php_flag`-Zeilen in `.htaccess` sind mod_php-Direktiven und führen ohne mod_php zu
einem 500. Vor der Umstellung prüfen (`grep -rlE '^\s*php_(value|flag|admin)' <webroot>`) und die
Einstellungen nach `.user.ini` oder in die Env-Variablen verschieben.

Dockerimage für Hosting von Seiten mit PHP Version 8.2 (TYPO3 Composer-Projekte, `DOCUMENT_ROOT=/var/www/html/public`).

Inkl. GM und Redis Support
Siehe .env.sample für Konfigurationsmöglichkeiten

## Was sich gegenüber dem alten Image ändert

Umgesetzt sind die Punkte **Kritisch** und **Hoch** aus dem Review (`_review/REVIEW.md`):

| Punkt | Umsetzung |
|-------|-----------|
| K1 Worker-Limit | `config/mpm_prefork.conf`; `scripts/entrypoint.sh` berechnet `MaxRequestWorkers` aus dem Memory-Limit des Containers, `ServerLimit` ist identisch, `MaxConnectionsPerChild 1000` |
| K2 NFS-I/O | OPcache/realpath-Tuning in `config/php.ini`, `-MultiViews`, kein `.htaccess` oberhalb des DocumentRoot und in Upload-Bäumen, `/etc/apache2/site.d/*.conf` als Ablage für Site-Regeln, tmp/Sessions in `/tmp` |
| K3 Composer-Updater | ersatzlos entfernt |
| H1 Shutdown | kein supervisord mehr, Apache ist der einzige Prozess, SIGTERM wird zu SIGWINCH (graceful stop, max. 25 s) |
| H2 Cron | kein cron-Daemon im Container, Kubernetes-Beispiele unter `cron-jobs/` |
| H3 Probes | statischer Endpoint `GET /healthz` aus dem Image-FS, antwortet nur wenn ein Worker frei ist |
| H4 Timeouts | `Timeout 120`, `mysqlnd.net_read_timeout`, `default_socket_timeout`, `mysqli.allow_persistent = Off` |
| H5 Logging | Error-Log auf stderr, Access-Log auf stdout, keine Logdateien, kein doppeltes Logging, Probe-Requests werden nicht geloggt |
| H6 Build | `apache2ctl -t` statt Apache-Start zur Build-Zeit |

Mit erledigt, weil die Umbauten es erfordern: Mail läuft über `sendmail_path` mit msmtp-Argumenten
(keine `/etc/msmtprc` mehr, damit CronJob-Pods ohne Entrypoint mailen können), das PID-File liegt unter
`/var/run/apache2/`. Unverändert geblieben sind alle Mittel/Niedrig-Punkte (root-Start, Port 80, Paketliste).

## Worker-Formel

```
MaxRequestWorkers = floor((limit_MiB - APACHE_BASELINE_MEMORY_MB) / APACHE_CHILD_MEMORY_MB)
```

`APACHE_CHILD_MEMORY_MB` pro Site messen (PSS unter Last):

```sh
for p in $(pgrep -f 'apache2 -D'); do grep ^Pss: /proc/$p/smaps_rollup; done
```

| Pod-Limit | Baseline | Kind p95 | MaxRequestWorkers |
|-----------|----------|----------|-------------------|
| 1 GiB | 256 MiB | 80 MiB | 9 |
| 2 GiB | 256 MiB | 100 MiB | 17 |
| 4 GiB | 256 MiB | 120 MiB | 32 |

## Was das Deployment mitbringen muss

```yaml
terminationGracePeriodSeconds: 45          # preStop 5 s + GracefulShutdownTimeout 25 s + Reserve
containers:
  - name: web
    resources:
      requests: { memory: 2Gi }
      limits:   { memory: 2Gi }            # daraus leitet der Entrypoint die Worker ab
    startupProbe:
      httpGet: { path: /healthz, port: 80 }
      periodSeconds: 5
      failureThreshold: 24
    readinessProbe:                        # ohne freien Worker nach ~10 s raus aus dem Service
      httpGet: { path: /healthz, port: 80 }
      periodSeconds: 5
      timeoutSeconds: 2
      failureThreshold: 2
    livenessProbe:                         # Neustart erst nach ~90 s Stillstand
      httpGet: { path: /healthz, port: 80 }
      periodSeconds: 10
      timeoutSeconds: 3
      failureThreshold: 9
    lifecycle:
      preStop:
        exec: { command: ["sh", "-c", "sleep 5"] }
    volumeMounts:
      - { name: webroot, mountPath: /var/www/html }
      - { name: tmp,     mountPath: /tmp }
      - { name: typo3-cache, mountPath: /var/www/html/var/cache }   # emptyDir, nicht NFS
      - { name: typo3-lock,  mountPath: /var/www/html/var/lock }    # emptyDir
      - { name: typo3-log,   mountPath: /var/www/html/var/log }     # emptyDir
```

Hinweis zu `fileadmin/`: `.htaccess`-Dateien darunter werden nicht mehr ausgewertet und PHP ist dort abgeschaltet;
`fileadmin/_temp_` ist gesperrt. `_processed_` und `typo3temp/assets` bleiben geteilte PVC-Pfade.

## Cron-Jobs

Der TYPO3-Scheduler und die Form-Cleanup-Bereinigung laufen nicht mehr im Container. Beispiele unter `cron-jobs/`:

- `typo3-scheduler.yaml`: `vendor/bin/typo3 scheduler:run` alle 15 Minuten, ein Lauf pro Site (`concurrencyPolicy: Forbid`)
- `typo3-form-cleanup.yaml`: `typo3_form_cleanup.sh` aus dem Image, täglich; durchsucht nur noch `fileadmin/user_upload` (`CLEANUP_FORM_UPLOAD_DIR`, `-maxdepth 2`) statt des gesamten DocumentRoot

## Neue Umgebungsvariablen

| Variable | Default | Bedeutung |
|----------|---------|-----------|
| `APACHE_MAX_REQUEST_WORKERS` | leer | fester Wert; leer = aus dem Memory-Limit berechnen |
| `APACHE_CHILD_MEMORY_MB` | 100 | gemessener Speicher pro Apache-Kind |
| `APACHE_BASELINE_MEMORY_MB` | 256 | Parent + OPcache-SHM |
| `APACHE_MIN_SPARE_SERVERS` / `APACHE_MAX_SPARE_SERVERS` | 2 / 4 | Prefork-Reserve |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | 1000 | Recycling der Kinder |
| `APACHE_TIMEOUT` | 120 | Apache `Timeout` (Netz-I/O) |
| `APACHE_ALLOW_OVERRIDE` | All | `None` schaltet `.htaccess` ab, Regeln dann über `/etc/apache2/site.d/` (ConfigMap) |
| `PHP_OPCACHE_MEMORY` / `PHP_OPCACHE_MAX_FILES` | 192 / 50000 | OPcache-Größe |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` / `PHP_OPCACHE_REVALIDATE_FREQ` | 1 / 60 | 0 nur, wenn Deploys immer die Pods neu starten |
| `PHP_MYSQLND_NET_READ_TIMEOUT` | 300 | Lese-Timeout für MySQL in Sekunden |

Entfallen: `TYPO3_SCHEDULER`, `COMPOSER_AUTOUPDATE_PACKAGES`, Cron-Mounts nach `/etc/cron.d/`.
Siehe `.env.sample`.

## Build über GitHub Actions

`.github/workflows/docker-build.yml` baut das Image auf jedem Push und veröffentlicht es nach
`ghcr.io/<owner>/php8.2-apache`:

| Auslöser | Tags |
|----------|------|
| Push auf einen Branch | `<branch>`, `sha-<kurz>`; Default-Branch zusätzlich `latest`; `develop` zusätzlich `dev` |
| Git-Tag `v1.2.3` | `1.2.3`, `1.2`, `production` |
| Manuell (Run workflow) | zusätzlich der eingegebene Tag, Default `production`, vom gewählten Branch/Tag |

GHCR-Pakete eines Nutzer-Accounts sind nach dem ersten Push privat. Entweder das Paket auf "public" stellen
oder im Cluster ein `imagePullSecret` mit einem Token (Scope `read:packages`) hinterlegen.
