%%%----------------------------------------------------------------------
%%% File    : notifications_util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module has the utility functions related to sending notifications.
%%%----------------------------------------------------------------------

-module(notifications_util).
-author('vipin').
-include("logger.hrl").
-include("packets.hrl").

-include("ha_namespaces.hrl").

-export([
    send_contact_notification/6
]).


-spec send_contact_notification(UserId :: binary(), UserPhone :: binary(), ContactId :: binary(),
        Role :: atom(), MessageType :: atom(), ContactListType :: atom()) -> ok.
send_contact_notification(UserId, UserPhone, ContactId, Role, MessageType, ContactListType) ->
    Server = util:get_host(),
    AvatarId = case Role of
        none -> undefined;
        friends -> model_accounts:get_avatar_id_binary(UserId)
    end,
    Name = model_accounts:get_name_binary(UserId),
    Contact = #pb_contact{
        uid = UserId,
        name = Name,
        avatar_id = AvatarId,
        normalized = UserPhone,
        role = Role
    },

    Payload = #pb_contact_list{type = ContactListType, contacts = [Contact]},
    Stanza = #pb_msg{
        id = util_id:new_msg_id(),
        type = MessageType,
        to_uid = ContactId,
        payload = Payload
    },
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).

