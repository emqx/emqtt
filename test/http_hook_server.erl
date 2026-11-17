%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc An HTTP server for the HTTP authentication and authorization
%% backends of the test broker. It allows every request, after the delay
%% given by the `delay' query parameter (milliseconds). Tests use it to make
%% the broker's channel process slow or unresponsive at a chosen step.
-module(http_hook_server).

-export([start/0, stop/1]).

%% Start the server on a random loopback port. The server is not linked to
%% the caller, so it outlives the test case process.
-spec start() -> {ok, pid(), inet:port_number()}.
start() ->
    Parent = self(),
    {Pid, MRef} = spawn_monitor(fun() -> init(Parent) end),
    receive
        {Pid, {ok, Port}} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Pid, Port};
        {'DOWN', MRef, process, Pid, Reason} ->
            error({http_hook_server_failed, Reason})
    end.

%% Stop the server. The connection handlers are linked to it and stop too.
-spec stop(pid()) -> ok.
stop(Pid) ->
    MRef = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', MRef, process, Pid, _} -> ok end.

init(Parent) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}},
                                     {active, false}, {reuseaddr, true},
                                     {packet, http_bin}]),
    {ok, Port} = inet:port(LSock),
    Parent ! {self(), {ok, Port}},
    accept_loop(LSock).

accept_loop(LSock) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    Pid = spawn_link(fun() -> receive go -> serve(Sock) end end),
    ok = gen_tcp:controlling_process(Sock, Pid),
    Pid ! go,
    accept_loop(LSock).

%% Serve the requests of one keep-alive connection.
serve(Sock) ->
    case read_request(Sock) of
        {ok, Path} ->
            #{path := Kind} = Uri = uri_string:parse(Path),
            Query = uri_string:dissect_query(maps:get(query, Uri, <<>>)),
            Delay = binary_to_integer(proplists:get_value(<<"delay">>, Query, <<"0">>)),
            timer:sleep(Delay),
            Body = response(Kind),
            ok = gen_tcp:send(Sock, ["HTTP/1.1 200 OK\r\n",
                                     "content-type: application/json\r\n",
                                     "content-length: ", integer_to_list(byte_size(Body)), "\r\n",
                                     "\r\n", Body]),
            serve(Sock);
        closed ->
            ok
    end.

response(<<"/authn">>) -> <<"{\"result\":\"allow\",\"is_superuser\":false}">>;
response(<<"/authz">>) -> <<"{\"result\":\"allow\"}">>.

read_request(Sock) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, {http_request, _Method, {abs_path, Path}, _Vsn}} ->
            read_headers(Sock, Path, 0);
        _ ->
            closed
    end.

read_headers(Sock, Path, Len) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, {http_header, _, 'Content-Length', _, V}} ->
            read_headers(Sock, Path, binary_to_integer(V));
        {ok, {http_header, _, _, _, _}} ->
            read_headers(Sock, Path, Len);
        {ok, http_eoh} ->
            ok = inet:setopts(Sock, [{packet, raw}]),
            {ok, _} = recv_body(Sock, Len),
            ok = inet:setopts(Sock, [{packet, http_bin}]),
            {ok, Path};
        _ ->
            closed
    end.

recv_body(_Sock, 0) -> {ok, <<>>};
recv_body(Sock, Len) -> gen_tcp:recv(Sock, Len).
