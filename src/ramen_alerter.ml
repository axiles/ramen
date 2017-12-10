(* Alert manager: receive alert signals from Ramen configuration and:
 * - deduplicate the alerts (same team, same name);
 * - find who to contact, and how (including cascading process);
 * - deliver the notifications;
 * - handle acknowledgments.
 *
 * Even when one want to manage several independent organizations it's better
 * to have one executable per organization, in order to simplify the data model
 * and also to make progressive rollouts possible.
 *)
open Batteries
open Helpers
open RamenHttpHelpers
open SqliteHelpers
open RamenLog
open Lwt
open AlerterSharedTypesJS

(* Purge inhibitions stopped for more than: *)
let max_inhibit_age = 24. *. 3600.

let () =
  async_exception_hook := (fun exn ->
    !logger.error "Received exception %s\n%s"
      (Printexc.to_string exn)
      (Printexc.get_backtrace ()))

let syslog = Syslog.openlog "ramen_alerter"

(* We want to have a global state of the alert management situation that we
 * can save regularly and restore whenever we start in order to limit the
 * disruption in case of a crash: *)

(* Notice there is no team: if someone is in a team and is found to be
 * oncall at some time then he will be sent the alerts.
 * If your belon to several team but want to be oncall for only one then
 * merely create several identities. *)
type schedule = {
  rank : int ;
  from : float ;
  oncaller : string }

(* The part of the internal state that we persist on disk: *)
type persisted_state = {
  (* Ongoing incidents stays there until they are manually closed (with
   * comment, reason, etc...) *)
  ongoing_incidents : (int, Incident.t) Hashtbl.t ;

  (* Used to give a unique id to any escalation so that we can ack them. *)
  mutable next_alert_id : int ;

  (* Same for incidents: *)
  mutable next_incident_id : int ;

  (* And inhibitions: *)
  mutable next_inhibition_id : int ;

  (* Teams *)
  mutable oncallers : OnCaller.t list ;
  mutable teams : Team.t list ;
  schedule : schedule list }

type state = {
  (* Where this state is saved *)
  save_file : string option ;
  default_team : string ;
  mutable dirty : bool ;

  (* What is saved onto/restored from disk to avoid losing context when
   * stopping or crashing: *)
  persist : persisted_state ;

  (* TODO: a file *)
  mutable archived_incidents : Incident.t list }

let is_inhibited state name team now =
  match List.find (fun t -> t.Team.name = team) state.persist.teams with
  | exception Not_found -> false
  | team ->
    let open Inhibition in
    (* First remove all expired inhibitions: *)
    let inhibitions, changed =
      List.fold_left (fun (inhibitions, changed) i ->
        if i.stop_date > now -. max_inhibit_age then
          i :: inhibitions, changed
        else
          inhibitions, true) ([], false) team.Team.inhibitions in
    if changed then (
      team.inhibitions <- inhibitions ;
      state.dirty <- true) ;
    (* See if this alert is inhibited: *)
    List.exists (fun i ->
        i.stop_date > now && String.starts_with name i.what
      ) inhibitions

exception Not_implemented

