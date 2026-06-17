%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(quic_server).

-export([ start_link/2
        , stop/1
        ]).

start_link(Port, Opts) ->
    spawn_link(fun() -> quic_server(Port, Opts) end).

quic_server(Port, Opts) ->
    {ok, _} = application:ensure_all_started(quic),
    Name = list_to_atom("quic_test_server_" ++ integer_to_list(Port)),
    {ok, _} = quic:start_server(Name, Port, server_opts(Opts)),
    receive
        stop ->
            _ = quic:stop_server(Name),
            ok
    end.

stop(Server) ->
    Server ! stop.

server_opts(Opts) ->
    {ok, Cert, Key} = load_certs(Opts),
    #{ cert => Cert
     , key => Key
     , alpn => alpn(Opts)
     , connection_handler =>
           fun(Conn) ->
               Handler = spawn_link(fun() -> conn_loop(Conn) end),
               {ok, Handler}
           end
     }.

alpn(Opts) ->
    case proplists:get_value(alpn, Opts, ["mqtt"]) of
        L when is_list(L) ->
            [iolist_to_binary(P) || P <- L]
    end.

load_certs(Opts) ->
    CertFile = proplists:get_value(certfile, Opts),
    KeyFile = proplists:get_value(keyfile, Opts),
    {ok, CertPem} = file:read_file(CertFile),
    {ok, KeyPem} = file:read_file(KeyFile),
    [{'Certificate', CertDer, _} | _] = public_key:pem_decode(CertPem),
    {ok, CertDer, decode_key(KeyPem)}.

decode_key(KeyPem) ->
    case public_key:pem_decode(KeyPem) of
        [{'RSAPrivateKey', Der, not_encrypted} | _] ->
            public_key:der_decode('RSAPrivateKey', Der);
        [{'ECPrivateKey', Der, not_encrypted} | _] ->
            public_key:der_decode('ECPrivateKey', Der);
        [{'PrivateKeyInfo', Der, not_encrypted} | _] ->
            public_key:der_decode('PrivateKeyInfo', Der);
        [{_Type, Der, not_encrypted} | _] ->
            Der
    end.

conn_loop(Conn) ->
    receive
        {quic, Conn, {stream_data, StreamId, <<"ping">>, _Fin}} ->
            _ = quic:send_data(Conn, StreamId, <<"pong">>, false),
            conn_loop(Conn);
        {quic, Conn, {closed, _Reason}} ->
            ok;
        {quic, Conn, _Other} ->
            conn_loop(Conn);
        {'DOWN', _, process, Conn, _} ->
            ok;
        _ ->
            conn_loop(Conn)
    end.
