(* The configuration that's managed by this module includes:
 *
 * - the Running Configuration (RC), which is the set of all programs that are
 *   supposed to run;
 * - the per worker Stats (generated by the archivist with option --stats)
 *   and used for allocating storage space;
 * - the per worker storage allocations (also generated by the archivist with
 *   option --allocs)
 * - the transient ongoing replays.
 *
 * All these bits of configuration have in common that they must be available
 * at every sites at least read-only (also write where the corresponding
 * commands are issued).
 *)
open Batteries
open RamenLog
open RamenHelpers
open RamenConsts
module O = RamenOperation
module N = RamenName
module E = RamenExpr
module T = RamenTypes
module OutRef = RamenOutRef
module Files = RamenFiles
module Retention = RamenRetention
module TimeRange = RamenTimeRange
module Versions = RamenVersions

(*
 * Ramen internal configuration record
 *
 * Just a handy bag of global parameters.
 *)

type conf =
  { log_level : log_level ;
    persist_dir : N.path ;
    test : bool ; (* true within `ramen test` *)
    keep_temp_files : bool ;
    reuse_prev_files : bool ;
    initial_export_duration : float ;
    site : N.site (* this site name *) ;
    masters : N.site Set.t ;
    bundle_dir : N.path ;
    sync_url : string ;
    username : string ;
    (* The keys not the file names: *)
    srv_pub_key : string ;
    clt_pub_key : string ;
    clt_priv_key : string }

type identity_file =
  { username : string ;
    server_public_key : string ;
    client_public_key : string ;
    client_private_key : string }
  [@@ppp PPP_JSON]

let make_conf
      ?(debug=false) ?(quiet=false)
      ?(keep_temp_files=false) ?(reuse_prev_files=false)
      ?(forced_variants=[])
      ?(initial_export_duration=Default.initial_export_duration)
      ~site ?(test=false)
      ?(bundle_dir=RamenCompilConfig.default_bundle_dir)
      ?(masters=Set.empty)
      ?(sync_url="")
      ?(username="")
      ?(srv_pub_key="")
      ?(clt_pub_key="")
      ?(clt_priv_key="")
      ?(identity=N.path "")
      persist_dir =
  if debug && quiet then
    failwith "Options --debug and --quiet are incompatible." ;
  let log_level =
    if debug then Debug else if quiet then Quiet else Normal in
  let persist_dir = N.simplified_path persist_dir in
  (* Read values from the file and et unset parameters with those.
   * In effect, the CLI parameters overwrite the file content. *)
  let username, srv_pub_key, clt_pub_key, clt_priv_key =
    if N.is_empty identity || not (Files.exists identity) then
      username, srv_pub_key, clt_pub_key, clt_priv_key
    else
      let what = Printf.sprintf2 "Reading identity file %a"
                   N.path_print identity in
      log_exceptions ~what (fun () ->
        let id = Files.ppp_of_file identity_file_ppp_json identity in
        (if username <> "" then username else id.username),
        (if srv_pub_key <> "" then srv_pub_key else id.server_public_key),
        (if clt_pub_key <> "" then clt_pub_key else id.client_public_key),
        (if clt_priv_key <> "" then clt_priv_key else id.client_private_key))
  in
  RamenExperiments.set_variants persist_dir forced_variants ;
  { log_level ; persist_dir ; keep_temp_files ; reuse_prev_files ;
    initial_export_duration ; site ; test ; bundle_dir ; masters ;
    sync_url ; username ; srv_pub_key ; clt_pub_key ; clt_priv_key }

(*
 * Common comprehensive representation of functions and programs
 *
 * This configuration (or the simpler, more compact and less redundant
 * serialized variant) is embedded directly in the workers binary.
 *)

