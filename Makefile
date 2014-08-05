.PHONY: deps test

REBAR := ./rebar

all:
	@$(REBAR) update-deps
	@$(REBAR) get-deps
	(cd deps/erpcgen/;make)
	(cd src && erl -noshell -pa ../deps/erpcgen/ebin -eval 'erpcgen:file(pmap,    [xdrlib,clnt])' -s init stop)
	(cd src && erl -noshell -pa ../deps/erpcgen/ebin -eval 'erpcgen:file(nfs_rpc, [xdrlib,clnt])' -s init stop)
	@$(REBAR) compile
	@$(REBAR) xref skip_deps=true
	@$(REBAR) eunit skip_deps=true
compile:
	@$(REBAR) compile skip_deps=true
xref:
	@$(REBAR) xref skip_deps=true
eunit:
	@$(REBAR) eunit skip_deps=true
doc: compile
	@$(REBAR) doc
clean:
	@$(REBAR) clean skip_deps=true
distclean:
	@$(REBAR) delete-deps
	@$(REBAR) clean
