%%%----------------------------------------------------------------------
%%% File    : mod_user_avatar.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% Handles all iq queries related to user avatars.
%%%----------------------------------------------------------------------

-module(mod_user_avatar).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("ha_types.hrl").
-include("ejabberd_stacktrace.hrl").

-define(AVATAR_OPTIONS_ETS, user_avatar_options).
-define(AWS_BUCKET_NAME, <<"halloapp-avatars">>).
-define(MAX_AVATAR_SIZE, 51200).    %% 50KB
-define(MAX_AVATAR_DIM, 256).


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    remove_user/2,
    user_avatar_published/3,
    check_and_upload_avatar/1,
    delete_avatar_s3/1
]).


start(Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_avatar, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_avatars, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_upload_avatar, ?MODULE, process_local_iq),
    % remove_user hook should run, before the redis data is deleted.
    % Otherwise we will not know what the old avatar_id was to delete from S3.
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 10),
    ejabberd_hooks:add(user_avatar_published, Host, ?MODULE, user_avatar_published, 50),
    ok.

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ejabberd_hooks:delete(user_avatar_published, Host, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_avatar),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_avatars),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_upload_avatar),
    ok.


depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers
%%====================================================================

%%% delete_user_avatar %%%
process_local_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_upload_avatar{data = Data}} = IQ) when Data =:= undefined ->
    process_delete_user_avatar(IQ, UserId);

%%% set_user_avatar %%%
process_local_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_upload_avatar{data = Data}} = IQ) ->
    process_set_user_avatar(IQ, UserId, base64:encode(Data));

