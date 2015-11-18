REBAR = $(shell pwd)/rebar
.PHONY: deps compile test

all: deps compile test

compile: deps
	$(REBAR) compile

deps:
	$(REBAR) get-deps

include tools.mk
