%%%-------------------------------------------------------------------
%%% @copyright (C) 2023, HalloApp, Inc.
%%%-------------------------------------------------------------------
-module(mod_http_katchup).
-author("vipin").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("packets.hrl").
-include("util_http.hrl").

-define(HOTSWAP_DTL_PATH, "/home/ha/pkg/ejabberd/current/lib/zzz_hotswap/dtl").
-define(USER_PROFILE_DTL, "user_profile.dtl").

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

-define(APPLE_APP_SITE_ASSOCIATION, <<"apple-app-site-association">>).
-define(ASSET_LINKS, <<"assetlinks.json">>).
-define(WEBSITE, <<"https://katchup.com/w/">>).
-define(IOS_LINK, <<"https://testflight.apple.com/join/aBZO6VoG">>).
-define(ANDROID_LINK, <<"https://play.google.com/store/apps/details?id=com.halloapp.katchup">>).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /katchup/.well-known
process([<<".well-known">>, FileBin], #request{method = 'GET'} = _R)
        when FileBin =:= ?APPLE_APP_SITE_ASSOCIATION orelse FileBin =:= ?ASSET_LINKS ->
    try
        ?INFO("Well known, file: ~s", [FileBin]),
        FileName = filename:join(misc:katchup_dir(), FileBin),
        {200, [?CT_JSON], {file, FileName}}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

%% /katchup/username
process([Username],
        #request{method = 'GET', q = _Q, ip = {NetIP, _Port}, headers = Headers} = _R) when size(Username) > 2 ->
    try
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        ?INFO("Username: ~p, UserAgent ~p Platform: ~p, IP: ~p", [Username, UserAgent, Platform, IP]),
        RedirResponse = case Platform of
            android -> {302, [?LOCATION_HEADER(?ANDROID_LINK)], <<"">>};
            ios -> {302, [?LOCATION_HEADER(?IOS_LINK)], <<"">>};
            _ -> {302, [?LOCATION_HEADER(?WEBSITE)], <<"">>}
        end,
        {ok, Uid} = model_accounts:get_username_uid(Username),
        case Uid =/= undefined andalso model_accounts:account_exists(Uid) of
            true ->
                UserProfile = model_accounts:get_user_profiles(Uid, Uid),
                ?INFO("Uid: ~p, Profile: ~p", [Uid, UserProfile]),
                PushName = UserProfile#pb_user_profile.name,
                Avatar = UserProfile#pb_user_profile.avatar_id,
                {ok, HtmlPage} = dtl_user_profile:render([
                    {push_name, PushName},
                    {avatar, Avatar}
                ]),
                {200, [?CT_HTML], HtmlPage};
            false -> RedirResponse
        end
   catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace: ~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process([Path], _Request) ->
    ?INFO("Path: ~p", [Path]),
    {302, [?LOCATION_HEADER(?WEBSITE)], <<"">>};

process(Path, _Request) ->
    ?INFO("Path: ~p", [Path]),
    {302, [?LOCATION_HEADER(?WEBSITE)], <<"">>}.

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    load_templates(),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ?INFO("reload ~w", [?MODULE]),
    load_templates(),
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

load_templates() ->
    UserProfilePath = dtl_path(?HOTSWAP_DTL_PATH, ?USER_PROFILE_DTL),
    ?INFO("Loading user profile template: ~s", [UserProfilePath]),
    erlydtl:compile_file(
        UserProfilePath,
        dtl_user_profile,
        [{auto_escape, false}]
    ),
    ok.

dtl_path(HotSwapDtlDir, DtlFileName) ->
    HotSwapTextPostPath = filename:join(HotSwapDtlDir, DtlFileName),
    case filelib:is_regular(HotSwapTextPostPath) of
        true -> HotSwapTextPostPath;
        false -> filename:join(misc:dtl_dir(), DtlFileName)
    end.

