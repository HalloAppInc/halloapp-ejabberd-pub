%%%----------------------------------------------------------------------
%%% File    : mod_muc_room.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : MUC room stuff
%%% Created : 19 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_muc_room).

-author('alexey@process-one.net').

-behaviour(gen_fsm).

%% External exports
-export([start_link/9,
	 start_link/7,
	 start/9,
	 start/7,
	 get_role/2,
	 get_affiliation/2,
	 is_occupant_or_admin/2,
	 route/4]).

%% gen_fsm callbacks
-export([init/1,
	 normal_state/2,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("xmpp.hrl").

-include("mod_muc_room.hrl").

-define(MAX_USERS_DEFAULT_LIST,
	[5, 10, 20, 30, 50, 100, 200, 500, 1000, 2000, 5000]).

-define(DEFAULT_MAX_USERS_PRESENCE,1000).

%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

-type state() :: #state{}.
-type fsm_stop() :: {stop, normal, state()}.
-type fsm_next() :: {next_state, normal_state, state()}.
-type fsm_transition() :: fsm_stop() | fsm_next().
-type history_element() :: {binary(), %% nick
			    message(), %% message itself
			    boolean(), %% have subject
			    erlang:timestamp(),
			    non_neg_integer()}.

-export_type([state/0]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Host, ServerHost, Access, Room, HistorySize, RoomShaper,
      Creator, Nick, DefRoomOpts) ->
    gen_fsm:start(?MODULE, [Host, ServerHost, Access, Room, HistorySize,
			    RoomShaper, Creator, Nick, DefRoomOpts],
		    ?FSMOPTS).

start(Host, ServerHost, Access, Room, HistorySize, RoomShaper, Opts) ->
    gen_fsm:start(?MODULE, [Host, ServerHost, Access, Room, HistorySize,
			    RoomShaper, Opts],
		    ?FSMOPTS).

start_link(Host, ServerHost, Access, Room, HistorySize, RoomShaper,
	   Creator, Nick, DefRoomOpts) ->
    gen_fsm:start_link(?MODULE, [Host, ServerHost, Access, Room, HistorySize,
				 RoomShaper, Creator, Nick, DefRoomOpts],
		       ?FSMOPTS).

start_link(Host, ServerHost, Access, Room, HistorySize, RoomShaper, Opts) ->
    gen_fsm:start_link(?MODULE, [Host, ServerHost, Access, Room, HistorySize,
				 RoomShaper, Opts],
		       ?FSMOPTS).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

init([Host, ServerHost, Access, Room, HistorySize,
      RoomShaper, Creator, _Nick, DefRoomOpts]) ->
    process_flag(trap_exit, true),
    Shaper = shaper:new(RoomShaper),
    State = set_affiliation(Creator, owner,
	    #state{host = Host, server_host = ServerHost,
		   access = Access, room = Room,
		   history = lqueue_new(HistorySize),
		   jid = jid:make(Room, Host, <<"">>),
		   just_created = true,
		   room_shaper = Shaper}),
    State1 = set_opts(DefRoomOpts, State),
    store_room(State1),
    ?INFO_MSG("Created MUC room ~s@~s by ~s",
	      [Room, Host, jid:to_string(Creator)]),
    add_to_log(room_existence, created, State1),
    add_to_log(room_existence, started, State1),
    {ok, normal_state, State1};
init([Host, ServerHost, Access, Room, HistorySize, RoomShaper, Opts]) ->
    process_flag(trap_exit, true),
    Shaper = shaper:new(RoomShaper),
    State = set_opts(Opts, #state{host = Host,
				  server_host = ServerHost,
				  access = Access,
				  room = Room,
				  history = lqueue_new(HistorySize),
				  jid = jid:make(Room, Host, <<"">>),
				  room_shaper = Shaper}),
    add_to_log(room_existence, started, State),
    {ok, normal_state, State}.

