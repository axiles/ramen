(* This module parses operations (and offer a few utilities related to
 * operations).
 *
 * An operation is the body of a function, ie. the actual operation that
 * workers will execute.
 *
 * The main operation is the `SELECT / GROUP BY` operation, but there are a
 * few others of lesser importance for data input and output.
 *
 * Operations are made of expressions, parsed in RamenExpr, and assembled
 * into programs (the compilation unit) in RamenProgram.
 *)
open Batteries
open RamenLang
open RamenHelpers
open RamenLog
open RamenConsts
module E = RamenExpr
module T = RamenTypes

(*$inject
  open TestHelpers
  open RamenLang
  open Stdint
*)

(* Represents an output field from the select clause
 * 'SELECT expr AS alias' *)
type selected_field =
  { expr : E.t ;
    alias : N.field ;
    doc : string ;
    (* FIXME: Have a variant and use it in RamenTimeseries as well. *)
    aggr : string option }
  [@@ppp PPP_OCaml]

let print_selected_field with_types oc f =
  let need_alias =
    match f.expr.text with
    | Stateless (SL0 (Path [ Name n ]))
      when f.alias = n -> false
    | Stateless (SL2 (Get, { text = Const (VString n) ; _ },
                           { text = Variable TupleIn ; _ }))
      when (f.alias :> string) = n -> false
    | _ -> true in
  if need_alias then (
    Printf.fprintf oc "%a AS %s"
      (E.print with_types) f.expr
      (f.alias :> string) ;
    if f.doc <> "" then Printf.fprintf oc " %S" f.doc
  ) else (
    E.print with_types oc f.expr ;
    if f.doc <> "" then Printf.fprintf oc " DOC %S" f.doc
  )

(* Represents what happens to a group after its value is output: *)
type flush_method =
  | Reset (* it can be deleted (tumbling windows) *)
  | Never (* or we may just keep the group as it is *)
  [@@ppp PPP_OCaml]

let print_flush_method oc = function
  | Reset ->
    Printf.fprintf oc "FLUSH"
  | Never ->
    Printf.fprintf oc "KEEP"
  [@@ppp PPP_OCaml]

(* Represents an input CSV format specifications: *)
type file_spec = { fname : E.t ; unlink : E.t }
  [@@ppp PPP_OCaml]
type csv_specs =
  { separator : string ; null : string ; fields : RamenTuple.typ }
  [@@ppp PPP_OCaml]

let print_csv_specs oc specs =
  Printf.fprintf oc "SEPARATOR %S NULL %S %a"
    specs.separator specs.null
    RamenTuple.print_typ specs.fields

let print_file_spec oc specs =
  Printf.fprintf oc "READ%a FILES %a"
    (fun oc unlink ->
      Printf.fprintf oc " AND DELETE IF %a" (E.print false) unlink)
      specs.unlink
    (E.print false) specs.fname

(* Type of an operation: *)

