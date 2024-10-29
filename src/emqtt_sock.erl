%%-------------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%-------------------------------------------------------------------------

-module(emqtt_sock).

-export([ connect/4
        , send/2
        , recv/2
        , close/1
        ]).

-export([ sockname/1
        , setopts/2
        , getstat/2
        ]).

-include("emqtt_internal.hrl").

-type(socket() :: inet:socket() | #ssl_socket{}).

-type(sockname() :: {inet:ip_address(), inet:port_number()}).

-type(option() :: gen_tcp:connect_option() | {ssl_opts, [ssl:tls_client_option()]}).

-export_type([socket/0, option/0]).

-define(DEFAULT_TCP_OPTIONS, [binary, {packet, raw}, {active, false},
                              {nodelay, true}]).

-spec(connect(inet:ip_address() | inet:hostname(),
              inet:port_number(), [option()], timeout())
      -> {ok, socket()} | {error, term()}).
connect(Host, Port, SockOpts, Timeout) ->
    TcpOpts = merge_opts(?DEFAULT_TCP_OPTIONS,
                         lists:keydelete(ssl_opts, 1, SockOpts)),
    case gen_tcp:connect(Host, Port, TcpOpts, Timeout) of
        {ok, Sock} ->
            case lists:keyfind(ssl_opts, 1, SockOpts) of
                {ssl_opts, SslOpts} ->
                    ssl_upgrade(Host, Sock, SslOpts, Timeout);
                false -> {ok, Sock}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

ssl_upgrade(Host, Sock, SslOpts0, Timeout) ->
    TlsVersions = proplists:get_value(versions, SslOpts0, []),
    Ciphers = proplists:get_value(ciphers, SslOpts0, default_ciphers(TlsVersions)),
    SslOpts1 = merge_opts(SslOpts0, [{ciphers, Ciphers}]),
    SslOpts2 = apply_sni(SslOpts1, Host),
    SslOpts3 = apply_host_check_fun(SslOpts2),
    SslOpts = maybe_drop_incompatible_options(TlsVersions, SslOpts3),
    case ssl:connect(Sock, SslOpts, Timeout) of
        {ok, SslSock} ->
            {ok, #ssl_socket{tcp = Sock, ssl = SslSock}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec(send(socket(), iodata()) -> ok | {error, einval | closed}).
send(Sock, Data) when is_port(Sock) ->
    send_tcp_data(Sock, Data);
send(#ssl_socket{ssl = SslSock}, Data) ->
    ssl:send(SslSock, Data);
send(QuicStream, Data) when is_reference(QuicStream) ->
    case quicer:send(QuicStream, Data) of
        {ok, _Len} ->
            ok;
        Other ->
            Other
    end.

-if(?OTP_RELEASE >= 26).
send_tcp_data(Sock, Data) ->
    gen_tcp:send(Sock, Data).
-else.
send_tcp_data(Sock, Data) ->
    try erlang:port_command(Sock, Data) of
        true -> ok
    catch
        error:badarg -> {error, einval}
    end.
-endif.

-spec(recv(socket(), non_neg_integer())
      -> {ok, iodata()} | {error, closed | inet:posix()}).
recv(Sock, Length) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length);
recv(#ssl_socket{ssl = SslSock}, Length) ->
    ssl:recv(SslSock, Length);
recv(QuicStream, Length) when is_reference(QuicStream) ->
    quicer:recv(QuicStream, Length).

-spec(close(socket()) -> ok).
close(Sock) when is_port(Sock) ->
    gen_tcp:close(Sock);
close(#ssl_socket{ssl = SslSock}) ->
    ssl:close(SslSock).

-spec(setopts(socket(), [gen_tcp:option() | ssl:tls_client_option()]) -> ok | {error, any()}).
setopts(Sock, Opts) when is_port(Sock) ->
    inet:setopts(Sock, Opts);
setopts(#ssl_socket{ssl = SslSock}, Opts) ->
    ssl:setopts(SslSock, Opts).

-spec(getstat(socket(), [atom()])
      -> {ok, [{atom(), integer()}]} | {error, term()}).
getstat(Sock, Options) when is_port(Sock) ->
    inet:getstat(Sock, Options);
getstat(#ssl_socket{tcp = Sock}, Options) ->
    inet:getstat(Sock, Options).

-spec(sockname(socket()) -> {ok, sockname()} | {error, term()}).
sockname(Sock) when is_port(Sock) ->
    inet:sockname(Sock);
sockname(#ssl_socket{ssl = SslSock}) ->
    ssl:sockname(SslSock);
sockname(Sock) when is_reference(Sock)->
    quicer:sockname(Sock).

-spec(merge_opts(list(), list()) -> list()).
merge_opts(Defaults, Options) ->
    lists:foldl(
      fun({Opt, Val}, Acc) ->
          lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
          lists:usort([Opt | Acc])
      end, Defaults, Options).

default_ciphers(TlsVersions) ->
    lists:foldl(
        fun(TlsVer, Ciphers) ->
            Ciphers ++ ssl:cipher_suites(all, TlsVer)
        end, [], TlsVersions).

apply_sni(Opts, Host) ->
    case lists:keyfind(server_name_indication, 1, Opts) of
        {_, SNI} when SNI =:= "true" orelse
                      SNI =:= <<"true">> orelse
                      SNI =:= true ->
            lists:keystore(server_name_indication, 1, Opts,
                           {server_name_indication, Host});
        _ ->
            Opts
    end.

apply_host_check_fun(Opts) ->
    case proplists:is_defined(customize_hostname_check, Opts) of
        true ->
            Opts;
        false ->
            %% Default Support wildcard cert
            DefHostCheck = {customize_hostname_check,
                            [{match_fun,
                              public_key:pkix_verify_hostname_match_fun(https)}]},
            [DefHostCheck | Opts]
    end.

maybe_drop_incompatible_options(['tlsv1.3'], SslOpts) ->
    Incompatible = [reuse_sessions, secure_renegotiate],
    lists:filter(fun({K, _V}) -> not lists:member(K, Incompatible) end, SslOpts);
maybe_drop_incompatible_options(_, SslOpts) ->
    SslOpts.
