REBAR := rebar3

.PHONY: all
all: compile

compile: get_deps
	$(REBAR) compile

with_ws: get_deps
	$(REBAR) compile as ws

get_deps:
	$(REBAR) get-deps

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump rebar.lock

.PHONY: xref
xref:
	$(REBAR) xref

.PHONY: eunit
eunit: compile
	$(REBAR) eunit verbose=truen

.PHONY: ct
ct: compile
	$(REBAR) ct -v

.PHONY: dialyzer
dialyzer:
	$(REBAR) dialyzer

