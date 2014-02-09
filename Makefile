.PHONY: test

ERL=erl
BEAMDIR=./deps/*/ebin ./ebin
REBAR=./rebar
REBAR_GEN=../../rebar
DIALYZER=dialyzer

all: update-deps get-deps clean compile xref edoc

get-deps:
	@$(REBAR) get-deps

update-deps:
	@$(REBAR) update-deps

compile:
	@$(REBAR) compile

xref:
	@$(REBAR) xref skip_deps=true

clean:
	@$(REBAR) clean

test:
	@$(REBAR) skip_deps=true eunit

edoc:
	./make_doc

dialyzer: compile
	@$(DIALYZER) ebin deps/ossp_uuid/ebin

setup-dialyzer:
	@$(DIALYZER) --build_plt --apps kernel stdlib mnesia eunit erts crypto
