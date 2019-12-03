.PHONY: all compile unlock clean distclean xref eunit ct dialyzer

CT_NODE_NAME = ct@127.0.0.1

REBAR := $(CURDIR)/rebar3

REBAR_URL := https://s3.amazonaws.com/rebar3/rebar3

all: compile

compile:
	$(REBAR) compile

unlock:
	$(REBAR) unlock

clean: distclean

distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump rebar.lock emqtt_cli

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

.PHONY: $(REBAR)
$(REBAR):
ifneq ($(wildcard rebar3),rebar3)
	@curl -Lo rebar3 $(REBAR_URL) || wget $(REBAR_URL)
endif
	@chmod a+x rebar3
