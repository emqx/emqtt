%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqtt_quic).

-export([ connect/4
        , send/2
        , recv/2
        , close/1
        ]).

-export([ setopts/2
        , getstat/2
        , sockname/1
        ]).

connect(Host, Port, Opts, Timeout) ->
    KeepAlive =  proplists:get_value(keepalive, Opts, 60),
    ConnOpts = [ {alpn, ["mqtt"]}
               , {idle_timeout_ms, timer:seconds(KeepAlive * 3)}
               , {peer_unidi_stream_count, 1}
               , {peer_bidi_stream_count, 10}
               | Opts],
    {ok, Conn} = quicer:connect(Host, Port, ConnOpts, Timeout),
    quicer:start_stream(Conn, [{active, false}]).

send(Stream, IoData) when is_list(IoData) ->
    send(Stream, iolist_to_binary(IoData));
send(Stream, Bin) ->
    case quicer:send(Stream, Bin) of
        {ok, _Len} ->
            ok;
        Other ->
            Other
    end.

recv(Stream, Count) ->
    quicer:recv(Stream, Count).

getstat(Stream, Options) ->
    quicer:getstat(Stream, Options).

setopts(Stream, Opts) ->
    [ ok = quicer:setopt(Stream, Opt, OptV)
      || {Opt, OptV} <- Opts ],
    ok.

close(Stream) ->
    quicer:close_stream(Stream, 1000).

sockname(H) ->
    quicer:sockname(H).
