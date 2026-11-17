CT_NODE_NAME = ct@127.0.0.1
## The CT suites run against an EMQX broker in a container.
## `docker': `make ct' starts the container and removes it after the run.
## `external': the broker is already running, for example started by CI with
## `scripts/ct-broker.sh up'.
CT_BROKER ?= docker

REBAR := $(CURDIR)/rebar3

REBAR_URL := https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3

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

unlock: $(REBAR)
	$(REBAR) unlock

clean: distclean

distclean:
	@rm -rf _build _packages erl_crash.dump rebar3.crashdump rebar.lock emqtt_cli rebar3

xref: $(REBAR)
	$(REBAR) xref

eunit: compile
	$(REBAR) eunit --verbose

ct: compile
ifeq ($(CT_BROKER),docker)
	scripts/ct-broker.sh up
	$(REBAR) as test ct --verbose --name $(CT_NODE_NAME); \
	  rc=$$?; scripts/ct-broker.sh down; exit $$rc
else
	$(REBAR) as test ct --verbose --name $(CT_NODE_NAME)
endif

ct-broker-up:
	scripts/ct-broker.sh up

ct-broker-down:
	scripts/ct-broker.sh down

cover: $(REBAR)
	$(REBAR) cover

test: eunit ct cover

dialyzer: $(REBAR)
	$(REBAR) dialyzer

escript: $(REBAR) compile
	$(REBAR) as escript escriptize

relup-test: ${REBAR}
	bin/appup_test.sh
