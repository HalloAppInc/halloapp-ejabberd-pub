%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%% Created : 31. Mar 2020 10:20 AM
%%%-------------------------------------------------------------------
-module(mod_sms).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("monitor.hrl").
-include("sms.hrl").
-include("ha_types.hrl").
-include("time.hrl").
-include("translate.hrl").
-include_lib("stdlib/include/assert.hrl").

-callback init() -> ok.
-callback can_send_sms(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
-callback can_send_voice_call(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
-callback send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, no_retry | retry}.
-callback send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail | call_fail | tts_fail, no_retry | retry}.
-callback send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
-optional_callbacks([init/0]).

-type method() :: sms | voice_call.

-ifdef(TEST).
-export([
    generate_code/1
]).
-endif.


%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
    on_user_first_login/2,
    request_sms/2,
    request_otp/5,
%%    check_otp_request_too_soon/2,
    verify_sms/3,
    find_next_ts/1,
    % TODO: move all the testing ones to the -ifdef(TEST)
%%    is_too_soon/2,  %% for testing
    send_otp/6, %% for testing
    send_otp_internal/7,
    pick_gw/3,  %% for testing,
    rand_weighted_selection/2,  %% for testing
    max_weight_selection/1,  %% for testing
    smart_send/7,  %% for testing
    generate_gateway_list/4,  %% for testing
    send_otp_to_inviter/4,  %% for testing
    get_new_gw_stats/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w ~p", [?MODULE, self()]),
    lists:foreach(fun init_gateway/1, sms_gateway_list:all()),
    ejabberd_hooks:add(on_user_first_login, halloapp, ?MODULE, on_user_first_login, 1),
    ejabberd_hooks:add(on_user_first_login, katchup, ?MODULE, on_user_first_login, 1),
    ok.

stop(_Host) ->
    ?INFO("stop ~w ~p", [?MODULE, self()]),
    ejabberd_hooks:delete(on_user_first_login, halloapp, ?MODULE, on_user_first_login, 1),
    ejabberd_hooks:delete(on_user_first_login, katchup, ?MODULE, on_user_first_login, 1),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

%% We use this hook to invalidate all past otp attempts.
%% Another way to fix this would be to store client's noise-pubkey when requesting_sms
%% and allow codes to be valid as long as client is using the same noise-pubkey.
-spec on_user_first_login(Uid :: uid(), Server :: binary()) -> ok.
on_user_first_login(Uid, _Server) ->
    AppType = util_uid:get_app_type(Uid),
    %% This hook is run on a successful login after every registration.
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            ok = model_phone:invalidate_old_attempts(Phone, AppType),
            ?INFO("Uid: ~s Phone: ~s AppType: ~p invalidate_old_attempts", [Uid, Phone, AppType]);
        {error, missing} ->
            ?ERROR("Uid: ~s missing_phone", [Uid])
    end,
    ok.


-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> {ok, non_neg_integer(), boolean()} | {error, term()}.
request_sms(Phone, UserAgent) ->
    request_otp(Phone, <<"en-US">>, UserAgent, sms, <<>>).

-spec request_otp(Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method :: method(),
    CampaignId :: binary()) ->
    {ok, non_neg_integer(), boolean()} | {error, term()}.
request_otp(Phone, LangId, UserAgent, Method, CampaignId) ->
    AppType = util_ua:get_app_type(UserAgent),
    case {config:get_hallo_env(), util:is_test_number(Phone)} of
        {prod, true} -> send_otp_to_inviter(Phone, LangId, UserAgent, Method);
        {prod, _} -> send_otp(Phone, LangId, Phone, UserAgent, Method, CampaignId);
        {stress, _} -> send_otp(Phone, LangId, Phone, UserAgent, Method, CampaignId);
        {_,_} -> just_enroll(Phone, AppType)
    end.


% Just generate and store code for this user. Mostly called for test phones or in localhost/test
-spec just_enroll(Phone :: binary(), AppType :: app_type()) -> {ok, integer(), boolean()}.
just_enroll(Phone, AppType) ->
    {ok, _NewAttemptId, _Timestamp} = ejabberd_auth:try_enroll(Phone, AppType, generate_code(Phone), <<>>),
    {ok, 30, false}.


