%% Generated automatically
%% DO NOT EDIT: run `make options` instead

-module(ejabberd_option).

-export([access_rules/0, access_rules/1]).
-export([acl/0, acl/1]).
-export([acme/0]).
-export([allow_contrib_modules/0]).
-export([allow_multiple_connections/0, allow_multiple_connections/1]).
-export([anonymous_protocol/0, anonymous_protocol/1]).
-export([api_permissions/0]).
-export([append_host_config/0]).
-export([auth_cache_life_time/0]).
-export([auth_cache_missed/0]).
-export([auth_cache_size/0]).
-export([auth_password_format/0, auth_password_format/1]).
-export([auth_use_cache/0, auth_use_cache/1]).
-export([c2s_cafile/0, c2s_cafile/1]).
-export([c2s_ciphers/0, c2s_ciphers/1]).
-export([c2s_dhfile/0, c2s_dhfile/1]).
-export([c2s_protocol_options/0, c2s_protocol_options/1]).
-export([c2s_tls_compression/0, c2s_tls_compression/1]).
-export([ca_file/0]).
-export([cache_life_time/0, cache_life_time/1]).
-export([cache_missed/0, cache_missed/1]).
-export([cache_size/0, cache_size/1]).
-export([captcha_cmd/0]).
-export([captcha_host/0]).
-export([captcha_limit/0]).
-export([captcha_url/0]).
-export([certfiles/0]).
-export([default_db/0, default_db/1]).
-export([default_ram_db/0, default_ram_db/1]).
-export([define_macro/0, define_macro/1]).
-export([disable_sasl_mechanisms/0, disable_sasl_mechanisms/1]).
-export([domain_balancing/0]).
-export([ext_api_headers/0, ext_api_headers/1]).
-export([ext_api_http_pool_size/0, ext_api_http_pool_size/1]).
-export([ext_api_path_oauth/0]).
-export([ext_api_url/0, ext_api_url/1]).
-export([fqdn/0]).
-export([hide_sensitive_log_data/0, hide_sensitive_log_data/1]).
-export([host_config/0]).
-export([hosts/0]).
-export([include_config_file/0, include_config_file/1]).
-export([language/0, language/1]).
-export([listen/0]).
-export([log_rate_limit/0]).
-export([log_rotate_count/0]).
-export([log_rotate_date/0]).
-export([log_rotate_size/0]).
-export([loglevel/0]).
-export([max_fsm_queue/0, max_fsm_queue/1]).
-export([modules/0, modules/1]).
-export([negotiation_timeout/0]).
-export([net_ticktime/0]).
-export([new_sql_schema/0]).
-export([oauth_access/0, oauth_access/1]).
-export([oauth_cache_life_time/0]).
-export([oauth_cache_missed/0]).
-export([oauth_cache_size/0]).
-export([oauth_expire/0]).
-export([oauth_use_cache/0]).
-export([oom_killer/0]).
-export([oom_queue/0]).
-export([oom_watermark/0]).
-export([pgsql_users_number_estimate/0, pgsql_users_number_estimate/1]).
-export([queue_dir/0]).
-export([queue_type/0, queue_type/1]).
-export([redis_connect_timeout/0]).
-export([redis_db/0]).
-export([redis_password/0]).
-export([redis_pool_size/0]).
-export([redis_port/0]).
-export([redis_queue_type/0]).
-export([redis_server/0]).
-export([registration_timeout/0]).
-export([resource_conflict/0, resource_conflict/1]).
-export([router_cache_life_time/0]).
-export([router_cache_missed/0]).
-export([router_cache_size/0]).
-export([router_use_cache/0]).
-export([rpc_timeout/0]).
-export([shaper/0]).
-export([shaper_rules/0, shaper_rules/1]).
-export([sm_cache_life_time/0]).
-export([sm_cache_missed/0]).
-export([sm_cache_size/0]).
-export([sm_use_cache/0, sm_use_cache/1]).
-export([sql_connect_timeout/0, sql_connect_timeout/1]).
-export([sql_database/0, sql_database/1]).
-export([sql_keepalive_interval/0, sql_keepalive_interval/1]).
-export([sql_password/0, sql_password/1]).
-export([sql_pool_size/0, sql_pool_size/1]).
-export([sql_port/0, sql_port/1]).
-export([sql_query_timeout/0, sql_query_timeout/1]).
-export([sql_queue_type/0, sql_queue_type/1]).
-export([sql_server/0, sql_server/1]).
-export([sql_ssl/0, sql_ssl/1]).
-export([sql_ssl_cafile/0, sql_ssl_cafile/1]).
-export([sql_ssl_certfile/0, sql_ssl_certfile/1]).
-export([sql_ssl_verify/0, sql_ssl_verify/1]).
-export([sql_start_interval/0, sql_start_interval/1]).
-export([sql_type/0, sql_type/1]).
-export([sql_username/0, sql_username/1]).
-export([trusted_proxies/0]).
-export([use_cache/0, use_cache/1]).
-export([validate_stream/0]).
-export([version/0]).
-export([websocket_origin/0]).
-export([websocket_ping_interval/0]).
-export([websocket_timeout/0]).

