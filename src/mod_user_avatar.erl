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
-include("translate.hrl").
-include("ejabberd_stacktrace.hrl").

-define(AVATAR_OPTIONS_ETS, user_avatar_options).
-define(NS_USER_AVATAR, <<"halloapp:user:avatar">>).
-define(AWS_BUCKET_NAME, <<"halloapp-avatars">>).
-define(MAX_AVATAR_SIZE, 51200).    %% 50KB
-define(MAX_AVATAR_DIM, 256).
-type(avatar_id() :: binary()).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    remove_user/2,
    user_avatar_published/3,
    upload_group_avatar/2
]).


start(Host, _Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_USER_AVATAR, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_avatar_published, Host, ?MODULE, user_avatar_published, 50),
    ok.

stop(Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    ejabberd_hooks:delete(user_avatar_published, Host, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_USER_AVATAR),
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

%% TODO(murali@): we should not rely on metadata info from the client.
process_local_iq(#iq{from = #jid{luser = UserId, lserver = Server}, type = set, lang = Lang,
        sub_els = [#avatar{width = Width, height = Height,
        userid = Uid, id = Id, cdata = Data}]} = IQ) ->
        try
            BinaryData = base64:decode(Data),
            BytesSize = byte_size(BinaryData),
            IsJpeg = is_jpeg(BinaryData),
            MaxDim = max(Width, Height),
            if
                Id =/= <<>> andalso Id =/= undefined ->
                    Txt = ?T("Invalid id in the avatar xml element"),
                    ?WARNING_MSG("Uid: ~s, Invalid id: ~s in the avatar xml element", [UserId, Id]),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                BytesSize > ?MAX_AVATAR_SIZE ->
                    Txt = ?T("Avatar size is too large, limit < 50KB."),
                    ?WARNING_MSG("Uid: ~s, Avatar is too large, size: ~s", [UserId, BytesSize]),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                MaxDim > ?MAX_AVATAR_DIM andalso MaxDim =/= undefined ->
                    Txt = ?T("Avatar must have a max dimension of 256."),
                    ?WARNING_MSG("Uid: ~s, Avatar has wrong dimensions: ~s x ~s",
                            [UserId, Width, Height]),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                Uid =/= UserId andalso Uid =/= <<>> ->
                    Txt = ?T("Invalid uid in the request."),
                    ?WARNING_MSG("Uid: ~s, Invalid user id: ~s in the request", [UserId, Uid]),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                IsJpeg =:= false andalso BytesSize > 0 ->
                    Txt = ?T("Invalid image format in the request, accepts only jpeg."),
                    ?WARNING_MSG("Uid: ~s, Invalid image format in the request", [UserId]),
                    xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                true ->
                    case publish_user_avatar(UserId, Server, BinaryData) of
                        error ->
                            Txt = ?T("Internal server error: failed to set avatar"),
                            ?ERROR_MSG("Userid: ~s, Failed to set avatar", [UserId]),
                            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
                        AvatarId ->
                            xmpp:make_iq_result(IQ, #avatar{id = AvatarId})
                    end
            end
        catch ?EX_RULE(Class, Reason, St) ->
            StackTrace = ?EX_STACK(St),
            ?ERROR_MSG("Userid: ~s, Invalid image data, response:~n~ts",
                    [UserId, misc:format_exception(2, Class, Reason, StackTrace)]),
            Text = ?T("Invalid image data: expected base64 encoded jpeg image data"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Text, Lang))
        end;

