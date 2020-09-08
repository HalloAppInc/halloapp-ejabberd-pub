%%%----------------------------------------------------------------------
%%% File    : push_util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions related to push notifications.
%%%----------------------------------------------------------------------

-module(push_util).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    parse_metadata/1
]).


-spec parse_metadata(Message :: message()) -> {binary(), binary(), binary()}.
parse_metadata(#message{id = Id, sub_els = [SubElement],
        from = #jid{luser = FromUid}}) when is_record(SubElement, chat) ->
    {Id, <<"chat">>, FromUid};
parse_metadata(#message{id = Id, sub_els = [SubElement],
        from = #jid{luser = FromUid}}) when is_record(SubElement, group_chat) ->
    {Id, <<"group_chat">>, FromUid};
parse_metadata(#message{id = Id, sub_els = [SubElement]})
        when is_record(SubElement, contact_list) ->
    {Id, <<"contact_notification">>, <<>>};
parse_metadata(#message{sub_els = [#ps_event{items = #ps_items{
        items = [#ps_item{id = Id, publisher = FromId, type = ItemType}]}}]}) ->
%% TODO(murali@): Change the fromId to be just userid instead of jid.
    #jid{luser = FromUid} = jid:from_string(FromId),
    {Id, util:to_binary(ItemType), FromUid};
parse_metadata(#message{sub_els = [#feed_st{posts = [Post]}]}) ->
    {Post#post_st.id, <<"post">>, Post#post_st.uid};
parse_metadata(#message{sub_els = [#feed_st{comments = [Comment]}]}) ->
    {Comment#comment_st.id, <<"comment">>, Comment#comment_st.publisher_uid};
parse_metadata(#message{to = #jid{luser = Uid}, id = Id}) ->
    ?ERROR_MSG("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]),
    {<<>>, <<>>, <<>>}.

