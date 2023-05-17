%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_image_ai).
-author("josh").

-behavior(gen_server).
-behavior(gen_mod).

-include("account.hrl").
-include("feed.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("proc.hrl").
-include("prompts.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
%% other API
-export([
    process_iq/1
]).

-define(URL(Model), "https://api.deepinfra.com/v1/inference/" ++ Model).

-define(MONITOR_TABLE, mod_image_ai_monitor).
-define(MONITOR_TIME_TAKEN_KEY, time_taken).
%% check every 60 seconds
-define(MONITOR_CHECK_INTERVAL_MS, (60 * ?SECONDS_MS)).
%% send alert if avg time taken to generate images exceeds 5 seconds
-define(MONITOR_TIME_TAKEN_THRESHOLD_MS, (5 * ?SECONDS_MS)).
%% log a warning if a single image generation request takes longer than 10 seconds
-define(TIME_TAKEN_WARNING_THRESHOLD_MS, (10 * ?SECONDS_MS)).

%%====================================================================
%% API
%%====================================================================

process_iq(#pb_iq{from_uid = Uid, payload = #pb_ai_image_request{text = Prompt, num_images = NumImages,
        prompt_mode = PromptMode, negative_prompt = RawNegativePrompt}} = IQ) ->
    %% TODO: enforce max number of retries per moment notification
    %% TODO: enforce max time between requests
    RequestId = util_id:new_long_id(),
    NotifId = model_feed:get_notification_id(Uid),
    MomentNotifInfo = model_feed:get_moment_info(NotifId, false),
    PromptId = MomentNotifInfo#moment_notification.promptId,
    PromptHelpersEnabled = case PromptMode of
        unknown ->
            case model_accounts:get_client_version(Uid) of
                {ok, ClientVersion} ->
                    case util_ua:get_client_type(ClientVersion) of
                        ios -> false;
                        _ -> true
                    end;
                _ ->
                    true
            end;
        user ->
            false;
        server ->
            true
    end,
    NegativePrompt = case RawNegativePrompt of
        undefined -> <<>>;
        _ -> RawNegativePrompt
    end,
    request_images(Uid, PromptId, Prompt, NegativePrompt, NumImages, RequestId, PromptHelpersEnabled),
    pb:make_iq_result(IQ, #pb_ai_image_result{result = pending, id = RequestId}).

%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    ?INFO("Start ~p", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_ai_image_request, ?MODULE, process_iq),
    ok.

stop(_Host) ->
    ?INFO("Stop ~p", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_ai_image_request),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    %% Start timer to run monitor tasks
    erlang:start_timer(?MONITOR_CHECK_INTERVAL_MS, ?PROC(), monitor_check),
    %% auth_token is the auth token for the DeepInfra service
    %% models_used is a set of strings
    %% ref_map is a map of Ref => {Uid, RequestId, StartTimestampMs, Model}
    AuthToken = mod_aws:get_secret(<<"DeepInfra_Auth_Token">>),
    {ok, #{auth_token => AuthToken, models_used => sets:new(), ref_map => #{}}}.


terminate(_Reason, _State) ->
    ok.


handle_call(Msg, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Msg]),
    {noreply, State}.


handle_cast({request_image, Uid, PromptId, UserText, UserNegativePrompt, NumImages, RequestId, PromptHelpersEnabled},
        #{auth_token := AuthToken, models_used := ModelsUsed, ref_map := RefMap} = State) ->
    PromptRecord = mod_prompts:get_prompt_from_id(PromptId),
    Model = PromptRecord#prompt.ai_image_model,
    Url = ?URL(Model),
    Headers = [{"Authorization", "bearer " ++ AuthToken}],
    Type = "application/json",
    {Prompt, NegativePrompt} = case PromptHelpersEnabled of
        true ->
            {(PromptRecord#prompt.prompt_wrapper)(UserText), PromptRecord#prompt.negative_prompt};
        false ->
            {UserText, UserNegativePrompt}
    end,
    Body = get_model_parameters(Prompt, NegativePrompt, util:to_integer(NumImages), Model),
    {ok, Ref} = httpc:request(post, {Url, Headers, Type, Body}, [], [{sync, false}]),
    NewRefMap = RefMap#{Ref => {Uid, RequestId, util:now_ms(), Model}},
    ?INFO("~s requesting ~p images, ref = ~p, request_id = ~p, model params: ~p", [Uid, NumImages, Ref, RequestId, Body]),
    {noreply, State#{models_used => sets:add_element(Model, ModelsUsed), ref_map => NewRefMap}};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


%% handles return message from async httpc request
handle_info({http, {Ref, {{_, 200, "OK"}, _Hdrs, Result}}}, #{ref_map := RefMap} = State) ->
    case maps:get(Ref, RefMap, undefined) of
        undefined ->
            ?ERROR("Got unexpected response with ref: ~p", [Ref]);
        {Uid, RequestId, StartTimeMs, Model} ->
            TimeTakenMs = util:now_ms() - StartTimeMs,
            ?INFO("Result for ~s (ref = ~p, request_id = ~p) generated in ~w ms", [Uid, Ref, RequestId, TimeTakenMs]),
            check_time_taken(Uid, TimeTakenMs),
            record_time(TimeTakenMs),
            record_request_success(Model, ok),
            parse_and_send_result(Uid, RequestId, Result)
    end,
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({http, {Ref, {{_, Code, HttpMsg}, _Hdrs, _Res}}}, #{ref_map := RefMap} = State) ->
    case maps:get(Ref, RefMap, undefined) of
        undefined ->
            ?ERROR("Got unexpected response with ref: ~p", [Ref]);
        {Uid, RequestId, StartTimeMs, Model} ->
            TimeTakenMs = util:now_ms() - StartTimeMs,
            ?ERROR("Unexpected result from ~s image request (ref = ~p, request_id = ~p, took ~w ms): ~p ~p",
                [Uid, Ref, RequestId, TimeTakenMs, Code, HttpMsg]),
            check_time_taken(Uid, TimeTakenMs),
            record_time(TimeTakenMs),
            record_request_success(Model, fail),
            Msg = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = Uid,
                type = error,
                payload = #pb_ai_image{
                    id = RequestId
                }
            },
            ejabberd_router:route(Msg)

    end,
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({http, {Ref, {error, Reason}}}, #{ref_map := RefMap} = State) ->
    case maps:get(Ref, RefMap, undefined) of
        undefined ->
            ?ERROR("Got unexpected response with ref: ~p", [Ref]);
        {Uid, RequestId, StartTimeMs, Model} ->
            TimeTakenMs = util:now_ms() - StartTimeMs,
            ?ERROR("HTTP error during ~s image request (ref = ~p, request_id = ~p, took ~w ms): ~p",
                [Uid, Ref, RequestId, TimeTakenMs, Reason]),
            check_time_taken(Uid, TimeTakenMs),
            record_request_success(Model, fail),
            Msg = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = Uid,
                type = error,
                payload = #pb_ai_image{
                    id = RequestId
                }
            },
            ejabberd_router:route(Msg)
    end,
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({timeout, _TRef, monitor_check}, #{models_used := ModelsUsed} = State) ->
    %% Check average image generation time for past 100 posts
    TimeTakenMsHistory = util_monitor:get_state_history(?MONITOR_TABLE, ?MONITOR_TIME_TAKEN_KEY),
    case TimeTakenMsHistory of
        [] -> ok;
        _ ->
            AvgTimeTakenMs = lists:sum(TimeTakenMsHistory) div length(TimeTakenMsHistory),
            case AvgTimeTakenMs > ?MONITOR_TIME_TAKEN_THRESHOLD_MS of
                true ->
                    ?ERROR("Image generation taking too long: ", [AvgTimeTakenMs]),
                    alerts:send_alert(<<"AI Images Taking Too Long">>, util:to_binary(node()), <<"critical">>,
                        <<"Average AI image generation time is too long: ", AvgTimeTakenMs/integer>>);
                false ->
                    ?INFO("Average image generation time: ~p ms", [AvgTimeTakenMs])
            end
    end,
    %% Check that the service is not down (receiving non-200 HTTP responses)
    lists:foreach(
        fun(Model) ->
            StateHistory = util_monitor:get_state_history(?MONITOR_TABLE, Model),
            case util_monitor:check_consecutive_fails(StateHistory) of
                true ->
                    alerts:send_alert(<<"Image generation requests failing">>, util:to_binary(node()), <<"critical">>,
                        <<"Requests to DeepInfra are returning non-200 codes for model: ", (util:to_binary(Model))/binary>>);
                false -> ok
            end
        end,
        sets:to_list(ModelsUsed)),
    {noreply, State};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Monitor functions
%%====================================================================

record_time(TimeTakenMs) ->
    Opts = [
        {state_history_length_ms, (100 * ?SECONDS_MS)},
        {ping_interval_ms, (1 * ?SECONDS_MS)}
    ],
    util_monitor:record_state(?MONITOR_TABLE, ?MONITOR_TIME_TAKEN_KEY, TimeTakenMs, Opts).

record_request_success(Model, State) ->
    Opts = [
        {state_history_length_ms, (50 * ?SECONDS_MS)},
        {ping_interval_ms, (1 * ?SECONDS_MS)}
    ],
    util_monitor:record_state(?MONITOR_TABLE, Model, State, Opts).

%%====================================================================
%% Internal functions
%%====================================================================

request_images(Uid, PromptId, Prompt, NegativePrompt, NumImages, RequestId, PromptHelpersEnabled) ->
    gen_server:cast(?PROC(), {request_image, Uid, PromptId, Prompt, NegativePrompt, NumImages, RequestId, PromptHelpersEnabled}).


-spec get_model_parameters(binary(), binary(), pos_integer(), string()) -> jiffy:json_object().
get_model_parameters(Prompt, NegativePrompt, NumImages, ?STABLE_DIFFUSION_1_5) ->
    jiffy:encode({[
        {<<"prompt">>, Prompt},
        {<<"negative_prompt">>, NegativePrompt},
        {<<"num_images">>, NumImages},
        {<<"num_inference_steps">>, 40},
        {<<"width">>, 384},
        {<<"height">>, 512}
    ]}).


parse_and_send_result(Uid, RequestId, RawResult) ->
    ResultMap = jiffy:decode(RawResult, [return_maps]),
    RawImages = maps:get(<<"images">>, ResultMap, []),
    IsFilteredList = maps:get(<<"nsfw_content_detected">>, ResultMap, []),
    Seed = maps:get(<<"seed">>, ResultMap, -1),
    lists:foreach(
        fun({RawImage, IsFiltered}) ->
            case IsFiltered of
                true ->
                    Msg = #pb_msg{
                        id = util_id:new_msg_id(),
                        to_uid = Uid,
                        type = error,
                        payload = #pb_ai_image{
                            id = RequestId
                        }
                    },
                    ?INFO("Sending AI image error (filtered) to ~s, seed = ~p", [Uid, Seed]),
                    ejabberd_router:route(Msg);
                false ->
                    [_, B64Image] = binary:split(RawImage, <<",">>),
                    Image = base64:decode(B64Image),
                    Msg = #pb_msg{
                        id = util_id:new_msg_id(),
                        to_uid = Uid,
                        payload = #pb_ai_image{
                            id = RequestId,
                            image = Image
                        }
                    },
                    ?INFO("Sending AI image to ~s, seed = ~p", [Uid, Seed]),
                    ejabberd_router:route(Msg)
            end
        end,
        lists:zip(RawImages, IsFilteredList)).


check_time_taken(Uid, TimeTakenMs) ->
    case TimeTakenMs > ?TIME_TAKEN_WARNING_THRESHOLD_MS of
        false -> ok;
        true ->
            ?WARNING("Time taken to generate image for ~s was greater than 10s (~pms)", [Uid, TimeTakenMs])
    end.

