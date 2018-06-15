open Batteries
open RamenLog
open RamenHelpers
module C = RamenConf
module F = C.Func
module P = C.Program

(* Dequeue command *)

let dequeue conf file n () =
  logger := make_logger conf.C.debug ;
  if file = "" then invalid_arg "dequeue" ;
  let open RingBuf in
  let rb = load file in
  let rec dequeue_loop n =
    if n > 0 then (
      (* TODO: same automatic retry-er as in CodeGenLib_IO *)
      let bytes = dequeue rb in
      Printf.printf "dequeued %d bytes\n%!" (Bytes.length bytes) ;
      dequeue_loop (n - 1)
    )
  in
  dequeue_loop n

(* Summary command *)

let summary conf files () =
  logger := make_logger conf.C.debug ;
  List.iter (fun file ->
    let open RingBuf in
    let rb = load file in
    let s = stats rb in
    Printf.printf "%s:\n\
                   Flags:%s\n\
                   seq range: %d..%d (%d)\n\
                   time range: %f..%f (%.1fs)\n\
                   %d/%d words used (%3.1f%%)\n\
                   mmapped bytes: %d\n\
                   producers range: %d..%d\n\
                   consumers range: %d..%d\n"
      file (if s.wrap then " Wrap" else "")
      s.first_seq (s.first_seq + s.alloc_count - 1) s.alloc_count
      s.t_min s.t_max (s.t_max -. s.t_min)
      s.alloced_words s.capacity
      (float_of_int s.alloced_words *. 100. /. (float_of_int s.capacity))
      s.mem_size s.prod_tail s.prod_head s.cons_tail s.cons_head ;
    unload rb
  ) files

(* Repair Command *)

let repair conf files () =
  logger := make_logger conf.C.debug ;
  List.iter (fun file ->
    let open RingBuf in
    let rb = load file in
    if repair rb then
      !logger.warning "Ringbuf was damaged" ;
    unload rb
  ) files

(* List all ringbuffers in use with some stats: *)

type func_status =
  | Running of F.t
  | NotRunning of string * string

let links conf no_abbrev with_header sort_col top prefix () =
  logger := make_logger conf.C.debug ;
  (* Memoizer to avoid reading the out_ref several times: *)
  let get_out_refs = lwt_memoize RamenOutRef.read in
  let get_stats = memoize (fun fname ->
    match RingBuf.load fname with
    | exception Failure _ -> None
    | rb ->
        let s = RingBuf.stats rb in
        RingBuf.unload rb ;
        Some s) in
  let fq_name = function
    | NotRunning (pn, fn) -> pn ^"/"^ fn
    | Running func -> F.fq_name func in
  let head =
    [| "parent" ; "child" ; "out_ref" ; "spec" ; "ringbuf" ;
       "fill ratio" ; "next seqs" |] in
  let line_of_link i p c =
    let parent = fq_name p and child = fq_name c in
    if String.starts_with parent prefix ||
       String.starts_with child prefix
    then
      let ringbuf, fill_ratio, next_seqs =
        match c with
        | NotRunning (pn, fn) -> "", 0., ""
        | Running c ->
            let ringbuf =
              if c.F.merge_inputs then
                C.in_ringbuf_name_merging conf c i
              else
                C.in_ringbuf_name_single conf c in
            let fill_ratio, next_seqs =
              match get_stats ringbuf with
              | None -> 0., ""
              | Some s ->
                  float_of_int s.alloced_words /. float_of_int s.capacity,
                  string_of_int s.cons_tail ^".."^ string_of_int s.cons_head in
            ringbuf, fill_ratio, next_seqs
      in
      let%lwt out_ref, spec =
        match p with
        | NotRunning (pn, fn) -> Lwt.return ("", "")
        | Running p ->
            let out_ref = C.out_ringbuf_names_ref conf p in
            let%lwt outs = get_out_refs out_ref in
            let spec =
              match Map.find ringbuf outs with
              | exception Not_found -> ""
              | spec -> RamenOutRef.string_of_file_spec spec in
            Lwt.return (out_ref, spec)
      in
      let ap s = if no_abbrev then s else abbrev_path s in
      let parent = ap parent and child = ap child in
      let ap s = if no_abbrev then s else
                   abbrev_path ~known_prefix:conf.persist_dir s in
      let out_ref = ap out_ref and ringbuf = ap ringbuf in
      Some TermTable.[|
        ValStr parent ; ValStr child ; ValStr out_ref ; ValStr spec ;
        ValStr ringbuf ; ValFlt fill_ratio ;
        ValStr next_seqs |] |> Lwt.return
    else
      Lwt.return_none
  in
  (* We first collect all links supposed to exist according to
   * parent/children relationships: *)
  let links =
    Lwt_main.run (
      C.with_rlock conf (fun programs ->
        (* Get rid of Lwt in AdvLock and RamenOutRef! *)
        Hashtbl.enum programs |> List.of_enum |>
        Lwt_list.fold_left_s (fun links (program_name, get_rc) ->
          let bin, prog = get_rc () in
          Lwt_list.fold_left_s (fun links func ->
            let%lwt _, links =
              Lwt_list.fold_left_s (fun (i, links) (par_prog, par_func) ->
                let par_prog = par_prog |? func.F.exp_program_name in
                let parent =
                  match Hashtbl.find programs par_prog with
                  | exception Not_found ->
                      NotRunning (par_prog, par_func)
                  | get_rc ->
                      let _bin, pprog = get_rc () in
                      (match List.find (fun f ->
                               f.F.name = par_func
                             ) pprog.P.funcs with
                      | exception Not_found ->
                          NotRunning (par_prog, par_func)
                      | pfunc -> Running pfunc) in
                match%lwt line_of_link i parent (Running func) with
                | Some line -> Lwt.return (i + 1, line :: links)
                | None -> Lwt.return (i + 1, links)
              ) (0, links) func.parents in
            Lwt.return links
          ) links prog.P.funcs
        ) [])) in
  TermTable.print_table ~sort_col ~with_header ?top head links
