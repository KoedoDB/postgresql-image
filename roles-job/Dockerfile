# The image of KoedoDB's roles Job (koedodb-reconcile-roles passwords): only the program, bash and the PostgreSQL 18 client (psql, pg_isready). It is not the database image: that one
# declares VOLUME /var/lib/postgresql (from the upstream image), which a Pod without a block volume at that path cannot start in a cchv microVM, and the Job needs no server.
# The client is the database's major (18), from the PostgreSQL project's own repository (Debian 13 has 17 only); the key is checked against its fingerprint.
#
#   docker build -t registry.koedodb-stg.com/sys-postgres/roles-job:<tag> roles-job/
#
# The program is a copy of ../koedodb-reconcile-roles (the database image keeps its own copy); keep the two the same.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
RUN set -eux; \
    apt-get update; \
    apt-get install --yes --no-install-recommends ca-certificates curl gnupg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /tmp/pgdg.asc; \
    test "$(gpg --show-keys --with-colons /tmp/pgdg.asc | awk -F: '/^fpr:/{print $10; exit}')" = B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8; \
    gpg --dearmor -o /usr/share/keyrings/pgdg.gpg /tmp/pgdg.asc; \
    echo 'deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main' > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install --yes --no-install-recommends postgresql-client-18; \
    apt-get purge --yes --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/* /tmp/pgdg.asc
COPY --chmod=0755 koedodb-reconcile-roles /usr/local/bin/koedodb-reconcile-roles
ENTRYPOINT ["/usr/local/bin/koedodb-reconcile-roles"]