module IncidentOps =
struct
  open Incident (* type of an incident is shared with JS but not the ops *)

  let make state alert =
    !logger.debug "Creating an incident for alert %s"
      (PPP.to_string Alert.t_ppp alert) ;
    let i = { id = state.persist.next_incident_id ;
              alerts = [ alert ] } in
    state.persist.next_incident_id <- state.persist.next_incident_id + 1 ;
    Hashtbl.add state.persist.ongoing_incidents i.id i ;
    state.dirty <- true ;
    i

  let is_for_team t i = team_of i = t

  let stopped_after ts i =
    match stopped i with
    | None -> true
    | Some s -> s >= ts

  let started_before ts i =
    Incident.started i <= ts

  let find_open_alert state ~name ~team ~title =
    Hashtbl.values state.persist.ongoing_incidents |>
    Enum.find_map (fun i ->
      if (List.hd i.alerts).team <> team then None else
      match List.find (fun a ->
        a.Alert.stopped_firing = None &&
        a.name = name && a.title = title) i.alerts with
      | exception Not_found -> None
      | a -> Some (i, a))

  let find_open_alert_by_id state id =
    Hashtbl.values state.persist.ongoing_incidents |>
    Enum.find_map (fun i ->
      match List.find (fun a -> a.Alert.id = id) i.alerts with
    | exception Not_found -> None
    | a -> Some (i, a))

  (* Let's be conservative and create a new incident for each new alerts.
   * User could still manually merge incidents later on. *)
  let get_or_create state alert =
    match find_open_alert state alert.Alert.name alert.team alert.title with
    | exception Not_found -> make state alert, None
    | i, a -> i, Some a

  let fold_archived state init f =
    List.fold_left f init state.archived_incidents

  let fold_ongoing state init f =
    Hashtbl.fold (fun _id i prev ->
      f prev i) state.persist.ongoing_incidents init

  let fold state init f =
    let init' = fold_ongoing state init f in
    fold_archived state init' f

  let find state i =
    Hashtbl.find state.persist.ongoing_incidents i

  let remove state i =
    Hashtbl.remove state.persist.ongoing_incidents i

  (* Move i1 alerts into i2 *)
  let merge_into state i1 i2 =
    let inc1, inc2 = find state i1, find state i2 in
    inc2.alerts <- List.rev_append inc1.alerts inc2.alerts ;
    remove state i1

  let archive state i =
    remove state i.id ;
    state.archived_incidents <- i :: state.archived_incidents
end

module AlertOps =
struct
  open Alert (* type of an alert is shared with JS but not the ops *)

  let make state name team importance title text started_firing now =
    let id = state.persist.next_alert_id in
    state.persist.next_alert_id <- state.persist.next_alert_id + 1 ;
    { id ; name ; team ; importance ; title ; text ; started_firing ;
      stopped_firing = None ; received = now ; escalation = None ;
      log = [] }

  let log alert event_time event =
    let current_time = Unix.gettimeofday () in
    !logger.info "Alert %s: %s"
      alert.name (PPP.to_string Alert.event_ppp event) ;
    alert.log <- { current_time ; event_time ; event } :: alert.log

  let stop state i a source time =
    a.stopped_firing <- Some time ;
    a.escalation <- None ;
    log a time (Stop source) ;
    (* If no more alerts are firing, archive the incident *)
    let stopped_firing a = a.Alert.stopped_firing <> None in
    if List.for_all stopped_firing i.Incident.alerts then
      IncidentOps.archive state i
end