-spec verify_sms(Phone :: phone(), AppType :: app_type(), Code :: binary()) -> match | nomatch.
verify_sms(Phone, AppType, Code) ->
    {ok, AllVerifyInfo} = model_phone:get_all_verification_info(Phone, AppType),
    case lists:search(
        fun(FetchedInfo) ->
            #verification_info{status = Status, gateway = Gateway, code = FetchedCode} = FetchedInfo,
            % normal sms gateways, regardless of status, should be checked normally
            % gateways with an external code will need to verify the recieved code the first time
            FetchedCode =:= Code andalso (not sms_gateway_list:uses_external_code(Gateway) orelse Status =:= <<"accepted">>)
        end, AllVerifyInfo) of
            false -> lists:foldl(fun(ExtCodeGW, DidMatch) ->
                    case DidMatch of
                        match -> match;
                        nomatch -> case ExtCodeGW:verify_code(Phone, AppType, Code, AllVerifyInfo) of
                            nomatch -> nomatch;
                            {match, ExtCodeMatch} -> add_verification_success(Phone, AppType, ExtCodeMatch, AllVerifyInfo)
                        end
                    end
               end, nomatch, sms_gateway_list:external_code_gateways());
            {value, FetchedInfo} ->
                add_verification_success(Phone, AppType, FetchedInfo, AllVerifyInfo)
    end.


-spec add_verification_success(Phone :: phone(), AppType :: app_type(), FetchedInfo :: verification_info(),
        AllVerifyInfo :: [verification_info()]) -> match.
add_verification_success(Phone, AppType, FetchedInfo, AllVerifyInfo) ->
    case util:is_monitor_phone(Phone) of
        true -> match;
        false ->
            #verification_info{attempt_id = AttemptId, gateway = Gateway} = FetchedInfo,
            ok = model_phone:add_verification_success(Phone, AppType, AttemptId),
            stat:count(util:get_stat_namespace(AppType) ++ "/registration", "verify_sms", 1,
                [{gateway, Gateway}, {cc, mod_libphonenumber:get_cc(Phone)}]),
            GatewayAtom = util:to_atom(Gateway),
            ?INFO("Phone: ~s sending feedback to gateway: ~s attemptId: ~s",
                        [Phone, Gateway, AttemptId]),
            case GatewayAtom of
                undefined ->
                    ?ERROR("Missing gateway of Phone:~p AttemptId: ~p", [Phone, AttemptId]),
                    ok;
                _ ->
                    %% spawn a new process for sending feedback.
                    spawn(GatewayAtom, send_feedback, [Phone, AllVerifyInfo])
            end,
            match
    end.


-spec send_otp_to_inviter (Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method ::
    atom()) -> {ok, non_neg_integer(), boolean()} | {error, term()}.
send_otp_to_inviter(Phone, LangId, UserAgent, Method)->
    AppType = util_ua:get_app_type(UserAgent),
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    case InvitersList of
        [] ->
            ?INFO("No inviter of phone: ~s", [Phone]),
            just_enroll(Phone, AppType);
        _ ->
            {Uid, _} = lists:last(InvitersList),
            case model_accounts:get_phone(Uid) of
                {error, missing} ->
                    ?ERROR("Missing phone of uid: ~s", [Uid]),
                    just_enroll(Phone, AppType);
                {ok, InviterPhone} ->
                    case test_users:is_test_uid(Uid) of
                        true -> send_otp(InviterPhone, LangId, Phone, UserAgent, Method, <<"undefined">>);
                        false -> just_enroll(Phone, AppType)
                    end
            end
    end. 

-spec send_otp(OtpPhone :: phone(), LangId :: binary(), Phone :: phone(), UserAgent :: binary(),
        Method :: method(), CampaignId :: binary()) -> {ok, non_neg_integer(), boolean()} | {error, term()}.
