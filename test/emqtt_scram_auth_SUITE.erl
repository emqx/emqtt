%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqtt_scram_auth_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include("emqtt.hrl").

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    emqtt_test_lib:all(?MODULE).

init_per_suite(Config) ->
    Host = os:getenv("EMQX_HOST", "localhost"),
    Port = list_to_integer(os:getenv("EMQX_PORT", "2883")),
    case emqtt_test_lib:is_tcp_server_available(Host, Port) of
        true ->
            [ {host, Host}
            , {port, Port}
            | Config];
        false ->
            {skip, no_emqx}
    end.

end_per_suite(_Config) ->
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

client_first_message() ->
    <<"n,,n=myuser,r=x15obqa'#WGRb-H">>.

auth_init() ->
    #{step => init}.

auth_handle(AuthState0, Reason, Props) ->
    ct:pal("auth packet received:\n  rc: ~p\n  props:\n  ~p", [Reason, Props]),
    case {Reason, Props} of
        {continue_authentication,
         #{ 'Authentication-Method' := <<"SCRAM-SHA-512">>
          , 'Authentication-Data' := ServerFirstMesage
          }} ->
            {continue, ClientFinalMessage, ClientCache} =
                esasl_scram:check_server_first_message(
                  ServerFirstMesage,
                  #{ client_first_message => client_first_message()
                   , password => <<"mypass">>
                   , algorithm => sha512
                   }
                 ),
            AuthState = AuthState0#{step := final, cache => ClientCache},
            OutProps = #{ 'Authentication-Method' => <<"SCRAM-SHA-512">>
                        , 'Authentication-Data' => ClientFinalMessage
                        },
            {continue, {?RC_CONTINUE_AUTHENTICATION, OutProps}, AuthState};
        _ ->
            {stop, protocol_error}
    end.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_scram(Config) ->
    ct:timetrap({seconds, 5}),
    Host = ?config(host, Config),
    Port = ?config(port, Config),
    {ok, C} = emqtt:start_link(
                #{ host => Host
                 , port => Port
                 , username => <<"myuser">>
                 , proto_ver => v5
                 , properties =>
                       #{ 'Authentication-Method' => <<"SCRAM-SHA-512">>
                        , 'Authentication-Data' => client_first_message()
                        }
                 , custom_auth_callbacks =>
                       #{ init => fun ?MODULE:auth_init/0
                        , handle_auth => fun ?MODULE:auth_handle/3
                        }
                 }),
    ?assertMatch({ok, _}, emqtt:connect(C)),
    ok.
