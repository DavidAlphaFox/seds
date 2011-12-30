%% Copyright (c) 2010, Michael Santos <michael.santos@gmail.com>
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% Redistributions of source code must retain the above copyright
%% notice, this list of conditions and the following disclaimer.
%%
%% Redistributions in binary form must reproduce the above copyright
%% notice, this list of conditions and the following disclaimer in the
%% documentation and/or other materials provided with the distribution.
%%
%% Neither the name of the author nor the names of its contributors
%% may be used to endorse or promote products derived from this software
%% without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.
-module(seds).
-behaviour(gen_server).

-include_lib("kernel/src/inet_dns.hrl").
-include("seds.hrl").

-define(SERVER, ?MODULE).

-export([start_link/0, start_link/1, send/2]).
-export([config/2, privpath/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
        terminate/2, code_change/3]).

-record(state, {
        acf = false,                    % allow client forwarding
        acl = [],                       % forward IP blacklist
        acl_port = [],                  % allowed ports (whitelist)

        f,                              % forwarders map
        s,                              % socket
        d = [],                         % domains
        p = []                          % list of proxies
    }).


send({IP, Port, #dns_rec{} = Rec}, #seds{} = Query) ->
    gen_server:call(?SERVER, {send, {IP, Port, Rec, Query}}).


start_link() ->
    start_link(?DNS_PORT).
start_link(Port) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port], []).

init([Port]) when Port > 1024 ->
    init(Port, []);
init([Port]) ->
    {ok, FD} = procket:open(Port, [
        {protocol, udp},
        {family, inet},
        {type, dgram}
    ]),
    init(Port, [{fd, FD}]).

init(Port, Opt) ->
    process_flag(trap_exit, true),

    {ok, Socket} = gen_udp:open(Port, [
            binary,
            {active, once}
        ] ++ Opt),
    {ok, #state{
            acf = config(dynamic, ?CFG, false),
            acl = config(acl, ?CFG, []),
            acl_port = config(allowed_ports, ?CFG, [22]),
            f = config(forward, ?CFG, []),
            d = [ string:tokens(N, ".") || N <- config(domains, ?CFG, ["localhost"]) ],
            s = Socket,
            p = dict:new()
        }}.


handle_call({send, {IP, Port, #dns_rec{} = Rec,
            #seds{type = Type, sum = Sum, data = Data} = Query}},
            _From, #state{p = Proxies} = State) ->
    Session = seds_protocol:session(Query, map(State)),
    case dict:find(Session, Proxies) of
        error when Sum == 0 ->
            {Proxy, Proxies1} = proxy(Session, State),
            ok = seds_proxy:send(Proxy, IP, Port, Rec, {Type, 0, Data}),
            {reply, ok, State#state{p = Proxies1}};
        error ->
            {reply, ok, State};
        {ok, Proxy} ->
            ok = seds_proxy:send(Proxy, IP, Port, Rec, {Type, Sum, Data}),
            {reply, ok, State}
    end;

handle_call(Request, _From, State) ->
    error_logger:error_report([{wtf, Request}]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

% DNS request from client
handle_info({udp, Socket, IP, Port, Data}, #state{
        s = Socket
    } = State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    spawn(seds_protocol, decode, [{IP, Port, Data}, map(State)]),
    {noreply, State};

% Session terminated
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{
        p = Proxies
    } = State) ->
    {noreply, State#state{
            p = dict:filter(
                fun (_,V) when V == Pid -> false;
                    (_,_) -> true
                end,
                Proxies)
        }};

% WTF?
handle_info(Info, State) ->
    error_logger:error_report([{wtf, Info}]),
    {noreply, State}.

terminate(_Reason, #state{s = Socket}) ->
    procket:close(Socket),
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%
%%% Internal Functions
%%%
proxy({{IP, Port}, Id} = Session, #state{
        s = Socket,
        p = Proxies
    }) ->
    error_logger:info_report([
        {session_start, {IP, Port}},
        {id, Id}
    ]),
    {ok, Pid} = seds_proxy:start_link(Socket, {IP, Port}),
    {Pid, dict:store(Session, Pid, Proxies)}.


config(Key, Cfg) ->
    config(Key, Cfg, undefined).
config(Key, Cfg, Default) ->
    {ok, Map} = file:consult(privpath(Cfg)),
    proplists:get_value(Key, Map, Default).

privpath(Cfg) ->
    filename:join([
            filename:dirname(code:which(?MODULE)),
            "..",
            "priv",
            Cfg
        ]).

map(#state{
        acf = ACF,
        acl = ACL,
        acl_port = ACP,
        f = Fwd,
        d = Domains
    }) ->
    #config{
        acf = ACF,
        acl = ACL,
        acl_port = ACP,
        f = Fwd,
        d = Domains
    }.
