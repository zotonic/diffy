PROJECT = diffy

ERL       ?= erl
ERLC      ?= $(ERL)c
REBAR     := ./rebar3
REBAR_URL := https://s3.amazonaws.com/rebar3/rebar3
DIALYZER  = dialyzer

all: compile

$(REBAR):
	$(ERL) -noshell -s inets -s ssl \
	  -eval '{ok, saved_to_file} = httpc:request(get, {"$(REBAR_URL)", []}, [], [{stream, "$(REBAR)"}])' \
	  -s init stop
	chmod +x $(REBAR)

compile: $(REBAR)
	$(REBAR) compile

test: eunit

eunit: $(REBAR)
	$(REBAR) as test eunit

xref: $(REBAR)
	$(REBAR) as test xref

dialyzer: $(REBAR)
	$(REBAR) as test dialyzer

clean: $(REBAR)
	$(REBAR) clean

distclean:
	rm -rf _build
	rm $(REBAR)


# dializer 

build-plt:
	@$(DIALYZER) --build_plt --output_plt .$(PROJECT).plt \
		--apps erts kernel stdlib -r deps

dialyze:
	@$(DIALYZER) -pa deps/*/ebin --src src --plt .$(PROJECT).plt --no_native \
		-Werror_handling -Wrace_conditions -Wunmatched_returns 