module Func =
struct
  type parent =
    O.site_identifier * N.rel_program option * N.func
    [@@ppp PPP_OCaml]

  type t =
    { program_name : N.program ;
      name : N.func ;
      (* A function which history we might want to query in the future
       * so make sure it is either stored or can be computed again from
       * ancestor stored history: *)
      retention : Retention.t option ;
      doc : string ;
      (* A lazy function runs only if it is used: has a children that is
       * itself used, emits notifications or export its data somehow. *)
      is_lazy : bool ;
      mutable operation : O.t ;
      in_type : RamenFieldMaskLib.in_type ;
      (* The signature identifies the code but not the actual parameters.
       * Those signatures are used to distinguish sets of ringbufs
       * or any other files where tuples are stored, so that those files
       * change when the code change, without a need to also change the
       * name of the operation. *)
      mutable signature : string ;
      parents : parent list ;
      merge_inputs : bool }

  module Serialized = struct
    type t = (* A version of the above without redundancy: *)
      { name : N.func ;
        retention : Retention.t option ;
        is_lazy : bool ;
        doc : string ;
        operation : O.t ;
        (* out type, factors...? store them in addition for the client, or use
         * the OCaml helper lib? Or have additional keys? Those keys are:
         * Retention, Doc, IsLazy, Factors, InType, OutType, Signature, MergeInputs.
         * Or replace the compiled info at reception by another object in RmAdmin?
         * For now just add the two that are important for RmAdmin: out_type and
         * factors. FIXME.
         * Note that fields are there ordered in user order, as expected. *)
        out_record : T.t ;
        factors : N.field list ;
        (* FIXME: why storing the signature? *)
        signature : string }
      [@@ppp PPP_OCaml]
  end

  let serialized (t : t) =
    Serialized.{
      name = t.name ;
      retention = t.retention ;
      is_lazy = t.is_lazy ;
      doc = t.doc ;
      operation = t.operation ;
      out_record = O.out_record_of_operation ~with_private:false t.operation ;
      factors = O.factors_of_operation t.operation ;
      signature = t.signature }

  let unserialized program_name (t : Serialized.t) =
    { program_name ;
      name = t.name ;
      retention = t.retention ;
      is_lazy = t.is_lazy ;
      doc = t.doc ;
      operation = t.operation ;
      signature = t.signature ;
      in_type = RamenFieldMaskLib.in_type_of_operation t.operation ;
      parents = O.parents_of_operation t.operation ;
      merge_inputs = O.is_merging t.operation }

  (* TODO: takes a func instead of child_prog? *)
  let program_of_parent_prog child_prog = function
    | None -> child_prog
    | Some rel_prog ->
        N.(program_of_rel_program child_prog rel_prog)

  let print_parent oc (parent : parent) =
    match parent with
    | site, None, f ->
        Printf.fprintf oc "%a%s"
          O.print_site_identifier site
          (f :> string)
    | site, Some p, f ->
        Printf.fprintf oc "%a%s/%s"
          O.print_site_identifier site
          (p :> string) (f :> string)

  (* Only for debug or keys, not for paths! *)
  let fq_name f = N.fq_of_program f.program_name f.name

  let path f =
    N.path_cat
      [ N.path_of_program f.program_name ;
        N.path (f.name :> string) ]

  let signature func params =
    (* We'd like to be formatting independent so that operation text can be
     * reformatted without ramen recompiling it. For this it is not OK to
     * strip redundant white spaces as some of those might be part of literal
     * string values. So we print it, trusting the printer to be exhaustive.
     * This is not enough to print the expression with types, as those do not
     * contain relevant info such as field rank. We therefore print without
     * types and encode input/output types explicitly below.
     * Also, notice that the program-wide running condition does not alter
     * the function signature, and rightfully so, as a change in the running
     * condition does not imply we should disregard past data or consider the
     * function changed in any way. It's `ramen run` job to evaluate the
     * running condition independently. *)
    let op_str = IO.to_string (O.print false) func.operation
    and out_type =
      O.out_type_of_operation ~with_private:false func.operation in
    "OP="^ op_str ^
    ";IN="^ RamenFieldMaskLib.in_type_signature func.in_type ^
    ";OUT="^ RamenTuple.type_signature out_type ^
    (* Similarly to input type, also depends on the parameters type: *)
    ";PRM="^ RamenTuple.params_type_signature params |>
    N.md5

  let dump_io func =
    !logger.debug "func %S:\n\tinput type: %a\n\toutput type: %a"
      (func.name :> string)
      RamenFieldMaskLib.print_in_type func.in_type
      RamenTuple.print_typ
        (O.out_type_of_operation ~with_private:false func.operation)

  let make_fieldmask parent child =
    let out_typ =
      O.out_type_of_operation ~with_private:false parent.operation in
    RamenFieldMaskLib.fieldmask_of_operation ~out_typ child.operation
