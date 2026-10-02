# syntax=docker/dockerfile:1
#
# Moodle on NGINX + PHP-FPM, as two images built from one Dockerfile:
#
#   docker build --target fpm   -t moodle-fpm   .
#   docker build --target nginx -t moodle-nginx .
#
# Both images carry the identical Moodle codebase at /var/www/moodle, so the
# NGINX container can serve static files and hand PHP paths to FPM without a
# shared volume. Run them side by side (e.g. one Kubernetes pod) with FPM on
# 127.0.0.1:9000.

ARG PHP_VERSION=8.4

# ---------------------------------------------------------------------------
# src: fetch Moodle at build time. MOODLE_VERSION is a release number such as
# 5.2.1, or "latest" for the newest stable release tag (no betas/RCs).
# ---------------------------------------------------------------------------
FROM alpine:3 AS src
ARG MOODLE_VERSION=latest
ARG MOODLE_REPO=https://github.com/moodle/moodle.git
# coreutils for GNU `sort -V`
RUN apk add --no-cache git coreutils
RUN set -eu; \
    version="${MOODLE_VERSION#v}"; \
    if [ "$version" = "latest" ]; then \
        version="$(git ls-remote --tags --refs "$MOODLE_REPO" 'v*' \
            | sed 's#.*refs/tags/v##' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V | tail -n 1)"; \
    fi; \
    test -n "$version"; \
    echo "Fetching Moodle ${version}"; \
    git clone --depth 1 --branch "v${version}" "$MOODLE_REPO" /moodle; \
    rm -rf /moodle/.git; \
    echo "$version" > /moodle/.image-version

# ---------------------------------------------------------------------------
# plugins: add the third-party plugins listed in plugins.txt. A separate stage,
# so editing the list doesn't re-fetch Moodle. The code is read-only at
# runtime, so this is the only way to add plugins (the web installer can't).
# ---------------------------------------------------------------------------
FROM src AS plugins
RUN apk add --no-cache curl unzip
COPY plugins.txt scripts/install-plugins.sh /tmp/
RUN sh /tmp/install-plugins.sh /tmp/plugins.txt /moodle

# ---------------------------------------------------------------------------
# php-base: PHP-FPM with the extensions and settings Moodle requires.
# ---------------------------------------------------------------------------
FROM php:${PHP_VERSION}-fpm AS php-base
COPY --from=mlocati/php-extension-installer:latest /usr/bin/install-php-extensions /usr/local/bin/
# sodium, curl, mbstring, xml, iconv, ctype, fileinfo are built into the base image
RUN install-php-extensions gd intl mysqli opcache soap zip exif
COPY conf/php/zz-moodle.ini /usr/local/etc/php/conf.d/zz-moodle.ini
COPY conf/php-fpm/zz-moodle.conf /usr/local/etc/php-fpm.d/zz-moodle.conf

# ---------------------------------------------------------------------------
# build: install Moodle's Composer runtime dependencies into vendor/.
# Required since Moodle 5.1 — it refuses to start without vendor/. Runs on
# php-base so Composer's platform (extension) checks are real.
# ---------------------------------------------------------------------------
FROM php-base AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git unzip \
 && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
COPY --from=plugins /moodle /moodle
WORKDIR /moodle
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN composer install --no-dev --classmap-authoritative --no-interaction --no-progress

# ---------------------------------------------------------------------------
# fpm: runs as www-data (33); mount moodledata writable for that UID/GID.
# ---------------------------------------------------------------------------
FROM php-base AS fpm
COPY --from=build /moodle /var/www/moodle
RUN mkdir -p /var/moodledata /var/cache/moodle \
 && chown www-data:www-data /var/moodledata /var/cache/moodle
WORKDIR /var/www/moodle
USER www-data

# ---------------------------------------------------------------------------
# nginx: unprivileged NGINX (UID 101) on port 8080, docroot public/ (Moodle 5.1+).
# ---------------------------------------------------------------------------
FROM nginxinc/nginx-unprivileged:stable-alpine AS nginx
COPY conf/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /moodle /var/www/moodle
EXPOSE 8080
