%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Top-level edts supervisor.
%%% @end
%%% @author Thomas Järvstrand <tjarvstrand@gmail.com>
%%% @editor Maxim Velesyuk <max.velesyuk@gmail.com>
%%% @copyright
%%% Copyright 2012 Thomas Järvstrand <tjarvstrand@gmail.com>
%%%
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU Lesser General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU Lesser General Public License for more details.
%%%
%%% You should have received a copy of the GNU Lesser General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(edts_cowboy).

-export([init/2,
         handle_request/1]).

%%%_* Includes =================================================================
%%%_* Defines ==================================================================



%%%_* Types ====================================================================
%%%_* API ======================================================================

init(Req, State) ->
  Req1 = handle_request(Req),
  {ok, Req1, State}.

handle_request(Req) ->
  try
    case cowboy_req:method(Req) of
      <<"POST">> ->
        case do_handle_request(Req) of
          {ok, Req1} ->
            ok_reply(Req1);
          {{ok, Data}, Req1} ->
            ok_reply(Req1, Data);
          {{error, {not_found, Term}}, Req1} ->
            error_reply(Req1, not_found, Term)
        end;
      _ ->
        error_reply(Req, method_not_allowed)
    end
  catch
    Class:Reason:Trace ->
      error_reply(Req,
            internal_server_error,
            [{class, format_term(Class)},
             {reason, format_term(Reason)},
             {stack_trace, format_term(Trace)}])
  end.


format_term(Term) ->
  list_to_binary(lists:flatten(io_lib:format("~p", [Term]))).

do_handle_request(Req) ->
  %% ignore leading /
  [_ | Split] = binary:split(cowboy_req:path(Req), <<"/">>, [global]),
  case [ binary_to_atom(B, unicode) || B <- Split ] of
    [Command] ->
      {Input, Req1} = get_input_context(Req),
      {edts_cmd:run(Command, Input), Req1};
    [plugins, Plugin, Command] ->
      {Input, Req1} = get_input_context(Req),
      {edts_cmd:plugin_run(Plugin, Command, Input), Req1};
    Path ->
      {{error, {not_found, [{path, list_to_binary(Path)}]}}, Req}
  end.

get_input_context(Req) ->
  case cowboy_req:read_body(Req) of
    {ok, Body, Req1} ->
      error_logger:error_report(["body: ", Body]),
      Decoded = case Body of
                  <<"null">> -> [];
                  <<"">> -> [];
                  _ -> mochijson2:decode(binary_to_list(Body), [{format, proplist}])
                end,
      Ret = orddict:from_list(decode_element(Decoded)),
      {Ret, Req1};
    _ -> {orddict:new(), Req}
  end.

decode_element([{_, _}|_] = Element) ->
  [{list_to_atom(binary_to_list(K)), decode_element(V)} || {K, V} <- Element];
decode_element(Element) when is_list(Element) ->
  [decode_element(E) || E <- Element];
decode_element(Element) when is_binary(Element) ->
  binary_to_list(Element);
decode_element(Element) ->
  Element.

ok_reply(Req) ->
  ok_reply(Req, undefined).

ok_reply(Req, Data) ->
  respond(Req, 200, Data).

error_reply(Req, Error) ->
  error_reply(Req, Error, []).

error_reply(Req, not_found, Data) ->
  error_reply(Req, 404, "Not Found", Data);
error_reply(Req, method_not_allowed, Data) ->
  error_reply(Req, 405, "Method Not Allowed", Data);

error_reply(Req, internal_server_error, Data) ->
  error_reply(Req, 500, "Internal Server Error", Data);
error_reply(Req, Error, _Data) ->
  ErrorString = "Internal Server Error: Unknown error " ++ atom_to_list(Error),
  error_reply(Req, 500, ErrorString, []).

error_reply(Req, Code, Message, Data) ->
  Body = [{code,    Code},
          {message, list_to_binary(Message)},
          {data,    Data}],
  respond(Req, Code, Body).

respond(Req, Code, Data) ->
  Headers = #{<<"Content-Type">> => <<"application/json">>},
  BodyString = case Data of
                 undefined -> "";
                 _         -> mochijson2:encode(Data)
               end,
  cowboy_req:reply(Code, Headers, BodyString, Req).

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
