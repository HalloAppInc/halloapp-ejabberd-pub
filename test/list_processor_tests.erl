%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(list_processor_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").


-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16505552222">>).
-define(NAME2, <<"Name2">>).

-define(UID3, <<"3">>).
-define(PHONE3, <<"16505553333">>).
-define(NAME3, <<"Name3">>).

-define(UID4, <<"4">>).
-define(PHONE4, <<"16505554444">>).
-define(NAME4, <<"Name4">>).

-define(UID5, <<"5">>).
-define(PHONE5, <<"16505555555">>).
-define(NAME5, <<"Name5">>).

-define(SERVER, <<"s.halloapp.net">>).
-define(TEMP_FILE_NAME, "/tmp/uids.txt").
-define(PASS, <<"pword">>).
-define(UA, <<"HalloApp/iPhone1.0">>).

is_even(X) ->
    (X rem 2) == 0.

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.

clear() ->
    tutil:cleardb(redis_auth),
    tutil:cleardb(redis_phone),
    tutil:cleardb(redis_accounts).

check_file_processing_test() ->
    try
        file:delete(?TEMP_FILE_NAME)
    catch _ ->
        ?debugFmt("Unable to delete: ~s. It is ok.", [?TEMP_FILE_NAME])
    end,

    {ok, Fh} = file:open(?TEMP_FILE_NAME, [write]),
    io:format(Fh, "~p~n", [?UID1]),
    io:format(Fh, "~p~n", [?UID2]),
    io:format(Fh, "~p~n", [?UID3]),
    io:format(Fh, "~p~n", [?UID4]),
    io:format(Fh, "~p~n", [?UID5]),
    file:close(Fh),
    ?assertEqual(1, list_processor:process_file_list(?TEMP_FILE_NAME, fun is_even/1, 1)),
    ?assertEqual(2, list_processor:process_file_list(?TEMP_FILE_NAME, fun is_even/1, 2)),
    ?assertEqual(2, list_processor:process_file_list(?TEMP_FILE_NAME, fun is_even/1, 10)),
    ok = file:delete(?TEMP_FILE_NAME),

    setup(),
    {ok, Uid1, register} = ejabberd_auth:check_and_register(?PHONE1, ?SERVER, ?PASS, ?NAME1, ?UA),
    {ok, Uid2, register} = ejabberd_auth:check_and_register(?PHONE2, ?SERVER, ?PASS, ?NAME2, ?UA),
    {ok, Uid3, register} = ejabberd_auth:check_and_register(?PHONE3, ?SERVER, ?PASS, ?NAME3, ?UA),
    {ok, Uid4, register} = ejabberd_auth:check_and_register(?PHONE4, ?SERVER, ?PASS, ?NAME4, ?UA),
    {ok, Uid5, register} = ejabberd_auth:check_and_register(?PHONE5, ?SERVER, ?PASS, ?NAME5, ?UA),

    {ok, Fh2} = file:open(?TEMP_FILE_NAME, [write]),
    io:format(Fh2, "~p~n", [Uid1]),
    io:format(Fh2, "~p~n", [Uid2]),
    io:format(Fh2, "~p~n", [Uid3]),
    io:format(Fh2, "~p~n", [Uid4]),
    io:format(Fh2, "~p~n", [Uid5]),
    file:close(Fh2),
    ?assertEqual(1, list_processor:process_file_list(?TEMP_FILE_NAME, fun list_processor:remove_user/1, 1)),
    ?assertEqual(2, list_processor:process_file_list(?TEMP_FILE_NAME, fun list_processor:remove_user/1, 2)),
    ?assertEqual(2, list_processor:process_file_list(?TEMP_FILE_NAME, fun list_processor:remove_user/1, 10)),
    ?assertEqual(0, list_processor:process_file_list(?TEMP_FILE_NAME, fun list_processor:remove_user/1, 10)),
    ok = file:delete(?TEMP_FILE_NAME).

