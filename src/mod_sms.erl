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
-include("sms.hrl").
-include("ha_types.hrl").
-include("time.hrl").
-include("translate.hrl").
-include_lib("stdlib/include/assert.hrl").

-callback send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail}.
-callback send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail}.
-callback send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.

-ifdef(TEST).
-export([
    generate_code/1,
    send_otp_to_inviter/4
]).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
    request_sms/2,
    request_otp/4,
    verify_sms/2,
    is_too_soon/1,  %% for testing
    send_otp/5, %% for testing
    send_otp_internal/6,
    pick_gw/2,  %% for testing,
    generate_code/1,  %% for testing
    smart_send/6,  %% for testing
    send_otp_to_inviter/4, %% for testing
    generate_gateway_list/2  %% for testing
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w ~p", [?MODULE, self()]),
    ok = twilio:init(),
    ok = mbird:init(),
    ok.

stop(_Host) ->
    ?INFO("stop ~w ~p", [?MODULE, self()]),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
request_sms(Phone, UserAgent) ->
    request_otp(Phone, <<"en-US">>, UserAgent, sms).

-spec request_otp(Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method :: atom()) ->
    {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
request_otp(Phone, LangId, UserAgent, Method) ->
    case {config:get_hallo_env(), util:is_test_number(Phone)} of
        {prod, true} -> send_otp_to_inviter(Phone, LangId, UserAgent, Method);
        {prod, _} -> send_otp(Phone, LangId, Phone, UserAgent, Method);
        {stress, _} -> send_otp(Phone, LangId, Phone, UserAgent, Method);
        {_,_} ->
            {ok, _NewAttemptId, _Timestamp} = ejabberd_auth:try_enroll(Phone, generate_code(Phone)),
            {ok, 30}
    end.


-spec verify_sms(Phone :: phone(), Code :: binary()) -> match | nomatch.
verify_sms(Phone, Code) ->
    {ok, AllVerifyInfo} = model_phone:get_all_verification_info(Phone),
    case lists:search(
        fun(FetchedInfo) ->
            #verification_info{status = Status, gateway = Gateway, code = FetchedCode} = FetchedInfo,
            % non-mbird_verify gateways, regardless of status, should be checked normally
            % mbird_verify gateways with an accepted status will have an updated code to check
            FetchedCode =:= Code andalso (Gateway =/= <<"mbird_verify">> orelse Status =:= <<"accepted">>)
        end, AllVerifyInfo) of
            false ->
                case mbird_verify:verify_code(Phone, Code, AllVerifyInfo) of
                    nomatch -> nomatch;
                    {match, MbirdMatch} -> add_verification_success(Phone, MbirdMatch, AllVerifyInfo)
                end;
            {value, FetchedInfo} ->
                add_verification_success(Phone, FetchedInfo, AllVerifyInfo)
    end.


-spec add_verification_success(Phone :: phone(), FetchedInfo :: verification_info(),
        AllVerifyInfo :: [verification_info()]) -> match.
add_verification_success(Phone, FetchedInfo, AllVerifyInfo) ->
    #verification_info{attempt_id = AttemptId, gateway = Gateway} = FetchedInfo,
    ok = model_phone:add_verification_success(Phone, AttemptId),
    stat:count("HA/registration", "verify_sms", 1,
        [{gateway, Gateway}, {cc, mod_libphonenumber:get_cc(Phone)}]),
    GatewayAtom = util:to_atom(Gateway),
    ?INFO("Phone: ~p, sending feedback to gateway: ~p, attemptId: ~p",
                [Phone, Gateway, AttemptId]),
    case GatewayAtom of
        undefined ->
            ?ERROR("Missing gateway of Phone:~p AttemptId: ~p", [Phone, AttemptId]),
            ok;
        _ -> GatewayAtom:send_feedback(Phone, AllVerifyInfo)
    end,
    match.


-spec send_otp_to_inviter (Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method ::
    atom()) -> {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
send_otp_to_inviter(Phone, LangId, UserAgent, Method)->
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    case length(InvitersList) of 
        0 ->
            ?INFO("No last known inviter of phone: ~p", [Phone]),
            {error, not_invited};
        _ ->
            {Uid, _} = lists:last(InvitersList),
                case model_accounts:get_phone(Uid) of 
                    {error, missing} = Error -> 
                        ?ERROR("Missing phone of id: ~p", [Uid]),
                        Error;
                    {ok, InviterPhone} -> 
                        case test_users:is_test_uid(Uid) of
                            true -> send_otp(InviterPhone, LangId, Phone, UserAgent, Method);
                            false -> {error, not_invited}
                        end
                end
    end. 

-spec send_otp(OtpPhone :: phone(), LangId :: binary(), Phone :: phone(), UserAgent :: binary(),
        Method :: atom()) -> {ok, non_neg_integer()} | {error, term()} | {error, term(), non_neg_integer()}.
send_otp(OtpPhone, LangId, Phone, UserAgent, Method) ->
    {ok, OldResponses} = model_phone:get_all_gateway_responses(Phone),
    case is_too_soon(OldResponses) of
        {true, WaitTs} -> {error, retried_too_soon, WaitTs};
        {false, _} ->
            stat:count("HA/registration", "send_otp"),
            stat:count("HA/registration", "send_otp_by_cc", 1,
                [{cc, mod_libphonenumber:get_cc(Phone)}]),
            stat:count("HA/registration", "send_otp_by_lang", 1, [{lang_id, util:to_list(LangId)}]),
            case send_otp_internal(OtpPhone, Phone, LangId, UserAgent, Method, OldResponses) of
                {ok, SMSResponse} ->
                    ?INFO("Response: ~p", [SMSResponse]),
                    #gateway_response{attempt_id = NewAttemptId, attempt_ts = Timestamp} = SMSResponse,
                    model_phone:add_gateway_response(Phone, NewAttemptId, SMSResponse),
                    AllResponses = OldResponses ++ [SMSResponse],
                    NextTs = find_next_ts(AllResponses),
                    {ok, NextTs - Timestamp};
                {error, GW, Reason} = _Err ->
                    %% We log an error inside the gateway already.
                    ?INFO("Unable to send ~p: ~p, Gateway: ~p, OtpPhone: ~p Phone: ~p ",
                        [Method, Reason, GW, OtpPhone, Phone]),
                    {error, Reason}
            end
    end.


%%====================================================================

-spec is_too_soon(OldResponses :: [gateway_response()]) -> {boolean(), integer()}.
is_too_soon(OldResponses) ->
    NextTs = find_next_ts(OldResponses),
    {NextTs > util:now(), NextTs - util:now()}.


-spec find_next_ts(OldResponses :: [gateway_response()]) -> non_neg_integer().
find_next_ts(OldResponses) ->
    %% Find the last unsuccessful attempts (ignoring when sms/otp fails on server side).
    ReverseOldResponses = lists:reverse(OldResponses),
    FailedResponses = lists:takewhile(
        fun(#gateway_response{verified = Success, status=Status}) ->
            Success =/= true andalso
            Status =/= undelivered andalso Status =/= failed andalso Status =/= unknown andalso Status =/= undefined
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


-spec send_otp_internal(OtpPhone :: phone(), Phone :: phone(), LangId :: binary(), UserAgent :: binary(), Method :: atom(),
        OldResponses :: [gateway_response()]) -> {ok, gateway_response()} | {error, atom(), term()}.
send_otp_internal(OtpPhone, Phone, LangId, UserAgent, Method, OldResponses) ->
    ?DEBUG("preparing to send otp, phone:~p, LangId: ~p, UserAgent: ~p",
        [OtpPhone, LangId, UserAgent]),
    case smart_send(OtpPhone, Phone, LangId, UserAgent, Method, OldResponses) of
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
-spec generate_gateway_list(Method :: atom(), OldResponses :: [gateway_response()]) -> [atom()].
generate_gateway_list(Method, OldResponses) ->
    {WorkingList, NotWorkingList} = lists:foldl(
        fun(#gateway_response{gateway = Gateway, method = Method2, status = Status}, {Working, NotWorking})
                when Method2 =:= Method ->
            case Status of
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
    ConsiderList = sms_gateway_list:get_sms_gateway_list(),
    ConsiderSet = sets:from_list(ConsiderList),

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
    ToChooseFromList.


-spec gateway_cc_filter(CC :: binary()) -> atom().
gateway_cc_filter(CC) ->
    %% TODO(vipin): Fix as and when we get approval. Replace the following using redis.
    case CC of
        <<"AE">> -> twilio;     %% UAE
        <<"AM">> -> twilio;     %% Armenia
        <<"BG">> -> twilio;     %% Bulgaria
        <<"BL">> -> twilio_verify;     %% Belarus
        <<"CN">> -> twilio_verify;     %% China, check once vetting is done
        <<"CU">> -> twilio_verify;     %% Cuba
        <<"TD">> -> twilio_verify;     %% Chad
        <<"CZ">> -> twilio_verify;     %% Czech Republic
        <<"EG">> -> twilio;     %% Egypt
        <<"ID">> -> twilio_verify;     %% Indonesia
        <<"JO">> -> twilio;     %% Jordan
        <<"KZ">> -> twilio_verify;     %% Kazakhstan
        <<"KE">> -> twilio_verify;     %% Kenya
        <<"KW">> -> twilio_verify;     %% Kuwait
        <<"MK">> -> twilio;     %% Macedonia
        <<"ME">> -> twilio;     %% Montenegro
        <<"MA">> -> twilio_verify;     %% Morocco
        <<"MX">> -> mbird;      %% Mexico
        <<"MZ">> -> twilio;     %% Mozambique
        <<"MM">> -> mbird;      %% Myanmar
        <<"NZ">> -> twilio_verify;     %% New Zealand
        <<"PH">> -> mbird;     %% Philippines
        <<"QA">> -> twilio_verify;     %% Qatar
        <<"RO">> -> twilio;     %% Romania
        <<"RU">> -> twilio_verify;     %% Russia
        <<"SA">> -> twilio;     %% Saudi Arabia
        <<"RS">> -> twilio;     %% Serbia
        <<"TZ">> -> twilio_verify;     %% Tanzania
        <<"UA">> -> twilio;     %% Ukraine
        <<"UZ">> -> twilio;     %% Uzbekistan
        <<"VN">> -> twilio_verify;     %% Vietnam
        _ -> unrestricted % will choose in smart_send
    end.


-spec smart_send(OtpPhone :: phone(), Phone :: phone(), LangId :: binary(), UserAgent :: binary(),
        Method :: atom(), OldResponses :: [gateway_response()]) -> {ok, gateway_response()} |
        {error, atom(), sms_fail} | {error, atom(), call_fail} | {error, atom(), voice_call_fail}.
smart_send(OtpPhone, Phone, LangId, UserAgent, Method, OldResponses) ->
    CC = mod_libphonenumber:get_cc(OtpPhone),
    % check if country has restricted gateway first
    NewGateway = gateway_cc_filter(CC),
    {NewGateway2, ToChooseFromList} = case NewGateway of
        unrestricted ->
            ChooseFromList = generate_gateway_list(Method, OldResponses),
            ConsiderList = sms_gateway_list:get_sms_gateway_list(),
            ConsiderSet = sets:from_list(ConsiderList),

            %% Pick one based on past performance.
            {PickedGateway, NewPickedGateway} = pick_gw(ChooseFromList, CC),
            ?INFO("Current Selection: ~p, New Selection: ~p, CC: ~p",
                [PickedGateway, NewPickedGateway, CC]),

            %% Just in case there is any bug in computation of new gateway.
            PickedGateway2 = case sets:is_element(PickedGateway, ConsiderSet) of
                true -> PickedGateway;
                false ->
                    ?ERROR("Choosing twilio, Had Picked: ~p, ConsiderList: ~p", [PickedGateway, ConsiderList]),
                    twilio
            end,
            {PickedGateway2, ChooseFromList};
        _ -> % matched with a country with specific gateway
            ChooseFromList = [NewGateway],
            {NewGateway, ChooseFromList}
    end,
    Code = case NewGateway2 of
        mbird_verify -> <<"999999">>;
        _ -> generate_code(Phone)
    end,
    ?INFO("Enrolling: ~s, Using Phone: ~s CC: ~s Chosen Gateway: ~p to send ~p Code: ~p",
        [Phone, OtpPhone, CC, NewGateway2, Method, Code]),
        
    {ok, NewAttemptId, Timestamp} = ejabberd_auth:try_enroll(Phone, Code),
    CurrentSMSResponse = #gateway_response{attempt_id = NewAttemptId,
        attempt_ts = Timestamp, method = Method, gateway = NewGateway2},
    smart_send_internal(OtpPhone, Code, LangId, UserAgent, CC, CurrentSMSResponse, ToChooseFromList).


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
    stat:count("HA/registration", "send_otp_by_gateway", 1,
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
                _ -> % pick from curated list
                    {PickedGateway, NewPickedGateway} = pick_gw(ToChooseFromList, CC),
                    ?INFO("Current Selection: ~p, New Selection: ~p, CC: ~p",
                        [PickedGateway, NewPickedGateway, CC]),
                    NewSMSResponse = CurrentSMSResponse#gateway_response{gateway = PickedGateway},
                    smart_send_internal(Phone, Code, LangId, UserAgent, CC, NewSMSResponse, ToChooseFromList)
            end;
        {error, Reason, no_retry} ->
            {error, Gateway, Reason}
    end.


-spec pick_gw(ChooseFrom :: [atom()], CC :: binary()) -> {atom(), atom()}.
pick_gw(ChooseFrom, CC) ->
    GWScores = get_gw_scores(ChooseFrom, CC),
    GWWeights = util:normalize_scores(GWScores),
    
    NewGWScores = get_new_gw_scores(ChooseFrom, CC),
    NewGWWeights = util:normalize_scores(NewGWScores),
    
    RandNo = rand:uniform(),

    {Picked, _LeftOver} = rand_weighted_selection(RandNo, GWWeights),
    % simulate what we would pick if we used country-specific scores
    {NewPicked, _NewLeftOver} = rand_weighted_selection(RandNo, NewGWWeights),

    ?DEBUG("Generated rand: ~p, Weights: ~p, Picked: ~p, New Weights: ~p, New Picked: ~p",
        [RandNo, GWWeights, Picked, NewGWWeights, NewPicked]),
    {lists:nth(Picked, ChooseFrom), lists:nth(NewPicked, ChooseFrom)}.


-spec rand_weighted_selection(RandNo :: float(), Weights :: list()) -> {integer(), float()}.
rand_weighted_selection(RandNo, Weights) ->
    %% Select first index that satisfy the gateway weight criteria. Selection uses the computed
    %% weights for each gateway. We iterate over the list using a uniformly generated random
    %% number between 0.0 and 1.0 and keep subtracting the weight from the left until the remainder
    %% is negative and then we stop.
    %%
    %% E.g. If the weights are [0.1, 0.2, 0.3, 0.4] and the random number is 0.5, the third gateway
    %% will be chosen.
    %%
    %% https://stackoverflow.com/questions/1761626/weighted-random-numbers
    %%
    %% TODO(vipin): Pick a faster algorithm.
    {PickedIdx, LeftOver} = lists:foldl(
        fun(XX, {I, Left}) ->
            case Left > 0 of
                true -> {I + 1, Left - XX};
                _ -> {I, Left}
            end
        end, {0, RandNo}, Weights),
    true = (LeftOver =< 0),
    {PickedIdx, LeftOver}.


-spec get_gw_scores(ChooseFrom :: [atom()], CC :: binary()) -> list().
get_gw_scores(ChooseFrom, _CC) ->
    %% TODO(vipin): Need to incorporate country specific score for each gateway.
    GlobalMap = #{mbird => 0.8, twilio => 0.8, twilio_verify => 0.5},
    RetVal = lists:map(
        fun(XX) ->
            case maps:find(XX, GlobalMap) of
                {ok, Score} -> Score;
                _ -> ?DEFAULT_GATEWAY_SCORE
            end
        end, ChooseFrom),
    ?DEBUG("GWs: ~p, Scores: ~p", [ChooseFrom, RetVal]),
    RetVal.


-spec get_new_gw_scores(ChooseFrom :: [atom()], CC :: binary()) -> list().
get_new_gw_scores(ChooseFrom, CC) ->
    RetVal = lists:map(
        fun(Gateway) ->
            get_gwcc_score(Gateway, CC)
        end, ChooseFrom),
    ?DEBUG("GWs: ~p, Scores: ~p", [ChooseFrom, RetVal]),
    RetVal.


%% Tries to retieve country-specific gateway score. If insufficient data (nan),
%% returns global gateway score instead. If unable to retrieve that as well, 
%% returns default gateway score as a last resort.
-spec get_gwcc_score(Gateway :: atom(), CC :: atom()) -> Score :: integer().
get_gwcc_score(Gateway, CC) ->
    GatewayCC = stat_sms:get_gwcc_atom_safe(Gateway, CC),
    case model_gw_score:get_aggregate_score(GatewayCC) of
        {ok, undefined} -> 
            ?DEBUG("Using Global score for ~p", [GatewayCC]),
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


