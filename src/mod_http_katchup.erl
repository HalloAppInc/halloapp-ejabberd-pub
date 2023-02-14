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
-export([process/2, convert_avatar/3]).

-define(APPLE_APP_SITE_ASSOCIATION, <<"apple-app-site-association">>).
-define(ASSET_LINKS, <<"assetlinks.json">>).
-define(WEBSITE, <<"https://katchup.com/w/">>).
-define(IOS_LINK, <<"https://apps.apple.com/us/app/katchup/id6444901429">>).
-define(ANDROID_LINK, <<"https://play.google.com/store/apps/details?id=com.halloapp.katchup">>).
-define(CDN_URL, "https://avatar-cdn.halloapp.net/").

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

%% /katchup/v/username
process([<<"v">>, Username],
        #request{method = 'GET', q = _Q, ip = {NetIP, _Port}, headers = Headers} = _R) when size(Username) > 2 ->
    try
        UserAgent = util_http:get_user_agent(Headers),
        Platform = util_http:get_platform(UserAgent),
        IP = util_http:get_ip(NetIP, Headers),
        Username2 = string:lowercase(Username),
        ?INFO("Username: ~p, UserAgent ~p Platform: ~p, IP: ~p", [Username2, UserAgent, Platform, IP]),
        IsFullAvatar = string:str(string:lowercase(binary_to_list(UserAgent)), "whatsapp") =:= 0,
        RedirResponse = case Platform of
            android -> {302, [?LOCATION_HEADER(?ANDROID_LINK)], <<"">>};
            ios -> {302, [?LOCATION_HEADER(?IOS_LINK)], <<"">>};
            _ -> {302, [?LOCATION_HEADER(?WEBSITE)], <<"">>}
        end,
        {ok, Uid} = model_accounts:get_username_uid(Username2),
        case Uid =/= undefined andalso model_accounts:account_exists(Uid) of
            true ->
                UserProfile = model_accounts:get_user_profiles(Uid, Uid),
                case UserProfile#pb_user_profile.avatar_id of
                    undefined ->
                        {302, [?LOCATION_HEADER("https://katchup.com/w/images/tomato.png")], <<"">>};
                    Avatar ->
                        case convert_avatar(binary_to_list(Avatar), binary_to_list(Username2), IsFullAvatar) of
                            {error, Reason2} ->
                                ?ERROR("Convert Avatar: ~p failed: ~p", [Avatar, Reason2]),
                                {302, [?LOCATION_HEADER(?CDN_URL ++ Avatar)], <<"">>};
                            Data -> {200, [?CT_JPG], Data}
                        end
                end;
            false -> RedirResponse
        end
   catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace: ~s",
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
        Username2 = string:lowercase(Username),
        ?INFO("Username: ~p, UserAgent ~p Platform: ~p, IP: ~p", [Username2, UserAgent, Platform, IP]),
        RedirResponse = case Platform of
            android -> {302, [?LOCATION_HEADER(?ANDROID_LINK)], <<"">>};
            ios -> {302, [?LOCATION_HEADER(?IOS_LINK)], <<"">>};
            _ -> {302, [?LOCATION_HEADER(?WEBSITE)], <<"">>}
        end,
        {ok, Uid} = model_accounts:get_username_uid(Username2),
        case Uid =/= undefined andalso model_accounts:account_exists(Uid) of
            true ->
                UserProfile = model_accounts:get_user_profiles(Uid, Uid),
                UserProfileBlob = enif_protobuf:encode(mod_user_profile:compose_user_profile_result(<<"-1">>, Uid)),
                ?INFO("Uid: ~p, Profile: ~p", [Uid, UserProfile]),
                PushName = UserProfile#pb_user_profile.name,
                Avatar = UserProfile#pb_user_profile.avatar_id,
                {ok, HtmlPage} = dtl_user_profile:render([
                    {user_name, Username2},
                    {push_name, PushName},
                    {avatar, Avatar},
                    {base64_enc_blob, base64url:encode(UserProfileBlob)}
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

convert_avatar(Id, Username, IsFullAvatar) ->
    ?INFO("Converting Id: ~p, Username: ~p", [Id, Username]),
    URL = case IsFullAvatar of
        false -> ?CDN_URL ++ Id;
        true -> ?CDN_URL ++ Id ++ "-full"
    end,
    case util_http:fetch_object(URL) of
        {error, Reason} -> {error, Reason};
        {ok, Body} ->
            TmpFileName = "/tmp/" ++ Id,
            TmpFileName1 = "/tmp/" ++ Id ++ ".jpg",
            TmpFileName2 = "/tmp/" ++ Id ++ "2.jpg",
            file:write_file(TmpFileName, Body),
            {Width, Height} = case IsFullAvatar of
                true -> {852, 639};
                false -> {256, 192}
            end,
            TranslateWidth = Width div 2,
            TranslateHeight = Height div 2,
            {EllipsisWidth, EllipsisHeight} = case IsFullAvatar of
                true -> {402, 302};
                false -> {121, 91}
            end,
            ImageSize = util:to_list(Width) ++ "x" ++ util:to_list(Height),
            TranslateCoOrd = util:to_list(TranslateWidth) ++ "," ++ util:to_list(TranslateHeight),
            EllipsisSize = util:to_list(EllipsisWidth) ++ "," ++ util:to_list(EllipsisHeight),
            %% Crop using a rotated ellipse
            Command1 = "convert " ++ TmpFileName ++ " -gravity Center \\( -size " ++ ImageSize ++ " xc:Black -draw \"push graphic-context translate " ++ TranslateCoOrd ++ " rotate -15 fill white stroke black ellipse 0,0 " ++ EllipsisSize ++ " 0,360 pop graphic-context\" -alpha copy \\) -compose copy-opacity -composite -background black -alpha remove " ++ TmpFileName1,
            ?INFO("cmd2: ~p", [Command1]),
            os:cmd(Command1),
            %% Add username sligtly rotated.
            DefFontSize = case IsFullAvatar of
                true -> 116;
                false -> 35
            end,
            Username2 = string:uppercase(Username),
            FontSize = util:to_list(erlang:min(DefFontSize, (DefFontSize * 10) / (length(Username2) + 1))),
            FontCoOrd = case IsFullAvatar of
                true -> "-10,630";
                false -> "-10,185"
            end,
            Command2 = "convert -font /home/ha/RubikBubbles-Regular.ttf -fill \"#C2D69B\" -pointsize " ++ FontSize ++ " -strokewidth 1 -stroke black -draw 'rotate -5 text " ++ FontCoOrd ++ " \"@" ++ Username2 ++ "\"' " ++ TmpFileName1 ++ " " ++ TmpFileName2,
            ?INFO("cmd2: ~p", [Command2]),
            os:cmd(Command2),
            file:delete(TmpFileName),
            file:delete(TmpFileName1),
            {ok, Data} = file:read_file(TmpFileName2),
            file:delete(TmpFileName2),
            Data
    end.

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

