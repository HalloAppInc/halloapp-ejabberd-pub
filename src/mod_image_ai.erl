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
    %% auth_token is the auth token for the DeepInfra service
    %% ref_map is a map of Ref => {Uid, StartTimestampMs}
    AuthToken = mod_aws:get_secret(<<"DeepInfra_Auth_Token">>),
    {ok, #{auth_token => AuthToken, ref_map => #{}}}.


terminate(_Reason, _State) ->
    ok.


handle_call(Msg, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Msg]),
    {noreply, State}.


handle_cast({request_image, Uid, PromptId, UserText, UserNegativePrompt, NumImages, RequestId, PromptHelpersEnabled},
        #{auth_token := AuthToken, ref_map := RefMap} = State) ->
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
    NewRefMap = RefMap#{Ref => {Uid, RequestId, util:now_ms()}},
    ?INFO("~s requesting ~p images, ref = ~p, request_id = ~p, model params: ~p", [Uid, NumImages, Ref, RequestId, Body]),
    {noreply, State#{ref_map => NewRefMap}};

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
        {Uid, RequestId, StartTimeMs} ->
            ?INFO("Result for ~s (ref = ~p, request_id = ~p) generated in ~w ms", [Uid, Ref, RequestId, util:now_ms() - StartTimeMs]),
            parse_and_send_result(Uid, RequestId, Result)
    end,
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({http, {Ref, {{_, Code, HttpMsg}, _Hdrs, _Res}}}, #{ref_map := RefMap} = State) ->
    case maps:get(Ref, RefMap, undefined) of
        undefined ->
            ?ERROR("Got unexpected response with ref: ~p", [Ref]);
        {Uid, RequestId, StartTimeMs} ->
            ?ERROR("Unexpected result from ~s image request (ref = ~p, request_id = ~p, took ~w ms): ~p ~p",
                [Uid, Ref, RequestId, util:now_ms() - StartTimeMs, Code, HttpMsg]),
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
        {Uid, RequestId, StartTimeMs} ->
            ?ERROR("HTTP error during ~s image request (ref = ~p, request_id = ~p, took ~w ms): ~p",
                [Uid, Ref, RequestId, util:now_ms() - StartTimeMs, Reason]),
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

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

