%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_props).
-author("josh").
-behaviour(gen_mod).

-include("ha_types.hrl").
-include("logger.hrl").
-include("props.hrl").
-include("xmpp.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process_local_iq/1]).

%% API
-export([
    get_hash/1,
    get_props/1
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PROPS, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PROPS),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handler
%%====================================================================

process_local_iq(#iq{from = #jid{luser = Uid}, type = get} = IQ) ->
    IsDev = dev_users:is_dev_uid(Uid),
    {Hash, SortedProplist} = get_props_and_hash(Uid),
    ?INFO("Uid:~s (dev = ~s) requesting props. hash = ~s, proplist = ~p",
        [Uid, IsDev, Hash, SortedProplist]),
    make_response(IQ, SortedProplist, Hash).

%%====================================================================
%% API
%%====================================================================

-spec get_hash(Uid :: binary()) -> binary().
get_hash(Uid) ->
    {Hash, _} = get_props_and_hash(Uid),
    Hash.


% If any props are changed, please update props doc: server/doc/server_props.md
-spec get_props(Uid :: binary()) -> proplist().
get_props(Uid) ->
    Proplist = case dev_users:is_dev_uid(Uid) of
        false ->
            [
                {dev, false},
                {groups, false},
                {max_group_size, 25},
                {max_post_media_items, 10},
                {group_feed, false},
                {silent_chat_messages, 5}
            ];
        true ->
            [
                {dev, true},
                {groups, false},
                {max_group_size, 25},
                {max_post_media_items, 10},
                {group_feed, true},
                {silent_chat_messages, 5}
            ]
    end,
    lists:keysort(1, Proplist).

%%====================================================================
%% Internal functions
%%====================================================================

generate_hash(SortedProplist) ->
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    base64url:encode(HashValue).


get_props_and_hash(Uid) ->
    SortedProplist = get_props(Uid),
    Hash = generate_hash(SortedProplist),
    {Hash, SortedProplist}.


make_response(IQ, SortedProplist, Hash) ->
    Props = [#prop{name = Key, value = Val} || {Key, Val} <- SortedProplist],
    Prop = #props{hash = Hash, props = Props},
    xmpp:make_iq_result(IQ, Prop).

