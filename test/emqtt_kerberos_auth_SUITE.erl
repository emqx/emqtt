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

%% To run this test suite.
%% You will need:
%% - EMQX running with kerberos auth enabled, serving MQTT at port 3883
%% - KDC is up and running.
%%
%% Set up test environment from EMQX CI docker-compose files:
%% - Update .ci/docker-compose-file/docker-compose.yaml to make sure erlang container is exposing port 3883:1883
%% - Command to start KDC: docker-compose -f ./.ci/docker-compose-file/docker-compose.yaml -f ./.ci/docker-compose-file/docker-compose-kdc.yaml up -d
%% - Run EMQX in the container 'erlang.emqx.net'
%% - Configure EMQX default tcp listener with kerberos auth enabled.
%% - Copy client keytab file '/var/lib/secret/krb_authn_cli.keytab' from container 'kdc.emqx.net' to `/tmp`
%%
-module(emqtt_kerberos_auth_SUITE).

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
    Port = list_to_integer(os:getenv("EMQX_PORT", "3883")),
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

%% This must match the server principal
%% For this test, the server principal is "mqtt/erlang.emqx.net@KDC.EMQX.NET"
server_fqdn() -> <<"erlang.emqx.net">>.

realm() -> <<"KDC.EMQX.NET">>.

bin(X) -> iolist_to_binary(X).

server_principal() ->
    bin(["mqtt/", server_fqdn(), "@", realm()]).

client_principal() ->
    bin(["krb_authn_cli@", realm()]).

client_keytab() ->
    <<"/tmp/krb_authn_cli.keytab">>.

auth_init(#{client_keytab := KeytabFile,
            client_principal := ClientPrincipal,
            server_fqdn := ServerFQDN,
            server_principal := ServerPrincipal}) ->
    ok = sasl_auth:kinit(KeytabFile, ClientPrincipal),
    {ok, ClientHandle} = sasl_auth:client_new(<<"mqtt">>, ServerFQDN, ServerPrincipal, <<"krb_authn_cli">>),
    {ok, {sasl_continue, FirstClientToken}} = sasl_auth:client_start(ClientHandle),
    InitialProps = props(FirstClientToken),
    State = #{client_handle => ClientHandle, step => 1},
    {InitialProps, State}.

auth_handle(#{step := 1,
              client_handle := ClientHandle
             } = AuthState, Reason, Props) ->
    ct:pal("step-1: auth packet received:\n  rc: ~p\n  props:\n  ~p", [Reason, Props]),
    case {Reason, Props} of
        {continue_authentication,
         #{'Authentication-Data' := ServerToken}} ->
            {ok, {sasl_continue, ClientToken}} =
                sasl_auth:client_step(ClientHandle, ServerToken),
            OutProps = props(ClientToken),
            NewState = AuthState#{step := 2},
            {continue, {?RC_CONTINUE_AUTHENTICATION, OutProps}, NewState};
        _ ->
            {stop, protocol_error}
    end;
auth_handle(#{step := 2,
              client_handle := ClientHandle
             }, Reason, Props) ->
    ct:pal("step-2: auth packet received:\n  rc: ~p\n  props:\n  ~p", [Reason, Props]),
    case {Reason, Props} of
        {continue_authentication,
         #{'Authentication-Data' := ServerToken}} ->
            {ok, {sasl_ok, ClientToken}} =
                sasl_auth:client_step(ClientHandle, ServerToken),
            OutProps = props(ClientToken),
            NewState = #{done => erlang:system_time()},
            {continue, {?RC_CONTINUE_AUTHENTICATION, OutProps}, NewState};
        _ ->
            {stop, protocol_error}
    end.

props(Data) ->
    #{'Authentication-Method' => <<"GSSAPI-KERBEROS">>,
      'Authentication-Data' => Data
     }.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_basic(Config) ->
    ct:timetrap({seconds, 5}),
    Host = ?config(host, Config),
    Port = ?config(port, Config),
    InitArgs = #{client_keytab => client_keytab(),
                 client_principal => client_principal(),
                 server_fqdn => server_fqdn(),
                 server_principal => server_principal()
                },
    {ok, C} = emqtt:start_link(
                #{ host => Host
                 , port => Port
                 , username => <<"myuser">>
                 , proto_ver => v5
                 , custom_auth_callbacks =>
                       #{ init => {fun ?MODULE:auth_init/1, [InitArgs]}
                        , handle_auth => fun ?MODULE:auth_handle/3
                        }
                 }),
    ?assertMatch({ok, _}, emqtt:connect(C)),
    {ok, _, [0]} = emqtt:subscribe(C, <<"t/#">>),
    ok.

t_bad_method_name(Config) ->
    ct:timetrap({seconds, 5}),
    Host = ?config(host, Config),
    Port = ?config(port, Config),
    InitFn = fun() ->
        KeytabFile = client_keytab(),
        ClientPrincipal = client_principal(),
        ServerFQDN = server_fqdn(),
        ServerPrincipal = server_principal(),
        ok = sasl_auth:kinit(KeytabFile, ClientPrincipal),
        {ok, ClientHandle} = sasl_auth:client_new(<<"mqtt">>, ServerFQDN, ServerPrincipal, <<"krb_authn_cli">>),
        {ok, {sasl_continue, FirstClientToken}} = sasl_auth:client_start(ClientHandle),
        InitialProps0 = props(FirstClientToken),
        %% the expected method is GSSAPI-KERBEROS, using "KERBEROS" should immediately result in a rejection
        InitialProps = InitialProps0#{'Authentication-Method' => <<"KERBEROS">>},
        State = #{client_handle => ClientHandle, step => 1},
        {InitialProps, State}
    end,
    {ok, C} = emqtt:start_link(
                #{ host => Host
                 , port => Port
                 , username => <<"myuser">>
                 , proto_ver => v5
                 , custom_auth_callbacks =>
                       #{init => {InitFn, []},
                         handle_auth => fun ?MODULE:auth_handle/3
                        }
                 }),
    _ = monitor(process, C),
    unlink(C),
    _ = emqtt:connect(C),
    receive
        {'DOWN', _, process, C, Reason} ->
            ?assertEqual({shutdown, not_authorized}, Reason);
        Msg ->
            ct:fail({unexpected, Msg})
    end,
    ok.