normal_state({route, From, <<"">>,
	      #message{type = Type, lang = Lang} = Packet}, StateData) ->
    case is_user_online(From, StateData) orelse
	is_user_allowed_message_nonparticipant(From, StateData) of
	true when Type == groupchat ->
	    Activity = get_user_activity(From, StateData),
	    Now = p1_time_compat:system_time(micro_seconds),
	    MinMessageInterval = trunc(gen_mod:get_module_opt(
					 StateData#state.server_host,
					 mod_muc, min_message_interval,
					 fun(MMI) when is_number(MMI) -> MMI end, 0)
				       * 1000000),
	    Size = element_size(Packet),
	    {MessageShaper, MessageShaperInterval} =
		shaper:update(Activity#activity.message_shaper, Size),
	    if Activity#activity.message /= undefined ->
		    ErrText = <<"Traffic rate limit is exceeded">>,
		    Err = xmpp:make_error(
			    Packet,
			    xmpp:err_resource_constraint(ErrText, Lang)),
		    ejabberd_router:route(StateData#state.jid, From, Err),
		    {next_state, normal_state, StateData};
	       Now >= Activity#activity.message_time + MinMessageInterval,
	       MessageShaperInterval == 0 ->
		    {RoomShaper, RoomShaperInterval} =
			shaper:update(StateData#state.room_shaper, Size),
		    RoomQueueEmpty = queue:is_empty(StateData#state.room_queue),
		    if RoomShaperInterval == 0, RoomQueueEmpty ->
			    NewActivity = Activity#activity{
					    message_time = Now,
					    message_shaper = MessageShaper},
			    StateData1 = store_user_activity(From,
							     NewActivity,
							     StateData),
			    StateData2 = StateData1#state{room_shaper =
							      RoomShaper},
			    process_groupchat_message(From, Packet,
						      StateData2);
		       true ->
			    StateData1 = if RoomQueueEmpty ->
						 erlang:send_after(RoomShaperInterval,
								   self(),
								   process_room_queue),
						 StateData#state{room_shaper =
								     RoomShaper};
					    true -> StateData
					 end,
			    NewActivity = Activity#activity{
					    message_time = Now,
					    message_shaper = MessageShaper,
					    message = Packet},
			    RoomQueue = queue:in({message, From},
						 StateData#state.room_queue),
			    StateData2 = store_user_activity(From,
							     NewActivity,
							     StateData1),
			    StateData3 = StateData2#state{room_queue = RoomQueue},
			    {next_state, normal_state, StateData3}
		    end;
	       true ->
		    MessageInterval = (Activity#activity.message_time +
					   MinMessageInterval - Now) div 1000,
		    Interval = lists:max([MessageInterval,
					  MessageShaperInterval]),
		    erlang:send_after(Interval, self(),
				      {process_user_message, From}),
		    NewActivity = Activity#activity{
				    message = Packet,
				    message_shaper = MessageShaper},
		    StateData1 = store_user_activity(From, NewActivity,	StateData),
		    {next_state, normal_state, StateData1}
	    end;
	true when Type == error ->
	    case is_user_online(From, StateData) of
		true ->
		    ErrorText = <<"It is not allowed to send error messages to the"
				  " room. The participant (~s) has sent an error "
				  "message (~s) and got kicked from the room">>,
		    NewState = expulse_participant(Packet, From, StateData,
						   translate:translate(Lang,
								       ErrorText)),
		    close_room_if_temporary_and_empty(NewState);
		_ ->
		    {next_state, normal_state, StateData}
	    end;
	true when Type == chat ->
	    ErrText = <<"It is not allowed to send private messages "
			"to the conference">>,
	    Err = xmpp:err_not_acceptable(ErrText, Lang),
	    ejabberd_router:route_error(StateData#state.jid, From, Packet, Err),
	    {next_state, normal_state, StateData};
	true when Type == normal ->
	    {next_state, normal_state,
	     try xmpp:decode_els(Packet) of
		 Pkt -> process_normal_message(From, Pkt, StateData)
	     catch _:{xmpp_codec, Why} ->
		     Txt = xmpp:format_error(Why),
		     Err = xmpp:err_bad_request(Txt, Lang),
		     ejabberd_router:route_error(
		       StateData#state.jid, From, Packet, Err),
		     StateData
	     end};
	true ->
	    ErrText = <<"Improper message type">>,
	    Err = xmpp:err_not_acceptable(ErrText, Lang),
	    ejabberd_router:route_error(StateData#state.jid, From, Packet, Err),
	    {next_state, normal_state, StateData};
	false when Type /= error ->
	    handle_roommessage_from_nonparticipant(Packet, StateData, From);
	false ->
	    {next_state, normal_state, StateData}
    end;
normal_state({route, From, <<"">>,
	      #iq{type = Type, lang = Lang, sub_els = [_]} = IQ0},
	     StateData) when Type == get; Type == set ->
    try
	case ejabberd_hooks:run_fold(
	       muc_process_iq,
	       StateData#state.server_host,
	       xmpp:set_from_to(xmpp:decode_els(IQ0),
				From, StateData#state.jid),
	       [StateData]) of
	    ignore ->
		{next_state, normal_state, StateData};
	    #iq{type = T} = IQRes when T == error; T == result ->
		ejabberd_router:route(StateData#state.jid, From, IQRes),
		{next_state, normal_state, StateData};
	    #iq{sub_els = [SubEl]} = IQ ->
		Res1 = case xmpp:get_ns(SubEl) of
			   ?NS_MUC_ADMIN ->
			       process_iq_admin(From, IQ, StateData);
			   ?NS_MUC_OWNER ->
			       process_iq_owner(From, IQ, StateData);
			   ?NS_DISCO_INFO when SubEl#disco_info.node == undefined ->
			       process_iq_disco_info(From, IQ, StateData);
			   ?NS_DISCO_INFO ->
			       Txt = <<"Disco info is not available for this node">>,
			       {error, xmpp:err_service_unavailable(Txt, Lang)};
			   ?NS_DISCO_ITEMS ->
			       process_iq_disco_items(From, IQ, StateData);
			   ?NS_VCARD ->
			       process_iq_vcard(From, IQ, StateData);
			   ?NS_MUCSUB ->
			       process_iq_mucsub(From, IQ, StateData);
			   ?NS_CAPTCHA ->
			       process_iq_captcha(From, IQ, StateData);
			   _ ->
			       {error, xmpp:err_feature_not_implemented()}
		       end,
		{IQRes, NewStateData} =
		    case Res1 of
			{result, Res, SD} ->
			    {xmpp:make_iq_result(IQ, Res), SD};
			{result, Res} ->
			    {xmpp:make_iq_result(IQ, Res), StateData};
			{ignore, SD} ->
			    {ignore, SD};
			{error, Error, ResStateData} ->
			    {xmpp:make_error(IQ0, Error), ResStateData};
			{error, Error} ->
			    {xmpp:make_error(IQ0, Error), StateData}
		    end,
		if IQRes /= ignore ->
			ejabberd_router:route(StateData#state.jid, From, IQRes);
		   true ->
			ok
		end,
		case NewStateData of
		    stop -> {stop, normal, StateData};
		    _ -> {next_state, normal_state, NewStateData}
		end
	end
    catch _:{xmpp_codec, Why} ->
	    ErrTxt = xmpp:format_error(Why),
	    Err = xmpp:make_error(IQ0, xmpp:err_bad_request(ErrTxt, Lang)),
	    ejabberd_router:route(StateData#state.jid, From, Err)
    end;
normal_state({route, From, <<"">>, #iq{} = IQ}, StateData) ->
    Err = xmpp:err_bad_request(),
    ejabberd_router:route_error(StateData#state.jid, From, IQ, Err),
    {next_state, normal_state, StateData};
normal_state({route, From, Nick, #presence{} = Packet}, StateData) ->
    Activity = get_user_activity(From, StateData),
    Now = p1_time_compat:system_time(micro_seconds),
    MinPresenceInterval =
	trunc(gen_mod:get_module_opt(StateData#state.server_host,
				     mod_muc, min_presence_interval,
                                     fun(I) when is_number(I), I>=0 ->
                                             I
                                     end, 0)
              * 1000000),
    if (Now >= Activity#activity.presence_time + MinPresenceInterval)
       and (Activity#activity.presence == undefined) ->
	    NewActivity = Activity#activity{presence_time = Now},
	    StateData1 = store_user_activity(From, NewActivity,
					     StateData),
	    process_presence(From, Nick, Packet, StateData1);
       true ->
	    if Activity#activity.presence == undefined ->
		    Interval = (Activity#activity.presence_time +
				    MinPresenceInterval - Now) div 1000,
		    erlang:send_after(Interval, self(),
				      {process_user_presence, From});
	       true -> ok
	    end,
	    NewActivity = Activity#activity{presence = {Nick, Packet}},
	    StateData1 = store_user_activity(From, NewActivity,
					     StateData),
	    {next_state, normal_state, StateData1}
    end;
normal_state({route, From, ToNick,
	      #message{type = Type, lang = Lang} = Packet},
	     StateData) ->
    case decide_fate_message(Packet, From, StateData) of
	{expulse_sender, Reason} ->
	    ?DEBUG(Reason, []),
	    ErrorText = <<"It is not allowed to send error messages to the"
			  " room. The participant (~s) has sent an error "
			  "message (~s) and got kicked from the room">>,
	    NewState = expulse_participant(Packet, From, StateData,
					   translate:translate(Lang, ErrorText)),
	    {next_state, normal_state, NewState};
	forget_message ->
	    {next_state, normal_state, StateData};
	continue_delivery ->
	    case {(StateData#state.config)#config.allow_private_messages,
		  is_user_online(From, StateData)} of
		{true, true} when Type == groupchat ->
		    ErrText = <<"It is not allowed to send private messages "
				"of type \"groupchat\"">>,
		    Err = xmpp:err_bad_request(ErrText, Lang),
		    ejabberd_router:route_error(
		      jid:replace_resource(StateData#state.jid, ToNick),
		      From, Packet, Err);
		{true, true} ->
		    case find_jids_by_nick(ToNick, StateData) of
			[] ->
			    ErrText = <<"Recipient is not in the conference room">>,
			    Err = xmpp:err_item_not_found(ErrText, Lang),
			    ejabberd_router:route_error(
			      jid:replace_resource(StateData#state.jid, ToNick),
			      From, Packet, Err);
			ToJIDs ->
			    SrcIsVisitor = is_visitor(From, StateData),
			    DstIsModerator = is_moderator(hd(ToJIDs), StateData),
			    PmFromVisitors =
				(StateData#state.config)#config.allow_private_messages_from_visitors,
			    if SrcIsVisitor == false;
			       PmFromVisitors == anyone;
			       (PmFromVisitors == moderators) and
			       DstIsModerator ->
				    {ok, #user{nick = FromNick}} =
					(?DICT):find(jid:tolower(From),
						     StateData#state.users),
				    FromNickJID =
					jid:replace_resource(StateData#state.jid,
							     FromNick),
				    X = #muc_user{},
				    PrivMsg = xmpp:set_subtag(Packet, X),
				    [ejabberd_router:route(FromNickJID, ToJID, PrivMsg)
				     || ToJID <- ToJIDs];
			       true ->
				    ErrText = <<"It is not allowed to send private messages">>,
				    Err = xmpp:err_forbidden(ErrText, Lang),
				    ejabberd_router:route_error(
				      jid:replace_resource(StateData#state.jid, ToNick),
				      From, Packet, Err)
			    end
		    end;
		{true, false} ->
		    ErrText = <<"Only occupants are allowed to send messages "
				"to the conference">>,
		    Err = xmpp:err_not_acceptable(ErrText, Lang),
		    ejabberd_router:route_error(
		      jid:replace_resource(StateData#state.jid, ToNick),
		      From, Packet, Err);
		{false, _} ->
		    ErrText = <<"It is not allowed to send private messages">>,
		    Err = xmpp:err_forbidden(ErrText, Lang),
		    ejabberd_router:route_error(
		      jid:replace_resource(StateData#state.jid, ToNick),
		      From, Packet, Err)
	    end,
	  {next_state, normal_state, StateData}
    end;
normal_state({route, From, ToNick,
	      #iq{id = StanzaId, lang = Lang} = Packet},
	     StateData) ->
    case {(StateData#state.config)#config.allow_query_users,
	  is_user_online_iq(StanzaId, From, StateData)} of
	{true, {true, NewId, FromFull}} ->
	    case find_jid_by_nick(ToNick, StateData) of
		false ->
		    ErrText = <<"Recipient is not in the conference room">>,
		    Err = xmpp:err_item_not_found(ErrText, Lang),
		    ejabberd_router:route_error(
		      jid:replace_resource(StateData#state.jid, ToNick),
		      From, Packet, Err);
		ToJID ->
		    {ok, #user{nick = FromNick}} =
			(?DICT):find(jid:tolower(FromFull), StateData#state.users),
		    {ToJID2, Packet2} = handle_iq_vcard(ToJID, NewId, Packet),
		    ejabberd_router:route(
		      jid:replace_resource(StateData#state.jid, FromNick),
		      ToJID2, Packet2)
	    end;
	{_, {false, _, _}} ->
	    ErrText = <<"Only occupants are allowed to send queries "
			"to the conference">>,
	    Err = xmpp:err_not_acceptable(ErrText, Lang),
	    ejabberd_router:route_error(
	      jid:replace_resource(StateData#state.jid, ToNick),
	      From, Packet, Err);
	_ ->
	    ErrText = <<"Queries to the conference members are "
			"not allowed in this room">>,
	    Err = xmpp:err_not_allowed(ErrText, Lang),
	    ejabberd_router:route_error(
	      jid:replace_resource(StateData#state.jid, ToNick),
	      From, Packet, Err)
    end,
    {next_state, normal_state, StateData};
normal_state(_Event, StateData) ->
    {next_state, normal_state, StateData}.

handle_event({service_message, Msg}, _StateName,
	     StateData) ->
    MessagePkt = #message{type = groupchat, body = xmpp:mk_text(Msg)},
    send_wrapped_multiple(
      StateData#state.jid,
      StateData#state.users,
      MessagePkt,
      ?NS_MUCSUB_NODES_MESSAGES,
      StateData),
    NSD = add_message_to_history(<<"">>,
				 StateData#state.jid, MessagePkt, StateData),
    {next_state, normal_state, NSD};
handle_event({destroy, Reason}, _StateName,
	     StateData) ->
    {result, undefined, stop} =
	destroy_room(#muc_destroy{xmlns = ?NS_MUC_OWNER, reason = Reason},
		     StateData),
    ?INFO_MSG("Destroyed MUC room ~s with reason: ~p",
	      [jid:to_string(StateData#state.jid), Reason]),
    add_to_log(room_existence, destroyed, StateData),
    {stop, shutdown, StateData};
handle_event(destroy, StateName, StateData) ->
    ?INFO_MSG("Destroyed MUC room ~s",
	      [jid:to_string(StateData#state.jid)]),
    handle_event({destroy, undefined}, StateName, StateData);
handle_event({set_affiliations, Affiliations},
	     StateName, StateData) ->
    {next_state, StateName,
     StateData#state{affiliations = Affiliations}};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event({get_disco_item, Filter, JID, Lang}, _From, StateName, StateData) ->
    Len = ?DICT:fold(fun(_, _, Acc) -> Acc + 1 end, 0,
                    StateData#state.users),
    Reply = case (Filter == all) or (Filter == Len) or ((Filter /= 0) and (Len /= 0)) of
	true ->
	    get_roomdesc_reply(JID, StateData,
			       get_roomdesc_tail(StateData, Lang));
	false ->
	    false
    end,
    {reply, Reply, StateName, StateData};
%% This clause is only for backwards compatibility
handle_sync_event({get_disco_item, JID, Lang}, From, StateName, StateData) ->
    handle_sync_event({get_disco_item, any, JID, Lang}, From, StateName, StateData);
handle_sync_event(get_config, _From, StateName,
		  StateData) ->
    {reply, {ok, StateData#state.config}, StateName,
     StateData};
handle_sync_event(get_state, _From, StateName,
		  StateData) ->
    {reply, {ok, StateData}, StateName, StateData};
handle_sync_event({change_config, Config}, _From,
		  StateName, StateData) ->
    {result, undefined, NSD} = change_config(Config, StateData),
    {reply, {ok, NSD#state.config}, StateName, NSD};
handle_sync_event({change_state, NewStateData}, _From,
		  StateName, _StateData) ->
    {reply, {ok, NewStateData}, StateName, NewStateData};
handle_sync_event({process_item_change, Item, UJID}, _From, StateName, StateData) ->
    NSD = process_item_change(Item, StateData, UJID),
    {reply, {ok, NSD}, StateName, NSD};
handle_sync_event(_Event, _From, StateName,
		  StateData) ->
    Reply = ok, {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

handle_info({process_user_presence, From}, normal_state = _StateName, StateData) ->
    RoomQueueEmpty = queue:is_empty(StateData#state.room_queue),
    RoomQueue = queue:in({presence, From}, StateData#state.room_queue),
    StateData1 = StateData#state{room_queue = RoomQueue},
    if RoomQueueEmpty ->
	   StateData2 = prepare_room_queue(StateData1),
	   {next_state, normal_state, StateData2};
       true -> {next_state, normal_state, StateData1}
    end;
handle_info({process_user_message, From},
	    normal_state = _StateName, StateData) ->
    RoomQueueEmpty =
	queue:is_empty(StateData#state.room_queue),
    RoomQueue = queue:in({message, From},
			 StateData#state.room_queue),
    StateData1 = StateData#state{room_queue = RoomQueue},
    if RoomQueueEmpty ->
	   StateData2 = prepare_room_queue(StateData1),
	   {next_state, normal_state, StateData2};
       true -> {next_state, normal_state, StateData1}
    end;
handle_info(process_room_queue,
	    normal_state = StateName, StateData) ->
    case queue:out(StateData#state.room_queue) of
      {{value, {message, From}}, RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  Packet = Activity#activity.message,
	  NewActivity = Activity#activity{message = undefined},
	  StateData1 = store_user_activity(From, NewActivity,
					   StateData),
	  StateData2 = StateData1#state{room_queue = RoomQueue},
	  StateData3 = prepare_room_queue(StateData2),
	  process_groupchat_message(From, Packet, StateData3);
      {{value, {presence, From}}, RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  {Nick, Packet} = Activity#activity.presence,
	  NewActivity = Activity#activity{presence = undefined},
	  StateData1 = store_user_activity(From, NewActivity,
					   StateData),
	  StateData2 = StateData1#state{room_queue = RoomQueue},
	  StateData3 = prepare_room_queue(StateData2),
	  process_presence(From, Nick, Packet, StateData3);
      {empty, _} -> {next_state, StateName, StateData}
    end;
handle_info({captcha_succeed, From}, normal_state,
	    StateData) ->
    NewState = case (?DICT):find(From,
				 StateData#state.robots)
		   of
		 {ok, {Nick, Packet}} ->
		     Robots = (?DICT):store(From, passed,
					    StateData#state.robots),
		     add_new_user(From, Nick, Packet,
				  StateData#state{robots = Robots});
		 _ -> StateData
	       end,
    {next_state, normal_state, NewState};
handle_info({captcha_failed, From}, normal_state,
	    StateData) ->
    NewState = case (?DICT):find(From,
				 StateData#state.robots)
		   of
		 {ok, {Nick, Packet}} ->
		     Robots = (?DICT):erase(From, StateData#state.robots),
		     Txt = <<"The CAPTCHA verification has failed">>,
		     Lang = xmpp:get_lang(Packet),
		     Err = xmpp:err_not_authorized(Txt, Lang),
		     ejabberd_router:route_error(
		       jid:replace_resource(StateData#state.jid, Nick),
		       From, Packet, Err),
		     StateData#state{robots = Robots};
		 _ -> StateData
	       end,
    {next_state, normal_state, NewState};
handle_info(shutdown, _StateName, StateData) ->
    {stop, shutdown, StateData};
handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.

terminate(Reason, _StateName, StateData) ->
    ?INFO_MSG("Stopping MUC room ~s@~s",
	      [StateData#state.room, StateData#state.host]),
    ReasonT = case Reason of
		shutdown ->
		    <<"You are being removed from the room "
		      "because of a system shutdown">>;
		_ -> <<"Room terminates">>
	      end,
    Packet = #presence{
		type = unavailable,
		sub_els = [#muc_user{items = [#muc_item{affiliation = none,
							reason = ReasonT,
							role = none}],
				     status_codes = [332]}]},
    (?DICT):fold(fun (LJID, Info, _) ->
			 Nick = Info#user.nick,
			 case Reason of
			   shutdown ->
			       send_wrapped(jid:replace_resource(StateData#state.jid,
								 Nick),
					    Info#user.jid, Packet,
					    ?NS_MUCSUB_NODES_PARTICIPANTS,
					    StateData);
			   _ -> ok
			 end,
			 tab_remove_online_user(LJID, StateData)
		 end,
		 [], StateData#state.users),
    add_to_log(room_existence, stopped, StateData),
    mod_muc:room_destroyed(StateData#state.host, StateData#state.room, self(),
			   StateData#state.server_host),
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
-spec route(pid(), jid(), binary(), stanza()) -> ok.
route(Pid, From, ToNick, Packet) ->
    gen_fsm:send_event(Pid, {route, From, ToNick, Packet}).

-spec process_groupchat_message(jid(), message(), state()) -> fsm_next().
process_groupchat_message(From, #message{lang = Lang} = Packet, StateData) ->
    case is_user_online(From, StateData) orelse
	   is_user_allowed_message_nonparticipant(From, StateData)
	of
      true ->
	  {FromNick, Role, IsSubscriber} = get_participant_data(From, StateData),
	  if (Role == moderator) or (Role == participant) or IsSubscriber or
	       ((StateData#state.config)#config.moderated == false) ->
		 Subject = check_subject(Packet),
		 {NewStateData1, IsAllowed} = case Subject of
						false -> {StateData, true};
						_ ->
						    case
						      can_change_subject(Role,
									 StateData)
							of
						      true ->
							  NSD =
							      StateData#state{subject
										  =
										  Subject,
									      subject_author
										  =
										  FromNick},
							  store_room(NSD),
							  {NSD, true};
						      _ -> {StateData, false}
						    end
					      end,
		 case IsAllowed of
		   true ->
		       case
			 ejabberd_hooks:run_fold(muc_filter_message,
						 StateData#state.server_host,
						 Packet,
						 [StateData,
						  StateData#state.jid,
						  From, FromNick])
			   of
			 drop ->
			     {next_state, normal_state, StateData};
			 NewPacket1 ->
			     NewPacket = xmpp:remove_subtag(NewPacket1, #nick{}),
			     Node = if Subject == false -> ?NS_MUCSUB_NODES_MESSAGES;
				       true -> ?NS_MUCSUB_NODES_SUBJECT
				    end,
			     send_wrapped_multiple(
			       jid:replace_resource(StateData#state.jid, FromNick),
			       StateData#state.users,
			       NewPacket, Node, NewStateData1),
			     NewStateData2 = case has_body_or_subject(NewPacket) of
					       true ->
						   add_message_to_history(FromNick, From,
									  NewPacket,
									  NewStateData1);
					       false ->
						   NewStateData1
					     end,
			     {next_state, normal_state, NewStateData2}
		       end;
		   _ ->
		       Err = case (StateData#state.config)#config.allow_change_subj of
			       true ->
				   xmpp:err_forbidden(
				     <<"Only moderators and participants are "
				       "allowed to change the subject in this "
				       "room">>, Lang);
			       _ ->
				   xmpp:err_forbidden(
				     <<"Only moderators are allowed to change "
				       "the subject in this room">>, Lang)
			     end,
		       ejabberd_router:route_error(
			 StateData#state.jid, From, Packet, Err),
		       {next_state, normal_state, StateData}
		 end;
	     true ->
		 ErrText = <<"Visitors are not allowed to send messages "
			     "to all occupants">>,
		 Err = xmpp:err_forbidden(ErrText, Lang),
		 ejabberd_router:route_error(
		   StateData#state.jid, From, Packet, Err),
		 {next_state, normal_state, StateData}
	  end;
      false ->
	  ErrText = <<"Only occupants are allowed to send messages "
		      "to the conference">>,
	  Err = xmpp:err_not_acceptable(ErrText, Lang),
	  ejabberd_router:route_error(StateData#state.jid, From, Packet, Err),
	  {next_state, normal_state, StateData}
    end.

-spec process_normal_message(jid(), message(), state()) -> state().
process_normal_message(From, #message{lang = Lang} = Pkt, StateData) ->
    IsInvitation = is_invitation(Pkt),
    IsVoiceRequest = is_voice_request(Pkt) and
	is_visitor(From, StateData),
    IsVoiceApprovement = is_voice_approvement(Pkt) and
	not is_visitor(From, StateData),
    if IsInvitation ->
	    case check_invitation(From, Pkt, StateData) of
		{error, Error} ->
		    ejabberd_router:route_error(StateData#state.jid, From, Pkt, Error),
		    StateData;
		IJID ->
		    Config = StateData#state.config,
		    case Config#config.members_only of
			true ->
			    case get_affiliation(IJID, StateData) of
				none ->
				    NSD = set_affiliation(IJID, member, StateData),
				    send_affiliation(IJID, member, StateData),
				    store_room(NSD),
				    NSD;
				_ ->
				    StateData
			    end;
			false ->
			    StateData
		    end
	    end;
       IsVoiceRequest ->
	    case (StateData#state.config)#config.allow_voice_requests of
		true ->
		    MinInterval = (StateData#state.config)#config.voice_request_min_interval,
		    BareFrom = jid:remove_resource(jid:tolower(From)),
		    NowPriority = -p1_time_compat:system_time(micro_seconds),
		    CleanPriority = NowPriority + MinInterval * 1000000,
		    Times = clean_treap(StateData#state.last_voice_request_time,
					CleanPriority),
		    case treap:lookup(BareFrom, Times) of
			error ->
			    Times1 = treap:insert(BareFrom,
						  NowPriority,
						  true, Times),
			    NSD = StateData#state{last_voice_request_time = Times1},
			    send_voice_request(From, Lang, NSD),
			    NSD;
			{ok, _, _} ->
			    ErrText = <<"Please, wait for a while before sending "
					"new voice request">>,
			    Err = xmpp:err_not_acceptable(ErrText, Lang),
			    ejabberd_router:route_error(
			      StateData#state.jid, From, Pkt, Err),
			    StateData#state{last_voice_request_time = Times}
		    end;
		false ->
		    ErrText = <<"Voice requests are disabled in this conference">>,
		    Err = xmpp:err_forbidden(ErrText, Lang),
		    ejabberd_router:route_error(
		      StateData#state.jid, From, Pkt, Err),
		    StateData
	    end;
       IsVoiceApprovement ->
	    case is_moderator(From, StateData) of
		true ->
		    case extract_jid_from_voice_approvement(Pkt) of
			error ->
			    ErrText = <<"Failed to extract JID from your voice "
					"request approval">>,
			    Err = xmpp:err_bad_request(ErrText, Lang),
			    ejabberd_router:route_error(
			      StateData#state.jid, From, Pkt, Err),
			    StateData;
			TargetJid ->
			    case is_visitor(TargetJid, StateData) of
				true ->
				    Reason = <<>>,
				    NSD = set_role(TargetJid,
						   participant,
						   StateData),
				    catch send_new_presence(TargetJid,
							    Reason,
							    NSD,
							    StateData),
				    NSD;
				_ ->
				    StateData
			    end
		    end;
		_ ->
		    ErrText = <<"Only moderators can approve voice requests">>,
		    Err = xmpp:err_not_allowed(ErrText, Lang),
		    ejabberd_router:route_error(
		      StateData#state.jid, From, Pkt, Err),
		    StateData
	    end;
       true ->
	    StateData
    end.

%% @doc Check if this non participant can send message to room.
%%
%% XEP-0045 v1.23:
%% 7.9 Sending a Message to All Occupants
%% an implementation MAY allow users with certain privileges
%% (e.g., a room owner, room admin, or service-level admin)
%% to send messages to the room even if those users are not occupants.
-spec is_user_allowed_message_nonparticipant(jid(), state()) -> boolean().
is_user_allowed_message_nonparticipant(JID,
				       StateData) ->
    case get_service_affiliation(JID, StateData) of
      owner -> true;
      _ -> false
    end.

%% @doc Get information of this participant, or default values.
%% If the JID is not a participant, return values for a service message.
-spec get_participant_data(jid(), state()) -> {binary(), role(), boolean()}.
get_participant_data(From, StateData) ->
    case (?DICT):find(jid:tolower(From),
		      StateData#state.users)
	of
      {ok, #user{nick = FromNick, role = Role, is_subscriber = IsSubscriber}} ->
	  {FromNick, Role, IsSubscriber};
      error -> {<<"">>, moderator, false}
    end.

-spec process_presence(jid(), binary(), presence(), state()) -> fsm_transition().
process_presence(From, Nick, #presence{type = Type0} = Packet0, StateData) ->
    IsOnline = is_user_online(From, StateData),
    if Type0 == available;
       IsOnline and ((Type0 == unavailable) or (Type0 == error)) ->
	   case ejabberd_hooks:run_fold(muc_filter_presence,
					StateData#state.server_host,
					Packet0,
					[StateData,
					 StateData#state.jid,
					 From, Nick]) of
	     drop ->
		 {next_state, normal_state, StateData};
	     #presence{} = Packet ->
		 close_room_if_temporary_and_empty(
		   do_process_presence(From, Nick, Packet, StateData))
	   end;
       true ->
	    {next_state, normal_state, StateData}
    end.

-spec do_process_presence(jid(), binary(), presence(), state()) ->
				 state().
do_process_presence(From, Nick, #presence{type = available, lang = Lang} = Packet,
		    StateData) ->
    case is_user_online(From, StateData) of
	false ->
	    add_new_user(From, Nick, Packet, StateData);
	true ->
	    case is_nick_change(From, Nick, StateData) of
		true ->
		    case {nick_collision(From, Nick, StateData),
			  mod_muc:can_use_nick(StateData#state.server_host,
					       StateData#state.host,
					       From, Nick),
			  {(StateData#state.config)#config.allow_visitor_nickchange,
			   is_visitor(From, StateData)}} of
			{_, _, {false, true}} ->
			    ErrText = <<"Visitors are not allowed to change their "
					"nicknames in this room">>,
			    Err = xmpp:err_not_allowed(ErrText, Lang),
			    ejabberd_router:route_error(
			      jid:replace_resource(StateData#state.jid, Nick),
			      From, Packet, Err),
			    StateData;
			{true, _, _} ->
			    ErrText = <<"That nickname is already in use by another "
					"occupant">>,
			    Err = xmpp:err_conflict(ErrText, Lang),
			    ejabberd_router:route_error(
			      jid:replace_resource(StateData#state.jid, Nick),
			      From, Packet, Err),
			    StateData;
			{_, false, _} ->
			    ErrText = <<"That nickname is registered by another "
					"person">>,
			    Err = xmpp:err_conflict(ErrText, Lang),
			    ejabberd_router:route_error(
			      jid:replace_resource(StateData#state.jid, Nick),
			      From, Packet, Err),
			    StateData;
			_ ->
			    case is_initial_presence(From, StateData) of
				true ->
				    subscriber_becomes_available(
				      From, Nick, Packet, StateData);
				false ->
				    change_nick(From, Nick, StateData)
			    end
		    end;
		_NotNickChange ->
		    case is_initial_presence(From, StateData) of
			true ->
			    subscriber_becomes_available(
			      From, Nick, Packet, StateData);
			false ->
			    Stanza = maybe_strip_status_from_presence(
				       From, Packet, StateData),
			    NewState = add_user_presence(From, Stanza,
							 StateData),
			    send_new_presence(From, NewState, StateData),
			    NewState
		    end
	    end
    end;
do_process_presence(From, Nick, #presence{type = unavailable} = Packet,
		    StateData) ->
    IsSubscriber = is_subscriber(From, StateData),
    NewPacket = case {(StateData#state.config)#config.allow_visitor_status,
		      is_visitor(From, StateData)} of
		    {false, true} ->
			strip_status(Packet);
		    _ -> Packet
		end,
    NewState = add_user_presence_un(From, NewPacket, StateData),
    case (?DICT):find(Nick, StateData#state.nicks) of
	{ok, [_, _ | _]} -> ok;
	_ -> send_new_presence(From, NewState, StateData)
    end,
    Reason = xmpp:get_text(NewPacket#presence.status),
    remove_online_user(From, NewState, IsSubscriber, Reason);
do_process_presence(From, _Nick, #presence{type = error, lang = Lang} = Packet,
		    StateData) ->
    ErrorText = <<"It is not allowed to send error messages to the"
		  " room. The participant (~s) has sent an error "
		  "message (~s) and got kicked from the room">>,
    expulse_participant(Packet, From, StateData,
			translate:translate(Lang, ErrorText)).

-spec maybe_strip_status_from_presence(jid(), presence(),
				       state()) -> presence().
maybe_strip_status_from_presence(From, Packet, StateData) ->
    case {(StateData#state.config)#config.allow_visitor_status,
	  is_visitor(From, StateData)} of
	{false, true} ->
	    strip_status(Packet);
	_Allowed -> Packet
    end.

-spec subscriber_becomes_available(jid(), binary(), presence(),
				   state()) -> state().
subscriber_becomes_available(From, Nick, Packet, StateData) ->
    Stanza = maybe_strip_status_from_presence(From, Packet, StateData),
    State1 = add_user_presence(From, Stanza, StateData),
    Aff = get_affiliation(From, State1),
    Role = get_default_role(Aff, State1),
    State2 = set_role(From, Role, State1),
    State3 = set_nick(From, Nick, State2),
    send_existing_presences(From, State3),
    send_initial_presence(From, State3, StateData),
    State3.

-spec close_room_if_temporary_and_empty(state()) -> fsm_transition().
close_room_if_temporary_and_empty(StateData1) ->
    case not (StateData1#state.config)#config.persistent
	   andalso (?DICT):size(StateData1#state.users) == 0
	of
      true ->
	  ?INFO_MSG("Destroyed MUC room ~s because it's temporary "
		    "and empty",
		    [jid:to_string(StateData1#state.jid)]),
	  add_to_log(room_existence, destroyed, StateData1),
	  {stop, normal, StateData1};
      _ -> {next_state, normal_state, StateData1}
    end.

-spec is_user_online(jid(), state()) -> boolean().
is_user_online(JID, StateData) ->
    LJID = jid:tolower(JID),
    (?DICT):is_key(LJID, StateData#state.users).

-spec is_subscriber(jid(), state()) -> boolean().
is_subscriber(JID, StateData) ->
    LJID = jid:tolower(JID),
    case (?DICT):find(LJID, StateData#state.users) of
	{ok, #user{is_subscriber = IsSubscriber}} ->
	    IsSubscriber;
	_ ->
	    false
    end.

%% Check if the user is occupant of the room, or at least is an admin or owner.
-spec is_occupant_or_admin(jid(), state()) -> boolean().
is_occupant_or_admin(JID, StateData) ->
    FAffiliation = get_affiliation(JID, StateData),
    FRole = get_role(JID, StateData),
    case FRole /= none orelse
	   FAffiliation == member orelse
	   FAffiliation == admin orelse FAffiliation == owner
	of
      true -> true;
      _ -> false
    end.

%%%
%%% Handle IQ queries of vCard
%%%
-spec is_user_online_iq(binary(), jid(), state()) ->
			       {boolean(), binary(), jid()}.
is_user_online_iq(StanzaId, JID, StateData)
    when JID#jid.lresource /= <<"">> ->
    {is_user_online(JID, StateData), StanzaId, JID};
is_user_online_iq(StanzaId, JID, StateData)
    when JID#jid.lresource == <<"">> ->
    try stanzaid_unpack(StanzaId) of
      {OriginalId, Resource} ->
	  JIDWithResource = jid:replace_resource(JID, Resource),
	  {is_user_online(JIDWithResource, StateData), OriginalId,
	   JIDWithResource}
    catch
      _:_ -> {is_user_online(JID, StateData), StanzaId, JID}
    end.

-spec handle_iq_vcard(jid(), binary(), iq()) -> {jid(), iq()}.
handle_iq_vcard(ToJID, NewId, #iq{type = Type, sub_els = SubEls} = IQ) ->
    ToBareJID = jid:remove_resource(ToJID),
    case SubEls of
	[SubEl] when Type == get, ToBareJID /= ToJID ->
	    case xmpp:get_ns(SubEl) of
		?NS_VCARD ->
		    {ToBareJID, change_stanzaid(ToJID, IQ)};
		_ ->
		    {ToJID, xmpp:set_id(IQ, NewId)}
	    end;
	_ ->
	    {ToJID, xmpp:set_id(IQ, NewId)}
    end.

-spec stanzaid_pack(binary(), binary()) -> binary().
stanzaid_pack(OriginalId, Resource) ->
    <<"berd",
      (jlib:encode_base64(<<"ejab\000",
		       OriginalId/binary, "\000",
		       Resource/binary>>))/binary>>.

-spec stanzaid_unpack(binary()) -> {binary(), binary()}.
stanzaid_unpack(<<"berd", StanzaIdBase64/binary>>) ->
    StanzaId = jlib:decode_base64(StanzaIdBase64),
    [<<"ejab">>, OriginalId, Resource] =
	str:tokens(StanzaId, <<"\000">>),
    {OriginalId, Resource}.

-spec change_stanzaid(jid(), iq()) -> iq().
change_stanzaid(ToJID, #iq{id = PreviousId} = Packet) ->
    NewId = stanzaid_pack(PreviousId, ToJID#jid.lresource),
    xmpp:set_id(Packet, NewId).

%% Decide the fate of the message and its sender
%% Returns: continue_delivery | forget_message | {expulse_sender, Reason}
-spec decide_fate_message(message(), jid(), state()) ->
				 continue_delivery | forget_message |
				 {expulse_sender, binary()}.
decide_fate_message(#message{type = error, error = Err},
		    From, StateData) ->
    PD = case check_error_kick(Err) of
	   %% If this is an error stanza and its condition matches a criteria
	   true ->
	       Reason =
		   io_lib:format("This participant is considered a ghost "
				 "and is expulsed: ~s",
				 [jid:to_string(From)]),
	       {expulse_sender, Reason};
	   false -> continue_delivery
	 end,
    case PD of
      {expulse_sender, R} ->
	  case is_user_online(From, StateData) of
	    true -> {expulse_sender, R};
	    false -> forget_message
	  end;
      Other -> Other
    end;
decide_fate_message(_, _, _) -> continue_delivery.

%% Check if the elements of this error stanza indicate
%% that the sender is a dead participant.
%% If so, return true to kick the participant.
-spec check_error_kick(error()) -> boolean().
check_error_kick(#error{reason = Reason}) ->
    case Reason of
	#gone{} -> true;
	'internal-server-error' -> true;
	'item-not-found' -> true;
	'jid-malformed' -> true;
	'recipient-unavailable' -> true;
	#redirect{} -> true;
	'remote-server-not-found' -> true;
	'remote-server-timeout' -> true;
	'service-unavailable' -> true;
	_ -> false
    end;
check_error_kick(undefined) ->
    false.

-spec get_error_condition(error()) -> string().
get_error_condition(#error{reason = Reason}) ->
    case Reason of
	#gone{} -> "gone";
	#redirect{} -> "redirect";
	Atom -> atom_to_list(Atom)
    end;
get_error_condition(undefined) ->
    "undefined".

-spec make_reason(stanza(), jid(), state(), binary()) -> binary().
make_reason(Packet, From, StateData, Reason1) ->
    {ok, #user{nick = FromNick}} = (?DICT):find(jid:tolower(From), StateData#state.users),
    Condition = get_error_condition(xmpp:get_error(Packet)),
    iolist_to_binary(io_lib:format(Reason1, [FromNick, Condition])).

-spec expulse_participant(stanza(), jid(), state(), binary()) ->
				 state().
expulse_participant(Packet, From, StateData, Reason1) ->
    IsSubscriber = is_subscriber(From, StateData),
    Reason2 = make_reason(Packet, From, StateData, Reason1),
    NewState = add_user_presence_un(From,
				    #presence{type = unavailable,
					      status = xmpp:mk_text(Reason2)},
				    StateData),
    send_new_presence(From, NewState, StateData),
    remove_online_user(From, NewState, IsSubscriber).

-spec set_affiliation(jid(), affiliation(), state()) -> state().
set_affiliation(JID, Affiliation, StateData) ->
    set_affiliation(JID, Affiliation, StateData, <<"">>).

-spec set_affiliation(jid(), affiliation(), state(), binary()) -> state().
set_affiliation(JID, Affiliation, StateData, Reason) ->
    LJID = jid:remove_resource(jid:tolower(JID)),
    Affiliations = case Affiliation of
		     none ->
			 (?DICT):erase(LJID, StateData#state.affiliations);
		     _ ->
			 (?DICT):store(LJID, {Affiliation, Reason},
				       StateData#state.affiliations)
		   end,
    StateData#state{affiliations = Affiliations}.

-spec get_affiliation(jid(), state()) -> affiliation().
get_affiliation(JID, StateData) ->
    {_AccessRoute, _AccessCreate, AccessAdmin,
     _AccessPersistent} =
	StateData#state.access,
    Res = case acl:match_rule(StateData#state.server_host,
			      AccessAdmin, JID)
	      of
	    allow -> owner;
	    _ ->
		LJID = jid:tolower(JID),
		case (?DICT):find(LJID, StateData#state.affiliations) of
		  {ok, Affiliation} -> Affiliation;
		  _ ->
		      LJID1 = jid:remove_resource(LJID),
		      case (?DICT):find(LJID1, StateData#state.affiliations)
			  of
			{ok, Affiliation} -> Affiliation;
			_ ->
			    LJID2 = setelement(1, LJID, <<"">>),
			    case (?DICT):find(LJID2,
					      StateData#state.affiliations)
				of
			      {ok, Affiliation} -> Affiliation;
			      _ ->
				  LJID3 = jid:remove_resource(LJID2),
				  case (?DICT):find(LJID3,
						    StateData#state.affiliations)
				      of
				    {ok, Affiliation} -> Affiliation;
				    _ -> none
				  end
			    end
		      end
		end
	  end,
    case Res of
      {A, _Reason} -> A;
      _ -> Res
    end.

-spec get_service_affiliation(jid(), state()) -> owner | none.
get_service_affiliation(JID, StateData) ->
    {_AccessRoute, _AccessCreate, AccessAdmin,
     _AccessPersistent} =
	StateData#state.access,
    case acl:match_rule(StateData#state.server_host,
			AccessAdmin, JID)
	of
      allow -> owner;
      _ -> none
    end.

-spec set_role(jid(), role(), state()) -> state().
set_role(JID, Role, StateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    {Users, Nicks} = case Role of
		       none ->
			   lists:foldl(fun (J, {Us, Ns}) ->
					       NewNs = case (?DICT):find(J, Us)
							   of
							 {ok,
							  #user{nick = Nick}} ->
							     (?DICT):erase(Nick,
									   Ns);
							 _ -> Ns
						       end,
					       {(?DICT):erase(J, Us), NewNs}
				       end,
				       {StateData#state.users,
					StateData#state.nicks},
				       LJIDs);
		       _ ->
			   {lists:foldl(
			      fun (J, Us) ->
				      {ok, User} = (?DICT):find(J, Us),
				      if User#user.last_presence == undefined ->
					      Us;
					 true ->
					      (?DICT):store(J, User#user{role = Role}, Us)
				      end
			      end,
			      StateData#state.users, LJIDs),
			    StateData#state.nicks}
		     end,
    StateData#state{users = Users, nicks = Nicks}.

-spec get_role(jid(), state()) -> role().
get_role(JID, StateData) ->
    LJID = jid:tolower(JID),
    case (?DICT):find(LJID, StateData#state.users) of
      {ok, #user{role = Role}} -> Role;
      _ -> none
    end.

-spec get_default_role(affiliation(), state()) -> role().
get_default_role(Affiliation, StateData) ->
    case Affiliation of
      owner -> moderator;
      admin -> moderator;
      member -> participant;
      outcast -> none;
      none ->
	  case (StateData#state.config)#config.members_only of
	    true -> none;
	    _ ->
		case (StateData#state.config)#config.members_by_default
		    of
		  true -> participant;
		  _ -> visitor
		end
	  end
    end.

-spec is_visitor(jid(), state()) -> boolean().
is_visitor(Jid, StateData) ->
    get_role(Jid, StateData) =:= visitor.

-spec is_moderator(jid(), state()) -> boolean().
is_moderator(Jid, StateData) ->
    get_role(Jid, StateData) =:= moderator.

-spec get_max_users(state()) -> non_neg_integer().
get_max_users(StateData) ->
    MaxUsers = (StateData#state.config)#config.max_users,
    ServiceMaxUsers = get_service_max_users(StateData),
    if MaxUsers =< ServiceMaxUsers -> MaxUsers;
       true -> ServiceMaxUsers
    end.

-spec get_service_max_users(state()) -> pos_integer().
get_service_max_users(StateData) ->
    gen_mod:get_module_opt(StateData#state.server_host,
			   mod_muc, max_users,
                           fun(I) when is_integer(I), I>0 -> I end,
                           ?MAX_USERS_DEFAULT).

-spec get_max_users_admin_threshold(state()) -> pos_integer().
get_max_users_admin_threshold(StateData) ->
    gen_mod:get_module_opt(StateData#state.server_host,
			   mod_muc, max_users_admin_threshold,
                           fun(I) when is_integer(I), I>0 -> I end,
                           5).

-spec get_user_activity(jid(), state()) -> #activity{}.
get_user_activity(JID, StateData) ->
    case treap:lookup(jid:tolower(JID),
		      StateData#state.activity)
	of
      {ok, _P, A} -> A;
      error ->
	  MessageShaper =
	      shaper:new(gen_mod:get_module_opt(StateData#state.server_host,
						mod_muc, user_message_shaper,
                                                fun(A) when is_atom(A) -> A end,
						none)),
	  PresenceShaper =
	      shaper:new(gen_mod:get_module_opt(StateData#state.server_host,
						mod_muc, user_presence_shaper,
                                                fun(A) when is_atom(A) -> A end,
						none)),
	  #activity{message_shaper = MessageShaper,
		    presence_shaper = PresenceShaper}
    end.

-spec store_user_activity(jid(), #activity{}, state()) -> state().
store_user_activity(JID, UserActivity, StateData) ->
    MinMessageInterval =
	trunc(gen_mod:get_module_opt(StateData#state.server_host,
				     mod_muc, min_message_interval,
				     fun(I) when is_number(I), I>=0 -> I end,
				     0)
	      * 1000),
    MinPresenceInterval =
	trunc(gen_mod:get_module_opt(StateData#state.server_host,
				     mod_muc, min_presence_interval,
				     fun(I) when is_number(I), I>=0 -> I end,
				     0)
	      * 1000),
    Key = jid:tolower(JID),
    Now = p1_time_compat:system_time(micro_seconds),
    Activity1 = clean_treap(StateData#state.activity,
			    {1, -Now}),
    Activity = case treap:lookup(Key, Activity1) of
		 {ok, _P, _A} -> treap:delete(Key, Activity1);
		 error -> Activity1
	       end,
    StateData1 = case MinMessageInterval == 0 andalso
			MinPresenceInterval == 0 andalso
			  UserActivity#activity.message_shaper == none andalso
			    UserActivity#activity.presence_shaper == none
			      andalso
			      UserActivity#activity.message == undefined andalso
				UserActivity#activity.presence == undefined
		     of
		   true -> StateData#state{activity = Activity};
		   false ->
		       case UserActivity#activity.message == undefined andalso
			      UserActivity#activity.presence == undefined
			   of
			 true ->
			     {_, MessageShaperInterval} =
				 shaper:update(UserActivity#activity.message_shaper,
					       100000),
			     {_, PresenceShaperInterval} =
				 shaper:update(UserActivity#activity.presence_shaper,
					       100000),
			     Delay = lists:max([MessageShaperInterval,
						PresenceShaperInterval,
						MinMessageInterval,
						MinPresenceInterval])
				       * 1000,
			     Priority = {1, -(Now + Delay)},
			     StateData#state{activity =
						 treap:insert(Key, Priority,
							      UserActivity,
							      Activity)};
			 false ->
			     Priority = {0, 0},
			     StateData#state{activity =
						 treap:insert(Key, Priority,
							      UserActivity,
							      Activity)}
		       end
		 end,
    StateData1.

-spec clean_treap(treap:treap(), integer()) -> treap:treap().
clean_treap(Treap, CleanPriority) ->
    case treap:is_empty(Treap) of
      true -> Treap;
      false ->
	  {_Key, Priority, _Value} = treap:get_root(Treap),
	  if Priority > CleanPriority ->
		 clean_treap(treap:delete_root(Treap), CleanPriority);
	     true -> Treap
	  end
    end.

-spec prepare_room_queue(state()) -> state().
prepare_room_queue(StateData) ->
    case queue:out(StateData#state.room_queue) of
      {{value, {message, From}}, _RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  Packet = Activity#activity.message,
	  Size = element_size(Packet),
	  {RoomShaper, RoomShaperInterval} =
	      shaper:update(StateData#state.room_shaper, Size),
	  erlang:send_after(RoomShaperInterval, self(),
			    process_room_queue),
	  StateData#state{room_shaper = RoomShaper};
      {{value, {presence, From}}, _RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  {_Nick, Packet} = Activity#activity.presence,
	  Size = element_size(Packet),
	  {RoomShaper, RoomShaperInterval} =
	      shaper:update(StateData#state.room_shaper, Size),
	  erlang:send_after(RoomShaperInterval, self(),
			    process_room_queue),
	  StateData#state{room_shaper = RoomShaper};
      {empty, _} -> StateData
    end.

-spec update_online_user(jid(), #user{}, state()) -> state().
update_online_user(JID, #user{nick = Nick, subscriptions = Nodes,
			      is_subscriber = IsSubscriber} = User, StateData) ->
    LJID = jid:tolower(JID),
    Nicks1 = case (?DICT):find(LJID, StateData#state.users) of
		 {ok, #user{nick = OldNick}} ->
		     case lists:delete(
			    LJID, ?DICT:fetch(OldNick, StateData#state.nicks)) of
			 [] ->
			     ?DICT:erase(OldNick, StateData#state.nicks);
			 LJIDs ->
			     ?DICT:store(OldNick, LJIDs, StateData#state.nicks)
		     end;
		 error ->
		     StateData#state.nicks
	     end,
    Nicks = (?DICT):update(Nick,
			   fun (LJIDs) -> [LJID|LJIDs -- [LJID]] end,
			   [LJID], Nicks1),
    Users = (?DICT):update(LJID,
			   fun(U) ->
				   U#user{nick = Nick,
					  subscriptions = Nodes,
					  is_subscriber = IsSubscriber}
			   end, User, StateData#state.users),
    NewStateData = StateData#state{users = Users, nicks = Nicks},
    case {?DICT:find(LJID, StateData#state.users),
	  ?DICT:find(LJID, NewStateData#state.users)} of
	{{ok, #user{nick = Old}}, {ok, #user{nick = New}}} when Old /= New ->
	    send_nick_changing(JID, Old, NewStateData, true, true);
	_ ->
	    ok
    end,
    NewStateData.

-spec add_online_user(jid(), binary(), role(), boolean(), [binary()], state()) -> state().
add_online_user(JID, Nick, Role, IsSubscriber, Nodes, StateData) ->
    tab_add_online_user(JID, StateData),
    User = #user{jid = JID, nick = Nick, role = Role,
		 is_subscriber = IsSubscriber, subscriptions = Nodes},
    StateData1 = update_online_user(JID, User, StateData),
    if IsSubscriber ->
	    store_room(StateData1);
       true ->
	    ok
    end,
    StateData1.

-spec remove_online_user(jid(), state(), boolean()) -> state().
remove_online_user(JID, StateData, IsSubscriber) ->
    remove_online_user(JID, StateData, IsSubscriber, <<"">>).

-spec remove_online_user(jid(), state(), boolean(), binary()) -> state().
remove_online_user(JID, StateData, _IsSubscriber = true, _Reason) ->
    LJID = jid:tolower(JID),
    Users = case (?DICT):find(LJID, StateData#state.users) of
		{ok, U} ->
		    (?DICT):store(LJID, U#user{last_presence = undefined},
				  StateData#state.users);
		error ->
		    StateData#state.users
	    end,
    StateData#state{users = Users};
remove_online_user(JID, StateData, _IsSubscriber, Reason) ->
    LJID = jid:tolower(JID),
    {ok, #user{nick = Nick}} = (?DICT):find(LJID,
					    StateData#state.users),
    add_to_log(leave, {Nick, Reason}, StateData),
    tab_remove_online_user(JID, StateData),
    Users = (?DICT):erase(LJID, StateData#state.users),
    Nicks = case (?DICT):find(Nick, StateData#state.nicks)
		of
	      {ok, [LJID]} ->
		  (?DICT):erase(Nick, StateData#state.nicks);
	      {ok, U} ->
		  (?DICT):store(Nick, U -- [LJID], StateData#state.nicks);
	      error -> StateData#state.nicks
	    end,
    StateData#state{users = Users, nicks = Nicks}.

-spec filter_presence(presence()) -> presence().
filter_presence(Presence) ->
    Els = lists:filter(
	    fun(El) ->
		    XMLNS = xmpp:get_ns(El),
		    case catch binary:part(XMLNS, 0, size(?NS_MUC)) of
			?NS_MUC -> false;
			_ -> true
		    end
	    end, xmpp:get_els(Presence)),
    xmpp:set_els(Presence, Els).

-spec strip_status(presence()) -> presence().
strip_status(Presence) ->
    Presence#presence{status = []}.

-spec add_user_presence(jid(), presence(), state()) -> state().
add_user_presence(JID, Presence, StateData) ->
    LJID = jid:tolower(JID),
    FPresence = filter_presence(Presence),
    Users = (?DICT):update(LJID,
			   fun (#user{} = User) ->
				   User#user{last_presence = FPresence}
			   end,
			   StateData#state.users),
    StateData#state{users = Users}.

-spec add_user_presence_un(jid(), presence(), state()) -> state().
add_user_presence_un(JID, Presence, StateData) ->
    LJID = jid:tolower(JID),
    FPresence = filter_presence(Presence),
    Users = (?DICT):update(LJID,
			   fun (#user{} = User) ->
				   User#user{last_presence = FPresence,
					     role = none}
			   end,
			   StateData#state.users),
    StateData#state{users = Users}.

%% Find and return a list of the full JIDs of the users of Nick.
%% Return jid record.
-spec find_jids_by_nick(binary(), state()) -> [jid()].
find_jids_by_nick(Nick, StateData) ->
    case (?DICT):find(Nick, StateData#state.nicks) of
      {ok, [User]} -> [jid:make(User)];
      {ok, Users} -> [jid:make(LJID) || LJID <- Users];
      error -> []
    end.

%% Find and return the full JID of the user of Nick with
%% highest-priority presence.  Return jid record.
-spec find_jid_by_nick(binary(), state()) -> jid() | false.
find_jid_by_nick(Nick, StateData) ->
    case (?DICT):find(Nick, StateData#state.nicks) of
      {ok, [User]} -> jid:make(User);
      {ok, [FirstUser | Users]} ->
	  #user{last_presence = FirstPresence} =
	      (?DICT):fetch(FirstUser, StateData#state.users),
	  {LJID, _} = lists:foldl(fun (Compare,
				       {HighestUser, HighestPresence}) ->
					  #user{last_presence = P1} =
					      (?DICT):fetch(Compare,
							    StateData#state.users),
					  case higher_presence(P1,
							       HighestPresence)
					      of
					    true -> {Compare, P1};
					    false ->
						{HighestUser, HighestPresence}
					  end
				  end,
				  {FirstUser, FirstPresence}, Users),
	  jid:make(LJID);
      error -> false
    end.

-spec higher_presence(undefined | presence(),
		      undefined | presence()) -> boolean().
higher_presence(Pres1, Pres2) when Pres1 /= undefined, Pres2 /= undefined ->
    Pri1 = get_priority_from_presence(Pres1),
    Pri2 = get_priority_from_presence(Pres2),
    Pri1 > Pri2;
higher_presence(Pres1, Pres2) ->
    Pres1 > Pres2.

-spec get_priority_from_presence(presence()) -> integer().
get_priority_from_presence(#presence{priority = Prio}) ->
    case Prio of
        undefined -> 0;
        _ -> Prio
    end.

-spec find_nick_by_jid(jid(), state()) -> binary().
find_nick_by_jid(JID, StateData) ->
    LJID = jid:tolower(JID),
    {ok, #user{nick = Nick}} = (?DICT):find(LJID, StateData#state.users),
    Nick.

-spec is_nick_change(jid(), binary(), state()) -> boolean().
is_nick_change(JID, Nick, StateData) ->
    LJID = jid:tolower(JID),
    case Nick of
      <<"">> -> false;
      _ ->
	  {ok, #user{nick = OldNick}} = (?DICT):find(LJID,
						     StateData#state.users),
	  Nick /= OldNick
    end.

-spec nick_collision(jid(), binary(), state()) -> boolean().
nick_collision(User, Nick, StateData) ->
    UserOfNick = find_jid_by_nick(Nick, StateData),
    (UserOfNick /= false andalso
      jid:remove_resource(jid:tolower(UserOfNick))
	/= jid:remove_resource(jid:tolower(User))).

-spec add_new_user(jid(), binary(), presence() | iq(), state()) ->
			  state() |
			  {error, error()} |
			  {ignore, state()} |
			  {result, xmpp_element(), state()}.
add_new_user(From, Nick, Packet, StateData) ->
    Lang = xmpp:get_lang(Packet),
    UserRoomJID = jid:replace_resource(StateData#state.jid, Nick),
    MaxUsers = get_max_users(StateData),
    MaxAdminUsers = MaxUsers +
		      get_max_users_admin_threshold(StateData),
    NUsers = dict:fold(fun (_, _, Acc) -> Acc + 1 end, 0,
		       StateData#state.users),
    Affiliation = get_affiliation(From, StateData),
    ServiceAffiliation = get_service_affiliation(From,
						 StateData),
    NConferences = tab_count_user(From),
    MaxConferences =
	gen_mod:get_module_opt(StateData#state.server_host,
			       mod_muc, max_user_conferences,
                               fun(I) when is_integer(I), I>0 -> I end,
                               10),
    Collision = nick_collision(From, Nick, StateData),
    IsSubscribeRequest = not is_record(Packet, presence),
    case {(ServiceAffiliation == owner orelse
	     ((Affiliation == admin orelse Affiliation == owner)
	       andalso NUsers < MaxAdminUsers)
	       orelse NUsers < MaxUsers)
	    andalso NConferences < MaxConferences,
	  Collision,
	  mod_muc:can_use_nick(StateData#state.server_host,
			       StateData#state.host, From, Nick),
	  get_default_role(Affiliation, StateData)}
	of
      {false, _, _, _} when NUsers >= MaxUsers orelse NUsers >= MaxAdminUsers ->
	  Txt = <<"Too many users in this conference">>,
	  Err = xmpp:err_resource_constraint(Txt, Lang),
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {false, _, _, _} when NConferences >= MaxConferences ->
	  Txt = <<"You have joined too many conferences">>,
	  Err = xmpp:err_resource_constraint(Txt, Lang),
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {false, _, _, _} ->
	  Err = xmpp:err_service_unavailable(),
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {_, _, _, none} ->
	  Err = case Affiliation of
		    outcast ->
			ErrText = <<"You have been banned from this room">>,
			xmpp:err_forbidden(ErrText, Lang);
		    _ ->
			ErrText = <<"Membership is required to enter this room">>,
			xmpp:err_registration_required(ErrText, Lang)
		end,
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {_, true, _, _} ->
	  ErrText = <<"That nickname is already in use by another occupant">>,
	  Err = xmpp:err_conflict(ErrText, Lang),
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {_, _, false, _} ->
	  ErrText = <<"That nickname is registered by another person">>,
	  Err = xmpp:err_conflict(ErrText, Lang),
	  ErrPacket = xmpp:make_error(Packet, Err),
	  if not IsSubscribeRequest ->
		  ejabberd_router:route(UserRoomJID, From, ErrPacket),
		  StateData;
	     true ->
		  {error, Err}
	  end;
      {_, _, _, Role} ->
	  case check_password(ServiceAffiliation, Affiliation,
			      Packet, From, StateData)
	      of
	    true ->
		Nodes = get_subscription_nodes(Packet),
		NewStateData =
		      if not IsSubscribeRequest ->
			      NewState = add_user_presence(
					   From, Packet,
					   add_online_user(From, Nick, Role,
							   IsSubscribeRequest,
							   Nodes, StateData)),
			      send_existing_presences(From, NewState),
			      send_initial_presence(From, NewState, StateData),
			      Shift = count_stanza_shift(Nick, Packet, NewState),
			      case send_history(From, Shift, NewState) of
				  true -> ok;
				  _ -> send_subject(From, StateData)
			      end,
			      NewState;
			 true ->
			      add_online_user(From, Nick, none,
					      IsSubscribeRequest,
					      Nodes, StateData)
		      end,
		  ResultState =
		      case NewStateData#state.just_created of
			  true ->
			      NewStateData#state{just_created = false};
			  false ->
			      Robots = (?DICT):erase(From, StateData#state.robots),
			      NewStateData#state{robots = Robots}
		      end,
		  if not IsSubscribeRequest -> ResultState;
		     true -> {result, subscribe_result(Packet), ResultState}
		  end;
	    nopass ->
		ErrText = <<"A password is required to enter this room">>,
		Err = xmpp:err_not_authorized(ErrText, Lang),
		ErrPacket = xmpp:make_error(Packet, Err),
		if not IsSubscribeRequest ->
			ejabberd_router:route(UserRoomJID, From, ErrPacket),
			StateData;
		   true ->
			{error, Err}
		end;
	    captcha_required ->
		SID = xmpp:get_id(Packet),
		RoomJID = StateData#state.jid,
		To = jid:replace_resource(RoomJID, Nick),
		Limiter = {From#jid.luser, From#jid.lserver},
		case ejabberd_captcha:create_captcha(SID, RoomJID, To,
						     Lang, Limiter, From)
                   of
		  {ok, ID, CaptchaEls} ->
		      MsgPkt = #message{id = ID, sub_els = CaptchaEls},
		      Robots = (?DICT):store(From, {Nick, Packet},
					     StateData#state.robots),
		      ejabberd_router:route(RoomJID, From, MsgPkt),
		      NewState = StateData#state{robots = Robots},
		      if not IsSubscribeRequest ->
			      NewState;
			 true ->
			      {ignore, NewState}
		      end;
		  {error, limit} ->
		      ErrText = <<"Too many CAPTCHA requests">>,
		      Err = xmpp:err_resource_constraint(ErrText, Lang),
		      ErrPacket = xmpp:make_error(Packet, Err),
		      if not IsSubscribeRequest ->
			      ejabberd_router:route(UserRoomJID, From, ErrPacket),
			      StateData;
			 true ->
			      {error, Err}
		      end;
		  _ ->
		      ErrText = <<"Unable to generate a CAPTCHA">>,
		      Err = xmpp:err_internal_server_error(ErrText, Lang),
		      ErrPacket = xmpp:make_error(Packet, Err),
		      if not IsSubscribeRequest ->
			      ejabberd_router:route(UserRoomJID, From, ErrPacket),
			      StateData;
			 true ->
			      {error, Err}
		      end
		end;
	    _ ->
		ErrText = <<"Incorrect password">>,
		Err = xmpp:err_not_authorized(ErrText, Lang),
		ErrPacket = xmpp:make_error(Packet, Err),
		if not IsSubscribeRequest ->
			ejabberd_router:route(UserRoomJID, From, ErrPacket),
			StateData;
		   true ->
			{error, Err}
		end
	  end
    end.

-spec check_password(affiliation(), affiliation(),
		     stanza(), jid(), state()) -> boolean() | nopass.
check_password(owner, _Affiliation, _Packet, _From,
	       _StateData) ->
    %% Don't check pass if user is owner in MUC service (access_admin option)
    true;
check_password(_ServiceAffiliation, Affiliation, Packet,
	       From, StateData) ->
    case (StateData#state.config)#config.password_protected
	of
      false -> check_captcha(Affiliation, From, StateData);
      true ->
	  Pass = extract_password(Packet),
	  case Pass of
	    false -> nopass;
	    _ ->
		case (StateData#state.config)#config.password of
		  Pass -> true;
		  _ -> false
		end
	  end
    end.

-spec check_captcha(affiliation(), jid(), state()) -> true | captcha_required.
check_captcha(Affiliation, From, StateData) ->
    case (StateData#state.config)#config.captcha_protected
	   andalso ejabberd_captcha:is_feature_available()
	of
      true when Affiliation == none ->
	  case (?DICT):find(From, StateData#state.robots) of
	    {ok, passed} -> true;
	    _ ->
		WList =
		    (StateData#state.config)#config.captcha_whitelist,
		#jid{luser = U, lserver = S, lresource = R} = From,
		case (?SETS):is_element({U, S, R}, WList) of
		  true -> true;
		  false ->
		      case (?SETS):is_element({U, S, <<"">>}, WList) of
			true -> true;
			false ->
			    case (?SETS):is_element({<<"">>, S, <<"">>}, WList)
				of
			      true -> true;
			      false -> captcha_required
			    end
		      end
		end
	  end;
      _ -> true
    end.

-spec extract_password(stanza()) -> binary() | false.
extract_password(Packet) ->
    case xmpp:get_subtag(Packet, #muc{}) of
	#muc{password = Password} when is_binary(Password) ->
	    Password;
	_ ->
	    false
    end.

-spec count_stanza_shift(binary(), stanza(), state()) -> non_neg_integer().
count_stanza_shift(Nick, Packet, StateData) ->
    case xmpp:get_subtag(Packet, #muc_history{}) of
	#muc_history{since = Since,
		     seconds = Seconds,
		     maxstanzas = MaxStanzas,
		     maxchars = MaxChars} ->
	    HL = lqueue_to_list(StateData#state.history),
	    Shift0 = case Since of
			 undefined -> 0;
			 _ ->
			     Sin = calendar:datetime_to_gregorian_seconds(
				     calendar:now_to_datetime(Since)),
			     count_seconds_shift(Sin, HL)
		     end,
	    Shift1 = case Seconds of
			 undefined -> 0;
			 _ ->
			     Sec = calendar:datetime_to_gregorian_seconds(
				     calendar:universal_time()) - Seconds,
			     count_seconds_shift(Sec, HL)
		     end,
	    Shift2 = case MaxStanzas of
			 undefined -> 0;
			 _ -> count_maxstanzas_shift(MaxStanzas, HL)
		     end,
	    Shift3 = case MaxChars of
			 undefined -> 0;
			 _ -> count_maxchars_shift(Nick, MaxChars, HL)
		     end,
	    lists:max([Shift0, Shift1, Shift2, Shift3]);
	false ->
	    0
    end.

-spec count_seconds_shift(non_neg_integer(),
			  [history_element()]) -> non_neg_integer().
count_seconds_shift(Seconds, HistoryList) ->
    lists:sum(lists:map(fun ({_Nick, _Packet, _HaveSubject,
			      TimeStamp, _Size}) ->
				T =
				    calendar:datetime_to_gregorian_seconds(TimeStamp),
				if T < Seconds -> 1;
				   true -> 0
				end
			end,
			HistoryList)).

-spec count_maxstanzas_shift(non_neg_integer(),
			     [history_element()]) -> non_neg_integer().
count_maxstanzas_shift(MaxStanzas, HistoryList) ->
    S = length(HistoryList) - MaxStanzas,
    if S =< 0 -> 0;
       true -> S
    end.

-spec count_maxchars_shift(binary(), non_neg_integer(),
			   [history_element()]) -> integer().
count_maxchars_shift(Nick, MaxSize, HistoryList) ->
    NLen = byte_size(Nick) + 1,
    Sizes = lists:map(fun ({_Nick, _Packet, _HaveSubject,
			    _TimeStamp, Size}) ->
			      Size + NLen
		      end,
		      HistoryList),
    calc_shift(MaxSize, Sizes).

-spec calc_shift(non_neg_integer(), [non_neg_integer()]) -> integer().
calc_shift(MaxSize, Sizes) ->
    Total = lists:sum(Sizes),
    calc_shift(MaxSize, Total, 0, Sizes).

-spec calc_shift(non_neg_integer(), integer(), integer(),
		 [non_neg_integer()]) -> integer().
calc_shift(_MaxSize, _Size, Shift, []) -> Shift;
calc_shift(MaxSize, Size, Shift, [S | TSizes]) ->
    if MaxSize >= Size -> Shift;
       true -> calc_shift(MaxSize, Size - S, Shift + 1, TSizes)
    end.

-spec is_room_overcrowded(state()) -> boolean().
is_room_overcrowded(StateData) ->
    MaxUsersPresence = gen_mod:get_module_opt(StateData#state.server_host,
	mod_muc, max_users_presence,
	fun(MUP) when is_integer(MUP) -> MUP end,
	?DEFAULT_MAX_USERS_PRESENCE),
    (?DICT):size(StateData#state.users) > MaxUsersPresence.

-spec presence_broadcast_allowed(jid(), state()) -> boolean().
presence_broadcast_allowed(JID, StateData) ->
    Role = get_role(JID, StateData),
    lists:member(Role, (StateData#state.config)#config.presence_broadcast).

-spec is_initial_presence(jid(), state()) -> boolean().
is_initial_presence(From, StateData) ->
    LJID = jid:tolower(From),
    case (?DICT):find(LJID, StateData#state.users) of
	{ok, #user{last_presence = Pres}} when Pres /= undefined ->
	    false;
	_ ->
	    true
    end.

-spec send_initial_presence(jid(), state(), state()) -> ok.
send_initial_presence(NJID, StateData, OldStateData) ->
    send_new_presence1(NJID, <<"">>, true, StateData, OldStateData).

-spec send_update_presence(jid(), state(), state()) -> ok.
send_update_presence(JID, StateData, OldStateData) ->
    send_update_presence(JID, <<"">>, StateData, OldStateData).

-spec send_update_presence(jid(), binary(), state(), state()) -> ok.
send_update_presence(JID, Reason, StateData, OldStateData) ->
    case is_room_overcrowded(StateData) of
	true -> ok;
	false -> send_update_presence1(JID, Reason, StateData, OldStateData)
    end.

-spec send_update_presence1(jid(), binary(), state(), state()) -> ok.
send_update_presence1(JID, Reason, StateData, OldStateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    lists:foreach(fun (J) ->
			  send_new_presence1(J, Reason, false, StateData,
					     OldStateData)
		  end,
		  LJIDs).

-spec send_new_presence(jid(), state(), state()) -> ok.
send_new_presence(NJID, StateData, OldStateData) ->
    send_new_presence(NJID, <<"">>, false, StateData, OldStateData).

-spec send_new_presence(jid(), binary(), state(), state()) -> ok.
send_new_presence(NJID, Reason, StateData, OldStateData) ->
    send_new_presence(NJID, Reason, false, StateData, OldStateData).

-spec send_new_presence(jid(), binary(), boolean(), state(), state()) -> ok.
send_new_presence(NJID, Reason, IsInitialPresence, StateData, OldStateData) ->
    case is_room_overcrowded(StateData) of
	true -> ok;
	false -> send_new_presence1(NJID, Reason, IsInitialPresence, StateData,
				    OldStateData)
    end.

-spec is_ra_changed(jid() | ljid(), boolean(), state(), state()) -> boolean().
is_ra_changed(_, _IsInitialPresence = true, _, _) ->
    false;
is_ra_changed(LJID, _IsInitialPresence = false, NewStateData, OldStateData) ->
    JID = case LJID of
	      #jid{} -> LJID;
	      _ -> jid:make(LJID)
	  end,
    NewRole = get_role(LJID, NewStateData),
    NewAff = get_affiliation(JID, NewStateData),
    OldRole = get_role(LJID, OldStateData),
    OldAff = get_affiliation(JID, OldStateData),
    if (NewRole == none) and (NewAff == OldAff) ->
	    %% A user is leaving the room;
	    false;
       true ->
	    (NewRole /= OldRole) or (NewAff /= OldAff)
    end.

-spec send_new_presence1(jid(), binary(), boolean(), state(), state()) -> ok.
send_new_presence1(NJID, Reason, IsInitialPresence, StateData, OldStateData) ->
    LNJID = jid:tolower(NJID),
    #user{nick = Nick} = (?DICT):fetch(LNJID, StateData#state.users),
    LJID = find_jid_by_nick(Nick, StateData),
    {ok,
     #user{jid = RealJID, role = Role0,
	   last_presence = Presence0} = UserInfo} =
	(?DICT):find(jid:tolower(LJID),
		     StateData#state.users),
    {Role1, Presence1} =
        case presence_broadcast_allowed(NJID, StateData) of
            true -> {Role0, Presence0};
            false -> {none, #presence{type = unavailable}}
        end,
    Affiliation = get_affiliation(LJID, StateData),
    UserList =
        case not (presence_broadcast_allowed(NJID, StateData) orelse
             presence_broadcast_allowed(NJID, OldStateData)) of
            true ->
                [{LNJID, UserInfo}];
            false ->
                (?DICT):to_list(StateData#state.users)
        end,
    lists:foreach(
      fun({LUJID, Info}) ->
	      {Role, Presence} = if LNJID == LUJID -> {Role0, Presence0};
				    true -> {Role1, Presence1}
				 end,
	      Item0 = #muc_item{affiliation = Affiliation,
				role = Role},
	      Item1 = case Info#user.role == moderator orelse
			  (StateData#state.config)#config.anonymous
			  == false of
			  true -> Item0#muc_item{jid = RealJID};
			  false -> Item0
		      end,
	      Item = if is_binary(Reason), Reason /= <<"">> ->
			     Item1#muc_item{reason = Reason};
			true ->
			     Item1
		     end,
	      StatusCodes = status_codes(IsInitialPresence, NJID, Info,
					 StateData),
	      Pres = if Presence == undefined -> #presence{};
			true -> Presence
		     end,
	      Packet = xmpp:set_subtag(
			 Pres, #muc_user{items = [Item],
					 status_codes = StatusCodes}),
	      Node1 = case is_ra_changed(NJID, IsInitialPresence, StateData, OldStateData) of
			  true -> ?NS_MUCSUB_NODES_AFFILIATIONS;
			  false -> ?NS_MUCSUB_NODES_PRESENCE
		      end,
	      send_wrapped(jid:replace_resource(StateData#state.jid, Nick),
			   Info#user.jid, Packet, Node1, StateData),
	      Type = xmpp:get_type(Packet),
	      IsSubscriber = Info#user.is_subscriber,
	      IsOccupant = Info#user.last_presence /= undefined,
	      if (IsSubscriber and not IsOccupant) and
		 (IsInitialPresence or (Type == unavailable)) ->
		      Node2 = ?NS_MUCSUB_NODES_PARTICIPANTS,
		      send_wrapped(jid:replace_resource(StateData#state.jid, Nick),
				   Info#user.jid, Packet, Node2, StateData);
		 true ->
		      ok
	      end
      end,
      UserList).

-spec send_existing_presences(jid(), state()) -> ok.
send_existing_presences(ToJID, StateData) ->
    case is_room_overcrowded(StateData) of
	true -> ok;
	false -> send_existing_presences1(ToJID, StateData)
    end.

-spec send_existing_presences1(jid(), state()) -> ok.
send_existing_presences1(ToJID, StateData) ->
    LToJID = jid:tolower(ToJID),
    {ok, #user{jid = RealToJID, role = Role}} =
	(?DICT):find(LToJID, StateData#state.users),
    lists:foreach(
      fun({FromNick, _Users}) ->
	      LJID = find_jid_by_nick(FromNick, StateData),
	      #user{jid = FromJID, role = FromRole,
		    last_presence = Presence} =
		  (?DICT):fetch(jid:tolower(LJID),
				StateData#state.users),
	      PresenceBroadcast =
		  lists:member(
		    FromRole, (StateData#state.config)#config.presence_broadcast),
	      case {RealToJID, PresenceBroadcast} of
		  {FromJID, _} -> ok;
		  {_, false} -> ok;
		  _ ->
		      FromAffiliation = get_affiliation(LJID, StateData),
		      Item0 = #muc_item{affiliation = FromAffiliation,
					role = FromRole},
		      Item = case Role == moderator orelse
				 (StateData#state.config)#config.anonymous
				 == false of
				 true -> Item0#muc_item{jid = FromJID};
				 false -> Item0
			     end,
		      Packet = xmpp:set_subtag(
				 Presence, #muc_user{items = [Item]}),
		      send_wrapped(jid:replace_resource(StateData#state.jid, FromNick),
				   RealToJID, Packet, ?NS_MUCSUB_NODES_PRESENCE, StateData)
	      end
      end,
      (?DICT):to_list(StateData#state.nicks)).

-spec set_nick(jid(), binary(), state()) -> state().
set_nick(JID, Nick, State) ->
    LJID = jid:tolower(JID),
    {ok, #user{nick = OldNick}} = (?DICT):find(LJID, State#state.users),
    Users = (?DICT):update(LJID,
			   fun (#user{} = User) -> User#user{nick = Nick} end,
			   State#state.users),
    OldNickUsers = (?DICT):fetch(OldNick, State#state.nicks),
    NewNickUsers = case (?DICT):find(Nick, State#state.nicks) of
		       {ok, U} -> U;
		       error -> []
		   end,
    Nicks = case OldNickUsers of
		[LJID] ->
		    (?DICT):store(Nick, [LJID | NewNickUsers -- [LJID]],
				  (?DICT):erase(OldNick, State#state.nicks));
		[_ | _] ->
		    (?DICT):store(Nick, [LJID | NewNickUsers -- [LJID]],
				  (?DICT):store(OldNick, OldNickUsers -- [LJID],
						State#state.nicks))
	    end,
    State#state{users = Users, nicks = Nicks}.

-spec change_nick(jid(), binary(), state()) -> state().
change_nick(JID, Nick, StateData) ->
    LJID = jid:tolower(JID),
    {ok, #user{nick = OldNick}} = (?DICT):find(LJID, StateData#state.users),
    OldNickUsers = (?DICT):fetch(OldNick, StateData#state.nicks),
    NewNickUsers = case (?DICT):find(Nick, StateData#state.nicks) of
		       {ok, U} -> U;
		       error -> []
		   end,
    SendOldUnavailable = length(OldNickUsers) == 1,
    SendNewAvailable = SendOldUnavailable orelse NewNickUsers == [],
    NewStateData = set_nick(JID, Nick, StateData),
    case presence_broadcast_allowed(JID, NewStateData) of
        true ->
            send_nick_changing(JID, OldNick, NewStateData,
                               SendOldUnavailable, SendNewAvailable);
        false -> ok
    end,
    add_to_log(nickchange, {OldNick, Nick}, StateData),
    NewStateData.

-spec send_nick_changing(jid(), binary(), state(), boolean(), boolean()) -> ok.
send_nick_changing(JID, OldNick, StateData,
		   SendOldUnavailable, SendNewAvailable) ->
    {ok,
     #user{jid = RealJID, nick = Nick, role = Role,
	   last_presence = Presence}} =
	(?DICT):find(jid:tolower(JID),
		     StateData#state.users),
    Affiliation = get_affiliation(JID, StateData),
    lists:foreach(
      fun({_LJID, Info}) when Presence /= undefined ->
	      Item0 = #muc_item{affiliation = Affiliation, role = Role},
	      Item1 = case Info#user.role == moderator orelse
			  (StateData#state.config)#config.anonymous
			  == false of
			  true -> Item0#muc_item{jid = RealJID, nick = Nick};
			  false -> Item0#muc_item{nick = Nick}
		      end,
	      Item2 = case Info#user.role == moderator orelse
			  (StateData#state.config)#config.anonymous
			  == false of
			  true -> Item0#muc_item{jid = RealJID};
			  false -> Item0
		      end,
	      Status110 = case JID == Info#user.jid of
			      true -> [110];
			      false -> []
			  end,
	      Packet1 = #presence{type = unavailable,
				  sub_els = [#muc_user{
						items = [Item1],
						status_codes = [303|Status110]}]},
	      Packet2 = xmpp:set_subtag(Presence,
					#muc_user{items = [Item2],
						  status_codes = Status110}),
	      if SendOldUnavailable ->
		      send_wrapped(
			jid:replace_resource(StateData#state.jid, OldNick),
			Info#user.jid, Packet1, ?NS_MUCSUB_NODES_PRESENCE,
			StateData);
		 true -> ok
	      end,
	      if SendNewAvailable ->
		      send_wrapped(
			jid:replace_resource(StateData#state.jid, Nick),
			Info#user.jid, Packet2, ?NS_MUCSUB_NODES_PRESENCE,
			StateData);
		 true -> ok
	      end;
	 (_) ->
	      ok
      end,
      (?DICT):to_list(StateData#state.users)).

-spec maybe_send_affiliation(jid(), affiliation(), state()) -> ok.
maybe_send_affiliation(JID, Affiliation, StateData) ->
    LJID = jid:tolower(JID),
    IsOccupant = case LJID of
		   {LUser, LServer, <<"">>} ->
		       not (?DICT):is_empty(
			     (?DICT):filter(fun({U, S, _}, _) ->
						    U == LUser andalso
						      S == LServer
					    end, StateData#state.users));
		   {_LUser, _LServer, _LResource} ->
		       (?DICT):is_key(LJID, StateData#state.users)
		 end,
    case IsOccupant of
      true ->
	  ok; % The new affiliation is published via presence.
      false ->
	  send_affiliation(LJID, Affiliation, StateData)
    end.

-spec send_affiliation(ljid(), affiliation(), state()) -> ok.
send_affiliation(LJID, Affiliation, StateData) ->
    Item = #muc_item{jid = jid:make(LJID),
		     affiliation = Affiliation,
		     role = none},
    Message = #message{id = randoms:get_string(),
		       sub_els = [#muc_user{items = [Item]}]},
    Recipients = case (StateData#state.config)#config.anonymous of
		   true ->
		       (?DICT):filter(fun(_, #user{role = moderator}) ->
					      true;
					 (_, _) ->
					      false
				      end, StateData#state.users);
		   false ->
		       StateData#state.users
		 end,
    send_multiple(StateData#state.jid,
		  StateData#state.server_host,
		  Recipients, Message).

-spec status_codes(boolean(), jid(), #user{}, state()) -> [pos_integer()].
status_codes(IsInitialPresence, JID, #user{jid = JID}, StateData) ->
    S0 = [110],
    case IsInitialPresence of
	true ->
	    S1 = case StateData#state.just_created of
		     true -> [201|S0];
		     false -> S0
		 end,
	    S2 = case (StateData#state.config)#config.anonymous of
		     true -> S1;
		     false -> [100|S1]
		 end,
	    S3 = case (StateData#state.config)#config.logging of
		     true -> [170|S2];
		     false -> S2
		 end,
	    S3;
	false -> S0
    end;
status_codes(_IsInitialPresence, _JID, _Info, _StateData) -> [].

-spec lqueue_new(non_neg_integer()) -> lqueue().
lqueue_new(Max) ->
    #lqueue{queue = queue:new(), len = 0, max = Max}.

-spec lqueue_in(term(), lqueue()) -> lqueue().
%% If the message queue limit is set to 0, do not store messages.
lqueue_in(_Item, LQ = #lqueue{max = 0}) -> LQ;
%% Otherwise, rotate messages in the queue store.
lqueue_in(Item,
	  #lqueue{queue = Q1, len = Len, max = Max}) ->
    Q2 = queue:in(Item, Q1),
    if Len >= Max ->
	   Q3 = lqueue_cut(Q2, Len - Max + 1),
	   #lqueue{queue = Q3, len = Max, max = Max};
       true -> #lqueue{queue = Q2, len = Len + 1, max = Max}
    end.

-spec lqueue_cut(queue:queue(), non_neg_integer()) -> queue:queue().
lqueue_cut(Q, 0) -> Q;
lqueue_cut(Q, N) ->
    {_, Q1} = queue:out(Q), lqueue_cut(Q1, N - 1).

-spec lqueue_to_list(lqueue()) -> list().
lqueue_to_list(#lqueue{queue = Q1}) ->
    queue:to_list(Q1).

-spec add_message_to_history(binary(), jid(), message(), state()) -> state().
add_message_to_history(FromNick, FromJID, Packet, StateData) ->
    HaveSubject = Packet#message.subject /= [],
    TimeStamp = p1_time_compat:timestamp(),
    AddrPacket = case (StateData#state.config)#config.anonymous of
		   true -> Packet;
		   false ->
		       Addresses = #addresses{
				      list = [#address{type = ofrom,
						       jid = FromJID}]},
		       xmpp:set_subtag(Packet, Addresses)
		 end,
    TSPacket = xmpp_util:add_delay_info(
		 AddrPacket, StateData#state.jid, TimeStamp),
    SPacket = xmpp:set_from_to(
		TSPacket,
		jid:replace_resource(StateData#state.jid, FromNick),
		StateData#state.jid),
    Size = element_size(SPacket),
    Q1 = lqueue_in({FromNick, TSPacket, HaveSubject,
		    calendar:now_to_universal_time(TimeStamp), Size},
		   StateData#state.history),
    add_to_log(text, {FromNick, Packet}, StateData),
    StateData#state{history = Q1}.

-spec send_history(jid(), integer(), state()) -> boolean().
send_history(JID, Shift, StateData) ->
    lists:foldl(fun ({Nick, Packet, HaveSubject, _TimeStamp,
		      _Size},
		     B) ->
			ejabberd_router:route(jid:replace_resource(StateData#state.jid,
							       Nick),
				     JID, Packet),
			B or HaveSubject
		end,
		false,
		lists:nthtail(Shift,
			      lqueue_to_list(StateData#state.history))).

-spec send_subject(jid(), state()) -> ok.
send_subject(_JID, #state{subject_author = <<"">>}) -> ok;
send_subject(JID, #state{subject_author = Nick} = StateData) ->
    Subject = StateData#state.subject,
    Packet = #message{type = groupchat, subject = xmpp:mk_text(Subject)},
    ejabberd_router:route(jid:replace_resource(StateData#state.jid, Nick), JID,
			  Packet).

-spec check_subject(message()) -> false | binary().
check_subject(#message{subject = []}) -> false;
check_subject(#message{subject = Subj}) -> xmpp:get_text(Subj).

-spec can_change_subject(role(), state()) -> boolean().
can_change_subject(Role, StateData) ->
    case (StateData#state.config)#config.allow_change_subj
	of
      true -> Role == moderator orelse Role == participant;
      _ -> Role == moderator
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Admin stuff

-spec process_iq_admin(jid(), iq(), #state{}) -> {error, error()} |
						 {result, undefined, #state{}} |
						 {result, muc_admin()}.
process_iq_admin(_From, #iq{lang = Lang, sub_els = [#muc_admin{items = []}]},
		 _StateData) ->
    Txt = <<"No 'item' element found">>,
    {error, xmpp:err_bad_request(Txt, Lang)};
process_iq_admin(From, #iq{type = set, lang = Lang,
			   sub_els = [#muc_admin{items = Items}]},
		 StateData) ->
    process_admin_items_set(From, Items, Lang, StateData);
process_iq_admin(From, #iq{type = get, lang = Lang,
			   sub_els = [#muc_admin{items = [Item]}]},
		 StateData) ->
    FAffiliation = get_affiliation(From, StateData),
    FRole = get_role(From, StateData),
    case Item of
	#muc_item{role = undefined, affiliation = undefined} ->
	    Txt = <<"Neither 'role' nor 'affiliation' attribute found">>,
	    {error, xmpp:err_bad_request(Txt, Lang)};
	#muc_item{role = undefined, affiliation = Affiliation} ->
	    if (FAffiliation == owner) or
	       (FAffiliation == admin) or
	       ((FAffiliation == member) and
		not (StateData#state.config)#config.anonymous) ->
		    Items = items_with_affiliation(Affiliation, StateData),
		    {result, #muc_admin{items = Items}};
	       true ->
		    ErrText = <<"Administrator privileges required">>,
		    {error, xmpp:err_forbidden(ErrText, Lang)}
	    end;
	#muc_item{role = Role} ->
	    if FRole == moderator ->
		    Items = items_with_role(Role, StateData),
		    {result, #muc_admin{items = Items}};
	       true ->
		    ErrText = <<"Moderator privileges required">>,
		    {error, xmpp:err_forbidden(ErrText, Lang)}
	    end
    end;
process_iq_admin(_From, #iq{type = get, lang = Lang}, _StateData) ->
    ErrText = <<"Too many <item/> elements">>,
    {error, xmpp:err_bad_request(ErrText, Lang)}.

-spec items_with_role(role(), state()) -> [muc_item()].
items_with_role(SRole, StateData) ->
    lists:map(fun ({_, U}) -> user_to_item(U, StateData)
	      end,
	      search_role(SRole, StateData)).

-spec items_with_affiliation(affiliation(), state()) -> [muc_item()].
items_with_affiliation(SAffiliation, StateData) ->
    lists:map(
      fun({JID, {Affiliation, Reason}}) ->
	      #muc_item{affiliation = Affiliation, jid = JID,
			reason = if is_binary(Reason), Reason /= <<"">> ->
					 Reason;
				    true ->
					 undefined
				 end};
	 ({JID, Affiliation}) ->
	      #muc_item{affiliation = Affiliation, jid = JID}
      end,
      search_affiliation(SAffiliation, StateData)).

-spec user_to_item(#user{}, state()) -> muc_item().
user_to_item(#user{role = Role, nick = Nick, jid = JID},
	     StateData) ->
    Affiliation = get_affiliation(JID, StateData),
    #muc_item{role = Role,
	      affiliation = Affiliation,
	      nick = Nick,
	      jid = JID}.

-spec search_role(role(), state()) -> [{ljid(), #user{}}].
search_role(Role, StateData) ->
    lists:filter(fun ({_, #user{role = R}}) -> Role == R
		 end,
		 (?DICT):to_list(StateData#state.users)).

-spec search_affiliation(affiliation(), state()) ->
				[{ljid(),
				  affiliation() | {affiliation(), binary()}}].
search_affiliation(Affiliation, StateData) ->
    lists:filter(fun ({_, A}) ->
			 case A of
			   {A1, _Reason} -> Affiliation == A1;
			   _ -> Affiliation == A
			 end
		 end,
		 (?DICT):to_list(StateData#state.affiliations)).

-spec process_admin_items_set(jid(), [muc_item()], binary() | undefined,
			      #state{}) -> {result, undefined, #state{}} |
					   {error, error()}.
process_admin_items_set(UJID, Items, Lang, StateData) ->
    UAffiliation = get_affiliation(UJID, StateData),
    URole = get_role(UJID, StateData),
    case catch find_changed_items(UJID, UAffiliation, URole,
				  Items, Lang, StateData, [])
	of
      {result, Res} ->
	  ?INFO_MSG("Processing MUC admin query from ~s in "
		    "room ~s:~n ~p",
		    [jid:to_string(UJID),
		     jid:to_string(StateData#state.jid), Res]),
	  NSD = lists:foldl(process_item_change(UJID),
			    StateData, lists:flatten(Res)),
	  store_room(NSD),
	  {result, undefined, NSD};
      {error, Err} -> {error, Err}
    end.

-spec process_item_change(jid()) -> function().
process_item_change(UJID) ->
    fun(E, SD) ->
        process_item_change(E, SD, UJID)
    end.

-type admin_action() :: {jid(), affiliation | role,
			 affiliation() | role(), binary()}.

-spec process_item_change(admin_action(), state(), jid()) -> state().
process_item_change(Item, SD, UJID) ->
    try case Item of
	    {JID, affiliation, owner, _} when JID#jid.luser == <<"">> ->
		%% If the provided JID does not have username,
		%% forget the affiliation completely
		SD;
	    {JID, role, none, Reason} ->
		catch send_kickban_presence(UJID, JID, Reason, 307, SD),
		set_role(JID, none, SD);
	    {JID, affiliation, none, Reason} ->
		case (SD#state.config)#config.members_only of
		    true ->
			catch send_kickban_presence(UJID, JID, Reason, 321, none, SD),
			maybe_send_affiliation(JID, none, SD),
			SD1 = set_affiliation(JID, none, SD),
			set_role(JID, none, SD1);
		    _ ->
			SD1 = set_affiliation(JID, none, SD),
			send_update_presence(JID, SD1, SD),
			maybe_send_affiliation(JID, none, SD1),
			SD1
		end;
	    {JID, affiliation, outcast, Reason} ->
		catch send_kickban_presence(UJID, JID, Reason, 301, outcast, SD),
		maybe_send_affiliation(JID, outcast, SD),
		set_affiliation(JID, outcast, set_role(JID, none, SD), Reason);
	    {JID, affiliation, A, Reason} when (A == admin) or (A == owner) ->
		SD1 = set_affiliation(JID, A, SD, Reason),
		SD2 = set_role(JID, moderator, SD1),
		send_update_presence(JID, Reason, SD2, SD),
		maybe_send_affiliation(JID, A, SD2),
		SD2;
	    {JID, affiliation, member, Reason} ->
		SD1 = set_affiliation(JID, member, SD, Reason),
		SD2 = set_role(JID, participant, SD1),
		send_update_presence(JID, Reason, SD2, SD),
		maybe_send_affiliation(JID, member, SD2),
		SD2;
	    {JID, role, Role, Reason} ->
		SD1 = set_role(JID, Role, SD),
		catch send_new_presence(JID, Reason, SD1, SD),
		SD1;
	    {JID, affiliation, A, _Reason} ->
		SD1 = set_affiliation(JID, A, SD),
		send_update_presence(JID, SD1, SD),
		maybe_send_affiliation(JID, A, SD1),
		SD1
	end
    catch E:R ->
	    ?ERROR_MSG("failed to set item ~p from ~s: ~p",
		       [Item, jid:to_string(UJID),
			{E, {R, erlang:get_stacktrace()}}]),
	    SD
    end.

-spec find_changed_items(jid(), affiliation(), role(),
			 [muc_item()], binary(), state(), [admin_action()]) ->
				{result, [admin_action()]}.
find_changed_items(_UJID, _UAffiliation, _URole, [],
		   _Lang, _StateData, Res) ->
    {result, Res};
find_changed_items(_UJID, _UAffiliation, _URole,
		   [#muc_item{jid = undefined, nick = undefined}|_],
		   Lang, _StateData, _Res) ->
    Txt = <<"Neither 'jid' nor 'nick' attribute found">>,
    throw({error, xmpp:err_bad_request(Txt, Lang)});
find_changed_items(_UJID, _UAffiliation, _URole,
		   [#muc_item{role = undefined, affiliation = undefined}|_],
		   Lang, _StateData, _Res) ->
    Txt = <<"Neither 'role' nor 'affiliation' attribute found">>,
    throw({error, xmpp:err_bad_request(Txt, Lang)});
find_changed_items(UJID, UAffiliation, URole,
		   [#muc_item{jid = J, nick = Nick, reason = Reason0,
			      role = Role, affiliation = Affiliation}|Items],
		   Lang, StateData, Res) ->
    [JID | _] = JIDs = 
	if J /= undefined ->
		[J];
	   Nick /= undefined ->
		case find_jids_by_nick(Nick, StateData) of
		    [] ->
			ErrText = iolist_to_binary(
				    io_lib:format(
				      translate:translate(
					Lang,
					<<"Nickname ~s does not exist in the room">>),
				      [Nick])),
			throw({error, xmpp:err_not_acceptable(ErrText, Lang)});
		    JIDList ->
			JIDList
		end
	end,
    {RoleOrAff, RoleOrAffValue} = if Role == undefined ->
					  {affiliation, Affiliation};
				     true ->
					  {role, Role}
				  end,
    TAffiliation = get_affiliation(JID, StateData),
    TRole = get_role(JID, StateData),
    ServiceAf = get_service_affiliation(JID, StateData),
    CanChangeRA = case can_change_ra(UAffiliation,
				     URole,
				     TAffiliation,
				     TRole, RoleOrAff, RoleOrAffValue,
				     ServiceAf) of
		      nothing -> nothing;
		      true -> true;
		      check_owner ->
			  case search_affiliation(owner, StateData) of
			      [{OJID, _}] ->
				  jid:remove_resource(OJID)
				      /=
				      jid:tolower(jid:remove_resource(UJID));
			      _ -> true
			  end;
		      _ -> false
		  end,
    case CanChangeRA of
	nothing ->
	    find_changed_items(UJID, UAffiliation, URole,
			       Items, Lang, StateData,
			       Res);
	true ->
	    Reason = if is_binary(Reason0) -> Reason0;
			true -> <<"">>
		     end,
	    MoreRes = [{jid:remove_resource(Jidx),
			RoleOrAff, RoleOrAffValue, Reason}
		       || Jidx <- JIDs],
	    find_changed_items(UJID, UAffiliation, URole,
			       Items, Lang, StateData,
			       [MoreRes | Res]);
	false ->
	    Txt = <<"Changing role/affiliation is not allowed">>,
	    throw({error, xmpp:err_not_allowed(Txt, Lang)})
    end.

-spec can_change_ra(affiliation(), role(), affiliation(), role(),
		    affiliation, affiliation(), affiliation()) -> boolean();
		   (affiliation(), role(), affiliation(), role(),
		    role, role(), affiliation()) -> boolean().
can_change_ra(_FAffiliation, _FRole, owner, _TRole,
	      affiliation, owner, owner) ->
    %% A room owner tries to add as persistent owner a
    %% participant that is already owner because he is MUC admin
    true;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, _RoleorAffiliation, _Value, owner) ->
    %% Nobody can decrease MUC admin's role/affiliation
    false;
can_change_ra(_FAffiliation, _FRole, TAffiliation,
	      _TRole, affiliation, Value, _ServiceAf)
    when TAffiliation == Value ->
    nothing;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      TRole, role, Value, _ServiceAf)
    when TRole == Value ->
    nothing;
can_change_ra(FAffiliation, _FRole, outcast, _TRole,
	      affiliation, none, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, outcast, _TRole,
	      affiliation, member, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, outcast, _TRole,
	      affiliation, admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, outcast, _TRole,
	      affiliation, owner, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, none, _TRole,
	      affiliation, outcast, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, none, _TRole,
	      affiliation, member, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, none, _TRole, affiliation,
	      admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, none, _TRole, affiliation,
	      owner, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, member, _TRole,
	      affiliation, outcast, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, member, _TRole,
	      affiliation, none, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, member, _TRole,
	      affiliation, admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, member, _TRole,
	      affiliation, owner, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, admin, _TRole, affiliation,
	      _Affiliation, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, owner, _TRole, affiliation,
	      _Affiliation, _ServiceAf) ->
    check_owner;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, affiliation, _Value, _ServiceAf) ->
    false;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      visitor, role, none, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      visitor, role, participant, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, _TAffiliation,
	      visitor, role, moderator, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      participant, role, none, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      participant, role, visitor, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, _TAffiliation,
	      participant, role, moderator, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(_FAffiliation, _FRole, owner, moderator,
	      role, visitor, _ServiceAf) ->
    false;
can_change_ra(owner, _FRole, _TAffiliation, moderator,
	      role, visitor, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, admin, moderator,
	      role, visitor, _ServiceAf) ->
    false;
can_change_ra(admin, _FRole, _TAffiliation, moderator,
	      role, visitor, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, owner, moderator,
	      role, participant, _ServiceAf) ->
    false;
can_change_ra(owner, _FRole, _TAffiliation, moderator,
	      role, participant, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, admin, moderator,
	      role, participant, _ServiceAf) ->
    false;
can_change_ra(admin, _FRole, _TAffiliation, moderator,
	      role, participant, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, role, _Value, _ServiceAf) ->
    false.

-spec send_kickban_presence(jid(), jid(), binary(),
			    pos_integer(), state()) -> ok.
send_kickban_presence(UJID, JID, Reason, Code, StateData) ->
    NewAffiliation = get_affiliation(JID, StateData),
    send_kickban_presence(UJID, JID, Reason, Code, NewAffiliation,
			  StateData).

-spec send_kickban_presence(jid(), jid(), binary(), pos_integer(),
			    affiliation(), state()) -> ok.
send_kickban_presence(UJID, JID, Reason, Code, NewAffiliation,
		      StateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    lists:foreach(fun (J) ->
			  {ok, #user{nick = Nick}} = (?DICT):find(J,
								  StateData#state.users),
			  add_to_log(kickban, {Nick, Reason, Code}, StateData),
			  tab_remove_online_user(J, StateData),
			  send_kickban_presence1(UJID, J, Reason, Code,
						 NewAffiliation, StateData)
		  end,
		  LJIDs).

-spec send_kickban_presence1(jid(), jid(), binary(), pos_integer(),
			     affiliation(), state()) -> ok.
send_kickban_presence1(MJID, UJID, Reason, Code, Affiliation,
		       StateData) ->
    {ok, #user{jid = RealJID, nick = Nick}} =
	(?DICT):find(jid:tolower(UJID),
		     StateData#state.users),
    ActorNick = get_actor_nick(MJID, StateData),
    lists:foreach(
      fun({_LJID, Info}) ->
	      Item0 = #muc_item{affiliation = Affiliation,
				role = none},
	      Item1 = case Info#user.role == moderator orelse
			  (StateData#state.config)#config.anonymous
			  == false of
			  true -> Item0#muc_item{jid = RealJID};
			  false -> Item0
		      end,
	      Item2 = if is_binary(Reason), Reason /= <<"">> ->
			      Item1#muc_item{reason = Reason};
			 true ->
			      Item1
		      end,
	      Item = case ActorNick of
			 <<"">> -> Item2;
			 _ -> Item2#muc_item{actor = #muc_actor{nick = ActorNick}}
		     end,
	      Packet = #presence{type = unavailable,
				 sub_els = [#muc_user{items = [Item],
						      status_codes = [Code]}]},
	      RoomJIDNick = jid:replace_resource(StateData#state.jid, Nick),
	      send_wrapped(RoomJIDNick, Info#user.jid, Packet,
			   ?NS_MUCSUB_NODES_AFFILIATIONS, StateData),
	      IsSubscriber = Info#user.is_subscriber,
	      IsOccupant = Info#user.last_presence /= undefined,
	      if (IsSubscriber and not IsOccupant) ->
		      send_wrapped(RoomJIDNick, Info#user.jid, Packet,
				   ?NS_MUCSUB_NODES_PARTICIPANTS, StateData);
		 true ->
		      ok
	      end
      end,
      (?DICT):to_list(StateData#state.users)).

-spec get_actor_nick(binary() | jid(), state()) -> binary().
get_actor_nick(<<"">>, _StateData) ->
    <<"">>;
get_actor_nick(MJID, StateData) ->
    case (?DICT):find(jid:tolower(MJID), StateData#state.users) of
	{ok, #user{nick = ActorNick}} -> ActorNick;
	_ -> <<"">>
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Owner stuff
-spec process_iq_owner(jid(), iq(), state()) ->
			      {result, undefined | muc_owner()} |
			      {result, undefined | muc_owner(), state() | stop} |
			      {error, error()}.
process_iq_owner(From, #iq{type = set, lang = Lang,
			   sub_els = [#muc_owner{destroy = Destroy,
						 config = Config,
						 items = Items}]},
		 StateData) ->
    FAffiliation = get_affiliation(From, StateData),
    if FAffiliation /= owner ->
	    ErrText = <<"Owner privileges required">>,
	    {error, xmpp:err_forbidden(ErrText, Lang)};
       Destroy /= undefined, Config == undefined, Items == [] ->
	    ?INFO_MSG("Destroyed MUC room ~s by the owner ~s",
		      [jid:to_string(StateData#state.jid), jid:to_string(From)]),
	    add_to_log(room_existence, destroyed, StateData),
	    destroy_room(Destroy, StateData);
       Config /= undefined, Destroy == undefined, Items == [] ->
	    case Config of
		#xdata{type = cancel} ->
		    {result, undefined};
		#xdata{type = submit} ->
		    case is_allowed_log_change(Config, StateData, From) andalso
			is_allowed_persistent_change(Config, StateData, From) andalso
			is_allowed_room_name_desc_limits(Config, StateData) andalso
			is_password_settings_correct(Config, StateData) of
			true -> set_config(Config, StateData, Lang);
			false -> {error, xmpp:err_not_acceptable()}
		    end;
		_ ->
		    Txt = <<"Incorrect data form">>,
		    {error, xmpp:err_bad_request(Txt, Lang)}
	    end;
       Items /= [], Config == undefined, Destroy == undefined ->
	    process_admin_items_set(From, Items, Lang, StateData);
       true ->
	    {error, xmpp:err_bad_request()}
    end;
process_iq_owner(From, #iq{type = get, lang = Lang,
			   sub_els = [#muc_owner{destroy = Destroy,
						 config = Config,
						 items = Items}]},
		 StateData) ->
    FAffiliation = get_affiliation(From, StateData),
    if FAffiliation /= owner ->
	    ErrText = <<"Owner privileges required">>,
	    {error, xmpp:err_forbidden(ErrText, Lang)};
       Destroy == undefined, Config == undefined ->
	    case Items of
		[] ->
		    {result,
		     #muc_owner{config = get_config(Lang, StateData, From)}};
		[#muc_item{affiliation = undefined}] ->
		    Txt = <<"No 'affiliation' attribute found">>,
		    {error, xmpp:err_bad_request(Txt, Lang)};
		[#muc_item{affiliation = Affiliation}] ->
		    Items = items_with_affiliation(Affiliation, StateData),
		    {result, #muc_owner{items = Items}};
		[_|_] ->
		    Txt = <<"Too many <item/> elements">>,
		    {error, xmpp:err_bad_request(Txt, Lang)}
	    end;
       true ->
	    {error, xmpp:err_bad_request()}
    end.

-spec is_allowed_log_change(xdata(), state(), jid()) -> boolean().
is_allowed_log_change(X, StateData, From) ->
    case xmpp_util:has_xdata_var(<<"muc#roomconfig_enablelogging">>, X) of
	false -> true;
	true ->
	    allow ==
		mod_muc_log:check_access_log(StateData#state.server_host,
					     From)
    end.

-spec is_allowed_persistent_change(xdata(), state(), jid()) -> boolean().
is_allowed_persistent_change(X, StateData, From) ->
    case xmpp_util:has_xdata_var(<<"muc#roomconfig_persistentroom">>, X) of
      false -> true;
      true ->
	  {_AccessRoute, _AccessCreate, _AccessAdmin,
	   AccessPersistent} =
	      StateData#state.access,
	  allow ==
	    acl:match_rule(StateData#state.server_host,
			   AccessPersistent, From)
    end.

%% Check if the Room Name and Room Description defined in the Data Form
%% are conformant to the configured limits
-spec is_allowed_room_name_desc_limits(xdata(), state()) -> boolean().
is_allowed_room_name_desc_limits(XData, StateData) ->
    IsNameAccepted = case xmpp_util:get_xdata_values(
			    <<"muc#roomconfig_roomname">>, XData) of
			 [N] ->
			     byte_size(N) =<
				 gen_mod:get_module_opt(
				   StateData#state.server_host,
				   mod_muc, max_room_name,
				   fun(infinity) -> infinity;
				      (I) when is_integer(I),
					       I>0 -> I
				   end, infinity);
			 _ ->
			     true
		     end,
    IsDescAccepted = case xmpp_util:get_xdata_values(
			    <<"muc#roomconfig_roomdesc">>, XData) of
			 [D] ->
			     byte_size(D) =<
				 gen_mod:get_module_opt(
				   StateData#state.server_host,
				   mod_muc, max_room_desc,
				   fun(infinity) -> infinity;
				      (I) when is_integer(I),
					       I>0 ->
					   I
				   end, infinity);
			 _ -> true
		     end,
    IsNameAccepted and IsDescAccepted.

%% Return false if:
%% "the password for a password-protected room is blank"
-spec is_password_settings_correct(xdata(), state()) -> boolean().
is_password_settings_correct(XData, StateData) ->
    Config = StateData#state.config,
    OldProtected = Config#config.password_protected,
    OldPassword = Config#config.password,
    NewProtected = case xmpp_util:get_xdata_values(
			  <<"muc#roomconfig_passwordprotectedroom">>, XData) of
		       [<<"1">>] -> true;
		       [<<"true">>] -> true;
		       [<<"0">>] -> false;
		       [<<"false">>] -> false;
		       _ -> undefined
		   end,
    NewPassword = case xmpp_util:get_xdata_values(
			 <<"muc#roomconfig_roomsecret">>, XData) of
		      [P] -> P;
		      _ -> undefined
		  end,
    case {OldProtected, NewProtected, OldPassword,
	  NewPassword}
	of
      {true, undefined, <<"">>, undefined} -> false;
      {true, undefined, _, <<"">>} -> false;
      {_, true, <<"">>, undefined} -> false;
      {_, true, _, <<"">>} -> false;
      _ -> true
    end.

-define(XFIELD(Type, Label, Var, Vals),
	#xdata_field{type = Type,
		     label = translate:translate(Lang, Label),
		     var = Var,
		     values = Vals}).

-define(BOOLXFIELD(Label, Var, Val),
	?XFIELD(boolean, Label, Var,
		case Val of
		  true -> [<<"1">>];
		  _ -> [<<"0">>]
		end)).

-define(STRINGXFIELD(Label, Var, Val),
	?XFIELD('text-single', Label, Var, [Val])).

-define(PRIVATEXFIELD(Label, Var, Val),
	?XFIELD('text-private', Label, Var, [Val])).

-define(JIDMULTIXFIELD(Label, Var, JIDList),
	?XFIELD('jid-multi', Label, Var,
		[jid:to_string(JID) || JID <- JIDList])).

-spec make_options([{binary(), binary()}], binary()) -> [xdata_option()].
make_options(Options, Lang) ->
    [#xdata_option{label = translate:translate(Lang, Label),
		   value = Value} || {Label, Value} <- Options].

-spec get_default_room_maxusers(state()) -> non_neg_integer().
get_default_room_maxusers(RoomState) ->
    DefRoomOpts =
	gen_mod:get_module_opt(RoomState#state.server_host,
			       mod_muc, default_room_options,
                               fun(L) when is_list(L) -> L end,
                               []),
    RoomState2 = set_opts(DefRoomOpts, RoomState),
    (RoomState2#state.config)#config.max_users.

-spec get_config(binary(), state(), jid()) -> xdata().
get_config(Lang, StateData, From) ->
    {_AccessRoute, _AccessCreate, _AccessAdmin, AccessPersistent} =
	StateData#state.access,
    ServiceMaxUsers = get_service_max_users(StateData),
    DefaultRoomMaxUsers = get_default_room_maxusers(StateData),
    Config = StateData#state.config,
    {MaxUsersRoomInteger, MaxUsersRoomString} =
	case get_max_users(StateData) of
	    N when is_integer(N) ->
		{N, integer_to_binary(N)};
	    _ -> {0, <<"none">>}
	end,
    Title = iolist_to_binary(
	      io_lib:format(
		translate:translate(Lang, <<"Configuration of room ~s">>),
		[jid:to_string(StateData#state.jid)])),
    Fs = [#xdata_field{type = hidden,
		       var = <<"FORM_TYPE">>,
		       values = [<<"http://jabber.org/protocol/muc#roomconfig">>]},
	  ?STRINGXFIELD(<<"Room title">>,
			<<"muc#roomconfig_roomname">>, (Config#config.title)),
	  ?STRINGXFIELD(<<"Room description">>,
			<<"muc#roomconfig_roomdesc">>,
			(Config#config.description))] ++
	case acl:match_rule(StateData#state.server_host, AccessPersistent, From) of
	    allow ->
		[?BOOLXFIELD(<<"Make room persistent">>,
			     <<"muc#roomconfig_persistentroom">>,
			     (Config#config.persistent))];
	    deny -> []
	end ++
	[?BOOLXFIELD(<<"Make room public searchable">>,
		     <<"muc#roomconfig_publicroom">>,
		     (Config#config.public)),
	 ?BOOLXFIELD(<<"Make participants list public">>,
		     <<"public_list">>, (Config#config.public_list)),
	 ?BOOLXFIELD(<<"Make room password protected">>,
		     <<"muc#roomconfig_passwordprotectedroom">>,
		     (Config#config.password_protected)),
	 ?PRIVATEXFIELD(<<"Password">>,
			<<"muc#roomconfig_roomsecret">>,
			case Config#config.password_protected of
			    true -> Config#config.password;
			    false -> <<"">>
			end),
	 #xdata_field{type = 'list-single',
		      label = translate:translate(
				Lang, <<"Maximum Number of Occupants">>),
		      var = <<"muc#roomconfig_maxusers">>,
		      values = [MaxUsersRoomString],
		      options =
			  if is_integer(ServiceMaxUsers) -> [];
			     true -> make_options(
				       [{<<"No limit">>, <<"none">>}],
				       Lang)
			  end ++
			  make_options(
			    [{integer_to_binary(N), integer_to_binary(N)}
			     || N <- lists:usort([ServiceMaxUsers,
						  DefaultRoomMaxUsers,
						  MaxUsersRoomInteger
						  | ?MAX_USERS_DEFAULT_LIST]),
				N =< ServiceMaxUsers],
			    Lang)},
	 #xdata_field{type = 'list-single',
		      label = translate:translate(
				Lang, <<"Present real Jabber IDs to">>),
		      var = <<"muc#roomconfig_whois">>,
		      values = [if Config#config.anonymous -> <<"moderators">>;
				   true -> <<"anyone">>
				end],
		      options = make_options(
				  [{<<"moderators only">>, <<"moderators">>},
				   {<<"anyone">>, <<"anyone">>}],
				  Lang)},
	 #xdata_field{type = 'list-multi',
		      label = translate:translate(
				Lang,
				<<"Roles for which Presence is Broadcasted">>),
		      var = <<"muc#roomconfig_presencebroadcast">>,
		      values = [atom_to_binary(Role, utf8)
				|| Role <- Config#config.presence_broadcast],
		      options = make_options(
				  [{<<"Moderator">>, <<"moderator">>},
				   {<<"Participant">>, <<"participant">>},
				   {<<"Visitor">>, <<"visitor">>}],
				  Lang)},
	 ?BOOLXFIELD(<<"Make room members-only">>,
		     <<"muc#roomconfig_membersonly">>,
		     (Config#config.members_only)),
	 ?BOOLXFIELD(<<"Make room moderated">>,
		     <<"muc#roomconfig_moderatedroom">>,
		     (Config#config.moderated)),
	 ?BOOLXFIELD(<<"Default users as participants">>,
		     <<"members_by_default">>,
		     (Config#config.members_by_default)),
	 ?BOOLXFIELD(<<"Allow users to change the subject">>,
		     <<"muc#roomconfig_changesubject">>,
		     (Config#config.allow_change_subj)),
	 ?BOOLXFIELD(<<"Allow users to send private messages">>,
		     <<"allow_private_messages">>,
		     (Config#config.allow_private_messages)),
	 #xdata_field{type = 'list-single',
		      label = translate:translate(
				Lang,
				<<"Allow visitors to send private messages to">>),
		      var = <<"allow_private_messages_from_visitors">>,
		      values = [case Config#config.allow_private_messages_from_visitors of
				    anyone -> <<"anyone">>;
				    moderators -> <<"moderators">>;
				    nobody -> <<"nobody">>
				end],
		      options = make_options(
				  [{<<"nobody">>, <<"nobody">>},
				   {<<"moderators only">>, <<"moderators">>},
				   {<<"anyone">>, <<"anyone">>}],
				  Lang)},
	 ?BOOLXFIELD(<<"Allow users to query other users">>,
		     <<"allow_query_users">>,
		     (Config#config.allow_query_users)),
	 ?BOOLXFIELD(<<"Allow users to send invites">>,
		     <<"muc#roomconfig_allowinvites">>,
		     (Config#config.allow_user_invites)),
	 ?BOOLXFIELD(<<"Allow visitors to send status text in "
		       "presence updates">>,
		     <<"muc#roomconfig_allowvisitorstatus">>,
		     (Config#config.allow_visitor_status)),
	 ?BOOLXFIELD(<<"Allow visitors to change nickname">>,
		     <<"muc#roomconfig_allowvisitornickchange">>,
		     (Config#config.allow_visitor_nickchange)),
	 ?BOOLXFIELD(<<"Allow visitors to send voice requests">>,
		     <<"muc#roomconfig_allowvoicerequests">>,
		     (Config#config.allow_voice_requests)),
	 ?BOOLXFIELD(<<"Allow subscription">>,
		     <<"muc#roomconfig_allow_subscription">>,
		     (Config#config.allow_subscription)),
	 ?STRINGXFIELD(<<"Minimum interval between voice requests "
			 "(in seconds)">>,
		       <<"muc#roomconfig_voicerequestmininterval">>,
		       integer_to_binary(Config#config.voice_request_min_interval))]
	++
	case ejabberd_captcha:is_feature_available() of
	    true ->
		[?BOOLXFIELD(<<"Make room CAPTCHA protected">>,
			     <<"captcha_protected">>,
			     (Config#config.captcha_protected))];
	    false -> []
	end ++
	[?JIDMULTIXFIELD(<<"Exclude Jabber IDs from CAPTCHA challenge">>,
			 <<"muc#roomconfig_captcha_whitelist">>,
			 ((?SETS):to_list(Config#config.captcha_whitelist)))]
	++
	case mod_muc_log:check_access_log(StateData#state.server_host, From) of
	    allow ->
		[?BOOLXFIELD(<<"Enable logging">>,
			     <<"muc#roomconfig_enablelogging">>,
			     (Config#config.logging))];
	    deny -> []
	end,
    Fields = ejabberd_hooks:run_fold(get_room_config,
				     StateData#state.server_host,
				     Fs,
				     [StateData, From, Lang]),
    #xdata{type = form, title = Title, fields = Fields}.

-spec set_config(xdata(), state(), binary()) -> {error, error()} |
						{result, undefined, state()}.
set_config(#xdata{fields = Fields}, StateData, Lang) ->
    Options = [{Var, Vals} || #xdata_field{var = Var, values = Vals} <- Fields],
    case set_xoption(Options, StateData#state.config,
		     StateData#state.server_host, Lang) of
	#config{} = Config ->
	    Res = change_config(Config, StateData),
	    {result, _, NSD} = Res,
	    Type = case {(StateData#state.config)#config.logging,
			 Config#config.logging}
		   of
		       {true, false} -> roomconfig_change_disabledlogging;
		       {false, true} -> roomconfig_change_enabledlogging;
		       {_, _} -> roomconfig_change
		   end,
	    Users = [{U#user.jid, U#user.nick, U#user.role}
		     || {_, U} <- (?DICT):to_list(StateData#state.users)],
	    add_to_log(Type, Users, NSD),
	    Res;
	Err -> Err
    end.

-define(SET_BOOL_XOPT(Opt, Val),
	case Val of
	  <<"0">> ->
	      set_xoption(Opts, Config#config{Opt = false}, ServerHost, Lang);
	  <<"false">> ->
	      set_xoption(Opts, Config#config{Opt = false}, ServerHost, Lang);
	  <<"1">> -> set_xoption(Opts, Config#config{Opt = true}, ServerHost, Lang);
	  <<"true">> ->
	      set_xoption(Opts, Config#config{Opt = true}, ServerHost, Lang);
	  _ ->
	      Txt = <<"Value of '~s' should be boolean">>,
	      ErrTxt = iolist_to_binary(io_lib:format(Txt, [Opt])),
	      {error, xmpp:err_bad_request(ErrTxt, Lang)}
	end).

-define(SET_NAT_XOPT(Opt, Val),
	case catch binary_to_integer(Val) of
	  I when is_integer(I), I > 0 ->
	      set_xoption(Opts, Config#config{Opt = I}, ServerHost, Lang);
	  _ ->
	      Txt = <<"Value of '~s' should be integer">>,
	      ErrTxt = iolist_to_binary(io_lib:format(Txt, [Opt])),
	      {error, xmpp:err_bad_request(ErrTxt, Lang)}
	end).

-define(SET_STRING_XOPT(Opt, Vals),
	try 
	    V = case Vals of
		    [] -> <<"">>;
		    [Val] -> Val;
		    _ when is_atom(Vals) -> Vals
		end,
	    set_xoption(Opts, Config#config{Opt = V}, ServerHost, Lang)
	catch _:_ ->
		Txt = <<"Incorrect value of option '~s'">>,
		ErrTxt = iolist_to_binary(io_lib:format(Txt, [Opt])),
		{error, xmpp:err_bad_request(ErrTxt, Lang)}
	end).

-define(SET_JIDMULTI_XOPT(Opt, Vals),
	begin
	  Set = lists:foldl(fun ({U, S, R}, Set1) ->
				    (?SETS):add_element({U, S, R}, Set1);
				(#jid{luser = U, lserver = S, lresource = R},
				 Set1) ->
				    (?SETS):add_element({U, S, R}, Set1);
				(_, Set1) -> Set1
			    end,
			    (?SETS):empty(), Vals),
	  set_xoption(Opts, Config#config{Opt = Set}, ServerHost, Lang)
	end).

-spec set_xoption([{binary(), [binary()]}], #config{},
		  binary(), binary()) -> #config{} | {error, error()}.
set_xoption([], Config, _ServerHost, _Lang) -> Config;
set_xoption([{<<"muc#roomconfig_roomname">>, Vals}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_STRING_XOPT(title, Vals);
set_xoption([{<<"muc#roomconfig_roomdesc">>, Vals}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_STRING_XOPT(description, Vals);
set_xoption([{<<"muc#roomconfig_changesubject">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_change_subj, Val);
set_xoption([{<<"allow_query_users">>, [Val]} | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_query_users, Val);
set_xoption([{<<"allow_private_messages">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_private_messages, Val);
set_xoption([{<<"allow_private_messages_from_visitors">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    case Val of
      <<"anyone">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   anyone);
      <<"moderators">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   moderators);
      <<"nobody">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   nobody);
      _ ->
	  Txt = <<"Value of 'allow_private_messages_from_visitors' "
		  "should be anyone|moderators|nobody">>,
	  {error, xmpp:err_bad_request(Txt, Lang)}
    end;
set_xoption([{<<"muc#roomconfig_allowvisitorstatus">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_visitor_status, Val);
set_xoption([{<<"muc#roomconfig_allowvisitornickchange">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_visitor_nickchange, Val);
set_xoption([{<<"muc#roomconfig_publicroom">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(public, Val);
set_xoption([{<<"public_list">>, [Val]} | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(public_list, Val);
set_xoption([{<<"muc#roomconfig_persistentroom">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(persistent, Val);
set_xoption([{<<"muc#roomconfig_moderatedroom">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(moderated, Val);
set_xoption([{<<"members_by_default">>, [Val]} | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(members_by_default, Val);
set_xoption([{<<"muc#roomconfig_membersonly">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(members_only, Val);
set_xoption([{<<"captcha_protected">>, [Val]} | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(captcha_protected, Val);
set_xoption([{<<"muc#roomconfig_allowinvites">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_user_invites, Val);
set_xoption([{<<"muc#roomconfig_allow_subscription">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_subscription, Val);
set_xoption([{<<"muc#roomconfig_passwordprotectedroom">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(password_protected, Val);
set_xoption([{<<"muc#roomconfig_roomsecret">>, Vals}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_STRING_XOPT(password, Vals);
set_xoption([{<<"anonymous">>, [Val]} | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(anonymous, Val);
set_xoption([{<<"muc#roomconfig_presencebroadcast">>, Vals} | Opts],
	    Config, ServerHost, Lang) ->
    Roles =
        lists:foldl(
          fun(_S, error) -> error;
             (S, {M, P, V}) ->
                  case S of
                      <<"moderator">> -> {true, P, V};
                      <<"participant">> -> {M, true, V};
                      <<"visitor">> -> {M, P, true};
                      _ -> error
                  end
          end, {false, false, false}, Vals),
    case Roles of
        error ->
	    Txt = <<"Value of 'muc#roomconfig_presencebroadcast' should "
		    "be moderator|participant|visitor">>,
	    {error, xmpp:err_bad_request(Txt, Lang)};
        {M, P, V} ->
            Res =
                if M -> [moderator]; true -> [] end ++
                if P -> [participant]; true -> [] end ++
                if V -> [visitor]; true -> [] end,
            set_xoption(Opts, Config#config{presence_broadcast = Res},
			ServerHost, Lang)
    end;
set_xoption([{<<"muc#roomconfig_allowvoicerequests">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(allow_voice_requests, Val);
set_xoption([{<<"muc#roomconfig_voicerequestmininterval">>,
	      [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_NAT_XOPT(voice_request_min_interval, Val);
set_xoption([{<<"muc#roomconfig_whois">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    case Val of
      <<"moderators">> ->
	  ?SET_BOOL_XOPT(anonymous,
			 (iolist_to_binary(integer_to_list(1))));
      <<"anyone">> ->
	  ?SET_BOOL_XOPT(anonymous,
			 (iolist_to_binary(integer_to_list(0))));
      _ ->
	  Txt = <<"Value of 'muc#roomconfig_whois' should be "
		  "moderators|anyone">>,
	  {error, xmpp:err_bad_request(Txt, Lang)}
    end;
set_xoption([{<<"muc#roomconfig_maxusers">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    case Val of
      <<"none">> -> ?SET_STRING_XOPT(max_users, none);
      _ -> ?SET_NAT_XOPT(max_users, Val)
    end;
set_xoption([{<<"muc#roomconfig_enablelogging">>, [Val]}
	     | Opts],
	    Config, ServerHost, Lang) ->
    ?SET_BOOL_XOPT(logging, Val);
set_xoption([{<<"muc#roomconfig_captcha_whitelist">>,
	      Vals}
	     | Opts],
	    Config, ServerHost, Lang) ->
    JIDs = [jid:from_string(Val) || Val <- Vals],
    ?SET_JIDMULTI_XOPT(captcha_whitelist, JIDs);
set_xoption([{<<"FORM_TYPE">>, _} | Opts], Config, ServerHost, Lang) ->
    set_xoption(Opts, Config, ServerHost, Lang);
set_xoption([{Opt, Vals} | Opts], Config, ServerHost, Lang) ->
    Txt = <<"Unknown option '~s'">>,
    ErrTxt = iolist_to_binary(io_lib:format(Txt, [Opt])),
    Err = {error, xmpp:err_bad_request(ErrTxt, Lang)},
    case ejabberd_hooks:run_fold(set_room_option,
				 ServerHost,
				 Err,
				 [Opt, Vals, Lang]) of
	{error, Reason} ->
	    {error, Reason};
	{Pos, Val} ->
	    set_xoption(Opts, setelement(Pos, Config, Val), ServerHost, Lang)
    end.

-spec change_config(#config{}, state()) -> {result, undefined, state()}.
change_config(Config, StateData) ->
    send_config_change_info(Config, StateData),
    NSD = remove_subscriptions(StateData#state{config = Config}),
    case {(StateData#state.config)#config.persistent,
	  Config#config.persistent}
	of
      {_, true} ->
	  mod_muc:store_room(NSD#state.server_host,
			     NSD#state.host, NSD#state.room, make_opts(NSD));
      {true, false} ->
	  mod_muc:forget_room(NSD#state.server_host,
			      NSD#state.host, NSD#state.room);
      {false, false} -> ok
    end,
    case {(StateData#state.config)#config.members_only,
	  Config#config.members_only}
	of
      {false, true} ->
	  NSD1 = remove_nonmembers(NSD), {result, undefined, NSD1};
      _ -> {result, undefined, NSD}
    end.

-spec send_config_change_info(#config{}, state()) -> ok.
send_config_change_info(Config, #state{config = Config}) -> ok;
send_config_change_info(New, #state{config = Old} = StateData) ->
    Codes = case {Old#config.logging, New#config.logging} of
	      {false, true} -> [170];
	      {true, false} -> [171];
	      _ -> []
	    end
	      ++
	      case {Old#config.anonymous, New#config.anonymous} of
		{true, false} -> [172];
		{false, true} -> [173];
		_ -> []
	      end
		++
		case Old#config{anonymous = New#config.anonymous,
				logging = New#config.logging} of
		  New -> [];
		  _ -> [104]
		end,
    Message = #message{type = groupchat,
		       id = randoms:get_string(),
		       sub_els = [#muc_user{status_codes = Codes}]},
    send_wrapped_multiple(StateData#state.jid,
			  StateData#state.users,
			  Message,
			  ?NS_MUCSUB_NODES_CONFIG,
			  StateData).

-spec remove_nonmembers(state()) -> state().
remove_nonmembers(StateData) ->
    lists:foldl(fun ({_LJID, #user{jid = JID}}, SD) ->
			Affiliation = get_affiliation(JID, SD),
			case Affiliation of
			  none ->
			      catch send_kickban_presence(<<"">>, JID, <<"">>,
							  322, SD),
			      set_role(JID, none, SD);
			  _ -> SD
			end
		end,
		StateData, (?DICT):to_list(StateData#state.users)).

-spec set_opts([{atom(), any()}], state()) -> state().
set_opts([], StateData) -> StateData;
set_opts([{Opt, Val} | Opts], StateData) ->
    NSD = case Opt of
	    title ->
		StateData#state{config =
				    (StateData#state.config)#config{title =
									Val}};
	    description ->
		StateData#state{config =
				    (StateData#state.config)#config{description
									= Val}};
	    allow_change_subj ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_change_subj
									= Val}};
	    allow_query_users ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_query_users
									= Val}};
	    allow_private_messages ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_private_messages
									= Val}};
	    allow_private_messages_from_visitors ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_private_messages_from_visitors
									= Val}};
	    allow_visitor_nickchange ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_visitor_nickchange
									= Val}};
	    allow_visitor_status ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_visitor_status
									= Val}};
	    public ->
		StateData#state{config =
				    (StateData#state.config)#config{public =
									Val}};
	    public_list ->
		StateData#state{config =
				    (StateData#state.config)#config{public_list
									= Val}};
	    persistent ->
		StateData#state{config =
				    (StateData#state.config)#config{persistent =
									Val}};
	    moderated ->
		StateData#state{config =
				    (StateData#state.config)#config{moderated =
									Val}};
	    members_by_default ->
		StateData#state{config =
				    (StateData#state.config)#config{members_by_default
									= Val}};
	    members_only ->
		StateData#state{config =
				    (StateData#state.config)#config{members_only
									= Val}};
	    allow_user_invites ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_user_invites
									= Val}};
	    password_protected ->
		StateData#state{config =
				    (StateData#state.config)#config{password_protected
									= Val}};
	    captcha_protected ->
		StateData#state{config =
				    (StateData#state.config)#config{captcha_protected
									= Val}};
	    password ->
		StateData#state{config =
				    (StateData#state.config)#config{password =
									Val}};
	    anonymous ->
		StateData#state{config =
				    (StateData#state.config)#config{anonymous =
									Val}};
	    presence_broadcast ->
		StateData#state{config =
				    (StateData#state.config)#config{presence_broadcast =
									Val}};
	    logging ->
		StateData#state{config =
				    (StateData#state.config)#config{logging =
									Val}};
	    mam ->
		StateData#state{config =
				    (StateData#state.config)#config{mam = Val}};
	    captcha_whitelist ->
		StateData#state{config =
				    (StateData#state.config)#config{captcha_whitelist
									=
									(?SETS):from_list(Val)}};
	    allow_voice_requests ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_voice_requests
									= Val}};
	    voice_request_min_interval ->
		StateData#state{config =
				    (StateData#state.config)#config{voice_request_min_interval
									= Val}};
	    max_users ->
		ServiceMaxUsers = get_service_max_users(StateData),
		MaxUsers = if Val =< ServiceMaxUsers -> Val;
			      true -> ServiceMaxUsers
			   end,
		StateData#state{config =
				    (StateData#state.config)#config{max_users =
									MaxUsers}};
	    vcard ->
		StateData#state{config =
				    (StateData#state.config)#config{vcard =
									Val}};
	    allow_subscription ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_subscription = Val}};
	    subscribers ->
		lists:foldl(
		  fun({JID, Nick, Nodes}, State) ->
			  User = #user{jid = JID, nick = Nick,
				       subscriptions = Nodes,
				       is_subscriber = true,
				       role = none},
			  update_online_user(JID, User, State)
		  end, StateData, Val);
	    affiliations ->
		StateData#state{affiliations = (?DICT):from_list(Val)};
	    subject -> StateData#state{subject = Val};
	    subject_author -> StateData#state{subject_author = Val};
	    _ -> StateData
	  end,
    set_opts(Opts, NSD).

-define(MAKE_CONFIG_OPT(Opt), {Opt, Config#config.Opt}).

-spec make_opts(state()) -> [{atom(), any()}].
make_opts(StateData) ->
    Config = StateData#state.config,
    Subscribers = (?DICT):fold(
		    fun(_LJID, #user{is_subscriber = true} = User, Acc) ->
			    [{User#user.jid, User#user.nick,
			      User#user.subscriptions}|Acc];
		       (_, _, Acc) ->
			    Acc
		    end, [], StateData#state.users),
    [?MAKE_CONFIG_OPT(title), ?MAKE_CONFIG_OPT(description),
     ?MAKE_CONFIG_OPT(allow_change_subj),
     ?MAKE_CONFIG_OPT(allow_query_users),
     ?MAKE_CONFIG_OPT(allow_private_messages),
     ?MAKE_CONFIG_OPT(allow_private_messages_from_visitors),
     ?MAKE_CONFIG_OPT(allow_visitor_status),
     ?MAKE_CONFIG_OPT(allow_visitor_nickchange),
     ?MAKE_CONFIG_OPT(public), ?MAKE_CONFIG_OPT(public_list),
     ?MAKE_CONFIG_OPT(persistent),
     ?MAKE_CONFIG_OPT(moderated),
     ?MAKE_CONFIG_OPT(members_by_default),
     ?MAKE_CONFIG_OPT(members_only),
     ?MAKE_CONFIG_OPT(allow_user_invites),
     ?MAKE_CONFIG_OPT(password_protected),
     ?MAKE_CONFIG_OPT(captcha_protected),
     ?MAKE_CONFIG_OPT(password), ?MAKE_CONFIG_OPT(anonymous),
     ?MAKE_CONFIG_OPT(logging), ?MAKE_CONFIG_OPT(max_users),
     ?MAKE_CONFIG_OPT(allow_voice_requests),
     ?MAKE_CONFIG_OPT(mam),
     ?MAKE_CONFIG_OPT(voice_request_min_interval),
     ?MAKE_CONFIG_OPT(vcard),
     {captcha_whitelist,
      (?SETS):to_list((StateData#state.config)#config.captcha_whitelist)},
     {affiliations,
      (?DICT):to_list(StateData#state.affiliations)},
     {subject, StateData#state.subject},
     {subject_author, StateData#state.subject_author},
     {subscribers, Subscribers}].

-spec destroy_room(muc_destroy(), state()) -> {result, undefined, stop}.
destroy_room(DEl, StateData) ->
    Destroy = DEl#muc_destroy{xmlns = ?NS_MUC_USER},
    lists:foreach(
      fun({_LJID, Info}) ->
	      Nick = Info#user.nick,
	      Item = #muc_item{affiliation = none,
			       role = none},
	      Packet = #presence{
			  type = unavailable,
			  sub_els = [#muc_user{items = [Item],
					       destroy = Destroy}]},
	      send_wrapped(jid:replace_resource(StateData#state.jid, Nick),
			   Info#user.jid, Packet,
			   ?NS_MUCSUB_NODES_CONFIG, StateData)
      end,
      (?DICT):to_list(StateData#state.users)),
    case (StateData#state.config)#config.persistent of
      true ->
	  mod_muc:forget_room(StateData#state.server_host,
			      StateData#state.host, StateData#state.room);
      false -> ok
    end,
    {result, undefined, stop}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Disco

-define(CONFIG_OPT_TO_FEATURE(Opt, Fiftrue, Fiffalse),
	case Opt of
	  true -> Fiftrue;
	  false -> Fiffalse
	end).

-spec process_iq_disco_info(jid(), iq(), state()) ->
				   {result, disco_info()} | {error, error()}.
process_iq_disco_info(_From, #iq{type = set, lang = Lang}, _StateData) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    {error, xmpp:err_not_allowed(Txt, Lang)};
process_iq_disco_info(_From, #iq{type = get, lang = Lang}, StateData) ->
    Config = StateData#state.config,
    Feats = [?NS_VCARD, ?NS_MUC,
	     ?CONFIG_OPT_TO_FEATURE((Config#config.public),
				    <<"muc_public">>, <<"muc_hidden">>),
	     ?CONFIG_OPT_TO_FEATURE((Config#config.persistent),
				    <<"muc_persistent">>, <<"muc_temporary">>),
	     ?CONFIG_OPT_TO_FEATURE((Config#config.members_only),
				    <<"muc_membersonly">>, <<"muc_open">>),
	     ?CONFIG_OPT_TO_FEATURE((Config#config.anonymous),
				    <<"muc_semianonymous">>, <<"muc_nonanonymous">>),
	     ?CONFIG_OPT_TO_FEATURE((Config#config.moderated),
				    <<"muc_moderated">>, <<"muc_unmoderated">>),
	     ?CONFIG_OPT_TO_FEATURE((Config#config.password_protected),
				    <<"muc_passwordprotected">>, <<"muc_unsecured">>)]
	++ case Config#config.allow_subscription of
	       true -> [?NS_MUCSUB];
	       false -> []
	   end
	++ case {gen_mod:is_loaded(StateData#state.server_host, mod_mam),
		 Config#config.mam} of
	       {true, true} ->
		   [?NS_MAM_TMP, ?NS_MAM_0, ?NS_MAM_1];
	       _ ->
		   []
	   end,
    {result, #disco_info{xdata = [iq_disco_info_extras(Lang, StateData)],
			 identities = [#identity{category = <<"conference">>,
						 type = <<"text">>,
						 name = get_title(StateData)}],
			 features = Feats}}.

-spec mk_rfieldt('boolean' | 'fixed' | 'hidden' |
		 'jid-multi' | 'jid-single' | 'list-multi' |
		 'list-single' | 'text-multi' | 'text-private' |
		 'text-single', binary(), binary()) -> xdata_field().
mk_rfieldt(Type, Var, Val) ->
    #xdata_field{type = Type, var = Var, values = [Val]}.

-spec mk_rfield(binary(), binary(), binary(), binary()) -> xdata_field().
mk_rfield(Label, Var, Val, Lang) ->
    #xdata_field{type = 'text-single',
		 label = translate:translate(Lang, Label),
		 var = Var,
		 values = [Val]}.

-spec iq_disco_info_extras(binary(), state()) -> xdata().
iq_disco_info_extras(Lang, StateData) ->
    Len = (?DICT):size(StateData#state.users),
    RoomDescription = (StateData#state.config)#config.description,
    #xdata{type = result,
	   fields = [mk_rfieldt(hidden, <<"FORM_TYPE">>,
				"http://jabber.org/protocol/muc#roominfo"),
		     mk_rfield(<<"Room description">>,
			       <<"muc#roominfo_description">>,
			       RoomDescription, Lang),
		     mk_rfield(<<"Number of occupants">>,
			       <<"muc#roominfo_occupants">>,
			       integer_to_binary(Len), Lang)]}.

-spec process_iq_disco_items(jid(), iq(), state()) ->
				    {error, error()} | {result, disco_items()}.
process_iq_disco_items(_From, #iq{type = set, lang = Lang}, _StateData) ->
    Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
    {error, xmpp:err_not_allowed(Txt, Lang)};
process_iq_disco_items(From, #iq{type = get, lang = Lang}, StateData) ->
    case (StateData#state.config)#config.public_list of
      true ->
	  {result, get_mucroom_disco_items(StateData)};
      _ ->
	  case is_occupant_or_admin(From, StateData) of
	    true ->
		{result, get_mucroom_disco_items(StateData)};
	    _ ->
	        Txt = <<"Only occupants or administrators can perform this query">>,
		{error, xmpp:err_forbidden(Txt, Lang)}
	  end
    end.

-spec process_iq_captcha(jid(), iq(), state()) -> {error, error()} |
						  {result, undefined}.
process_iq_captcha(_From, #iq{type = get, lang = Lang}, _StateData) ->
    Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
    {error, xmpp:err_not_allowed(Txt, Lang)};
process_iq_captcha(_From, #iq{type = set, lang = Lang, sub_els = [SubEl]},
		   _StateData) ->
    case ejabberd_captcha:process_reply(SubEl) of
      ok -> {result, undefined};
      {error, malformed} ->
	    Txt = <<"Incorrect CAPTCHA submit">>,
	    {error, xmpp:err_bad_request(Txt, Lang)};
      _ ->
	    Txt = <<"The CAPTCHA verification has failed">>,
	    {error, xmpp:err_not_allowed(Txt, Lang)}
    end.

-spec process_iq_vcard(jid(), iq(), state()) ->
			      {result, vcard_temp() | xmlel()} |
			      {result, undefined, state()} |
			      {error, error()}.
process_iq_vcard(_From, #iq{type = get}, StateData) ->
    #state{config = #config{vcard = VCardRaw}} = StateData,
    case fxml_stream:parse_element(VCardRaw) of
	#xmlel{} = VCard ->
	    {result, VCard};
	{error, _} ->
	    {result, #vcard_temp{}}
    end;
process_iq_vcard(From, #iq{type = set, lang = Lang, sub_els = [SubEl]},
		 StateData) ->
    case get_affiliation(From, StateData) of
	owner ->
	    VCardRaw = fxml:element_to_binary(xmpp:encode(SubEl)),
	    Config = StateData#state.config,
	    NewConfig = Config#config{vcard = VCardRaw},
	    change_config(NewConfig, StateData);
	_ ->
	    ErrText = <<"Owner privileges required">>,
	    {error, xmpp:err_forbidden(ErrText, Lang)}
    end.

-spec process_iq_mucsub(jid(), iq(), state()) ->
			       {error, error()} |
			       {result, undefined | muc_subscribe(), state()} |
			       {ignore, state()}.
process_iq_mucsub(_From, #iq{type = set, lang = Lang,
			     sub_els = [#muc_subscribe{}]},
		  #state{config = #config{allow_subscription = false}}) ->
    {error, xmpp:err_not_allowed(<<"Subscriptions are not allowed">>, Lang)};
process_iq_mucsub(From,
		  #iq{type = set, lang = Lang,
		      sub_els = [#muc_subscribe{nick = Nick}]} = Packet,
		  StateData) ->
    LJID = jid:tolower(From),
    case (?DICT):find(LJID, StateData#state.users) of
	{ok, #user{role = Role, nick = Nick1}} when Nick1 /= Nick ->
	    Nodes = get_subscription_nodes(Packet),
	    case {nick_collision(From, Nick, StateData),
		  mod_muc:can_use_nick(StateData#state.server_host,
				       StateData#state.host,
				       From, Nick)} of
		{true, _} ->
		    ErrText = <<"That nickname is already in use by another occupant">>,
		    {error, xmpp:err_conflict(ErrText, Lang)};
		{_, false} ->
		    ErrText = <<"That nickname is registered by another person">>,
		    {error, xmpp:err_conflict(ErrText, Lang)};
		_ ->
		    NewStateData = add_online_user(
				     From, Nick, Role, true, Nodes, StateData),
		    {result, subscribe_result(Packet), NewStateData}
	    end;
	{ok, #user{role = Role}} ->
	    Nodes = get_subscription_nodes(Packet),
	    NewStateData = add_online_user(
			     From, Nick, Role, true, Nodes, StateData),
	    {result, subscribe_result(Packet), NewStateData};
	error ->
	    add_new_user(From, Nick, Packet, StateData)
    end;
process_iq_mucsub(From, #iq{type = set, sub_els = [#muc_unsubscribe{}]},
		  StateData) ->
    LJID = jid:tolower(From),
    case ?DICT:find(LJID, StateData#state.users) of
	{ok, #user{is_subscriber = true} = User} ->
	    NewStateData = remove_subscription(From, User, StateData),
	    store_room(NewStateData),
	    {result, undefined, NewStateData};
	_ ->
	    {result, undefined, StateData}
    end;
process_iq_mucsub(_From, #iq{type = get, lang = Lang}, _StateData) ->
    Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
    {error, xmpp:err_bad_request(Txt, Lang)}.

-spec remove_subscription(jid(), #user{}, state()) -> state().
remove_subscription(JID, #user{is_subscriber = true} = User, StateData) ->
    case User#user.last_presence of
	undefined ->
	    remove_online_user(JID, StateData, false);
	_ ->
	    LJID = jid:tolower(JID),
	    Users = ?DICT:store(LJID, User#user{is_subscriber = false},
				StateData#state.users),
	    StateData#state{users = Users}
    end;
remove_subscription(_JID, #user{}, StateData) ->
    StateData.

-spec remove_subscriptions(state()) -> state().
remove_subscriptions(StateData) ->
    if not (StateData#state.config)#config.allow_subscription ->
	    dict:fold(
	      fun(_LJID, User, State) ->
		      remove_subscription(User#user.jid, User, State)
	      end, StateData, StateData#state.users);
       true ->
	    StateData
    end.

-spec get_subscription_nodes(iq()) -> [binary()].
get_subscription_nodes(#iq{sub_els = [#muc_subscribe{events = Nodes}]}) ->
    lists:filter(
      fun(Node) ->
	      lists:member(Node, [?NS_MUCSUB_NODES_PRESENCE,
				  ?NS_MUCSUB_NODES_MESSAGES,
				  ?NS_MUCSUB_NODES_AFFILIATIONS,
				  ?NS_MUCSUB_NODES_SUBJECT,
				  ?NS_MUCSUB_NODES_CONFIG,
				  ?NS_MUCSUB_NODES_PARTICIPANTS])
      end, Nodes);
get_subscription_nodes(_) ->
    [].

-spec subscribe_result(iq()) -> muc_subscribe().
subscribe_result(#iq{sub_els = [#muc_subscribe{nick = Nick}]} = Packet) ->
    #muc_subscribe{nick = Nick, events = get_subscription_nodes(Packet)}.

-spec get_title(state()) -> binary().
get_title(StateData) ->
    case (StateData#state.config)#config.title of
      <<"">> -> StateData#state.room;
      Name -> Name
    end.

-spec get_roomdesc_reply(jid(), state(), binary()) -> {item, binary()} | false.
get_roomdesc_reply(JID, StateData, Tail) ->
    IsOccupantOrAdmin = is_occupant_or_admin(JID,
					     StateData),
    if (StateData#state.config)#config.public or
	 IsOccupantOrAdmin ->
	   if (StateData#state.config)#config.public_list or
		IsOccupantOrAdmin ->
		  {item, <<(get_title(StateData))/binary,Tail/binary>>};
	      true -> {item, get_title(StateData)}
	   end;
       true -> false
    end.

-spec get_roomdesc_tail(state(), binary()) -> binary().
get_roomdesc_tail(StateData, Lang) ->
    Desc = case (StateData#state.config)#config.public of
	     true -> <<"">>;
	     _ -> translate:translate(Lang, <<"private, ">>)
	   end,
    Len = (?DICT):size(StateData#state.users),
    <<" (", Desc/binary,
      (iolist_to_binary(integer_to_list(Len)))/binary, ")">>.

-spec get_mucroom_disco_items(state()) -> disco_items().
get_mucroom_disco_items(StateData) ->
    Items = lists:map(
	      fun({_LJID, Info}) ->
		      Nick = Info#user.nick,
		      #disco_item{jid = jid:make(StateData#state.room,
						 StateData#state.host,
						 Nick),
				  name = Nick}
	      end,
	      (?DICT):to_list(StateData#state.users)),
    #disco_items{items = Items}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Voice request support

-spec is_voice_request(message()) -> boolean().
is_voice_request(Packet) ->
    Els = xmpp:get_els(Packet),
    lists:any(
      fun(#xdata{} = X) ->
	      case {xmpp_util:get_xdata_values(<<"FORM_TYPE">>, X),
		    xmpp_util:get_xdata_values(<<"muc#role">>, X)} of
		  {[<<"http://jabber.org/protocol/muc#request">>],
		   [<<"participant">>]} ->
		      true;
		  _ ->
		      false
	      end;
	 (_) ->
	      false
      end, Els).

-spec prepare_request_form(jid(), binary(), binary()) -> message().
prepare_request_form(Requester, Nick, Lang) ->
    Title = translate:translate(Lang, <<"Voice request">>),
    Instruction = translate:translate(
		    Lang, <<"Either approve or decline the voice request.">>),
    Fs = [#xdata_field{var = <<"FORM_TYPE">>,
		       type = hidden,
		       values = [<<"http://jabber.org/protocol/muc#request">>]},
	  #xdata_field{var = <<"muc#role">>,
		       type = hidden,
		       values = [<<"participant">>]},
	  ?STRINGXFIELD(<<"User JID">>, <<"muc#jid">>,
			jid:to_string(Requester)),
	  ?STRINGXFIELD(<<"Nickname">>, <<"muc#roomnick">>, Nick),
	  ?BOOLXFIELD(<<"Grant voice to this person?">>,
		      <<"muc#request_allow">>, false)],
    #message{type = normal,
	     sub_els = [#xdata{type = form,
			       title = Title,
			       instructions = [Instruction],
			       fields = Fs}]}.

-spec send_voice_request(jid(), binary(), state()) -> ok.
send_voice_request(From, Lang, StateData) ->
    Moderators = search_role(moderator, StateData),
    FromNick = find_nick_by_jid(From, StateData),
    lists:foreach(fun ({_, User}) ->
			  ejabberd_router:route(
			    StateData#state.jid, User#user.jid,
			    prepare_request_form(From, FromNick, Lang))
		  end,
		  Moderators).

-spec is_voice_approvement(message()) -> boolean().
is_voice_approvement(Packet) ->
    Els = xmpp:get_els(Packet),
    lists:any(
      fun(#xdata{} = X) ->
	      case {xmpp_util:get_xdata_values(<<"FORM_TYPE">>, X),
		    xmpp_util:get_xdata_values(<<"muc#role">>, X),
		    xmpp_util:get_xdata_values(<<"muc#request_allow">>, X)} of
		  {[<<"http://jabber.org/protocol/muc#request">>],
		   [<<"participant">>], [Flag]} when Flag == <<"true">>;
						     Flag == <<"1">> ->
		      true;
		  _ ->
		      false
	      end;
	 (_) ->
	      false
      end, Els).

-spec extract_jid_from_voice_approvement(message()) -> jid() | error.
extract_jid_from_voice_approvement(Packet) ->
    Els = xmpp:get_els(Packet),
    lists:foldl(
      fun(#xdata{} = X, error) ->
	      case {xmpp_util:get_xdata_values(<<"FORM_TYPE">>, X),
		    xmpp_util:get_xdata_values(<<"muc#role">>, X),
		    xmpp_util:get_xdata_values(<<"muc#request_allow">>, X),
		    xmpp_util:get_xdata_values(<<"muc#jid">>, X)} of
		  {[<<"http://jabber.org/protocol/muc#request">>],
		   [<<"participant">>], [Flag], [J]} when Flag == <<"true">>;
							  Flag == <<"1">> ->
		      jid:from_string(J);
		  _ ->
		      error
	      end;
	 (_, Acc) ->
	      Acc
      end, error, Els).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Invitation support

-spec is_invitation(message()) -> boolean().
is_invitation(Packet) ->
    Els = xmpp:get_els(Packet),
    lists:any(
      fun(#muc_user{invites = [_|_]}) -> true;
	 (_) -> false
      end, Els).

-spec check_invitation(jid(), message(), state()) -> {error, error()} | jid().
check_invitation(From, Packet, StateData) ->
    Lang = xmpp:get_lang(Packet),
    FAffiliation = get_affiliation(From, StateData),
    CanInvite = (StateData#state.config)#config.allow_user_invites
	orelse
	FAffiliation == admin orelse FAffiliation == owner,
    case CanInvite of
	false ->
	    Txt = <<"Invitations are not allowed in this conference">>,
	    {error, xmpp:err_not_allowed(Txt, Lang)};
	true ->
	    case xmpp:get_subtag(Packet, #muc_user{}) of
		#muc_user{invites = [#muc_invite{to = undefined}]} ->
		    Txt = <<"No 'to' attribute found">>,
		    {error, xmpp:err_bad_request(Txt, Lang)};
		#muc_user{invites = [#muc_invite{to = JID, reason = Reason} = I]} ->
		    Invite = I#muc_invite{to = undefined, from = From},
		    Password = case (StateData#state.config)#config.password_protected of
				   true ->
				       (StateData#state.config)#config.password;
				   false ->
				       undefined
			       end,
		    XUser = #muc_user{password = Password, invites = [Invite]},
		    XConference = #x_conference{jid = jid:make(StateData#state.room,
							       StateData#state.host),
						reason = Reason},
		    Body = iolist_to_binary(
			     [io_lib:format(
				translate:translate(
				  Lang,
				  <<"~s invites you to the room ~s">>),
				[jid:to_string(From),
				 jid:to_string({StateData#state.room,
						StateData#state.host,
						<<"">>})]),
			      case (StateData#state.config)#config.password_protected of
				  true ->
				      <<", ",
					(translate:translate(
					   Lang, <<"the password is">>))/binary,
					" '",
					((StateData#state.config)#config.password)/binary,
					"'">>;
				  _ -> <<"">>
			      end,
			      case Reason of
				  <<"">> -> <<"">>;
				  _ -> <<" (", Reason/binary, ") ">>
			      end]),
		    Msg = #message{type = normal,
				   body = xmpp:mk_text(Body),
				   sub_els = [XUser, XConference]},
		    ejabberd_router:route(StateData#state.jid, JID, Msg),
		    JID;
		#muc_user{invites = [_|_]} ->
		    Txt = <<"Multiple <invite/> elements are not allowed">>,
		    {error, xmpp:err_forbidden(Txt, Lang)};
		_ ->
		    Txt = <<"No <invite/> element found">>,
		    {error, xmpp:err_bad_request(Txt, Lang)}
	    end
    end.

%% Handle a message sent to the room by a non-participant.
%% If it is a decline, send to the inviter.
%% Otherwise, an error message is sent to the sender.
-spec handle_roommessage_from_nonparticipant(message(), state(), jid()) -> ok.
handle_roommessage_from_nonparticipant(Packet, StateData, From) ->
    case xmpp:get_subtag(Packet, #muc_user{}) of
	#muc_user{decline = #muc_decline{to = #jid{} = To} = Decline} = XUser ->
	    NewDecline = Decline#muc_decline{to = undefined, from = From},
	    NewXUser = XUser#muc_user{decline = NewDecline},
	    NewPacket = xmpp:set_subtag(Packet, NewXUser),
	    ejabberd_router:route(StateData#state.jid, To, NewPacket);
	_ ->
	    ErrText = <<"Only occupants are allowed to send messages "
			"to the conference">>,
	    Err = xmpp:err_not_acceptable(ErrText, xmpp:get_lang(Packet)),
	    ejabberd_router:route_error(StateData#state.jid, From, Packet, Err)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Logging

add_to_log(Type, Data, StateData)
    when Type == roomconfig_change_disabledlogging ->
    mod_muc_log:add_to_log(StateData#state.server_host,
			   roomconfig_change, Data, StateData#state.jid,
			   make_opts(StateData));
add_to_log(Type, Data, StateData) ->
    case (StateData#state.config)#config.logging of
      true ->
	  mod_muc_log:add_to_log(StateData#state.server_host,
				 Type, Data, StateData#state.jid,
				 make_opts(StateData));
      false -> ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Users number checking

-spec tab_add_online_user(jid(), state()) -> ok.
tab_add_online_user(JID, StateData) ->
    {LUser, LServer, LResource} = jid:tolower(JID),
    US = {LUser, LServer},
    Room = StateData#state.room,
    Host = StateData#state.host,
    catch ets:insert(muc_online_users,
		     #muc_online_users{us = US, resource = LResource,
				       room = Room, host = Host}),
    ok.

-spec tab_remove_online_user(jid(), state()) -> ok.
tab_remove_online_user(JID, StateData) ->
    {LUser, LServer, LResource} = jid:tolower(JID),
    US = {LUser, LServer},
    Room = StateData#state.room,
    Host = StateData#state.host,
    catch ets:delete_object(muc_online_users,
			    #muc_online_users{us = US, resource = LResource,
					      room = Room, host = Host}),
    ok.

-spec tab_count_user(jid()) -> non_neg_integer().
tab_count_user(JID) ->
    {LUser, LServer, _} = jid:tolower(JID),
    US = {LUser, LServer},
    case catch ets:select(muc_online_users,
			  [{#muc_online_users{us = US, _ = '_'}, [], [[]]}])
	of
      Res when is_list(Res) -> length(Res);
      _ -> 0
    end.

-spec element_size(stanza()) -> non_neg_integer().
element_size(El) ->
    byte_size(fxml:element_to_binary(xmpp:encode(El))).

-spec store_room(state()) -> ok.
store_room(StateData) ->
    if (StateData#state.config)#config.persistent ->
	    mod_muc:store_room(StateData#state.server_host,
			       StateData#state.host, StateData#state.room,
			       make_opts(StateData));
       true ->
	    ok
    end.

-spec send_wrapped(jid(), jid(), stanza(), binary(), state()) -> ok.
send_wrapped(From, To, Packet, Node, State) ->
    LTo = jid:tolower(To),
    case ?DICT:find(LTo, State#state.users) of
	{ok, #user{is_subscriber = true,
		   subscriptions = Nodes,
		   last_presence = undefined}} ->
	    case lists:member(Node, Nodes) of
		true ->
		    NewPacket = wrap(From, To, Packet, Node),
		    ejabberd_router:route(State#state.jid, To, NewPacket);
		false ->
		    ok
	    end;
	_ ->
	    ejabberd_router:route(From, To, Packet)
    end.

-spec wrap(jid(), jid(), stanza(), binary()) -> message().
wrap(From, To, Packet, Node) ->
    El = xmpp:encode(xmpp:set_from_to(Packet, From, To)),
    #message{
       sub_els = [#pubsub_event{
		     items = [#pubsub_event_items{
				 node = Node,
				 items = [#pubsub_event_item{
					     id = randoms:get_string(),
					     xml_els = [El]}]}]}]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Multicast

-spec send_multiple(jid(), binary(), [#user{}], stanza()) -> ok.
send_multiple(From, Server, Users, Packet) ->
    JIDs = [ User#user.jid || {_, User} <- ?DICT:to_list(Users)],
    ejabberd_router_multicast:route_multicast(From, Server, JIDs, Packet).

-spec send_wrapped_multiple(jid(), [#user{}], stanza(), binary(), state()) -> ok.
send_wrapped_multiple(From, Users, Packet, Node, State) ->
    lists:foreach(
      fun({_, #user{jid = To}}) ->
	      send_wrapped(From, To, Packet, Node, State)
      end, ?DICT:to_list(Users)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Detect messange stanzas that don't have meaninful content
-spec has_body_or_subject(message()) -> boolean().
has_body_or_subject(#message{body = Body, subject = Subj}) ->
    Body /= [] orelse Subj /= [].
