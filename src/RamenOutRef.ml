(* OutRef files are the files describing where a func should send its
 * output. It's basically a list of ringbuf files, with a bitmask of fields
 * that must be written, and an optional timestamp  after which the export
 * should stop (esp. useful for non-ring buffers).
 * Ring and Non-ring buffers are distinguished with their filename
 * extensions, which are either ".r" (ring) or ".b" (buffer).
 * This has the nice consequence that you cannot have a single file name
 * repurposed into a different kind of storage.
 *
 * In case of non-ring buffers, on completion the file is renamed with the
 * min and max sequence numbers and timestamps (if known), and a new one is
 * created.
 *
 * We want to lock those files, both internally (same process) and externally
 * (other processes), although we are fine with advisory locking.
 * Unfortunately lockf will only lock other processes out so we have to combine
 * RWLocks and lockf.
 *)
open Batteries
open Stdint

open RamenHelpersNoLog
open RamenLog
open RamenConsts
open RamenSync
module C = RamenConf
module CltCmd = Sync_client_cmd.DessserGen
module Channel = RamenChannel
module Files = RamenFiles
module N = RamenName
module OD = Output_specs.DessserGen
module OWD = Output_specs_wire.DessserGen
module VOS = Value.OutputSpecs
module ZMQClient = RamenSyncZMQClient

(* [combine_specs s1 s2] returns the result of replacing [s1] with [s2].
 * Basically, new fields prevail and we merge channels, keeping the longer
 * timeout, and the most recent non-zero reader pid: *)
let combine_specs s1 s2 =
  VOS.{ s2 with channels =
    hashtbl_merge s1.VOS.channels s2.VOS.channels
      (fun _ spec1 spec2 ->
        match spec1, spec2 with
        | (Some _ as s), None | None, (Some _ as s) -> s
        | Some (t1, s1, p1), Some (t2, s2, p2) ->
            let timeout =
              if t1 = 0. || t2 = 0. then 0. (* no timeout wins *)
              else Float.max t1 t2
            and num_sources =
              (* endless channels win! *)
              if s1 < Int16.zero || s2 < Int16.zero then Int16.(neg one)
              else max s1 s2
            and pid =
              (* latest set pid wins *)
              if p2 = Uint32.zero then p1 else p2
            in
            Some (timeout, num_sources, pid)
        | _ -> assert false) }

let timed_out ~now t = t > 0. && now > t

let topics = "sites/*/workers/*/outputs"

let output_specs_key site fq =
  Key.(PerSite (site, PerWorker (fq, OutputSpecs)))

let write ?while_ session k c =
  let v = Value.OutputSpecs c in
  ZMQClient.send_cmd ?while_ session (CltCmd.SetKey (k, v))

