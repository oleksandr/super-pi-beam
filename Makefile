.PHONY: all build test test-cluster clean

all: build

build:
	mise exec -- mix compile --warnings-as-errors

test:
	mise exec -- mix test --warnings-as-errors

clean:
	mise exec -- mix clean

# Multi-node tests: three Erlang nodes against PostgreSQL. Needs DATABASE_URL and a running epmd.
test-cluster:
	epmd -daemon
	SUPER_PI_STORAGE_BACKEND=postgres mise exec -- elixir --erl "-hidden" --name sp_ctl@127.0.0.1 --cookie super_pi_cluster_test -S mix test --only cluster test/super_pi/cluster_test.exs
