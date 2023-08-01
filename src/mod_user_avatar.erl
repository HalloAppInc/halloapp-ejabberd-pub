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
-include("packets.hrl").
-include("ha_types.hrl").
-include("ejabberd_stacktrace.hrl").

-define(AVATAR_OPTIONS_ETS, user_avatar_options).
-define(AWS_BUCKET_NAME, <<"halloapp-avatars">>).
-define(MAX_SMALL_AVATAR_SIZE, 51200).     %% 50KB
-define(MAX_FULL_AVATAR_SIZE, 512000).     %% 500KB


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    remove_user/2,
    user_avatar_published/3,
    check_and_upload_avatar/2,
    delete_avatar_s3/1
]).


start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    %% HalloApp
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_avatar, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_avatars, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_upload_avatar, ?MODULE, process_local_iq),
    % remove_user hook should run, before the redis data is deleted.
    % Otherwise we will not know what the old avatar_id was to delete from S3.
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 10),
    ejabberd_hooks:add(user_avatar_published, halloapp, ?MODULE, user_avatar_published, 50),
    %% Katchup
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_avatar, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_avatars, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_upload_avatar, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, katchup, ?MODULE, remove_user, 10),
    %% Photo Sharing
    gen_iq_handler:add_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_avatar, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_avatars, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_upload_avatar, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, ?PHOTO_SHARING, ?MODULE, remove_user, 10),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    %% HalloApp
    ejabberd_hooks:delete(user_avatar_published, halloapp, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_avatar),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_avatars),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_upload_avatar),
    %% Katchup
    ejabberd_hooks:delete(remove_user, katchup, ?MODULE, remove_user, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_avatar),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_avatars),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_upload_avatar),
    %% Photo Sharing
    ejabberd_hooks:delete(remove_user, ?PHOTO_SHARING, ?MODULE, remove_user, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_avatar),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_avatars),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_upload_avatar),
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
        payload = #pb_upload_avatar{data = Data, full_data = _FullData}} = IQ)
        when Data =:= undefined ->  %% orelse FullData =:= undefined - uncomment after 12-08-2021.
    process_delete_user_avatar(IQ, UserId);

%%% set_user_avatar %%%
process_local_iq(#pb_iq{from_uid = UserId, type = set,
        payload = #pb_upload_avatar{data = Data, full_data = FullData}} = IQ) ->
    %% TODO(murali@): remove this case after 12-08-2021.
    FinalFullData = case FullData of
        undefined -> Data;
        _ -> FullData
    end,
    process_set_user_avatar(IQ, UserId, Data, FinalFullData);

%%% get_avatar (friend) %%%
process_local_iq(#pb_iq{from_uid = _UserId, type = get,
        payload = #pb_avatar{uid = FriendId}} = IQ) ->
    pb:make_iq_result(IQ, #pb_avatar{uid = FriendId, id = model_accounts:get_avatar_id_binary(FriendId)});

%%% get_avatars %%%
process_local_iq(#pb_iq{from_uid = _UserId, type = get,
        payload = #pb_avatars{avatars = Avatars}} = IQ) ->
    NewAvatars = lists:foreach(
        fun(#pb_avatar{uid = FriendId} = Avatar) ->
            Avatar#pb_avatar{id = model_accounts:get_avatar_id_binary(FriendId)}
        end, Avatars),
    pb:make_iq_result(IQ, #pb_avatars{avatars = NewAvatars}).


% Remove user hook is run before the user data is actually deleted.
remove_user(UserId, Server) ->
    delete_user_avatar_internal(UserId, Server).


% TODO: get the W and H from the image data and make sure they are <= 256
-spec check_and_upload_avatar(SmallData :: binary(), FullData :: binary()) ->
        {ok, avatar_id()} | {error, bad_data | max_size | bad_format | upload_error}.
check_and_upload_avatar(SmallData, FullData) ->
    SmallDataSize = byte_size(SmallData),
    IsSmallImageJpeg = is_jpeg(SmallData),
    FullDataSize = byte_size(FullData),
    IsFullImageJpeg = is_jpeg(FullData),
    if
        SmallDataSize > ?MAX_SMALL_AVATAR_SIZE -> {error, max_size};
        FullDataSize > ?MAX_FULL_AVATAR_SIZE -> {error, max_size};
        IsSmallImageJpeg =:= false -> {error, bad_format};
        IsFullImageJpeg =:= false -> {error, bad_format};
        true ->
            case upload_avatar(SmallData, FullData) of
                error -> {error, upload_error};
                {ok, AvatarId} -> {ok, AvatarId}
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
-spec process_set_user_avatar(IQ :: iq(), Uid :: uid(),
    Data :: binary(), FullData :: binary()) -> iq().
process_set_user_avatar(IQ, Uid, Data, FullData) ->
    ?INFO("Uid: ~s uploading avatar small_size: ~p, full_size: ~p",
        [Uid, byte_size(Data), byte_size(FullData)]),
    case check_and_upload_avatar(Data, FullData) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, AvatarId} ->
            ?INFO("Uid: ~s AvatarId: ~s", [Uid, AvatarId]),
            update_user_avatar(Uid, util:get_host(), AvatarId),
            pb:make_iq_result(IQ, #pb_avatar{id = AvatarId})
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
    AppType = util_uid:get_app_type(UserId),
    ejabberd_hooks:run(user_avatar_published, AppType, [UserId, Server, AvatarId]),
    delete_avatar_s3(OldAvatarId),
    ok.

% TODO: No longer needed here. model_halloapp_friends does the job of publishing it to relevant audience.
-spec user_avatar_published(UserId :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(UserId, _Server, AvatarId) ->
    ?INFO("Uid: ~p, AvatarId: ~p", [UserId, AvatarId]),
    {ok, Friends} = model_friends:get_friends(UserId),
    lists:foreach(
        fun(FriendId) ->
            Message = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = FriendId,
                payload = #pb_avatar{uid = UserId, id = AvatarId}},
            ejabberd_router:route(Message)
        end, Friends).


-spec upload_avatar(SmallData :: binary(), FullData :: binary()) -> {ok, avatar_id()} | error.
upload_avatar(SmallData, FullData) ->
    AvatarId = util_id:new_avatar_id(),
    case upload_avatar(?AWS_BUCKET_NAME, AvatarId, SmallData, FullData) of
        ok -> {ok, AvatarId};
        error -> error
    end.


-spec upload_avatar(BucketName :: binary(), AvatarId :: avatar_id(),
        SmallData :: binary(), FullData :: binary()) -> ok | error.
upload_avatar(BucketName, AvatarId, SmallData, FullData) ->
    Headers = [{"content-type", "image/jpeg"}],
    try
        SmallAvatarId = binary_to_list(AvatarId),
        Result1 = erlcloud_s3:put_object(binary_to_list(BucketName), SmallAvatarId, SmallData, [], Headers),
        FullAvatarId = binary_to_list(AvatarId) ++ "-full",
        Result2 = erlcloud_s3:put_object(binary_to_list(BucketName), FullAvatarId, FullData, [], Headers),
        ?INFO("AvatarId: ~s, Result_small: ~p, Result_full: ~p",
            [FullAvatarId, Result1, Result2]),
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

