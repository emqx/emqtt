.PHONY: all compile unlock clean distclean xref eunit ct dialyzer

CT_NODE_NAME = ct@127.0.0.1

REBAR := $(CURDIR)/rebar3

REBAR_URL := https://s3.amazonaws.com/rebar3/rebar3

all: emqtt

emqtt: compile
	$(REBAR) as emqtt release

pkg: escript
	$(REBAR) as emqtt_pkg release
	make -C packages

compile: escript
	$(REBAR) compile

unlock:
	$(REBAR) unlock

clean: distclean

distclean:
	@rm -rf _build _packages erl_crash.dump rebar3.crashdump rebar.lock emqtt_cli

xref:
	$(REBAR) xref

eunit: compile
	$(REBAR) eunit verbose=true

ct: compile
	$(REBAR) as test ct -v --name $(CT_NODE_NAME)

cover:
	$(REBAR) cover

dialyzer:
	$(REBAR) dialyzer

escript:
	$(REBAR) as escript escriptize

