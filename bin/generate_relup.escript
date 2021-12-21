#!/usr/bin/env escript
%%! -noinput
%% -*- mode: erlang;erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ft=erlang ts=4 sw=4 et

main([NewVsn, OldVsns, RelDir, LibDir, OutDir]) ->
    Paths=[ RelDir | filelib:wildcard(LibDir ++ "*/ebin/")],
    UpFrom = string:tokens(OldVsns, ","),
    DownTo = UpFrom,
    case systools:make_relup(NewVsn, UpFrom, DownTo, [{path,Paths} ,{outdir, OutDir}]) of
        ok ->
            io:format("success! relup in outdir: ~p ~n", [OutDir]);
        Error ->
            io:format("Failed: ~p !~n", [Error]),
            halt(1)
    end.
