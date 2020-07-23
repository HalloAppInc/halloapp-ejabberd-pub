%%%----------------------------------------------------------------------
%%% File    : mod_offline_halloapp.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Add limit for max number of messages per user. 
%%%----------------------------------------------------------------------
%% TODO(murali@): rename this file later.
-module(mod_offline_halloapp).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("offline_message.hrl").
-include("ejabberd_sm.hrl").

-define(MESSAGE_RESPONSE_TIMEOUT_MILLISEC, 30000).  %% 30 seconds.

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API and hooks.
-export([
    offline_message_hook/1,
    user_receive_packet/1,
    user_send_ack/1,
    sm_register_connection_hook/3,
    user_session_activated/2,
    remove_user/2,
    count_user_messages/1
]).


%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, Opts) ->
    ?INFO_MSG("mod_offline_halloapp: start", []),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
    ?INFO_MSG("mod_offline_halloapp: stop", []),
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).



%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Host|_]) ->
    ?DEBUG("mod_offline_halloapp: init", []),
    process_flag(trap_exit, true),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message_hook, 10),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:add(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:add(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 100),
    ejabberd_hooks:add(user_session_activated, Host, ?MODULE, user_session_activated, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    {ok, #{host => Host}}.


terminate(_Reason, #{host := Host} = _State) ->
    ?DEBUG("mod_offline_halloapp: terminate", []),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message_hook, 10),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 10),
    ejabberd_hooks:delete(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:delete(sm_register_connection_hook, Host, ?MODULE, sm_register_connection_hook, 100),
    ejabberd_hooks:delete(user_session_activated, Host, ?MODULE, user_session_activated, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


code_change(_OldVsn, State, _Extra) ->
    ?DEBUG("mod_offline_halloapp: code_change", []),
    {ok, State}.


handle_call(Request, _From, State) ->
    ?DEBUG("invalid request: ~p", [Request]),
    {reply, {error, bad_arg}, State}.


handle_cast({setup_push_timer, Message}, State) ->
    util:send_after(?MESSAGE_RESPONSE_TIMEOUT_MILLISEC, {push_offline_message, Message}),
    {noreply, State};

handle_cast(Request, State) ->
    ?DEBUG("invalid request: ~p", [Request]),
    {noreply, State}.


handle_info({push_offline_message, Message}, #{host := _ServerHost} = State) ->
    MsgId = xmpp:get_id(Message),
    #jid{user = Uid} = xmpp:get_to(Message),
    case model_messages:get_message(Uid, MsgId) of
        {ok, undefined} ->
            ?INFO_MSG("Uid: ~s, message has been acked, Id: ~s", [Uid, MsgId]);
        _ ->
            ?INFO_MSG("Uid: ~s, no ack for message Id: ~s, trying a push", [Uid, MsgId]),
            ejabberd_sm:route_offline_message(Message)
    end,
    {noreply, State};

handle_info(Request, State) ->
    ?DEBUG("invalid request: ~p", [Request]),
    {noreply, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%      API and hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec user_send_ack(Packet :: ack()) -> ok.
user_send_ack(#ack{id = MsgId, from = #jid{user = UserId, server = Server}} = Ack) ->
    {ok, OfflineMessage} = model_messages:get_message(UserId, MsgId),
    case OfflineMessage of
        undefined ->
            ?WARNING_MSG("missing a message on redis, msg_id: ~s, from_uid: ~s", [MsgId, UserId]);
        _ ->
            ok = model_messages:ack_message(UserId, MsgId),
            case OfflineMessage#offline_message.content_type of
                <<"chat">> ->
                    ejabberd_hooks:run(user_ack_packet, Server, [{Ack, OfflineMessage}]);
                <<"group_chat">> ->
                    % TODO: change this code to fire always
                    ejabberd_hooks:run(user_ack_packet, Server, [{Ack, OfflineMessage}]);
                _ -> ok
            end
    end.


offline_message_hook({Action, #message{} = Message} = _Acc) ->
    NewMessage = adjust_id_and_store_message(Message),
    {Action, NewMessage}.


user_receive_packet({Packet, #{lserver := _ServerHost} = State} = _Acc)
        when is_record(Packet, message) ->
    NewMessage = adjust_id_and_store_message(Packet),
    setup_push_timer(NewMessage),
    {NewMessage, State};
user_receive_packet(Acc) ->
    Acc.


sm_register_connection_hook(SID, JID, Info) ->
    #jid{luser = LUser, lserver = LServer, lresource = LResource} = JID,
    US = {LUser, LServer},
    USR = {LUser, LServer, LResource},
    Session = #session{sid = SID, usr = USR, us = US, info = Info},
    case ejabberd_sm:is_active_session(Session) of
        true -> route_offline_messages(JID);
        false -> ok
    end.


user_session_activated(User, Server) ->
    JID = jid:make(User, Server),
    route_offline_messages(JID).


remove_user(User, _Server) ->
    ?INFO_MSG("removing all user messages, uid: ~s", [User]),
    model_messages:remove_all_user_messages(User).


-spec count_user_messages(UserId :: binary()) -> integer().
count_user_messages(User) ->
    {ok, Res} = model_messages:count_user_messages(User),
    Res.


%% TODO(murali@): Add logic to increment retry count.
-spec route_offline_messages(JID :: jid()) -> ok.
route_offline_messages(#jid{luser = UserId, lserver = _ServerHost}) ->
    {ok, OfflineMessages} = model_messages:get_all_user_messages(UserId),
    lists:foreach(fun route_offline_message/1, OfflineMessages).


-spec route_offline_message(OfflineMessage :: undefined | offline_message()) -> ok.
route_offline_message(undefined) ->
    ok;
route_offline_message(#offline_message{from_uid = FromUid, to_uid = ToUid, message = Message}) ->
    ?INFO_MSG("sending offline message from_uid: ~s to_uid: ~s", [FromUid, ToUid]),
    case fxml_stream:parse_element(Message) of
        {error, Reason} -> ?ERROR_MSG("failed to parse: ~p, reason: ~s", [Message, Reason]);
        MessageXmlEl ->
            try
                Packet = xmpp:decode(MessageXmlEl, ?NS_CLIENT, [ignore_els]),
                ejabberd_router:route(Packet)
            catch
                Class : Reason : Stacktrace ->
                    ?ERROR_MSG("failed routing: ~s", [
                            lager:pr_stacktrace(Stacktrace, {Class, Reason})])
            end
    end.


-spec adjust_id_and_store_message(message()) -> message().
adjust_id_and_store_message(Message) ->
    NewMessage = xmpp:set_id_if_missing(Message, util:new_msg_id()),
    ok = model_messages:store_message(NewMessage),
    NewMessage.


-spec setup_push_timer(Message :: message()) -> ok.
setup_push_timer(Message) ->
    gen_server:cast(get_proc(), {setup_push_timer, Message}).


