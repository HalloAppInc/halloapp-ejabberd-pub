%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_albums).
-author("josh").

-include("albums.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("server.hrl").

-export([
    create_album/2,
    get_album_info/1,
    get_album_media_items/2,
    get_album/1,
    get_album/2,
    delete_album/1,
    get_user_albums/2,
    get_role/2,
    set_role/3,
    remove_role/2,
    execute_member_actions/2,
    get_name/1,
    set_name/2,
    get_location/1,
    set_location/2,
    get_time_range/1,
    set_time_range/2,
    get_contribute_access/1,
    set_contribute_access/2,
    get_view_access/1,
    set_view_access/2,
    get_all_members/1,
    get_media_items/2,
    store_media_items/2,
    remove_media_items/3
]).

-define(FIELD_NAME, <<"na">>).
-define(FIELD_OWNER, <<"ow">>).
-define(FIELD_START_TIME, <<"st">>).
-define(FIELD_END_TIME, <<"et">>).
-define(FIELD_OFFSET, <<"zo">>).
-define(FIELD_LATITUDE, <<"la">>).
-define(FIELD_LONGITUDE, <<"lo">>).
-define(FIELD_CAN_VIEW, <<"cv">>).
-define(FIELD_CAN_CONTRIBUTE, <<"cc">>).

-define(FIELD_MEDIA_ITEM_PUBLISHER_UID, <<"uid">>).
-define(FIELD_MEDIA_ITEM_PAYLOAD, <<"pay">>).
-define(FIELD_MEDIA_ITEM_DEVICE_TS_MS, <<"dts">>).
-define(FIELD_MEDIA_ITEM_UPLOAD_TS_MS, <<"uts">>).
-define(FIELD_MEDIA_ITEM_PARENT_MEDIA_ID, <<"pid">>).

%%====================================================================
%% API
%%====================================================================

%% Note: media items must be stored separately using store_media_items/2
-spec create_album(Uid :: uid(), album()) -> album_id().
create_album(Uid, #album{name = Name, time_range = {StartTs, EndTs, Offset}, location = {Latitude, Longitude},
        can_view = CanView, can_contribute = CanContribute, members = Members}) ->
    AlbumId = util_id:generate_album_id(),
    %% This is where the album creator/owner is added to the list of members
    MemberCommands = [["HSET", album_members_key(AlbumId), Uid, owner] | lists:map(
        fun(#album_member{uid = MUid, role = Role, pending = Pending}) ->
            EncodedRole = encode_role({Role, Pending}),
            ["HSET", album_members_key(AlbumId), MUid, EncodedRole]
        end,
        Members)],
    UserCommand = ["HSET", user_albums_key(Uid), AlbumId, encode_role({owner, false})],
    AllCommands = [UserCommand] ++ [["HSET",
        album_key(AlbumId),
        ?FIELD_NAME, Name,
        ?FIELD_OWNER, Uid,
        ?FIELD_START_TIME, StartTs,
        ?FIELD_END_TIME, EndTs,
        ?FIELD_OFFSET, Offset,
        ?FIELD_LATITUDE, util:to_binary(Latitude),
        ?FIELD_LONGITUDE, util:to_binary(Longitude),
        ?FIELD_CAN_VIEW, CanView,
        ?FIELD_CAN_CONTRIBUTE, CanContribute]] ++ MemberCommands,
    qmn(AllCommands),
    AlbumId.


-spec get_album_info(AlbumId :: album_id()) -> maybe(album()).
get_album_info(AlbumId) ->
    [{ok, AlbumData}, {ok, AlbumMemberData}] = qp([["HGETALL", album_key(AlbumId)], ["HGETALL", album_members_key(AlbumId)]]),
    case AlbumData of
        [] -> undefined;
        _ ->
            AlbumMap = util:list_to_map(AlbumData),
            Members = lists:map(
                fun({Uid, RawRole}) ->
                    {Role, Pending} = decode_role(RawRole),
                    #album_member{uid = Uid, role = Role, pending = Pending}
                end,
                util_redis:parse_hgetall(AlbumMemberData)),
            #album{
                id = AlbumId,
                name = maps:get(?FIELD_NAME, AlbumMap),
                owner = maps:get(?FIELD_OWNER, AlbumMap),
                time_range = {util_redis:decode_int(maps:get(?FIELD_START_TIME, AlbumMap, undefined)),
                    util_redis:decode_int(maps:get(?FIELD_END_TIME, AlbumMap, undefined)),
                    util_redis:decode_int(maps:get(?FIELD_OFFSET, AlbumMap, undefined))},
                location = {util_redis:decode_float(maps:get(?FIELD_LATITUDE, AlbumMap, undefined)),
                    util_redis:decode_float(maps:get(?FIELD_LONGITUDE, AlbumMap, undefined))},
                can_view = util:to_atom(maps:get(?FIELD_CAN_VIEW, AlbumMap)),
                can_contribute = util:to_atom(maps:get(?FIELD_CAN_CONTRIBUTE, AlbumMap)),
                members = Members
            }
    end.