-spec access_rules() -> [{atom(),acl:access()}].
access_rules() ->
    access_rules(global).
-spec access_rules(global | binary()) -> [{atom(),acl:access()}].
access_rules(Host) ->
    ejabberd_config:get_option({access_rules, Host}).

-spec acl() -> [{atom(),[acl:acl_rule()]}].
acl() ->
    acl(global).
-spec acl(global | binary()) -> [{atom(),[acl:acl_rule()]}].
acl(Host) ->
    ejabberd_config:get_option({acl, Host}).

-spec acme() -> #{'auto'=>boolean(), 'ca_url'=>binary(), 'cert_type'=>'ec' | 'rsa', 'contact'=>[binary()]}.
acme() ->
    ejabberd_config:get_option({acme, global}).

-spec allow_contrib_modules() -> boolean().
allow_contrib_modules() ->
    ejabberd_config:get_option({allow_contrib_modules, global}).

-spec allow_multiple_connections() -> boolean().
allow_multiple_connections() ->
    allow_multiple_connections(global).
-spec allow_multiple_connections(global | binary()) -> boolean().
allow_multiple_connections(Host) ->
    ejabberd_config:get_option({allow_multiple_connections, Host}).

-spec anonymous_protocol() -> 'both' | 'login_anon' | 'sasl_anon'.
anonymous_protocol() ->
    anonymous_protocol(global).
-spec anonymous_protocol(global | binary()) -> 'both' | 'login_anon' | 'sasl_anon'.
anonymous_protocol(Host) ->
    ejabberd_config:get_option({anonymous_protocol, Host}).

-spec api_permissions() -> [ejabberd_access_permissions:permission()].
api_permissions() ->
    ejabberd_config:get_option({api_permissions, global}).

-spec append_host_config() -> [{binary(),any()}].
append_host_config() ->
    ejabberd_config:get_option({append_host_config, global}).

-spec auth_cache_life_time() -> 'infinity' | pos_integer().
auth_cache_life_time() ->
    ejabberd_config:get_option({auth_cache_life_time, global}).

-spec auth_cache_missed() -> boolean().
auth_cache_missed() ->
    ejabberd_config:get_option({auth_cache_missed, global}).

-spec auth_cache_size() -> 'infinity' | pos_integer().
auth_cache_size() ->
    ejabberd_config:get_option({auth_cache_size, global}).

-spec auth_password_format() -> 'plain' | 'scram'.
auth_password_format() ->
    auth_password_format(global).
-spec auth_password_format(global | binary()) -> 'plain' | 'scram'.
auth_password_format(Host) ->
    ejabberd_config:get_option({auth_password_format, Host}).

-spec auth_use_cache() -> boolean().
auth_use_cache() ->
    auth_use_cache(global).
