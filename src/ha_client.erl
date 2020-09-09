%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 04. Sep 2020 5:00 PM
%%%-------------------------------------------------------------------
-module(ha_client).
-author("nikola").

-behavior(gen_server).

-include_lib("stdlib/include/assert.hrl").

-include("logger.hrl").
-include("packets.hrl").

%% API
-export([start_link/0]).

-export([
    send/2,
    recv_nb/1,
    recv/1,
    close/1,
    send_auth/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).


-record(state, {
    socket :: gen_tcp:socket(),
    % Queue of decoded pb messages received
    recv_q :: list()
}).


start_link() ->
    gen_server:start_link(ha_client, [], []).


-spec send(Client :: pid(), Message :: iolist()) -> ok | {error, closed | inet:posix()}.
send(Client, Message) ->
    gen_server:call(Client, {send, Message}).


recv_nb(Client) ->
    gen_server:call(Client, {recv_nb}).


recv(Client) ->
    gen_server:call(Client, {recv}).


close(Client) ->
    gen_server:call(Client, {close}).


send_auth(Client, Uid, Password) ->
    gen_server:call(Client, {send_auth, Uid, Password}).


init(_Args) ->
    {ok, Socket} = ssl:connect("localhost", 5210, [binary]),
    % Active is the default
%%    ssl:setopts(Socket, [{active, true}]),
    State = #state{
        socket = Socket,
        recv_q = queue:new()
    },
    {ok, State}.


handle_call({send, Message}, _From, State) ->
    Socket = State#state.socket,
    Result = send_internal(Socket, Message),
    {reply, Result, State};


handle_call({recv_nb}, _From, State) ->
    {Val, RecvQ2} = queue:out(State#state.recv_q),
    NewState = State#state{recv_q = RecvQ2},
    Result = case Val of
        empty -> undefined;
        {value, Message} -> Message
    end,
    {reply, Result, NewState};


handle_call({recv}, _From, State) ->
    {Val, RecvQ2} = queue:out(State#state.recv_q),
    NewState = State#state{recv_q = RecvQ2},
    Result = case Val of
        empty ->
            receive
                {ssl, _Socket, Message} ->
                    ?INFO_MSG("recv got ~p", [Message]),
                    Message

            end;
        {value, Message} -> Message
    end,
    {reply, Result, NewState};

handle_call({close}, _From, State) ->
    Socket = State#state.socket,
    ssl:close(Socket),
    NewState = State#state{socket = undefined},
    {reply, ok, NewState};

handle_call({send_auth, Uid, Passwd}, _From, State) ->
    Socket = State#state.socket,
    HaAuth = #pb_auth_request{
        uid = Uid,
        pwd = Passwd,
        cm = #pb_client_mode{mode = active},
        cv = #pb_client_version{version = <<"HalloAppAndroid/82D">>},
        resource = <<"android">>
    },
    send_internal(Socket, HaAuth),
    {reply, ok, State}.

handle_cast(Something, State) ->
    ?INFO_MSG("handle_cast ~p", [Something]),
    {noreply, State}.

handle_info({ssl, _Socket, Message}, State) ->
    ?INFO_MSG("recv ~p", [Message]),
    <<Size:32/big, Payload/binary>> = Message,
    ?assert(byte_size(Payload) =:= Size),
    Result = enif_protobuf:decode(Payload, pb_packet),
    RecvQ = queue:in(Result, State#state.recv_q),
    NewState = State#state{recv_q = RecvQ},
    {noreply, NewState};

handle_info(Something, State) ->
    ?INFO_MSG("handle_info ~p", [Something]),
    {noreply, State}.


send_internal(Socket, Message) when is_binary(Message) ->
    Size = byte_size(Message),
    ssl:send(Socket, <<Size:32/big, Message/binary>>);
send_internal(Socket, PBRecord) when is_tuple(PBRecord) ->
    Message = enif_protobuf:encode(PBRecord),
    send_internal(Socket, Message).
