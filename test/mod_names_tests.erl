%%%-------------------------------------------------------------------
%%% File: mod_names_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_names_tests).
-author('murali').

-include("xmpp.hrl").
-include("feed.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(PHONE1, <<"14703381473">>).
-define(UA1, <<"ios">>).

-define(NAME1, <<"alice">>).
-define(NAME2, <<"bob">>).

-define(UID2, <<"1000000000457424539">>).
-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

setup_accounts(Accounts) ->
    lists:foreach(
        fun([Uid, Phone, Name, UserAgent]) ->
            ok = model_accounts:create_account(Uid, Phone, Name, UserAgent),
            ok = model_phone:add_phone(Phone, Uid)
        end, Accounts),
    ok.


create_name_st(Uid, Name) ->
    #name{
        uid = Uid,
        name = Name
    }.

get_set_name_iq(Uid, Ouid, Name, Server) ->
    NameSt = create_name_st(Ouid, Name),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [NameSt]
    }.

get_set_name_iq_result(Uid, Server) ->
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = []
    }.


get_error_iq_result(Reason, Uid, Server) ->
    #iq{
        from = jid:make(Server),
        type = error,
        to = jid:make(Uid, Server),
        sub_els = [#error_st{reason = Reason}]
    }.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


set_name_iq_test() ->
    setup(),
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    %% make sure initial name after setup is set properly.
    ?assertEqual(?NAME1, model_accounts:get_name_binary(?UID1)),

    %% setting a different name to the same uid with set-iq.
    NameIQ = get_set_name_iq(?UID1, ?UID1, ?NAME2, ?SERVER),
    ResultIQ1 = mod_names:process_local_iq(NameIQ),
    ExpectedResultIQ = get_set_name_iq_result(?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),

    %% make sure name is now updated to be name2.
    ?assertEqual(?NAME2, model_accounts:get_name_binary(?UID1)),
    ok.


set_name_iq_error_test() ->
    setup(),

    %% setting uid name with wrong iq. expect an error.
    NameIQ = get_set_name_iq(?UID1, ?UID2, ?NAME1, ?SERVER),
    ResultIQ1 = mod_names:process_local_iq(NameIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_uid, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),
    ok.


set_name_test() ->
    setup_accounts([
        [?UID1, ?PHONE1, ?NAME1, ?UA1]]),

    %% make sure initial name after setup is set properly.
    ?assertEqual(?NAME1, model_accounts:get_name_binary(?UID1)),

    ok = mod_names:set_name(?UID1, ?NAME2),

    %% make sure name is now updated to be name2.
    ?assertEqual(?NAME2, model_accounts:get_name_binary(?UID1)),
    ok.

