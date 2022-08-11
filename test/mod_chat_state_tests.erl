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
-include("packets.hrl").
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
    ChatState = create_chat_state(?UID1, <<>>, ?UID2, typing,  chat),
    tutil:meck_init(ejabberd_router, route,
        fun(Packet) ->
            %% UID1 send `typing` chat_state to UID2, thread_id is UID1
            ExpectedPacket = create_chat_state(?UID1, ?UID2, ?UID1, typing, chat),
            ?assertEqual(ExpectedPacket, Packet),
            ok
        end),
    mod_chat_state:process_chat_state(ChatState, ?UID2),
    tutil:meck_finish(ejabberd_router).


process_chat_state_available_test() ->
    setup(),
    %% UID1 send `available` chat_state to server, thread_id is UID2
    ChatState = create_chat_state(?UID1, <<>>, ?UID2, available, chat),
    tutil:meck_init(ejabberd_router, route,
        fun(Packet) ->
            %% UID1 send `available` chat_state to UID2, thread_id is UID1
            ExpectedPacket = create_chat_state(?UID1, ?UID2, ?UID1, available, chat),
            ?assertEqual(ExpectedPacket, Packet),
            ok
        end),
    mod_chat_state:process_chat_state(ChatState, ?UID2),
    tutil:meck_finish(ejabberd_router).


process_group_chat_state_test() ->
    setup(),
    Gid = create_group(),
    ChatState = create_chat_state(?UID1, <<>>, Gid, available, chat),
    tutil:meck_init(ejabberd_router, route_multicast,
        fun(FromUid, BroadcastUids, Packet) ->
            ?assertEqual(?UID1, FromUid),
            ?assertEqual(lists:sort([?UID2, ?UID3]), lists:sort(BroadcastUids)),
            ?assertEqual(ChatState, Packet),
            ok
        end),
    mod_chat_state:process_group_chat_state(ChatState, Gid),
    tutil:meck_finish(ejabberd_router).


%%====================================================================
%% Internal functions
%%====================================================================


setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_groups),
    tutil:cleardb(redis_accounts).


create_chat_state(FromUid, ToUid, ThreadId, Type, ThreadType) ->
    #pb_chat_state{
        from_uid = FromUid,
        to_uid = ToUid,
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType
    }.


create_group() ->
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    model_groups:add_member(Gid, ?UID2, ?UID1),
    model_groups:add_member(Gid, ?UID3, ?UID1),
    Gid.


