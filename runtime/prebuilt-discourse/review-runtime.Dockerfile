# Public stock, version-independent review overlay. No customer context is sent.
# Both required arguments are supplied by the host after validating public metadata.
ARG STOCK_IMAGE
FROM ${STOCK_IMAGE} AS stock

FROM stock AS build
USER root
ARG EXPECTED_LOCK_SHA256
RUN set -eu; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends gcc g++ make libc6-dev libsqlite3-dev pkg-config >/dev/null; \
    cd /var/www/discourse; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    find vendor/bundle -type f -o -type l | LC_ALL=C sort > /tmp/bundle-before; \
    su discourse -c 'cd /var/www/discourse && BUNDLE_FROZEN=true BUNDLE_WITH=generic_import bundle install --jobs 2 --retry 0 --quiet && BUNDLE_FROZEN=true BUNDLE_WITH=generic_import bundle check'; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    find vendor/bundle -type f -o -type l | LC_ALL=C sort > /tmp/bundle-after; \
    LC_ALL=C comm -13 /tmp/bundle-before /tmp/bundle-after > /tmp/bundle-added; \
    mkdir -p /overlay/var/www/discourse/vendor/bundle; \
    tar -cf - -T /tmp/bundle-added | tar -xf - -C /overlay/var/www/discourse

FROM stock
# Stock currently defaults to root, as does the existing prebuilt recipe.
# Set it explicitly for build operations without changing the upstream entrypoint.
USER root
COPY --from=build --chown=discourse:discourse /overlay/var/www/discourse/vendor/bundle/ /var/www/discourse/vendor/bundle/
ARG EXPECTED_LOCK_SHA256
RUN set -eu; \
    cd /var/www/discourse; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    su discourse -c 'cd /var/www/discourse && BUNDLE_FROZEN=true BUNDLE_WITH=generic_import bundle check && BUNDLE_FROZEN=true BUNDLE_WITH=generic_import bundle exec ruby -e "require %q(sqlite3); require %q(redcarpet)"'