-spec auth_use_cache(global | binary()) -> boolean().
auth_use_cache(Host) ->
    ejabberd_config:get_option({auth_use_cache, Host}).

-spec c2s_cafile() -> 'undefined' | binary().
c2s_cafile() ->
    c2s_cafile(global).
-spec c2s_cafile(global | binary()) -> 'undefined' | binary().
c2s_cafile(Host) ->
    ejabberd_config:get_option({c2s_cafile, Host}).

-spec c2s_ciphers() -> 'undefined' | binary().
c2s_ciphers() ->
    c2s_ciphers(global).
-spec c2s_ciphers(global | binary()) -> 'undefined' | binary().
c2s_ciphers(Host) ->
    ejabberd_config:get_option({c2s_ciphers, Host}).

-spec c2s_dhfile() -> 'undefined' | binary().
c2s_dhfile() ->
    c2s_dhfile(global).
-spec c2s_dhfile(global | binary()) -> 'undefined' | binary().
c2s_dhfile(Host) ->
    ejabberd_config:get_option({c2s_dhfile, Host}).

-spec c2s_protocol_options() -> 'undefined' | binary().
c2s_protocol_options() ->
    c2s_protocol_options(global).
-spec c2s_protocol_options(global | binary()) -> 'undefined' | binary().
c2s_protocol_options(Host) ->
    ejabberd_config:get_option({c2s_protocol_options, Host}).

-spec c2s_tls_compression() -> 'false' | 'true' | 'undefined'.
c2s_tls_compression() ->
    c2s_tls_compression(global).
-spec c2s_tls_compression(global | binary()) -> 'false' | 'true' | 'undefined'.
c2s_tls_compression(Host) ->
    ejabberd_config:get_option({c2s_tls_compression, Host}).

-spec ca_file() -> binary().
ca_file() ->
    ejabberd_config:get_option({ca_file, global}).

-spec cache_life_time() -> 'infinity' | pos_integer().
cache_life_time() ->
    cache_life_time(global).
-spec cache_life_time(global | binary()) -> 'infinity' | pos_integer().
cache_life_time(Host) ->
    ejabberd_config:get_option({cache_life_time, Host}).

-spec cache_missed() -> boolean().
cache_missed() ->
    cache_missed(global).
-spec cache_missed(global | binary()) -> boolean().
cache_missed(Host) ->
    ejabberd_config:get_option({cache_missed, Host}).

-spec cache_size() -> 'infinity' | pos_integer().
cache_size() ->
    cache_size(global).
-spec cache_size(global | binary()) -> 'infinity' | pos_integer().
cache_size(Host) ->
    ejabberd_config:get_option({cache_size, Host}).

-spec captcha_cmd() -> 'undefined' | binary().
captcha_cmd() ->
    ejabberd_config:get_option({captcha_cmd, global}).

-spec captcha_host() -> binary().
captcha_host() ->
    ejabberd_config:get_option({captcha_host, global}).

-spec captcha_limit() -> 'infinity' | pos_integer().
captcha_limit() ->
    ejabberd_config:get_option({captcha_limit, global}).

-spec captcha_url() -> 'undefined' | binary().
captcha_url() ->
    ejabberd_config:get_option({captcha_url, global}).

-spec certfiles() -> 'undefined' | [binary()].
certfiles() ->
    ejabberd_config:get_option({certfiles, global}).

-spec default_db() -> 'mnesia' | 'sql'.
default_db() ->
    default_db(global).
-spec default_db(global | binary()) -> 'mnesia' | 'sql'.
default_db(Host) ->
    ejabberd_config:get_option({default_db, Host}).

-spec default_ram_db() -> 'mnesia' | 'redis' | 'sql'.
default_ram_db() ->
    default_ram_db(global).
-spec default_ram_db(global | binary()) -> 'mnesia' | 'redis' | 'sql'.
default_ram_db(Host) ->
    ejabberd_config:get_option({default_ram_db, Host}).

-spec define_macro() -> any().
define_macro() ->
    define_macro(global).