type t =
  (* Aggregation of several tuples into one based on some key. Superficially
   * looks like a select but much more involved. Most clauses being optional,
   * this is really the Swiss-army knife for all data manipulation in Ramen: *)
  | Aggregate of {
      fields : selected_field list ; (* Composition of the output tuple *)
      and_all_others : bool ; (* also "select *" *)
      merge : merge ;
      (* Optional buffering of N tuples for sorting according to some
       * expression: *)
      sort : (int * E.t option (* until *) * E.t list (* by *)) option ;
      (* Simple way to filter out incoming tuples: *)
      where : E.t ;
      (* How to compute the time range for that event: *)
      event_time : RamenEventTime.t option ;
      (* Will send these notification to the alerter: *)
      notifications : E.t list ;
      key : E.t list (* Grouping key *) ;
      commit_cond : E.t (* Output the group after/before this condition holds *) ;
      commit_before : bool ; (* Commit first and aggregate later *)
      flush_how : flush_method ; (* How to flush: reset or slide values *)
      (* List of funcs (or sub-queries) that are our parents: *)
      from : data_source list ;
      (* Pause in between two productions (useful for operations with no
       * parents: *)
      every : float ;
      (* Fields with expected small dimensionality, suitable for breaking down
       * the time series: *)
      factors : N.field list }
  | ReadCSVFile of {
      where : file_spec ;
      what : csv_specs ;
      preprocessor : E.t option ;
      event_time : RamenEventTime.t option ;
      factors : N.field list }
  | ListenFor of {
      net_addr : Unix.inet_addr ;
      port : int ;
      proto : RamenProtocols.net_protocol ;
      factors : N.field list }
  (* For those factors, event time etc are hardcoded, and data sources
   * can not be sub-queries: *)
  | Instrumentation of { from : data_source list }
  | Notifications of { from : data_source list }
  [@@ppp PPP_OCaml]

and merge =
  (* Number of entries to buffer (default 1), expression to merge-sort
   * the parents, and timeout: *)
  { last : int ; on : E.t list ; timeout : float }
  [@@ppp PPP_OCaml]

(* Possible FROM sources: other function (optionally from another program),
 * sub-query or internal instrumentation: *)
and data_source =
  | NamedOperation of (site_identifier * N.rel_program option * N.func)
  | SubQuery of t
  | GlobPattern of Globs.t
  [@@ppp PPP_OCaml]

and site_identifier =
  | AllSites
  | TheseSites of Globs.t
  | ThisSite
  [@@ppp PPP_OCaml]

let print_site_identifier oc = function
  | AllSites -> ()
  | TheseSites s ->
      Printf.fprintf oc "%a:"
        (RamenParsing.print_quoted Globs.print) s
  | ThisSite -> Char.print oc ':'

let rec print_data_source with_types oc = function
  | NamedOperation (site, Some rel_p, f) ->
      let fq = (rel_p :> string) ^"/"^ (f :> string) in
      Printf.fprintf oc "%a%a"
        print_site_identifier site
        (RamenParsing.print_quoted String.print) fq
  | NamedOperation (site, None, f) ->
      Printf.fprintf oc "%a%a"
        print_site_identifier site
        (RamenParsing.print_quoted N.func_print) f
  | SubQuery q ->
      Printf.fprintf oc "(%a)"
        (print with_types) q
  | GlobPattern s ->
      Globs.print oc s

and print with_types oc op =
  let sep = ", " in
  let sp =
    let had_output = ref false in
    fun oc ->
      String.print oc (if !had_output then " " else "") ;
      had_output := true in
  match op with
  | Aggregate { fields ; and_all_others ; merge ; sort ; where ;
                notifications ; key ; commit_cond ; commit_before ;
                flush_how ; from ; every ; event_time ; _ } ->
    if from <> [] then
      Printf.fprintf oc "%tFROM %a" sp
        (List.print ~first:"" ~last:"" ~sep
          (print_data_source with_types)) from ;
    if merge.on <> [] then (
      Printf.fprintf oc "%tMERGE LAST %d ON %a" sp
        merge.last
        (List.print ~first:"" ~last:"" ~sep (E.print with_types)) merge.on ;
      if merge.timeout > 0. then
        Printf.fprintf oc "%tTIMEOUT AFTER %g SECONDS" sp merge.timeout) ;
    Option.may (fun (n, u_opt, b) ->
      Printf.fprintf oc "%tSORT LAST %d" sp n ;
      Option.may (fun u ->
        Printf.fprintf oc "%tOR UNTIL %a" sp
          (E.print with_types) u) u_opt ;
      Printf.fprintf oc " BY %a"
        (List.print ~first:"" ~last:"" ~sep (E.print with_types)) b
    ) sort ;
    if fields <> [] || not and_all_others then
      Printf.fprintf oc "%tSELECT %a%s%s" sp
        (List.print ~first:"" ~last:"" ~sep
          (print_selected_field with_types)) fields
        (if fields <> [] && and_all_others then sep else "")
        (if and_all_others then "*" else "") ;
    if every > 0. then
      Printf.fprintf oc "%tEVERY %g SECONDS" sp every ;
    if not (E.is_true where) then
      Printf.fprintf oc "%tWHERE %a" sp
        (E.print with_types) where ;
    if key <> [] then
      Printf.fprintf oc "%tGROUP BY %a" sp
        (List.print ~first:"" ~last:"" ~sep (E.print with_types)) key ;
    if not (E.is_true commit_cond) ||
       flush_how <> Reset ||
       notifications <> [] then (
      let sep = ref " " in
      if flush_how = Reset && notifications = [] then (
        Printf.fprintf oc "%tCOMMIT" sp ;
        sep := ", ") ;
      if flush_how <> Reset then (
        Printf.fprintf oc "%s%a" !sep print_flush_method flush_how ;
        sep := ", ") ;
      if notifications <> [] then (
        List.print ~first:!sep ~last:"" ~sep:!sep
          (fun oc n -> Printf.fprintf oc "NOTIFY %a" (E.print with_types) n)
          oc notifications ;
        sep := ", ") ;
      if not (E.is_true commit_cond) then
        Printf.fprintf oc "%t%s %a" sp
          (if commit_before then "BEFORE" else "AFTER")
          (E.print with_types) commit_cond) ;
      Option.may (fun et ->
        sp oc ;
        RamenEventTime.print oc et
      ) event_time

  | ReadCSVFile { where = file_spec ; what = csv_specs ; preprocessor ;
                  event_time ; _ } ->
    Printf.fprintf oc "%t%a %s %a" sp
      print_file_spec file_spec
      (Option.map_default (fun e ->
         Printf.sprintf2 "%tPREPROCESS WITH %a" sp (E.print with_types) e
       ) "" preprocessor)
      print_csv_specs csv_specs ;
    Option.may (fun et ->
      sp oc ;
      RamenEventTime.print oc et
    ) event_time

  | ListenFor { net_addr ; port ; proto } ->
    Printf.fprintf oc "%tLISTEN FOR %s ON %s:%d" sp
      (RamenProtocols.string_of_proto proto)
      (Unix.string_of_inet_addr net_addr)
      port

  | Instrumentation { from } ->
    Printf.fprintf oc "%tLISTEN FOR INSTRUMENTATION%a" sp
      (List.print ~first:" FROM " ~last:"" ~sep:", "
        (print_data_source with_types)) from

  | Notifications { from } ->
    Printf.fprintf oc "%tLISTEN FOR NOTIFICATIONS%a" sp
      (List.print ~first:" FROM " ~last:"" ~sep:", "
        (print_data_source with_types)) from

(* We need some tools to fold/iterate over all expressions contained in an
 * operation. We always do so depth first. *)

let fold_top_level_expr init f = function
  | ListenFor _ | Instrumentation _ | Notifications _ -> init
  | ReadCSVFile { where = { fname ; unlink } ; preprocessor ; _ } ->
      let x =
        Option.map_default (f init "CSV preprocessor") init preprocessor in
      let x = f x "CSV filename" fname in
      f x "CSV DELETE-IF clause" unlink
  | Aggregate { fields ; merge ; sort ; where ; key ; commit_cond ;
                notifications ; _ } ->
      let x =
        List.fold_left (fun prev sf ->
            let what = Printf.sprintf "field %S" (sf.alias :> string) in
            f prev what sf.expr
          ) init fields in
      let x = List.fold_left (fun prev me ->
            f prev "MERGE-ON clause" me
          ) x merge.on in
      let x = f x "WHERE clause" where in
      let x = List.fold_left (fun prev ke ->
            f prev "GROUP-BY clause" ke
          ) x key in
      let x = List.fold_left (fun prev notif ->
            f prev "NOTIFY" notif
          ) x notifications in
      let x = f x "COMMIT clause" commit_cond in
      let x = match sort with
        | None -> x
        | Some (_, u_opt, b) ->
            let x = match u_opt with
              | None -> x
              | Some u -> f x "SORT-UNTIL clause" u in
            List.fold_left (fun prev e ->
              f prev "SORT-BY clause" e
            ) x b in
      x

let iter_top_level_expr f =
  fold_top_level_expr () (fun () -> f)

let fold_expr init f =
  fold_top_level_expr init (fun i _ -> E.fold f [] i)

let iter_expr f op =
  fold_expr () (fun s () e -> f s e) op

let map_top_level_expr f op =
  match op with
  | ListenFor _ | Instrumentation _ | Notifications _ -> op
  | ReadCSVFile ({ where = { fname ; unlink } ; preprocessor ; _ } as a) ->
      ReadCSVFile { a with
        where = { fname = f fname ; unlink = f unlink } ;
        preprocessor = Option.map f preprocessor }
  | Aggregate ({ fields ; merge ; sort ; where ; key ; commit_cond ;
                  notifications ; _ } as a) ->
      Aggregate { a with
        fields =
          List.map (fun sf ->
            { sf with expr = f sf.expr }
          ) fields ;
        merge = { merge with on = List.map f merge.on } ;
        where = f where ;
        key = List.map f key ;
        notifications = List.map f notifications ;
        commit_cond = f commit_cond ;
        sort =
          Option.map (fun (i, u_opt, b) ->
            i,
            Option.map f u_opt,
            List.map f b
          ) sort }

let map_expr f =
  map_top_level_expr (E.map f [])

(* Various functions to inspect an operation: *)

let is_merging = function
  | Aggregate { merge ; _ } when merge.on <> [] -> true
  | _ -> false

(* BEWARE: you might have an event_time set in the Func.t that is inherited
 * and therefore not in the operation! *)
let event_time_of_operation op =
  let event_time, fields =
    match op with
    | Aggregate { event_time ; fields ; _ } ->
        event_time, List.map (fun sf -> sf.alias) fields
    | ReadCSVFile { event_time ; what ; _ } ->
        event_time, List.map (fun ft -> ft.RamenTuple.name) what.fields
    | ListenFor { proto ; _ } ->
        RamenProtocols.event_time_of_proto proto, []
    | Instrumentation _ ->
        RamenBinocle.event_time, []
    | Notifications _ ->
        RamenNotification.event_time, []
  and event_time_from_fields fields =
    let fos = N.field in
    let start = fos "start"
    and stop = fos "stop"
    and duration = fos "duration" in
    if List.mem start fields then
      Some RamenEventTime.(
        (start, ref OutputField, 1.),
        if List.mem stop fields then
          StopField (stop, ref OutputField, 1.)
        else if List.mem duration fields then
          DurationField (duration, ref OutputField, 1.)
        else
          DurationConst 0.)
    else None
  in
  if event_time <> None then event_time else
  event_time_from_fields fields

let operation_with_event_time op event_time = match op with
  | Aggregate s -> Aggregate { s with event_time }
  | ReadCSVFile s -> ReadCSVFile { s with event_time }
  | ListenFor _ -> op
  | Instrumentation _ -> op
  | Notifications _ -> op

let func_id_of_data_source = function
  | NamedOperation id -> id
  | SubQuery _
      (* Should have been replaced by a hidden function
       * by the time this is called *)
  | GlobPattern _ ->
      (* Should not be called on instrumentation operation *)
      assert false

let parents_of_operation = function
  | ListenFor _ | ReadCSVFile _
  (* Note that those have a from clause but no actual parents: *)
  | Instrumentation _ | Notifications _ -> []
  | Aggregate { from ; _ } ->
      List.map func_id_of_data_source from

let factors_of_operation = function
  | ReadCSVFile { factors ; _ }
  | Aggregate { factors ; _ } -> factors
  | ListenFor { factors ; proto ; _ } ->
      if factors <> [] then factors
      else RamenProtocols.factors_of_proto proto
  | Instrumentation _ -> RamenBinocle.factors
  | Notifications _ -> RamenNotification.factors

let operation_with_factors op factors = match op with
  | ReadCSVFile s -> ReadCSVFile { s with factors }
  | Aggregate s -> Aggregate { s with factors }
  | ListenFor s -> ListenFor { s with factors }
  | Instrumentation _ -> op
  | Notifications _ -> op

(* Return the (likely) untyped output tuple *)
let out_type_of_operation ?(with_private=true) = function
  | Aggregate { fields ; and_all_others ; _ } ->
      assert (not and_all_others) ;
      List.fold_left (fun lst sf ->
        if not with_private && N.is_private sf.alias then lst else
        RamenTuple.{
          name = sf.alias ;
          doc = sf.doc ;
          aggr = sf.aggr ;
          typ = sf.expr.typ ;
          units = sf.expr.units } :: lst
      ) [] fields |> List.rev
  | ReadCSVFile { what = { fields ; _ } ; _ } ->
      fields
  | ListenFor { proto ; _ } ->
      RamenProtocols.tuple_typ_of_proto proto
  | Instrumentation _ ->
      RamenBinocle.tuple_typ
  | Notifications _ ->
      RamenNotification.tuple_typ

(* Same as above, but return the output type as a TRecord (the way it's
 * supposed to be!) *)
let out_record_of_operation ?with_private op =
  T.make ~nullable:false
    (T.TRecord (
      (out_type_of_operation ?with_private op |> List.enum) |>
      Enum.map (fun ft ->
        (ft.RamenTuple.name :> string), ft.typ) |>
      Array.of_enum))

let envvars_of_operation op =
  fold_expr Set.empty (fun _ s e ->
    match e.E.text with
    | Stateless (SL2 (Get, { text = Const (VString n) ; _ },
                           { text = Variable TupleEnv ; _ })) ->
        Set.add (N.field n) s
    | _ -> s) op |>
  Set.to_list |>
  List.fast_sort N.compare

let use_event_time op =
  fold_expr false (fun _ b e ->
    match e.E.text with
    | Stateless (SL0 (EventStart|EventStop)) -> true
    | _ -> b
  ) op

let has_notifications = function
  | ListenFor _ | ReadCSVFile _
  | Instrumentation _ | Notifications _ -> false
  | Aggregate { notifications ; _ } ->
      notifications <> []

let resolve_unknown_tuple resolver e =
  E.map (fun stack e ->
    let resolver = function
      | [] | E.Int _ :: _ as path -> (* Int is TODO *)
          Printf.sprintf2 "Cannot resolve unknown path %a"
            E.print_path path |>
          failwith
      | E.Name n :: _ ->
          resolver stack n
    in
    match e.E.text with
    | Stateless (SL2 (Get, n, ({ text = Variable TupleUnknown ; _ } as x))) ->
        let pref =
          match E.int_of_const n with
          | Some n -> resolver [ Int n ]
          | None ->
              (match E.string_of_const n with
              | Some n ->
                  let n = N.field n in
                  resolver [ Name n ]
              | None ->
                  Printf.sprintf2 "Cannot resolve unknown tuple in %a"
                    (E.print false) e |>
                  failwith) in
        { e with text =
          Stateless (SL2 (Get, n, { x with text = Variable pref })) }
    | _ -> e
  ) [] e

(* Also used by [RamenProgram] to check running condition *)
let prefix_def params def =
  resolve_unknown_tuple (fun _stack n ->
    if RamenTuple.params_mem n params then TupleParam else def)

(* Replace the expressions with [TupleUnknown] with their likely tuple. *)
let resolve_unknown_tuples params op =
  (* Unless it's a param (TODO: or an opened record), assume TupleUnknow
   * belongs to def: *)
  match op with
  | Aggregate ({ fields ; merge ; sort ; where ; key ; commit_cond ;
                 notifications ; _ } as aggr) ->
      let is_selected_fields ?i name = (* Tells if a field is in _out_ *)
        list_existsi (fun i' sf ->
          sf.alias = name &&
          Option.map_default (fun i -> i' < i) true i
        ) fields in
      (* Resolve TupleUnknown into either TupleParam (if the name is in
       * params), TupleIn or TupleOut (depending on the presence of this alias
       * in selected_fields -- optionally, only before position i). It will
       * also keep track of opened records and look up there first. *)
      let prefix_smart ?(allow_out=true) ?i =
        resolve_unknown_tuple (fun stack n ->
          (* First, lookup for an opened record: *)
          if List.exists (fun e ->
               match e.E.text with
               | Record kvs ->
                   (* Notice that we look into _all_ fields, not only the
                    * ones defined previously. Not sure if better or
                    * worse. *)
                   List.exists (fun (k, _) -> k = n) kvs
               | _ -> false
             ) stack
          then (
            (* Notice we do not keep a reference on the actual expression.
             * That's much safer to look it up again whenever we need it,
             * so that we are free to map the AST. *)
            !logger.debug "Field %a though to belong to an opened record"
              N.field_print n ;
            Record
          ) else (
            let pref =
              (* Look into predefined records: *)
              if RamenTuple.params_mem n params then
                TupleParam
              (* Then into fields that have been defined before: *)
              else if allow_out && is_selected_fields ?i n then
                TupleOut
              (* Then finally assume input: *)
              else TupleIn in
            !logger.debug "Field %a thought to belong to %s"
              N.field_print n
              (string_of_prefix pref) ;
            pref
          )
        )
    in
    let fields =
      List.mapi (fun i sf ->
        { sf with expr = prefix_smart ~i sf.expr }
      ) fields in
    let merge =
      { merge with
          on = List.map (prefix_def params TupleIn) merge.on } in
    let sort =
      Option.map (fun (n, u_opt, b) ->
        n,
        Option.map (prefix_def params TupleIn) u_opt,
        List.map (prefix_def params TupleIn) b
      ) sort in
    let where = prefix_smart ~allow_out:false where in
    let key = List.map (prefix_def params TupleIn) key in
    let commit_cond = prefix_smart commit_cond in
    let notifications = List.map prefix_smart notifications in
    Aggregate { aggr with
      fields ; merge ; sort ; where ; key ; commit_cond ; notifications }

  | ReadCSVFile ({ where ; preprocessor ; _ } as csv) ->
    (* Default to In if not a param, and then disallow In >:-> *)
    let preprocessor =
      Option.map (fun p ->
        (* prefix_def will select Param if it is indeed in param, and only
         * if not will it assume it's in env; which makes sense as that's the
         * only two possible tuples here: *)
        prefix_def params TupleEnv p
      ) preprocessor in
    let where =
      { fname = prefix_def params TupleEnv where.fname ;
        unlink = prefix_def params TupleEnv where.unlink } in
    ReadCSVFile { csv with preprocessor ; where }

  | op -> op

exception DependsOnInvalidTuple of tuple_prefix
let check_depends_only_on lst =
  let check_can_use tuple =
    if not (List.mem tuple lst) then
      raise (DependsOnInvalidTuple tuple)
  in
  E.iter (fun _ e ->
    match e.E.text with
    | Variable tuple -> check_can_use tuple
    | Stateless (SL0 (EventStart|EventStop)) ->
      (* Be conservative for now.
       * TODO: Actually check the event time expressions.
       * Also, we may not know yet the event time (if it's inferred from
       * a parent).
       * TODO: Perform those checks only after factors/time inference.
       * And finally, we will do all this for nothing, as the fields are
       * taken from output event when they are just transferred from input.
       * So when the field used in the time expression can be computed only
       * from the input tuple (with no use of another out field) we could
       * as well recompute it - at least when it's just forwarded.
       * But then we would need to be smarter in
       * CodeGen_OCaml.emit_event_time will need more context (is out
       * available) and how is it computed. So for now, let's assume any
       * mention of #start/#stop is from out.  *)
      check_can_use TupleOut
    | _ -> ())

(* Check that the expression is valid, or return an error message.
 * Also perform some optimisation, numeric promotions, etc...
 * This is done after the parse rather than Rejecting the parsing
 * result for better error messages, and also because we need the
 * list of available parameters. *)
let checked params op =
  let op = resolve_unknown_tuples params op in
  let check_pure clause =
    E.unpure_iter (fun _ _ ->
      failwith ("Stateful functions not allowed in "^ clause))
  and check_no_state state clause =
    E.unpure_iter (fun _ e ->
      match e.E.text with
      | Stateful (g, _, _) when g = state ->
          Printf.sprintf "%s stateful functions not allowed in %s"
            (match g with LocalState -> "Locally" | GlobalState -> "Globally")
            clause |>
          failwith
      | _ -> ())
  and warn_no_group clause =
    E.unpure_iter (fun _ e ->
      match e.E.text with
      | Stateful (LocalState, skip, stateful) ->
          !logger.warning
            "In %s: Locally stateful function without a GROUP-BY clause. \
             Did you mean %a?"
            clause
            (E.print_text ~max_depth:1 false)
              (Stateful (GlobalState, skip, stateful))
      | _ -> ())
  and check_fields_from lst where e =
    try check_depends_only_on lst e
    with DependsOnInvalidTuple tuple ->
      Printf.sprintf2 "Tuple %s not allowed in %s (only %a)"
        (RamenLang.string_of_prefix tuple)
        where (pretty_list_print RamenLang.tuple_prefix_print) lst |>
      failwith
  and check_field_exists field_names f =
    if not (List.mem f field_names) then
      Printf.sprintf2 "Field %a is not in output tuple (only %a)"
        N.field_print f
        (pretty_list_print N.field_print) field_names |>
      failwith in
  let check_event_time field_names (start_field, duration) =
    let check_field (f, src, _scale) =
      if RamenTuple.params_mem f params then
        (* FIXME: check that the type is compatible with TFloat!
         *        And not nullable! *)
        src := RamenEventTime.Parameter
      else
        check_field_exists field_names f
    in
    check_field start_field ;
    match duration with
    | RamenEventTime.DurationConst _ -> ()
    | RamenEventTime.DurationField f
    | RamenEventTime.StopField f -> check_field f
  and check_factors field_names =
    List.iter (check_field_exists field_names)
  and check_no_group = check_no_state LocalState
  in
  (match op with
  | Aggregate { fields ; and_all_others ; merge ; sort ; where ; key ;
                commit_cond ; event_time ; notifications ; from ; every ;
                factors ; _ } ->
    (* Check that we use the TupleGroup only for virtual fields: *)
    iter_expr (fun _ e ->
      match e.E.text with
      | Stateless (SL2 (Get, { text = Const (VString n) ; _ },
                             { text = Variable TupleGroup ; _ })) ->
          let n = N.field n in
          if not (N.is_virtual n) then
            Printf.sprintf2 "Tuple group has only virtual fields (no %a)"
              N.field_print n |>
            failwith
      | _ -> ()) op ;
    (* Now check what tuple prefixes are used: *)
    List.fold_left (fun prev_aliases sf ->
        check_fields_from
          [ TupleParam; TupleEnv; TupleIn; TupleGroup;
            TupleOut (* FIXME: only if defined earlier *);
            TupleOutPrevious ; Record ] "SELECT clause" sf.expr ;
        (* Check unicity of aliases *)
        if List.mem sf.alias prev_aliases then
          Printf.sprintf2 "Alias %a is not unique"
            N.field_print sf.alias |>
          failwith ;
        sf.alias :: prev_aliases
      ) [] fields |> ignore;
    if not and_all_others then (
      let field_names = List.map (fun sf -> sf.alias) fields in
      Option.may (check_event_time field_names) event_time ;
      check_factors field_names factors
    ) ;
    (* Disallow group state in WHERE because it makes no sense: *)
    check_no_group "WHERE clause" where ;
    check_fields_from
      [ TupleParam; TupleEnv; TupleIn;
        TupleGroup; TupleOutPrevious; TupleMergeGreatest ; Record ]
      "WHERE clause" where ;
    List.iter (fun k ->
      check_pure "GROUP-BY clause" k ;
      check_fields_from
        [ TupleParam; TupleEnv; TupleIn ; Record ] "Group-By KEY" k
    ) key ;
    List.iter (fun name ->
      check_fields_from [ TupleParam; TupleEnv; TupleIn; TupleOut; Record ]
                        "notification" name
    ) notifications ;
    check_fields_from
      [ TupleParam; TupleEnv; TupleIn;
        TupleOut; TupleOutPrevious;
        TupleGroup; Record ]
      "COMMIT WHEN clause" commit_cond ;
    Option.may (fun (_, until_opt, bys) ->
      Option.may (fun until ->
        check_fields_from
          [ TupleParam; TupleEnv;
            TupleSortFirst; TupleSortSmallest; TupleSortGreatest; Record ]
          "SORT-UNTIL clause" until
      ) until_opt ;
      List.iter (fun by ->
        check_fields_from
          [ TupleParam; TupleEnv; TupleIn; Record ]
          "SORT-BY clause" by
      ) bys
    ) sort ;
    List.iter (fun e ->
      check_fields_from
        [ TupleParam; TupleEnv; TupleIn; Record ]
        "MERGE-ON clause" e
    ) merge.on ;
    if every > 0. && from <> [] then
      failwith "Cannot have both EVERY and FROM" ;
    (* Check that we do not use any fields from out that is generated: *)
    let generators = List.filter_map (fun sf ->
        if E.is_generator sf.expr then Some sf.alias else None
      ) fields in
    iter_expr (fun _ e ->
      match e.E.text with
      | Stateless (SL2 (Get, { text = Const (VString n) ; _ },
                             { text = Variable TupleOutPrevious ; _ })) ->
          let n = N.field n in
          if List.mem n generators then
            Printf.sprintf2 "Cannot use a generated output field %a"
              N.field_print n |>
            failwith
      | _ -> ()
    ) op ;
    (* Finally, check that if now group-by clause is present, then no
     * LocalState is used anywhere: *)
    if key = [] then iter_top_level_expr warn_no_group op

  | ListenFor { proto ; factors ; _ } ->
    let tup_typ = RamenProtocols.tuple_typ_of_proto proto in
    let field_names = List.map (fun t -> t.RamenTuple.name) tup_typ in
    check_factors field_names factors

  | ReadCSVFile { what ; where = { fname ; unlink } ; event_time ; factors ;
                  preprocessor ; _ } ->
    let field_names = List.map (fun t -> t.RamenTuple.name) what.fields in
    Option.may (check_event_time field_names) event_time ;
    check_factors field_names factors ;
    (* Default to In if not a param, and then disallow In >:-> *)
    Option.may (fun p ->
      check_fields_from [ TupleParam; TupleEnv ] "PREPROCESSOR" p
    ) preprocessor ;
    check_fields_from [ TupleParam; TupleEnv ] "FILE NAMES" fname ;
    check_fields_from [ TupleParam; TupleEnv ] "DELETE-IF" unlink ;
    check_pure "DELETE-IF" unlink
    (* FIXME: check the field type declarations use only scalar types *)

  | Instrumentation _ | Notifications _ -> ()) ;
  (* Now that we have inferred the IO tuples, run some additional checks on
   * the expressions: *)
  iter_expr (fun _ e -> E.check e) op ;
  op

module Parser =
struct
  (*$< Parser *)
  open RamenParsing

  let rec default_alias e =
    match e.E.text with
    | Stateless (SL0 (Path [ Name name ]))
      when not (N.is_virtual name) ->
        (name :> string)
    | Stateless (SL2 (Get, { text = Const (VString n) ; _ }, _))
      when not (N.is_virtual (N.field n)) ->
        n
    (* Provide some default name for common aggregate functions: *)
    | Stateful (_, _, SF1 (AggrMin, e)) -> "min_"^ default_alias e
    | Stateful (_, _, SF1 (AggrMax, e)) -> "max_"^ default_alias e
    | Stateful (_, _, SF1 (AggrSum, e)) -> "sum_"^ default_alias e
    | Stateful (_, _, SF1 (AggrAvg, e)) -> "avg_"^ default_alias e
    | Stateful (_, _, SF1 (AggrAnd, e)) -> "and_"^ default_alias e
    | Stateful (_, _, SF1 (AggrOr, e)) -> "or_"^ default_alias e
    | Stateful (_, _, SF1 (AggrFirst, e)) -> "first_"^ default_alias e
    | Stateful (_, _, SF1 (AggrLast, e)) -> "last_"^ default_alias e
    | Stateful (_, _, SF1 (AggrHistogram _, e)) ->
        default_alias e ^"_histogram"
    | Stateless (SL2 (Percentile, e,
        { text = (Const p | Vector [ { text = Const p ; _ } ]) ; _ }))
      when T.is_round_integer p ->
        Printf.sprintf2 "%s_%ath" (default_alias e) T.print p
    (* Some functions better leave no traces: *)
    | Stateless (SL1s (Print, e::_)) -> default_alias e
    | Stateless (SL1 (Cast _, e)) -> default_alias e
    | Stateful (_, _, SF1 (Group, e)) -> default_alias e
    | _ -> raise (Reject "must set alias")

  (* Either `expr` or `expr AS alias` or `expr AS alias "doc"`, or
   * `expr doc "doc"`: *)
  let selected_field m =
    let m = "selected field" :: m in
    (
      E.Parser.p ++ (
        optional ~def:(None, "") (
          blanks -- strinG "as" -- blanks -+ some non_keyword ++
          optional ~def:"" (blanks -+ quoted_string)) |||
        (blanks -- strinG "doc" -- blanks -+ quoted_string >>:
         fun doc -> None, doc)) ++
      optional ~def:None (
        blanks -+ some RamenTuple.Parser.default_aggr) >>:
      fun ((expr, (alias, doc)), aggr) ->
        let alias =
          Option.default_delayed (fun () -> default_alias expr) alias in
        let alias = N.field alias in
        { expr ; alias ; doc ; aggr }
    ) m

  let event_time_clause m =
    let m = "event time clause" :: m in
    let scale m =
      let m = "scale event field" :: m in
      (optional ~def:1. (
        (optional ~def:() blanks -- star --
         optional ~def:() blanks -+ number ))
      ) m
    in (
      let open RamenEventTime in
      strinG "event" -- blanks -- (strinG "starting" ||| strinG "starts") --
      blanks -- strinG "at" -- blanks -+ non_keyword ++ scale ++
      optional ~def:(DurationConst 0.) (
        (blanks -- optional ~def:() ((strinG "and" ||| strinG "with") -- blanks) --
         strinG "duration" -- blanks -+ (
           (non_keyword ++ scale >>: fun (n, s) ->
              let n = N.field n in
              DurationField (n, ref OutputField, s)) |||
           (duration >>: fun n -> DurationConst n)) |||
         blanks -- strinG "and" -- blanks --
         (strinG "stops" ||| strinG "stopping" |||
          strinG "ends" ||| strinG "ending") -- blanks --
         strinG "at" -- blanks -+
           (non_keyword ++ scale >>: fun (n, s) ->
              let n = N.field n in
              StopField (n, ref OutputField, s)))) >>:
      fun ((sta, sca), dur) ->
        let sta = N.field sta in
        (sta, ref OutputField, sca), dur
    ) m

  let every_clause m =
    let m = "every clause" :: m in
    (strinG "every" -- blanks -+ duration >>: fun every ->
       if every < 0. then
         raise (Reject "sleep duration must be greater than 0") ;
       every) m

  let select_clause m =
    let m = "select clause" :: m in
    ((strinG "select" ||| strinG "yield") -- blanks -+
     several ~sep:list_sep
             ((star >>: fun _ -> None) |||
              some selected_field)) m

  let event_time_start () =
    E.make (Stateless (SL2 (Get, E.of_string "start",
                                 E.make (Variable TupleIn))))

  let merge_clause m =
    let m = "merge clause" :: m in
    (
      strinG "merge" -+
      optional ~def:1 (
        blanks -- strinG "last" -- blanks -+
        pos_decimal_integer "Merge buffer size") ++
      optional ~def:[] (
        blanks -- strinG "on" -- blanks -+
        several ~sep:list_sep E.Parser.p) ++
      optional ~def:0. (
        blanks -- strinG "timeout" -- blanks -- strinG "after" -- blanks -+
        duration) >>:
      fun ((last, on), timeout) ->
        (* We do not make it the default to avoid creating a new type at
         * every parsing attempt: *)
        let on =
          if on = [] then [ event_time_start () ] else on in
        { last ; on ; timeout }
    ) m

  let sort_clause m =
    let m = "sort clause" :: m in
    (
      strinG "sort" -- blanks -- strinG "last" -- blanks -+
      pos_decimal_integer "Sort buffer size" ++
      optional ~def:None (
        blanks -- strinG "or" -- blanks -- strinG "until" -- blanks -+
        some E.Parser.p) ++
      optional ~def:[] (
        blanks -- strinG "by" -- blanks -+
        several ~sep:list_sep E.Parser.p) >>:
      fun ((l, u), b) ->
        let b =
          if b = [] then [ event_time_start () ] else b in
        l, u, b
    ) m

  let where_clause m =
    let m = "where clause" :: m in
    ((strinG "where" ||| strinG "when") -- blanks -+ E.Parser.p) m

  let group_by m =
    let m = "group-by clause" :: m in
    (strinG "group" -- blanks -- strinG "by" -- blanks -+
     several ~sep:list_sep E.Parser.p) m

  type commit_spec =
    | NotifySpec of E.t
    | FlushSpec of flush_method
    | CommitSpec (* we would commit anyway, just a placeholder *)

  let notification_clause m =
    let m = "notification" :: m in
    (
      strinG "notify" -- blanks -+
      optional ~def:None (some E.Parser.p) >>: fun name ->
        NotifySpec (name |? E.of_string "Don't Panic!")
    ) m

  let flush m =
    let m = "flush clause" :: m in
    ((strinG "flush" >>: fun () -> Reset) |||
     (strinG "keep" -- optional ~def:() (blanks -- strinG "all") >>:
       fun () -> Never) >>:
     fun s -> FlushSpec s) m

  let dummy_commit m =
    (strinG "commit" >>: fun () -> CommitSpec) m

  let default_commit_cond = E.of_bool true

  let commit_clause m =
    let m = "commit clause" :: m in
    (several ~sep:list_sep_and ~what:"commit clauses"
       (dummy_commit ||| notification_clause ||| flush) ++
     optional ~def:(false, default_commit_cond)
      (blanks -+
       ((strinG "after" >>: fun _ -> false) |||
        (strinG "before" >>: fun _ -> true)) +- blanks ++
       E.Parser.p)) m

  let default_port_of_protocol = function
    | RamenProtocols.Collectd -> 25826
    | RamenProtocols.NetflowV5 -> 2055
    | RamenProtocols.Graphite -> 2003

  let net_protocol m =
    let m = "network protocol" :: m in
    (
      (strinG "collectd" >>: fun () -> RamenProtocols.Collectd) |||
      ((strinG "netflow" ||| strinG "netflowv5") >>: fun () ->
        RamenProtocols.NetflowV5) |||
      (strinG "graphite" >>: fun () -> RamenProtocols.Graphite)
    ) m

  let network_address =
    several ~sep:none (cond "inet address" (fun c ->
      (c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'A') ||
      c == '.' || c == ':') '0') >>:
    fun s ->
      let s = String.of_list s in
      try Unix.inet_addr_of_string s
      with Failure x -> raise (Reject x)

  let inet_addr m =
    let m = "network address" :: m in
    ((string "*" >>: fun () -> Unix.inet_addr_any) |||
     (string "[*]" >>: fun () -> Unix.inet6_addr_any) |||
     (network_address)) m

  let host_port m =
    let m = "host and port" :: m in
    (
      inet_addr ++
      optional ~def:None (
        char ':' -+
        some (decimal_integer_range ~min:0 ~max:65535 "port number"))
    ) m

  let listen_clause m =
    let m = "listen on operation" :: m in
    (strinG "listen" -- blanks --
     optional ~def:() (strinG "for" -- blanks) -+
     net_protocol ++
     optional ~def:None (
       blanks --
       optional ~def:() (strinG "on" -- blanks) -+
       some host_port) >>:
     fun (proto, addr_opt) ->
        let net_addr, port =
          match addr_opt with
          | None -> Unix.inet_addr_any, default_port_of_protocol proto
          | Some (addr, None) -> addr, default_port_of_protocol proto
          | Some (addr, Some port) -> addr, port in
        net_addr, port, proto) m

  let instrumentation_clause m =
    let m = "read instrumentation operation" :: m in
    (strinG "listen" -- blanks --
     optional ~def:() (strinG "for" -- blanks) -+
     (that_string "instrumentation" ||| that_string "notifications")) m

let fields_schema m =
  let m = "tuple schema" :: m in
  (
    char '(' -- opt_blanks -+
      several ~sep:list_sep RamenTuple.Parser.field +-
    opt_blanks +- char ')'
  ) m

  (* FIXME: It should be allowed to enter separator, null, preprocessor in
   * any order *)
  let read_file_specs m =
    let m = "read file operation" :: m in
    (
      strinG "read" -- blanks -+
      optional ~def:(E.of_bool false) (
        strinG "and" -- blanks -- strinG "delete" -- blanks -+
        optional ~def:(E.of_bool true) (
          strinG "if" -- blanks -+ E.Parser.p +- blanks)) +-
      strinGs "file" +- blanks ++
      E.Parser.p >>: fun (unlink, fname) ->
        { unlink ; fname }
    ) m

  let csv_specs m =
    let m = "CSV format" :: m in
    (optional ~def:Default.csv_separator (
       strinG "separator" -- opt_blanks -+ quoted_string +- opt_blanks) ++
     optional ~def:"" (
       strinG "null" -- opt_blanks -+ quoted_string +- opt_blanks) ++
     fields_schema >>:
     fun ((separator, null), fields) ->
       if separator = null || separator = "" then
         raise (Reject "Invalid CSV separator") ;
       { separator ; null ; fields }) m

  let preprocessor_clause m =
    let m = "file preprocessor" :: m in
    (
      strinG "preprocess" -- blanks -- strinG "with" -- opt_blanks -+
      E.Parser.p
    ) m

  let factor_clause m =
    let m = "factors" :: m
    and field = non_keyword >>: N.field in
    ((strinG "factor" ||| strinG "factors") -- blanks -+
     several ~sep:list_sep_and field) m

  type select_clauses =
    | SelectClause of selected_field option list
    | MergeClause of merge
    | SortClause of (int * E.t option (* until *) * E.t list (* by *))
    | WhereClause of E.t
    | EventTimeClause of RamenEventTime.t
    | FactorClause of N.field list
    | GroupByClause of E.t list
    | CommitClause of (commit_spec list * (bool (* before *) * E.t))
    | FromClause of data_source list
    | EveryClause of float
    | ListenClause of (Unix.inet_addr * int * RamenProtocols.net_protocol)
    | InstrumentationClause of string
    | ExternalDataClause of file_spec
    | PreprocessorClause of E.t option
    | CsvSpecsClause of csv_specs

  (* A special from clause that accept globs, used to match workers in
   * instrumentation operations. *)
  let from_pattern m =
    let what = "pattern" in
    let m = what :: m in
    let first_char = letter ||| underscore ||| char '/' ||| star in
    let any_char = first_char ||| decimal_digit in
    (* It must have a star, or it will be parsed as a func_identifier
     * instead: *)
    let checked s =
      if String.contains s '*' then s else
        raise (Reject "Not a glob") in
    let unquoted =
      first_char ++ repeat_greedy ~sep:none ~what any_char >>: fun (c, s) ->
        checked (String.of_list (c :: s))
    and quoted =
      id_quote -+ repeat_greedy ~sep:none ~what (
        cond "quoted program identifier" ((<>) '\'') 'x') +-
      id_quote >>: fun s ->
      checked (String.of_list s) in
    (unquoted ||| quoted) m

  type tmp_data_source =
    | Named_ of (N.rel_program option * N.func)
    | Pattern_ of string

  let rec from_clause m =
    let m = "from clause" :: m in
    let site =
      optional ~def:ThisSite (
        site_identifier >>: fun h -> TheseSites (Globs.compile h)) in
    (
      strinG "from" -- blanks -+
      several ~sep:list_sep_and (
        (
          char '(' -- opt_blanks -+ p +- opt_blanks +- char ')' >>:
            fun t -> SubQuery t
        ) ||| (
          from_pattern >>: fun s -> GlobPattern (Globs.compile s)
        ) ||| (
          optional ~def:AllSites (site +- char ':') ++
          func_identifier >>: fun (h, (p, f)) -> NamedOperation (h, p, f)
        )
      )
    ) m

  and p m =
    let m = "operation" :: m in
    let part =
      (select_clause >>: fun c -> SelectClause c) |||
      (merge_clause >>: fun c -> MergeClause c) |||
      (sort_clause >>: fun c -> SortClause c) |||
      (where_clause >>: fun c -> WhereClause c) |||
      (event_time_clause >>: fun c -> EventTimeClause c) |||
      (group_by >>: fun c -> GroupByClause c) |||
      (commit_clause >>: fun c -> CommitClause c) |||
      (from_clause >>: fun c -> FromClause c) |||
      (every_clause >>: fun c -> EveryClause c) |||
      (listen_clause >>: fun c -> ListenClause c) |||
      (instrumentation_clause >>: fun c -> InstrumentationClause c) |||
      (read_file_specs >>: fun c -> ExternalDataClause c) |||
      (preprocessor_clause >>: fun c -> PreprocessorClause (Some c)) |||
      (csv_specs >>: fun c -> CsvSpecsClause c) |||
      (factor_clause >>: fun c -> FactorClause c) in
    (several ~sep:blanks part >>: fun clauses ->
      (* Used for its address: *)
      let default_select_fields = []
      and default_star = true
      and default_merge = { last = 1 ; on = [] ; timeout = 0. }
      and default_sort = None
      and default_where = E.of_bool true
      and default_event_time = None
      and default_key = []
      and default_commit = ([], (false, default_commit_cond))
      and default_from = []
      and default_every = 0.
      and default_listen = None
      and default_instrumentation = ""
      and default_ext_data = None
      and default_preprocessor = None
      and default_csv_specs = None
      and default_factors = [] in
      let default_clauses =
        default_select_fields, default_star, default_merge, default_sort,
        default_where, default_event_time, default_key,
        default_commit, default_from, default_every,
        default_listen, default_instrumentation, default_ext_data,
        default_preprocessor, default_csv_specs, default_factors in
      let select_fields, and_all_others, merge, sort, where,
          event_time, key, commit, from, every, listen, instrumentation,
          ext_data, preprocessor, csv_specs, factors =
        List.fold_left (
          fun (select_fields, and_all_others, merge, sort, where,
               event_time, key, commit, from, every, listen,
               instrumentation, ext_data, preprocessor, csv_specs,
               factors) ->
            (* FIXME: in what follows, detect and signal cases when a new value
             * replaces an old one (but the default), such as when two WHERE
             * clauses are given. *)
            function
            | SelectClause fields_or_stars ->
              let fields, and_all_others =
                List.fold_left (fun (fields, and_all_others) -> function
                  | Some f -> f::fields, and_all_others
                  | None when not and_all_others -> fields, true
                  | None -> raise (Reject "All fields (\"*\") included \
                                   several times")
                ) ([], false) fields_or_stars in
              (* The above fold_left inverted the field order. *)
              let select_fields = List.rev fields in
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | MergeClause merge ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | SortClause sort ->
              select_fields, and_all_others, merge, Some sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | WhereClause where ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | EventTimeClause event_time ->
              select_fields, and_all_others, merge, sort, where,
              Some event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | GroupByClause key ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | CommitClause commit' ->
              if commit != default_commit then
                raise (Reject "Cannot have several commit clauses") ;
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit', from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | FromClause from' ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, (List.rev_append from' from),
              every, listen, instrumentation, ext_data, preprocessor,
              csv_specs, factors
            | EveryClause every ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | ListenClause l ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, Some l,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | InstrumentationClause c ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen, c,
              ext_data, preprocessor, csv_specs, factors
            | ExternalDataClause c ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, Some c, preprocessor, csv_specs,
              factors
            | PreprocessorClause preprocessor ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
            | CsvSpecsClause c ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, Some c,
              factors
            | FactorClause factors ->
              select_fields, and_all_others, merge, sort, where,
              event_time, key, commit, from, every, listen,
              instrumentation, ext_data, preprocessor, csv_specs,
              factors
          ) default_clauses clauses in
      let commit_specs, (commit_before, commit_cond) = commit in
      (* Try to catch when we write "commit when" instead of "commit
       * after/before": *)
      if commit_specs = [ CommitSpec ] &&
         commit_cond = default_commit_cond then
        raise (Reject "Lone COMMIT makes no sense. \
                       Do you mean COMMIT AFTER/BEFORE?") ;
      (* Distinguish between Aggregate, Read, ListenFor...: *)
      let not_aggregate =
        select_fields == default_select_fields && sort == default_sort &&
        where == default_where && key == default_key &&
        commit == default_commit
      and not_listen = listen = None || from != default_from || every <> 0.
      and not_instrumentation = instrumentation = ""
      and not_csv =
        ext_data = None && preprocessor == default_preprocessor &&
        csv_specs = None || from != default_from || every <> 0.
      and not_event_time = event_time = default_event_time
      and not_factors = factors == default_factors in
      if not_listen && not_csv && not_instrumentation then
        let flush_how, notifications =
          List.fold_left (fun (f, n) -> function
            | CommitSpec -> f, n
            | NotifySpec n' -> f, n'::n
            | FlushSpec f' ->
                if f = None then (Some f', n)
                else raise (Reject "Several flush clauses")
          ) (None, []) commit_specs in
        let flush_how = flush_how |? Reset in
        Aggregate { fields = select_fields ; and_all_others ; merge ; sort ;
                    where ; event_time ; notifications ; key ;
                    commit_before ; commit_cond ; flush_how ; from ;
                    every ; factors }
      else if not_aggregate && not_csv && not_event_time &&
              not_instrumentation && listen <> None then
        let net_addr, port, proto = Option.get listen in
        ListenFor { net_addr ; port ; proto ; factors }
      else if not_aggregate && not_listen &&
              not_instrumentation &&
              ext_data <> None && csv_specs <> None then
        ReadCSVFile { where = Option.get ext_data ;
                      what = Option.get csv_specs ;
                      preprocessor ; event_time ; factors }
      else if not_aggregate && not_listen && not_csv && not_listen &&
              not_factors
      then
        if String.lowercase instrumentation = "instrumentation" then
          Instrumentation { from }
        else
          Notifications { from }
      else
        raise (Reject "Incompatible mix of clauses")
    ) m

  (*$inject
    let test_op s =
      (match test_p p s with
      | Ok (res, rem) ->
        let params =
          [ RamenTuple.{
              ptyp = { name = N.field "avg_window" ;
                       typ = { structure = T.TI32 ;
                               nullable = false } ;
                       units = None ; doc = "" ; aggr = None } ;
              value = T.VI32 10l }] in
        BatPervasives.Ok (
          RamenOperation.checked params res,
          rem)
      | x -> x) |>
      TestHelpers.test_printer (RamenOperation.print false)
  *)
  (*$= test_op & ~printer:BatPervasives.identity
    "FROM 'foo' SELECT in.start, in.stop, in.itf_clt AS itf_src, in.itf_srv AS itf_dst" \
      (test_op "from foo select start, stop, itf_clt as itf_src, itf_srv as itf_dst")

    "FROM 'foo' WHERE (in.packets) > (0)" \
      (test_op "from foo where packets > 0")

    "FROM 'foo' SELECT in.t, in.value EVENT STARTING AT t*10. AND DURATION 60." \
      (test_op "from foo select t, value aggregates using max event starting at t*10 with duration 60s")

    "FROM 'foo' SELECT in.t1, in.t2, in.value EVENT STARTING AT t1*10. AND STOPPING AT t2*10." \
      (test_op "from foo select t1, t2, value event starting at t1*10. and stopping at t2*10.")

    "FROM 'foo' NOTIFY \"ouch\"" \
      (test_op "from foo NOTIFY \"ouch\"")

    "FROM 'foo' SELECT MIN LOCALLY skip nulls(in.start) AS start, \\
       MAX LOCALLY skip nulls(in.stop) AS max_stop, \\
       (SUM LOCALLY skip nulls(in.packets)) / \\
         (param.avg_window) AS packets_per_sec \\
     GROUP BY (in.start) / ((1000000) * (param.avg_window)) \\
     COMMIT AFTER \\
       ((MAX LOCALLY skip nulls(in.start)) + (3600)) > (out.start)" \
        (test_op "select min start as start, \\
                           max stop as max_stop, \\
                           (sum packets)/avg_window as packets_per_sec \\
                   from foo \\
                   group by start / (1_000_000 * avg_window) \\
                   commit after out.start < (max in.start) + 3600")

    "FROM 'foo' SELECT 1 AS one GROUP BY true COMMIT BEFORE (SUM LOCALLY skip nulls(1)) >= (5)" \
        (test_op "select 1 as one from foo commit before sum 1 >= 5 group by true")

    "FROM 'foo/bar' SELECT in.n, LAG GLOBALLY skip nulls(2, out.n) AS l" \
        (test_op "SELECT n, lag(2, n) AS l FROM foo/bar")

    "READ AND DELETE IF false FILES \"/tmp/toto.csv\"  SEPARATOR \",\" NULL \"\" (f1 BOOL?, f2 I32)" \
      (test_op "read file \"/tmp/toto.csv\" (f1 bool?, f2 i32)")

    "READ AND DELETE IF true FILES \"/tmp/toto.csv\"  SEPARATOR \",\" NULL \"\" (f1 BOOL?, f2 I32)" \
      (test_op "read and delete file \"/tmp/toto.csv\" (f1 bool?, f2 i32)")

    "READ AND DELETE IF false FILES \"/tmp/toto.csv\"  SEPARATOR \"\\t\" NULL \"<NULL>\" (f1 BOOL?, f2 I32)" \
      (test_op "read file \"/tmp/toto.csv\" \\
                      separator \"\\t\" null \"<NULL>\" \\
                      (f1 bool?, f2 i32)")

    "SELECT 1 AS one EVERY 1 SECONDS" \
        (test_op "YIELD 1 AS one EVERY 1 SECOND")
  *)

  (*$>*)
end
