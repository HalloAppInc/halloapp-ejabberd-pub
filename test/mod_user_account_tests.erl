%%%-------------------------------------------------------------------
%%% File: mod_user_account_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_user_account_tests).
-author('murali').

-include("xmpp.hrl").
-include("packets.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(SERVER1, <<"s.halloapp.net">>).
-define(PHONE1, <<"+14703381473">>).
-define(PHONE2, <<"+4703381473">>).
-define(NORM_PHONE1, <<"14703381473">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    mod_libphonenumber:start(<<>>, <<>>),
    ok.


create_delete_account_iq(Uid, Server, Type, Phone) ->
    #pb_iq{
        from_uid = Uid,
        type = Type,
        payload = #pb_delete_account{
                phone = Phone
            }
    }.


delete_account_iq1_test() ->
    setup(),
    tutil:meck_init(model_accounts, get_phone, fun(_) -> {ok, ?NORM_PHONE1} end),
    tutil:meck_init(ejabberd_auth, remove_user, fun(_, _) -> ok end),
    IQ = create_delete_account_iq(?UID1, ?SERVER1, set, ?PHONE1),
    IQRes = mod_user_account:process_local_iq(IQ),
    tutil:meck_finish(model_accounts),
    tutil:meck_finish(ejabberd_auth),
    ?assertEqual(ignore, IQRes),
    ok.


delete_account_iq2_test() ->
    tutil:meck_init(model_accounts, get_phone, fun(_) -> {ok, ?NORM_PHONE1} end),
    tutil:meck_init(ejabberd_auth, remove_user, fun(_, _) -> ok end),

    IQ1 = create_delete_account_iq(?UID1, ?SERVER1, get, undefined),
    IQRes1 = mod_user_account:process_local_iq(IQ1),

    IQ2 = create_delete_account_iq(?UID1, ?SERVER1, set, ?PHONE2),
    IQRes2 = mod_user_account:process_local_iq(IQ2),

    tutil:meck_finish(model_accounts),
    tutil:meck_finish(ejabberd_auth),

    ?assertEqual(util:err(invalid_request), tutil:get_error_iq_sub_el(IQRes1)),
    ?assertEqual(ignore, IQRes2),
    ok.