-spec define_macro(global | binary()) -> any().
define_macro(Host) ->
    ejabberd_config:get_option({define_macro, Host}).

-spec disable_sasl_mechanisms() -> [binary()].
disable_sasl_mechanisms() ->
    disable_sasl_mechanisms(global).
-spec disable_sasl_mechanisms(global | binary()) -> [binary()].
disable_sasl_mechanisms(Host) ->
    ejabberd_config:get_option({disable_sasl_mechanisms, Host}).

-spec domain_balancing() -> #{binary()=>#{'component_number':=1..1114111, 'type'=>'bare_destination' | 'bare_source' | 'destination' | 'random' | 'source'}}.
domain_balancing() ->
    ejabberd_config:get_option({domain_balancing, global}).

-spec ext_api_headers() -> binary().
ext_api_headers() ->
    ext_api_headers(global).
-spec ext_api_headers(global | binary()) -> binary().
ext_api_headers(Host) ->
    ejabberd_config:get_option({ext_api_headers, Host}).

-spec ext_api_http_pool_size() -> pos_integer().
ext_api_http_pool_size() ->
    ext_api_http_pool_size(global).
-spec ext_api_http_pool_size(global | binary()) -> pos_integer().
ext_api_http_pool_size(Host) ->
    ejabberd_config:get_option({ext_api_http_pool_size, Host}).

-spec ext_api_path_oauth() -> binary().
ext_api_path_oauth() ->
    ejabberd_config:get_option({ext_api_path_oauth, global}).

-spec ext_api_url() -> binary().
ext_api_url() ->
    ext_api_url(global).
-spec ext_api_url(global | binary()) -> binary().
ext_api_url(Host) ->
    ejabberd_config:get_option({ext_api_url, Host}).

-spec fqdn() -> [binary()].
fqdn() ->
    ejabberd_config:get_option({fqdn, global}).

-spec hide_sensitive_log_data() -> boolean().
hide_sensitive_log_data() ->
    hide_sensitive_log_data(global).
-spec hide_sensitive_log_data(global | binary()) -> boolean().
hide_sensitive_log_data(Host) ->
    ejabberd_config:get_option({hide_sensitive_log_data, Host}).

-spec host_config() -> [{binary(),any()}].
host_config() ->
    ejabberd_config:get_option({host_config, global}).

-spec hosts() -> [binary(),...].
hosts() ->
    ejabberd_config:get_option({hosts, global}).

-spec include_config_file() -> any().
include_config_file() ->
    include_config_file(global).
-spec include_config_file(global | binary()) -> any().
include_config_file(Host) ->
    ejabberd_config:get_option({include_config_file, Host}).

-spec language() -> binary().
language() ->
    language(global).
-spec language(global | binary()) -> binary().
language(Host) ->
    ejabberd_config:get_option({language, Host}).

-spec listen() -> [ejabberd_listener:listener()].
listen() ->
    ejabberd_config:get_option({listen, global}).

-spec log_rate_limit() -> 'undefined' | non_neg_integer().
log_rate_limit() ->
    ejabberd_config:get_option({log_rate_limit, global}).

-spec log_rotate_count() -> 'undefined' | non_neg_integer().
log_rotate_count() ->
    ejabberd_config:get_option({log_rotate_count, global}).

-spec log_rotate_date() -> 'undefined' | string().
log_rotate_date() ->
    ejabberd_config:get_option({log_rotate_date, global}).

-spec log_rotate_size() -> 'undefined' | non_neg_integer().
log_rotate_size() ->
    ejabberd_config:get_option({log_rotate_size, global}).

-spec loglevel() -> 0 | 1 | 2 | 3 | 4 | 5.
loglevel() ->
    ejabberd_config:get_option({loglevel, global}).

-spec max_fsm_queue() -> 'undefined' | pos_integer().
max_fsm_queue() ->
    max_fsm_queue(global).
-spec max_fsm_queue(global | binary()) -> 'undefined' | pos_integer().
max_fsm_queue(Host) ->
    ejabberd_config:get_option({max_fsm_queue, Host}).

