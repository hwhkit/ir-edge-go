# IR Edge —— 机器端程序（ir：CLI + daemon + 本地 Web）
BINARY := ir
BUILD_DIR := dist

.PHONY: build test lint run clean

build:
	@mkdir -p $(BUILD_DIR)
	go build -trimpath -o $(BUILD_DIR)/$(BINARY) ./cmd/ir

test:
	go test -count=1 ./...

lint:
	@files="$$(gofmt -l $$(find . -name '*.go' -not -path './.gocache/*'))"; test -z "$$files" || { echo "gofmt needed:"; echo "$$files"; exit 1; }
	go vet ./...

run:
	go run ./cmd/ir

clean:
	rm -rf $(BUILD_DIR)
