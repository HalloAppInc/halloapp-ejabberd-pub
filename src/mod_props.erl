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
-include("packets.hrl").
-include("groups.hrl").
-include("time.hrl").

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
    get_hash/2,
    get_props/2    %% debug only
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_props, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_props),
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

process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ) ->
    IsDev = dev_users:is_dev_uid(Uid),
    {ok, ClientVersion} = model_accounts:get_client_version(Uid),
    {Hash, SortedProplist} = get_props_and_hash(Uid, ClientVersion),
    ?INFO("Uid:~s (dev = ~s) requesting props. hash = ~s, proplist = ~p",
        [Uid, IsDev, Hash, SortedProplist]),
    make_response(IQ, SortedProplist, Hash).

%%====================================================================
%% API
%%====================================================================

%% deprecated but still used by xmpp clients.
%% TODO(murali@): remove this in 1 month.
-spec get_hash(Uid :: binary()) -> binary().
get_hash(Uid) ->
    {ok, ClientVersion} = model_accounts:get_client_version(Uid),
    get_hash(Uid, ClientVersion).


-spec get_hash(Uid :: binary(), ClientVersion :: binary()) -> binary().
get_hash(Uid, ClientVersion) ->
    {Hash, _} = get_props_and_hash(Uid, ClientVersion),
    Hash.


-spec get_props(Uid :: binary(), ClientVersion :: binary()) -> proplist().
get_props(Uid, ClientVersion) ->
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        max_group_size => ?MAX_GROUP_SIZE, %% max limit on the group size.
        max_post_media_items => 10, %% max number of media_items client can post.
        groups => true, %% whether the client can create groups or not.
        group_chat => false, %% whether the client can access group_chat or not.
        group_feed => true, %% whether the client can access group_feed or not.
        combine_feed => true, %% whether to combine content from group_feed and home feed.
        silent_chat_messages => 0, %% number of silent_chats client can send.
        cleartext_chat_messages => true, %% whether to disable cleartext chat messages.
        max_feed_video_duration => 600, %% duration in seconds for videos on feed.
        max_chat_video_duration => 600, %% duration in seconds for videos in chats.
        private_reactions => false, %% whether client can send private reactions.
        group_sync_time => 1 * ?WEEKS, %% how often should clients sync group metadata
        group_invite_links => false, %% enables group_invite_links on the client.
        group_background => false, %% enables group_background on the client.
        max_video_bit_rate => 8000000, %% max_video_bit_rate set to 8Mbps.
        new_client_container => false %% indicates whether the client can start sending new container formats.
    },
    PropMap2 = get_uid_based_props(PropMap1, Uid),
    ClientType = util_ua:get_client_type(ClientVersion),
    PropMap3 = get_client_based_props(PropMap2, ClientType, ClientVersion),
    Proplist = maps:to_list(PropMap3),
    lists:keysort(1, Proplist).


-spec get_uid_based_props(PropMap :: map(), Uid :: binary()) -> map().
get_uid_based_props(PropMap, Uid) ->
    case dev_users:is_dev_uid(Uid) of
        false -> PropMap;
        true ->
            % Set dev to be true.
            PropMap1 = maps:update(dev, true, PropMap),
            PropMap2 = maps:update(group_invite_links, true, PropMap1),
            PropMap3 = maps:update(group_background, true, PropMap2),
            PropMap3
    end.


-spec get_client_based_props(PropMap :: map(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, android, _ClientVersion) ->
    maps:update(groups, true, PropMap);
get_client_based_props(PropMap, ios, ClientVersion) ->
    Result = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS0.3.75">>),
    maps:update(groups, Result, PropMap);
get_client_based_props(PropMap, undefined, _) ->
    maps:update(groups, false, PropMap).

%%====================================================================
%% Internal functions
%%====================================================================

generate_hash(SortedProplist) ->
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    base64url:encode(HashValue).


get_props_and_hash(Uid, ClientVersion) ->
    SortedProplist = get_props(Uid, ClientVersion),
    Hash = generate_hash(SortedProplist),
    {Hash, SortedProplist}.


make_response(IQ, SortedProplist, Hash) ->
    Props = [#pb_prop{name = util:to_binary(Key), value = util:to_binary(Val)} ||
            {Key, Val} <- SortedProplist],
    Prop = #pb_props{hash = base64url:decode(Hash), props = Props},
    pb:make_iq_result(IQ, Prop).