-spec modules() -> [{module(),gen_mod:opts(),integer()}].
modules() ->
    modules(global).
-spec modules(global | binary()) -> [{module(),gen_mod:opts(),integer()}].
modules(Host) ->
    ejabberd_config:get_option({modules, Host}).

-spec negotiation_timeout() -> pos_integer().
negotiation_timeout() ->
    ejabberd_config:get_option({negotiation_timeout, global}).

-spec net_ticktime() -> pos_integer().
net_ticktime() ->
    ejabberd_config:get_option({net_ticktime, global}).

-spec new_sql_schema() -> boolean().
new_sql_schema() ->
    ejabberd_config:get_option({new_sql_schema, global}).

-spec oauth_access() -> 'none' | acl:acl().
oauth_access() ->
    oauth_access(global).
-spec oauth_access(global | binary()) -> 'none' | acl:acl().
oauth_access(Host) ->
    ejabberd_config:get_option({oauth_access, Host}).

-spec oauth_cache_life_time() -> 'infinity' | pos_integer().
oauth_cache_life_time() ->
    ejabberd_config:get_option({oauth_cache_life_time, global}).

-spec oauth_cache_missed() -> boolean().
oauth_cache_missed() ->
    ejabberd_config:get_option({oauth_cache_missed, global}).

-spec oauth_cache_size() -> 'infinity' | pos_integer().
oauth_cache_size() ->
    ejabberd_config:get_option({oauth_cache_size, global}).

-spec oauth_expire() -> non_neg_integer().
oauth_expire() ->
    ejabberd_config:get_option({oauth_expire, global}).

-spec oauth_use_cache() -> boolean().
oauth_use_cache() ->
    ejabberd_config:get_option({oauth_use_cache, global}).

-spec oom_killer() -> boolean().
oom_killer() ->
    ejabberd_config:get_option({oom_killer, global}).

-spec oom_queue() -> pos_integer().
oom_queue() ->
    ejabberd_config:get_option({oom_queue, global}).

-spec oom_watermark() -> 1..255.
oom_watermark() ->
    ejabberd_config:get_option({oom_watermark, global}).

-spec pgsql_users_number_estimate() -> boolean().
pgsql_users_number_estimate() ->
    pgsql_users_number_estimate(global).
-spec pgsql_users_number_estimate(global | binary()) -> boolean().
pgsql_users_number_estimate(Host) ->
    ejabberd_config:get_option({pgsql_users_number_estimate, Host}).

-spec queue_dir() -> 'undefined' | binary().
queue_dir() ->
    ejabberd_config:get_option({queue_dir, global}).

-spec queue_type() -> 'file' | 'ram'.
queue_type() ->
    queue_type(global).
-spec queue_type(global | binary()) -> 'file' | 'ram'.
queue_type(Host) ->
    ejabberd_config:get_option({queue_type, Host}).

-spec redis_connect_timeout() -> pos_integer().
redis_connect_timeout() ->
    ejabberd_config:get_option({redis_connect_timeout, global}).

-spec redis_db() -> non_neg_integer().
redis_db() ->
    ejabberd_config:get_option({redis_db, global}).

-spec redis_password() -> string().
redis_password() ->
    ejabberd_config:get_option({redis_password, global}).

-spec redis_pool_size() -> pos_integer().
redis_pool_size() ->
    ejabberd_config:get_option({redis_pool_size, global}).

-spec redis_port() -> 1..1114111.
redis_port() ->
    ejabberd_config:get_option({redis_port, global}).

-spec redis_queue_type() -> 'file' | 'ram'.
redis_queue_type() ->
    ejabberd_config:get_option({redis_queue_type, global}).

-spec redis_server() -> string().
redis_server() ->
    ejabberd_config:get_option({redis_server, global}).

-spec registration_timeout() -> 'infinity' | pos_integer().
registration_timeout() ->
    ejabberd_config:get_option({registration_timeout, global}).

