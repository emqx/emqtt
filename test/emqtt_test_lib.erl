%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqtt_test_lib).

%% The suites run against an EMQX broker in a container, started by
%% `scripts/ct-broker.sh'. It listens on the loopback address of the test
%% VM at the default ports, and its REST API is at `?API'.
%% See the script for the listeners.

-export([ ensure_broker/0
        , start_listeners/0
        , stop_listeners/0
        , is_running/0
        , restart_listener/1
        , set_ssl_options/2
        , kick_client/1
        , subscriptions/1
        , delay_authn/1
        , delay_authz/1
        , clear_delays/0
        , is_tcp_server_available/2
        , all/1
        , has_quic/0
        ]).

%% TLS helpers
-export([ gen_ca/2
        , gen_host_cert/3
        , gen_host_cert/4
        , ca_key_name/2
        , ca_cert_name/2
        , key_name/2
        , cert_name/2
        ]
       ).

-define(API, "http://127.0.0.1:18083/api/v5").
-define(USERNAME, <<"admin">>).
-define(PASSWORD, <<"public">>).
-define(TOKEN, {?MODULE, token}).
-define(HOOK_SERVER, {?MODULE, hook_server}).

%% The `t_' test cases exported by the suite.
-spec all(module()) -> [atom()].
all(Suite) ->
    [F || {F, 1} <- Suite:module_info(exports),
          lists:prefix("t_", atom_to_list(F))].

%% Wait until the broker serves its REST API, then make sure all listeners
%% run: a failed suite can leave them stopped.
-spec ensure_broker() -> ok.
ensure_broker() ->
    {ok, _} = application:ensure_all_started(inets),
    ok = wait_until(fun() ->
                            case catch request(get, "/status", undefined, []) of
                                {200, _} -> true;
                                _ -> false
                            end
                    end, 60_000),
    start_listeners().

%% Start all listeners and wait until they run.
-spec start_listeners() -> ok.
start_listeners() ->
    lists:foreach(fun(Id) -> {200, _} = api(post, "/listeners/" ++ Id ++ "/start") end,
                  listener_ids()),
    wait_until(fun is_running/0, 10_000).

%% Stop all listeners. This closes every client connection, as a broker
%% restart does, but the sessions and retained messages remain.
-spec stop_listeners() -> ok.
stop_listeners() ->
    lists:foreach(fun(Id) -> {200, _} = api(post, "/listeners/" ++ Id ++ "/stop") end,
                  listener_ids()),
    wait_until(fun() -> lists:all(fun(R) -> not R end, listeners_running()) end, 10_000).

%% `true' when all listeners run.
-spec is_running() -> boolean().
is_running() ->
    lists:all(fun(R) -> R end, listeners_running()).

-spec restart_listener(string()) -> ok.
restart_listener(Id) ->
    {200, _} = api(post, "/listeners/" ++ Id ++ "/restart"),
    ok.

%% Set the TLS options of a listener. `cacertfile', `certfile' and `keyfile'
%% are files on the test VM; their contents are sent to the broker. The
%% options that `Opts' does not give are reset to the defaults of the image.
-spec set_ssl_options(string() | binary(), map()) -> ok.
set_ssl_options(Id0, Opts) ->
    Id = unicode:characters_to_list(Id0),
    Defaults = #{ verify => verify_none
                , fail_if_no_peer_cert => false
                , cacertfile => <<"${EMQX_ETC_DIR}/certs/cacert.pem">>
                , certfile => <<"${EMQX_ETC_DIR}/certs/cert.pem">>
                , keyfile => <<"${EMQX_ETC_DIR}/certs/key.pem">>
                },
    SslOpts = maps:merge(Defaults, maps:map(fun pem/2, Opts)),
    [Type, _Name] = string:split(Id, ":"),
    {200, _} = api(put, "/listeners/" ++ Id,
                   #{id => list_to_binary(Id), type => list_to_binary(Type),
                     ssl_options => SslOpts}),
    ok.

pem(K, File) when K =:= cacertfile; K =:= certfile; K =:= keyfile ->
    {ok, Pem} = file:read_file(File),
    Pem;
pem(_K, V) ->
    V.

%% Kick a client out, as `emqx_cm:kick_session/1' does.
-spec kick_client(binary()) -> ok.
kick_client(ClientId) ->
    {204, _} = api(delete, "/clients/" ++ uri_string:quote(ClientId)),
    ok.

