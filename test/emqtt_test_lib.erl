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
        ]).

-spec start_emqx() -> ok.
start_emqx() ->
    ensure_test_module(emqx_common_test_helpers),
    ensure_test_module(emqx_ratelimiter_SUITE),
    emqx_common_test_helpers:start_apps([]),
    ok.

-spec stop_emqx() -> ok.
stop_emqx() ->
    ensure_test_module(emqx_common_test_helpers),
    emqx_common_test_helpers:stop_apps([]).

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
