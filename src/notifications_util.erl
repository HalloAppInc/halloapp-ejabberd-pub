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
-include("xmpp.hrl").

-include("ha_namespaces.hrl").

-export([
    send_contact_notification/6
]).


-spec send_contact_notification(UserId :: binary(), UserPhone :: binary(), Server :: binary(),
        ContactId :: binary(), Role :: list(), MessageType :: atom()) -> ok.
send_contact_notification(UserId, UserPhone, Server, ContactId, Role, MessageType) -> 
    AvatarId = case Role of
        <<"none">> -> undefined;
        <<"friends">> -> model_accounts:get_avatar_id_binary(UserId)
    end,
    Name = model_accounts:get_name_binary(UserId),
    Contact = #contact{
        userid = UserId,
        name = Name,
        avatarid = AvatarId,
        normalized = UserPhone,
        role = Role
    },

    SubEls = [#contact_list{type = normal, xmlns = ?NS_USER_CONTACTS, contacts = [Contact]}],
    Stanza = #message{
        id = util:new_msg_id(),
        type = MessageType,
        from = jid:make(Server),
        to = jid:make(ContactId, Server),
        sub_els = SubEls
    },
    ?DEBUG("Notifying contact: ~p about user: ~p using stanza: ~p",
            [{ContactId, Server}, UserId, Stanza]),
    ejabberd_router:route(Stanza).