-spec get_album_media_items(album_id(), binary()) -> album().
get_album_media_items(AlbumId, Cursor) ->
    get_album_media_items(AlbumId, Cursor, ?MEDIA_ITEMS_PER_PAGE).

-spec get_album_media_items(album_id(), binary(), pos_integer()) -> album().
get_album_media_items(AlbumId, Cursor, Limit) ->
    Start = case Cursor of
        <<>> -> "-inf";
        _ -> "(" ++ util:to_list(Cursor)
    end,
    [{ok, MediaItemIdResults}] = q([
        ["ZRANGE", album_media_key(AlbumId), Start, "+inf", "BYSCORE", "LIMIT", 0, Limit, "WITHSCORES"]]),
    {MediaItemIds, Scores} = lists:unzip(util_redis:parse_zrange_with_scores(MediaItemIdResults)),
    {MediaItems, NewCursor} = case length(MediaItemIds) < ?MEDIA_ITEMS_PER_PAGE of
        true -> {get_media_items(AlbumId, MediaItemIds), <<>>};
        false -> {get_media_items(AlbumId, MediaItemIds), lists:last(Scores)}
    end,
    #album{
        id = AlbumId,
        media_items = MediaItems,
        cursor = NewCursor
    }.


-spec get_album(album_id()) -> maybe(album()).
get_album(AlbumId) ->
    get_album(AlbumId, <<>>).

-spec get_album(album_id(), binary()) -> maybe(album()).
get_album(AlbumId, Cursor) ->
    get_album(AlbumId, Cursor, ?MEDIA_ITEMS_PER_PAGE).

-spec get_album(album_id(), binary(), pos_integer()) -> maybe(album()).
get_album(AlbumId, Cursor, Limit) ->
    case get_album_info(AlbumId) of
        undefined -> undefined;
        AlbumWithInfo ->
            AlbumWithMedia = get_album_media_items(AlbumId, Cursor, Limit),
            AlbumWithInfo#album{
                media_items = AlbumWithMedia#album.media_items,
                cursor = AlbumWithMedia#album.cursor
            }
    end.


-spec delete_album(album_id()) -> ok.
delete_album(AlbumId) ->
    {ok, RawMemberData} = q(["HGETALL", album_members_key(AlbumId)]),
    MemberList = util_redis:parse_hgetall(RawMemberData),
    {ok, MediaItemIds} = q(["HGETALL", album_media_key(AlbumId)]),
    Commands1 = [
        ["DEL", album_key(AlbumId)],
        ["DEL", album_members_key(AlbumId)],
        ["DEL", album_media_key(AlbumId)]
    ],
    Commands2 = lists:foldl(
        fun({MUid, _EncodedRole}, AccList) ->
            [["HDEL", user_albums_key(MUid), AlbumId] | [["DEL", user_media_key(AlbumId, MUid)] | AccList]]
        end,
        [],
        MemberList),
    Commands3 = lists:map(
        fun(MediaItemId) ->
            ["DEL", media_item_key(AlbumId, MediaItemId)]
        end,
        MediaItemIds),
    qmn(lists:append([Commands1, Commands2, Commands3])),
    ok.


-spec get_user_albums(uid(), user_album_type()) -> list(album_id()).
get_user_albums(Uid, Type) ->
    {ok, RawUserAlbumData} = q(["HGETALL", user_albums_key(Uid)]),
    UserAlbumData = lists:map(fun({AId, EncRole}) -> {AId, decode_role(EncRole)} end,
        util_redis:parse_hgetall(RawUserAlbumData)),
    case Type of
        member ->
            lists:filtermap(
                fun({AId, {_Role, false}}) -> {true, AId}; (_) -> false end,
                UserAlbumData);
        invited ->
            lists:filtermap(
                fun({AId, {_Role, true}}) -> {true, AId}; (_) -> false end,
                UserAlbumData);
        all ->
            lists:map(fun({AId, _}) -> AId end, UserAlbumData)
    end.


