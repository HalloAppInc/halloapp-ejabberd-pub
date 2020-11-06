%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Aug 2020 1:44 PM
%%%-------------------------------------------------------------------
-module(mod_aws_tests).
-author("josh").

-include_lib("eunit/include/eunit.hrl").

-define(SECRET1, <<"Secret1">>).
-define(SECRET2, <<"Secret2">>).
-define(SECRET1_VALUE, <<"data">>).
-define(SECRETS_TABLE, mod_aws:get_table_name()).

%%====================================================================
%% Tests
%%====================================================================

create_delete_table_test() ->
    setup(),
    ?assertNotEqual(undefined, ets:info(?SECRETS_TABLE)),
    finish(),
    ?assertEqual(undefined, ets:info(?SECRETS_TABLE)).


fetch_secret_test() ->
    setup(),
    ?assertEqual(?SECRET1_VALUE, mod_aws:retrieve_secret(?SECRET1)),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    finish().


%% get_cached_secret api is accessible for test only.
%% test if caching works properly.
get_cached_secret() ->
    setup(),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    ?assertEqual(?SECRET1_VALUE, mod_aws:get_and_cache_secret(?SECRET1)),
    ?assert(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(?SECRET1_VALUE, mod_aws:get_cached_secret(?SECRET1)),
    finish().


get_secret() ->
    setup(),
    %% Test that the secret is always dummy_secret for any id in testing environment.
    ?assertEqual(undefined, mod_aws:get_cached_secret(?SECRET1)),
    ?assertEqual(<<"dummy_secret">>, mod_aws:get_secret(?SECRET1)),
    ?assertNot(ets:member(?SECRETS_TABLE, ?SECRET1)),
    ?assertEqual(<<"dummy_secret">>, mod_aws:get_secret(?SECRET2)),
    finish().

%%====================================================================
%% Internal functions
%%====================================================================

% this only properly mocks the part being inspected by mod_aws code
mock_get_secret_value(SecretName, _Opts) ->
    case SecretName of
        ?SECRET1 ->
            {ok, [arn, created_date, name,
                {<<"SecretString">>, ?SECRET1_VALUE}, id, stage]}
    end.


setup() ->
    ok = mod_aws:start(util:get_host(), []),
    meck:new(erlcloud_sm),
    meck:expect(erlcloud_sm, get_secret_value, fun mock_get_secret_value/2),
    ok.


finish() ->
    ok = mod_aws:stop(util:get_host()),
    ?assert(meck:validate(erlcloud_sm)),
    meck:unload(erlcloud_sm),
    ok.

