.PHONY: build run index query

build:
	cargo build --release

run: build
	./target/release/boltai

index: build
	./target/release/boltai index -d docs -o boltai_index.json

query: build
	./target/release/boltai query -i boltai_index.json -q "example query" -k 5
