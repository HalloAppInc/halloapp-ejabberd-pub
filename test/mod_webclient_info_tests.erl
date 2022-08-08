%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. July 2022
%%%-------------------------------------------------------------------

-module(mod_webclient_info_tests).
-author("michelle").

-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1,  <<"1000000000000000001">>).
-define(STATIC_KEY, <<"StaticKey1">>).
-define(STATIC_KEY2, <<"StaticKey2">>).


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_auth).


autheticate_test() ->
    setup(),

    PbWeb = struct_util:create_pb_web_client_info(authenticate_key, ?STATIC_KEY),
    PbIq = #pb_iq{from_uid = ?UID1, type = set, payload = PbWeb},
    IqRes = mod_webclient_info:process_local_iq(PbIq),
    #pb_iq{to_uid = ?UID1, type = result, payload = #pb_web_client_info{result = ok}} = IqRes,
    {ok, [?STATIC_KEY]} = model_auth:get_static_keys(?UID1),

    PbWeb2 = struct_util:create_pb_web_client_info(authenticate_key, ?STATIC_KEY2),
    PbIq2 = #pb_iq{from_uid = ?UID1, type = set, payload = PbWeb2},
    IqRes2 = mod_webclient_info:process_local_iq(PbIq2),
    #pb_iq{to_uid = ?UID1, type = result, payload = #pb_web_client_info{result = ok}} = IqRes2,
    {ok, StaticKeys} = model_auth:get_static_keys(?UID1),
    ?assertEqual(sets:from_list([?STATIC_KEY2, ?STATIC_KEY]), sets:from_list(StaticKeys)),

    ok.


remove_test() ->
    setup(),
    PbWebAdd = struct_util:create_pb_web_client_info(authenticate_key, ?STATIC_KEY),
    PbIq = #pb_iq{from_uid = ?UID1, type = set, payload = PbWebAdd},
    mod_webclient_info:process_local_iq(PbIq),
    {ok, [?STATIC_KEY]} = model_auth:get_static_keys(?UID1),

    PbWebRemove = struct_util:create_pb_web_client_info(remove_key, ?STATIC_KEY),
    PbIq2 = #pb_iq{from_uid = ?UID1, type = set, payload = PbWebRemove},
    IqRes2 = mod_webclient_info:process_local_iq(PbIq2),
    #pb_iq{to_uid = ?UID1, type = result, payload = #pb_web_client_info{result = ok}} = IqRes2,
    {ok, []} = model_auth:get_static_keys(?UID1),

    ok.

