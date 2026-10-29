.PHONY: all build test clean

all: build

build:
	mise exec -- mix compile --warnings-as-errors

test:
	mise exec -- mix test --warnings-as-errors

clean:
	mise exec -- mix clean
