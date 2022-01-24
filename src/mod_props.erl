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
        max_feed_video_duration => 600, %% duration in seconds for videos on feed.
        max_chat_video_duration => 600, %% duration in seconds for videos in chats.
        private_reactions => false, %% whether client can send private reactions.
        group_sync_time => 1 * ?WEEKS, %% how often should clients sync group metadata
        max_video_bit_rate => 8000000, %% max_video_bit_rate set to 8Mbps.
        audio_note_bit_rate => 96000, %% audio_note_bit_rate set to 96Kbps.
        voice_notes => false, %% enables voice notes in 1-1 messages on client.
        media_comments => true,  %% enables media comments.
        cleartext_group_feed => true, %% whether client must send unencrypted content in group_feed.
        audio_calls => false, %% whether clients can make audio calls.
        video_calls => false, %% whether clients can make video calls.
        call_wait_timeout => 60, %% time (sec) to wait before ending the call on timeout when remote party is not responding.
        streaming_upload_chunk_size =>  65536, %% size of media streaming upload chunk size, 64KB.
        streaming_initial_download_size => 5242880, %% size of intial download while media streaming, 5MB.
        streaming_sending_enabled => false, %% whether streaming is enabled.
        flat_comments => false, %% whether clients display a flat comment structure similar to chat.
        voice_posts => false %% whether to enable voice posts
    },
    PropMap2 = get_uid_based_props(PropMap1, Uid),
    ClientType = util_ua:get_client_type(ClientVersion),
    PropMap3 = get_client_based_props(PropMap2, ClientType, ClientVersion),
    Proplist = maps:to_list(PropMap3),
    lists:keysort(1, Proplist).


-spec get_uid_based_props(PropMap :: map(), Uid :: binary()) -> map().
get_uid_based_props(PropMap, Uid) ->
    ResPropMap = case dev_users:is_dev_uid(Uid) of
        false ->
            PropMap;
        true ->
            % Set dev to be true.
            PropMap1 = maps:update(dev, true, PropMap),
            PropMap2 = maps:update(voice_notes, true, PropMap1),
            PropMap3 = maps:update(audio_calls, true, PropMap2),
            PropMap4 = maps:update(video_calls, true, PropMap3),
            PropMap5 = maps:update(streaming_sending_enabled, true, PropMap4),
            PropMap6 = maps:update(flat_comments, true, PropMap5),
            PropMap7 = maps:update(voice_posts, true, PropMap6),
            PropMap8 = maps:update(max_video_bit_rate, 4000000, PropMap7),
            PropMap8
    end,
    apply_uid_prop_overrides(Uid, ResPropMap).


-spec get_client_based_props(PropMap :: map(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, android, ClientVersion) ->
    %% All android versions starting v0.197
    Result2 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android0.196">>),
    PropMap1 = maps:update(voice_notes, Result2, PropMap),
    PropMap1;

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

apply_uid_prop_overrides(Uid, PropMap) ->
    maps:map(
        fun (K, V) ->
            case uid_prop_override(Uid, K) of
                undef -> V;
                NewV -> NewV
            end
        end,
        PropMap).

-spec uid_prop_override(Uid :: uid(), Prop :: atom()) -> undef | term().
uid_prop_override(<<"1000000000570149128">>, voice_posts) -> true;  %% Michael asked.
uid_prop_override(<<"1000000000557045692">>, voice_posts) -> true;  %% Neeraj asked.
uid_prop_override(<<"1000000000520279204">>, voice_posts) -> true;  %% Neeraj asked.
uid_prop_override(<<"1000000000052736684">>, audio_calls) -> true;  %% Sunisha
uid_prop_override(<<"1000000000399778754">>, audio_calls) -> true;  %% Neeraj's another friend: +91-94441-02346
uid_prop_override(<<"1000000000415550189">>, audio_calls) -> true;  %% Rahul Mehta (Neeraj)
uid_prop_override(<<"1000000000503720864">>, audio_calls) -> true;  %% Jim Goetz
uid_prop_override(<<"1000000000925762631">>, audio_calls) -> true;  %% Gergana (Nikola)
uid_prop_override(<<"1000000000122054965">>, audio_calls) -> true;  %% Katya (Nikola)
uid_prop_override(<<"1000000000683067883">>, audio_calls) -> true;  %% Madlen (Nikola)
uid_prop_override(<<"1000000000938575483">>, audio_calls) -> true;  %% Pavlina (Nikola)
uid_prop_override(<<"1000000000940017573">>, audio_calls) -> true;  %% Alex Contreras (Nikola)
uid_prop_override(_Uid, _Prop) ->
    undef.

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