send_otp(OtpPhone, LangId, Phone, UserAgent, Method, CampaignId) ->
    AppType = util_ua:get_app_type(UserAgent),
    StatNamespace = util:get_stat_namespace(AppType),
    {ok, OldResponses} = model_phone:get_all_gateway_responses(Phone, AppType),
    stat:count(StatNamespace ++ "/registration", "send_otp"),
    stat:count(StatNamespace ++ "/registration", "send_otp_by_cc", 1,
        [{cc, mod_libphonenumber:get_cc(Phone)}]),
    stat:count(StatNamespace ++ "/registration", "send_otp_by_campaign_id", 1,
        [{campaign_id, CampaignId}]),
    stat:count(StatNamespace ++ "/registration", "send_otp_by_lang", 1, [{lang_id, util:to_list(LangId)}]),
    case send_otp_internal(OtpPhone, Phone, LangId, UserAgent, Method, CampaignId, OldResponses) of
        {ok, SMSResponse} ->
            ?INFO("Response: ~p", [SMSResponse]),
            #gateway_response{attempt_id = NewAttemptId, attempt_ts = Timestamp} = SMSResponse,
            model_phone:add_gateway_response(Phone, AppType, NewAttemptId, SMSResponse),
            AllResponses = OldResponses ++ [SMSResponse],
            NextTs = find_next_ts(AllResponses),
            IsUndelivered = lists:any(fun(#gateway_response{status = Status}) ->
                  is_undelivered(Status)
            end, AllResponses),
            {ok, NextTs - Timestamp, IsUndelivered};
        {error, GW, Reason} = _Err ->
            %% We log an error inside the gateway already.
            ?INFO("Unable to send ~p: ~p, Gateway: ~p, OtpPhone: ~s Phone: ~s ",
                [Method, Reason, GW, OtpPhone, Phone]),
            {error, Reason}
    end.

%%====================================================================

-spec init_gateway(Gateway :: atom()) -> ok.
init_gateway(Gateway) ->
    case erlang:function_exported(Gateway, init, 0) of
        true ->
            try Gateway:init()
            catch
                Class : Reason : Stacktrace  ->
                    ?ERROR("Failed to initialize sms Gateways:~s ~p Stacktrace:~s",
                        [Gateway, Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
            end;
        false -> ok
    end.


-spec find_next_ts(OldResponses :: [gateway_response()]) -> non_neg_integer().
find_next_ts(OldResponses) ->
    %% Find the last unsuccessful attempts (ignoring when sms/otp fails on server side).
    ReverseOldResponses = lists:reverse(OldResponses),
    FailedResponses = lists:takewhile(
        fun(#gateway_response{verified = Success, status = Status, valid = Validity}) ->
            Success =/= true andalso Validity =/= false andalso is_successful_otp_attempt(Status)
        end, ReverseOldResponses),
    OldResponses2 = lists:reverse(FailedResponses),
    Len = length(OldResponses2),
    if
        Len == 0 ->
            util:now() - 10;
        true ->
            %% A good amount of time away from the last unsuccessful attempt. Please note this is
            %% approximation of exponential backoff.
            #gateway_response{attempt_ts = LastTs} = lists:nth(Len, OldResponses2),
            util_sms:good_next_ts_diff(Len) + util:to_integer(LastTs)
    end.

is_successful_otp_attempt(Status) ->
    Status =/= undelivered andalso Status =/= failed andalso
        Status =/= unknown andalso Status =/= undefined.


is_undelivered(Status) ->
    Status =:= undelivered.


-spec send_otp_internal(OtpPhone :: phone(), Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method :: method(),
        CampaignId :: binary(), OldResponses :: [gateway_response()]) -> {ok, gateway_response()} | {error, atom(), term()}.
send_otp_internal(OtpPhone, Phone, LangId, UserAgent, Method, CampaignId, OldResponses) ->
    ?DEBUG("preparing to send otp, phone:~p, LangId: ~p, UserAgent: ~p, CampaignId",
        [OtpPhone, LangId, UserAgent, CampaignId]),
    case smart_send(OtpPhone, Phone, LangId, UserAgent, Method, CampaignId, OldResponses) of
        {ok, SMSResponse} ->
            {ok, SMSResponse};
        {error, _GW, _Reason} = Err ->
            Err
    end.


-spec generate_code(Phone :: phone()) -> binary().
generate_code(Phone) ->
    TestProd = util:is_test_number(Phone) andalso not config:is_prod_env(),
    case TestProd of
        true -> <<"111111">>;
        false -> list_to_binary(io_lib:format("~6..0w", [crypto:rand_uniform(0, 999999)]))
    end.


%% TODO(vipin)
%% On callback from the provider track (success, cost). Investigative logging to track missing
%% callback.
-spec generate_gateway_list(AppType :: maybe(app_type()), CC :: binary(), Method :: method(), OldResponses :: [gateway_response()]) -> {boolean(), [atom()]}.
generate_gateway_list(AppType, CC, Method, OldResponses) ->
    {WorkingList, NotWorkingList} = lists:foldl(
        fun(#gateway_response{gateway = Gateway, method = Method2, status = Status}, {Working, NotWorking})
                when Method2 =:= Method ->
            case Status of
                canceled -> {Working, NotWorking ++ [Gateway]};
                failed -> {Working, NotWorking ++ [Gateway]};
                undelivered -> {Working, NotWorking ++ [Gateway]};
                unknown -> {Working, NotWorking ++ [Gateway]};
                _ -> {Working ++ [Gateway], NotWorking}
            end;
           (#gateway_response{gateway = _Gateway, method = _Method, status = _Status}, {Working, NotWorking}) ->
               {Working, NotWorking}
        end, {[], []}, OldResponses),

    WorkingSet = sets:from_list(WorkingList),
    NotWorkingSet = sets:from_list(NotWorkingList),

    FullConsiderList = sms_gateway_list:enabled(),
    ConsiderList = filter_gateways(AppType, CC, Method, FullConsiderList),

    ConsiderSet = sets:from_list(ConsiderList),

    IsFirstAttempt = case {sets:size(WorkingSet), sets:size(NotWorkingSet)} of
        {0, 0} -> true;
        {_, _} -> false
    end,

    %% Don't want to try using NotWorkingSet.
    GoodSet = sets:subtract(ConsiderSet, NotWorkingSet),

    %% In case we have gateways we have tried that we don't use any more.
    SupportedWorkingSet = sets:intersection(WorkingSet, ConsiderSet),

    %% Need to give preference to GW in GoodSet that is not in WorkingSet.
    TrySet = sets:subtract(GoodSet, SupportedWorkingSet),

    %% To eliminate duplicates.
    ?DEBUG("Working: ~p", [sets:to_list(SupportedWorkingSet)]),
    ?DEBUG("Not Working: ~p", [sets:to_list(NotWorkingSet)]),
    ?DEBUG("Try: ~p", [sets:to_list(TrySet)]),
    ?DEBUG("Consider: ~p", [sets:to_list(ConsiderSet)]),

    %% If length(TryList) > 0 pick any from TryList, else if size(SupportedWorkingSet) > 0 pick any from
    %% SupportedWokringSet. If both have no elements pick any from ConsiderList.
    ToChooseFromSet = case {sets:size(TrySet), sets:size(SupportedWorkingSet)} of
        {0, 0} -> ConsiderSet;  %% None of the GWs we have support for has worked.
        {0, _} -> SupportedWorkingSet;  %% We have tried all the GWs. Will try again using what has worked.
        {_, _} -> TrySet        %% We will try using GWs we have not tried.
    end,
    ToChooseFromList = sets:to_list(sets:intersection(ToChooseFromSet, ConsiderSet)), %% should be a subset of ConsiderList
    ?DEBUG("Choose from: ~p", [ToChooseFromList]),
    {IsFirstAttempt, ToChooseFromList}.


-spec filter_gateways(AppType :: maybe(app_type()), CC :: binary(), Method :: method(), GatewayList :: list(atom())) -> list(atom()).
filter_gateways(AppType, CC, Method, GatewayList) ->
    Function = case Method of
        sms -> can_send_sms;
        voice_call -> can_send_voice_call
    end,
    ResultList = lists:filter(
        fun (Gateway) ->
            Gateway:Function(AppType, CC)
        end,
        GatewayList),
    case ResultList of
        [] ->
            ?ERROR("No gateway after filter AppType: ~p, CC:~s ~p ~p -> ~p",
                [AppType, CC, Method, GatewayList, ResultList]),
            GatewayList;
        _ -> ResultList
    end.


-spec smart_send(OtpPhone :: phone(), Phone :: phone(), LangId :: binary(), UserAgent :: binary(),
        Method :: method(), CampaignId :: binary(), OldResponses :: [gateway_response()]) -> {ok, gateway_response()} |
        {error, Gateway :: atom(), sms_fail | voice_call_fail | call_fail | tts_fail}.
smart_send(OtpPhone, Phone, LangId, UserAgent, Method, CampaignId, OldResponses) ->
    CC = mod_libphonenumber:get_cc(OtpPhone),
    AppType = util_ua:get_app_type(UserAgent),

    {IsFirstAttempt, ChooseFromList} = generate_gateway_list(AppType, CC, Method, OldResponses),

    FullConsiderList = sms_gateway_list:enabled(),
    ConsiderList = filter_gateways(AppType, CC, Method, FullConsiderList),

    ConsiderSet = sets:from_list(ConsiderList),

    %% Pick one based on past performance.
    PickedGateway = pick_gw(ChooseFromList, CC, IsFirstAttempt),
    ?DEBUG("Phone: ~s Picked Gateway: ~p CC: ~s", [Phone, PickedGateway, CC]),

    %% Just in case there is any bug in computation of new gateway.
    PickedGateway2 = case sets:is_element(PickedGateway, ConsiderSet) of
        true -> PickedGateway;
        false ->
            ?ERROR("Choosing twilio, Had Picked: ~p, ConsiderList: ~p", [PickedGateway, ConsiderList]),
            twilio
    end,
    Code = case sms_gateway_list:uses_external_code(PickedGateway2) of
        true -> <<"999999">>;
        _ -> generate_code(Phone)
    end,
    ?INFO("Enrolling: ~s Using Phone: ~s CC: ~s Chosen Gateway: ~p to send ~p Code: ~s",
        [Phone, OtpPhone, CC, PickedGateway2, Method, Code]),
        
    {ok, NewAttemptId, Timestamp} = ejabberd_auth:try_enroll(Phone, AppType, Code, CampaignId),
    CurrentSMSResponse = #gateway_response{attempt_id = NewAttemptId,
        attempt_ts = Timestamp, method = Method, gateway = PickedGateway2},
    smart_send_internal(OtpPhone, Code, LangId, UserAgent, CC, CurrentSMSResponse, ChooseFromList).


-spec smart_send_internal(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent ::
        binary(), CC :: binary(), CurrentSMSResponse :: gateway_response(), GatewayList ::
        [atom()]) -> {ok, gateway_response()} | {error, atom(), atom()}.
smart_send_internal(Phone, Code, LangId, UserAgent, CC, CurrentSMSResponse, GatewayList) ->
    #gateway_response{gateway = Gateway, method = Method} = CurrentSMSResponse,
    ?INFO("Using Phone: ~s, Choosing gateway: ~p out of ~p", [Phone, Gateway, GatewayList]),
    Result = case Method of
        voice_call -> Gateway:send_voice_call(Phone, Code, LangId, UserAgent);
        sms -> Gateway:send_sms(Phone, Code, LangId, UserAgent)
    end,
    stat:count(util:get_stat_namespace(UserAgent) ++ "/registration", "send_otp_by_gateway", 1,
        [{gateway, Gateway}, {method, Method}, {cc, CC}]),
    ?DEBUG("Result: ~p", [Result]),
    case Result of
        {ok, SMSResponse} ->
            SMSResponse2 = SMSResponse#gateway_response{
                attempt_ts = CurrentSMSResponse#gateway_response.attempt_ts,
                method = Method,
                attempt_id = CurrentSMSResponse#gateway_response.attempt_id,
                gateway = Gateway,
                lang_id = LangId
                },
            {ok, SMSResponse2};
        {error, Reason, retry} ->
            ToChooseFromList = lists:delete(Gateway, GatewayList),
            case ToChooseFromList of
                [] ->
                    {error, Gateway, Reason};
                _ ->
                    % pick from curated list
                    PickedGateway = pick_gw(ToChooseFromList, CC, false),
                    ?DEBUG("Phone: ~s Picked Gateway: ~p, CC: ~p", [Phone, PickedGateway, CC]),
                    NewSMSResponse = CurrentSMSResponse#gateway_response{gateway = PickedGateway},
                    smart_send_internal(Phone, Code, LangId, UserAgent, CC, NewSMSResponse, ToChooseFromList)
            end;
        {error, Reason, no_retry} ->
            {error, Gateway, Reason}
    end.


-spec pick_gw(ChooseFrom :: [atom()], CC :: binary(), IsFirstAttempt :: boolean()) -> Gateway :: atom().
pick_gw(ChooseFrom, CC, IsFirstAttempt) ->
    CCGWScores = get_new_gw_scores(ChooseFrom, CC),
    %% Allocate based on square of the gateway scores.
    SqrGWScores = maps:fold(
        fun(Key, Value, AccIn) ->
            AccIn#{Key => Value * Value}
        end, #{}, CCGWScores),
    GWWeights = util:normalize_scores(SqrGWScores),
    RandNo = rand:uniform(),

    UseMax = should_use_max(CC),

    Gateway = case IsFirstAttempt andalso not UseMax of
        true ->
            % Pick based on country-specific scores
            rand_weighted_selection(RandNo, GWWeights);
        false ->
            % Pick the gateway with the max score.
            max_weight_selection(GWWeights)
    end,

    ExperimentalGateway = pick_gw_experimental(ChooseFrom, CC, IsFirstAttempt),

    ?INFO("Old Selection: ~p New Selection: ~p Weights: ~p Rand: ~p IsFirst: ~p CC: ~s",
        [Gateway, ExperimentalGateway, GWWeights, RandNo, IsFirstAttempt, CC]),

    ExperimentalGateway. %%TODO: Remove old gateway selection code once we're sure this is better.

-spec pick_gw_experimental(ChooseFrom :: [atom()], CC :: binary(), IsFirstAttempt :: boolean()) -> Gateway :: atom().
pick_gw_experimental(ChooseFrom, CC, IsFirstAttempt) ->
    CCGWScores = get_new_gw_stats(ChooseFrom, CC),
    RelevantGateways = stat_sms:relevant_gateways(CCGWScores),

    SampleRandomly = should_sample_randomly(),

    Candidates = case SampleRandomly orelse length(RelevantGateways) == 0 of
        true ->
                % Sample randomly from all gateways some fraction of the time to keep test traffic.
                ChooseFrom;
        false ->
                %% If given clickatell, twilio, twilio_verify, relevant gatways should return
                %% twilio and twilio_verify. When choosing, we should choose one of
                %% twilio, twilio_verify on random
                %%
                %% Meaning: There could be more than one relevant gateways
                RelevantGateways
     end,

    ?INFO("experimental pick: Candidates: ~p, Relevant ~p, Score Data: ~p Sample Randomly ~p", [Candidates, RelevantGateways, CCGWScores, SampleRandomly]),

     case IsFirstAttempt of
         true ->
             % Chooses randomly from either the best candidates (if we aren't sampling) or all gateways (if we are) 
             random_choice(Candidates);
        false ->
             % Pick the gateway with the max score.
             GWWeights = maps:map(fun(_, {Score, _}) -> Score end, CCGWScores),
             max_weight_selection(GWWeights)
     end.

-spec max_weight_selection(Weights :: #{atom() => float()}) -> atom().
max_weight_selection(Weights) ->
    %% If the weights are [0.5, 0.6, 0.3, 0.4], the second gateway will be chosen.
    {BestGW, BestScore} = maps:fold(
        fun(Gateway, Score, {CurrGW, Max}) ->
            case Score > Max of
                true -> {Gateway, Score};
                _ -> {CurrGW, Max}
            end
        end, {undefined, -0.1}, Weights),
    ?DEBUG("BestGW: ~p Score: ~p Weights: ~p", [BestGW, BestScore, Weights]),
    BestGW.


-spec rand_weighted_selection(RandNo :: float(), Weights :: #{atom() => float()}) -> atom().
rand_weighted_selection(RandNo, Weights) ->
    %% Select gateway randomly based on weights. Selection uses the computed
    %% weights for each gateway. We iterate over the weights using a uniformly generated random
    %% number between 0.0 and 1.0 and keep subtracting the weight from the number until the
    %% number is negative and then we stop.
    %%
    %%
    %% https://stackoverflow.com/questions/1761626/weighted-random-numbers
    %%
    {PickedGateway, LeftOver} = maps:fold(
        fun(Gateway, Score, {CurrGW, Left}) ->
            case Left > 0 of
                true -> {Gateway, Left - Score};
                _ -> {CurrGW, Left}
            end
        end, {0, RandNo}, Weights),
    true = (LeftOver =< 0),
    PickedGateway.

-spec should_use_max(CC :: binary()) -> boolean().
should_use_max(CC) ->
    %% Right now default to old behavior except for Indonesia.
    %% todo: do this more elegantly!
    RandNo = rand:uniform(),
    case CC of 
        <<"ID">> -> RandNo < ?PROBABILITY_USE_MAX;
        <<"SA">> -> RandNo < ?PROBABILITY_USE_MAX;
        _ -> false
    end.

-spec random_choice(Options :: list(atom())) -> boolean().
 random_choice(Options) ->
     lists:nth(rand:uniform(length(Options)), Options).

 -spec should_sample_randomly() -> boolean().
 should_sample_randomly() ->
     rand:uniform() < ?PROBABILITY_SAMPLE_RANDOMLY.


-spec get_new_gw_scores(ChooseFrom :: [atom()], CC :: binary()) -> #{atom() => integer()}.
get_new_gw_scores(ChooseFrom, CC) ->
    RetVal = lists:map(
        fun(Gateway) ->
            {Gateway, get_gwcc_score(Gateway, CC)}
        end, ChooseFrom),
    ScoreMap = maps:from_list(RetVal),
    ?DEBUG("CC: ~p, Gateway Scores: ~p", [CC, ScoreMap]),
    ScoreMap.

-spec get_new_gw_stats(ChooseFrom :: [atom()], CC :: binary()) -> #{atom() => {float(), integer()}}.
get_new_gw_stats(ChooseFrom, CC) ->
    RetVal = lists:map(
        fun(Gateway) ->
           {ok, Stats} = get_stats(Gateway, CC),
           {Gateway, Stats}
        end, ChooseFrom),
    ScoreMap = maps:from_list(RetVal),
    ?INFO("CC: ~p, Gateway Scores: ~p", [CC, ScoreMap]),
    ScoreMap.

%% Tries to retieve country-specific gateway score. If insufficient data (nan),
%% returns global gateway score instead. If unable to retrieve that as well, 
%% returns default gateway score as a last resort.
-spec get_gwcc_score(Gateway :: atom(), CC :: binary()) -> Score :: integer().
get_gwcc_score(Gateway, CC) ->
    GatewayCC = stat_sms:get_gwcc_atom_safe(Gateway, CC),
    case model_gw_score:get_aggregate_score(GatewayCC) of
        {ok, undefined} -> 
            ?INFO("Using Global score for ~p", [GatewayCC]),
            {ok, GlobalScore} = get_aggregate_score(Gateway),
            GlobalScore;
        {ok, Score} when Score > ?DEFAULT_GATEWAY_SCORE_PERCENT -> Score;
        {ok, _} -> ?DEFAULT_GATEWAY_SCORE_PERCENT
    end.


%% overloaded function to be able to return a default value
-spec get_aggregate_score(Gateway :: atom()) -> {ok, integer()}.
get_aggregate_score(Gateway) ->
    {ok, AggScore} = model_gw_score:get_aggregate_score(Gateway),
    RetScore = case AggScore of
        undefined -> ?DEFAULT_GATEWAY_SCORE_PERCENT;
        _ when AggScore > ?DEFAULT_GATEWAY_SCORE_PERCENT -> AggScore;
        _ -> ?DEFAULT_GATEWAY_SCORE_PERCENT
    end,
    {ok, RetScore}. 


get_stats(Gateway, CC) ->
    % new function and looks up info from "new" redis key.
    GatewayCC = stat_sms:get_gwcc_atom_safe(Gateway, CC),
    case model_gw_score:get_aggregate_stats(GatewayCC) of
        {ok, X, Y} when X =:= undefined orelse Y =:= undefined -> 
            ?INFO("Using Global stats for ~p", [GatewayCC]),
            get_aggregate_stats(Gateway);
        {ok, Score, Count} -> {ok, {Score / 100, Count}}
    end.

get_aggregate_stats(Gateway) ->
    case model_gw_score:get_aggregate_stats(Gateway) of
        {ok, X, Y} when X =:= undefined orelse Y =:= undefined  -> 
            {ok, {?DEFAULT_GATEWAY_SCORE_PERCENT/100, ?MIN_TEXTS_TO_SCORE_GW}};
        {ok, Score, Count} ->
            {ok, {Score / 100, Count}}
    end.