(* Timeout old chans and remove stale versions of files: *)
let filter_out_ref =
  let some_filtered = ref false in
  let file_exists ft fname =
    match ft with
    | OWD.RingBuf ->
        (* Ringbufs are never created by the workers but by supervisor or
         * archivist (workers will rotate non-wrapping ringbuffers but even then
         * the original has to pre-exist) *)
        Files.exists fname
    | Orc _ ->
        (* Will be created as needed (including if the file name points at an
         * obsolete ringbuf version :( *)
        true in
  let can_be_written_to ft fname =
    match ft with
    | OWD.RingBuf ->
        Files.check ~has_perms:0o400 fname = Files.FileOk
    | Orc _ ->
        true in
  let filter ?(warn=true) cause f fname =
    let r = f fname in
    if not r then
      (if warn then !logger.warning else !logger.debug)
        "OutRef: Ignoring %s ringbuffer %a"
        cause N.path_print fname ;
    r in
  fun ~now h ->
    let filter_chans rcpt chans =
      Hashtbl.filter (fun (t, _, _) ->
        if timed_out ~now t then (
          !logger.warning "OutRef: Timing out recipient %a"
            VOS.recipient_print rcpt ;
          some_filtered := true ;
          false
        ) else true
      ) chans in
    let h =
      Hashtbl.filteri (fun rcpt spec ->
        let valid_rcpt =
          match rcpt with
          | OWD.DirectFile fname ->
              (* It is OK if a ringbuffer disappear and it happens regularly to
               * supervisor when tearing down a replay, therefore no warning in
               * that case: *)
              filter "non-existent" ~warn:false
                (file_exists spec.OD.file_type) fname &&
              filter "non-writable" (can_be_written_to spec.file_type) fname
          | IndirectFile _
          | SyncKey _ ->
              true in
        if valid_rcpt then
          let chans = filter_chans rcpt spec.OD.channels in
          spec.channels <- chans ;
          Hashtbl.length chans > 0
        else (
          some_filtered := true ;
          false
        )
      ) h in
    h,
    !some_filtered

let read session site fq ~now =
  let k = output_specs_key site fq in
  match (Client.find session.ZMQClient.clt k).value with
  | exception Not_found ->
      Hashtbl.create 0,
      false
  | Value.OutputSpecs s ->
      filter_out_ref ~now s
  | v ->
      if not Value.(equal dummy v) then
        err_sync_type k v "an output specifications" ;
      Hashtbl.create 0,
      false

let read_live session site fq ~now =
  let h, _ = read session site fq ~now in
  Hashtbl.filter_inplace (fun s ->
    Hashtbl.filteri_inplace (fun c _ ->
      c = Channel.live
    ) s.OD.channels ;
    not (Hashtbl.is_empty s.channels)
  ) h ;
  h

let with_outref_locked ?while_ session site fq f =
  let k = output_specs_key site fq in
  let res = ref None in
  let exn = ref None in
  ZMQClient.send_cmd ?while_ session (CltCmd.LockOrCreateKey (k, 3.0, true))
    ~on_done:(fun () ->
      (try
        res := Some (f ())
      with e ->
        exn := Some e) ;
      ZMQClient.send_cmd ?while_ session (CltCmd.UnlockKey k))
    ~on_ko:(fun () ->
      exn := Some (Failure (Printf.sprintf2 "Cannot lock %a" Key.print k))) ;
  (* Pull result and exception from the callbacks:
   * (FIXME: ZMQClient API) *)
  ZMQClient.process_until ~while_:(fun () ->
    Option.map_default (fun f -> f ()) true while_ &&
    !res = None && !exn = None) session ;
  Option.may raise !exn ;
  (* If there is no [exn] and no [res], then it means [process_until] quit
   * because of [while_]. Raise Exit in that case. *)
  match !res with Some r -> r | None -> raise Exit

let add ~now ?while_ session site fq out_fname
        ?(file_type=OWD.RingBuf) ?(timeout_date=0.)
        ?(num_sources=Int16.(neg one)) ?(pid=Uint32.zero)
        ?(channel=Channel.live) ?(filters=[||]) fieldmask =
  let channels = Hashtbl.create 1 in
  Hashtbl.add channels channel (timeout_date, num_sources, pid) ;
  let file_spec = OD.{ file_type ; fieldmask ; filters ; channels } in
  with_outref_locked ?while_ session site fq (fun () ->
    let h, some_filtered = read session site fq ~now in
    let do_write () =
      let k = output_specs_key site fq in
      write ?while_ session k h in
    let rewrite file_spec =
      Hashtbl.replace h out_fname file_spec ;
      let k = output_specs_key site fq in
      !logger.debug "OutRef: Adding %a to %a with fieldmask %a"
        VOS.recipient_print out_fname
        Key.print k
        RamenFieldMask.print fieldmask ;
      do_write ()
    in
    match Hashtbl.find h out_fname with
    | exception Not_found ->
        rewrite file_spec
    | prev_spec ->
        let file_spec = combine_specs prev_spec file_spec in
        if VOS.file_spec_eq prev_spec file_spec then (
          !logger.debug "OutRef: same entry: %a vs %a"
            VOS.file_spec_print prev_spec
            VOS.file_spec_print file_spec ;
          if some_filtered then do_write ()
        ) else
          rewrite file_spec)

let remove ~now ?while_ session site fq out_fname ?(pid=Uint32.zero) chan =
  with_outref_locked ?while_ session site fq (fun () ->
    let h, some_filtered = read session site fq ~now in
    let k = output_specs_key site fq in
    match Hashtbl.find h out_fname with
    | exception Not_found ->
        if some_filtered then
          write ?while_ session k h
    | spec ->
        Hashtbl.modify_opt chan (function
          | None ->
              None
          | Some (_timeout, _count, current_pid) as prev ->
              if current_pid = Uint32.zero || current_pid = pid then
                None
              else
                prev (* Do not remove someone else's link! *)
        ) spec.channels ;
        if Hashtbl.is_empty spec.channels then
          Hashtbl.remove h out_fname ;
        write ?while_ session k h ;
        !logger.debug "OutRef: Removed %a from %a"
          VOS.recipient_print out_fname
          Key.print k)

(* Check that fname is listed in outbuf_ref_fname for any non-timed out
 * channel: *)
let mem session site fq out_fname ~now =
  let h, _ = read session site fq ~now in
  match Hashtbl.find h out_fname with
  | exception Not_found ->
      false
  | spec ->
      try
        Hashtbl.iter (fun _c (t, _, _) ->
          if not (timed_out ~now t) then raise Exit
        ) spec.channels ;
        false
      with Exit -> true

let remove_channel ~now ?while_ session site fq chan =
  with_outref_locked ?while_ session site fq (fun () ->
    let h, _ = read session site fq ~now in
    Hashtbl.filter_inplace (fun spec ->
      Hashtbl.remove spec.OD.channels chan ;
      not (Hashtbl.is_empty spec.channels)
    ) h ;
    let k = output_specs_key site fq in
    write ?while_ session k h ;
    !logger.debug "OutRef: Removed channel %a from %a"
      Channel.print chan
      Key.print k)

let check_spec_change rcpt old new_ =
  (* Or the rcpt should have changed: *)
  if new_.OD.file_type <> old.OD.file_type then
    Printf.sprintf2 "Output file %a changed file type \
                     from %s to %s while in use"
      VOS.recipient_print rcpt
      VOS.(string_of_file_type old.file_type)
      VOS.(string_of_file_type new_.file_type) |>
    failwith ;
  if new_.fieldmask <> old.fieldmask then
    Printf.sprintf2 "Output file %a changed field mask \
                     from %a to %a while in use"
      VOS.recipient_print rcpt
      RamenFieldMask.print old.fieldmask
      RamenFieldMask.print new_.fieldmask |>
    failwith
