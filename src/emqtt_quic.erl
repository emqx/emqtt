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
        , close/1
        ]).

-export([ setopts/2
        , getstat/2
        ]).

connect(Host, Port, Opts, Timeout) ->
    {ok, Conn} = quicer:connect(Host, Port, Opts, Timeout),
    quicer:start_stream(Conn, []).

send(Stream, IoData) when is_list(IoData) ->
    send(Stream, iolist_to_binary(IoData));
send(Stream, Bin) ->
    case quicer:send(Stream, Bin) of
    {ok, _Len} ->
            ok;
        Other ->
            Other
    end.

%% @todo get_stat
getstat(Stream, Options) ->
    quicer:getstat(Stream, Options).

%% @todo setopts
setopts(_Stream, _Opts) ->
    ok.

close(Stream) ->
    quicer:close_stream(Stream).
