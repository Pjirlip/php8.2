# PHP-FPM container: runs PHP only. Static files, keep-alive connections and TLS termination never
# occupy a PHP process; Apache (Dockerfile.httpd) proxies .php requests to this container over
# 127.0.0.1:9000 inside the same pod.
FROM php:8.2-fpm
LABEL maintainer="Philipp Dippel <philipp.dippel@propeller.de>"
SHELL ["/bin/bash", "-c"]

RUN addgroup --gid 1000 propeller && useradd --system -u 1000 -g propeller propeller

ENV PROVISION_CONTEXT="production"
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin
ENV DOCUMENT_ROOT=/var/www/html
ENV LETSENCRYPT_EMAIL=certbot@propeller.de
# Pool sizing (K1). An empty PHP_FPM_MAX_CHILDREN lets entrypoint.sh derive the value from the container
# memory limit: floor((limit_MiB - BASELINE_MB) / CHILD_MB). Only PHP requests occupy a child.
ENV PHP_FPM_LISTEN=127.0.0.1:9000 \
    PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN="" \
    PHP_FPM_CHILD_MEMORY_MB=64 \
    PHP_FPM_BASELINE_MEMORY_MB=256 \
    PHP_FPM_START_SERVERS=2 \
    PHP_FPM_MIN_SPARE_SERVERS=1 \
    PHP_FPM_MAX_SPARE_SERVERS=4 \
    PHP_FPM_PROCESS_IDLE_TIMEOUT=10s \
    PHP_FPM_MAX_REQUESTS=1000 \
    PHP_FPM_REQUEST_TERMINATE_TIMEOUT=300 \
    PHP_FPM_SLOWLOG_TIMEOUT=0

ENV SMTP_SERVER=example.com
ENV SMTP_PORT=25
ENV SMTP_FROM=mail@example.com
ENV PHP_MEMORY_LIMIT=256M
ENV PHP_MAX_EXEC_TIME=240
ENV PHP_POST_AND_UPLOAD_MAX_SIZE=50M
# PHP runtime tuning (K2, H4)
ENV PHP_OPCACHE_MEMORY=192 \
    PHP_OPCACHE_MAX_FILES=50000 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=1 \
    PHP_OPCACHE_REVALIDATE_FREQ=60 \
    PHP_MYSQLND_NET_READ_TIMEOUT=300

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY ./config/php.ini /usr/local/etc/php/conf.d/zz-propeller.ini
COPY ./config/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY ./config/locale.gen /etc/locale.gen
COPY ./scripts/entrypoint.sh ./scripts/typo3_form_cleanup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/typo3_form_cleanup.sh && \
    # the base image's pool files (www.conf, docker.conf, zz-docker.conf) are replaced by the pool
    # entrypoint.sh writes at startup
    rm -f /usr/local/etc/php-fpm.d/*.conf

RUN mkdir -p /home/propeller/.composer/cache && chown -R propeller:propeller /home/propeller/ && chmod -R 0750 /home/propeller/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        locales \
        libxml2-dev libfreetype6-dev \
        libcurl3-openssl-dev \
        libjpeg62-turbo-dev \
        libmcrypt-dev \
        libpng-dev \
        zlib1g-dev \
        libicu-dev\
        libzip-dev \
        libxslt-dev \
        libonig-dev \
        libldap2-dev \
        wget \
        git \
        jq \
        msmtp \
        sudo \
        ssh-client \
        vim \
        gpg \
        gcc\ 
        g++\
        apt-transport-https \
        libgraphicsmagick1-dev \
        graphicsmagick \
        ghostscript \
        lsb-release \
        mailutils && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-install -j$(nproc) pdo_mysql sysvmsg sysvsem mysqli soap gd zip opcache intl curl bcmath sockets xsl ldap && \
    pecl install redis && docker-php-ext-enable redis && \
    apt-get clean && \
    apt-get -y purge \
        libxml2-dev libfreetype6-dev \
        libjpeg62-turbo-dev \
        libmcrypt-dev \
        libpng-dev \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/* /usr/src/* /tmp/pear

# Add propeller Gitlab to known hosts for composer (skipped if hosts are unreachable, e.g. on public CI)
RUN (ssh-keyscan -T 5 -H gitlab.propeller.de atum.propeller.de >> /etc/ssh/ssh_known_hosts || true)

# Generate and set Locale; verified because locale-gen silently skips a last line without newline
RUN locale-gen && locale -a | grep -qi "^en_US.utf8$"
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
# Set Timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Validate pool generation and the complete FPM configuration at build time (H6); every extension has to load
RUN PHP_FPM_MAX_CHILDREN=4 entrypoint.sh php-fpm -t && \
    for ext in bcmath curl gd intl ldap mysqli pdo_mysql redis soap sockets xsl zip; do php -m | grep -qix "$ext" || { echo "extension $ext failed to load"; exit 1; }; done && \
    php --ini | grep -q zz-propeller.ini

EXPOSE 9000

# SIGQUIT is php-fpm's graceful stop; Kubernetes sends it on pod termination (bounded by process_control_timeout)
STOPSIGNAL SIGQUIT

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]
