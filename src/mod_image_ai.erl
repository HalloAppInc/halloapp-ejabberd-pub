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

-include("logger.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
%% other API
-export([
    process_iq/1
]).


-define(STABLE_DIFFUSION_1_5, "runwayml/stable-diffusion-v1-5").
-define(URL(Model), "https://api.deepinfra.com/v1/inference/" ++ Model).

%%====================================================================
%% API
%%====================================================================

process_iq(#pb_iq{from_uid = Uid, payload = #pb_ai_image_request{text = Prompt, num_images = NumImages}} = IQ) ->
    %% TODO: enforce max number of retries per moment notification
    %% TODO: enforce max time between requests
    RequestId = util_id:new_long_id(),
    request_images(Uid, Prompt, NumImages, RequestId),
    pb:make_iq_result(IQ, #pb_ai_image_result{result = pending, id = RequestId}).

%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    ?INFO("Start ~p", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_gen_server_name()),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_ai_image_request, ?MODULE, process_iq),
    ok.

stop(_Host) ->
    ?INFO("Stop ~p", [?MODULE]),
    gen_mod:stop_child(get_gen_server_name()),
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


handle_cast({request_image, Uid, Prompt, NumImages, RequestId, Model},
        #{auth_token := AuthToken, ref_map := RefMap} = State) ->
    Url = ?URL(Model),
    Headers = [{"Authorization", "bearer " ++ AuthToken}],
    Type = "application/json",
    Body = get_model_parameters(Prompt, util:to_integer(NumImages), Model),
    {ok, Ref} = httpc:request(post, {Url, Headers, Type, Body}, [], [{sync, false}]),
    NewRefMap = RefMap#{Ref => {Uid, RequestId, util:now_ms()}},
    ?INFO("~s requesting ~p images, ref = ~p, request_id = ~p", [Uid, NumImages, Ref, RequestId]),
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
            {[{<<"images">>, RawImages}]} = jiffy:decode(Result),
            lists:foreach(
                fun(RawImage) ->
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
                    ejabberd_router:route(Msg)
                end,
                RawImages)
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

request_images(Uid, Prompt, NumImages, RequestId) ->
    %% TODO: some logic for choosing different models?
    gen_server:cast(get_gen_server_name(), {request_image, Uid, Prompt, NumImages, RequestId, ?STABLE_DIFFUSION_1_5}).

get_gen_server_name() ->
    gen_mod:get_module_proc(util:to_binary(node()), ?MODULE).


-spec get_model_parameters(binary(), pos_integer(), string()) -> jiffy:json_object().
get_model_parameters(Prompt, NumImages, ?STABLE_DIFFUSION_1_5) ->
    jiffy:encode({[
        {<<"num_images">>, NumImages},
        {<<"prompt">>, <<Prompt/binary, " ((realistic))">>},
        {<<"negative_prompt">>, <<"unrealistic">>},
        {<<"num_inference_steps">>, 25}
    ]}).

