.PHONY: all build test cyclecheck lint typecheck test-postgres test-cluster test-postgres-tls test-image pg-up pg-down clean

all: build

build:
	mise exec -- mix compile --warnings-as-errors

test:
	mise exec -- mix test --warnings-as-errors

lint:
	mise exec -- mix lint:quick

typecheck:
	mise exec -- mix lint

cyclecheck:
	mise exec -- mix xref graph --format cycles --label compile-connected --fail-above 0
	mise exec -- mix xref graph --format cycles --label compile --fail-above 0

clean:
	mise exec -- mix clean

PG_PORT ?= 55433
PG_URL := ecto://postgres:postgres@127.0.0.1:$(PG_PORT)

# A throwaway PostgreSQL 18 in Docker, with the suite's database and a separate one for the
# migration property (it migrates down). `make pg-down` removes it.
pg-up:
	docker rm -f sp-pg >/dev/null 2>&1 || true
	docker run -d --name sp-pg -p $(PG_PORT):5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=super_pi_test postgres:18 >/dev/null
	# TCP check: the init-time server listens only on the Unix socket.
	for i in $$(seq 1 30); do docker exec sp-pg pg_isready -h 127.0.0.1 -U postgres >/dev/null && break; sleep 1; done
	docker exec sp-pg createdb -h 127.0.0.1 -U postgres super_pi_migration

pg-down:
	docker rm -f sp-pg >/dev/null 2>&1 || true

# The whole suite on PostgreSQL, then the :postgres tests (real concurrency, migration property).
# Needs Docker.
test-postgres: pg-up
	SUPER_PI_STORAGE_BACKEND=postgres DATABASE_URL=$(PG_URL)/super_pi_test mise exec -- mix test && \
	SUPER_PI_STORAGE_BACKEND=postgres DATABASE_URL=$(PG_URL)/super_pi_test SUPER_PI_MIGRATION_TEST_URL=$(PG_URL)/super_pi_migration \
	  mise exec -- mix test --only postgres; \
	  status=$$?; $(MAKE) pg-down; exit $$status

# Multi-node tests: three Erlang nodes against PostgreSQL. Needs DATABASE_URL (`make pg-up` gives
# ecto://postgres:postgres@127.0.0.1:55433/super_pi_test). Starts epmd.
test-cluster:
	mise exec -- epmd -daemon
	SUPER_PI_STORAGE_BACKEND=postgres mise exec -- elixir --erl "-hidden" --name sp_ctl@127.0.0.1 --cookie super_pi_cluster_test -S mix test --only cluster test/super_pi/cluster_test.exs

TLS_DIR := $(CURDIR)/tmp/tls
TLS_PORT ?= 55432

# Real TLS to PostgreSQL: require, verify-full with the right CA, refusal with a wrong CA or host name.
# Needs Docker and openssl.
test-postgres-tls:
	rm -rf $(TLS_DIR) && mkdir -p $(TLS_DIR)
	cd $(TLS_DIR) && \
	  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=test-ca" && \
	  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" && \
	  printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > san.cnf && \
	  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile san.cnf && \
	  openssl req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other-ca.pem -days 2 -subj "/CN=other-ca"
	docker rm -f sp-pgtls >/dev/null 2>&1 || true
	docker run -d --name sp-pgtls -p $(TLS_PORT):5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=sp_tls \
	  -v "$(TLS_DIR):/tls:ro" --entrypoint sh postgres:18 -c \
	  'cp /tls/server.pem /tls/server.key /var/lib/postgresql/ && chown postgres:postgres /var/lib/postgresql/server.* && chmod 600 /var/lib/postgresql/server.key && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/var/lib/postgresql/server.pem -c ssl_key_file=/var/lib/postgresql/server.key'
	# TCP check: the init-time server listens only on the Unix socket.
	for i in $$(seq 1 30); do docker exec sp-pgtls pg_isready -h 127.0.0.1 -U postgres && break; sleep 1; done
	SUPER_PI_TLS_TEST_URL=ecto://postgres:postgres@127.0.0.1:$(TLS_PORT)/sp_tls \
	SUPER_PI_TLS_TEST_CA=$(TLS_DIR)/ca.pem \
	SUPER_PI_TLS_TEST_WRONG_CA=$(TLS_DIR)/other-ca.pem \
	  mise exec -- mix test --only postgres test/super_pi/postgres_tls_test.exs; \
	  status=$$?; docker rm -f sp-pgtls >/dev/null; exit $$status

IMAGE_PORT ?= 4000

# The release image builds, starts and answers /health. Needs Docker.
test-image:
	docker build -t super-pi .
	docker rm -f sp-image-test >/dev/null 2>&1 || true
	docker run -d --name sp-image-test -p $(IMAGE_PORT):4000 -e SUPER_PI_SQLITE_PATH=/tmp/sp.db -e SUPER_PI_AUTO_MIGRATE=true \
	  -e SUPER_PI_GATEWAY_BIND=0.0.0.0 -e SUPER_PI_GATEWAY_TOKEN=test-image super-pi
	status=1; for i in $$(seq 1 30); do curl -fsS localhost:$(IMAGE_PORT)/health && { status=0; break; }; sleep 1; done; \
	  [ $$status -eq 0 ] || docker logs sp-image-test; docker rm -f sp-image-test >/dev/null; exit $$status