-spec resource_conflict() -> 'acceptnew' | 'closenew' | 'closeold' | 'setresource'.
resource_conflict() ->
    resource_conflict(global).
-spec resource_conflict(global | binary()) -> 'acceptnew' | 'closenew' | 'closeold' | 'setresource'.
resource_conflict(Host) ->
    ejabberd_config:get_option({resource_conflict, Host}).

-spec router_cache_life_time() -> 'infinity' | pos_integer().
router_cache_life_time() ->
    ejabberd_config:get_option({router_cache_life_time, global}).

-spec router_cache_missed() -> boolean().
router_cache_missed() ->
    ejabberd_config:get_option({router_cache_missed, global}).

-spec router_cache_size() -> 'infinity' | pos_integer().
router_cache_size() ->
    ejabberd_config:get_option({router_cache_size, global}).

-spec router_use_cache() -> boolean().
router_use_cache() ->
    ejabberd_config:get_option({router_use_cache, global}).

-spec rpc_timeout() -> pos_integer().
rpc_timeout() ->
    ejabberd_config:get_option({rpc_timeout, global}).

-spec shaper() -> #{atom()=>ejabberd_shaper:shaper_rate()}.
shaper() ->
    ejabberd_config:get_option({shaper, global}).

-spec shaper_rules() -> [{atom(),[ejabberd_shaper:shaper_rule()]}].
shaper_rules() ->
    shaper_rules(global).
-spec shaper_rules(global | binary()) -> [{atom(),[ejabberd_shaper:shaper_rule()]}].
shaper_rules(Host) ->
    ejabberd_config:get_option({shaper_rules, Host}).

-spec sm_cache_life_time() -> 'infinity' | pos_integer().
sm_cache_life_time() ->
    ejabberd_config:get_option({sm_cache_life_time, global}).

-spec sm_cache_missed() -> boolean().
sm_cache_missed() ->
    ejabberd_config:get_option({sm_cache_missed, global}).

-spec sm_cache_size() -> 'infinity' | pos_integer().
sm_cache_size() ->
    ejabberd_config:get_option({sm_cache_size, global}).

-spec sm_use_cache() -> boolean().
sm_use_cache() ->
    sm_use_cache(global).
-spec sm_use_cache(global | binary()) -> boolean().
sm_use_cache(Host) ->
    ejabberd_config:get_option({sm_use_cache, Host}).

-spec sql_connect_timeout() -> pos_integer().
sql_connect_timeout() ->
    sql_connect_timeout(global).
-spec sql_connect_timeout(global | binary()) -> pos_integer().
sql_connect_timeout(Host) ->
    ejabberd_config:get_option({sql_connect_timeout, Host}).

-spec sql_database() -> 'undefined' | binary().
sql_database() ->
    sql_database(global).
-spec sql_database(global | binary()) -> 'undefined' | binary().
sql_database(Host) ->
    ejabberd_config:get_option({sql_database, Host}).

-spec sql_keepalive_interval() -> 'undefined' | pos_integer().
sql_keepalive_interval() ->
    sql_keepalive_interval(global).
-spec sql_keepalive_interval(global | binary()) -> 'undefined' | pos_integer().
sql_keepalive_interval(Host) ->
    ejabberd_config:get_option({sql_keepalive_interval, Host}).

-spec sql_password() -> binary().
sql_password() ->
    sql_password(global).
-spec sql_password(global | binary()) -> binary().
sql_password(Host) ->
    ejabberd_config:get_option({sql_password, Host}).

-spec sql_pool_size() -> pos_integer().
sql_pool_size() ->
    sql_pool_size(global).
-spec sql_pool_size(global | binary()) -> pos_integer().
sql_pool_size(Host) ->
    ejabberd_config:get_option({sql_pool_size, Host}).

-spec sql_port() -> 1..1114111.
sql_port() ->
    sql_port(global).
-spec sql_port(global | binary()) -> 1..1114111.
sql_port(Host) ->
    ejabberd_config:get_option({sql_port, Host}).

