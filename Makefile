.PHONY: all compile unlock clean distclean xref eunit ct dialyzer

export WITH_WS

REBAR := rebar3

all: compile

compile:
	$(REBAR) compile

unlock:
	$(REBAR) unlock

clean: distclean

distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump rebar.lock

xref:
	$(REBAR) xref

eunit: compile
	$(REBAR) eunit verbose=true

ct: compile
	$(REBAR) ct -v

dialyzer:
	$(REBAR) dialyzer

