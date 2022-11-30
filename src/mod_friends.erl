%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_friends).
-author("josh").

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").

%% exported for tests only
-ifdef(TEST).
-export([
    get_user_info_from_uid/2
]).
-endif.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1,
    remove_user/2
]).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_action, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_list, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, ?KATCHUP, ?MODULE, remove_user, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_action),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_list),
    ejabberd_hooks:delete(remove_user, ?KATCHUP, ?MODULE, remove_user, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handlers
%%====================================================================

%% get RelationshipList (type = normal)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = normal} = RelationshipList} = IQ) ->
    {ok, FriendUids} = model_friends:get_friends(Uid),
    UserInfos = get_user_info_from_uid(FriendUids, normal),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{users = UserInfos});


%% get RelationshipList (type = incoming)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = incoming} = RelationshipList} = IQ) ->
    IncomingFriendUids = model_friends:get_incoming_friends(Uid),
    UserInfos = get_user_info_from_uid(IncomingFriendUids, incoming),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{users = UserInfos});


%% get RelationshipList (type = outgoing)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = outgoing} = RelationshipList} = IQ) ->
    OutgoingFriendUids = model_friends:get_outgoing_friends(Uid),
    UserInfos = get_user_info_from_uid(OutgoingFriendUids, outgoing),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{users = UserInfos});


%% get RelationshipList (type = blocked)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = blocked} = RelationshipList} = IQ) ->
    BlockedUids = model_friends:get_blocked_uids(Uid),
    UserInfos = get_user_info_from_uid(BlockedUids, blocked),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{users = UserInfos});


%% get RelationshipList error: unknown type
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = Type}} = IQ) ->
    ?ERROR("Received IQ from ~s for unknown RelationshipList type: ~s", [Uid, Type]),
    pb:make_error(IQ, util:err(invalid_type));


%% RelationshipAction (action = add)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_action{action = add, uid = Ouid} = RelationshipAction} = IQ) ->
    Ret = case model_friends:is_incoming(Uid, Ouid) orelse model_friends:is_ignored(Uid, Ouid) of
        true ->
            %% accepting an incoming friend request
            case model_friends:is_blocked_any(Uid, Ouid) of
                false ->
                    model_friends:add_friend(Uid, Ouid),
                    {OUserInfo, friends} = get_user_info_from_uid(Ouid, friends),
                    ok = notify_friendship_change(Uid, Ouid, add, friends),
                    ejabberd_hooks:run(add_friend, ?KATCHUP, [Uid, util:get_host(), Ouid, false]),
                    ?INFO("~s added ~s, end result: friends", [Uid, Ouid]),
                    RelationshipAction#pb_relationship_action{
                        status = friends,
                        user_info = OUserInfo
                    };
                true ->
                    ?INFO("~s added ~s, end result: none (someone was blocked)"),
                    RelationshipAction#pb_relationship_action{
                        status = none
                    }
            end;
        false ->
            %% sending an outgoing friend request
            case model_friends:is_blocked_any(Uid, Ouid) of
                false ->
                    model_friends:add_outgoing_friend(Uid, Ouid),
                    ok = notify_friendship_change(Uid, Ouid, add, incoming),
                    ?INFO("~s added ~s, end result: outgoing", [Uid, Ouid]);
                true ->
                    ?INFO("~s added ~s, end result: none (someone was blocked)", [Uid, Ouid])
            end,
            RelationshipAction#pb_relationship_action{status = outgoing}
    end,
    pb:make_iq_result(IQ, Ret);

