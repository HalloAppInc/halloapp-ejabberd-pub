%%%-------------------------------------------------------------------
%%% File    : mod_retract_tests.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-------------------------------------------------------------------

-module(mod_retract_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("xmpp.hrl").
-include("groups.hrl").

-define(SERVER, <<"s.halloapp.net">>).
-define(UID1, <<"10000000003765032">>).
-define(UID2, <<"20000000003765036">>).
-define(UID3, <<"30000000003765036">>).
-define(GROUP_NAME1, <<"Test Group 1">>).
-define(ID1, <<"id1">>).


%%====================================================================
%% Tests
%%====================================================================


process_chat_retract_test() ->
    setup(),

    RetractSt = create_retract_st(?ID1, ?UID2, <<>>),
    MessageSt = create_message_stanza(?UID1, normal, <<>>, RetractSt),

    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            RetractSt2 = create_retract_st(?ID1, ?UID1, <<>>),
            MessageSt2 = create_message_stanza(?UID1, normal, ?UID2, RetractSt2),
            ?assertEqual(MessageSt2, Packet),
            ok
        end),

    ok = mod_retract:process_retract_message(MessageSt),

    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router).


process_groupchat_retract_test() ->
    setup(),

    Gid = create_group(),
    RetractSt = create_retract_st(?ID1, <<>>, Gid),
    MessageSt = create_message_stanza(?UID1, groupchat, <<>>, RetractSt),

    meck:new(ejabberd_router_multicast),
    meck:expect(ejabberd_router_multicast, route_multicast,
        fun(From, Server, BroadcastJids, Packet) ->
            ExpectedFrom = jid:make(?UID1, ?SERVER),
            ?assertEqual(ExpectedFrom, From),
            ?assertEqual(?SERVER, Server),
            ExpectedBroadcastJids = util:uids_to_jids([?UID2, ?UID3], ?SERVER),
            ?assertEqual(lists:sort(ExpectedBroadcastJids), lists:sort(BroadcastJids)),
            ?assertEqual(MessageSt, Packet),
            ok
        end),

    ok = mod_retract:process_retract_message(MessageSt),

    meck:validate(ejabberd_router_multicast),
    meck:unload(ejabberd_router_multicast).


%%====================================================================
%% Internal functions
%%====================================================================


setup() ->
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_groups_client, flushdb),
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).


create_retract_st(Id, Uid, Gid) ->
    #retract_st{
        id = Id,
        uid = Uid,
        gid = Gid
    }.

create_message_stanza(FromUid, Type, ToUid, RetractSt) ->
    #message{
        from = jid:make(FromUid, ?SERVER),
        to = jid:make(ToUid, ?SERVER),
        type = Type,
        sub_els = [RetractSt]
    }.


create_group() ->
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    model_groups:add_member(Gid, ?UID2, ?UID1),
    model_groups:add_member(Gid, ?UID3, ?UID1),
    Gid.