-spec sql_query_timeout() -> pos_integer().
sql_query_timeout() ->
    sql_query_timeout(global).
-spec sql_query_timeout(global | binary()) -> pos_integer().
sql_query_timeout(Host) ->
    ejabberd_config:get_option({sql_query_timeout, Host}).

-spec sql_queue_type() -> 'file' | 'ram'.
sql_queue_type() ->
    sql_queue_type(global).
-spec sql_queue_type(global | binary()) -> 'file' | 'ram'.
sql_queue_type(Host) ->
    ejabberd_config:get_option({sql_queue_type, Host}).

-spec sql_server() -> binary().
sql_server() ->
    sql_server(global).
-spec sql_server(global | binary()) -> binary().
sql_server(Host) ->
    ejabberd_config:get_option({sql_server, Host}).

-spec sql_ssl() -> boolean().
sql_ssl() ->
    sql_ssl(global).
-spec sql_ssl(global | binary()) -> boolean().
sql_ssl(Host) ->
    ejabberd_config:get_option({sql_ssl, Host}).

-spec sql_ssl_cafile() -> 'undefined' | binary().
sql_ssl_cafile() ->
    sql_ssl_cafile(global).
-spec sql_ssl_cafile(global | binary()) -> 'undefined' | binary().
sql_ssl_cafile(Host) ->
    ejabberd_config:get_option({sql_ssl_cafile, Host}).

-spec sql_ssl_certfile() -> 'undefined' | binary().
sql_ssl_certfile() ->
    sql_ssl_certfile(global).
-spec sql_ssl_certfile(global | binary()) -> 'undefined' | binary().
sql_ssl_certfile(Host) ->
    ejabberd_config:get_option({sql_ssl_certfile, Host}).

-spec sql_ssl_verify() -> boolean().
sql_ssl_verify() ->
    sql_ssl_verify(global).
-spec sql_ssl_verify(global | binary()) -> boolean().
sql_ssl_verify(Host) ->
    ejabberd_config:get_option({sql_ssl_verify, Host}).

-spec sql_start_interval() -> pos_integer().
sql_start_interval() ->
    sql_start_interval(global).
-spec sql_start_interval(global | binary()) -> pos_integer().
sql_start_interval(Host) ->
    ejabberd_config:get_option({sql_start_interval, Host}).

-spec sql_type() -> 'mssql' | 'mysql' | 'odbc' | 'pgsql' | 'sqlite'.
sql_type() ->
    sql_type(global).
-spec sql_type(global | binary()) -> 'mssql' | 'mysql' | 'odbc' | 'pgsql' | 'sqlite'.
sql_type(Host) ->
    ejabberd_config:get_option({sql_type, Host}).

-spec sql_username() -> binary().
sql_username() ->
    sql_username(global).
-spec sql_username(global | binary()) -> binary().
sql_username(Host) ->
    ejabberd_config:get_option({sql_username, Host}).

-spec trusted_proxies() -> 'all' | [{inet:ip4_address() | inet:ip6_address(),byte()}].
trusted_proxies() ->
    ejabberd_config:get_option({trusted_proxies, global}).

-spec use_cache() -> boolean().
use_cache() ->
    use_cache(global).
-spec use_cache(global | binary()) -> boolean().
use_cache(Host) ->
    ejabberd_config:get_option({use_cache, Host}).

-spec validate_stream() -> boolean().
validate_stream() ->
    ejabberd_config:get_option({validate_stream, global}).

-spec version() -> binary().
version() ->
    ejabberd_config:get_option({version, global}).

-spec websocket_origin() -> [binary()].
websocket_origin() ->
    ejabberd_config:get_option({websocket_origin, global}).

-spec websocket_ping_interval() -> pos_integer().
websocket_ping_interval() ->
    ejabberd_config:get_option({websocket_ping_interval, global}).

-spec websocket_timeout() -> pos_integer().
websocket_timeout() ->
    ejabberd_config:get_option({websocket_timeout, global}).

