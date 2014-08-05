-module(nfs_rpc_app).
-behaviour(application).

-include("nfs_rpc_app.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start/0]).
%% Callback for application
-export([start/2, prep_stop/1, stop/1]).

-define(LOCALHOST_ADDR, {127, 0, 0, 1}).

-type rpc_app_args() :: [#nfs_rpc_app_arg{}].

-record(state, {
          args :: rpc_app_args()
         }).

%% API
start() ->
    application:ensure_started(ranch),
    application:start(?MODULE).

%% Callback  for application
start(_Type, _Args) ->
    {ok, Args} = application:get_env(nfs_rpc_server, args),
    NewArgs = start_rpc_server(Args),
    {ok, Pid} = nfs_rpc_server_sup:start_link(),
    {ok, Pid, #state{args = NewArgs}}.

prep_stop(#state{args = Args}) ->
    stop_rpc_server(Args),
    ok.

stop(_State) ->
    ok.

%% private
%% start/stop a rpc server
start_rpc_server(Args) ->
    start_rpc_server(Args, []).

start_rpc_server([], Acc) ->
    Acc;
start_rpc_server([#nfs_rpc_app_arg{
                     ref          = Ref,
                     acceptor_num = NbAcceptors,
                     trans_opts   = TransOpts,
                     prg_name     = ProgName,
                     vsn_lo       = ProgVsnLo,
                     vsn_hi       = ProgVsnHi,
                     use_pmap     = UsePmap,
                     mod          = Mod,
                     init_args    = InitArgs} = Arg|Tail], Acc) ->
    {ok, State} = apply(Mod, init, [InitArgs]),
    PrgVsns = lists:map(
                fun(V) ->
                        {V, list_to_atom(atom_to_list(ProgName) ++ "_" ++
                                             integer_to_list(V))}
                end, lists:seq(ProgVsnLo, ProgVsnHi)),
    NewArg = Arg#nfs_rpc_app_arg{prg_vsns = PrgVsns, state = State},
    %% start server via ranch
    ranch:start_listener(Ref, NbAcceptors, ranch_tcp, TransOpts, nfs_rpc_proto, NewArg),
    register_with_portmapper(NewArg, UsePmap),
    start_rpc_server(Tail, [NewArg|Acc]).

stop_rpc_server([]) ->
    ok;
stop_rpc_server([#nfs_rpc_app_arg{
                    ref          = Ref,
                    use_pmap     = UsePmap} = Arg|Tail]) ->
    unregister_with_portmapper(Arg, UsePmap),
    ranch:stop_listener(Ref),
    stop_rpc_server(Tail).

%% pmap procs
register_with_portmapper(_Arg, false) ->
    ok;
register_with_portmapper(Arg, true) ->
    pmap_reg(Arg, set).

unregister_with_portmapper(_Arg, false) ->
    ok;
unregister_with_portmapper(Arg, true) ->
    pmap_reg(Arg, unset).

pmap_reg(undefined, _Func) -> ok;
pmap_reg(#nfs_rpc_app_arg{
            trans_opts = TransOpts,
            prg_num    = Prg,
            prg_vsns   = Vsns}, Func) ->
    Port = proplists:get_value(port, TransOpts),
    {ok, PClnt} = pmap:open(?LOCALHOST_ADDR),
    lists:foreach(fun({Vsn, _Fun}) ->
                          case pmap:Func(PClnt, Prg, Vsn, tcp, Port) of
                              {ok, true} ->
                                  pmap:close(PClnt);
                              {ok, false} ->
                                  pmap:close(PClnt),
                                  exit(pmap_reg)
                          end
                  end, Vsns).
