% @hidden
-module(jorel_provider_config).
-behaviour(jorel_provider).
-include("../include/jorel.hrl").

-export([init/1, do/1]).

-define(PROVIDER, gen_config).
-define(EXCLUDE, ["_jorel", "_relx", "_rel", "test"]).

init(State) ->
  jorel_config:add_provider(
    State,
    {?PROVIDER,
     #{
        module => ?MODULE,
        depends => [],
        desc => "Create a configuration file"
      }
    }
   ).

do(State) ->
  ?INFO("== Start provider ~p", [?PROVIDER]),
  RelName = case lists:keyfind(relname, 1, State) of
              {relname, R} -> 
                eutils:to_atom(R);
              _ -> 
                case file:get_cwd() of
                  {ok, D} -> 
                    case filename:basename(D) of
                      [] -> noname;
                      X -> eutils:to_atom(X)
                    end;
                  _ -> 
                    noname
                end
            end,
  RelVsn = case lists:keyfind(relvsn, 1, State) of
             {relvsn, V} -> V;
             _ -> "1.0.0"
           end,
  Output = case lists:keyfind(config, 1, State) of
            {config, C} -> C;
            _ -> "jorel.config"
          end,
  BootApps = lists:foldl(fun(App, Acc) ->
                             [eutils:to_atom(filename:basename(App, ".app"))|Acc]
                         end, [sasl], 
                         filelib:wildcard("ebin/*.app") ++ filelib:wildcard("apps/*/ebin/*.app")),
  AllApps = lists:foldl(fun(App, Acc) ->
                             [eutils:to_atom(filename:basename(App, ".app"))|Acc]
                         end, [sasl], 
                        efile:wildcard("**/ebin/*.app", ?EXCLUDE)),
  case erlconf:open('jorel.config', Output, [{save_on_close, false}]) of
    {ok, _} ->
      ?INFO("== Create file ~s", [Output]),
      Term = [
              {release, {RelName, RelVsn}, AllApps},
              {boot, BootApps},
              {all_deps, false},
              {output_dir, "_jorel"},
              {exclude_dirs, ["_jorel", "_relx", "_rel", "test"]},
              {include_src, false},
              {include_erts, false},
              {disable_relup, false},
              {providers, [jorel_provider_tar, jorel_provider_zip, jorel_provider_deb, jorel_provider_git_tag]}
             ],
      Term1 = case filelib:wildcard("config/*.config") of
                [Config] -> 
                  Term ++ [{sys_config, Config}];
                _ ->
                  Term
              end,
      Term2 = case filelib:is_regular("config/vm.args") of
                true ->
                  Term1 ++ [{vm_args, "config/vm.args"}];
                _ ->
                  Term1
              end,
      {ok, Term2} = erlconf:term('jorel.config', Term2),
      ok = erlconf:save('jorel.config'),
      close = erlconf:close('jorel.config');
    E ->
      ?HALT("!!! Can't create file ~s: ~p", [Output, E])
  end,
  ?INFO("== Provider ~p complete", [?PROVIDER]),
  State.