%%% get_avatar (friend) %%%
process_local_iq(#pb_iq{from_uid = UserId, type = get,
        payload = #pb_avatar{uid = FriendId}} = IQ) ->
    case check_and_get_avatar_id(UserId, FriendId) of
        undefined ->
            ?WARNING("Uid: ~s, Invalid friend_uid: ~s", [UserId, FriendId]),
            pb:make_error(IQ, util:err(invalid_friend_uid));
        AvatarId ->
            pb:make_iq_result(IQ, #pb_avatar{uid = FriendId, id = AvatarId})
    end;

%%% get_avatars %%%
process_local_iq(#pb_iq{from_uid = UserId, type = get,
        payload = #pb_avatars{avatars = Avatars}} = IQ) ->
    NewAvatars = lists:foreach(
        fun(#pb_avatar{uid = FriendId} = Avatar) ->
            Avatar#pb_avatar{id = check_and_get_avatar_id(UserId, FriendId)}
        end, Avatars),
    pb:make_iq_result(IQ, #pb_avatars{avatars = NewAvatars}).


% Remove user hook is run before the user data is actually deleted.
remove_user(UserId, Server) ->
    delete_user_avatar_internal(UserId, Server).


% TODO: get the W and H from the image data and make sure they are <= 256
-spec check_and_upload_avatar(Base64Data :: binary()) ->
        {ok, avatar_id()} | {error, bad_data | max_size | bad_format | upload_error}.
check_and_upload_avatar(Base64Data) ->
    case util:decode_base_64(Base64Data) of
        {error, bad_data} -> {error, bad_data};
        {ok, Data} ->
            DataSize = byte_size(Data),
            IsJpeg = is_jpeg(Data),
            if
                DataSize > ?MAX_AVATAR_SIZE -> {error, max_size};
                IsJpeg =:= false -> {error, bad_format};
                true ->
                    case upload_avatar(Data) of
                        error -> {error, upload_error};
                        {ok, AvatarId} -> {ok, AvatarId}
                    end
            end
    end.


%%====================================================================
%% internal functions
%%====================================================================


-spec process_delete_user_avatar(IQ :: iq(), Uid :: uid()) -> iq().
process_delete_user_avatar(IQ, Uid) ->
    ?INFO("Uid: ~s deleting avatar", [Uid]),
    delete_user_avatar_internal(Uid, util:get_host()),
    pb:make_iq_result(IQ, #pb_avatar{id = <<>>}).


%% TODO(murali@): update functions here to work on binary data after updating group_avatars.
-spec process_set_user_avatar(IQ :: iq(), Uid :: uid(), Base64Data :: binary()) -> iq().
process_set_user_avatar(IQ, Uid, Base64Data) ->
    ?INFO("Uid: ~s uploading avatar base64_size: ~p", [Uid, byte_size(Base64Data)]),
    case check_and_upload_avatar(Base64Data) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, AvatarId} ->
            ?INFO("Uid: ~s AvatarId: ~s", [Uid, AvatarId]),
            update_user_avatar(Uid, util:get_host(), AvatarId),
            pb:make_iq_result(IQ, #pb_avatar{id = AvatarId})
    end.


-spec check_and_get_avatar_id(Uid :: uid(), FriendUid :: uid()) -> undefined | avatar_id().
check_and_get_avatar_id(Uid, Uid) ->
    model_accounts:get_avatar_id_binary(Uid);
check_and_get_avatar_id(Uid, FriendUid) ->
    case model_friends:is_friend(Uid, FriendUid) of
        false ->
            undefined;
        true ->
            model_accounts:get_avatar_id_binary(Uid)
    end.


-spec delete_user_avatar_internal(Uid :: uid(), Server :: binary()) -> ok.
delete_user_avatar_internal(Uid, Server) ->
    update_user_avatar(Uid, Server, <<>>),
    ok.


-spec delete_avatar_s3(AvatarId :: avatar_id() | undefined) -> ok | error.
delete_avatar_s3(undefined) ->
    ok;
delete_avatar_s3(<<>>) ->
    ?WARNING("AvatarId is empty binary"),
    ok;
delete_avatar_s3(AvatarId) ->
    try
        Result = erlcloud_s3:delete_object(
            binary_to_list(?AWS_BUCKET_NAME), binary_to_list(AvatarId)),
        ?INFO("AvatarId: ~s, Result: ~p", [AvatarId, Result]),
        ok
    catch Class:Reason:St ->
        ?ERROR("AvatarId: ~s failed to delete object on s3: Stacktrace: ~p",
            [AvatarId, lager:pr_stacktrace(St, {Class, Reason})]),
        error
    end.


-spec update_user_avatar(UserId :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
update_user_avatar(UserId, Server, AvatarId) ->
    {ok, OldAvatarId} = model_accounts:get_avatar_id(UserId),
    case AvatarId of
        <<>> ->
            model_accounts:delete_avatar_id(UserId);
        AvatarId ->
            model_accounts:set_avatar_id(UserId, AvatarId)
    end,
    ejabberd_hooks:run(user_avatar_published, Server, [UserId, Server, AvatarId]),
    delete_avatar_s3(OldAvatarId),
    ok.


-spec user_avatar_published(UserId :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(UserId, Server, AvatarId) ->
    {ok, Friends} = model_friends:get_friends(UserId),
    lists:foreach(
        fun(FriendId) ->
            Message = #message{
                id = util:new_msg_id(),
                to = jid:make(FriendId, Server),
                from = jid:make(Server),
                sub_els = [#avatar{userid = UserId, id = AvatarId}]},
            ejabberd_router:route(Message)
        end, Friends).


-spec upload_avatar(BinaryData :: binary()) -> {ok, avatar_id()} | error.
upload_avatar(BinaryData) ->
    AvatarId = util:new_avatar_id(),
    case upload_avatar(?AWS_BUCKET_NAME, AvatarId, BinaryData) of
        ok -> {ok, AvatarId};
        error -> error
    end.


-spec upload_avatar(BucketName :: binary(), AvatarId :: avatar_id(), BinaryData :: binary())
        -> ok | error.
upload_avatar(BucketName, AvatarId, BinaryData) ->
    Headers = [{"content-type", "image/jpeg"}],
    try
        Result = erlcloud_s3:put_object(binary_to_list(
                BucketName), binary_to_list(AvatarId), BinaryData, [], Headers),
        ?INFO("AvatarId: ~s, Result: ~p", [AvatarId, Result]),
        ok
    catch ?EX_RULE(Class, Reason, St) ->
        StackTrace = ?EX_STACK(St),
        ?ERROR("AvatarId: ~s, Error uploading object on s3: response:~n~ts",
               [AvatarId, misc:format_exception(2, Class, Reason, StackTrace)]),
        error
    end.


-spec is_jpeg(BinaryData :: binary()) -> boolean().
is_jpeg(<<255, 216, _/binary>>) ->
    true;
is_jpeg(_) ->
    false.

