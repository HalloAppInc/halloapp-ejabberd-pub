%%%----------------------------------------------------------------------------------------------
%%% File    : mod_presence_subscription.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles storing and retrieving user's subscriptions to 
%%% their contact's presence, and also contacts who subscribed to
%%% a user's presence. This is useful to be able to fetch user's contacts presence
%%% and broadcast a user's presence.
%%% This module also handles all the presence stanzas of type subscribe/unsubscribe.
%%% Given a user: we share their presence information only to their contacts.
%%% A subscribes to B, C, D's presence.
%%% Only B and C have A in their address book and D does not.
%%% So A can only see B and C's presence.
%%%
%%%----------------------------------------------------------------------------------------------

-module(mod_presence_subscription).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API and hooks.
-export([
    presence_subs_hook/3,
    unset_presence_hook/4,
    re_register_user/4,
    remove_user/2,
    subscribe/2,
    unsubscribe/2,
    get_subscribed_uids/1,
    get_broadcast_uids/1,
    remove_contact/3,
    user_receive_packet/1
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(presence_subs_hook, Host, ?MODULE, presence_subs_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 10),
    ejabberd_hooks:add(remove_contact, Host, ?MODULE, remove_contact, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(presence_subs_hook, Host, ?MODULE, presence_subs_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 10),
    ejabberd_hooks:delete(remove_contact, Host, ?MODULE, remove_contact, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% hooks
%%====================================================================

-spec re_register_user(Uid :: binary(), Server :: binary(),
        Phone :: binary(), CampaignId :: binary()) -> {ok, any()} | {error, any()}.
re_register_user(Uid, _Server, _Phone, _CampaignId) ->
    presence_unsubscribe_all(Uid).


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    presence_unsubscribe_all(Uid).


-spec unset_presence_hook(Uid :: binary(), Mode :: atom(),
        Resource :: binary(), Reason :: atom()) -> {ok, any()} | {error, any()}.
%% passive connections should not affect your presence behavior.
unset_presence_hook(_Uid, passive, _Resource, _Reason) -> ok;
unset_presence_hook(Uid, active, _Resource, _Reason) ->
    presence_unsubscribe_all(Uid).


-spec presence_unsubscribe_all(Uid :: binary()) -> ok.
presence_unsubscribe_all(Uid) ->
    ?INFO("Uid: ~s, unsubscribe_all", [Uid]),
    model_accounts:presence_unsubscribe_all(Uid).


-spec presence_subs_hook(User :: binary(), Server :: binary(),
        Presence :: pb_presence()) -> {ok, any()} | {error, any()}.
presence_subs_hook(User, Server, #pb_presence{uid = Uid, to_uid = ToUid, type = Type}) ->
    FinalToUid = case {Uid, ToUid} of
        {_, <<>>} ->
            ?INFO("pb_presence_uid field is still being used"),
            Uid;
        _ ->
            ToUid
    end,
    ?INFO("Uid: ~p, type: ~p toUid: ~p", [User, Type, ToUid]),
    case Type of
        subscribe ->
            check_and_subscribe(User, Server, FinalToUid);
        unsubscribe ->
            unsubscribe(User, FinalToUid)
    end.


-spec remove_contact(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
remove_contact(Uid, _Server, Ouid) ->
    unsubscribe(Ouid, Uid),
    ok.

%% Presence stanzas are sent only on active connections.
%% We drop the packet on passive connections.
user_receive_packet({#pb_presence{} = Packet, #{mode := Mode} = State} = Acc)  ->
    case Mode of
        active -> Acc;
        passive ->
            ?INFO("drop packet: ~p on mode: ~p", [Packet, Mode]),
            {stop, {drop, State}}
    end;
user_receive_packet(Acc) ->
    Acc.


%%====================================================================
%% API
%%====================================================================

-spec subscribe(User :: binary(), Contact :: binary()) -> {ok, any()} | {error, any()}.
subscribe(User, User) ->
    {ok, ignore_self_subscribe};
subscribe(User, Contact) ->
    ?INFO("Uid: ~s, Contact: ~s", [User, Contact]),
    model_accounts:presence_subscribe(User, Contact).


-spec unsubscribe(User :: binary(), Contact :: binary()) -> {ok, any()} | {error, any()}.
unsubscribe(User, Contact) ->
    ?INFO("Uid: ~s, Contact: ~s", [User, Contact]),
    model_accounts:presence_unsubscribe(User, Contact).


-spec get_subscribed_uids(User :: binary()) -> [binary()].
get_subscribed_uids(User) ->
    {ok, Result} = model_accounts:get_subscribed_uids(User),
    Result.


-spec get_broadcast_uids(User :: binary()) -> [binary()].
get_broadcast_uids(User) ->
    {ok, Result} = model_accounts:get_broadcast_uids(User),
    Result.


%%====================================================================
%% Internal functions
%%====================================================================

%% TODO(murali@): use uid and Ouid instead of user and contact variables in this file.
-spec check_and_subscribe(User :: binary(), Server :: binary(),
        Contact :: binary()) -> ignore | ok | {ok, any()} | {error, any()}.
check_and_subscribe(User, Server, Contact) ->
    {ok, UserPhone} = model_accounts:get_phone(User),
    case model_contacts:is_contact(Contact, UserPhone) of
        false ->
            ?INFO("ignore presence_subscribe, Uid: ~s, ContactUid: ~s", [User, Contact]),
            ignore;
        true ->
            ?INFO("accept presence_subscribe, Uid: ~s, ContactUid: ~s", [User, Contact]),
            subscribe(User, Contact),
            mod_user_activity:probe_and_send_presence(User, Server, Contact)
    end.