process_local_iq(#iq{from = #jid{luser = UserId, lserver = _Server}, type = get,
        lang = _Lang, sub_els = [#avatar{userid = UserId}]} = IQ) ->
        xmpp:make_iq_result(IQ, #avatar{id = model_accounts:get_avatar_id_binary(UserId)});

process_local_iq(#iq{from = #jid{luser = UserId, lserver = _Server}, type = get,
        lang = Lang, sub_els = [#avatar{userid = FriendId}]} = IQ) ->
        case check_and_get_avatar_id(UserId, FriendId) of
            undefined ->
                Txt = ?T("Invalid friend_uid"),
                ?WARNING_MSG("Uid: ~s, Invalid friend_uid: ~s", [UserId, FriendId]),
                xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
            AvatarId ->
                xmpp:make_iq_result(IQ, #avatar{userid = FriendId, id = AvatarId})
        end;

process_local_iq(#iq{from = #jid{luser = UserId, lserver = _Server}, type = get,
        lang = _Lang, sub_els = [#avatars{} = Avatars]} = IQ) ->
        NewAvatars = lists:foreach(
                fun(#avatar{userid = FriendId} = Avatar) ->
                    Avatar#avatar{id = check_and_get_avatar_id(UserId, FriendId)}
                end, Avatars),
        xmpp:make_iq_result(IQ, NewAvatars).


remove_user(UserId, Server) ->
    delete_user_avatar(UserId, Server).


%%====================================================================
%% internal functions
%%====================================================================

-spec check_and_get_avatar_id(UserId :: binary(), FriendId :: binary()) -> undefined | binary().
check_and_get_avatar_id(UserId, UserId) ->
    model_accounts:get_avatar_id_binary(UserId);
check_and_get_avatar_id(UserId, FriendId) ->
    case model_friends:is_friend(UserId, FriendId) of
        false ->
            undefined;
        true ->
            model_accounts:get_avatar_id_binary(UserId)
    end.


-spec publish_user_avatar(UserId :: binary(), Server :: binary(),
        Data :: binary()) -> avatar_id().
publish_user_avatar(UserId, Server, <<>>) ->
    delete_user_avatar(UserId, Server);
publish_user_avatar(UserId, Server, BinaryData) ->
    AvatarId = util:new_avatar_id(),
    case upload_user_avatar(AvatarId, BinaryData) of
        ok ->
            update_user_avatar(UserId, Server, AvatarId),
            AvatarId;
        error ->
            error
    end.


-spec delete_user_avatar(UserId :: binary(), Server :: binary()) -> ok.
delete_user_avatar(UserId, Server) ->
    case model_accounts:get_avatar_id_binary(UserId) of
        <<>> ->
            ok;
        OldAvatarId ->
            try
                Result = erlcloud_s3:delete_object(
                        binary_to_list(?AWS_BUCKET_NAME), binary_to_list(OldAvatarId)),
                ?INFO_MSG("Uid: ~s, Result: ~p", [UserId, Result])
            catch ?EX_RULE(Class, Reason, St) ->
                StackTrace = ?EX_STACK(St),
                ?ERROR_MSG("Uid: ~s, Error deleting object on s3: response:~n~ts",
                       [UserId, misc:format_exception(2, Class, Reason, StackTrace)])
            end
    end,
    AvatarId = <<>>,
    update_user_avatar(UserId, Server, AvatarId),
    AvatarId.


-spec update_user_avatar(UserId :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
update_user_avatar(UserId, Server, AvatarId) ->
    model_accounts:set_avatar_id(UserId, AvatarId),
    ejabberd_hooks:run(user_avatar_published, Server, [UserId, Server, AvatarId]).


-spec user_avatar_published(UserId :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(UserId, Server, AvatarId) ->
    {ok, Friends} = model_friends:get_friends(UserId),
    lists:foreach(
        fun(FriendId) ->
            Message = #message{id = util:new_msg_id(), to = jid:make(FriendId, Server),
                    from = jid:make(Server), sub_els = [#avatar{userid = UserId, id = AvatarId}]},
            ejabberd_router:route(Message)
        end, Friends).


% TODO: maybe we should rename mod_user_avatar to mod_avatar since it now has group functions
% TODO: both funcitons are the same now...
-spec upload_group_avatar(AvatarId :: binary(), BinaryData :: binary()) -> ok | error.
upload_group_avatar(AvatarId, BinaryData) ->
    upload_avatar(?AWS_BUCKET_NAME, AvatarId, BinaryData).


-spec upload_user_avatar(AvatarId :: binary(), BinaryData :: binary()) -> ok | error.
upload_user_avatar(AvatarId, BinaryData) ->
    upload_avatar(?AWS_BUCKET_NAME, AvatarId, BinaryData).


-spec upload_avatar(BucketName :: binary(), AvatarId :: binary(), BinaryData :: binary())
        -> ok | error.
upload_avatar(BucketName, AvatarId, BinaryData) ->
    Headers = [{"content-type", "image/jpeg"}],
    try
        Result = erlcloud_s3:put_object(binary_to_list(
                BucketName), binary_to_list(AvatarId), BinaryData, [], Headers),
        ?INFO_MSG("AvatarId: ~s, Result: ~p", [AvatarId, Result]),
        ok
    catch ?EX_RULE(Class, Reason, St) ->
        StackTrace = ?EX_STACK(St),
        ?ERROR_MSG("AvatarId: ~s, Error uploading object on s3: response:~n~ts",
               [AvatarId, misc:format_exception(2, Class, Reason, StackTrace)]),
        error
    end.


-spec is_jpeg(BinaryData :: binary()) -> boolean().
is_jpeg(<<255, 216, _/binary>>) ->
    true;
is_jpeg(_) ->
    false.