module OnCallerOps =
struct
  open OnCaller

  let default_oncaller =
    { name = "default_oncall" ;
      contacts = [| Contact.Console |] }

  let get_contacts state oncaller_name =
    match List.find (fun c -> c.OnCaller.name = oncaller_name
            ) state.persist.oncallers with
    | exception Not_found -> [||]
    | oncaller -> oncaller.OnCaller.contacts

  let get state name =
    (* Notice this does not even check the name is in the DB at all,
     * but that's not really needed ATM. *)
    let contacts = get_contacts state name in
    { name ; contacts }

  let who_is_oncall state team rank time =
    match List.find (fun t -> t.Team.name = team) state.persist.teams with
    | exception Not_found ->
      default_oncaller
    | team ->
      (match
        List.fold_left (fun best_s s ->
            if s.rank <> rank || s.from > time ||
               not (List.exists ((=) s.oncaller) team.members)
            then best_s else
            match best_s with
            | None -> Some s
            | Some best ->
              if s.from >= best.from then Some s else best_s
          ) None state.persist.schedule with
      | None -> default_oncaller
      | Some s -> get state s.oncaller)

  let assign_unassigned state =
    (* All oncallers not member of any team will be added to the "slackers"
     * team, which will be created if it doesn't exists. *)
    let all_assigned =
      List.fold_left (fun s t ->
          List.fold_left (fun s o ->
            Set.add o s) s t.Team.members
        ) Set.empty state.persist.teams in
    let unassigned =
      List.filter_map (fun o ->
          if Set.mem o.name all_assigned then None
          else Some o.name
        ) state.persist.oncallers in
    if unassigned <> [] then (
      !logger.info "Oncallers %a are slackers"
        (List.print String.print) unassigned ;
      state.dirty <- true ;
      let slackers = "Slackers" in
      match List.find (fun t -> t.Team.name = slackers)
                      state.persist.teams with
      | exception Not_found ->
        state.persist.teams <-
          Team.{ name = slackers ; members = unassigned ;
                 escalations = [] ; inhibitions = [] } ::
            state.persist.teams
      | t ->
        t.members <- List.rev_append unassigned t.members
    )
end

module Sender =
struct
  let string_of_alert alert attempt victim =
    Printf.sprintf "\
      Title: %s\n\
      Time: %s\n\
      Id: %d\n\
      Attempt: %d\n\
      Dest: %s\n\
      %s\n\n%!"
      alert.Alert.title (string_of_time alert.started_firing)
      alert.id attempt victim alert.text

  exception CannotSendAlert of string

  let send_mail ~subject ~cc ~bcc dest body =
    let cmd =
      ("", [|"mail"; "-s"; subject; "-c"; cc; "-b"; bcc; dest|]) in
    let%lwt status =
      run_coprocess "send mail" ~timeout:10. ~to_stdin:body cmd in
    if status = Unix.WEXITED 0 then (
      !logger.debug "Mail sent" ;
      return_unit
    ) else (
      let err = string_of_process_status status in
      !logger.error "Cannot send mail: %s" err ;
      fail (CannotSendAlert err)
    )

  let via_console alert attempt victim =
    Printf.printf "%s\n%!" (string_of_alert alert attempt victim) ;
    return_unit

  let via_syslog alert attempt victim =
    let level =
      match alert.Alert.importance with
      | 0 -> `LOG_EMERG | 1 -> `LOG_ALERT | 2 -> `LOG_CRIT
      | 3 -> `LOG_ERR | 4 -> `LOG_WARNING | 5 -> `LOG_NOTICE
      | _ -> `LOG_INFO in
    let msg =
      Printf.sprintf "Name=%s;Title=%s;Id=%d;Attempt=%d;Dest=%s;Text=%s"
        alert.name alert.title alert.id attempt victim alert.text in
    wrap (fun () -> Syslog.syslog syslog level msg)

  let via_email to_ cc bcc alert attempt victim =
    let body = string_of_alert alert attempt victim in
    (* TODO: there should be a link to an acknowledgement URL *)
    let subject = "ALERT: "^ alert.title in
    send_mail ~subject ~cc ~bcc to_ body

  let via_sqlite file insert_q create_q alert attempt victim =
    let open Sqlite3 in
    let handle = db_open file in
    let replacements =
      [ "$ID$", string_of_int alert.Alert.id ;
        "$NAME$", sql_quote alert.name ;
        "$STARTED$", string_of_float alert.started_firing ;
        "$STOPPED$", (match alert.stopped_firing with
                     | Some f -> string_of_float f
                     | None -> "NULL") ;
        "$TEXT$", sql_quote alert.text ;
        "$TITLE$", sql_quote alert.title ;
        "$TEAM$", sql_quote alert.team ;
        "$IMPORTANCE$", string_of_int alert.importance ;
        "$VICTIM$", sql_quote victim ;
        "$ATTEMPT$", string_of_int attempt ] in
    let q = List.fold_left (fun str (sub, by) ->
      String.nreplace ~str ~sub ~by) insert_q replacements in
    let db_fail err q =
      let msg =
        Printf.sprintf "Cannot %S into sqlite DB %S: %s"
          q file (Rc.to_string err) in
      fail (CannotSendAlert msg) in
    let exec_or_fail q =
      match exec handle q with
      | Rc.OK -> return_unit
      | err -> db_fail err q in
    let%lwt () =
      match exec handle q with
      | Rc.OK -> return_unit
      | Rc.ERROR when create_q <> "" ->
        !logger.info "Creating table in sqlite DB %S" file ;
        let%lwt () = exec_or_fail create_q in
        exec_or_fail q
      | err ->
        db_fail err q in
    close ~max_tries:30 handle

  let via_todo _alert _attempt _victim = fail Not_implemented

  let get =
    let open Contact in
    function
    | Console -> via_console
    | SysLog -> via_syslog
    | Email { to_ ; cc ; bcc } -> via_email to_ cc bcc
    | Sqlite { file ; insert ; create } -> via_sqlite file insert create
    | SMS _ -> via_todo
end

module EscalationOps =
struct
  open Escalation

  let default_escalation now =
    (* First send type 0, then after 5 minutes send type 1 then after 10
     * minutes send type 2, and repeat type 2 every 10 minutes: *)
    { steps = [|
        { timeout = 350. ; victims = [| 0 |] } ;
        { timeout = 600. ; victims = [| 0 ; 1 |] } ;
        { timeout = 600. ; victims = [| 0 ; 1 |] } |] ;
      attempt = 0 ; last_sent = now }

  let make state alert now =
    !logger.debug "Creating an escalation" ;
    (* We might not find a configuration corresponding to this alert
     * importance. In that case we take the configuration for the next
     * most important alerts: *)
    match List.find (fun t -> t.Team.name = alert.Alert.team
            ) state.persist.teams with
    | exception Not_found ->
      default_escalation now
    | team ->
      (match 
        List.fold_left (fun best esc ->
            if esc.Team.importance > alert.Alert.importance then best else
            match best with
            | None -> Some esc
            | Some best_e ->
              if esc.importance > best_e.importance then Some esc
              else best
          ) None team.escalations with
      | None -> default_escalation now
      | Some e ->
        Escalation.{
          steps = Array.of_list e.Team.steps ;
          attempt = 0 ; last_sent = now })

  (* Send a message and prepare the escalation *)
  let outcry_once state alert step attempt now =
    (* We figure out who the oncallers are at each attempt of each alert of an
     * incident. This means that if the incident happens during an oncall
     * shift the new oncallers get involved in the middle of the action while
     * the previous oncallers, still firefighting, stop to receive updates.
     * This is on purpose: we want the incident to be handed over so at this
     * point we expect both oncall squads are already collaborating. In case
     * the previous squad hopes to finish firefighting soon and to avoid
     * bothering next squad then they can easily silence the incident anyway.
     *
     * How we actually contact an oncaller depends on its personal preferences
     * so we now need to know who exactly are we going to bother. Note that
     * here [victims] is nothing but the rank of the oncallers to be
     * targeted. *)
    let _contacted, ths =
      Array.fold_left (fun (contacted, ths as prev) rank ->
          let open OnCallerOps in
          let victim = who_is_oncall state alert.Alert.team rank now in
          let contact = get_cap victim.contacts (attempt - 1) in
          !logger.debug "%d oncall is %s, contact for attempt %d is: %s"
            rank victim.name attempt (PPP.to_string Contact.t_ppp contact) ;
          if Set.mem contact contacted then (
              !logger.debug "Skipping since already contacted" ;
              prev
          ) else (
            let sender = Sender.get contact in
            AlertOps.log alert now (Alert.Outcry (victim.name, contact)) ;
            Set.add contact contacted,
            sender alert attempt victim.name :: ths)
        ) (Set.empty, []) step.victims in
    join ths

  (* Same as above, but escalate until delivery *)
  let outcry state alert esc now =
    let rec loop () =
      let step = get_cap esc.steps esc.attempt in
      esc.attempt <- esc.attempt + 1 ;
      AlertOps.log alert now (Alert.Escalate step) ;
      (try%lwt
        let%lwt () = outcry_once state alert step esc.attempt now in
        esc.last_sent <- now ;
        return_unit
      with exn ->
        !logger.error "Cannot reach oncaller: %s"
          (Printexc.to_string exn) ;
        if esc.attempt - 1 < Array.length esc.steps - 1 then (
          loop ()
        ) else (
          !logger.error "All contacts have failed, giving up" ;
          return_unit)) in
    loop ()

  let fold_ongoing state init f =
    IncidentOps.fold_ongoing state init (fun prev i ->
      List.fold_left (fun prev a ->
        match a.Alert.escalation with
        | Some esc ->
          assert (a.stopped_firing = None) ;
          f prev a esc
        | None -> prev) prev i.alerts)
end

let check_escalations state now =
  EscalationOps.fold_ongoing state [] (fun prev alert esc ->
      let timeout =
        (* If we have not tried yet there is no possible timeout. *)
        if esc.attempt = 0 then 0. else
          (* Check the timeout of the current attempt: *)
          let step = get_cap esc.steps (esc.attempt - 1) in
          esc.last_sent +. step.timeout in
      if now >= timeout then (
        EscalationOps.outcry state alert esc now :: prev
      ) else prev
    ) |>
  join

let get_state save_file default_team =
  let get_new () =
    { ongoing_incidents = Hashtbl.create 5 ;
      next_alert_id = 0 ;
      next_incident_id = 0 ;
      next_inhibition_id = 0 ;
      oncallers = [ OnCaller.{ name = "John Doe" ;
                               contacts = [| Contact.Console |] } ] ;
      teams = [
        Team.{ name = "Firefighters" ;
               members = [ "John Doe" ] ;
               escalations = [
                 { importance = 0 ;
                   steps = Escalation.[
                     { victims = [| 0 |] ; timeout = 350. } ;
                     { victims = [| 0; 1 |] ; timeout = 350. } ] } ] ;
               inhibitions = [] } ] ;
      schedule = [ { rank = 0 ; from = 0. ; oncaller = "John Doe" } ] }
  in
  let persist =
    match save_file with
    | Some fname ->
      (try
         File.with_file_in fname (fun ic -> Marshal.input ic)
       with Sys_error err ->
             !logger.debug "Cannot read state from file %S: %s. Starting anew."
                 fname err ;
             get_new ()
          | BatInnerIO.No_more_input ->
             !logger.debug "Cannot read state from file %S: not enough input. Starting anew."
                 fname ;
             get_new ())
    | None -> get_new ()
  in
  let state =
    { save_file ; dirty = false ; default_team ;
      persist ; archived_incidents = [] } in
  let rec check_escalations_loop () =
    let now = Unix.gettimeofday () in
    let%lwt () = catch
      (fun () -> check_escalations state now)
      (fun e ->
        print_exception e ;
        return_unit) in
    Lwt_unix.sleep 0.5 >>=
    check_escalations_loop
  in
  async check_escalations_loop ;
  return state

let save_state state =
  if state.dirty then (
    Option.may (fun fname ->
        !logger.debug "Saving state in file %S." fname ;
        File.with_file_out ~mode:[`create; `trunc] fname (fun oc ->
          Marshal.output oc state.persist)
      ) state.save_file ;
    state.dirty <- false
  )

(* Everything start by: we receive an alert with a name, a team name,
 * and a description (text + title). *)
let alert state ~name ~team ~importance ~title ~text ~firing ~time ~now =
  if firing then (
    (* First step: deduplication *)
    let alert =
      AlertOps.make state name team importance title text time now in
    match IncidentOps.get_or_create state alert with
    | _i, Some orig_alert ->
      AlertOps.log orig_alert time (NewNotification Duplicate) ;
      return_unit
    | _i, None ->
      if is_inhibited state name team now then (
        AlertOps.log alert time (NewNotification Inhibited) ;
        return_unit
      ) else (
        let esc = EscalationOps.make state alert now in
        alert.escalation <- Some esc ;
        AlertOps.log alert time (NewNotification StartEscalation) ;
        state.dirty <- true ;
        (* Let the implicit timeout or 0 deliver the first page. *)
        save_state state ;
        return_unit
      )
  ) else (
    (* Retrieve the alert and close it *)
    (match IncidentOps.find_open_alert state ~name ~team ~title with
    | exception Not_found ->
      (* Maybe we just started in non-firing position, or the incident
       * have been manually archived already. Better not ask too many
       * questions and just log. *)
      !logger.info "Unknown alert %s for team %s titled %S stopped firing."
        name team title
    | i, a ->
      AlertOps.stop state i a Notification time) ;
    return_unit
  )

let acknowledge state id =
  (* TODO: the time when the ack was sent *)
  let now = Unix.gettimeofday () in
  try
    IncidentOps.fold_ongoing state () (fun () i ->
      List.iter (fun alert ->
          if alert.Alert.id = id then (
            AlertOps.log alert now Ack ;
            alert.Alert.escalation <- None ;
            raise Exit
          )
        ) i.Incident.alerts) ;
    !logger.error "Received an ack for unknown id %d!" id
  with Exit -> ()

module HttpSrv =
struct
  let replace_placeholders body = return body

  let serve_string body =
    let%lwt body = replace_placeholders body in
    respond_ok ~body ~ct:Consts.html_content_type ()

  let find_team state name =
    match List.find (fun t -> t.Team.name = name) state.persist.teams with
    | exception Not_found ->
      bad_request ("unknown team "^ name)
    | t -> return t

  let notify state params =
    let hg = Hashtbl.find_default params
    and now = Unix.gettimeofday () in
    match hg "name" "alert",
          hg "importance" "10" |> int_of_string,
          hg "time" (string_of_float now) |> float_of_string,
          hg "firing" "true" |> looks_like_true with
    | exception _ ->
      fail (HttpError (400, "importance and now must be numeric"))
    | name, importance, time, firing ->
      state.dirty <- true ;
      alert state ~name ~importance ~now ~time ~firing
        ~team:(hg "team" state.default_team)
        ~title:(hg "title" "")
        ~text:(hg "text" "") >>=
      Cohttp_lwt_unix.Server.respond_string ~status:(`Code 200) ~body:""

  let get_teams state =
    let body = PPP.to_string Team.get_resp_ppp state.persist.teams in
    respond_ok ~body ()

  let new_team state _headers name =
    match List.find (fun t -> t.Team.name = name) state.persist.teams with
    | exception Not_found ->
      state.persist.teams <-
        Team.{ name ; members = [] ; escalations = [] ;
               inhibitions = [] } :: state.persist.teams ;
      state.dirty <- true ;
      respond_ok ()
    | _ ->
      bad_request ("Team "^ name ^" already exists")

  let get_oncaller state _headers name =
    let oncaller = OnCallerOps.get state name in
    let body = PPP.to_string OnCaller.t_ppp oncaller in
    respond_ok ~body ()

  let get_ongoing state team_opt =
    let incidents =
      Hashtbl.fold (fun _id incident prev ->
          match incident.Incident.alerts with
          | [] -> prev (* Should not happen *)
          | a :: _ ->
            let is_selected =
              match team_opt with None -> true
                                | Some t -> a.team = t in
            if is_selected then (
              incident :: prev
            ) else prev
        ) state.persist.ongoing_incidents [] in
    let body =
      PPP.to_string GetOngoing.resp_ppp incidents in
    respond_ok ~body ()

  let get_history state _headers team time_range =
    (* For now we have the whole history in a single file. *)
    let is_in_team =
      match team with
      | Some t -> fun i -> IncidentOps.is_for_team t i
      | None -> fun _ -> true
    and is_in_range =
      match time_range with
      | GetHistory.LastSecs s ->
          let min_ts = Unix.gettimeofday () -. s in
          IncidentOps.stopped_after min_ts
      | GetHistory.SinceUntil (s, u) ->
          fun i ->
            IncidentOps.stopped_after s i &&
            IncidentOps.started_before u i in
    let is_in i =
      is_in_team i && is_in_range i in
    let logs =
      IncidentOps.fold state [] (fun prev i ->
        if is_in i then i :: prev else prev) in
    let body = PPP.to_string GetHistory.resp_ppp logs in
    respond_ok ~body ()

  let get_history_post state headers body =
    let%lwt req = of_json headers "Get History" GetHistory.req_ppp body in
    get_history state headers req.team req.time_range

  let get_history_get state headers team params =
    let%lwt time_range =
      match Hashtbl.find params "last" with
      | exception Not_found ->
        (match Hashtbl.find params "range" with
        | exception Not_found ->
          fail (HttpError (400, "Missing parameter: last or range"))
        | r ->
          (try
            let s, u = String.split ~by:"," r in
            GetHistory.SinceUntil (float_of_string (min s u),
                                   float_of_string (max s u)) |>
            return
          with Not_found | Failure _ ->
            let msg = "Invalid parameter: range must be \
                       timestamp,timestamp" in
            fail (HttpError (400, msg))))
      | l ->
        (try GetHistory.LastSecs (float_of_string l) |> return
        with Failure _ ->
          let msg = "Invalid parameter: last must be a numeric" in
          fail (HttpError (400, msg))) in
    get_history state headers team time_range

  let alert_of_id state id =
    try IncidentOps.find_open_alert_by_id state id |> return
    with Not_found ->
      bad_request "No alert with that id in opened incidents"

  let get_ack state id =
    let%lwt _i, a = alert_of_id state id in
    (* We record the ack regardless of stopped_firing *)
    AlertOps.log a (Unix.gettimeofday ()) Alert.Ack ;
    a.escalation <- None ;
    state.dirty <- true ;
    respond_ok ()

  (* Stops an alert as if a notification with firing=f have been received *)
  let get_stop state id =
    let%lwt i, a = alert_of_id state id in
    let now = Unix.gettimeofday () in
    AlertOps.stop state i a Manual now ;
    state.dirty <- true ;
    respond_ok ()

  (* Inhibitions *)

  let user = "anonymous user"

  let add_inhibit_ state team inhibit =
    let open Inhibition in
    let%lwt team = find_team state team in
    let id = state.persist.next_inhibition_id in
    state.persist.next_inhibition_id <-
      state.persist.next_inhibition_id + 1 ;
    state.dirty <- true ;
    let inhibit = { inhibit with id } in
    (* TODO: lock the conf with a RW lock *)
    match List.find (fun i -> i.id = inhibit.id) team.Team.inhibitions with
    | exception Not_found ->
      team.inhibitions <- inhibit :: team.inhibitions ;
      return_unit
    | _ ->
      failwith "Found an inhibit with next id?"

  let edit_inhibit state headers team body =
    let open Inhibition in
    let%lwt inhibit = of_json headers "Inhibit" Inhibition.t_ppp body in
    let%lwt team = find_team state team in
    (* Note: one do not delete inhibitions but one can set a past
     * stop_date. *)
    match List.find (fun i -> i.id = inhibit.id) team.Team.inhibitions with
    | exception Not_found ->
      bad_request "No such inhibition"
    | i ->
      i.what <- inhibit.what ;
      i.start_date <- inhibit.start_date ;
      i.stop_date <- inhibit.stop_date ;
      i.why <- inhibit.why ;
      state.dirty <- true ;
      respond_ok ()

  let add_inhibit state headers team body =
    let%lwt inhibit = of_json headers "Inhibit" Inhibition.t_ppp body in
    add_inhibit_ state team inhibit >>=
    respond_ok (* TODO: why not returning the GetTeam.resp directly? *)

  let stfu state _headers team =
    let open Inhibition in
    let now = Unix.gettimeofday () in
    let inhibit =
      { id = -1 ; what = "" ; start_date = now ; stop_date = now +. 3600. ;
        who = user ; why = "STFU!" } in
    add_inhibit_ state team inhibit >>=
    respond_ok

  let save_oncaller state headers name body =
    let%lwt oncaller =
      of_json headers "Save Oncaller" OnCaller.t_ppp body in
    let rec list_replace prev = function
      | [] -> List.rev (oncaller :: prev) (* New one *)
      | c :: rest ->
        if c.OnCaller.name = name then
          List.rev_append prev (oncaller :: rest)
        else
          list_replace (c :: prev) rest in
    state.persist.oncallers <- list_replace [] state.persist.oncallers ;
    state.dirty <- true ;
    respond_ok ()

  let save_members state headers name body =
    let%lwt members =
      of_json headers "Save members" Team.set_members_ppp body in
    let%lwt team = find_team state name in
    team.Team.members <- members ;
    OnCallerOps.assign_unassigned state ;
    state.dirty <- true ;
    respond_ok ()

  let start port cert_opt key_opt state www_dir =
    let router meth path params headers body =
      let alert_id_of_string s =
        match int_of_string s with
        | exception Failure _ ->
            bad_request "alert id must be numeric"
        | id -> return id in
      let%lwt resp =
        match meth, path with
        | `GET, ["notify"] ->
          notify state params
        | `GET, ["teams"] ->
          get_teams state
        | `GET, ["team"; "new"; name] ->
          new_team state headers name
        | `GET, ["oncaller"; name] ->
          get_oncaller state headers name
        | `GET, ["ongoing"] ->
          get_ongoing state None
        | `GET, ["ongoing"; team] ->
          get_ongoing state (Some team)
        | (`POST|`PUT), ["history"] ->
          get_history_post state headers body
        | `GET, ("history" :: team) ->
          let team = if team = [] then None else Some (List.hd team) in
          get_history_get state headers team params
        | `GET, ["ack" ; id] ->
          let%lwt id = alert_id_of_string id in
          get_ack state id
        | `GET, ["stop" ; id] ->
          let%lwt id = alert_id_of_string id in
          get_stop state id
        | `POST, ["inhibit"; "add"; team] ->
          add_inhibit state headers team body
        | `POST, ["inhibit"; "edit" ; team] ->
          edit_inhibit state headers team body
        | `GET, ["stfu" ; team] ->
          stfu state headers team
        | `POST, ["oncaller"; name] ->
          save_oncaller state headers name body
        | `POST, ["members"; name] ->
          save_members state headers name body
        (* Web UI *)
        | `GET, ([]|["index.html"]) ->
          if www_dir = "" then
            serve_string AlerterGui.without_link
          else
            serve_string AlerterGui.with_links
        | `GET, ["style.css" | "alerter_script.js" as file] ->
          serve_file www_dir file replace_placeholders
        (* Everything else is an error: *)
        | _ ->
          fail (HttpError (404, "No such resource")) in
      save_state state ;
      return resp
  in
  http_service port cert_opt key_opt router
end

(*
 * Start the notification listener
 *)

open Cmdliner

let debug =
  let env = Term.env_info "ALERT_DEBUG" in
  let i = Arg.info ~doc:"increase verbosity"
                   ~env ["d"; "debug"] in
  Arg.(value (flag i))

let daemonize =
  let env = Term.env_info "ALERT_DAEMONIZE" in
  let i = Arg.info ~doc:"daemonize"
                   ~env [ "daemon"; "daemonize"] in
  Arg.(value (flag i))

let to_stderr =
  let env = Term.env_info "ALERT_LOG_TO_STDERR" in
  let i = Arg.info ~doc:"log onto stderr"
                   ~env [ "log-onto-stderr"; "log-to-stderr"; "to-stderr";
                          "stderr" ] in
  Arg.(value (flag i))

let log_dir =
  let env = Term.env_info "ALERT_LOG_DIR" in
  let i = Arg.info ~doc:"Directory where to write log files into"
                   ~env [ "log-dir" ; "logdir" ] in
  Arg.(value (opt (some string) None i))

let http_port =
  let env = Term.env_info "ALERT_HTTP_PORT" in
  let i = Arg.info ~doc:"Port where to run the HTTP server \
                         (HTTPS will be run on that port + 1)"
                   ~env [ "http-port" ] in
  Arg.(value (opt int 29382 i))

let ssl_cert =
  let env = Term.env_info "ALERT_SSL_CERT_FILE" in
  let i = Arg.info ~doc:"File containing the SSL certificate"
                   ~env [ "ssl-certificate" ] in
  Arg.(value (opt (some string) None i))

let ssl_key =
  let env = Term.env_info "ALERT_SSL_KEY_FILE" in
  let i = Arg.info ~doc:"File containing the SSL private key"
                   ~env [ "ssl-key" ] in
  Arg.(value (opt (some string) None i))

let save_file =
  let env = Term.env_info "ALERT_SAVE_FILE" in
  let i = Arg.info ~doc:"file where to save the current state of alerting"
                   ~env ["save-file"] in
  Arg.(value (opt (some string) None i))

let default_team =
  let env = Term.env_info "ALERT_DEFAULT_TEAM" in
  let i = Arg.info ~doc:"default team when unspecified in the notification"
                   ~env ["default-team"] in
  Arg.(value (opt string "firefighters" i))

let www_dir =
  let env = Term.env_info "ALERTER_WWW_DIR" in
  let i = Arg.info ~doc:"Directory where to read the files served \
                         via HTTP for the GUI (serve from memory \
                         if unset)"
                   ~env [ "www-dir" ; "www-root" ; "web-dir" ; "web-root" ] in
  Arg.(value (opt string "" i))

let start_all debug daemonize to_stderr logdir save_file
              default_team http_port ssl_cert ssl_key www_dir () =
  if to_stderr && daemonize then
    failwith "Options --daemonize and --to-stderr are incompatible." ;
  if to_stderr && logdir <> None then
    failwith "Options --log-dir and --to-stderr are incompatible." ;
  Option.may mkdir_all logdir ;
  logger := make_logger ?logdir debug ;
  if daemonize then do_daemonize () ;
  Lwt_main.run (
    let%lwt alerter_state = get_state save_file default_team in
    HttpSrv.start http_port ssl_cert ssl_key alerter_state www_dir)

let start_cmd =
  Term.(
    (const start_all
      $ debug
      $ daemonize
      $ to_stderr
      $ log_dir
      $ save_file
      $ default_team
      $ http_port
      $ ssl_cert
      $ ssl_key
      $ www_dir),
    info "ramen_alerter")

let () =
  match Term.eval start_cmd with
  | `Ok f -> f ()
  | x -> Term.exit x