end

module Program =
struct
  type t =
    { default_params : RamenTuple.params ;
      condition : E.t ; (* for debug only *)
      funcs : Func.t list }

  module Serialized = struct
    type t =
      { default_params : RamenTuple.params [@ppp_default []] ;
        condition : E.t ; (* part of the program signature *)
        funcs : Func.Serialized.t list }
      [@@ppp PPP_OCaml]
  end

  let serialized (t : t) =
    Serialized.{
      default_params = t.default_params ;
      condition = t.condition ;
      funcs = List.map Func.serialized t.funcs }

  let unserialized program_name (t : Serialized.t) =
    { default_params = t.default_params ;
      condition = t.condition ;
      funcs = List.map (Func.unserialized program_name) t.funcs }

  let version_of_bin (fname : N.path) =
    let args = [| (fname :> string) ; WorkerCommands.print_version |] in
    Files.with_stdout_from_command
      ~expected_status:0 fname args Legacy.input_line

  let info_of_bin program_name (fname : N.path) =
    let args = [| (fname :> string) ; WorkerCommands.get_info |] in
    Files.with_stdout_from_command
      ~expected_status:0 fname args Legacy.input_value |>
    unserialized program_name

  let env_of_params_and_exps conf params =
    (* First the params: *)
    let env =
      Hashtbl.enum params /@
      (fun ((n : N.field), v) ->
        Printf.sprintf2 "%s%s=%a"
          param_envvar_prefix
          (n :> string)
          RamenTypes.print v) in
    (* Then the experiment variants: *)
    let exps =
      RamenExperiments.all_experiments conf.persist_dir |>
      List.map (fun (name, exp) ->
        exp_envvar_prefix ^ name ^"="
          ^ exp.RamenExperiments.variants.(exp.variant).name) |>
      List.enum in
    Enum.append env exps

  let wants_to_run conf (fname : N.path) params =
    let args = [| (fname :> string) ; WorkerCommands.wants_to_run |] in
    let env = env_of_params_and_exps conf params |> Array.of_enum in
    Files.with_stdout_from_command
      ~expected_status:0 ~env fname args Legacy.input_line |>
    bool_of_string

  let of_bin =
    let log errors_ok fmt =
      (if errors_ok then !logger.debug else !logger.error) fmt in
    (* Cache of path to date of last read and program *)
    let reread_data (program_name, fname) errors_ok : t =
      !logger.debug "Reading config from %a..." N.path_print fname ;
      match version_of_bin fname with
      | exception e ->
          let err = Printf.sprintf2 "Cannot get version from %a: %s"
                      N.path_print fname (Printexc.to_string e) in
          log errors_ok "%s" err ;
          failwith err
      | v when v <> RamenVersions.codegen ->
        let err = Printf.sprintf2
                    "Executable %a is for version %s (I'm version %s)"
                    N.path_print fname
                    v RamenVersions.codegen in
        log errors_ok "%s" err ;
        failwith err
      | _ ->
          (try info_of_bin program_name fname with e ->
             let err = Printf.sprintf2 "Cannot get info from %a: %s"
                         N.path_print fname
                         (Printexc.to_string e) in
             !logger.error "%s" err ;
             failwith err)
    and age_of_data (_, fname) errors_ok =
      try Files.mtime fname
      with e ->
        log errors_ok "Cannot get mtime of %a: %s"
          N.path_print fname
          (Printexc.to_string e) ;
        0.
    in
    let get_prog = cached2 "of_bin" reread_data age_of_data in
    fun ?(errors_ok=false) program_name params (fname : N.path) ->
      let p = get_prog (program_name, fname) errors_ok in
      (* Patch actual parameters (in a _new_ prog not the cached one!): *)
      { default_params = RamenTuple.overwrite_params p.default_params params ;
        funcs = List.map (fun f -> Func.{ f with program_name }) p.funcs ;
        condition = p.condition }

  let bin_of_program_name lib_path program_name =
    (* Use an extension so we can still use the plain program_name for a
     * directory holding subprograms. Not using "exe" as it remind me of
     * that operating system, but rather "x" as in the x bit: *)
    N.path_cat [ lib_path ;
                 Files.add_ext (N.path_of_program program_name) "x" ]
