%%%-------------------------------------------------------------------
%%% File: mod_names_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_names_tests).
-author('murali').

-include("packets.hrl").
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
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

setup_accounts(Accounts) ->
    lists:foreach(
        fun([Uid, Phone, Name, UserAgent]) ->
            AppType = util_uid:get_app_type(Uid),
            ok = model_accounts:create_account(Uid, Phone, UserAgent),
            ok = model_accounts:set_name(Uid, Name),
            ok = model_phone:add_phone(Phone, AppType, Uid)
        end, Accounts),
    ok.


create_name_st(Uid, Name) ->
    #pb_name{
        uid = Uid,
        name = Name
    }.

get_set_name_iq(Uid, Ouid, Name) ->
    NameSt = create_name_st(Ouid, Name),
    #pb_iq{
        from_uid = Uid,
        type = set,
        to_uid = <<>>,
        payload = NameSt
    }.

get_set_name_iq_result(Uid) ->
    #pb_iq{
        from_uid = <<>>,
        type = result,
        to_uid = Uid,
        payload = undefined
    }.


get_error_iq_result(Reason, Uid) ->
    #pb_iq{
        from_uid = <<>>,
        type = error,
        to_uid = Uid,
        payload = #pb_error_stanza{reason = util:to_binary(Reason)}
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
    NameIQ = get_set_name_iq(?UID1, ?UID1, ?NAME2),
    ResultIQ1 = mod_names:process_local_iq(NameIQ),
    ExpectedResultIQ = get_set_name_iq_result(?UID1),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),

    %% make sure name is now updated to be name2.
    ?assertEqual(?NAME2, model_accounts:get_name_binary(?UID1)),
    ok.


set_name_iq_error_test() ->
    setup(),

    %% setting uid name with wrong iq. expect an error.
    NameIQ = get_set_name_iq(?UID1, ?UID2, ?NAME1),
    ResultIQ1 = mod_names:process_local_iq(NameIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_uid, ?UID1),
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