%% RelationshipAction (action = remove)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_action{action = remove, uid = Ouid} = RelationshipAction} = IQ) ->
    Ret = case model_friends:is_friend(Uid, Ouid) of
        true ->
            %% remove existing friend
            ok = model_friends:remove_friend(Uid, Ouid),
            ok = notify_friendship_change(Uid, Ouid, remove, none),
            ejabberd_hooks:run(remove_friend, ?KATCHUP, [Uid, util:get_host(), Ouid]),
            ?INFO("~s removed ~s, end result: none", [Uid, Ouid]),
            RelationshipAction#pb_relationship_action{status = none};
        false ->
            case model_friends:is_outgoing(Uid, Ouid) of
                true ->
                    %% rescind outgoing friend request
                    ok = model_friends:remove_outgoing_friend(Uid, Ouid),
                    case model_friends:is_blocked_by(Uid, Ouid) of
                        true -> ok;
                        false ->
                            Msg = #pb_relationship_action{
                                action = remove,
                                uid = Uid,
                                status = none
                            },
                            send_msg(Uid, Ouid, Msg)
                    end,
                    ?INFO("~s removed ~s, end result: none", [Uid, Ouid]);
                false ->
                    %% ignore (reject) incoming friend request
                    ok = model_friends:ignore_incoming_friend(Uid, Ouid),
                    ?INFO("~s removed ~s, end result: none (ignored)", [Uid, Ouid])
            end,
            RelationshipAction#pb_relationship_action{status = none}
    end,
    pb:make_iq_result(IQ, Ret);


%% RelationshipAction (action = block)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_action{action = block, uid = Ouid} = RelationshipAction} = IQ) ->
    %% model_friends:block will remove friend/incoming/outgoing relationship from each user
    ok = model_friends:block(Uid, Ouid),
    ejabberd_hooks:run(block_uids, ?KATCHUP, [Uid, util:get_host(), [Ouid]]),
    Ret = RelationshipAction#pb_relationship_action{status = none},
    ?INFO("~s blocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret);


%% RelationshipAction (action = unblock)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_action{action = unblock, uid = Ouid} = RelationshipAction} = IQ) ->
    ok = model_friends:unblock(Uid, Ouid),
    ejabberd_hooks:run(unblock_uids, ?KATCHUP, [Uid, util:get_host(), [Ouid]]),
    Ret = RelationshipAction#pb_relationship_action{status = none},
    ?INFO("~s unblocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret).

%%====================================================================
%% API
%%====================================================================

remove_user(Uid, _Server) ->
    %% Remove all friends
    {ok, FriendUids} = model_friends:get_friends(Uid),
    lists:foreach(
        fun(FriendUid) ->
            Payload = #pb_relationship_action{
                action = remove,
                uid = Uid,
                status = none
            },
            send_msg(Uid, FriendUid, Payload)
        end,
        FriendUids),
    model_friends:remove_all_friends(Uid),
    %% Remove all outgoing/incoming friend requests
    model_friends:remove_all_outgoing_friends(Uid),
    model_friends:remove_all_incoming_friends(Uid),
    %% Remove all block/blocked by relationships
    model_friends:remove_all_blocked_uids(Uid),
    model_friends:remove_all_blocked_by_uids(Uid),
    ?INFO("Removed all friends, incoming/outgoing, blocked/blocked by lists for ~s", [Uid]),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

notify_friendship_change(Uid, Ouid, Action, Status) when Status =:= incoming orelse Status =:= friends ->
    %% Notify Ouid that Uid has changed the status of the friendship
    {UserInfo, Status} = get_user_info_from_uid(Uid, Status),
    RelationshipAction = #pb_relationship_action{
        action = Action,
        uid = Uid,
        status = Status,
        user_info = UserInfo
    },
    send_msg(Uid, Ouid, RelationshipAction);

notify_friendship_change(Uid, Ouid, Action, Status) ->
    %% Notify Ouid that Uid has changed the status of the friendship
    RelationshipAction = #pb_relationship_action{
        action = Action,
        uid = Uid,
        status = Status
    },
    send_msg(Uid, Ouid, RelationshipAction).


send_msg(From, To, Payload) ->
    Msg = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = To,
        from_uid = From,
        payload = Payload
    },
    ejabberd_router:route(Msg).


get_user_info_from_uid(Uids, Status) when is_list(Uids) ->
    {Result, Status} = lists:mapfoldl(fun get_user_info_from_uid/2, Status, Uids),
    Result;

get_user_info_from_uid(Uid, Status) ->
    %% TODO: should have a fun in model_accounts to fetch these all at once
    Username = todo,
    {ok, Name} = model_accounts:get_name(Uid),
    AvatarId = case Status of
        blocked -> <<>>;
        _ -> model_accounts:get_avatar_id_binary(Uid)
    end,
    UserInfo = #pb_user_info{
        uid = Uid,
        username = Username,
        name = Name,
        avatar_id = AvatarId,
        status = Status
    },
    {UserInfo, Status}.
