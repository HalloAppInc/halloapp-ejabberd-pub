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
    check_and_upload_avatar/1,
    delete_avatar_s3/1
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

%%% delete_user_avatar %%%
process_local_iq(#iq{from = #jid{luser = UserId}, type = set,
        sub_els = [#avatar{cdata = <<>>}]} = IQ) ->
    delete_user_avatar(IQ, UserId);

%%% set_user_avatar %%%
process_local_iq(#iq{from = #jid{luser = UserId}, type = set,
        sub_els = [#avatar{cdata = Data}]} = IQ) ->
    set_user_avatar(IQ, UserId, Data);

%%% get_avatar (own) %%%
process_local_iq(#iq{from = #jid{luser = UserId, lserver = _Server}, type = get,
        lang = _Lang, sub_els = [#avatar{userid = UserId}]} = IQ) ->
    % TODO: unify this code with the one below
    xmpp:make_iq_result(IQ, #avatar{id = model_accounts:get_avatar_id_binary(UserId)});

%%% get_avatar (friend) %%%
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

%%% get_avatars %%%
process_local_iq(#iq{from = #jid{luser = UserId, lserver = _Server}, type = get,
        lang = _Lang, sub_els = [#avatars{} = Avatars]} = IQ) ->
    NewAvatars = lists:foreach(
            fun(#avatar{userid = FriendId} = Avatar) ->
                Avatar#avatar{id = check_and_get_avatar_id(UserId, FriendId)}
            end, Avatars),
    xmpp:make_iq_result(IQ, NewAvatars).


remove_user(UserId, Server) ->
    delete_user_avatar_internal(UserId, Server).


-spec check_and_upload_avatar(Base64Data :: binary()) -> ok.
check_and_upload_avatar(Base64Data) ->
    case decode_base_64(Base64Data) of
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


delete_user_avatar(IQ, Uid) ->
    ?INFO_MSG("Uid: ~s deleting avatar", [Uid]),
    delete_user_avatar_internal(Uid, util:get_host()),
    xmpp:make_iq_result(IQ, #avatar{id = <<>>}).


set_user_avatar(IQ, Uid, Base64Data) ->
    ?INFO_MSG("Uid: ~s uploading avatar base64_size: ~p", [Uid, byte_size(Base64Data)]),
    case check_and_upload_avatar(Base64Data) of
        {error, Reason} ->
            xmpp:make_error(IQ, err(Reason));
        {ok, AvatarId} ->
            ?INFO_MSG("Uid: ~s AvatarId: ~s", [Uid, AvatarId]),
            update_user_avatar(Uid, util:get_host(), AvatarId),
            xmpp:make_iq_result(IQ, #avatar{id = AvatarId})
    end,
    ok.


% TODO: move this function to util
-spec decode_base_64(Base64Data :: binary()) -> {ok, binary()} | {error, bad_data}.
decode_base_64(Base64Data) ->
    try
        {ok, base64:decode(Base64Data)}
    catch
        error:badarg -> {error, bad_data}
    end.


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


-spec delete_user_avatar_internal(UserId :: binary(), Server :: binary()) -> ok.
delete_user_avatar_internal(UserId, Server) ->
    delete_user_old_avatar(UserId),
    update_user_avatar(UserId, Server, <<>>),
    ok.


-spec delete_user_old_avatar(UserId :: binary()) -> ok | error.
delete_user_old_avatar(UserId) ->
    case model_accounts:get_avatar_id_binary(UserId) of
        <<>> ->
            ok;
        OldAvatarId ->
            delete_avatar_s3(OldAvatarId)
    end.


-spec delete_avatar_s3(AvatarId :: binary()) -> ok | error.
delete_avatar_s3(AvatarId) ->
    try
        Result = erlcloud_s3:delete_object(
            binary_to_list(?AWS_BUCKET_NAME), binary_to_list(AvatarId)),
        ?INFO_MSG("AvatarId: ~s, Result: ~p", [AvatarId, Result]),
        ok
    catch Class:Reason:St ->
        ?ERROR_MSG("AvatarId: ~s failed to delete object on s3: Stacktrace: ~p",
            [AvatarId, lager:pr_stacktrace(St, {Class, Reason})]),
        error
    end.


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


-spec upload_avatar(BinaryData :: binary()) -> {ok, avatar()} | error.
upload_avatar(BinaryData) ->
    AvatarId = util:new_avatar_id(),
    case upload_avatar(?AWS_BUCKET_NAME, AvatarId, BinaryData) of
        ok -> {ok, AvatarId};
        error -> error
    end.


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

% TODO: (Nikola) duplicated code with mod_groups_api. Move this to some util.
-spec err(Reason :: atom()) -> stanza_error().
err(Reason) ->
    #stanza_error{reason = Reason}.

