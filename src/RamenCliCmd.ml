(* For each ramen command, check arguments and mostly transfer the control
 * further to more specialized modules. *)
open Batteries
open Stdint
open RamenLog
open RamenHelpers
open RamenConsts
open RamenSyncHelpers
module C = RamenConf
module RC = C.Running
module F = C.Func
module FS = F.Serialized
module P = C.Program
module O = RamenOperation
module T = RamenTypes
module N = RamenName
module OutRef = RamenOutRef
module Files = RamenFiles
module Services = RamenServices
module Processes = RamenProcesses
module EventTime = RamenEventTime
module ZMQClient = RamenSyncZMQClient

let () =
  Printexc.register_printer (function
    | Failure msg -> Some msg
    | _ -> None)

let make_copts
      debug quiet persist_dir rand_seed keep_temp_files reuse_prev_files
      forced_variants initial_export_duration site bundle_dir masters
      sync_url srv_pub_key username clt_pub_key clt_priv_key identity =
  if not (N.is_empty identity) then
    Files.check_file_is_secure identity ;
  (match rand_seed with
  | None -> Random.self_init ()
  | Some seed ->
      RamenSupervisor.rand_seed := Some seed ;
      Random.init seed) ;
  (* As the RAMEN_VARIANTS and RAMEN_MASTERS envars can only take a list as
   * a single string, let's consider each value can be a list: *)
  let list_of_string_opt opt =
    List.fold_left (fun lst s ->
      List.rev_append (String.split_on_char ',' s) lst
    ) [] opt
  in
  let forced_variants = list_of_string_opt forced_variants
  and masters =
    list_of_string_opt masters |> List.map N.site |> Set.of_list in
  if srv_pub_key <> "" && (clt_pub_key = "" || clt_priv_key = "") then
    failwith "To connect securely to that server, the client \
              private and secret keys must also be provided" ;
  let conf =
    C.make_conf
      ~debug ~quiet ~keep_temp_files ~reuse_prev_files ~forced_variants
      ~initial_export_duration ~site ~bundle_dir ~masters ~sync_url
      ~srv_pub_key ~username ~clt_pub_key ~clt_priv_key ~identity persist_dir in
  (* Find out the ZMQ URL to reach the conf server: *)
  if conf.sync_url <> "" then conf
  else
    let sync_url =
      match Services.resolve_every_site conf ServiceNames.confserver with
      | [] ->
          (* TODO: Only when the sync_server experiment have started:
          let host =
            if Set.is_empty conf.masters then
              "localhost"
            else
              (Set.min_elt conf.masters :> string) in
          "tcp://"^ host ^":"^ string_of_int Default.confserver_port *)
          ""
      | (site, se) :: _ ->
          let url =
            Printf.sprintf2 "tcp://%a:%d"
              N.host_print se.Services.host
              se.port in
          !logger.debug "Worker will use %S to contact %a:confserver"
            url N.site_print site ;
          url in
    { conf with sync_url }

(*
 * `ramen supervisor`
 *
 * Start the process supervisor, which will keep running the programs
 * present in the configuration/rc file (and kill the others).
 * This does not return (under normal circumstances).
 *
 * The actual work is done in module RamenProcesses.
 *)

let check_binocle_errors () =
  Option.may raise !Binocle.last_error

let while_ () = !RamenProcesses.quit = None

let start_daemon conf daemonize to_stdout to_syslog name =
  if to_stdout && daemonize then
    failwith "Options --daemonize and --stdout are incompatible." ;
  if to_stdout && to_syslog then
    failwith "Options --syslog and --stdout are incompatible." ;
  if to_syslog then
    init_syslog conf.C.log_level
  else (
    let logdir =
      if to_stdout then None
      else (
        let log_path =
          N.path_cat [ conf.C.persist_dir ; N.path "log" ; name ] in
        (* It can be surprising when the command keeps the console but logs
         * elsewhere, and is rarely the desired behavior, so log about it: *)
        if not daemonize then
          Printf.printf "Will log in %a\n%!" N.path_print log_path ;
        Some log_path
      ) in
    Option.may Files.mkdir_all logdir ;
    init_logger ?logdir:(logdir :> string option) conf.C.log_level) ;
  check_binocle_errors () ;
  if daemonize then do_daemonize () ;
  let open RamenProcesses in
  prepare_signal_handlers conf

let supervisor conf daemonize to_stdout to_syslog autoreload
               use_external_compiler max_simult_compils
               smt_solver fail_for_good_ () =
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  start_daemon conf daemonize to_stdout to_syslog (N.path "supervisor") ;
  (* Controls all calls to restart_on_failure: *)
  fail_for_good := fail_for_good_ ;
  let open RamenProcesses in
  prepare_signal_handlers conf ;
  (* Also attempt to repair the report/notifs ringbufs.
   * This is OK because there can be no writer right now, and the report
   * ringbuf being a non-wrapping buffer then reader part cannot be damaged
   * anyway. For notifications we could have the alerter reading though,
   * so FIXME: smarter ringbuf_repair that spins before repairing. *)
  let reports_rb = prepare_reports conf in
  RingBuf.unload reports_rb ;
  let notify_rb = prepare_notifs conf in
  RingBuf.unload notify_rb ;
  (* The main job of this process is to make what's actually running
   * in accordance to the running program list: *)
  restart_on_failure ~while_ "synchronize_running"
    RamenExperiments.(specialize the_big_one) [|
      RamenProcesses.dummy_nop ;
      (fun () -> RamenSupervisor.synchronize_running conf autoreload) |] ;
  Option.may exit !RamenProcesses.quit

(*
 * `ramen alerter`
 *
 * Start the alerter process, which will read the notifications ringbuf
 * and perform whatever action it takes, most likely reaching out to
 * external systems.
 *
 * The actual work is done in module RamenAlerter.
 *)

let alerter conf notif_conf_file max_fpr daemonize to_stdout
             to_syslog () =
  if max_fpr < 0. || max_fpr > 1. then
    failwith "False-positive rate is a rate is a rate." ;
  start_daemon conf daemonize to_stdout to_syslog (N.path "alerter") ;
  (* The configuration file better exists, unless it's the default one in
   * which case it will be created with the default configuration: *)
  let notif_conf_file =
    match notif_conf_file with
    | None ->
        let notif_conf_file =
          N.path_cat [ conf.C.persist_dir ; N.path "alerter.conf" ] in
        RamenAlerter.ensure_conf_file_exists notif_conf_file ;
        notif_conf_file
    | Some notif_conf_file ->
        if Files.check ~min_size:1 notif_conf_file <> FileOk then (
          Printf.sprintf2 "Configuration file %a does not exist."
            N.path_print notif_conf_file |>
          failwith
        ) else (
          (* Try to parse that file while we have the user attention: *)
          ignore (RamenAlerter.load_config notif_conf_file)
        ) ;
        notif_conf_file in
  let notify_rb = RamenProcesses.prepare_notifs conf in
  restart_on_failure ~while_ "process_notifications"
    RamenExperiments.(specialize the_big_one) [|
      RamenProcesses.dummy_nop ;
      (fun () ->
        RamenAlerter.start conf notif_conf_file notify_rb max_fpr) |] ;
  Option.may exit !RamenProcesses.quit

let notify conf parameters notif_name () =
  init_logger conf.C.log_level ;
  let rb = RamenProcesses.prepare_notifs conf in
  let start = Unix.gettimeofday () in
  let firing, certainty, parameters =
    RingBufLib.normalize_notif_parameters parameters in
  let parameters = Array.of_list parameters in
  RingBufLib.write_notif rb
    ((conf.site :> string), "CLI", start, None,
     notif_name, firing, certainty, parameters)

(*
 * `ramen tunneld`
 *
 * Runs a service allowing other sites to transfer tuples to workers running
 * on this one.
 *)

let resolve_port conf port_opt def service_name =
  Option.default_delayed (fun () ->
    match Services.resolve conf conf.C.site service_name with
    | exception Not_found ->
        !logger.warning
          "No port given and cannot resolve service %a on site %a, will \
           use default %d"
          N.service_print service_name
          N.site_print conf.C.site
          def ;
        def
    | se ->
        se.Services.port
  ) port_opt

let tunneld conf daemonize to_stdout to_syslog port_opt () =
  let service_name = ServiceNames.tunneld in
  let port =
    resolve_port conf port_opt Default.tunneld_port service_name in
  start_daemon conf daemonize to_stdout to_syslog
               (N.path (service_name :> string)) ;
  RamenCopySrv.copy_server conf port ;
  Option.may exit !RamenProcesses.quit

(*
 * `ramen confserver`
 *
 * Runs a service that reads all configuration and makes it available to
 * other processes via a real-time synchronisation protocol.
 *)

let confserver conf daemonize to_stdout to_syslog ports ports_sec
               srv_pub_key_file srv_priv_key_file () =
  let service_name = ServiceNames.confserver in
  if ports = [] && ports_sec = [] then
    failwith "You must specify some ports to listen to with --secure and/or \
             --insecure" ;
  if ports_sec = [] && not (N.is_empty srv_pub_key_file) then
    failwith "--public-key makes no sense without --secure" ;
  if ports_sec = [] && not (N.is_empty srv_priv_key_file) then
    failwith "--private-key makes no sense without --secure" ;
  start_daemon conf daemonize to_stdout to_syslog
               (N.path (service_name :> string)) ;
  RamenSyncZMQServer.start
    conf ports ports_sec srv_pub_key_file srv_priv_key_file ;
  Option.may exit !RamenProcesses.quit

let confclient conf () =
  let topics = [ "*" ] in
  let on_new _clt k v u mtime owner expiry =
    !logger.info "%a = %a (set by %s, mtime=%f, owner=%S, expiry=%f)"
      RamenSync.Key.print k
      RamenSync.Value.print v
      u mtime
      owner expiry
  in
  start_sync conf ~topics ~on_new ~while_ (fun clt ->
    !logger.info "Receiving:" ;
    forever (fun () ->
      ZMQClient.process_in ~while_ clt
    ) ())

(*
 * `ramen compile`
 *
 * Turn a ramen program into an executable binary.
 * Actual work happens in RamenCompiler.
 *)

(* Note: We need a program name to identify relative parents. *)
let compile_local
    conf lib_path use_external_compiler
    max_simult_compils smt_solver source_file
    output_file_opt program_name_opt =
  (* There is a long way to calling the compiler so we configure it from
   * here: *)
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  let get_parent =
    if lib_path = [] then
      let programs = RC.with_rlock conf identity in
      RamenCompiler.parent_from_programs programs
    else
      List.map Files.absolute_path_of lib_path |>
      RamenCompiler.parent_from_lib_path in
  let program_name_opt =
    if program_name_opt <> None then
      program_name_opt
    else
      (* Try to get an idea from the lib-path: *)
      match lib_path with
      | p::_ ->
        (try
          let p =
            Files.remove_ext source_file |>
            Files.rel_path_from (Files.absolute_path_of p) in
          Some (N.program (p :> string))
        with Failure s ->
          !logger.debug "%s" s ;
          None)
      | [] -> None in
  let program_name =
    Option.default_delayed (fun () ->
      RamenRun.default_program_name source_file
    ) program_name_opt in
  let output_file =
    Option.default_delayed (fun () ->
      Files.change_ext "x" source_file
    ) output_file_opt in
  RamenMake.build conf ~force_rebuild:true get_parent program_name
                  source_file output_file

(* We store sources separately from programs, as the same source can run under
 * several program names (given different parameters, for instance).
 * For simplicity there is no separate command to upload a file: the
 * confserver will taste and rate any uploaded source file.
 *
 * The ConfServer must not compile the source down to an executable file.
 * Only the supervisor daemons must.
 * One can check that a source is valid by compiling it locally.
 * But the ConfServer must parse it and type it in order to extract the META
 * informations. Only the code generation is not required.
 *
 * For parsing and typing, the confserver resolves parent names against the
 * source tree only. Remember that supervisor will link against the running
 * config. Both hierarchies must largely match each other anyway.
 *
 * Therefore, a source has several values attached to it:
 * - the text, that anyone can read/write
 * - and the info, that only the confserver can write.
 *
 * When compiling the confserver locks the source (therefore the creator
 * must unlock it). Then it writes the info and unlock all.
 * The info contains the same thing as the Program.t today (no program name
 * and no param values and no env values), and the typed operation.
 *
 * When generating code, the supervisors do not restart from the source but from
 * the (typed!) operation, thus speeding up the process and alleviating the need
 * for a solver on the sites.
 *
 * Given there are two different keys for the source text and the source info,
 * how to we know the info relate to the version of the source that has just
 * been written? We know because of the MD5 of the source that's present in
 * the info (the MD5 of the full text so that the client can easily check it).
 *
 * Now of course the confserver does not pre-compile itself. Indeed, a daemon
 * compiler can do that, for simpler design and parallelising for free.
 * See `ramen compserver`.
 *)

let compile_sync conf replace src_file source_name_opt =
  let open RamenSync in
  let source = Files.read_whole_file src_file in
  let md5 = N.md5 source in
  let value = Value.of_string source in
  let source_name =
    Option.default_delayed (fun () ->
      Files.remove_ext (N.simplified_path src_file)
    ) source_name_opt in
  let ext = Files.ext src_file in
  if ext = "" then
    failwith "Need an extension to build a source file." ;
  let k_source = Key.(Sources (source_name, ext)) in
  let on_ko () = Processes.quit := Some 1 in
  let on_set _clt k v _u _mtime =
    match k, v with
    | Key.(Sources (p, "info")), Value.(SourceInfo s)
      when p = source_name ->
        if s.Value.SourceInfo.md5 = md5 then (
          !logger.info "%a" Value.SourceInfo.print s ;
          !logger.debug "Quitting..." ;
          (* FIXME: if we see this during the initial sync we might not
           * have received the error message yet ; or not even sent the
           * source code actually. *)
          if not (Value.SourceInfo.compiled s ) then (
            Processes.quit := Some 1 ;
            !logger.error "Cannot compile: %s"
              (Value.SourceInfo.compilation_error s)
          ) else
            Processes.quit := Some 0
        ) else (
          !logger.warning "Server MD5 for %a is %S instead of %S, waiting..."
            N.path_print source_name s.Value.SourceInfo.md5 md5
        )
    | _ -> () in
  let on_new clt k v uid mtime _owner _expiry = on_set clt k v uid mtime in
  let topics = [
    (N.path_cat [ N.path "sources" ; source_name ; N.path "info" ] :> string)
  ] in
  start_sync conf ~while_ ~on_new ~on_set ~topics (fun clt ->
    if replace then
      ZMQClient.send_cmd ~while_
        (LockOrCreateKey (k_source, Default.sync_lock_timeout))
        ~on_ko ~on_ok:(fun () ->
          ZMQClient.send_cmd ~while_ (SetKey (k_source, value))
            ~on_ko ~on_ok:(fun () ->
              ZMQClient.send_cmd ~while_ (UnlockKey k_source)))
    else
      ZMQClient.send_cmd ~while_ (NewKey (k_source, value, 0.)) ~on_ko ;
    ZMQClient.process_in ~while_ clt)

(* Do not generate any executable file, but parse/typecheck new or updated
 * source programs, using the build infrastructure to accept any source format
 * (for now distinguishing them using extension as usual).
 * The only change required from the builder is:
 * - source/target files are read from and written to the config tree instead
 *   of the file system;
 * - instead of using mtime, it must use the md5s;
 * - it must stop before reaching the .x but instead aim for a "/info".
 *)
let compserver conf daemonize to_stdout to_syslog
               use_external_compiler max_simult_compils smt_solver () =
  if conf.C.sync_url = "" then
    failwith "Cannot start the compilation service without --confserver." ;
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  start_daemon conf daemonize to_stdout to_syslog (N.path "compserver") ;
  let topics = [ "sources/*" ] in
  let open RamenSync in
  let on_set clt k v _uid mtime =
    let get_parent = RamenCompiler.parent_from_confserver clt in
    match k, v with
    | Key.(Sources (_, "info")), _ -> ()
    | Key.(Sources (src_file, ext)), Value.RamenValue T.(VString text) ->
        assert (ext <> "info") ;
        let k_info = Key.(Sources (src_file, "info")) in
        let open ZMQClient in
        let unlock () =
          !logger.debug "Unlocking %a" Key.print k_info ;
          send_cmd ~while_ (UnlockKey k_info) in
        send_cmd ~while_
          (LockOrCreateKey (k_info, Default.sync_compile_timeo))
          ~on_ko:unlock ~on_ok:(fun () ->
            let tmp_src_file =
              N.path_cat [ conf.C.persist_dir ; N.path "compserver/tmp" ;
                           N.path ((src_file :> string) ^"."^ ext) ] in
            let target_file = Files.change_ext "info" tmp_src_file in
            !logger.debug "Creating temporary source files %a and %a"
              N.path_print tmp_src_file
              N.path_print target_file ;
            Files.write_whole_file tmp_src_file text ;
            (* Replicate the mtimes in the local FS temporary files, for the
             * builder to use the usual mtime comparison to determine
             * obsolescence: *)
            Files.touch tmp_src_file mtime ;
            (match Client.find clt Key.(Sources (src_file, "info")) with
            | exception Not_found -> ()
            | { mtime ; _ } ->
                if Files.exists target_file then Files.touch target_file mtime) ;
            (* Program name used to resolve relative names is the location in the
             * source tree: *)
            let program_name = N.program (Files.remove_ext src_file :> string) in
            let info =
              match RamenMake.build conf get_parent program_name
                                    tmp_src_file target_file with
              | exception e ->
                !logger.error "Cannot build %a into %a: %s"
                  N.path_print src_file
                  N.path_print target_file
                  (Printexc.to_string e) ;
                { md5 = Files.read_whole_file tmp_src_file |> N.md5 ;
                  detail = Failed { err_msg = Printexc.to_string e } }
              | () ->
                !logger.debug "Read result from info file %a"
                  N.path_print target_file ;
                RamenMake.read_source_info target_file in
            !logger.info "(pre)Compiled %a into %a"
              N.path_print src_file Value.SourceInfo.print info ;
            send_cmd ~while_
              (SetKey (k_info, Value.(SourceInfo info)))
              ~on_ko:unlock ~on_ok:unlock)
    | Key.Error _, _  ->
        (* Errors have been logged already *)
        ()
    | k, v ->
        !logger.warning "Irrelevant: %a, %a"
          Key.print k Value.print v in
  let on_new clt k v uid mtime _owner _expiry = on_set clt k v uid mtime in
  start_sync conf ~while_ ~on_new ~on_set ~topics
                  (ZMQClient.process_in ~while_)

let compile conf lib_path use_external_compiler
            max_simult_compils smt_solver source_files
            output_file_opt program_name_opt replace () =
  let many_source_files = List.length source_files > 1 in
  if many_source_files && program_name_opt <> None then
    failwith "Cannot specify the program name for several source files." ;
  init_logger conf.C.log_level ;
  List.iter (fun source_file ->
    if conf.C.sync_url = "" then
      compile_local conf lib_path use_external_compiler
                    max_simult_compils smt_solver source_file
                    output_file_opt program_name_opt
    else
      let target_file_opt =
        Option.map (fun s ->
          Files.remove_ext (N.path (s : N.program :> string))
        ) program_name_opt in
      compile_sync conf replace source_file target_file_opt
  ) source_files

(*
 * `ramen run`
 *
 * Ask the ramen daemon to start a compiled program.
 *)

let run conf params replace kill_if_disabled report_period program_name_opt
        src_file on_site bin_file () =
  let params = List.enum params |> Hashtbl.of_enum in
  init_logger conf.C.log_level ;
  (* If we run in --debug mode, also set that worker in debug mode: *)
  let debug = conf.C.log_level = Debug in
  RamenRun.run conf ~params ~debug ~replace ~kill_if_disabled ~report_period
               ?src_file ~on_site bin_file program_name_opt

(*
 * `ramen kill`
 *
 * Remove that program from the list of running programs.
 * This time the program is identified by its name not its executable file.
 *)

let kill conf program_names purge () =
  init_logger conf.C.log_level ;
  let num_kills = RamenRun.kill conf ~purge program_names in
  Printf.printf "Killed %d program%s\n"
    num_kills (if num_kills > 1 then "s" else "")

(*
 * `ramen choreographer`
 *
 * Turn the MustRun config into a FuncGraph and expose it in the configuration
 * for the supervisor.
 *)
let choreographer conf daemonize to_stdout to_syslog () =
  if conf.C.sync_url = "" then
    failwith "Cannot start the choreographer without --confserver." ;
  start_daemon conf daemonize to_stdout to_syslog (N.path "choreographer") ;
  RamenChoreographer.start conf ~while_


(*
 * `ramen info`
 *
 * Display a program or function meta information from the binary.
 *)

let prog_info prog opt_func_name =
  if prog.P.default_params <> [] then (
    TermTable.print_head 0 "Parameters" ;
    TermTable.print 1 "%a" RamenTuple.print_params prog.default_params) ;
  TermTable.print_head 0 "Running condition" ;
  TermTable.print 1 "%a" (RamenExpr.print true) prog.condition ;
  let info_func i func =
    TermTable.print i "%s" (N.func_color func.F.name) ;
    if func.doc <> "" then TermTable.print_abstract i func.doc ;
    TermTable.print_head (i+1) "Parents" ;
    if func.parents = [] then
      TermTable.print (i+2) "None"
    else
      List.iter (function
        | site, None, f ->
            TermTable.print (i+2) "%a%s"
              O.print_site_identifier site
              (N.func_color f)
        | site, Some rp, f ->
            TermTable.print (i+2) "%a%s/%s"
              O.print_site_identifier site
              (N.rel_program_color rp)
              (N.func_color f)
      ) func.parents ;
    TermTable.print_head (i+1) "Input type" ;
    TermTable.print (i+2) "%a" RamenFieldMaskLib.print_in_type func.in_type ;
    let out_type =
      O.out_type_of_operation ~with_private:false func.operation in
    TermTable.print_head (i+1) "Output type" ;
    TermTable.print (i+2) "Ramen: %a" RamenTuple.print_typ out_type ;
    TermTable.print (i+2) "ORC: %a"
      RamenOrc.print (RamenOrc.of_tuple out_type) ;
    O.event_time_of_operation func.operation |>
    Option.may (fun et ->
      TermTable.print_head (i+1) "Event time" ;
      TermTable.print (i+2) "%a" EventTime.print et) ;
    TermTable.print_head (i+1) "Factors" ;
    TermTable.print (i+2) "%a"
      (List.print N.field_print) (O.factors_of_operation func.operation) ;
    TermTable.print_head (i+1) "Operation" ;
    TermTable.print (i+2) "%a" (O.print true) func.operation ;
    if func.F.retention <> None || func.F.is_lazy then (
      let lst = [] in
      let lst =
        match func.F.retention with
        | Some r ->
            IO.to_string RamenProgram.print_retention r :: lst
        | None ->
          lst in
      let lst =
        if func.F.is_lazy then "lazy"::lst else lst in
      TermTable.print_head (i+1) "Misc" ;
      TermTable.print (i+2) "%a"
        (List.print ~first:"" ~last:"" ~sep:", " String.print) lst
    ) ;
    print_endline ""
  in
  match opt_func_name with
  | None ->
      TermTable.print_head 0 "Functions" ;
      List.iter (info_func 1) prog.funcs
  | Some func_name ->
      (match List.find (fun func ->
               func.F.name = func_name) prog.funcs with
      | exception Not_found ->
          Printf.sprintf2 "No such function %a"
            N.func_print func_name |>
          failwith
      | func -> info_func 0 func)

let info_local params program_name_opt bin_file opt_func_name =
  let params = List.enum params |> Hashtbl.of_enum in
  let program_name =
    Option.default_delayed (fun () ->
      RamenRun.default_program_name bin_file
    ) program_name_opt in
  let prog = P.of_bin program_name params bin_file in
  prog_info prog opt_func_name

let info_sync conf program_name_opt (src_path : N.path) opt_func_name =
  let program_name = program_name_opt |? (N.program (src_path :> string)) in
  let topics =
    [ "sources/"^ (src_path :> string) ^"/info" ] in
  start_sync conf ~topics ~while_ (fun clt ->
    let prog = RamenSync.program_of_src_path clt src_path |>
               P.unserialized program_name in
    prog_info prog opt_func_name)

let info conf params program_name_opt bin_file opt_func_name () =
  if conf.C.sync_url = "" then
    info_local params program_name_opt bin_file opt_func_name
  else
    (* bin_file is then the source path! *)
    info_sync conf program_name_opt bin_file opt_func_name

(*
 * `ramen gc`
 *
 * Delete old or unused files.
 *)

let gc conf dry_run del_ratio compress_older loop daemonize
       to_stdout to_syslog () =
  if daemonize && loop = Some 0. then
    failwith "It makes no sense to --daemonize without --loop." ;
  let loop = loop |? Default.gc_loop in
  start_daemon conf daemonize to_stdout to_syslog (N.path "gc") ;
  if conf.C.sync_url = "" then
    if loop <= 0. then
      RamenGc.cleanup_once_local conf dry_run del_ratio compress_older
    else
      RamenGc.cleanup_loop ~while_ conf dry_run del_ratio compress_older loop
  else
    RamenGc.cleanup_sync ~while_ conf dry_run del_ratio compress_older loop ;
  Option.may exit !RamenProcesses.quit

(*
 * `ramen ps`
 *
 * Display information about running programs and quit.
 *)

let sort_col_of_string spec str =
  let str = String.(trim str |> lowercase) in
  try int_of_string str
  with Failure _ ->
    let matching =
      Array.enum spec |> Enum.foldi (fun i c l ->
        let c = String.lowercase c in
        if String.starts_with c str then (i, c) :: l else l) [] in
    (match matching with
    | [ i, _ ] -> i
    | [] ->
        Printf.sprintf2 "Unknown column %S (must be one of %a)"
          str
          (pretty_array_print String.print_quoted) spec |>
        failwith
    | l ->
        Printf.sprintf2 "Ambiguous: %S could be %a"
          str
          (pretty_list_print (fun oc (_, s) ->
            String.print_quoted oc s)) l |>
        failwith)

let ps_local profile conf short pretty with_header sort_col top pattern all =
  let must_run_here rce =
    rce.RC.status = RC.MustRun && RC.match_localsite conf rce.RC.on_site in
  (* Start by reading the last minute of instrumentation data: *)
  let stats = RamenPs.read_stats conf in
  (* Now iter over all workers and display those stats: *)
  let open TermTable in
  if short then
    let head =
      if profile then
        [| "program" ; "top-half" ; "CPU" ; "wait in" ; "wait out" ;
           "tot_per_tuple" ; "where_fast" ; "find_group" ; "where_slow" ;
           "update_group" ; "commit_incoming" ; "select_others" ;
           "finalize_others" ; "commit_others" ; "flush_others" |]
      else
        [| "program" ; "top-half" ; "parameters" ; "#in" ; "#selected" ;
           "#out" ; "#groups" ; "CPU" ; "wait in" ; "wait out" ; "heap" ;
           "max heap" ; "volume in" ; "volume out" |]  in
    let sort_col = sort_col_of_string head sort_col in
    let print = print_table ~pretty ~sort_col ~with_header ?top head in
    (* For --short, we sum everything by program: *)
    let h = RamenPs.per_program stats in
    RC.with_rlock conf (fun programs ->
      Hashtbl.iter (fun (program_name : N.program) (rce, _get_rc) ->
        let display top_half s =
          (if profile then
            [| Some (ValStr (program_name :> string)) ;
               Some (ValBool top_half) ;
               Some (ValFlt s.RamenPs.cpu) ;
               flt_or_na s.wait_in ;
               flt_or_na s.wait_out ;
               perf s.profile.tot_per_tuple ;
               perf s.profile.where_fast ;
               perf s.profile.find_group ;
               perf s.profile.where_slow ;
               perf s.profile.update_group ;
               perf s.profile.commit_incoming ;
               perf s.profile.select_others ;
               perf s.profile.finalize_others ;
               perf s.profile.commit_others ;
               perf s.profile.flush_others |]
          else
            [| Some (ValStr (program_name :> string)) ;
               Some (ValBool top_half) ;
               Some (ValStr (RamenParams.to_string rce.RC.params)) ;
               int_or_na s.in_count ;
               int_or_na s.selected_count ;
               int_or_na s.out_count ;
               int_or_na s.group_count ;
               Some (ValFlt s.cpu) ;
               flt_or_na s.wait_in ;
               flt_or_na s.wait_out ;
               Some (ValInt (Uint64.to_int s.ram)) ;
               Some (ValInt (Uint64.to_int s.max_ram)) ;
               flt_or_na (Option.map Uint64.to_float s.bytes_in) ;
               flt_or_na (Option.map Uint64.to_float s.bytes_out) |]) |>
          print in
        if (all || must_run_here rce) &&
           Globs.matches pattern (program_name :> string)
        then (
          [ false ; true ] |> List.iter (fun top_half ->
            match Hashtbl.find h (program_name, top_half) with
            | exception Not_found ->
                if not top_half then display top_half RamenPs.no_stats
            | s -> display top_half s)
        )
      ) programs) ;
    print [||]
  else
    (* Otherwise we want to display all we can about individual workers *)
    let head =
      if profile then
        [| "operation" ; "top-half" ; "CPU" ; "wait in" ; "wait out" ;
           "tot_per_tuple" ; "where_fast" ; "find_group" ; "where_slow" ;
           "update_group" ; "commit_incoming" ; "select_others" ;
           "finalize_others" ; "commit_others" ; "flush_others" |]
      else
        [| "operation" ; "top-half" ; "#in" ; "#selected" ; "#out" ;
           "#groups" ; "last out" ; "min event time" ; "max event time" ;
           "CPU" ; "wait in" ; "wait out" ; "heap" ; "max heap" ;
           "volume in" ; "volume out" ; "avg out sz" ; "startup time" ;
           "#parents" ; "#children" ; "signature" |] in
    let sort_col = sort_col_of_string head sort_col in
    let print = print_table ~pretty ~sort_col ~with_header ?top head in
    RC.with_rlock conf (fun programs ->
      (* First pass to get the children: *)
      let children_of_func = Hashtbl.create 23 in
      Hashtbl.iter (fun _prog_name (rce, get_rc) ->
        if all || must_run_here rce then match get_rc () with
        | exception _ -> ()
        | prog ->
            List.iter (fun func ->
              List.iter (fun (_, pp, pf) ->
                (* We could use the pattern to filter out uninteresting
                 * parents but there is not much to save at this point. *)
                let k =
                  F.program_of_parent_prog func.F.program_name pp, pf in
                Hashtbl.add children_of_func k func
              ) func.F.parents
            ) prog.P.funcs
      ) programs ;
      Hashtbl.iter (fun ((fq : N.fq), top_half) s ->
        if Globs.matches pattern (fq :> string) then
          match RC.find_func_or_fail programs fq with
          | exception _ -> ()
          | rce, _prog, func ->
              if all || must_run_here rce then (
                (if profile then
                  [| Some (ValStr (fq :> string)) ;
                     Some (ValBool top_half) ;
                     Some (ValFlt s.RamenPs.cpu) ;
                     flt_or_na s.wait_in ;
                     flt_or_na s.wait_out ;
                     perf s.profile.tot_per_tuple ;
                     perf s.profile.where_fast ;
                     perf s.profile.find_group ;
                     perf s.profile.where_slow ;
                     perf s.profile.update_group ;
                     perf s.profile.commit_incoming ;
                     perf s.profile.select_others ;
                     perf s.profile.finalize_others ;
                     perf s.profile.commit_others ;
                     perf s.profile.flush_others |]
                 else
                  let num_children = Hashtbl.find_all children_of_func
                                       (func.F.program_name, func.F.name) |>
                                       List.length in
                  [| Some (ValStr (fq :> string)) ;
                     Some (ValBool top_half) ;
                     int_or_na s.in_count ;
                     int_or_na s.selected_count ;
                     int_or_na s.out_count ;
                     int_or_na s.group_count ;
                     date_or_na s.last_out ;
                     date_or_na s.min_etime ;
                     date_or_na s.max_etime ;
                     Some (ValFlt s.cpu) ;
                     flt_or_na s.wait_in ;
                     flt_or_na s.wait_out ;
                     Some (ValInt (Uint64.to_int s.ram)) ;
                     Some (ValInt (Uint64.to_int s.max_ram)) ;
                     flt_or_na (Option.map Uint64.to_float s.bytes_in) ;
                     flt_or_na (Option.map Uint64.to_float s.bytes_out) ;
                     flt_or_na (Option.map Uint64.to_float s.avg_full_bytes) ;
                     Some (ValDate s.startup_time) ;
                     Some (ValInt (List.length func.F.parents)) ;
                     Some (ValInt num_children) ;
                     Some (ValStr func.signature) |]) |>
                print)
      ) stats) ;
      print [||]

(* TODO: add an option to select the site *)
let ps_sync conf _short pretty with_header sort_col top _pattern =
  let head =
    [| "site" ; "operation" ; "top-half" ; "#in" ; "#selected" ; "#out" ;
       "#groups" ; "last out" ; "min event time" ; "max event time" ;
       "CPU" ; "wait in" ; "wait out" ; "heap" ; "max heap" ;
       "volume in" ; "volume out" ; "avg out sz" ; "startup time" ;
       "#parents" ; "#children" ; "archive size" ; "oldest archived" ;
       "archive duration" ; "worker signature" ; "program signature" |] in
  let open TermTable in
  let sort_col = sort_col_of_string head sort_col in
  let print_tbl = print_table ~pretty ~sort_col ~with_header ?top head in
  let topics =
    [ "sites/*/workers/*/stats/runtime" ;
      "sites/*/workers/*/worker" ;
      "sites/*/workers/*/archives/*" ] in
  start_sync conf ~topics ~while_ (fun clt ->
    let open RamenSync in
    Client.iter clt (fun k v ->
      match k, v.value with
      | Key.PerSite (site, PerWorker (fq, Worker)),
        Value.Worker worker ->
          let get_k k what f =
            let k = Key.PerSite (site, PerWorker (fq, k)) in
            match (Client.find clt k).value with
            | exception Not_found -> None
            | v ->
                (match f v with
                | None -> invalid_sync_type k v what
                | x -> x) in
          let s = get_k RuntimeStats "RuntimeStats" (function
            | Value.RuntimeStats x -> Some x
            | _ -> None) in
          let arc_size = get_k NumArcBytes "NumArcBytes" (function
            | Value.RamenValue T.(VI64 x) -> Some x
            | _ -> None) |? 0L in
          let arc_times = get_k ArchivedTimes "ArchivedTimes" (function
            | Value.TimeRange x -> Some x
            | _ -> None) |? [] in
          let arc_oldest = match arc_times with [] -> None
                                              | (a, _, _) :: _ -> Some a in
          let arc_duration = TimeRange.span arc_times in
          let open Value.RuntimeStats in
          [| Some (ValStr (site :> string)) ;
             Some (ValStr (fq :> string)) ;
             Some (ValBool (worker.Value.Worker.role <> Whole)) ;
             Option.map (fun s -> ValInt (Uint64.to_int s.tot_in_tuples)) s ;
             Option.map (fun s -> ValInt (Uint64.to_int s.tot_sel_tuples)) s ;
             Option.map (fun s -> ValInt (Uint64.to_int s.tot_out_tuples)) s ;
             Option.map (fun s -> ValInt (Uint64.to_int s.cur_groups)) s ;
             Option.bind s (fun s -> date_or_na s.last_output) ;
             Option.bind s (fun s -> date_or_na s.min_etime) ;
             Option.bind s (fun s -> date_or_na s.max_etime) ;
             Option.map (fun s -> ValFlt s.tot_cpu) s ;
             Option.map (fun s -> ValFlt s.tot_wait_in) s ;
             Option.map (fun s -> ValFlt s.tot_wait_out) s ;
             Option.map (fun s -> ValInt (Uint64.to_int s.cur_ram)) s ;
             Option.map (fun s -> ValInt (Uint64.to_int s.max_ram)) s ;
             Option.map (fun s -> ValFlt (Uint64.to_float s.tot_in_bytes)) s ;
             Option.map (fun s -> ValFlt (Uint64.to_float s.tot_out_bytes)) s ;
             Option.bind s (fun s ->
               if Uint64.(compare s.tot_full_bytes_samples zero) > 0 then
                 Some (ValFlt (Uint64.to_float s.tot_full_bytes /.
                               Uint64.to_float s.tot_full_bytes_samples))
               else
                 None) ;
             Option.map (fun s -> ValDate s.last_startup) s ;
             Some (ValInt (List.length worker.parents)) ;
             Some (ValInt (List.length worker.children)) ;
             Some (ValInt (Int64.to_int arc_size)) ;
             Option.map (fun s -> ValDate s) arc_oldest ;
             Some (ValDuration arc_duration) ;
             Some (ValStr worker.worker_signature) ;
             Some (ValStr worker.bin_signature) |] |>
          print_tbl
      | _ -> ())) ;
  print_tbl [||]

let ps_ profile conf short pretty with_header sort_col top pattern all () =
  if profile && conf.C.sync_url <> "" then
    failwith "The profile command is incompatible with --confserver." ;
  init_logger conf.C.log_level ;
  if conf.C.sync_url <> "" then
    ps_sync conf short pretty with_header sort_col top pattern
  else
    ps_local profile conf short pretty with_header sort_col top pattern all

let ps = ps_ false
let profile = ps_ true

(*
 * `ramen tail`
 *
 * Display the last tuple(s) output by an operation.
 *
 * This first create a non-wrapping buffer file and then asks the operation
 * to write in there for 1 hour (by default).
 * This buffer name is standard so that other clients wishing to read those
 * tuples can reuse the same and benefit from a shared history.
 *)

let table_formatter pretty raw null units =
  (* TODO: reuse RamenTypes in TermTable *)
  let open RamenTypes in
  let open TermTable in
  function
  | VFloat t ->
      if units = Some RamenUnits.seconds_since_epoch && pretty then
        Some (ValDate t)
      else if units = Some RamenUnits.seconds && pretty then
        Some (ValDuration t)
      else
        Some (ValFlt t)
  | VNull -> None
  | t ->
    Some (ValStr (IO.to_string (print_custom ~null ~quoting:(not raw)) t))

(* [func_name_or_code] is a list of strings as present in the command
 * line. It could be a function name followed by a list of field names, or
 * it could be the code of a function which output we want to display.
 * We find out by picking the first that works. In case both approach
 * fails we have to display the two error messages though. *)
let parse_func_name_of_code conf what func_name_or_code =
  let parse_as_names () =
    match func_name_or_code with
    | func_name :: field_names ->
        let fq = N.fq func_name
        and field_names = List.map N.field field_names in
        let ret = fq, field_names, [] in
        (* First, is it any of the special ringbuf? *)
        if String.ends_with func_name ("#"^ SpecialFunctions.stats) ||
           String.ends_with func_name ("#"^ SpecialFunctions.notifs) then
          ret
        else
          (* Check this function exists: *)
          if conf.C.sync_url = "" then (
            RC.with_rlock conf (fun programs ->
              RC.find_func programs fq |> ignore) ;
            ret
          ) else
            (* FIXME: Assume the function exists.* In the future, have
             * the connection to confserver already setup. *)
            ret
    | _ -> assert false (* As the command line parser prevent this *)
  and parse_as_code () =
    if conf.C.sync_url <> "" then
      failwith "TODO: confserver support for immediate code" ;
    let program_name = C.make_transient_program () in
    let func_name = N.func "f" in
    let programs = RC.with_rlock conf identity in (* best effort *)
    let get_parent = RamenCompiler.parent_from_programs programs in
    let oc, src_file =
      BatFile.open_temporary_out ~prefix:what ~suffix:".ramen" () in
    let src_file = N.path src_file in
    !logger.info "Going to use source file %a"
      N.path_print_quoted src_file ;
    let bin_file = Files.change_ext "x" src_file in
    on_error
      (fun () ->
        if not conf.C.keep_temp_files then (
          Files.safe_unlink src_file ;
          Files.safe_unlink bin_file))
      (fun () ->
        Printf.fprintf oc
          "-- Temporary file created on %a for %s\n\
           DEFINE '%s' AS\n%a\n"
          print_as_date (Unix.time ())
          what
          (func_name :> string)
          (List.print ~first:"" ~last:"" ~sep:" " String.print)
            func_name_or_code ;
        close_out oc ;
        Files.safe_unlink bin_file ; (* hahaha! *)
        RamenMake.build conf get_parent program_name src_file bin_file ;
        (* Run it, making sure it archives its history straight from the
         * start: *)
        let debug = conf.C.log_level = Debug in
        RamenRun.run conf ~report_period:0. ~src_file ~debug
                     bin_file (Some program_name)) ;
    let fq = N.fq_of_program program_name func_name in
    fq, [], [ program_name ]
  in
  try
    parse_as_names ()
  with e1 ->
    try parse_as_code ()
    with e2 ->
      let cmd_line = String.join " " func_name_or_code in
      Printf.sprintf
        "Cannot parse %S as a function name (%s) nor as a program (%s)"
        cmd_line
        (Printexc.to_string e1)
        (Printexc.to_string e2) |>
      failwith

let head_of_types ~with_units head_typ =
  Array.map (fun t ->
    (t.RamenTuple.name :> string) ^
       (if with_units then
         Option.map_default RamenUnits.to_string "" t.units
       else "")
  ) head_typ

let tail_local
      conf fq field_names with_header with_units sep null raw
      last next min_seq max_seq continuous where since until
      with_event_time duration pretty flush =
  if (last <> None || next <> None || continuous) &&
     (min_seq <> None || max_seq <> None) then
    failwith "Options --{last,next,continuous} and \
              --{min,max}-seq are incompatible." ;
  if continuous && next <> None then
    failwith "Option --next and --continuous are incompatible." ;
  if with_units && with_header = 0 then
    failwith "Option --with-units makes no sense without --with-header." ;
  (* Do something useful by default: display the 10 last lines *)
  let last =
    if last = None && next = None && min_seq = None && max_seq = None &&
       since = None && until = None
    then Some 10 else last in
  let flush = flush || continuous in
  let next = if continuous then Some max_int else next in
  let programs = RC.with_rlock conf identity in
  let bname, is_temp_export, filter, ser, params, event_time =
    RamenExport.read_output conf ~duration fq where programs
  in
  (* Find out which seqnums we want to scan: *)
  let mi, ma = match last, next with
    | None, None ->
        min_seq,
        Option.map succ max_seq (* max_seqnum is in *)
    | Some l, None ->
        let _mi, ma = RingBufLib.seq_range bname in
        Some (cap_add ma ~-l),
        Some ma
    | None, Some n ->
        let _mi, ma = RingBufLib.seq_range bname in
        Some ma, Some (cap_add ma n)
    | Some l, Some n ->
        let _mi, ma = RingBufLib.seq_range bname in
        Some (cap_add ma ~-l), Some (cap_add ma n)
  in
  !logger.debug "Will display tuples from %a (incl) to %a (excl)"
    (Option.print Int.print) mi
    (Option.print Int.print) ma ;
  let field_names = RamenExport.check_field_names ser field_names in
  let head_idx, head_typ =
    RamenExport.header_of_type ~with_event_time field_names ser in
  let open TermTable in
  let head_typ = Array.of_list head_typ in
  let head = head_of_types ~with_units head_typ in
  let print = print_table ~sep ~pretty ~with_header ~flush head in
  (* Pick a "printer" for each column according to the field type: *)
  let formatter = table_formatter pretty raw null
  in
  if is_temp_export then (
    let rec reset_export_timeout () =
      let _mre, _prog, func =
        RC.with_rlock conf (fun programs ->
          RC.find_func_or_fail programs fq) in
      let _ = RamenProcesses.start_export conf ~duration func in
      (* Start by sleeping as we've just set the temp export above: *)
      Unix.sleepf (max 1. (duration -. 1.)) ;
      reset_export_timeout () in
    Thread.create (
      restart_on_failure "reset_export_timeout"
        reset_export_timeout) () |> ignore) ;
  let open RamenSerialization in
  let event_time_of_tuple = match event_time with
    | None ->
        if with_event_time then
          failwith "Function has no event time information"
        else (fun _ -> 0., 0.)
    | Some et ->
        event_time_of_tuple ser params et
  in
  let unserialize = RamenSerialization.read_array_of_values ser in
  (* Then, scan all present ringbufs in the requested range (either
   * the last N tuples or, TBD, since ts1 [until ts2]) and display
   * them *)
  fold_seq_range ~wait_for_more:true bname ?mi ?ma () (fun () _m tx ->
    match RamenSerialization.read_tuple unserialize tx with
    | RingBufLib.DataTuple chan, Some tuple
      when chan = RamenChannel.live && filter tuple ->
        let t1, t2 = event_time_of_tuple tuple in
        if Option.map_default (fun since -> t2 > since) true since &&
           Option.map_default (fun until -> t1 <= until) true until
        then (
          let cols =
            Array.mapi (fun i idx ->
              match idx with
              | -2 -> Some (ValDate t2)
              | -1 -> Some (ValDate t1)
              | idx -> formatter head_typ.(i).units tuple.(idx)
            ) head_idx in
          print cols
        ) else (
          !logger.debug "evtime %f..%f filtered out" t1 t2
        )
    | _ -> ()) ;
  print [||]

(* Sync version of tail cannot use seqnums nor since/until; use replay for
 * that, which is more generic and does not depends on local files. *)
(* TODO: add with_site *)
(* FIXME: last/next semantic is unclear. For now we just print last+next
 * tuples. Use the max seqnum found just after sync as the current seqnum?
 * Also, if workers used tuple seqnum as the sequence id to identify tuples,
 * we would need no skipped counter and could use min/max_seq.
 * FIXME: regarding tail rate limit: To make tail more useful make the rate
 * limit progressive? *)
let tail_sync
      conf (fq : N.fq) field_names with_header with_units sep null raw
      last next min_seq max_seq continuous where since until
      with_event_time _duration pretty flush =
  if min_seq <> None || max_seq <> None then
    failwith "Options --{min,max}-seq are incompatible with --confserver." ;
  if since <> None || until <> None then
    !logger.warning
      "With --confserver, options --since/--until filter but do not select." ;
  if continuous && next <> None then
    failwith "Option --next and --continuous are incompatible." ;
  if with_units && with_header = 0 then
    failwith "Option --with-units makes no sense without --with-header." ;
  (* Do something useful by default: display the 10 last lines *)
  let last =
    if last = None && next = None && min_seq = None && max_seq = None &&
       since = None && until = None
    then 10 else last |? 0 in
  let flush = flush || continuous in
  let next = if continuous then max_int else next |? 0 in
  (* We need to check that this worker is indeed running, get its output type,
   * and then we want to receive its tail.
   * No need to receive its subscribers though. *)
  (* TODO: a way to specify another glob: *)
  let sites = "*" in
  let topics =
    [ "sites/"^ sites ^"/workers/"^ (fq :> string) ^"/worker" ;
      (* TODO: would be faster to sync the specific sources once we know
       * their name, rather than all defined sources. *)
      "sources/*/info" ;
      "tails/"^ sites ^"/"^ (fq :> string) ^"/lasts/*" ] in
  start_sync conf ~topics ~while_ (fun clt ->
    let open RamenSync in
    (* Get the workers and their types: *)
    !logger.debug "Looking for running workers %a on sites %S"
      N.fq_print fq
      sites ;
    let workers =
      Client.fold clt (fun k v lst ->
        match k, v.value with
        | PerSite (site, PerWorker (fq', Worker)),
          Worker worker
          when worker.role = Whole ->
            assert (fq = fq') ;
            (site, worker) :: lst
        | _ -> lst
      ) [] in
    !logger.debug "Found sites: %a"
      (Enum.print N.site_print) (List.enum workers /@ fst) ;
    if workers = [] then
      Printf.sprintf2 "Function %a is not running anywhere"
        N.fq_print fq |>
      failwith ;
    let out_types =
      (List.enum workers /@ snd |>
      (* enumerates workers with distinct src_path *)
      Enum.uniq_by
        (fun w1 w2 -> N.eq w1.Value.Worker.src_path w2.src_path)) /@
      function_of_worker clt fq /@
      (fun (_prog, func) ->
        O.out_type_of_operation ~with_private:false func.FS.operation,
        O.event_time_of_operation func.operation) |>
      Enum.uniq_by
        (fun (t1, et1) (t2, et2) ->
          RamenTuple.eq_types t1 t2 &&
          (not with_event_time && since = None && until = None ||
           et1 = et2)) |>
      List.of_enum in
    if List.length out_types <> 1 then
      Printf.sprintf2 "Running workers for %a output different types: %a"
        N.fq_print fq
        (List.print (Tuple2.print RamenTuple.print_typ
                                  (Option.print EventTime.print)))
          out_types |>
      failwith ;
    let out_type, event_time = List.hd out_types in
    let out_type =
      RingBufLib.ser_tuple_typ_of_tuple_typ out_type |>
      List.map fst in
    !logger.debug "Tuple serialized type: %a"
      RamenTuple.print_typ out_type ;
    !logger.debug "Nullmask size: %d"
      (RingBufLib.nullmask_bytes_of_tuple_type out_type) ;
    (* Prepare to print the tails *)
    let field_names = RamenExport.check_field_names out_type field_names in
    let head_idx, head_typ =
      RamenExport.header_of_type ~with_event_time field_names out_type in
    let open TermTable in
    let head_typ = Array.of_list head_typ in
    let head = head_of_types ~with_units head_typ in
    let print = print_table ~sep ~pretty ~with_header ~flush head in
    (* Pick a "printer" for each column according to the field type: *)
    let formatter = table_formatter pretty raw null
    in
    let open RamenSerialization in
    let event_time_of_tuple = match event_time with
      | None ->
          if with_event_time then
            failwith "Function has no event time information"
          else (fun _ -> 0., 0.)
      | Some et ->
          (* As we might be tailling from several instance of the same
           * worker, we have already lost track of the params at this point.
           * Problem solved by removing the event-time notation and type
           * altogether and use only the conventional start/stop fields. *)
          let params = [] in
          event_time_of_tuple out_type params et
    in
    let unserialize = RamenSerialization.read_array_of_values out_type in
    let filter = RamenSerialization.filter_tuple_by out_type where in
    (* Callback for each tuple: *)
    let count_last = ref last and count_next = ref next in
    let on_key counter k v =
      match k, v with
      | Key.Tails (_site, _fq, LastTuple _seq),
        Value.Tuple { skipped ; values } ->
          if skipped > 0 then
            !logger.warning "Skipped %d tuples" skipped ;
          let tx = RingBuf.tx_of_bytes values in
          (match unserialize tx 0 with
          | exception RingBuf.Damaged ->
              !logger.error "Cannot unserialize tail tuple: %a"
                (hex_print ~from_rb:false ?num_cols:None) values
          | tuple when filter tuple ->
              let t1, t2 = event_time_of_tuple tuple in
              if Option.map_default (fun since -> t2 > since) true since &&
                 Option.map_default (fun until -> t1 <= until) true until
              then (
                let cols =
                  Array.mapi (fun i idx ->
                    match idx with
                    | -2 -> Some (ValDate t2)
                    | -1 -> Some (ValDate t1)
                    | idx -> formatter head_typ.(i).units tuple.(idx)
                  ) head_idx in
                print cols ;
                decr counter
              ) else
                !logger.debug "evtime %f..%f filtered out" t1 t2
          | _ -> ())
      | _ -> () in
    (* Iter over tuples received at sync: *)
    Client.iter clt (fun k hv -> on_key count_last k hv.value) ;
    (* Subscribe to all those tails: *)
    !logger.debug "Subscribing to %d workers tail" (List.length workers) ;
    let subscriber =
      conf.C.username ^"-tail-"^ string_of_int (Unix.getpid ()) in
    List.iter (fun (site, _w) ->
      let k = Key.Tails (site, fq, Subscriber subscriber) in
      let cmd = Client.CltMsg.NewKey (k, Value.dummy, 0.) in
      ZMQClient.send_cmd ~while_ cmd
    ) workers ;
    (* Loop *)
    !logger.debug "Waiting for tuples..." ;
    let while_' () =
      while_ () && (!count_last > 0 || !count_next > 0) in
    clt.Client.on_new <-
      fun _ k v _ _ _ _ -> on_key count_next k v ;
    ZMQClient.process_in ~while_:while_' clt ;
    print [||] ;
    (* Unsubscribe *)
    !logger.debug "Unsubscribing from %d tails..." (List.length workers) ;
    List.iter (fun (site, _w) ->
      let k = Key.Tails (site, fq, Subscriber subscriber) in
      let cmd = Client.CltMsg.DelKey k in
      ZMQClient.send_cmd ~while_ cmd
    ) workers)

let purge_transient conf to_purge () =
  if to_purge <> [] then
    let patterns =
      List.map (fun (p : N.program) ->
        Globs.escape (p :> string)
      ) to_purge in
    let nb_kills = RamenRun.kill conf ~purge:true patterns in
    !logger.debug "Killed %d programs" nb_kills

let tail conf func_name_or_code with_header with_units sep null raw
         last next min_seq max_seq continuous where since until
         with_event_time duration pretty flush
         (* We might compile the command line: *)
         use_external_compiler max_simult_compils smt_solver
         () =
  init_logger conf.C.log_level ;
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  let fq, field_names, to_purge =
    parse_func_name_of_code conf "ramen tail" func_name_or_code in
  finally (purge_transient conf to_purge)
    ((if conf.C.sync_url = "" then  tail_local else tail_sync)
        conf fq field_names with_header with_units sep null raw
        last next min_seq max_seq continuous where since until
        with_event_time duration pretty) flush

(*
 * `ramen replay`
 *
 * Like tail, but replays history.
 * Mainly for testing purposes for now.
 * `tail` ask a worker to archive its output and then display this archive.
 * Non-live channels are never archived though. So replay has to create its
 * own receiving ring-buffer like a new worker would do, create a channel,
 * ask for the operation to output this channel to this ringbuf,
 * choose the replayers according to the stats file, setup all the out_ref
 * from the replayers to its own ringbuf (no the outref currently in place
 * should be ok), and finally launch the replayers.
 *
 * Note: refactor the CSV dumper to accommodate for tail, replay and
 * time series.
 *)

let replay_ conf fq field_names with_header with_units sep null raw
            where since until with_event_time pretty flush =
  if with_units && with_header = 0 then
    failwith "Option --with-units makes no sense without --with-header." ;
  let until = until |? Unix.gettimeofday () in
  let formatter = table_formatter pretty raw null in
  let callback head =
    let head = Array.of_list head in
    let head' = head_of_types ~with_units head in
    let print = TermTable.print_table ~na:null ~sep ~pretty ~with_header
                                      ~flush head' in
    (fun _t1 _t2 tuple ->
      let vals =
        Array.mapi (fun i -> formatter head.(i).units) tuple in
      print vals),
    (fun () -> print [||]) in
  if conf.C.sync_url = "" then
    RamenExport.replay_local conf ~while_ fq field_names where since until
                             ~with_event_time callback
  else
    let topics = RamenExport.replay_topics in
    start_sync conf ~topics ~while_
      (RamenExport.replay_sync conf ~while_ fq field_names where since until
                               ~with_event_time callback)

let replay conf func_name_or_code with_header with_units sep null raw
           where since until with_event_time pretty flush
           (* We might compile the command line: *)
           use_external_compiler max_simult_compils smt_solver
           () =
  init_logger conf.C.log_level ;
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  let fq, field_names, to_purge =
    parse_func_name_of_code conf "ramen tail" func_name_or_code in
  finally (purge_transient conf to_purge)
    (replay_ conf fq field_names with_header with_units sep null raw
             where since until with_event_time pretty) flush

(*
 * `ramen timeseries`
 *
 * Similar to tail, but output only two columns: time and a value, and
 * make sure to provide as many data samples as asked for, consolidating
 * the actual samples as needed.
 *
 * This works only on operations with time-event information and uses the
 * same output archive files as the `ramen tail` command does.
 *)

let timeseries_ conf fq data_fields
                since until with_header where factors num_points
                time_step sep null consolidation
                bucket_time pretty =
  let num_points =
    if num_points <= 0 && time_step <= 0. then 100 else num_points in
  let until = until |? Unix.gettimeofday () in
  let since = since |? until -. 600. in
  (* Obtain the data: *)
  let num_points, since, until =
    RamenTimeseries.compute_num_points time_step num_points since until in
  let columns, timeseries =
    if conf.C.sync_url = "" then
      RamenTimeseries.get_local conf num_points since until where factors
          ~consolidation ~bucket_time fq data_fields
    else
      let topics = RamenExport.replay_topics in
      start_sync conf ~topics ~while_
        (RamenTimeseries.get_sync conf num_points since until where factors
          ~consolidation ~bucket_time fq data_fields ~while_)
  in
  (* Display results: *)
  let single_data_field = List.length data_fields = 1 in
  let head =
    Array.fold_left (fun res sc ->
      let v =
        Array.enum sc /@ T.to_string |>
        List.of_enum |>
        String.concat "." in
      if single_data_field then
        (if v = "" then (List.hd data_fields :> string) else v) :: res
      else
        List.fold_left (fun res (df : N.field) ->
          ((df :> string) ^ (if v = "" then "" else "("^ v ^")")) :: res
        ) res data_fields
    ) [] columns |> List.rev in
  let head = "Time" :: head |> Array.of_list in
  let open TermTable in
  let print = print_table ~na:null ~sep ~pretty ~with_header head in
  Enum.iter (fun (t, vs) ->
    Array.append
      [| Some (ValDate t) |]
      (Array.concat
        (List.map
          (Array.map (function
            | None -> None
            | Some v -> Some (ValFlt v))) (Array.to_list vs))) |>
    print
  ) timeseries ;
  print [||]

let timeseries conf func_name_or_code
               since until with_header where factors num_points
               time_step sep null consolidation
               bucket_time pretty
               (* We might compile the command line: *)
               use_external_compiler max_simult_compils smt_solver
               () =
  init_logger conf.C.log_level ;
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  let fq, field_names, to_purge =
    parse_func_name_of_code conf "ramen tail" func_name_or_code in
  finally (purge_transient conf to_purge)
    (timeseries_ conf fq field_names
                 since until with_header where factors num_points
                 time_step sep null consolidation
                 bucket_time) pretty

(*
 * `ramen httpd`
 *
 * Starts an HTTP daemon that will serve (and maybe one day also accept)
 * time series, either impersonating Graphite API (https://graphiteapp.org/)
 * or any other API of our own.
 *)

let httpd conf daemonize to_stdout to_syslog fault_injection_rate
          server_url api graphite
          (* The API might compile some code: *)
          use_external_compiler max_simult_compils smt_solver
          () =
  RamenCompiler.init use_external_compiler max_simult_compils smt_solver ;
  if fault_injection_rate > 1. then
    failwith "Fault injection rate is a rate is a rate." ;
  start_daemon conf daemonize to_stdout to_syslog (N.path "httpd") ;
  RamenHttpd.run_httpd conf server_url api graphite fault_injection_rate ;
  Option.may exit !RamenProcesses.quit

(* TODO: allow several queries as in the API *)
let graphite_expand conf for_render since until query () =
  init_logger conf.C.log_level ;
  if not for_render then
    RamenGraphite.metrics_find conf ?since ?until query |>
    List.of_enum |>
    PPP.to_string ~pretty:true RamenGraphite.metrics_ppp_json |>
    Printf.printf "%s\n"
  else
    RamenGraphite.targets_for_render conf ?since ?until [ query ] |>
    Enum.iter (fun (_func, fq, fvals, data_field) ->
      Printf.printf "%a %a with %a"
        N.fq_print fq
        N.field_print data_field
        (Set.print (fun oc (factor, opt_val) ->
          Printf.fprintf oc "%a:" N.field_print factor ;
          match opt_val with
          | None -> String.print oc "*"
          | Some v -> T.print oc v)) fvals)

(*
 * `ramen archivist`
 *
 * A daemon that react to RC stats and a user configuration file
 * and decides what worker should save its history in order to be
 * able to retrieve or rebuild the output of all persistent functions.
 *)

let archivist conf loop daemonize stats allocs reconf
              to_stdout to_syslog smt_solver () =
  RamenSmt.solver := smt_solver ;
  if not stats && not allocs && not reconf then
    failwith "Must specify at least one of --stats, --allocs or --reconf." ;
  if daemonize && loop = Some 0. then
    failwith "It makes no sense to --daemonize without --loop." ;
  if stats && conf.C.sync_url <> "" then
    failwith "The --stats command makes no sens with confserver." ;
  let loop = loop |? Default.archivist_loop in
  start_daemon conf daemonize to_stdout to_syslog (N.path "archivist") ;
  if conf.C.sync_url = "" then (
    if loop <= 0. then
      RamenArchivist.run_once conf ~while_ stats allocs reconf
    else
      RamenArchivist.run_loop conf ~while_ loop stats allocs reconf
  ) else (
    RamenArchivist.run_sync conf ~while_ loop allocs reconf
  ) ;
  Option.may exit !RamenProcesses.quit

(*
 * Display various internal informations
 *)

let variants conf () =
  init_logger conf.C.log_level ;
  let open RamenExperiments in
  let experimenter_id = get_experimenter_id conf.C.persist_dir in
  Printf.printf "Experimenter Id: %d\n" experimenter_id ;
  Printf.printf "Experiments (legend: %s | %s | unselected):\n"
    (green "forced") (yellow "selected") ;
  all_experiments conf.C.persist_dir |>
  List.iter (fun (name, e) ->
    Printf.printf "  %s:\n" name ;
    for i = 0 to Array.length e.variants - 1 do
      let v = e.variants.(i) in
      Printf.printf "    %s (%s%%):\n%s\n"
        ((if e.variant = i then
           if e.forced then green else yellow
         else identity) v.Variant.name)
        (nice_string_of_float (100. *. v.Variant.share))
        (reindent "      " v.Variant.descr)
    done ;
    Printf.printf "\n")

let stats conf () =
  init_logger conf.C.log_level ;
  (* Initialize all metrics so that they register to Binocle: *)
  List.iter (fun initer ->
    initer conf.C.persist_dir
  ) !RamenWorkerStats.all_saved_metrics ;
  Binocle.display_console ()
