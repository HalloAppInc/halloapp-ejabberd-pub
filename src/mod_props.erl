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
    get_hash/0
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PROPS, ?MODULE, process_local_iq),
    {Hash, SortedProplist} = generate_hash_and_sorted_proplist(?PROPLIST),
    persistent_term:put(?PROPS_HASH_KEY, Hash),
    persistent_term:put(?PROPLIST_KEY, SortedProplist),
    ?INFO_MSG("Props hash: ~p", [Hash]),
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
    ?INFO_MSG("uid: ~p requesting props", [Uid]),
    make_response(IQ, persistent_term:get(?PROPLIST_KEY), get_hash()).

%%====================================================================
%% API
%%====================================================================

-spec get_hash() -> binary().
get_hash() ->
    persistent_term:get(?PROPS_HASH_KEY).

%%====================================================================
%% Internal functions
%%====================================================================

make_response(IQ, SortedProplist, Hash) ->
    Props = [#prop{name = Key, value = Val} || {Key, Val} <- SortedProplist],
    Prop = #props{hash = Hash, props = Props},
    xmpp:make_iq_result(IQ, Prop).


-spec generate_hash_and_sorted_proplist(proplist()) -> {binary(), proplist()}.
generate_hash_and_sorted_proplist(Proplist) ->
    SortedProplist = lists:keysort(1, Proplist),
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    {base64url:encode(HashValue), SortedProplist}.

