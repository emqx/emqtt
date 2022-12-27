CT_NODE_NAME = ct@127.0.0.1

REBAR ?= $(or $(shell which rebar3 2>/dev/null),$(CURDIR)/rebar3)

REBAR_URL := https://github.com/erlang/rebar3/releases/download/3.19.0/rebar3

all: emqtt

$(REBAR):
	curl -fsSL "$(REBAR_URL)" -o $@
	chmod +x $@

emqtt: $(REBAR) escript
	$(REBAR) as emqtt release

pkg: escript
	$(REBAR) as emqtt_pkg release
	make -C packages

compile: $(REBAR)
	$(REBAR) compile

unlock:
	$(REBAR) unlock

clean: distclean

distclean:
	@rm -rf _build _packages erl_crash.dump rebar3.crashdump rebar.lock emqtt_cli rebar3

xref:
	$(REBAR) xref

eunit: compile
	$(REBAR) eunit verbose=true

ct: compile
	$(REBAR) as test ct -v --name $(CT_NODE_NAME)

cover:
	$(REBAR) cover

test: eunit ct cover

dialyzer:
	$(REBAR) dialyzer

escript: $(REBAR) compile
	$(REBAR) as escript escriptize

relup-test: ${REBAR}
	bin/appup_test.sh
