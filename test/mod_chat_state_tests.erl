%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 9. Aug 2020 4:54 PM
%%%-------------------------------------------------------------------
-module(mod_chat_state_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("xmpp.hrl").
-include("groups.hrl").

-define(SERVER, <<"s.halloapp.net">>).
-define(UID1, <<"10000000003765032">>).
-define(UID2, <<"20000000003765036">>).
-define(UID3, <<"30000000003765036">>).
-define(GROUP_NAME1, <<"Test Group 1">>).


%%====================================================================
%% Tests
%%====================================================================


process_chat_state_typing_test() ->
    setup(),
    %% UID1 send `typing` chat_state to server, thread_id is UID2
    ChatState = create_chat_state(?UID1, ?SERVER, ?UID2, typing,  chat),
    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            %% UID1 send `typing` chat_state to UID2, thread_id is UID1
            ExpectedPacket = create_chat_state(?UID1, ?UID2, ?UID1, typing, chat),
            ?assertEqual(ExpectedPacket, Packet),
            ok
        end),
    mod_chat_state:process_chat_state(ChatState, ?UID2),
    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router).


process_chat_state_available_test() ->
    setup(),
    %% UID1 send `available` chat_state to server, thread_id is UID2
    ChatState = create_chat_state(?UID1, ?SERVER, ?UID2, available, chat),
    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            %% UID1 send `available` chat_state to UID2, thread_id is UID1
            ExpectedPacket = create_chat_state(?UID1, ?UID2, ?UID1, available, chat),
            ?assertEqual(ExpectedPacket, Packet),
            ok
        end),
    mod_chat_state:process_chat_state(ChatState, ?UID2),
    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router).


process_group_chat_state_test() ->
    setup(),
    Gid = create_group(),
    ChatState = create_chat_state(?UID1, ?SERVER, Gid, available, chat),
    meck:new(ejabberd_router_multicast),
    meck:expect(ejabberd_router_multicast, route_multicast,
        fun(From, Server, BroadcastJids, Packet) ->
            ExpectedFrom = jid:make(?UID1, ?SERVER),
            ?assertEqual(ExpectedFrom, From),
            ?assertEqual(?SERVER, Server),
            ExpectedBroadcastJids = [?UID1, ?UID2, ?UID3],
            ?assertEqual(lists:sort(ExpectedBroadcastJids), lists:sort(BroadcastJids)),
            ?assertEqual(ChatState, Packet),
            ok
        end),
    mod_chat_state:process_chat_state(ChatState, Gid),
    meck:validate(ejabberd_router_multicast),
    meck:unload(ejabberd_router_multicast).


%%====================================================================
%% Internal functions
%%====================================================================


setup() ->
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    ejabberd_auth_halloapp:start(?SERVER),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_groups_client, flushdb),
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).


create_chat_state(FromUid, ToUid, ThreadId, Type, ThreadType) ->
    #chat_state{
        from = jid:make(FromUid, ?SERVER),
        to = jid:make(ToUid, ?SERVER),
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType
    }.


create_group() ->
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    model_groups:add_member(Gid, ?UID2, ?UID1),
    model_groups:add_member(Gid, ?UID3, ?UID1),
    Gid.