%% The subscriptions to a topic, as the broker reports them.
-spec subscriptions(binary()) -> [map()].
subscriptions(Topic) ->
    {200, #{<<"data">> := Subs}} =
        api(get, "/subscriptions?topic=" ++ uri_string:quote(Topic)),
    Subs.

%% Add an HTTP authenticator that takes `Ms' milliseconds to allow each
%% client. Undo with `clear_delays/0'.
-spec delay_authn(non_neg_integer()) -> ok.
delay_authn(Ms) ->
    {200, _} = api(post, "/authentication",
                   (http_backend("authn", Ms))#{mechanism => password_based,
                                                backend => http}),
    ok.

%% Add an HTTP authorization source that takes `Ms' milliseconds to allow
%% each publish and subscribe. It blocks the channel process for that time.
%% Undo with `clear_delays/0'.
-spec delay_authz(non_neg_integer()) -> ok.
delay_authz(Ms) ->
    {204, _} = api(post, "/authorization/sources",
                   (http_backend("authz", Ms))#{type => http, enable => true}),
    ok.

%% Remove what `delay_authn/1' and `delay_authz/1' added.
-spec clear_delays() -> ok.
clear_delays() ->
    case persistent_term:get(?HOOK_SERVER, undefined) of
        undefined ->
            ok;
        {Pid, _Port} ->
            {Code1, _} = api(delete, "/authentication/password_based:http"),
            true = lists:member(Code1, [204, 404]),
            {Code2, _} = api(delete, "/authorization/sources/http"),
            true = lists:member(Code2, [204, 404]),
            ok = http_hook_server:stop(Pid),
            _ = persistent_term:erase(?HOOK_SERVER),
            ok
    end.

http_backend(Kind, Ms) ->
    Port = hook_server_port(),
    Url = io_lib:format("http://127.0.0.1:~b/~s?delay=~b", [Port, Kind, Ms]),
    #{ method => post
     , url => iolist_to_binary(Url)
     , body => #{clientid => <<"${clientid}">>}
     , headers => #{<<"content-type">> => <<"application/json">>}
     , request_timeout => <<"30s">>
     }.

hook_server_port() ->
    case persistent_term:get(?HOOK_SERVER, undefined) of
        undefined ->
            {ok, Pid, Port} = http_hook_server:start(),
            persistent_term:put(?HOOK_SERVER, {Pid, Port}),
            Port;
        {_Pid, Port} ->
            Port
    end.

-spec is_tcp_server_available(string(), inet:port_number()) -> boolean().
is_tcp_server_available(Host, Port) ->
    case gen_tcp:connect(Host, Port, [], 1000) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            true;
        {error, _} ->
            false
    end.

has_quic() ->
    false =:= os:getenv("BUILD_WITHOUT_QUIC").

%%--------------------------------------------------------------------
%% REST API

