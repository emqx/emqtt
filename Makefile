CT_NODE_NAME = ct@127.0.0.1

REBAR := $(CURDIR)/rebar3

REBAR_URL := https://github.com/emqx/rebar3/releases/download/3.14.3-emqx-8/rebar3

all: emqtt

$(REBAR):
	@curl -k -f -L "$(REBAR_URL)" -o ./rebar3
	@chmod +x ./rebar3

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

dialyzer:
	$(REBAR) dialyzer

escript: $(REBAR) compile
	$(REBAR) as escript escriptize
