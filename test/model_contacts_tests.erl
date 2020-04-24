%%%-------------------------------------------------------------------
%%% File: model_contacts_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_contacts_tests).
-author("murali").

-include_lib("eunit/include/eunit.hrl").
-define(UID, <<"1000000000376503286">>).
-define(CONTACT1, <<"14705551473">>).
-define(CONTACT2, <<"16502241748">>).
-define(CONTACT3, <<"14703381473">>).
-define(SID, <<"dbd22016">>).

setup() ->
    redis_sup:start_link(),
    clear(),
    model_contacts:start_link(),
    ok.


clear() ->
    ok = gen_server:cast(redis_contacts_client, flushdb).


add_contact_test() ->
    setup(),
    {ok, []} = model_contacts:get_contacts(?UID),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    %% Test con:{uid}
    {ok, [?CONTACT1]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1).


add_contacts_test() ->
    setup(),
    ok = model_contacts:add_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT3),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT3).


remove_contact_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:remove_contact(?UID, ?CONTACT1),
    %% Test con:{uid}
    {ok, [?CONTACT2]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2).


remove_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:remove_contacts(?UID, [?CONTACT1, ?CONTACT2]),
    %% Test con:{uid}
    {ok, []} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


remove_all_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
     %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    ok = model_contacts:remove_all_contacts(?UID),
    %% Test con:{uid}
    {ok, []} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


sync_contacts_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    ok = model_contacts:sync_contacts(?UID, ?SID, [?CONTACT3]),
    %% Test sync:{sid}
    {ok, [?CONTACT3]} = model_contacts:get_sync_contacts(?UID, ?SID),
    %% Test con:{uid}
    {ok, [?CONTACT1, ?CONTACT2]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, [?UID]} = model_contacts:get_contact_uids(?CONTACT2),
    ok = model_contacts:finish_sync(?UID, ?SID),
    %% Test con:{uid}
    {ok, [?CONTACT3]} = model_contacts:get_contacts(?UID),
    %% Test rev:{phone}
    {ok, []} = model_contacts:get_contact_uids(?CONTACT1),
    {ok, []} = model_contacts:get_contact_uids(?CONTACT2).


is_contact_test() ->
    setup(),
    ok = model_contacts:add_contact(?UID, ?CONTACT1),
    ok = model_contacts:add_contact(?UID, ?CONTACT2),
    true = model_contacts:is_contact(?UID,  ?CONTACT1),
    true = model_contacts:is_contact(?UID,  ?CONTACT2),
    false = model_contacts:is_contact(?UID,  ?CONTACT3).

