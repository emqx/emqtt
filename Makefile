CT_NODE_NAME = ct@127.0.0.1
CT_EMQX_PROFILE = emqx

REBAR ?= $(or $(shell which rebar3 2>/dev/null),$(CURDIR)/rebar3)
REBAR_TEST = env PROFILE=$(CT_EMQX_PROFILE) $(REBAR)

REBAR_URL := https://github.com/erlang/rebar3/releases/download/3.19.0/rebar3

export REBAR_GIT_CLONE_OPTIONS += --depth=1

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
	$(REBAR_TEST) eunit --verbose

ct: compile
	$(REBAR_TEST) as test ct --verbose --name $(CT_NODE_NAME)

cover:
	$(REBAR_TEST) cover

test: eunit ct cover

dialyzer:
	$(REBAR) dialyzer

escript: $(REBAR) compile
	$(REBAR) as escript escriptize

relup-test: ${REBAR}
	bin/appup_test.sh