-spec get_role(album_id(), uid()) -> album_role().
get_role(AlbumId, Uid) ->
    {ok, EncodedRole} = q(["HGET", album_members_key(AlbumId), Uid]),
    decode_role(EncodedRole).


-spec set_role(album_id(), uid(), album_role()) -> ok.
set_role(AlbumId, Uid, NewRole) ->
    EncodedRole = encode_role(NewRole),
    [{ok, _}, {ok, _}] = qmn([["HSET", album_members_key(AlbumId), Uid, EncodedRole],
        ["HSET", user_albums_key(Uid), AlbumId, EncodedRole]]),
    ok.


-spec remove_role(album_id(), uid()) -> ok.
remove_role(AlbumId, Uid) ->
    [{ok, _}, {ok, _}] = qmn([["HDEL", album_members_key(AlbumId), Uid],
        ["HDEL", user_albums_key(Uid), AlbumId]]),
    ok.


-spec execute_member_actions(album_id(), member_actions_list()) -> ok.
execute_member_actions(AlbumId, ActionList) ->
    Commands = lists:map(
        fun
            ({set, Uid, Role, Pending}) ->
                [["HSET", album_members_key(AlbumId), Uid, encode_role({Role, Pending})]];
            ({remove, Uid, RemoveAllMedia}) ->
                {ok, MediaItemIds} = q(["SMEMBERS", user_media_key(AlbumId, Uid)]),
                case RemoveAllMedia of
                    true ->
                        [["ZREM", album_media_key(AlbumId) | MediaItemIds],
                            ["HDEL", album_members_key(AlbumId), Uid],
                            ["DEL", user_media_key(AlbumId, Uid)]] ++
                            lists:map(fun(Id) -> ["DEL", media_item_key(AlbumId, Id)] end, MediaItemIds);
                    false ->
                        [["HDEL", album_members_key(AlbumId), Uid]]
                end
        end,
        ActionList),
    qp(lists:append(Commands)),
    ok.


-spec get_name(album_id()) -> bad_album_id | binary().
get_name(AlbumId) ->
    {ok, Name} = q(["HGET", album_key(AlbumId), ?FIELD_NAME]),
    case Name of
        undefined -> bad_album_id;
        _ -> Name
    end.


-spec set_name(album_id(), binary()) -> ok.
set_name(AlbumId, Name) ->
    {ok, _} = q(["HSET", album_key(AlbumId), ?FIELD_NAME, Name]),
    ok.


-spec get_location(album_id()) -> location().
get_location(AlbumId) ->
    {ok, [RawLatitude, RawLongitude]} = q(["HMGET", album_key(AlbumId), ?FIELD_LATITUDE, ?FIELD_LONGITUDE]),
    {util_redis:decode_float(RawLatitude), util_redis:decode_float(RawLongitude)}.


-spec set_location(album_id(), location()) -> ok.
set_location(AlbumId, {Latitude, Longitude}) ->
    {ok, _} = q(["HSET", album_key(AlbumId), ?FIELD_LATITUDE, util:to_binary(Latitude), ?FIELD_LONGITUDE, util:to_binary(Longitude)]),
    ok.


-spec get_time_range(album_id()) -> time_range().
get_time_range(AlbumId) ->
    {ok, [StartTs, EndTs, UtcOffset]} = q(["HMGET", album_key(AlbumId), ?FIELD_START_TIME, ?FIELD_END_TIME, ?FIELD_OFFSET]),
    {util_redis:decode_int(StartTs), util_redis:decode_int(EndTs), util_redis:decode_int(UtcOffset)}.


-spec set_time_range(album_id(), time_range()) -> ok.
set_time_range(AlbumId, {StartTs, EndTs, Offset}) ->
    {ok, _} = q(["HSET", album_key(AlbumId), ?FIELD_START_TIME, StartTs, ?FIELD_END_TIME, EndTs, ?FIELD_OFFSET, Offset]),
    ok.


-spec get_contribute_access(album_id()) -> bad_album_id | share_access().
get_contribute_access(AlbumId) ->
    get_access(AlbumId, contribute).


-spec set_contribute_access(album_id(), share_access()) -> ok.
set_contribute_access(AlbumId, Access) ->
    set_access(AlbumId, contribute, Access).


