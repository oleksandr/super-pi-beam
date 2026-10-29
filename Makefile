.PHONY: all build build-elixir build-tui test test-elixir test-tui run-tui clean

all: build

build: build-elixir build-tui

build-elixir:
	mise exec -- mix compile --warnings-as-errors

build-tui:
	cd clients/agy-tui && mise exec -- go build -o ../../bin/agy-tui ./cmd/agy-tui

test: test-elixir test-tui

test-elixir:
	mise exec -- mix test --warnings-as-errors

test-tui:
	cd clients/agy-tui && mise exec -- go test -v ./...

run-tui: build-tui
	./bin/super-agy

clean:
	rm -f bin/agy-tui
	mise exec -- mix clean
