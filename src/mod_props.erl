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

-ifdef(TEST).
-export([
    generate_hash/1,
    make_response/3    
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process_local_iq/2]).

%% API
-export([
    get_hash/2,
    get_props/2    %% debug only
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_props, ?MODULE, process_local_iq, 2),
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

process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ,
        #{client_version := ClientVersion} = _C2SState) ->
    IsDev = dev_users:is_dev_uid(Uid),
    {Hash, SortedProplist} = get_props_and_hash(Uid, ClientVersion),
    ?INFO("Uid:~s (dev = ~s) requesting props. hash = ~s, proplist = ~p",
        [Uid, IsDev, Hash, SortedProplist]),
    make_response(IQ, SortedProplist, Hash).

%%====================================================================
%% API
%%====================================================================

-spec get_hash(Uid :: binary(), ClientVersion :: binary()) -> binary().
get_hash(Uid, ClientVersion) ->
    {Hash, _} = get_props_and_hash(Uid, ClientVersion),
    Hash.


-spec get_props(Uid :: binary(), ClientVersion :: binary()) -> proplist().
get_props(Uid, ClientVersion) ->
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        contact_sync_frequency => 1 * ?DAYS, %% how often should clients sync all contacts.
        max_group_size => ?MAX_GROUP_SIZE, %% max limit on the group size.
        max_post_media_items => 10, %% max number of media_items client can post.
        group_chat => false, %% whether the client can access group_chat or not.
        group_feed => true, %% whether the client can access group_feed or not.
        silent_chat_messages => 0, %% number of silent_chats client can send.
        max_feed_video_duration => 600, %% duration in seconds for videos on feed.
        max_chat_video_duration => 600, %% duration in seconds for videos in chats.
        private_reactions => false, %% whether client can send private reactions.
        group_sync_time => 1 * ?WEEKS, %% how often should clients sync group metadata
        group_invite_links => true, %% enables group_invite_links on the client.
        max_video_bit_rate => 8000000, %% max_video_bit_rate set to 8Mbps.
        audio_note_bit_rate => 96000, %% audio_note_bit_rate set to 96Kbps.
        new_client_container => false, %% indicates whether the client can start sending new container formats.
        voice_notes => false, %% enables voice notes in 1-1 messages on client.
        media_comments => true,  %% enables media comments.
        cleartext_group_feed => true %% whether client must send unencrypted content in group_feed
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
            PropMap2 = maps:update(new_client_container, true, PropMap1),
            PropMap3 = maps:update(voice_notes, true, PropMap2),
            PropMap3
    end.


-spec get_client_based_props(PropMap :: map(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, android, ClientVersion) ->
    %% All android versions starting v0.163
    Result = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.162">>),
    PropMap1 = maps:update(new_client_container, Result, PropMap),
    %% All android versions starting v0.197
    Result2 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.196">>),
    PropMap2 = maps:update(voice_notes, Result2, PropMap1),
    PropMap2;

get_client_based_props(PropMap, ios, ClientVersion) ->
    %% All ios versions starting v1.10.167
    Result = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.10.166">>),
    PropMap1 = maps:update(voice_notes, Result, PropMap),
    PropMap1;

get_client_based_props(PropMap, undefined, _) ->
    maps:update(groups, false, PropMap).

%%====================================================================
%% Internal functions
%%====================================================================

generate_hash(SortedProplist) ->
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    HashValue.


get_props_and_hash(Uid, ClientVersion) ->
    SortedProplist = get_props(Uid, ClientVersion),
    Hash = generate_hash(SortedProplist),
    {Hash, SortedProplist}.


make_response(IQ, SortedProplist, Hash) ->
    Props = [#pb_prop{name = util:to_binary(Key), value = util:to_binary(Val)} ||
            {Key, Val} <- SortedProplist],
    Prop = #pb_props{hash = Hash, props = Props},
    pb:make_iq_result(IQ, Prop).