end


(*
 * Running Config: what programs must run where.
 *
 * Note: keyed by program name. Several distinct instances of the same binary
 * can easily be given different names using `ramen run --as` if that's needed.
 *)

module Running =
struct
  type entry =
    { (* Tells whether the entry must actually be started. Set to true
         at exit so that we do not loose information of previously run
         entries. *)
      mutable status : worker_status [@ppp_default MustRun] ;
      (* Should this worker be started in debug mode regardless of supervisor
       * mode? *)
      debug : bool [@ppp_default false] ;
      (* Stat report period: *)
      report_period : float [@ppp_default Default.report_period] ;
      (* Full path to the worker's binary: *)
      bin : N.path ;
      (* "Command line" for that worker: *)
      params : RamenParams.t [@ppp_default Hashtbl.create 0] ;
      (* Optionally, file from which this worker can be (re)build (see RamenMake).
       * When it is rebuild, relative parents are found using the program name that's
       * the key in the running config. *)
      src_file : N.path [@ppp_default N.path ""] ;
      (* Optionally, run this worker only on these sites: *)
      on_site : Globs.t [@ppp_default Globs.all] ;
      (* For nodes added automatically, that were not in the RC file proper *)
      automatic : bool [@ppp_default false] }
    [@@ppp PPP_OCaml]

  (* Killed programs are kept in the RC file unless --purged, so it's still
   * possible to get their stats etc. *)
  and worker_status = MustRun | Killed
    [@@ppp PPP_OCaml]

  (* The rc file keyed by program name: *)
  type running_config = (N.program, entry) Hashtbl.t
    [@@ppp PPP_OCaml]

  let match_localsite conf site_glob =
    Globs.matches site_glob (conf.site :> string)

  let find_func programs fq =
    let program_name, func_name = N.fq_parse fq in
    let rce, get_rc =
      Hashtbl.find programs program_name in
    let prog = get_rc () in
    rce, prog, List.find (fun f -> f.Func.name = func_name) prog.Program.funcs

  let find_func_or_fail programs fq =
    try find_func programs fq
    with Not_found ->
      Printf.sprintf2 "Unknown function %a"
        N.fq_print fq |>
      failwith
end

(*
 * Global per-func stats that are updated by the thread reading #notifs and
 * the one reading the RC, and also saved on disk while ramen is not running:
 *)

module FuncStats =
struct
  type t =
    { startup_time : float ; (* To distinguish from present run *)
      min_etime : float option [@ppp_default None] ;
      max_etime : float option [@ppp_default None] ;
      tuples : int64 [@ppp_default 0L] ;
      bytes : int64 [@ppp_default 0L] ;
      cpu : float (* Cumulated seconds *) [@ppp_default 0.] ;
      ram : int64 (* Max observed heap size *) [@ppp_default 0L] ;
      mutable parents : (N.site * N.fq) list ;
      (* Also gather available history per running workers, to speed up
       * establishing query plans: *)
      mutable archives : TimeRange.t [@ppp_default []] ;
      mutable num_arc_files : int [@ppp_default 0] ;
      mutable num_arc_bytes : int64 [@ppp_default 0L] ;
      (* We want to allocate disk space only to those workers that are running,
       * but also want to save stats about workers that's been running recently
       * enough and might resume: *)
      mutable is_running : bool [@ppp_default false] }
    [@@ppp PPP_OCaml]

  let make ~startup_time ~is_running =
    { startup_time ; is_running ; min_etime = None ; max_etime = None ;
      tuples = 0L ; bytes = 0L ; cpu = 0. ; ram = 0L ; parents = [] ;
      archives = TimeRange.empty ; num_arc_files = 0 ; num_arc_bytes = 0L }

  let archives_print oc =
    List.print (Tuple2.print Float.print Float.print) oc
end


(*
 * Replays
 *
 * Replays are temporary workers+paths used to recompute a given target
 * function output in a given time range.
 *
 * See RamenReplay for actual operations.
 *)

module Replays =
struct
  (* Like BatSet.t, but with a serializer: *)
  type 'a set = 'a Set.t
  let set_ppp_ocaml ppp =
    let open PPP in
    PPP_OCaml.list ppp >>: Set.(to_list, of_list)

  type site_fq = N.site * N.fq
    [@@ppp PPP_OCaml]

  let site_fq_print oc (site, fq) =
    Printf.fprintf oc "%a:%a"
      N.site_print site
      N.fq_print fq

  let link_print oc (psite_fq, site_fq) =
    Printf.fprintf oc "%a=>%a"
      site_fq_print psite_fq
      site_fq_print site_fq

  type entry =
    { channel : RamenChannel.t ;
      target : site_fq ;
      target_fieldmask : RamenFieldMask.fieldmask ;
      since : float ;
      until : float ;
      final_rb : N.path ;
      (* Sets turned into lists for easier deser in C++: *)
      sources : site_fq list ;
      (* We pave the whole way from all sources to the target for this
       * channel id, rather than letting the normal stream carry this
       * channel events, in order to avoid spamming unrelated nodes
       * (Cf. issue #640): *)
      links : (site_fq * site_fq) list ;
      timeout_date : float }
    [@@ppp PPP_OCaml]

  type replays = (RamenChannel.t, entry) Hashtbl.t
    [@@ppp PPP_OCaml]

  let file_name conf =
    N.path_cat [ conf.persist_dir ; N.path "replays" ;
                 N.path RamenVersions.replays ; N.path "replays" ]

  let load_locked =
    let ppp_of_fd = Files.ppp_of_fd ~default:"{}" replays_ppp_ocaml in
    fun fname fd ->
      let context = "Reading replays" in
      let now = Unix.gettimeofday () in
      fail_with_context context (fun () -> ppp_of_fd fname fd) |>
      Hashtbl.filter (fun replay -> replay.timeout_date > now)

  let load conf =
    let fname = file_name conf in
    RamenAdvLock.with_r_lock fname (load_locked fname)

  let save_locked =
    let ppp_to_fd = Files.ppp_to_fd ~pretty:true replays_ppp_ocaml in
    fun fd replays ->
      let context = "Saving replays" in
      fail_with_context context (fun () -> ppp_to_fd fd replays)

  let add conf replay =
    !logger.debug "Adding replay for channel %a"
      RamenChannel.print replay.channel ;
    let fname = file_name conf in
    RamenAdvLock.with_w_lock fname (fun fd ->
      let replays = load_locked fname fd in
      if Hashtbl.mem replays replay.channel then
        Printf.sprintf2 "Replay channel %a is already in use!"
          RamenChannel.print replay.channel |>
        failwith ;
      Hashtbl.add replays replay.channel replay ;
      save_locked fd replays)

  let remove conf channel =
    let fname = file_name conf in
    RamenAdvLock.with_w_lock fname (fun fd ->
      let replays = load_locked fname fd in
      Hashtbl.remove replays channel ;
      save_locked fd replays)
end

(*
 *  Various directory names:
 *)

let type_signature_hash = N.md5 % RamenTuple.type_signature

(* Each workers regularly snapshot its internal state in this file.
 * This data contains tuples and stateful function internal states, so
 * that it has to depend not only on worker_state version (which versions
 * the structure of the state structure itself), but also on codegen
 * version (which versions the language/state), the parameters signature,
 * and also the OCaml version itself since we use stdlib's Marshaller: *)
let worker_state conf func params_sign =
  N.path_cat
    [ conf.persist_dir ; N.path "workers/states" ;
      N.path RamenVersions.(worker_state ^"_"^ codegen) ;
      N.path Config.version ; Func.path func ;
      N.path func.signature ; N.path params_sign ;
      N.path "snapshot" ]

(* The "in" ring-buffers are used to store tuple received by an operation.
 * We want that file to be unique for a given operation name and to change
 * whenever the input type of this operation changes. On the other hand, we
 * would like to keep it in case of a change in code that does not change
 * the input type because data not yet read would still be valid. So we
 * name that file after the function full name and its input type
 * signature.
 * Then some operations have all parents write in a single ring-buffer
 * (called "all.r") and some (those performing a MERGE operation) have one
 * ring-buffer per parent (called after the number of the parent in the
 * FROM clause): *)

let in_ringbuf_name_base conf func =
  let sign = N.md5 (RamenFieldMaskLib.in_type_signature func.Func.in_type) in
  N.path_cat
    [ conf.persist_dir ; N.path "workers/ringbufs" ;
      N.path RamenVersions.ringbuf ; Func.path func ; N.path sign ]

let in_ringbuf_name_single conf func =
  N.path_cat [ in_ringbuf_name_base conf func ; N.path "all.r" ]

let in_ringbuf_name_merging conf func parent_index =
  N.path_cat [ in_ringbuf_name_base conf func ;
               N.path (string_of_int parent_index ^".r") ]

let in_ringbuf_names conf func =
  if func.Func.parents = [] then []
  else if func.Func.merge_inputs then
    List.mapi (fun i _ ->
      in_ringbuf_name_merging conf func i
    ) func.Func.parents
  else
    [ in_ringbuf_name_single conf func ]

(* Returns the name of func input ringbuf for the given parent (if func is
 * merging, each parent uses a distinct one) and the file_spec. *)
let input_ringbuf_fname conf parent child =
  (* In case of merge, ringbufs are numbered as the node parents: *)
  if child.Func.merge_inputs then
    match List.findi (fun _ (_, pprog, pname) ->
            let pprog_name =
              Func.program_of_parent_prog child.Func.program_name pprog in
            pprog_name = parent.Func.program_name && pname = parent.name
          ) child.parents with
    | exception Not_found ->
        !logger.error "Operation %S is not a child of %S"
          (child.name :> string)
          (parent.name :> string) ;
        invalid_arg "input_ringbuf_fname"
    | i, _ ->
        in_ringbuf_name_merging conf child i
  else in_ringbuf_name_single conf child

(* Operations can also be asked to output their full result (all the public
 * fields) in a non-wrapping file for later retrieval by the tail or
 * timeseries commands.
 * We want those files to be identified by the name of the operation and
 * the output type of the operation. *)
let archive_buf_name ~file_type conf func =
  let ext =
    match file_type with
    | OutRef.RingBuf -> "b"
    | OutRef.Orc _ -> "orc" in
  let sign =
    O.out_type_of_operation ~with_private:false func.Func.operation |>
    type_signature_hash in
  N.path_cat
    [ conf.persist_dir ; N.path "workers/ringbufs" ;
      N.path RamenVersions.ringbuf ; Func.path func ;
      N.path sign ; N.path ("archive."^ ext) ]

(* Every function with factors will have a file sequence storing possible
 * values encountered for that time range. This is so that we can quickly
 * do autocomplete for graphite metric names regardless of archiving. This
 * could also be used to narrow down the time range of a replays in presence
 * of filtering by a factor.
 * Those files are cleaned by the GC according to retention times only -
 * they are not taken into account for size computation, as they are
 * independent of archiving and are supposed to be small anyway.
 * This function merely returns the directory name where the factors possible
 * values are saved. Then, the factor field name (with '/' url-encoded) gives
 * the name of the directory containing a file per time slice (named
 * begin_end). *)
let factors_of_function conf func =
  let sign =
    O.out_type_of_operation ~with_private:false func.Func.operation |>
    type_signature_hash in
  N.path_cat
    [ conf.persist_dir ; N.path "workers/factors" ;
      N.path RamenVersions.factors ; N.path Config.version ;
      Func.path func ;
      (* extension for the GC. *)
      N.path (sign ^".factors") ]

(* Operations are told where to write their output (and which selection of
 * fields) by another file, the "out-ref" file, which is a kind of symbolic
 * link with several destinations (plus a format, plus an expiry date).
 * like the above archive file, the out_ref files must be identified by the
 * operation name and its output type: *)
let out_ringbuf_names_ref conf func =
  let sign =
    O.out_type_of_operation ~with_private:false func.Func.operation |>
    type_signature_hash in
  N.path_cat
    [ conf.persist_dir ; N.path "workers/out_ref" ;
      N.path RamenVersions.out_ref ; Func.path func ;
      N.path (sign ^"/out_ref") ]

(* Finally, operations have two additional output streams: one for
 * instrumentation statistics, and one for notifications. Both are
 * common to all running operations, low traffic, and archived. *)
let report_ringbuf conf =
  N.path_cat
    [ conf.persist_dir ; N.path "instrumentation_ringbuf" ;
      N.path (RamenVersions.instrumentation_tuple ^"_"^
              RamenVersions.ringbuf) ;
      N.path "ringbuf.r" ]

let notify_ringbuf conf =
  N.path_cat
    [ conf.persist_dir ; N.path "notify_ringbuf" ;
      N.path (RamenVersions.notify_tuple ^"_"^ RamenVersions.ringbuf) ;
      N.path "ringbuf.r" ]

(* This is not a ringbuffer but a mere snapshot of the alerter state: *)
let pending_notifications_file conf =
  N.path_cat
    [ conf.persist_dir ;
      N.path ("pending_notifications_" ^ RamenVersions.pending_notify ^"_"^
              RamenVersions.notify_tuple) ]

(* For custom API, where to store alerting thresholds: *)
let api_alerts_root conf =
  N.path_cat [ conf.persist_dir ; N.path "/api/set_alerts" ]

let test_literal_programs_root conf =
  N.path_cat [ conf.persist_dir ; N.path "tests" ]

(* Where are SMT files (used for type-checking) written temporarily *)
let smt_file src_file =
  Files.change_ext "smt2" src_file

let compserver_cache_file conf src_path ext =
  N.path_cat [ conf.persist_dir ; N.path "compserver/cache" ;
               N.path Versions.codegen ;
               N.path ((src_path : N.src_path :> string) ^"."^ ext) ]

let supervisor_cache_file conf fname ext =
  N.path_cat [ conf.persist_dir ; N.path "supervisor/cache" ;
               N.path Versions.codegen ; N.cat fname (N.path ("."^ ext)) ]

(* Location of server key files: *)
let default_srv_pub_key_file conf =
  N.path_cat [ conf.persist_dir ; N.path "confserver/public_key" ]

let default_srv_priv_key_file conf =
  N.path_cat [ conf.persist_dir ; N.path "confserver/private_key" ]

(* Create a temporary program name: *)
let make_transient_program () =
  let now = Unix.gettimeofday ()
  and pid = Unix.getpid ()
  and rnd = Random.int max_int_for_random in
  Legacy.Printf.sprintf "tmp/_%h_%d.%d" now rnd pid |>
  N.program
