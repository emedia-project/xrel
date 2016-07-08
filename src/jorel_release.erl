% @hidden
-module(jorel_release).
-include("../include/jorel.hrl").

-export([
         get_erts/1,
         make_root/1,
         resolv_apps/1,
         resolv_boot/2,
         make_lib/2,
         make_release/3,
         make_bin/1,
         make_upgrade_scripts/1,
         include_erts/1,
         make_boot_script/2,
         build_config_compiler/1
        ]).

-define(COPY_OPTIONS(Other), [{directory_mode, 8#00755}, {regular_file_mode, 8#00644}, {executable_file_mode, 8#00755}|Other]).

get_erts(State) ->
  case jorel_config:get(State, erts_info, false) of
    {erts_info, {_, _, _} = ERTSInfo} ->
      ERTSInfo;
    {erts_info, _} ->
      case jorel_config:get(State, include_erts, true) of
        {include_erts, true} -> {ok, erlang:system_info(version), code:root_dir()};
        {include_erts, false} -> {false, erlang:system_info(version), code:root_dir()};
        {include_erts, "jorel://" ++ Path} -> get_erts_from_url(?JOREL_IN ++ Path ++ ".tgz");
        {include_erts, <<"jorel://", Path>>} -> get_erts_from_url(?JOREL_IN ++ bucs:to_string(Path) ++ ".tgz");
        {include_erts, URL = "http://" ++ _} -> get_erts_from_url(URL);
        {include_erts, URL = <<"http://",  _/binary>>} -> get_erts_from_url(bucs:to_string(URL));
        {include_erts, URL = "https://" ++ _} -> get_erts_from_url(URL);
        {include_erts, URL = <<"https://",  _/binary>>} -> get_erts_from_url(bucs:to_string(URL));
        {include_erts, Path} -> find_erts_info(bucs:to_string(Path))
      end
  end.

get_erts_from_url(URL) ->
  case application:ensure_all_started(inets) of
    {ok, _} -> ok;
    _ -> ?HALT("Can't start inets", [])
  end,
  case application:ensure_all_started(ssl) of
    {ok, _} -> ok;
    _ -> ?HALT("Can't start ssl", [])
  end,
  case http_uri:parse(URL) of
    {ok, {http, _, _, _, P, _}} ->
      Archive = filename:join([?JOREL_HOME|string:tokens(P, "/")]),
      Path = filename:rootname(Archive, ".tgz"),
      Install = filename:dirname(Archive),
      _ = case filelib:is_dir(Path) of
            false ->
              ?INFO("= Download ERTS", []),
              case bucfile:make_dir(Install) of
                ok ->
                  case httpc:request(get, {URL, []}, [{autoredirect, true}], []) of
                    {ok, {{_, 200, _}, _, Body}} ->
                      case file:write_file(Archive, Body) of
                        ok -> 
                          case erl_tar:extract(Archive, [compressed, {cwd, Install}]) of
                            ok ->
                              _ = file:delete(Archive),
                              ?INFO("= Download ERTS compete", []),
                              find_erts_info(Path);
                            _ ->
                              ?HALT("!!! Faild to download ERTS", [])
                          end;
                        {error, Reason1} -> 
                          ?HALT("!!! Faild to save ERTS: ~p", [Reason1])
                      end;
                    {error, Reason2} ->
                      ?HALT("!!! Faild to download ERTS: ~p", [Reason2])
                  end;
                {error, Reason3} ->
                  ?HALT("!!! Can't create directory ~w: ~p", [Install, Reason3])
              end;
            true ->
              find_erts_info(Path)
          end;
    _ ->
      ?HALT("!!! Invalid URL for ERTS", [])
  end.

find_erts_info(Path) ->
  case filelib:is_dir(Path) of
    true ->
      case filelib:wildcard(filename:join([Path, "erts-*"])) of
        [ERTS|_] -> 
          case re:run(ERTS, "^.*-(.*)$", [{capture, all_but_first, list}]) of
            {match,[Version]} -> 
              ?DEBUG("= Will use ERTS ~s from ~s", [Version, Path]),
              {ok, Version, Path};
            _ ->
              ?HALT("!!! Can't retrieve ERTS informations from ~p", [Path])
          end;
        _ -> 
          ?HALT("!!! No ERTS found at ~s", [Path])
      end;
    false ->
      ?HALT("!!! Can't find ERTS at ~s", [Path])
  end.

make_root(State) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  case bucfile:make_dir(Outdir) of
    ok ->
      ?DEBUG("* Create directory ~s", [Outdir]);
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [Outdir, Reason])
  end.

resolv_apps(State) ->
  {release, {_, _}, Apps} = jorel_config:get(State, release),
  case Apps of
    [] ->
      ?HALT("!!! Missing apps in release", []);
    _ ->
      Apps1 = case jorel_config:get(State, all_deps, false) of
                {all_deps, true} -> find_all_deps(State, Apps);
                _ -> Apps
              end,
      resolv_apps(State, Apps1, [], [])
  end.

resolv_boot(State, AllApps) ->
  case jorel_config:get(State, boot, all) of
    {boot, all} -> AllApps;
    {boot, Apps} -> resolv_apps(State, Apps, [], [])
  end.

make_lib(State, Apps) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  LibDir = filename:join(Outdir, "lib"),
  Src = case jorel_config:get(State, include_src, false) of
          {include_src, true} -> ["src", "include"];
          {include_src, false} -> []
        end,
  case bucfile:make_dir(LibDir) of
    ok ->
      lists:foreach(fun(#{app := App, vsn := Vsn, path := Path}) ->
                        copy_deps(App, Vsn, Path, LibDir, Src)
                    end, Apps);
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [LibDir, Reason])
  end.

make_release(State, AllApps, BootApps) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  {relvsn, Vsn} = jorel_config:get(State, relvsn),
  RelDir = filename:join([Outdir, "releases", Vsn]),
  ?INFO("* Create ~s", [RelDir]),
  case bucfile:make_dir(RelDir) of
    ok ->
      _ = make_rel_file(State, RelDir, "vm.args", jorel_vm_args),
      _ = case jorel_elixir:exist() of
            true ->
              Dest = filename:join(RelDir, "sys.config"),
              case jorel_config:get(State, sys_config, false) of
                {sys_config, false} ->
                  {relname, RelName} = jorel_config:get(State, relname),
                  case jorel_sys_config_dtl:render([{relname, RelName}]) of
                    {ok, Data} ->
                      case file:write_file(Dest, Data) of
                        ok -> Dest;
                        {error, Reason1} ->
                          ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason1])
                      end;
                    {error, Reason} ->
                      ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason])
                  end;
                {sys_config, Src} ->
                  {env, MixEnv} = jorel_config:get(State, env, prod),
                  ?INFO("* Create ~s from ~s (env ~s)", [Dest, Src, MixEnv]),
                  case jorel_elixir:config_to_sys_config(Src, Dest, MixEnv) of
                    ok -> 
                      ok;
                    error ->
                      ?HALT("!!! Can't create ~s from ~s", [Dest, Src])
                  end
              end;
            false ->
              make_rel_file(State, RelDir, "sys.config", jorel_sys_config)
          end,
      tempdir:mktmp(fun(TmpDir) ->
                        BootErl = make_rel_file(State, TmpDir, "extrel.erl", jorel_extrel),
                        BootExe = jorel_escript:build(BootErl, filename:dirname(BootErl)),
                        case bucfile:copyfile(BootExe, 
                                              filename:join(RelDir, filename:basename(BootExe)),
                                              ?COPY_OPTIONS([])) of
                          ok -> ok;
                          {error, Reason2} ->
                            ?HALT("Can't copy ~s: ~p", [BootExe, Reason2])
                        end
                    end),
      RelBootFile = make_release_file(State, RelDir, BootApps, "-" ++ Vsn ++ ".rel"),
      _ = make_boot_script(State, BootApps),
      case file:rename(RelBootFile, RelBootFile ++ ".boot") of
        ok -> ok;
        {error, Reason4} ->
          ?HALT("!!! Faild to rename release boot file: ~p", [Reason4])
      end,
      RelFile = make_release_file(State, RelDir, AllApps, "-" ++ Vsn ++ ".rel"),
      ?INFO("* Create RELEASES file", []),
      case release_handler:create_RELEASES(Outdir, RelDir, RelFile, []) of
        ok -> ok;
        {error, Reason3} ->
          ?HALT("!!! Failed to create RELEASES: ~p", [Reason3])
      end;
    {error, Reason} ->
      ?HALT("!!! Failed to create ~s: ~p", [RelDir, Reason])
  end.

