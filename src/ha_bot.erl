%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% Halloapp Bot client designed to help stress test the backend services. The bot client is
%%% given a config file which tells it what actions to do how often. Bots are organized in
%%% bot_farms (ha_bot_farm) and the farms are controlled by ha_stress module.
%%% @end
%%% Created : 10. Mar 2021 5:05 PM
%%%-------------------------------------------------------------------
-module(ha_bot).
-author("nikola").

-behaviour(gen_server).

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").


%% API
-export([
    start_link/1,
    stop/1,
    async_stop/1,
    set_conf/2,
    register/2,
    set_account/4,
    connect/1,
    disconnect/1
]).

%% Actions API
-export([
    action_register/1,
    action_phonebook_full_sync/1,
    action_register_and_phonebook/1,
    action_send_im/1,
    action_recv_im/1,
    action_post/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(TICK_TIME, 1000). % tick inteval 1s
-define(STATS_TIME, 10000). % stats inteval 10s

-record(state, {
    bot_name :: atom(),
    parent_pid :: pid(),
    phone :: maybe(phone()),
    uid :: maybe(uid()),
    keypair :: maybe(tuple()),
    name :: maybe(binary()),
    c :: maybe(pid()),  % pid of the ha_client
    conf = #{} :: map(),
    tref :: timer:tref(),
    tref_stats :: timer:tref(),
    stats = #{} :: map(),

    % Not used yet, The bot will store some state below
    contacts_list = #{} :: map(), % phone => #pb_contact
    posts = #{} :: map(),
    comments = #{} :: map()
}).

-type state() :: #state{}.

%%%===================================================================
%%% API
%%%===================================================================


%% @doc Spawns the server and registers the local name (unique)
-spec start_link(Name :: atom()) ->
        {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name, self()], []).

-spec stop(Name :: term()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec async_stop(Name :: term()) -> ok.
async_stop(Pid) ->
    gen_server:cast(Pid, {stop}).

set_conf(Pid, Conf) ->
    gen_server:call(Pid, {set_conf, Conf}).

-spec register(Pid :: pid(), Phone :: phone()) ->
        {ok, Uid :: uid(), KeyPair :: tuple()} | {error, term()}.
register(Pid, Phone) ->
    gen_server:call(Pid, {register, Phone}).

-spec set_account(Pid :: pid(), Phone :: phone(), Uid :: uid(), KeyPair :: tuple()) -> ok.
set_account(Pid, Phone, Uid, KeyPair) ->
    gen_server:call(Pid, {set_account, Phone, Uid, KeyPair}).

-spec connect(Pid :: pid()) -> ok | {error, term()}.
connect(Pid) ->
    gen_server:call(Pid, {connect}).


-spec disconnect(Pid :: pid()) -> ok | {error, term()}.
disconnect(Pid) ->
    gen_server:call(Pid, {disconnect}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([Name, ParentPid]) ->
    ?INFO("Starting bot: ~p self: ~p parent: ~p", [Name, self(), ParentPid]),
    {ok, Tref} = timer:send_interval(?TICK_TIME, self(), {tick}),
    {ok, TrefStats} = timer:send_interval(?STATS_TIME, self(), {send_stats}),
    {ok, #state{bot_name = Name, parent_pid = ParentPid, tref = Tref, tref_stats = TrefStats}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
        State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call({set_conf, Conf}, _From, State) ->
    {reply, ok, State#state{conf = Conf}};
handle_call({register, Phone}, _From, State) ->
    State2 = do_register(Phone, State),
    {reply, {ok, State2#state.uid}, State2};
handle_call({set_account, Phone, Uid, KeyPair}, _From, State) ->
    State2 = State#state{
        phone = Phone,
        uid = Uid,
        keypair = KeyPair,
        name = gen_random_name() % TODO: make the caller pass the name
    },
    {reply, ok, State2};
handle_call({connect}, _From, #state{uid = Uid, keypair = KeyPair} = State) ->
    {ok, C} = ha_client:connect_and_login(Uid, KeyPair),
    State2 = State#state{c = C},
    {reply, ok, State2};
handle_call({disconnect}, _From, State) ->
    {reply, ok, do_disconnect(State)};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({stop}, State) ->
    {stop, normal, State};
handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({tick}, State = #state{bot_name = Name, uid = Uid, phone = Phone}) ->
    ?DEBUG("tick ~p", [Name]),
    State2 = try
        do_actions(State)
    catch
        C:R:S ->
            ?ERROR("Uid: ~p Phone: ~p Stacktrace: ~s",
                [Uid, Phone, lager:pr_stacktrace(S, {C, R})]),
            count(State, "error")
    end,
    {noreply, State2};
handle_info({send_stats}, State = #state{parent_pid = ParentPid, stats = Stats}) ->
    ParentPid ! {bot_stats, Stats},
    {noreply, State#state{stats = #{}}};
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
        State :: #state{}) -> term()).
terminate(_Reason, _State = #state{c = C, bot_name = BotName, tref = Tref, tref_stats = TrefStats}) ->
    ?INFO("terminating bot ~p", [BotName]),
    timer:cancel(Tref),
    timer:cancel(TrefStats),
    case C of
        undefined -> ok;
        _ -> ha_client:stop(C)
    end,
    ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
        Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #state{}, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


do_register(Phone, #state{conf = Conf} = State) ->
    ?assert(util:is_test_number(Phone)),
    Options = #{
        host => maps:get(http_host, Conf),
        port => maps:get(http_port, Conf),
        return_keypair => true
    },
    {ok, _Res} = registration_client:request_sms(Phone, Options),
    Name = gen_random_name(),
    {ok, Resp, KeyPair} = registration_client:register(Phone, <<"111111">>, Name, Options),
    Uid = Resp#pb_verify_otp_response.uid,
    State2 = State#state{
        phone = Phone,
        uid = Uid,
        keypair = KeyPair,
        name = Name
    },
    ?INFO("register phone:~s uid: ~s", [Phone, Uid]),
    State2.


gen_random_name() ->
    N = util:random_str(6),
    <<<<"Bot User ">>/binary, N/binary>>.


do_actions(#state{conf = Conf} = State) ->
    Actions = get_actions(Conf),
    EndState = lists:foldl(
        fun (Action, State1) ->
            case maps:get(Action, Conf, undefined) of
                undefined -> State1;
                {Freq, Args} ->
                    do_action(Action, Freq, Args, State1)
            end
        end,
        State,
        Actions),
    EndState.


-spec freq_to_count(Freq :: float()) -> integer().
% Freq is in Hz, returns number of times this action should be performed.
freq_to_count(Freq) when Freq < 1.0 ->
    case rand:uniform() < Freq of
        true -> 1;
        false -> 0
    end;
freq_to_count(Freq) when Freq >= 1.0 ->
    X = math:floor(Freq),
    trunc(X + freq_to_count(Freq - X)).


do_action(Action, Freq, Args, State) ->
    Count = freq_to_count(Freq),
    lists:foldl(
        fun (_, State1) ->
            erlang:apply(?MODULE, Action, [{Args, State1}])
        end,
        State,
        lists:seq(1, Count)).

% replaces '.' with random digits (eg. "12..5555...." -> "124455551234")
generate_phone(PhonePattern) when is_binary(PhonePattern) ->
    generate_phone(binary_to_list(PhonePattern));
generate_phone(PhonePattern) when is_list(PhonePattern) ->
    list_to_binary(lists:map(
        fun
            ($.) ->
                rand:uniform(10) - 1 + $0;
            (D) -> D
        end,
        PhonePattern)).


% TODO: arrange the code better: Move the internal functions below. Keep actions together.
%% Actions implementation

-spec get_actions(Conf :: map()) -> [atom()].
get_actions(Conf) ->
    lists:filter(fun (K) -> erlang:function_exported(?MODULE, K, 1) end, maps:keys(Conf)).


action_register({_, #state{bot_name = Name, conf = Conf} = State}) ->
    PhonePattern = maps:get(phone_pattern, Conf),
    Phone = generate_phone(PhonePattern),
    ?DEBUG("~p doing register Phone: ~p", [Name, Phone]),
    State2 = do_register(Phone, State),
    State3 = count(State2, "register"),
    State3.


action_phonebook_full_sync({{N}, #state{uid = Uid, conf = Conf} = State}) ->
    ?DEBUG("phonebook N = ~p Uid: ~s", [N, Uid]),
    PhonePattern = maps:get(phone_pattern, Conf),
    State2 = ensure_account(State),

    % TODO: its confusing that this is called list but it's a map
    ContactList = State2#state.contacts_list,
    NewContactList = case maps:size(ContactList) of
        N -> maps:keys(ContactList);
        % we either have not generated the contacts or the contact list
        % is not the right size, so we generate a new one
        _X -> generate_contacts(N, PhonePattern)
    end,
    State3 = do_phonebook_full_sync(NewContactList, State2),
    State4 = count(State3, "phonebook_full"),
    State4.

action_register_and_phonebook({{N}, State}) ->
    State2 = action_register({{}, State}),
    action_phonebook_full_sync({{N}, State2}).

action_send_im({{MsgSize}, State}) ->
    State2 = ensure_connected(ensure_account(State)),
    Uid = State2#state.uid,
    Uids = contact_uids(State2),

    Uids2 = case Uids of
        % If we have no Uids in our ContactList, just send IM to ourselves.
        [] -> [Uid];
        _ -> Uids
    end,
    % pick random uid to send to
    ToUid = lists:nth(rand:uniform(length(Uids2)), Uids2),
    C = State2#state.c,
    Packet = #pb_packet{stanza = #pb_msg{
        id = util:random_str(10),
        from_uid = Uid,
        to_uid = ToUid,
        payload = #pb_chat_stanza{
            payload = util:random_str(MsgSize)
        }}},
    % TODO: handle errors here. Maybe reconnect if no connection. Connection sometimes get dropped
    % because some other bot registers with the same number
    case ha_client:send(C, Packet) of
        ok -> count(State2, "send_im");
        {error, closed} -> do_disconnect(State2)
    end.

action_recv_im({{}, #state{} = State}) ->
    State2 = ensure_connected(ensure_account(State)),
    C = State2#state.c,
    % get all the messages we received
    Msgs = ha_client:recv_all_nb(C),
    State3 = lists:foldl(
        fun(Msg, S) ->
            case Msg of
                #pb_packet{stanza = #pb_msg{payload = #pb_chat_stanza{}}} -> count(S, "recv_im");
                #pb_packet{stanza = #pb_msg{}} -> count(S, "recv_msg");
                _ -> S
            end
        end,
        State2,
        Msgs),
    State3.

action_post({{PostSize, NumRecepients}, State}) ->
    State2 = ensure_connected(ensure_account_with_phonebook(State)),
    Uid = State2#state.uid,
    Uids = contact_uids(State2),

    % randomly select upto NumRecepients from the contacts
    Uids2 = lists:sublist(util:random_shuffle(Uids), NumRecepients),

    C = State2#state.c,
    FeedItem = #pb_feed_item{
        action = publish,
        item = #pb_post {
            id = util:random_str(10),
            publisher_uid = Uid,
            publisher_name = State#state.name,
            payload = util:random_str(PostSize),
            audience = #pb_audience{
                type = all,
                uids = Uids2
            }
        }
    },

    % TODO: handle errors here. Maybe reconnect if no connection. Connection sometimes get dropped
    % because some other bot registers with the same number
    Response = ha_client:send_iq(C, set, FeedItem),
    case Response of
        _ ->
            #pb_iq{
                type = Type,
                payload = Result
            } = Response#pb_packet.stanza,
            case {Type, Result} of
                {result, Result} ->
                    count(State2, "post");
                {error, _} ->
                    count(State2, "post_error")
            end
    end.

%% Internal functions

-spec count(State :: #state{}, Action :: string()) -> #state{}.
count(State = #state{stats = Stats}, Action) ->
    Stats2 = maps:update_with(Action, fun (V) -> V + 1 end, 1, Stats),
    State#state{stats = Stats2}.

% returns a list of uids this bot has as contacts
contact_uids(#state{contacts_list = ContactList}) ->
    lists:filtermap(
        fun (Contact) ->
            AUid = Contact#pb_contact.uid,
            case AUid of
                undefined -> false;
                <<>> -> false;
                AUid -> {true, AUid}
            end
        end, maps:values(ContactList)).


generate_contacts(N, _PhonePattern) when N =< 0 ->
    [];
generate_contacts(N, PhonePattern) ->
    [generate_phone(PhonePattern) | generate_contacts(N - 1, PhonePattern)].

do_phonebook_full_sync(Phones, State) ->
    Start = util:now_ms(),
    State2 = ensure_connected(State),
    C = State2#state.c,
    PhonebookSync = #pb_contact_list{
        type = full,
        sync_id = util:random_str(6),
        batch_index = 0,
        is_last = true,
        contacts = [#pb_contact{raw = P} || P <- Phones]
    },
    % TODO: handle timeouts here, also handle errors
    Response = ha_client:send_iq(C, set, PhonebookSync),
    End = util:now_ms(),
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_contact_list{
                contacts = ResultContacts
            }
        }
    } = Response,

    ContactList = lists:map(
        fun (Contact) ->
            ?DEBUG("~p", [Contact]),
            {Contact#pb_contact.raw, Contact}
        end, ResultContacts),

    State3 = State2#state{contacts_list = maps:from_list(ContactList)},
    ContactUids = contact_uids(State3),
    ?INFO("got ~p contacts ~p uids took: ~pms",
        [length(ResultContacts), length(ContactUids), End - Start]),

    State3.

ensure_account_with_phonebook(#state{uid = undefined} = State) ->
    ensure_account_with_phonebook(action_register({undefined, State}));
ensure_account_with_phonebook(#state{contacts_list = CL, conf = Conf} = State)
        when map_size(CL) =:= 0 ->
    N = maps:get(phonebook_size, Conf),
    action_phonebook_full_sync({{N}, State});
ensure_account_with_phonebook(State) ->
    State.


ensure_account(#state{uid = undefined} = State) ->
    action_register({undefined, State});
ensure_account(#state{uid = _Uid} = State) ->
    State.

ensure_connected(#state{c = undefined, uid = undefined} = State) ->
    do_connect(ensure_account(State));
ensure_connected(#state{c = undefined} = State) ->
    do_connect(State);
ensure_connected(State) ->
    % we must be connected already
    State.

do_connect(#state{c = undefined, phone = Phone, uid = Uid, keypair = KeyPair, conf = Conf} = State) ->
    % TODO: fix ha_client so that we don't have to pass this custom options for auto_send_acks and so on
    Options = #{
        auto_send_acks => true,
        auto_send_pongs => true,
        monitor => true
    },
    Options2 = case maps:is_key(app_host, Conf) of
        false -> Options;
        true -> maps:put(host, maps:get(app_host, Conf), Options)
    end,
    Options3 = case maps:is_key(app_port, Conf) of
        false -> Options2;
        true -> maps:put(port, maps:get(app_port, Conf), Options2)
    end,
    case ha_client:connect_and_login(Uid, KeyPair, Options3) of
        {ok, C} ->
            count(State#state{c = C}, "connect");
        {error, Reason} ->
            ?INFO("login for Uid: ~p Phone: ~p failed ~p", [Uid, Phone, Reason]),
            State2 = reset_state(State),
            State3 = count(State2, "reset"),
            ensure_connected(State3)
    end.


% remove the phone, uid, keypair and other field. This will cause a new account to get registered.
-spec reset_state(State :: state()) -> state().
reset_state(State) ->
    State#state{
        phone = undefined,
        uid = undefined,
        keypair = undefined,
        name = undefined,
        c = undefined,

        contacts_list = #{}
    }.

do_disconnect(#state{c = C} = State) when C =/= undefined ->
    ha_client:stop(C),
    State#state{c = undefined}.