listener_ids() ->
    [binary_to_list(Id) || #{<<"id">> := Id} <- listeners()].

listeners_running() ->
    [R || #{<<"status">> := #{<<"running">> := R}} <- listeners()].

listeners() ->
    {200, Listeners} = api(get, "/listeners"),
    Listeners.

api(Method, Path) ->
    api(Method, Path, undefined).

api(Method, Path, Body) ->
    case request(Method, Path, Body, [auth_header()]) of
        {401, _} ->
            %% The token expired: log in again
            _ = persistent_term:erase(?TOKEN),
            request(Method, Path, Body, [auth_header()]);
        Result ->
            Result
    end.

auth_header() ->
    Token = case persistent_term:get(?TOKEN, undefined) of
                undefined ->
                    {200, #{<<"token">> := T}} =
                        request(post, "/login", #{username => ?USERNAME,
                                                  password => ?PASSWORD}, []),
                    persistent_term:put(?TOKEN, T),
                    T;
                T ->
                    T
            end,
    {"authorization", "Bearer " ++ binary_to_list(Token)}.

request(Method, Path, Body, Headers) ->
    Url = ?API ++ Path,
    Req = case {Method, Body} of
              {_, undefined} when Method =:= get; Method =:= delete ->
                  {Url, Headers};
              {_, undefined} ->
                  {Url, Headers, "application/json", <<>>};
              _ ->
                  {Url, Headers, "application/json", iolist_to_binary(json:encode(Body))}
          end,
    {ok, {{_, Code, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Req, [{timeout, 30_000}], [{body_format, binary}]),
    {Code, decode(proplists:get_value("content-type", RespHeaders), RespBody)}.

decode("application/json" ++ _, Bin) when Bin =/= <<>> -> json:decode(Bin);
decode(_ContentType, Bin) -> Bin.

%% Poll `Fun' every 100 ms until it returns `true'.
wait_until(Fun, Timeout) when Timeout > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, Timeout - 100)
    end;
wait_until(Fun, _Timeout) ->
    error({timeout, Fun}).

%%--------------------------------------------------------------------
%% TLS helpers

gen_ca(Path, Name) ->
  %% Generate ca.pem and ca.key which will be used to generate certs
  %% for hosts server and clients
  ECKeyFile = filename(Path, "~s-ec.key", [Name]),
  os:cmd("openssl ecparam -name secp256r1 > " ++ ECKeyFile),
  Cmd = lists:flatten(
          io_lib:format("openssl req -new -x509 -nodes "
                        "-newkey ec:~s "
                        "-keyout ~s -out ~s -days 3650 "
                        "-subj \"/C=SE/O=Internet Widgits Pty Ltd CA\"",
                        [ECKeyFile, ca_key_name(Path, Name),
                         ca_cert_name(Path, Name)])),
  os:cmd(Cmd).

ca_cert_name(Path, Name) ->
    cert_name(Path, Name).
cert_name(Path, Name) ->
    filename(Path, "~s.pem", [Name]).
ca_key_name(Path, Name) ->
    key_name(Path, Name).
key_name(Path, Name) ->
  filename(Path, "~s.key", [Name]).

gen_host_cert(H, CaName, Path) ->
    gen_host_cert(H, CaName, Path, false).

gen_host_cert(H, CaName, Path, IsWildCard) ->
  ECKeyFile = filename(Path, "~s-ec.key", [CaName]),
  CN = maybe_wildcard(str(H), IsWildCard),
  HKey = filename(Path, "~s.key", [H]),
  HCSR = filename(Path, "~s.csr", [H]),
  HPEM = filename(Path, "~s.pem", [H]),
  HEXT = filename(Path, "~s.extfile", [H]),
  CSR_Cmd =
    lists:flatten(
      io_lib:format(
        "openssl req -new -nodes -newkey ec:~s "
        "-keyout ~s -out ~s "
        "-addext \"subjectAltName=DNS:~s\" "
        "-addext keyUsage=digitalSignature,keyAgreement "
        "-subj \"/C=SE/O=Internet Widgits Pty Ltd/CN=~s\"",
        [ECKeyFile, HKey, HCSR, CN, CN])),
  create_file(HEXT,
              "keyUsage=digitalSignature,keyAgreement\n"
              "subjectAltName=DNS:~s\n", [CN]),
  CERT_Cmd =
    lists:flatten(
      io_lib:format(
        "openssl x509 -req "
        "-extfile ~s "
        "-in ~s -CA ~s -CAkey ~s -CAcreateserial "
        "-out ~s -days 500",
        [HEXT, HCSR, ca_cert_name(Path, CaName), ca_key_name(Path, CaName),
         HPEM])),
  os:cmd(CSR_Cmd),
  os:cmd(CERT_Cmd),
  file:delete(HEXT).

filename(Path, F, A) ->
  filename:join(Path, str(io_lib:format(F, A))).

str(Arg) ->
  binary_to_list(iolist_to_binary(Arg)).

create_file(Filename, Fmt, Args) ->
  {ok, F} = file:open(Filename, [write]),
  try
    io:format(F, Fmt, Args)
  after
    file:close(F)
  end,
  ok.

maybe_wildcard(Str, true) ->
    "*."++Str;
maybe_wildcard(Str, false) ->
    Str.
