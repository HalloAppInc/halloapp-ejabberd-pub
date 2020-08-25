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
-behavior(gen_server).

-include("logger.hrl").
-include("sms.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).
%% API
-export([
    send_sms/2,
    prepare_registration_sms/2,
    generate_code/1
]).

-type phone() :: binary().

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w ~p", [?MODULE, self()]),
    X = gen_mod:start_child(?MODULE, Host, Opts, get_proc()),
    ?INFO_MSG("here ~p", [X]),
    X.

stop(_Host) ->
    ?INFO_MSG("start ~w ~p", [?MODULE, self()]),
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

mod_options(_Host) ->
    [].

init(_Stuff) ->
    ?DEBUG("mod_sms: stuff ~p", [_Stuff]),
    process_flag(trap_exit, true),
    State = make_state(),
    {ok, State}.

%%====================================================================
%% API
%%====================================================================

-spec send_sms(Phone :: phone(), Msg :: string()) -> ok | {error, sms_fail}.
send_sms(Phone, Msg) ->
    gen_server:call(get_proc(), {send_sms, Phone, Msg}).

-spec prepare_registration_sms(Code :: binary(), UserAgent :: binary()) -> string().
prepare_registration_sms(Code, UserAgent) ->
    AppHash = get_app_hash(UserAgent),
    Msg = io_lib:format("Your HalloApp verification code: ~s~n~n~n~s", [Code, AppHash]),
    Msg.

-spec generate_code(IsDebug :: boolean()) -> binary().
generate_code(true) ->
    <<"111111">>;
generate_code(false) ->
    list_to_binary(io_lib:format("~6..0w", [crypto:rand_uniform(0, 999999)])).


handle_call({send_sms, Phone, Msg}, _From, State) ->
    ?INFO_MSG("send_sms ~p", [Phone]),
    URL = ?BASE_URL,
    AuthStr = base64:encode_to_string(get_twilio_account_sid(State) ++ ":"
        ++ get_twilio_auth_token(State)),
    Headers = [{"Authorization", "Basic " ++ AuthStr}],
    ?DEBUG("Auth: ~p", [Headers]),
    Type = "application/x-www-form-urlencoded",
    Body = compose_twilio_body(Phone, Msg),
    HTTPOptions = [],
    Options = [],
    ?DEBUG("URL : ~p", [URL]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("twilio: ~p", [Response]),
    Res = case Response of
        {ok, {{_, 201, "CREATED"}, _ResHeaders, _ResBody}} ->
            ok;
        _ ->
            ?ERROR_MSG("Sending SMS failed ~p", [Response]),
            {error, sms_fail}
    end,
    {reply, Res, State};

handle_call(X, _From, State) ->
    ?DEBUG("here ~p", [X]),
    {reply, ok, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) ->
    ?INFO_MSG("terminate ~p", [?MODULE]),
    ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

-spec make_state() -> map().
make_state() ->
    #{twilio_secret_json => do_get_twilio_secret_json()}.

-spec do_get_twilio_secret_json() -> string().
do_get_twilio_secret_json() ->
    binary_to_list(mod_aws:get_secret(<<"Twilio">>)).

%% Caching the secret
-spec get_twilio_secret_json(State :: map()) -> binary().
get_twilio_secret_json(State) ->
    maps:get(twilio_secret_json, State).

-spec get_twilio_account_sid(State :: map()) -> string().
get_twilio_account_sid(State) ->
%%    ?DEBUG("secret json ~p", [get_twilio_secret_json(State)]),
    Json = jiffy:decode(get_twilio_secret_json(State), [return_maps]),
    binary_to_list(maps:get(<<"account_sid">>, Json)).

-spec get_twilio_auth_token(State :: map()) -> string().
get_twilio_auth_token(State) ->
    Json = jiffy:decode(get_twilio_secret_json(State), [return_maps]),
    binary_to_list(maps:get(<<"auth_token">>, Json)).

-spec compose_twilio_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: uri_string:uri_string().
compose_twilio_body(Phone, Message) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    Uri = uri_string:compose_query([{"To", PlusPhone }, {"From", ?FROM_PHONE}, {"Body", Message}], [{encoding, utf8}]),
    Uri.

-spec get_app_hash(binary()) -> binary().
get_app_hash(UserAgent) ->
    case {util_ua:is_android_debug(UserAgent), util_ua:is_android(UserAgent)} of
        {true, true} -> ?ANDROID_DEBUG_HASH;
        {false, true} -> ?ANDROID_RELEASE_HASH;
        _ -> <<"">>
    end.
