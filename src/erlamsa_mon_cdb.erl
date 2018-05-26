-module(erlamsa_mon_cdb).  

-include("erlamsa.hrl").
         
-export([init/1, start/1, init_port/3]).

parse_params(["after_params=" ++ AfterParam|T], Acc) ->
    parse_params(T, maps:put(do_after_params, AfterParam, Acc));
parse_params(["after=" ++ AfterType|T], Acc) ->
    parse_params(T, maps:put(do_after_type, list_to_atom(AfterType), Acc));
%%TODO:add launch in addition to attach
parse_params(["pid=" ++ App|T], Acc) ->
    parse_params(T, maps:put(run, io_lib:format("-p ~s", [App]), Acc));
parse_params(["attach=" ++ App|T], Acc) ->
    parse_params(T, maps:put(run, io_lib:format("-pn ~s", [App]), Acc));
parse_params(["app=" ++ App|T], Acc) ->
    parse_params(T, maps:put(run, io_lib:format("~s", [App]), Acc));
parse_params([_H|T], Acc) ->
    %%TODO: do it in more elegant way
    io:format("Invalid monitor parameter: ~p, skipping...", [T]),
    parse_params(T, Acc);
parse_params([], Acc) ->
    Acc.

do_after(exec, Opts) ->
    ExecPath = maps:get(do_after_params, Opts, ""),
    os:cmd(ExecPath); %%TODO: add result to logs
do_after(nil, _Opts) -> ok.

start(Params) ->
    Pid = spawn(?MODULE, start, [Params]),
    {ok, Pid}.

init(Params) -> 
    MonOpts = parse_params(string:split(Params,",",all), maps:new()),
    cdb_start(MonOpts, ?START_MONITOR_ATTEMPTS).

cdb_start(_MonOpts, 0) ->                         
    erlamsa_logger:log(info, "cdb_monitor: too many failures (~p), giving up", [?START_MONITOR_ATTEMPTS]);
cdb_start(MonOpts, N) ->
    erlamsa_logger:log(info, "entering cdb_monitor, options parsing complete", []),
    Cmd = io_lib:format("cdb ~s", [maps:get(run, MonOpts, "no_app_provided")]),
    erlamsa_logger:log(info, "cdb_monitor attempting to run: '~s'", [Cmd]),
    {Pid, StartResult} = start_port(Cmd, []), %% TODO:ugly, rewrite
    cdb_cmdline(MonOpts, Pid, StartResult, N).	
                                          
cdb_cmdline(MonOpts, _Pid, {State, Acc}, N) when State =:= closed; State =:= process_exit ->
    erlamsa_logger:log(info, "cdb_monitor error (~p): '~s'", [State, Acc]),
    cdb_start(MonOpts, N-1);                                                                                                          	
cdb_cmdline(MonOpts, Pid, StartResult, _N) ->
    erlamsa_logger:log(info, "cdb_monitor execution returned, seems legit: '~s'", [StartResult]),
    CrashMsg = call_port(Pid, "g\r\n"), 
    erlamsa_logger:log(info, "cdb_monitor [-->!!!<--] detected event (CRASH?!): ~s", [CrashMsg]),
    Backtrace = call_port(Pid, "k\r\n"),
    erlamsa_logger:log(info, "cdb_monitor backtrace: ~s", [Backtrace]),
    Registers = call_port(Pid, "r\r\n"),
    erlamsa_logger:log(info, "cdb_monitor registers: ~s", [Registers]),
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_local_time(erlang:now()),
    DumpFile = io_lib:format("~s_~4..0w_~2..0w_~2..0w_~2..0w_~2..0w_~2..0w.minidump", [maps:get(app, MonOpts, ""), Year, Month, Day, Hour, Minute, Second]),
    Minidump = call_port(Pid, io_lib:format(".dump /m ~s \r\n", [DumpFile])),
    erlamsa_logger:log(info, "cdb_monitor minidump saved to ~s with result: ~s", [DumpFile, Minidump]),
    call_port_no_wait(Pid, "q\r\n"),
    stop_port(Pid),
    erlamsa_logger:log(info, "cdb_monitor cdb finished.", []),
    erlamsa_logger:log(info, "cdb_monitor executing after actions", []),
    do_after(maps:get(do_after_type, MonOpts, nil), MonOpts),
    cdb_start(MonOpts, ?START_MONITOR_ATTEMPTS).


start_port(ExtPrg, ExtraParams) ->
    Pid = spawn(?MODULE, init_port, [ExtPrg, ExtraParams, self()]),
    receive
        {Pid, Result} ->
            {Pid, Result}
    end.

stop_port(Pid) ->
    Pid ! stop.

call_port(Pid, Msg) ->
    Pid ! {call, self(), Msg},
    receive
        {Pid, Result} ->
            Result
    end.

call_port_no_wait(Pid, Msg) ->
    Pid ! {call, self(), Msg}.

receive_port(Port) ->
    receive
	{Port, {data, Data}} ->
            {data, Data};
	{Port, closed} ->
	    {closed};	
	{'EXIT', Port, Reason} ->
	    {process_exit, Reason} 	
    end.

read_cdb_data(Port) ->
    read_cdb_data(Port, none, []).
read_cdb_data(_Port, "> ", Acc) ->
    lists:flatten(lists:reverse(Acc));
read_cdb_data(Port, _Any, Acc) ->
    case receive_port(Port) of
	{data, Data} ->
	    read_cdb_data(Port, lists:nthtail(length(Data) - 2, Data), [Data | Acc]);
	{closed} ->
	    {closed, lists:flatten(lists:reverse(Acc))};
	{process_exit, Reason} ->
	    {process_exit, lists:flatten(lists:reverse(Acc))}
    end.

loop(Port) ->
    receive
	{call, Caller, Msg} ->
	    Port ! {self(), {command, Msg}},
	    %io:format("Reading data back...~n~n"),
      	    Caller ! {self(), read_cdb_data(Port)},
	    loop(Port);
	stop ->
	    Port ! {self(), close},
	    receive
            {Port, closed} ->
                exit(normal)
	    end;
	{'EXIT', Port, Reason} ->
	    Port ! {self(), process_exit},
	    exit(port_terminated)
    end.   

init_port(ExtPrg, ExtraParams, RetPid) ->
    process_flag(trap_exit, true),
    Port = open_port({spawn, ExtPrg}, [use_stdio, stderr_to_stdout, stream, hide | ExtraParams]),
    Data = read_cdb_data(Port),
    RetPid ! {self(), Data},
    loop(Port). 



