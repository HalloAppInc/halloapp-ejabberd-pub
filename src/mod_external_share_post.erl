%%%-----------------------------------------------------------------------------------
%%% File    : mod_external_share_post.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%-----------------------------------------------------------------------------------

-module(mod_external_share_post).
-behaviour(gen_mod).
-author('vipin').

-include("ha_types.hrl").
-include("packets.hrl").
-include("logger.hrl").
-include("feed.hrl").

-define(MAX_STORE_ITERATION, 3).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    process_local_iq/1,
    get_share_post/1,
    store_share_post/5  %% for testing
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_external_share_post, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_external_share_post),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% feed: IQs
%%====================================================================

%% Get post blob.
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_external_share_post{action = get, blob_id = BlobId}} = IQ) ->
    ?INFO("get share_post Uid: ~s", [Uid]),
    case get_share_post(BlobId) of
        {ok, ExternalSharePostContainer} ->
            {PushName, Avatar} = mod_http_share_post:get_push_name_and_avatar(
                ExternalSharePostContainer#pb_external_share_post_container.uid),
            pb:make_iq_result(IQ,
                ExternalSharePostContainer#pb_external_share_post_container{
                    name = PushName, avatar_id = Avatar});
        {error, Reason} ->
            ?ERROR("get share_post Uid: ~s, error: ~p", [Uid, Reason]),
            pb:make_error(IQ, util:err(Reason))
    end;

%% Store post blob.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_external_share_post{action = store, blob = PostBlob,
        expires_in_seconds = ExpireIn, og_tag_info = OgTagInfo}} = IQ) ->
    ?INFO("store share_post Uid: ~s", [Uid]),
    case store_share_post(Uid, PostBlob, ExpireIn, OgTagInfo, 1) of
        {ok, BlobId} ->
            pb:make_iq_result(IQ, #pb_external_share_post{blob_id = BlobId});
        {error, Reason} ->
            ?ERROR("store share_post Uid: ~s, error: ~p", [Uid, Reason]),
            pb:make_error(IQ, util:err(Reason))
    end;

%% Delete post blob.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_external_share_post{action = delete, blob_id = BlobId}} = IQ) ->
    ?INFO("delete share_post Uid: ~s, Blob Id: ~s", [Uid, BlobId]),
    case delete_share_post(Uid, BlobId) of
        ok ->
            pb:make_iq_result(IQ);
        {error, Reason} ->
            ?ERROR("delete share_post Uid: ~s, error: ~p", [Uid, Reason]),
            pb:make_error(IQ, util:err(Reason))
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec store_share_post(Uid :: uid(), PostBlob :: binary(), ExpireIn :: integer(),
    OgTagInfo :: maybe(#pb_og_tag_info{}), Iter :: integer())
        -> {ok, binary()} | {error, any()}.
store_share_post(_Uid, _PostBlob, _ExpireIn, _OgTagInfo, Iter) when Iter > ?MAX_STORE_ITERATION ->
    {error, non_uniq_post_id};
store_share_post(_Uid, _PostBlob, undefined, _OgTagInfo, _Iter) ->
    {error, null_expires_in};
store_share_post(_Uid, _PostBlob, ExpireIn, _OgTagInfo, _Iter) when ExpireIn =< 0 orelse ExpireIn > ?POST_EXPIRATION ->
    {error, invalid_expires_in};
store_share_post(Uid, PostBlob, ExpireIn, OgTagInfo, Iter) ->
    IsDev = dev_users:is_dev_uid(Uid),
    Title = case OgTagInfo of
        undefined -> undefined;
        _ -> OgTagInfo#pb_og_tag_info.title
    end,
    BlobId = case Iter of
        1 -> util:random_str(8);
        2 -> util:random_str(8);
        _ -> util:random_str(22)
    end,
    ?INFO("Uid: ~s, BlobId: ~s, Title: ~s", [Uid, BlobId, Title]),
    PostContainer = #pb_external_share_post_container{
        uid = Uid,
        blob = PostBlob,
        og_tag_info = OgTagInfo
    },
    case enif_protobuf:encode(PostContainer) of
        {error, Reason} ->
            ?ERROR("Unable to encode, error: ~p", [Reason]),
            {error, protobuf_encode_error};
        EncPostContainer ->
            case model_feed:store_external_share_post(BlobId, EncPostContainer, ExpireIn) of
                true ->
                    stat:count("HA/share_post", "store"),
                    stat:count("HA/share_post_by_dev", "store", 1, [{is_dev, IsDev}]),
                    {ok, BlobId};
                false ->
                    ?INFO("BlobId: ~s already exists, trying again, Iter: ~p", [BlobId, Iter + 1]),
                    store_share_post(Uid, PostBlob, ExpireIn, OgTagInfo, Iter + 1)
            end
    end.


-spec delete_share_post(Uid :: uid(), BlobId :: binary()) -> ok | {error, any()}.
delete_share_post(Uid, BlobId) ->
    ?INFO("Uid: ~s, BlobId: ~s", [Uid, BlobId]),
    IsDev = dev_users:is_dev_uid(Uid),
    stat:count("HA/share_post", "delete"),
    stat:count("HA/share_post_by_dev", "delete", 1, [{is_dev, IsDev}]),
    ok = model_feed:delete_external_share_post(BlobId),
    ok.

-spec get_share_post(BlobId :: binary()) -> {ok, pb_external_share_post_container()} | {error, any()}.
get_share_post(BlobId) ->
    ?INFO("BlobId: ~s", [BlobId]),
    case model_feed:get_external_share_post(BlobId) of
        {ok, undefined} ->
            ?INFO("Blob not found: ~s", [BlobId]),
            {error, not_found};
        {ok, Blob} ->
            case enif_protobuf:decode(Blob, pb_external_share_post_container) of
                {error, Reason} ->
                    ?ERROR("Unable to decode blob: ~s, error: ~p", [BlobId, Reason]),
                    {error, protbuf_decode_error};
                Pkt ->
                    stat:count("HA/share_post", "get"),
                    {ok, Pkt}
            end
    end.

