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
    store_share_post/4  %% for testing
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

%% Store post blob.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_external_share_post{action = store, blob = PostBlob,
        expires_in_seconds = ExpireIn}} = IQ) ->
    ?INFO("store share_post Uid: ~s", [Uid]),
    case store_share_post(Uid, PostBlob, ExpireIn, 1) of
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

-spec store_share_post(Uid :: uid(), PostBlob :: binary(), ExpireIn :: integer(), Iter :: integer())
        -> {ok, binary()} | {error, any()}.
store_share_post(_Uid, _PostBlob, _ExpireIn, Iter) when Iter > ?MAX_STORE_ITERATION ->
    {error, non_uniq_post_id};
store_share_post(_Uid, _PostBlob, undefined, _Iter) ->
    {error, null_expires_in};
store_share_post(_Uid, _PostBlob, ExpireIn, _Iter) when ExpireIn =< 0 orelse ExpireIn > ?POST_EXPIRATION ->
    {error, invalid_expires_in};
store_share_post(Uid, PostBlob, ExpireIn, Iter) ->
    BlobId = case Iter of
        1 -> util:random_str(8);
        2 -> util:random_str(8);
        _ -> util:random_str(22)
    end,
    ?INFO("Uid: ~s, BlobId: ~s", [Uid, BlobId]),
    PostContainer = #pb_external_share_post_container{
        uid = Uid,
        blob = PostBlob
    },
    case enif_protobuf:encode(PostContainer) of
        {error, Reason} ->
            ?ERROR("Unable to encode, error: ~p", [Reason]),
            {error, protobuf_encode_error};
        EncPostContainer ->
            case model_feed:store_external_share_post(BlobId, EncPostContainer, ExpireIn) of
                true -> {ok, BlobId};
                false ->
                    ?INFO("BlobId: ~s already exists, trying again, Iter: ~p", [BlobId, Iter + 1]),
                    store_share_post(Uid, PostBlob, ExpireIn, Iter + 1)
            end
    end.


-spec delete_share_post(Uid :: uid(), BlobId :: binary()) -> ok | {error, any()}.
delete_share_post(Uid, BlobId) ->
    ?INFO("Uid: ~s, BlobId: ~s", [Uid, BlobId]),
    ok = model_feed:delete_external_share_post(BlobId),
    ok.

