(* Temporary service that upload in the configuration the content of the
 * configuration files. Will disappear as soon as every file is replaced
 * by the synchronized config tree. *)
open Batteries
open RamenHelpers
open RamenLog
open RamenSync
open RamenConsts
module Archivist = RamenArchivist
module Files = RamenFiles
module Processes = RamenProcesses
module FuncGraph = RamenFuncGraph
module ZMQClient = RamenSyncZMQClient
module Client = ZMQClient.Client
module CltMsg = Client.CltMsg
module SrvMsg = Client.SrvMsg
module User = RamenSync.User
module Capa = RamenSync.Capacity
module C = RamenConf
module RC = C.Running
module FS = C.FuncStats
module F = C.Func
module P = C.Program
module T = RamenTypes
module O = RamenOperation
module Services = RamenServices

let while_ () = !Processes.quit = None

(* Try to lock all the keys we care about. If a lock fail, unlock everything.
 * Otherwise call the continuation [k].
 * Typically, [k] is then supposed to update and unlock. *)
let lock_keys clt zock f k =
  ZMQClient.lock_matching clt zock ~while_ f k

(* Helper function that takes a key filter and a new set of values, and
 * replaces all keys matching the filter with the new set of values. *)
let replace_keys clt zock f h =
  (* Start by deleting the extraneous keys: *)
  Client.H.enum clt.Client.h //
  (fun (k, _) -> f k && not (Client.H.mem h k)) |>
  Enum.iter (fun (k, _) ->
    ZMQClient.send_cmd zock ~while_ (CltMsg.DelKey k)) ;
  (* Now add/update the keys from [h]: *)
  Client.H.iter (fun k (v, r, w) ->
    (* FIXME: add r and w in NewKey *)
    Option.may (fun v ->
      if Client.H.mem clt.Client.h k then
        ZMQClient.send_cmd zock ~while_ (CltMsg.UpdKey (k, v))
      else
        ZMQClient.send_cmd zock ~while_ (CltMsg.NewKey (k, v)) ;
      ZMQClient.send_cmd zock ~while_ (CltMsg.UnlockKey k)
    ) v
  ) h

