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

-export([ start_emqx/0
        , stop_emqx/0
        , ensure_test_module/1
        , ensure_listener/4
        , ensure_quic_listener/2
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
        , set_ssl_options/2
        ]
       ).

-spec all(module()) -> list(string()).
all(Suite) ->
    ensure_test_module(emqx_common_test_helpers),
    emqx_common_test_helpers:all(Suite).

-spec start_emqx() -> ok.
start_emqx() ->
    ensure_test_module(emqx_common_test_helpers),
    ensure_test_module(emqx_ratelimiter_SUITE),
    emqx_common_test_helpers:start_apps([]),
    ok = ensure_quic_listener(mqtt, 14567),
    ok.

-spec stop_emqx() -> ok.
stop_emqx() ->
    ensure_test_module(emqx_common_test_helpers),
    emqx_common_test_helpers:stop_apps([]).

is_tcp_server_available(Host, Port) ->
    ensure_test_module(emqx_common_test_helpers),
    emqx_common_test_helpers:is_tcp_server_available(Host, Port).

-spec ensure_test_module(M::atom()) -> ok.
ensure_test_module(M) ->
    false == code:is_loaded(M) andalso
        compile_emqx_test_module(M).

-spec compile_emqx_test_module(M::atom()) -> ok.
compile_emqx_test_module(M) ->
    EmqxDir = code:lib_dir(emqx),
    EmqttDir = code:lib_dir(emqtt),
    MFilename= filename:join([EmqxDir, "test", M]),
    OutDir = filename:join([EmqttDir, "test"]),
    {ok, _} = compile:file(MFilename, [{outdir, OutDir}]),
    ok.

-spec ensure_quic_listener(atom(), inet:port_number()) -> ok.
ensure_quic_listener(Name, BindPort) ->
    case has_quic() of
        true ->
            ok = ensure_listener(quic, Name, {0, 0, 0, 0}, BindPort);
        _ ->
            ok
    end.

-spec ensure_listener(atom(), atom(), inet:ip_address(), inet:port_number()) -> ok.
ensure_listener(Type, Name, BindAddr, BindPort) ->
    Type =:= quic andalso application:ensure_all_started(quicer),
    BaseConf = #{
                 enable => true,
                 bind => {BindAddr, BindPort},
                 acceptors => 16,
                 max_connections => 1024000,
                 limiter => #{},
                 mountpoint => <<>>,
                 zone => default,
                 proxy_protocol => false,
                 tcp_options => #{active_n => 10},
                 hibernate_after => 5000
                },
    TypeSpecificConf = listener_conf(Type),
    Conf = maps:merge(BaseConf, TypeSpecificConf),
    emqx_config:put([listeners, Type, Name], Conf),
    case emqx_listeners:start_listener(Type, Name, Conf) of
        ok -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

listener_conf(quic) ->
    CertFile = filename:join(code:lib_dir(emqx), "etc/certs/cert.pem"),
    KeyFile = filename:join(code:lib_dir(emqx), "etc/certs/key.pem"),
    SslOpts = #{
      certfile => CertFile,
      ciphers =>
      [
       "TLS_AES_256_GCM_SHA384",
       "TLS_AES_128_GCM_SHA256",
       "TLS_CHACHA20_POLY1305_SHA256"
      ],
      keyfile => KeyFile
     },
    #{ssl_options => SslOpts};
listener_conf(ws) ->
    #{
      websocket =>
      #{check_origin_enable => false,
        compress => false,
        deflate_opts =>
        #{client_context_takeover => takeover,
          client_max_window_bits => 15,
          mem_level => 8,
          server_context_takeover => takeover,
          server_max_window_bits => 15,
          strategy => default
         },
        fail_if_no_subprotocol => true,
        idle_timeout => 7200000,
        max_frame_size => infinity,
        mqtt_path => "/mqtt",
        mqtt_piggyback => multiple,
        proxy_address_header => "x-forwarded-for",
        proxy_port_header => "x-forwarded-port",
        supported_subprotocols => ["mqtt","mqtt-v3","mqtt-v3.1.1","mqtt-v5"],
        validate_utf8 => true}
     };
listener_conf(_) -> #{}.

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

set_ssl_options(ListenerId, Opts) ->
    {ok, #{type := Type, name := Name}} = emqx_listeners:parse_listener_id(ListenerId),
    emqx_config:put_listener_conf(Type, Name, [ssl_options], Opts),
    ok = emqx_listeners:restart_listener(ListenerId).

has_quic() ->
    false =:= os:getenv("BUILD_WITHOUT_QUIC").
