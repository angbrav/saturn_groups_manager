REBAR = $(shell pwd)/rebar
.PHONY: deps compile test

all: deps compile test

compile: deps
	$(REBAR) compile

deps:
	$(REBAR) get-deps

rel: all
	$(REBAR) generate

relclean:
	rm -rf rel/saturn_groups_manager

include tools.mk