make_boot_script(State, BootApps) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  {relname, Relname} = jorel_config:get(State, relname),
  {relvsn, RelVsn} = jorel_config:get(State, relvsn),
  AppsPaths = lists:foldl(
                fun(#{app := App, vsn := Vsn}, Acc) ->
                    filelib:wildcard(
                      filename:join(
                        [Outdir, "lib", bucs:to_list(App) ++ "-" ++ Vsn, "**", "ebin"]
                       )) ++ Acc
                end, [], BootApps),
  RelDir = filename:join([Outdir, "releases", RelVsn]),
  Paths = [RelDir|AppsPaths],
  ?INFO("* Create boot script", []),
  case systools:make_script(
         bucs:to_list(Relname) ++ "-" ++ RelVsn,
         [{path, Paths},
          {outdir, RelDir},
          silent]) of
    error ->
      ?HALT("!!! Can't generate boot script", []);
    {error, _, Error} ->
      ?HALT("!!! Error while generating boot script : ~p", [Error]);
    {ok, _, []} ->
      ok;
    {ok, _, Warnings} ->
      ?WARN("! Generate boot script : ~p", [Warnings]);
    _ ->
      ok
  end.

make_bin(State) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  NodetoolDest = filename:join([Outdir, "bin", "nodetool"]),
  {binfile, BinFile} = jorel_config:get(State, binfile),
  {relvsn, Vsn} = jorel_config:get(State, relvsn),
  {relname, Name} = jorel_config:get(State, relname),
  {init_sources, InitSources} = jorel_config:get(State, init_sources, []),
  InitSources1 = case {is_list(InitSources), 
                       (bucs:is_string(InitSources) andalso length(InitSources) > 0)} of
                   {true, true} -> [InitSources];
                   _ -> InitSources
                 end,
  {_, ERTSVersion, _} = get_erts(State),
  BinFileWithVsn = BinFile ++ "-" ++ Vsn,
  ?INFO("* Generate ~s", [BinFile]),
  _ = case bucfile:make_dir(filename:dirname(BinFile)) of
        ok -> ok;
        {error, Reason} ->
          ?HALT("!!! Failed to create ~s: ~p", [BinFile, Reason])
      end,
  case jorel_unix_start_dtl:render([{relvsn, Vsn}, {relname, Name}, {ertsvsn, ERTSVersion}, {sources, InitSources1}]) of
    {ok, Data} ->
      case file:write_file(BinFile, Data) of
        ok ->
          ?INFO("* Generate ~s", [BinFileWithVsn]),
          Bins = case file:copy(BinFile, BinFileWithVsn) of
                   {ok, _} ->
                     [BinFile, BinFileWithVsn];
                   {error, Reason2} ->
                     ?ERROR("Error while creating ~s: ~p", [BinFileWithVsn, Reason2]),
                     [BinFile]
                 end,
          lists:foreach(fun(Bin) ->
                            case file:change_mode(Bin, 8#777) of
                              ok -> ok;
                              {error, Reason1} ->
                                ?HALT("!!! Can't set executable to ~s: ~p", [Bin, Reason1])
                            end
                        end, Bins);
        {error, Reason1} ->
          ?HALT("!!! Error while creating ~s: ~p", [BinFile, Reason1])
      end;
    {error, Reason1} ->
      ?HALT("!!! Error while creating ~s: ~p", [BinFile, Reason1])
  end,
  ?INFO("* Generate ~s", [NodetoolDest]),
  case jorel_nodetool_dtl:render() of
    {ok, NodetoolData} ->
      case file:write_file(NodetoolDest, NodetoolData) of
        ok -> 
          ok;
        {error, Reason3} ->
          ?HALT("!!! Error while creating ~s: ~p", [NodetoolDest, Reason3])
      end;
    {error, Reason4} ->
      ?HALT("!!! Error while creating ~s: ~p", [NodetoolDest, Reason4])
  end.

make_upgrade_scripts(State) ->
  {outdir, Outdir} = jorel_config:get(State, outdir),
  UpgradeEscriptDest = filename:join([Outdir, "bin", "upgrade.escript"]),
  ?INFO("* Install upgrade scripts", []),
  ?DEBUG("* Generate ~s", [UpgradeEscriptDest]),
  case jorel_upgrade_escript_dtl:render() of
    {ok, UpgradeData} ->
      case file:write_file(UpgradeEscriptDest, UpgradeData) of
        ok -> 
          ok;
        {error, Reason4} ->
          ?HALT("!!! Error while creating ~s: ~p", [UpgradeEscriptDest, Reason4])
      end;
    {error, Reason3} ->
      ?HALT("!!! Error while creating ~s: ~p", [UpgradeEscriptDest, Reason3])
  end.

include_erts(State) ->
  case get_erts(State) of
    {ok, ERTSVersion, Path} ->
      ?INFO("* Add ERTS ~s from ~s", [ERTSVersion, Path]),
      {outdir, Outdir} = jorel_config:get(State, outdir),
      bucfile:copy(
        filename:join(Path, "erts-" ++ ERTSVersion),
        Outdir,
        ?COPY_OPTIONS([recursive])),
      ErtsBinDir = filename:join([Outdir, "erts-" ++ ERTSVersion, "bin"]),
      ?DEBUG("* Substituting in erl.src and start.src to form erl and start", []),
      %%! Workaround for pre OTP 17.0: start.src does
      %%! not have correct permissions, so the above 'preserve' option did not help
      %%! Workaround for Charlie who have a fucking monkey MB
      ok = file:change_mode(filename:join(ErtsBinDir, "start"), 8#0755),
      ok = file:change_mode(filename:join(ErtsBinDir, "start.src"), 8#0755),
      ok = file:change_mode(filename:join(ErtsBinDir, "erl"), 8#0755),
      ok = file:change_mode(filename:join(ErtsBinDir, "erl.src"), 8#0755),
      subst_src_scripts(["erl", "start"], ErtsBinDir, ErtsBinDir,
                        [{"FINAL_ROOTDIR", "`cd $(dirname $0)/../../ && pwd`"},
                         {"EMU", "beam"}],
                        [preserve]),
      ?INFO("* Install start_clean.boot", []),
      ok = bucfile:copy(filename:join([Path, "bin", "start_clean.boot"]),
                        filename:join([Outdir, "bin", "start_clean.boot"]),
                        ?COPY_OPTIONS([])),
      ?INFO("* Install start.boot", []),
      ok = bucfile:copy(filename:join([Path, "bin", "start.boot"]),
                        filename:join([Outdir, "bin", "start.boot"]),
                        ?COPY_OPTIONS([]));
    _ ->
      ok
  end.

% Private

find_all_deps(State, Apps) ->
  {exclude_dirs, Exclude} = jorel_config:get(State, exclude_dirs, ["**/_jorel/**", "**/_rel*/**", "**/test/**"]),
  case bucfile:wildcard(
         filename:join(["**", "ebin", "*.app"]),
         Exclude,
         [expand_path]
        ) of
    [] -> Apps;
    DepsApps ->
      lists:foldl(fun(Path, Acc) ->
                      App = filename:basename(Path, ".app"),
                      case lists:member(App, Acc) of
                        true -> Acc;
                        false -> [bucs:to_atom(App)|Acc]
                      end
                  end, Apps, DepsApps)
  end.

resolv_apps(_, [], _, Apps) -> Apps;
resolv_apps(State, [App|Rest], Done, AllApps) ->
  {_, _, ERTSPath} = get_erts(State),
  {ignore_deps, IgnoreDeps} = jorel_config:get(State, ignore_deps, []),
  case lists:member(App, IgnoreDeps) of
    false ->
      {App, Vsn, Path, Deps} = case resolv_local(State, App) of
                                 notfound ->
                                   case resolv_app(State, filename:join([ERTSPath, "lib", "**"]), App) of
                                     notfound ->
                                       case jorel_elixir:exist() of
                                         true ->
                                           case jorel_elixir:path() of
                                             {ok, ElixirPath} ->
                                               case resolv_app(State, filename:join([ElixirPath, "**"]), App) of
                                                 notfound ->
                                                   ?HALT("!!! (3) Can't find application ~s", [App]);
                                                 R -> R
                                               end;
                                             _ ->
                                               ?HALT("!!! (2) Can't find application ~s", [App])
                                           end;
                                         false -> 
                                           ?HALT("!!! (1) Can't find application ~s", [App])
                                       end;
                                     R -> R
                                   end;
                                 R -> R
                               end,
      Done1 = [App|Done],
      Rest1 = buclists:delete_if(fun(A) ->
                                     lists:member(A, Done1)
                                 end, lists:umerge(lists:sort(Rest), lists:sort(Deps))),
      resolv_apps(
        State,
        Rest1,
        Done1,
        [#{app => App, vsn => Vsn, path => Path}| AllApps]);
    true ->
      resolv_apps(State, Rest, Done, AllApps)
  end.

resolv_local(State, App) ->
  case jorel_elixir:exist() of
    true ->
      {env, MixEnv} = jorel_config:get(State, env, prod),
      case resolv_app(State, filename:join(["_build", bucs:to_string(MixEnv), "lib", "**", "ebin"]), App) of
        notfound ->
          resolv_app(State, filename:join("**", "ebin"), App);
        Else ->
          Else
      end;
    false ->
      resolv_app(State, filename:join("**", "ebin"), App)
  end.

resolv_app(State, Path, Name) ->
  {exclude_dirs, Exclude} = jorel_config:get(State, exclude_dirs, ["**/_jorel/**", "**/_rel*/**", "**/test/**"]),
  case bucfile:wildcard(
         filename:join(Path, bucs:to_list(Name) ++ ".app"),
         Exclude,
         [expand_path]
        ) of
    [] -> notfound;
    [AppFile|_] ->
      ?DEBUG("= Found ~s", [AppFile]),
      AppPathFile = bucfile:expand_path(AppFile),
      case file:consult(AppPathFile) of
        {ok, [{application, Name, Config}]} ->
          Vsn = case lists:keyfind(vsn, 1, Config) of
                  {vsn, Vsn1} -> Vsn1;
                  _ -> "0"
                end,
          Deps = lists:foldl(fun(Type, Acc) ->
                                 case lists:keyfind(Type, 1, Config) of
                                   {Type, Apps} -> Acc ++ Apps;
                                   _ -> Acc
                                 end
                             end, [], [applications, included_applications]),
          {Name, Vsn, app_path(Name, Vsn, AppPathFile), Deps};
        E ->
          ?HALT("!!! Invalid ~p.app file ~s: ~p", [Name, AppPathFile, E])
      end
  end.

app_path(App, Vsn, Path) ->
  Dirname = filename:dirname(Path),
  AppName = bucs:to_list(App) ++ "-" ++ Vsn,
  case string:rstr(Dirname, AppName) of
    0 ->
      case string:rstr(Dirname, bucs:to_list(App)) of
        0 ->
          ?HALT("!!! Can't find root path for ~s", [App]);
        N ->
          string:substr(Dirname, 1, N + length(bucs:to_list(App)))
      end;
    N ->
      string:substr(Dirname, 1, N + length(AppName))
  end.

copy_deps(App, Vsn, Path, Dest, Extra) ->
  ?INFO("* Copy ~s version ~s (~s)", [App, Vsn, Path]),
  bucfile:copy(Path, 
               Dest, 
               ?COPY_OPTIONS([recursive, {only, ["ebin", "priv"] ++ Extra}])),
  FinalDest = filename:join(Dest, bucs:to_list(App) ++ "-" ++ Vsn),
  CopyDest = filename:join(Dest, filename:basename(Path)),
  if
    FinalDest =:= CopyDest -> ok;
    true ->
      _ = case filelib:is_dir(FinalDest) of
            true ->
              case bucfile:remove_recursive(FinalDest) of
                ok -> ok;
                {error, Reason} ->
                  ?HALT("!!! Can't remove ~s: ~p", [FinalDest, Reason])
              end;
            false ->
              ok
          end,
      case file:rename(CopyDest, FinalDest) of
        ok ->
          ?DEBUG("* Move ~s to ~s", [CopyDest, FinalDest]);
        {error, Reason1} ->
          ?HALT("!!! Can't rename ~s: ~p", [CopyDest, Reason1])
      end
  end.

make_rel_file(State, RelDir, File, Type) ->
  Dest = filename:join(RelDir, File),
  ?INFO("* Create ~s", [Dest]),
  case jorel_config:get(State, Type, false) of
    {Type, false} ->
      Mod = bucs:to_atom(bucs:to_list(Type) ++ "_dtl"),
      {relname, RelName} = jorel_config:get(State, relname),
      case Mod:render([{relname, RelName}]) of
        {ok, Data} ->
          case file:write_file(Dest, Data) of
            ok -> Dest;
            {error, Reason1} ->
              ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason1])
          end;
        {error, Reason} ->
          ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason])
      end;
    {Type, Src} ->
      case file:copy(Src, Dest) of
        {ok, _} -> Dest;
        {error, Reason} ->
          ?HALT("!!! Can't copy ~s to ~s: ~p", [Src, Dest, Reason])
      end
  end.

make_release_file(State, RelDir, Apps, Ext) ->
  {_, ERTSVersion, _} = get_erts(State),
  {relname, Name} = jorel_config:get(State, relname),
  {relvsn, Vsn} = jorel_config:get(State, relvsn),
  Params = [
            {relname, Name},
            {relvsn, Vsn},
            {ertsvsn, ERTSVersion},
            {apps, lists:map(fun maps:to_list/1, Apps)}
           ],
  Dest = filename:join(RelDir, bucs:to_list(Name) ++ Ext),
  ?INFO("* Create ~s", [Dest]),
  case jorel_rel_dtl:render(Params) of
    {ok, Data} ->
      case file:write_file(Dest, Data) of
        ok -> Dest;
        {error, Reason1} ->
          ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason1])
      end;
    {error, Reason} ->
      ?HALT("!!! Error while creating ~s: ~p", [Dest, Reason])
  end.

subst_src_scripts(Scripts, SrcDir, DestDir, Vars, Opts) ->
  lists:foreach(fun(Script) ->
                    subst_src_script(Script, SrcDir, DestDir,
                                     Vars, Opts)
                end, Scripts).

subst_src_script(Script, SrcDir, DestDir, Vars, Opts) ->
  subst_file(filename:join([SrcDir, Script ++ ".src"]),
             filename:join([DestDir, Script]),
             Vars, Opts).

subst_file(Src, Dest, Vars, Opts) ->
  {ok, Conts} = read_txt_file(Src),
  NConts = subst(Conts, Vars),
  write_file(Dest, NConts),
  case lists:member(preserve, Opts) of
    true ->
      {ok, FileInfo} = file:read_file_info(Src),
      file:write_file_info(Dest, FileInfo);
    false ->
      ok
  end.

read_txt_file(File) ->
  {ok, Bin} = file:read_file(File),
  {ok, binary_to_list(Bin)}.

write_file(FName, Conts) ->
  Enc = file:native_name_encoding(),
  {ok, Fd} = file:open(FName, [write]),
  file:write(Fd, unicode:characters_to_binary(Conts, Enc, Enc)),
  file:close(Fd).

subst(Str, Vars) ->
  subst(Str, Vars, []).

subst([$%, C| Rest], Vars, Result) when $A =< C, C =< $Z ->
  subst_var([C| Rest], Vars, Result, []);
subst([$%, C| Rest], Vars, Result) when $a =< C, C =< $z ->
  subst_var([C| Rest], Vars, Result, []);
subst([$%, C| Rest], Vars, Result) when  C == $_ ->
  subst_var([C| Rest], Vars, Result, []);
subst([C| Rest], Vars, Result) ->
  subst(Rest, Vars, [C| Result]);
subst([], _Vars, Result) ->
  lists:reverse(Result).

subst_var([$%| Rest], Vars, Result, VarAcc) ->
  Key = lists:reverse(VarAcc),
  case lists:keysearch(Key, 1, Vars) of
    {value, {Key, Value}} ->
      subst(Rest, Vars, lists:reverse(Value, Result));
    false ->
      subst(Rest, Vars, [$%| VarAcc ++ [$%| Result]])
  end;
subst_var([C| Rest], Vars, Result, VarAcc) ->
  subst_var(Rest, Vars, Result, [C| VarAcc]);
subst_var([], Vars, Result, VarAcc) ->
  subst([], Vars, [VarAcc ++ [$%| Result]]).

build_config_compiler(State) ->
  Apps = [extract_app(Path) || #{path := Path} <- resolv_apps(State, [syntax_tools], [], [])],
  {outdir, Outdir} = jorel_config:get(State, outdir),
  ConfigScript = filename:join([Outdir, "bin", "config.escript"]),
  ok = filelib:ensure_dir(ConfigScript),
  tempdir:mktmp(
    fun(TmpDir) ->
        {ok, Escript} = escript:extract(escript:script_name(), []),
        {archive, Archive} = lists:keyfind(archive, 1, Escript),
        ?DEBUG("* Extract ~s tp ~s", [escript:script_name(), TmpDir]),
        zip:extract(Archive, [{cwd, TmpDir}]),
        ?INFO("* Create ~s", [ConfigScript]),
        AppsForArchive = [{"doteki", TmpDir}|Apps],
        ArchiveFiles = lists:foldl(
                         fun({App, Path}, Acc) ->
                             Acc ++ [read_file(File, Path, App) 
                                     || File <- filelib:wildcard("*", filename:join([Path, App, "ebin"]))]
                         end, [], AppsForArchive),
        PZ = lists:concat(lists:join(" ", [A ++ "/ebin" || {A, _} <- AppsForArchive])),
        case escript:create(ConfigScript, 
                            [{shebang, "/usr/bin/env escript"}
                             , {comment, ""}
                             , {emu_args, " -escript main doteki -pz " ++ PZ}
                             , {archive, ArchiveFiles, []}]) of
          ok -> ok;
          {error, EscriptError} ->
            ?ERROR("Failed to create ~s: ~p", [ConfigScript, EscriptError])
        end
    end),
  State.

extract_app(Path) ->
  case lists:reverse(Path) of
    [$/|Rest] ->
      {filename:basename(lists:reverse(Rest)),
       filename:dirname(lists:reverse(Rest))};
    _ ->
      {filename:basename(Path),
       filename:dirname(Path)}
  end.

read_file(Filename, Prefix, App) ->
  File = filename:join([Prefix, App, "ebin", Filename]),
  ArchiveFile = filename:join([App, "ebin", Filename]),
  ?DEBUG("= Add ~p (~p) in update script", [File, ArchiveFile]),
  {ok, Bin} = file:read_file(File),
  {ArchiveFile, Bin}.