-spec get_view_access(album_id()) -> bad_album_id | share_access().
get_view_access(AlbumId) ->
    get_access(AlbumId, view).


-spec set_view_access(album_id(), share_access()) -> ok.
set_view_access(AlbumId, Access) ->
    set_access(AlbumId, view, Access).


-spec get_all_members(album_id()) -> list({uid(), album_role()}).
get_all_members(AlbumId) ->
    {ok, RawMemberData} = q(["HGETALL", album_members_key(AlbumId)]),
    MemberData = util_redis:parse_hgetall(RawMemberData),
    lists:map(fun({Uid, EncodedRole}) -> {Uid, decode_role(EncodedRole)} end, MemberData).


%% TODO: add a function to decode client payload, so we can inspect these items for debugging
-spec get_media_items(AlbumId :: album_id(), MediaItemIds :: binary() | list(binary())) -> list(maybe(pb_media_item())).
get_media_items(AlbumId, MediaItemId) when not is_list(MediaItemId) ->
    get_media_items(AlbumId, [MediaItemId]);
get_media_items(AlbumId, MediaItemIds) ->
    Commands = lists:map(
        fun(MediaItemId) ->
            ["HMGET", media_item_key(AlbumId, MediaItemId), ?FIELD_MEDIA_ITEM_PUBLISHER_UID, ?FIELD_MEDIA_ITEM_PAYLOAD,
                ?FIELD_MEDIA_ITEM_DEVICE_TS_MS, ?FIELD_MEDIA_ITEM_UPLOAD_TS_MS, ?FIELD_MEDIA_ITEM_PARENT_MEDIA_ID]
        end,
        MediaItemIds),
    Results = qmn(Commands),
    MediaItems1 = lists:zipwith(
        fun({ok, [PUid, Payload, DeviceTsMs, UploadTsMs, ParentMediaId]}, MediaItemId) ->
            %% Check if media item exists
            case PUid of
                undefined -> undefined;
                _ ->
                    #pb_media_item{
                        id = MediaItemId,
                        publisher_uid = PUid,
                        album_id = AlbumId,
                        payload = Payload,
                        device_capture_timestamp_ms = util_redis:decode_int(DeviceTsMs),
                        upload_timestamp_ms = util_redis:decode_int(UploadTsMs),
                        parent_media_id = ParentMediaId
                    }
            end
        end,
        Results, MediaItemIds),
    PUids = lists:foldl(
        fun(#pb_media_item{publisher_uid = PUid}, AccUids) ->
                sets:add_element(PUid, AccUids);
            (_, Acc) -> Acc
        end,
        sets:new(),
        MediaItems1),
    PUidInfoMap = lists:foldl(
        fun(PUid, AccMap) ->
            {Name, Username, _AvatarId} = model_accounts:get_album_member_info(PUid),
            maps:put(PUid, {Name, Username}, AccMap)
        end,
        #{},
        sets:to_list(PUids)),
    lists:map(
        fun(#pb_media_item{publisher_uid = PUid} = PbMediaItem) ->
                {Name, Username} = maps:get(PUid, PUidInfoMap),
                PbMediaItem#pb_media_item{publisher_name = Name, publisher_username = Username};
            (undefined) -> undefined
        end,
        MediaItems1).


-spec store_media_items(AlbumId :: album_id(), PbMediaItems :: pb_media_item() | list(pb_media_item())) -> ok.
store_media_items(AlbumId, PbMediaItem) when not is_list(PbMediaItem) ->
    store_media_items(AlbumId, [PbMediaItem]);
store_media_items(AlbumId, PbMediaItems) ->
    Commands = lists:map(
        fun(#pb_media_item{id = Id, publisher_uid = PUid, payload = Payload, device_capture_timestamp_ms = DeviceTsMs,
            upload_timestamp_ms = UploadTsMs, parent_media_id = ParentMediaId}) ->
            [["ZADD", album_media_key(AlbumId), DeviceTsMs, Id],
                ["SADD", user_media_key(AlbumId, PUid), Id],
                ["HSET", media_item_key(AlbumId, Id),
                    ?FIELD_MEDIA_ITEM_PUBLISHER_UID, PUid,
                    ?FIELD_MEDIA_ITEM_PAYLOAD, Payload,
                    ?FIELD_MEDIA_ITEM_DEVICE_TS_MS, DeviceTsMs,
                    ?FIELD_MEDIA_ITEM_UPLOAD_TS_MS, UploadTsMs,
                    ?FIELD_MEDIA_ITEM_PARENT_MEDIA_ID, ParentMediaId]]
        end,
        PbMediaItems),
    qp(lists:append(Commands)),
    ok.


-spec remove_media_items(album_id(), uid(), binary() | list(binary())) -> ok.
remove_media_items(AlbumId, Uid, MediaId) when not is_list(MediaId) ->
    remove_media_items(AlbumId, Uid, [MediaId]);
remove_media_items(AlbumId, Uid, MediaIds) ->
    Commands = lists:map(
        fun(MediaId) ->
            [["ZREM", album_media_key(AlbumId), MediaId],
                ["SREM", user_media_key(AlbumId, Uid), MediaId],
                ["DEL", media_item_key(AlbumId, MediaId)]]
        end,
        MediaIds),
    qp(lists:append(Commands)),
    ok.


-spec decode_role(encoded_album_role()) -> album_role().
decode_role(RawRole) ->
    case RawRole of
        <<"owner">> -> {owner, false};
        <<"admin">> -> {admin, false};
        <<"contributor">> -> {contributor, false};
        <<"viewer">> -> {viewer, false};
        <<"pending_admin">> -> {admin, true};
        <<"pending_contributor">> -> {contributor, true};
        <<"pending_viewer">> -> {viewer, true};
        _ -> {none, false}
    end.


-spec encode_role(album_role()) -> encoded_album_role().
encode_role(Role) ->
    case Role of
        {owner, false} -> <<"owner">>;
        {admin, false} -> <<"admin">>;
        {contributor, false} -> <<"contributor">>;
        {viewer, false} -> <<"viewer">>;
        {admin, true} -> <<"pending_admin">>;
        {contributor, true} -> <<"pending_contributor">>;
        {viewer, true} -> <<"pending_viewer">>;
        {none, false} -> <<"none">>
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec get_access(album_id(), share_type()) -> bad_album_id | share_access().
get_access(AlbumId, Type) ->
    Field = case Type of
                contribute -> ?FIELD_CAN_CONTRIBUTE;
                view -> ?FIELD_CAN_VIEW
            end,
    {ok, Access} = q(["HGET", album_key(AlbumId), Field]),
    case Access of
        undefined -> bad_album_id;
        _ -> util:to_atom(Access)
    end.


-spec set_access(album_id(), share_type(), share_access()) -> ok.
set_access(AlbumId, Type, Access) ->
    Field = case Type of
        contribute -> ?FIELD_CAN_CONTRIBUTE;
        view -> ?FIELD_CAN_VIEW
    end,
    {ok, _} = q(["HSET", album_key(AlbumId), Field, Access]),
    ok.


-spec album_key(AlbumId :: album_id()) -> binary().
album_key(AlbumId) ->
    <<?ALBUM_KEY/binary, <<"{">>/binary, AlbumId/binary, <<"}">>/binary>>.


-spec album_members_key(AlbumId :: album_id()) -> binary().
album_members_key(AlbumId) ->
    <<?ALBUM_MEMBERS_KEY/binary, <<"{">>/binary, AlbumId/binary, <<"}">>/binary>>.


-spec album_media_key(AlbumId :: album_id()) -> binary().
album_media_key(AlbumId) ->
    <<?ALBUM_MEDIA_KEY/binary, <<"{">>/binary, AlbumId/binary, <<"}">>/binary>>.


-spec media_item_key(album_id(), binary()) -> binary().
media_item_key(AlbumId, MediaItemId) ->
    <<?MEDIA_ITEM_KEY/binary, "{", AlbumId/binary, "}:", MediaItemId/binary>>.


-spec user_albums_key(uid()) -> binary().
user_albums_key(Uid) ->
    <<?USER_ALBUMS_KEY/binary, "{", Uid/binary, "}">>.


-spec user_media_key(album_id(), uid()) -> binary().
user_media_key(AlbumId, Uid) ->
    <<?USER_MEDIA_KEY/binary, "{", AlbumId/binary, "}:", Uid/binary>>.


q(Command) -> ecredis:q(ecredis_feed, Command).
qp(Commands) -> ecredis:qp(ecredis_feed, Commands).
qmn(Commands) -> util_redis:run_qmn(ecredis_feed, Commands).