(* One module per data source so that it's easier to track those *)

module TargetConfig =
struct
  let update conf _clt zock =
    let k = Key.TargetConfig in
    let unlock () =
      ZMQClient.send_cmd zock ~while_ (CltMsg.UnlockKey k) in
    ZMQClient.send_cmd zock ~while_ (CltMsg.LockKey k) ~on_ok:(fun () ->
      let programs = RC.with_rlock conf identity in
      let rcs =
        Hashtbl.fold (fun pname (rce, _get_rc) rcs ->
          let params = alist_of_hashtbl rce.RC.params in
          let entry =
            RamenSync.Value.{
              enabled = rce.RC.status = RC.MustRun ;
              debug = rce.debug ;
              report_period = rce.report_period ;
              params ;
              src_file = rce.RC.src_file ;
              on_site = Globs.decompile rce.RC.on_site ;
              automatic = rce.RC.automatic } in
          (pname, entry) :: rcs
        ) programs [] in
      let v = Value.TargetConfig rcs in
      ZMQClient.send_cmd zock ~while_ (CltMsg.SetKey (k, v))
                         ~on_ok:unlock ~on_ko:unlock)
end

(* FIXME: Archivist should write the stats in there directly *)
module GraphInfo =
struct
  let update_from_graph conf clt zock graph =
    !logger.debug "Update per-site configuration with graph %a"
      FuncGraph.print graph ;
    let h = Client.H.create 50 in
    let upd k v =
      let r = Capa.anybody and w = Capa.nobody in
      Client.H.add h k (Some v, r, w) in
    Hashtbl.iter (fun site _per_site_h ->
      let is_master = Set.mem site conf.C.masters in
      upd (PerSite (site, IsMaster)) (Value.Bool is_master) ;
      (* TODO: PerService *)
      let stats = Archivist.load_stats ~site conf in
      Hashtbl.iter (fun fq stats ->
        upd (PerSite (site, PerWorker (fq, StartupTime)))
            (Value.Float stats.FS.startup_time) ;
        Option.may (fun min_etime ->
          upd (PerSite (site, PerWorker (fq, MinETime)))
              (Value.Float min_etime) ;
        ) stats.FS.min_etime ;
        Option.may (fun max_etime ->
          upd (PerSite (site, PerWorker (fq, MaxETime)))
              (Value.Float max_etime) ;
        ) stats.FS.max_etime ;
        upd (PerSite (site, PerWorker (fq, TotTuples)))
            (Value.Int stats.FS.tuples) ;
        upd (PerSite (site, PerWorker (fq, TotBytes)))
            (Value.Int stats.FS.bytes) ;
        upd (PerSite (site, PerWorker (fq, TotCpu)))
            (Value.Float stats.FS.cpu) ;
        upd (PerSite (site, PerWorker (fq, MaxRam)))
            (Value.Int stats.FS.ram) ;
        upd (PerSite (site, PerWorker (fq, ArchivedTimes)))
            (Value.TimeRange stats.FS.archives) ;
        upd (PerSite (site, PerWorker (fq, NumArcFiles)))
            (Value.Int (Int64.of_int stats.FS.num_arc_files)) ;
        upd (PerSite (site, PerWorker (fq, NumArcBytes)))
            (Value.Int stats.FS.num_arc_bytes)
      ) stats
    ) graph.FuncGraph.h ;
    let f = function
      | Key.PerSite
          (_, (IsMaster |
              (PerWorker
                (_, (StartupTime | MinETime |
                 MaxETime | TotTuples | TotBytes | TotCpu | MaxRam |
                 ArchivedTimes))))) -> true
      | _ -> false in
    lock_keys clt zock f (fun () ->
      replace_keys clt zock f h (* Also unlock *))

  let update conf clt zock =
    match FuncGraph.make conf with
    | exception e ->
        print_exception ~what:"update PerSite" e ;
        !logger.info "skipping this step..."
    | graph ->
        update_from_graph conf clt zock graph
end

(* FIXME: User conf file should be stored in the conftree to begin with,
 * then Archivist and GC should also write directly in there: *)
module Storage =
struct
  let last_read_user_conf = ref 0.

  let update conf clt zock =
    let fname = Archivist.user_conf_file conf in
    let t = Files.mtime_def 0. fname in
    if t > !last_read_user_conf then (
      !logger.info "Updating storage configuration from %a"
        N.path_print fname ;
      let f = function
        | Key.Storage (RetentionsOverride _ | TotalSize | RecallCost) -> true
        | _ -> false in
      lock_keys clt zock f (fun () ->
        let h = Client.H.create 20 in
        let upd k v =
          Client.H.add h k (Some v, Capa.Anybody, Capa.Admin) in
        last_read_user_conf := t ;
        let user_conf = Archivist.get_user_conf conf in
        upd (Storage TotalSize)
            Value.(Int (Int64.of_int user_conf.Archivist.size_limit)) ;
        upd (Storage RecallCost)
            Value.(Float user_conf.recall_cost) ;
        Hashtbl.iter (fun glob retention ->
          upd (Storage (RetentionsOverride glob))
              Value.(Retention retention)
        ) user_conf.retentions ;
        replace_keys clt zock f h (* And unlock *))
    )
end

(* FIXME: RmAdmin graph info is supposed to come from the choreographer output
 * and the TargetConfig. We keep this temporarily to avoid breaking everything
 * at once: *)
module SrcInfo =
struct
  let update conf clt zock =
    let f = function
      | Key.PerProgram (_, (SourceModTime | SourceFile)) -> true
      | _ -> false in
    lock_keys clt zock f (fun () ->
      let h = Client.H.create 20 in
      let upd k v =
        let r = Capa.anybody and w = Capa.nobody in
        Client.H.add h k (v, r, w) in
      RC.with_rlock conf identity |>
      Hashtbl.iter (fun pname (rce, get_rc) ->
        (match Files.mtime rce.RC.src_file with
        | exception Unix.(Unix_error (ENOENT, _, _)) ->
            () (* No file -> No source info *)
        | mtime ->
            let km = Key.PerProgram (pname, SourceModTime)
            and ks = Key.PerProgram (pname, SourceFile) in
            let do_upd () =
              upd km (Some Value.(Float mtime)) ;
              upd ks (Some Value.(String (rce.RC.src_file :> string)))
            and keep k =
              upd k None in
            (match Client.H.find clt.Client.h km with
            | exception Not_found -> do_upd ()
            | { v = Value.(Float prev_mtime) ; _ } ->
                if mtime > prev_mtime then do_upd ()
                else (keep km ; keep ks)
            | hv ->
                !logger.error
                  "Wrong type for source modification time (%a), deleting"
                  Value.print hv.v)) ;
        (match get_rc () with
        | exception _ -> ()
        | p ->
            Option.may (fun condition ->
              upd (Key.PerProgram (pname, RunCondition))
                  (Some Value.(String condition))
            ) p.P.condition ;
            List.iter (fun f ->
              let upd fk v =
                upd (Key.PerProgram (pname, PerFunction (f.F.name, fk)))
                    (Some v) in
              Option.may (fun retention ->
                upd Key.Retention Value.(Retention retention)
              ) f.F.retention ;
              upd Key.Doc Value.(String f.F.doc) ;
              upd Key.IsLazy Value.(Bool f.F.is_lazy) ;
              let op = f.F.operation in
              upd Key.Operation Value.(String
                (IO.to_string (O.print true) op)) ;
              List.iteri (fun i (field : N.field) ->
                upd Key.(Factors i) Value.(String (field :> string))
              ) (O.factors_of_operation op) ;
              upd Key.InType Value.(RamenType
                (RamenFieldMaskLib.record_of_in_type f.F.in_type)) ;
              upd Key.OutType Value.(RamenType
                (O.out_record_of_operation ~with_private:false op)) ;
              upd Key.Signature Value.(String f.F.signature) ;
              upd Key.MergeInputs Value.(Bool f.F.merge_inputs)
            ) p.funcs)) ;
      replace_keys clt zock f h (* and unlock *))
end

(* FIXME: Archivist is supposed to write directly in the conf tree *)
module AllocInfo =
struct
  let last_read_allocs = ref 0.

  let update conf clt zock =
    let fname = Archivist.allocs_file conf in
    let t = Files.mtime_def 0. fname in
    if t > !last_read_allocs then (
      !logger.info "Updating storage allocations from %a"
        N.path_print fname ;
      last_read_allocs := t ;
      let f = function
        | Key.PerSite (_, PerWorker (_, AllocedArcBytes)) -> true
        | _ -> false in
      lock_keys clt zock f (fun () ->
        let allocs = Archivist.load_allocs conf in
        let h = Client.H.create 20 in
        let upd k v =
          Client.H.add h k (Some v, Capa.Anybody, Capa.Admin) in
        Hashtbl.iter (fun (site, fq) size ->
          upd (PerSite (site, PerWorker (fq, AllocedArcBytes)))
              Value.(Int (Int64.of_int size))
        ) allocs ;
        replace_keys clt zock f h (* and unlock *))
    )
end


(*
 * The service: update conftree from files in a loop.
 *)

let sync_step conf clt zock =
  log_and_ignore_exceptions ~what:"update TargetConfig"
    (TargetConfig.update conf clt) zock ;
  log_and_ignore_exceptions ~what:"update GraphInfo"
    (GraphInfo.update conf clt) zock ;
  log_and_ignore_exceptions ~what:"update Storage"
    (Storage.update conf clt) zock ;
  log_and_ignore_exceptions ~what:"update SrcInfo"
    (SrcInfo.update conf clt) zock ;
  log_and_ignore_exceptions ~what:"update AllocInfo"
    (AllocInfo.update conf clt) zock

let service_loop conf upd_period zock clt =
  let last_upd = ref 0. in
  Processes.until_quit (fun () ->
    let num_msg = ZMQClient.process_in zock clt in
    !logger.debug "Received %d messages" num_msg ;
    let now = Unix.gettimeofday () in
    if now >= !last_upd +. upd_period &&
       (upd_period > 0. || !last_upd = 0.)
    then (
      last_upd := now ;
      sync_step conf clt zock ;
    ) ;
    if upd_period <= 0. && ZMQClient.pending_callbacks () = 0 then
      raise Exit ;
    true
  )

let start conf loop =
  (* Given filesyncer carry on with updates only when the lock have succeeded,
   * no other keys than the error logs are actually needed: *)
  let topics = [] in
  ZMQClient.start ~recvtimeo:1. ~while_ conf.C.sync_url conf.C.login ~topics
    (service_loop conf loop)
