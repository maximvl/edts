%%%-------------------------------------------------------------------
%%% @author João Neves <joao.neves@klarna.com>
%%% @copyright (C) 2012, João Neves
%%% @doc
%%%
%%% @end
%%% Created : 10 Sep 2012 by João Neves <joao.neves@klarna.com>
%%%-------------------------------------------------------------------
-module(edts_debug_server).

-behaviour(gen_server).

%% API
-export([start/0, stop/0, start_link/0, maybe_attach/1,
        interpret_modules/1, toggle_breakpoint/2,
        uninterpret_modules/1, wait_for_debugger/0, continue/0, step/0 ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Exported for spawning
-export([ start_debugging/1 ]).

-define(SERVER, ?MODULE).

-record(dbg_state, {
          debugger = undefined :: undefined | pid(),
          proc = unattached    :: unattached | pid(),
          listeners = []       :: [term()]
         }).

%%%===================================================================
%%% API
%%%===================================================================

start() ->
  edts_debug_server:start_link(),
  {ok, node()}.

stop() ->
  ok.


%%--------------------------------------------------------------------
%% @doc
%% Potentially attach to an interpreter process Pid. Will not
%% reattach if already attached.
%% @end
-spec maybe_attach(Pid :: pid()) -> {attached, pid(), pid()}
                                  | {already_attached, pid(), pid()}.
%%--------------------------------------------------------------------
maybe_attach(Pid) ->
  case gen_server:call(?SERVER, {attach, Pid}) of
    {ok, attach} ->
      AttPid = spawn_link(?MODULE, start_debugging, [Pid]),
      {attached, AttPid, Pid};
    {error, already_attached, AttPid} ->
      {already_attached, AttPid, Pid}
  end.

%%--------------------------------------------------------------------
%% @doc
%% Make Modules interpretable. Returns the list of modules which were
%% interpretable and set as such.
%% @end
-spec interpret_modules(Modules :: [module()]) -> {ok, [module()]}.
%%--------------------------------------------------------------------
interpret_modules(Modules) ->
  gen_server:call(?SERVER, {interpret, Modules}).

%%--------------------------------------------------------------------
%% @doc
%% Toggles a breakpoint at Module:Line.
%% @end
-spec toggle_breakpoint(Module :: module(), Line :: non_neg_integer()) ->
                           {ok, set, {Module, Line}}
                         | {ok, unset, {Module, Line}}.
%%--------------------------------------------------------------------
toggle_breakpoint(Module, Line) ->
  gen_server:call(?SERVER, {toggle_breakpoint, Module, Line}).

%%--------------------------------------------------------------------
%% @doc
%% Uninterprets Modules.
%% @end
-spec uninterpret_modules(Modules :: [module()]) -> ok.
%%--------------------------------------------------------------------
uninterpret_modules(Modules) ->
  gen_server:call(?SERVER, {uninterpret, Modules}).

%%--------------------------------------------------------------------
%% @doc
%% Waits for debugging to be triggered by a breakpoint and returns
%% relevant module and line information.
%% @end
-spec wait_for_debugger() -> {ok, {module(), non_neg_integer()}}.
%%--------------------------------------------------------------------
wait_for_debugger() ->
  gen_server:call(?SERVER, wait_for_debugger, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Orders the debugger to continue execution until it reaches another
%% breakpoint or execution terminates.
%% @end
-spec continue() -> ok.
%%--------------------------------------------------------------------
continue() ->
  gen_server:call(?SERVER, continue, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Orders the debugger to step in execution.
%% @end
-spec step() -> ok.
%%--------------------------------------------------------------------
step() ->
  gen_server:call(?SERVER, step, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
  int:auto_attach([break], {?MODULE, maybe_attach, []}),
  {ok, #dbg_state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({attach, Pid}, _From, #dbg_state{proc = unattached} = State) ->
  {reply, {ok, attach}, State#dbg_state{proc = Pid}};
handle_call({attach, Pid}, _From, #dbg_state{debugger=Dbg, proc=Pid} = State) ->
  {reply, {already_attached, Dbg, Pid}, State};

handle_call({interpret, Modules}, _From, State) ->
  Reply = {ok, [int:i(M) || M <- Modules, int:interpretable(M)]},
  {reply, Reply, State};

handle_call({toggle_breakpoint, Module, Line}, _From, State) ->
  Reply = case lists:keymember({Module, Line}, 1, int:all_breaks()) of
            true  -> int:delete_break(Module, Line),
                     {ok, unset, {Module, Line}};
            false -> int:break(Module, Line),
                     {ok, set, {Module, Line}}
          end,
  {reply, Reply, State};

handle_call({uninterpret, Modules}, _From, State) ->
  [int:n(M) || M <- Modules],
  {reply, ok, State};

handle_call(wait_for_debugger, From, State) ->
  Listeners = State#dbg_state.listeners,
  {noreply, State#dbg_state{listeners = [From|Listeners]}};

handle_call(continue, From, #dbg_state{proc = Pid} = State) ->
  int:continue(Pid),
  Listeners = State#dbg_state.listeners,
  {noreply, State#dbg_state{listeners = [From|Listeners]}};

handle_call(step, From, #dbg_state{proc = Pid} = State) ->
  int:step(Pid),
  Listeners = State#dbg_state.listeners,
  {noreply, State#dbg_state{listeners = [From|Listeners]}}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({register_attached, Pid}, State) ->
  {noreply, State#dbg_state{debugger = Pid}};
handle_cast({notify, Info}, #dbg_state{listeners = Listeners} = State) ->
  notify(Info, Listeners),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
  int:auto_attach(false),
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

notify(Info) ->
  gen_server:cast(?SERVER, {notify, Info}).

notify(_, []) ->
  ok;
notify(Info, [Client|R]) ->
  gen_server:reply(Client, {ok, Info}),
  notify(Info, R).

register_attached(Pid) ->
  gen_server:cast(?SERVER, {register_attached, Pid}).

start_debugging(Pid) ->
  register_attached(self()),
  int:attached(Pid),
  io:format("Debugger ~p attached to ~p~n", [self(), Pid]),
  debug_loop().

debug_loop() ->
  receive
    {Meta, {break_at, Module, Line, _Cur}} ->
      Bindings = int:meta(Meta, bindings, nostack),
      notify({break, {Module, Line}, Bindings}),
      debug_loop();
    {_Meta, idle} ->
      notify(idle),
      debug_loop();
    {_Meta, running} ->
      debug_loop();
    _ = Msg ->
      io:format("Unexpected message: ~p~n", [Msg]),
      debug_loop()
  end.

%%%====================================================================
%%% Unit tests
%%%====================================================================
