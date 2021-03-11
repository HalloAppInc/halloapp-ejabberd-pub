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
    action_register/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(TICK_TIME, 1000). % tick inteval 1s

-record(state, {
    bot_name :: atom(),
    phone :: phone(),
    uid :: uid(),
    password :: binary(),
    name :: binary(),
    c :: pid(),  % pid of the ha_client
    conf = #{} :: map(),
    tref :: timer:tref(),

    % Not used yet, The bot will store some state below
    contacts_list = #{} :: map(),
    posts = #{} :: map(),
    comments = #{} :: map()
}).

%%%===================================================================
%%% API
%%%===================================================================


%% @doc Spawns the server and registers the local name (unique)
-spec start_link(Name :: atom()) ->
        {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name], []).

-spec stop(Name :: term()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec async_stop(Name :: term()) -> ok.
async_stop(Pid) ->
    gen_server:cast(Pid, {stop}).

set_conf(Pid, Conf) ->
    gen_server:call(Pid, {set_conf, Conf}).

-spec register(Pid :: pid(), Phone :: phone()) ->
        {ok, Uid :: uid(), Password :: binary()} | {error, term()}.
register(Pid, Phone) ->
    gen_server:call(Pid, {register, Phone}).

-spec set_account(Pid :: pid(), Phone :: phone(), Uid :: uid(), Password :: binary()) -> ok.
set_account(Pid, Phone, Uid, Password) ->
    gen_server:call(Pid, {set_account, Phone, Uid, Password}).

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
init([Name]) ->
    ?INFO("Starting bot: ~p", [Name]),
    {ok, Tref} = timer:send_interval(?TICK_TIME, self(), {tick}),
    {ok, #state{bot_name = Name, tref = Tref}}.

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
handle_call({set_account, Phone, Uid, Password}, _From, State) ->
    State2 = State#state{
        phone = Phone,
        uid = Uid,
        password = Password,
        name = gen_random_name() % TODO: make the caller pass the name
    },
    {reply, ok, State2};
handle_call({connect}, _From, #state{uid = Uid, password = Password} = State) ->
    {ok, C} = ha_client:connect_and_login(Uid, Password),
    State2 = State#state{c = C},
    {reply, ok, State2};
handle_call({disconnect}, _From, #state{c = C} = State) ->
    case C of
        undefined -> ok;
        _ -> ha_client:stop(C)
    end,
    State2 = State#state{c = undefined},
    {reply, ok, State2};
handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({stop}, State = #state{}) ->
    {stop, normal, State};
handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info({tick}, State = #state{bot_name = Name}) ->
    ?DEBUG("tick ~p", [Name]),
    try
        State2 = do_actions(State),
        {noreply, State2}
    catch
        C:R:S ->
            ?ERROR(lager:pr_stacktrace(S, {C, R})),
            {noreply, State}
    end;
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
        State :: #state{}) -> term()).
terminate(_Reason, _State = #state{c = C, bot_name = BotName}) ->
    ?INFO("terminating bot ~p", [BotName]),
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


do_register(Phone, State) ->
    ?assert(util:is_test_number(Phone)),
    {ok, _Res} = registration_client:request_sms(Phone),
    Name = gen_random_name(),
    {ok, Uid, Password, _Resp} = registration_client:register(Phone, <<"111111">>, Name),
    State2 = State#state{
        phone = Phone,
        uid = Uid,
        password = Password,
        name = Name
    },
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


% Freq is in Hz, returns number of times this action should be performed.
freq_to_count(Freq) when Freq < 1.0 ->
    case rand:uniform() < Freq of
        true -> 1;
        false -> 0
    end;
freq_to_count(Freq) when Freq >= 1.0 ->
    X = math:floor(Freq),
    X + freq_to_count(Freq - X).


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


%% Actions implementation

-spec get_actions(Conf :: map()) -> [atom()].
get_actions(Conf) ->
    lists:filter(fun (K) -> erlang:function_exported(?MODULE, K, 1) end, maps:keys()).


action_register({_, #state{bot_name = Name, conf = Conf} = State}) ->
    PhonePattern = maps:get(phone_pattern, Conf),
    Phone = generate_phone(PhonePattern),
    ?DEBUG("~p doing register Phone: ~p", [Name, Phone]),
    State2 = do_register(Phone, State),
    State2.

