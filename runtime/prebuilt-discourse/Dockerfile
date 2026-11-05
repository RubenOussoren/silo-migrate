# Minimal migration overlay on the stock prebuilt Discourse web image.
# The stock image omits the optional `generic_import` gem group, and its Ruby
# has no compiler. The compiler stays in the discarded build stage; only the
# two locked gems are copied into the final image. Gemfile.lock is unchanged.
ARG STOCK_IMAGE=docker.io/discourse/discourse@sha256:f847da87e77b0506eae2167d75f0cce500cf174fde7127b60e33baaafeab65ec
FROM ${STOCK_IMAGE} AS stock

FROM stock AS build
ARG EXPECTED_LOCK_SHA256=bacaa276aebc56385bf28c9fefbc6224e494e0361bd734933b4a20427e0f87d2
RUN set -eu; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends gcc make libc6-dev >/dev/null; \
    cd /var/www/discourse; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    su discourse -c 'cd /var/www/discourse && BUNDLE_WITH=generic_import bundle install --jobs 2 --retry 0 --quiet'; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    # Only the two locked gem trees (gems, specs, compiled extensions, cache).
    find vendor/bundle \( -name 'redcarpet-3.6.1*' -o -name 'sqlite3-2.9.6-x86_64-linux-gnu*' \) -prune -print | sort > /tmp/new-paths; \
    test -s /tmp/new-paths; \
    mkdir -p /overlay/var/www/discourse; \
    tar -cf - -T /tmp/new-paths | tar -xf - -C /overlay/var/www/discourse; \
    cat /tmp/new-paths

FROM stock
COPY --from=build --chown=discourse:discourse /overlay/var/www/discourse/vendor/bundle/ /var/www/discourse/vendor/bundle/
ARG EXPECTED_LOCK_SHA256=bacaa276aebc56385bf28c9fefbc6224e494e0361bd734933b4a20427e0f87d2
RUN set -eu; \
    cd /var/www/discourse; \
    echo "$EXPECTED_LOCK_SHA256  Gemfile.lock" | sha256sum -c -; \
    su discourse -c 'cd /var/www/discourse && BUNDLE_WITH=generic_import bundle check && BUNDLE_WITH=generic_import bundle exec ruby -e "require %q(sqlite3); require %q(redcarpet); puts [SQLite3::VERSION, Redcarpet::VERSION, SQLite3::SQLITE_VERSION].join(%q( ))"'; \
    mkdir -p /usr/local/share/silo-migrate; \
    echo 'discourse-prebuilt-migration' > /usr/local/share/silo-migrate/profile
# The stock image's boot-time migrate/precompile stay as upstream defaults;
# the operation layer sets these explicitly per container.
