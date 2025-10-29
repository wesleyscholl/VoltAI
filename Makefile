.PHONY: build run index query

build:
	cargo build --release

run: build
	./target/release/voltai

index: build
	./target/release/voltai index -d docs -o voltai_index.json

query: build
	./target/release/voltai query -i voltai_index.json -q "example query" -k 5
