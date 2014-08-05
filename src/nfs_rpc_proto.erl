-module(nfs_rpc_proto).

%% Callback from ranch
-export([start_link/4]).

%% External exports
-export([client_ip/1, client_socket/1, reply/3]).

%% Internal use
-export([init/4]).

-record(client, {
          sock,
          addr,  % {Ip, Port} for udp, 'sock' for tcp
          xid,
          rverf}).

-include("nfs_rpc.hrl").
-include("nfs_rpc_app.hrl").

-define(LOCALHOST_ADDR, {127, 0, 0, 1}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start_link(Ref, Socket, Transport, State) ->
    Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, State]),
    {ok, Pid}.

%%-----------------------------------------------------------------
%% Func: client_ip(#client) -> {ok, {ip(), Port}} | {error, Reason}
%% Purpose: Returns the IP address and port of the client of this
%%          session.  Can be used by a server implementation to
%%          get info about a certain client.
%%          Ref is passed to the server implementation code in
%%          each call.
%%-----------------------------------------------------------------
client_ip(Clnt) when Clnt#client.addr == sock ->
    inet:peername(Clnt#client.sock);
client_ip(Clnt) ->
    {ok, Clnt#client.addr}.

%%-----------------------------------------------------------------
%% Func: client_socket(#client) -> Sock
%% Purpose: Returns the socket associated with a client.  Note that
%%          for UDP, all clients are multiplexed onto the same
%%          socket.
%%          Ref is passed to the server implementation code in
%%          each call.
%%-----------------------------------------------------------------
client_socket(Clnt) ->
    Clnt#client.sock.

%%-----------------------------------------------------------------
%% Func: reply(Clnt, Status, Bytes) -> void
%% Types: Clnt = #client
%%        Status = success | garbage_args | error
%%        Bytes = io_list of bytes, IFF Status == success
%% Purpose: Send a rpc reply back to the client.  MUST only be
%%          called if the callback module returned {noreply, S'}
%%          on the original call.
%%-----------------------------------------------------------------
reply(Clnt, Status, Bytes) ->
    do_reply(Status, Bytes, Clnt).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, S}          |
%%          {ok, S, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
init(Ref, Socket, Transport, State) ->
    ok = ranch:accept_ack(Ref),
    wait_request(<<>>, Socket, Transport, State).

wait_request(Buffer, Socket, Transport, State) ->
    %% First, get the Record Marking 32-bit header
    case Transport:recv(Socket, 4, infinity) of
        {ok, <<Last:1/integer, Len:31/integer>>} ->
            %% Second, get the fragment data which size is `Len`
            case Transport:recv(Socket, Len, infinity) of
                {ok, Data} ->
                    case Last of
                        0 ->
                            %% wait next fragment
                            wait_request(<<Buffer/binary, Data/binary>>,
                                         Socket,
                                         Transport,
                                         State);
                        1 ->
                            %% Received all fragments, we can process those as one rpc message
                            NewState = handle_msg(<<Buffer/binary, Data/binary>>, Socket, sock, State),
                            wait_request(<<>>, Socket, Transport, NewState)
                    end;
                {error, closed} ->
                    Transport:close(Socket);
                {error, Reason} ->
                    log_error("wait_request/4", State, {recv_error, Reason}),
                    Transport:close(Socket)
            end;
        {error, closed} ->
            Transport:close(Socket);
        {error, Reason} ->
            log_error("wait_request/4", State, {recv_error, Reason}),
            Transport:close(Socket)
    end.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
handle_msg(Msg, Sock, Addr, S) ->
    case catch handle_msg1(Msg, Sock, Addr, S) of
        {accepted, {Status, Bytes, NState}, Clnt} ->
            do_reply(Status, Bytes, Clnt),
            S#nfs_rpc_app_arg{state = NState};
        {accepted, {_ErrorStatus, _ErrorDetail} = ErrorRep, Clnt} ->
            do_reply(ErrorRep, Clnt),
            S;
        {rejected, Clnt, RejectBody, NState} ->
            Reply = {Clnt#client.xid, {'REPLY', {'MSG_DENIED', RejectBody}}},
            send_reply(Clnt, nfs_rpc_xdr:enc_rpc_msg(Reply)),
            S#nfs_rpc_app_arg{state = NState};
        {noreply, NState} -> % the callback replies later
            S#nfs_rpc_app_arg{state = NState};
        {'EXIT', Reason} ->
            log_error("handle_msg/4", S, {rpc_msg, Reason}),
            S
    end.

%% The call to this function is catched, which means that bad
%% rpc messages and programming errors are handled the same way,
%% both end up in the error log.
handle_msg1(Msg, Sock, Addr, S) ->
    {{Xid, Body}, Off} = nfs_rpc_xdr:dec_rpc_msg(Msg, 0),
    {'CALL', {RpcVsn, Prg, Vsn, Proc, Cred, Verf}} = Body,
    Clnt0 = #client{sock = Sock, addr = Addr, xid = Xid},
    chk_rpc_vsn(RpcVsn, Clnt0),
    Clnt1 = chk_auth(Cred, Verf, Clnt0),
    Fun = chk_prg(Prg, Vsn, S, Clnt1),
    %% Ok, we're ready to call the implementation
    case (catch apply(S#nfs_rpc_app_arg.mod, Fun, [Proc,Msg,Off,Clnt1,S#nfs_rpc_app_arg.state])) of
        X = {success, _Bytes, _NState} ->
            {accepted, X, Clnt1};
        {garbage_args, NState} ->
            {accepted, {garbage_args, [], NState}, Clnt1};
        {noreply, NState} ->
            {noreply, NState};
        {error, NState} ->
            {accepted, {error, [], NState}, Clnt1};
        {'EXIT', Reason} ->
            log_error("handle_msg1/4", S, {S#nfs_rpc_app_arg.mod, Reason}),
            {accepted, {error, [], S#nfs_rpc_app_arg.state}, Clnt1}
    end.

do_reply(ErrorRep, Clnt) ->
    Reply = accepted(Clnt, ErrorRep),
    send_reply(Clnt, nfs_rpc_xdr:enc_rpc_msg(Reply)).

do_reply(success, Bytes, Clnt) ->
    Reply = accepted(Clnt, {'SUCCESS', <<>>}),
    send_reply(Clnt, [nfs_rpc_xdr:enc_rpc_msg(Reply), Bytes]);
do_reply(garbage_args, _, Clnt) ->
    Reply = accepted(Clnt, {'GARBAGE_ARGS', void}),
    send_reply(Clnt, nfs_rpc_xdr:enc_rpc_msg(Reply));
do_reply(error, _, Clnt) ->
    Reply = accepted(Clnt, {'SYSTEM_ERR', void}),
    send_reply(Clnt, nfs_rpc_xdr:enc_rpc_msg(Reply)).

accepted(C, AcceptBody) ->
    {C#client.xid, {'REPLY', {'MSG_ACCEPTED', {C#client.rverf, AcceptBody}}}}.

%% we support RPC version 2 only.
chk_rpc_vsn(?RPC_VERSION_2, _Clnt) -> ok;
chk_rpc_vsn(_, Clnt) -> throw({rejected, Clnt,
                               {'RPC_MISMATCH',
                                {?RPC_VERSION_2, ?RPC_VERSION_2}}}).

%% we should implement a more flexible authentication scheme...
chk_auth({'AUTH_NONE', _}, {'AUTH_NONE', _}, Clnt) ->
    Clnt#client{rverf = {'AUTH_NONE', <<>>}};
chk_auth({'AUTH_SYS', _}, {'AUTH_NONE', _}, Clnt) ->
    Clnt#client{rverf = {'AUTH_NONE', <<>>}};
chk_auth(_,_, Clnt) -> throw({rejected, Clnt, {'AUTH_ERROR', 'AUTH_TOOWEAK'}}).

chk_prg(Prg, Vsn, S, Clnt) ->
    if
        Prg /= S#nfs_rpc_app_arg.prg_num ->
            throw({accepted, {'PROG_UNAVAIL', void}, Clnt});
        true ->
            case lists:keysearch(Vsn, 1, S#nfs_rpc_app_arg.prg_vsns) of
                {value, {_, Fun}} -> Fun;
                _ ->
                    throw({accepted,
                           {'PROG_MISMATCH',
                            {element(1, hd(S#nfs_rpc_app_arg.prg_vsns)),
                             element(1, lists:last(S#nfs_rpc_app_arg.prg_vsns))}}, Clnt})
            end
    end.

send_reply(Clnt, Reply) when Clnt#client.addr == sock ->
    Len = io_list_len(Reply),
    gen_tcp:send(Clnt#client.sock,
                 [<<1:1/integer, Len:31/unsigned-integer>>, Reply]);
send_reply(#client{sock = S, addr = {Ip, Port}}, Reply) ->
    gen_udp:send(S, Ip, Port, Reply).

log_error(Fun, S, Term) ->
    Cause = io_lib:format("nfs_rpc_server: prog:~p vsns:~p ~p\n",
                          [S#nfs_rpc_app_arg.prg_num,
                           S#nfs_rpc_app_arg.prg_vsns,
                           Term]),
    error_logger:error_msg("~p,~p,~p,~p~n",
                           [{module, ?MODULE_STRING},
                            {function, Fun},
                            {line, ?LINE}, {body, Cause}]).

io_list_len(L) -> io_list_len(L, 0).
io_list_len([H|T], N) ->
    if
        H >= 0, H =< 255 -> io_list_len(T, N+1);
        is_list(H) -> io_list_len(T, io_list_len(H,N));
        is_binary(H) -> io_list_len(T, size(H) + N);
        true -> exit({xdr, opaque})
    end;
io_list_len(H, N) when is_binary(H) ->
    size(H) + N;
io_list_len([], N) ->
    N.
