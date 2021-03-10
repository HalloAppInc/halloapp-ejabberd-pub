%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Mar 2021 4:38 PM
%%%-------------------------------------------------------------------
-module(registration_tests).
-author("nikola").

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(PHONE10, <<"12065550010">>).
-define(PHONE11, <<"12065550011">>).
-define(NAME10, <<"Elon Musk">>).

group() ->
    {registration, [sequence], [
        registration_request_sms_test,
        registration_register_test
    ]}.

request_sms_test(_Conf) ->
    {ok, Resp} = registration_client:request_sms(?PHONE10),
    ct:pal("~p", [Resp]),
    #{
        <<"phone">> := ?PHONE10,
        <<"retry_after_secs">> := 15,
        <<"result">> := <<"ok">>
    } = Resp,
    ok.

% TODO: test request_sms errors like not_invited, bad_user_agent

% TODO: this test should eventually switch to register2
register_test(_Conf) ->
    {ok, Uid, Password, Data} = registration_client:register(?PHONE10, <<"111111">>, ?NAME10),
    ct:pal("~p", [Data]),
    #{
        <<"name">> := ?NAME10,
        <<"phone">> := ?PHONE10,
        <<"result">> := <<"ok">>
    } = Data,
    ?assertEqual(true, model_accounts:account_exists(Uid)),
    ?assertEqual({ok, ?NAME10}, model_accounts:get_name(Uid)),
    ok.


